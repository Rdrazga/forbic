//! Automatic qualification (RFC-0085, I11; the Book's 16:789): the fully qualified form of every
//! identifier a program writes, computed from what the compiler resolved it to.
//!
//! When the host asks for it (`Workspace.qualify`), the compiler notes, for each identifier the
//! program's author wrote, the definition it resolved to: where that definition's name is written
//! and of which kind it is (`Resolution`). A declaration is noted too, as resolving to itself, with
//! the type it is a member of. From that table alone this file prints the source with every noted
//! identifier in its qualified form (`write`), and checks that each printed form resolves again to
//! the definition it was computed from (`verify`), which is what makes the forms trustworthy: a
//! qualified form is not unique to one definition, every local being `(local:)Name`, but read
//! under the scope rules where it is printed it names one.
//!
//! - A definition of a file or of a module nested in one is `(/Path:)Name`: `Path` is the file's
//!   path in its bundle without `.forb`, then `/Module` for each nested module around it; a
//!   program compiled without a bundle has the empty path, `(/:)Name`.
//! - A field, method or enumerator is `(/Path/type:)Name`, after the type that declares it.
//! - A parameter or a local is `(local:)Name`.
//! - A built-in type or a standard definition is `(/Verse.org/Verse:)Name`.
//!
//! Nothing here changes a compile: a compile without the flag notes nothing, and the program, its
//! IR and every output are the same with it.
const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const modules = @import("modules.zig");
const functions = @import("functions.zig");
const stdlib = @import("stdlib.zig");
const catalogue = @import("aggregate_types.zig");

pub const none: u32 = std.math.maxInt(u32);

pub const Kind = enum(u8) {
    /// A parameter or a local of the code it is written in.
    local,
    /// A definition of a file or of a module nested in one: a value, a function, a type, an
    /// alias, a native, an import or a module.
    global,
    /// A field, a method or an enumerator of the type `owner` names.
    member,
    /// A built-in type or a standard definition: it has no declaration in the program.
    builtin,
    /// A name in the body of a generic function or a parametric type that means another
    /// definition in each specialization: it has no one form, and is printed as written.
    varies,
};

/// The identifier whose first byte is at `at` resolves to the definition whose name starts at
/// `declared` (`none` for a built-in). A declaration is the entry whose `at` is its `declared`;
/// for a member, `owner` is where the name of the type that declares it starts.
pub const Resolution = struct {
    at: u32,
    declared: u32 = none,
    owner: u32 = none,
    /// For the declaration of a local whose scope is not all of the code after it (the
    /// parameters of an `Fn`, whose captures are named in its body only): where the scope
    /// begins, and where it ends.
    begin: u32 = none,
    end: u32 = none,
    kind: Kind,

    fn before(_: void, a: Resolution, b: Resolution) bool {
        return a.at < b.at;
    }
};

/// What `write` and `verify` read: the compiled text and its module tables, the parts of it the
/// program's author wrote, and the table, ordered by position with one entry per position.
pub const Text = struct {
    source: []const u8,
    paths: []const u8 = "",
    modules: []const types.Module = &.{},
    nested: []const types.NestedModule = &.{},
    /// One part for a single file; one per file of a bundle, in source order. Library blocks
    /// that macros append are not among them: what the author did not write is not printed.
    written: []const types.Span,
    entries: []const Resolution,

    /// The entry at `at`, if there is one.
    pub fn find(self: Text, at: u32) ?Resolution {
        const index = self.firstFrom(at);
        if (index == self.entries.len or self.entries[index].at != at) return null;
        return self.entries[index];
    }
    fn firstFrom(self: Text, at: u32) usize {
        return std.sort.lowerBound(Resolution, self.entries, at, struct {
            fn order(key: u32, item: Resolution) std.math.Order {
                return std.math.order(key, item.at);
            }
        }.order);
    }
    /// The identifier whose first byte is at `at`.
    pub fn name(self: Text, at: u32) []const u8 {
        var end = at;
        while (end < self.source.len and identifierByte(self.source[end])) end += 1;
        return self.source[at..end];
    }
};

