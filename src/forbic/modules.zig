//! Immutable virtual-module discovery and checked source provenance. No I/O.
const std = @import("std");
const storage_init = @import("scratch.zig");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const Span = types.Span;
const Token = lexer.Token;
const origin: Span = .{ .start = 0, .end = 0 };

pub const Input = struct { path: []const u8, source: []const u8 };
/// `parts` is empty for a bundle of files. A bundle given as a folder tree (RFC-0093) has a
/// module path for its root and files for its modules; `Folders.join` turns it into one input
/// per folder, whose text is the folder's files, and lists them in `parts`.
pub const Bundle = struct { root: []const u8, modules: []const Input, parts: []const Part = &.{} };
/// RFC-0093: one file of a module given as a folder, as `Folders.join` makes it: the file's own
/// path and source, the input (module) it is a part of, and where its text starts in that input.
pub const Part = struct { module: u32, path: []const u8, source: []const u8, start: u32 };
pub const LocatedDiagnostic = struct { path: []const u8, source: []const u8, diagnostic: types.Diagnostic };
pub const Prepared = struct { source: []const u8, paths: []const u8, modules: []const types.Module, imports: []const types.Import, nested: []const types.NestedModule = &.{}, parts: []const types.ModulePart = &.{}, file_paths: []const u8 = "" };
pub const Result = union(enum) { ok: Prepared, failed: LocatedDiagnostic };
const CachedImport = struct { alias: Span, path: Span, target: u32 };
const Header = struct { start: u32 = 0, end: u32 = 0 };
const Frame = struct { entry: u32, next: u32 };

