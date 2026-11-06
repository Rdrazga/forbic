//! TASK-0109, W4.4: the embedding API of Forbic (RFC-0088 A2 and A5, M1 criterion 4).
//!
//! A Zig application embeds Forbic through this file alone: it registers its natives, compiles a
//! program from a string, a file, a module bundle or a folder tree, prepares it once (both
//! machines admit it, each on its own), and runs it many times, on as many workers as it has
//! threads, each run with its own grants, seed, clock, fuel and trace mode. Results, printed
//! lines, reports and failures come back as values. A run that must survive the process (a state
//! directory, persistent keys, a journal that a crash resumes or abandons) is a durable run.
//! `docs/embedding.md` is the guide; every capacity here is a profile's or the host's.
//!
//! This file, like the host services it builds on, reaches nothing of ForbOS: it is the root of
//! the package's `forbic_embed` module, whose only imports are the package's `forbic` and
//! `forbic_host` modules (`forbic/build.zig`, `forbic_embed_boundary.zig`).
const std = @import("std");
const builtin = @import("builtin");
/// The language itself, for what this file does not wrap: types, diagnostics, reports.
pub const forbic = @import("forbic");
const forbic_host = @import("forbic_host").command;
const journal = @import("forbic_host").journal;
const input = @import("forbic_host").input;
const host_project = @import("forbic_host").project;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

/// What a native is written with: `native.entry`, `native.effectEntry`, `native.Context`,
/// `native.Error`, `native.Array`, `native.ArrayOut`, `native.Cost` (RFC-0042).
pub const native = forbic.native;
/// How a diagnostic is written: the header alone (`plain`, the default) or with its source.
pub const Style = forbic.excerpt.Style;
/// What a run keeps of its steps: all of them (`full`), their count and digest (`digest`), or
/// nothing (`off`). A `digest` run's reports are checked by replaying it.
pub const TraceMode = forbic.types.TraceMode;
/// A diagnostic's code: the closed set of everything the compiler, the machines and the host
/// can refuse.
pub const Code = forbic.types.Diagnostic.Code;
/// The seed of a run whose host chooses none.
pub const default_seed = forbic.effects.default_seed;
/// The ticks per second of a run's virtual clock when the host chooses none (1 to 1,000,000).
pub const default_tick_rate = forbic.types.Scheduler.default_tick_rate;
/// The fuel of a run when the host chooses none: the profile's evaluation work.
pub const default_fuel: u64 = forbic.types.limits.evaluation_work;
/// The most grants one run takes: the profile's.
pub const grant_capacity = forbic.effects.grant_capacity;

// ---------------------------------------------------------------------------------------------
// Natives

/// The most natives one table holds: a call names its native with 16 bits.
pub const max_natives = std.math.maxInt(u16) + 1;
/// The standard natives (`std.*`), which every table starts with.
pub const standard_natives = forbic.native_std.table.len;

/// A table of natives: the standard ones, then the host's, in the order registered. Its storage
/// is the host's, given to `init`, so its capacity is the host's choice. A program compiled
/// against it borrows it until the program is prepared, which copies it; registering more later
/// changes no program already compiled.
pub const Natives = struct {
    storage: []forbic.native.Entry,
    count: usize,

    pub const InitError = error{
        /// The storage cannot hold the standard natives.
        StorageTooSmall,
        /// The storage holds more than a call can name (`max_natives`).
        StorageTooLarge,
    };
    pub const RegisterError = error{
        /// The storage is full.
        TooManyNatives,
        /// The table already has a native of that name.
        DuplicateNative,
        /// The entry is not one a program may call: its name is not 1 to `identifier_bytes`
        /// bytes of UTF-8, its signature or effect is not one the machines admit
        /// (`native.wellFormed`), or it already carries a host context.
        InvalidNative,
    };

    pub fn init(storage: []forbic.native.Entry) InitError!Natives {
        if (storage.len < standard_natives) return error.StorageTooSmall;
        if (storage.len > max_natives) return error.StorageTooLarge;
        @memcpy(storage[0..standard_natives], &forbic.native_std.table);
        return .{ .storage = storage, .count = standard_natives };
    }

    /// Adds a native that needs nothing of the host: a function of its arguments.
    pub fn register(self: *Natives, entry: forbic.native.Entry) RegisterError!void {
        if (entry.host != null) return error.InvalidNative;
        return self.add(entry);
    }

    /// Adds a native that reads `host` through `Context.hostContext(Host)`. The host keeps `host`
    /// alive while any program compiled with this table can run, and unchanged while a run, or
    /// the report of one, can call the native: both machines and the report replay call it, and
    /// must be given one function.
    pub fn registerWith(self: *Natives, comptime Host: type, host: *const Host, entry: forbic.native.Entry) RegisterError!void {
        if (entry.host != null) return error.InvalidNative;
        var given = entry;
        given.host = .{ .pointer = host, .type_name = @typeName(Host) };
        return self.add(given);
    }

    fn add(self: *Natives, entry: forbic.native.Entry) RegisterError!void {
        std.debug.assert(self.count >= standard_natives and self.count <= self.storage.len);
        if (entry.id.len == 0 or entry.id.len > forbic.types.limits.identifier_bytes or !std.unicode.utf8ValidateSlice(entry.id)) return error.InvalidNative;
        if (!forbic.native.wellFormed(entry)) return error.InvalidNative;
        for (self.table()) |held| if (std.mem.eql(u8, held.id, entry.id)) return error.DuplicateNative;
        if (self.count == self.storage.len) return error.TooManyNatives;
        self.storage[self.count] = entry;
        self.count += 1;
    }

    pub fn table(self: *const Natives) []const forbic.native.Entry {
        return self.storage[0..self.count];
    }
};

// ---------------------------------------------------------------------------------------------
// Sources and diagnostics

/// One file of a bundle: its path in the bundle and its text.
pub const File = forbic.modules.Input;

/// Where a program comes from. A bundle names its root module; a bundle whose root is a module
/// path (`/acme@example.com/Orders`) is a folder tree (RFC-0093): each folder's files are one
/// module. The host's bytes are borrowed until the compile returns: the compiler copies what it
/// keeps.
pub const Source = union(enum) {
    /// Source text the host holds; `name` names it in diagnostics.
    text: Named,
    /// A source file, read with `io`; its path names it.
    file: Path,
    /// A module bundle packet (`forbic eval FILE --bundle`), as bytes the host holds.
    packet: Named,
    /// A module bundle packet in a file.
    packet_file: Path,
    /// The files of a bundle, or of a folder tree, as the host holds them.
    files: Files,
    /// TASK-0109, W4.6: a project directory (`DIR/forbic.json` naming the root module, the tree in
    /// `DIR/src/`), read as `forbic run DIR` reads it into the packet of its folder tree (RFC-0095).
    /// A diagnostic's `path` is the file's path in the tree, under `DIR/src/`.
    project: Path,
};
pub const Named = struct { name: []const u8, bytes: []const u8 };
pub const Path = struct { io: std.Io, path: [:0]const u8 };
pub const Files = struct { root: []const u8, files: []const File };

/// A diagnostic where it points: the file (or module) and its text, which it borrows from what
/// it was reported against (a compiler until its next compile, or a program until destroyed).
pub const Diagnostic = struct {
    path: []const u8,
    source: []const u8,
    diagnostic: forbic.types.Diagnostic,

    pub fn code(self: Diagnostic) Code {
        return self.diagnostic.code;
    }
    pub fn message(self: Diagnostic) []const u8 {
        return self.diagnostic.message();
    }
    /// The 1-based line and byte column the diagnostic points at.
    pub fn location(self: Diagnostic) struct { line: u32, column: u32 } {
        const at = self.diagnostic.location(self.source);
        return .{ .line = at.line, .column = at.column };
    }
    /// The text the `forbic` tool writes for it: `PATH:LINE:COLUMN: error: MESSAGE`, then in
    /// `excerpt` style the lines it points at. For a project the tool writes `DIR/src/` before
    /// `PATH`, the file's path in the tree; this writes `PATH` alone (RFC-0095, decision 8).
    pub fn write(self: Diagnostic, out: *std.Io.Writer, style: Style) std.Io.Writer.Error!void {
        return forbic_host.writeDiagnostic(out, self.path, self.source, self.diagnostic, style);
    }

    fn located(program: forbic.types.Program, diagnostic: forbic.types.Diagnostic, fallback: []const u8) Diagnostic {
        const at = forbic.modules.locateIn(program, diagnostic, fallback);
        return .{ .path = at.path, .source = at.source, .diagnostic = at.diagnostic };
    }
};

