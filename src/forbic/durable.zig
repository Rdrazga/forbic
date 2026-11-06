//! The durable journal (RFC-0086, P2.4: J1 to J9): the sink of a journaled run, and its file.
//!
//! A journaled run writes one append-only stream of records: a header (the run's parameters),
//! every input the world gives the run before the guest sees it (write-ahead, J2), every
//! committed action, and one seal per commit point (J3), so that the actions of one outermost
//! region become durable together or not at all. Syncs may be grouped (J4): what a crash keeps
//! is the synced part and possibly a prefix of what was appended after it, its last record torn;
//! every reader cuts the stream at its last valid seal or end, so what survives is always a
//! whole number of commit points. Nothing is shown before its seal is durable (J5): the journal
//! hands its consumer the actions of the durable prefix, read back from the disk after a sync.
//!
//! This file holds what does not depend on an operating system: the format, the `Disk` a
//! journal writes to (a file in the host, a simulated one in tests and the DST, so that every
//! disk operation can fail deterministically), the `Journal` that is a run's `effects.Sink` and
//! `effects.InputJournal`, and the readers that cut a journal at its durable prefix. The state
//! directory, the lock, the writers' files and `forbic journal show` are the host's, in
//! `src/tooling/journal.zig`. Recovery (P2.5: R1 to R7) reads the same records: it cuts a
//! journal at its durable prefix, serves its sealed inputs to a run of the program again, and
//! resumes the journal in verify mode, where that run's sealed actions are compared with the
//! journal's instead of appended (R4).
//!
//! The run's VM state is never in the journal: a crash loses it, and it was never visible.
//! Only what the world gave (inputs) and what the run did to it (actions) are recorded.
const std = @import("std");
const effects = @import("effects.zig");
const types = @import("types.zig");
const assert = std.debug.assert;

/// The first bytes of a header's payload.
pub const magic = "forbic-journal-1";

/// J1. Kind 7 (`abandoned`, P2.5, R7a) ends a run that was abandoned; its payload is empty. Kind 6
/// (`published`, RFC-0087, P5.7: S6) records a publication of the store: the generation it made
/// and the number of sealed actions it covers.
pub const Kind = enum(u8) { header = 1, input = 2, action = 3, seal = 4, end = 5, abandoned = 7, published = 6, _ };

/// `u32 length | u8 kind | payload | u32 crc32c(kind, payload)`, little-endian; `length` is the
/// payload's.
pub const frame_bytes = 9;
/// The longest payload any journal may hold, whatever profile wrote it: a longer length is a
/// record that is not valid, which ends the journal.
pub const max_payload: u32 = 1 << 27;
/// The longest diagnostic code an `end` record names.
pub const max_code_bytes = 64;

const action_fixed = 8 + 4 + 4;
const input_fixed = 8 + 1 + 4 + 8 + 1 + 8 + 4;
const seal_payload = 8 + 8;
const published_payload = 32 + 8;
/// The largest `end` record, which a quota always keeps room for.
pub const end_record_bytes = frame_bytes + 1 + 4 + max_code_bytes + 4 + 4;

pub fn actionRecordBytes(text: usize) u64 {
    return frame_bytes + action_fixed + @as(u64, text);
}
pub fn inputRecordBytes(bytes: usize) u64 {
    return frame_bytes + input_fixed + @as(u64, bytes);
}
pub const seal_record_bytes: u64 = frame_bytes + seal_payload;
pub const published_record_bytes: u64 = frame_bytes + published_payload;

const Crc = std.hash.crc.@"CRC-32/ISCSI";

/// CRC-32C of a record's kind and payload.
pub fn checksum(kind: u8, parts: []const []const u8) u32 {
    var crc = Crc.init();
    crc.update(&.{kind});
    for (parts) |part| crc.update(part);
    return crc.final();
}

pub const DiskError = error{DiskFailed};

/// Where a journal lies: an append-only file. Each call is one disk operation, which may fail;
/// a simulated disk fails or crashes at whichever its test chooses.
pub const Disk = struct {
    context: *anyopaque,
    /// Appends the bytes of `parts`, in order, after what the file holds.
    append: *const fn (context: *anyopaque, parts: []const []const u8) DiskError!void,
    /// Makes everything appended so far durable.
    sync: *const fn (context: *anyopaque) DiskError!void,
    /// Reads up to `buffer.len` bytes at `offset`; fewer only at the end of the file.
    read: *const fn (context: *anyopaque, offset: u64, buffer: []u8) DiskError!usize,
    /// RFC-0086, P2.5 (R1): drops every byte from `length` on. Durable at the next sync.
    truncate: *const fn (context: *anyopaque, length: u64) DiskError!void,
};

// ---- Payloads -------------------------------------------------------------------------------

/// A grant as the header records it (J1, R6, J8): its kind and name, the resource it names (a
/// reader's path, `-` for standard input, or a writer's target), whether a reader's resource can
/// be repositioned, and for a writer the SHA-256 of its base copy.
pub const GrantRecord = struct {
    kind: effects.GrantKind,
    name: []const u8,
    path: []const u8,
    repositionable: bool = false,
    base: [32]u8 = @splat(0),
};

/// RFC-0087, P5.5 (S7): the store a run of a program with persistent cells started from: the
/// generation `active` named (all zero: none yet) and the object of the program's schema. Written
/// after the grants, only for such a program, so every other journal is as it was.
pub const StoreRef = struct { base: [32]u8, schema: [32]u8 };

/// The run's parameters (J1). Slices borrow the payload they were decoded from.
pub const Header = struct {
    toolchain: []const u8,
    profile: []const u8,
    /// SHA-256 of the program's source: the single file, or the bundle packet's bytes.
    program: [32]u8,
    seed: u64,
    tick_rate: u64,
    grants: []const GrantRecord,
    store: ?StoreRef = null,
};

pub const Input = struct {
    sequence: u64,
    kind: effects.InputKind,
    request: u32,
    tick: u64,
    status: effects.InputStatus,
    bits: u64,
    bytes: []const u8,
};

pub const Seal = struct { actions: u64, inputs: u64 };

/// RFC-0087, P5.7 (S6): a publication of the store. `generation` is the one it made from the
/// previous publication's (or the header's base) with the store actions sealed before `through`
/// that follow the previous one's `through`. Never all zero.
pub const Published = struct { generation: [32]u8, through: u64 };

pub const Outcome = enum(u8) { completed = 0, fatal = 1 };

/// How a run ended (J7): completed, or a fatal error with its code's name and span.
pub const End = struct {
    outcome: Outcome,
    code: []const u8 = "",
    start: u32 = 0,
    end: u32 = 0,
};

pub const Decoded = union(enum) {
    header: void,
    input: Input,
    action: effects.Action,
    seal: Seal,
    end: End,
    /// P2.5 (R7a): the run was abandoned, its durable prefix processed without running.
    abandoned: void,
    /// P5.7 (S6): the store was published from the durable prefix.
    published: Published,
};

const Encoder = struct {
    out: []u8,
    at: usize = 0,

    fn bytes(self: *Encoder, data: []const u8) error{NoSpace}!void {
        if (data.len > self.out.len - self.at) return error.NoSpace;
        @memcpy(self.out[self.at..][0..data.len], data);
        self.at += data.len;
    }
    fn int(self: *Encoder, comptime T: type, value: T) error{NoSpace}!void {
        var word: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &word, value, .little);
        try self.bytes(&word);
    }
    fn text(self: *Encoder, data: []const u8) error{NoSpace}!void {
        try self.int(u32, @intCast(data.len));
        try self.bytes(data);
    }
};