pub const Storage = struct {
    source: [types.limits.source_bytes]u8 = undefined,
    paths: [types.limits.module_paths_bytes]u8 = undefined,
    modules: [types.limits.modules]types.Module = undefined,
    imports: [types.limits.imports]types.Import = undefined,
    cached: [types.limits.imports]CachedImport = undefined,
    headers: [types.limits.modules]Header = undefined,
    states: [types.limits.modules]enum { unseen, active, done } = undefined,
    /// RFC-0093 (c1-1): the inputs the program reaches, in the order of their paths; whether
    /// `throughFolders` has read an input it does not reach; and the modules of the one it reads.
    reached: [types.limits.modules]u32 = undefined,
    peeked: [types.limits.modules]bool = undefined,
    peek_nested: [types.limits.modules]types.NestedModule = undefined,
    order: [types.limits.modules]u32 = undefined,
    mapping: [types.limits.modules]u32 = undefined,
    frames: [types.limits.modules]Frame = undefined,
    /// Modules declared inside files (RFC-0074): as scanned, with spans relative to their file,
    /// and as published, in the order of the prepared source.
    nested_cached: [types.limits.modules]types.NestedModule = undefined,
    nested_headers: [types.limits.modules]Header = undefined,
    nested: [types.limits.modules]types.NestedModule = undefined,
    nested_cached_count: u32 = 0,
    nested_count: u32 = 0,
    /// Some scanned file declares a name `module`, so `Name := module{...}` keeps the meaning
    /// it had before modules could nest: the construction of a value of that type.
    module_named: bool = false,
    /// The first problem with the modules some file declares, reported unless `module_named`.
    nested_problem: ?LocatedDiagnostic = null,
    source_count: u32 = 0,
    path_count: u32 = 0,
    module_count: u32 = 0,
    import_count: u32 = 0,
    cached_count: u32 = 0,
    /// RFC-0093: for a bundle given as a folder tree, the files of the modules as published, their
    /// paths, which parts of `bundle.parts` make each input, and one module's parts as spans of
    /// that input (the last one reaching its end), as the lexer takes them.
    parts: [types.limits.module_files]types.ModulePart = undefined,
    file_paths: [types.limits.module_file_paths_bytes]u8 = undefined,
    part_ranges: [types.limits.modules]Header = undefined,
    local_parts: [types.limits.module_files]types.ModulePart = undefined,
    part_count: u32 = 0,
    file_path_count: u32 = 0,
    /// The first import of the module being scanned, which the aliases of all its files follow.
    headers_start: u32 = 0,
    /// The join of a folder tree into one input per module, which outlives `prepare`.
    folders: Folders = .{},

    pub fn reset(self: *Storage) void {
        self.source_count = 0;
        self.path_count = 0;
        self.module_count = 0;
        self.import_count = 0;
        self.cached_count = 0;
        self.nested_cached_count = 0;
        self.nested_count = 0;
        self.module_named = false;
        self.nested_problem = null;
        self.part_count = 0;
        self.file_path_count = 0;
    }

    /// Inputs and token scratch have one writer and readable immutable slices.
    /// Published views borrow this storage until its next preparation/reset.
    pub fn prepare(self: *Storage, bundle: Bundle, tokens: []Token) Result {
        self.reset();
        // RFC-0093: the modules of a folder tree are named by module paths, and only such a
        // bundle has parts; `partRanges` checks that they describe its inputs.
        const folders = bundle.parts.len != 0;
        if (!(if (folders) modulePath(bundle.root) else canonicalPath(bundle.root))) return fail(.{ .path = bundle.root, .source = "" }, origin, .invalid_module_path);
        if (bundle.modules.len > self.modules.len) return fail(.{ .path = bundle.root, .source = "" }, origin, .module_limit);
        if (folders and !self.partRanges(bundle)) return fail(.{ .path = bundle.root, .source = "" }, origin, .invalid_module_metadata);
        var total: usize = 0;
        for (bundle.modules, 0..) |input, index| {
            if (!(if (folders) modulePath(input.path) else canonicalPath(input.path))) return fail(input, origin, .invalid_module_path);
            if (input.source.len > self.source.len - total) return fail(input, origin, .source_limit);
            total += input.source.len;
            if (!std.unicode.utf8ValidateSlice(input.source)) return fail(input, origin, .invalid_utf8);
            // `Folders.join` gives its inputs in the order of their paths, each once.
            if (folders) {
                if (index != 0 and !std.mem.lessThan(u8, bundle.modules[index - 1].path, input.path)) return fail(input, origin, .duplicate_module);
            } else for (bundle.modules[0..index]) |earlier| {
                if (std.mem.eql(u8, input.path, earlier.path)) return fail(input, origin, .duplicate_module);
            }
        }
        const root = (if (folders) findSorted(bundle.modules, bundle.root) else findInput(bundle.modules, bundle.root)) orelse return fail(.{ .path = bundle.root, .source = "" }, origin, .missing_module);
        @memset(self.states[0..bundle.modules.len], .unseen);
        if (self.scan(bundle, root, tokens)) |problem| return .{ .failed = problem };
        self.states[root] = .active;
        self.frames[0] = .{ .entry = root, .next = self.headers[root].start };
        var depth: usize = 1;
        while (depth != 0) {
            const frame = &self.frames[depth - 1];
            if (frame.next == self.headers[frame.entry].end) {
                self.states[frame.entry] = .done;
                self.mapping[frame.entry] = self.module_count;
                self.order[self.module_count] = frame.entry;
                self.module_count += 1;
                depth -= 1;
                continue;
            }
            const edge = self.cached[frame.next];
            frame.next += 1;
            switch (self.states[edge.target]) {
                .done => {},
                .active => return fail(bundle.modules[frame.entry], edge.path, .module_cycle),
                .unseen => {
                    if (self.scan(bundle, edge.target, tokens)) |problem| return .{ .failed = problem };
                    self.states[edge.target] = .active;
                    std.debug.assert(depth < self.frames.len);
                    self.frames[depth] = .{ .entry = edge.target, .next = self.headers[edge.target].start };
                    depth += 1;
                },
            }
        }
        // Every reachable file has been read: a bundle that declares `module` nests nothing.
        if (!self.module_named) if (self.nested_problem) |problem| return .{ .failed = problem };
        // RFC-0093: a folder's subfolders are modules of their own paths, so a module that a
        // file of the folder declares may not take a subfolder's name: `/D/A/B` names one. Nor
        // may a folder lie below it (c1-1): with `M.B` in a file of `/D/A`, a folder `/D/A/M/B`
        // under a folder `/D/A/M` that has no file made `/D/A/M/B` a folder and `/D/A/M.B` the
        // nested module. Every nested module's path begins with a top-level one's, so these
        // are the ones to check.
        if (folders and !self.module_named) for (self.order[0..self.module_count]) |entry| {
            const declared = self.nested_headers[entry];
            const input = bundle.modules[entry];
            for (self.nested_cached[declared.start..declared.end]) |module| {
                if (module.parent != types.no_parent) continue;
                var buffer: [types.limits.module_path_bytes]u8 = undefined;
                const path = joinPath(&buffer, input.path, module.name.text(input.source)) orelse continue;
                if (folderAt(InputPaths{ .inputs = bundle.modules }, bundle.modules.len, path)) return fail(input, module.name, .duplicate_name);
            }
        };
        // A folder the program does not reach was not checked above, yet the path of one it
        // reaches may pass through it: `using{/D/A/M/B}` reads the folder `/D/A/M/B`, and a file
        // of `/D/A`, which nothing else reaches, declaring `M.B` would make the path mean two
        // modules, so that adding the folder changed what the `using` meant.
        if (folders and !self.module_named) if (self.throughFolders(bundle, tokens)) |problem| return .{ .failed = problem };
        for (self.order[0..self.module_count], 0..) |entry, ordinal| {
            const input = bundle.modules[entry];
            if (ordinal != 0) {
                if (self.source_count == self.source.len) return fail(input, origin, .source_limit);
                self.source[self.source_count] = '\n';
                self.source_count += 1;
            }
            if (input.source.len > self.source.len - self.source_count) return fail(input, origin, .source_limit);
            const base = self.source_count;
            @memcpy(self.source[base..][0..input.source.len], input.source);
            self.source_count += @intCast(input.source.len);
            const path_start = self.path_count;
            @memcpy(self.paths[path_start..][0..input.path.len], input.path);
            self.path_count += @intCast(input.path.len);
            const import_start = self.import_count;
            const header = self.headers[entry];
            for (self.cached[header.start..header.end]) |edge| {
                std.debug.assert(self.mapping[edge.target] < ordinal);
                self.imports[self.import_count] = .{
                    .alias = shifted(edge.alias, base),
                    .path = shifted(edge.path, base),
                    .target = self.mapping[edge.target],
                };
                self.import_count += 1;
            }
            self.modules[ordinal] = .{
                .path = .{ .start = path_start, .end = self.path_count },
                .source = .{ .start = base, .end = self.source_count },
                .imports = .{ .start = import_start, .end = self.import_count },
            };
            // RFC-0093: the files of the module, where they now stand; the last holds the
            // library block that follows them, as a file of a bundle of files does.
            if (folders) {
                const range = self.part_ranges[entry];
                for (bundle.parts[range.start..range.end], range.start..) |part, index| {
                    const file_start = self.file_path_count;
                    @memcpy(self.file_paths[file_start..][0..part.path.len], part.path);
                    self.file_path_count += @intCast(part.path.len);
                    const end: u32 = if (index + 1 == range.end) self.source_count else base + part.start + @as(u32, @intCast(part.source.len));
                    self.parts[self.part_count] = .{ .path = .{ .start = file_start, .end = self.file_path_count }, .source = .{ .start = base + part.start, .end = end } };
                    self.part_count += 1;
                }
            }
            // A file's nested modules follow those of the files before it, in source order.
            const declared = self.nested_headers[entry];
            const first = self.nested_count;
            if (!self.module_named) for (self.nested_cached[declared.start..declared.end]) |module| {
                self.nested[self.nested_count] = .{
                    .name = shifted(module.name, base),
                    .source = shifted(module.source, base),
                    .parent = if (module.parent == types.no_parent) types.no_parent else first + module.parent,
                    .is_public = module.is_public,
                };
                self.nested_count += 1;
            };
        }
        const result: Prepared = .{ .source = self.source[0..self.source_count], .paths = self.paths[0..self.path_count], .modules = self.modules[0..self.module_count], .imports = self.imports[0..self.import_count], .nested = self.nested[0..self.nested_count], .parts = self.parts[0..self.part_count], .file_paths = self.file_paths[0..self.file_path_count] };
        std.debug.assert(validateBundle(result.source, result.paths, result.modules, result.imports, result.nested, result.parts, result.file_paths));
        return .{ .ok = result };
    }

    /// Which parts make each input of a folder tree, checked against the inputs: every input is
    /// made of a run of parts, in order, that tile its text with a newline between each, whose
    /// paths are files of the input's folder in the order of their names. `Folders.join` makes
    /// them so; this keeps `prepare` from trusting a caller that did not.
    fn partRanges(self: *Storage, bundle: Bundle) bool {
        if (bundle.parts.len > self.parts.len) return false;
        var at: u32 = 0;
        for (bundle.modules, 0..) |input, index| {
            const first = at;
            var expected: u32 = 0;
            while (at < bundle.parts.len and bundle.parts[at].module == index) : (at += 1) {
                const part = bundle.parts[at];
                if (part.start != expected or part.start > input.source.len or part.source.len > input.source.len - part.start) return false;
                if (!std.mem.eql(u8, input.source[part.start..][0..part.source.len], part.source)) return false;
                const folder = folderOf(part.path) orelse return false;
                if (!canonicalPath(part.path) or input.path.len == 0 or !std.mem.eql(u8, folder, input.path[1..])) return false;
                if (at != first and !std.mem.lessThan(u8, bundle.parts[at - 1].path, part.path)) return false;
                expected = part.start + @as(u32, @intCast(part.source.len));
                if (at + 1 < bundle.parts.len and bundle.parts[at + 1].module == index) {
                    if (expected == input.source.len or input.source[expected] != '\n') return false;
                    expected += 1;
                }
            }
            // An empty folder is no module: a module has a file. The compiler may have put the
            // module's library block after its last file (RFC-0056), which that file holds.
            if (at == first or expected > input.source.len) return false;
            self.part_ranges[index] = .{ .start = first, .end = at };
        }
        return at == bundle.parts.len;
    }

    /// One input's parts as spans of the input, the last reaching its end, for the lexer.
    fn localParts(self: *Storage, bundle: Bundle, entry: u32, length: usize) []const types.ModulePart {
        const range = self.part_ranges[entry];
        const local = self.local_parts[0 .. range.end - range.start];
        for (bundle.parts[range.start..range.end], local, 0..) |part, *out, index| {
            const end: u32 = if (index + 1 == local.len) @intCast(length) else part.start + @as(u32, @intCast(part.source.len));
            out.* = .{ .path = .{ .start = 0, .end = 0 }, .source = .{ .start = part.start, .end = end } };
        }
        return local;
    }

    fn scan(self: *Storage, bundle: Bundle, entry: u32, scratch: []Token) ?LocatedDiagnostic {
        const input = bundle.modules[entry];
        const folders = bundle.parts.len != 0;
        // RFC-0093: a comment ends with its file, also where a folder's files are one text.
        const lexed = if (folders) lexer.tokenizeParts(input.source, scratch, self.localParts(bundle, entry, input.source.len)) else lexer.tokenize(input.source, scratch);
        const tokens = switch (lexed) {
            .failed => |diagnostic| return .{ .path = input.path, .source = input.source, .diagnostic = diagnostic },
            .ok => |tokens| tokens,
        };
        const start = self.cached_count;
        self.headers_start = start;
        if (!folders) {
            if (self.scanImports(bundle, input, tokens, 0, input.source.len, false)) |problem| return problem;
            // A module path names a module of a folder tree; a file names none.
            for (tokens) |token| if (token.kind == .path) return issue(input, token.span, .folder_bundle_required);
        } else {
            // Each file of a folder starts with its imports. Every other module path its
            // text writes names a module it uses, the longest folder that the path begins
            // with: what follows is a module declared there (`using{/D/A/Inner}`).
            const range = self.part_ranges[entry];
            var at: usize = 0;
            for (bundle.parts[range.start..range.end]) |part| {
                const end = part.start + part.source.len;
                while (tokens[at].kind != .eof and tokens[at].span.start < part.start) at += 1;
                const imported = self.cached_count;
                if (self.scanImports(bundle, input, tokens, at, end, true)) |problem| return problem;
                var next = imported;
                // A statement ends with its file, as it does in a bundle of files: what a file
                // opens it closes, so no declaration takes the next file's text.
                var depth: u32 = 0;
                while (tokens[at].kind != .eof and tokens[at].span.end <= end) : (at += 1) {
                    const token = tokens[at];
                    switch (token.kind) {
                        .left_paren, .left_brace, .left_bracket => depth += 1,
                        .right_paren, .right_brace, .right_bracket => depth -|= 1,
                        else => {},
                    }
                    if (token.kind != .path) continue;
                    if (next < self.cached_count and self.cached[next].path.start == token.span.start) {
                        next += 1;
                        continue;
                    }
                    const text = token.span.text(input.source);
                    if (!modulePath(text)) return issue(input, token.span, .invalid_module_path);
                    const found = longestModule(bundle.modules, text) orelse return issue(input, token.span, .missing_module);
                    if (self.cached_count == self.cached.len) return issue(input, token.span, .import_limit);
                    self.cached[self.cached_count] = .{
                        .alias = .{ .start = token.span.start, .end = token.span.start },
                        .path = .{ .start = token.span.start, .end = token.span.start + found.length },
                        .target = found.target,
                    };
                    self.cached_count += 1;
                }
                if (depth != 0) return issue(input, .{ .start = @intCast(end), .end = @intCast(end) }, .unmatched_parenthesis);
            }
        }
        self.headers[entry] = .{ .start = start, .end = self.cached_count };
        self.scanNested(input, tokens, entry);
        return null;
    }

    /// The imports that start a file, from token `from`, before source offset `limit`: in a
    /// bundle of files `Name := import{"relative/path"}`, in a folder tree (RFC-0093)
    /// `Name := import{/Domain/Folder}`, which names the module of a folder.
    fn scanImports(self: *Storage, bundle: Bundle, input: Input, tokens: []const Token, from: usize, limit: usize, folders: bool) ?LocatedDiagnostic {
        const start = if (folders) self.headers_start else self.cached_count;
        var cursor: usize = from;
        while (true) {
            while (tokens[cursor].kind == .newline or tokens[cursor].kind == .separator) cursor += 1;
            if (tokens.len - cursor < 5 or tokens[cursor].span.start >= limit) break;
            const name = tokens[cursor];
            if (name.kind != .identifier or tokens[cursor + 1].kind != .colon or tokens[cursor + 2].kind != .equal or tokens[cursor + 3].kind != .identifier or !std.mem.eql(u8, tokens[cursor + 3].span.text(input.source), "import")) break;
            cursor += 4;
            if (tokens[cursor].kind != .left_brace) return issue(input, tokens[cursor].span, .unexpected_token);
            cursor += 1;
            while (tokens[cursor].kind == .newline) cursor += 1;
            const path = tokens[cursor];
            if (folders and path.kind != .path) return issue(input, path.span, .path_import_required);
            if (!folders and path.kind != .string) return issue(input, path.span, if (path.kind == .path) .folder_bundle_required else .invalid_module_path);
            const inner: Span = if (folders) path.span else .{ .start = path.span.start + 1, .end = path.span.end - 1 };
            cursor += 1;
            while (tokens[cursor].kind == .newline) cursor += 1;
            if (tokens[cursor].kind != .right_brace) return issue(input, tokens[cursor].span, .unexpected_token);
            cursor += 1;
            if (tokens[cursor].kind != .newline and tokens[cursor].kind != .separator and tokens[cursor].kind != .eof) return issue(input, tokens[cursor].span, .unexpected_token);
            // An alias names a module in the whole module, all its files (RFC-0093).
            for (self.cached[start..self.cached_count]) |earlier| {
                if (std.mem.eql(u8, earlier.alias.text(input.source), name.span.text(input.source))) return issue(input, name.span, .duplicate_name);
            }
            const target = if (folders) target: {
                const text = inner.text(input.source);
                if (!modulePath(text)) return issue(input, inner, .invalid_module_path);
                // An import names a folder; a module declared in one is reached through it.
                const found = longestModule(bundle.modules, text) orelse return issue(input, inner, .missing_module);
                if (found.length != text.len) return issue(input, inner, .path_import_required);
                break :target found.target;
            } else target: {
                var normalized: [types.limits.module_path_bytes]u8 = undefined;
                const resolved = resolve(input.path, inner.text(input.source), &normalized) orelse return issue(input, inner, .invalid_module_path);
                break :target findInput(bundle.modules, resolved) orelse return issue(input, inner, .missing_module);
            };
            if (self.cached_count == self.cached.len) return issue(input, name.span, .import_limit);
            self.cached[self.cached_count] = .{ .alias = name.span, .path = inner, .target = target };
            self.cached_count += 1;
        }
        return null;
    }

    /// Records the modules one file declares. A problem with them (too many, too deep, a
    /// name twice, braces that do not match) is kept, not reported: whether the bundle nests
    /// modules at all is known only when every file has been read (`module_named`).
    /// Rule 5 of RFC-0093 for the folders the program does not reach: every reached folder is
    /// reached through the folders its path begins with, and one of them that the program does
    /// not reach may not declare, at the top level of its files, a module whose path a reached
    /// folder is or lies below. Each such folder is read once, its modules into room of their
    /// own; one that does not lex, declares the name `module`, or holds more modules than any
    /// program may, could never be compiled and nests nothing. Inputs come in the order of their
    /// paths, so the reached ones sorted by index are sorted by path.
    fn throughFolders(self: *Storage, bundle: Bundle, scratch: []Token) ?LocatedDiagnostic {
        const reached = self.reached[0..self.module_count];
        @memcpy(reached, self.order[0..self.module_count]);
        std.sort.pdq(u32, reached, {}, std.sort.asc(u32));
        const paths: ReachedPaths = .{ .inputs = bundle.modules, .reached = reached };
        @memset(self.peeked[0..bundle.modules.len], false);
        for (reached) |entry| {
            const path = bundle.modules[entry].path;
            // The domain holds no `/`, so every `/` after the first ends a folder's path.
            var at: usize = 1;
            while (std.mem.indexOfScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
                const folder = findSorted(bundle.modules, path[0..slash]) orelse continue;
                if (self.states[folder] == .done or self.peeked[folder]) continue;
                self.peeked[folder] = true;
                const input = bundle.modules[folder];
                const tokens = switch (lexer.tokenizeParts(input.source, scratch, self.localParts(bundle, folder, input.source.len))) {
                    .failed => continue,
                    .ok => |tokens| tokens,
                };
                const found = scanModules(input.source, tokens, &self.peek_nested);
                if (found.named) continue;
                if (found.problem) |problem| if (problem.code == .module_limit) continue;
                for (self.peek_nested[0..found.count]) |module| {
                    if (module.parent != types.no_parent) continue;
                    var buffer: [types.limits.module_path_bytes]u8 = undefined;
                    const joined = joinPath(&buffer, input.path, module.name.text(input.source)) orelse continue;
                    if (folderAt(paths, reached.len, joined)) return issue(input, module.name, .duplicate_name);
                }
            }
        }
        return null;
    }

    fn scanNested(self: *Storage, input: Input, tokens: []const Token, entry: u32) void {
        const start = self.nested_cached_count;
        const found = scanModules(input.source, tokens, self.nested_cached[start..]);
        self.nested_cached_count += found.count;
        self.nested_headers[entry] = .{ .start = start, .end = self.nested_cached_count };
        if (found.named) self.module_named = true;
        if (found.problem) |problem| if (self.nested_problem == null) {
            self.nested_problem = issue(input, problem.span, problem.code);
        };
    }
};

