//! Euclidean `Quotient`/`Mod` and exact `rational` values (RFC-0070): models, corners,
//! failure, keys, reports and admission of forged IR.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

const min: i64 = std.math.minInt(i64);
const max: i64 = std.math.maxInt(i64);
const origin: types.Span = .{ .start = 0, .end = 0 };
/// The only definition of the hand-built programs below, so the type has the first user ID.
const fraction: types.Type = @fromBackingInt(4);
const only_rational = [_]types.Definition{.rational};

fn integer(value: i64) types.Node {
    return .{ .span = origin, .value_type = .i64, .kind = .{ .integer = value } };
}
fn rational(op: types.RationalOp, lhs: u32, rhs: u32) types.Node {
    const result: types.Type = switch (op) {
        .floor, .ceil => .i64,
        .to_float => .float,
        else => fraction,
    };
    return .{ .span = origin, .value_type = result, .kind = .{ .rational = .{ .op = op, .lhs = lhs, .rhs = rhs } } };
}
fn compare(op: types.CompareOp, lhs: u32, rhs: u32) types.Node {
    return .{ .span = origin, .value_type = .logic, .kind = .{ .compare = .{ .op = op, .lhs = lhs, .rhs = rhs } } };
}
fn divide(op: types.BinaryOp, lhs: u32, rhs: u32) types.Node {
    return .{ .span = origin, .value_type = .i64, .kind = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } } };
}
/// A straight-line program of the given nodes with the rational type in its catalogue.
fn program(nodes: []const types.Node) types.Program {
    return .{ .source = "", .nodes = nodes, .bindings = &.{}, .strings = "", .definitions = &only_rational };
}

/// What an operation yields in exact arithmetic: a fraction in lowest terms whose terms fit
/// `i64`, or an overflow when they do not.
const Exact = union(enum) { value: types.Rational, overflow };

fn lowest(numerator: i128, denominator: i128) Exact {
    std.debug.assert(denominator != 0);
    const shared: i128 = @intCast(std.math.gcd(@abs(numerator), @abs(denominator)));
    var top = @divExact(numerator, shared);
    var bottom = @divExact(denominator, shared);
    if (bottom < 0) {
        top = -top;
        bottom = -bottom;
    }
    if (top < min or top > max or bottom > max) return .overflow;
    return .{ .value = .{ .numerator = @intCast(top), .denominator = @intCast(bottom) } };
}
fn modelBinary(op: types.RationalOp, a: types.Rational, b: types.Rational) Exact {
    const an: i128 = a.numerator;
    const ad: i128 = a.denominator;
    const bn: i128 = b.numerator;
    const bd: i128 = b.denominator;
    return switch (op) {
        .add => lowest(an * bd + bn * ad, ad * bd),
        .subtract => lowest(an * bd - bn * ad, ad * bd),
        .multiply => lowest(an * bn, ad * bd),
        .negate => lowest(-an, ad),
        else => unreachable,
    };
}
/// Whether `actual` is the binary64 nearest to the fraction, ties to the even mantissa. Checked
/// exactly in 256-bit integers scaled by 2^118: the fraction against the midpoints either side.
fn nearestFloat(value: types.Rational, actual: f64) bool {
    if (value.numerator == 0) return @as(u64, @bitCast(actual)) == 0;
    if ((actual < 0) != (value.numerator < 0)) return false;
    const bits: u64 = @bitCast(@abs(actual));
    const exponent_field: i32 = @intCast(bits >> 52);
    if (exponent_field == 0 or exponent_field == 0x7ff) return false;
    const mantissa: u256 = (bits & ((@as(u64, 1) << 52) - 1)) | (@as(u64, 1) << 52);
    const exponent = exponent_field - 1075;
    if (exponent < -116 or exponent > 12) return false;
    const top: u256 = @abs(value.numerator);
    const bottom: u256 = @intCast(value.denominator);
    const exact = top << 118;
    const centre = (mantissa * bottom) << @intCast(exponent + 118);
    const above = bottom << @intCast(exponent + 117);
    // The lowest mantissa of a binade has a neighbour half as far below.
    const below = if (mantissa == @as(u256, 1) << 52) above >> 1 else above;
    if (exact > centre + above or exact + below < centre) return false;
    const tie = exact == centre + above or exact + below == centre;
    return !tie or mantissa & 1 == 0;
}

fn euclid(a: i64, b: i64) struct { quotient: i128, remainder: i128 } {
    const remainder = @mod(@as(i128, a), @as(i128, @abs(b)));
    return .{ .quotient = @divExact(@as(i128, a) - remainder, @as(i128, b)), .remainder = remainder };
}

test "Quotient and Mod are Euclidean on every pair in -20..20 and fail on a zero divisor" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    var a: i64 = -20;
    while (a <= 20) : (a += 1) {
        source.clearRetainingCapacity();
        try source.appendSlice(std.testing.allocator, "Q(A:i64,B:i64)<computes>:i64=Attempt(Quotient[A,B],777)\nM(A:i64,B:i64)<computes>:i64=Attempt(Mod[A,B],777)\n");
        var b: i64 = -20;
        while (b <= 20) : (b += 1) try source.print(std.testing.allocator, "Q{d}:i64=Q({d},{d})\nM{d}:i64=M({d},{d})\n", .{ b + 20, a, b, b + 20, a, b });
        const x = try h.execute(source.items);
        b = -20;
        while (b <= 20) : (b += 1) {
            var name: [8]u8 = undefined;
            const quotient = x.get(try std.fmt.bufPrint(&name, "Q{d}", .{b + 20})).?.integer;
            const remainder = x.get(try std.fmt.bufPrint(&name, "M{d}", .{b + 20})).?.integer;
            if (b == 0) {
                try std.testing.expectEqual(@as(i64, 777), quotient);
                try std.testing.expectEqual(@as(i64, 777), remainder);
                continue;
            }
            const expected = euclid(a, b);
            try std.testing.expectEqual(expected.quotient, @as(i128, quotient));
            try std.testing.expectEqual(expected.remainder, @as(i128, remainder));
            // The Book's own statement of the rule, checked on the results themselves.
            try std.testing.expect(remainder >= 0 and remainder < @abs(b));
            try std.testing.expectEqual(a, quotient * b + remainder);
            // Rounded down for a positive divisor and up for a negative one.
            try std.testing.expectEqual(if (b > 0) @divFloor(a, b) else -@divFloor(a, -b), quotient);
        }
    }
}

