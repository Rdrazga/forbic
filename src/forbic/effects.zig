//! Native effects (RFC-0079): what a run does to the world, and what it takes from it.
//!
//! A run acts on the world only through an effect native, and an effect native only describes
//! its action: it hands the bytes to the run's `Log`. The log holds the action under the
//! rollback region that is open at the call. When that region fails the action is dropped and
//! was never visible; when the outermost region around it commits, or at once when there is
//! none, the action is committed in program order. So output obeys the rule that state obeys:
//! what a failed `Attempt` did, it did not do.
//!
//! What a run takes from the world is different: it cannot be given back. A draw advances the
//! run's `Stream` and a rollback does not move it back (RFC-0067 D19). The stream is a pure
//! function of a seed and a position, so the seed is the whole record of the world's part in a
//! run: a second machine and a report replay that start from the same seed read the same
//! values, and never ask the world again.
//!
//! Regions here are counted, not stored. `depth` is the number of open regions, and a mark is
//! kept only for a region in which an action was prepared, so a mark always owns at least one
//! pending action and the marks need no capacity of their own. Opening, committing and failing
//! a region are each one step, whatever the region did; dropping its actions costs a step per
//! action only when a sink has to be told.
const std = @import("std");
const active = @import("profile.zig").active;
const assert = std.debug.assert;

pub const entry_capacity: comptime_int = active.effect_entries;
pub const byte_capacity: comptime_int = active.effect_bytes;

comptime {
    assert(entry_capacity > 0 and entry_capacity <= std.math.maxInt(u32));
    assert(byte_capacity > 0 and byte_capacity <= std.math.maxInt(u32));
}

/// RFC-0086: the entries an input record holds, and the bytes of their values.
pub const input_entry_capacity: comptime_int = active.input_entries;
pub const input_byte_capacity: comptime_int = active.input_bytes;

comptime {
    assert(input_entry_capacity > 0 and input_entry_capacity < std.math.maxInt(u32));
    assert(input_byte_capacity > 0 and input_byte_capacity <= std.math.maxInt(u32));
}

/// RFC-0086, P2.3: the grants a host may give a run. A writer's channel is its index plus one,
/// so the channels fit in 32 bits with room to spare.
pub const grant_capacity: comptime_int = active.grants;
/// The longest name a grant may have, in bytes: the length of an identifier.
pub const grant_name_bytes = 128;

comptime {
    assert(grant_capacity > 0 and grant_capacity < std.math.maxInt(u32));
}

/// What a grant gives (RFC-0086 H1): a line source, or an append-only channel. RFC-0087 appends
/// its kinds. The enum is open so that a forged definition or record can name a kind that does
/// not exist, and each machine can be seen to refuse it.
pub const GrantKind = enum(u8) { reader, writer, session, key, _ };

/// One capability the host gives a run before it starts (H1): a kind and a name, distinct per
/// kind. The name borrows the host's storage for the length of the run and of its report.
pub const Grant = struct { kind: GrantKind, name: []const u8 };

/// Whether a list of grants is one a host may give: at most `grant_capacity`, each of a known
/// kind, named with 1 to `grant_name_bytes` bytes of UTF-8 text, no two of a kind named alike.
/// The comparison of every pair is quadratic in a list of at most `grant_capacity`, and runs
/// once, before a run or a replay.
pub fn validGrants(grants: []const Grant) bool {
    if (grants.len > grant_capacity) return false;
    for (grants, 0..) |grant, index| {
        // RFC-0087, P5.5: and the persistent keys a host grants by name (K2).
        if (grant.kind != .reader and grant.kind != .writer and grant.kind != .key) return false;
        if (grant.name.len == 0 or grant.name.len > grant_name_bytes or !std.unicode.utf8ValidateSlice(grant.name)) return false;
        for (grants[0..index]) |earlier| if (earlier.kind == grant.kind and std.mem.eql(u8, earlier.name, grant.name)) return false;
    }
    return true;
}

/// The channel of the writer granted at `index` (H5): channel 0 is `Print`'s.
/// Saturating, so that an index no admitted grant has (a forged report's) gives a channel no
/// writer has, rather than stopping the host.
pub fn writerChannel(index: u32) u32 {
    return @min(index +| 1, store_channel - 1);
}

/// RFC-0087, P5.5 (S5): the channel of the actions that save a write of a persistent cell, the
/// largest channel number. No writer has it (`writerChannel` stays below it), so a store action
/// and a line of a writer are never taken for each other.
pub const store_channel: u32 = std.math.maxInt(u32);

/// The seed of a run whose host supplies none. It is fixed, so that a run is repeatable unless
/// a host decides otherwise; its value is part of every journal and replay, so it never changes.
pub const default_seed: u64 = 0x5645_5253_452f_5400;

/// Words a bounded draw may reject in a row before it gives up. Each is rejected with
/// probability below one half, so this is never reached; it is what makes the loop bounded.
pub const max_rejections = 128;

/// The run's source of randomness: SplitMix64 written as a function of the position, so that
/// a stream has no state but how far it has been read. It is a statistical generator, not a
/// cryptographic one; a host that wants unpredictable runs supplies an unpredictable seed.
pub const Stream = struct {
    seed: u64 = default_seed,
    /// Words read so far. Rollback never lowers it.
    position: u64 = 0,

    /// The word at `position` of the stream that `seed` names.
    pub fn word(seed: u64, position: u64) u64 {
        var z = seed +% (position +% 1) *% 0x9e3779b97f4a7c15;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    pub fn next(self: *Stream) u64 {
        const value = word(self.seed, self.position);
        self.position +%= 1;
        return value;
    }

    /// A uniform value in `0..bound-1`. Words in the part of the range that would favour the
    /// low values are rejected and drawn again, never folded back in. Null when
    /// `max_rejections` words in a row were rejected.
    pub fn below(self: *Stream, bound: u64) ?u64 {
        assert(bound != 0);
        // 2^64 mod bound: that many of the lowest words are one too many for an even split.
        const rejected = (0 -% bound) % bound;
        for (0..max_rejections) |_| {
            const value = self.next();
            if (value >= rejected) return value % bound;
        }
        return null;
    }

    /// A uniform integer between the two bounds, both included, given in either order.
    pub fn integer(self: *Stream, first: i64, second: i64) ?i64 {
        const low = @min(first, second);
        const high = @max(first, second);
        // The width as an unsigned number: the whole of `i64` is one less than 2^64.
        const width: u64 = @bitCast(high -% low);
        const offset = if (width == std.math.maxInt(u64)) self.next() else self.below(width + 1) orelse return null;
        return @bitCast(@as(u64, @bitCast(low)) +% offset);
    }

    /// A uniform float between the two bounds, given in either order: 53 bits of one word,
    /// interpolated and clamped so that rounding cannot leave the interval. It always reads
    /// exactly one word. A bound that is not finite has no uniform interval and gives NaN.
    pub fn float(self: *Stream, first: f64, second: f64) f64 {
        const unit = @as(f64, @floatFromInt(self.next() >> 11)) * 0x1.0p-53;
        if (!std.math.isFinite(first) or !std.math.isFinite(second)) return std.math.nan(f64);
        // Written out, not `@min`: which of two zeros of different sign comes first is the
        // order of the arguments on every host.
        const low = if (second < first) second else first;
        const high = if (second < first) first else second;
        // Both products are within the bounds, so the sum cannot overflow as `high - low` can.
        const value = low * (1.0 - unit) + high * unit;
        return if (value < low) low else if (value > high) high else value;
    }
};

/// The count, size and a 64-bit hash of a sequence of actions, in order. Two machines, or a
/// machine and a replay, that commit the same actions in the same order agree on all three.
/// Like the call witness, the hash detects divergence and is no defence against a collision
/// someone looked for.
pub const Tally = struct {
    count: u64 = 0,
    bytes: u64 = 0,
    digest: u64 = 0x13198a2e03707344,

    const length_key: u64 = 0xa4093822299f31d0;
    const chunk_key: u64 = 0x082efa98ec4e6c89;

    fn mix(a: u64, b: u64) u64 {
        const product = @as(u128, a) * @as(u128, b);
        return @as(u64, @truncate(product)) ^ @as(u64, @truncate(product >> 64));
    }

    /// Appends one action. The length is folded first, so where one action ends and the next
    /// begins is part of the hash.
    pub fn add(self: *Tally, text: []const u8) void {
        var digest = mix(self.digest ^ text.len, length_key);
        var at: usize = 0;
        while (text.len - at >= 8) : (at += 8) digest = mix(digest ^ std.mem.readInt(u64, text[at..][0..8], .little), chunk_key);
        if (at != text.len) {
            var last: [8]u8 = @splat(0);
            @memcpy(last[0 .. text.len - at], text[at..]);
            digest = mix(digest ^ std.mem.readInt(u64, &last, .little), chunk_key);
        }
        self.digest = digest;
        self.count += 1;
        self.bytes += text.len;
    }

    /// Appends one action on `channel` (RFC-0086 H5). An action on channel 0, `Print`'s, is
    /// folded as `add` folds it, so the tally of every program without writers is unchanged;
    /// any other channel is folded before the action, so a line on one writer and the same line
    /// on another differ.
    pub fn addOn(self: *Tally, channel: u32, text: []const u8) void {
        if (channel != 0) self.digest = mix(self.digest ^ channel, channel_key);
        self.add(text);
    }
    const channel_key: u64 = 0x452821e638d01377;

    pub fn eql(self: Tally, other: Tally) bool {
        return self.count == other.count and self.bytes == other.bytes and self.digest == other.digest;
    }
};

/// A committed action as the host sees it. `sequence` counts the committed actions of the run
/// from zero: a run with the same program and seed commits the same actions under the same
/// numbers, which is what lets a durable sink make `commit` idempotent (RFC-0079 "Recovery").
/// `channel` is where it goes (RFC-0086 H5): 0 for `Print`'s standard output, a writer's grant
/// index plus one for that writer.
pub const Action = struct { sequence: u64, text: []const u8, channel: u32 = 0 };

/// The host's end of the contract. A run without a sink keeps or counts its actions and
/// shows them to no one. The text borrows the run's storage for the length of the call.
pub const Sink = struct {
    context: *anyopaque,
    /// Called at the call, in program order, before the action is buffered. The host makes
    /// sure a later `commit` of this text can succeed, and shows nothing. False ends the run
    /// with `effect_prepare_failed` at the call.
    prepare: *const fn (context: *anyopaque, text: []const u8) bool,
    /// Called once the action can no longer be undone, in program order. The action becomes
    /// visible. False ends the run with `effect_commit_failed`: the sink is then taken not to
    /// know whether this action is visible, and no later action is committed.
    /// For a durable sink (RFC-0086 J5) `commit` accepts the action in order and `seal` ends its
    /// commit point: the action becomes visible when its seal is durable, not at this call. A
    /// recovering run's sealed actions are compared, not merely skipped (R4).
    commit: *const fn (context: *anyopaque, action: Action) bool,
    /// Called for a prepared action that will never be committed, newest first: its region
    /// failed, or the run ended in a fatal error. The host releases what `prepare` took.
    abort: *const fn (context: *anyopaque, text: []const u8) void,
    /// RFC-0086, P2.4 (J3): called once after the actions of a commit point (one action outside
    /// every region, or every action an outermost region held), with the number of actions the
    /// run has committed so far. A commit point with no action has no seal. False ends the run
    /// with `effect_commit_failed` at the committing node. A sink without it is told nothing.
    seal: ?*const fn (context: *anyopaque, through: u64) bool = null,
};

pub const Error = error{ EffectLimit, EffectPrepareFailed, EffectCommitFailed };

/// What an effect native is given by whoever runs it: where its action goes and the stream
/// it draws from. A machine lends the ports of its `Log`; a report replay lends its own, so
/// that it learns what the native does without a device.
pub const Port = struct {
    context: *anyopaque,
    /// RFC-0086, P2.3: an action on a channel, 0 for `Print`'s.
    act: *const fn (context: *anyopaque, channel: u32, text: []const u8) Error!void,
    stream: *Stream,
    /// RFC-0086: the run's input log, lent to an `input` native, and the tick of the call.
    inputs: ?*Inputs = null,
    tick: u64 = 0,
    /// RFC-0086, P2.3: the run's grants, which say what a handle a native is given names.
    grants: []const Grant = &.{},
};

/// A committed action a `full` run kept: its bytes in `Record.bytes`, and its channel
/// (RFC-0086 H6), which tells the host where the action goes.
pub const Entry = struct { start: u32, end: u32, channel: u32 = 0 };

/// What a completed run says it did to the world and took from it. A report replay works
/// all of it out again from the run's steps and refuses a record that differs.
pub const Record = struct {
    seed: u64 = default_seed,
    /// Words the run read from its stream.
    draws: u64 = 0,
    /// Every action the run committed, in order.
    output: Tally = .{},
    /// Actions prepared in a region that then failed. They were never visible.
    discarded: u64 = 0,
    /// The committed actions themselves, kept by a `full` run for its report. A `digest` or
    /// `off` run hands them to its sink as it goes and keeps none.
    entries: []const Entry = &.{},
    bytes: []const u8 = "",
    /// RFC-0086: what the run took from the world, in the order it took it, kept in every trace
    /// mode and after a fatal error (I8): the second machine, the digest second run and the
    /// report replay read it instead of the world.
    inputs: []const InputEntry = &.{},
    input_bytes: []const u8 = "",
    /// RFC-0086, P2.3: the run's grants (H1, H7), a run parameter like the seed.
    grants: []const Grant = &.{},

    pub fn text(self: Record, index: usize) []const u8 {
        const entry = self.entries[index];
        return self.bytes[entry.start..entry.end];
    }

    pub fn inputRecord(self: Record) InputRecord {
        return .{ .entries = self.inputs, .bytes = self.input_bytes };
    }
};

/// What an input entry read (RFC-0086 I1). Kinds are appended as their forms arrive: `line`
/// is the readers' (P2.3), and RFC-0087 adds `load` (P5.5, S4): the entry of a persistent cell
/// for a key, whose `request` is `loadRequest(cell, grant)`.
pub const InputKind = enum(u8) { clock, line, load };

/// RFC-0087, P5.5 (S4): the request of a load, `cell * load_grants + grant`: which persistent cell
/// asks and for which key grant. `load_grants` is the same in every capacity profile, so a record
/// written under one profile names the same loads under another.
pub const load_grants: u32 = 1024;

comptime {
    assert(grant_capacity <= load_grants);
    assert(@as(u64, active.source_cells) * load_grants <= std.math.maxInt(u32));
}

pub fn loadRequest(cell: u32, grant: u32) u32 {
    assert(grant < load_grants);
    return cell * load_grants + grant;
}
/// A value, or the end of a stream, which is recorded like a value (I4).
pub const InputStatus = enum(u8) { value, end };

/// What a run asks the world for: the kind, what is asked (a reader's grant index, 0 for the
/// clock) and the tick of the call (0 at the root).
pub const Request = struct { kind: InputKind, request: u32 = 0, tick: u64 = 0 };

/// The world's answer: a reading's binary64 in `bits`, or a line's bytes, which the answer
/// lends for the length of the call.
pub const Answer = struct { status: InputStatus = .value, bits: u64 = 0, bytes: []const u8 = "" };

/// One entry of the input record (I1): its sequence is its index. A clock entry records the
/// world's raw reading, from which every reader works out the value again (I5); a line's
/// bytes lie in the record's bytes at `start .. end`.
pub const InputEntry = struct {
    tick: u64,
    bits: u64 = 0,
    start: u32 = 0,
    end: u32 = 0,
    request: u32 = 0,
    kind: InputKind,
    status: InputStatus = .value,
};

/// A run's input record, or the part of one a later run is given as its prefix (I3).
pub const InputRecord = struct {
    entries: []const InputEntry = &.{},
    bytes: []const u8 = "",
};

/// The host's end of the inputs (RFC-0086): it answers one request from the world. An error is
/// a device that could not answer, which ends the run (`input_failed`, I4).
pub const InputSource = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, request: Request) error{InputFailed}!Answer,
};

