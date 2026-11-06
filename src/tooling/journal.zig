//! The host's side of a journaled `forbic` run (RFC-0086, P2.4 and P2.5): the state directory
//! given by `--state DIR`, its lock, the journal file `DIR/journal` on the host's disk, the
//! writers' base copies and their materialisation from the durable prefix (J8), recovery
//! (R1 to R7: what a state directory holds when a run starts, `--resume`, `--abandon`, rotation
//! to `DIR/journal.done`, the readers' cursors), and `forbic journal show`.
//!
//! The format, the run's sink and verify mode are `forbic.durable`'s, which know nothing of files:
//! here a `durable.Disk` is a file. Everything a refusal looks at is read before anything is
//! created or written, so a refused command leaves a state directory as it found it.
const std = @import("std");
const forbic = @import("forbic");
const durable = forbic.durable;
const effects = forbic.effects;
const publication = forbic.publication;
const storage = @import("storage.zig");

/// What the header names as the toolchain that wrote a journal (J1).
pub const toolchain = "forbic 0.0.1 (Forbic pure-core prototype; Zig 0.17.0)";
/// Seals per sync of the tool's journals (J4, Q6): a run that commits often syncs in groups.
pub const sync_group: u32 = 64;
/// What a reader of a journal file holds for one record: the largest any journal may have.
const record_buffer_bytes = durable.max_payload + 4;

/// A journal file on the host's disk: appends go through a buffer to the file's end, a sync
/// writes the buffer out and syncs the file, and a read reads the file where it is told.
pub const FileDisk = struct {
    io: std.Io,
    file: std.Io.File,
    writer: std.Io.File.Writer,

    pub fn init(io: std.Io, file: std.Io.File, buffer: []u8) FileDisk {
        return .{ .io = io, .file = file, .writer = file.writer(io, buffer) };
    }
    pub fn disk(self: *FileDisk) durable.Disk {
        return .{ .context = self, .append = append, .sync = sync, .read = read, .truncate = truncate };
    }
    fn append(context: *anyopaque, parts: []const []const u8) durable.DiskError!void {
        const self: *FileDisk = @ptrCast(@alignCast(context));
        for (parts) |part| self.writer.interface.writeAll(part) catch return error.DiskFailed;
    }
    fn sync(context: *anyopaque) durable.DiskError!void {
        const self: *FileDisk = @ptrCast(@alignCast(context));
        self.writer.interface.flush() catch return error.DiskFailed;
        self.file.sync(self.io) catch return error.DiskFailed;
    }
    fn read(context: *anyopaque, offset: u64, buffer: []u8) durable.DiskError!usize {
        const self: *FileDisk = @ptrCast(@alignCast(context));
        // What is read was synced, so the buffer holds none of it; flushing first keeps a read
        // of anything appended exact all the same.
        self.writer.interface.flush() catch return error.DiskFailed;
        return self.file.readPositionalAll(self.io, buffer, offset) catch error.DiskFailed;
    }
    /// R1: the file ends at `length`, and the next append goes there.
    fn truncate(context: *anyopaque, length: u64) durable.DiskError!void {
        const self: *FileDisk = @ptrCast(@alignCast(context));
        self.writer.interface.flush() catch return error.DiskFailed;
        self.file.setLength(self.io, length) catch return error.DiskFailed;
        self.writer.seekTo(length) catch return error.DiskFailed;
    }
};

/// A file only read: a journal as `journal show`, publication and recovery's checks read it.
const ReadDisk = struct {
    io: std.Io,
    file: std.Io.File,

    fn disk(self: *ReadDisk) durable.Disk {
        return .{ .context = self, .append = refuse, .sync = refuseSync, .read = read, .truncate = refuseTruncate };
    }
    fn refuse(_: *anyopaque, _: []const []const u8) durable.DiskError!void {
        return error.DiskFailed;
    }
    fn refuseSync(_: *anyopaque) durable.DiskError!void {
        return error.DiskFailed;
    }
    fn refuseTruncate(_: *anyopaque, _: u64) durable.DiskError!void {
        return error.DiskFailed;
    }
    fn read(context: *anyopaque, offset: u64, buffer: []u8) durable.DiskError!usize {
        const self: *ReadDisk = @ptrCast(@alignCast(context));
        return self.file.readPositionalAll(self.io, buffer, offset) catch error.DiskFailed;
    }
};

/// Makes a directory's entries durable: a file created or renamed in it (J4, J8). Windows
/// has no such call; there the rename and the file's own sync are what a host can do.
fn syncDirectory(io: std.Io, dir: std.Io.Dir) !void {
    if (@import("builtin").os.tag == .windows) return;
    // A directory opened without `iterate` is an `O_PATH` handle on Linux, which `fsync`
    // refuses (`EBADF`); open it again for reading to sync it.
    const readable = try dir.openDir(io, ".", .{ .iterate = true });
    defer readable.close(io);
    const handle: std.Io.File = .{ .handle = readable.handle, .flags = .{ .nonblocking = false } };
    try handle.sync(io);
}

/// The grants of a run as the tool holds them: the list, and the path each names.
pub const Grants = struct {
    list: []const effects.Grant,
    paths: []const []const u8,
};

/// Who shows the durable prefix of an `eval`: each channel-0 line on standard output (J9). The
/// writers' lines are published at the end (J8), and a `trace` shows no line.
const Shown = struct {
    out: *std.Io.Writer,
    printing: bool,
    failed: bool = false,

    fn show(context: *anyopaque, action: effects.Action) bool {
        const self: *Shown = @ptrCast(@alignCast(context));
        if (!self.printing or action.channel != 0) return true;
        self.out.writeAll(action.text) catch {
            self.failed = true;
            return false;
        };
        self.out.writeByte('\n') catch {
            self.failed = true;
            return false;
        };
        return true;
    }
};

/// RFC-0086, P2.5: what a command asks of a state directory. `start` is a run with neither
/// `--resume` nor `--abandon`: it runs afresh, and refuses an unfinished journal (`run_unfinished`).
pub const Intent = enum { start, resume_run, abandon };

/// A command's request, with the run options it named: a resumed run takes the header's for every
/// one it does not name, and one it names must be the header's (R3).
pub const Request = struct {
    intent: Intent = .start,
    /// SHA-256 of the program's source (the single file, or the bundle packet's bytes); `--abandon`
    /// reads no program.
    program: [32]u8 = @splat(0),
    seed: ?u64 = null,
    random_seed: bool = false,
    tick_rate: ?u64 = null,
    /// The grants the command line named; none is not "no grants" to a resumed run, which takes
    /// the header's.
    grants: Grants = .{ .list = &.{}, .paths = &.{} },
};

/// The run options of a resumed run (R3), its readers' cursors (R6) and what it publishes (J8).
pub const Resumption = struct {
    seed: u64,
    tick_rate: u64,
    grants: Grants,
    /// By grant index: the byte where a reader's next line starts, past its sealed lines; 0 for
    /// a writer.
    cursors: []u64,
};

/// A writer's target as publication sees it (J8). The real path is the file a symbolic link
/// names, so that publication writes through the link rather than replacing it; for a target
/// that does not exist yet, the real path of its directory and its name. Grants whose targets are
/// one file, by inode or by real path, share one base and one publication (H6).
const Target = struct {
    real: []const u8,
    inode: ?std.Io.File.INode,
    /// More than one name: renaming a new file over this one would leave the others on the old
    /// content, so publication writes it in place instead.
    linked: bool,
};

/// What a state directory holds, read without writing anything.
const Found = union(enum) {
    /// No journal, or (`headerless`) one whose first record is no valid header record, which is
    /// no journal (R1, G18).
    none: struct { headerless: bool },
    /// A journal whose prefix ends in `end` or `abandoned` (R2).
    finished: *Survey,
    /// A journal of a run that did not finish (R4, R7a).
    unfinished: *Survey,
    /// Refused, with the refusal already reported.
    refused,
};

/// A journal found in a state directory, and all that a command decides from it before anything
/// is written (G7): the header's grants as the run's, the writers' targets and owners, the writers
/// `--abandon` cannot publish, and a resume's parameters and readers' cursors.
const Survey = struct {
    header: durable.Header,
    scan: durable.Scan,
    grants: Grants,
    bases: [][32]u8,
    owners: []?u32,
    targets: []?Target,
    /// By grant index: why `--abandon` cannot publish a writer (G19), or null.
    unpublishable: []?anyerror,
    resumption: ?Resumption = null,
};