const ScanProblem = struct { span: Span, code: types.Diagnostic.Code };
const Scan = struct { count: u32 = 0, named: bool = false, problem: ?ScanProblem = null };

/// Finds every `Name := module{...}` of one file: at the start of a statement of the file or
/// of a module body, never inside an expression, a comment or a string, since it reads
/// tokens. The braces are matched here; what stands between them is the parser's. Spans are
/// relative to the file and parents index `out`. Preparation and admission both run this, so
/// an admitted table is exactly the modules the text declares.
///
/// `named` says the file declares the name `module` itself (the word followed by `:` or `<`
/// where a declaration, a field or a binding may start). Such a bundle keeps the meaning
/// `Name := module{...}` had before modules could nest, the construction of a value.
fn scanModules(source: []const u8, tokens: []const Token, out: []types.NestedModule) Scan {
    const Open = struct { index: u32, depth: u32 };
    var result: Scan = .{};
    var open: [types.limits.module_depth]Open = undefined;
    var open_count: usize = 0;
    var depth: u32 = 0;
    var statement = true;
    var after_brace = false;
    var at: usize = 0;
    while (at < tokens.len) : (at += 1) {
        const token = tokens[at];
        if ((statement or after_brace) and token.kind == .identifier and at + 1 < tokens.len and (tokens[at + 1].kind == .colon or tokens[at + 1].kind == .less)) {
            if (std.mem.eql(u8, token.span.text(source), "module")) result.named = true;
        }
        after_brace = token.kind == .left_brace;
        // After a problem only `named` is still wanted.
        if (result.problem != null) {
            statement = token.kind == .newline or token.kind == .separator;
            continue;
        }
        const body: u32 = if (open_count == 0) 0 else open[open_count - 1].depth;
        if (statement and depth == body and token.kind == .identifier) {
            if (declaresModule(source, tokens, at)) |found| {
                if (open_count == open.len or result.count == out.len) {
                    result.problem = .{ .span = token.span, .code = .module_limit };
                    continue;
                }
                // The modules of one scope have distinct names.
                const parent: u32 = if (open_count == 0) types.no_parent else open[open_count - 1].index;
                const twice = for (out[0..result.count]) |earlier| {
                    if (earlier.parent == parent and std.mem.eql(u8, earlier.name.text(source), token.span.text(source))) break true;
                } else false;
                if (twice) {
                    result.problem = .{ .span = token.span, .code = .duplicate_name };
                    continue;
                }
                out[result.count] = .{
                    .name = token.span,
                    .source = .{ .start = tokens[found.brace].span.end, .end = tokens[found.brace].span.end },
                    .parent = parent,
                    .is_public = found.is_public,
                };
                depth += 1;
                open[open_count] = .{ .index = result.count, .depth = depth };
                open_count += 1;
                result.count += 1;
                at = found.brace;
                after_brace = true;
                continue;
            }
        }
        switch (token.kind) {
            .left_brace, .left_paren, .left_bracket => depth += 1,
            .right_brace, .right_paren, .right_bracket => {
                // Brackets that do not match are the parser's to report; nothing nests after them.
                if (depth == 0) {
                    if (open_count == 0) result.problem = .{ .span = token.span, .code = .unexpected_token };
                } else {
                    if (open_count != 0 and depth == open[open_count - 1].depth) {
                        if (token.kind != .right_brace) {
                            result.problem = .{ .span = token.span, .code = .unexpected_token };
                            continue;
                        }
                        open_count -= 1;
                        out[open[open_count].index].source.end = token.span.start;
                    }
                    depth -= 1;
                }
            },
            else => {},
        }
        statement = token.kind == .newline or token.kind == .separator;
    }
    if (result.problem == null and open_count != 0) result.problem = .{ .span = out[open[open_count - 1].index].name, .code = .unexpected_token };
    // A stray closer at file level is reported by the parser, as it always was; it only
    // matters here when modules were found, whose table would not be trustworthy.
    if (result.problem) |problem| if (problem.code == .unexpected_token and result.count == 0) {
        result.problem = null;
    };
    return result;
}