test "Quotient and Mod at the i64 extremes agree with the model and overflow only for the least value over minus one" {
    const h = try harness.create();
    defer scratch.release(h);
    const edges = [_]i64{ min, min + 1, min / 2, -3, -2, -1, 0, 1, 2, 3, max / 2, max - 1, max };
    for (edges) |a| for (edges) |b| for ([_]types.BinaryOp{ .quotient, .modulo }) |op| {
        const nodes = [_]types.Node{ integer(a), integer(b), divide(op, 0, 1) };
        const result = try h.run(program(&nodes), 64);
        if (b == 0) {
            // Unguarded, as only forged code is: fatal, like the existing `/`.
            try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, result.failed.code);
            continue;
        }
        if (a == min and b == -1) {
            try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
            continue;
        }
        const expected = euclid(a, b);
        try std.testing.expectEqual(if (op == .quotient) expected.quotient else expected.remainder, @as(i128, result.ok.values[2].integer));
    };
    // The same corner through source: checked overflow is fatal, and `Attempt` does not catch it.
    for ([_][]const u8{ "Least:i64=-9223372036854775807-1;A:i64=Attempt(Quotient[Least,-1],0)", "Least:i64=-9223372036854775807-1;A:i64=Attempt(Mod[Least,-1],0)" }) |source| {
        const result = try h.run(try h.compile(source), 4096);
        try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
    }
    const x = try h.execute("Least:i64=-9223372036854775807-1;A:i64=Attempt(Quotient[Least,1],0);B:i64=Attempt(Mod[Least,2],5);C:i64=Attempt(Mod[Least,Least],5);D:i64=Attempt(Quotient[9223372036854775807,Least],5);E:i64=Attempt(Mod[9223372036854775807,Least],5)");
    try std.testing.expectEqual(min, x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 0), x.get("D").?.integer);
    try std.testing.expectEqual(max, x.get("E").?.integer);
}

test "the existing truncating division keeps its results beside the Euclidean forms" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("A:i64=-7/2;B:i64=7/-2;C:i64=Attempt(Quotient[-7,2],0);D:i64=Attempt(Quotient[7,-2],0);E:i64=Attempt(Mod[-7,2],9);F:i64=Attempt(Mod[7,-2],9)");
    try std.testing.expectEqual(@as(i64, -3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -3), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, -4), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -3), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("F").?.integer);
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, (try h.run(try h.compile("A:i64=Attempt(1/0,7)"), 4096)).failed.code);
}

test "the Book's rational examples hold" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\Reduced:logic=R(5,2)==R(10,4) and R(5,2)==R(15,6) and R(10,4)==R(15,6)
        \\Signs:logic=R(1,-3)==R(-1,3) and R(-1,-3)==R(1,3)
        \\Whole:logic=R(2,1)==MakeRationalFromInt(2) and R(4,2)==MakeRationalFromInt(2) and R(9,3)==MakeRationalFromInt(3)
        \\F1:i64=Floor(R(5,2))
        \\C1:i64=Ceil(R(5,2))
        \\F2:i64=Floor(R(-5,2))
        \\C2:i64=Ceil(R(-5,2))
        \\F3:i64=Floor(R(5,-2))
        \\C3:i64=Ceil(R(5,-2))
        \\F4:i64=Floor(R(-5,-2))
        \\C4:i64=Ceil(R(-5,-2))
        \\F5:i64=Floor(MakeRationalFromInt(-5))
        \\C5:i64=Ceil(MakeRationalFromInt(-5))
        \\F6:i64=Floor(R(10,2))
        \\Half(X:i64)<computes><decides>:rational=Rational[X,2]
        \\H:i64=Attempt(Floor(Half[7])+Ceil(Half[7]),0)
        \\Share(Total:i64,N:i64)<computes><decides>:i64=Floor(Rational[Total,N])
        \\S:i64=Attempt(Share[225,100],-1)
        \\None:i64=Attempt(Share[225,0],-1)
        \\Zero:rational=R(0,-7)
    );
    for ([_][]const u8{ "Reduced", "Signs", "Whole" }) |name| try std.testing.expect(x.get(name).?.boolean);
    const Expected = struct { []const u8, i64 };
    for ([_]Expected{ .{ "F1", 2 }, .{ "C1", 3 }, .{ "F2", -3 }, .{ "C2", -2 }, .{ "F3", -3 }, .{ "C3", -2 }, .{ "F4", 2 }, .{ "C4", 3 }, .{ "F5", -5 }, .{ "C5", -5 }, .{ "F6", 5 }, .{ "H", 7 }, .{ "S", 2 }, .{ "None", -1 } }) |row| {
        try std.testing.expectEqual(row[1], x.get(row[0]).?.integer);
    }
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 0, .denominator = 1 }, x.get("Zero").?.rational);
}

fn smooth(random: std.Random) i64 {
    // Products of small primes: large terms that still share factors and cancel.
    var value: i64 = 1;
    for ([_]i64{ 2, 3, 5, 7 }) |prime| {
        var times = random.uintLessThan(u8, 24);
        while (times != 0 and value <= @divTrunc(max, prime)) : (times -= 1) value *= prime;
    }
    return if (random.boolean()) value else -value;
}
fn term(random: std.Random) i64 {
    return switch (random.uintLessThan(u8, 20)) {
        0...7 => random.intRangeAtMost(i64, -30, 30),
        8...10 => random.intRangeAtMost(i64, -1_000_000, 1_000_000),
        11, 12 => random.intRangeAtMost(i64, -(1 << 33), 1 << 33),
        13, 14 => random.int(i64),
        15, 16, 17 => smooth(random),
        else => ([_]i64{ min, min + 1, max, max - 1, 1 << 62, -(1 << 62), (1 << 53) + 1, 1, -1, 0 })[random.uintLessThan(usize, 10)],
    };
}

