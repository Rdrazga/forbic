//! TASK-0109, W4.6 (RFC-0095): a Forbic project directory, read into the bundle packet of a
//! folder tree (RFC-0093), which the host then compiles and runs as `--bundle` would.
//!
//! A project is a directory holding a manifest, `forbic.json`, whose only field names the root
//! module (`{"root": "/user@example.com/Hello"}`), and a folder `src/` holding the tree: each
//! folder under `src/` is the module of its path, and its `.forb` files are that module's text.
//! The walk reads `src/` alone, breadth first, without recursion, one folder open at a time, and
//! follows no symbolic link: a link is refused where the walk meets it (the manifest, `src/`, any
//! entry under `src/` it does not leave out), so every source is a file of the directory named.
//! Names that start with `.` are left out, and so is every file that does not end in `.forb`;
//! both still count toward the walk's bound, and neither is examined further. A folder that holds
//! a source is a module, so its path must be a module path, and no source lies directly in
//! `src/`. The packet lists the sources in the byte order of their paths, whatever order the file
//! system gives, so one tree always gives the same bytes, which is what a journal records as the
//! program (RFC-0086).
//!
//! Bounds, each the profile's: at most `module_files` sources, `2 * module_files` entries in all
//! (folders and files, sources or not), paths within `module_path_bytes`, sources within
//! `source_bytes` together with a newline between the files of each folder (as RFC-0093 joins
//! them), and a manifest of 4 KiB. Exceeding one refuses the project with the
//! bound named; nothing is compiled. Storage is one `Storage`, made with `scratch` and touched as
//! far as the project uses it.
const std = @import("std");
const builtin = @import("builtin");
const forbic = @import("forbic");

const limits = forbic.types.limits;

/// The manifest's name in the project directory.
pub const manifest_name = "forbic.json";
/// The folder of the tree in the project directory.
pub const sources_name = "src";
/// What a source file's name ends with.
pub const source_suffix = ".forb";
/// The most bytes a manifest holds.
pub const manifest_capacity = 4096;
/// The most sources a project has: the files a folder tree may have.
pub const source_capacity = limits.module_files;
/// The most entries the walk reads: folders and files, sources or not.
pub const entry_capacity = 2 * limits.module_files;
/// The most bytes of a path under `src/`.
pub const path_capacity = limits.module_path_bytes;

/// Why a project was refused.
pub const Reason = enum {
    /// The project directory cannot be opened.
    no_directory,
    /// `forbic.json` does not exist.
    no_manifest,
    /// `forbic.json` is larger than `manifest_capacity`.
    manifest_too_large,
    /// `forbic.json` is not one JSON object whose only field is a string `root`.
    manifest_invalid,
    /// The root is not a module path.
    root_invalid,
    /// No source lies directly in the root's folder.
    root_without_sources,
    /// `src/` does not exist or is not a folder.
    no_sources_folder,
    /// An entry is a symbolic link (on Windows, any reparse point: a link or a junction).
    symbolic_link,
    /// An entry is neither a regular file nor a folder: a pipe, a socket, a device.
    not_file_or_folder,
    /// A name is not UTF-8 text.
    name_not_utf8,
    /// A source is not UTF-8 text, which a packet cannot carry.
    source_not_utf8,
    path_too_long,
    too_many_sources,
    too_many_entries,
    sources_too_large,
    /// An entry cannot be opened or read: `error_name` says why.
    unreadable,
    /// A source lies directly in `src/`, in no module's folder.
    source_outside_module,
    /// A folder that holds sources is a module, and its path is not a module path.
    folder_not_module,
};

/// A refusal: its reason, the path it is about relative to the project directory (empty for
/// the directory itself), and the system's error when there is one.
pub const Refusal = struct {
    reason: Reason,
    path_bytes: [refusal_path_capacity]u8 = undefined,
    path_length: usize = 0,
    error_name: ?[]const u8 = null,

    /// Room for `src/`, a folder's path and one name of the longest the system gives, so that
    /// even the path that was too long is shown whole.
    pub const refusal_path_capacity = sources_name.len + 1 + path_capacity + 1 + std.Io.Dir.max_name_bytes;

    pub fn path(self: *const Refusal) []const u8 {
        return self.path_bytes[0..self.path_length];
    }

    /// The refusal as the `forbic` tool writes it: `DIR/PATH: error: MESSAGE`.
    pub fn write(self: *const Refusal, out: *std.Io.Writer, directory: []const u8) std.Io.Writer.Error!void {
        if (self.path_length == 0) try out.print("{s}: error: ", .{directory}) else try out.print("{s}/{s}: error: ", .{ withoutSeparator(directory), self.path() });
        switch (self.reason) {
            .no_directory => try out.writeAll("cannot open the project directory"),
            .no_manifest => try out.writeAll("is not a Forbic project: it has no " ++ manifest_name ++ " naming its root module"),
            .manifest_too_large => try out.print("the manifest holds more than {d} bytes", .{manifest_capacity}),
            .manifest_invalid => try out.writeAll("the manifest must be one JSON object with one field, \"root\", a module path such as \"/user@example.com/App\""),
            .root_invalid => try out.writeAll("\"root\" must be a module path such as \"/user@example.com/App\": a slash, a domain, then names, each after a slash"),
            .root_without_sources => try out.writeAll("\"root\" names no folder of " ++ sources_name ++ "/ that holds " ++ source_suffix ++ " files"),
            .no_sources_folder => try out.writeAll("a project keeps its sources in a folder " ++ sources_name ++ "/, which is missing"),
            .symbolic_link => try out.writeAll("is a symbolic link; a project's files must be its own"),
            .not_file_or_folder => try out.writeAll("is neither a regular file nor a folder"),
            .name_not_utf8 => try out.writeAll("a name in the project is not UTF-8 text"),
            .source_not_utf8 => try out.writeAll("is not UTF-8 text"),
            .path_too_long => try out.print("the path under " ++ sources_name ++ "/ is longer than {d} bytes", .{path_capacity}),
            .too_many_sources => try out.print("the project has more than {d} " ++ source_suffix ++ " files", .{source_capacity}),
            .too_many_entries => try out.print("the project's " ++ sources_name ++ "/ holds more than {d} entries (folders and files)", .{entry_capacity}),
            .sources_too_large => try out.print("the project's sources hold more than {d} bytes together, with a newline between the files of each folder", .{limits.source_bytes}),
            .unreadable => try out.writeAll("cannot be read"),
            .source_outside_module => try out.writeAll("lies in no module: a source belongs in a folder of " ++ sources_name ++ "/ whose path is a module path, such as " ++ sources_name ++ "/hello@example.com/App/"),
            .folder_not_module => try out.writeAll("holds " ++ source_suffix ++ " files, so it is a module, but its path is no module path: a domain (letters, digits, _, ., @ and -, such as hello@example.com), then names (a letter or _, then letters, digits and _), each after a slash"),
        }
        if (self.error_name) |name| try out.print(" ({s})", .{name});
        try out.writeByte('\n');
    }
};