/// Whether the statement at `at` declares a module: `Name := module{`, or the same with
/// `<public>` or `<internal>` after the name, on one line with nothing but blanks between the
/// tokens. `validateNested` reads the same text back, so the table cannot name anything else.
fn declaresModule(source: []const u8, tokens: []const Token, at: usize) ?struct { brace: usize, is_public: bool } {
    var cursor = at + 1;
    var is_public = false;
    if (cursor + 2 < tokens.len and tokens[cursor].kind == .less) {
        if (tokens[cursor + 1].kind != .identifier or tokens[cursor + 2].kind != .greater) return null;
        const word = tokens[cursor + 1].span.text(source);
        if (std.mem.eql(u8, word, "public")) is_public = true else if (!std.mem.eql(u8, word, "internal")) return null;
        cursor += 3;
    }
    if (cursor + 3 >= tokens.len or tokens[cursor].kind != .colon or tokens[cursor + 1].kind != .equal or tokens[cursor + 2].kind != .identifier or tokens[cursor + 3].kind != .left_brace) return null;
    if (!std.mem.eql(u8, tokens[cursor + 2].span.text(source), "module")) return null;
    const header = moduleHeader(source[tokens[at].span.end..tokens[cursor + 3].span.start]) orelse return null;
    std.debug.assert(header == is_public);
    return .{ .brace = cursor + 3, .is_public = is_public };
}

/// What stands between the name of a nested module and its `{`, without blanks: null unless it
/// is the header of a module declaration, else whether the header says `<public>`.
fn moduleHeader(text: []const u8) ?bool {
    var compact: [24]u8 = undefined;
    var used: usize = 0;
    for (text) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (used == compact.len) return null;
        compact[used] = byte;
        used += 1;
    }
    if (std.mem.eql(u8, compact[0..used], ":=module") or std.mem.eql(u8, compact[0..used], "<internal>:=module")) return false;
    if (std.mem.eql(u8, compact[0..used], "<public>:=module")) return true;
    return null;
}

fn findInput(inputs: []const Input, path: []const u8) ?u32 {
    for (inputs, 0..) |input, index| if (std.mem.eql(u8, input.path, path)) return @intCast(index);
    return null;
}
/// `findInput` over inputs in the order of their paths, as `Folders.join` gives them.
/// `folder/name`, the module path of a module that a file of `folder` declares at its top
/// level. Null when it is longer than any module path, so that no folder can be it or lie
/// below it.
fn joinPath(buffer: *[types.limits.module_path_bytes]u8, folder: []const u8, name: []const u8) ?[]const u8 {
    if (folder.len + 1 + name.len > buffer.len) return null;
    @memcpy(buffer[0..folder.len], folder);
    buffer[folder.len] = '/';
    @memcpy(buffer[folder.len + 1 ..][0..name.len], name);
    return buffer[0 .. folder.len + 1 + name.len];
}

/// Whether one of the `count` paths that `context.at(i)` gives in byte order is `path` or lies
/// below it (begins with `path/`). The paths below it sort together, from `path/` on: two
/// binary searches.
fn folderAt(context: anytype, count: usize, path: []const u8) bool {
    const exact = lowerBound(context, count, path, false);
    if (exact < count and std.mem.eql(u8, context.at(exact), path)) return true;
    const below = lowerBound(context, count, path, true);
    if (below == count) return false;
    const other = context.at(below);
    return other.len > path.len and std.mem.startsWith(u8, other, path) and other[path.len] == '/';
}
/// The first of the sorted paths that is not before `path`, or `path/` when `slash`.
fn lowerBound(context: anytype, count: usize, path: []const u8, slash: bool) usize {
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const other = context.at(middle);
        const before = switch (std.mem.order(u8, other[0..@min(other.len, path.len)], path)) {
            .lt => true,
            .gt => false,
            .eq => slash and (other.len == path.len or other[path.len] < '/'),
        };
        if (before) low = middle + 1 else high = middle;
    }
    return low;
}
/// The paths of the inputs a program reaches, `reached` sorted.
const ReachedPaths = struct {
    inputs: []const Input,
    reached: []const u32,
    fn at(self: ReachedPaths, index: usize) []const u8 {
        return self.inputs[self.reached[index]].path;
    }
};
/// The paths of `Folders.join`'s inputs, which come in byte order.
const InputPaths = struct {
    inputs: []const Input,
    fn at(self: InputPaths, index: usize) []const u8 {
        return self.inputs[index].path;
    }
};

fn findSorted(inputs: []const Input, path: []const u8) ?u32 {
    var low: usize = 0;
    var high: usize = inputs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, inputs[middle].path, path)) {
            .eq => return @intCast(middle),
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return null;
}
/// The folder module that a module path begins with, the longest one: the whole path, or the
/// part before one of its `/`, down to the domain. At most one lookup per segment.
fn longestModule(inputs: []const Input, path: []const u8) ?struct { target: u32, length: u32 } {
    var end = path.len;
    while (end > 1) {
        if (findSorted(inputs, path[0..end])) |target| return .{ .target = target, .length = @intCast(end) };
        end = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return null;
    }
    return null;
}
/// The folder of a bundle path, `a/b` of `a/b/c.forb`, or null for a file at the top.
fn folderOf(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return path[0..slash];
}

/// RFC-0093: a module path, `/Domain/Name/Name`: a `/` and a domain (`lexer.isDomainContinue`
/// bytes), then names, each after a `/`, within the capacity of a path. The lexer reads the
/// same shape (`lexer.pathEnd`), so a path written in source is one of these or too long.
pub fn modulePath(path: []const u8) bool {
    if (path.len < 2 or path.len > types.limits.module_path_bytes or path[0] != '/' or !lexer.isDomainStart(path[1])) return false;
    if (lexer.pathEnd(path, 0) != path.len) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    _ = parts.next();
    while (parts.next()) |name| if (name.len > types.limits.identifier_bytes) return false;
    return true;
}