/// Why a source did not compile.
pub const Failure = union(enum) {
    /// The source could not be read: the file system's error, by name.
    unreadable: Reason,
    /// The bundle packet is not one (`InvalidBundle`), or it or a bundle of files holds more
    /// than the profile allows (`BundleLimit`).
    invalid_bundle: Reason,
    /// The program is refused, at a place in its source.
    diagnostic: Diagnostic,
    /// TASK-0109, W4.6: the project directory is refused before anything is compiled: no
    /// manifest, a link, a bound passed (`refusal.reason`, and the path refused).
    project: ProjectRefusal,

    pub const Reason = struct { name: []const u8, reason: []const u8 };
    pub const ProjectRefusal = struct { name: []const u8, refusal: *const host_project.Refusal };

    /// The diagnostic's code; null for a source that was never compiled.
    pub fn code(self: Failure) ?Code {
        return switch (self) {
            .diagnostic => |diagnostic| diagnostic.code(),
            .unreadable, .invalid_bundle, .project => null,
        };
    }
    /// The text the `forbic` tool writes for the same failure, but for a project's diagnostic,
    /// which names its file by its path in the tree (`Diagnostic.write`).
    pub fn write(self: Failure, out: *std.Io.Writer, style: Style) std.Io.Writer.Error!void {
        switch (self) {
            .unreadable => |problem| try out.print("{s}: error: cannot read source ({s})\n", .{ problem.name, problem.reason }),
            .invalid_bundle => |problem| try out.print("{s}: error: invalid bounded module bundle ({s})\n", .{ problem.name, problem.reason }),
            .project => |problem| try problem.refusal.write(out, problem.name),
            .diagnostic => |diagnostic| try diagnostic.write(out, style),
        }
    }
};

// ---------------------------------------------------------------------------------------------
// Identity (RFC-0088, A2)

/// A program's identity: a domain-separated, length-delimited SHA-256 over everything that
/// decides what its compilation and admission are: the exact root and the ordered module paths
/// and bytes (or the name and text of a single source), the compiler options, the toolchain
/// build, the schemas of the IR and the bytecode, the native table's names and signatures, and
/// every capacity of the profile. It hashes canonical fields, never pointers or raw structs.
/// Two compilations with one identity compile to the same program; the host's native functions
/// and contexts are compared as well before a cache gives a program out (`Cache`).
pub const Identity = struct {
    digest: [32]u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, &a.digest, &b.digest);
    }
    pub fn hex(self: Identity) [64]u8 {
        return std.fmt.bytesToHex(self.digest, .lower);
    }
};

const identity_domain = "forbic program identity 1";

const Hasher = struct {
    sha: Sha256 = .init(.{}),

    /// Every field is its length, then its bytes: no two sequences of fields hash alike.
    fn bytes(self: *Hasher, text: []const u8) void {
        self.number(text.len);
        self.sha.update(text);
    }
    fn number(self: *Hasher, value: u64) void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .little);
        self.sha.update(&encoded);
    }
    /// A named section, so that a section can never be read as the end of the one before.
    fn section(self: *Hasher, name: []const u8) void {
        self.bytes(name);
    }
    /// The shape of a type that holds programs: its name, size, alignment and fields, and the
    /// names of a union's cases. A change of representation changes the identity.
    fn shape(self: *Hasher, comptime T: type) void {
        @setEvalBranchQuota(1_000_000);
        self.bytes(@typeName(T));
        self.number(@sizeOf(T));
        self.number(@alignOf(T));
        switch (@typeInfo(T)) {
            .@"struct" => |s| inline for (s.field_names, s.field_types) |name, field| {
                self.bytes(name);
                self.bytes(@typeName(field));
            },
            .@"union" => |u| inline for (u.field_names, u.field_types) |name, field| {
                self.bytes(name);
                self.bytes(@typeName(field));
            },
            .@"enum" => |e| inline for (e.field_names) |name| self.bytes(name),
            else => {},
        }
    }
    /// A value of a pointer-free type, field by field and by name.
    fn canonical(self: *Hasher, comptime T: type, value: T) void {
        @setEvalBranchQuota(100_000);
        switch (@typeInfo(T)) {
            .@"struct" => |s| if (s.layout == .@"packed") {
                self.number(@as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(value)));
            } else inline for (s.field_names) |name| {
                self.bytes(name);
                self.canonical(@FieldType(T, name), @field(value, name));
            },
            .@"enum" => self.bytes(@tagName(value)),
            .bool => self.number(@intFromBool(value)),
            .int => self.number(@intCast(value)),
            else => @compileError("no canonical form of " ++ @typeName(T)),
        }
    }
    fn native(self: *Hasher, entry: forbic.native.Entry) void {
        // Every field of an entry is hashed or named here: a new field does not compile until
        // it is decided whether it is part of what the program means.
        const fields = @typeInfo(forbic.native.Entry).@"struct".field_names;
        inline for (fields) |name| {
            if (comptime std.mem.eql(u8, name, "id")) {
                self.bytes(entry.id);
            } else if (comptime std.mem.eql(u8, name, "params")) {
                self.number(entry.params.len);
                for (entry.params) |param| self.canonical(forbic.native.Shape, param);
            } else if (comptime std.mem.eql(u8, name, "call")) {
                // The host's code: compared by `Cache`, never hashed.
            } else if (comptime std.mem.eql(u8, name, "host")) {
                // Whether it has a host context, and of what type; the pointer is compared.
                self.bytes(if (entry.host) |host| host.type_name else "");
            } else {
                self.bytes(name);
                self.canonical(@FieldType(forbic.native.Entry, name), @field(entry, name));
            }
        }
    }
    fn final(self: *Hasher) Identity {
        var identity: Identity = undefined;
        self.sha.final(&identity.digest);
        return identity;
    }
};

/// What a source is once it is loaded: the bytes of a single source, or a bundle's modules.
const Loaded = struct {
    name: []const u8,
    form: union(enum) { single: []const u8, bundle: forbic.modules.Bundle },
    /// The bytes a durable run is given again: the source, or the packet it came from (none for
    /// files, which `prepare` writes as a packet).
    bytes: []const u8,
};

fn identityOf(loaded: Loaded, natives: []const forbic.native.Entry) Identity {
    var hasher: Hasher = .{};
    hasher.section(identity_domain);
    hasher.section("toolchain");
    hasher.bytes(journal.toolchain);
    hasher.bytes(builtin.zig_version_string);
    hasher.bytes(@tagName(builtin.mode));
    hasher.bytes(@tagName(builtin.cpu.arch));
    hasher.bytes(@tagName(builtin.os.tag));
    hasher.bytes(@tagName(builtin.cpu.arch.endian()));
    hasher.section("schema");
    hasher.shape(forbic.types.Program);
    hasher.shape(forbic.types.Node);
    hasher.shape(@FieldType(forbic.types.Node, "kind"));
    hasher.shape(forbic.vm.Instruction);
    hasher.shape(forbic.types.Value);
    hasher.shape(forbic.types.Binding);
    hasher.shape(forbic.types.Definition);
    hasher.shape(forbic.native.Entry);
    hasher.shape(forbic.native.Shape);
    hasher.section("profile");
    inline for (@typeInfo(forbic.profile.Profile).@"struct".field_names) |name| {
        hasher.bytes(name);
        const value = @field(forbic.profile.active, name);
        if (@TypeOf(value) == []const u8) hasher.bytes(value) else hasher.number(value);
    }
    // The compiler and the lowering take no option an embedding host can choose today; the
    // section is there so that one that is added changes every identity.
    hasher.section("options");
    hasher.bytes("lowering=default");
    hasher.section("natives");
    hasher.number(natives.len);
    for (natives) |entry| hasher.native(entry);
    hasher.section("source");
    switch (loaded.form) {
        .single => |text| {
            hasher.bytes("single");
            hasher.bytes(loaded.name);
            hasher.bytes(text);
        },
        .bundle => |bundle| {
            hasher.bytes("bundle");
            hasher.bytes(bundle.root);
            hasher.number(bundle.modules.len);
            for (bundle.modules) |module| {
                hasher.bytes(module.path);
                hasher.bytes(module.source);
            }
        },
    }
    return hasher.final();
}

