//! The host's side of the store (RFC-0087, P5.5: S1, S3, S4, S6, S7): `DIR/store/` on the file
//! system as a `forbic.store.Disk`, what a journaled run loads from it before it starts, and
//! `forbic store show`.
//!
//! The logic of the store (the format, the rules of publication) is `forbic.store`'s, which knows
//! no file system. Here a `put` is a file written beside its name, synced, renamed over it and
//! synced again; an object or a generation that is already there with the bytes its name is the
//! hash of is left alone. Windows has no directory sync, so the sync of the renamed file is what a
//! host can do there; the order of the operations is what keeps the store whole when a crash
//! reorders none of them, and a reader that finds it otherwise refuses it (`StoreFailed`).
const std = @import("std");
const forbic = @import("forbic");
const durable = forbic.durable;
const effects = forbic.effects;
const store = forbic.store;

/// A persistent cell of the program, by its index among the program's cells and its store name (S2).
pub const Cell = struct { index: u32, name: []const u8 };

/// The persistent cells of `program` with their store names, in the order they are declared.
pub fn cellsOf(arena: std.mem.Allocator, program: forbic.types.Program) std.mem.Allocator.Error![]Cell {
    var cells: std.ArrayList(Cell) = .empty;
    const cat = forbic.persist_json.Catalogue.of(program);
    for (program.source_cells, 0..) |cell, index| {
        if (cell.keyed != .persistent) continue;
        const name = forbic.persist_json.storeName(cat, cell.name);
        const joined = try arena.alloc(u8, name.length());
        var at: usize = 0;
        for (name.slice()) |part| {
            @memcpy(joined[at..][0..part.len], part);
            at += part.len;
        }
        try cells.append(arena, .{ .index = @intCast(index), .name = joined });
    }
    return cells.toOwnedSlice(arena);
}

/// Makes a directory's entries durable (see `journal.zig`): a no-op where there is no such call.
fn syncDirectory(io: std.Io, dir: std.Io.Dir) !void {
    if (@import("builtin").os.tag == .windows) return;
    const readable = try dir.openDir(io, ".", .{ .iterate = true });
    defer readable.close(io);
    const handle: std.Io.File = .{ .handle = readable.handle, .flags = .{ .nonblocking = false } };
    try handle.sync(io);
}

/// How a directory's entries are made durable: the host's (`syncDirectory`), or, in a test, one that
/// records which directories were synced.
pub const DirectorySync = struct {
    context: ?*anyopaque = null,
    call: *const fn (context: ?*anyopaque, io: std.Io, dir: std.Io.Dir) anyerror!void = hostSync,

    fn sync(self: DirectorySync, io: std.Io, dir: std.Io.Dir) anyerror!void {
        return self.call(self.context, io, dir);
    }
    fn hostSync(_: ?*anyopaque, io: std.Io, dir: std.Io.Dir) anyerror!void {
        return syncDirectory(io, dir);
    }
};

/// `createDirPath` that also makes each directory it creates durable: the entry of a new directory
/// lives in its parent, so the parent is synced after the directory is made (a file or directory in
/// a directory that is not itself durable is lost with it). The directories made here are synced
/// in the order they were made, the outermost first. The last one, `sub_path` itself, is synced
/// in its parent also when it was there, because a run that died after making it may not have
/// synced it; the directories above it that were there are not.
pub fn createDirPathDurable(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, sync: DirectorySync) !void {
    var it = std.Io.Dir.path.componentIterator(sub_path);
    var component = it.last() orelse return error.BadPathName;
    var existed = false;
    while (true) {
        existed = false;
        if (dir.createDir(io, component.path, .default_dir)) |_| {
            try syncParent(io, dir, component.path, sync);
        } else |problem| switch (problem) {
            error.PathAlreadyExists => {
                const stat = try dir.statFile(io, component.path, .{});
                if (stat.kind != .directory) return error.NotDir;
                existed = true;
            },
            error.FileNotFound => {
                component = it.previous() orelse return problem;
                continue;
            },
            else => return problem,
        }
        component = it.next() orelse {
            if (existed) try syncParent(io, dir, component.path, sync);
            return;
        };
    }
}