/// Orders a table that the compiler wrote in the order it read the program.
pub fn sort(entries: []Resolution) void {
    std.sort.pdq(Resolution, entries, {}, Resolution.before);
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Whether the identifier at `at` is the word of a qualifier the author wrote, `(word:)`: the
/// form printed for the name after it stands in its place.
fn qualifierWord(text: Text, at: u32) bool {
    const end = at + @as(u32, @intCast(text.name(at).len));
    var start = at;
    while (start > 0 and std.mem.indexOfScalar(u8, " \t\r", text.source[start - 1]) != null) start -= 1;
    return start > 0 and text.source[start - 1] == '(' and end + 1 < text.source.len and text.source[end] == ':' and text.source[end + 1] == ')';
}

/// Where a qualifier the author wrote right before the identifier at `at` begins, `(word:)Name`.
fn qualifierBefore(text: Text, at: u32, lower: u32) ?u32 {
    if (at < lower + 3 or text.source[at - 1] != ')' or text.source[at - 2] != ':') return null;
    var start = at - 2;
    while (start > lower and identifierByte(text.source[start - 1])) start -= 1;
    if (start == at - 2) return null;
    while (start > lower and std.mem.indexOfScalar(u8, " \t\r", text.source[start - 1]) != null) start -= 1;
    if (start == lower or text.source[start - 1] != '(') return null;
    return start - 1;
}

/// The path of the scope that declares what is written at `position`: the file's path in its
/// bundle without `.forb`, then each nested module around it, then `member` if one is given.
fn writePath(text: Text, position: u32, member: ?[]const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    const at: types.Span = .{ .start = position, .end = position };
    var segments: u32 = 0;
    if (text.modules.len != 0) if (modules.owner(at, text.modules)) |file| {
        const path = text.modules[file].path.text(text.paths);
        const stem = if (std.mem.endsWith(u8, path, ".forb")) path[0 .. path.len - ".forb".len] else path;
        // A module of a folder tree is named by its module path already (RFC-0093).
        if (stem.len != 0 and stem[0] == '/') try out.writeAll(stem) else try out.print("/{s}", .{stem});
        segments += 1;
    };
    if (text.nested.len != 0) if (modules.innermost(at, text.nested)) |inner| {
        // Outermost first: the chain is at most `module_depth` long.
        var chain: [types.limits.module_depth + 1]u32 = undefined;
        var length: usize = 0;
        var walk = inner;
        while (walk != types.no_parent and length < chain.len) : (walk = text.nested[walk].parent) {
            chain[length] = walk;
            length += 1;
        }
        while (length != 0) {
            length -= 1;
            try out.print("/{s}", .{text.nested[chain[length]].name.text(text.source)});
            segments += 1;
        }
    };
    if (member) |owner| {
        try out.print("/{s}", .{owner});
    } else if (segments == 0) try out.writeByte('/');
}

/// Writes the qualifier of `entry`, `(...:)`. Returns false, writing nothing, for a member whose
/// type the table does not know.
pub fn writeForm(text: Text, entry: Resolution, out: *std.Io.Writer) std.Io.Writer.Error!bool {
    switch (entry.kind) {
        .varies => return false,
        .local => try out.writeAll("(local:)"),
        .builtin => try out.writeAll("(/Verse.org/Verse:)"),
        .global => {
            try out.writeByte('(');
            try writePath(text, entry.declared, null, out);
            try out.writeAll(":)");
        },
        .member => {
            const declaration = text.find(entry.declared) orelse return false;
            if (declaration.owner == none) return false;
            try out.writeByte('(');
            try writePath(text, declaration.owner, text.name(declaration.owner), out);
            try out.writeAll(":)");
        },
    }
    return true;
}

/// Prints the parts the author wrote with every noted identifier in its qualified form, in the
/// layout it was written in (the Book's example 16:880). A qualifier the author wrote is replaced
/// by the form of the name it qualifies. A bundle's files each begin with a line `# path`.
pub fn write(text: Text, out: *std.Io.Writer) (std.Io.Writer.Error || error{AmbiguousPath})!void {
    // Two scopes of one path would give two definitions one form.
    if (ambiguousPath(text) != null) return error.AmbiguousPath;
    for (text.written) |part| {
        if (text.modules.len != 0) if (modules.owner(part, text.modules)) |file| {
            try out.print("# {s}\n", .{text.modules[file].path.text(text.paths)});
        };
        var cursor = part.start;
        var index = text.firstFrom(part.start);
        while (index < text.entries.len and text.entries[index].at < part.end) : (index += 1) {
            const entry = text.entries[index];
            if (entry.at < cursor or qualifierWord(text, entry.at)) continue;
            const start = qualifierBefore(text, entry.at, cursor) orelse entry.at;
            try out.writeAll(text.source[cursor..start]);
            // Without a form the author's own qualifier stays.
            if (!try writeForm(text, entry, out)) try out.writeAll(text.source[start..entry.at]);
            cursor = entry.at;
        }
        try out.writeAll(text.source[cursor..part.end]);
        if (text.modules.len != 0 and (part.end == part.start or text.source[part.end - 1] != '\n')) try out.writeByte('\n');
    }
}

pub const Problem = struct {
    at: u32,
    reason: []const u8,
};

/// What `verify` checks the table against, besides the text: the compiled program, whose IR
/// and catalogue say which member and which function each access and call reaches, the
/// compile's functions, whose parameter types tell overloads apart, the members the catalogue
/// does not hold (methods, interface fields, fields with accessors), each by where its name is
/// written and where the name of the type that declares it is, and the names
/// `(/Verse.org/Verse:)` qualifies.
pub const Facts = struct {
    program: types.Program,
    functions: []const functions.Definition,
    members: []const [2]u32 = &.{},
    builtin: *const fn ([]const u8) bool = standardName,
};

/// The resolution property of RFC-0085 Part 4: each noted identifier, read again under the scope
/// rules at its place in its printed form, resolves to the definition it was noted with.
///
/// - `(local:)Name`: the local of that name in scope there, which is the nearest declaration of
///   a local of that name before it whose scope has not ended, since a local can be named only
///   after its declaration and no declaration hides another (RFC-0076, no shadowing); the one
///   exception, an `Fn`'s capture `[A:t = A]`, has the `Fn`'s body for its scope. So a local is
///   not declared where another of its name is in reach, but for such a capture.
/// - A path form: the declarations of that name that have that form, exactly one; overloads
///   share their form and are told apart by their parameter types.
/// - `(/Verse.org/Verse:)Name`: a name the language or its standard library defines, which
///   `builtin` answers, that neither the file nor a local in reach declares, and that is not
///   written after a dot (the members of built-in types have no form).
///
/// Every entry must also agree with its declaration's entry: same kind, same name, and for a
/// member the type the catalogue says declares it. And every access to a field or an
/// enumerator, and every call of a named function, that the IR holds at a noted identifier must
/// reach the definition the table names there. No path is the path of two scopes. Returns the
/// first identifier for which the property fails.
pub fn verify(text: Text, facts: Facts) ?Problem {
    var first_buffer: [512]u8 = undefined;
    var second_buffer: [512]u8 = undefined;
    if (ambiguousPath(text)) |at| return .{ .at = at, .reason = "two scopes have this path" };
    for (text.entries, 0..) |entry, index| {
        if (!inside(text.written, entry.at)) return .{ .at = entry.at, .reason = "noted outside the text the author wrote" };
        const name = text.name(entry.at);
        if (name.len == 0) return .{ .at = entry.at, .reason = "noted where no identifier is written" };
        if (index != 0 and text.entries[index - 1].at == entry.at) return .{ .at = entry.at, .reason = "noted twice" };
        if (entry.kind == .varies) {
            if (entry.declared != none) return .{ .at = entry.at, .reason = "a name of many meanings noted with one" };
            continue;
        }
        if (entry.kind == .builtin) {
            if (!facts.builtin(name)) return .{ .at = entry.at, .reason = "not a built-in name" };
            if (entry.at != 0 and text.source[entry.at - 1] == '.') return .{ .at = entry.at, .reason = "a member printed as a built-in" };
            if (localInDefinition(text, index, name)) return .{ .at = entry.at, .reason = "a built-in form for a name a local in reach has" };
            // A standard name yields to every declaration of it the file makes, but for an
            // extension method, which is named after a receiver only.
            for (text.entries) |other| if (other.kind == .global and other.declared == other.at and std.mem.eql(u8, text.name(other.at), name) and sameFile(text, other.at, entry.at)) {
                if (functionAt(facts.functions, other.at)) |function| if (function.is_extension) continue;
                return .{ .at = entry.at, .reason = "a built-in form for a name the program declares" };
            };
            continue;
        }
        const declaration = text.find(entry.declared) orelse return .{ .at = entry.at, .reason = "its declaration is not noted" };
        if (declaration.declared != declaration.at) return .{ .at = entry.at, .reason = "its declaration is a use" };
        if (declaration.kind != entry.kind) return .{ .at = entry.at, .reason = "of another kind than its declaration" };
        if (!std.mem.eql(u8, text.name(declaration.at), name)) return .{ .at = entry.at, .reason = "named otherwise than its declaration" };
        if (entry.kind == .member and declaration.owner == none) return .{ .at = entry.at, .reason = "a member without its type" };
        if (entry.kind == .member and entry.at == entry.declared) if (declaringType(facts, entry.at)) |owner| {
            if (owner != entry.owner) return .{ .at = entry.at, .reason = "a member of another type than the one that declares it" };
        };
        if (entry.kind == .local) {
            if (entry.at == entry.declared) {
                // A local is declared where its name is followed by its type, `:=`, `->`, the
                // rest of a destructured tuple or the end of a pattern, never where it is read.
                if (!declarationSite(text, entry.at + @as(u32, @intCast(name.len)))) return .{ .at = entry.at, .reason = "a local declared where its name is read" };
                // Nor where another local of its name is in reach: no declaration hides one.
                if (entry.begin == none) if (inReach(text, index, entry.at, name, entry.at)) |_| return .{ .at = entry.at, .reason = "a local declared where one of its name is in reach" };
                continue;
            }
            const nearest = inReach(text, index, entry.at, name, null);
            if (nearest == null) return .{ .at = entry.at, .reason = "(local:) names another local here" };
            // RFC-0085, I4: overloads of a nested function share their name and their block, and
            // the arguments of a call, or the expected type of a value, choose one of them.
            if (nearest.?.at != declaration.at and !nestedOverload(text, facts, nearest.?, declaration, name)) return .{ .at = entry.at, .reason = "(local:) names another local here" };
            continue;
        }
        var form: std.Io.Writer = .fixed(&first_buffer);
        if (!(writeForm(text, entry, &form) catch return .{ .at = entry.at, .reason = "form too long" })) return .{ .at = entry.at, .reason = "no form" };
        const signature = functionAt(facts.functions, declaration.at);
        var found: u32 = 0;
        for (text.entries) |candidate| {
            if (candidate.declared != candidate.at or candidate.kind != entry.kind) continue;
            if (!std.mem.eql(u8, text.name(candidate.at), name)) continue;
            var other: std.Io.Writer = .fixed(&second_buffer);
            if (!(writeForm(text, candidate, &other) catch return .{ .at = candidate.at, .reason = "form too long" })) continue;
            if (!std.mem.eql(u8, form.buffered(), other.buffered())) continue;
            // Overloads share their form: the parameter types pick one.
            if (candidate.at != declaration.at and signature != null) {
                const theirs = functionAt(facts.functions, candidate.at) orelse continue;
                if (!sameParameters(signature.?, theirs)) continue;
            }
            found += 1;
        }
        if (found != 1) return .{ .at = entry.at, .reason = "its form names several definitions" };
    }
    // What the program does at a noted identifier is what the table names there.
    if (crossCheck(types.Node, text, facts, facts.program.nodes)) |problem| return problem;
    for (facts.program.functions) |function| {
        if (function.body.start > function.body.end or function.body.end > facts.program.function_nodes.len) continue;
        if (crossCheck(types.FunctionNode, text, facts, facts.program.function_nodes[function.body.start..function.body.end])) |problem| return problem;
    }
    return null;
}

/// The nearest declaration of a local named `name` before entry `index` (at `at`) whose scope
/// reaches `at`, other than the one at `except`. A scope without a known end reaches every
/// later position for a use; for a declaration, only scopes that end are asked, so that
/// locals of the same name in two functions, whose ends are not all known, are not taken for
/// one inside the other.
fn inReach(text: Text, index: usize, at: u32, name: []const u8, except: ?u32) ?Resolution {
    var back = index + 1;
    while (back != 0) {
        back -= 1;
        const candidate = text.entries[back];
        if (candidate.kind != .local or candidate.declared != candidate.at) continue;
        if (except != null and candidate.at == except.?) continue;
        if (!std.mem.eql(u8, text.name(candidate.at), name)) continue;
        if (except != null and candidate.end == none) continue;
        const reaches = candidate.at == at or ((candidate.begin == none or at >= candidate.begin) and (candidate.end == none or at < candidate.end));
        if (reaches) return candidate;
    }
    return null;
}

/// RFC-0085, I4: whether the local declared at `declaration` is an overload of `nearest`, the
/// nested function a `(local:)` use finds: both are nested functions, the declaration is the
/// earlier, and every local of their name declared between them is a nested function too (the
/// overloads of one block, since no other declaration of the name may stand there).
fn nestedOverload(text: Text, facts: Facts, nearest: Resolution, declaration: Resolution, name: []const u8) bool {
    if (declaration.kind != .local or declaration.at >= nearest.at) return false;
    if (!nestedAt(facts, nearest.at) or !nestedAt(facts, declaration.at)) return false;
    for (text.entries) |candidate| {
        if (candidate.kind != .local or candidate.declared != candidate.at) continue;
        if (candidate.at <= declaration.at or candidate.at >= nearest.at) continue;
        if (!std.mem.eql(u8, text.name(candidate.at), name)) continue;
        if (!nestedAt(facts, candidate.at)) return false;
    }
    return true;
}

/// Whether a nested function (RFC-0085, I3) of the program is declared at `at`.
fn nestedAt(facts: Facts, at: u32) bool {
    for (facts.program.functions) |function| if (function.nested and function.name.start == at) return true;
    return false;
}

fn declarationSite(text: Text, after: u32) bool {
    var at = after;
    // A comment between the name and what follows it is white space (RFC-0089).
    while (at < text.source.len) {
        if (text.source[at] == ' ' or text.source[at] == '\t') {
            at += 1;
        } else if (lexer.commentOpens(text.source, at)) {
            at = @intCast(lexer.commentEnd(text.source, at));
        } else break;
    }
    if (at == text.source.len) return false;
    return switch (text.source[at]) {
        // A type, `:=`, the rest of a destructured tuple, the end of a pattern.
        ':', ',', ')', '}' => true,
        // The parameters of a nested function (RFC-0085, I3), whose effects follow them at once:
        // a call is no declaration.
        '(' => signatureAt(text, at),
        // `I->X` of a `For`, `Name =>` of a pattern.
        '-', '=' => at + 1 < text.source.len and text.source[at + 1] == '>',
        else => false,
    };
}

/// Whether the parenthesis at `open` closes right before a `<`, as the parameters of a
/// signature do before its effects.
fn signatureAt(text: Text, open: u32) bool {
    var depth: u32 = 0;
    var at = open;
    while (at < text.source.len) : (at += 1) switch (text.source[at]) {
        // The loop's step moves from the last byte of a comment to the byte after it.
        '#', '<' => if (lexer.commentOpens(text.source, at)) {
            at = @intCast(lexer.commentEnd(text.source, at) - 1);
        },
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return at + 1 < text.source.len and text.source[at + 1] == '<';
        },
        else => {},
    };
    return false;
}