/// One journaled run's state directory, from before the run to after its publication.
pub const Run = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    path: []const u8,
    dir: std.Io.Dir,
    lock: std.Io.File,
    file: ?std.Io.File = null,
    disk: FileDisk = undefined,
    journal: durable.Journal = undefined,
    buffer: []u8 = &.{},
    shown: Shown,
    grants: Grants = .{ .list = &.{}, .paths = &.{} },
    /// By grant index: the writer grant whose target receives this grant's lines (grants that
    /// name one file share it, H6), or none for a reader.
    owners: []?u32 = &.{},
    targets: []?Target = &.{},
    /// By grant index: the SHA-256 of a writer's base (J8), as its header records it.
    bases: [][32]u8 = &.{},
    /// The real path of the state directory, and the name its publications stage under (J8).
    real: []const u8 = "",
    tag: [16]u8 = undefined,
    /// P2.5: the run resumes an unfinished journal (R4).
    resumption: ?Resumption = null,
    found: durable.Scan = .{},
    sealed: ?*durable.SealedInputs = null,
    closed: bool = false,
    /// Why the writers could not be published after the journal ended, if they could not.
    unpublished: ?anyerror = null,
    /// Why the journal, its writers published, could not be rotated (R2), if it could not.
    unrotated: ?anyerror = null,
    /// By grant index, for a journal found in the directory: the writers `--abandon` skips (G19).
    unpublishable: []?anyerror = &.{},
    /// RFC-0087, P5.5 (S6, S7): the store the run started from and the schema of its program, when
    /// it has persistent cells: from the header of a journal found in the directory, or made at the
    /// start. Publication builds the next generation from it.
    store: ?durable.StoreRef = null,
    gpa: std.mem.Allocator = undefined,
    /// Why the store could not be published, when `publishStore` said `StoreFailed`.
    store_why: []const u8 = "",
    /// The error the store's publication ended with, if it did not complete.
    store_problem: ?anyerror = null,

    /// Either a run to start (`start`) or resume (`proceed`), or nothing more to do: the
    /// command's status, its message given.
    pub const Opened = union(enum) { ok: *Run, done: u8 };

    /// Opens `path` for the command's `request` (R1, R2, R3, R6, R7a). Everything a refusal needs
    /// is read first, without writing (G7); then the directory is created if it is missing and its
    /// lock taken, and what it holds is read again under the lock:
    /// - no journal, or one without a valid header record (removed): a run starts afresh;
    ///   `--abandon` has nothing to do;
    /// - a finished journal: its processing is finished (its writers published) and it is rotated
    ///   to `DIR/journal.done`; then a run starts afresh, and `--resume` or `--abandon` run nothing;
    /// - an unfinished journal: refused without `--resume` or `--abandon` (`run_unfinished`);
    ///   resumed after R3's and R6's checks; or abandoned (R7a).
    pub fn open(init: std.process.Init, path: []const u8, request: Request, out: *std.Io.Writer, printing: bool, err: *std.Io.Writer) !Opened {
        const io = init.io;
        const arena = init.arena.allocator();
        // Looked at before anything is created: a refused command writes nothing.
        const peek = try survey(io, arena, path, request, err);
        switch (peek) {
            .refused => return .{ .done = 1 },
            .none => |none| if (request.intent == .abandon and !none.headerless) return nothingToAbandon(err, path),
            else => {},
        }
        storage.createDirPathDurable(io, std.Io.Dir.cwd(), path, .{}) catch |problem| return refuse(err, "forbic: error: cannot use state directory {s} ({s})\n", .{ path, @errorName(problem) });
        const dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |problem| return refuse(err, "forbic: error: cannot use state directory {s} ({s})\n", .{ path, @errorName(problem) });
        // An exclusive lock for the life of the run, as `traverse apply` locks its store.
        const lock = dir.createFile(io, "lock", .{ .truncate = false, .read = true, .lock = .exclusive, .lock_nonblocking = true }) catch |problem| {
            dir.close(io);
            if (problem == error.WouldBlock) return refuse(err, "forbic: error: state directory {s} is in use\n", .{path});
            return refuse(err, "forbic: error: cannot use state directory {s} ({s})\n", .{ path, @errorName(problem) });
        };
        const run = arena.create(Run) catch |problem| {
            lock.close(io);
            dir.close(io);
            return problem;
        };
        run.* = .{ .io = io, .arena = arena, .gpa = init.gpa, .path = path, .dir = dir, .lock = lock, .shown = .{ .out = out, .printing = printing } };
        errdefer run.close();
        var real_bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
        run.real = try arena.dupe(u8, real_bytes[0..try dir.realPath(io, &real_bytes)]);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(run.real, &digest, .{});
        _ = std.fmt.bufPrint(&run.tag, "{x}", .{digest[0..8]}) catch unreachable;
        // Under the lock, what the directory holds decides; it may have changed since the peek.
        switch (try survey(io, arena, path, request, err)) {
            .refused => {
                run.close();
                return .{ .done = 1 };
            },
            .none => |none| {
                if (none.headerless) {
                    // R1: a journal without a valid header is no journal. Nothing of it was visible.
                    dir.deleteFile(io, "journal") catch |problem| {
                        run.close();
                        return refuse(err, "forbic: error: cannot use state directory {s} ({s})\n", .{ path, @errorName(problem) });
                    };
                    try syncDirectory(io, dir);
                }
                if (request.intent == .abandon) {
                    run.close();
                    return nothingToAbandon(err, path);
                }
                // RFC-0087, P5.7 (P12): the store holds the last publication the rotated journal
                // records before a run starts on it.
                if (try run.confirmStore(err)) |status| {
                    run.close();
                    return .{ .done = status };
                }
                return .{ .ok = run };
            },
            .finished => |found| {
                // R2: the processing of a run that finished, which its own end did not complete.
                run.install(found);
                const status = try run.processFinished(err, request.intent == .abandon);
                if (status == 0 and request.intent == .start) return .{ .ok = run };
                run.close();
                if (status != 0 or request.intent == .abandon) return .{ .done = status };
                try err.print("forbic: the run in {s} has finished; nothing runs\n", .{path});
                return .{ .done = 0 };
            },
            .unfinished => |found| {
                run.install(found);
                if (request.intent == .abandon) {
                    const status = try run.abandon(err);
                    run.close();
                    return .{ .done = status };
                }
                std.debug.assert(request.intent == .resume_run and run.resumption != null);
                return .{ .ok = run };
            },
        }
    }

    /// A journal found in the directory, as this run's: its grants, targets, owners and bases
    /// (J8), and a resume's parameters.
    fn install(self: *Run, found: *const Survey) void {
        self.grants = found.grants;
        self.bases = found.bases;
        self.owners = found.owners;
        self.targets = found.targets;
        self.unpublishable = found.unpublishable;
        self.found = found.scan;
        self.resumption = found.resumption;
        self.store = found.header.store;
    }

    fn refuse(err: *std.Io.Writer, comptime format: []const u8, arguments: anytype) !Opened {
        try err.print(format, arguments);
        return .{ .done = 1 };
    }

    fn nothingToAbandon(err: *std.Io.Writer, path: []const u8) !Opened {
        try err.print("forbic: state directory {s} holds no unfinished run\n", .{path});
        return .{ .done = 0 };
    }

    /// A run that starts afresh (F9): creates the journal exclusively, under the lock, copies each
    /// writer's target to its base (J8), and writes the header (J1) and syncs it. Null when the
    /// journal is started; otherwise the refusal's status, reported on `err`, and no journal is
    /// left. A writer's target that does not exist is not created: its base is empty, and
    /// publication creates it.
    pub fn start(self: *Run, program: []const u8, seed: u64, tick_rate: u64, grants: Grants, readers: []const ?std.Io.File.Reader, store: ?durable.StoreRef, err: *std.Io.Writer) !?u8 {
        const io = self.io;
        const arena = self.arena;
        std.debug.assert(self.resumption == null and self.file == null);
        self.grants = grants;
        // Until the header is durable the journal is this run's own: a refusal or an error takes
        // it away again, so that a directory is never left holding a journal with no header.
        errdefer self.discard();
        // Created under the lock, and only if no journal is there: the check is the creation.
        const file = self.dir.createFile(io, "journal", .{ .read = true, .exclusive = true }) catch |problem| {
            self.close();
            if (problem == error.PathAlreadyExists) return try failed(err, "forbic: error: state directory {s} holds an unfinished run (run_unfinished): continue it with --resume, or end it with --abandon\n", .{self.path});
            return try failed(err, "forbic: error: cannot create the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        };
        self.file = file;
        const records = try arena.alloc(durable.GrantRecord, grants.list.len);
        self.bases = try arena.alloc([32]u8, grants.list.len);
        self.copyBases(records, readers) catch |problem| {
            if (problem == error.OutOfMemory) return error.OutOfMemory;
            self.discard();
            return try failed(err, "forbic: error: cannot copy the writers of {s} ({s})\n", .{ self.path, @errorName(problem) });
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(program, &digest, .{});
        self.store = store;
        const header: durable.Header = .{ .toolchain = toolchain, .profile = forbic.profile.active.name, .program = digest, .seed = seed, .tick_rate = tick_rate, .grants = records, .store = store };
        const payload = try durable.encodeHeader(header, try arena.alloc(u8, durable.headerBytes(header)));
        if (payload.len > durable.max_payload) {
            self.discard();
            return try failed(err, "forbic: error: the grants of {s} do not fit a journal's header\n", .{self.path});
        }
        try self.attach(file);
        const started = if (self.journal.start(payload)) |_| syncDirectory(io, self.dir) else |problem| problem;
        started catch |problem| {
            self.discard();
            return try failed(err, "forbic: error: cannot write the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        };
        return null;
    }

    fn failed(err: *std.Io.Writer, comptime format: []const u8, arguments: anytype) !u8 {
        try err.print(format, arguments);
        return 1;
    }

    /// The journal of the run on `file`, its buffers, its group and its consumer.
    fn attach(self: *Run, file: std.Io.File) !void {
        // One buffer for every record a reader of this journal meets, the header included.
        if (self.buffer.len == 0) self.buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
        self.disk = .init(self.io, file, try self.arena.alloc(u8, 64 * 1024));
        self.journal = .init(self.disk.disk(), self.buffer);
        self.journal.group = sync_group;
        self.journal.consumer = .{ .context = &self.shown, .show = Shown.show };
    }

    /// R4: a resumed run's journal, after the tool has re-established its readers (R6): the file
    /// is cut at its durable prefix (R1), its sealed inputs read for the run's prefix (I3) if
    /// `loadSealed` has not, and the journal resumed in verify mode. RFC-0087, P5.7: a run with a
    /// store first publishes what its journal sealed and the last publication did not (S6), and
    /// records it, so that the store holds every sealed write whatever the resumed run does next.
    /// Null when it is ready; otherwise the failure's status.
    pub fn proceed(self: *Run, err: *std.Io.Writer) !?u8 {
        std.debug.assert(self.resumption != null and self.file == null);
        if (try self.loadSealed(err)) |status| return status;
        const file = self.dir.openFile(self.io, "journal", .{ .mode = .read_write }) catch |problem| return try failed(err, "forbic: error: cannot open the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        self.file = file;
        try self.attach(file);
        durable.cutAt(self.disk.disk(), self.found) catch |problem| return try failed(err, "forbic: error: cannot cut the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        if (self.store != null) {
            self.journal.consumer = null;
            self.journal.reopen(self.found);
            self.publishStore() catch |problem| {
                self.store_problem = problem;
                return try failed(err, "forbic: error: the journal in {s} cannot be resumed: its store is not published ({s})\n", .{ self.path, try self.storeReason() });
            };
            // The journal goes on after the record, if one was appended.
            self.found.cut = self.journal.offset;
            self.found.valid = self.journal.offset;
            self.journal = .init(self.disk.disk(), self.buffer);
            self.journal.group = sync_group;
            self.journal.consumer = .{ .context = &self.shown, .show = Shown.show };
        }
        self.journal.resumeAt(self.found);
        return null;
    }

    /// R4, RFC-0087 P5.7 (R8): the inputs of the journal's durable prefix, read without writing, as
    /// the resumed run's prefix: its loads are served from them, so the host reads from the store
    /// only the entries of the loads the journal did not seal. Null when they are read (or were);
    /// otherwise the failure's status.
    pub fn loadSealed(self: *Run, err: *std.Io.Writer) !?u8 {
        std.debug.assert(self.resumption != null);
        if (self.sealed != null) return null;
        const file = self.dir.openFile(self.io, "journal", .{}) catch |problem| return try failed(err, "forbic: error: cannot open the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        defer file.close(self.io);
        var reading: ReadDisk = .{ .io = self.io, .file = file };
        if (self.buffer.len == 0) self.buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
        const sealed = try forbic.scratch.storage(durable.SealedInputs);
        self.sealed = sealed;
        forbic.scratch.initialise(sealed);
        _ = sealed.load(reading.disk(), self.buffer) catch |problem| return try failed(err, "forbic: error: cannot read the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        return null;
    }

    /// The header's grants: a reader's path and whether it can be repositioned (R6), a writer's
    /// target and the SHA-256 of the base copied from it (J8). Grants that name one file, by
    /// whatever path, share one base and one publication; which grant owns which file is written to
    /// `DIR/writers/owners`, so that a recovery can tell that the files are still grouped alike (G20).
    fn copyBases(self: *Run, records: []durable.GrantRecord, readers: []const ?std.Io.File.Reader) !void {
        const io = self.io;
        try self.resolveTargets();
        var made_writers = false;
        for (self.grants.list, self.grants.paths, records, self.owners, self.targets, self.bases, 0..) |grant, path, *record, owner, target, *base, index| {
            record.* = .{ .kind = grant.kind, .name = grant.name, .path = path };
            // RFC-0087, P5.5: a key names no resource: there is nothing to reposition or to copy.
            if (grant.kind == .key) continue;
            if (grant.kind == .reader) {
                if (index < readers.len) if (readers[index]) |reader| {
                    if (!std.mem.eql(u8, path, "-")) {
                        const stat = try reader.file.stat(io);
                        record.repositionable = stat.kind == .file;
                    }
                };
                continue;
            }
            if (owner.? != index) {
                record.base = self.bases[owner.?];
                base.* = record.base;
                continue;
            }
            if (!made_writers) {
                try self.dir.createDirPath(io, "writers");
                made_writers = true;
            }
            var name: [32]u8 = undefined;
            const base_path = try std.fmt.bufPrint(&name, "writers/{d}.base", .{index});
            const copy = try self.dir.createFile(io, base_path, .{});
            defer copy.close(io);
            var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
            // A target that does not exist has an empty base.
            if (target.?.inode != null) {
                const source = try std.Io.Dir.cwd().openFile(io, target.?.real, .{});
                defer source.close(io);
                var chunk: [64 * 1024]u8 = undefined;
                var at: u64 = 0;
                while (true) {
                    const count = try source.readPositionalAll(io, &chunk, at);
                    if (count == 0) break;
                    hash.update(chunk[0..count]);
                    try copy.writePositionalAll(io, chunk[0..count], at);
                    at += count;
                    if (count < chunk.len) break;
                }
            }
            try copy.sync(io);
            hash.final(&record.base);
            base.* = record.base;
        }
        if (made_writers) {
            const owners = try self.dir.createFile(io, "writers/owners", .{});
            defer owners.close(io);
            try owners.writePositionalAll(io, try ownersText(self.arena, self.owners), 0);
            try owners.sync(io);
            const writers = try self.dir.openDir(io, "writers", .{});
            defer writers.close(io);
            try syncDirectory(io, writers);
        }
    }

    /// Each writer's target (`Target`) and owner, for a run that starts afresh.
    fn resolveTargets(self: *Run) !void {
        const io = self.io;
        const count = self.grants.list.len;
        self.owners = try self.arena.alloc(?u32, count);
        self.targets = try self.arena.alloc(?Target, count);
        const lock_stat = try self.lock.stat(io);
        const journal_inode: ?std.Io.File.INode = if (self.dir.statFile(io, "journal", .{})) |stat| stat.inode else |_| null;
        try resolveAll(io, self.arena, self.grants, .{ .real = self.real, .lock = lock_stat.inode, .journal = journal_inode }, self.owners, self.targets, null);
    }

    /// The run ended (J7): appends `end` and syncs, shows what is left of the durable prefix,
    /// publishes the writers (J8), and rotates the journal to `DIR/journal.done` (R2), so that the
    /// next run on the directory starts afresh and no later processing publishes it again. A
    /// journal that failed during the run, or a recovery that diverged, takes no end: what it made
    /// durable stays as it is, for a recovery.
    pub fn finish(self: *Run, end: durable.End) !void {
        try self.journal.finish(end);
        self.publish(self.journal.disk) catch |problem| {
            self.unpublished = problem;
            return error.Unpublished;
        };
        self.rotate() catch |problem| {
            self.unrotated = problem;
            return error.Unrotated;
        };
    }

    /// Whether showing the durable prefix met a standard output that has gone.
    pub fn shownFailed(self: *const Run) bool {
        return self.shown.failed;
    }

    /// R2: a finished journal found by a later command is published again and rotated. Its
    /// channel-0 lines are not shown again: standard output is at most once (J9), and `journal
    /// show` prints them. The command's status: 0 when it was, and otherwise 1, reported, and the
    /// journal left as it is. Under `--abandon` (`skipping`) a writer that cannot be published is
    /// reported and skipped, and the journal is rotated all the same (G19).
    fn processFinished(self: *Run, err: *std.Io.Writer, skipping: bool) !u8 {
        // RFC-0087, P5.7: a journal with a store records its publication, after its end: it is cut
        // first, past a record a crash tore. One without a store is only read, as before.
        const file = self.dir.openFile(self.io, "journal", .{ .mode = if (self.store != null) .read_write else .read_only }) catch |problem| return try failed(err, "forbic: error: cannot open the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        var reading: ReadDisk = .{ .io = self.io, .file = file };
        self.file = file;
        if (self.buffer.len == 0) self.buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
        var disk = reading.disk();
        if (self.store != null) {
            try self.attach(file);
            self.journal.consumer = null;
            durable.cutAt(self.disk.disk(), self.found) catch |problem| return try failed(err, "forbic: error: cannot cut the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
            self.journal.reopen(self.found);
            disk = self.disk.disk();
        }
        if (skipping) {
            const skipped = try self.publishEach(disk, err);
            self.rotate() catch |problem| return try failed(err, "forbic: error: the journal in {s} is finished, but it is not rotated ({s})\n", .{ self.path, @errorName(problem) });
            if (skipped != 0 or self.store_problem != null) return try failed(err, "forbic: the run in {s} had finished; {s}\n", .{ self.path, try self.unpublishedText(skipped) });
            try err.print("forbic: state directory {s} holds no unfinished run\n", .{self.path});
            return 0;
        }
        self.publish(disk) catch |problem| {
            if (self.store_problem != null) return try failed(err, "forbic: error: the journal in {s} is finished; its store is not published ({s})\n", .{ self.path, try self.storeReason() });
            return try failed(err, "forbic: error: the journal in {s} is finished; its writers are not published ({s})\n", .{ self.path, @errorName(problem) });
        };
        self.rotate() catch |problem| return try failed(err, "forbic: error: the journal in {s} is finished and its writers are published, but it is not rotated ({s})\n", .{ self.path, @errorName(problem) });
        return 0;
    }

    /// R7a: the unfinished journal is cut (R1), its writers published from the durable prefix
    /// (J8), and `abandoned` appended and synced; then it is rotated (R2). Nothing runs, and
    /// nothing of the program is read. What the run had not sealed was never visible, and is lost.
    /// A writer that cannot be published (its base gone or changed, its target unusable) is
    /// reported by name and skipped: abandoning always ends the journal, and then exits with 1
    /// (G19).
    fn abandon(self: *Run, err: *std.Io.Writer) !u8 {
        const file = self.dir.openFile(self.io, "journal", .{ .mode = .read_write }) catch |problem| return try failed(err, "forbic: error: cannot open the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        self.file = file;
        try self.attach(file);
        // Shown nothing again (J9).
        self.journal.consumer = null;
        durable.cutAt(self.disk.disk(), self.found) catch |problem| return try failed(err, "forbic: error: cannot cut the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        // RFC-0087, P5.7 (R9): the record of the store's publication goes before `abandoned`.
        self.journal.reopen(self.found);
        const skipped = try self.publishEach(self.disk.disk(), err);
        self.journal.abandon() catch |problem| return try failed(err, "forbic: error: the run in {s} is not abandoned ({s})\n", .{ self.path, @errorName(problem) });
        self.rotate() catch |problem| return try failed(err, "forbic: error: the run in {s} is abandoned; its journal is not rotated ({s})\n", .{ self.path, @errorName(problem) });
        if (skipped != 0 or self.store_problem != null) return try failed(err, "forbic: the run in {s} is abandoned; {s}\n", .{ self.path, try self.unpublishedText(skipped) });
        try err.print("forbic: the run in {s} is abandoned\n", .{self.path});
        return 0;
    }

    /// G19: each writer published that can be; one that cannot is reported and skipped. The count
    /// of those skipped.
    fn publishEach(self: *Run, disk: durable.Disk, err: *std.Io.Writer) !u32 {
        var skipped: u32 = 0;
        // RFC-0087, P5.5 (R9): the sealed store actions are published, with the schema of the header.
        self.publishStore() catch |problem| {
            self.store_problem = problem;
            try err.print("forbic: error: the store of the run in {s} is not published ({s})\n", .{ self.path, try self.storeReason() });
        };
        for (self.grants.list, self.owners, 0..) |grant, owner, index| {
            if (grant.kind != .writer or owner == null or owner.? != index) continue;
            const reason = self.unpublishable[index] orelse if (self.publishWriter(disk, @intCast(index))) |_| continue else |problem| problem;
            try err.print("forbic: error: writer {s} of the run in {s} is not published ({s})\n", .{ grant.name, self.path, @errorName(reason) });
            skipped += 1;
        }
        return skipped;
    }

    /// R2: the finished journal becomes `DIR/journal.done`, replacing an older one, and the
    /// directory is synced: the next run creates its own.
    fn rotate(self: *Run) !void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
        try self.dir.rename("journal", self.dir, "journal.done", self.io);
        try syncDirectory(self.io, self.dir);
    }

    /// J8: each writer's target becomes its base followed by the durable lines of its channels,
    /// in sequence order. A function of the base and the durable prefix, so repeating it writes
    /// the same file. Staged under a name of this state directory's own (`PATH.TAG.tmp`, so that
    /// runs of two directories that publish one target never share it), synced, and renamed over
    /// the target's real path, through a symbolic link; a target with more than one name is
    /// written in place instead, which keeps it one file. A base that is not the one the header
    /// records is not published (`BaseChanged`): every base is checked whole before any target is
    /// written (G9).
    pub fn publish(self: *Run, disk: durable.Disk) !void {
        for (self.grants.list, self.owners, self.bases, 0..) |grant, owner, expected, index| {
            if (grant.kind != .writer or owner == null or owner.? != index) continue;
            try self.checkBase(@intCast(index), expected);
        }
        for (self.grants.list, self.owners, self.bases, 0..) |grant, owner, expected, index| {
            if (grant.kind != .writer or owner == null or owner.? != index) continue;
            try self.writeTarget(disk, @intCast(index), expected);
        }
        // RFC-0087, P5.5 (S6): and the store.
        self.publishStore() catch |problem| {
            self.store_problem = problem;
            return error.StoreUnpublished;
        };
    }

    /// What publication left undone, for a message: the writers skipped and the store.
    pub fn unpublishedText(self: *Run, skipped: u32) ![]const u8 {
        if (self.store_problem == null) return std.fmt.allocPrint(self.arena, "{d} of its writers are not published", .{skipped});
        if (skipped == 0) return "its store is not published";
        return std.fmt.allocPrint(self.arena, "{d} of its writers and its store are not published", .{skipped});
    }

    /// Why the store's publication did not complete, as a message's parenthesis.
    pub fn storeReason(self: *const Run) ![]const u8 {
        const problem = self.store_problem orelse return "";
        if (self.store_why.len == 0) return @errorName(problem);
        return std.fmt.allocPrint(self.arena, "{s}: {s}", .{ @errorName(problem), self.store_why });
    }

    /// RFC-0087, P5.5 (S6), P5.7: the store actions of the journal's durable prefix that follow its
    /// last `published` record (or all of them, after the generation the run started from), the
    /// last of each entry, become the generation after that record's, and `active` names it; then
    /// a `published` record of it is appended to the journal and synced. A function of the base and
    /// the prefix, so repeating it after a crash writes the same files and records the same
    /// generation. A run with no persistent cell has no store; one whose prefix holds nothing new
    /// publishes nothing and records nothing (P5.6: a schema other than its base's is something).
    /// `self.journal` lies after the journal's cut: the live journal at the end of a run, or one
    /// reopened.
    pub fn publishStore(self: *Run) !void {
        const reference = self.store orelse return;
        var files = try storage.Files.open(self.io, self.dir, true);
        defer files.close(self.io);
        var store = files.handle(self.gpa);
        var planned = publication.plan(self.gpa, &store, self.journal.disk, self.buffer, reference) catch |problem| return self.storeFailed(&store, problem);
        defer planned.deinit();
        const made = (publication.apply(&planned, &store) catch |problem| return self.storeFailed(&store, problem)) orelse return;
        self.journal.recordPublished(.{ .generation = made, .through = planned.through }) catch |problem| {
            self.store_why = "the journal cannot record its publication";
            return problem;
        };
    }

    fn storeFailed(self: *Run, store: *forbic.store.Store, problem: anyerror) anyerror {
        self.store_why = if (problem == error.ActiveMoved) "another publication has moved its active generation" else store.why;
        return problem;
    }

    /// RFC-0087, P5.7 (P12): before a run starts afresh on a store, the last publication the rotated
    /// journal (`DIR/journal.done`) records is what `active` names. Where a crash lost the
    /// replacement of `active`, or the generation it names, and kept the rotation that followed it
    /// (a file system that does not order its metadata, G22), `active` is behind on that journal's
    /// chain: the chain is written again from the journal and `active` made its last
    /// (`publication.confirm`). A rotated journal without a store or a record, of a header this
    /// build cannot read, or whose chain is not its publications (`StoreFailed`) tells nothing, and
    /// an `active` outside the chain was moved by another publication: the run starts as it would
    /// have. Only a header with a store makes the journal be read whole. Null when the run may
    /// start; otherwise the status of a disk that failed, reported.
    fn confirmStore(self: *Run, err: *std.Io.Writer) !?u8 {
        const io = self.io;
        _ = self.dir.statFile(io, "store/generations", .{}) catch |problem| {
            if (problem == error.FileNotFound) return null;
            return try failed(err, "forbic: error: the store in {s} cannot be used ({s})\n", .{ self.path, @errorName(problem) });
        };
        const file = self.dir.openFile(io, "journal.done", .{}) catch |problem| {
            if (problem == error.FileNotFound) return null;
            return try failed(err, "forbic: error: cannot read the journal in {s} ({s})\n", .{ self.path, @errorName(problem) });
        };
        defer file.close(io);
        var reading: ReadDisk = .{ .io = io, .file = file };
        if (self.buffer.len == 0) self.buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
        var reader: durable.Reader = .{ .disk = reading.disk(), .buffer = self.buffer };
        const item = (reader.next() catch |problem| return try self.unconfirmed(err, problem)) orelse return null;
        if (item.kind != .header) return null;
        const payload = try self.arena.dupe(u8, item.payload);
        const summary = durable.summarizeHeader(payload) catch return null;
        if (summary.grants > effects.grant_capacity) return null;
        const records = try self.arena.alloc(durable.GrantRecord, summary.grants);
        const header = durable.decodeHeader(payload, records) catch return null;
        const reference = header.store orelse return null;
        var files = storage.Files.open(io, self.dir, false) catch |problem| return try failed(err, "forbic: error: the store in {s} cannot be used ({s})\n", .{ self.path, @errorName(problem) });
        defer files.close(io);
        var store = files.handle(self.gpa);
        _ = publication.confirm(self.gpa, &store, reading.disk(), self.buffer, reference) catch |problem| switch (problem) {
            error.StoreFailed, error.ActiveMoved => return null,
            else => |other| return try self.unconfirmed(err, other),
        };
        return null;
    }

    fn unconfirmed(self: *Run, err: *std.Io.Writer, problem: anyerror) !u8 {
        if (problem == error.OutOfMemory) return error.OutOfMemory;
        return try failed(err, "forbic: error: the store in {s} cannot be brought up to the publication its last journal records ({s})\n", .{ self.path, @errorName(problem) });
    }

    /// One writer's publication, its base checked first.
    fn publishWriter(self: *Run, disk: durable.Disk, index: u32) !void {
        try self.checkBase(index, self.bases[index]);
        try self.writeTarget(disk, index, self.bases[index]);
    }

    fn checkBase(self: *Run, index: u32, expected: [32]u8) !void {
        var name: [32]u8 = undefined;
        const digest = try baseDigest(self.io, self.dir, try std.fmt.bufPrint(&name, "writers/{d}.base", .{index}));
        if (!std.mem.eql(u8, &digest, &expected)) return error.BaseChanged;
    }

    /// The target of writer `index` becomes its base and its durable lines. A staging file left by
    /// an error is removed.
    fn writeTarget(self: *Run, disk: durable.Disk, index: u32, expected: [32]u8) !void {
        const io = self.io;
        const target = self.targets[index].?;
        var name: [32]u8 = undefined;
        const base_path = try std.fmt.bufPrint(&name, "writers/{d}.base", .{index});
        const base = try self.dir.openFile(io, base_path, .{});
        defer base.close(io);
        var temporary_name: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temporary_name, "{s}.{s}.tmp", .{ target.real, &self.tag });
        // A target with other names is rewritten where it lies; any other is staged.
        const in_place = target.linked and target.inode != null;
        const staged = if (in_place) try std.Io.Dir.cwd().openFile(io, target.real, .{ .mode = .read_write }) else try std.Io.Dir.cwd().createFile(io, temporary, .{});
        errdefer if (!in_place) std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        {
            defer staged.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var writer = staged.writer(io, &buffer);
            var chunk: [64 * 1024]u8 = undefined;
            var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
            var at: u64 = 0;
            while (true) {
                const count = try base.readPositionalAll(io, &chunk, at);
                if (count == 0) break;
                hash.update(chunk[0..count]);
                try writer.interface.writeAll(chunk[0..count]);
                at += count;
                if (count < chunk.len) break;
            }
            // Checked before the copy too; a base that changed during it is not published.
            var digest: [32]u8 = undefined;
            hash.final(&digest);
            if (!std.mem.eql(u8, &digest, &expected)) return error.BaseChanged;
            at += try durable.writePublished(disk, self.buffer, self.owners, index, &writer.interface);
            try writer.interface.flush();
            if (in_place) try staged.setLength(io, at);
            try staged.sync(io);
        }
        if (in_place) return;
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), target.real, io);
        const parent = std.fs.path.dirname(target.real) orelse ".";
        const directory = try std.Io.Dir.cwd().openDir(io, parent, .{});
        defer directory.close(io);
        try syncDirectory(io, directory);
    }

    /// Closes what `open` opened, the lock last. A second call does nothing.
    pub fn close(self: *Run) void {
        if (self.closed) return;
        self.closed = true;
        if (self.sealed) |sealed| forbic.scratch.release(sealed);
        self.sealed = null;
        if (self.buffer.len != 0) forbic.scratch.free(self.buffer);
        self.buffer = &.{};
        if (self.file) |file| file.close(self.io);
        self.file = null;
        self.lock.close(self.io);
        self.dir.close(self.io);
    }

    /// A run refused before its header was durable: its journal is removed, under the lock, and
    /// what `open` opened is closed. The writers' bases it copied stay; the next run copies them
    /// again.
    fn discard(self: *Run) void {
        if (self.closed) return;
        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
            self.dir.deleteFile(self.io, "journal") catch {};
        }
        self.close();
    }
};

/// A writer's target (`Target`): its real path when it exists, else its directory's real path and
/// its name. A target that names a directory, or whose directory does not exist, is an error.
fn resolveTarget(io: std.Io, arena: std.mem.Allocator, path: []const u8) !Target {
    var bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().realPathFile(io, path, &bytes)) |length| {
        const real = try arena.dupe(u8, bytes[0..length]);
        const stat = try std.Io.Dir.cwd().statFile(io, real, .{});
        if (stat.kind == .directory) return error.IsDir;
        return .{ .real = real, .inode = stat.inode, .linked = stat.nlink > 1 };
    } else |problem| {
        if (problem != error.FileNotFound) return problem;
        const parent = std.fs.path.dirname(path) orelse ".";
        const length = try std.Io.Dir.cwd().realPathFile(io, parent, &bytes);
        return .{ .real = try std.fs.path.join(arena, &.{ bytes[0..length], std.fs.path.basename(path) }), .inode = null, .linked = false };
    }
}

/// What a writer's target must not be: in the state directory (`real`, its real path, empty where
/// it does not exist yet), or its lock or journal by another name.
const StateFiles = struct {
    real: []const u8,
    lock: ?std.Io.File.INode,
    journal: ?std.Io.File.INode,
};

/// Each writer's target (`Target`) and owner: grants whose targets are one file, by inode or by
/// real path, share the first one's (H6). A target in the state directory, or one that is the
/// journal or the lock by another name, would be overwritten by publication:
/// `WriterInStateDirectory`. With `problems`, a target that cannot be used is recorded there and
/// owns itself; without, it is the error.
fn resolveAll(io: std.Io, arena: std.mem.Allocator, grants: Grants, state: StateFiles, owners: []?u32, targets: []?Target, problems: ?[]?anyerror) !void {
    for (grants.list, grants.paths, owners, targets, 0..) |grant, path, *owner, *target, index| {
        owner.* = null;
        target.* = null;
        if (grant.kind != .writer) continue;
        const resolved = usableTarget(io, arena, path, state) catch |problem| {
            if (problem == error.OutOfMemory) return error.OutOfMemory;
            const list = problems orelse return problem;
            list[index] = problem;
            owner.* = @intCast(index);
            continue;
        };
        target.* = resolved;
        const shared: ?usize = for (targets[0..index], 0..) |earlier, at| {
            const other = earlier orelse continue;
            if (sameFile(other, resolved)) break at;
        } else null;
        owner.* = if (shared) |at| owners[at] else @intCast(index);
    }
}

fn usableTarget(io: std.Io, arena: std.mem.Allocator, path: []const u8, state: StateFiles) !Target {
    const resolved = try resolveTarget(io, arena, path);
    const real = state.real;
    if (real.len != 0 and std.mem.startsWith(u8, resolved.real, real) and resolved.real.len > real.len and std.fs.path.isSep(resolved.real[real.len])) return error.WriterInStateDirectory;
    if (resolved.inode) |inode| {
        if (state.lock != null and inode == state.lock.?) return error.WriterInStateDirectory;
        if (state.journal != null and inode == state.journal.?) return error.WriterInStateDirectory;
    }
    return resolved;
}

fn sameFile(a: Target, b: Target) bool {
    if (a.inode != null and b.inode != null) return a.inode.? == b.inode.?;
    return std.mem.eql(u8, a.real, b.real);
}

/// G20: `DIR/writers/owners`, a line per grant: the index of the writer grant that owns its target,
/// or `-` for a reader.
fn ownersText(arena: std.mem.Allocator, owners: []const ?u32) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    for (owners) |owner| {
        if (owner) |at| try text.writer.print("{d}\n", .{at}) else try text.writer.writeAll("-\n");
    }
    return text.written();
}

/// Whether the owners `DIR/writers/owners` records are `owners`: the targets are grouped as when
/// the run started. A file that is missing or cannot be read is not.
fn ownersRecorded(io: std.Io, arena: std.mem.Allocator, path: []const u8, owners: []const ?u32) !bool {
    const expected = try ownersText(arena, owners);
    const bytes = try arena.alloc(u8, expected.len + 1);
    var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&name, "{s}/writers/owners", .{path}) catch return false;
    const recorded = std.Io.Dir.cwd().readFile(io, file, bytes) catch return false;
    return std.mem.eql(u8, recorded, expected);
}

/// The real path of the state directory `path`, or, where it does not exist, its parent's real
/// path and its name; empty where neither exists.
fn stateReal(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var bytes: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().openDir(io, path, .{})) |dir| {
        defer dir.close(io);
        return arena.dupe(u8, bytes[0..try dir.realPath(io, &bytes)]);
    } else |_| {}
    const parent = std.fs.path.dirname(path) orelse ".";
    const length = std.Io.Dir.cwd().realPathFile(io, parent, &bytes) catch return "";
    return std.fs.path.join(arena, &.{ bytes[0..length], std.fs.path.basename(path) });
}

fn stateFiles(io: std.Io, arena: std.mem.Allocator, path: []const u8) !StateFiles {
    var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lock = std.fmt.bufPrint(&name, "{s}/lock", .{path}) catch return error.NameTooLong;
    const lock_inode: ?std.Io.File.INode = if (std.Io.Dir.cwd().statFile(io, lock, .{})) |stat| stat.inode else |_| null;
    const journal = std.fmt.bufPrint(&name, "{s}/journal", .{path}) catch return error.NameTooLong;
    const journal_inode: ?std.Io.File.INode = if (std.Io.Dir.cwd().statFile(io, journal, .{})) |stat| stat.inode else |_| null;
    return .{ .real = try stateReal(io, arena, path), .lock = lock_inode, .journal = journal_inode };
}

/// What `path` holds for `request`, read without writing anything; a refusal is reported on `err`.
/// Every check a refusal can come from is made here, so that a refused command leaves the
/// directory as it found it (G7): R3, R6, the writers' targets and owners, their bases, and what a
/// finished journal may publish to (G21).
fn survey(io: std.Io, arena: std.mem.Allocator, path: []const u8, request: Request, err: *std.Io.Writer) !Found {
    var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal = std.fmt.bufPrint(&name, "{s}/journal", .{path}) catch {
        try err.print("forbic: error: cannot use state directory {s} (NameTooLong)\n", .{path});
        return .refused;
    };
    const file = std.Io.Dir.cwd().openFile(io, journal, .{}) catch |problem| {
        if (problem == error.FileNotFound) return fresh(io, arena, path, request, false, err);
        try err.print("forbic: error: cannot use state directory {s} ({s})\n", .{ path, @errorName(problem) });
        return .refused;
    };
    defer file.close(io);
    var reading: ReadDisk = .{ .io = io, .file = file };
    const buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
    defer forbic.scratch.free(buffer);
    const found = durable.scan(reading.disk(), buffer) catch |problem| {
        try err.print("forbic: error: cannot read the journal in {s} ({s})\n", .{ path, @errorName(problem) });
        return .refused;
    };
    // R1, G18: only a file whose first record is no whole header record is no journal.
    if (!found.has_header) return fresh(io, arena, path, request, true, err);
    const finished = found.finished();
    if (!finished and request.intent == .start) {
        try err.print("forbic: error: state directory {s} holds an unfinished run (run_unfinished): continue it with --resume, or end it with --abandon\n", .{path});
        return .refused;
    }
    const verb: []const u8 = if (finished) "processed" else if (request.intent == .abandon) "abandoned" else "resumed";
    // The header's slices borrow the payload, which the buffer is about to lose.
    var reader: durable.Reader = .{ .disk = reading.disk(), .buffer = buffer };
    const item = (reader.next() catch null) orelse {
        try err.print("forbic: error: cannot read the journal in {s} (DiskFailed)\n", .{path});
        return .refused;
    };
    const payload = try arena.dupe(u8, item.payload);
    // G18: a header this build cannot hold is another build's, never no journal.
    const summary = durable.summarizeHeader(payload) catch return refusal(err, path, verb, "its header cannot be read by this build", .{});
    const resuming = request.intent == .resume_run and !finished;
    if (resuming and !std.mem.eql(u8, summary.toolchain, toolchain)) return anotherRun(err, path, .toolchain);
    if ((resuming or finished) and !std.mem.eql(u8, summary.profile, forbic.profile.active.name)) {
        if (resuming) return anotherRun(err, path, .profile);
        return refusal(err, path, verb, "it is of the {s} profile, and this build is of the {s} profile", .{ summary.profile, forbic.profile.active.name });
    }
    if (summary.grants > effects.grant_capacity) return refusal(err, path, verb, "it names {d} grants, and this build holds at most {d}", .{ summary.grants, effects.grant_capacity });
    const records = try arena.alloc(durable.GrantRecord, summary.grants);
    const header = durable.decodeHeader(payload, records) catch return refusal(err, path, verb, "its header cannot be read by this build", .{});
    if (request.intent == .resume_run) {
        // R3: nothing runs before the header is found to be this run's. A finished journal
        // resumed with grants takes them only if they are its own.
        const given = request.grants.list.len != 0;
        if (finished) {
            if (given and !sameGrants(header.grants, request.grants)) return anotherRun(err, path, .grants);
        } else {
            const expected_grants = try arena.alloc(durable.GrantRecord, if (given) request.grants.list.len else header.grants.len);
            if (given) {
                for (request.grants.list, request.grants.paths, expected_grants) |grant, grant_path, *record| record.* = .{ .kind = grant.kind, .name = grant.name, .path = grant_path };
            } else @memcpy(expected_grants, header.grants);
            const expected: durable.Header = .{
                .toolchain = toolchain,
                .profile = forbic.profile.active.name,
                .program = request.program,
                .seed = request.seed orelse header.seed,
                .tick_rate = request.tick_rate orelse header.tick_rate,
                .grants = expected_grants,
            };
            const differs: ?durable.Mismatch = if (request.random_seed) .seed else durable.mismatch(header, expected);
            if (differs) |field| return anotherRun(err, path, field);
        }
    }
    // The header's grants as the run's, copied out of the buffer.
    const count = header.grants.len;
    const found_survey = try arena.create(Survey);
    const list = try arena.alloc(effects.Grant, count);
    const paths = try arena.alloc([]const u8, count);
    found_survey.* = .{
        .header = header,
        .scan = found,
        .grants = .{ .list = list, .paths = paths },
        .bases = try arena.alloc([32]u8, count),
        .owners = try arena.alloc(?u32, count),
        .targets = try arena.alloc(?Target, count),
        .unpublishable = try arena.alloc(?anyerror, count),
    };
    @memset(found_survey.unpublishable, null);
    var writers: usize = 0;
    for (header.grants, list, paths, found_survey.bases) |grant, *entry, *grant_path, *base| {
        entry.* = .{ .kind = grant.kind, .name = try arena.dupe(u8, grant.name) };
        grant_path.* = try arena.dupe(u8, grant.path);
        base.* = grant.base;
        if (grant.kind == .writer) writers += 1;
    }
    const s = found_survey;
    // `--abandon` always ends the journal: a writer it cannot publish is skipped (G19). Any other
    // command is refused where a writer cannot be published.
    const skipping = request.intent == .abandon;
    const state = stateFiles(io, arena, path) catch |problem| {
        try err.print("forbic: error: cannot use state directory {s} ({s})\n", .{ path, @errorName(problem) });
        return .refused;
    };
    resolveAll(io, arena, s.grants, state, s.owners, s.targets, if (skipping) s.unpublishable else null) catch |problem| {
        if (problem == error.OutOfMemory) return error.OutOfMemory;
        try err.print("forbic: error: cannot use the writers of the journal in {s} ({s})\n", .{ path, @errorName(problem) });
        return .refused;
    };
    // G20: the targets are grouped into files as they were when the run started.
    if (writers != 0 and !try ownersRecorded(io, arena, path, s.owners)) {
        if (!skipping) return refusal(err, path, verb, "its writers' files are not the ones its run started with", .{});
        for (s.grants.list, s.unpublishable) |grant, *reason| {
            if (grant.kind == .writer and reason.* == null) reason.* = error.WritersChanged;
        }
    }
    // G21: the finished journal of a command without `--resume` or `--abandon` is published only to
    // targets the command grants itself, under the same names.
    if (finished and request.intent == .start) for (s.grants.list, s.targets) |grant, target| {
        if (grant.kind != .writer) continue;
        const granted = for (request.grants.list, request.grants.paths) |mine, mine_path| {
            if (mine.kind == .writer and std.mem.eql(u8, mine.name, grant.name)) break mine_path;
        } else null;
        const same = if (granted) |mine_path| if (resolveTarget(io, arena, mine_path)) |resolved| sameFile(resolved, target.?) else |_| false else false;
        if (!same) return refusal(err, path, verb, "this command does not grant its writer {s} the same file: grant it, or end the run with --abandon", .{grant.name});
    };
    // J8, G9: each writer's base is still the one the header records.
    for (s.grants.list, s.owners, s.bases, s.unpublishable, 0..) |grant, owner, expected, *reason, index| {
        if (grant.kind != .writer or owner == null or owner.? != index or reason.* != null) continue;
        const problem: ?anyerror = if (baseOf(io, path, index)) |digest| (if (std.mem.eql(u8, &digest, &expected)) null else error.BaseChanged) else |problem| problem;
        const why = problem orelse continue;
        if (skipping) {
            reason.* = why;
            continue;
        }
        if (why == error.BaseChanged) return refusal(err, path, verb, "the base of writer {s} is not the one its journal records", .{grant.name});
        return refusal(err, path, verb, "the base of writer {s} cannot be read ({s})", .{ grant.name, @errorName(why) });
    }
    if (finished) return .{ .finished = s };
    if (request.intent == .resume_run) s.resumption = (try resumption(io, arena, path, header, found, s.grants, err)) orelse return .refused;
    return .{ .unfinished = s };
}

/// A directory with no journal, or none but a file without a valid header record: a run starts
/// afresh in it. Its writers' targets are checked first, as the run's start checks them again under
/// the lock, so that a refused run creates nothing.
fn fresh(io: std.Io, arena: std.mem.Allocator, path: []const u8, request: Request, headerless: bool, err: *std.Io.Writer) !Found {
    if (request.intent != .abandon and request.grants.list.len != 0) {
        const state = try stateFiles(io, arena, path);
        const owners = try arena.alloc(?u32, request.grants.list.len);
        const targets = try arena.alloc(?Target, request.grants.list.len);
        resolveAll(io, arena, request.grants, state, owners, targets, null) catch |problem| {
            if (problem == error.OutOfMemory) return error.OutOfMemory;
            try err.print("forbic: error: cannot copy the writers of {s} ({s})\n", .{ path, @errorName(problem) });
            return .refused;
        };
    }
    return .{ .none = .{ .headerless = headerless } };
}

/// Whether `grants` are the header's own list (R3): kind, name and path as written, in order.
fn sameGrants(recorded: []const durable.GrantRecord, grants: Grants) bool {
    if (recorded.len != grants.list.len) return false;
    for (recorded, grants.list, grants.paths) |a, b, b_path| {
        if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.path, b_path)) return false;
    }
    return true;
}