/// Syncs the directory that holds `path`, which is `dir` when `path` is one name.
fn syncParent(io: std.Io, dir: std.Io.Dir, path: []const u8, sync: DirectorySync) !void {
    const parent_path = std.Io.Dir.path.dirname(path) orelse return sync.sync(io, dir);
    const parent = try dir.openDir(io, parent_path, .{});
    defer parent.close(io);
    try sync.sync(io, parent);
}

/// `DIR/store/` and its three places, open.
pub const Files = struct {
    root: std.Io.Dir,
    objects: std.Io.Dir,
    generations: std.Io.Dir,
    io: std.Io = undefined,
    sync: DirectorySync = .{},

    /// Opens the store of the state directory `state`; with `create`, makes what is missing (S1).
    pub fn open(io: std.Io, state: std.Io.Dir, create: bool) !Files {
        return openWith(io, state, create, .{});
    }

    /// `open` with directories made durable by `sync`.
    pub fn openWith(io: std.Io, state: std.Io.Dir, create: bool, sync: DirectorySync) !Files {
        if (create) try state.createDirPath(io, "store/objects");
        if (create) try state.createDirPath(io, "store/generations");
        const root = try state.openDir(io, "store", .{});
        errdefer root.close(io);
        const objects = try root.openDir(io, "objects", .{});
        errdefer objects.close(io);
        const generations = try root.openDir(io, "generations", .{});
        errdefer generations.close(io);
        // The entries of objects, generations and active live in store, and the entry of store in the
        // state directory: a file synced in a directory whose own entry is not durable is lost with
        // it, so both are synced, inside out, before anything is published. Every time, because a
        // crash may have cut an earlier creation short. The entry of the state directory itself is
        // its creator's (`createDirPathDurable`).
        if (create) {
            try sync.sync(io, root);
            try sync.sync(io, state);
        }
        return .{ .root = root, .objects = objects, .generations = generations, .io = io, .sync = sync };
    }
    pub fn close(self: *Files, io: std.Io) void {
        self.generations.close(io);
        self.objects.close(io);
        self.root.close(io);
    }
    pub fn handle(self: *Files, gpa: std.mem.Allocator) forbic.store.Store {
        return .{ .disk = .{ .context = self, .read = read, .put = put }, .gpa = gpa };
    }

    fn place(self: *Files, area: forbic.store.Area) std.Io.Dir {
        return switch (area) {
            .objects => self.objects,
            .generations => self.generations,
            .root => self.root,
        };
    }

    fn read(context: *anyopaque, gpa: std.mem.Allocator, area: forbic.store.Area, name: []const u8, limit: usize) forbic.store.DiskError!?[]u8 {
        const self: *Files = @ptrCast(@alignCast(context));
        const file = self.place(area).openFile(self.io, name, .{}) catch |problem| return if (problem == error.FileNotFound) null else error.DiskFailed;
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return error.DiskFailed;
        // The size is the disk's to claim: it is checked before any memory is taken for it.
        if (stat.size > limit) return error.TooLarge;
        const bytes = gpa.alloc(u8, std.math.cast(usize, stat.size) orelse return error.DiskFailed) catch return error.DiskFailed;
        errdefer gpa.free(bytes);
        const count = file.readPositionalAll(self.io, bytes, 0) catch return error.DiskFailed;
        if (count != bytes.len) return error.DiskFailed;
        return bytes;
    }

    fn put(context: *anyopaque, area: forbic.store.Area, name: []const u8, bytes: []const u8) forbic.store.DiskError!void {
        const self: *Files = @ptrCast(@alignCast(context));
        const dir = self.place(area);
        const io = self.io;
        // A file named by the hash of its bytes that is already whole is not written again.
        // It is synced again, with its directory: a publication cut short after its rename may have
        // left it named but not yet durable, and this one is what makes it so.
        if (area != .root) if (self.whole(dir, name, bytes)) {
            const file = dir.openFile(io, name, .{ .mode = .read_write }) catch return error.DiskFailed;
            defer file.close(io);
            file.sync(io) catch return error.DiskFailed;
            self.sync.sync(io, dir) catch return error.DiskFailed;
            return;
        };
        var staged_name: [96]u8 = undefined;
        const staged = std.fmt.bufPrint(&staged_name, "{s}.tmp", .{name}) catch return error.DiskFailed;
        {
            const file = dir.createFile(io, staged, .{}) catch return error.DiskFailed;
            defer file.close(io);
            file.writePositionalAll(io, bytes, 0) catch return error.DiskFailed;
            file.sync(io) catch return error.DiskFailed;
        }
        dir.rename(staged, dir, name, io) catch {
            dir.deleteFile(io, staged) catch {};
            return error.DiskFailed;
        };
        // The renamed file is synced again, and where the host can, its directory: the rename is as
        // durable as the file system makes it before the next file is written.
        {
            // Opened for writing: Windows flushes only a handle that can write.
            const file = dir.openFile(io, name, .{ .mode = .read_write }) catch return error.DiskFailed;
            defer file.close(io);
            file.sync(io) catch return error.DiskFailed;
        }
        self.sync.sync(io, dir) catch return error.DiskFailed;
    }

    /// Whether the file `name` holds exactly `bytes`.
    fn whole(self: *Files, dir: std.Io.Dir, name: []const u8, bytes: []const u8) bool {
        const file = dir.openFile(self.io, name, .{}) catch return false;
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return false;
        if (stat.size != bytes.len) return false;
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        var chunk: [64 * 1024]u8 = undefined;
        var at: u64 = 0;
        while (at < bytes.len) {
            const count = file.readPositionalAll(self.io, &chunk, at) catch return false;
            if (count == 0) return false;
            hash.update(chunk[0..count]);
            at += count;
        }
        var digest: store.Hash = undefined;
        hash.final(&digest);
        return std.mem.eql(u8, &digest, &store.hashOf(bytes));
    }
};