const Decoder = struct {
    in: []const u8,
    at: usize = 0,

    fn bytes(self: *Decoder, count: usize) error{Malformed}![]const u8 {
        if (count > self.in.len - self.at) return error.Malformed;
        defer self.at += count;
        return self.in[self.at..][0..count];
    }
    fn int(self: *Decoder, comptime T: type) error{Malformed}!T {
        return std.mem.readInt(T, (try self.bytes(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn text(self: *Decoder) error{Malformed}![]const u8 {
        return self.bytes(try self.int(u32));
    }
    fn done(self: *const Decoder) error{Malformed}!void {
        if (self.at != self.in.len) return error.Malformed;
    }
};

/// The bytes a header's payload needs.
pub fn headerBytes(header: Header) usize {
    var total: usize = 4 + magic.len + 4 + header.toolchain.len + 4 + header.profile.len + 32 + 8 + 8 + 4;
    for (header.grants) |grant| total += 1 + 4 + grant.name.len + 4 + grant.path.len + 1 + 32;
    if (header.store != null) total += 64;
    return total;
}

pub fn encodeHeader(header: Header, out: []u8) error{NoSpace}![]const u8 {
    var e: Encoder = .{ .out = out };
    try e.text(magic);
    try e.text(header.toolchain);
    try e.text(header.profile);
    try e.bytes(&header.program);
    try e.int(u64, header.seed);
    try e.int(u64, header.tick_rate);
    try e.int(u32, @intCast(header.grants.len));
    for (header.grants) |grant| {
        try e.int(u8, @backingInt(grant.kind));
        try e.text(grant.name);
        try e.text(grant.path);
        try e.int(u8, @intFromBool(grant.repositionable));
        try e.bytes(&grant.base);
    }
    if (header.store) |store| {
        try e.bytes(&store.base);
        try e.bytes(&store.schema);
    }
    return out[0..e.at];
}

/// A header's payload, its grants written to `grants`. A header with more grants than `grants`
/// has room for, a kind that is not a reader's or a writer's, grants that are not a list a host
/// may give (`effects.validGrants`), or a tick rate no run takes (`types.Scheduler.validRate`) is
/// malformed.
pub fn decodeHeader(payload: []const u8, grants: []GrantRecord) error{Malformed}!Header {
    var d: Decoder = .{ .in = payload };
    if (!std.mem.eql(u8, try d.text(), magic)) return error.Malformed;
    const toolchain = try d.text();
    const profile = try d.text();
    const program = (try d.bytes(32))[0..32].*;
    const seed = try d.int(u64);
    const tick_rate = try d.int(u64);
    // Every other way a run is given its rate refuses one outside the scheduler's range, and a
    // resumed run takes this one as its own.
    if (!types.Scheduler.validRate(tick_rate)) return error.Malformed;
    const count = try d.int(u32);
    if (count > grants.len) return error.Malformed;
    for (grants[0..count]) |*grant| {
        const kind = try d.int(u8);
        // RFC-0087, P5.5: and a persistent key (kind 3; 2 is the session, which is no grant).
        if (kind > @backingInt(effects.GrantKind.writer) and kind != @backingInt(effects.GrantKind.key)) return error.Malformed;
        const name = try d.text();
        const path = try d.text();
        const flags = try d.int(u8);
        if (flags > 1) return error.Malformed;
        grant.* = .{ .kind = @fromBackingInt(kind), .name = name, .path = path, .repositionable = flags == 1, .base = (try d.bytes(32))[0..32].* };
        // A key names no resource: nothing to reposition or to copy.
        if (grant.kind == .key and (path.len != 0 or flags != 0 or !std.mem.allEqual(u8, &grant.base, 0))) return error.Malformed;
    }
    var store: ?StoreRef = null;
    if (d.at != d.in.len) store = .{ .base = (try d.bytes(32))[0..32].*, .schema = (try d.bytes(32))[0..32].* };
    try d.done();
    // The names are checked as `effects.validGrants` checks a list a host may give.
    if (count > effects.grant_capacity) return error.Malformed;
    for (grants[0..count], 0..) |grant, index| {
        if (grant.name.len == 0 or grant.name.len > effects.grant_name_bytes or !std.unicode.utf8ValidateSlice(grant.name)) return error.Malformed;
        for (grants[0..index]) |earlier| if (earlier.kind == grant.kind and std.mem.eql(u8, earlier.name, grant.name)) return error.Malformed;
    }
    return .{ .toolchain = toolchain, .profile = profile, .program = program, .seed = seed, .tick_rate = tick_rate, .grants = grants[0..count], .store = store };
}

/// The fewest bytes a grant of a header's payload takes: a kind, a name of one byte, an empty
/// path, the flag and the base.
const min_grant_bytes = 1 + 4 + 1 + 4 + 1 + 32;

/// P2.5 (G18): what a header's payload says before its grants, and how many grants it names. A
/// reader sizes its grants by it, and tells a header of a build that holds more grants than it does
/// from one that is malformed, without trusting the payload for an allocation: a count the payload
/// has no room for is malformed.
pub const HeaderSummary = struct {
    toolchain: []const u8,
    profile: []const u8,
    grants: u32,
};

pub fn summarizeHeader(payload: []const u8) error{Malformed}!HeaderSummary {
    var d: Decoder = .{ .in = payload };
    if (!std.mem.eql(u8, try d.text(), magic)) return error.Malformed;
    const toolchain = try d.text();
    const profile = try d.text();
    _ = try d.bytes(32 + 8 + 8);
    const count = try d.int(u32);
    if (count > (payload.len - d.at) / min_grant_bytes) return error.Malformed;
    return .{ .toolchain = toolchain, .profile = profile, .grants = count };
}

/// J8: what publication writes after a writer's base: the durable lines of every channel whose
/// grant `owners` gives to `owner` (channel `c` is grant `c - 1`), each followed by a newline, in
/// sequence order. The host's publication and the DST's model of it are this one function. Returns
/// the bytes written.
pub fn writePublished(disk: Disk, buffer: []u8, owners: []const ?u32, owner: u32, out: *std.Io.Writer) (ReadError || std.Io.Writer.Error)!u64 {
    var prefix = try Prefix.init(disk, buffer);
    var written: u64 = 0;
    while (try prefix.next()) |record| switch (record.decoded) {
        .action => |action| {
            if (action.channel == 0 or action.channel > owners.len) continue;
            const of = owners[action.channel - 1] orelse continue;
            if (of != owner) continue;
            try out.writeAll(action.text);
            try out.writeByte('\n');
            written += action.text.len + 1;
        },
        else => {},
    };
    return written;
}

/// A record's payload other than a header's. A payload that does not decode exactly is
/// malformed.
pub fn decode(kind: Kind, payload: []const u8) error{Malformed}!Decoded {
    var d: Decoder = .{ .in = payload };
    const decoded: Decoded = switch (kind) {
        .header => return .header,
        .input => input: {
            const sequence = try d.int(u64);
            const input_kind = std.enums.fromInt(effects.InputKind, try d.int(u8)) orelse return error.Malformed;
            const request = try d.int(u32);
            const tick = try d.int(u64);
            const status = std.enums.fromInt(effects.InputStatus, try d.int(u8)) orelse return error.Malformed;
            const bits = try d.int(u64);
            break :input .{ .input = .{ .sequence = sequence, .kind = input_kind, .request = request, .tick = tick, .status = status, .bits = bits, .bytes = try d.text() } };
        },
        .action => action: {
            const sequence = try d.int(u64);
            const channel = try d.int(u32);
            break :action .{ .action = .{ .sequence = sequence, .channel = channel, .text = try d.text() } };
        },
        .seal => .{ .seal = .{ .actions = try d.int(u64), .inputs = try d.int(u64) } },
        .end => end: {
            const outcome = std.enums.fromInt(Outcome, try d.int(u8)) orelse return error.Malformed;
            const code = try d.text();
            if (code.len > max_code_bytes or (outcome == .completed) != (code.len == 0)) return error.Malformed;
            const start = try d.int(u32);
            const finish = try d.int(u32);
            if (start > finish or (outcome == .completed and finish != 0)) return error.Malformed;
            break :end .{ .end = .{ .outcome = outcome, .code = code, .start = start, .end = finish } };
        },
        .abandoned => .abandoned,
        .published => published: {
            const generation = (try d.bytes(32))[0..32].*;
            // All zero is the header's word for "no generation": no publication makes it.
            if (std.mem.allEqual(u8, &generation, 0)) return error.Malformed;
            break :published .{ .published = .{ .generation = generation, .through = try d.int(u64) } };
        },
        _ => return error.Malformed,
    };
    try d.done();
    return decoded;
}

// ---- Reading --------------------------------------------------------------------------------

/// One record as it lies in the file: `start .. end` are its bytes, frame included.
pub const Item = struct { kind: Kind, payload: []const u8, start: u64, end: u64 };

pub const ReadError = DiskError || error{RecordTooLarge};

/// Reads records in order. A record that is incomplete, fails its checksum, has an unknown kind
/// or a length no record may have ends the journal (J1): `next` gives null there and never
/// reads past it. A whole record longer than the reader's buffer is `RecordTooLarge`, not an
/// end: the journal goes on, and this reader cannot follow it. A reader whose buffer holds
/// `max_payload` and a checksum never meets one.
pub const Reader = struct {
    disk: Disk,
    buffer: []u8,
    offset: u64 = 0,

    pub fn next(self: *Reader) ReadError!?Item {
        var frame: [5]u8 = undefined;
        if (try self.disk.read(self.disk.context, self.offset, &frame) != frame.len) return null;
        const length = std.mem.readInt(u32, frame[0..4], .little);
        if (length > max_payload) return null;
        const kind = frame[4];
        if (kind < @backingInt(Kind.header) or kind > @backingInt(Kind.abandoned)) return null;
        if (@as(u64, length) + 4 > self.buffer.len) {
            // A record that would end past the file is incomplete, however long it says it is.
            var last: [1]u8 = undefined;
            if (try self.disk.read(self.disk.context, self.offset + frame_bytes + length - 1, &last) == 0) return null;
            return error.RecordTooLarge;
        }
        const rest = self.buffer[0 .. length + 4];
        if (try self.disk.read(self.disk.context, self.offset + frame.len, rest) != rest.len) return null;
        const payload = rest[0..length];
        if (std.mem.readInt(u32, rest[length..][0..4], .little) != checksum(kind, &.{payload})) return null;
        const start = self.offset;
        self.offset += frame_bytes + @as(u64, length);
        return .{ .kind = @fromBackingInt(kind), .payload = payload, .start = start, .end = self.offset };
    }
};

/// The structure a journal's records must have, beyond each record's own validity: one header,
/// first; inputs and actions numbered from zero without a gap; each seal after at least one new
/// action, naming every action and input before it; an end (or, P2.5, an `abandoned`) only
/// after the last action's seal; nothing after either but, P5.7, a `published`. A `published`
/// covers every action sealed before it (`through` is their number), follows no action and,
/// before an end, no input that is not sealed, and covers more actions than the `published`
/// before it, if any. A record that breaks it is, like a torn one, the end of the journal.
pub const Checker = struct {
    records: u64 = 0,
    actions: u64 = 0,
    inputs: u64 = 0,
    sealed_actions: u64 = 0,
    sealed_inputs: u64 = 0,
    ended: bool = false,
    /// P5.7: the `through` of the last `published`, if any.
    published: ?u64 = null,

    /// Whether `item` may follow the records accepted so far; if so, it is accepted.
    pub fn accept(self: *Checker, item: Item) ?Decoded {
        if (self.ended and item.kind != .published) return null;
        if ((self.records == 0) != (item.kind == .header)) return null;
        if (item.kind == .header) {
            // Its own validity is checked where it is read (`decodeHeader`), which needs room for
            // its grants; here, its magic.
            var d: Decoder = .{ .in = item.payload };
            const first = d.text() catch return null;
            if (!std.mem.eql(u8, first, magic)) return null;
        }
        const decoded = decode(item.kind, item.payload) catch return null;
        switch (decoded) {
            .header => {},
            .input => |input| {
                if (input.sequence != self.inputs) return null;
                self.inputs += 1;
            },
            .action => |action| {
                if (action.sequence != self.actions) return null;
                self.actions += 1;
            },
            .seal => |seal| {
                if (seal.actions != self.actions or seal.inputs != self.inputs or seal.actions == self.sealed_actions) return null;
                self.sealed_actions = seal.actions;
                self.sealed_inputs = seal.inputs;
            },
            // Every action before an end was sealed (J3): an end after an unsealed one is forged.
            .end, .abandoned => {
                if (self.actions != self.sealed_actions) return null;
                self.ended = true;
            },
            // P5.7: a publication is of the durable prefix: of every action sealed before it, of no
            // input a cut would drop, and of more actions than the publication before it.
            .published => |published| {
                if (self.actions != self.sealed_actions or published.through != self.sealed_actions) return null;
                if (!self.ended and self.inputs != self.sealed_inputs) return null;
                if (self.published) |last| if (published.through <= last) return null;
                self.published = published.through;
            },
        }
        self.records += 1;
        return decoded;
    }
};

/// What a journal holds, read to its first invalid record.
pub const Scan = struct {
    /// Whether it starts with a valid header: without one it is no journal (R1).
    has_header: bool = false,
    /// Where the header's record ends.
    header_end: u64 = 0,
    /// Where the durable prefix ends: after the last valid seal or end, or after the header when
    /// there is none. Every reader stops here (J4).
    cut: u64 = 0,
    /// Where the valid records end; what lies after it is never read.
    valid: u64 = 0,
    /// The actions and inputs of the durable prefix, and the end it records, if any.
    actions: u64 = 0,
    inputs: u64 = 0,
    end: ?End = null,
    /// P2.5 (R7a): the prefix ends in `abandoned`.
    abandoned: bool = false,
    /// P5.7 (S6): the last `published` of the prefix, if any.
    published: ?Published = null,

    /// R2: a journal whose prefix ends in `end` or `abandoned` belongs to a run that finished.
    pub fn finished(self: Scan) bool {
        return self.end != null or self.abandoned;
    }
};

pub fn scan(disk: Disk, buffer: []u8) ReadError!Scan {
    var reader: Reader = .{ .disk = disk, .buffer = buffer };
    var checker: Checker = .{};
    var result: Scan = .{};
    while (try reader.next()) |item| {
        const decoded = checker.accept(item) orelse break;
        result.valid = item.end;
        switch (decoded) {
            .header => {
                result.has_header = true;
                result.header_end = item.end;
                result.cut = item.end;
            },
            .seal => {
                result.cut = item.end;
                result.actions = checker.actions;
                result.inputs = checker.inputs;
            },
            .end => |end| {
                result.cut = item.end;
                result.actions = checker.actions;
                result.inputs = checker.inputs;
                result.end = end;
            },
            .abandoned => {
                result.cut = item.end;
                result.actions = checker.actions;
                result.inputs = checker.inputs;
                result.abandoned = true;
            },
            // P5.7: a publication is durable once it is synced, and a cut keeps it.
            .published => |published| {
                result.cut = item.end;
                result.actions = checker.actions;
                result.inputs = checker.inputs;
                result.published = published;
            },
            .input, .action => {},
        }
    }
    return result;
}

// ---- Recovery (P2.5) ------------------------------------------------------------------------

/// R1: cuts a journal after its durable prefix and makes the cut durable: what lies after the
/// last valid seal or end was never visible. Two disk operations, a crash at either of which
/// leaves a journal whose durable prefix is the same.
pub fn cutAt(disk: Disk, found: Scan) DiskError!void {
    assert(found.has_header);
    try disk.truncate(disk.context, found.cut);
    try disk.sync(disk.context);
}

/// R3: what of a run's parameters a journal's header must share with the run that resumes it.
pub const Mismatch = enum { toolchain, profile, program, seed, tick_rate, grants };

/// The first parameter in which `recorded` (a journal's header) is not the run `expected` would
/// be, or null. Grants are compared by kind, name and resource, in order; whether a reader can be
/// repositioned (R6) and a writer's base (J8) are the host's to check against its files.
pub fn mismatch(recorded: Header, expected: Header) ?Mismatch {
    if (!std.mem.eql(u8, recorded.toolchain, expected.toolchain)) return .toolchain;
    if (!std.mem.eql(u8, recorded.profile, expected.profile)) return .profile;
    if (!std.mem.eql(u8, &recorded.program, &expected.program)) return .program;
    if (recorded.seed != expected.seed) return .seed;
    if (recorded.tick_rate != expected.tick_rate) return .tick_rate;
    if (recorded.grants.len != expected.grants.len) return .grants;
    for (recorded.grants, expected.grants) |a, b| {
        if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.path, b.path)) return .grants;
    }
    return null;
}

/// R4: the inputs of a journal's durable prefix, in order, as a resumed run's input log is given
/// them for its prefix (I3). Storage for a whole input record: reserve it with `scratch.storage`;
/// it is touched only as far as the journal's inputs go.
pub const SealedInputs = struct {
    entries: [effects.input_entry_capacity]effects.InputEntry = undefined,
    bytes: [effects.input_byte_capacity]u8 = undefined,
    count: u32 = 0,
    byte_count: u32 = 0,

    pub const LoadError = ReadError || error{InputLimit};

    /// Reads the inputs of the durable prefix of the journal on `disk`. A journal that holds more
    /// than a run of this profile records is one this profile cannot resume (`InputLimit`).
    pub fn load(self: *SealedInputs, disk: Disk, buffer: []u8) LoadError!effects.InputRecord {
        self.count = 0;
        self.byte_count = 0;
        var prefix = try Prefix.init(disk, buffer);
        while (try prefix.next()) |held| switch (held.decoded) {
            .input => |input| {
                if (self.count == effects.input_entry_capacity or input.bytes.len > effects.input_byte_capacity - self.byte_count) return error.InputLimit;
                const start = self.byte_count;
                @memcpy(self.bytes[start..][0..input.bytes.len], input.bytes);
                self.byte_count += @intCast(input.bytes.len);
                self.entries[self.count] = .{ .tick = input.tick, .bits = input.bits, .start = start, .end = self.byte_count, .request = input.request, .kind = input.kind, .status = input.status };
                self.count += 1;
            },
            else => {},
        };
        return self.record();
    }

    pub fn record(self: *const SealedInputs) effects.InputRecord {
        return .{ .entries = self.entries[0..self.count], .bytes = self.bytes[0..self.byte_count] };
    }
};

/// The records of a journal's durable prefix, in order, header first: a `scan`, then a second
/// reading that stops at its cut.
pub const Prefix = struct {
    reader: Reader,
    checker: Checker = .{},
    cut: u64,

    pub fn init(disk: Disk, buffer: []u8) ReadError!Prefix {
        const found = try scan(disk, buffer);
        return .{ .reader = .{ .disk = disk, .buffer = buffer }, .cut = found.cut };
    }
    /// The next record of the prefix and its decoded form, or null at the cut. The file is read
    /// again: a record that changed since the scan ends the prefix where it lies.
    pub fn next(self: *Prefix) ReadError!?struct { item: Item, decoded: Decoded } {
        if (self.reader.offset >= self.cut) return null;
        const item = (try self.reader.next()) orelse return null;
        if (item.end > self.cut) return null;
        const decoded = self.checker.accept(item) orelse return null;
        return .{ .item = item, .decoded = decoded };
    }
};

// ---- Writing --------------------------------------------------------------------------------

/// Who is shown the durable prefix (J5, J9): each action once, in sequence order, after the
/// sync that made its seal durable. False is a consumer that cannot take more (a reader of
/// standard output that has gone): the commit point's seal reports the failure.
pub const Consumer = struct {
    context: *anyopaque,
    show: *const fn (context: *anyopaque, action: effects.Action) bool,
};

/// The journal of one run: its `effects.Sink` (J3, J6) and its `effects.InputJournal` (J2).
/// It appends to its disk, syncs every `group` seals and at the end (J4), and shows its
/// consumer what each sync made durable. After a disk operation fails it refuses every later
/// call (J6), so the durable prefix it leaves is whole.
pub const Journal = struct {
    disk: Disk,
    /// Where the durable range is read back for the consumer: it bounds the longest action and
    /// line the journal takes.
    buffer: []u8,
    /// Seals per sync: 1 syncs every commit point.
    group: u32 = 1,
    /// The bytes the file may hold, set by the host; none: unbounded (J6).
    quota: ?u64 = null,
    consumer: ?Consumer = null,

    /// Bytes appended, and synced.
    offset: u64 = 0,
    synced: u64 = 0,
    /// Where the last seal appended ends, and where the last durable one does.
    sealed: u64 = 0,
    durable: u64 = 0,
    /// Where the records shown to the consumer end.
    shown: u64 = 0,
    actions: u64 = 0,
    inputs: u64 = 0,
    sealed_actions: u64 = 0,
    pending_seals: u32 = 0,
    /// Room the prepared actions hold in the quota.
    reserved: u64 = 0,
    syncs: u64 = 0,
    /// A disk operation failed: the journal takes nothing more.
    failed: bool = false,
    /// The consumer could take no more: it is shown nothing more.
    consumer_failed: bool = false,
    started: bool = false,
    ended: bool = false,
    /// P2.5 (R4): a resumed journal reads its durable prefix back here, record by record, and
    /// compares each action and seal the run commits with it until the cut; nothing is appended
    /// or shown before the cut is passed.
    verify: Reader = undefined,
    verify_end: u64 = 0,
    /// The run committed an action or a seal other than the journal's, asked the world for an
    /// input before it passed the last seal, or ended before it (R4, R5): `recovery_diverged`.
    /// The journal then takes nothing more, and its durable prefix stays as the cut left it.
    diverged: bool = false,
    /// The inputs the run has taken: served from its prefix, or appended. A verified seal must
    /// name as many as the journal's did (R4).
    taken: u64 = 0,

    pub fn init(disk: Disk, buffer: []u8) Journal {
        return .{ .disk = disk, .buffer = buffer };
    }

    /// Appends the header and syncs it: a journal whose header is not durable is no journal.
    pub fn start(self: *Journal, header_payload: []const u8) DiskError!void {
        assert(!self.started and self.offset == 0);
        self.started = true;
        if (!self.append(.header, &.{header_payload})) return error.DiskFailed;
        if (!self.syncNow()) return error.DiskFailed;
    }

    /// R4: the journal of a run that resumes the one `found` describes, on the same disk, after
    /// its cut (R1). The run's actions up to the last seal are verified, not appended; its inputs
    /// past the sealed ones are appended after them. Nothing of the prefix is shown again (J9).
    pub fn resumeAt(self: *Journal, found: Scan) void {
        assert(!self.started and self.offset == 0);
        assert(found.has_header and !found.finished() and found.cut >= found.header_end);
        self.started = true;
        self.offset = found.cut;
        self.synced = found.cut;
        self.sealed = found.cut;
        self.durable = found.cut;
        self.shown = found.cut;
        self.inputs = found.inputs;
        self.verify = .{ .disk = self.disk, .buffer = self.buffer, .offset = found.header_end };
        self.verify_end = found.cut;
        self.passPublished();
    }

    /// RFC-0087, P5.7: moves the verification past the `published` records at its cursor, which
    /// the host made and a run does not repeat: a journal whose cut follows them has been
    /// verified once its last seal has.
    fn passPublished(self: *Journal) void {
        while (self.verify.offset < self.verify_end) {
            var ahead = self.verify;
            const item = (ahead.next() catch return) orelse return;
            if (item.kind != .published or item.end > self.verify_end) return;
            self.verify = ahead;
        }
    }

    /// Whether the run has not yet passed the journal's last seal (R4).
    pub fn verifying(self: *const Journal) bool {
        return self.verify_end != 0 and self.verify.offset < self.verify_end;
    }

    /// The next action or seal of the prefix under verification; its inputs are the run's prefix,
    /// which its input log checks. Null is a disk that failed, or a file that changed under the
    /// journal: the journal fails.
    fn recorded(self: *Journal) ?Decoded {
        assert(self.verifying());
        while (self.verify.offset < self.verify_end) {
            const item = (self.verify.next() catch null) orelse break;
            if (item.end > self.verify_end) break;
            const decoded = decode(item.kind, item.payload) catch break;
            switch (decoded) {
                // P5.7: a publication is the host's record, which a run does not make.
                .input, .published => continue,
                .action, .seal => return decoded,
                .header, .end, .abandoned => break,
            }
        }
        self.failed = true;
        return null;
    }

    fn diverge(self: *Journal) bool {
        self.diverged = true;
        self.failed = true;
        return false;
    }

    pub const FinishError = DiskError || error{Diverged};

    /// J7: the run ended. Appends `end` and syncs it, and shows the consumer the rest of the
    /// durable prefix. A journal that failed earlier takes no end: its durable prefix stays as
    /// the failure left it, for a recovery. A resumed run that ends before it passed the
    /// journal's last seal did not commit what the journal holds: it diverged (R4).
    pub fn finish(self: *Journal, end: End) FinishError!void {
        assert(self.started and !self.ended);
        if (self.failed) return if (self.diverged) error.Diverged else error.DiskFailed;
        if (self.verifying()) {
            _ = self.diverge();
            return error.Diverged;
        }
        assert(end.code.len <= max_code_bytes);
        var fixed: [5]u8 = undefined;
        fixed[0] = @backingInt(end.outcome);
        std.mem.writeInt(u32, fixed[1..5], @intCast(end.code.len), .little);
        var span: [8]u8 = undefined;
        std.mem.writeInt(u32, span[0..4], end.start, .little);
        std.mem.writeInt(u32, span[4..8], end.end, .little);
        if (!self.append(.end, &.{ &fixed, end.code, &span })) return error.DiskFailed;
        self.sealed = self.offset;
        self.ended = true;
        if (!self.syncNow()) return error.DiskFailed;
    }

    /// R7a: ends a resumed journal without running anything: appends `abandoned` and syncs it.
    /// What the run had not sealed was never visible, and is lost.
    pub fn abandon(self: *Journal) DiskError!void {
        assert(self.started and !self.ended);
        if (self.failed) return error.DiskFailed;
        if (!self.append(.abandoned, &.{})) return error.DiskFailed;
        self.sealed = self.offset;
        self.ended = true;
        self.verify_end = 0;
        if (!self.syncNow()) return error.DiskFailed;
    }

    /// RFC-0087, P5.7: the journal `found` describes, on the same disk after its cut (R1), as a
    /// host that processes it without running anything finds it: finished or not, to be abandoned
    /// (R7a) or to record a publication (S6) before a run resumes it. Nothing is verified.
    pub fn reopen(self: *Journal, found: Scan) void {
        assert(!self.started and self.offset == 0);
        assert(found.has_header and found.cut >= found.header_end);
        self.started = true;
        self.ended = found.finished();
        self.offset = found.cut;
        self.synced = found.cut;
        self.sealed = found.cut;
        self.durable = found.cut;
        self.shown = found.cut;
        self.actions = found.actions;
        self.sealed_actions = found.actions;
        self.inputs = found.inputs;
        self.taken = found.inputs;
    }

    /// RFC-0087, P5.7 (S6): appends `published` and syncs it, after the store was published from
    /// the durable prefix, which every action of the journal is part of. It may follow the end.
    pub fn recordPublished(self: *Journal, published: Published) DiskError!void {
        assert(self.started and !self.verifying());
        assert(published.through == self.sealed_actions and self.actions == self.sealed_actions);
        assert(!std.mem.allEqual(u8, &published.generation, 0));
        if (self.failed) return error.DiskFailed;
        var payload: [published_payload]u8 = undefined;
        payload[0..32].* = published.generation;
        std.mem.writeInt(u64, payload[32..40], published.through, .little);
        if (!self.append(.published, &.{&payload})) return error.DiskFailed;
        self.sealed = self.offset;
        if (!self.syncNow()) return error.DiskFailed;
    }

    pub fn sink(self: *Journal) effects.Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort, .seal = seal };
    }

    pub fn inputJournal(self: *Journal) effects.InputJournal {
        return .{ .context = self, .append = appendInput, .served = served };
    }

    /// The room an action holds from its prepare to its commit or abort: its record, and a seal
    /// in case it is a commit point of its own.
    fn room(text: usize) u64 {
        return actionRecordBytes(text) + seal_record_bytes;
    }
    fn fits(self: *const Journal, bytes: u64) bool {
        const quota = self.quota orelse return true;
        return self.offset + self.reserved + bytes + end_record_bytes <= quota;
    }
    /// The longest text the read-back buffer holds in one record.
    fn takes(self: *const Journal, fixed: usize, bytes: usize) bool {
        return self.buffer.len >= 4 + fixed and bytes <= self.buffer.len - 4 - fixed;
    }

    fn prepare(context: *anyopaque, text: []const u8) bool {
        const self: *Journal = @ptrCast(@alignCast(context));
        if (self.failed or !self.started or self.ended) return false;
        if (!self.takes(action_fixed, text.len) or !self.fits(room(text.len))) return false;
        self.reserved += room(text.len);
        return true;
    }
    fn abort(context: *anyopaque, text: []const u8) void {
        const self: *Journal = @ptrCast(@alignCast(context));
        assert(self.reserved >= room(text.len));
        self.reserved -= room(text.len);
    }
    fn commit(context: *anyopaque, action: effects.Action) bool {
        const self: *Journal = @ptrCast(@alignCast(context));
        assert(self.reserved >= room(action.text.len));
        self.reserved -= room(action.text.len);
        if (self.failed) return false;
        if (action.sequence != self.actions) {
            self.failed = true;
            return false;
        }
        // R4: an action the journal already holds is compared, channel and every byte, and
        // neither appended nor shown again.
        if (self.verifying()) {
            const held = self.recorded() orelse return false;
            if (held != .action or held.action.sequence != action.sequence or held.action.channel != action.channel or !std.mem.eql(u8, held.action.text, action.text)) return self.diverge();
            self.actions += 1;
            return true;
        }
        var fixed: [action_fixed]u8 = undefined;
        std.mem.writeInt(u64, fixed[0..8], action.sequence, .little);
        std.mem.writeInt(u32, fixed[8..12], action.channel, .little);
        std.mem.writeInt(u32, fixed[12..16], @intCast(action.text.len), .little);
        if (!self.append(.action, &.{ &fixed, action.text })) return false;
        self.actions += 1;
        return true;
    }
    fn seal(context: *anyopaque, through: u64) bool {
        const self: *Journal = @ptrCast(@alignCast(context));
        if (self.failed) return false;
        if (through != self.actions or through == self.sealed_actions) {
            self.failed = true;
            return false;
        }
        // R4, R5: the commit points of the run again are the journal's; one that straddles the
        // last seal, or ends elsewhere, is a run that diverged.
        if (self.verifying()) {
            const held = self.recorded() orelse return false;
            if (held != .seal or held.seal.actions != through or held.seal.inputs != self.taken) return self.diverge();
            self.sealed_actions = through;
            self.passPublished();
            return true;
        }
        var payload: [seal_payload]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], self.actions, .little);
        std.mem.writeInt(u64, payload[8..16], self.inputs, .little);
        if (!self.append(.seal, &.{&payload})) return false;
        self.sealed = self.offset;
        self.sealed_actions = self.actions;
        self.pending_seals += 1;
        if (self.pending_seals < self.group) return true;
        return self.syncNow() and !self.consumer_failed;
    }
    fn appendInput(context: *anyopaque, sequence: u32, entry: effects.InputEntry, bytes: []const u8) bool {
        const self: *Journal = @ptrCast(@alignCast(context));
        if (self.failed or !self.started or self.ended) return false;
        if (sequence != self.inputs) {
            self.failed = true;
            return false;
        }
        // R5 (JM3): a run that is the journal's asks the world for nothing before it has passed
        // the last seal, whose inputs it is served; one that does has diverged.
        if (self.verifying()) return self.diverge();
        // A line the journal cannot hold, or one past the quota, is a device that cannot take
        // it: `input_failed`, as for a source that cannot answer.
        if (!self.takes(input_fixed, bytes.len) or !self.fits(inputRecordBytes(bytes.len))) return false;
        var fixed: [input_fixed]u8 = undefined;
        std.mem.writeInt(u64, fixed[0..8], sequence, .little);
        fixed[8] = @backingInt(entry.kind);
        std.mem.writeInt(u32, fixed[9..13], entry.request, .little);
        std.mem.writeInt(u64, fixed[13..21], entry.tick, .little);
        fixed[21] = @backingInt(entry.status);
        std.mem.writeInt(u64, fixed[22..30], entry.bits, .little);
        std.mem.writeInt(u32, fixed[30..34], @intCast(bytes.len), .little);
        if (!self.append(.input, &.{ &fixed, bytes })) return false;
        self.inputs += 1;
        self.taken += 1;
        return true;
    }
    /// R4: an input of the sealed prefix the run was served; nothing is appended.
    fn served(context: *anyopaque, sequence: u32) void {
        const self: *Journal = @ptrCast(@alignCast(context));
        assert(sequence == self.taken);
        self.taken += 1;
    }

    /// One record, framed, in one disk operation.
    fn append(self: *Journal, kind: Kind, payload: []const []const u8) bool {
        assert(!self.failed and payload.len <= 3);
        var length: u64 = 0;
        for (payload) |part| length += part.len;
        assert(length <= max_payload);
        var frame: [5]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], @intCast(length), .little);
        frame[4] = @backingInt(kind);
        var crc: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc, checksum(frame[4], payload), .little);
        var parts: [5][]const u8 = undefined;
        parts[0] = &frame;
        for (payload, 1..) |part, index| parts[index] = part;
        parts[payload.len + 1] = &crc;
        self.disk.append(self.disk.context, parts[0 .. payload.len + 2]) catch {
            self.failed = true;
            return false;
        };
        self.offset += frame_bytes + length;
        return true;
    }

    /// Syncs, then shows the consumer the actions that the sync made durable.
    fn syncNow(self: *Journal) bool {
        self.disk.sync(self.disk.context) catch {
            self.failed = true;
            return false;
        };
        self.syncs += 1;
        self.synced = self.offset;
        self.durable = self.sealed;
        self.pending_seals = 0;
        if (self.shown == 0) self.shown = self.offset;
        return self.deliver();
    }

    /// J5: the records between what was shown and the last durable seal, read back from the
    /// disk. They are this journal's own: one that does not read back as written is a disk that
    /// failed.
    fn deliver(self: *Journal) bool {
        if (self.shown >= self.durable) return true;
        var reader: Reader = .{ .disk = self.disk, .buffer = self.buffer, .offset = self.shown };
        while (reader.offset < self.durable) {
            const item = (reader.next() catch null) orelse {
                self.failed = true;
                return false;
            };
            if (item.kind != .action) continue;
            const decoded = decode(.action, item.payload) catch {
                self.failed = true;
                return false;
            };
            if (self.consumer) |consumer| if (!self.consumer_failed and !consumer.show(consumer.context, decoded.action)) {
                self.consumer_failed = true;
            };
        }
        self.shown = reader.offset;
        // A consumer that could take no more is the seal's to report; the disk is whole.
        return true;
    }
};