pub const InputError = error{ InputLimit, InputFailed, InputUnavailable, InputInvalid, InputDiverged };

/// RFC-0086, P2.4 (J2): where a journaled run writes each input it takes from the world, before
/// the guest sees it. `sequence` is the entry's index in the record; the bytes are a line's,
/// lent for the call. False is a device that failed: the run ends with `input_failed` at the
/// call, and the entry is not recorded, as for a source that cannot answer (I4).
pub const InputJournal = struct {
    context: *anyopaque,
    append: *const fn (context: *anyopaque, sequence: u32, entry: InputEntry, bytes: []const u8) bool,
    /// RFC-0086, P2.5 (R4): told each entry the prefix serves, after it was found to be the one
    /// asked for, so that a resumed journal knows how many inputs the run has taken at each of
    /// its commit points. A journal without it is told nothing.
    served: ?*const fn (context: *anyopaque, sequence: u32) void = null,
};

/// Whether a binary64, by its bits, is a number: neither NaN nor an infinity.
pub fn finiteBits(bits: u64) bool {
    return bits & 0x7ff0_0000_0000_0000 != 0x7ff0_0000_0000_0000;
}

/// I5: the value of a clock reading whose raw value is `raw`, after the reading whose value was
/// `previous`, if there was one. The clock holds its last value when the world's goes back
/// (api:141); `<` decides, so of `-0.0` and `0.0` the earlier one stays.
pub fn clockValue(previous: ?u64, raw: u64) u64 {
    const earlier = previous orelse return raw;
    const before: f64 = @bitCast(earlier);
    const now: f64 = @bitCast(raw);
    return if (before < now) raw else earlier;
}

/// A machine's input log (RFC-0086 I1 to I5). Each machine has its own, in its effect log. An
/// entry is asked of the `prefix` while it lasts, and of the `source` after it; it is never
/// rolled back, by a region or by a fatal error: what the world gave the run stays given.
pub const Inputs = struct {
    /// The host's choices for the runs that use this log; a run does not change them.
    source: ?InputSource = null,
    /// The record of an earlier run that this one must agree with. Borrowed.
    prefix: InputRecord = .{},
    /// RFC-0086, P2.3: what the host grants the run (H1), in order. Borrowed, fixed for the run,
    /// and given alike to every machine that must agree with it; a reset keeps it.
    grants: []const Grant = &.{},

    entries: [input_entry_capacity]InputEntry = undefined,
    bytes: [input_byte_capacity]u8 = undefined,
    count: u32 = 0,
    byte_count: u32 = 0,
    /// The latest clock reading, which belongs to the log and not to a region (I5).
    has_reading: bool = false,
    reading_tick: u64 = 0,
    reading_bits: u64 = 0,
    /// RFC-0086, P2.4: the journal of a journaled run, told every entry the world gives (J2). A
    /// host choice that a reset keeps, as the source; the entries of the prefix are not its.
    journal: ?InputJournal = null,

    /// Before a run: nothing recorded, no reading. The prefix and the source stay.
    pub fn reset(self: *Inputs) void {
        self.count = 0;
        self.byte_count = 0;
        self.has_reading = false;
        self.reading_tick = 0;
        self.reading_bits = 0;
    }

    /// The tool's rerun after a limit (I3): the next run of this log is given this run's record
    /// as its prefix, so it asks the world only for what this run never read. The prefix lies
    /// in this log's own storage, where the next run writes the same entries again in place.
    pub fn again(self: *Inputs) void {
        self.prefix = self.record();
    }

    /// What the run has recorded. It borrows the log until the next run.
    pub fn record(self: *const Inputs) InputRecord {
        return .{ .entries = self.entries[0..self.count], .bytes = self.bytes[0..self.byte_count] };
    }

    pub fn value(self: *const Inputs, index: u32) []const u8 {
        assert(index < self.count);
        const entry = self.entries[index];
        return self.bytes[entry.start..entry.end];
    }

    /// One input of the run. The clock is read once per tick (I5): a read at the tick of the
    /// latest reading gives its value again and records nothing.
    pub fn read(self: *Inputs, request: Request) InputError!Answer {
        assert(self.count <= input_entry_capacity and self.byte_count <= input_byte_capacity);
        switch (request.kind) {
            .clock => {
                assert(request.request == 0);
                if (self.has_reading and self.reading_tick == request.tick) return .{ .bits = self.reading_bits };
                // Ticks only grow (RFC-0082), so a later read is never at an earlier tick.
                assert(!self.has_reading or self.reading_tick < request.tick);
                const entry = try self.take(request);
                if (entry.status != .value or entry.start != entry.end or !finiteBits(entry.bits)) return error.InputInvalid;
                const bits = clockValue(if (self.has_reading) self.reading_bits else null, entry.bits);
                self.has_reading = true;
                self.reading_tick = request.tick;
                self.reading_bits = bits;
                return .{ .bits = bits };
            },
            .line => {
                const entry = try self.take(request);
                const line = self.bytes[entry.start..entry.end];
                if (entry.status == .end) return if (line.len == 0 and entry.bits == 0) .{ .status = .end } else error.InputInvalid;
                // A line is text without its newline (I6).
                if (entry.bits != 0 or std.mem.indexOfScalar(u8, line, '\n') != null or !std.unicode.utf8ValidateSlice(line)) return error.InputInvalid;
                return .{ .bytes = line };
            },
            // RFC-0087, P5.5 (S4): the text of an entry, or `end` for an entry the store lacks. It
            // is read like any input, once, and never undone; whether it is JSON that decodes is
            // the machine's to say (`load_invalid`), not the log's.
            .load => {
                const entry = try self.take(request);
                const text = self.bytes[entry.start..entry.end];
                if (entry.bits != 0 or request.tick != 0 or (entry.status == .end and text.len != 0)) return error.InputInvalid;
                return .{ .status = entry.status, .bytes = text };
            },
        }
    }

    /// Records the next entry: the prefix's while it lasts, which must be what is asked now,
    /// and the world's after it. A recorded answer that is not valid for its kind is recorded
    /// still, and the read refuses it: the record is the run's whatever the run did (I8).
    fn take(self: *Inputs, request: Request) InputError!InputEntry {
        if (self.count == input_entry_capacity) return error.InputLimit;
        const answer: Answer = if (self.count < self.prefix.entries.len) prefixed: {
            const recorded = self.prefix.entries[self.count];
            if (recorded.kind != request.kind or recorded.request != request.request or recorded.tick != request.tick) return error.InputDiverged;
            // A prefix can come from a report under review: where its bytes lie is checked too.
            if (recorded.start > recorded.end or recorded.end > self.prefix.bytes.len) return error.InputDiverged;
            break :prefixed .{ .status = recorded.status, .bits = recorded.bits, .bytes = self.prefix.bytes[recorded.start..recorded.end] };
        } else world: {
            const source = self.source orelse return error.InputUnavailable;
            break :world source.read(source.context, request) catch return error.InputFailed;
        };
        if (answer.bytes.len > input_byte_capacity - self.byte_count) return error.InputLimit;
        const start = self.byte_count;
        const end = start + @as(u32, @intCast(answer.bytes.len));
        const entry: InputEntry = .{ .tick = request.tick, .bits = answer.bits, .start = start, .end = end, .request = request.request, .kind = request.kind, .status = answer.status };
        // Write-ahead (J2): what the world gave is in the journal before the guest sees it. The
        // prefix came from a record, and is not the world's to journal again.
        if (self.journal) |journal| {
            if (self.count >= self.prefix.entries.len) {
                if (!journal.append(journal.context, self.count, entry, answer.bytes)) return error.InputFailed;
            } else if (journal.served) |served| served(journal.context, self.count);
        }
        // A prefix of this log's own record (`again`) is written again where it lies: the copy
        // may be of bytes onto themselves, never onto bytes after them.
        std.mem.copyForwards(u8, self.bytes[start..][0..answer.bytes.len], answer.bytes);
        self.byte_count = end;
        self.entries[self.count] = entry;
        self.count += 1;
        return entry;
    }
};