fn anotherRun(err: *std.Io.Writer, path: []const u8, field: durable.Mismatch) !Found {
    try err.print("forbic: error: the journal in {s} is of another run (recovery_mismatch): its {s} differs\n", .{ path, switch (field) {
        .toolchain => "toolchain",
        .profile => "profile",
        .program => "program",
        .seed => "seed",
        .tick_rate => "tick rate",
        .grants => "list of grants",
    } });
    return .refused;
}

fn refusal(err: *std.Io.Writer, path: []const u8, verb: []const u8, comptime format: []const u8, arguments: anytype) !Found {
    try err.print("forbic: error: the journal in {s} cannot be {s} (recovery_mismatch): " ++ format ++ "\n", .{ path, verb } ++ arguments);
    return .refused;
}

/// The SHA-256 of `DIR/writers/INDEX.base`.
fn baseOf(io: std.Io, path: []const u8, index: usize) ![32]u8 {
    var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_path = std.fmt.bufPrint(&name, "{s}/writers/{d}.base", .{ path, index }) catch return error.NameTooLong;
    return baseDigest(io, std.Io.Dir.cwd(), base_path);
}

/// R3, R6: what a resumed run takes from its header and the cursors of its readers. Null when it
/// cannot be resumed: the refusal is reported (`recovery_mismatch`).
fn resumption(io: std.Io, arena: std.mem.Allocator, path: []const u8, header: durable.Header, found: durable.Scan, grants: Grants, err: *std.Io.Writer) !?Resumption {
    const cursors = try arena.alloc(u64, header.grants.len);
    @memset(cursors, 0);
    // R6: a reader that cannot be repositioned (a pipe, standard input) cannot be resumed.
    const files = try arena.alloc(?std.Io.File, header.grants.len);
    @memset(files, null);
    defer for (files) |file| if (file) |opened| opened.close(io);
    for (header.grants, files) |grant, *file| {
        if (grant.kind != .reader) continue;
        if (!grant.repositionable) return mismatchOf(err, path, "reader {s} cannot be repositioned: abandon the run with --abandon", .{grant.name});
        const opened = std.Io.Dir.cwd().openFile(io, grant.path, .{}) catch |problem| return mismatchOf(err, path, "reader {s} cannot be opened ({s})", .{ grant.name, @errorName(problem) });
        file.* = opened;
        const stat = opened.stat(io) catch |problem| return mismatchOf(err, path, "reader {s} cannot be opened ({s})", .{ grant.name, @errorName(problem) });
        if (stat.kind != .file) return mismatchOf(err, path, "reader {s} cannot be repositioned: abandon the run with --abandon", .{grant.name});
    }
    // The bytes of each reader's sealed lines, each with its newline (the last one's only if the
    // file has it), must be the file's from its start: a file that differs changed since.
    var journal_name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal = std.fmt.bufPrint(&journal_name, "{s}/journal", .{path}) catch unreachable;
    const file = try std.Io.Dir.cwd().openFile(io, journal, .{});
    defer file.close(io);
    var reading: ReadDisk = .{ .io = io, .file = file };
    const buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
    defer forbic.scratch.free(buffer);
    const line = forbic.scratch.alloc(u8, effects.input_byte_capacity + 1) orelse return error.OutOfMemory;
    defer forbic.scratch.free(line);
    var prefix = durable.Prefix.init(reading.disk(), buffer) catch |problem| return mismatchOf(err, path, "its journal cannot be read ({s})", .{@errorName(problem)});
    prefix.cut = found.cut;
    while (prefix.next() catch |problem| return mismatchOf(err, path, "its journal cannot be read ({s})", .{@errorName(problem)})) |record| switch (record.decoded) {
        .input => |input| {
            if (input.kind != .line or input.status != .value) continue;
            if (input.request >= header.grants.len or header.grants[input.request].kind != .reader) return mismatchOf(err, path, "its journal reads a grant that is no reader", .{});
            // No run of this build reads a longer line; one in the journal is another build's.
            if (input.bytes.len > effects.input_byte_capacity) return mismatchOf(err, path, "its journal holds a line of {d} bytes, and this build reads at most {d}", .{ input.bytes.len, effects.input_byte_capacity });
            const reader = files[input.request].?;
            const at = cursors[input.request];
            const count = reader.readPositionalAll(io, line[0 .. input.bytes.len + 1], at) catch |problem| return mismatchOf(err, path, "reader {s} cannot be read ({s})", .{ header.grants[input.request].name, @errorName(problem) });
            const whole = count >= input.bytes.len and std.mem.eql(u8, line[0..input.bytes.len], input.bytes);
            const ends = count == input.bytes.len or (count == input.bytes.len + 1 and line[input.bytes.len] == '\n');
            if (!whole or !ends) return mismatchOf(err, path, "reader {s} has changed since the run read it", .{header.grants[input.request].name});
            cursors[input.request] = at + count;
        },
        else => {},
    };
    return .{ .seed = header.seed, .tick_rate = header.tick_rate, .grants = grants, .cursors = cursors };
}