test "random rationals agree with an exact 128-bit model in every operation and overflow exactly when the answer does not fit" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x7a70);
    const random = prng.random();
    var overflows: usize = 0;
    var values: usize = 0;
    var zeros: usize = 0;
    for (0..4000) |_| {
        const terms = [4]i64{ term(random), term(random), term(random), term(random) };
        var nodes: [32]types.Node = undefined;
        nodes[0..6].* = .{ integer(terms[0]), integer(terms[1]), rational(.make, 0, 1), integer(terms[2]), integer(terms[3]), rational(.make, 3, 4) };
        // A fraction that cannot be built stops the run where it is made.
        var made: [2]types.Rational = undefined;
        var buildable = true;
        for (0..2) |side| {
            const top = terms[2 * side];
            const bottom = terms[2 * side + 1];
            const expected: ?Exact = if (bottom == 0) null else lowest(top, bottom);
            if (expected != null and expected.? == .value) {
                made[side] = expected.?.value;
                continue;
            }
            const alone = [_]types.Node{ integer(top), integer(bottom), rational(.make, 0, 1) };
            const result = try h.run(program(&alone), 64);
            try std.testing.expectEqual(if (expected == null) types.Diagnostic.Code.division_by_zero else types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
            if (expected == null) zeros += 1 else overflows += 1;
            buildable = false;
        }
        if (!buildable) continue;
        var count: usize = 6;
        var expected: [32]?types.Value = @splat(null);
        expected[2] = .{ .rational = made[0] };
        expected[5] = .{ .rational = made[1] };
        for ([_]types.RationalOp{ .add, .subtract, .multiply, .negate }) |op| {
            const node = if (op == .negate) rational(op, 2, 2) else rational(op, 2, 5);
            switch (modelBinary(op, made[0], made[1])) {
                .value => |value| {
                    nodes[count] = node;
                    expected[count] = .{ .rational = value };
                    count += 1;
                },
                .overflow => {
                    // Alone at the end of its own program: the run must stop there.
                    var failing: [7]types.Node = undefined;
                    failing[0..6].* = nodes[0..6].*;
                    failing[6] = node;
                    const result = try h.run(program(&failing), 64);
                    try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
                    overflows += 1;
                },
            }
        }
        const a = made[0];
        const b = made[1];
        nodes[count] = rational(.floor, 2, 2);
        expected[count] = .{ .integer = @intCast(@divFloor(@as(i128, a.numerator), a.denominator)) };
        nodes[count + 1] = rational(.ceil, 5, 5);
        expected[count + 1] = .{ .integer = @intCast(-@divFloor(-@as(i128, b.numerator), b.denominator)) };
        count += 2;
        const left = @as(i128, a.numerator) * b.denominator;
        const right = @as(i128, b.numerator) * a.denominator;
        for ([_]types.CompareOp{ .equal, .unequal, .less, .less_equal, .greater, .greater_equal }) |op| {
            nodes[count] = compare(op, 2, 5);
            expected[count] = .{ .boolean = switch (op) {
                .equal => left == right,
                .unequal => left != right,
                .less => left < right,
                .less_equal => left <= right,
                .greater => left > right,
                .greater_equal => left >= right,
            } };
            count += 1;
        }
        const float_at = count;
        nodes[count] = rational(.to_float, 2, 2);
        nodes[count + 1] = rational(.to_float, 5, 5);
        count += 2;
        const result = try h.run(program(nodes[0..count]), 64);
        const got = result.ok.values;
        for (expected[0..count], got[0..count]) |want, actual| if (want) |value| try std.testing.expectEqualDeep(value, actual);
        for (got[0..count]) |value| if (value == .rational) {
            values += 1;
            try std.testing.expect(value.rational.normalised());
        };
        // Equal fractions are stored identically, which is what makes them one map key.
        try std.testing.expectEqual(left == right, std.meta.eql(got[2].rational, got[5].rational));
        try std.testing.expect(nearestFloat(a, got[float_at].floating));
        try std.testing.expect(nearestFloat(b, got[float_at + 1].floating));
    }
    // The distribution reaches every outcome often enough to mean something.
    try std.testing.expect(overflows > 200 and zeros > 50 and values > 10_000);
}

test "rational to float is correctly rounded at ties, at the extremes and for long expansions" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { i64, i64, f64 };
    for ([_]Case{
        .{ 1, 2, 0.5 },
        .{ -1, 4, -0.25 },
        .{ 0, 5, 0.0 },
        .{ 1, 3, 0.3333333333333333 },
        .{ 2, 3, 0.6666666666666666 },
        .{ 1, 10, 0.1 },
        .{ max, 1, 9223372036854775808.0 },
        .{ min, 1, -9223372036854775808.0 },
        .{ 1, max, 1.0842021724855044e-19 },
        // Halfway between two floats: the even one, down and then up.
        .{ (1 << 53) + 1, 1, 9007199254740992.0 },
        .{ (1 << 53) + 3, 1, 9007199254740996.0 },
        // (2^53 + 1) / 2 is 2^52 + 1/2, halfway between 2^52 and 2^52 + 1: the even 2^52,
        // whichever way the fraction was spelled.
        .{ (1 << 54) + 2, 4, 4503599627370496.0 },
        .{ (1 << 53) + 1, 2, 4503599627370496.0 },
        .{ (1 << 53) + 3, 2, 4503599627370498.0 },
        .{ max, max - 1, 1.0 },
        .{ max - 1, max, 1.0 },
    }) |case| {
        const nodes = [_]types.Node{ integer(case[0]), integer(case[1]), rational(.make, 0, 1), rational(.to_float, 2, 2) };
        const result = try h.run(program(&nodes), 64);
        const actual = result.ok.values[3].floating;
        try std.testing.expectEqual(@as(u64, @bitCast(case[2])), @as(u64, @bitCast(actual)));
        try std.testing.expect(nearestFloat(result.ok.values[2].rational, actual));
    }
    // Near-ties over large odd denominators, where one rounding too many would show.
    var prng = std.Random.DefaultPrng.init(0xf10a7);
    const random = prng.random();
    for (0..3000) |_| {
        const bottom = random.intRangeAtMost(i64, 1, max) | 1;
        const mantissa = random.intRangeAtMost(i64, 1 << 52, (1 << 53) - 1);
        // About (mantissa + 1/2) / 2^k of the denominator: next to a rounding boundary.
        const shift = random.uintLessThan(u7, 60);
        const top128 = ((@as(i128, mantissa) * 2 + 1) * bottom) >> (shift + 1);
        const top: i64 = @intCast(@min(@max(top128 + random.intRangeAtMost(i64, -2, 2), 1), max));
        const nodes = [_]types.Node{ integer(if (random.boolean()) top else -top), integer(bottom), rational(.make, 0, 1), rational(.to_float, 2, 2) };
        const result = try h.run(program(&nodes), 64);
        try std.testing.expect(nearestFloat(result.ok.values[2].rational, result.ok.values[3].floating));
    }
    const x = try h.execute("A:float=ToFloat(Attempt(Rational[1,3],MakeRationalFromInt(0)))+ToFloat(1);B:float=ToFloat(MakeRationalFromInt(-7))");
    try std.testing.expectEqual(@as(f64, 1.3333333333333333), x.get("A").?.floating);
    try std.testing.expectEqual(@as(f64, -7.0), x.get("B").?.floating);
}