const Mark = struct { depth: u32, entries: u32, bytes: u32 };

pub const Log = struct {
    /// The host's choices for the runs that use this log; a run does not change them.
    seed: u64 = default_seed,
    sink: ?Sink = null,

    stream: Stream = .{},
    /// The committed actions a `full` run keeps, then the pending ones.
    entries: [entry_capacity]Entry = undefined,
    /// One per open region that has prepared an action of its own, outermost first.
    marks: [entry_capacity]Mark = undefined,
    bytes: [byte_capacity]u8 = undefined,
    count: u32 = 0,
    /// How many of the entries are committed.
    kept: u32 = 0,
    byte_count: u32 = 0,
    mark_count: u32 = 0,
    /// Rollback regions open now. An action prepared at depth 0 can never be undone.
    depth: u32 = 0,
    /// Whether committed actions stay in the log for the report (`full`), or leave it.
    retain: bool = true,
    committed: Tally = .{},
    discarded: u64 = 0,
    /// What the run takes from the world that no seed gives (RFC-0086): never rolled back.
    inputs: Inputs = .{},

    /// Constant-time checks of what this log itself maintains.
    fn check(self: *const Log) void {
        assert(self.kept <= self.count and self.count <= entry_capacity and self.byte_count <= byte_capacity);
        // A mark owns at least one pending action, and marks nest strictly.
        assert(self.mark_count <= self.count - self.kept);
        if (self.mark_count != 0) {
            const top = self.marks[self.mark_count - 1];
            assert(top.depth != 0 and top.depth <= self.depth and top.entries >= self.kept and top.entries < self.count);
        }
        // Outside every region nothing waits: an action is committed as it is prepared.
        if (self.depth == 0) assert(self.count == self.kept and self.mark_count == 0);
        if (!self.retain) assert(self.kept == 0);
    }

    /// Before a run: nothing prepared, the stream at its start. `retain` is whether the run
    /// stores its witness, and so has a report that lists its output.
    pub fn reset(self: *Log, retain: bool) void {
        self.stream = .{ .seed = self.seed };
        self.count = 0;
        self.kept = 0;
        self.byte_count = 0;
        self.mark_count = 0;
        self.depth = 0;
        self.retain = retain;
        self.committed = .{};
        self.discarded = 0;
        self.inputs.reset();
    }

    /// A rollback region opens.
    pub fn begin(self: *Log) void {
        self.check();
        self.depth += 1;
    }

    pub fn text(self: *const Log, index: u32) []const u8 {
        assert(index < self.count);
        const entry = self.entries[index];
        return self.bytes[entry.start..entry.end];
    }

    /// An effect native describes its action. Nothing is visible yet unless no region is open.
    pub fn prepare(self: *Log, action: []const u8) Error!void {
        return self.prepareOn(0, action);
    }

    /// `prepare` of an action on `channel` (RFC-0086 H5): every channel shares the log's one
    /// sequence and commit order, and the channel is kept with the action.
    pub fn prepareOn(self: *Log, channel: u32, action: []const u8) Error!void {
        self.check();
        defer self.check();
        if (self.depth == 0 and !self.retain) {
            // Nothing can undo it and no report lists it: it needs no room in the log.
            if (self.sink) |sink| if (!sink.prepare(sink.context, action)) return error.EffectPrepareFailed;
            try self.publish(channel, action);
            // A commit point of one action (RFC-0086 J3).
            return self.seal();
        }
        if (self.count == entry_capacity or action.len > byte_capacity - self.byte_count) return error.EffectLimit;
        if (self.sink) |sink| if (!sink.prepare(sink.context, action)) return error.EffectPrepareFailed;
        if (self.depth != 0 and (self.mark_count == 0 or self.marks[self.mark_count - 1].depth != self.depth)) {
            self.marks[self.mark_count] = .{ .depth = self.depth, .entries = self.count, .bytes = self.byte_count };
            self.mark_count += 1;
        }
        @memcpy(self.bytes[self.byte_count..][0..action.len], action);
        self.entries[self.count] = .{ .start = self.byte_count, .end = self.byte_count + @as(u32, @intCast(action.len)), .channel = channel };
        self.byte_count += @intCast(action.len);
        self.count += 1;
        if (self.depth == 0) try self.flush();
    }

    /// The innermost region commits: its actions now belong to the region around it, and are
    /// committed to the world when there is none.
    pub fn commit(self: *Log) Error!void {
        self.check();
        defer self.check();
        assert(self.depth != 0);
        const closing = self.depth;
        self.depth -= 1;
        if (self.mark_count != 0 and self.marks[self.mark_count - 1].depth == closing) {
            // The parent's own mark, when it has one, already lies below these actions.
            if (self.depth == 0 or (self.mark_count > 1 and self.marks[self.mark_count - 2].depth == self.depth)) {
                self.mark_count -= 1;
            } else self.marks[self.mark_count - 1].depth = self.depth;
        }
        if (self.depth == 0) try self.flush();
    }

    /// The innermost region fails: what it prepared, and what regions inside it handed up to
    /// it, never happened.
    pub fn abort(self: *Log) void {
        self.check();
        defer self.check();
        assert(self.depth != 0);
        const closing = self.depth;
        self.depth -= 1;
        if (self.mark_count == 0 or self.marks[self.mark_count - 1].depth != closing) return;
        const mark = self.marks[self.mark_count - 1];
        self.mark_count -= 1;
        self.discarded += self.count - mark.entries;
        self.drop(mark.entries, mark.bytes);
    }

    /// The run ends in a fatal error: what is pending is dropped, what was committed stays.
    pub fn abortAll(self: *Log) void {
        self.drop(self.kept, if (self.kept == 0) 0 else self.entries[self.kept - 1].end);
        self.mark_count = 0;
        self.depth = 0;
        self.check();
    }

    /// Forgets the entries from `first` on, newest first, telling the sink of each.
    fn drop(self: *Log, first: u32, bytes: u32) void {
        assert(first >= self.kept and first <= self.count and bytes <= self.byte_count);
        if (self.sink) |sink| {
            var index = self.count;
            while (index > first) {
                index -= 1;
                sink.abort(sink.context, self.text(index));
            }
        }
        self.count = first;
        self.byte_count = bytes;
    }

    /// Commits the pending actions, oldest first. Only with no region open.
    fn flush(self: *Log) Error!void {
        assert(self.depth == 0 and self.mark_count == 0);
        // A commit point that commits nothing has no seal (RFC-0086 J3).
        const committing = self.count > self.kept;
        var index = self.kept;
        while (index < self.count) : (index += 1) {
            self.publish(self.entries[index].channel, self.text(index)) catch |err| {
                // The sink has this one. The ones after it are told they will not follow, and
                // the ones before it are committed and stay.
                self.drop(index + 1, self.entries[index].end);
                self.count = if (self.retain) index else 0;
                self.byte_count = if (self.retain) self.entries[index].start else 0;
                return err;
            };
            if (self.retain) self.kept = index + 1;
        }
        if (!self.retain) {
            self.count = 0;
            self.byte_count = 0;
        }
        if (committing) try self.seal();
    }

    fn publish(self: *Log, channel: u32, action: []const u8) Error!void {
        if (self.sink) |sink| if (!sink.commit(sink.context, .{ .sequence = self.committed.count, .text = action, .channel = channel })) return error.EffectCommitFailed;
        self.committed.addOn(channel, action);
    }

    /// RFC-0086, P2.4 (J3): the end of a commit point, after its last action, told to a sink
    /// that seals: the actions of one outermost region become durable together or not at all.
    fn seal(self: *Log) Error!void {
        const sink = self.sink orelse return;
        const sealing = sink.seal orelse return;
        if (!sealing(sink.context, self.committed.count)) return error.EffectCommitFailed;
    }

    fn act(context: *anyopaque, channel: u32, action: []const u8) Error!void {
        const self: *Log = @ptrCast(@alignCast(context));
        return self.prepareOn(channel, action);
    }

    /// What this log lends an effect native called at `tick` of the run's virtual clock.
    pub fn port(self: *Log, tick: u64) Port {
        return .{ .context = self, .act = act, .stream = &self.stream, .inputs = &self.inputs, .tick = tick, .grants = self.inputs.grants };
    }

    /// What a completed run reports. It borrows the log until the next run.
    pub fn record(self: *const Log) Record {
        assert(self.depth == 0 and self.count == self.kept);
        return .{ .seed = self.stream.seed, .draws = self.stream.position, .output = self.committed, .discarded = self.discarded, .entries = self.entries[0..self.kept], .bytes = self.bytes[0..self.byte_count], .inputs = self.inputs.entries[0..self.inputs.count], .input_bytes = self.inputs.bytes[0..self.inputs.byte_count], .grants = self.inputs.grants };
    }
};

const scratch = @import("scratch.zig");

/// A sink for tests: it writes down every call, and refuses the prepare or the commit whose
/// number it was told to refuse.
pub const Recorder = struct {
    pub const Call = struct { kind: enum { prepare, commit, abort }, sequence: u64 = 0, start: u32, end: u32, channel: u32 = 0 };
    calls: [4096]Call = undefined,
    call_count: u32 = 0,
    bytes: [64 * 1024]u8 = undefined,
    byte_count: u32 = 0,
    prepares: u64 = 0,
    commits: u64 = 0,
    /// The prepare, or the commit, counted from zero, that fails. Null: none does.
    fail_prepare: ?u64 = null,
    fail_commit: ?u64 = null,
    /// Calls that found no room to be written down; a test that sees any proves nothing.
    lost: u64 = 0,
    /// RFC-0086, P2.4: the `through` of each seal, in order, kept apart from the calls; the seal,
    /// counted from zero, that fails. Null: none does.
    seals: [1024]u64 = undefined,
    seal_count: u32 = 0,
    seal_calls: u64 = 0,
    fail_seal: ?u64 = null,

    pub fn clear(self: *Recorder) void {
        self.call_count = 0;
        self.byte_count = 0;
        self.prepares = 0;
        self.commits = 0;
        self.lost = 0;
        self.seal_count = 0;
        self.seal_calls = 0;
    }
    fn note(self: *Recorder, kind: @FieldType(Call, "kind"), sequence: u64, action: []const u8) void {
        self.noteOn(kind, sequence, 0, action);
    }
    fn noteOn(self: *Recorder, kind: @FieldType(Call, "kind"), sequence: u64, channel: u32, action: []const u8) void {
        if (self.call_count == self.calls.len or action.len > self.bytes.len - self.byte_count) {
            self.lost += 1;
            return;
        }
        @memcpy(self.bytes[self.byte_count..][0..action.len], action);
        self.calls[self.call_count] = .{ .kind = kind, .sequence = sequence, .start = self.byte_count, .end = self.byte_count + @as(u32, @intCast(action.len)), .channel = channel };
        self.byte_count += @intCast(action.len);
        self.call_count += 1;
    }
    fn prepare(context: *anyopaque, action: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const number = self.prepares;
        self.prepares += 1;
        if (self.fail_prepare == number) return false;
        self.note(.prepare, 0, action);
        return true;
    }
    fn commit(context: *anyopaque, action: Action) bool {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const number = self.commits;
        self.commits += 1;
        if (self.fail_commit == number) return false;
        self.noteOn(.commit, action.sequence, action.channel, action.text);
        return true;
    }
    fn abort(context: *anyopaque, action: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.note(.abort, 0, action);
    }
    fn seal(context: *anyopaque, through: u64) bool {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const number = self.seal_calls;
        self.seal_calls += 1;
        if (self.fail_seal == number) return false;
        if (self.seal_count == self.seals.len) {
            self.lost += 1;
            return true;
        }
        self.seals[self.seal_count] = through;
        self.seal_count += 1;
        return true;
    }
    pub fn sink(self: *Recorder) Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort, .seal = seal };
    }
    /// The seals heard, in order.
    pub fn sealed(self: *const Recorder) []const u64 {
        return self.seals[0..self.seal_count];
    }
    pub fn text(self: *const Recorder, call: Call) []const u8 {
        return self.bytes[call.start..call.end];
    }
    /// The committed actions, one per line: what a device would show.
    pub fn visible(self: *const Recorder, out: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(out);
        for (self.calls[0..self.call_count]) |call| if (call.kind == .commit) {
            writer.writeAll(self.text(call)) catch unreachable;
            writer.writeByte('\n') catch unreachable;
        };
        return writer.buffered();
    }
};