/// A project read: its root, its sources in the order of their paths, and the bundle packet that
/// holds them, all borrowed from the `Storage` until its next `load`.
pub const Project = struct {
    root: []const u8,
    files: []const forbic.modules.Input,
    packet: []const u8,
};

pub const Result = union(enum) { ok: Project, refused: *const Refusal };

const Entry = struct {
    path_start: u32,
    path_length: u32,
    kind: enum { folder, source },
    source_start: u32 = 0,
    source_length: u32 = 0,
};

/// Everything one `load` needs, as large as the profile's bounds. Create it with
/// `forbic.scratch.storage` and `forbic.scratch.initialise`.
pub const Storage = struct {
    paths: [entry_capacity * path_capacity]u8 = undefined,
    /// The root folder, then every folder and source the walk keeps, at most `entry_capacity`.
    entries: [entry_capacity + 1]Entry = undefined,
    /// The sources, and one byte more to see that the last one read is too large.
    sources: [limits.source_bytes + 1]u8 = undefined,
    inputs: [source_capacity]forbic.modules.Input = undefined,
    packet: [forbic.bundle_packet.max_packet_bytes]u8 = undefined,
    root: [path_capacity]u8 = undefined,
    manifest: [manifest_capacity + 1]u8 = undefined,
    refusal: Refusal = .{ .reason = .unreadable },
    unread: struct { reason: Reason = .unreadable, problem: ?anyerror = null } = .{},
    entry_count: usize = 0,
    path_used: usize = 0,
    source_used: usize = 0,

    /// Reads the project in `directory`.
    pub fn load(self: *Storage, io: std.Io, directory: []const u8) Result {
        self.entry_count = 0;
        self.path_used = 0;
        self.source_used = 0;
        return self.read(io, directory) catch |refused| switch (refused) {
            error.Refused => .{ .refused = &self.refusal },
        };
    }

    fn read(self: *Storage, io: std.Io, directory: []const u8) error{Refused}!Result {
        var project = std.Io.Dir.cwd().openDir(io, directory, .{}) catch |problem| return self.refuseTop(.no_directory, "", problem);
        defer project.close(io);
        const root = try self.readManifest(io, project);
        var top = try self.openSources(io, project);
        defer top.close(io);
        self.entries[0] = .{ .path_start = 0, .path_length = 0, .kind = .folder };
        self.entry_count = 1;
        var sources: usize = 0;
        var seen: usize = 0;
        // The newlines the join of each folder adds between its files (RFC-0093), which the
        // sources' bound covers too.
        var separators: usize = 0;
        // Breadth first: each folder is read when its turn comes, so the walk holds one open.
        var index: usize = 0;
        while (index < self.entry_count) : (index += 1) {
            const folder = self.entries[index];
            if (folder.kind != .folder) continue;
            const folder_path = self.paths[folder.path_start..][0..folder.path_length];
            var opened = if (folder_path.len == 0) top else top.openDir(io, folder_path, .{ .iterate = true, .follow_symlinks = false }) catch |problem| return self.refuseIn(.unreadable, folder_path, "", problem);
            defer if (folder_path.len != 0) opened.close(io);
            var items = opened.iterateAssumeFirstIteration();
            var folder_sources: usize = 0;
            while (items.next(io) catch |problem| return self.refuseIn(.unreadable, folder_path, "", problem)) |item| {
                seen += 1;
                if (seen > entry_capacity) return self.refuseTop(.too_many_entries, "", null);
                if (item.name.len == 0 or item.name[0] == '.') continue;
                const kind = if (item.kind != .unknown) item.kind else (opened.statFile(io, item.name, .{ .follow_symlinks = false }) catch |problem| return self.refuseIn(.unreadable, folder_path, item.name, problem)).kind;
                // A file that is no source is left out before its name is examined: only what
                // the walk keeps (folders, sources) and what it refuses (links, pipes) is named.
                if (kind == .file and !std.mem.endsWith(u8, item.name, source_suffix)) continue;
                if (!std.unicode.utf8ValidateSlice(item.name)) return self.refuseIn(.name_not_utf8, folder_path, "", null);
                const length = folder_path.len + @intFromBool(folder_path.len != 0) + item.name.len;
                if (length > path_capacity) return self.refuseIn(.path_too_long, folder_path, item.name, null);
                switch (kind) {
                    .directory => _ = self.push(folder_path, item.name, .folder),
                    .file => {
                        if (folder_path.len == 0) return self.refuseIn(.source_outside_module, "", item.name, null);
                        // The first source makes the folder a module: its path must be one.
                        if (folder_sources == 0 and !folderIsModule(folder_path)) return self.refuseIn(.folder_not_module, folder_path, "", null);
                        sources += 1;
                        folder_sources += 1;
                        if (sources > source_capacity) return self.refuseTop(.too_many_sources, "", null);
                        const entry = self.push(folder_path, item.name, .source);
                        try self.readSource(io, opened, item.name, entry);
                    },
                    .sym_link => return self.refuseIn(.symbolic_link, folder_path, item.name, null),
                    else => return self.refuseIn(.not_file_or_folder, folder_path, item.name, null),
                }
            }
            separators += folder_sources -| 1;
        }
        if (self.source_used + separators > limits.source_bytes) return self.refuseTop(.sources_too_large, "", null);
        var count: usize = 0;
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.kind != .source) continue;
            self.inputs[count] = .{ .path = self.paths[entry.path_start..][0..entry.path_length], .source = self.sources[entry.source_start..][0..entry.source_length] };
            count += 1;
        }
        std.debug.assert(count == sources);
        const files = self.inputs[0..count];
        std.mem.sortUnstable(forbic.modules.Input, files, {}, before);
        if (!rootHasSources(root, files)) return self.refuseTop(.root_without_sources, manifest_name, null);
        return .{ .ok = .{ .root = root, .files = files, .packet = self.writePacket(root, files) } };
    }

    fn readManifest(self: *Storage, io: std.Io, project: std.Io.Dir) error{Refused}![]const u8 {
        const stat = project.statFile(io, manifest_name, .{ .follow_symlinks = false }) catch |problem| switch (problem) {
            error.FileNotFound => return self.refuseTop(.no_manifest, "", null),
            else => return self.refuseTop(.unreadable, manifest_name, problem),
        };
        if (stat.kind == .sym_link) return self.refuseTop(.symbolic_link, manifest_name, null);
        if (stat.kind != .file) return self.refuseTop(.not_file_or_folder, manifest_name, null);
        const bytes = self.readFile(io, project, manifest_name, &self.manifest) catch |problem| switch (problem) {
            error.TooLarge => return self.refuseTop(.manifest_too_large, manifest_name, null),
            error.Unreadable => return self.refuseTop(self.unread.reason, manifest_name, self.unread.problem),
        };
        var room: [2 * manifest_capacity]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&room);
        const Manifest = struct { root: []const u8 };
        const manifest = std.json.parseFromSliceLeaky(Manifest, fixed.allocator(), bytes, .{}) catch |problem| return self.refuseTop(.manifest_invalid, manifest_name, problem);
        if (!forbic.modules.modulePath(manifest.root)) return self.refuseTop(.root_invalid, manifest_name, null);
        @memcpy(self.root[0..manifest.root.len], manifest.root);
        return self.root[0..manifest.root.len];
    }

    fn openSources(self: *Storage, io: std.Io, project: std.Io.Dir) error{Refused}!std.Io.Dir {
        const stat = project.statFile(io, sources_name, .{ .follow_symlinks = false }) catch |problem| switch (problem) {
            error.FileNotFound => return self.refuseTop(.no_sources_folder, "", null),
            else => return self.refuseTop(.unreadable, sources_name, problem),
        };
        if (stat.kind == .sym_link) return self.refuseTop(.symbolic_link, sources_name, null);
        if (stat.kind != .directory) return self.refuseTop(.no_sources_folder, "", null);
        return project.openDir(io, sources_name, .{ .iterate = true, .follow_symlinks = false }) catch |problem| return self.refuseTop(.unreadable, sources_name, problem);
    }

    fn push(self: *Storage, folder: []const u8, name: []const u8, kind: @FieldType(Entry, "kind")) *Entry {
        // `seen` bounds the entries after the root, `path_capacity` each path: both fit.
        std.debug.assert(self.entry_count <= entry_capacity);
        const start = self.path_used;
        var used = start;
        if (folder.len != 0) {
            @memcpy(self.paths[used..][0..folder.len], folder);
            used += folder.len;
            self.paths[used] = '/';
            used += 1;
        }
        @memcpy(self.paths[used..][0..name.len], name);
        used += name.len;
        self.path_used = used;
        const entry = &self.entries[self.entry_count];
        entry.* = .{ .path_start = @intCast(start), .path_length = @intCast(used - start), .kind = kind };
        self.entry_count += 1;
        return entry;
    }

    fn readSource(self: *Storage, io: std.Io, folder: std.Io.Dir, name: []const u8, entry: *Entry) error{Refused}!void {
        const path = self.paths[entry.path_start..][0..entry.path_length];
        // The room left, and one byte more, so that a file that grew after its size was read is
        // still seen to be too large.
        const bytes = self.readFile(io, folder, name, self.sources[self.source_used..]) catch |problem| switch (problem) {
            error.TooLarge => return self.refuseTop(.sources_too_large, "", null),
            error.Unreadable => return self.refuseIn(self.unread.reason, path, "", self.unread.problem),
        };
        if (!std.unicode.utf8ValidateSlice(bytes)) return self.refuseIn(.source_not_utf8, path, "", null);
        entry.source_start = @intCast(self.source_used);
        entry.source_length = @intCast(bytes.len);
        self.source_used += bytes.len;
    }

    /// Reads the regular file `name` of `folder` into `buffer`, whose last byte is room to see
    /// that the file has more: a file larger than `buffer.len - 1` bytes is `TooLarge`. Why it
    /// could not be read is left in `unread`, for the caller to name the file.
    fn readFile(self: *Storage, io: std.Io, folder: std.Io.Dir, name: []const u8, buffer: []u8) error{ Unreadable, TooLarge }![]const u8 {
        std.debug.assert(buffer.len >= 1);
        const maximum = buffer.len - 1;
        const file = openRegular(io, folder, name) catch |problem| return self.notRead(.unreadable, problem);
        defer file.close(io);
        const stat = file.stat(io) catch |problem| return self.notRead(.unreadable, problem);
        if (stat.kind == .sym_link) return self.notRead(.symbolic_link, null);
        if (stat.kind != .file) return self.notRead(.not_file_or_folder, null);
        if (stat.size > maximum) return error.TooLarge;
        const count = file.readPositionalAll(io, buffer, 0) catch |problem| return self.notRead(.unreadable, problem);
        if (count > maximum) return error.TooLarge;
        return buffer[0..count];
    }

    fn notRead(self: *Storage, reason: Reason, problem: ?anyerror) error{Unreadable} {
        self.unread = .{ .reason = reason, .problem = problem };
        return error.Unreadable;
    }

    /// Records a refusal about a path of the project directory itself (`forbic.json`, `src`), or
    /// about the directory when `path` is empty.
    fn refuseTop(self: *Storage, reason: Reason, path: []const u8, problem: ?anyerror) error{Refused} {
        self.refusal = .{ .reason = reason, .error_name = if (problem) |known| @errorName(known) else null };
        @memcpy(self.refusal.path_bytes[0..path.len], path);
        self.refusal.path_length = path.len;
        return error.Refused;
    }

    /// Records a refusal about `src/FOLDER/NAME` (`src/FOLDER` when `name` is empty, `src` when
    /// both are), cut at the refusal's capacity.
    fn refuseIn(self: *Storage, reason: Reason, folder: []const u8, name: []const u8, problem: ?anyerror) error{Refused} {
        self.refusal = .{ .reason = reason, .error_name = if (problem) |known| @errorName(known) else null };
        var writer: std.Io.Writer = .fixed(&self.refusal.path_bytes);
        writer.writeAll(sources_name) catch {};
        if (folder.len != 0) writer.writeByte('/') catch {};
        writer.writeAll(folder) catch {};
        if (name.len != 0) writer.writeByte('/') catch {};
        writer.writeAll(name) catch {};
        self.refusal.path_length = writer.end;
        return error.Refused;
    }

    /// The packet of the tree: `{"root":ROOT,"modules":[{"path":P,"source":S},...]}`, minified,
    /// the sources in the order of `files`. Its capacity is the packet's own bound, which holds
    /// any project within the walk's bounds.
    fn writePacket(self: *Storage, root: []const u8, files: []const forbic.modules.Input) []const u8 {
        var out: std.Io.Writer = .fixed(&self.packet);
        writeTree(&out, root, files) catch unreachable;
        return out.buffered();
    }
};

