//! Run-owned strings. Strings built at run time live in the unused tail of the
//! same buffer that backs the program's literal pool, so every string value is
//! still a reference into one pool and the existing aliasing validation applies.
//! Both machines share this allocation and formatting glue; each admits the nodes
//! and checks results independently.
const std = @import("std");
const types = @import("types.zig");

pub const Error = error{ StringLimit, WorkLimit };

/// The writable tail behind a program's literal pool and how much of it a run has used.
pub const Pool = struct {
    /// Start of the buffer behind the literal pool; the tail follows the literals.
    origin: [*]const u8,
    base: usize,
    tail: []u8,
    used: usize,
    /// The end at which the pool's last bytes are not the end of the newest string made, or
    /// `fresh` when they are. Only a reclamation sets it: one that frees the newest string's
    /// last byte leaves an earlier string at the tail, which a run that never reclaims has
    /// garbage above, so `concat` copies it as that run does (c7-1). It stays until the end
    /// moves: a string made after it is the newest.
    stale: usize = fresh,

    pub const fresh = std.math.maxInt(usize);

    pub fn init(strings: []const u8, tail: []u8) Pool {
        return .{ .origin = strings.ptr, .base = strings.len, .tail = tail, .used = strings.len };
    }
    /// Continues a pool whose run-built bytes already occupy `used` bytes.
    pub fn resumed(strings: []const u8, tail: []u8, used: usize) Pool {
        return .{ .origin = strings.ptr, .base = strings.len, .tail = tail, .used = used };
    }
    /// True when `value` is a boundary-aligned reference into the pool (literals or
    /// run-built bytes). Empty strings are always acceptable.
    pub fn aliases(self: Pool, value: []const u8) bool {
        if (value.len == 0) return true;
        const start = @intFromPtr(value.ptr);
        const origin = @intFromPtr(self.origin);
        if (start < origin or start - origin > self.used) return false;
        const offset = start - origin;
        if (value.len > self.used - offset) return false;
        const bytes = self.origin[0..self.used];
        return boundary(offset, bytes) and boundary(offset + value.len, bytes);
    }
    /// The canonical empty string, aliasing the pool.
    pub fn empty(self: Pool) []const u8 {
        return self.origin[0..0];
    }
    /// The pool as one slice: literals followed by every run-built string.
    pub fn view(self: Pool, strings: []const u8) []const u8 {
        std.debug.assert(strings.len == self.base and self.used >= self.base);
        return strings.ptr[0..self.used];
    }
};

/// Work charged for producing `length` bytes.
pub fn work(length: usize) u64 {
    return 1 + length / 8;
}

fn boundary(index: usize, bytes: []const u8) bool {
    return index == bytes.len or (bytes[index] & 0xC0) != 0x80;
}

/// Appends `length` bytes to the run-owned tail and returns the writable region.
pub fn reserve(pool: *Pool, length: usize, remaining: *u64) Error![]u8 {
    std.debug.assert(pool.used >= pool.base);
    const offset = pool.used - pool.base;
    if (offset > pool.tail.len or length > pool.tail.len - offset) return error.StringLimit;
    const cost = work(length);
    if (cost > remaining.*) return error.WorkLimit;
    remaining.* -= cost;
    pool.used += length;
    return pool.tail[offset .. offset + length];
}

/// Joins two strings. When `left` ends where the newest string made ends nothing lies beyond
/// it, so the result extends it in place and only `right` is copied (and charged): building a
/// long string by repeated appends costs its final length, not the square of it. `left` itself
/// keeps its bytes and its value. A string that ends the pool only because a reclamation freed
/// what was made after it is copied (`Pool.stale`): whether `+` extends, and so what it costs,
/// does not depend on whether, or where, the run reclaimed.
pub fn concat(pool: *Pool, left: []const u8, right: []const u8, remaining: *u64) Error![]const u8 {
    if (left.len != 0 and pool.used != pool.stale and @intFromPtr(left.ptr) + left.len == @intFromPtr(pool.origin) + pool.used) {
        const out = try reserve(pool, right.len, remaining);
        @memcpy(out, right);
        return left.ptr[0 .. left.len + right.len];
    }
    const out = try reserve(pool, left.len + right.len, remaining);
    @memcpy(out[0..left.len], left);
    @memcpy(out[left.len..], right);
    return out;
}

