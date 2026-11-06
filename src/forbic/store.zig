//! The store of persistent cells (RFC-0087, P5.5: S1, S6, S7): what the host keeps between
//! sessions, and what publication builds from the durable prefix of a journal.
//!
//! A store is three kinds of file, each written whole, once, and never changed:
//!
//! - **objects**, named by the SHA-256 of their bytes: the text of an entry (the canonical JSON of
//!   its value, E2) or of a schema;
//! - **generations**, named by the SHA-256 of their bytes: a manifest, the canonical JSON of the
//!   generation's number, its parent, the object of the schema of the program that published it
//!   (G2) and a list of `(cell, key, object)` sorted by cell and key;
//! - **`active`**, the one file that is replaced: the name of the generation a run starts on.
//!
//! This file holds what does not depend on an operating system: the format, the rules of
//! publication, and the `Disk` a store is written to (a directory in the host, a simulated one in
//! tests and the DST, so that every disk operation can fail or crash deterministically). A `put` is
//! one disk operation that is complete and durable when it returns; a crash during it leaves the
//! file whole or absent. Publication writes the objects, then the generation, then `active`, so a
//! crash leaves `active` naming the generation it named before, or the new one with everything it
//! names already on the disk. Publishing the same writes again after a crash writes the same
//! files: a function of the base and the writes (S6).
//!
//! The reader trusts nothing it reads: a name is a hash of the bytes it names, a manifest is
//! parsed strictly and must be the text this file would write for what it says, and a store that
//! is not so is `StoreFailed`, with the reason in `Store.why`.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [32]u8;
pub const Hex = [64]u8;
pub const format_version: u32 = 1;

pub fn hashOf(bytes: []const u8) Hash {
    var digest: Hash = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}
pub fn hexOf(hash: Hash) Hex {
    return std.fmt.bytesToHex(hash, .lower);
}
fn unhex(text: []const u8) ?Hash {
    if (text.len != 64) return null;
    var out: Hash = undefined;
    for (&out, 0..) |*byte, index| {
        const high = nibble(text[2 * index]) orelse return null;
        const low = nibble(text[2 * index + 1]) orelse return null;
        byte.* = high << 4 | low;
    }
    return out;
}
fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

pub const Area = enum { objects, generations, root };
/// The one file of `Area.root`.
pub const active_name = "active";

pub const DiskError = error{ DiskFailed, TooLarge };

/// The length of `active`: a hash in hex and a newline.
pub const active_bytes: usize = 65;
/// The largest object the store reads (RFC-0087): an entry's text reaches the store in one journal
/// record, so no text it wrote is longer than a record's payload (`durable.max_payload`); a schema
/// is smaller. A longer file under an object's name was not written here.
pub const max_object_bytes: usize = 1 << 27;
/// The largest manifest the store reads and writes: it is read whole and parsed into memory, and
/// no more bytes than an object holds; a publication that would make a longer one is refused
/// (`StoreFailed`), and a longer file was not written here.
pub const max_manifest_bytes: usize = 1 << 27;

/// Where a store lies. Each call is one disk operation, which may fail.
pub const Disk = struct {
    context: *anyopaque,
    /// The whole file `name` of `area`, in memory of `gpa`; null when there is none. A file of more
    /// than `limit` bytes is `TooLarge`, before any of it is read or any memory is taken for it.
    read: *const fn (context: *anyopaque, gpa: std.mem.Allocator, area: Area, name: []const u8, limit: usize) DiskError!?[]u8,
    /// Writes the whole file `name` of `area`, replacing one: complete and durable when it returns.
    put: *const fn (context: *anyopaque, area: Area, name: []const u8, bytes: []const u8) DiskError!void,
};

pub const Error = DiskError || error{ OutOfMemory, StoreFailed, ActiveMoved };

/// One saved entry: the value of `key` in the persistent cell `cell` (S2), as the object that holds
/// its text.
pub const Entry = struct { cell: []const u8, key: []const u8, object: Hash };

pub fn entryLess(_: void, a: Entry, b: Entry) bool {
    return order(a.cell, a.key, b.cell, b.key) == .lt;
}
fn order(cell_a: []const u8, key_a: []const u8, cell_b: []const u8, key_b: []const u8) std.math.Order {
    const cells = std.mem.order(u8, cell_a, cell_b);
    return if (cells != .eq) cells else std.mem.order(u8, key_a, key_b);
}

/// A generation as its manifest says it (S1): the entries are sorted by cell and key, without
/// repeats.
pub const Generation = struct {
    number: u64,
    parent: ?Hash,
    schema: Hash,
    entries: []const Entry,

    /// The entry of `key` in `cell`, by binary search.
    pub fn find(self: Generation, cell: []const u8, key: []const u8) ?Entry {
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = self.entries[middle];
            switch (order(entry.cell, entry.key, cell, key)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return entry,
            }
        }
        return null;
    }
};