// ---- A disk in memory, for tests ------------------------------------------------------------

/// A disk for tests: an append-only file in memory that writes down how many operations it was
/// asked for, and fails the append, the sync or the read whose number it was told to fail, as
/// `effects.Recorder` does for sinks. A failed append appends nothing.
pub const Memory = struct {
    bytes: []u8,
    len: usize = 0,
    synced: usize = 0,
    appends: u64 = 0,
    syncs: u64 = 0,
    reads: u64 = 0,
    fail_append: ?u64 = null,
    fail_sync: ?u64 = null,
    fail_read: ?u64 = null,

    truncates: u64 = 0,
    fail_truncate: ?u64 = null,

    pub fn disk(self: *Memory) Disk {
        return .{ .context = self, .append = append, .sync = sync, .read = read, .truncate = truncate };
    }
    /// Disk operations so far: appends, syncs and truncations.
    pub fn operations(self: *const Memory) u64 {
        return self.appends + self.syncs + self.truncates;
    }
    fn truncate(context: *anyopaque, length: u64) DiskError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const number = self.truncates;
        self.truncates += 1;
        if (self.fail_truncate == number) return error.DiskFailed;
        if (length < self.len) self.len = @intCast(length);
        self.synced = @min(self.synced, self.len);
    }
    pub fn contents(self: *const Memory) []const u8 {
        return self.bytes[0..self.len];
    }
    fn append(context: *anyopaque, parts: []const []const u8) DiskError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const number = self.appends;
        self.appends += 1;
        if (self.fail_append == number) return error.DiskFailed;
        var total: usize = 0;
        for (parts) |part| total += part.len;
        if (total > self.bytes.len - self.len) return error.DiskFailed;
        for (parts) |part| {
            @memcpy(self.bytes[self.len..][0..part.len], part);
            self.len += part.len;
        }
    }
    fn sync(context: *anyopaque) DiskError!void {
        const self: *Memory = @ptrCast(@alignCast(context));
        const number = self.syncs;
        self.syncs += 1;
        if (self.fail_sync == number) return error.DiskFailed;
        self.synced = self.len;
    }
    fn read(context: *anyopaque, offset: u64, buffer: []u8) DiskError!usize {
        const self: *Memory = @ptrCast(@alignCast(context));
        const number = self.reads;
        self.reads += 1;
        if (self.fail_read == number) return error.DiskFailed;
        if (offset >= self.len) return 0;
        const count = @min(buffer.len, self.len - offset);
        @memcpy(buffer[0..count], self.bytes[offset..][0..count]);
        return count;
    }
};