/// RFC-0093: a bundle given as a folder tree, joined into one input per folder. Its root is a
/// module path; each file belongs to the module of its folder, `a/b/c.forb` to `/a/b`, whose
/// first segment is a domain and whose others are names. A folder's files are its module's
/// text, joined by newlines in the byte order of their names, and the inputs come in the order
/// of their paths, whatever the order of the inventory. A file at the top of the tree belongs
/// to no module. The host gives the tree; nothing here looks anything up.
pub const Folders = struct {
    source: [types.limits.source_bytes]u8 = undefined,
    paths: [types.limits.module_paths_bytes]u8 = undefined,
    inputs: [types.limits.modules]Input = undefined,
    parts: [types.limits.module_files]Part = undefined,
    order: [types.limits.module_files]u32 = undefined,

    pub const Joined = union(enum) { ok: Bundle, failed: LocatedDiagnostic };

    /// The inputs and parts borrow this storage and the bundle until the next join.
    pub fn join(self: *Folders, bundle: Bundle) Joined {
        const nowhere: Input = .{ .path = bundle.root, .source = "" };
        if (!modulePath(bundle.root)) return .{ .failed = issue(nowhere, origin, .invalid_module_path) };
        if (bundle.modules.len > self.order.len) return .{ .failed = issue(nowhere, origin, .module_limit) };
        var total: usize = 0;
        for (bundle.modules, 0..) |input, index| {
            if (!canonicalPath(input.path)) return .{ .failed = issue(input, origin, .invalid_module_path) };
            if (!folderPath(folderOf(input.path) orelse "")) return .{ .failed = issue(input, origin, .invalid_module_path) };
            if (input.source.len > self.source.len - total) return .{ .failed = issue(input, origin, .source_limit) };
            total += input.source.len;
            if (!std.unicode.utf8ValidateSlice(input.source)) return .{ .failed = issue(input, origin, .invalid_utf8) };
            self.order[index] = @intCast(index);
        }
        const order = self.order[0..bundle.modules.len];
        std.sort.pdq(u32, order, bundle.modules, fileBefore);
        var used: usize = 0;
        var path_used: usize = 0;
        var count: usize = 0;
        var module_start: usize = 0;
        for (order, 0..) |entry, rank| {
            const input = bundle.modules[entry];
            const folder = folderOf(input.path).?;
            const before: ?[]const u8 = if (rank == 0) null else bundle.modules[order[rank - 1]].path;
            if (before) |earlier| if (std.mem.eql(u8, earlier, input.path)) return .{ .failed = issue(input, origin, .duplicate_module) };
            if (before == null or !std.mem.eql(u8, folderOf(before.?).?, folder)) {
                if (count == self.inputs.len) return .{ .failed = issue(input, origin, .module_limit) };
                self.paths[path_used] = '/';
                @memcpy(self.paths[path_used + 1 ..][0..folder.len], folder);
                self.inputs[count] = .{ .path = self.paths[path_used..][0 .. folder.len + 1], .source = "" };
                path_used += folder.len + 1;
                count += 1;
                module_start = used;
            } else {
                if (used == self.source.len) return .{ .failed = issue(input, origin, .source_limit) };
                self.source[used] = '\n';
                used += 1;
            }
            if (input.source.len > self.source.len - used) return .{ .failed = issue(input, origin, .source_limit) };
            self.parts[rank] = .{ .module = @intCast(count - 1), .path = input.path, .source = input.source, .start = @intCast(used - module_start) };
            @memcpy(self.source[used..][0..input.source.len], input.source);
            used += input.source.len;
            self.inputs[count - 1].source = self.source[module_start..used];
        }
        return .{ .ok = .{ .root = bundle.root, .modules = self.inputs[0..count], .parts = self.parts[0..order.len] } };
    }

    /// Whether the folder of a file names a module: `/` and the folder is a module path.
    fn folderPath(folder: []const u8) bool {
        if (folder.len == 0 or folder.len + 1 > types.limits.module_path_bytes) return false;
        var buffer: [types.limits.module_path_bytes]u8 = undefined;
        buffer[0] = '/';
        @memcpy(buffer[1..][0..folder.len], folder);
        return modulePath(buffer[0 .. folder.len + 1]);
    }

    fn fileBefore(inputs: []const Input, left: u32, right: u32) bool {
        const a = inputs[left].path;
        const b = inputs[right].path;
        const folder_a = folderOf(a).?;
        const folder_b = folderOf(b).?;
        return switch (std.mem.order(u8, folder_a, folder_b)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, a[folder_a.len + 1 ..], b[folder_b.len + 1 ..]),
        };
    }
};

/// RFC-0093: a diagnostic about a module of a folder tree as compiling one gave it, located in
/// the joined text of a module (`located.path` is the module's path), moved to the file that
/// holds it, with that file's line and column. `joined` is the bundle the compiler was given.
pub fn locateFile(joined: Bundle, located: LocatedDiagnostic) LocatedDiagnostic {
    if (joined.parts.len == 0) return located;
    const module = findSorted(joined.modules, located.path) orelse return located;
    // Only a diagnostic located in the module's text, which begins with the module's files: one
    // that no module holds is located in the whole program, under the root's path.
    if (!std.mem.startsWith(u8, located.source, joined.modules[module].source)) return located;
    const span = located.diagnostic.span;
    var first: usize = 0;
    while (first < joined.parts.len and joined.parts[first].module != module) first += 1;
    var last = first;
    while (last + 1 < joined.parts.len and joined.parts[last + 1].module == module) last += 1;
    if (first == joined.parts.len) return located;
    var chosen = first;
    while (chosen < last and joined.parts[chosen + 1].start <= span.start) chosen += 1;
    const part = joined.parts[chosen];
    // The last file holds the library block after it, as the source the compiler located with does.
    const end: usize = if (chosen == last) located.source.len else part.start + part.source.len;
    if (part.start > located.source.len or end > located.source.len) return located;
    const shift = struct {
        fn of(at: Span, from: u32, to: usize) Span {
            const s = @min(@max(at.start, from), to) - from;
            const e = @min(@max(at.end, from), to) - from;
            return .{ .start = @intCast(s), .end = @intCast(@max(s, e)) };
        }
    }.of;
    const related = located.diagnostic.related;
    const same = related.start < related.end and related.start >= part.start and related.end <= end;
    return .{ .path = part.path, .source = located.source[part.start..end], .diagnostic = .{
        .span = shift(span, part.start, end),
        .code = located.diagnostic.code,
        .related = if (same) shift(related, part.start, end) else .{ .start = 0, .end = 0 },
    } };
}

/// `locate` for any program: one whose modules are folders (RFC-0093) is located in the file
/// that holds the span, with the file's own line and column.
pub fn locateIn(program: anytype, diagnostic: types.Diagnostic, fallback_path: []const u8) LocatedDiagnostic {
    return locateParts(program.source, program.paths, program.modules, program.parts, program.file_paths, diagnostic, fallback_path);
}
pub fn locateParts(source: []const u8, paths: []const u8, modules: []const types.Module, parts: []const types.ModulePart, file_paths: []const u8, diagnostic: types.Diagnostic, fallback_path: []const u8) LocatedDiagnostic {
    if (parts.len == 0) return locate(source, paths, modules, diagnostic, fallback_path);
    var low: usize = 0;
    var high: usize = parts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (parts[middle].source.start <= diagnostic.span.start) low = middle + 1 else high = middle;
    }
    if (low == 0 or !contains(parts[low - 1].source, diagnostic.span)) return .{ .path = fallback_path, .source = source, .diagnostic = diagnostic };
    const part = parts[low - 1];
    const related: types.Span = if (diagnostic.related.start < diagnostic.related.end and contains(part.source, diagnostic.related)) .{ .start = diagnostic.related.start - part.source.start, .end = diagnostic.related.end - part.source.start } else .{ .start = 0, .end = 0 };
    return .{ .path = part.path.text(file_paths), .source = part.source.text(source), .diagnostic = .{ .span = .{ .start = diagnostic.span.start - part.source.start, .end = diagnostic.span.end - part.source.start }, .code = diagnostic.code, .related = related } };
}
fn shifted(span: Span, base: u32) Span {
    return .{ .start = span.start + base, .end = span.end + base };
}
fn fail(input: Input, span: Span, code: types.Diagnostic.Code) Result {
    return .{ .failed = issue(input, span, code) };
}
fn issue(input: Input, span: Span, code: types.Diagnostic.Code) LocatedDiagnostic {
    std.debug.assert(span.start <= span.end and span.end <= input.source.len);
    return .{ .path = input.path, .source = input.source, .diagnostic = .{ .span = span, .code = code } };
}

pub fn canonicalPath(path: []const u8) bool {
    if (!pathBytes(path) or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
fn pathBytes(path: []const u8) bool {
    if (path.len == 0 or path.len > types.limits.module_path_bytes or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == ':') return false;
    return true;
}
pub fn resolve(importer: []const u8, path: []const u8, buffer: *[types.limits.module_path_bytes]u8) ?[]const u8 {
    if (!canonicalPath(importer) or !pathBytes(path) or path[0] == '/') return null;
    var used: usize = std.mem.lastIndexOfScalar(u8, importer, '/') orelse 0;
    @memcpy(buffer[0..used], importer[0..used]);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return null;
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (used == 0) return null;
            used = std.mem.lastIndexOfScalar(u8, buffer[0..used], '/') orelse 0;
            continue;
        }
        const separator: usize = if (used == 0) 0 else 1;
        if (part.len + separator > buffer.len - used) return null;
        if (separator != 0) {
            buffer[used] = '/';
            used += 1;
        }
        @memcpy(buffer[used..][0..part.len], part);
        used += part.len;
    }
    return if (canonicalPath(buffer[0..used])) buffer[0..used] else null;
}

pub fn contains(range: Span, span: Span) bool {
    return span.start <= span.end and span.start >= range.start and span.end <= range.end;
}
/// The module whose source holds `span`. Admission asks this for every node, so it is a binary
/// search: a module table is ordered by source position and its ranges do not touch (`validate`
/// requires both, `prepare` builds them so), which leaves the last module that starts at or
/// before the span as the only one that can hold it.
pub fn owner(span: Span, modules: []const types.Module) ?u32 {
    var low: usize = 0;
    var high: usize = modules.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (modules[middle].source.start <= span.start) low = middle + 1 else high = middle;
    }
    if (low == 0 or !contains(modules[low - 1].source, span)) return null;
    return @intCast(low - 1);
}
/// The nested module whose braces hold `span`, the innermost one. The table is ordered by
/// start and its modules nest properly (`validateNested`), so the holder is the last module
/// that starts at or before the span or one of that module's ancestors: a binary search and a
/// walk bounded by `module_depth`, whatever the number of modules.
pub fn innermost(span: Span, nested: []const types.NestedModule) ?u32 {
    var low: usize = 0;
    var high: usize = nested.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (nested[middle].source.start <= span.start) low = middle + 1 else high = middle;
    }
    if (low == 0) return null;
    var candidate: u32 = @intCast(low - 1);
    for (0..types.limits.module_depth + 1) |_| {
        if (contains(nested[candidate].source, span)) return candidate;
        candidate = nested[candidate].parent;
        if (candidate == types.no_parent or candidate >= nested.len) return null;
    }
    return null;
}