/// A source for tests (RFC-0086): it answers from a script, writes down every request, and
/// fails the read whose number it was told to fail, as `Recorder` does for sinks.
/// RFC-0087, P5.5: one entry of a scripted store.
pub const Stored = struct { request: u32, text: []const u8 };

pub const Script = struct {
    /// The raw readings of the clock, in the order they are asked for. After them the clock
    /// reads `base + tick / rate` seconds, as `forbic eval --clock` does.
    clocks: []const f64 = &.{},
    base: f64 = 1_700_000_000.0,
    rate: u64 = 60,
    /// The lines of each stream, by request; after its lines a stream is at its end.
    streams: []const []const []const u8 = &.{},
    /// RFC-0087, P5.5: the store the loads of persistent cells ask: the text of each entry by
    /// request (`loadRequest`); a request not listed is at its end.
    store: []const Stored = &.{},
    clock_reads: usize = 0,
    cursors: [16]usize = @splat(0),
    reads: u64 = 0,
    /// The read, counted from zero, that fails as a device would. Null: none does.
    fail_read: ?u64 = null,
    asked: [256]Request = undefined,
    asked_count: u32 = 0,
    /// Requests that found no room to be written down; a test that sees any proves nothing.
    lost: u64 = 0,

    /// Back to the start of every stream and of the clock's list, for another run.
    pub fn rewind(self: *Script) void {
        self.clock_reads = 0;
        self.cursors = @splat(0);
        self.reads = 0;
        self.asked_count = 0;
        self.lost = 0;
    }
    pub fn source(self: *Script) InputSource {
        return .{ .context = self, .read = read };
    }
    /// The world's clock at `tick` past the scripted readings.
    pub fn paced(self: *const Script, tick: u64) f64 {
        @setFloatMode(.strict);
        return self.base + @as(f64, @floatFromInt(tick)) / @as(f64, @floatFromInt(self.rate));
    }
    fn read(context: *anyopaque, request: Request) error{InputFailed}!Answer {
        const self: *Script = @ptrCast(@alignCast(context));
        const number = self.reads;
        self.reads += 1;
        if (self.asked_count == self.asked.len) self.lost += 1 else {
            self.asked[self.asked_count] = request;
            self.asked_count += 1;
        }
        if (self.fail_read == number) return error.InputFailed;
        switch (request.kind) {
            .clock => {
                const raw = if (self.clock_reads < self.clocks.len) self.clocks[self.clock_reads] else self.paced(request.tick);
                self.clock_reads += 1;
                return .{ .bits = @bitCast(raw) };
            },
            .line => {
                if (request.request >= self.streams.len or request.request >= self.cursors.len) return .{ .status = .end };
                const lines = self.streams[request.request];
                const cursor = &self.cursors[request.request];
                if (cursor.* >= lines.len) return .{ .status = .end };
                cursor.* += 1;
                return .{ .bytes = lines[cursor.* - 1] };
            },
            // RFC-0087, P5.5: the entries of the scripted store, or the end.
            .load => {
                for (self.store) |held| if (held.request == request.request) return .{ .bytes = held.text };
                return .{ .status = .end };
            },
        }
    }
};

test "the stream is a function of seed and position, and bounded draws stay in range" {
    // The first words of the default stream, fixed here so that a change of generator is seen.
    try std.testing.expectEqual(@as(u64, 0x0e73b0fb38726e1a), Stream.word(default_seed, 0));
    // The published SplitMix64 sequence from a state of zero.
    try std.testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), Stream.word(0, 0));
    try std.testing.expectEqual(@as(u64, 0x6e789e6aa1b965f4), Stream.word(0, 1));
    var a: Stream = .{};
    var b: Stream = .{};
    for (0..64) |index| {
        const value = a.next();
        try std.testing.expectEqual(value, Stream.word(default_seed, index));
        try std.testing.expectEqual(value, b.next());
    }
    var other: Stream = .{ .seed = default_seed + 1 };
    try std.testing.expect(other.next() != Stream.word(default_seed, 0));
    // Every bound, including the ones that reject nearly half of the words.
    var stream: Stream = .{ .seed = 7 };
    for ([_]u64{ 1, 2, 3, 5, 6, 7, 10, 255, 256, 257, 1 << 32, (1 << 63) - 1, 1 << 63, (1 << 63) + 1, std.math.maxInt(u64) }) |bound| {
        for (0..200) |_| try std.testing.expect(stream.below(bound).? < bound);
    }
    try std.testing.expectEqual(@as(u64, 0), stream.below(1).?);
    // Bounds in either order, the whole of i64, and a single value.
    for (0..2000) |_| {
        const value = stream.integer(3, -3).?;
        try std.testing.expect(value >= -3 and value <= 3);
    }
    try std.testing.expectEqual(@as(i64, 9), stream.integer(9, 9).?);
    try std.testing.expectEqual(std.math.minInt(i64), stream.integer(std.math.minInt(i64), std.math.minInt(i64)).?);
    const before = stream.position;
    _ = stream.integer(std.math.minInt(i64), std.math.maxInt(i64)).?;
    try std.testing.expectEqual(before + 1, stream.position);
    var low = false;
    var high = false;
    for (0..4000) |_| {
        const value = stream.integer(std.math.maxInt(i64) - 1, std.math.maxInt(i64)).?;
        low = low or value == std.math.maxInt(i64) - 1;
        high = high or value == std.math.maxInt(i64);
        try std.testing.expect(value >= std.math.maxInt(i64) - 1);
    }
    try std.testing.expect(low and high);
}

test "a bounded draw is unbiased over a range that does not divide the words" {
    // Three values: without rejection the first would come up one time more in 2^64, which no
    // test can see, so the test is of the rule itself on a small word. With 8-bit words and a
    // bound of 3, 256 mod 3 = 1 word is rejected and each value has 85 of the others.
    var counts = [_]u32{ 0, 0, 0 };
    const rejected: u32 = (256 - 3) % 3;
    for (0..256) |value| {
        if (value >= rejected) counts[value % 3] += 1;
    }
    try std.testing.expectEqualSlices(u32, &.{ 85, 85, 85 }, &counts);
    // And the 64-bit draw over six values is even to within sampling error.
    var stream: Stream = .{ .seed = 99 };
    var seen: [6]u32 = @splat(0);
    for (0..60000) |_| seen[@intCast(stream.integer(1, 6).? - 1)] += 1;
    for (seen) |count| try std.testing.expect(count > 9500 and count < 10500);
}

test "a float draw reads one word, stays in its interval and refuses bounds that are not finite" {
    var stream: Stream = .{ .seed = 3 };
    const cases = [_][2]f64{ .{ 0, 1 }, .{ 1, 0 }, .{ -1e308, 1e308 }, .{ 5, 5 }, .{ -0.0, 0.0 }, .{ 1e-320, 2e-320 }, .{ std.math.floatMax(f64), std.math.floatMax(f64) }, .{ -std.math.floatMax(f64), std.math.floatMax(f64) } };
    for (cases) |bounds| for (0..500) |_| {
        const before = stream.position;
        const value = stream.float(bounds[0], bounds[1]);
        try std.testing.expectEqual(before + 1, stream.position);
        try std.testing.expect(value >= @min(bounds[0], bounds[1]) and value <= @max(bounds[0], bounds[1]));
    };
    for ([_][2]f64{ .{ std.math.nan(f64), 1 }, .{ 0, std.math.inf(f64) }, .{ -std.math.inf(f64), 0 }, .{ std.math.inf(f64), std.math.inf(f64) } }) |bounds| {
        const before = stream.position;
        try std.testing.expect(std.math.isNan(stream.float(bounds[0], bounds[1])));
        try std.testing.expectEqual(before + 1, stream.position);
    }
    // The unit is 53 bits of the word: the largest is just below one.
    try std.testing.expect(@as(f64, @floatFromInt(@as(u64, std.math.maxInt(u64)) >> 11)) * 0x1.0p-53 < 1.0);
}

test "a tally tells apart counts, lengths, order and every byte" {
    const of = struct {
        fn call(parts: []const []const u8) Tally {
            var tally: Tally = .{};
            for (parts) |part| tally.add(part);
            return tally;
        }
    }.call;
    const base = of(&.{ "alpha", "be", "" });
    try std.testing.expect(base.eql(of(&.{ "alpha", "be", "" })));
    try std.testing.expectEqual(@as(u64, 3), base.count);
    try std.testing.expectEqual(@as(u64, 7), base.bytes);
    // Where one action ends and the next begins is part of it; so are order and empty ones.
    for ([_][]const []const u8{ &.{ "alphab", "e", "" }, &.{ "alphabe", "", "" }, &.{ "be", "alpha", "" }, &.{ "alpha", "be" }, &.{ "alpha", "", "be" }, &.{ "alpha", "bf", "" }, &.{ "alpha", "be", "\x00" } }) |other| {
        try std.testing.expect(base.digest != of(other).digest);
    }
    // Every byte of a text longer than a chunk reaches the hash, and so does a trailing zero.
    var text: [29]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = @intCast(index + 1);
    const whole = of(&.{&text});
    for (0..text.len) |index| {
        text[index] ^= 0x40;
        try std.testing.expect(whole.digest != of(&.{&text}).digest);
        text[index] ^= 0x40;
    }
    try std.testing.expect(of(&.{"abc"}).digest != of(&.{"abc\x00"}).digest);
}

fn testLog() !*Log {
    const log = try scratch.storage(Log);
    scratch.initialise(log);
    return log;
}

test "an action is visible when its outermost region commits, in program order, and never when it fails" {
    const log = try testLog();
    defer scratch.release(log);
    var recorder: Recorder = .{};
    log.sink = recorder.sink();
    var shown: [256]u8 = undefined;
    for ([_]bool{ true, false }) |retain| {
        log.reset(retain);
        recorder.clear();
        try log.prepare("a");
        try std.testing.expectEqualStrings("a\n", recorder.visible(&shown));
        log.begin();
        try log.prepare("b");
        log.begin();
        try log.prepare("c");
        // Nothing of an open region is visible, however deep.
        try std.testing.expectEqualStrings("a\n", recorder.visible(&shown));
        try log.commit();
        try std.testing.expectEqualStrings("a\n", recorder.visible(&shown));
        log.begin();
        try log.prepare("d");
        log.abort();
        try log.prepare("e");
        try log.commit();
        try std.testing.expectEqualStrings("a\nb\nc\ne\n", recorder.visible(&shown));
        // An inner commit followed by an outer failure discards the inner region's actions too.
        log.begin();
        log.begin();
        try log.prepare("f");
        try log.commit();
        log.begin();
        log.begin();
        try log.prepare("g");
        try log.commit();
        try log.commit();
        log.abort();
        try log.prepare("h");
        try std.testing.expectEqualStrings("a\nb\nc\ne\nh\n", recorder.visible(&shown));
        try std.testing.expectEqual(@as(u64, 5), log.committed.count);
        try std.testing.expectEqual(@as(u64, 3), log.discarded);
        try std.testing.expectEqual(@as(u32, 0), log.depth);
        const record = log.record();
        try std.testing.expectEqual(@as(usize, if (retain) 5 else 0), record.entries.len);
        if (retain) {
            var listed: Tally = .{};
            for (0..record.entries.len) |index| listed.add(record.text(index));
            try std.testing.expect(listed.eql(record.output));
            try std.testing.expectEqualStrings("abceh", record.bytes);
        }
        // The sink heard every prepare, the aborts newest first, and commits numbered in order.
        var sequence: u64 = 0;
        var aborted: [8]u8 = undefined;
        var aborted_count: usize = 0;
        for (recorder.calls[0..recorder.call_count]) |call| switch (call.kind) {
            .commit => {
                try std.testing.expectEqual(sequence, call.sequence);
                sequence += 1;
            },
            .abort => {
                aborted[aborted_count] = recorder.text(call)[0];
                aborted_count += 1;
            },
            .prepare => {},
        };
        try std.testing.expectEqualStrings("dgf", aborted[0..aborted_count]);
        try std.testing.expectEqual(@as(u64, 8), recorder.prepares);
        try std.testing.expectEqual(@as(u64, 0), recorder.lost);
    }
}