/// The manifest of `generation`, the text its name is the hash of.
pub fn render(gpa: std.mem.Allocator, generation: Generation) std.mem.Allocator.Error![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    renderTo(&text.writer, generation) catch return error.OutOfMemory;
    return text.toOwnedSlice();
}
fn renderTo(out: *std.Io.Writer, generation: Generation) std.Io.Writer.Error!void {
    try out.print("{{\"forbic_store\":{d},\"number\":{d},\"parent\":", .{ format_version, generation.number });
    if (generation.parent) |parent| try out.print("\"{s}\"", .{hexOf(parent)}) else try out.writeAll("null");
    try out.print(",\"schema\":\"{s}\",\"entries\":[", .{hexOf(generation.schema)});
    for (generation.entries, 0..) |entry, index| {
        if (index != 0) try out.writeByte(',');
        try out.writeAll("{\"cell\":");
        try std.json.Stringify.encodeJsonString(entry.cell, .{}, out);
        try out.writeAll(",\"key\":");
        try std.json.Stringify.encodeJsonString(entry.key, .{}, out);
        try out.print(",\"object\":\"{s}\"}}", .{hexOf(entry.object)});
    }
    try out.writeAll("]}\n");
}

const Wire = struct {
    forbic_store: u32,
    number: u64,
    parent: ?[]const u8,
    schema: []const u8,
    entries: []const WireEntry,
};
const WireEntry = struct { cell: []const u8, key: []const u8, object: []const u8 };