/// One entry a run loads: the request that asks for it (`effects.loadRequest`) and its text.
pub const Load = struct { request: u32, text: []const u8 };

/// What a journaled run on a program with persistent cells starts from (S4, S7): the reference its
/// journal's header records, and the text of every entry the program's cells could load for the
/// keys it was granted, read and checked before anything runs.
pub const Prepared = struct {
    reference: durable.StoreRef,
    /// Sorted by request.
    loads: []const Load,
};

pub const Prepare = union(enum) { ok: Prepared, problem: Problem };

pub const Problem = union(enum) {
    /// The store cannot be read or written: the reason is the store's.
    failed: []const u8,
    /// A disk operation failed.
    disk: anyerror,
    /// RFC-0087, P5.6 (G3): the schema of the generation the run would start from refuses the
    /// program's; every refusal, in the order the check gives them. Nothing was written.
    incompatible: []const forbic.persist_schema.Refusal,
    /// TASK-0109 W2 round 2, c1-2: the header of the journal being resumed names a schema that
    /// is not its program's (`other_schema`). Nothing was made or written.
    other_schema,
};

/// Prepares the store of the state directory `state` for a run (S3 to S7): makes `DIR/store/`, takes
/// the generation `active` names (a resumed run, the one its header records), checks its schema
/// against the program's `schema` (G3, P5.6), writes the program's schema as an object (a resumed
/// run keeps the header's), and reads from the generation the entry of every `(cell, key)` the
/// run's cells and keys name. A store that cannot be read is `StoreFailed`, and a schema that
/// refuses the program's is `incompatible`, both reported before anything runs; a refusal writes
/// nothing. `resumed` is the header's reference of a journal being resumed, whose schema must be
/// the program's (c1-2): the header's program is this one (R3), and its schema is a function of it,
/// so a header that names another was not written by this program's run; it is refused (`other_schema`)
/// before anything of the store is made or written. RFC-0087, P5.7 (R8):
/// `sealed` is the input record its durable prefix holds: a load it holds is served from it and
/// never asked of the store, so its entry is not read.
pub fn prepare(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state: std.Io.Dir, cells: []const Cell, schema: []const u8, grants: []const effects.Grant, resumed: ?durable.StoreRef, sealed: effects.InputRecord) error{OutOfMemory}!Prepare {
    if (resumed) |recorded| if (!std.mem.eql(u8, &recorded.schema, &store.hashOf(schema))) return .{ .problem = .other_schema };
    var files = Files.open(io, state, true) catch |problem| return .{ .problem = .{ .disk = problem } };
    defer files.close(io);
    var held = files.handle(gpa);
    const base: store.Hash = if (resumed) |recorded| recorded.base else (held.activeName() catch |problem| return failure(&held, problem)) orelse @splat(0);
    const generation: ?store.Generation = if (std.mem.allEqual(u8, &base, 0)) null else held.generation(arena, base) catch |problem| return failure(&held, problem);
    if (generation) |found| switch (try checkSchema(&held, arena, found, schema)) {
        .ok => |outcome| if (outcome.refusals.len != 0) return .{ .problem = .{ .incompatible = outcome.refusals } },
        .problem => |problem| return .{ .problem = problem },
    };
    var reference: durable.StoreRef = undefined;
    const made = held.putObject(schema) catch |problem| return failure(&held, problem);
    if (resumed) |recorded| {
        // The journal's header names the schema and the base; the program is the same, so the schema
        // object is the one written before the header (checked above), written again if it is gone.
        reference = recorded;
    } else {
        reference.schema = made;
        reference.base = base;
    }
    var loads: std.ArrayList(Load) = .empty;
    // The loads the journal sealed, by request.
    var served: std.ArrayList(u32) = .empty;
    for (sealed.entries) |input| if (input.kind == .load) try served.append(arena, input.request);
    std.mem.sort(u32, served.items, {}, std.sort.asc(u32));
    if (generation) |found| {
        for (cells) |cell| for (grants, 0..) |grant, index| {
            if (grant.kind != .key) continue;
            const request = effects.loadRequest(cell.index, @intCast(index));
            if (std.sort.binarySearch(u32, served.items, request, struct {
                fn order(wanted: u32, present: u32) std.math.Order {
                    return std.math.order(wanted, present);
                }
            }.order) != null) continue;
            const entry = found.find(cell.name, grant.name) orelse continue;
            const text = held.text(entry) catch |problem| return failure(&held, problem);
            try loads.append(arena, .{ .request = request, .text = try arena.dupe(u8, text) });
            gpa.free(text);
        };
    }
    std.mem.sort(Load, loads.items, {}, struct {
        fn less(_: void, a: Load, b: Load) bool {
            return a.request < b.request;
        }
    }.less);
    return .{ .ok = .{ .reference = reference, .loads = try loads.toOwnedSlice(arena) } };
}