/// A disk that reads a file's bytes and takes no writes: a journal as a test forged it.
pub const Image = struct {
    bytes: []const u8,

    pub fn disk(self: *Image) Disk {
        return .{ .context = self, .append = refuse, .sync = refuseSync, .read = read, .truncate = refuseTruncate };
    }
    fn refuse(_: *anyopaque, _: []const []const u8) DiskError!void {
        return error.DiskFailed;
    }
    fn refuseTruncate(_: *anyopaque, _: u64) DiskError!void {
        return error.DiskFailed;
    }
    fn refuseSync(_: *anyopaque) DiskError!void {
        return error.DiskFailed;
    }
    fn read(context: *anyopaque, offset: u64, buffer: []u8) DiskError!usize {
        const self: *Image = @ptrCast(@alignCast(context));
        if (offset >= self.bytes.len) return 0;
        const count = @min(buffer.len, self.bytes.len - offset);
        @memcpy(buffer[0..count], self.bytes[offset..][0..count]);
        return count;
    }
};

// ---- Tests ----------------------------------------------------------------------------------

const scratch = @import("scratch.zig");
const testing = std.testing;

test "the checksum is CRC-32C, and a header encodes and decodes exactly" {
    try testing.expectEqual(@as(u32, 0xe3069283), checksum('1', &.{"23456789"}));
    const grants = [_]GrantRecord{
        .{ .kind = .reader, .name = "config", .path = "config.txt", .repositionable = true },
        .{ .kind = .writer, .name = "log", .path = "out/log.txt", .base = @splat(7) },
    };
    const header: Header = .{ .toolchain = "forbic 0.0.1", .profile = "bootstrap", .program = @splat(3), .seed = 42, .tick_rate = 60, .grants = &grants };
    var buffer: [512]u8 = undefined;
    const payload = try encodeHeader(header, &buffer);
    try testing.expectEqual(headerBytes(header), payload.len);
    var back: [4]GrantRecord = undefined;
    const decoded = try decodeHeader(payload, &back);
    try testing.expectEqualStrings("bootstrap", decoded.profile);
    try testing.expectEqual(@as(u64, 42), decoded.seed);
    try testing.expectEqual(@as(usize, 2), decoded.grants.len);
    try testing.expectEqualStrings("out/log.txt", decoded.grants[1].path);
    try testing.expect(decoded.grants[0].repositionable and !decoded.grants[1].repositionable);
    try testing.expectEqual(@as(u8, 7), decoded.grants[1].base[31]);
    // Every shorter payload, and one with a byte more, is malformed; so are forged fields.
    for (0..payload.len) |length| try testing.expectError(error.Malformed, decodeHeader(payload[0..length], &back));
    var longer: [513]u8 = undefined;
    @memcpy(longer[0..payload.len], payload);
    longer[payload.len] = 0;
    try testing.expectError(error.Malformed, decodeHeader(longer[0 .. payload.len + 1], &back));
    try testing.expectError(error.Malformed, decodeHeader(payload, back[0..1]));
    var forged: [512]u8 = undefined;
    @memcpy(forged[0..payload.len], payload);
    forged[4] = 'V';
    try testing.expectError(error.Malformed, decodeHeader(forged[0..payload.len], &back));
    const same_name = [_]GrantRecord{ .{ .kind = .writer, .name = "log", .path = "a" }, .{ .kind = .writer, .name = "log", .path = "b" } };
    try testing.expectError(error.Malformed, decodeHeader(try encodeHeader(.{ .toolchain = "", .profile = "", .program = @splat(0), .seed = 0, .tick_rate = 1, .grants = &same_name }, &forged), &back));
    const unnamed = [_]GrantRecord{.{ .kind = .reader, .name = "", .path = "a" }};
    try testing.expectError(error.Malformed, decodeHeader(try encodeHeader(.{ .toolchain = "", .profile = "", .program = @splat(0), .seed = 0, .tick_rate = 1, .grants = &unnamed }, &forged), &back));
    const unknown = [_]GrantRecord{.{ .kind = @fromBackingInt(2), .name = "x", .path = "a" }};
    try testing.expectError(error.Malformed, decodeHeader(try encodeHeader(.{ .toolchain = "", .profile = "", .program = @splat(0), .seed = 0, .tick_rate = 1, .grants = &unknown }, &forged), &back));
    // G18: the summary names the toolchain, the profile and the count of grants, which every
    // shorter payload's does not have room for.
    const summary = try summarizeHeader(payload);
    try testing.expectEqualStrings("forbic 0.0.1", summary.toolchain);
    try testing.expectEqualStrings("bootstrap", summary.profile);
    try testing.expectEqual(@as(u32, 2), summary.grants);
    const count_at = 4 + magic.len + 4 + "forbic 0.0.1".len + 4 + "bootstrap".len + 32 + 8 + 8;
    try testing.expectError(error.Malformed, summarizeHeader(payload[0 .. count_at + 3]));
    // A count the payload has no room for is malformed whatever the payload's length.
    @memcpy(forged[0..payload.len], payload);
    std.mem.writeInt(u32, forged[count_at..][0..4], 3, .little);
    try testing.expectError(error.Malformed, summarizeHeader(forged[0..payload.len]));
    std.mem.writeInt(u32, forged[count_at..][0..4], std.math.maxInt(u32), .little);
    try testing.expectError(error.Malformed, summarizeHeader(forged[0..payload.len]));
}