test "rational overflow corners are fatal in both machines and avoidable overflow does not happen" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "Least:i64=-9223372036854775807-1;Most:i64=9223372036854775807;R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0));";
    var buffer: [1024]u8 = undefined;
    for ([_][]const u8{
        // The denominator must be positive, and the least value has no negation.
        "X:rational=R(Least,-1)",
        "X:rational=R(1,Least)",
        "X:rational=R(Most,Least)",
        "X:rational=-MakeRationalFromInt(Least)",
        "X:rational=MakeRationalFromInt(Most)+MakeRationalFromInt(1)",
        "X:rational=MakeRationalFromInt(Least)-MakeRationalFromInt(1)",
        "X:rational=MakeRationalFromInt(Most)*MakeRationalFromInt(2)",
        "X:rational=R(1,Most)*R(1,2)",
        "X:rational=R(1,Most)+R(1,Most-1)",
        "X:rational=R(1,Most)-R(1,2)",
        // Fatal means fatal: no failure context turns it into a failure.
        "X:rational=Attempt(Rational[Least,-1],MakeRationalFromInt(0))",
        "F()<computes><decides>:rational=Rational[1,Least];X:rational=Attempt(F[],MakeRationalFromInt(0))",
    }) |tail| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, tail });
        const result = try h.run(try h.compile(source), 4096);
        if (result != .failed) std.debug.print("no overflow: {s}\n", .{tail});
        try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, result.failed.code);
    }
    const Fits = struct { []const u8, i64, i64 };
    for ([_]Fits{
        .{ "R(Least,Least)", 1, 1 },
        .{ "R(Least,2)", -(1 << 62), 1 },
        .{ "R(2,Least)", -1, 1 << 62 },
        .{ "R(Least,1)", min, 1 },
        .{ "R(Most,Most)", 1, 1 },
        .{ "R(Least+1,-1)", max, 1 },
        .{ "-MakeRationalFromInt(Most)", -max, 1 },
        // Products and sums whose plain cross products leave 64 bits but whose answers do not.
        .{ "R(Most,3)*R(3,Most)", 1, 1 },
        .{ "R(Most,2)*R(2,1)", max, 1 },
        .{ "R(Least,3)*R(3,2)", -(1 << 62), 1 },
        .{ "R(1,3298534883328)+R(1,5497558138880)", 1, 2061584302080 },
        .{ "R(Most,2)+R(Most,2)", max, 1 },
        .{ "R(Most,2)-R(Most,2)", 0, 1 },
        .{ "R(1,Most)-R(1,Most)", 0, 1 },
        .{ "R(Least,1)+R(1,1)", min + 1, 1 },
        .{ "R(4611686018427387904,3)-R(4611686018427387904,3)+R(4611686018427387904,3)*R(3,2)", 1 << 61, 1 },
    }) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}X:rational={s}", .{ prelude, case[0] });
        const x = h.execute(source) catch |err| {
            std.debug.print("avoidable overflow: {s}\n", .{case[0]});
            return err;
        };
        try std.testing.expectEqualDeep(types.Rational{ .numerator = case[1], .denominator = case[2] }, x.get("X").?.rational);
    }
}

test "rationals are map keys and parts of structural equality" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0))
        \\M:map(rational,i64)=map{R(1,2)=>1,R(1,3)=>2}
        \\A:i64=Or(Lookup(M,R(2,4)),-1)
        \\B:i64=Or(Lookup(M,R(1,2)+R(1,3)),-1)
        \\C:i64=Or(Lookup(M,R(-7,-21)),-1)
        \\M2:=WithIndex[M,R(-3,-9),7]
        \\D:i64=M2.Length*100+Or(Lookup(M2,R(1,3)),-1)
        \\M3:=Attempt(Without[M,R(3,6)],M)
        \\E:i64=M3.Length*100+Or(Lookup(M3,R(1,3)),-1)
        \\Gone:i64=Attempt(Without[M,R(1,4)].Length,-1)
        \\Pt:=struct{X:rational,Y:rational}
        \\T1:logic=tuple{R(1,2),1}==tuple{R(5,10),1}
        \\T2:logic=array{R(1,2),R(1,3)}==array{R(2,4),R(3,9)}
        \\T3:logic=option{R(1,2)}==option{R(1,3)}
        \\T4:logic=Pt{X:=R(1,2),Y:=-R(1,3)}==Pt{X:=R(4,8),Y:=R(1,-3)}
        \\T5:logic=map{R(1,2)=>"a"}==map{R(2,4)=>"a"}
        \\T6:logic=R(1,2)!=R(2,4)
        \\Deep:map(tuple(rational,string),i64)=map{tuple{R(1,2),"a"}=>5}
        \\F:i64=Or(Lookup(Deep,tuple{R(3,6),"a"}),-1)
        \\Keys:[]rational=For(K->V:M,K)
    );
    try std.testing.expectEqual(@as(i64, 1), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 207), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 102), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Gone").?.integer);
    for ([_][]const u8{ "T1", "T2", "T4", "T5" }) |name| try std.testing.expect(x.get(name).?.boolean);
    for ([_][]const u8{ "T3", "T6" }) |name| try std.testing.expect(!x.get(name).?.boolean);
    try std.testing.expectEqual(@as(i64, 5), x.get("F").?.integer);
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("Keys").?).?.len);
    // Two spellings of one fraction are one key: the literal is rejected as any duplicate is.
    const duplicate = try h.run(try h.compile("R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0));M:map(rational,i64)=map{R(1,2)=>1,R(-2,-4)=>2}"), 4096);
    try std.testing.expectEqual(types.Diagnostic.Code.duplicate_map_key, duplicate.failed.code);
}