/// A manifest, read strictly: JSON of the shape `render` writes, entries sorted without repeats,
/// names that are hashes, and exactly the text `render` writes for what it says. Allocated in
/// `arena`; null for a text that is none of these.
pub fn parse(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?Generation {
    const wire = std.json.parseFromSliceLeaky(Wire, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (wire.forbic_store != format_version) return null;
    const schema = unhex(wire.schema) orelse return null;
    const parent: ?Hash = if (wire.parent) |named| (unhex(named) orelse return null) else null;
    const entries = try arena.alloc(Entry, wire.entries.len);
    for (wire.entries, entries, 0..) |held, *out, index| {
        out.* = .{ .cell = held.cell, .key = held.key, .object = unhex(held.object) orelse return null };
        if (index != 0 and order(entries[index - 1].cell, entries[index - 1].key, out.cell, out.key) != .lt) return null;
    }
    const generation: Generation = .{ .number = wire.number, .parent = parent, .schema = schema, .entries = entries };
    const again = try render(arena, generation);
    return if (std.mem.eql(u8, again, text)) generation else null;
}

/// The text a store action carries (RFC-0087 S5): the cell's store name, the key's name, and the
/// entry's text, which is the action's bytes after `"value":` and before the closing brace.
pub const Action = struct { cell: []const u8, key: []const u8, value: []const u8 };

/// `{"cell":NAME,"key":NAME,"value":TEXT}` as `persist_json.encodeStoreAction` writes it, or null
/// for any other text. The names are unescaped into `arena`; `value` lies in `text`.
pub fn parseAction(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?Action {
    var at: usize = 0;
    if (!std.mem.startsWith(u8, text, "{\"cell\":")) return null;
    at += 8;
    const cell = (try unescaped(arena, text, &at)) orelse return null;
    if (!std.mem.startsWith(u8, text[at..], ",\"key\":")) return null;
    at += 7;
    const key = (try unescaped(arena, text, &at)) orelse return null;
    if (!std.mem.startsWith(u8, text[at..], ",\"value\":")) return null;
    at += 9;
    if (text.len < at + 2 or text[text.len - 1] != '}') return null;
    return .{ .cell = cell, .key = key, .value = text[at .. text.len - 1] };
}

/// A JSON string at `at` of `text`, unescaped; `at` moves past its closing quote.
fn unescaped(arena: std.mem.Allocator, text: []const u8, at: *usize) std.mem.Allocator.Error!?[]u8 {
    if (at.* >= text.len or text[at.*] != '"') return null;
    var out: std.ArrayList(u8) = .empty;
    var index = at.* + 1;
    while (true) {
        if (index >= text.len) return null;
        const c = text[index];
        if (c == '"') break;
        if (c < 0x20) return null;
        if (c != '\\') {
            try out.append(arena, c);
            index += 1;
            continue;
        }
        if (index + 1 >= text.len) return null;
        const e = text[index + 1];
        index += 2;
        switch (e) {
            '"', '\\', '/' => try out.append(arena, e),
            'b' => try out.append(arena, 0x08),
            'f' => try out.append(arena, 0x0C),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            't' => try out.append(arena, '\t'),
            'u' => {
                const first = hex4(text, &index) orelse return null;
                var code: u21 = first;
                if (first >= 0xD800 and first < 0xDC00) {
                    if (!std.mem.startsWith(u8, text[index..], "\\u")) return null;
                    index += 2;
                    const second = hex4(text, &index) orelse return null;
                    if (second < 0xDC00 or second >= 0xE000) return null;
                    code = 0x10000 + ((@as(u21, first) - 0xD800) << 10) + (second - 0xDC00);
                } else if (first >= 0xDC00 and first < 0xE000) return null;
                var bytes: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(code, &bytes) catch return null;
                try out.appendSlice(arena, bytes[0..length]);
            },
            else => return null,
        }
    }
    at.* = index + 1;
    return try out.toOwnedSlice(arena);
}
fn hex4(text: []const u8, index: *usize) ?u16 {
    if (text.len - index.* < 4) return null;
    var value: u16 = 0;
    for (text[index.*..][0..4]) |c| {
        const digit = std.fmt.charToDigit(c, 16) catch return null;
        value = value << 4 | digit;
    }
    index.* += 4;
    return value;
}

/// The last write of each entry among the store actions of a durable prefix, in sequence order (S6):
/// a later write of an entry replaces an earlier one.
pub const Updates = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringArrayHashMapUnmanaged(Update) = .empty,
    /// Actions that were no store action (a journal edited to hold a text this build did not write).
    malformed: u64 = 0,

    pub const Update = struct { cell: []const u8, key: []const u8, text: []u8 };

    pub fn init(gpa: std.mem.Allocator) Updates {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }
    pub fn deinit(self: *Updates) void {
        var values = self.map.iterator();
        while (values.next()) |held| self.gpa.free(held.value_ptr.text);
        self.map.deinit(self.gpa);
        self.arena.deinit();
    }
    /// Takes one store action. A text that is none is counted in `malformed`: the caller refuses it.
    /// The names of an action are parsed into scratch that the next action reuses; only an entry
    /// met for the first time keeps a copy, so the memory held is the entries' and not the actions'.
    pub fn add(self: *Updates, text: []const u8) std.mem.Allocator.Error!void {
        var scratch_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const parsed = (try parseAction(scratch, text)) orelse {
            self.malformed += 1;
            return;
        };
        // One name per entry: the lengths of the two names first, so no two entries share one.
        const name = try std.fmt.allocPrint(scratch, "{d}:{s}{s}", .{ parsed.cell.len, parsed.cell, parsed.key });
        const copy = try self.gpa.dupe(u8, parsed.value);
        errdefer self.gpa.free(copy);
        if (self.map.getPtr(name)) |held| {
            self.gpa.free(held.text);
            held.text = copy;
            return;
        }
        const kept = self.arena.allocator();
        const cell = try kept.dupe(u8, parsed.cell);
        const key = try kept.dupe(u8, parsed.key);
        try self.map.put(self.gpa, try kept.dupe(u8, name), .{ .cell = cell, .key = key, .text = copy });
    }
    /// The updates sorted by cell and key. Owned by `gpa`.
    pub fn sorted(self: *Updates) std.mem.Allocator.Error![]Update {
        const list = try self.gpa.dupe(Update, self.map.values());
        std.mem.sort(Update, list, {}, struct {
            fn less(_: void, a: Update, b: Update) bool {
                return order(a.cell, a.key, b.cell, b.key) == .lt;
            }
        }.less);
        return list;
    }
};

/// A store on a `Disk`.
pub const Store = struct {
    disk: Disk,
    gpa: std.mem.Allocator,
    /// What a `StoreFailed` is about, borrowed or static.
    why: []const u8 = "",
    /// The longest manifest read or written; a test lowers it.
    manifest_limit: usize = max_manifest_bytes,

    pub fn failed(self: *Store, reason: []const u8) error{StoreFailed} {
        self.why = reason;
        return error.StoreFailed;
    }

    /// The generation `active` names, or null for a store without one (a first run). `arena`
    /// holds the manifest it parses.
    pub fn active(self: *Store, arena: std.mem.Allocator) Error!?Active {
        const named = (try self.activeName()) orelse return null;
        return .{ .hash = named, .generation = try self.generation(arena, named) };
    }
    pub const Active = struct { hash: Hash, generation: Generation };

    /// The file `name` of `area` of at most `limit` bytes; a longer one is `StoreFailed`, `why` its
    /// reason (the disk refused it unread).
    fn read(self: *Store, area: Area, name: []const u8, limit: usize, why: []const u8) Error!?[]u8 {
        return self.disk.read(self.disk.context, self.gpa, area, name, limit) catch |problem| switch (problem) {
            error.TooLarge => self.failed(why),
            else => |other| other,
        };
    }

    /// The name `active` holds, or null when there is no file.
    pub fn activeName(self: *Store) Error!?Hash {
        const bytes = (try self.read(.root, active_name, active_bytes, "the file active is not a generation's name")) orelse return null;
        defer self.gpa.free(bytes);
        if (bytes.len != active_bytes or bytes[64] != '\n') return self.failed("the file active is not a generation's name");
        const named = unhex(bytes[0..64]) orelse return self.failed("the file active is not a generation's name");
        // All zero is the header's word for "no generation yet": no hash is.
        if (std.mem.allEqual(u8, &named, 0)) return self.failed("the file active is not a generation's name");
        return named;
    }

    pub fn generation(self: *Store, arena: std.mem.Allocator, hash: Hash) Error!Generation {
        const name = hexOf(hash);
        const bytes = (try self.read(.generations, &name, self.manifest_limit, "a generation is longer than a manifest can be")) orelse return self.failed("a generation the store names is missing");
        defer self.gpa.free(bytes);
        if (!std.mem.eql(u8, &hashOf(bytes), &hash)) return self.failed("a generation is not the bytes its name is the hash of");
        const parsed = (try parse(arena, bytes)) orelse return self.failed("a generation's manifest is not one");
        return parsed;
    }

    /// The text of the object `entry` names, in memory of `gpa`: checked against its name.
    pub fn text(self: *Store, entry: Entry) Error![]u8 {
        const name = hexOf(entry.object);
        const bytes = (try self.read(.objects, &name, max_object_bytes, "an object is longer than the store writes")) orelse return self.failed("an object the store names is missing");
        errdefer self.gpa.free(bytes);
        if (!std.mem.eql(u8, &hashOf(bytes), &entry.object)) return self.failed("an object is not the bytes its name is the hash of");
        // Every object is text (an entry's JSON, a schema): one that is not was not written here.
        if (!std.unicode.utf8ValidateSlice(bytes)) return self.failed("an object is not text");
        return bytes;
    }

    /// Writes `bytes` as an object and gives its name.
    pub fn putObject(self: *Store, bytes: []const u8) Error!Hash {
        const hash = hashOf(bytes);
        const name = hexOf(hash);
        try self.disk.put(self.disk.context, .objects, &name, bytes);
        return hash;
    }

    /// S6: the generation that follows `base` (none for a first one) with `updates` applied, written
    /// and made active; its name, or null when there is nothing to publish. `updates` are sorted by
    /// cell and key, without repeats. Objects first, then the generation, then `active`: whichever
    /// operation a crash stops at, `active` names `base` or the new generation, whose files are all
    /// there. `active` is replaced only if it names `base` (or already the new generation, as after
    /// a crash that stopped after it): otherwise another publication has moved it, `ActiveMoved`.
    pub fn publish(self: *Store, base: ?Hash, schema: Hash, updates: []const Updates.Update) Error!?Hash {
        if (updates.len == 0) return null;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const before: ?Generation = if (base) |named| try self.generation(arena, named) else null;
        const next = try self.following(arena, before, base, schema, updates);
        const hash = try self.write(arena, next, updates);
        try self.activate(base, hash);
        return hash;
    }

    /// RFC-0087, P5.7: the generation that follows `before` (named `base`; none for a first one)
    /// with `updates` applied and the schema `schema`, computed and not written: each update's
    /// object is the name of its text. `updates` are sorted by cell and key, without repeats. What
    /// `publish` writes, so that a host can tell which generation a publication makes without
    /// making it.
    pub fn following(self: *Store, arena: std.mem.Allocator, before: ?Generation, base: ?Hash, schema: Hash, updates: []const Updates.Update) Error!Generation {
        const old: []const Entry = if (before) |held| held.entries else &.{};
        const merged = try arena.alloc(Entry, old.len + updates.len);
        var count: usize = 0;
        var from: usize = 0;
        for (updates, 0..) |update, index| {
            if (index != 0 and order(updates[index - 1].cell, updates[index - 1].key, update.cell, update.key) != .lt) return self.failed("the writes to publish are not sorted by entry");
            while (from < old.len and order(old[from].cell, old[from].key, update.cell, update.key) == .lt) : (from += 1) {
                merged[count] = old[from];
                count += 1;
            }
            if (from < old.len and order(old[from].cell, old[from].key, update.cell, update.key) == .eq) from += 1;
            merged[count] = .{ .cell = update.cell, .key = update.key, .object = hashOf(update.text) };
            count += 1;
        }
        while (from < old.len) : (from += 1) {
            merged[count] = old[from];
            count += 1;
        }
        const number = if (before) |held| (std.math.add(u64, held.number, 1) catch return self.failed("a generation's number cannot grow")) else 1;
        return .{ .number = number, .parent = base, .schema = schema, .entries = merged[0..count] };
    }

    /// The name of `next`, the hash of its manifest, which must be one this store reads back.
    pub fn nameOf(self: *Store, arena: std.mem.Allocator, next: Generation) Error!Hash {
        const manifest = try render(arena, next);
        // A manifest this store would not read back is not written: it would end every later run.
        if (manifest.len > self.manifest_limit) return self.failed("the generation would be longer than a manifest can be");
        return hashOf(manifest);
    }

    /// Writes the objects of `updates`, then the manifest of `next` (as `following` made it from
    /// them); its name. Files that are there already are left whole and synced again.
    pub fn write(self: *Store, arena: std.mem.Allocator, next: Generation, updates: []const Updates.Update) Error!Hash {
        for (updates) |update| _ = try self.putObject(update.text);
        const manifest = try render(arena, next);
        if (manifest.len > self.manifest_limit) return self.failed("the generation would be longer than a manifest can be");
        const hash = hashOf(manifest);
        const name = hexOf(hash);
        try self.disk.put(self.disk.context, .generations, &name, manifest);
        return hash;
    }

    /// Makes `active` name `hash`, written last: only if it names `from` (none: no file) or
    /// already `hash`, as after a crash that stopped after it; otherwise another publication has
    /// moved it, `ActiveMoved`.
    pub fn activate(self: *Store, from: ?Hash, hash: Hash) Error!void {
        const current = try self.activeName();
        const moved = if (current) |named| !std.mem.eql(u8, &named, &hash) and (from == null or !std.mem.eql(u8, &named, &from.?)) else from != null;
        if (moved) return error.ActiveMoved;
        var line: [65]u8 = undefined;
        line[0..64].* = hexOf(hash);
        line[64] = '\n';
        try self.disk.put(self.disk.context, .root, active_name, &line);
    }

    /// RFC-0087, P5.6: the generation that follows `base` with its entries and the schema `schema`,
    /// written and made active, when `base`'s schema is another; its name, or null when there is
    /// no base or its schema is that one. A run that saved nothing but read the store under a schema
    /// of its own (a field added with a default, say) leaves that schema, so that every later
    /// program is checked against what this one read (G2, G4). Published as `publish` publishes, so
    /// publishing again after a crash writes the same files.
    pub fn publishSchema(self: *Store, base: ?Hash, schema: Hash) Error!?Hash {
        const named = base orelse return null;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const before = try self.generation(arena, named);
        if (std.mem.eql(u8, &before.schema, &schema)) return null;
        const next = try self.following(arena, before, base, schema, &.{});
        const hash = try self.write(arena, next, &.{});
        try self.activate(base, hash);
        return hash;
    }
};

/// RFC-0087, P5.5, S7: the schema object this version writes: the persistent cells of the program,
/// by store name. Its types are P5.6's (G1): until then a schema names the cells and the kind of
/// their keys, and a reader that wants more finds `"schema":0`.
pub fn schemaText(gpa: std.mem.Allocator, cells: []const []const u8) std.mem.Allocator.Error![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    text.writer.writeAll("{\"schema\":0,\"cells\":[") catch return error.OutOfMemory;
    for (cells, 0..) |cell, index| {
        if (index != 0) text.writer.writeByte(',') catch return error.OutOfMemory;
        text.writer.writeAll("{\"cell\":") catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(cell, .{}, &text.writer) catch return error.OutOfMemory;
        text.writer.writeAll(",\"key\":\"persistent_key\"}") catch return error.OutOfMemory;
    }
    text.writer.writeAll("]}\n") catch return error.OutOfMemory;
    return text.toOwnedSlice();
}

// ---- A disk in memory, for tests and the DST ------------------------------------------------

/// A store in memory that counts its operations and fails, or "crashes" at, the one whose number it
/// was told to. A failed `put` writes nothing, or, with `apply_failed`, writes its file whole
/// before it fails: a crash that came just after the file became durable.
pub const Memory = struct {
    gpa: std.mem.Allocator,
    files: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    operations: u64 = 0,
    puts: u64 = 0,
    fail_at: ?u64 = null,
    apply_failed: bool = false,

    pub fn init(gpa: std.mem.Allocator) Memory {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Memory) void {
        var held = self.files.iterator();
        while (held.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.files.deinit(self.gpa);
    }
    pub fn disk(self: *Memory) Disk {
        return .{ .context = self, .read = read, .put = put };
    }
    fn path(area: Area, name: []const u8, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{t}/{s}", .{ area, name }) catch unreachable;
    }
    fn read(context: *anyopaque, gpa: std.mem.Allocator, area: Area, name: []const u8, limit: usize) DiskError!?[]u8 {
        const self: *Memory = @ptrCast(@alignCast(context));
        const number = self.operations;
        self.operations += 1;
        if (self.fail_at == number) return error.DiskFailed;
        var buffer: [128]u8 = undefined;
        const bytes = self.files.get(path(area, name, &buffer)) orelse return null;
        if (bytes.len > limit) return error.TooLarge;
        return gpa.dupe(u8, bytes) catch return error.DiskFailed;
    }
    fn put(context: *anyopaque, area: Area, name: []const u8, bytes: []const u8) DiskError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const number = self.operations;
        self.operations += 1;
        self.puts += 1;
        const failing = self.fail_at == number;
        if (failing and !self.apply_failed) return error.DiskFailed;
        var buffer: [128]u8 = undefined;
        const key = path(area, name, &buffer);
        const copy = self.gpa.dupe(u8, bytes) catch return error.DiskFailed;
        if (self.files.getPtr(key)) |existing| {
            self.gpa.free(existing.*);
            existing.* = copy;
        } else {
            const owned = self.gpa.dupe(u8, key) catch {
                self.gpa.free(copy);
                return error.DiskFailed;
            };
            self.files.put(self.gpa, owned, copy) catch {
                self.gpa.free(owned);
                self.gpa.free(copy);
                return error.DiskFailed;
            };
        }
        if (failing) return error.DiskFailed;
    }
    /// The file `name` of `area`, if the disk holds it.
    pub fn file(self: *const Memory, area: Area, name: []const u8) ?[]const u8 {
        var buffer: [128]u8 = undefined;
        return self.files.get(path(area, name, &buffer));
    }
};

// ---- Tests ----------------------------------------------------------------------------------

const testing = std.testing;

fn updateOf(cell: []const u8, key: []const u8, text: []const u8) Updates.Update {
    return .{ .cell = cell, .key = key, .text = @constCast(text) };
}

test "a first publication writes objects, a generation and active; a second builds on it" {
    var memory: Memory = .init(testing.allocator);
    defer memory.deinit();
    var store: Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try store.active(arena)) == null);
    const schema = hashOf("schema");
    const first = (try store.publish(null, schema, &.{ updateOf(":Stats", "alice", "{\"a\":1}"), updateOf(":Stats", "bob", "{\"b\":2}") })).?;
    const held = (try store.active(arena)).?;
    try testing.expectEqualSlices(u8, &first, &held.hash);
    try testing.expectEqual(@as(u64, 1), held.generation.number);
    try testing.expectEqual(@as(usize, 2), held.generation.entries.len);
    const alice = held.generation.find(":Stats", "alice").?;
    const alice_text = try store.text(alice);
    defer testing.allocator.free(alice_text);
    try testing.expectEqualStrings("{\"a\":1}", alice_text);
    // A second publication replaces one entry, adds another and keeps the rest.
    const second = (try store.publish(first, schema, &.{ updateOf(":Slots", "alice", "[1]"), updateOf(":Stats", "bob", "{\"b\":3}") })).?;
    const next = (try store.active(arena)).?;
    try testing.expectEqualSlices(u8, &second, &next.hash);
    try testing.expectEqual(@as(u64, 2), next.generation.number);
    try testing.expectEqualSlices(u8, &first, &next.generation.parent.?);
    try testing.expectEqual(@as(usize, 3), next.generation.entries.len);
    try testing.expectEqualSlices(u8, &alice.object, &next.generation.find(":Stats", "alice").?.object);
    const bob = try store.text(next.generation.find(":Stats", "bob").?);
    defer testing.allocator.free(bob);
    try testing.expectEqualStrings("{\"b\":3}", bob);
    // Nothing to publish: nothing written.
    const operations = memory.operations;
    try testing.expect((try store.publish(second, schema, &.{})) == null);
    try testing.expectEqual(operations, memory.operations);
}