// ---------------------------------------------------------------------------------------------
// Compiling

pub const CompileOptions = struct {
    /// The natives the program may bind (`Name := native{"id"}`); the standard ones when null.
    natives: ?*const Natives = null,
};

/// A compiler: one thread's storage for compiling, as large as the profile's capacities and
/// touched only as far as a program uses it. What one use lends (a `Compilation`, a `Failure`)
/// borrows it until its next use: the next `compile`, `identify` or `Cache.obtain` with it, which
/// reads into the same buffers, whether or not it succeeds.
pub const Compiler = struct {
    gpa: Allocator,
    workspace: *forbic.Workspace,
    packet: ?*forbic.bundle_packet.Workspace = null,
    /// TASK-0109, W4.6: a project's walk, made when first needed.
    project: ?*host_project.Storage = null,
    /// Read buffers for a source file and for a packet file, made when first needed.
    source_buffer: ?[]u8 = null,
    packet_buffer: ?[]u8 = null,
    /// Counts uses: a `Compilation` of an earlier one is refused by `prepare`.
    generation: u64 = 0,
    /// The copies of what the last use kept of the host's source (its name, and the bytes of a
    /// `text`, `packet` or `files` source, within the profile's bounds), lent with what that use
    /// lent: the host's bytes are borrowed only until the use returns.
    kept: []u8 = &.{},
    kept_files: []File = &.{},

    pub fn create(gpa: Allocator) error{OutOfMemory}!*Compiler {
        const self = try gpa.create(Compiler);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .workspace = try forbic.scratch.storage(forbic.Workspace) };
        forbic.scratch.initialise(self.workspace);
        return self;
    }

    pub fn destroy(self: *Compiler) void {
        forbic.scratch.release(self.workspace);
        if (self.packet) |packet| forbic.scratch.release(packet);
        if (self.project) |storage| forbic.scratch.release(storage);
        if (self.source_buffer) |buffer| forbic.scratch.free(buffer);
        if (self.packet_buffer) |buffer| forbic.scratch.free(buffer);
        self.forget();
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    /// Compiles `source`. The result borrows this compiler until its next use or `destroy`; the
    /// host's bytes are borrowed until `compile` returns (the compiler keeps copies of them).
    pub fn compile(self: *Compiler, source: Source, options: CompileOptions) error{OutOfMemory}!Compiled {
        const natives = if (options.natives) |table| table.table() else &forbic.native_std.table;
        const loaded = switch (try self.load(source)) {
            .ok => |loaded| loaded,
            .failed => |failure| return .{ .failed = failure },
        };
        return self.compileLoaded(loaded, natives, identityOf(loaded, natives));
    }

    /// The identity `source` would compile to with `options`, without compiling it: what a host
    /// keys its own store of programs by. A failure is a source that cannot be read or parsed, or
    /// that is larger than the profile allows. A use of the compiler: it ends what the compiler
    /// lent before.
    pub fn identify(self: *Compiler, source: Source, options: CompileOptions) error{OutOfMemory}!Identified {
        const natives = if (options.natives) |table| table.table() else &forbic.native_std.table;
        return switch (try self.load(source)) {
            .ok => |loaded| .{ .ok = identityOf(loaded, natives) },
            .failed => |failure| .{ .failed = failure },
        };
    }

    const Load = union(enum) { ok: Loaded, failed: Failure };

    /// Reads and parses `source` once: its identity and its compile are of the same bytes. What
    /// the result holds of the host's source is the compiler's copy, made only within the
    /// profile's bounds: a larger source is refused as compiling it would be, before more is copied.
    fn load(self: *Compiler, source: Source) error{OutOfMemory}!Load {
        self.generation += 1;
        self.forget();
        const limits = forbic.types.limits;
        switch (source) {
            .text => |named| {
                // The lexer refuses a longer source with this diagnostic, at its start: what it
                // points into is the part of the source the profile holds.
                const held = named.bytes[0..@min(named.bytes.len, limits.source_bytes)];
                const kept = try self.keep(&.{ named.name, held });
                const name = kept[0..named.name.len];
                const text = kept[named.name.len..];
                if (held.len != named.bytes.len) return .{ .failed = .{ .diagnostic = .{ .path = name, .source = text, .diagnostic = .{ .span = .{ .start = 0, .end = 0 }, .code = .source_limit } } } };
                return .{ .ok = .{ .name = name, .form = .{ .single = text }, .bytes = text } };
            },
            .file => |path| {
                const maximum = limits.source_bytes;
                const buffer = try readBuffer(&self.source_buffer, maximum + 1);
                const name = try self.keep(&.{path.path});
                const bytes = input.read(path.io, path.path, buffer, maximum) catch |problem| return .{ .failed = .{ .unreadable = .{ .name = name, .reason = @errorName(problem) } } };
                return .{ .ok = .{ .name = name, .form = .{ .single = bytes }, .bytes = bytes } };
            },
            .packet => |named| {
                // `parse` refuses a longer packet first.
                if (named.bytes.len > forbic.bundle_packet.max_packet_bytes) {
                    const name = try self.keep(&.{named.name});
                    return .{ .failed = .{ .invalid_bundle = .{ .name = name, .reason = @errorName(error.BundleLimit) } } };
                }
                const kept = try self.keep(&.{ named.name, named.bytes });
                return self.parsed(kept[0..named.name.len], kept[named.name.len..]);
            },
            .packet_file => |path| {
                const maximum = forbic.bundle_packet.max_packet_bytes;
                const buffer = try readBuffer(&self.packet_buffer, maximum + 1);
                const name = try self.keep(&.{path.path});
                const bytes = input.read(path.io, path.path, buffer, maximum) catch |problem| return .{ .failed = .{ .unreadable = .{ .name = name, .reason = @errorName(problem) } } };
                return self.parsed(name, bytes);
            },
            .files => |files| return self.keepFiles(files),
            // The packet of the project's tree: what a durable run is given again, and what the
            // journal of `forbic run DIR` records. The packet is the compiler's own storage; the
            // name is kept like every other source's (TASK-0109 W4.6, s6-1).
            .project => |path| {
                const storage = self.project orelse made: {
                    const storage = try forbic.scratch.storage(host_project.Storage);
                    forbic.scratch.initialise(storage);
                    self.project = storage;
                    break :made storage;
                };
                const name = try self.keep(&.{path.path});
                return switch (storage.load(path.io, path.path)) {
                    .refused => |refusal| .{ .failed = .{ .project = .{ .name = name, .refusal = refusal } } },
                    .ok => |read| self.parsed(name, read.packet),
                };
            },
        }
    }

    /// The most files a bundle can have, and the most bytes of their paths and its root: a
    /// bundle of files or a folder tree holds at most `modules` or `module_files` files, and its
    /// root and every path are at most `module_path_bytes` long.
    const kept_files_limit = @max(forbic.types.limits.modules, forbic.types.limits.module_files);
    const kept_paths_limit = (kept_files_limit + 1) * forbic.types.limits.module_path_bytes;

    /// A bundle of files, copied when it is within what any bundle that compiles holds (the files
    /// and path bytes above, and at most `source_bytes` of sources); a larger one is refused as
    /// a packet of it is (`BundleLimit`), and only its root is copied, to name it.
    fn keepFiles(self: *Compiler, files: Files) error{OutOfMemory}!Load {
        const limits = forbic.types.limits;
        var path_bytes: usize = files.root.len;
        var source_bytes: usize = 0;
        const within = files.files.len <= kept_files_limit and for (files.files) |file| {
            path_bytes += file.path.len;
            source_bytes += file.source.len;
            if (path_bytes > kept_paths_limit or source_bytes > limits.source_bytes) break false;
        } else path_bytes <= kept_paths_limit;
        if (!within) {
            const name = try self.keep(&.{files.root});
            return .{ .failed = .{ .invalid_bundle = .{ .name = name, .reason = @errorName(error.BundleLimit) } } };
        }
        std.debug.assert(self.kept.len == 0 and self.kept_files.len == 0);
        const bytes = try self.gpa.alloc(u8, path_bytes + source_bytes);
        errdefer self.gpa.free(bytes);
        const list = try self.gpa.alloc(File, files.files.len);
        self.kept = bytes;
        self.kept_files = list;
        var at: usize = 0;
        const root = append(bytes, &at, files.root);
        for (files.files, list) |file, *made| {
            const path = append(bytes, &at, file.path);
            made.* = .{ .path = path, .source = append(bytes, &at, file.source) };
        }
        std.debug.assert(at == bytes.len);
        return .{ .ok = .{ .name = root, .form = .{ .bundle = .{ .root = root, .modules = list } }, .bytes = "" } };
    }

    /// Copies `pieces`, one after another, into the compiler's keeping until its next use.
    fn keep(self: *Compiler, pieces: []const []const u8) error{OutOfMemory}![]const u8 {
        std.debug.assert(self.kept.len == 0 and self.kept_files.len == 0);
        var total: usize = 0;
        for (pieces) |piece| total += piece.len;
        const bytes = try self.gpa.alloc(u8, total);
        var at: usize = 0;
        for (pieces) |piece| _ = append(bytes, &at, piece);
        std.debug.assert(at == bytes.len);
        self.kept = bytes;
        return bytes;
    }

    fn append(into: []u8, at: *usize, piece: []const u8) []const u8 {
        const made = into[at.*..][0..piece.len];
        @memcpy(made, piece);
        at.* += piece.len;
        return made;
    }

    /// Frees the copies the last use kept: nothing it lent is used after.
    fn forget(self: *Compiler) void {
        self.gpa.free(self.kept_files);
        self.gpa.free(self.kept);
        self.kept = &.{};
        self.kept_files = &.{};
    }

    fn parsed(self: *Compiler, name: []const u8, bytes: []const u8) error{OutOfMemory}!Load {
        const packet = self.packet orelse made: {
            const storage = try forbic.scratch.storage(forbic.bundle_packet.Workspace);
            forbic.scratch.initialise(storage);
            self.packet = storage;
            break :made storage;
        };
        const bundle = packet.parse(bytes) catch |problem| return .{ .failed = .{ .invalid_bundle = .{ .name = name, .reason = @errorName(problem) } } };
        return .{ .ok = .{ .name = name, .form = .{ .bundle = bundle }, .bytes = bytes } };
    }

    fn readBuffer(slot: *?[]u8, size: usize) error{OutOfMemory}![]u8 {
        if (slot.*) |held| return held;
        const made = forbic.scratch.alloc(u8, size) orelse return error.OutOfMemory;
        slot.* = made;
        return made;
    }

    fn compileLoaded(self: *Compiler, loaded: Loaded, natives: []const forbic.native.Entry, identity: Identity) Compiled {
        self.workspace.natives = natives;
        const program = switch (loaded.form) {
            .single => |text| switch (self.workspace.compile(text)) {
                .ok => |program| program,
                .failed => |diagnostic| return .{ .failed = .{ .diagnostic = .{ .path = loaded.name, .source = text, .diagnostic = diagnostic } } },
            },
            .bundle => |bundle| switch (self.workspace.compileBundle(bundle)) {
                .ok => |program| program,
                .failed => |problem| return .{ .failed = .{ .diagnostic = .{ .path = problem.path, .source = problem.source, .diagnostic = problem.diagnostic } } },
            },
        };
        return .{ .ok = .{ .compiler = self, .generation = self.generation, .program = program, .loaded = loaded, .identity = identity } };
    }
};