/// The scope that declares what is written at `span`: a file module by its number, or nested
/// module `n` as `modules.len + n`. Two names are in one namespace exactly when their homes are equal.
pub fn home(span: Span, modules: []const types.Module, nested: []const types.NestedModule) ?u32 {
    const file = owner(span, modules) orelse return null;
    if (nested.len == 0) return file;
    const inner = innermost(span, nested) orelse return file;
    return @intCast(modules.len + inner);
}

/// The scope that declares scope `id` itself, or null for a file.
pub fn enclosing(id: u32, modules: []const types.Module, nested: []const types.NestedModule) ?u32 {
    if (id < modules.len) return null;
    const module = nested[id - modules.len];
    if (module.parent != types.no_parent) return @intCast(modules.len + module.parent);
    return owner(module.source, modules).?;
}

/// Whether scope `inner` is `outer` or lies inside it.
pub fn inside(inner: u32, outer: u32, modules: []const types.Module, nested: []const types.NestedModule) bool {
    var at = inner;
    for (0..types.limits.module_depth + 2) |_| {
        if (at == outer) return true;
        at = enclosing(at, modules, nested) orelse return false;
    }
    return false;
}

/// Whether `name` is declared in the scope whose text is `scope`, and not in a module nested in it.
pub fn within(scope: Span, name: Span, nested: []const types.NestedModule) bool {
    return contains(scope, name) and owned(scope, name, nested);
}
/// The second half of `within`, for a name already known to lie in the scope's text. Lookups
/// that scan many names ask `contains` and compare the text first, as they did before modules
/// could nest, and ask this of the one name that matches.
pub fn owned(scope: Span, name: Span, nested: []const types.NestedModule) bool {
    return nested.len == 0 or declaredBy(scope, name, nested);
}
fn declaredBy(scope: Span, name: Span, nested: []const types.NestedModule) bool {
    const inner = innermost(name, nested) orelse return true;
    // The innermost holder of the name is the scope itself or a module declared inside it.
    return nested[inner].source.start == scope.start and nested[inner].source.end == scope.end;
}

/// Admission of the nested-module table against the source and the file table, which the
/// caller has validated: the table must be exactly the modules the text declares, found by
/// the scan that preparation runs. So a table can neither invent a module (over a comment,
/// a string, an expression, or where the bundle declares its own `module`), nor drop one,
/// nor move a boundary, nor change who may name a module; order, nesting and depth, which
/// `innermost` relies on, follow. A program whose text never says `module` has none and is
/// not lexed.
pub fn validateNested(source: []const u8, modules: []const types.Module, nested: []const types.NestedModule) bool {
    return validateNestedWith(source, modules, nested, &.{});
}
/// `validateNested` for any program: the files of a module given as a folder (RFC-0093) are
/// lexed as preparation lexed them, each comment ending with its file. `parts` are admitted.
fn validateNestedWith(source: []const u8, modules: []const types.Module, nested: []const types.NestedModule, parts: []const types.ModulePart) bool {
    if (modules.len == 0) return nested.len == 0;
    if (nested.len > types.limits.modules) return false;
    if (nested.len == 0 and std.mem.indexOf(u8, source, "module") == null) return true;
    const found = storage_init.alloc(types.NestedModule, nested.len + 1) orelse return false;
    defer storage_init.free(found);
    var count: u32 = 0;
    var named = false;
    var part_at: usize = 0;
    for (modules) |file| {
        const text = file.source.text(source);
        const tokens = storage_init.alloc(Token, types.limits.tokens) orelse return false;
        defer storage_init.free(tokens);
        const first_part = part_at;
        while (part_at < parts.len and parts[part_at].source.end <= file.source.end) part_at += 1;
        const local = storage_init.alloc(types.ModulePart, part_at - first_part) orelse return false;
        defer storage_init.free(local);
        for (parts[first_part..part_at], local) |part, *out| out.* = .{ .path = part.path, .source = .{ .start = part.source.start - file.source.start, .end = part.source.end - file.source.start } };
        const lexing = if (parts.len == 0) lexer.tokenize(text, tokens) else lexer.tokenizeParts(text, tokens, local);
        const lexed = switch (lexing) {
            .failed => return false,
            .ok => |lexed| lexed,
        };
        const first = count;
        const scan = scanModules(text, lexed, found[first..]);
        named = named or scan.named;
        // More modules than the table has, or modules the compiler would have refused.
        if (scan.problem != null) {
            if (!named) return false;
            continue;
        }
        for (found[first..][0..scan.count]) |*module| {
            module.name = shifted(module.name, file.source.start);
            module.source = shifted(module.source, file.source.start);
            if (module.parent != types.no_parent) module.parent += first;
        }
        count += scan.count;
    }
    // A bundle that declares the name `module` nests nothing, whatever its text looks like.
    if (named) return nested.len == 0;
    if (count != nested.len) return false;
    for (found[0..count], nested) |want, have| if (!std.meta.eql(want, have)) return false;
    return true;
}

pub fn locate(source: []const u8, paths: []const u8, modules: []const types.Module, diagnostic: types.Diagnostic, fallback_path: []const u8) LocatedDiagnostic {
    const index = owner(diagnostic.span, modules) orelse return .{ .path = fallback_path, .source = source, .diagnostic = diagnostic };
    const module = modules[index];
    // A second place is kept when it is in the same file, where its position means something.
    const related: types.Span = if (diagnostic.related.start < diagnostic.related.end and owner(diagnostic.related, modules) == index) .{ .start = diagnostic.related.start - module.source.start, .end = diagnostic.related.end - module.source.start } else .{ .start = 0, .end = 0 };
    return .{ .path = module.path.text(paths), .source = module.source.text(source), .diagnostic = .{ .span = .{ .start = diagnostic.span.start - module.source.start, .end = diagnostic.span.end - module.source.start }, .code = diagnostic.code, .related = related } };
}

/// Readable immutable pool slices are caller preconditions. Every descriptor,
/// path, namespace partition and import target is independently admitted here.
pub fn validate(source: []const u8, paths: []const u8, modules: []const types.Module, imports: []const types.Import) bool {
    if (modules.len == 0) return paths.len == 0 and imports.len == 0;
    if (modules.len > types.limits.modules or imports.len > types.limits.imports or paths.len > types.limits.module_paths_bytes or source.len > types.limits.source_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(paths)) return false;
    var source_end: u32 = 0;
    var path_end: u32 = 0;
    var import_end: u32 = 0;
    for (modules, 0..) |module, index| {
        if (module.source.start > module.source.end or module.source.end > source.len) return false;
        if (index != 0) {
            if (source_end == source.len or source[source_end] != '\n') return false;
            source_end += 1;
        }
        if (module.source.start != source_end) return false;
        source_end = module.source.end;
        if (module.path.start != path_end or module.path.start > module.path.end or module.path.end > paths.len) return false;
        const path = module.path.text(paths);
        if (!canonicalPath(path)) return false;
        for (modules[0..index]) |earlier| if (std.mem.eql(u8, earlier.path.text(paths), path)) return false;
        path_end = module.path.end;
        if (module.imports.start != import_end or module.imports.start > module.imports.end or module.imports.end > imports.len) return false;
        for (imports[module.imports.start..module.imports.end], 0..) |edge, ordinal| {
            if (edge.target >= index or !contains(module.source, edge.alias) or !contains(module.source, edge.path)) return false;
            if (!identifier(edge.alias.text(source)) or edge.alias.end >= edge.path.start or edge.path.start == module.source.start or edge.path.end == module.source.end) return false;
            if (source[edge.path.start - 1] != '"' or source[edge.path.end] != '"') return false;
            var scratch: [types.limits.module_path_bytes]u8 = undefined;
            const resolved = resolve(path, edge.path.text(source), &scratch) orelse return false;
            if (!std.mem.eql(u8, resolved, modules[edge.target].path.text(paths))) return false;
            for (imports[module.imports.start .. module.imports.start + ordinal]) |earlier| if (std.mem.eql(u8, earlier.alias.text(source), edge.alias.text(source))) return false;
        }
        import_end = module.imports.end;
    }
    return source_end == source.len and path_end == paths.len and import_end == imports.len;
}
/// Admission of the module tables of any program: a single file or a bundle of files
/// (`validate`, `validateNested`), or a folder tree (RFC-0093), whose modules are named by
/// module paths, whose files are its parts, and whose imports name modules by path.
pub fn validateBundle(source: []const u8, paths: []const u8, modules: []const types.Module, imports: []const types.Import, nested: []const types.NestedModule, parts: []const types.ModulePart, file_paths: []const u8) bool {
    if (parts.len == 0) return file_paths.len == 0 and validate(source, paths, modules, imports) and validateNested(source, modules, nested);
    return validateFolders(source, paths, modules, imports, parts, file_paths) and validateNestedWith(source, modules, nested, parts) and validateNestedPaths(source, paths, modules, nested);
}