fn writeTree(out: *std.Io.Writer, root: []const u8, files: []const forbic.modules.Input) std.Io.Writer.Error!void {
    try out.writeAll("{\"root\":");
    try std.json.Stringify.encodeJsonString(root, .{}, out);
    try out.writeAll(",\"modules\":[");
    for (files, 0..) |file, index| {
        if (index != 0) try out.writeByte(',');
        try out.writeAll("{\"path\":");
        try std.json.Stringify.encodeJsonString(file.path, .{}, out);
        try out.writeAll(",\"source\":");
        try std.json.Stringify.encodeJsonString(file.source, .{}, out);
        try out.writeByte('}');
    }
    try out.writeAll("]}");
}

fn before(_: void, a: forbic.modules.Input, b: forbic.modules.Input) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Whether `folder` (a path under `src/`) is a module path once it starts with a slash.
fn folderIsModule(folder: []const u8) bool {
    var room: [path_capacity + 1]u8 = undefined;
    std.debug.assert(folder.len < room.len);
    room[0] = '/';
    @memcpy(room[1..][0..folder.len], folder);
    return forbic.modules.modulePath(room[0 .. folder.len + 1]);
}

/// `directory` without the separators it ends in, so that a path joined to it has one; a
/// directory that is nothing but separators (`/`) is kept.
pub fn withoutSeparator(directory: []const u8) []const u8 {
    var end = directory.len;
    while (end > 1 and (directory[end - 1] == '/' or directory[end - 1] == '\\')) end -= 1;
    return directory[0..end];
}