test "failed divisions roll back writes and leave no trace beyond the failure" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Cell:i64=0
        \\var Kept:rational=MakeRationalFromInt(9)
        \\TryQ(B:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+1;Quotient[7,B]},-Cell-100)
        \\TryM(B:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+10;Mod[7,B]},-Cell-100)
        \\TryR(B:i64)<transacts>:i64=Attempt(Block{set Cell=Cell+100;set Kept=Kept+Kept;Floor(Rational[7,B])},-Cell-100)
        \\A:i64=TryQ(2)
        \\B:i64=TryQ(0)
        \\C:i64=TryM(4)
        \\D:i64=TryM(0)
        \\E:i64=TryR(2)
        \\F:i64=TryR(0)
        \\Seen:i64=Cell
        \\Value:rational=Kept
        \\Pick(X:i64)<computes>:i64=If(Q:=Quotient[7,X],Q>-100,Q,-1)
        \\G:i64=Pick(2)*10+Pick(0)
        \\Div(N:i64,M:i64)<computes><decides>:rational=Rational[N,M]
        \\H:rational=Attempt(Div[1,2]+Div[1,0],MakeRationalFromInt(5))
        \\Chain(K:i64)<computes><decides>:i64=Quotient[100,K]+Mod[100,K]
        \\I:i64=Attempt(Chain[7],-1)+Attempt(Chain[0],-1)
    );
    try std.testing.expectEqual(@as(i64, 3), x.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, -101), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, -111), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 3), x.get("E").?.integer);
    try std.testing.expectEqual(@as(i64, -211), x.get("F").?.integer);
    try std.testing.expectEqual(@as(i64, 111), x.get("Seen").?.integer);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 18, .denominator = 1 }, x.get("Value").?.rational);
    try std.testing.expectEqual(@as(i64, 29), x.get("G").?.integer);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 5, .denominator = 1 }, x.get("H").?.rational);
    try std.testing.expectEqual(@as(i64, 15), x.get("I").?.integer);
    // Each failed division is one recorded failure of its `demand`, as `Require` records it.
    try std.testing.expect(x.failure_count >= 5);
    for (x.failures) |failure| try std.testing.expectEqual(types.Diagnostic.Code.requirement_failed, failure.code);
}

test "rationals pass through cells, instances, generics, closures and loops" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\H:rational=Attempt(Rational[1,2],MakeRationalFromInt(0))
        \\T:rational=Attempt(Rational[1,3],MakeRationalFromInt(0))
        \\var Cell:rational=H
        \\Bump()<transacts>:rational=Block{set Cell+=T;set Cell*=H;set Cell-=T;Cell}
        \\After:rational=Bump()
        \\Id[V:type](X:V)<computes>:V{X}
        \\I:rational=Id[rational](H)
        \\Box:=class{var R:rational}
        \\Use()<transacts>:rational=Block{B:=Box{R:=H};set B.R=B.R+B.R;B.R}
        \\U:rational=Use()
        \\Frac:=rational
        \\Z:Frac=H-H
        \\Order:logic=H>=T and T<=H and H>T and not (H<T) and +H==H
        \\Step(S:tuple(rational,i64))<computes>:tuple(rational,i64)=tuple{S(0)+Attempt(Rational[1,S(1)*(S(1)+1)],H),S(1)+1}
        \\Sum:rational=Iterate(Step,40,tuple{MakeRationalFromInt(0),1})(0)
        \\Scale:=Fn(X:rational){X*T}
        \\Scaled:rational=Scale(H)
        \\Opt:option(rational)=option{H}
        \\Picked:rational=Or(Opt,T)
        \\Halves:[]rational=For(N:1..4,Attempt(Rational[N,2],H))
        \\Count:i64=Halves.Length
        \\Third:rational=Attempt(Halves[2],T)
    );
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 1, .denominator = 12 }, x.get("After").?.rational);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 1, .denominator = 2 }, x.get("I").?.rational);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 1, .denominator = 1 }, x.get("U").?.rational);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 0, .denominator = 1 }, x.get("Z").?.rational);
    try std.testing.expect(x.get("Order").?.boolean);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 40, .denominator = 41 }, x.get("Sum").?.rational);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 1, .denominator = 6 }, x.get("Scaled").?.rational);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 1, .denominator = 2 }, x.get("Picked").?.rational);
    try std.testing.expectEqual(@as(i64, 4), x.get("Count").?.integer);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = 3, .denominator = 2 }, x.get("Third").?.rational);
}

test "division forms need a failure context, exact operand types and their own bracket shapes" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, types.Diagnostic.Code };
    const r = "R:rational=MakeRationalFromInt(3);";
    var buffer: [512]u8 = undefined;
    for ([_]Case{
        .{ "A:i64=Quotient[7,2]", .failure_context_required },
        .{ "A:i64=Mod[7,2]", .failure_context_required },
        .{ "A:rational=Rational[7,2]", .failure_context_required },
        .{ "F(X:i64)<computes>:i64=Quotient[X,2]", .failure_context_required },
        .{ "A:i64=Attempt(Quotient(7,2),0)", .expected_call },
        .{ "A:i64=Attempt(Mod(7,2),0)", .expected_call },
        .{ "A:rational=MakeRationalFromInt[7]", .expected_call },
        .{ "A:i64=Attempt(Quotient[7],0)", .argument_count },
        .{ "A:i64=Attempt(Mod[7,2,1],0)", .argument_count },
        .{ "A:rational=Attempt(Rational[7],MakeRationalFromInt(0))", .argument_count },
        .{ "A:rational=MakeRationalFromInt(1,2)", .argument_count },
        .{ "A:i64=Attempt(Quotient[7.0,2],0)", .type_mismatch },
        .{ "A:i64=Attempt(Mod[7,2.0],0)", .type_mismatch },
        .{ "A:rational=Attempt(Rational[1.0,2],MakeRationalFromInt(0))", .type_mismatch },
        .{ "A:rational=MakeRationalFromInt(1.5)", .type_mismatch },
        .{ "A:rational=Attempt(Rational[R,R],R)", .type_mismatch },
        // No implicit conversion in either direction, as between `i64` and `float`.
        .{ "A:rational=7", .type_mismatch },
        .{ "A:i64=R", .type_mismatch },
        .{ "A:rational=R+1", .type_mismatch },
        .{ "A:rational=1*R", .type_mismatch },
        .{ "A:logic=R==3", .type_mismatch },
        .{ "A:logic=R<3", .type_mismatch },
        .{ "A:rational=R/R", .type_mismatch },
        .{ "var V:rational=R;F()<transacts>:rational=Block{set V/=R;V}", .type_mismatch },
        // `Floor` and `Ceil` are total on a rational in parentheses and failable on a float in brackets.
        .{ "A:i64=Attempt(Floor[R],0)", .type_mismatch },
        .{ "A:i64=Attempt(Ceil[R],0)", .type_mismatch },
        .{ "A:i64=Floor(1.5)", .type_mismatch },
        .{ "A:i64=Ceil(7)", .type_mismatch },
        .{ "A:i64=Attempt(Round[R],0)", .type_mismatch },
        .{ "A:i64=Attempt(Int[R],0)", .type_mismatch },
        .{ "A:string=ToString(R)", .type_mismatch },
        .{ "A:string=\"{R}\"", .type_mismatch },
        .{ "A:i64=R.Numerator", .type_mismatch },
        .{ "A:rational=rational{}", .unknown_name },
    }) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ r, case[0] });
        const result = h.front.compile(source);
        if (result == .ok) std.debug.print("unexpected rational admission: {s}\n", .{case[0]});
        try std.testing.expect(result == .failed);
        if (result.failed.code != case[1]) std.debug.print("rational diagnostic for {s}: {s}\n", .{ case[0], result.failed.message() });
        try std.testing.expectEqual(case[1], result.failed.code);
    }
}