test "a header's tick rate is one a run takes, or the header is malformed" {
    // c1-3: a resumed run takes the header's rate as its own, and the machines assert it.
    var buffer: [256]u8 = undefined;
    var back: [1]GrantRecord = undefined;
    for ([_]u64{ 1, 60, 1000, 1001, types.Scheduler.max_tick_rate }) |rate| {
        const payload = try encodeHeader(.{ .toolchain = "t", .profile = "bootstrap", .program = @splat(0), .seed = 0, .tick_rate = rate, .grants = &.{} }, &buffer);
        try testing.expectEqual(rate, (try decodeHeader(payload, &back)).tick_rate);
    }
    for ([_]u64{ 0, types.Scheduler.max_tick_rate + 1, 1 << 31, 549755813948, std.math.maxInt(u64) }) |rate| {
        const payload = try encodeHeader(.{ .toolchain = "t", .profile = "bootstrap", .program = @splat(0), .seed = 0, .tick_rate = rate, .grants = &.{}, .store = .{ .base = @splat(0), .schema = @splat(1) } }, &buffer);
        try testing.expectError(error.Malformed, decodeHeader(payload, &back));
        // The summary does not read the rate: such a header is another build's, never no journal.
        _ = try summarizeHeader(payload);
    }
}

test "a header of more grants than this build holds is summarized, not decoded, and publication's lines are each channel's" {
    // G18: a header another build wrote with more grants than this one holds is still a header.
    const many = try testing.allocator.alloc(GrantRecord, effects.grant_capacity + 1);
    defer testing.allocator.free(many);
    const names = try testing.allocator.alloc([12]u8, many.len);
    defer testing.allocator.free(names);
    for (many, names, 0..) |*grant, *name, index| grant.* = .{ .kind = .writer, .name = std.fmt.bufPrint(name, "w{d}", .{index}) catch unreachable, .path = "p" };
    const header: Header = .{ .toolchain = "t", .profile = "program", .program = @splat(0), .seed = 0, .tick_rate = 60, .grants = many };
    const bytes = try testing.allocator.alloc(u8, headerBytes(header));
    defer testing.allocator.free(bytes);
    const payload = try encodeHeader(header, bytes);
    const summary = try summarizeHeader(payload);
    try testing.expectEqual(@as(u32, effects.grant_capacity + 1), summary.grants);
    try testing.expectEqualStrings("program", summary.profile);
    try testing.expectError(error.Malformed, decodeHeader(payload, many));
    // J8: the lines of the channels a writer owns, in order; channel 0 and others' are not its.
    const log = try testLog();
    defer scratch.release(log);
    var b: Bench = .{};
    b.init();
    try b.begin();
    log.sink = b.journal.sink();
    defer log.sink = null;
    log.reset(false);
    try log.prepareOn(1, "a");
    try log.prepareOn(2, "b");
    try log.prepare("shown");
    try log.prepareOn(3, "c");
    log.begin();
    try log.prepareOn(1, "unsealed");
    const owners = [_]?u32{ 0, null, 0 };
    var out_bytes: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_bytes);
    try testing.expectEqual(@as(u64, 4), try writePublished(b.memory.disk(), &b.buffer, &owners, 0, &out));
    try testing.expectEqualStrings("a\nc\n", out.buffered());
    out = .fixed(&out_bytes);
    try testing.expectEqual(@as(u64, 0), try writePublished(b.memory.disk(), &b.buffer, &owners, 1, &out));
}

/// Both ends of a journal under test: a disk in memory and the journal on it, with a consumer
/// that writes down what it is shown.
const Bench = struct {
    storage: [16 * 1024]u8 = undefined,
    buffer: [2048]u8 = undefined,
    memory: Memory = undefined,
    journal: Journal = undefined,
    shown: [64]effects.Action = undefined,
    shown_text: [1024]u8 = undefined,
    shown_count: usize = 0,
    shown_bytes: usize = 0,
    refuse_show: bool = false,

    fn init(self: *Bench) void {
        self.memory = .{ .bytes = &self.storage };
        self.journal = .init(self.memory.disk(), &self.buffer);
        self.journal.consumer = .{ .context = self, .show = show };
        self.shown_count = 0;
        self.shown_bytes = 0;
        self.refuse_show = false;
    }
    fn show(context: *anyopaque, action: effects.Action) bool {
        const self: *Bench = @ptrCast(@alignCast(context));
        if (self.refuse_show) return false;
        @memcpy(self.shown_text[self.shown_bytes..][0..action.text.len], action.text);
        self.shown[self.shown_count] = .{ .sequence = action.sequence, .channel = action.channel, .text = self.shown_text[self.shown_bytes..][0..action.text.len] };
        self.shown_bytes += action.text.len;
        self.shown_count += 1;
        return true;
    }
    fn shownText(self: *const Bench, out: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(out);
        for (self.shown[0..self.shown_count]) |action| writer.print("{d}:{s} ", .{ action.channel, action.text }) catch unreachable;
        return writer.buffered();
    }
    fn begin(self: *Bench) !void {
        var header: [256]u8 = undefined;
        try self.journal.start(try encodeHeader(.{ .toolchain = "test", .profile = "bootstrap", .program = @splat(1), .seed = 9, .tick_rate = 60, .grants = &.{} }, &header));
    }
    /// The kinds of the records of the disk's durable prefix, as letters: h, i, a, s, e.
    fn kinds(self: *Bench, bytes: []const u8, out: []u8) ![]const u8 {
        var image: Image = .{ .bytes = bytes };
        var prefix = try Prefix.init(image.disk(), &self.buffer);
        var at: usize = 0;
        while (try prefix.next()) |record| {
            out[at] = "hiase"[@backingInt(record.item.kind) - 1];
            at += 1;
        }
        return out[0..at];
    }
};

fn testLog() !*effects.Log {
    const log = try scratch.storage(effects.Log);
    scratch.initialise(log);
    return log;
}

test "a journal seals each commit point of the effect log, syncs in groups and shows only what is durable" {
    const log = try testLog();
    defer scratch.release(log);
    var b: Bench = .{};
    for ([_]bool{ true, false }) |retain| {
        b.init();
        b.journal.group = 2;
        try b.begin();
        log.sink = b.journal.sink();
        defer log.sink = null;
        log.reset(retain);
        var text: [256]u8 = undefined;
        try log.prepare("a");
        // Sealed, not yet synced: nothing is shown.
        try testing.expectEqual(@as(usize, 0), b.shown_count);
        try log.prepareOn(2, "b");
        // The second seal syncs both commit points, and both are shown.
        try testing.expectEqualStrings("0:a 2:b ", b.shownText(&text));
        log.begin();
        try log.prepare("c");
        log.begin();
        try log.prepareOn(4, "d");
        log.abort();
        try log.prepareOn(2, "e");
        try log.commit();
        try testing.expectEqualStrings("0:a 2:b ", b.shownText(&text));
        // A region that commits nothing has no seal and no sync.
        log.begin();
        try log.commit();
        try testing.expectEqual(@as(u64, 2), b.journal.syncs);
        // The end syncs what was left and shows it.
        try b.journal.finish(.{ .outcome = .completed });
        try testing.expectEqualStrings("0:a 2:b 0:c 2:e ", b.shownText(&text));
        try testing.expectEqual(@as(u64, 3), b.journal.syncs);
        var kinds: [32]u8 = undefined;
        try testing.expectEqualStrings("hasasaase", try b.kinds(b.memory.contents(), &kinds));
        const found = try scan(b.memory.disk(), &b.buffer);
        try testing.expect(found.has_header and found.end != null and found.end.?.outcome == .completed);
        try testing.expectEqual(@as(u64, 4), found.actions);
        try testing.expectEqual(b.memory.len, found.cut);
        // Every action shown came in sequence order, once.
        for (b.shown[0..b.shown_count], 0..) |action, index| try testing.expectEqual(@as(u64, index), action.sequence);
        try testing.expectEqual(@as(u64, 0), b.journal.reserved);
    }
}