/// Whether a source lies directly in the folder of `root` (`/d/A` is the folder `d/A`).
fn rootHasSources(root: []const u8, files: []const forbic.modules.Input) bool {
    const folder = root[1..];
    for (files) |file| {
        if (file.path.len <= folder.len + 1 or !std.mem.startsWith(u8, file.path, folder) or file.path[folder.len] != '/') continue;
        if (std.mem.indexOfScalar(u8, file.path[folder.len + 1 ..], '/') == null) return true;
    }
    return false;
}

/// Opens a regular file of `folder` without following a link. On Linux the open does not block,
/// so a pipe put in a file's place between the walk and the open cannot stall the host before
/// its kind is refused (as `input.zig` does for a source named on the command line).
fn openRegular(io: std.Io, folder: std.Io.Dir, name: []const u8) !std.Io.File {
    if (builtin.os.tag != .linux) return folder.openFile(io, name, .{ .follow_symlinks = false });
    const linux = std.os.linux;
    var terminated: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    if (name.len >= terminated.len) return error.NameTooLong;
    @memcpy(terminated[0..name.len], name);
    terminated[name.len] = 0;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true, .NOFOLLOW = true };
    for (0..4) |_| {
        const result = linux.openat(folder.handle, terminated[0..name.len :0], flags, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return .{ .handle = @intCast(result), .flags = .{ .nonblocking = true } },
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.InputOpen,
        }
    }
    return error.InputInterrupted;
}

// ---------------------------------------------------------------------------------------------
// Tests

const File = struct { path: []const u8, data: []const u8 };