/// `Pool.stale` after a reclamation that left `kept` bytes in a pool that held `used`, whose
/// stale end was `stale`. `newest` says whether the byte before `used` is still in use, so that
/// it ends the kept bytes: then the tail is as fresh as it was; otherwise the string at the new
/// tail was made before the newest one, and is stale.
pub fn staleAfter(stale: usize, used: usize, kept: usize, newest: bool) usize {
    std.debug.assert(kept <= used);
    return if (newest and stale != used) Pool.fresh else kept;
}

/// What a lone code unit above ASCII reads as in text: U+FFFD, the replacement character.
pub const replacement = "\xEF\xBF\xBD";

/// Decimal integers, `true`/`false`, shortest-round-trip floats and `NaN`/`Inf`/`-Inf`.
/// A `char32` is its UTF-8 encoding. A `char` is its own byte when it is ASCII; any other
/// code unit is part of an encoding and no text on its own, so it reads as `replacement`
/// (RFC-0069): a string never holds bytes that are not valid UTF-8.
pub fn convert(pool: *Pool, value: types.Value, remaining: *u64) Error![]const u8 {
    var buffer: [400]u8 = undefined;
    const text: []const u8 = switch (value) {
        .enumeration => |character| text: {
            std.debug.assert(types.validCharacter(character.value_type, character.index));
            if (character.value_type == types.Type.char and character.index >= 0x80) break :text replacement;
            const length = std.unicode.utf8Encode(@intCast(character.index), buffer[0..4]) catch unreachable;
            break :text buffer[0..length];
        },
        .integer => |x| std.fmt.bufPrint(&buffer, "{d}", .{x}) catch unreachable,
        .boolean => |x| if (x) "true" else "false",
        .floating => |x| if (types.isNan(x)) "NaN" else if (std.math.isInf(x)) (if (x < 0) "-Inf" else "Inf") else std.fmt.bufPrint(&buffer, "{d}", .{x}) catch unreachable,
        else => unreachable,
    };
    const out = try reserve(pool, text.len, remaining);
    @memcpy(out, text);
    return out;
}

test "concat and convert append to the tail and extend the pool" {
    var backing: [64]u8 = undefined;
    @memcpy(backing[0..3], "abc");
    const strings = backing[0..3];
    var pool = Pool.init(strings, backing[3..]);
    var remaining: u64 = 100;
    const joined = try concat(&pool, "abc", "雪", &remaining);
    try std.testing.expectEqualStrings("abc雪", joined);
    try std.testing.expectEqual(@as(usize, 3 + 6), pool.used);
    try std.testing.expectEqualStrings("-42", try convert(&pool, .{ .integer = -42 }, &remaining));
    try std.testing.expectEqualStrings("true", try convert(&pool, .{ .boolean = true }, &remaining));
    try std.testing.expectEqualStrings("3.5", try convert(&pool, .{ .floating = 3.5 }, &remaining));
    try std.testing.expectEqualStrings("abcabc雪-42true3.5", pool.view(strings));
    // Characters: an ASCII unit is itself, a lone unit above ASCII is U+FFFD, a scalar is its encoding.
    try std.testing.expectEqualStrings("a", try convert(&pool, types.characterValue(types.Type.char, 'a'), &remaining));
    try std.testing.expectEqualStrings(replacement, try convert(&pool, types.characterValue(types.Type.char, 0xC3), &remaining));
    try std.testing.expectEqualStrings("\xc3\xa9", try convert(&pool, types.characterValue(types.Type.char32, 0xE9), &remaining));
    try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", try convert(&pool, types.characterValue(types.Type.char32, 0x1F600), &remaining));
    try std.testing.expectEqualStrings("\x00", try convert(&pool, types.characterValue(types.Type.char32, 0), &remaining));
    try std.testing.expect(std.unicode.utf8ValidateSlice(pool.view(strings)));
    // Exhaustion is a checked error and charges nothing.
    var starved: u64 = 0;
    try std.testing.expectError(error.WorkLimit, concat(&pool, "x", "y", &starved));
    var full = Pool.init(strings, backing[3..]);
    full.used = full.base + full.tail.len;
    var plenty: u64 = 100;
    try std.testing.expectError(error.StringLimit, concat(&full, "x", "", &plenty));
}