/// Why `prepare` refuses a resumed run whose header names a schema other than its program's.
pub const other_schema = "the journal's header names a schema that is not its program's";

/// RFC-0087, P5.6 (G3): the check of the schema of `generation` against the program's `schema`.
const Checked = union(enum) { ok: forbic.persist_schema.Outcome, problem: Problem };
fn checkSchema(held: *store.Store, arena: std.mem.Allocator, generation: store.Generation, schema: []const u8) error{OutOfMemory}!Checked {
    const old = held.text(.{ .cell = "", .key = "", .object = generation.schema }) catch |problem| return switch (problem) {
        error.OutOfMemory => error.OutOfMemory,
        error.StoreFailed => .{ .problem = .{ .failed = held.why } },
        else => .{ .problem = .{ .disk = problem } },
    };
    defer held.gpa.free(old);
    const outcome = forbic.persist_schema.check(arena, old, schema) catch |problem| switch (problem) {
        error.OutOfMemory => return error.OutOfMemory,
        // The program's own schema is always one: `describe` wrote it.
        error.InvalidNew => unreachable,
    };
    if (outcome.unreadable) |reason| return .{ .problem = .{ .failed = try std.fmt.allocPrint(arena, "the schema of its generation cannot be read: {s}", .{reason}) } };
    return .{ .ok = outcome };
}