/// Whether a local named `name` is declared before entry `index` in the same definition of a
/// file or module: back to the nearest such definition that begins a line.
fn localInDefinition(text: Text, index: usize, name: []const u8) bool {
    var back = index;
    while (back != 0) {
        back -= 1;
        const candidate = text.entries[back];
        if (candidate.declared != candidate.at) continue;
        if (candidate.kind == .global and lineStart(text, candidate.at)) return false;
        if (candidate.kind == .local and std.mem.eql(u8, text.name(candidate.at), name)) return true;
    }
    return false;
}

fn lineStart(text: Text, at: u32) bool {
    var before = at;
    while (before != 0 and (text.source[before - 1] == ' ' or text.source[before - 1] == '\t')) before -= 1;
    return before == 0 or text.source[before - 1] == '\n';
}

fn sameFile(text: Text, a: u32, b: u32) bool {
    if (text.modules.len == 0) return true;
    const first = modules.owner(.{ .start = a, .end = a }, text.modules) orelse return false;
    const second = modules.owner(.{ .start = b, .end = b }, text.modules) orelse return false;
    return first == second;
}

/// Where the name of the type that declares the member whose name is written at `at` is
/// written, by the catalogue, the methods and slots of the program and its fields with
/// accessors; null for a member they do not show (a generic method).
fn declaringType(facts: Facts, at: u32) ?u32 {
    const program = facts.program;
    for (facts.members) |pair| if (pair[0] == at) return pair[1];
    for (program.definitions) |definition| {
        const own: types.Span = switch (definition) {
            .record => |record| record.fields,
            .class => |class| .{ .start = class.fields.start + class.inherited, .end = class.fields.end },
            .enumeration => |enumeration| {
                if (enumeration.cases.end > program.cases.len) continue;
                for (program.cases[enumeration.cases.start..enumeration.cases.end]) |case| if (case.start == at) return enumeration.name.start;
                continue;
            },
            else => continue,
        };
        if (own.start > own.end or own.end > program.fields.len) continue;
        for (program.fields[own.start..own.end]) |field| if (field.name.start == at) return (catalogue.declaredName(definition) orelse continue).start;
    }
    return null;
}