pub const Compiled = union(enum) { ok: Compilation, failed: Failure };
pub const Identified = union(enum) { ok: Identity, failed: Failure };

/// A compiled program, not yet admitted: it borrows its compiler until the compiler's next use.
pub const Compilation = struct {
    compiler: *const Compiler,
    generation: u64,
    /// The IR, for inspection; a host runs a program through `prepare`.
    program: forbic.types.Program,
    loaded: Loaded,
    identity: Identity,

    pub fn name(self: Compilation) []const u8 {
        return self.loaded.name;
    }
    /// Whether the compiler has not been used since (no compile, identify or obtain): only then
    /// is the program its own.
    pub fn current(self: Compilation) bool {
        return self.compiler.generation == self.generation;
    }
};

// ---------------------------------------------------------------------------------------------
// Prepared programs

pub const PrepareError = error{
    OutOfMemory,
    /// The compiler has compiled another program since: this one is no longer there.
    StaleCompilation,
};

/// Which admission refused a program, and why: a compiled program that a machine refuses is a
/// defect of the toolchain, or of a native table, never of the program's author.
pub const Refusal = struct { by: forbic.prepared.Admission, diagnostic: Diagnostic };
pub const Preparation = union(enum) { ok: *Program, refused: Refusal };

/// A prepared program: compiled, then admitted by the reference evaluator and by the VM, each on
/// its own (RFC-0088, A1 and A3). It owns everything it holds and is immutable, so any number of
/// threads may run it at once, each on its own `Worker`. Made by `prepare` (freed by `destroy`)
/// or lent by a `Cache` (given back with `Cache.release`).
pub const Program = opaque {
    const Held = struct {
        gpa: Allocator,
        handle: *forbic.prepared.Prepared,
        identity: Identity,
        /// The name, the bytes a durable run compiles again, and whether they are a packet.
        name: [:0]const u8,
        bytes: []const u8,
        bundled: bool,
        /// `name` and `bytes`, in one allocation.
        block: []u8,
    };
    fn held(self: *const Program) *const Held {
        return @ptrCast(@alignCast(self));
    }

    pub fn identity(self: *const Program) Identity {
        return held(self).identity;
    }
    pub fn name(self: *const Program) []const u8 {
        return held(self).name;
    }
    /// The frozen IR, for inspection.
    pub fn ir(self: *const Program) forbic.types.Program {
        return held(self).handle.program();
    }
    /// Everything the program holds: the admitted IR and bytecode, the native table, its name and
    /// the source a durable run compiles again. What a `Cache` counts against its byte ceiling.
    pub fn bytes(self: *const Program) usize {
        const program = held(self);
        return program.handle.bytes() + program.block.len + @sizeOf(Held);
    }

    /// Runs the program on `worker`'s storage with `options`: see `RunOptions` and `Outcome`.
    pub fn run(self: *const Program, worker: *Worker, options: RunOptions) RunError!Outcome {
        return worker.start(self, options);
    }

    /// A durable run: see `DurableOptions`.
    pub fn runDurable(self: *const Program, io: std.Io, gpa: Allocator, options: DurableOptions, visitor: anytype) DurableError!DurableOutcome {
        return durableRun(self, io, gpa, options, visitor);
    }

    /// Frees the program. Nothing it lent (results of its runs, diagnostics) may be used after.
    pub fn destroy(self: *Program) void {
        const program: *Held = @ptrCast(@alignCast(self));
        const gpa = program.gpa;
        program.handle.destroy();
        gpa.free(program.block);
        program.* = undefined;
        gpa.destroy(program);
    }
};

/// Admits `compilation` on both machines and copies it into a program the host owns.
pub fn prepare(gpa: Allocator, compilation: Compilation) PrepareError!Preparation {
    if (!compilation.current()) return error.StaleCompilation;
    const handle = switch (try forbic.prepared.prepare(gpa, compilation.program)) {
        .ok => |handle| handle,
        .failed => |refusal| return .{ .refused = .{ .by = refusal.by, .diagnostic = Diagnostic.located(compilation.program, refusal.diagnostic, compilation.loaded.name) } },
    };
    errdefer handle.destroy();
    const loaded = compilation.loaded;
    // A durable run compiles the program again from bytes: a bundle of files is written as the
    // packet the `forbic` tool reads, so that it is one input whose SHA-256 the journal records.
    var packet: std.Io.Writer.Allocating = .init(gpa);
    defer packet.deinit();
    const bundled = loaded.form == .bundle;
    const durable = if (bundled and loaded.bytes.len == 0) written: {
        const bundle = loaded.form.bundle;
        std.json.Stringify.value(.{ .root = bundle.root, .modules = bundle.modules }, .{}, &packet.writer) catch return error.OutOfMemory;
        break :written packet.written();
    } else loaded.bytes;
    const block = try gpa.alloc(u8, loaded.name.len + 1 + durable.len);
    errdefer gpa.free(block);
    @memcpy(block[0..loaded.name.len], loaded.name);
    block[loaded.name.len] = 0;
    @memcpy(block[loaded.name.len + 1 ..], durable);
    const program = try gpa.create(Program.Held);
    program.* = .{
        .gpa = gpa,
        .handle = handle,
        .identity = compilation.identity,
        .name = block[0..loaded.name.len :0],
        .bytes = block[loaded.name.len + 1 ..],
        .bundled = bundled,
        .block = block,
    };
    return .{ .ok = @ptrCast(program) };
}