/// RFC-0087, P5.6: what `forbic check FILE --state DIR` finds, the check of G3 without a run and
/// without the run lock: the program's `schema` against the schema of the active generation of the
/// store of the state directory `path`. Nothing is written.
pub const Trial = union(enum) {
    /// No generation to check against: no directory, no store, or a store without one.
    empty,
    /// The state directory holds a journal, which the next run processes first: it may publish a
    /// generation of another schema (R2), so the store's schema is not yet the one a run meets.
    journal,
    /// The check, compatible when it has no refusal.
    checked: forbic.persist_schema.Outcome,
    problem: Problem,
};
pub fn trial(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, schema: []const u8) error{OutOfMemory}!Trial {
    const state = std.Io.Dir.cwd().openDir(io, path, .{}) catch |problem| return if (problem == error.FileNotFound) .empty else .{ .problem = .{ .disk = problem } };
    defer state.close(io);
    if (state.statFile(io, "journal", .{})) |_| return .journal else |problem| if (problem != error.FileNotFound) return .{ .problem = .{ .disk = problem } };
    var files = Files.open(io, state, false) catch |problem| return if (problem == error.FileNotFound) .empty else .{ .problem = .{ .disk = problem } };
    defer files.close(io);
    var held = files.handle(gpa);
    const found = (held.active(arena) catch |problem| return switch (problem) {
        error.OutOfMemory => error.OutOfMemory,
        error.StoreFailed => .{ .problem = .{ .failed = held.why } },
        else => .{ .problem = .{ .disk = problem } },
    }) orelse return .empty;
    return switch (try checkSchema(&held, arena, found.generation, schema)) {
        .ok => |outcome| .{ .checked = outcome },
        .problem => |problem| .{ .problem = problem },
    };
}

fn failure(held: *store.Store, problem: store.Error) error{OutOfMemory}!Prepare {
    return switch (problem) {
        error.OutOfMemory => error.OutOfMemory,
        error.StoreFailed => .{ .problem = .{ .failed = held.why } },
        else => .{ .problem = .{ .disk = problem } },
    };
}

/// The answer to a load: the entry's text, or none.
pub fn answer(loads: []const Load, request: u32) ?[]const u8 {
    var low: usize = 0;
    var high: usize = loads.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (loads[middle].request < request) low = middle + 1 else if (loads[middle].request > request) high = middle else return loads[middle].text;
    }
    return null;
}