fn nodeOf(comptime N: type, item: N) types.Node {
    return if (N == types.Node) item else item.node;
}

/// The field reads, enumerators and calls of named functions among `nodes` (one body, whose
/// operands index it), against the entries at the identifiers they are written at.
fn crossCheck(comptime N: type, text: Text, facts: Facts, nodes: []const N) ?Problem {
    const program = facts.program;
    for (nodes, 0..) |item, index| {
        const node = nodeOf(N, item);
        const span = node.span;
        if (span.start >= span.end or span.end > text.source.len) continue;
        const reached: struct { at: u32, declared: u32, kind: Kind } = switch (node.kind) {
            .field, .object_get => |access| blk: {
                if (access.value >= index) continue;
                const receiver = nodeOf(N, nodes[access.value]).value_type;
                const field = (if (node.kind == .field) catalogue.fieldAt(receiver, access.index, program.definitions, program.fields) else catalogue.classFieldAt(receiver, access.index, program.definitions, program.fields)) orelse continue;
                break :blk .{ .at = span.start, .declared = field.name.start, .kind = .member };
            },
            .enumeration => |case| blk: {
                const definition = catalogue.definition(node.value_type, program.definitions) orelse continue;
                if (definition != .enumeration or definition.enumeration.cases.start + case >= program.cases.len) continue;
                const written = program.cases[definition.enumeration.cases.start + case];
                const length = written.end - written.start;
                if (length == 0 or length > span.end - span.start) continue;
                break :blk .{ .at = span.end - length, .declared = written.start, .kind = .member };
            },
            .call => |call| blk: {
                if (call.function >= program.functions.len) continue;
                const function = program.functions[call.function];
                if (function.anonymous or function.name.end <= function.name.start or function.name.end > text.source.len) continue;
                const length = function.name.end - function.name.start;
                if (length > span.end - span.start) continue;
                break :blk .{ .at = span.end - length, .declared = function.name.start, .kind = .global };
            },
            else => continue,
        };
        const entry = text.find(reached.at) orelse continue;
        if (entry.kind != reached.kind or !std.mem.eql(u8, text.name(reached.at), text.name(reached.declared))) continue;
        if (entry.declared != reached.declared) return .{ .at = reached.at, .reason = "names another definition than the program reaches" };
    }
    return null;
}