test "programs that already use the new names keep their own meaning" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try h.execute("Mod(A:i64,B:i64)<computes>:i64=A-B;Quotient(A:i64)<computes>:i64=A*2;X:i64=Mod(7,2)+Quotient(10)");
    try std.testing.expectEqual(@as(i64, 25), x.get("X").?.integer);
    x = try h.execute("Rational(N:i64)<computes><decides>:i64=Block{Require[N>0];N};MakeRationalFromInt(N:i64)<computes>:i64=N+1;X:i64=Attempt(Rational[4],-1)+Attempt(Rational[-4],-1)+MakeRationalFromInt(1)");
    try std.testing.expectEqual(@as(i64, 5), x.get("X").?.integer);
    x = try h.execute("rational:=struct{N:i64=1};V:rational=rational{};X:i64=V.N");
    try std.testing.expectEqual(@as(i64, 1), x.get("X").?.integer);
    x = try h.execute("rational:=i64;V:rational=5;X:i64=V+1");
    try std.testing.expectEqual(@as(i64, 6), x.get("X").?.integer);
    x = try h.execute("rational:i64=3;Mod:i64=4;Y:=rational;X:i64=Y+Mod");
    try std.testing.expectEqual(@as(i64, 7), x.get("X").?.integer);
    x = try h.execute("Quotient:function(tuple(i64),i64)=Fn(N:i64){N+1};F(Mod:i64)<computes>:i64=Mod*Quotient(Mod);X:i64=F(3)");
    try std.testing.expectEqual(@as(i64, 12), x.get("X").?.integer);
    x = try h.execute("Mod(N:i64)<computes>:i64=If(N<5,N,Mod(N-5));X:i64=Mod(13)");
    try std.testing.expectEqual(@as(i64, 3), x.get("X").?.integer);
    x = try h.execute("Rational:=class{N:i64};Mod:=class<abstract>{};V:Rational=Rational{N:=4};X:i64=Attempt(Rational[V].N,-1)");
    try std.testing.expectEqual(@as(i64, 4), x.get("X").?.integer);
    // `Name := rational...` stays a value wherever the program gave the name a meaning.
    x = try h.execute("rational[T:type](X:T)<computes>:T{X};F:=rational[i64];X:i64=F(1)");
    try std.testing.expectEqual(@as(i64, 1), x.get("X").?.integer);
    x = try h.execute("rational(N:i64)<computes>:i64=N+1;G:=rational;X:i64=G(4)");
    try std.testing.expectEqual(@as(i64, 5), x.get("X").?.integer);
    // Where nothing of the name is declared, each builtin is itself and the alias names the type.
    x = try h.execute("Frac:=rational;V:Frac=MakeRationalFromInt(2);X:i64=Attempt(Mod[Quotient[17,5],2],-1)+Floor(V)");
    try std.testing.expectEqual(@as(i64, 3), x.get("X").?.integer);
}

test "reports print a rational as an exact pair and inspection names the type" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("R(A:i64,B:i64)<computes>:rational=Attempt(Rational[A,B],MakeRationalFromInt(0));Pt<public>:=struct{X:rational,Y:rational};A<public>:rational=R(-10,4);B<public>:[]rational=array{R(1,3),MakeRationalFromInt(7)};C<public>:Pt=Pt{X:=R(0,5),Y:=R(9223372036854775807,2)};D<public>:option(rational)=option{R(2,-6)};E<public>:float=ToFloat(A)");
    const x = (try h.run(p, 4096)).ok;
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, true, .{});
    try std.testing.expectEqualStrings("{\"A\":{\"$rational\":[-5,2]},\"B\":[{\"$rational\":[1,3]},{\"$rational\":[7,1]}],\"C\":{\"X\":{\"$rational\":[0,1]},\"Y\":{\"$rational\":[9223372036854775807,2]}},\"D\":[{\"$rational\":[-1,3]}],\"E\":-2.5}\n", out.buffered());
    // The report is valid JSON whose numbers are the two terms.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const pair = parsed.value.object.get("A").?.object.get("$rational").?.array;
    try std.testing.expectEqual(@as(i64, -5), pair.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), pair.items[1].integer);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    const text = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(text);
    var inspected = std.Io.Writer.fixed(text);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&inspected, p));
    try std.testing.expect(std.mem.indexOf(u8, inspected.buffered(), "{\"id\":4,\"kind\":\"rational\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspected.buffered(), "{\"rational\":{\"op\":\"make\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspected.buffered(), "{\"rational\":{\"op\":\"to_float\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, inspected.buffered(), "\"kind\":\"rational\""));
}

test "a report rejects forged rational values that no machine could have stored" {
    const h = try harness.create();
    defer scratch.release(h);
    const nodes = [_]types.Node{ integer(6), integer(4), rational(.make, 0, 1), rational(.floor, 2, 2) };
    const p = program(&nodes);
    const limits: reporting.Limits = .{};
    for ([_]types.Value{
        .{ .rational = .{ .numerator = 6, .denominator = 4 } },
        .{ .rational = .{ .numerator = 3, .denominator = 0 } },
        .{ .rational = .{ .numerator = 3, .denominator = -2 } },
        .{ .rational = .{ .numerator = -3, .denominator = -2 } },
        .{ .rational = .{ .numerator = 0, .denominator = 2 } },
        .{ .rational = .{ .numerator = min, .denominator = min } },
        .{ .integer = 3 },
        .{ .floating = 1.5 },
    }) |forged| {
        const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 64).ok;
        _ = try reporting.validate(reference, false, limits);
        try std.testing.expectEqualDeep(types.Rational{ .numerator = 3, .denominator = 2 }, reference.values[2].rational);
        h.values[2] = forged;
        try std.testing.expectError(error.InvalidExecution, reporting.validate(reference, false, limits));
    }
    // And a rational where the program computes an integer.
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 64).ok;
    h.values[3] = .{ .rational = .{ .numerator = 1, .denominator = 1 } };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(reference, false, limits));
}