/// `forbic store show DIR`: the active generation of the store of the state directory `path`, one
/// JSON object per line: the generation (its name, number and parent), its schema, and each entry
/// with its object and its text.
pub fn show(io: std.Io, gpa: std.mem.Allocator, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const state = std.Io.Dir.cwd().openDir(io, path, .{}) catch |problem| {
        try err.print("forbic: error: cannot open the state directory {s} ({s})\n", .{ path, @errorName(problem) });
        return 1;
    };
    defer state.close(io);
    var files = Files.open(io, state, false) catch |problem| {
        try err.print("forbic: error: {s} holds no store ({s})\n", .{ path, @errorName(problem) });
        return 1;
    };
    defer files.close(io);
    var held = files.handle(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = held.active(arena) catch |problem| return refused(&held, path, problem, err);
    const current = found orelse {
        try err.print("forbic: the store in {s} has no generation yet\n", .{path});
        return 0;
    };
    try out.print("{{\"generation\":\"{s}\",\"number\":{d},\"parent\":", .{ store.hexOf(current.hash), current.generation.number });
    if (current.generation.parent) |parent| try out.print("\"{s}\"", .{store.hexOf(parent)}) else try out.writeAll("null");
    try out.writeAll("}\n");
    // The schema is an object like any other, and a text that is JSON is shown as such.
    const schema = held.text(.{ .cell = "", .key = "", .object = current.generation.schema }) catch |problem| return refused(&held, path, problem, err);
    defer gpa.free(schema);
    try out.writeAll("{\"schema\":");
    try rawText(out, schema);
    try out.writeAll("}\n");
    for (current.generation.entries) |entry| {
        const text = held.text(entry) catch |problem| return refused(&held, path, problem, err);
        defer gpa.free(text);
        try out.writeAll("{\"entry\":{\"cell\":");
        try std.json.Stringify.encodeJsonString(entry.cell, .{}, out);
        try out.writeAll(",\"key\":");
        try std.json.Stringify.encodeJsonString(entry.key, .{}, out);
        try out.print(",\"object\":\"{s}\",\"value\":", .{store.hexOf(entry.object)});
        try rawText(out, text);
        try out.writeAll("}}\n");
    }
    return 0;
}

/// An entry's text as it is: JSON, written as it was saved (without its newline); anything else as
/// a string.
fn rawText(out: *std.Io.Writer, text: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (std.json.validate(std.heap.page_allocator, trimmed) catch false) return out.writeAll(trimmed);
    try std.json.Stringify.encodeJsonString(text, .{}, out);
}

fn refused(held: *store.Store, path: []const u8, problem: store.Error, err: *std.Io.Writer) !u8 {
    switch (problem) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StoreFailed => try err.print("forbic: error: the store in {s} cannot be read (store_failed): {s}\n", .{ path, held.why }),
        else => try err.print("forbic: error: the store in {s} cannot be read ({s})\n", .{ path, @errorName(problem) }),
    }
    return 1;
}

// ---- Tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// Records the directories synced, by path (with '/' separators), in order.
const SyncLog = struct {
    gpa: std.mem.Allocator,
    paths: std.ArrayList([]u8) = .empty,

    fn directorySync(self: *SyncLog) DirectorySync {
        return .{ .context = self, .call = record };
    }
    fn record(context: ?*anyopaque, io: std.Io, dir: std.Io.Dir) anyerror!void {
        const self: *SyncLog = @ptrCast(@alignCast(context.?));
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try dir.realPath(io, &buffer);
        const copy = try self.gpa.dupe(u8, buffer[0..length]);
        std.mem.replaceScalar(u8, copy, 0x5c, '/');
        try self.paths.append(self.gpa, copy);
    }
    fn deinit(self: *SyncLog) void {
        for (self.paths.items) |path| self.gpa.free(path);
        self.paths.deinit(self.gpa);
    }
    /// The position of the first sync of a directory whose path ends in `suffix`.
    fn first(self: *const SyncLog, suffix: []const u8) ?usize {
        for (self.paths.items, 0..) |path, index| if (std.mem.endsWith(u8, path, suffix)) return index;
        return null;
    }
};