test "the log is bounded: entries and bytes fill exactly, and a run that keeps nothing never fills" {
    const log = try testLog();
    defer scratch.release(log);
    // A full run keeps what it commits, so its report can list it.
    log.reset(true);
    for (0..entry_capacity) |_| try log.prepare("");
    try std.testing.expectError(error.EffectLimit, log.prepare(""));
    try std.testing.expectEqual(@as(u64, entry_capacity), log.committed.count);
    log.reset(true);
    const chunk: [128]u8 = @splat('x');
    comptime assert(byte_capacity % chunk.len == 0 and byte_capacity / chunk.len < entry_capacity);
    for (0..byte_capacity / chunk.len) |_| try log.prepare(&chunk);
    try std.testing.expectError(error.EffectLimit, log.prepare("y"));
    try log.prepare("");
    // A run that keeps nothing commits outside regions without using the log at all.
    log.reset(false);
    for (0..3 * entry_capacity) |_| try log.prepare(&chunk);
    try std.testing.expectEqual(@as(u64, 3 * entry_capacity), log.committed.count);
    try std.testing.expectEqual(@as(u32, 0), log.count);
    // Inside a region it must hold them until the region ends, and that is bounded.
    log.begin();
    for (0..entry_capacity) |_| try log.prepare("");
    try std.testing.expectError(error.EffectLimit, log.prepare(""));
    // A region that commits into the world gives the room back; so does one that fails.
    try log.commit();
    try std.testing.expectEqual(@as(u32, 0), log.count);
    log.begin();
    for (0..entry_capacity) |_| try log.prepare("");
    log.abort();
    try std.testing.expectEqual(@as(u32, 0), log.count);
    try std.testing.expectEqual(@as(u64, entry_capacity), log.discarded);
    // As deep as regions go, a mark is kept only where an action was prepared.
    for (0..100_000) |_| log.begin();
    try log.prepare("deep");
    try std.testing.expectEqual(@as(u32, 1), log.mark_count);
    for (0..100_000) |_| try log.commit();
    try std.testing.expectEqual(@as(u64, 4 * entry_capacity + 1), log.committed.count);
}

test "a sink that fails: a refused prepare shows nothing, a failed commit keeps what came before" {
    const log = try testLog();
    defer scratch.release(log);
    var recorder: Recorder = .{};
    log.sink = recorder.sink();
    var shown: [256]u8 = undefined;
    for ([_]bool{ true, false }) |retain| {
        // Every prepare in turn is refused, inside a region and outside.
        for (0..4) |refused| {
            log.reset(retain);
            recorder.clear();
            recorder.fail_prepare = refused;
            recorder.fail_commit = null;
            const outcome = sequence: {
                log.prepare("a") catch |err| break :sequence err;
                log.begin();
                log.prepare("b") catch |err| break :sequence err;
                log.prepare("c") catch |err| break :sequence err;
                log.commit() catch |err| break :sequence err;
                log.prepare("d") catch |err| break :sequence err;
                break :sequence error.EffectLimit;
            };
            try std.testing.expectEqual(error.EffectPrepareFailed, outcome);
            log.abortAll();
            const expected = [_][]const u8{ "", "a\n", "a\n", "a\nb\nc\n" };
            try std.testing.expectEqualStrings(expected[refused], recorder.visible(&shown));
            try std.testing.expectEqual(@as(u32, 0), log.depth);
            try std.testing.expectEqual(@as(u32, log.kept), log.count);
            // What was prepared and never committed was aborted, and nothing else was.
            var prepared: u32 = 0;
            var settled: u32 = 0;
            for (recorder.calls[0..recorder.call_count]) |call| {
                if (call.kind == .prepare) prepared += 1 else settled += 1;
            }
            try std.testing.expectEqual(prepared, settled);
        }
        // Every commit in turn fails.
        for (0..4) |failing| {
            log.reset(retain);
            recorder.clear();
            recorder.fail_prepare = null;
            recorder.fail_commit = failing;
            const outcome = sequence: {
                log.prepare("a") catch |err| break :sequence err;
                log.begin();
                log.prepare("b") catch |err| break :sequence err;
                log.prepare("c") catch |err| break :sequence err;
                log.commit() catch |err| break :sequence err;
                log.prepare("d") catch |err| break :sequence err;
                break :sequence error.EffectLimit;
            };
            try std.testing.expectEqual(error.EffectCommitFailed, outcome);
            log.abortAll();
            const expected = [_][]const u8{ "", "a\n", "a\nb\n", "a\nb\nc\n" };
            try std.testing.expectEqualStrings(expected[failing], recorder.visible(&shown));
            try std.testing.expectEqual(@as(u64, failing), log.committed.count);
            try std.testing.expectEqual(@as(u32, if (retain) @intCast(failing) else 0), log.kept);
            try std.testing.expectEqual(log.kept, log.count);
            // The action after the one that failed was told it would not follow.
            if (failing == 1) {
                const last = recorder.calls[recorder.call_count - 1];
                try std.testing.expect(last.kind == .abort);
                try std.testing.expectEqualStrings("c", recorder.text(last));
            }
        }
    }
}

/// The semantics with nothing shared: one list of texts per open region. A region that
/// commits appends its list to its parent's, the root's list is the world, and a region that
/// fails throws its list away.
const Model = struct {
    const Text = struct { bytes: [6]u8, len: u8 };
    lists: [12]std.ArrayList(Text) = @splat(.empty),
    depth: usize = 0,
    discarded: u64 = 0,

    fn destroy(self: *Model, allocator: std.mem.Allocator) void {
        for (&self.lists) |*list| list.deinit(allocator);
    }
    fn begin(self: *Model) void {
        self.depth += 1;
        self.lists[self.depth].clearRetainingCapacity();
    }
    fn prepare(self: *Model, allocator: std.mem.Allocator, action: []const u8) !void {
        var text: Text = .{ .bytes = undefined, .len = @intCast(action.len) };
        @memcpy(text.bytes[0..action.len], action);
        try self.lists[self.depth].append(allocator, text);
    }
    fn commit(self: *Model, allocator: std.mem.Allocator) !void {
        try self.lists[self.depth - 1].appendSlice(allocator, self.lists[self.depth].items);
        self.depth -= 1;
    }
    fn abort(self: *Model) void {
        self.discarded += self.lists[self.depth].items.len;
        self.depth -= 1;
    }
    fn pending(self: *const Model) usize {
        var total: usize = 0;
        for (self.lists[1 .. self.depth + 1]) |list| total += list.items.len;
        return total;
    }
};

test "sixty thousand random region actions agree with a list per region, kept or not" {
    const allocator = std.testing.allocator;
    const log = try testLog();
    defer scratch.release(log);
    for ([_]bool{ true, false }, [_]u64{ 0x79e1, 0x79e2 }) |retain, seed| {
        var model: Model = .{};
        defer model.destroy(allocator);
        var random = std.Random.DefaultPrng.init(seed);
        const r = random.random();
        var world: Tally = .{};
        var seen: usize = 0;
        var deepest: usize = 0;
        var most_marks: u32 = 0;
        var aborted_actions: u64 = 0;
        log.sink = null;
        log.reset(retain);
        for (0..30_000) |step| {
            const choice = r.uintLessThan(u8, 16);
            if (choice < 5 and model.depth + 1 < model.lists.len) {
                log.begin();
                model.begin();
            } else if (choice < 8 and model.depth != 0) {
                try log.commit();
                try model.commit(allocator);
            } else if (choice < 10 and model.depth != 0) {
                aborted_actions += model.lists[model.depth].items.len;
                log.abort();
                model.abort();
            } else if (model.pending() + 1 < entry_capacity and (!retain or model.lists[0].items.len + model.pending() + 1 < entry_capacity)) {
                var text: [6]u8 = undefined;
                const length = r.uintLessThan(usize, text.len + 1);
                for (text[0..length]) |*byte| byte.* = 'a' + @as(u8, @intCast((step + length) % 26));
                try log.prepare(text[0..length]);
                try model.prepare(allocator, text[0..length]);
            }
            // What the model's world has gained is what the log has committed, in order.
            for (model.lists[0].items[seen..]) |text| world.add(text.bytes[0..text.len]);
            seen = model.lists[0].items.len;
            try std.testing.expect(world.eql(log.committed));
            try std.testing.expectEqual(model.depth, log.depth);
            try std.testing.expectEqual(model.discarded, log.discarded);
            try std.testing.expectEqual(model.pending(), log.count - log.kept);
            if (retain) {
                try std.testing.expectEqual(seen, log.kept);
            } else try std.testing.expectEqual(@as(u32, 0), log.kept);
            // The pending actions, oldest first, are the lists of the open regions in order.
            var index: u32 = log.kept;
            for (model.lists[1 .. model.depth + 1]) |list| for (list.items) |text| {
                try std.testing.expectEqualStrings(text.bytes[0..text.len], log.text(index));
                index += 1;
            };
            deepest = @max(deepest, model.depth);
            most_marks = @max(most_marks, log.mark_count);
        }
        while (model.depth != 0) {
            try log.commit();
            try model.commit(allocator);
        }
        for (model.lists[0].items[seen..]) |text| world.add(text.bytes[0..text.len]);
        try std.testing.expect(world.eql(log.committed));
        const record = log.record();
        if (retain) for (model.lists[0].items, 0..) |text, index| try std.testing.expectEqualStrings(text.bytes[0..text.len], record.text(index));
        // The walk nested, kept several marks at once and threw actions away; else it proved little.
        try std.testing.expect(deepest >= 8 and most_marks >= 4 and aborted_actions >= 500 and log.committed.count >= 500);
    }
}

fn testInputs() !*Inputs {
    const inputs = try scratch.storage(Inputs);
    scratch.initialise(inputs);
    return inputs;
}

fn clockAt(inputs: *Inputs, tick: u64) InputError!f64 {
    return @bitCast((try inputs.read(.{ .kind = .clock, .tick = tick })).bits);
}

fn lineOf(inputs: *Inputs, request: u32, tick: u64) InputError!?[]const u8 {
    const answer = try inputs.read(.{ .kind = .line, .request = request, .tick = tick });
    return if (answer.status == .end) null else answer.bytes;
}

fn bitsOf(value: f64) u64 {
    return @bitCast(value);
}