// ---------------------------------------------------------------------------------------------
// Runs

/// The clock a run reads (`GetSecondsSinceEpoch`, `Profile`): a fixed start, in seconds at tick 0,
/// plus the run's virtual time, so that a run can be repeated; or the host's real-time clock.
pub const Clock = union(enum) { start: f64, real: std.Io };

/// What a run is given (RFC-0086, RFC-0087): a reader the program opens by name and reads lines
/// from (`OpenReader["name"]`), a writer it appends committed lines to (`OpenWriter["name"]`), or a
/// persistent key (`GetPersistentKey["name"]`). Names are 1 to 128 bytes of UTF-8, once per kind.
/// The streams are the host's, borrowed for the run; the host flushes a writer.
pub const Grant = union(enum) {
    reader: struct { name: []const u8, from: *std.Io.Reader },
    writer: struct { name: []const u8, to: *std.Io.Writer },
    /// A key without a state directory finds no entry and saves nothing (RFC-0087, S3): a durable
    /// run is the one that keeps what a program sets.
    key: []const u8,
};

/// A run's choices, all given again for every run (RFC-0088, A4): nothing of an earlier run or
/// an earlier choice reaches the next.
pub const RunOptions = struct {
    /// The work the run may do before it ends with `work_limit`.
    fuel: u64 = default_fuel,
    seed: u64 = default_seed,
    tick_rate: u64 = default_tick_rate,
    clock: Clock = .{ .start = 0 },
    trace: TraceMode = .digest,
    grants: []const Grant = &.{},
    /// Where each committed `Print` line goes, followed by a newline, as the run commits it: what
    /// a failed region printed is never written. None discards them. The host flushes it.
    output: ?*std.Io.Writer = null,
};

pub const RunError = error{
    /// Not 1 to 1,000,000 ticks per second.
    InvalidTickRate,
    /// A start that is not a finite number of seconds.
    InvalidClock,
    /// More than `grant_capacity` grants, a name that is not 1 to 128 bytes of UTF-8, or two
    /// grants of one kind with one name.
    InvalidGrants,
    /// Two reader grants of one stream: they would split its lines between them.
    SharedReader,
};

/// A run's end: completed, with its values, or ended by an error of the program (which includes
/// running out of fuel or of a capacity, and a writer of the host that refused a line).
pub const Outcome = union(enum) { completed: Completed, failed: Diagnostic };

/// One thread's storage for runs: a VM's, as large as the profile's capacities and touched only
/// as far as a run uses it. A worker runs one program at a time; the result of a run borrows it
/// until its next run.
pub const Worker = struct {
    gpa: Allocator,
    machine: *forbic.prepared.VmRun,
    replay: ?*forbic.trace_replay.Storage = null,
    world: World = .{},
    grants: [grant_capacity]forbic.effects.Grant = undefined,
    readers: [grant_capacity]?*std.Io.Reader = undefined,
    writers: [grant_capacity]?*std.Io.Writer = undefined,
    /// Counts runs: a `Completed` of an earlier run is refused.
    generation: u64 = 0,

    pub fn create(gpa: Allocator) error{OutOfMemory}!*Worker {
        const self = try gpa.create(Worker);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .machine = try forbic.scratch.storage(forbic.prepared.VmRun) };
        forbic.scratch.initialise(self.machine);
        return self;
    }

    pub fn destroy(self: *Worker) void {
        forbic.scratch.release(self.machine);
        if (self.replay) |replay| forbic.scratch.release(replay);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn start(self: *Worker, program: *const Program, options: RunOptions) RunError!Outcome {
        // The storage below is the last run's, which its result borrows: that result ends here,
        // before anything is checked or written, whether or not this run goes on.
        self.generation += 1;
        if (!forbic.types.Scheduler.validRate(options.tick_rate)) return error.InvalidTickRate;
        switch (options.clock) {
            .start => |seconds| if (!std.math.isFinite(seconds)) return error.InvalidClock,
            .real => {},
        }
        if (options.grants.len > grant_capacity) return error.InvalidGrants;
        const count = options.grants.len;
        for (options.grants, 0..) |grant, index| {
            self.readers[index] = null;
            self.writers[index] = null;
            self.grants[index] = switch (grant) {
                .reader => |reader| reader: {
                    for (self.readers[0..index]) |earlier| if (earlier == reader.from) return error.SharedReader;
                    self.readers[index] = reader.from;
                    break :reader .{ .kind = .reader, .name = reader.name };
                },
                .writer => |writer| writer: {
                    self.writers[index] = writer.to;
                    break :writer .{ .kind = .writer, .name = writer.name };
                },
                .key => |key| .{ .kind = .key, .name = key },
            };
        }
        if (!forbic.effects.validGrants(self.grants[0..count])) return error.InvalidGrants;
        self.world = .{
            .clock = options.clock,
            .tick_rate = options.tick_rate,
            .readers = self.readers[0..count],
            .writers = self.writers[0..count],
            .output = options.output,
        };
        const held = Program.held(program);
        const result = held.handle.runVm(self.machine, .{
            .work_budget = options.fuel,
            .seed = options.seed,
            .tick_rate = options.tick_rate,
            .trace = options.trace,
            .grants = self.grants[0..count],
            .source = self.world.source(),
            .sink = self.world.sink(),
        }) catch return error.InvalidGrants;
        return switch (result) {
            .failed => |diagnostic| .{ .failed = Diagnostic.located(held.handle.program(), diagnostic, held.name) },
            .ok => |execution| .{ .completed = .{
                .execution = execution,
                .owner = .{ .worker = .{ .worker = self, .generation = self.generation } },
                .replayed = held.handle.replayProgram(&self.machine.strings),
                .name = held.name,
                .seed = options.seed,
                .tick_rate = options.tick_rate,
                .fuel = options.fuel,
            } },
        };
    }
};