test "a new directory path is made durable from its outermost parent in" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var log: SyncLog = .{ .gpa = testing.allocator };
    defer log.deinit();
    try createDirPathDurable(io, temporary.dir, "a/b/c", log.directorySync());
    // The entries of a, b and c live in the directories above them: the parent of each is synced.
    try testing.expectEqual(@as(usize, 3), log.paths.items.len);
    try testing.expect(!std.mem.endsWith(u8, log.paths.items[0], "/a"));
    try testing.expect(std.mem.endsWith(u8, log.paths.items[1], "/a"));
    try testing.expect(std.mem.endsWith(u8, log.paths.items[2], "/a/b"));
    // A path that is there is not made again; its entry is synced once more, in its parent, for a
    // run that died between making it and syncing it.
    var again: SyncLog = .{ .gpa = testing.allocator };
    defer again.deinit();
    try createDirPathDurable(io, temporary.dir, "a/b/c", again.directorySync());
    try testing.expectEqual(@as(usize, 1), again.paths.items.len);
    try testing.expect(std.mem.endsWith(u8, again.paths.items[0], "/a/b"));
    // A part that is there is kept: only the new directories are synced.
    again.deinit();
    again.paths = .empty;
    try createDirPathDurable(io, temporary.dir, "a/b/d/e", again.directorySync());
    try testing.expectEqual(@as(usize, 2), again.paths.items.len);
    try testing.expect(std.mem.endsWith(u8, again.paths.items[0], "/a/b"));
    try testing.expect(std.mem.endsWith(u8, again.paths.items[1], "/a/b/d"));
    // A file in the way is refused.
    (try temporary.dir.createFile(io, "file", .{})).close(io);
    try testing.expectError(error.NotDir, createDirPathDurable(io, temporary.dir, "file/x", again.directorySync()));
}

test "creating the store makes its directory entries durable, inside out, and a put syncs its directory" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "state");
    const state = try temporary.dir.openDir(io, "state", .{});
    defer state.close(io);
    var log: SyncLog = .{ .gpa = testing.allocator };
    defer log.deinit();
    var files = try Files.openWith(io, state, true, log.directorySync());
    defer files.close(io);
    // The entries of objects, generations and active live in store, and the entry of store lives in
    // the state directory: both are synced before anything is acknowledged, store first.
    const store_at = log.first("/state/store") orelse return error.TestUnexpectedResult;
    const state_at = log.first("/state") orelse return error.TestUnexpectedResult;
    try testing.expect(store_at < state_at);
    // Again for a store that is there: a crash may have cut the first one short.
    const before = log.paths.items.len;
    var second = try Files.openWith(io, state, true, log.directorySync());
    second.close(io);
    try testing.expect(log.paths.items.len > before);
    // Opening without creating makes nothing and syncs nothing.
    const opened = log.paths.items.len;
    var reading = try Files.openWith(io, state, false, log.directorySync());
    reading.close(io);
    try testing.expectEqual(opened, log.paths.items.len);
    // A put syncs the directory of its file.
    var held = files.handle(testing.allocator);
    _ = try held.putObject("{}");
    try testing.expect(std.mem.endsWith(u8, log.paths.items[log.paths.items.len - 1], "/state/store/objects"));
}

test "a store file longer than its place can hold is refused unread, whatever the allocator would give" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "state");
    const state = try temporary.dir.openDir(io, "state", .{});
    defer state.close(io);
    var files = try Files.open(io, state, true);
    defer files.close(io);
    // A pointer far longer than its 65 bytes, and an allocator with nothing to give: the size is
    // checked before an allocation is tried, so the store is refused and not "the disk failed".
    {
        const file = try files.root.createFile(io, store.active_name, .{});
        defer file.close(io);
        try file.setLength(io, 1 << 24);
    }
    var none: [16]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&none);
    var held = files.handle(fixed.allocator());
    try testing.expectError(error.StoreFailed, held.activeName());
    try testing.expectEqualStrings("the file active is not a generation's name", held.why);
    // A generation and an object, one byte over the bound each has.
    const named = store.hashOf("x");
    const name = store.hexOf(named);
    {
        const file = try files.generations.createFile(io, &name, .{});
        defer file.close(io);
        try file.setLength(io, store.max_manifest_bytes + 1);
    }
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.StoreFailed, held.generation(arena_state.allocator(), named));
    try testing.expectEqualStrings("a generation is longer than a manifest can be", held.why);
    {
        const file = try files.objects.createFile(io, &name, .{});
        defer file.close(io);
        try file.setLength(io, store.max_object_bytes + 1);
    }
    try testing.expectError(error.StoreFailed, held.text(.{ .cell = "", .key = "", .object = named }));
    try testing.expectEqualStrings("an object is longer than the store writes", held.why);
    // The disk's own answer: a limit one under the size is TooLarge, at the size the file is read.
    try testing.expectError(error.TooLarge, Files.read(&files, testing.allocator, .objects, &name, store.max_object_bytes));
}