fn mismatchOf(err: *std.Io.Writer, path: []const u8, comptime format: []const u8, arguments: anytype) !?Resumption {
    try err.print("forbic: error: the journal in {s} cannot be resumed (recovery_mismatch): " ++ format ++ "\n", .{path} ++ arguments);
    return null;
}

fn baseDigest(io: std.Io, dir: std.Io.Dir, base_path: []const u8) ![32]u8 {
    const base = try dir.openFile(io, base_path, .{});
    defer base.close(io);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    var at: u64 = 0;
    while (true) {
        const count = try base.readPositionalAll(io, &chunk, at);
        if (count == 0) break;
        hash.update(chunk[0..count]);
        at += count;
        if (count < chunk.len) break;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

// ---- forbic journal show -------------------------------------------------------------------

/// `forbic journal show DIR`: the durable prefix of `DIR/journal`, one JSON object per line: the
/// header, then each input, action, seal and the end, in order. What follows the last seal or
/// end is not shown: no reader ever sees it (J4). A directory whose last run finished and was
/// rotated (R2) shows `DIR/journal.done`.
pub fn show(io: std.Io, arena: std.mem.Allocator, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var name: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const journal = std.fmt.bufPrint(&name, "{s}/journal", .{path}) catch {
        try err.print("forbic: error: cannot open journal {s}/journal (NameTooLong)\n", .{path});
        return 1;
    };
    var done_name: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(io, journal, .{}) catch |problem| rotated: {
        if (problem == error.FileNotFound) {
            const done = std.fmt.bufPrint(&done_name, "{s}.done", .{journal}) catch unreachable;
            if (std.Io.Dir.cwd().openFile(io, done, .{})) |found| break :rotated found else |_| {}
        }
        try err.print("forbic: error: cannot open journal {s} ({s})\n", .{ journal, @errorName(problem) });
        return 1;
    };
    defer file.close(io);
    var reading: ReadDisk = .{ .io = io, .file = file };
    const buffer = forbic.scratch.alloc(u8, record_buffer_bytes) orelse return error.OutOfMemory;
    defer forbic.scratch.free(buffer);
    return write(reading.disk(), buffer, arena, journal, out, err) catch |problem| switch (problem) {
        error.DiskFailed, error.RecordTooLarge => {
            try err.print("forbic: error: cannot read journal {s} ({s})\n", .{ journal, @errorName(problem) });
            return 1;
        },
        else => |other| return other,
    };
}

fn write(disk: durable.Disk, buffer: []u8, arena: std.mem.Allocator, journal: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var prefix = try durable.Prefix.init(disk, buffer);
    const first = (try prefix.next()) orelse return noJournal(journal, err);
    // G18: a header of more grants than this build holds is another build's, not no journal.
    const summary = durable.summarizeHeader(first.item.payload) catch return noJournal(journal, err);
    if (summary.grants > effects.grant_capacity) {
        try err.print("forbic: error: journal {s} names {d} grants, and this build holds at most {d}\n", .{ journal, summary.grants, effects.grant_capacity });
        return 1;
    }
    const grants = try arena.alloc(durable.GrantRecord, summary.grants);
    const header = durable.decodeHeader(first.item.payload, grants) catch {
        try err.print("forbic: error: the header of journal {s} cannot be read by this build\n", .{journal});
        return 1;
    };
    try out.writeAll("{\"header\":{\"toolchain\":");
    try string(out, header.toolchain);
    try out.writeAll(",\"profile\":");
    try string(out, header.profile);
    try out.writeAll(",\"program\":");
    try hex(out, &header.program);
    try out.print(",\"seed\":{d},\"tick_rate\":{d},\"grants\":[", .{ header.seed, header.tick_rate });
    for (header.grants, 0..) |grant, index| {
        if (index != 0) try out.writeByte(',');
        try out.print("{{\"kind\":\"{t}\",\"name\":", .{grant.kind});
        try string(out, grant.name);
        // RFC-0087, P5.5: a key names no resource.
        if (grant.kind == .key) {
            try out.writeByte('}');
            continue;
        }
        try out.writeAll(",\"path\":");
        try string(out, grant.path);
        if (grant.kind == .reader) {
            try out.print(",\"repositionable\":{s}}}", .{if (grant.repositionable) "true" else "false"});
        } else {
            try out.writeAll(",\"base\":");
            try hex(out, &grant.base);
            try out.writeByte('}');
        }
    }
    try out.writeByte(']');
    // RFC-0087, P5.5 (S7): the generation the run started from, and its program's schema.
    if (header.store) |store| {
        try out.writeAll(",\"store\":{\"base\":");
        if (std.mem.allEqual(u8, &store.base, 0)) try out.writeAll("null") else try hex(out, &store.base);
        try out.writeAll(",\"schema\":");
        try hex(out, &store.schema);
        try out.writeByte('}');
    }
    try out.writeAll("}}\n");
    while (try prefix.next()) |record| switch (record.decoded) {
        .header => unreachable,
        .input => |input| {
            try out.print("{{\"input\":{{\"sequence\":{d},\"kind\":\"{t}\",\"request\":{d},\"tick\":{d},\"status\":\"{t}\"", .{ input.sequence, input.kind, input.request, input.tick, input.status });
            switch (input.kind) {
                .clock => {
                    try out.writeAll(",\"value\":");
                    try number(out, @bitCast(input.bits));
                },
                // A line that is not text (I6: the run refused it) is shown by its bytes.
                .line => if (input.status == .value) {
                    if (std.unicode.utf8ValidateSlice(input.bytes)) {
                        try out.writeAll(",\"line\":");
                        try string(out, input.bytes);
                    } else {
                        try out.writeAll(",\"bytes\":");
                        try hex(out, input.bytes);
                    }
                },
                // RFC-0087, P5.5: the text of an entry, as the store held it.
                .load => if (input.status == .value) {
                    try out.writeAll(",\"text\":");
                    try string(out, input.bytes);
                },
            }
            try out.writeAll("}}\n");
        },
        .action => |action| {
            try out.print("{{\"action\":{{\"sequence\":{d},\"channel\":{d},\"text\":", .{ action.sequence, action.channel });
            try string(out, action.text);
            try out.writeAll("}}\n");
        },
        .seal => |seal| try out.print("{{\"seal\":{{\"actions\":{d},\"inputs\":{d}}}}}\n", .{ seal.actions, seal.inputs }),
        .end => |end| switch (end.outcome) {
            .completed => try out.writeAll("{\"end\":{\"outcome\":\"completed\"}}\n"),
            .fatal => {
                try out.writeAll("{\"end\":{\"outcome\":\"fatal\",\"code\":");
                try string(out, end.code);
                try out.print(",\"start\":{d},\"end\":{d}}}}}\n", .{ end.start, end.end });
            },
        },
        .abandoned => try out.writeAll("{\"abandoned\":{}}\n"),
        // RFC-0087, P5.7: a publication of the store.
        .published => |published| {
            try out.writeAll("{\"published\":{\"generation\":");
            try hex(out, &published.generation);
            try out.print(",\"through\":{d}}}}}\n", .{published.through});
        },
    };
    return 0;
}

fn noJournal(journal: []const u8, err: *std.Io.Writer) !u8 {
    try err.print("forbic: error: {s} is no journal (it has no valid header)\n", .{journal});
    return 1;
}

/// A JSON string of text. A byte of a path that is not UTF-8 (a host's file name can be any
/// bytes) is shown as the escape of its value, so that every byte is seen.
fn string(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('"');
    const text = std.unicode.utf8ValidateSlice(bytes);
    for (bytes) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print("\\u{x:0>4}", .{byte}),
        else => if (byte >= 0x80 and !text) try out.print("\\u{x:0>4}", .{byte}) else try out.writeByte(byte),
    };
    try out.writeByte('"');
}

/// A reading as a JSON number, or as the string a value report gives a value that is no number.
fn number(out: *std.Io.Writer, value: f64) !void {
    if (std.math.isNan(value)) return out.writeAll("\"NaN\"");
    if (std.math.isInf(value)) return out.writeAll(if (value > 0) "\"Inf\"" else "\"-Inf\"");
    try out.print("{d}", .{value});
}

/// Bytes as a JSON string of lowercase hexadecimal digits.
fn hex(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('"');
    for (bytes) |byte| try out.print("{x:0>2}", .{byte});
    try out.writeByte('"');
}

// ---- Tests --------------------------------------------------------------------------------

/// A state directory for a test, its writers' targets beside it.
const Fixture = struct {
    temporary: std.testing.TmpDir,
    at: []const u8,
    directory: [std.Io.Dir.max_path_bytes]u8 = undefined,
    names: [12][std.Io.Dir.max_path_bytes + 16]u8 = undefined,
    arena: std.heap.ArenaAllocator,

    fn create(self: *Fixture) !void {
        self.temporary = std.testing.tmpDir(.{});
        self.arena = .init(std.testing.allocator);
        self.at = self.directory[0..try self.temporary.dir.realPath(std.testing.io, &self.directory)];
    }
    fn destroy(self: *Fixture) void {
        self.arena.deinit();
        self.temporary.cleanup();
    }
    fn init(self: *Fixture) std.process.Init {
        return .{ .minimal = undefined, .arena = &self.arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = undefined, .preopens = undefined };
    }
    fn path(self: *Fixture, index: usize, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&self.names[index], "{s}/{s}", .{ self.at, name });
    }
    fn read(self: *Fixture, name: []const u8, buffer: []u8) ![]const u8 {
        return self.temporary.dir.readFile(std.testing.io, name, buffer);
    }
    fn missing(self: *Fixture, name: []const u8) !void {
        try std.testing.expectError(error.FileNotFound, self.temporary.dir.statFile(std.testing.io, name, .{}));
    }
};