/// The world of an in-memory run: its clock, the host's readers and writers by grant index, and
/// where `Print` goes. A load finds no entry: without a state directory there is no store (S3).
const World = struct {
    clock: Clock = .{ .start = 0 },
    tick_rate: u64 = default_tick_rate,
    readers: []const ?*std.Io.Reader = &.{},
    writers: []const ?*std.Io.Writer = &.{},
    output: ?*std.Io.Writer = null,

    fn paced(start: f64, tick: u64, rate: u64) f64 {
        @setFloatMode(.strict);
        return start + @as(f64, @floatFromInt(tick)) / @as(f64, @floatFromInt(rate));
    }
    fn read(context: *anyopaque, request: forbic.effects.Request) error{InputFailed}!forbic.effects.Answer {
        const self: *World = @ptrCast(@alignCast(context));
        switch (request.kind) {
            .clock => {
                const seconds = switch (self.clock) {
                    .start => |start| paced(start, request.tick, self.tick_rate),
                    .real => |io| @as(f64, @floatFromInt(std.Io.Clock.real.now(io).nanoseconds)) / std.time.ns_per_s,
                };
                return .{ .bits = @bitCast(seconds) };
            },
            .load => return .{ .status = .end },
            .line => {
                if (request.request >= self.readers.len) return error.InputFailed;
                const reader = self.readers[request.request] orelse return error.InputFailed;
                const line = reader.takeDelimiter('\n') catch return error.InputFailed;
                return if (line) |text| .{ .bytes = text } else .{ .status = .end };
            },
        }
    }
    fn source(self: *World) forbic.effects.InputSource {
        return .{ .context = self, .read = read };
    }

    fn prepareAction(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn commit(context: *anyopaque, action: forbic.effects.Action) bool {
        const self: *World = @ptrCast(@alignCast(context));
        // A store action is committed to no store where there is no journal (RFC-0087, S3).
        if (action.channel == forbic.effects.store_channel) return true;
        const to: ?*std.Io.Writer = if (action.channel == 0) self.output else if (action.channel - 1 < self.writers.len) self.writers[action.channel - 1] else return false;
        const writer = to orelse return true;
        writer.writeAll(action.text) catch return false;
        writer.writeByte('\n') catch return false;
        return true;
    }
    fn abort(_: *anyopaque, _: []const u8) void {}
    fn sink(self: *World) forbic.effects.Sink {
        return .{ .context = self, .prepare = prepareAction, .commit = commit, .abort = abort };
    }
};

/// A value of a top-level binding: a number, a `logic` or a string as Zig has them, and anything
/// else (arrays, maps, structs, instances) as the machine holds it, which `writeValues` writes.
pub const Value = union(enum) {
    integer: i64,
    float: f64,
    logic: bool,
    string: []const u8,
    other: forbic.types.Value,
};

pub const ReportError = error{
    /// The result is of a run before the worker's last one: its storage holds another run.
    Stale,
    /// The run kept no trace (`off`): there is nothing a report could be checked against.
    NoTrace,
    /// The report is larger than the profile allows.
    ReportLimit,
    /// The run does not replay to what it reported: a defect, never the program's.
    InvalidExecution,
    WriteFailed,
    OutOfMemory,
};

/// A completed run. It borrows the worker it ran on until the worker's next run (the next call of
/// `run` on it, even one refused), and until a report of it that replays the run stops short
/// (`ReportLimit`, `InvalidExecution`, `OutOfMemory`: the second run spent the run's strings). It
/// borrows its
/// program until the program is destroyed; a durable run's lives only for its visitor's call.
pub const Completed = struct {
    execution: forbic.evaluator.Execution,
    owner: union(enum) { worker: struct { worker: *Worker, generation: u64 }, durable: *bool },
    /// The IR over the run's string pool, which a report of a `digest` run replays.
    replayed: forbic.types.Program,
    name: []const u8,
    seed: u64,
    tick_rate: u64,
    fuel: u64,

    fn check(self: Completed) error{Stale}!void {
        switch (self.owner) {
            .worker => |owner| if (owner.worker.generation != owner.generation) return error.Stale,
            .durable => |spent| if (spent.*) return error.Stale,
        }
    }

    /// The value of the first top-level binding named `binding`, or null when there is none or
    /// the run did not compute it.
    pub fn value(self: Completed, binding: []const u8) error{Stale}!?Value {
        try self.check();
        const program = self.execution.program;
        for (program.bindings) |candidate| {
            if (!std.mem.eql(u8, candidate.name.text(program.source), binding)) continue;
            if (!self.execution.active(candidate.node)) return null;
            const found = forbic.value_report.bindingValue(self.execution, candidate);
            return switch (found) {
                .integer => |x| .{ .integer = x },
                .floating => |x| .{ .float = x },
                .boolean => |x| .{ .logic = x },
                .string => |x| .{ .string = x },
                else => .{ .other = found },
            };
        }
        return null;
    }

    /// Committed actions, draws and inputs, as the run's effect record counts them.
    pub fn effects(self: Completed) error{Stale}!forbic.effects.Record {
        try self.check();
        return self.execution.effects;
    }

    /// The values of every top-level binding as one JSON object and a newline: what `forbic eval`
    /// prints after the lines. The report is validated first; a `digest` run's by replaying it.
    pub fn writeValues(self: Completed, out: *std.Io.Writer) ReportError!void {
        try self.check();
        if (self.execution.trace == .off) return error.NoTrace;
        const replay = try self.replayer();
        defer self.done(replay);
        _ = (if (replay) |storage| forbic.value_report.writeReplayed(out, self.execution, storage.producer(self.replayed, self.fuel), false, .{}) else forbic.value_report.write(out, self.execution, false, .{})) catch |problem| return self.failed(replay != null, problem);
    }

    /// The trace report: what `forbic trace` prints, validated as `writeValues` is.
    pub fn writeTrace(self: Completed, out: *std.Io.Writer) ReportError!void {
        try self.check();
        if (self.execution.trace == .off) return error.NoTrace;
        const replay = try self.replayer();
        defer self.done(replay);
        (if (replay) |storage| forbic.failure_report.writeReplayed(out, self.execution, storage.producer(self.replayed, self.fuel), self.name, .{}) else forbic.failure_report.write(out, self.execution, self.name, .{})) catch |problem| return self.failed(replay != null, problem);
    }

    /// The storage of a report's second run, on the reported run's seed and clock: the worker's,
    /// or for a durable run one made for the report.
    fn replayer(self: Completed) error{OutOfMemory}!?*forbic.trace_replay.Storage {
        if (self.execution.trace != .digest) return null;
        const storage = switch (self.owner) {
            .worker => |owner| owner.worker.replay orelse made: {
                const made = try forbic.scratch.storage(forbic.trace_replay.Storage);
                owner.worker.replay = made;
                break :made made;
            },
            .durable => try forbic.scratch.storage(forbic.trace_replay.Storage),
        };
        forbic.scratch.initialise(storage);
        storage.control.effects.seed = self.seed;
        storage.control.tick_rate = self.tick_rate;
        return storage;
    }
    /// A report's error. A replay that stopped short left the run's string pool as far as it got,
    /// so the run's values are no longer its own: the result is spent, every copy of it.
    fn failed(self: Completed, replayed: bool, problem: anyerror) ReportError {
        const reported = reportError(problem);
        if (replayed and reported != error.WriteFailed) switch (self.owner) {
            .worker => |owner| owner.worker.generation += 1,
            .durable => |spent| spent.* = true,
        };
        return reported;
    }
    fn done(self: Completed, replay: ?*forbic.trace_replay.Storage) void {
        if (self.owner == .durable) if (replay) |storage| forbic.scratch.release(storage);
    }
};

/// The IR a run was given, from its execution's view of it: the machine extends the view's
/// `strings` over the strings the run built, and the literals end where the IR's `string_tail`
/// starts. A report's second run is given the IR, and builds those strings again.
fn literalsOnly(program: forbic.types.Program) forbic.types.Program {
    const start = @intFromPtr(program.strings.ptr);
    const tail = @intFromPtr(program.string_tail.ptr);
    std.debug.assert(tail >= start and tail - start <= program.strings.len);
    var ir = program;
    ir.strings = program.strings[0 .. tail - start];
    return ir;
}

fn reportError(problem: anyerror) ReportError {
    return switch (problem) {
        error.ReportLimit => error.ReportLimit,
        error.WriteFailed => error.WriteFailed,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidExecution,
    };
}

// ---------------------------------------------------------------------------------------------
// Durable runs

/// What a durable run asks of its state directory (RFC-0086, P2.5): to `start` a run (which
/// refuses a directory that holds an unfinished one), to resume one a crash left unfinished
/// (`resume_run`), or to end it without running (`abandon`), publishing what it sealed.
pub const Intent = journal.Intent;

/// A grant of a durable run: a reader and a writer are files, which a resumed run reads on from
/// where its journal sealed them and into which a run's committed lines are published.
pub const FileGrant = union(enum) {
    reader: NamedPath,
    writer: NamedPath,
    key: []const u8,
};
pub const NamedPath = struct { name: []const u8, path: []const u8 };

/// A durable run, as `forbic eval FILE --state DIR` makes it: it keeps a journal in `state`,
/// loads the persistent cells of its keys from the store there and publishes what it sets when
/// it ends; a crash leaves the journal, which the next run resumes or abandons.
pub const DurableOptions = struct {
    state: []const u8,
    intent: Intent = .start,
    /// Null: the default to start, or the journal's when resuming. A value given to a resumed
    /// run must be the journal's.
    seed: ?u64 = null,
    tick_rate: ?u64 = null,
    /// The start of the clock in seconds at tick 0; null is the real-time clock.
    clock: ?f64 = null,
    /// A resumed run takes the journal's grants when it is given none.
    grants: []const FileGrant = &.{},
    /// Where the run's `Print` lines go, as the journal makes them durable.
    output: *std.Io.Writer,
    /// Where diagnostics and notes go, as the `forbic` tool writes them on standard error.
    messages: *std.Io.Writer,
    style: Style = .plain,
};

pub const DurableError = error{ InvalidTickRate, InvalidClock, InvalidGrants, OutOfMemory };

/// A durable run's end. Whatever it is, `messages` says it in words.
pub const DurableOutcome = union(enum) {
    /// The run completed and its visitor was given it.
    completed,
    /// Nothing ran: an abandoned run, or a directory whose run had already finished.
    nothing_ran,
    /// The run, the state directory or the host refused: see `DurableFailure`.
    failed: DurableFailure,
};

/// Why a durable run failed, as values, and the first line it wrote to `messages`.
pub const DurableFailure = struct {
    cause: Cause,
    /// The program's diagnostic, for `program`.
    code: ?Code = null,
    /// The error that stopped the host or the visitor, for `host` and `visitor`.
    error_name: ?[]const u8 = null,
    note_bytes: [note_capacity]u8 = undefined,
    note_length: usize = 0,

    pub const Cause = enum {
        /// The program was refused or ended in an error: `code` says which.
        program,
        /// The state directory, its journal or its store refused the run (in use, unfinished, of
        /// another run, damaged, not a directory): `note()` says which, as the tool does.
        state,
        /// The visitor returned an error, after the run had finished.
        visitor,
        /// The host could not go on: a writer, the file system or memory.
        host,
    };
    pub const note_capacity = 256;

    /// The first line written to `messages`, without its newline, cut at `note_capacity` bytes.
    pub fn note(self: *const DurableFailure) []const u8 {
        return self.note_bytes[0..self.note_length];
    }
};

/// The `messages` of a durable run: everything goes on to the host's writer, and the first line
/// is kept for the failure.
const Messages = struct {
    inner: *std.Io.Writer,
    failure: DurableFailure = .{ .cause = .host },
    lined: bool = false,
    buffer: [256]u8 = undefined,
    writer: std.Io.Writer,

    fn take(self: *Messages, bytes: []const u8) std.Io.Writer.Error!void {
        try self.inner.writeAll(bytes);
        if (self.lined) return;
        const line = if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| bytes[0..end] else bytes;
        self.lined = line.len != bytes.len;
        const room = @min(line.len, DurableFailure.note_capacity - self.failure.note_length);
        @memcpy(self.failure.note_bytes[self.failure.note_length..][0..room], line[0..room]);
        self.failure.note_length += room;
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Messages = @alignCast(@fieldParentPtr("writer", w));
        try self.take(w.buffered());
        w.end = 0;
        var taken: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try self.take(slice);
            taken += slice.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.take(last);
        return taken + last.len * splat;
    }
    fn failed(self: *Messages, cause: DurableFailure.Cause, code: ?Code, error_name: ?[]const u8) DurableOutcome {
        var failure = self.failure;
        failure.cause = cause;
        failure.code = code;
        failure.error_name = error_name;
        return .{ .failed = failure };
    }
};

fn durableRun(program: *const Program, io: std.Io, gpa: Allocator, options: DurableOptions, visitor: anytype) DurableError!DurableOutcome {
    const held = Program.held(program);
    if (options.tick_rate) |rate| if (!forbic.types.Scheduler.validRate(rate)) return error.InvalidTickRate;
    if (options.clock) |start| if (!std.math.isFinite(start)) return error.InvalidClock;
    if (options.grants.len > grant_capacity) return error.InvalidGrants;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const list = try arena.allocator().alloc(forbic.effects.Grant, options.grants.len);
    const paths = try arena.allocator().alloc([]const u8, options.grants.len);
    for (options.grants, list, paths) |grant, *made, *path| switch (grant) {
        .reader => |reader| {
            made.* = .{ .kind = .reader, .name = reader.name };
            path.* = reader.path;
        },
        .writer => |writer| {
            made.* = .{ .kind = .writer, .name = writer.name };
            path.* = writer.path;
        },
        .key => |key| {
            made.* = .{ .kind = .key, .name = key };
            path.* = "";
        },
    };
    if (!forbic.effects.validGrants(list)) return error.InvalidGrants;
    for (list, paths) |grant, path| if (grant.kind != .key and path.len == 0) return error.InvalidGrants;
    const Visitor = @TypeOf(visitor);
    // `null` is a run without a visitor.
    const visiting = Visitor != @TypeOf(null);
    const Handler = struct {
        visitor: if (visiting) Visitor else void,
        called: bool = false,
        spent: bool = false,
        problem: ?anyerror = null,
        name: []const u8,

        fn consume(context: *anyopaque, execution: forbic.evaluator.Execution, _: *std.Io.Writer, _: *std.Io.Writer) anyerror!u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.called = true;
            if (comptime visiting) return self.visit(execution) else return 0;
        }
        fn visit(self: *@This(), execution: forbic.evaluator.Execution) u8 {
            self.visitor.completed(.{
                .execution = execution,
                .owner = .{ .durable = &self.spent },
                .replayed = literalsOnly(execution.program),
                .name = self.name,
                .seed = execution.effects.seed,
                .tick_rate = execution.scheduler.tick_rate,
                .fuel = forbic.types.limits.evaluation_work,
            }) catch |problem| {
                self.problem = problem;
                return 1;
            };
            return 0;
        }
    };
    var handler: Handler = .{ .visitor = if (visiting) visitor else {}, .name = held.name };
    var messages: Messages = .{ .inner = options.messages, .writer = undefined };
    messages.writer = .{ .buffer = &messages.buffer, .vtable = &.{ .drain = Messages.drain } };
    var reporting: forbic_host.Reporting = .{};
    // `execute` uses only `io`, `gpa` and `arena` of the process state (W3.2a).
    const init: std.process.Init = .{ .minimal = undefined, .arena = &arena, .gpa = gpa, .io = io, .environ_map = undefined, .preopens = undefined };
    const status = forbic_host.execute(init, .{
        .command = .{ .run = .{ .context = &handler, .consume = Handler.consume, .prints = true } },
        .file = held.name,
        .bundled = held.bundled,
        .given = held.bytes,
        .natives = held.handle.program().natives,
        .seed = options.seed orelse default_seed,
        .tick_rate = options.tick_rate orelse default_tick_rate,
        .clock = options.clock,
        .grants = .{ .list = list, .paths = paths },
        .state = options.state,
        .journaling = .{ .intent = options.intent, .seed_given = options.seed != null, .tick_rate_given = options.tick_rate != null },
        .diagnostics = options.style,
        .reporting = &reporting,
    }, options.output, &messages.writer) catch |problem| {
        messages.writer.flush() catch {};
        return switch (problem) {
            error.OutOfMemory => error.OutOfMemory,
            error.IntentWithoutState, error.StateNotTaken, error.InvalidGrants, error.GrantsNotTaken => error.InvalidGrants,
            else => messages.failed(.host, null, @errorName(problem)),
        };
    };
    messages.writer.flush() catch |problem| return messages.failed(.host, null, @errorName(problem));
    if (handler.problem) |problem| return messages.failed(.visitor, null, @errorName(problem));
    if (status != 0) return messages.failed(if (reporting.code != null) .program else .state, reporting.code, null);
    return if (handler.called) .completed else .nothing_ran;
}