test "forged unguarded divisions stop both machines at the division" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { []const u8, enum { rational, quotient, modulo } };
    for ([_]Case{
        .{ "Z:i64=0;V<public>:rational=Attempt(Rational[7,Z],MakeRationalFromInt(1))", .rational },
        .{ "Z:i64=0;V<public>:i64=Attempt(Quotient[7,Z],1)", .quotient },
        .{ "Z:i64=0;V<public>:i64=Attempt(Mod[7,Z],1)", .modulo },
        .{ "F(Z:i64)<computes>:i64=Attempt(Mod[7,Z],1);V<public>:i64=F(0)", .modulo },
    }) |case| {
        const p = try h.compile(case[0]);
        // Honest code fails softly and takes the fallback.
        const honest = try h.run(p, 4096);
        try std.testing.expect(honest == .ok);
        const body = p.function_nodes.len != 0;
        const count = if (body) p.function_nodes.len else p.nodes.len;
        var target: ?usize = null;
        var demand: ?usize = null;
        for (0..count) |index| {
            const node = if (body) p.function_nodes[index].node else p.nodes[index];
            const found = switch (case[1]) {
                .rational => node.kind == .rational and node.kind.rational.op == .make and node.span.start != node.span.end and index != 0 and demand != null,
                .quotient => node.kind == .binary and node.kind.binary.op == .quotient,
                .modulo => node.kind == .binary and node.kind.binary.op == .modulo,
            };
            if (found and target == null) target = index;
            if (node.kind == .demand and target == null) demand = index;
        }
        try std.testing.expect(target != null and demand != null);
        // Keep the `demand` and its accounting, but make what it demands always true.
        var forged = p;
        var span: types.Span = undefined;
        if (body) {
            const nodes = try std.testing.allocator.dupe(types.FunctionNode, p.function_nodes);
            defer std.testing.allocator.free(nodes);
            nodes[nodes[demand.?].node.kind.demand].node.kind = .{ .boolean = true };
            span = nodes[target.?].node.span;
            forged.function_nodes = nodes;
            const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
            const actual = h.runtime.evaluate(forged, 4096);
            try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, reference.failed.code);
            try std.testing.expectEqualDeep(reference.failed, actual.failed);
            continue;
        }
        const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
        defer std.testing.allocator.free(nodes);
        nodes[nodes[demand.?].kind.demand].kind = .{ .boolean = true };
        span = nodes[target.?].span;
        forged.nodes = nodes;
        const reference = evaluator.evaluateWithRuntimeStorage(forged, &h.values, &h.members, &h.control, &h.state, &h.frames, 4096);
        const actual = h.runtime.evaluate(forged, 4096);
        try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, reference.failed.code);
        try std.testing.expectEqualDeep(reference.failed, actual.failed);
        try std.testing.expectEqualDeep(span, reference.failed.span);
    }
}

test "forged rational nodes, types and catalogues are rejected by both admissions" {
    const h = try harness.create();
    defer scratch.release(h);
    const float: types.Node = .{ .span = origin, .value_type = .float, .kind = .{ .floating = 1.5 } };
    const good = [_]types.Node{ integer(1), integer(2), rational(.make, 0, 1), rational(.make, 1, 0), rational(.add, 2, 3), rational(.negate, 4, 4), rational(.floor, 5, 5), rational(.ceil, 5, 5), rational(.to_float, 5, 5), compare(.less, 2, 3), float };
    // The honest program runs, so each rejection below is caused by its one change.
    const honest = try h.run(program(&good), 64);
    try std.testing.expectEqualDeep(types.Rational{ .numerator = -5, .denominator = 2 }, honest.ok.values[5].rational);
    const Change = struct { index: usize, node: types.Node };
    const retyped = struct {
        fn of(node: types.Node, value_type: types.Type) types.Node {
            var changed = node;
            changed.value_type = value_type;
            return changed;
        }
    }.of;
    for ([_]Change{
        // A division that claims another result type, or divides something else.
        .{ .index = 2, .node = retyped(good[2], .i64) },
        .{ .index = 2, .node = retyped(good[2], .float) },
        .{ .index = 2, .node = retyped(good[2], @fromBackingInt(5)) },
        .{ .index = 3, .node = rational(.make, 2, 0) },
        .{ .index = 3, .node = rational(.make, 0, 2) },
        .{ .index = 3, .node = rational(.make, 0, 3) },
        // Arithmetic on integers, on a float, or with another result.
        .{ .index = 4, .node = rational(.add, 0, 1) },
        .{ .index = 4, .node = rational(.multiply, 2, 1) },
        .{ .index = 4, .node = rational(.subtract, 0, 3) },
        .{ .index = 4, .node = retyped(good[4], .i64) },
        .{ .index = 4, .node = retyped(good[4], .logic) },
        // Unary operations name their one operand twice and have fixed results.
        .{ .index = 5, .node = rational(.negate, 4, 3) },
        .{ .index = 5, .node = rational(.negate, 0, 0) },
        .{ .index = 6, .node = rational(.floor, 5, 4) },
        .{ .index = 6, .node = retyped(good[6], fraction) },
        .{ .index = 6, .node = retyped(good[6], .float) },
        .{ .index = 6, .node = rational(.floor, 0, 0) },
        .{ .index = 7, .node = rational(.ceil, 4, 5) },
        .{ .index = 7, .node = retyped(good[7], .logic) },
        .{ .index = 8, .node = rational(.to_float, 5, 2) },
        .{ .index = 8, .node = retyped(good[8], .i64) },
        .{ .index = 8, .node = retyped(good[8], fraction) },
        // Operands that do not exist yet.
        .{ .index = 4, .node = rational(.add, 2, 4) },
        .{ .index = 4, .node = rational(.add, 99, 3) },
        .{ .index = 6, .node = rational(.floor, 6, 6) },
        // Order between a rational and an integer, and equality across the two.
        .{ .index = 9, .node = compare(.less, 2, 0) },
        .{ .index = 9, .node = compare(.equal, 0, 2) },
        // Euclidean division is not a float operation, and nothing else builds a rational.
        .{ .index = 9, .node = .{ .span = origin, .value_type = .float, .kind = .{ .float_binary = .{ .op = .quotient, .lhs = 8, .rhs = 8 } } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = .float, .kind = .{ .float_binary = .{ .op = .modulo, .lhs = 8, .rhs = 8 } } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = fraction, .kind = .{ .aggregate = .{ .start = 0, .end = 0 } } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = fraction, .kind = .{ .enumeration = 0 } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = fraction, .kind = .{ .integer = 1 } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = fraction, .kind = .{ .negate = 2 } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = fraction, .kind = .{ .binary = .{ .op = .add, .lhs = 2, .rhs = 3 } } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = fraction, .kind = .{ .float_negate = 2 } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = .float, .kind = .{ .int_to_float = 2 } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = .i64, .kind = .{ .float_to_int = .{ .mode = .floor, .operand = 2 } } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = .i64, .kind = .{ .binary = .{ .op = .quotient, .lhs = 2, .rhs = 3 } } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = .i64, .kind = .{ .array_length = 2 } } },
        .{ .index = 9, .node = .{ .span = origin, .value_type = .logic, .kind = .{ .option_present = 2 } } },
    }, 0..) |change, ordinal| {
        var nodes = good;
        nodes[change.index] = change.node;
        harness.invalid(h, program(&nodes)) catch |err| {
            std.debug.print("forged rational change {d} was admitted\n", .{ordinal});
            return err;
        };
    }
    // The type exists once: a second definition would be a different type of the same values.
    var twice = program(&good);
    twice.definitions = &[_]types.Definition{ .rational, .rational };
    try harness.invalid(h, twice);
    // Without the definition there is no such type at all.
    var none = program(&good);
    none.definitions = &.{};
    try harness.invalid(h, none);
    // A rational is not a container, a key-less map, or a callable's shape.
    var keyed = program(&good);
    keyed.definitions = &[_]types.Definition{ .rational, .{ .map = .{ .key = fraction, .value = fraction } }, .{ .array = fraction }, .{ .option = fraction } };
    try std.testing.expect((try h.run(keyed, 64)) == .ok);
}