/// A position of the first of two scopes whose qualified paths are the same (a module `b` nested
/// in the file `a.forb` and the file `a/b.forb`), if there are two.
fn ambiguousPath(text: Text) ?u32 {
    if (text.modules.len == 0) return null;
    const count = text.modules.len + text.nested.len;
    for (0..count) |first| for (first + 1..count) |second| {
        if (samePath(text, first, second)) return scopeAt(text, first);
    };
    return null;
}

fn scopeAt(text: Text, scope: usize) u32 {
    return if (scope < text.modules.len) text.modules[scope].source.start else text.nested[scope - text.modules.len].name.start;
}

fn samePath(text: Text, a: usize, b: usize) bool {
    var first_buffer: [types.limits.module_path_bytes + 64 * (types.limits.module_depth + 1)]u8 = undefined;
    var second_buffer: [types.limits.module_path_bytes + 64 * (types.limits.module_depth + 1)]u8 = undefined;
    var first: std.Io.Writer = .fixed(&first_buffer);
    var second: std.Io.Writer = .fixed(&second_buffer);
    writeScope(text, a, &first) catch return false;
    writeScope(text, b, &second) catch return false;
    return std.mem.eql(u8, first.buffered(), second.buffered());
}

/// The path of scope `scope` (a file by its number, or a nested module after the files).
fn writeScope(text: Text, scope: usize, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (scope < text.modules.len) {
        const path = text.modules[scope].path.text(text.paths);
        const stem = if (std.mem.endsWith(u8, path, ".forb")) path[0 .. path.len - ".forb".len] else path;
        if (stem.len != 0 and stem[0] == '/') return out.writeAll(stem);
        return out.print("/{s}", .{stem});
    }
    const module = text.nested[scope - text.modules.len];
    // A nested module's path is that of its scope followed by its name.
    try writePath(text, module.name.start, module.name.text(text.source), out);
}