test "publishing again after a crash writes the same files, and active moved by another is refused" {
    const schema = hashOf("schema");
    const updates = [_]Updates.Update{ updateOf(":A", "k", "1"), updateOf(":B", "k", "2") };
    var reference: Memory = .init(testing.allocator);
    defer reference.deinit();
    var store: Store = .{ .disk = reference.disk(), .gpa = testing.allocator };
    const base = (try store.publish(null, schema, &.{updateOf(":A", "k", "0")})).?;
    const total = reference.operations;
    const wanted = (try store.publish(base, schema, &updates)).?;
    const cost = reference.operations - total;
    // A crash at each operation of the publication, with the failed one written or not, and then
    // the publication again: the same generation, and a store whose files are all whole.
    for (0..cost) |at| for ([_]bool{ false, true }) |applied| {
        var memory: Memory = .init(testing.allocator);
        defer memory.deinit();
        var crashing: Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
        _ = (try crashing.publish(null, schema, &.{updateOf(":A", "k", "0")})).?;
        memory.fail_at = memory.operations + at;
        memory.apply_failed = applied;
        try testing.expectError(error.DiskFailed, crashing.publish(base, schema, &updates));
        memory.fail_at = null;
        // Whatever the crash left, `active` names the base or the new generation.
        const named = (try crashing.activeName()).?;
        try testing.expect(std.mem.eql(u8, &named, &base) or std.mem.eql(u8, &named, &wanted));
        const again = (try crashing.publish(base, schema, &updates)).?;
        try testing.expectEqualSlices(u8, &wanted, &again);
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const held = (try crashing.active(arena_state.allocator())).?;
        for (held.generation.entries) |entry| testing.allocator.free(try crashing.text(entry));
    };
    // Another publication moved active since: this one is refused, and changes nothing.
    var memory: Memory = .init(testing.allocator);
    defer memory.deinit();
    var other: Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const one = (try other.publish(null, schema, &.{updateOf(":A", "k", "0")})).?;
    _ = (try other.publish(one, schema, &.{updateOf(":A", "k", "1")})).?;
    try testing.expectError(error.ActiveMoved, other.publish(one, schema, &.{updateOf(":A", "k", "2")}));
}