/// RFC-0093 rule 5, as `prepare` checks it: no folder of the tree is the module path of a
/// top-level nested module, nor lies below one (c1-1). The tables are admitted otherwise:
/// every module path is distinct and every nested module lies in a module.
fn validateNestedPaths(source: []const u8, paths: []const u8, modules: []const types.Module, nested: []const types.NestedModule) bool {
    if (nested.len == 0) return true;
    const sorted = storage_init.alloc(u32, modules.len) orelse return false;
    defer storage_init.free(sorted);
    for (sorted, 0..) |*entry, index| entry.* = @intCast(index);
    const Sorted = struct {
        paths: []const u8,
        modules: []const types.Module,
        order: []const u32,
        fn before(context: @This(), left: u32, right: u32) bool {
            return std.mem.lessThan(u8, context.modules[left].path.text(context.paths), context.modules[right].path.text(context.paths));
        }
        fn at(context: @This(), index: usize) []const u8 {
            return context.modules[context.order[index]].path.text(context.paths);
        }
    };
    const context: Sorted = .{ .paths = paths, .modules = modules, .order = sorted };
    std.sort.pdq(u32, sorted, context, Sorted.before);
    for (nested) |module| {
        if (module.parent != types.no_parent) continue;
        const folder = owner(module.name, modules) orelse return false;
        var buffer: [types.limits.module_path_bytes]u8 = undefined;
        const path = joinPath(&buffer, modules[folder].path.text(paths), module.name.text(source)) orelse continue;
        if (folderAt(context, modules.len, path)) return false;
    }
    return true;
}

/// The tables of a folder tree, every entry: modules tile the source as in `validate`, each named
/// by a distinct module path; each is made of a run of parts that tile its text with a newline
/// between each, whose paths are files of its folder in the order of their names; each import
/// stands in its module and names an earlier module by the path written there: an alias's path
/// is the whole of a module path in the text, a `using` path's is the longest module that the
/// written path begins with. A table can therefore neither move a file, nor rename a module, nor
/// make a path mean another module than preparation found.
fn validateFolders(source: []const u8, paths: []const u8, modules: []const types.Module, imports: []const types.Import, parts: []const types.ModulePart, file_paths: []const u8) bool {
    if (modules.len == 0 or modules.len > types.limits.modules or imports.len > types.limits.imports or paths.len > types.limits.module_paths_bytes or source.len > types.limits.source_bytes) return false;
    if (parts.len > types.limits.module_files or file_paths.len > types.limits.module_file_paths_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(paths) or !std.unicode.utf8ValidateSlice(file_paths)) return false;
    var source_end: u32 = 0;
    var path_end: u32 = 0;
    var import_end: u32 = 0;
    var part_at: usize = 0;
    var file_end: u32 = 0;
    for (modules, 0..) |module, index| {
        if (module.source.start > module.source.end or module.source.end > source.len) return false;
        if (index != 0) {
            if (source_end == source.len or source[source_end] != '\n') return false;
            source_end += 1;
        }
        if (module.source.start != source_end) return false;
        source_end = module.source.end;
        if (module.path.start != path_end or module.path.start > module.path.end or module.path.end > paths.len) return false;
        const path = module.path.text(paths);
        if (!modulePath(path)) return false;
        path_end = module.path.end;
        if (module.imports.start != import_end or module.imports.start > module.imports.end or module.imports.end > imports.len) return false;
        import_end = module.imports.end;
        const first = part_at;
        var expected = module.source.start;
        while (true) {
            if (part_at == parts.len) return false;
            const part = parts[part_at];
            if (part.source.start != expected or part.source.start > part.source.end or part.source.end > module.source.end) return false;
            if (part.path.start != file_end or part.path.start > part.path.end or part.path.end > file_paths.len) return false;
            file_end = part.path.end;
            const file = part.path.text(file_paths);
            if (!canonicalPath(file)) return false;
            const folder = folderOf(file) orelse return false;
            if (!std.mem.eql(u8, folder, path[1..])) return false;
            if (part_at != first and !std.mem.lessThan(u8, parts[part_at - 1].path.text(file_paths), file)) return false;
            part_at += 1;
            if (part.source.end == module.source.end) break;
            if (source[part.source.end] != '\n') return false;
            expected = part.source.end + 1;
        }
    }
    if (source_end != source.len or path_end != paths.len or import_end != imports.len or part_at != parts.len or file_end != file_paths.len) return false;
    // Module paths are distinct, which the order of them by path shows, and is looked up in.
    const sorted = storage_init.alloc(u32, modules.len) orelse return false;
    defer storage_init.free(sorted);
    for (sorted, 0..) |*entry, index| entry.* = @intCast(index);
    const Order = struct {
        paths: []const u8,
        modules: []const types.Module,
        fn before(context: @This(), left: u32, right: u32) bool {
            return std.mem.lessThan(u8, context.modules[left].path.text(context.paths), context.modules[right].path.text(context.paths));
        }
    };
    const order: Order = .{ .paths = paths, .modules = modules };
    std.sort.pdq(u32, sorted, order, Order.before);
    for (sorted[1..], sorted[0 .. sorted.len - 1]) |later, earlier| if (!Order.before(order, earlier, later)) return false;
    for (modules, 0..) |module, index| {
        const edges = imports[module.imports.start..module.imports.end];
        for (edges, 0..) |edge, ordinal| {
            if (edge.target >= index or !contains(module.source, edge.alias) or !contains(module.source, edge.path)) return false;
            if (edge.path.start + 1 >= module.source.end or source[edge.path.start] != '/' or !lexer.isDomainStart(source[edge.path.start + 1])) return false;
            // The path starts a path of the text and ends where a segment does.
            if (edge.path.start != module.source.start) {
                const before = source[edge.path.start - 1];
                if (lexer.isDomainContinue(before) or before == '/') return false;
            }
            const written = lexer.pathEnd(source[0..module.source.end], edge.path.start);
            if (edge.path.end > written or (edge.path.end != written and source[edge.path.end] != '/')) return false;
            if (!std.mem.eql(u8, edge.path.text(source), modules[edge.target].path.text(paths))) return false;
            if (edge.alias.start == edge.alias.end) {
                if (edge.alias.start != edge.path.start) return false;
            } else {
                if (!identifier(edge.alias.text(source)) or edge.alias.end >= edge.path.start or edge.path.end != written) return false;
                for (edges[0..ordinal]) |earlier| if (earlier.alias.start != earlier.alias.end and std.mem.eql(u8, earlier.alias.text(source), edge.alias.text(source))) return false;
            }
            // No longer module is a beginning of what is written.
            var end = edge.path.end;
            while (end < written) {
                end += 1;
                while (end < written and source[end] != '/') end += 1;
                if (sortedModule(sorted, paths, modules, source[edge.path.start..end])) return false;
            }
        }
    }
    return true;
}
fn sortedModule(sorted: []const u32, paths: []const u8, modules: []const types.Module, path: []const u8) bool {
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, modules[sorted[middle]].path.text(paths), path)) {
            .eq => return true,
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return false;
}