/// Writes `files` under `at`, making their folders.
fn makeTree(io: std.Io, at: std.Io.Dir, files: []const File) !void {
    for (files) |file| {
        if (std.fs.path.dirnamePosix(file.path)) |folder| try at.createDirPath(io, folder);
        try at.writeFile(io, .{ .sub_path = file.path, .data = file.data });
    }
}

/// A fresh storage for one test; `release` it.
fn testStorage() !*Storage {
    const storage = try forbic.scratch.storage(Storage);
    forbic.scratch.initialise(storage);
    return storage;
}

const hello_manifest: File = .{ .path = "forbic.json", .data = "{\"root\": \"/user@example.com/Hello\"}\n" };

test "a project is read into the packet of its tree: its sources in the order of their paths, nothing else" {
    const io = std.testing.io;
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    const files = [_]File{
        hello_manifest,
        .{ .path = "README.md", .data = "not a source" },
        .{ .path = "src/user@example.com/Hello/main.forb", .data = "Kit := import{/user@example.com/Kit}\nAnswer<public>:i64 = Kit.Base + Extra\n" },
        .{ .path = "src/user@example.com/Hello/extra.forb", .data = "Extra:i64 = 2\n" },
        .{ .path = "src/user@example.com/Hello/notes.txt", .data = "left out" },
        .{ .path = "src/user@example.com/Kit/base.forb", .data = "Base<public>:i64 = 40 # \"quoted\"\t\\\n" },
        .{ .path = "src/.hidden/ignored.forb", .data = "left out too" },
        .{ .path = "src/user@example.com/Hello/.draft.forb", .data = "and this" },
        .{ .path = "src/user@example.com/Empty/.keep", .data = "" },
    };
    try makeTree(io, first.dir, &files);
    // The same tree written in the other order: the file system may list it differently.
    var reversed: [files.len]File = files;
    std.mem.reverse(File, &reversed);
    try makeTree(io, second.dir, &reversed);
    const expected = "{\"root\":\"/user@example.com/Hello\",\"modules\":[" ++
        "{\"path\":\"user@example.com/Hello/extra.forb\",\"source\":\"Extra:i64 = 2\\n\"}," ++
        "{\"path\":\"user@example.com/Hello/main.forb\",\"source\":\"Kit := import{/user@example.com/Kit}\\nAnswer<public>:i64 = Kit.Base + Extra\\n\"}," ++
        "{\"path\":\"user@example.com/Kit/base.forb\",\"source\":\"Base<public>:i64 = 40 # \\\"quoted\\\"\\t\\\\\\n\"}]}";
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var directories: [2][std.Io.Dir.max_path_bytes]u8 = undefined;
    for ([_]std.Io.Dir{ first.dir, second.dir }, &directories) |tree, *room| {
        const length = try tree.realPath(io, room);
        const read = switch (storage.load(io, room[0..length])) {
            .ok => |read| read,
            .refused => |refusal| {
                std.debug.print("refused: {s} {s}\n", .{ @tagName(refusal.reason), refusal.path() });
                return error.TestUnexpectedResult;
            },
        };
        try std.testing.expectEqualStrings("/user@example.com/Hello", read.root);
        try std.testing.expectEqualStrings(expected, read.packet);
        try std.testing.expectEqual(@as(usize, 3), read.files.len);
        try std.testing.expectEqualStrings("user@example.com/Kit/base.forb", read.files[2].path);
        // The packet is one the bundle reader takes, with the same inventory.
        const packet = try forbic.scratch.storage(forbic.bundle_packet.Workspace);
        defer forbic.scratch.release(packet);
        forbic.scratch.initialise(packet);
        const bundle = try packet.parse(read.packet);
        try std.testing.expectEqualStrings(read.root, bundle.root);
        for (bundle.modules, read.files) |parsed, file| {
            try std.testing.expectEqualStrings(file.path, parsed.path);
            try std.testing.expectEqualStrings(file.source, parsed.source);
        }
    }
}

/// Loads the project in `tree` and expects it refused for `reason` at `path` (relative to the
/// project directory), with `message` written after `DIR/PATH: error: `.
fn expectRefused(storage: *Storage, io: std.Io, tree: std.Io.Dir, reason: Reason, path: []const u8, message: []const u8) !void {
    var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tree.realPath(io, &room);
    try expectRefusedAt(storage, io, room[0..length], reason, path, message);
}

fn expectRefusedAt(storage: *Storage, io: std.Io, directory: []const u8, reason: Reason, path: []const u8, message: []const u8) !void {
    const refusal = switch (storage.load(io, directory)) {
        .ok => return error.TestUnexpectedResult,
        .refused => |refusal| refusal,
    };
    try std.testing.expectEqual(reason, refusal.reason);
    try std.testing.expectEqualStrings(path, refusal.path());
    var bytes: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    try refusal.write(&out, directory);
    var expected_bytes: [2048]u8 = undefined;
    const expected = if (path.len == 0)
        try std.fmt.bufPrint(&expected_bytes, "{s}: error: {s}\n", .{ directory, message })
    else
        try std.fmt.bufPrint(&expected_bytes, "{s}/{s}: error: {s}\n", .{ directory, path, message });
    try std.testing.expectEqualStrings(expected, out.buffered());
}