test "a damaged store is refused, never read: a changed object, a changed manifest, a bad active" {
    const schema = hashOf("schema");
    var memory: Memory = .init(testing.allocator);
    defer memory.deinit();
    var store: Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    const named = (try store.publish(null, schema, &.{updateOf(":A", "k", "[1]")})).?;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const held = (try store.active(arena)).?;
    const entry = held.generation.entries[0];
    // The object is another file under its name.
    const object_name = hexOf(entry.object);
    try memory.disk().put(memory.disk().context, .objects, &object_name, "[2]");
    try testing.expectError(error.StoreFailed, store.text(entry));
    try testing.expectEqualStrings("an object is not the bytes its name is the hash of", store.why);
    // An object whose name is its hash but that is no text.
    const binary = "\"\xff\xfe\"";
    const binary_name = hexOf(hashOf(binary));
    try memory.disk().put(memory.disk().context, .objects, &binary_name, binary);
    try testing.expectError(error.StoreFailed, store.text(.{ .cell = ":A", .key = "k", .object = hashOf(binary) }));
    try testing.expectEqualStrings("an object is not text", store.why);
    // An object that is gone.
    const gone: Entry = .{ .cell = ":A", .key = "k", .object = hashOf("never written") };
    try testing.expectError(error.StoreFailed, store.text(gone));
    // A manifest that is not the bytes its name is the hash of, and one that is its own hash but no manifest.
    const manifest_name = hexOf(named);
    try memory.disk().put(memory.disk().context, .generations, &manifest_name, "{}");
    try testing.expectError(error.StoreFailed, store.generation(arena, named));
    const junk = "{\"forbic_store\":1}";
    const junk_hash = hashOf(junk);
    const junk_name = hexOf(junk_hash);
    try memory.disk().put(memory.disk().context, .generations, &junk_name, junk);
    try testing.expectError(error.StoreFailed, store.generation(arena, junk_hash));
    // An active file that names no hash.
    for ([_][]const u8{ "", "zz\n", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef\n" }) |bad| {
        try memory.disk().put(memory.disk().context, .root, active_name, bad);
        try testing.expectError(error.StoreFailed, store.activeName());
    }
}

test "a generation longer than a manifest can be is refused when it is written, not found unreadable after" {
    const schema = hashOf("schema");
    var memory: Memory = .init(testing.allocator);
    defer memory.deinit();
    var store: Store = .{ .disk = memory.disk(), .gpa = testing.allocator };
    // A first generation of one entry, then a limit under what two entries need.
    const first = (try store.publish(null, schema, &.{updateOf(":A", "k", "1")})).?;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const length = (try render(arena, (try store.generation(arena, first)))).len;
    store.manifest_limit = length + 10;
    try testing.expectError(error.StoreFailed, store.publish(first, schema, &.{updateOf(":B", "k", "2")}));
    try testing.expectEqualStrings("the generation would be longer than a manifest can be", store.why);
    // Nothing moved: active still names the first generation, and it still reads.
    try testing.expectEqualSlices(u8, &first, &(try store.activeName()).?);
    _ = try store.generation(arena, first);
    // A limit under the first generation itself refuses to read it.
    store.manifest_limit = length - 1;
    try testing.expectError(error.StoreFailed, store.generation(arena, first));
}

test "a manifest is read strictly: only the text this file writes for what it says" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]Entry{
        .{ .cell = ":A", .key = "a\"b", .object = hashOf("1") },
        .{ .cell = ":A", .key = "b", .object = hashOf("2") },
        .{ .cell = "x.forb:B.C", .key = "雪", .object = hashOf("3") },
    };
    const generation: Generation = .{ .number = 7, .parent = hashOf("p"), .schema = hashOf("s"), .entries = &entries };
    const text = try render(arena, generation);
    const parsed = (try parse(arena, text)).?;
    try testing.expectEqual(@as(u64, 7), parsed.number);
    try testing.expectEqualStrings("a\"b", parsed.entries[0].key);
    try testing.expectEqualSlices(u8, &hashOf("3"), &parsed.entries[2].object);
    // Anything but that text is refused: whitespace, another order, a repeat, an upper-case name, a
    // member twice, trailing bytes, another version.
    const spaced = try std.mem.replaceOwned(u8, arena, text, ",\"schema\"", ", \"schema\"");
    try testing.expect((try parse(arena, spaced)) == null);
    try testing.expect((try parse(arena, text[0 .. text.len - 1])) == null);
    try testing.expect((try parse(arena, try std.mem.concat(arena, u8, &.{ text, "x" }))) == null);
    const version = try std.mem.replaceOwned(u8, arena, text, "\"forbic_store\":1", "\"forbic_store\":2");
    try testing.expect((try parse(arena, version)) == null);
    const swapped: Generation = .{ .number = 7, .parent = null, .schema = hashOf("s"), .entries = &.{ entries[1], entries[0] } };
    try testing.expect((try parse(arena, try render(arena, swapped))) == null);
    const repeated: Generation = .{ .number = 7, .parent = null, .schema = hashOf("s"), .entries = &.{ entries[0], entries[0] } };
    try testing.expect((try parse(arena, try render(arena, repeated))) == null);
    const upper = try std.ascii.allocUpperString(arena, &hexOf(hashOf("s")));
    const loud = try std.mem.replaceOwned(u8, arena, text, &hexOf(hashOf("s")), upper);
    try testing.expect((try parse(arena, loud)) == null);
}