test "the clock is read once per tick, holds its value when the world goes back, and refuses what is not a number" {
    const inputs = try testInputs();
    defer scratch.release(inputs);
    var script: Script = .{ .clocks = &.{ 100.0, 90.0, 100.5 } };
    inputs.source = script.source();
    inputs.reset();
    try std.testing.expectEqual(@as(f64, 100.0), try clockAt(inputs, 0));
    // The same tick, however often: the same value, and no entry.
    for (0..1000) |_| try std.testing.expectEqual(@as(f64, 100.0), try clockAt(inputs, 0));
    try std.testing.expectEqual(@as(u32, 1), inputs.count);
    // The world's clock went back: the value holds, and the entry keeps what the world said.
    try std.testing.expectEqual(@as(f64, 100.0), try clockAt(inputs, 5));
    try std.testing.expectEqual(@as(f64, 100.0), try clockAt(inputs, 5));
    try std.testing.expectEqual(@as(f64, 100.5), try clockAt(inputs, 6));
    // Past the script, the world reads `base + tick / rate`.
    try std.testing.expectEqual(script.paced(120), try clockAt(inputs, 120));
    try std.testing.expectEqual(@as(u32, 4), inputs.count);
    try std.testing.expectEqual(@as(u32, 4), script.asked_count);
    const ticks = [_]u64{ 0, 5, 6, 120 };
    const raws = [_]f64{ 100.0, 90.0, 100.5, script.paced(120) };
    for (inputs.entries[0..4], ticks, raws, script.asked[0..4]) |entry, tick, raw, asked| {
        try std.testing.expectEqual(InputKind.clock, entry.kind);
        try std.testing.expectEqual(InputStatus.value, entry.status);
        try std.testing.expectEqual(@as(u32, 0), entry.request);
        try std.testing.expectEqual(tick, entry.tick);
        try std.testing.expectEqual(bitsOf(raw), entry.bits);
        try std.testing.expectEqual(entry.start, entry.end);
        try std.testing.expectEqual(Request{ .kind = .clock, .tick = tick }, asked);
    }
    try std.testing.expectEqual(@as(u32, 0), inputs.byte_count);

    // Of two zeros neither is below the other: the earlier one stays.
    script = .{ .clocks = &.{ -0.0, 0.0, 0.0, -0.0 } };
    inputs.source = script.source();
    inputs.reset();
    try std.testing.expectEqual(bitsOf(-0.0), bitsOf(try clockAt(inputs, 0)));
    try std.testing.expectEqual(bitsOf(-0.0), bitsOf(try clockAt(inputs, 1)));
    inputs.reset();
    script.rewind();
    script.clock_reads = 2;
    try std.testing.expectEqual(bitsOf(0.0), bitsOf(try clockAt(inputs, 0)));
    try std.testing.expectEqual(bitsOf(0.0), bitsOf(try clockAt(inputs, 1)));

    // NaN and the infinities are no time: `input_invalid`, and the entry stays recorded (I8).
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |raw| {
        const answers = [_]f64{ 5.0, raw };
        script = .{ .clocks = &answers };
        inputs.source = script.source();
        inputs.reset();
        _ = try clockAt(inputs, 0);
        try std.testing.expectError(error.InputInvalid, clockAt(inputs, 1));
        try std.testing.expectEqual(@as(u32, 2), inputs.count);
        try std.testing.expectEqual(bitsOf(raw), inputs.entries[1].bits);
    }
    // A device that cannot answer records nothing; a run without a source has no world.
    script = .{ .fail_read = 1 };
    inputs.source = script.source();
    inputs.reset();
    _ = try clockAt(inputs, 0);
    try std.testing.expectError(error.InputFailed, clockAt(inputs, 1));
    try std.testing.expectEqual(@as(u32, 1), inputs.count);
    inputs.source = null;
    inputs.reset();
    try std.testing.expectError(error.InputUnavailable, clockAt(inputs, 0));
    try std.testing.expectEqual(@as(u32, 0), inputs.count);
}

test "lines are text without their newline, an end is recorded like a value, and every reader shares the cursor" {
    const inputs = try testInputs();
    defer scratch.release(inputs);
    const stream = [_][]const u8{ "alpha", "", "carriage\r", "\xe9\x9b\xaa" };
    var script: Script = .{ .streams = &.{&stream} };
    inputs.source = script.source();
    inputs.reset();
    for (stream) |line| try std.testing.expectEqualStrings(line, (try lineOf(inputs, 0, 0)).?);
    // The end, and again the end: a file at its end answers so every time it is asked.
    try std.testing.expectEqual(@as(?[]const u8, null), try lineOf(inputs, 0, 0));
    try std.testing.expectEqual(@as(?[]const u8, null), try lineOf(inputs, 0, 3));
    try std.testing.expectEqual(@as(u32, 6), inputs.count);
    try std.testing.expectEqual(InputStatus.end, inputs.entries[5].status);
    try std.testing.expectEqual(@as(u64, 3), inputs.entries[5].tick);
    try std.testing.expectEqualStrings("alphacarriage\r\xe9\x9b\xaa", inputs.record().bytes);
    try std.testing.expectEqualStrings("carriage\r", inputs.value(2));
    // A line holding a newline, or bytes that are not UTF-8, is no line of text.
    for ([_][]const u8{ "a\nb", "\xff", "\xe9\x9b" }) |bad| {
        const lines = [_][]const u8{ "fine", bad };
        script = .{ .streams = &.{&lines} };
        inputs.source = script.source();
        inputs.reset();
        _ = try lineOf(inputs, 0, 0);
        try std.testing.expectError(error.InputInvalid, lineOf(inputs, 0, 0));
        try std.testing.expectEqual(@as(u32, 2), inputs.count);
    }
}

test "a run given a record as its prefix asks the world only past it, and refuses a request that is not the recorded one" {
    const first = try testInputs();
    defer scratch.release(first);
    const second = try testInputs();
    defer scratch.release(second);
    const lines = [_][]const u8{ "alpha", "beta" };
    var world: Script = .{ .clocks = &.{ 10.0, 12.0 }, .streams = &.{&lines} };
    first.source = world.source();
    first.reset();
    const Run = struct {
        fn reads(inputs: *Inputs) !void {
            try std.testing.expectEqual(@as(f64, 10.0), try clockAt(inputs, 0));
            try std.testing.expectEqualStrings("alpha", (try lineOf(inputs, 0, 0)).?);
            try std.testing.expectEqual(@as(f64, 12.0), try clockAt(inputs, 3));
            try std.testing.expectEqualStrings("beta", (try lineOf(inputs, 0, 3)).?);
            try std.testing.expectEqual(@as(?[]const u8, null), try lineOf(inputs, 0, 4));
        }
    };
    try Run.reads(first);
    const record = first.record();
    try std.testing.expectEqual(@as(usize, 5), record.entries.len);
    // The second machine gets the record and no world, and gives the same answers.
    second.prefix = record;
    second.source = null;
    second.reset();
    try Run.reads(second);
    try std.testing.expectEqualDeep(record.entries, second.record().entries);
    try std.testing.expectEqualStrings(record.bytes, second.record().bytes);
    // Past the prefix it has no world to ask.
    try std.testing.expectError(error.InputUnavailable, clockAt(second, 9));
    // With one, it asks only for what the first run never read.
    var later: Script = .{ .clocks = &.{ 99.0, 1.0, 1.0 } };
    second.source = later.source();
    second.reset();
    try Run.reads(second);
    try std.testing.expectEqual(@as(u64, 0), later.reads);
    try std.testing.expectEqual(@as(f64, 99.0), try clockAt(second, 9));
    try std.testing.expectEqual(@as(u64, 1), later.reads);
    // A request inside the prefix that is not the recorded one: another tick, kind or request.
    second.source = null;
    second.reset();
    try std.testing.expectError(error.InputDiverged, clockAt(second, 1));
    second.reset();
    try std.testing.expectError(error.InputDiverged, lineOf(second, 0, 0));
    second.reset();
    _ = try clockAt(second, 0);
    try std.testing.expectError(error.InputDiverged, lineOf(second, 1, 0));
    try std.testing.expectEqual(@as(u32, 1), second.count);
    // A prefix whose bytes lie outside it is refused where it is read.
    var forged = record.entries[0..2].*;
    forged[1].end = @intCast(record.bytes.len + 1);
    second.prefix = .{ .entries = &forged, .bytes = record.bytes };
    second.reset();
    _ = try clockAt(second, 0);
    try std.testing.expectError(error.InputDiverged, lineOf(second, 0, 0));
    // A recorded end of a clock, or bytes for one, is no reading wherever it comes from.
    var ended = record.entries[0..1].*;
    ended[0].status = .end;
    second.prefix = .{ .entries = &ended, .bytes = record.bytes };
    second.reset();
    try std.testing.expectError(error.InputInvalid, clockAt(second, 0));

    // The tool's rerun after a limit: the log's own record is the prefix of its next run, which
    // writes the same entries again where they lie and asks the world past them only.
    const gamma = [_][]const u8{"gamma"};
    var other: Script = .{ .clocks = &.{ 55.0, 56.0 }, .streams = &.{&gamma} };
    first.again();
    first.source = other.source();
    first.reset();
    try Run.reads(first);
    try std.testing.expectEqual(@as(u64, 0), other.reads);
    try std.testing.expectEqual(@as(f64, 55.0), try clockAt(first, 7));
    try std.testing.expectEqualStrings("gamma", (try lineOf(first, 0, 7)).?);
    try std.testing.expectEqual(@as(u32, 7), first.count);
    try std.testing.expectEqualStrings("alphabetagamma", first.record().bytes);
}

/// A world of one endless stream of the same line, and a clock that never repeats.
const Endless = struct {
    line: []const u8,
    fn read(context: *anyopaque, request: Request) error{InputFailed}!Answer {
        const self: *Endless = @ptrCast(@alignCast(context));
        return switch (request.kind) {
            .clock => .{ .bits = bitsOf(@floatFromInt(request.tick)) },
            .line => .{ .bytes = self.line },
            .load => .{ .status = .end },
        };
    }
};

test "the input record is bounded: entries and bytes fill exactly, and reads at one tick need no room" {
    const inputs = try testInputs();
    defer scratch.release(inputs);
    const chunk: [128]u8 = @splat('x');
    var world: Endless = .{ .line = &chunk };
    inputs.source = .{ .context = &world, .read = Endless.read };
    inputs.reset();
    for (0..input_entry_capacity) |tick| _ = try clockAt(inputs, tick);
    try std.testing.expectError(error.InputLimit, clockAt(inputs, input_entry_capacity));
    // The reading of the last tick is the log's: it needs no entry.
    try std.testing.expectEqual(@as(f64, @floatFromInt(input_entry_capacity - 1)), try clockAt(inputs, input_entry_capacity - 1));
    // Bytes fill exactly too, and an empty line still fits where a byte does not.
    comptime assert(input_byte_capacity % chunk.len == 0 and input_byte_capacity / chunk.len < input_entry_capacity);
    inputs.reset();
    for (0..input_byte_capacity / chunk.len) |_| _ = (try lineOf(inputs, 0, 0)).?;
    world.line = "y";
    try std.testing.expectError(error.InputLimit, lineOf(inputs, 0, 0));
    world.line = "";
    try std.testing.expectEqualStrings("", (try lineOf(inputs, 0, 0)).?);
    try std.testing.expectEqual(@as(u32, input_byte_capacity), inputs.byte_count);
}

/// The inputs with nothing shared: the clock's raw readings come from a function of the read's
/// number, which goes back now and then; each stream has a cursor that only moves on.
const InputModel = struct {
    lines: [3][40][6]u8 = undefined,
    lengths: [3][40]u8 = undefined,
    cursors: [3]usize = @splat(0),
    reading: ?f64 = null,
    reading_tick: u64 = 0,
    reads: u64 = 0,

    fn raw(read_number: u64, tick: u64) f64 {
        // Every fifth reading of the world is three seconds behind.
        const behind: f64 = if (read_number % 5 == 4) 3.0 else 0.0;
        return 1000.0 + @as(f64, @floatFromInt(tick)) - behind;
    }
    fn clock(self: *InputModel, tick: u64) f64 {
        if (self.reading != null and self.reading_tick == tick) return self.reading.?;
        const value = raw(self.reads, tick);
        self.reads += 1;
        const held = if (self.reading) |earlier| (if (earlier < value) value else earlier) else value;
        self.reading = held;
        self.reading_tick = tick;
        return held;
    }
    fn line(self: *InputModel, stream: usize) ?[]const u8 {
        self.reads += 1;
        if (self.cursors[stream] == self.lines[stream].len) return null;
        self.cursors[stream] += 1;
        const at = self.cursors[stream] - 1;
        return self.lines[stream][at][0..self.lengths[stream][at]];
    }
};