test "every input from the world is in the journal before its value is returned, and the seal counts it" {
    const log = try testLog();
    defer scratch.release(log);
    var b: Bench = .{};
    b.init();
    try b.begin();
    const config = [_][]const u8{ "alpha", "beta" };
    var script: effects.Script = .{ .clocks = &.{7.5}, .streams = &.{&config} };
    log.sink = b.journal.sink();
    log.inputs.source = script.source();
    log.inputs.journal = b.journal.inputJournal();
    defer {
        log.sink = null;
        log.inputs.source = null;
        log.inputs.journal = null;
    }
    log.reset(false);
    const before = b.memory.len;
    const clock = try log.inputs.read(.{ .kind = .clock });
    // The record lies on the disk before the read returns.
    try testing.expect(b.memory.len > before);
    try testing.expectEqual(@as(f64, 7.5), @as(f64, @bitCast(clock.bits)));
    try log.prepare("after the clock");
    log.begin();
    const line = try log.inputs.read(.{ .kind = .line, .request = 0, .tick = 1 });
    try testing.expectEqualStrings("alpha", line.bytes);
    try log.prepare("alpha seen");
    log.abort();
    // The line was read in a region that failed: it is spent, and journaled all the same.
    _ = try log.inputs.read(.{ .kind = .line, .request = 0, .tick = 1 });
    try log.prepare("beta seen");
    _ = try log.inputs.read(.{ .kind = .line, .request = 0, .tick = 2 });
    try b.journal.finish(.{ .outcome = .fatal, .code = "division_by_zero", .start = 3, .end = 9 });
    var kinds: [32]u8 = undefined;
    try testing.expectEqualStrings("hiasiiasie", try b.kinds(b.memory.contents(), &kinds));
    var image: Image = .{ .bytes = b.memory.contents() };
    var prefix = try Prefix.init(image.disk(), &b.buffer);
    var inputs: u64 = 0;
    var seals: [2]Seal = undefined;
    var seal_count: usize = 0;
    while (try prefix.next()) |record| switch (record.decoded) {
        .input => |input| {
            try testing.expectEqual(inputs, input.sequence);
            const recorded = log.inputs.record().entries[inputs];
            try testing.expectEqual(recorded.kind, input.kind);
            try testing.expectEqual(recorded.tick, input.tick);
            try testing.expectEqual(recorded.status, input.status);
            try testing.expectEqual(recorded.bits, input.bits);
            try testing.expectEqualStrings(log.inputs.value(@intCast(inputs)), input.bytes);
            inputs += 1;
        },
        .seal => |seal| {
            seals[seal_count] = seal;
            seal_count += 1;
        },
        .end => |end| {
            try testing.expectEqual(Outcome.fatal, end.outcome);
            try testing.expectEqualStrings("division_by_zero", end.code);
            try testing.expectEqual(@as(u32, 9), end.end);
        },
        else => {},
    };
    try testing.expectEqual(@as(u64, 4), inputs);
    try testing.expectEqualDeep([2]Seal{ .{ .actions = 1, .inputs = 1 }, .{ .actions = 2, .inputs = 3 } }, seals);
}

/// A log scenario of commit points and inputs, with the commit points it has, for the tests
/// that fail and crash every disk operation in turn. It stops at the first error.
fn scenario(log: *effects.Log) (effects.Error || effects.InputError)!void {
    try log.prepare("p0");
    _ = try log.inputs.read(.{ .kind = .clock });
    log.begin();
    try log.prepareOn(2, "w1");
    _ = try log.inputs.read(.{ .kind = .line, .request = 0 });
    log.begin();
    try log.prepare("p2");
    try log.commit();
    try log.prepare("p3");
    try log.commit();
    log.begin();
    try log.prepare("gone");
    log.abort();
    _ = try log.inputs.read(.{ .kind = .line, .request = 0, .tick = 2 });
    try log.prepareOn(2, "w4");
    try log.prepare("p5");
}

/// The commit points of `scenario`: the number of actions committed after each.
const scenario_points = [_]u64{ 1, 4, 5, 6 };

test "an append or a sync that fails, at every disk operation in turn, ends the run where it fails and leaves whole commit points" {
    const log = try testLog();
    defer scratch.release(log);
    var b: Bench = .{};
    const config = [_][]const u8{ "alpha", "beta" };
    var script: effects.Script = .{ .streams = &.{&config} };
    log.inputs.source = script.source();
    defer {
        log.sink = null;
        log.inputs.source = null;
        log.inputs.journal = null;
    }
    // The uninterrupted run, to count its disk operations.
    b.init();
    try b.begin();
    log.sink = b.journal.sink();
    log.inputs.journal = b.journal.inputJournal();
    log.reset(false);
    script.rewind();
    try scenario(log);
    try b.journal.finish(.{ .outcome = .completed });
    const appends = b.memory.appends;
    const syncs = b.memory.syncs;
    try testing.expectEqual(@as(u64, 1 + 3 + 6 + 4 + 1), appends);
    for ([_]bool{ true, false }) |appending| {
        const operations = if (appending) appends else syncs;
        for (0..operations) |failing| {
            b.init();
            if (appending) b.memory.fail_append = failing else b.memory.fail_sync = failing;
            log.sink = b.journal.sink();
            log.inputs.journal = b.journal.inputJournal();
            log.reset(false);
            script.rewind();
            if (failing == 0) {
                // The header's append or sync: no journal, and nothing runs.
                try testing.expectError(error.DiskFailed, b.begin());
                continue;
            }
            try b.begin();
            const outcome = scenario(log);
            const failed_at_end = if (outcome) |_| b.journal.finish(.{ .outcome = .completed }) else |_| b.journal.finish(.{ .outcome = .fatal, .code = "x" });
            try testing.expectError(error.DiskFailed, failed_at_end);
            try testing.expect(b.journal.failed);
            if (outcome) |_| {
                // Only the end's append or sync is left to fail.
                try testing.expect(failing + 1 == operations);
            } else |problem| try testing.expect(problem == error.EffectCommitFailed or problem == error.InputFailed);
            // The journal refuses everything after it failed.
            try testing.expect(!b.journal.sink().prepare(&b.journal, "late"));
            // What the disk holds, synced or not, is cut at whole commit points of the scenario.
            for ([_][]const u8{ b.memory.bytes[0..b.memory.synced], b.memory.contents() }) |bytes| {
                var image: Image = .{ .bytes = bytes };
                const found = try scan(image.disk(), &b.buffer);
                try testing.expect(found.has_header);
                try testing.expect(found.actions == 0 or std.mem.indexOfScalar(u64, &scenario_points, found.actions) != null);
            }
            // What was shown is the synced prefix's actions, and nothing else.
            var image: Image = .{ .bytes = b.memory.bytes[0..b.memory.synced] };
            try testing.expectEqual((try scan(image.disk(), &b.buffer)).actions, b.shown_count);
        }
    }
}

test "the quota refuses the prepare that would pass it, then an input, and always keeps room for the end" {
    const log = try testLog();
    defer scratch.release(log);
    var b: Bench = .{};
    var script: effects.Script = .{};
    log.inputs.source = script.source();
    defer {
        log.sink = null;
        log.inputs.source = null;
        log.inputs.journal = null;
    }
    b.init();
    try b.begin();
    const header_end = b.memory.len;
    // Room for the header, two actions of four bytes with their seals, and an end.
    b.journal.quota = header_end + 2 * (actionRecordBytes(4) + seal_record_bytes) + end_record_bytes;
    log.sink = b.journal.sink();
    log.inputs.journal = b.journal.inputJournal();
    log.reset(true);
    try log.prepare("abcd");
    log.begin();
    try log.prepare("efgh");
    try testing.expectError(error.EffectPrepareFailed, log.prepare("i"));
    log.abort();
    // The room an aborted action held is given back.
    try log.prepare("ijkl");
    try testing.expectError(error.EffectPrepareFailed, log.prepare(""));
    try testing.expectError(error.InputFailed, log.inputs.read(.{ .kind = .clock }));
    try testing.expectEqual(@as(u32, 0), log.inputs.count);
    try b.journal.finish(.{ .outcome = .fatal, .code = "effect_prepare_failed", .start = 1, .end = 2 });
    try testing.expect(b.memory.len <= b.journal.quota.?);
    // A text longer than the read-back buffer holds is refused at its prepare.
    b.init();
    try b.begin();
    log.sink = b.journal.sink();
    log.reset(false);
    b.journal.consumer = null;
    const long: [2048]u8 = @splat('x');
    try testing.expectError(error.EffectPrepareFailed, log.prepare(&long));
    try log.prepare(long[0 .. b.buffer.len - 4 - action_fixed]);
}

test "a consumer that cannot take more ends the run at the seal that showed it, and a read back that fails is a disk that failed" {
    const log = try testLog();
    defer scratch.release(log);
    var b: Bench = .{};
    defer log.sink = null;
    b.init();
    try b.begin();
    log.sink = b.journal.sink();
    log.reset(false);
    try log.prepare("a");
    b.refuse_show = true;
    try testing.expectError(error.EffectCommitFailed, log.prepare("b"));
    // The disk is whole: the journal still takes its end.
    try testing.expect(!b.journal.failed);
    try b.journal.finish(.{ .outcome = .fatal, .code = "effect_commit_failed" });
    b.init();
    try b.begin();
    log.sink = b.journal.sink();
    log.reset(false);
    b.memory.fail_read = b.memory.reads;
    try testing.expectError(error.EffectCommitFailed, log.prepare("a"));
    try testing.expect(b.journal.failed);
}

/// A journal whose records are built one at a time, for forged files.
const Forge = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn record(self: *Forge, kind: u8, payload: []const u8) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], @intCast(payload.len), .little);
        self.bytes[self.len + 4] = kind;
        @memcpy(self.bytes[self.len + 5 ..][0..payload.len], payload);
        std.mem.writeInt(u32, self.bytes[self.len + 5 + payload.len ..][0..4], checksum(kind, &.{payload}), .little);
        self.len += frame_bytes + payload.len;
    }
    fn header(self: *Forge) void {
        var buffer: [256]u8 = undefined;
        self.record(1, encodeHeader(.{ .toolchain = "t", .profile = "bootstrap", .program = @splat(0), .seed = 1, .tick_rate = 60, .grants = &.{} }, &buffer) catch unreachable);
    }
    fn action(self: *Forge, sequence: u64, text: []const u8) void {
        var payload: [1024]u8 = undefined;
        var e: Encoder = .{ .out = &payload };
        e.int(u64, sequence) catch unreachable;
        e.int(u32, 0) catch unreachable;
        e.text(text) catch unreachable;
        self.record(3, payload[0..e.at]);
    }
    fn seal(self: *Forge, actions: u64, inputs: u64) void {
        var payload: [16]u8 = undefined;
        std.mem.writeInt(u64, payload[0..8], actions, .little);
        std.mem.writeInt(u64, payload[8..16], inputs, .little);
        self.record(4, &payload);
    }
    fn end(self: *Forge) void {
        self.record(5, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    }
    /// RFC-0087, P5.7: a `published` record.
    fn published(self: *Forge, generation: u8, through: u64) void {
        var payload: [40]u8 = undefined;
        @memset(payload[0..32], generation);
        std.mem.writeInt(u64, payload[32..40], through, .little);
        self.record(6, &payload);
    }
    /// An input of the world: a clock reading.
    fn clock(self: *Forge, sequence: u64) void {
        var payload: [64]u8 = undefined;
        var e: Encoder = .{ .out = &payload };
        e.int(u64, sequence) catch unreachable;
        e.int(u8, @backingInt(effects.InputKind.clock)) catch unreachable;
        e.int(u32, 0) catch unreachable;
        e.int(u64, 0) catch unreachable;
        e.int(u8, @backingInt(effects.InputStatus.value)) catch unreachable;
        e.int(u64, 0) catch unreachable;
        e.text("") catch unreachable;
        self.record(2, payload[0..e.at]);
    }
    fn scanned(self: *const Forge, buffer: []u8) !Scan {
        var image: Image = .{ .bytes = self.bytes[0..self.len] };
        return scan(image.disk(), buffer);
    }
};