/// A run on `state` that starts afresh, of a program whose source is `program`.
fn openRunOf(init: std.process.Init, state: []const u8, program: []const u8, list: Grants, readers: []const ?std.Io.File.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !*Run {
    const run = switch (try Run.open(init, state, .{ .grants = list }, out, true, err)) {
        .ok => |run| run,
        .done => return error.Refused,
    };
    errdefer run.close();
    if (try run.start(program, 7, 60, list, readers, null, err) != null) return error.Refused;
    return run;
}

fn openRun(init: std.process.Init, state: []const u8, list: Grants, out: *std.Io.Writer, err: *std.Io.Writer) !*Run {
    return openRunOf(init, state, "Value:i64 = 1", list, &.{}, out, err);
}

/// An effect log for a test, journaled by `run`.
fn testLog(run: *Run) !*effects.Log {
    const log = try forbic.scratch.storage(effects.Log);
    forbic.scratch.initialise(log);
    log.sink = run.journal.sink();
    log.inputs.journal = run.journal.inputJournal();
    log.reset(false);
    return log;
}

test "writers are their base and the durable lines of their channels, published again after a crash to the same file" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    const log_path = try fixture.path(0, "log.txt");
    const same_path = try fixture.path(1, "./log.txt");
    const fresh_path = try fixture.path(2, "sub/fresh.txt");
    const twin_path = try fixture.path(4, "sub/./fresh.txt");
    try fixture.temporary.dir.createDirPath(io, "sub");
    const state = try fixture.path(3, "state");
    // Two writers of one file, by two paths, and two of one whose target does not exist yet.
    const list = [_]effects.Grant{ .{ .kind = .writer, .name = "log" }, .{ .kind = .writer, .name = "audit" }, .{ .kind = .writer, .name = "fresh" }, .{ .kind = .writer, .name = "twin" } };
    const paths = [_][]const u8{ log_path, same_path, fresh_path, twin_path };
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
    defer run.close();
    try std.testing.expectEqualStrings("", message.buffered());
    // The missing target is not created before publication: its base is empty (F11).
    try fixture.missing("sub/fresh.txt");
    const log = try testLog(run);
    defer forbic.scratch.release(log);
    try log.prepareOn(1, "one");
    log.begin();
    try log.prepareOn(2, "two");
    try log.prepare("shown");
    try log.prepareOn(3, "three");
    try log.prepareOn(4, "twin");
    try log.commit();
    log.begin();
    try log.prepareOn(1, "never");
    log.abort();
    try log.prepareOn(1, "four");
    // A crash now: nothing was published. What a later publication writes depends only on the
    // base and the journal's durable prefix, so repeating it, torn tails and all, changes nothing.
    try run.disk.writer.interface.flush();
    try run.publish(run.journal.disk);
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("earlier\none\ntwo\nfour\n", try fixture.read("log.txt", &bytes));
    try std.testing.expectEqualStrings("three\ntwin\n", try fixture.read("sub/fresh.txt", &bytes));
    try run.publish(run.journal.disk);
    try std.testing.expectEqualStrings("earlier\none\ntwo\nfour\n", try fixture.read("log.txt", &bytes));
    // Staged under this directory's own name, and none left behind.
    var staged_name: [64]u8 = undefined;
    try fixture.missing(try std.fmt.bufPrint(&staged_name, "log.txt.{s}.tmp", .{&run.tag}));
    try fixture.missing("log.txt.tmp");
    // The bases: one per file, named by the grant that owns it.
    try std.testing.expectEqualStrings("earlier\n", try fixture.read("state/writers/0.base", &bytes));
    try std.testing.expectEqualStrings("", try fixture.read("state/writers/2.base", &bytes));
    try fixture.missing("state/writers/1.base");
    try fixture.missing("state/writers/3.base");
    // A torn record after the last seal is no part of the prefix: publishing again changes nothing.
    try run.disk.writer.interface.writeAll(&.{ 40, 0, 0, 0, 3, 1, 2 });
    try run.disk.writer.interface.flush();
    try run.publish(run.journal.disk);
    try std.testing.expectEqualStrings("earlier\none\ntwo\nfour\n", try fixture.read("log.txt", &bytes));
    // The line shown on standard output comes from the durable prefix, once, at the end's sync.
    try std.testing.expectEqualStrings("", out.buffered());
    // The torn bytes go before the end is appended, as a recovery's cut would take them.
    try run.disk.writer.seekTo(run.journal.offset);
    try run.disk.file.setLength(io, run.journal.offset);
    try run.finish(.{ .outcome = .completed });
    try std.testing.expectEqualStrings("shown\n", out.buffered());
    try std.testing.expectEqualStrings("earlier\none\ntwo\nfour\n", try fixture.read("log.txt", &bytes));
    try std.testing.expectEqualStrings("three\ntwin\n", try fixture.read("sub/fresh.txt", &bytes));
    // The finished journal was rotated (R2): the next run starts afresh, and `journal show` shows
    // the finished one.
    try fixture.missing("state/journal");
    var long_out: [4096]u8 = undefined;
    var shown: std.Io.Writer = .fixed(&long_out);
    try std.testing.expectEqual(@as(u8, 0), try show(io, fixture.arena.allocator(), state, &shown, &message));
    try std.testing.expect(std.mem.endsWith(u8, shown.buffered(), "{\"end\":{\"outcome\":\"completed\"}}\n"));
}