test "appending to the newest string extends it in place and older values are untouched" {
    var backing: [4096]u8 = undefined;
    @memcpy(backing[0..2], "ab");
    const strings = backing[0..2];
    var pool = Pool.init(strings, backing[2..]);
    var remaining: u64 = 1_000_000;
    var text = try concat(&pool, "ab", "c", &remaining);
    const first = text;
    for (0..1000) |_| text = try concat(&pool, text, "xy", &remaining);
    try std.testing.expectEqual(@as(usize, 3 + 2000), text.len);
    // One copy of each appended piece: the pool holds the final string once, not a quadratic pile.
    try std.testing.expectEqual(@as(usize, 2 + 3 + 2000), pool.used);
    try std.testing.expectEqualStrings("abc", first);
    try std.testing.expect(pool.aliases(text) and pool.aliases(first));
    // A string that is not the newest is copied, so two extensions of one value stay independent.
    const left = try concat(&pool, first, "1", &remaining);
    const right = try concat(&pool, first, "2", &remaining);
    try std.testing.expectEqualStrings("abc1", left);
    try std.testing.expectEqualStrings("abc2", right);
    try std.testing.expect(pool.aliases(left) and pool.aliases(right));
    // Empty operands and literal tails behave like ordinary joins.
    var fresh = Pool.init(strings, backing[2..]);
    const lit = try concat(&fresh, strings, "z", &remaining);
    try std.testing.expectEqualStrings("abz", lit);
    try std.testing.expectEqual(@as(usize, 3), fresh.used);
    try std.testing.expectEqualStrings("", try concat(&fresh, "", "", &remaining));
}

test "concat extends only the newest string made, whatever a reclamation left at the tail" {
    var backing: [64]u8 = undefined;
    const strings = backing[0..0];
    var pool = Pool.init(strings, backing[0..]);
    var remaining: u64 = 100;
    const kept = try concat(&pool, "", "kept", &remaining);
    const garbage = try concat(&pool, "", "garbage", &remaining);
    try std.testing.expectEqual(@as(usize, 11), pool.used);
    // A run that does not reclaim copies `kept`, which garbage lies beyond.
    var copied = pool;
    var spent: u64 = 100;
    _ = try concat(&copied, kept, "+", &spent);
    try std.testing.expectEqual(100 - work(5), spent);
    // A reclamation that frees the garbage (the newest string's last byte) leaves `kept` at the
    // tail, stale: it is copied as the run above copies it, at the same charge.
    pool.stale = staleAfter(pool.stale, pool.used, 4, false);
    pool.used = 4;
    spent = 100;
    const joined = try concat(&pool, kept, "+", &spent);
    try std.testing.expectEqual(100 - work(5), spent);
    try std.testing.expectEqualStrings("kept+", joined);
    try std.testing.expect(joined.ptr != kept.ptr);
    // The copy is the newest string: it is extended in place, charging only what is added.
    spent = 100;
    const again = try concat(&pool, joined, "!", &spent);
    try std.testing.expectEqual(100 - work(1), spent);
    try std.testing.expect(again.ptr == joined.ptr);
    // A reclamation that keeps the newest string's last byte keeps the tail as fresh as it was,
    // and one that frees nothing at a stale tail keeps it stale.
    try std.testing.expectEqual(Pool.fresh, staleAfter(Pool.fresh, 20, 10, true));
    try std.testing.expectEqual(@as(usize, 10), staleAfter(20, 20, 10, true));
    try std.testing.expectEqual(@as(usize, 10), staleAfter(Pool.fresh, 20, 10, false));
    _ = garbage;
}