// ---------------------------------------------------------------------------------------------
// The bounded cache (RFC-0088, A5)

/// The most entries a cache may be given.
pub const max_cache_entries = 4096;
/// The most leases a cache may have out at once.
pub const max_cache_leases = 65536;

/// A cache's ceilings, the host's: zero entries (the default) is no cache, so that nothing is
/// kept that the host did not ask for. `leases` bounds the programs lent at once, the ones the
/// cache keeps and the ones it could not.
pub const CacheLimits = struct { entries: u32 = 0, bytes: usize = 0, leases: u32 = 64 };

/// A program a cache lends: given back with `Cache.release` to the cache that lent it, once.
/// `hit` is whether it was already there; `kept` whether the cache holds it (otherwise it is the
/// lease's alone, and is destroyed when given back). The other fields name the lease.
pub const Lease = struct {
    program: *const Program,
    hit: bool,
    kept: bool,
    cache: *const Cache,
    ticket: u32,
    serial: u64,
};

pub const Obtained = union(enum) { ok: Lease, failed: Failure, refused: Refusal };

/// An optional bounded cache of prepared programs, by identity (RFC-0088, A5). It owns what it
/// holds and lends it out: a program lent is pinned until every lease of it is given back, and
/// each lease is a ticket of its own, given back once. Inserting into a full cache evicts
/// unpinned entries, oldest inserted first, when that makes room, and otherwise the new program
/// is not kept (a bypass): a miss is normal, never the guest's error. Not thread-safe: a host
/// that shares one guards it, while the programs it lends are shared freely.
pub const Cache = struct {
    gpa: Allocator,
    limits: CacheLimits,
    slots: []Slot,
    tickets: []Ticket,
    used_bytes: usize = 0,
    /// Counts insertions and leases alike: no two are ever numbered alike, so a lease given back
    /// twice, or a lease of an entry evicted since, names nothing.
    serial: u64 = 0,

    const Slot = struct {
        program: ?*Program = null,
        /// The tickets out on it.
        references: u32 = 0,
        /// When it was inserted: eviction takes the smallest first (FIFO).
        serial: u64 = 0,
        bytes: usize = 0,
    };
    /// One lease out: on an entry (`slot`), or of a program the cache did not keep (`program`).
    /// A free ticket has serial 0.
    const Ticket = struct {
        serial: u64 = 0,
        slot: ?u32 = null,
        program: ?*Program = null,
    };

    pub fn create(gpa: Allocator, limits: CacheLimits) error{ OutOfMemory, TooManyEntries, TooManyLeases }!*Cache {
        if (limits.entries > max_cache_entries) return error.TooManyEntries;
        if (limits.leases == 0 or limits.leases > max_cache_leases) return error.TooManyLeases;
        const self = try gpa.create(Cache);
        errdefer gpa.destroy(self);
        const slots = try gpa.alloc(Slot, limits.entries);
        errdefer gpa.free(slots);
        const tickets = try gpa.alloc(Ticket, limits.leases);
        @memset(slots, .{});
        @memset(tickets, .{});
        self.* = .{ .gpa = gpa, .limits = limits, .slots = slots, .tickets = tickets };
        return self;
    }

    /// Frees the cache and every program it holds. Refused while a lease is out.
    pub fn destroy(self: *Cache) error{InUse}!void {
        for (self.tickets) |ticket| if (ticket.serial != 0) return error.InUse;
        for (self.slots) |slot| if (slot.program) |program| program.destroy();
        const gpa = self.gpa;
        gpa.free(self.slots);
        gpa.free(self.tickets);
        self.* = undefined;
        gpa.destroy(self);
    }

    /// The program of `source` with `options`: lent from the cache when it holds one of that
    /// identity and those native implementations; otherwise compiled with `compiler`, prepared and
    /// kept when it fits. The source is read once. Like a compile, it ends what `compiler` lent
    /// before. `TooManyLeases`: `limits.leases` are out, and nothing was read.
    pub fn obtain(self: *Cache, compiler: *Compiler, source: Source, options: CompileOptions) error{ OutOfMemory, TooManyLeases }!Obtained {
        const ticket: u32 = for (self.tickets, 0..) |held, index| {
            if (held.serial == 0) break @intCast(index);
        } else return error.TooManyLeases;
        const natives = if (options.natives) |table| table.table() else &forbic.native_std.table;
        const loaded = switch (try compiler.load(source)) {
            .ok => |loaded| loaded,
            .failed => |failure| return .{ .failed = failure },
        };
        const identity = identityOf(loaded, natives);
        for (self.slots, 0..) |*slot, index| if (slot.program) |program| {
            if (!program.identity().eql(identity) or !sameNatives(program.ir().natives, natives)) continue;
            return .{ .ok = self.lend(ticket, program, @intCast(index), true) };
        };
        const compilation = switch (compiler.compileLoaded(loaded, natives, identity)) {
            .ok => |compilation| compilation,
            .failed => |failure| return .{ .failed = failure },
        };
        const program = switch (prepare(self.gpa, compilation) catch |problem| switch (problem) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StaleCompilation => unreachable, // compiled just now
        }) {
            .ok => |program| program,
            .refused => |refusal| return .{ .refused = refusal },
        };
        return .{ .ok = self.lend(ticket, program, self.insert(program), false) };
    }

    /// Gives a lease back. A lease given back twice, or to another cache, is refused, and changes
    /// nothing.
    pub fn release(self: *Cache, lease: Lease) error{UnknownLease}!void {
        if (lease.cache != self or lease.ticket >= self.tickets.len) return error.UnknownLease;
        const ticket = &self.tickets[lease.ticket];
        if (ticket.serial == 0 or ticket.serial != lease.serial) return error.UnknownLease;
        if (ticket.slot) |index| {
            const slot = &self.slots[index];
            std.debug.assert(slot.references != 0 and slot.program != null);
            slot.references -= 1;
        } else ticket.program.?.destroy();
        ticket.* = .{};
    }

    /// Programs held, bytes held, programs lent and leases out.
    pub fn usage(self: *const Cache) struct { entries: u32, bytes: usize, pinned: u32, leases: u32 } {
        var entries: u32 = 0;
        var pinned: u32 = 0;
        var leases: u32 = 0;
        for (self.slots) |slot| if (slot.program != null) {
            entries += 1;
            if (slot.references != 0) pinned += 1;
        };
        for (self.tickets) |ticket| leases += @intFromBool(ticket.serial != 0);
        return .{ .entries = entries, .bytes = self.used_bytes, .pinned = pinned, .leases = leases };
    }

    fn lend(self: *Cache, index: u32, program: *Program, slot: ?u32, hit: bool) Lease {
        self.serial += 1;
        self.tickets[index] = if (slot) |at| .{ .serial = self.serial, .slot = at } else .{ .serial = self.serial, .program = program };
        if (slot) |at| self.slots[at].references += 1;
        return .{ .program = program, .hit = hit, .kept = slot != null, .cache = self, .ticket = index, .serial = self.serial };
    }

    /// Keeps `program` when there is room, after evicting what must go: its slot, or null for a
    /// bypass, which evicts nothing.
    fn insert(self: *Cache, program: *Program) ?u32 {
        const size = program.bytes();
        if (self.slots.len == 0 or size > self.limits.bytes) return null;
        // One identity, one entry: a program of the same identity with other native functions
        // stays the lease's.
        for (self.slots) |slot| if (slot.program) |held| if (held.identity().eql(program.identity())) return null;
        // Room: a free slot and the bytes, after evicting unpinned entries oldest first. Worked
        // out before anything is evicted, so that a bypass evicts nothing.
        var free_slot = false;
        var evictable: usize = 0;
        var unpinned: usize = 0;
        for (self.slots) |slot| {
            if (slot.program == null) free_slot = true else if (slot.references == 0) {
                evictable += slot.bytes;
                unpinned += 1;
            }
        }
        std.debug.assert(self.used_bytes <= self.limits.bytes);
        const room = self.limits.bytes - self.used_bytes;
        const over = if (size > room) size - room else 0;
        if (evictable < over or (!free_slot and unpinned == 0)) return null;
        var freed: usize = 0;
        while (freed < over or !free_slot) {
            const oldest = self.oldestUnpinned().?;
            const slot = &self.slots[oldest];
            freed += slot.bytes;
            self.used_bytes -= slot.bytes;
            slot.program.?.destroy();
            slot.* = .{};
            free_slot = true;
        }
        const index = for (self.slots, 0..) |slot, at| {
            if (slot.program == null) break at;
        } else unreachable;
        self.serial += 1;
        self.slots[index] = .{ .program = program, .serial = self.serial, .bytes = size };
        self.used_bytes += size;
        std.debug.assert(self.used_bytes <= self.limits.bytes);
        return @intCast(index);
    }

    fn oldestUnpinned(self: *const Cache) ?usize {
        var oldest: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.program == null or slot.references != 0) continue;
            if (oldest == null or slot.serial < self.slots[oldest.?].serial) oldest = index;
        }
        return oldest;
    }
};

/// Whether two native tables have the same functions and host contexts, entry by entry: the part
/// of a table its identity does not hash (pointers).
fn sameNatives(a: []const forbic.native.Entry, b: []const forbic.native.Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.call != y.call) return false;
        const x_host: ?*const anyopaque = if (x.host) |host| host.pointer else null;
        const y_host: ?*const anyopaque = if (y.host) |host| host.pointer else null;
        if (x_host != y_host) return false;
    }
    return true;
}

test {
    _ = @import("forbic_embed_tests.zig");
}