test "a state directory is locked for its run, and one that holds an unfinished journal is refused untouched" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    const state = try fixture.path(0, "state");
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    // A directory whose lock another holds is in use.
    try fixture.temporary.dir.createDirPath(io, "state");
    const held = try fixture.temporary.dir.createFile(io, "state/lock", .{ .truncate = false, .lock = .exclusive });
    try std.testing.expectError(error.Refused, openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state is in use\n"));
    held.close(io);
    try fixture.missing("state/journal");
    message = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message);
    // While it runs, a second run on the directory is refused: by its unfinished journal.
    try std.testing.expectError(error.Refused, openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message));
    run.close();
    // Without its lock file the directory is refused all the same, and nothing is created in it.
    try fixture.temporary.dir.deleteFile(io, "state/lock");
    var before: [1024]u8 = undefined;
    const kept = try fixture.read("state/journal", &before);
    message = .fixed(&err_bytes);
    try std.testing.expectError(error.Refused, openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state holds an unfinished run (run_unfinished): continue it with --resume, or end it with --abandon\n"));
    try fixture.missing("state/lock");
    var after: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(kept, try fixture.read("state/journal", &after));
    // `journal show` of the unfinished journal: its header, and nothing sealed.
    var long_out: [2048]u8 = undefined;
    var shown: std.Io.Writer = .fixed(&long_out);
    try std.testing.expectEqual(@as(u8, 0), try show(io, fixture.arena.allocator(), state, &shown, &message));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, shown.buffered(), "\n"));
}

test "journal show prints a journal cut at its last seal, and refuses one whose header is torn" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    const state = try fixture.path(0, "state");
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message);
    const log = try testLog(run);
    defer forbic.scratch.release(log);
    try log.prepare("a \"quoted\"\tline\x01");
    log.begin();
    try log.prepare("pending");
    try run.disk.writer.interface.flush();
    const header_end = run.journal.shown;
    run.close();
    var long_out: [4096]u8 = undefined;
    var shown: std.Io.Writer = .fixed(&long_out);
    try std.testing.expectEqual(@as(u8, 0), try show(io, fixture.arena.allocator(), state, &shown, &message));
    try std.testing.expectEqualStrings("{\"action\":{\"sequence\":0,\"channel\":0,\"text\":\"a \\\"quoted\\\"\\tline\\u0001\"}}\n{\"seal\":{\"actions\":1,\"inputs\":0}}\n", shown.buffered()[std.mem.indexOfScalar(u8, shown.buffered(), '\n').? + 1 ..]);
    // A header cut short: no journal.
    const file = try fixture.temporary.dir.openFile(io, "state/journal", .{ .mode = .read_write });
    try file.setLength(io, header_end - 1);
    file.close(io);
    message = .fixed(&err_bytes);
    shown = .fixed(&long_out);
    try std.testing.expectEqual(@as(u8, 1), try show(io, fixture.arena.allocator(), state, &shown, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "is no journal (it has no valid header)\n"));
    try std.testing.expectEqualStrings("", shown.buffered());
    // R1: a run on the directory removes what is no journal and starts afresh; `--abandon` finds
    // nothing to abandon there, and nothing at all where there is no directory.
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 0 }, try Run.open(fixture.init(), state, .{ .intent = .abandon }, &out, true, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state holds no unfinished run\n"));
    try fixture.missing("state/journal");
    const nowhere = try fixture.path(1, "nowhere");
    try std.testing.expectEqual(Run.Opened{ .done = 0 }, try Run.open(fixture.init(), nowhere, .{ .intent = .abandon }, &out, true, &message));
    try fixture.missing("nowhere");
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = "not a journal" });
    const again = try openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message);
    again.close();
    var bytes: [1024]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try fixture.read("state/journal", &bytes), durable.magic) != null);
}

test "every diagnostic code fits an end record" {
    inline for (comptime std.meta.fieldNames(forbic.types.Diagnostic.Code)) |field| {
        comptime std.debug.assert(field.len <= durable.max_code_bytes);
    }
}

test "a writer in the state directory, or that is its journal or lock, and a state path that is a file, are refused and leave nothing" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    const state = try fixture.path(0, "state");
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    try fixture.temporary.dir.createDirPath(io, "state/writers");
    const missing_target = try fixture.path(5, "new.txt");
    for ([_][]const u8{ "state/journal", "state/lock", "state/writers/0.base", "state/journal.done" }, 1..) |name, index| {
        var message: std.Io.Writer = .fixed(&err_bytes);
        const target = try fixture.path(index, name);
        // A writer whose target does not exist comes first: it is not created by a refused run.
        const list = [_]effects.Grant{ .{ .kind = .writer, .name = "fresh" }, .{ .kind = .writer, .name = "log" } };
        try std.testing.expectError(error.Refused, openRun(fixture.init(), state, .{ .list = &list, .paths = &.{ missing_target, target } }, &out, &message));
        try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "WriterInStateDirectory") != null);
        // Refused before anything is created (G7): no journal, no lock, no target.
        try fixture.missing("state/journal");
        try fixture.missing("state/lock");
        try fixture.missing("new.txt");
    }
    var message: std.Io.Writer = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), state, .{ .list = &.{}, .paths = &.{} }, &out, &message);
    run.close();
    run.close();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    const file = try fixture.path(4, "file");
    message = .fixed(&err_bytes);
    try std.testing.expectError(error.Refused, openRun(fixture.init(), file, .{ .list = &.{}, .paths = &.{} }, &out, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "cannot use state directory") != null);
}

test "a finished journal whose publication was cut short is published and rotated by the next command, and resuming it runs nothing" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    const state = try fixture.path(0, "state");
    const list = [_]effects.Grant{.{ .kind = .writer, .name = "log" }};
    const paths = [_][]const u8{try fixture.path(1, "log.txt")};
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    var bytes: [256]u8 = undefined;
    for ([_]Intent{ .resume_run, .start }) |intent| {
        const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
        const log = try testLog(run);
        defer forbic.scratch.release(log);
        try log.prepareOn(1, "line");
        try log.prepare("shown once");
        // The end is durable; the process stops before its publication.
        try run.journal.finish(.{ .outcome = .completed });
        run.close();
        const published = try fixture.read("log.txt", &bytes);
        const before = try fixture.arena.allocator().dupe(u8, published);
        var request: Request = .{ .intent = intent };
        if (intent == .start) {
            // G21: a command without `--resume` or `--abandon` publishes a finished journal only
            // to the files it grants itself under the same names; otherwise it is refused untouched.
            try fixture.temporary.dir.deleteFile(io, "state/lock");
            var kept: [1024]u8 = undefined;
            const journal_bytes = try fixture.arena.allocator().dupe(u8, try fixture.read("state/journal", &kept));
            try fixture.temporary.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "" });
            const other_paths = [_][]const u8{try fixture.path(2, "other.txt")};
            const renamed = [_]effects.Grant{.{ .kind = .writer, .name = "audit" }};
            for ([_]Grants{ .{ .list = &.{}, .paths = &.{} }, .{ .list = &list, .paths = &other_paths }, .{ .list = &renamed, .paths = &paths } }) |grants| {
                message = .fixed(&err_bytes);
                try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .grants = grants }, &out, true, &message));
                try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state cannot be processed (recovery_mismatch): this command does not grant its writer log the same file: grant it, or end the run with --abandon\n"));
                try std.testing.expectEqualStrings(journal_bytes, try fixture.read("state/journal", &kept));
                try std.testing.expectEqualStrings(before, try fixture.read("log.txt", &bytes));
                try fixture.missing("state/lock");
            }
            request.grants = .{ .list = &list, .paths = &paths };
        }
        out = .fixed(&out_bytes);
        message = .fixed(&err_bytes);
        const opened = try Run.open(fixture.init(), state, request, &out, true, &message);
        // Its writers are published, its channel-0 lines not shown again (J9), and it is rotated.
        var expected: [256]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}line\n", .{before}), try fixture.read("log.txt", &bytes));
        try std.testing.expectEqualStrings("", out.buffered());
        try fixture.missing("state/journal");
        _ = try fixture.temporary.dir.statFile(io, "state/journal.done", .{});
        switch (intent) {
            .resume_run => {
                try std.testing.expectEqual(Run.Opened{ .done = 0 }, opened);
                try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state has finished; nothing runs\n"));
            },
            else => {
                // A run starts afresh after it.
                try std.testing.expect(opened == .ok);
                if (try opened.ok.start("Value:i64 = 1", 7, 60, .{ .list = &list, .paths = &paths }, &.{}, null, &message) != null) return error.Refused;
                opened.ok.close();
                try fixture.temporary.dir.deleteFile(io, "state/journal");
            },
        }
    }
}

test "abandoning an unfinished run publishes what it sealed, ends its journal and rotates it, and runs nothing" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    const state = try fixture.path(0, "state");
    const list = [_]effects.Grant{ .{ .kind = .reader, .name = "in" }, .{ .kind = .writer, .name = "log" } };
    const paths = [_][]const u8{ "-", try fixture.path(1, "log.txt") };
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
    const log = try testLog(run);
    defer forbic.scratch.release(log);
    try log.prepareOn(2, "sealed");
    log.begin();
    try log.prepareOn(2, "unsealed");
    try log.prepare("pending");
    // The run stops with the region open: its tail is on the disk, unsealed.
    try run.disk.writer.interface.flush();
    run.close();
    message = .fixed(&err_bytes);
    // A reader of standard input cannot be repositioned: the run cannot be resumed (R6).
    try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = programDigest("Value:i64 = 1") }, &out, true, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "cannot be resumed (recovery_mismatch): reader in cannot be repositioned: abandon the run with --abandon\n"));
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 0 }, try Run.open(fixture.init(), state, .{ .intent = .abandon }, &out, true, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state is abandoned\n"));
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("sealed\n", try fixture.read("log.txt", &bytes));
    try std.testing.expectEqualStrings("", out.buffered());
    try fixture.missing("state/journal");
    var long_out: [4096]u8 = undefined;
    var shown: std.Io.Writer = .fixed(&long_out);
    try std.testing.expectEqual(@as(u8, 0), try show(io, fixture.arena.allocator(), state, &shown, &message));
    try std.testing.expect(std.mem.endsWith(u8, shown.buffered(), "{\"action\":{\"sequence\":0,\"channel\":2,\"text\":\"sealed\"}}\n{\"seal\":{\"actions\":1,\"inputs\":0}}\n{\"abandoned\":{}}\n"));
    // Nothing is left to abandon; a run starts afresh.
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 0 }, try Run.open(fixture.init(), state, .{ .intent = .abandon }, &out, true, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state holds no unfinished run\n"));
}

fn programDigest(program: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(program, &digest, .{});
    return digest;
}

test "a resume is refused untouched when its program, parameters, grants, readers or bases are not the journal's, and given its readers' cursors otherwise" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "config.txt", .data = "alpha\nbeta\ngamma" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    const state = try fixture.path(0, "state");
    const config = try fixture.path(1, "config.txt");
    const log_path = try fixture.path(2, "log.txt");
    const list = [_]effects.Grant{ .{ .kind = .reader, .name = "config" }, .{ .kind = .writer, .name = "log" } };
    const paths = [_][]const u8{ config, log_path };
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const program = "Value:i64 = 2";
    {
        const file = try std.Io.Dir.cwd().openFile(io, config, .{});
        defer file.close(io);
        var buffer: [64]u8 = undefined;
        const readers = [_]?std.Io.File.Reader{ file.reader(io, &buffer), null };
        const run = try openRunOf(fixture.init(), state, program, .{ .list = &list, .paths = &paths }, &readers, &out, &message);
        defer run.close();
        const log = try testLog(run);
        defer forbic.scratch.release(log);
        const lines = [_][]const u8{ "alpha", "beta", "gamma" };
        var script: effects.Script = .{ .streams = &.{&lines} };
        log.inputs.source = script.source();
        _ = try log.inputs.read(.{ .kind = .line, .request = 0 });
        try log.prepareOn(2, "after alpha");
        // A line read and not sealed: not part of the cursor.
        _ = try log.inputs.read(.{ .kind = .line, .request = 0 });
        try run.disk.writer.interface.flush();
    }
    var kept: [4096]u8 = undefined;
    const journal_bytes = try fixture.arena.allocator().dupe(u8, try fixture.read("state/journal", &kept));
    // G7: a refusal creates nothing, not even the lock file.
    try fixture.temporary.dir.deleteFile(io, "state/lock");
    const Case = struct { request: Request, says: []const u8 };
    const other_list = [_]effects.Grant{.{ .kind = .reader, .name = "config" }};
    const cases = [_]Case{
        .{ .request = .{ .intent = .resume_run, .program = programDigest("Value:i64 = 3") }, .says = "of another run (recovery_mismatch): its program differs" },
        .{ .request = .{ .intent = .resume_run, .program = programDigest(program), .seed = 8 }, .says = "its seed differs" },
        .{ .request = .{ .intent = .resume_run, .program = programDigest(program), .random_seed = true }, .says = "its seed differs" },
        .{ .request = .{ .intent = .resume_run, .program = programDigest(program), .tick_rate = 30 }, .says = "its tick rate differs" },
        .{ .request = .{ .intent = .resume_run, .program = programDigest(program), .grants = .{ .list = &other_list, .paths = paths[0..1] } }, .says = "its list of grants differs" },
    };
    for (cases) |case| {
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, case.request, &out, true, &message));
        errdefer std.debug.print("{s}\n", .{message.buffered()});
        try std.testing.expect(std.mem.indexOf(u8, message.buffered(), case.says) != null);
        try std.testing.expectEqualStrings(journal_bytes, try fixture.read("state/journal", &kept));
        try fixture.missing("state/lock");
    }
    // The same parameters named again are the journal's.
    message = .fixed(&err_bytes);
    const same = try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = programDigest(program), .seed = 7, .tick_rate = 60, .grants = .{ .list = &list, .paths = &paths } }, &out, true, &message);
    try std.testing.expect(same == .ok);
    // R6: the reader reads on past its one sealed line and its newline.
    try std.testing.expectEqualSlices(u64, &.{ 6, 0 }, same.ok.resumption.?.cursors);
    try std.testing.expectEqual(@as(u64, 7), same.ok.resumption.?.seed);
    same.ok.close();
    // A reader whose sealed bytes changed, a base that is not the one recorded, and writers whose
    // files are not grouped as they were (G20).
    for ([_][2][]const u8{ .{ "config.txt", "alphb\nbeta\n" }, .{ "config.txt", "alpha" }, .{ "config.txt", "alphabet\n" }, .{ "state/writers/1.base", "later\n" }, .{ "state/writers/owners", "-\n0\n" } }, 0..) |change, index| {
        fixture.temporary.dir.deleteFile(io, "state/lock") catch {};
        var saved: [64]u8 = undefined;
        const original = try fixture.arena.allocator().dupe(u8, try fixture.read(change[0], &saved));
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = change[0], .data = change[1] });
        message = .fixed(&err_bytes);
        const opened = try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = programDigest(program) }, &out, true, &message);
        if (index == 1) {
            // The last sealed line without its newline is the file's last line: the same bytes.
            try std.testing.expect(opened == .ok);
            try std.testing.expectEqualSlices(u64, &.{ 5, 0 }, opened.ok.resumption.?.cursors);
            opened.ok.close();
        } else {
            try std.testing.expectEqual(Run.Opened{ .done = 1 }, opened);
            const says = switch (index) {
                3 => "cannot be resumed (recovery_mismatch): the base of writer log is not the one its journal records",
                4 => "cannot be resumed (recovery_mismatch): its writers' files are not the ones its run started with",
                else => "cannot be resumed (recovery_mismatch): reader config has changed since the run read it",
            };
            try std.testing.expect(std.mem.indexOf(u8, message.buffered(), says) != null);
            try fixture.missing("state/lock");
        }
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = change[0], .data = original });
        try std.testing.expectEqualStrings(journal_bytes, try fixture.read("state/journal", &kept));
    }
    // Proceeding cuts the unsealed tail and serves the sealed line as the run's prefix.
    message = .fixed(&err_bytes);
    const resumed = (try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = programDigest(program) }, &out, true, &message)).ok;
    defer resumed.close();
    try std.testing.expectEqual(@as(?u8, null), try resumed.proceed(&message));
    try std.testing.expectEqual(@as(usize, 1), resumed.sealed.?.record().entries.len);
    try std.testing.expectEqualStrings("alpha", resumed.sealed.?.record().bytes);
    try std.testing.expect(resumed.journal.verifying());
    try std.testing.expect((try fixture.temporary.dir.statFile(io, "state/journal", .{})).size < journal_bytes.len);
}