test "a forged journal ends at its first record that is torn, flipped, unknown, out of order or after the end" {
    var buffer: [1024]u8 = undefined;
    var good: Forge = .{};
    good.header();
    const header_end = good.len;
    good.action(0, "one");
    good.seal(1, 0);
    const first_seal = good.len;
    good.action(1, "two");
    good.action(2, "three");
    good.seal(3, 0);
    const second_seal = good.len;
    good.end();
    const found = try good.scanned(&buffer);
    try testing.expect(found.has_header and found.end != null);
    try testing.expectEqual(good.len, found.cut);
    try testing.expectEqual(@as(u64, 3), found.actions);
    // Truncated at every length: the cut is the last whole seal before it, never past it.
    for (0..good.len) |length| {
        var image: Image = .{ .bytes = good.bytes[0..length] };
        const cut = try scan(image.disk(), &buffer);
        try testing.expectEqual(length >= header_end, cut.has_header);
        const expected: usize = if (length < header_end) 0 else if (length < first_seal) header_end else if (length < second_seal) first_seal else second_seal;
        try testing.expectEqual(@as(u64, expected), cut.cut);
        try testing.expect(cut.end == null);
    }
    // A byte flipped anywhere: the journal ends at the record that holds it.
    const starts = [_]usize{ 0, header_end, header_end + frame_bytes + action_fixed + 3, first_seal, first_seal + frame_bytes + action_fixed + 3, first_seal + 2 * (frame_bytes + action_fixed) + 3 + 5, second_seal, good.len };
    for (0..good.len) |at| {
        var flipped = good;
        flipped.bytes[at] ^= 0x10;
        const cut = try flipped.scanned(&buffer);
        var holder: usize = 0;
        while (starts[holder + 1] <= at) holder += 1;
        try testing.expect(cut.valid <= starts[holder]);
        try testing.expect(cut.cut <= starts[holder]);
    }
    // Records that are valid each on their own, in an order no journal has.
    const Case = struct { build: *const fn (*Forge) void, cut: u64 };
    const cases = [_]Case{
        // An unknown kind with a valid checksum.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.record(6, "");
                x.action(1, "b");
                x.seal(2, 0);
            }
        }.f, .cut = 1 },
        // Two headers.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.header();
                x.action(1, "b");
                x.seal(2, 0);
            }
        }.f, .cut = 1 },
        // An action out of sequence.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.action(2, "b");
                x.seal(2, 0);
            }
        }.f, .cut = 1 },
        // A seal that names other counts, and one that seals no new action.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.action(1, "b");
                x.seal(2, 1);
            }
        }.f, .cut = 1 },
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.seal(1, 0);
                x.action(1, "b");
                x.seal(2, 0);
            }
        }.f, .cut = 1 },
        // An end after an action that was never sealed.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.action(1, "b");
                x.end();
            }
        }.f, .cut = 1 },
        // A record after the end.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.end();
                x.action(1, "b");
                x.seal(2, 0);
            }
        }.f, .cut = 1 },
        // A length no record may have, and a payload that does not decode exactly.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                std.mem.writeInt(u32, x.bytes[x.len..][0..4], max_payload + 1, .little);
                x.bytes[x.len + 4] = 3;
                x.len += 5;
            }
        }.f, .cut = 1 },
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.header();
                x.action(0, "a");
                x.seal(1, 0);
                x.record(4, &.{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
            }
        }.f, .cut = 1 },
        // No header first.
        .{ .build = struct {
            fn f(x: *Forge) void {
                x.action(0, "a");
                x.seal(1, 0);
            }
        }.f, .cut = 0 },
    };
    for (cases, 0..) |case, index| {
        var forged: Forge = .{};
        case.build(&forged);
        const cut = try forged.scanned(&buffer);
        errdefer std.debug.print("forged journal {d}\n", .{index});
        try testing.expectEqual(case.cut, cut.actions);
        try testing.expectEqual(case.cut != 0 or index != cases.len - 1, cut.has_header);
    }
    // A record longer than the reader's buffer is not an end: the reader cannot follow it.
    var long: Forge = .{};
    long.header();
    long.action(0, &(@as([600]u8, @splat('x'))));
    var image: Image = .{ .bytes = long.bytes[0..long.len] };
    try testing.expectError(error.RecordTooLarge, scan(image.disk(), buffer[0..512]));
    // A disk that cannot be read is an error, not an end.
    var memory: Memory = .{ .bytes = &long.bytes, .len = long.len, .fail_read = 1 };
    try testing.expectError(error.DiskFailed, scan(memory.disk(), &buffer));
}

// ---- Recovery (P2.5) ------------------------------------------------------------------------

/// The scenario's journal, written whole on `b`, with its bytes copied to `out`.
fn wholeScenario(b: *Bench, log: *effects.Log, script: *effects.Script, out: []u8) ![]const u8 {
    b.init();
    try b.begin();
    log.sink = b.journal.sink();
    log.inputs.source = script.source();
    log.inputs.journal = b.journal.inputJournal();
    log.reset(false);
    script.rewind();
    try scenario(log);
    try b.journal.finish(.{ .outcome = .completed });
    @memcpy(out[0..b.memory.len], b.memory.contents());
    return out[0..b.memory.len];
}

/// `b`'s disk holding `image`, cut (R1) and resumed (R4), with `log` given the sealed inputs.
fn resumeOn(b: *Bench, log: *effects.Log, script: *effects.Script, image: []const u8, sealed: *SealedInputs) !Scan {
    b.init();
    @memcpy(b.storage[0..image.len], image);
    b.memory.len = image.len;
    b.memory.synced = image.len;
    const found = try scan(b.memory.disk(), &b.buffer);
    try cutAt(b.memory.disk(), found);
    log.sink = b.journal.sink();
    log.inputs.journal = b.journal.inputJournal();
    log.inputs.prefix = try sealed.load(b.memory.disk(), &b.buffer);
    log.reset(false);
    script.rewind();
    // The world goes on past the lines that were sealed (R6).
    for (log.inputs.prefix.entries) |entry| if (entry.kind == .line and entry.status == .value) {
        script.cursors[entry.request] += 1;
    };
    b.journal.resumeAt(found);
    // Nothing sealed is shown again: the consumer's next action is the first past the cut.
    b.shown_count = 0;
    return found;
}

test "a journal cut at any length and resumed verifies what was sealed, appends the rest, and shows only what is new" {
    const log = try testLog();
    defer scratch.release(log);
    const sealed = try scratch.storage(SealedInputs);
    defer scratch.release(sealed);
    var b: Bench = .{};
    const config = [_][]const u8{ "alpha", "beta" };
    var script: effects.Script = .{ .streams = &.{&config} };
    defer {
        log.sink = null;
        log.inputs.source = null;
        log.inputs.journal = null;
        log.inputs.prefix = .{};
    }
    var whole_bytes: [16 * 1024]u8 = undefined;
    const whole = try wholeScenario(&b, log, &script, &whole_bytes);
    var header_end: usize = 0;
    {
        var image: Image = .{ .bytes = whole };
        var reader: Reader = .{ .disk = image.disk(), .buffer = &b.buffer };
        header_end = @intCast((try reader.next()).?.end);
    }
    var resumed: usize = 0;
    // Cut short at every length past the header, as a crash leaves a journal.
    for (header_end..whole.len) |length| {
        const found = try resumeOn(&b, log, &script, whole[0..length], sealed);
        try testing.expect(!found.finished());
        try testing.expectEqual(found.cut, b.memory.len);
        try testing.expectEqual(found.inputs, sealed.count);
        try scenario(log);
        try testing.expect(!b.journal.diverged and !b.journal.verifying());
        try b.journal.finish(.{ .outcome = .completed });
        try testing.expectEqualSlices(u8, whole, b.memory.contents());
        // What was shown is what lies past the cut, each action once.
        try testing.expectEqual(scenario_points[scenario_points.len - 1] - found.actions, b.shown_count);
        if (b.shown_count != 0) try testing.expectEqual(found.actions, b.shown[0].sequence);
        resumed += 1;
    }
    try testing.expect(resumed > 100);
}

test "a resumed journal refuses an action, a commit point and an input that are not its own, and a run that ends early" {
    const log = try testLog();
    defer scratch.release(log);
    const sealed = try scratch.storage(SealedInputs);
    defer scratch.release(sealed);
    var b: Bench = .{};
    const config = [_][]const u8{ "alpha", "beta" };
    var script: effects.Script = .{ .streams = &.{&config} };
    log.inputs.source = script.source();
    defer {
        log.sink = null;
        log.inputs.source = null;
        log.inputs.journal = null;
        log.inputs.prefix = .{};
    }
    var whole_bytes: [16 * 1024]u8 = undefined;
    const whole = try wholeScenario(&b, log, &script, &whole_bytes);
    // Cut after the second commit point: `p0`, then `w1 p2 p3` with a clock and a line read.
    var cut_at: usize = 0;
    {
        var image: Image = .{ .bytes = whole };
        var prefix = try Prefix.init(image.disk(), &b.buffer);
        var seals: usize = 0;
        while (try prefix.next()) |record| if (record.decoded == .seal) {
            seals += 1;
            if (seals == 2) cut_at = @intCast(record.item.end);
        };
    }
    const image = whole[0..cut_at];
    // Another text.
    _ = try resumeOn(&b, log, &script, image, sealed);
    try log.prepare("p0");
    _ = try log.inputs.read(.{ .kind = .clock });
    log.begin();
    try log.prepareOn(2, "w1");
    _ = try log.inputs.read(.{ .kind = .line, .request = 0 });
    try log.prepare("p9");
    try testing.expectError(error.EffectCommitFailed, log.commit());
    try testing.expect(b.journal.diverged);
    try testing.expectEqualSlices(u8, image, b.memory.contents());
    try testing.expectError(error.Diverged, b.journal.finish(.{ .outcome = .completed }));
    // Another channel.
    _ = try resumeOn(&b, log, &script, image, sealed);
    try testing.expectError(error.EffectCommitFailed, log.prepareOn(3, "p0"));
    try testing.expect(b.journal.diverged);
    // A commit point that straddles the journal's: two actions where it sealed one.
    _ = try resumeOn(&b, log, &script, image, sealed);
    log.begin();
    try log.prepare("p0");
    try log.prepare("p1");
    try testing.expectError(error.EffectCommitFailed, log.commit());
    try testing.expect(b.journal.diverged);
    // A seal whose inputs are not the journal's: neither the clock nor the line was read.
    _ = try resumeOn(&b, log, &script, image, sealed);
    try log.prepare("p0");
    log.begin();
    try log.prepareOn(2, "w1");
    try log.prepare("p2");
    try log.prepare("p3");
    try testing.expectError(error.EffectCommitFailed, log.commit());
    try testing.expect(b.journal.diverged);
    // An input of the world asked for before the last seal (JM3): the prefix is spent early.
    _ = try resumeOn(&b, log, &script, image, sealed);
    _ = try log.inputs.read(.{ .kind = .clock });
    _ = try log.inputs.read(.{ .kind = .line, .request = 0 });
    try testing.expectError(error.InputFailed, log.inputs.read(.{ .kind = .line, .request = 0, .tick = 1 }));
    try testing.expect(b.journal.diverged);
    // An input other than the one the prefix holds: the log refuses it, and the journal is left.
    _ = try resumeOn(&b, log, &script, image, sealed);
    try testing.expectError(error.InputDiverged, log.inputs.read(.{ .kind = .line, .request = 0 }));
    try testing.expectEqualSlices(u8, image, b.memory.contents());
    // A run that ends before the last seal did not commit what the journal holds.
    _ = try resumeOn(&b, log, &script, image, sealed);
    try log.prepare("p0");
    try testing.expectError(error.Diverged, b.journal.finish(.{ .outcome = .completed }));
    try testing.expectEqualSlices(u8, image, b.memory.contents());
}