test "each division and rational operation costs one unit of fuel in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const nodes = [_]types.Node{ integer(7), integer(2), divide(.quotient, 0, 1), divide(.modulo, 0, 1), rational(.make, 0, 1), rational(.add, 4, 4), rational(.multiply, 5, 4), rational(.negate, 6, 6), rational(.floor, 7, 7), rational(.to_float, 7, 7), compare(.less, 7, 4) };
    const p = program(&nodes);
    for (0..nodes.len) |budget| {
        const result = try h.run(p, budget);
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
    }
    const x = (try h.run(p, nodes.len)).ok;
    try std.testing.expectEqual(@as(i64, -25), x.values[8].integer);
    try std.testing.expectEqual(@as(f64, -24.5), x.values[9].floating);
    try std.testing.expect(x.values[10].boolean);
    // Through calls and failure contexts the machines still stop at the same unit.
    const called = try h.compile("Part(A:i64,B:i64)<computes><decides>:rational=Rational[Quotient[A,B],Mod[A,B]];Sum(N:i64)<computes>:rational=Attempt(Part[N,7]+Part[N,5]*Part[N,3],MakeRationalFromInt(0));V<public>:i64=Floor(Sum(101))+Ceil(Sum(8))+Floor(Sum(7))");
    var needed: u64 = 0;
    while ((try h.run(called, needed)) == .failed) needed += 1;
    try std.testing.expect(needed > 20 and needed < 400);
    const done = (try h.run(called, needed)).ok;
    // 14/3 + 20/1 * 33/2 floors to 334 and 1/1 + 1/3 * 2/2 rounds up to 2; a zero remainder
    // fails the division that uses it, which leaves the fallback.
    try std.testing.expectEqual(@as(i64, 336), done.get("V").?.integer);
}

test "names a used module exports keep their meaning beside the new builtins" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "L:=import{\"lib.forb\"}\nusing{L}\n";
    const Case = struct { lib: []const u8, main: []const u8, expected: i64 };
    for ([_]Case{
        // `Name := rational` reads the exported value or function, not the type.
        .{ .lib = "rational<public>:i64=7", .main = head ++ "Y:=rational\nA<public>:i64=Y", .expected = 7 },
        .{ .lib = "rational<public>(N:i64)<computes>:i64=N+1", .main = head ++ "G:=rational\nA<public>:i64=G(4)", .expected = 5 },
        .{ .lib = "rational<public>:i64=7", .main = head ++ "A<public>:i64=rational+1", .expected = 8 },
        .{ .lib = "Mod<public>(A:i64,B:i64)<computes>:i64=A-B", .main = head ++ "A<public>:i64=Mod(7,2)", .expected = 5 },
        .{ .lib = "Rational<public>(N:i64)<computes><decides>:i64=Block{Require[N>0];N}", .main = head ++ "A<public>:i64=Attempt(Rational[4],-1)", .expected = 4 },
        .{ .lib = "MakeRationalFromInt<public>(N:i64)<computes>:i64=N+1", .main = head ++ "A<public>:i64=MakeRationalFromInt(4)", .expected = 5 },
        .{ .lib = "rational<public>:=struct{N:i64=1}", .main = head ++ "X:rational=rational{}\nA<public>:i64=X.N", .expected = 1 },
        // A module's own private name does not reach its importer, where the builtin stands.
        .{ .lib = "Mod(A:i64,B:i64)<computes>:i64=A-B\nV<public>:i64=Mod(9,1)", .main = "L:=import{\"lib.forb\"}\nA<public>:i64=Attempt(Mod[7,2],0)+L.V", .expected = 9 },
        .{ .lib = "R<public>:rational=MakeRationalFromInt(3)", .main = head ++ "Half:=rational\nB:Half=R*R\nA<public>:i64=Floor(B)", .expected = 9 },
    }, 0..) |case, ordinal| {
        const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = case.main }, .{ .path = "lib.forb", .source = case.lib } };
        const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
        if (bundled == .failed) std.debug.print("bundle {d} failed: {s} in {s}\n", .{ ordinal, bundled.failed.diagnostic.message(), bundled.failed.path });
        try std.testing.expect(bundled == .ok);
        try std.testing.expectEqual(case.expected, (try h.run(bundled.ok, 20_000)).ok.get("A").?.integer);
    }
}