test "two state directories that publish one target stage it under names of their own, and a link is written through" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "shared.txt", .data = "" });
    const list = [_]effects.Grant{.{ .kind = .writer, .name = "log" }};
    const paths = [_][]const u8{try fixture.path(0, "shared.txt")};
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const first = try openRun(fixture.init(), try fixture.path(1, "one"), .{ .list = &list, .paths = &paths }, &out, &message);
    defer first.close();
    const second = try openRun(fixture.init(), try fixture.path(2, "two"), .{ .list = &list, .paths = &paths }, &out, &message);
    defer second.close();
    try std.testing.expect(!std.mem.eql(u8, &first.tag, &second.tag));
    // A symbolic link to the target, and a second name of it, where the host can make them.
    const linked = linked: {
        fixture.temporary.dir.symLink(io, "shared.txt", "link.txt", .{}) catch break :linked false;
        break :linked true;
    };
    if (!linked) return error.SkipZigTest;
    const link_list = [_]effects.Grant{.{ .kind = .writer, .name = "log" }};
    const link_paths = [_][]const u8{try fixture.path(3, "link.txt")};
    const third = try openRun(fixture.init(), try fixture.path(4, "three"), .{ .list = &link_list, .paths = &link_paths }, &out, &message);
    defer third.close();
    const log = try testLog(third);
    defer forbic.scratch.release(log);
    try log.prepareOn(1, "through the link");
    try third.publish(third.journal.disk);
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("through the link\n", try fixture.read("shared.txt", &bytes));
    var target: [256]u8 = undefined;
    _ = try fixture.temporary.dir.readLink(io, "link.txt", &target);
}

test "a target with a second name is published in place, so that both names see it" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "old\n" });
    fixture.temporary.dir.hardLink("a.txt", fixture.temporary.dir, "b.txt", io, .{}) catch return error.SkipZigTest;
    const list = [_]effects.Grant{.{ .kind = .writer, .name = "log" }};
    const paths = [_][]const u8{try fixture.path(0, "a.txt")};
    var out_bytes: [256]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), try fixture.path(1, "state"), .{ .list = &list, .paths = &paths }, &out, &message);
    defer run.close();
    const log = try testLog(run);
    defer forbic.scratch.release(log);
    try log.prepareOn(1, "new");
    try run.publish(run.journal.disk);
    try run.publish(run.journal.disk);
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("old\nnew\n", try fixture.read("a.txt", &bytes));
    try std.testing.expectEqualStrings("old\nnew\n", try fixture.read("b.txt", &bytes));
    // G9: a base changed past the first chunk a copy reads is found before the target, written in
    // place, is touched.
    const changed = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(changed);
    @memset(changed, 'x');
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/writers/0.base", .data = changed });
    try std.testing.expectError(error.BaseChanged, run.publish(run.journal.disk));
    try std.testing.expectEqualStrings("old\nnew\n", try fixture.read("a.txt", &bytes));
}

/// A journal record as `durable` frames it, appended to `list`: for forged journals.
fn forgeRecord(list: *std.ArrayList(u8), kind: durable.Kind, payload: []const u8) !void {
    const gpa = std.testing.allocator;
    var frame: [5]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], @intCast(payload.len), .little);
    frame[4] = @backingInt(kind);
    try list.appendSlice(gpa, &frame);
    try list.appendSlice(gpa, payload);
    var check: [4]u8 = undefined;
    std.mem.writeInt(u32, &check, durable.checksum(@backingInt(kind), &.{payload}), .little);
    try list.appendSlice(gpa, &check);
}

fn forgeLine(list: *std.ArrayList(u8), sequence: u64, request: u32, line: []const u8) !void {
    const gpa = std.testing.allocator;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var word: [8]u8 = undefined;
    var half: [4]u8 = undefined;
    std.mem.writeInt(u64, &word, sequence, .little);
    try payload.appendSlice(gpa, &word);
    try payload.append(gpa, @backingInt(effects.InputKind.line));
    std.mem.writeInt(u32, &half, request, .little);
    try payload.appendSlice(gpa, &half);
    std.mem.writeInt(u64, &word, 0, .little);
    try payload.appendSlice(gpa, &word);
    try payload.append(gpa, @backingInt(effects.InputStatus.value));
    try payload.appendSlice(gpa, &word);
    std.mem.writeInt(u32, &half, @intCast(line.len), .little);
    try payload.appendSlice(gpa, &half);
    try payload.appendSlice(gpa, line);
    try forgeRecord(list, .input, payload.items);
}

fn forgeAction(list: *std.ArrayList(u8), sequence: u64, channel: u32, text: []const u8) !void {
    var payload: [64]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], sequence, .little);
    std.mem.writeInt(u32, payload[8..12], channel, .little);
    std.mem.writeInt(u32, payload[12..16], @intCast(text.len), .little);
    @memcpy(payload[16..][0..text.len], text);
    try forgeRecord(list, .action, payload[0 .. 16 + text.len]);
}

fn forgeSeal(list: *std.ArrayList(u8), actions: u64, inputs: u64) !void {
    var payload: [16]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], actions, .little);
    std.mem.writeInt(u64, payload[8..16], inputs, .little);
    try forgeRecord(list, .seal, &payload);
}

test "a resume whose journal holds a sealed line longer than this build reads is refused, not trusted" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "config.txt", .data = "alpha\n" });
    const state = try fixture.path(0, "state");
    const list = [_]effects.Grant{.{ .kind = .reader, .name = "config" }};
    const paths = [_][]const u8{try fixture.path(1, "config.txt")};
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    {
        const file = try std.Io.Dir.cwd().openFile(io, paths[0], .{});
        defer file.close(io);
        var buffer: [64]u8 = undefined;
        const opened = [_]?std.Io.File.Reader{file.reader(io, &buffer)};
        const run = try openRunOf(fixture.init(), state, "Value:i64 = 1", .{ .list = &list, .paths = &paths }, &opened, &out, &message);
        run.close();
    }
    // The run's header, then a sealed line a byte longer than any run of this build reads.
    var header_bytes: [1024]u8 = undefined;
    var journal_bytes: std.ArrayList(u8) = .empty;
    defer journal_bytes.deinit(gpa);
    try journal_bytes.appendSlice(gpa, try fixture.read("state/journal", &header_bytes));
    const long = try gpa.alloc(u8, effects.input_byte_capacity + 1);
    defer gpa.free(long);
    @memset(long, 'a');
    try forgeLine(&journal_bytes, 0, 0, long);
    try forgeAction(&journal_bytes, 0, 0, "got");
    try forgeSeal(&journal_bytes, 1, 1);
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = journal_bytes.items });
    try fixture.temporary.dir.deleteFile(io, "state/lock");
    try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = programDigest("Value:i64 = 1") }, &out, true, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "/state cannot be resumed (recovery_mismatch): its journal holds a line of ") != null);
    try fixture.missing("state/lock");
    const after = try std.Io.Dir.cwd().readFileAlloc(io, try fixture.path(2, "state/journal"), gpa, .unlimited);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, journal_bytes.items, after);
}

test "a journal whose header names more grants than this build holds, another profile, or cannot be read is refused, and never removed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "state");
    const state = try fixture.path(0, "state");
    const journal_path = try fixture.path(1, "state/journal");
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    // A header of this toolchain and profile with one grant more than this build holds.
    const many = try gpa.alloc(durable.GrantRecord, effects.grant_capacity + 1);
    defer gpa.free(many);
    const names = try gpa.alloc([12]u8, many.len);
    defer gpa.free(names);
    for (many, names, 0..) |*grant, *name, index| grant.* = .{ .kind = .writer, .name = std.fmt.bufPrint(name, "w{d}", .{index}) catch unreachable, .path = "p" };
    const program = programDigest("Value:i64 = 1");
    const header: durable.Header = .{ .toolchain = toolchain, .profile = forbic.profile.active.name, .program = program, .seed = 7, .tick_rate = 60, .grants = many };
    const payload = try gpa.alloc(u8, durable.headerBytes(header));
    defer gpa.free(payload);
    var journal_bytes: std.ArrayList(u8) = .empty;
    defer journal_bytes.deinit(gpa);
    try forgeRecord(&journal_bytes, .header, try durable.encodeHeader(header, payload));
    try forgeAction(&journal_bytes, 0, 0, "a");
    try forgeSeal(&journal_bytes, 1, 0);
    var says: [256]u8 = undefined;
    const too_many = try std.fmt.bufPrint(&says, "names {d} grants, and this build holds at most {d}\n", .{ many.len, effects.grant_capacity });
    const Case = struct { request: Request, says: []const u8 };
    for ([_]bool{ false, true }) |finished| {
        if (finished) try forgeRecord(&journal_bytes, .abandoned, "");
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = journal_bytes.items });
        const cases = if (finished) [_]Case{
            .{ .request = .{}, .says = "/state cannot be processed (recovery_mismatch): " },
            .{ .request = .{ .intent = .resume_run, .program = program }, .says = "/state cannot be processed (recovery_mismatch): " },
            .{ .request = .{ .intent = .abandon }, .says = "/state cannot be processed (recovery_mismatch): " },
        } else [_]Case{
            .{ .request = .{}, .says = "/state holds an unfinished run (run_unfinished)" },
            .{ .request = .{ .intent = .resume_run, .program = program }, .says = "/state cannot be resumed (recovery_mismatch): " },
            .{ .request = .{ .intent = .abandon }, .says = "/state cannot be abandoned (recovery_mismatch): " },
        };
        for (cases, 0..) |case, index| {
            var message: std.Io.Writer = .fixed(&err_bytes);
            errdefer std.debug.print("{s}\n", .{message.buffered()});
            try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, case.request, &out, true, &message));
            try std.testing.expect(std.mem.indexOf(u8, message.buffered(), case.says) != null);
            if (finished or index != 0) try std.testing.expect(std.mem.endsWith(u8, message.buffered(), too_many));
            const after = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, gpa, .unlimited);
            defer gpa.free(after);
            try std.testing.expectEqualSlices(u8, journal_bytes.items, after);
            try fixture.missing("state/lock");
        }
        var message: std.Io.Writer = .fixed(&err_bytes);
        var long_out: [64]u8 = undefined;
        var shown: std.Io.Writer = .fixed(&long_out);
        try std.testing.expectEqual(@as(u8, 1), try show(io, fixture.arena.allocator(), state, &shown, &message));
        try std.testing.expect(std.mem.endsWith(u8, message.buffered(), too_many));
    }
    // A finished journal of another profile, and a header record whole but unreadable.
    var payload_bytes: [512]u8 = undefined;
    const other: durable.Header = .{ .toolchain = toolchain, .profile = "elsewhere", .program = program, .seed = 7, .tick_rate = 60, .grants = &.{} };
    var unreadable: [64]u8 = undefined;
    @memcpy(unreadable[0..4], &[_]u8{ durable.magic.len, 0, 0, 0 });
    @memcpy(unreadable[4..][0..durable.magic.len], durable.magic);
    const forged = [_][]const u8{ try durable.encodeHeader(other, &payload_bytes), unreadable[0 .. 4 + durable.magic.len + 3] };
    const refusals = [_][]const u8{ "/state cannot be processed (recovery_mismatch): it is of the elsewhere profile", "/state cannot be processed (recovery_mismatch): its header cannot be read by this build\n" };
    for (forged, refusals) |header_payload, refusal_says| {
        journal_bytes.clearRetainingCapacity();
        try forgeRecord(&journal_bytes, .header, header_payload);
        try forgeAction(&journal_bytes, 0, 0, "a");
        try forgeSeal(&journal_bytes, 1, 0);
        try forgeRecord(&journal_bytes, .abandoned, "");
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = journal_bytes.items });
        var message: std.Io.Writer = .fixed(&err_bytes);
        try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{}, &out, true, &message));
        try std.testing.expect(std.mem.indexOf(u8, message.buffered(), refusal_says) != null);
        const after = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, gpa, .unlimited);
        defer gpa.free(after);
        try std.testing.expectEqualSlices(u8, journal_bytes.items, after);
    }
}

