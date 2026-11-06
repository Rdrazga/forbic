//! Substring search in time linear in the text and the pattern, with no memory beyond a few
//! words: the two-way algorithm of Crochemore and Perrin. The string kernels search with it
//! (RFC-0077), so the fuel they declare per byte covers what they do whatever the bytes are:
//! a pattern built to make a plain search slow costs what any other pattern costs.
//!
//! A `Pattern` is prepared once (at most `2 * length` comparisons for each of two orders) and
//! then finds any number of occurrences; a search compares at most twice the bytes it passes.
const std = @import("std");

pub const Pattern = struct {
    bytes: []const u8,
    /// The pattern is `bytes[0..split]` then `bytes[split..]`, a critical factorization.
    split: usize,
    period: usize,
    /// Whether `period` is a period of the whole pattern; otherwise it is only a safe shift.
    periodic: bool,

    pub fn init(bytes: []const u8) Pattern {
        std.debug.assert(bytes.len != 0);
        const forward = maximalSuffix(bytes, false);
        const backward = maximalSuffix(bytes, true);
        const chosen = if (forward.start >= backward.start) forward else backward;
        const split = chosen.start;
        // The left part repeats `period` later exactly when the whole pattern has that period.
        const periodic = split <= bytes.len - chosen.period and std.mem.eql(u8, bytes[0..split], bytes[chosen.period..][0..split]);
        return .{
            .bytes = bytes,
            .split = split,
            .period = if (periodic) chosen.period else @max(split, bytes.len - split) + 1,
            .periodic = periodic,
        };
    }

    /// The position of the first occurrence of the pattern in `text` at or after `from`.
    pub fn find(self: Pattern, text: []const u8, from: usize) ?usize {
        const pattern = self.bytes;
        if (from > text.len or pattern.len > text.len - from) return null;
        const last = text.len - pattern.len;
        var at = from;
        // How much of the pattern's start is known to match at `at` from the shift before.
        var known: usize = 0;
        while (at <= last) {
            var right = @max(self.split, known);
            while (right < pattern.len and pattern[right] == text[at + right]) right += 1;
            if (right < pattern.len) {
                at += right - self.split + 1;
                known = 0;
                continue;
            }
            var left = self.split;
            while (left > known and pattern[left - 1] == text[at + left - 1]) left -= 1;
            if (left <= known) return at;
            at += self.period;
            known = if (self.periodic) pattern.len - self.period else 0;
        }
        return null;
    }
};

/// Where the maximal suffix of `bytes` starts, under the byte order or its reverse, and its
/// period.
fn maximalSuffix(bytes: []const u8, reversed: bool) struct { start: usize, period: usize } {
    var start: usize = 0;
    var candidate: usize = 1;
    var offset: usize = 0;
    var period: usize = 1;
    while (candidate + offset < bytes.len) {
        const a = bytes[candidate + offset];
        const b = bytes[start + offset];
        const smaller = if (reversed) a > b else a < b;
        if (smaller) {
            // The candidate loses: everything up to here has the period that spans both.
            candidate += offset + 1;
            offset = 0;
            period = candidate - start;
        } else if (a == b) {
            if (offset + 1 == period) {
                candidate += period;
                offset = 0;
            } else offset += 1;
        } else {
            start = candidate;
            candidate = start + 1;
            offset = 0;
            period = 1;
        }
    }
    return .{ .start = start, .period = period };
}

/// The first occurrence of `pattern` in `text` at or after `from`; the empty pattern is found
/// at `from`, as `std.mem.indexOfPos` finds it.
pub fn indexOfPos(text: []const u8, from: usize, pattern: []const u8) ?usize {
    if (from > text.len) return null;
    if (pattern.len == 0) return from;
    if (pattern.len == 1) return std.mem.indexOfScalarPos(u8, text, from, pattern[0]);
    return Pattern.init(pattern).find(text, from);
}

test "the two-way search finds what the plain search finds, for every start" {
    var prng = std.Random.DefaultPrng.init(0x7707);
    const random = prng.random();
    var text_buffer: [96]u8 = undefined;
    var pattern_buffer: [12]u8 = undefined;
    var round: usize = 0;
    while (round < 60000) : (round += 1) {
        // Small alphabets make periods, borders and near misses common.
        const letters: u8 = 1 + random.uintLessThan(u8, 3);
        const text = text_buffer[0..random.uintAtMost(usize, text_buffer.len)];
        for (text) |*byte| byte.* = 'a' + random.uintLessThan(u8, letters);
        const pattern = pattern_buffer[0 .. 1 + random.uintLessThan(usize, pattern_buffer.len)];
        if (random.boolean() and text.len >= pattern.len) {
            // A pattern cut from the text, so that it occurs.
            const cut = random.uintAtMost(usize, text.len - pattern.len);
            @memcpy(pattern, text[cut..][0..pattern.len]);
        } else for (pattern) |*byte| {
            byte.* = 'a' + random.uintLessThan(u8, letters);
        }
        const prepared = Pattern.init(pattern);
        var from: usize = 0;
        while (from <= text.len) : (from += 1 + random.uintLessThan(usize, 3)) {
            const expected = std.mem.indexOfPos(u8, text, from, pattern);
            const actual = prepared.find(text, from);
            if (expected != actual) std.debug.print("text {s} pattern {s} from {d}: {?d}, expected {?d}\n", .{ text, pattern, from, actual, expected });
            try std.testing.expectEqual(expected, actual);
            try std.testing.expectEqual(expected, indexOfPos(text, from, pattern));
        }
    }
    try std.testing.expectEqual(@as(?usize, 2), indexOfPos("abc", 2, ""));
    try std.testing.expectEqual(@as(?usize, null), indexOfPos("abc", 4, ""));
    try std.testing.expectEqual(@as(?usize, null), indexOfPos("", 0, "a"));
}

test "a pattern that nearly matches everywhere is found, or not, in time linear in the text" {
    // The plain search compares half the text at every position of this one: 2^34 bytes.
    const size = 1 << 18;
    const text = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    const pattern = try std.testing.allocator.alloc(u8, size / 2 + 1);
    defer std.testing.allocator.free(pattern);
    @memset(pattern, 'a');
    pattern[pattern.len - 1] = 'b';
    try std.testing.expectEqual(@as(?usize, null), indexOfPos(text, 0, pattern));
    text[size - 1] = 'b';
    try std.testing.expectEqual(@as(?usize, size - pattern.len), indexOfPos(text, 0, pattern));
    pattern[0] = 'b';
    pattern[pattern.len - 1] = 'a';
    try std.testing.expectEqual(@as(?usize, null), indexOfPos(text, 0, pattern));
}