/// Whether two scopes of the program print the same path, which `write` refuses to print.
pub fn ambiguous(text: Text) bool {
    return ambiguousPath(text) != null;
}

/// The names a program reaches without declaring them, which `(/Verse.org/Verse:)` qualifies:
/// the built-in types and type constructors, the conversions and the standard functions.
pub fn standardName(name: []const u8) bool {
    if (std.meta.stringToEnum(types.Type, name) != null) return true;
    if (stdlib.function(name) != null) return true;
    for ([_][]const u8{
        "char",    "char32",    "accessor",   "rational",     "cancelable",         "reader",              "writer",                     "void",  "any",      stdlib.pi_name,
        "BitAnd",  "BitOr",     "BitXor",     "BitNot",       "array",              "tuple",               "option",                     "map",   "function", "task",
        "event",   "awaitable", "signalable", "sticky_event", "subscribable_event", "weak_map",            "Floor",                      "Ceil",  "Round",    "Int",
        "ToFloat", "ToString",  "Quotient",   "Mod",          "Rational",           "MakeRationalFromInt",
        // RFC-0092, B4.
        "GetCastableFinalSuperClass",
        // RFC-0091 (B3): the bottom type, where a type is written.
        "false",
    }) |word| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

fn inside(parts: []const types.Span, at: u32) bool {
    for (parts) |part| if (at >= part.start and at < part.end) return true;
    return false;
}

/// The function whose name is written at `at`, if one is.
fn functionAt(definitions: []const functions.Definition, at: u32) ?*const functions.Definition {
    for (definitions) |*definition| if (definition.name.start == at and definition.name.end > definition.name.start) return definition;
    return null;
}

/// Whether two functions take the same parameter types.
fn sameParameters(a: *const functions.Definition, b: *const functions.Definition) bool {
    if (a.parameter_count != b.parameter_count) return false;
    for (a.parameters[0..a.parameter_count], b.parameters[0..b.parameter_count]) |x, y| if (x.value_type != y.value_type) return false;
    return true;
}