fn identifier(name: []const u8) bool {
    if (name.len == 0 or name.len > types.limits.identifier_bytes or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

test "virtual paths normalize relative imports without escaping or aliasing inventory names" {
    var scratch: [types.limits.module_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("shared/theme.forb", resolve("app/main.forb", "../shared/./theme.forb", &scratch).?);
    try std.testing.expectEqualStrings("app/theme.forb", resolve("app/main.forb", "theme.forb", &scratch).?);
    for ([_][]const u8{ "", "/a", "x//y", "C:/x", "x\\y", "../../x" }) |path| try std.testing.expect(resolve("app/main.forb", path, &scratch) == null);
    for ([_][]const u8{ "", "./x", "x/../y", "/x", "x//y", "C:x", "x\\y", "x\x00y" }) |path| try std.testing.expect(!canonicalPath(path));
}

test "the owner of a span is the one module that contains it, at every boundary" {
    // Sources "ab", "", "cde" and "" joined by newlines; an empty module still owns its position.
    const table = [_]types.Module{
        .{ .path = .{ .start = 0, .end = 1 }, .source = .{ .start = 0, .end = 2 }, .imports = .{ .start = 0, .end = 0 } },
        .{ .path = .{ .start = 1, .end = 2 }, .source = .{ .start = 3, .end = 3 }, .imports = .{ .start = 0, .end = 0 } },
        .{ .path = .{ .start = 2, .end = 3 }, .source = .{ .start = 4, .end = 7 }, .imports = .{ .start = 0, .end = 0 } },
        .{ .path = .{ .start = 3, .end = 4 }, .source = .{ .start = 8, .end = 8 }, .imports = .{ .start = 0, .end = 0 } },
    };
    try std.testing.expect(validate("ab\n\ncde\n", "abcd", &table, &.{}));
    for (0..table.len + 1) |count| {
        var start: u32 = 0;
        while (start <= 10) : (start += 1) {
            var end: u32 = 0;
            while (end <= 10) : (end += 1) {
                const span: Span = .{ .start = start, .end = end };
                var expected: ?u32 = null;
                for (table[0..count], 0..) |module, index| if (expected == null and contains(module.source, span)) {
                    expected = @intCast(index);
                };
                try std.testing.expectEqual(expected, owner(span, table[0..count]));
            }
        }
    }
}

test "diamond discovery is inventory-independent and retains exact source partitions" {
    const inputs = [_]Input{
        .{ .path = "main.forb", .source = "Left:=import{\"left.forb\"}\nRight:=import{\"right.forb\"}\nRoot:i64=1" },
        .{ .path = "right.forb", .source = "Base:=import{\"base.forb\"}\nRight:i64=2" },
        .{ .path = "base.forb", .source = "Value<public>:i64=3" },
        .{ .path = "left.forb", .source = "Base:=import{\"base.forb\"}\nLeft:i64=4" },
    };
    const storage = try storage_init.storage(Storage);
    defer storage_init.release(storage);
    storage_init.initialise(storage);
    const tokens = try std.testing.allocator.alloc(Token, types.limits.tokens);
    defer std.testing.allocator.free(tokens);
    const prepared = (storage.prepare(.{ .root = "main.forb", .modules = &inputs }, tokens)).ok;
    for ([_][]const u8{ "base.forb", "left.forb", "right.forb", "main.forb" }, prepared.modules) |expected, module| try std.testing.expectEqualStrings(expected, module.path.text(prepared.paths));
    try std.testing.expectEqual(@as(usize, 4), prepared.imports.len);
    var bad = prepared.modules[3];
    bad.imports.end -= 1;
    const saved = storage.modules[3];
    storage.modules[3] = bad;
    try std.testing.expect(!validate(prepared.source, prepared.paths, prepared.modules, prepared.imports));
    storage.modules[3] = saved;
    const reversed = [_]Input{ inputs[3], inputs[2], inputs[1], inputs[0] };
    const original = try std.testing.allocator.dupe(u8, prepared.source);
    defer std.testing.allocator.free(original);
    const other = (storage.prepare(.{ .root = "main.forb", .modules = &reversed }, tokens)).ok;
    try std.testing.expectEqualStrings(original, other.source);
}

test "nested modules are found by statement, hold every position between their braces and stop at the depth" {
    const storage = try storage_init.storage(Storage);
    defer storage_init.release(storage);
    storage_init.initialise(storage);
    const tokens = try std.testing.allocator.alloc(Token, types.limits.tokens);
    defer std.testing.allocator.free(tokens);
    const inputs = [_]Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA:=module{X:i64=1\nB<public> := module {Y:i64=Block{C:=module{};2}}\n}; D<internal>:=module{}\nE:i64=3" },
        .{ .path = "lib.forb", .source = "F<public>:=module{\n}" },
    };
    const prepared = storage.prepare(.{ .root = "main.forb", .modules = &inputs }, tokens).ok;
    // `C` stands inside an expression: it is no module. The imported file comes first.
    const expected = [_]struct { name: []const u8, parent: u32, public: bool, body: []const u8 }{
        .{ .name = "F", .parent = types.no_parent, .public = true, .body = "\n" },
        .{ .name = "A", .parent = types.no_parent, .public = false, .body = "X:i64=1\nB<public> := module {Y:i64=Block{C:=module{};2}}\n" },
        .{ .name = "B", .parent = 1, .public = true, .body = "Y:i64=Block{C:=module{};2}" },
        .{ .name = "D", .parent = types.no_parent, .public = false, .body = "" },
    };
    try std.testing.expectEqual(expected.len, prepared.nested.len);
    for (expected, prepared.nested) |want, have| {
        try std.testing.expectEqualStrings(want.name, have.name.text(prepared.source));
        try std.testing.expectEqualStrings(want.body, have.source.text(prepared.source));
        try std.testing.expectEqual(want.parent, have.parent);
        try std.testing.expectEqual(want.public, have.is_public);
    }
    try std.testing.expect(validateNested(prepared.source, prepared.modules, prepared.nested));
    // The holder of every span is the innermost module whose braces contain it; the scope of
    // a name is that module, or else its file.
    var start: u32 = 0;
    while (start <= prepared.source.len) : (start += 1) {
        var end = start;
        while (end <= @min(prepared.source.len, start + 3)) : (end += 1) {
            const span: Span = .{ .start = start, .end = end };
            var holder: ?u32 = null;
            for (prepared.nested, 0..) |module, index| if (contains(module.source, span)) {
                holder = @intCast(index);
            };
            try std.testing.expectEqual(holder, innermost(span, prepared.nested));
            const file = owner(span, prepared.modules);
            const scope: ?u32 = if (file == null) null else if (holder) |inner| @intCast(prepared.modules.len + inner) else file;
            try std.testing.expectEqual(scope, home(span, prepared.modules, prepared.nested));
            for (prepared.nested) |module| try std.testing.expectEqual(holder != null and std.meta.eql(prepared.nested[holder.?].source, module.source), within(module.source, span, prepared.nested));
        }
    }
    try std.testing.expect(inside(4, 3, prepared.modules, prepared.nested) and inside(4, 1, prepared.modules, prepared.nested) and !inside(3, 4, prepared.modules, prepared.nested));
    try std.testing.expectEqual(@as(?u32, 3), enclosing(4, prepared.modules, prepared.nested));
    try std.testing.expectEqual(@as(?u32, 0), enclosing(2, prepared.modules, prepared.nested));
    try std.testing.expectEqual(@as(?u32, null), enclosing(1, prepared.modules, prepared.nested));
    // A chain exactly as deep as the capacity is admitted; one level more is not, though it
    // is as well formed. The scan refuses to build the deeper one.
    var text: [16 * (types.limits.module_depth + 2)]u8 = undefined;
    var table: [types.limits.module_depth + 1]types.NestedModule = undefined;
    for ([_]usize{ types.limits.module_depth, types.limits.module_depth + 1 }) |depth| {
        var used: u32 = 0;
        for (0..depth) |level| {
            const header = "M:=module{";
            @memcpy(text[used..][0..header.len], header);
            table[level] = .{ .name = .{ .start = used, .end = used + 1 }, .source = .{ .start = used + @as(u32, header.len), .end = 0 }, .parent = if (level == 0) types.no_parent else @intCast(level - 1), .is_public = false };
            used += @as(u32, header.len);
        }
        for (0..depth) |level| {
            table[depth - 1 - level].source.end = used;
            text[used] = '}';
            used += 1;
        }
        const file = [_]types.Module{.{ .path = .{ .start = 0, .end = 1 }, .source = .{ .start = 0, .end = used }, .imports = .{ .start = 0, .end = 0 } }};
        try std.testing.expect(validate(text[0..used], "m", &file, &.{}));
        try std.testing.expectEqual(depth == types.limits.module_depth, validateNested(text[0..used], &file, table[0..depth]));
        const deep = [_]Input{.{ .path = "m", .source = text[0..used] }};
        const result = storage.prepare(.{ .root = "m", .modules = &deep }, tokens);
        if (depth == types.limits.module_depth) {
            try std.testing.expectEqualSlices(types.NestedModule, table[0..depth], result.ok.nested);
        } else try std.testing.expectEqual(types.Diagnostic.Code.module_limit, result.failed.diagnostic.code);
    }
    // No table without files, and no entry beyond the capacity.
    try std.testing.expect(!validateNested("M:=module{}", &.{}, table[0..1]));
}

test "interpolation dense bundle validates nested modules" {
    const input = "M:=module{\n  Y<public>:i64=2\n}\nX:=1\nS<public>:string=\"{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}{X}\"\n";
    const file = [_]types.Module{.{ .path = .{ .start = 0, .end = 1 }, .source = .{ .start = 0, .end = input.len }, .imports = .{ .start = 0, .end = 0 } }};
    const tokens = try std.testing.allocator.alloc(Token, types.limits.tokens);
    defer std.testing.allocator.free(tokens);
    const lexed = (lexer.tokenize(input, tokens)).ok;
    var table: [types.limits.modules]types.NestedModule = undefined;
    const result = scanModules(input, lexed, &table);
    try std.testing.expect(validateNested(input, &file, table[0..result.count]));
}