test "abandoning ends a journal that every reader then takes as finished, and nothing may follow it" {
    var buffer: [1024]u8 = undefined;
    var good: Forge = .{};
    good.header();
    good.action(0, "one");
    good.seal(1, 0);
    const sealed_end = good.len;
    good.action(1, "lost");
    var image: Image = .{ .bytes = good.bytes[0..good.len] };
    var memory: Memory = .{ .bytes = &good.bytes, .len = good.len, .synced = good.len };
    const found = try scan(image.disk(), &buffer);
    try testing.expect(!found.finished() and found.cut == sealed_end);
    try cutAt(memory.disk(), found);
    try testing.expectEqual(sealed_end, memory.len);
    var journal: Journal = .init(memory.disk(), &buffer);
    journal.resumeAt(found);
    try journal.abandon();
    const ended = try scan(memory.disk(), &buffer);
    try testing.expect(ended.finished() and ended.abandoned and ended.end == null and ended.actions == 1 and ended.cut == memory.len);
    // A record after `abandoned`, or `abandoned` after an action not sealed, ends the journal.
    var after: Forge = .{};
    after.header();
    after.action(0, "a");
    after.seal(1, 0);
    after.record(7, "");
    const abandoned_end = after.len;
    after.action(1, "b");
    after.seal(2, 0);
    const cut = try after.scanned(&buffer);
    try testing.expect(cut.abandoned and cut.cut == abandoned_end and cut.actions == 1);
    var unsealed: Forge = .{};
    unsealed.header();
    unsealed.action(0, "a");
    unsealed.record(7, "");
    try testing.expect(!(try unsealed.scanned(&buffer)).finished());
    // An `abandoned` with a payload is malformed, and so is a `published` without its payload.
    var payload: Forge = .{};
    payload.header();
    payload.record(7, "x");
    try testing.expect(!(try payload.scanned(&buffer)).finished());
    var six: Forge = .{};
    six.header();
    six.action(0, "a");
    six.seal(1, 0);
    six.record(6, "");
    six.action(1, "b");
    six.seal(2, 0);
    try testing.expectEqual(@as(u64, 1), (try six.scanned(&buffer)).actions);
    // A disk whose truncation fails is a cut that fails.
    var failing: Memory = .{ .bytes = &good.bytes, .len = good.len, .fail_truncate = 0 };
    try testing.expectError(error.DiskFailed, cutAt(failing.disk(), found));
}

test "a published record covers the durable prefix, follows the end, and one that is forged ends the journal" {
    var buffer: [1024]u8 = undefined;
    // A publication before a resume, then the end and the publication at the end.
    var good: Forge = .{};
    good.header();
    good.clock(0);
    good.action(0, "a");
    good.seal(1, 1);
    good.published(1, 1);
    const first = good.len;
    good.action(1, "b");
    good.seal(2, 1);
    good.end();
    good.published(2, 2);
    const whole = try good.scanned(&buffer);
    try testing.expect(whole.finished() and whole.cut == good.len and whole.actions == 2);
    try testing.expectEqual(@as(u8, 2), whole.published.?.generation[0]);
    try testing.expectEqual(@as(u64, 2), whole.published.?.through);
    // Cut after the first publication, the journal is unfinished and keeps it.
    var image: Image = .{ .bytes = good.bytes[0 .. first + 3] };
    const cut = try scan(image.disk(), &buffer);
    try testing.expect(!cut.finished() and cut.cut == first and cut.published.?.through == 1);
    // Each forgery ends the journal at the record: `through` past the sealed actions, short of
    // them, a record no later than the one before it, one after an action or an input not sealed,
    // an all-zero generation, a second record after the end, and anything but one after the end.
    const Case = struct { build: *const fn (*Forge) void, actions: u64, published: ?u64 };
    const cases = [_]Case{
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.published(1, 2);
            }
        }.f, .actions = 1, .published = null },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.published(1, 0);
            }
        }.f, .actions = 1, .published = null },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.published(1, 1);
                forge.published(2, 1);
            }
        }.f, .actions = 1, .published = 1 },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.action(1, "b");
                forge.published(1, 1);
            }
        }.f, .actions = 1, .published = null },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.clock(0);
                forge.published(1, 1);
            }
        }.f, .actions = 1, .published = null },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.published(0, 1);
            }
        }.f, .actions = 1, .published = null },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.end();
                forge.published(1, 1);
                forge.published(2, 1);
            }
        }.f, .actions = 1, .published = 1 },
        .{ .build = struct {
            fn f(forge: *Forge) void {
                forge.action(0, "a");
                forge.seal(1, 0);
                forge.end();
                forge.published(1, 1);
                forge.action(1, "b");
                forge.seal(2, 0);
            }
        }.f, .actions = 1, .published = 1 },
    };
    for (cases) |case| {
        var forged: Forge = .{};
        forged.header();
        case.build(&forged);
        const found = try forged.scanned(&buffer);
        try testing.expectEqual(case.actions, found.actions);
        try testing.expectEqual(case.published, if (found.published) |held| held.through else null);
        try testing.expect(found.valid < forged.len);
    }
    // An unsealed input after the end is the end's, and a publication may follow it.
    var after: Forge = .{};
    after.header();
    after.action(0, "a");
    after.seal(1, 0);
    after.clock(0);
    after.end();
    after.published(1, 1);
    try testing.expectEqual(after.len, (try after.scanned(&buffer)).cut);
}

test "a journal records its publications after its end and before a resume, and verifying a resumed one passes over them" {
    var buffer: [1024]u8 = undefined;
    var bytes: [4096]u8 = undefined;
    var memory: Memory = .{ .bytes = &bytes };
    var journal: Journal = .init(memory.disk(), &buffer);
    var header: [256]u8 = undefined;
    try journal.start(try encodeHeader(.{ .toolchain = "t", .profile = "bootstrap", .program = @splat(0), .seed = 1, .tick_rate = 60, .grants = &.{} }, &header));
    const sink = journal.sink();
    try testing.expect(sink.prepare(sink.context, "a") and sink.commit(sink.context, .{ .sequence = 0, .channel = 1, .text = "a" }) and sink.seal.?(sink.context, 1));
    // A crash: the journal is reopened after its cut, and a publication recorded before the resume.
    const found = try scan(memory.disk(), &buffer);
    var reopened: Journal = .init(memory.disk(), &buffer);
    reopened.reopen(found);
    try reopened.recordPublished(.{ .generation = @splat(5), .through = 1 });
    var resumed_scan = try scan(memory.disk(), &buffer);
    try testing.expect(!resumed_scan.finished() and resumed_scan.cut == memory.len and resumed_scan.published.?.through == 1);
    // The resumed run commits what was sealed, verified past the record, then more.
    var resumed: Journal = .init(memory.disk(), &buffer);
    resumed.resumeAt(resumed_scan);
    const again = resumed.sink();
    try testing.expect(again.prepare(again.context, "a") and again.commit(again.context, .{ .sequence = 0, .channel = 1, .text = "a" }) and again.seal.?(again.context, 1));
    try testing.expect(!resumed.verifying() and !resumed.diverged);
    try testing.expect(again.prepare(again.context, "b") and again.commit(again.context, .{ .sequence = 1, .channel = 1, .text = "b" }) and again.seal.?(again.context, 2));
    try resumed.finish(.{ .outcome = .completed });
    // At the end the whole prefix is published, and its record follows the end.
    try resumed.recordPublished(.{ .generation = @splat(6), .through = 2 });
    resumed_scan = try scan(memory.disk(), &buffer);
    try testing.expect(resumed_scan.finished() and resumed_scan.end != null and resumed_scan.cut == memory.len and resumed_scan.published.?.generation[0] == 6);
    // A finished journal reopened records nothing new in this test, and abandons nothing.
    var finished: Journal = .init(memory.disk(), &buffer);
    finished.reopen(resumed_scan);
    try testing.expect(finished.ended);
    // `abandoned` follows a record of a publication, and one may follow it.
    var other_bytes: [4096]u8 = undefined;
    var other: Memory = .{ .bytes = &other_bytes };
    @memcpy(other_bytes[0..found.cut], bytes[0..found.cut]);
    other.len = found.cut;
    other.synced = found.cut;
    var abandoning: Journal = .init(other.disk(), &buffer);
    abandoning.reopen(found);
    try abandoning.recordPublished(.{ .generation = @splat(5), .through = 1 });
    try abandoning.abandon();
    const ended = try scan(other.disk(), &buffer);
    try testing.expect(ended.abandoned and ended.published.?.through == 1 and ended.cut == other.len);
}

test "a header is another run's by its toolchain, profile, program, seed, tick rate or grants" {
    const grants = [_]GrantRecord{ .{ .kind = .reader, .name = "config", .path = "c.txt", .repositionable = true }, .{ .kind = .writer, .name = "log", .path = "l.txt" } };
    const header: Header = .{ .toolchain = "t", .profile = "bootstrap", .program = @splat(1), .seed = 4, .tick_rate = 60, .grants = &grants };
    try testing.expectEqual(@as(?Mismatch, null), mismatch(header, header));
    // Whether a reader can be repositioned and a writer's base are the host's to check.
    var other_grants = grants;
    other_grants[0].repositionable = false;
    other_grants[1].base = @splat(9);
    var same = header;
    same.grants = &other_grants;
    try testing.expectEqual(@as(?Mismatch, null), mismatch(header, same));
    var changed = header;
    changed.toolchain = "u";
    try testing.expectEqual(@as(?Mismatch, .toolchain), mismatch(header, changed));
    changed = header;
    changed.profile = "program";
    try testing.expectEqual(@as(?Mismatch, .profile), mismatch(header, changed));
    changed = header;
    changed.program[31] = 2;
    try testing.expectEqual(@as(?Mismatch, .program), mismatch(header, changed));
    changed = header;
    changed.seed = 5;
    try testing.expectEqual(@as(?Mismatch, .seed), mismatch(header, changed));
    changed = header;
    changed.tick_rate = 30;
    try testing.expectEqual(@as(?Mismatch, .tick_rate), mismatch(header, changed));
    const moved = [_]GrantRecord{ grants[0], .{ .kind = .writer, .name = "log", .path = "m.txt" } };
    const renamed = [_]GrantRecord{ grants[0], .{ .kind = .writer, .name = "audit", .path = "l.txt" } };
    const swapped = [_]GrantRecord{ grants[1], grants[0] };
    for ([_][]const GrantRecord{ grants[0..1], &swapped, &moved, &renamed }) |list| {
        changed = header;
        changed.grants = list;
        try testing.expectEqual(@as(?Mismatch, .grants), mismatch(header, changed));
    }
}