test "a project's manifest names its root module and nothing else, or the project is refused" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &room);
    var missing_room: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_room, "{s}/missing", .{room[0..length]});
    try expectRefusedAt(storage, io, missing, .no_directory, "", "cannot open the project directory (FileNotFound)");
    try expectRefused(storage, io, temporary.dir, .no_manifest, "", "is not a Forbic project: it has no forbic.json naming its root module");
    try makeTree(io, temporary.dir, &.{.{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" }});
    const invalid = "the manifest must be one JSON object with one field, \"root\", a module path such as \"/user@example.com/App\"";
    for ([_]struct { []const u8, []const u8 }{
        .{ "", "UnexpectedEndOfInput" },
        .{ "[]", "UnexpectedToken" },
        .{ "{}", "MissingField" },
        .{ "{\"root\": 1}", "UnexpectedToken" },
        .{ "{\"root\": \"/user@example.com/Hello\", \"state\": \"s\"}", "UnknownField" },
        .{ "{\"root\": \"/user@example.com/Hello\", \"root\": \"/user@example.com/Hello\"}", "DuplicateField" },
        .{ "{\"root\": \"/user@example.com/Hello\"} {}", "SyntaxError" },
    }) |case| {
        try temporary.dir.writeFile(io, .{ .sub_path = manifest_name, .data = case[0] });
        var message_bytes: [512]u8 = undefined;
        try expectRefused(storage, io, temporary.dir, .manifest_invalid, manifest_name, try std.fmt.bufPrint(&message_bytes, "{s} ({s})", .{ invalid, case[1] }));
    }
    for ([_][]const u8{ "user@example.com/Hello", "/", "/user@example.com/Hello/", "/user@example.com//Hello", "/-x/Hello" }) |root| {
        var manifest_bytes: [128]u8 = undefined;
        try temporary.dir.writeFile(io, .{ .sub_path = manifest_name, .data = try std.fmt.bufPrint(&manifest_bytes, "{{\"root\":\"{s}\"}}", .{root}) });
        try expectRefused(storage, io, temporary.dir, .root_invalid, manifest_name, "\"root\" must be a module path such as \"/user@example.com/App\": a slash, a domain, then names, each after a slash");
    }
    // A root whose folder has only subfolders, or does not exist, has nothing to run.
    for ([_][]const u8{ "/user@example.com", "/user@example.com/Other" }) |root| {
        var manifest_bytes: [128]u8 = undefined;
        try temporary.dir.writeFile(io, .{ .sub_path = manifest_name, .data = try std.fmt.bufPrint(&manifest_bytes, "{{\"root\":\"{s}\"}}", .{root}) });
        try expectRefused(storage, io, temporary.dir, .root_without_sources, manifest_name, "\"root\" names no folder of src/ that holds .forb files");
    }
    // The bound of a manifest, whitespace included.
    const large = try std.testing.allocator.alloc(u8, manifest_capacity + 1);
    defer std.testing.allocator.free(large);
    @memset(large, ' ');
    const valid = "{\"root\":\"/user@example.com/Hello\"}";
    @memcpy(large[0..valid.len], valid);
    try temporary.dir.writeFile(io, .{ .sub_path = manifest_name, .data = large[0..manifest_capacity] });
    switch (storage.load(io, room[0..length])) {
        .ok => {},
        .refused => return error.TestUnexpectedResult,
    }
    try temporary.dir.writeFile(io, .{ .sub_path = manifest_name, .data = large });
    try expectRefused(storage, io, temporary.dir, .manifest_too_large, manifest_name, "the manifest holds more than 4096 bytes");
    // A manifest that is a folder.
    try temporary.dir.deleteFile(io, manifest_name);
    try temporary.dir.createDirPath(io, manifest_name);
    try expectRefused(storage, io, temporary.dir, .not_file_or_folder, manifest_name, "is neither a regular file nor a folder");
}

test "a project keeps its sources in src/, a folder of its own" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try makeTree(io, temporary.dir, &.{hello_manifest});
    const missing = "a project keeps its sources in a folder src/, which is missing";
    try expectRefused(storage, io, temporary.dir, .no_sources_folder, "", missing);
    try temporary.dir.writeFile(io, .{ .sub_path = sources_name, .data = "a file" });
    try expectRefused(storage, io, temporary.dir, .no_sources_folder, "", missing);
    try temporary.dir.deleteFile(io, sources_name);
    try temporary.dir.createDirPath(io, sources_name);
    try expectRefused(storage, io, temporary.dir, .root_without_sources, manifest_name, "\"root\" names no folder of src/ that holds .forb files");
}

test "a project's files are its own: a symbolic link is refused wherever it stands" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try makeTree(io, outside.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
    var outside_room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const outside_length = try outside.dir.realPath(io, &outside_room);
    var target_room: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const message = "is a symbolic link; a project's files must be its own";
    for ([_]struct { link: []const u8, target: []const u8, folder: bool, path: []const u8 }{
        .{ .link = "src/user@example.com/Hello/linked.forb", .target = "src/user@example.com/Hello/main.forb", .folder = false, .path = "src/user@example.com/Hello/linked.forb" },
        .{ .link = "src/user@example.com/Linked", .target = "src/user@example.com/Hello", .folder = true, .path = "src/user@example.com/Linked" },
        .{ .link = "src", .target = "src", .folder = true, .path = "src" },
        .{ .link = "forbic.json", .target = "forbic.json", .folder = false, .path = "forbic.json" },
    }) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
        if (std.mem.eql(u8, case.link, "src")) try temporary.dir.deleteTree(io, "src");
        if (std.mem.eql(u8, case.link, "forbic.json")) try temporary.dir.deleteFile(io, "forbic.json");
        // A link to the other project, outside this one.
        const target = try std.fmt.bufPrint(&target_room, "{s}/{s}", .{ outside_room[0..outside_length], case.target });
        temporary.dir.symLink(io, target, case.link, .{ .is_directory = case.folder }) catch |problem| switch (problem) {
            // Windows grants links to administrators and to developer mode only.
            error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
            else => return problem,
        };
        try expectRefused(storage, io, temporary.dir, .symbolic_link, case.path, message);
    }
}