/// The world the model describes, as a source.
const ModelWorld = struct {
    model: *const InputModel,
    cursors: [3]usize = @splat(0),
    reads: u64 = 0,
    fn read(context: *anyopaque, request: Request) error{InputFailed}!Answer {
        const self: *ModelWorld = @ptrCast(@alignCast(context));
        const number = self.reads;
        self.reads += 1;
        switch (request.kind) {
            .clock => return .{ .bits = bitsOf(InputModel.raw(number, request.tick)) },
            .line => {
                const stream = request.request;
                if (self.cursors[stream] == self.model.lines[stream].len) return .{ .status = .end };
                self.cursors[stream] += 1;
                const at = self.cursors[stream] - 1;
                return .{ .bytes = self.model.lines[stream][at][0..self.model.lengths[stream][at]] };
            },
            .load => return .{ .status = .end },
        }
    }
};

test "sixty thousand random region actions, clock reads and line reads agree with a model, and a run given the record agrees without the world" {
    const allocator = std.testing.allocator;
    const logs = [_]*Log{ try testLog(), try testLog() };
    defer for (logs) |log| scratch.release(log);
    var lines: InputModel = .{};
    var setup = std.Random.DefaultPrng.init(0x1a7e);
    for (&lines.lines, &lines.lengths) |*stream, *lengths| for (stream, lengths) |*text, *length| {
        length.* = setup.random().uintLessThan(u8, text.len + 1);
        for (text[0..length.*]) |*byte| byte.* = 'a' + setup.random().uintLessThan(u8, 26);
    };
    var world: ModelWorld = .{ .model = &lines };
    // The first log asks the world; the second is given the first's record and no world.
    logs[0].inputs.source = .{ .context = &world, .read = ModelWorld.read };
    logs[1].inputs.source = null;
    for (logs, 0..) |log, pass| {
        if (pass == 1) logs[1].inputs.prefix = logs[0].inputs.record();
        var model: Model = .{};
        defer model.destroy(allocator);
        var inputs: InputModel = lines;
        var random = std.Random.DefaultPrng.init(0x1a7f);
        const r = random.random();
        var world_tally: Tally = .{};
        var seen: usize = 0;
        var tick: u64 = 0;
        var cached: u64 = 0;
        var ended: u64 = 0;
        var in_regions: u64 = 0;
        log.reset(true);
        for (0..60_000) |step| {
            const choice = r.uintLessThan(u8, 24);
            if (choice < 5 and model.depth + 1 < model.lists.len) {
                log.begin();
                model.begin();
            } else if (choice < 8 and model.depth != 0) {
                try log.commit();
                try model.commit(allocator);
            } else if (choice < 10 and model.depth != 0) {
                log.abort();
                model.abort();
            } else if (choice < 14) {
                // The virtual clock moves on now and then; reads at one tick share a reading. The
                // record holds one entry per tick read, so the ticks are few enough for it.
                if (r.uintLessThan(u8, 40) == 0) tick += 1 + r.uintLessThan(u64, 3);
                const before = log.inputs.count;
                const value = try clockAt(&log.inputs, tick);
                try std.testing.expectEqual(bitsOf(inputs.clock(tick)), bitsOf(value));
                if (log.inputs.count == before) cached += 1;
                if (model.depth != 0) in_regions += 1;
            } else if (choice == 14 and r.uintLessThan(u8, 4) == 0) {
                const stream = r.uintLessThan(u32, 3);
                const expected = inputs.line(stream);
                const actual = try lineOf(&log.inputs, stream, tick);
                if (expected) |text| try std.testing.expectEqualStrings(text, actual.?) else {
                    try std.testing.expectEqual(@as(?[]const u8, null), actual);
                    ended += 1;
                }
            } else if (choice > 14 and model.pending() + 1 < entry_capacity and model.lists[0].items.len + model.pending() + 1 < entry_capacity) {
                var text: [6]u8 = undefined;
                const length = r.uintLessThan(usize, text.len + 1);
                for (text[0..length]) |*byte| byte.* = 'a' + @as(u8, @intCast((step + length) % 26));
                try log.prepare(text[0..length]);
                try model.prepare(allocator, text[0..length]);
            }
            for (model.lists[0].items[seen..]) |text| world_tally.add(text.bytes[0..text.len]);
            seen = model.lists[0].items.len;
            try std.testing.expect(world_tally.eql(log.committed));
            try std.testing.expectEqual(model.depth, log.depth);
            // An input is never undone: the record has an entry for every read of the world.
            try std.testing.expectEqual(inputs.reads, log.inputs.count);
        }
        while (model.depth != 0) {
            try log.commit();
            try model.commit(allocator);
        }
        // The walk read inputs inside regions that failed, reused readings and ran streams dry.
        try std.testing.expect(in_regions >= 1000 and cached >= 1000 and ended >= 100 and model.discarded >= 500);
        const record = log.record();
        try std.testing.expectEqual(@as(usize, inputs.reads), record.inputs.len);
        if (pass == 1) {
            // The run given the record recorded it again, entry for entry and byte for byte.
            const original = logs[0].record();
            try std.testing.expectEqualDeep(original.inputs, record.inputs);
            try std.testing.expectEqualStrings(original.input_bytes, record.input_bytes);
            try std.testing.expect(original.output.eql(record.output));
        } else try std.testing.expectEqual(inputs.reads, world.reads);
    }
}

test "a tally folds the channel of every action but `Print`'s, and a list of grants is one a host may give" {
    var plain: Tally = .{};
    var zero: Tally = .{};
    plain.add("line");
    zero.addOn(0, "line");
    try std.testing.expect(plain.eql(zero));
    var first: Tally = .{};
    var second: Tally = .{};
    first.addOn(1, "line");
    second.addOn(2, "line");
    // The same bytes on another channel are another action, though they count alike.
    try std.testing.expect(!first.eql(plain) and !first.eql(second));
    try std.testing.expectEqual(plain.count, first.count);
    try std.testing.expectEqual(plain.bytes, second.bytes);
    // Where one action ends and the next begins is folded too, channel and all.
    var split: Tally = .{};
    split.addOn(1, "li");
    split.addOn(1, "ne");
    try std.testing.expect(!split.eql(first));

    try std.testing.expect(validGrants(&.{}));
    try std.testing.expect(validGrants(&.{ .{ .kind = .reader, .name = "a" }, .{ .kind = .writer, .name = "a" }, .{ .kind = .reader, .name = "\xe9\x9b\xaa" } }));
    const long: [grant_name_bytes]u8 = @splat('n');
    try std.testing.expect(validGrants(&.{.{ .kind = .writer, .name = &long }}));
    for ([_][]const Grant{
        &.{ .{ .kind = .reader, .name = "a" }, .{ .kind = .reader, .name = "a" } },
        &.{.{ .kind = .reader, .name = "" }},
        &.{.{ .kind = .writer, .name = "\xff" }},
        &.{.{ .kind = @fromBackingInt(@intCast(2)), .name = "a" }},
        &.{.{ .kind = .writer, .name = &(long ++ "n".*) }},
    }) |grants| try std.testing.expect(!validGrants(grants));
    try std.testing.expectEqual(@as(u32, 1), writerChannel(0));
}

/// A sink that checks what it is handed: sequence numbers from zero, and each action's channel,
/// folded into a tally of its own.
const ChannelSink = struct {
    tally: Tally = .{},
    next: u64 = 0,
    out_of_order: u64 = 0,
    fn prepare(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn commit(context: *anyopaque, action: Action) bool {
        const self: *ChannelSink = @ptrCast(@alignCast(context));
        if (action.sequence != self.next) self.out_of_order += 1;
        self.next += 1;
        self.tally.addOn(action.channel, action.text);
        return true;
    }
    fn abort(_: *anyopaque, _: []const u8) void {}
    fn sink(self: *ChannelSink) Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort };
    }
};

/// The regions of the model of channels: per region a list of actions, each with its channel.
const ChannelModel = struct {
    const Text = struct { channel: u32, bytes: [6]u8, len: u8 };
    lists: [12]std.ArrayList(Text) = @splat(.empty),
    depth: usize = 0,
    discarded: u64 = 0,

    fn destroy(self: *ChannelModel, allocator: std.mem.Allocator) void {
        for (&self.lists) |*list| list.deinit(allocator);
    }
    fn begin(self: *ChannelModel) void {
        self.depth += 1;
        self.lists[self.depth].clearRetainingCapacity();
    }
    fn prepare(self: *ChannelModel, allocator: std.mem.Allocator, channel: u32, action: []const u8) !void {
        var text: Text = .{ .channel = channel, .bytes = undefined, .len = @intCast(action.len) };
        @memcpy(text.bytes[0..action.len], action);
        try self.lists[self.depth].append(allocator, text);
    }
    fn commit(self: *ChannelModel, allocator: std.mem.Allocator) !void {
        try self.lists[self.depth - 1].appendSlice(allocator, self.lists[self.depth].items);
        self.depth -= 1;
    }
    fn abort(self: *ChannelModel) void {
        self.discarded += self.lists[self.depth].items.len;
        self.depth -= 1;
    }
    fn pending(self: *const ChannelModel) usize {
        var total: usize = 0;
        for (self.lists[1 .. self.depth + 1]) |list| total += list.items.len;
        return total;
    }
};

test "thirty thousand random region actions on four channels share one sequence and one commit order, kept or not" {
    const allocator = std.testing.allocator;
    const log = try testLog();
    defer scratch.release(log);
    for ([_]bool{ true, false }, [_]u64{ 0xc4a1, 0xc4a2 }) |retain, seed| {
        var model: ChannelModel = .{};
        defer model.destroy(allocator);
        var checking: ChannelSink = .{};
        var random = std.Random.DefaultPrng.init(seed);
        const r = random.random();
        var world: Tally = .{};
        var seen: usize = 0;
        var per_channel: [4]u64 = @splat(0);
        log.sink = checking.sink();
        defer log.sink = null;
        log.reset(retain);
        for (0..30_000) |step| {
            const choice = r.uintLessThan(u8, 16);
            if (choice < 5 and model.depth + 1 < model.lists.len) {
                log.begin();
                model.begin();
            } else if (choice < 8 and model.depth != 0) {
                try log.commit();
                try model.commit(allocator);
            } else if (choice < 10 and model.depth != 0) {
                log.abort();
                model.abort();
            } else if (model.pending() + 1 < entry_capacity and (!retain or model.lists[0].items.len + model.pending() + 1 < entry_capacity)) {
                var text: [6]u8 = undefined;
                const length = r.uintLessThan(usize, text.len + 1);
                for (text[0..length]) |*byte| byte.* = 'a' + @as(u8, @intCast((step + length) % 26));
                const channel = r.uintLessThan(u32, 4);
                try log.prepareOn(channel, text[0..length]);
                try model.prepare(allocator, channel, text[0..length]);
            }
            for (model.lists[0].items[seen..]) |text| {
                world.addOn(text.channel, text.bytes[0..text.len]);
                per_channel[text.channel] += 1;
            }
            seen = model.lists[0].items.len;
            try std.testing.expect(world.eql(log.committed));
            try std.testing.expect(world.eql(checking.tally));
            try std.testing.expectEqual(model.discarded, log.discarded);
            // The pending actions keep their channels, oldest first.
            var index: u32 = log.kept;
            for (model.lists[1 .. model.depth + 1]) |list| for (list.items) |text| {
                try std.testing.expectEqual(text.channel, log.entries[index].channel);
                try std.testing.expectEqualStrings(text.bytes[0..text.len], log.text(index));
                index += 1;
            };
        }
        while (model.depth != 0) {
            try log.commit();
            try model.commit(allocator);
        }
        for (model.lists[0].items[seen..]) |text| world.addOn(text.channel, text.bytes[0..text.len]);
        try std.testing.expect(world.eql(log.committed) and world.eql(checking.tally));
        try std.testing.expectEqual(@as(u64, 0), checking.out_of_order);
        try std.testing.expectEqual(log.committed.count, checking.next);
        const record = log.record();
        if (retain) {
            for (model.lists[0].items, 0..) |text, at| {
                try std.testing.expectEqual(text.channel, record.entries[at].channel);
                try std.testing.expectEqualStrings(text.bytes[0..text.len], record.text(at));
            }
        } else try std.testing.expectEqual(@as(usize, 0), record.entries.len);
        // Every channel was written to, often.
        for (per_channel) |count| try std.testing.expect(count >= 200);
    }
}