test "a resumed run whose header names a schema other than its program's is refused before the store is made or written" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "state");
    const state = try temporary.dir.openDir(io, "state", .{});
    defer state.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The program's schema: one cell of integers.
    const schema = try forbic.persist_schema.render(arena, .{ .schema = forbic.persist_schema.version, .cells = &.{.{ .cell = ":X", .key = forbic.persist_schema.persistent_key, .value = 0 }}, .types = &.{.{ .primitive = "i64" }} });
    const cells = [_]Cell{.{ .index = 0, .name = ":X" }};
    // c1-2: no store yet; nothing is made.
    const forged: durable.StoreRef = .{ .base = @splat(0), .schema = @splat(0x11) };
    const none = try prepare(io, testing.allocator, arena, state, &cells, schema, &.{}, forged, .{});
    try testing.expect(none.problem == .other_schema);
    try testing.expectError(error.FileNotFound, state.statFile(io, "store", .{}));
    // A store a first run left: its files and `active` are as they were.
    var files = try Files.open(io, state, true);
    defer files.close(io);
    var held = files.handle(testing.allocator);
    const made = try held.putObject(schema);
    const base = (try held.publish(null, made, &.{.{ .cell = ":X", .key = "alice", .text = @constCast("1") }})).?;
    const entry = store.hashOf("1");
    for ([_]store.Hash{ @splat(0x11), entry }) |named| {
        const refusal = try prepare(io, testing.allocator, arena, state, &cells, schema, &.{}, .{ .base = base, .schema = named }, .{});
        try testing.expect(refusal.problem == .other_schema);
        const listed = try state.openDir(io, "store/objects", .{ .iterate = true });
        defer listed.close(io);
        var count: usize = 0;
        var objects = listed.iterate();
        while (try objects.next(io)) |_| count += 1;
        try testing.expectEqual(@as(usize, 2), count);
        try testing.expectEqualSlices(u8, &base, &(try held.activeName()).?);
    }
    // The header's own schema is the program's: the run is prepared on its base.
    const prepared = try prepare(io, testing.allocator, arena, state, &cells, schema, &.{}, .{ .base = base, .schema = made }, .{});
    try testing.expectEqualSlices(u8, &made, &prepared.ok.reference.schema);
}

test "an object that is there but cut short or changed is written again whole" {
    // s5-1: recovery rewrites what a crash damaged by putting it again, so a put that finds a file
    // by its name must not take it for whole.
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "state");
    const state = try temporary.dir.openDir(io, "state", .{});
    defer state.close(io);
    var files = try Files.open(io, state, true);
    defer files.close(io);
    var held = files.handle(testing.allocator);
    const text = "{\"value\":12345}\n";
    const object = try held.putObject(text);
    const name = store.hexOf(object);
    for ([_][]const u8{ "", text[0 .. text.len / 2], "{\"value\":12346}\n" }) |damaged| {
        try files.objects.writeFile(io, .{ .sub_path = &name, .data = damaged });
        try testing.expectError(error.StoreFailed, held.text(.{ .cell = "", .key = "", .object = object }));
        try testing.expectEqualSlices(u8, &object, &(try held.putObject(text)));
        const back = try held.text(.{ .cell = "", .key = "", .object = object });
        defer testing.allocator.free(back);
        try testing.expectEqualStrings(text, back);
    }
}