test "a store action is read back as the machine writes it, escapes included, and nothing else is" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const action = (try parseAction(arena, "{\"cell\":\"kit/save.forb:Slots.Data\",\"key\":\"a\\\"b\\\\c\\u0001\\u96ea\",\"value\":{\"x\":[1,2]}}")).?;
    try testing.expectEqualStrings("kit/save.forb:Slots.Data", action.cell);
    try testing.expectEqualStrings("a\"b\\c\x01雪", action.key);
    try testing.expectEqualStrings("{\"x\":[1,2]}", action.value);
    for ([_][]const u8{
        "",
        "{}",
        "{\"cell\":\"a\",\"key\":\"b\"}",
        "{\"key\":\"b\",\"cell\":\"a\",\"value\":1}",
        "{\"cell\":\"a\",\"key\":\"b\",\"value\":}",
        "{\"cell\":\"a\",\"key\":\"b\",\"value\":1",
        "{\"cell\":\"a\\x\",\"key\":\"b\",\"value\":1}",
        "{\"cell\":\"a\n\",\"key\":\"b\",\"value\":1}",
        "{\"cell\":\"\\ud800\",\"key\":\"b\",\"value\":1}",
        "{\"cell\":\"\\udc00\",\"key\":\"b\",\"value\":1}",
    }) |bad| try testing.expect((try parseAction(arena, bad)) == null);
}