test "a recorder writes down the channel of each committed action, and the log's record carries the grants" {
    const log = try testLog();
    defer scratch.release(log);
    var recorder: Recorder = .{};
    const grants = [_]Grant{ .{ .kind = .reader, .name = "in" }, .{ .kind = .writer, .name = "out" } };
    log.sink = recorder.sink();
    log.inputs.grants = &grants;
    log.reset(true);
    try log.prepareOn(2, "written");
    log.begin();
    try log.prepare("printed");
    try log.prepareOn(2, "held");
    try log.commit();
    log.begin();
    try log.prepareOn(2, "dropped");
    log.abort();
    // A reset keeps the grants, as it keeps the seed and the sink.
    const record = log.record();
    try std.testing.expectEqual(@as(usize, 2), record.grants.len);
    try std.testing.expectEqualStrings("out", record.grants[1].name);
    const channels = [_]u32{ 2, 0, 2 };
    var commits: usize = 0;
    for (recorder.calls[0..recorder.call_count]) |call| if (call.kind == .commit) {
        try std.testing.expectEqual(channels[commits], call.channel);
        try std.testing.expectEqual(@as(u64, commits), call.sequence);
        commits += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), commits);
    for (record.entries, channels) |entry, channel| try std.testing.expectEqual(channel, entry.channel);
    log.reset(true);
    try std.testing.expectEqual(@as(usize, 2), log.inputs.grants.len);
    // The port lends the grants to a native.
    try std.testing.expectEqual(@as(usize, 2), log.port(0).grants.len);
}

// RFC-0086, P2.4: seals and the write-ahead of inputs.

test "a sink that seals hears one seal per commit point with actions, after its last action, kept or not" {
    const log = try testLog();
    defer scratch.release(log);
    var recorder: Recorder = .{};
    log.sink = recorder.sink();
    defer log.sink = null;
    for ([_]bool{ true, false }) |retain| {
        log.reset(retain);
        recorder.clear();
        // Outside every region an action is a commit point of its own.
        try log.prepare("a");
        try log.prepareOn(2, "b");
        try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, recorder.sealed());
        // An outermost region that commits seals once, after all it held, inner regions included.
        log.begin();
        try log.prepare("c");
        log.begin();
        try log.prepareOn(4, "d");
        try log.commit();
        try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, recorder.sealed());
        try log.prepare("e");
        try log.commit();
        try std.testing.expectEqualSlices(u64, &.{ 1, 2, 5 }, recorder.sealed());
        // A region that fails, or commits nothing, has no seal; nor has an inner region's commit.
        log.begin();
        try log.prepare("f");
        log.abort();
        log.begin();
        log.begin();
        try log.commit();
        try log.commit();
        try std.testing.expectEqualSlices(u64, &.{ 1, 2, 5 }, recorder.sealed());
        // A seal names the actions committed so far, which every commit before it numbered.
        var commits: u64 = 0;
        for (recorder.calls[0..recorder.call_count]) |call| if (call.kind == .commit) {
            commits += 1;
        };
        try std.testing.expectEqual(@as(u64, 5), commits);
        try std.testing.expectEqual(@as(u64, 0), recorder.lost);
    }
}

test "a seal that fails ends the run at the commit point and keeps what was sealed before it" {
    const log = try testLog();
    defer scratch.release(log);
    var recorder: Recorder = .{};
    log.sink = recorder.sink();
    defer log.sink = null;
    for ([_]bool{ true, false }) |retain| {
        for (0..3) |failing| {
            log.reset(retain);
            recorder.clear();
            recorder.fail_seal = failing;
            defer recorder.fail_seal = null;
            const first = log.prepare("a");
            if (failing == 0) {
                try std.testing.expectError(error.EffectCommitFailed, first);
                continue;
            }
            try first;
            log.begin();
            try log.prepare("b");
            try log.prepare("c");
            const second = log.commit();
            if (failing == 1) {
                try std.testing.expectError(error.EffectCommitFailed, second);
                try std.testing.expectEqualSlices(u64, &.{1}, recorder.sealed());
                // The actions were committed; the seal is what failed.
                try std.testing.expectEqual(@as(u64, 3), log.committed.count);
                continue;
            }
            try second;
            try std.testing.expectError(error.EffectCommitFailed, log.prepare("d"));
            try std.testing.expectEqualSlices(u64, &.{ 1, 3 }, recorder.sealed());
        }
    }
}

/// A sink that checks each seal against the commits it was handed: a seal comes after at least
/// one commit, and names every action committed so far.
const SealingSink = struct {
    commits: u64 = 0,
    sealed_through: u64 = 0,
    seals: u64 = 0,
    wrong: u64 = 0,
    fn prepare(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn commit(context: *anyopaque, action: Action) bool {
        const self: *SealingSink = @ptrCast(@alignCast(context));
        if (action.sequence != self.commits) self.wrong += 1;
        self.commits += 1;
        return true;
    }
    fn abort(_: *anyopaque, _: []const u8) void {}
    fn seal(context: *anyopaque, through: u64) bool {
        const self: *SealingSink = @ptrCast(@alignCast(context));
        if (through != self.commits or through == self.sealed_through) self.wrong += 1;
        self.sealed_through = through;
        self.seals += 1;
        return true;
    }
    fn sink(self: *SealingSink) Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort, .seal = seal };
    }
};

test "thirty thousand random region actions seal exactly the commit points that a model of regions has" {
    const allocator = std.testing.allocator;
    const log = try testLog();
    defer scratch.release(log);
    for ([_]bool{ true, false }, [_]u64{ 0x5ea1, 0x5ea2 }) |retain, seed| {
        var model: ChannelModel = .{};
        defer model.destroy(allocator);
        var checking: SealingSink = .{};
        var random = std.Random.DefaultPrng.init(seed);
        const r = random.random();
        // The model's commit points: an action outside every region, or an outermost region
        // that commits holding at least one action.
        var points: u64 = 0;
        var through: u64 = 0;
        log.sink = checking.sink();
        defer log.sink = null;
        log.reset(retain);
        for (0..30_000) |_| {
            const choice = r.uintLessThan(u8, 16);
            if (choice < 4 and model.depth + 1 < model.lists.len) {
                log.begin();
                model.begin();
            } else if (choice < 8 and model.depth != 0) {
                const outermost = model.depth == 1;
                const held = model.lists[model.depth].items.len;
                try log.commit();
                try model.commit(allocator);
                if (outermost and held != 0) {
                    points += 1;
                    through += held;
                }
            } else if (choice < 10 and model.depth != 0) {
                log.abort();
                model.abort();
            } else if (model.pending() + 1 < entry_capacity and (!retain or model.lists[0].items.len + model.pending() + 1 < entry_capacity)) {
                const channel = r.uintLessThan(u32, 3);
                try log.prepareOn(channel, "x");
                try model.prepare(allocator, channel, "x");
                if (model.depth == 0) {
                    points += 1;
                    through += 1;
                }
            }
            try std.testing.expectEqual(points, checking.seals);
            try std.testing.expectEqual(through, checking.sealed_through);
        }
        try std.testing.expectEqual(@as(u64, 0), checking.wrong);
        try std.testing.expectEqual(log.committed.count, checking.commits);
        // A `full` log keeps what it commits, so it fills after `entry_capacity` actions.
        try std.testing.expect(points > 300);
    }
}

/// An input journal for tests: it writes down each entry it is told of, with its bytes, and fails
/// the append whose number it was told to fail.
const TestInputJournal = struct {
    sequences: [64]u32 = undefined,
    entries: [64]InputEntry = undefined,
    text: [256]u8 = undefined,
    text_count: usize = 0,
    count: u32 = 0,
    appends: u64 = 0,
    fail_append: ?u64 = null,
    fn append(context: *anyopaque, sequence: u32, entry: InputEntry, bytes: []const u8) bool {
        const self: *TestInputJournal = @ptrCast(@alignCast(context));
        const number = self.appends;
        self.appends += 1;
        if (self.fail_append == number) return false;
        self.sequences[self.count] = sequence;
        self.entries[self.count] = entry;
        @memcpy(self.text[self.text_count..][0..bytes.len], bytes);
        self.text_count += bytes.len;
        self.count += 1;
        return true;
    }
    fn journal(self: *TestInputJournal) InputJournal {
        return .{ .context = self, .append = append };
    }
};

test "an input from the world is journaled before it is returned, the prefix's are not, and a journal that fails records nothing" {
    const inputs = try testInputs();
    defer scratch.release(inputs);
    const config = [_][]const u8{ "alpha", "beta" };
    var script: Script = .{ .clocks = &.{ 5.0, 4.0 }, .streams = &.{&config} };
    var written: TestInputJournal = .{};
    inputs.source = script.source();
    inputs.journal = written.journal();
    inputs.reset();
    try std.testing.expectEqual(@as(f64, 5.0), try clockAt(inputs, 0));
    // A reading held at its tick asks no one and journals nothing.
    try std.testing.expectEqual(@as(f64, 5.0), try clockAt(inputs, 0));
    try std.testing.expectEqualStrings("alpha", (try lineOf(inputs, 0, 3)).?);
    // The world went back: the raw reading is journaled, the value held.
    try std.testing.expectEqual(@as(f64, 5.0), try clockAt(inputs, 4));
    try std.testing.expectEqualStrings("beta", (try lineOf(inputs, 0, 4)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try lineOf(inputs, 0, 4));
    try std.testing.expectEqual(@as(u32, 5), written.count);
    for (written.sequences[0..written.count], written.entries[0..written.count], inputs.record().entries, 0..) |sequence, entry, recorded, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), sequence);
        try std.testing.expectEqualDeep(recorded, entry);
    }
    try std.testing.expectEqual(bitsOf(4.0), written.entries[2].bits);
    try std.testing.expectEqualStrings("alphabeta", written.text[0..written.text_count]);
    // A run given that record as its prefix journals only what it reads past it.
    const record = inputs.record();
    const prefix = try std.testing.allocator.dupe(InputEntry, record.entries[0..3]);
    defer std.testing.allocator.free(prefix);
    const prefix_bytes = try std.testing.allocator.dupe(u8, record.bytes);
    defer std.testing.allocator.free(prefix_bytes);
    script.rewind();
    written = .{};
    inputs.prefix = .{ .entries = prefix, .bytes = prefix_bytes };
    inputs.reset();
    _ = try clockAt(inputs, 0);
    _ = try lineOf(inputs, 0, 3);
    _ = try clockAt(inputs, 4);
    try std.testing.expectEqual(@as(u32, 0), written.count);
    try std.testing.expectEqualStrings("alpha", (try lineOf(inputs, 0, 4)).?);
    try std.testing.expectEqual(@as(u32, 1), written.count);
    try std.testing.expectEqual(@as(u32, 3), written.sequences[0]);
    inputs.prefix = .{};
    // An append that fails is a device that failed: `input_failed`, and the entry is not kept.
    for (0..3) |failing| {
        script.rewind();
        written = .{ .fail_append = failing };
        inputs.reset();
        const outcome: ?InputError = attempt: {
            _ = clockAt(inputs, 0) catch |problem| break :attempt problem;
            _ = lineOf(inputs, 0, 1) catch |problem| break :attempt problem;
            _ = clockAt(inputs, 2) catch |problem| break :attempt problem;
            break :attempt null;
        };
        try std.testing.expectEqual(@as(?InputError, error.InputFailed), outcome);
        try std.testing.expectEqual(@as(u32, @intCast(failing)), inputs.count);
        try std.testing.expectEqual(@as(u32, @intCast(failing)), written.count);
    }
    inputs.journal = null;
    inputs.source = null;
}