test "a project's walk is bounded: sources, entries, path length and source bytes, each refused past its bound" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    const gpa = std.testing.allocator;
    var name_room: [64]u8 = undefined;

    // `source_capacity` sources are a project; one more is refused.
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try makeTree(io, temporary.dir, &.{hello_manifest});
        try temporary.dir.createDirPath(io, "src/user@example.com/Hello");
        for (0..source_capacity) |index| {
            try temporary.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_room, "src/user@example.com/Hello/f{d:0>5}.forb", .{index}), .data = "" });
        }
        var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &room);
        switch (storage.load(io, room[0..length])) {
            .ok => |read| try std.testing.expectEqual(@as(usize, source_capacity), read.files.len),
            .refused => return error.TestUnexpectedResult,
        }
        try temporary.dir.writeFile(io, .{ .sub_path = "src/user@example.com/Hello/last.forb", .data = "" });
        var message: [128]u8 = undefined;
        try expectRefused(storage, io, temporary.dir, .too_many_sources, "", try std.fmt.bufPrint(&message, "the project has more than {d} .forb files", .{source_capacity}));
    }
    // Entries of any kind count: files that are no sources, and names left out.
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
        // Two folders and one source are entries already.
        for (0..entry_capacity - 3) |index| {
            try temporary.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_room, "src/{s}{d:0>5}.txt", .{ if (index % 2 == 0) "." else "n", index }), .data = "" });
        }
        var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &room);
        switch (storage.load(io, room[0..length])) {
            .ok => |read| try std.testing.expectEqual(@as(usize, 1), read.files.len),
            .refused => return error.TestUnexpectedResult,
        }
        try temporary.dir.writeFile(io, .{ .sub_path = "src/one-more.txt", .data = "" });
        var message: [128]u8 = undefined;
        try expectRefused(storage, io, temporary.dir, .too_many_entries, "", try std.fmt.bufPrint(&message, "the project's src/ holds more than {d} entries (folders and files)", .{entry_capacity}));
    }
    // Entries the walk keeps (folders and sources) fill the bound exactly, beside the root folder.
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
        for (0..entry_capacity - 3) |index| {
            try temporary.dir.createDirPath(io, try std.fmt.bufPrint(&name_room, "src/folder{d:0>5}", .{index}));
        }
        var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &room);
        switch (storage.load(io, room[0..length])) {
            .ok => |read| try std.testing.expectEqual(@as(usize, 1), read.files.len),
            .refused => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, entry_capacity + 1), storage.entry_count);
        try temporary.dir.createDirPath(io, "src/one-more");
        var message: [128]u8 = undefined;
        try expectRefused(storage, io, temporary.dir, .too_many_entries, "", try std.fmt.bufPrint(&message, "the project's src/ holds more than {d} entries (folders and files)", .{entry_capacity}));
    }
    // A path under src/ of `path_capacity` bytes is read; one byte more is refused, at its folder.
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
        // Folders of 100 bytes each (names within `identifier_bytes`), then a file that makes the
        // path exactly the capacity.
        var folder: std.ArrayList(u8) = .empty;
        defer folder.deinit(gpa);
        try folder.appendSlice(gpa, "user@example.com/Hello");
        while (path_capacity - folder.items.len > 100 + 1 + 16) {
            try folder.append(gpa, '/');
            try folder.appendNTimes(gpa, 'd', 100);
        }
        const name_length = path_capacity - folder.items.len - 1;
        const name = try gpa.alloc(u8, name_length + 1);
        defer gpa.free(name);
        @memset(name, 'n');
        @memcpy(name[name_length - source_suffix.len ..][0..source_suffix.len], source_suffix);
        const sub_path = try std.fmt.allocPrint(gpa, "src/{s}", .{folder.items});
        defer gpa.free(sub_path);
        var sub = try temporary.dir.createDirPathOpen(io, sub_path, .{});
        defer sub.close(io);
        try sub.writeFile(io, .{ .sub_path = name[0..name_length], .data = "" });
        var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &room);
        switch (storage.load(io, room[0..length])) {
            // The long path sorts first: `d` before `m`.
            .ok => |read| try std.testing.expectEqual(@as(usize, path_capacity), read.files[0].path.len),
            .refused => |refusal| {
                std.debug.print("refused: {s} {s}\n", .{ @tagName(refusal.reason), refusal.path() });
                return error.TestUnexpectedResult;
            },
        }
        try sub.deleteFile(io, name[0..name_length]);
        @memcpy(name[name_length + 1 - source_suffix.len ..][0..source_suffix.len], source_suffix);
        try sub.writeFile(io, .{ .sub_path = name, .data = "" });
        const expected_path = try std.fmt.allocPrint(gpa, "src/{s}/{s}", .{ folder.items, name });
        defer gpa.free(expected_path);
        var message: [128]u8 = undefined;
        try expectRefused(storage, io, temporary.dir, .path_too_long, expected_path, try std.fmt.bufPrint(&message, "the path under src/ is longer than {d} bytes", .{path_capacity}));
    }
    // Sources of `source_bytes` together are read; one byte more is refused.
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const half = limits.source_bytes / 2;
        const text = try gpa.alloc(u8, limits.source_bytes - half + 1);
        defer gpa.free(text);
        @memset(text, '\n');
        // Two files of one folder are joined by a newline, which the bound counts.
        try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/a.forb", .data = text[0..half] }, .{ .path = "src/user@example.com/Hello/b.forb", .data = text[0 .. limits.source_bytes - half - 1] } });
        var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &room);
        switch (storage.load(io, room[0..length])) {
            .ok => |read| try std.testing.expectEqual(@as(usize, limits.source_bytes - 1), read.files[0].source.len + read.files[1].source.len),
            .refused => return error.TestUnexpectedResult,
        }
        try temporary.dir.writeFile(io, .{ .sub_path = "src/user@example.com/Hello/b.forb", .data = text[0 .. limits.source_bytes - half] });
        var message: [160]u8 = undefined;
        const too_large = try std.fmt.bufPrint(&message, "the project's sources hold more than {d} bytes together, with a newline between the files of each folder", .{limits.source_bytes});
        try expectRefused(storage, io, temporary.dir, .sources_too_large, "", too_large);
        // Files of two folders are not joined: together they may fill the bound exactly.
        try temporary.dir.deleteFile(io, "src/user@example.com/Hello/b.forb");
        try makeTree(io, temporary.dir, &.{.{ .path = "src/user@example.com/Kit/b.forb", .data = text[0 .. limits.source_bytes - half] }});
        switch (storage.load(io, room[0..length])) {
            .ok => |read| try std.testing.expectEqual(@as(usize, limits.source_bytes), read.files[0].source.len + read.files[1].source.len),
            .refused => return error.TestUnexpectedResult,
        }
        try temporary.dir.writeFile(io, .{ .sub_path = "src/user@example.com/Kit/b.forb", .data = text });
        try expectRefused(storage, io, temporary.dir, .sources_too_large, "", too_large);
    }
}