test "the writes of a prefix collapse to the last of each entry, sorted" {
    var updates: Updates = .init(testing.allocator);
    defer updates.deinit();
    try updates.add("{\"cell\":\":B\",\"key\":\"k\",\"value\":1}");
    try updates.add("{\"cell\":\":A\",\"key\":\"k2\",\"value\":2}");
    try updates.add("{\"cell\":\":A\",\"key\":\"k\",\"value\":3}");
    try updates.add("{\"cell\":\":B\",\"key\":\"k\",\"value\":4}");
    try updates.add("not an action");
    // Two names that join alike are two entries.
    try updates.add("{\"cell\":\":A\",\"key\":\"kk\",\"value\":5}");
    try updates.add("{\"cell\":\":Ak\",\"key\":\"k\",\"value\":6}");
    try testing.expectEqual(@as(u64, 1), updates.malformed);
    const list = try updates.sorted();
    defer testing.allocator.free(list);
    try testing.expectEqual(@as(usize, 5), list.len);
    const expected = [_][3][]const u8{ .{ ":A", "k", "3" }, .{ ":A", "k2", "2" }, .{ ":A", "kk", "5" }, .{ ":Ak", "k", "6" }, .{ ":B", "k", "4" } };
    for (list, expected) |update, want| {
        try testing.expectEqualStrings(want[0], update.cell);
        try testing.expectEqualStrings(want[1], update.key);
        try testing.expectEqualStrings(want[2], update.text);
    }
}