test "a journal whose header's tick rate no run takes is refused untouched by a resume, an abandon and journal show" {
    // c1-3: the rate would become the resumed run's, which the machines assert.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "state");
    const state = try fixture.path(0, "state");
    const journal_path = try fixture.path(1, "state/journal");
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    const program = programDigest("Value:i64 = 1");
    var payload: [512]u8 = undefined;
    var journal_bytes: std.ArrayList(u8) = .empty;
    defer journal_bytes.deinit(gpa);
    for ([_]u64{ 0, forbic.types.Scheduler.max_tick_rate + 1, 1 << 31, std.math.maxInt(u64) }) |rate| {
        const header: durable.Header = .{ .toolchain = toolchain, .profile = forbic.profile.active.name, .program = program, .seed = 7, .tick_rate = rate, .grants = &.{}, .store = .{ .base = @splat(0), .schema = @splat(1) } };
        journal_bytes.clearRetainingCapacity();
        try forgeRecord(&journal_bytes, .header, try durable.encodeHeader(header, &payload));
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = journal_bytes.items });
        const Case = struct { request: Request, says: []const u8 };
        const cases = [_]Case{
            .{ .request = .{ .intent = .resume_run, .program = program }, .says = "/state cannot be resumed (recovery_mismatch): its header cannot be read by this build\n" },
            .{ .request = .{ .intent = .abandon }, .says = "/state cannot be abandoned (recovery_mismatch): its header cannot be read by this build\n" },
        };
        for (cases) |case| {
            var message: std.Io.Writer = .fixed(&err_bytes);
            errdefer std.debug.print("{s}\n", .{message.buffered()});
            try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, case.request, &out, true, &message));
            try std.testing.expect(std.mem.endsWith(u8, message.buffered(), case.says));
            const after = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, gpa, .unlimited);
            defer gpa.free(after);
            try std.testing.expectEqualSlices(u8, journal_bytes.items, after);
            try fixture.missing("state/lock");
            try fixture.missing("state/store");
        }
        var message: std.Io.Writer = .fixed(&err_bytes);
        var shown_bytes: [64]u8 = undefined;
        var shown: std.Io.Writer = .fixed(&shown_bytes);
        try std.testing.expectEqual(@as(u8, 1), try show(io, fixture.arena.allocator(), state, &shown, &message));
        try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state/journal cannot be read by this build\n"));
        try std.testing.expectEqual(@as(usize, 0), shown.buffered().len);
    }
}

/// The names of the files of `DIR/store/objects` and `DIR/store/generations` and the bytes of
/// `DIR/store/active`, in `out`, for comparing a store before and after a command.
fn storeListing(io: std.Io, state: std.Io.Dir, out: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    for ([_][]const u8{ "store/objects", "store/generations" }) |place| {
        var names: [16][64]u8 = undefined;
        var count: usize = 0;
        const dir = try state.openDir(io, place, .{ .iterate = true });
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            names[count] = entry.name[0..64].*;
            count += 1;
        }
        std.mem.sort([64]u8, names[0..count], {}, struct {
            fn less(_: void, a: [64]u8, b: [64]u8) bool {
                return std.mem.lessThan(u8, &a, &b);
            }
        }.less);
        for (names[0..count]) |name| try writer.print("{s}:{s};", .{ place, name });
    }
    var active: [65]u8 = undefined;
    try writer.writeAll(try state.readFile(io, "store/active", &active));
    return writer.buffered();
}

test "a journal whose header names a schema that is no schema of the store is not published, and abandoning it ends it" {
    // c1-2: the header's program binds the program, not its store's schema.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.createDirPath(io, "state");
    const state = try fixture.path(0, "state");
    const state_dir = try fixture.temporary.dir.openDir(io, "state", .{});
    defer state_dir.close(io);
    // The store a first session left: a schema and one entry.
    var files = try storage.Files.open(io, state_dir, true);
    var held = files.handle(gpa);
    const schema_text = try forbic.store.schemaText(gpa, &.{":X"});
    defer gpa.free(schema_text);
    const schema = try held.putObject(schema_text);
    const base = (try held.publish(null, schema, &.{.{ .cell = ":X", .key = "alice", .text = @constCast("1") }})).?;
    files.close(io);
    var before_bytes: [2048]u8 = undefined;
    const before = try storeListing(io, state_dir, &before_bytes);
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    const program = programDigest("Value:i64 = 1");
    var payload: [512]u8 = undefined;
    var journal_bytes: std.ArrayList(u8) = .empty;
    defer journal_bytes.deinit(gpa);
    const reason = "(StoreFailed: the schema the journal's header names is not a schema the store holds)";
    // None in the store, and an entry's object.
    for ([_][32]u8{ @splat(0x11), forbic.store.hashOf("1") }) |forged| for ([_]bool{ false, true }) |finished| {
        const header: durable.Header = .{ .toolchain = toolchain, .profile = forbic.profile.active.name, .program = program, .seed = 7, .tick_rate = 60, .grants = &.{}, .store = .{ .base = base, .schema = forged } };
        journal_bytes.clearRetainingCapacity();
        try forgeRecord(&journal_bytes, .header, try durable.encodeHeader(header, &payload));
        try forgeAction(&journal_bytes, 0, effects.store_channel, "{\"cell\":\":X\",\"key\":\"alice\",\"value\":2}");
        try forgeSeal(&journal_bytes, 1, 0);
        if (finished) try forgeRecord(&journal_bytes, .abandoned, "");
        try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/journal", .data = journal_bytes.items });
        var message: std.Io.Writer = .fixed(&err_bytes);
        errdefer std.debug.print("{s}\n", .{message.buffered()});
        if (finished) {
            // R2: the next command processes it: refused, the journal left as it is.
            try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{}, &out, true, &message));
            try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "is finished; its store is not published " ++ reason ++ "\n"));
        } else {
            // A resume publishes its prefix before it runs: refused, the journal left as it is.
            const run = switch (try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = program }, &out, true, &message)) {
                .ok => |run| run,
                .done => return error.TestUnexpectedResult,
            };
            const status = try run.proceed(&message);
            run.close();
            try std.testing.expectEqual(@as(?u8, 1), status);
            try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "cannot be resumed: its store is not published " ++ reason ++ "\n"));
        }
        const kept = try std.Io.Dir.cwd().readFileAlloc(io, try fixture.path(1, "state/journal"), gpa, .unlimited);
        defer gpa.free(kept);
        try std.testing.expectEqualSlices(u8, journal_bytes.items, kept);
        var after_bytes: [2048]u8 = undefined;
        try std.testing.expectEqualStrings(before, try storeListing(io, state_dir, &after_bytes));
        // No dead end: `--abandon` ends the journal and rotates it, its store not published, and
        // the next run starts on the store as it was.
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .intent = .abandon }, &out, true, &message));
        try std.testing.expect(std.mem.endsWith(u8, message.buffered(), if (finished) "had finished; its store is not published\n" else "is abandoned; its store is not published\n"));
        try fixture.missing("state/journal");
        try std.testing.expectEqualStrings(before, try storeListing(io, state_dir, &after_bytes));
        message = .fixed(&err_bytes);
        const fresh_run = switch (try Run.open(fixture.init(), state, .{}, &out, true, &message)) {
            .ok => |run| run,
            .done => return error.TestUnexpectedResult,
        };
        fresh_run.close();
        try std.testing.expectEqualStrings(before, try storeListing(io, state_dir, &after_bytes));
        var shown_bytes: [512]u8 = undefined;
        var shown: std.Io.Writer = .fixed(&shown_bytes);
        message = .fixed(&err_bytes);
        try std.testing.expectEqual(@as(u8, 0), try storage.show(io, gpa, state, &shown, &message));
        var first_bytes: [96]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, shown.buffered(), try std.fmt.bufPrint(&first_bytes, "{{\"generation\":\"{s}\"", .{forbic.store.hexOf(base)})));
    };
}

test "a publication checks every base before it writes, and leaves no staging file when it fails" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "audit.txt", .data = "" });
    const list = [_]effects.Grant{ .{ .kind = .writer, .name = "log" }, .{ .kind = .writer, .name = "audit" } };
    const paths = [_][]const u8{ try fixture.path(0, "log.txt"), try fixture.path(1, "audit.txt") };
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    const run = try openRun(fixture.init(), try fixture.path(2, "state"), .{ .list = &list, .paths = &paths }, &out, &message);
    defer run.close();
    const log = try testLog(run);
    defer forbic.scratch.release(log);
    try log.prepareOn(1, "one");
    try log.prepareOn(2, "two");
    // The second writer's base changed past the first chunk a copy reads: neither target is written.
    const changed = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(changed);
    @memset(changed, 'x');
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/writers/1.base", .data = changed });
    try std.testing.expectError(error.BaseChanged, run.publish(run.journal.disk));
    var bytes: [256]u8 = undefined;
    try std.testing.expectEqualStrings("earlier\n", try fixture.read("log.txt", &bytes));
    try std.testing.expectEqualStrings("", try fixture.read("audit.txt", &bytes));
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/writers/1.base", .data = "" });
    // A rename that fails, over what became a directory: its staging file is removed.
    try fixture.temporary.dir.deleteFile(io, "audit.txt");
    try fixture.temporary.dir.createDirPath(io, "audit.txt/inside");
    if (run.publish(run.journal.disk)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqualStrings("earlier\none\n", try fixture.read("log.txt", &bytes));
    var staged: [64]u8 = undefined;
    try fixture.missing(try std.fmt.bufPrint(&staged, "audit.txt.{s}.tmp", .{&run.tag}));
}

test "abandoning publishes every writer it can, reports the others by name, and always ends the journal" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "audit.txt", .data = "" });
    const state = try fixture.path(0, "state");
    const list = [_]effects.Grant{ .{ .kind = .writer, .name = "log" }, .{ .kind = .writer, .name = "audit" } };
    const paths = [_][]const u8{ try fixture.path(1, "log.txt"), try fixture.path(2, "audit.txt") };
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    var bytes: [256]u8 = undefined;
    {
        const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
        defer run.close();
        const log = try testLog(run);
        defer forbic.scratch.release(log);
        try log.prepareOn(1, "one");
        try log.prepareOn(2, "two");
        log.begin();
        try log.prepareOn(1, "unsealed");
        try run.disk.writer.interface.flush();
    }
    // The first writer's base is gone: it is skipped and named, the other published, and the
    // journal ends and is rotated all the same (G19).
    try fixture.temporary.dir.deleteFile(io, "state/writers/0.base");
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .intent = .abandon }, &out, true, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "forbic: error: writer log of the run in ") != null);
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "/state is not published (FileNotFound)\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state is abandoned; 1 of its writers are not published\n"));
    try std.testing.expectEqualStrings("earlier\n", try fixture.read("log.txt", &bytes));
    try std.testing.expectEqualStrings("two\n", try fixture.read("audit.txt", &bytes));
    try fixture.missing("state/journal");
    var long_out: [4096]u8 = undefined;
    var shown: std.Io.Writer = .fixed(&long_out);
    try std.testing.expectEqual(@as(u8, 0), try show(io, fixture.arena.allocator(), state, &shown, &message));
    try std.testing.expect(std.mem.endsWith(u8, shown.buffered(), "{\"abandoned\":{}}\n"));
    // A finished journal whose writers' files are no longer grouped as at its start: `--abandon`
    // skips them all, and rotates it.
    {
        const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
        defer run.close();
        const log = try testLog(run);
        defer forbic.scratch.release(log);
        try log.prepareOn(1, "three");
        try run.journal.finish(.{ .outcome = .completed });
    }
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "state/writers/owners", .data = "1\n1\n" });
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .intent = .abandon }, &out, true, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "writer log of the run in ") != null);
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "writer audit of the run in ") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, message.buffered(), "is not published (WritersChanged)\n"));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state had finished; 2 of its writers are not published\n"));
    try std.testing.expectEqualStrings("earlier\n", try fixture.read("log.txt", &bytes));
    try fixture.missing("state/journal");
}

test "a run whose journal cannot be rotated says so, its writers published, and so does the next command" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "log.txt", .data = "earlier\n" });
    // Where the rotation goes there is a directory that is not empty.
    try fixture.temporary.dir.createDirPath(io, "state/journal.done/inside");
    const state = try fixture.path(0, "state");
    const list = [_]effects.Grant{.{ .kind = .writer, .name = "log" }};
    const paths = [_][]const u8{try fixture.path(1, "log.txt")};
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    var bytes: [256]u8 = undefined;
    {
        const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
        defer run.close();
        const log = try testLog(run);
        defer forbic.scratch.release(log);
        try log.prepareOn(1, "one");
        try std.testing.expectError(error.Unrotated, run.finish(.{ .outcome = .completed }));
        try std.testing.expect(run.unrotated != null and run.unpublished == null);
    }
    try std.testing.expectEqualStrings("earlier\none\n", try fixture.read("log.txt", &bytes));
    _ = try fixture.temporary.dir.statFile(io, "state/journal", .{});
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .grants = .{ .list = &list, .paths = &paths } }, &out, true, &message));
    try std.testing.expect(std.mem.indexOf(u8, message.buffered(), "/state is finished and its writers are published, but it is not rotated (") != null);
    try std.testing.expectEqualStrings("earlier\none\n", try fixture.read("log.txt", &bytes));
}

test "a resume whose writers' files are grouped otherwise than when its run started is refused" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.create();
    defer fixture.destroy();
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try fixture.temporary.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    const state = try fixture.path(0, "state");
    const list = [_]effects.Grant{ .{ .kind = .writer, .name = "a" }, .{ .kind = .writer, .name = "b" } };
    const paths = [_][]const u8{ try fixture.path(1, "a.txt"), try fixture.path(2, "b.txt") };
    var out_bytes: [64]u8 = undefined;
    var err_bytes: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    var message: std.Io.Writer = .fixed(&err_bytes);
    {
        const run = try openRun(fixture.init(), state, .{ .list = &list, .paths = &paths }, &out, &message);
        defer run.close();
        const log = try testLog(run);
        defer forbic.scratch.release(log);
        try log.prepareOn(1, "x");
        try run.disk.writer.interface.flush();
    }
    // The two targets have become one file, where the host can make a second name.
    try fixture.temporary.dir.deleteFile(io, "b.txt");
    fixture.temporary.dir.hardLink("a.txt", fixture.temporary.dir, "b.txt", io, .{}) catch return error.SkipZigTest;
    try fixture.temporary.dir.deleteFile(io, "state/lock");
    message = .fixed(&err_bytes);
    try std.testing.expectEqual(Run.Opened{ .done = 1 }, try Run.open(fixture.init(), state, .{ .intent = .resume_run, .program = programDigest("Value:i64 = 1") }, &out, true, &message));
    try std.testing.expect(std.mem.endsWith(u8, message.buffered(), "/state cannot be resumed (recovery_mismatch): its writers' files are not the ones its run started with\n"));
    try fixture.missing("state/lock");
}