test "a project's sources are UTF-8 text, which a packet carries" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:string = \"caf\xc3\xa9\"\n" } });
    var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &room);
    switch (storage.load(io, room[0..length])) {
        .ok => |read| try std.testing.expect(std.mem.indexOf(u8, read.packet, "caf\xc3\xa9") != null),
        .refused => return error.TestUnexpectedResult,
    }
    try temporary.dir.writeFile(io, .{ .sub_path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1 # \xff\n" });
    try expectRefused(storage, io, temporary.dir, .source_not_utf8, "src/user@example.com/Hello/main.forb", "is not UTF-8 text");
}

test "Linux: a pipe in a project is refused without waiting for a writer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
    var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &room);
    var fifo_room: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const fifo = try std.mem.printSentinel(&fifo_room, "{s}/src/user@example.com/Hello/waiting.forb", .{room[0..length]}, 0);
    const linux = std.os.linux;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0)));
    try expectRefused(storage, io, temporary.dir, .not_file_or_folder, "src/user@example.com/Hello/waiting.forb", "is neither a regular file nor a folder");
}

test "a source belongs to a module: a folder holding sources has a module path, and src/ holds none itself" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    const gpa = std.testing.allocator;
    const folder_message = "holds .forb files, so it is a module, but its path is no module path: a domain (letters, digits, _, ., @ and -, such as hello@example.com), then names (a letter or _, then letters, digits and _), each after a slash";
    for ([_][]const u8{ "user@example.com/my-lib", "user@example.com/My Lib", "user@example.com/1Lib", "user@example.com/a.b", "-x/Lib" }) |folder| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(gpa, "src/{s}/a.forb", .{folder});
        defer gpa.free(path);
        try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" }, .{ .path = path, .data = "B:i64 = 2\n" } });
        const refused = try std.fmt.allocPrint(gpa, "src/{s}", .{folder});
        defer gpa.free(refused);
        try expectRefused(storage, io, temporary.dir, .folder_not_module, refused, folder_message);
    }
    // A folder with no source is no module, whatever its name; a domain alone is one.
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" }, .{ .path = "src/notes and drafts/x.txt", .data = "" }, .{ .path = "src/user@example.com/top.forb", .data = "" } });
    var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &room);
    switch (storage.load(io, room[0..length])) {
        .ok => |read| try std.testing.expectEqual(@as(usize, 2), read.files.len),
        .refused => return error.TestUnexpectedResult,
    }
    try makeTree(io, temporary.dir, &.{.{ .path = "src/main.forb", .data = "" }});
    try expectRefused(storage, io, temporary.dir, .source_outside_module, "src/main.forb", "lies in no module: a source belongs in a folder of src/ whose path is a module path, such as src/hello@example.com/App/");
}

test "a file the walk leaves out is not examined: a long name is no refusal" {
    const io = std.testing.io;
    const storage = try testStorage();
    defer forbic.scratch.release(storage);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try makeTree(io, temporary.dir, &.{ hello_manifest, .{ .path = "src/user@example.com/Hello/main.forb", .data = "A:i64 = 1\n" } });
    var name: [200]u8 = undefined;
    @memset(&name, 'n');
    var sub = try temporary.dir.openDir(io, "src/user@example.com/Hello", .{});
    defer sub.close(io);
    // The folder's path and this name are longer than a path under src/ may be.
    const folder_name: [path_capacity - 200 - 1]u8 = @splat('d');
    var folder = try sub.createDirPathOpen(io, &folder_name, .{});
    defer folder.close(io);
    try folder.writeFile(io, .{ .sub_path = &name, .data = "" });
    var room: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &room);
    switch (storage.load(io, room[0..length])) {
        .ok => |read| try std.testing.expectEqual(@as(usize, 1), read.files.len),
        .refused => |refusal| {
            std.debug.print("refused: {s} {s}\n", .{ @tagName(refusal.reason), refusal.path() });
            return error.TestUnexpectedResult;
        },
    }
}

test "a project directory named with trailing separators joins its paths with one" {
    try std.testing.expectEqualStrings("p", withoutSeparator("p/"));
    try std.testing.expectEqualStrings("p", withoutSeparator("p\\/"));
    try std.testing.expectEqualStrings("a/p", withoutSeparator("a/p"));
    try std.testing.expectEqualStrings("/", withoutSeparator("//"));
    var refusal: Refusal = .{ .reason = .no_sources_folder };
    refusal.path_length = 0;
    var bytes: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    refusal = .{ .reason = .symbolic_link };
    @memcpy(refusal.path_bytes[0..3], "src");
    refusal.path_length = 3;
    try refusal.write(&out, "p//");
    try std.testing.expectEqualStrings("p/src: error: is a symbolic link; a project's files must be its own\n", out.buffered());
}
