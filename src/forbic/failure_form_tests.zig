//! `First[...]`, `logic{...}`, `option{...}` as a failure context, optional chaining and the
//! bitwise intrinsics (RFC-0072).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const harness = @import("generic_function_tests.zig");

fn int(x: anytype, name: []const u8) !i64 {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    return value.integer;
}

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const actual = try int(x, name);
    if (actual != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, actual, expected });
    try std.testing.expectEqual(expected, actual);
}

fn expectLogic(x: anytype, name: []const u8, expected: bool) !void {
    const actual = x.get(name).?.boolean;
    if (actual != expected) std.debug.print("{s}: {}, expected {}\n", .{ name, actual, expected });
    try std.testing.expectEqual(expected, actual);
}

/// The value inside an option binding, or null when it is empty.
fn inside(x: anytype, name: []const u8) ?types.Value {
    const elements = x.elements(x.get(name).?).?;
    std.debug.assert(elements.len <= 1);
    return if (elements.len == 1) elements[0] else null;
}

fn expectIntegers(x: anytype, name: []const u8, expected: []const i64) !void {
    const elements = x.elements(x.get(name).?).?;
    if (expected.len != elements.len) std.debug.print("{s}: {d} elements, expected {d}\n", .{ name, elements.len, expected.len });
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |want, got| try std.testing.expectEqual(want, got.integer);
}

fn expectRejected(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const result = h.front.compile(source);
    if (result == .ok) std.debug.print("compiled: {s}\n", .{source});
    try std.testing.expect(result == .failed);
    if (result.failed.code != code) std.debug.print("{s}: {s}\n", .{ source, result.failed.message() });
    try std.testing.expectEqual(code, result.failed.code);
}

fn count(program: types.Program, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
    var found: usize = 0;
    for (program.nodes) |node| found += @intFromBool(node.kind == kind);
    return found;
}

// ---------------------------------------------------------------------------------------
// Bitwise intrinsics
// ---------------------------------------------------------------------------------------

test "the bitwise intrinsics give the Book's values" {
    const h = try harness.create();
    defer scratch.release(h);
    // Every line of the Book's bitwise section (04_operators.md, "Bitwise Operations").
    const x = try h.execute("Flags:i64=10\n" ++
        "A<public>:i64=BitAnd(12,10)\nB<public>:i64=BitAnd(-1,42)\nC<public>:i64=BitOr(12,10)\nD<public>:i64=BitOr(-1,42)\n" ++
        "E<public>:i64=BitXor(12,10)\nF<public>:i64=BitXor(42,42)\nG<public>:i64=BitNot(0)\nH<public>:i64=BitNot(12)\n" ++
        "I<public>:i64=BitAnd(Flags,2)\nJ<public>:i64=BitAnd(Flags,4)\nK<public>:i64=BitOr(Flags,1)\n" ++
        "L<public>:i64=BitAnd(Flags,BitNot(8))\nM<public>:i64=BitXor(Flags,2)\nN<public>:i64=BitAnd(Flags,1)\n" ++
        "O<public>:logic=BitNot(BitAnd(15,9))==BitOr(BitNot(15),BitNot(9))\n" ++
        "P<public>:logic=BitNot(BitOr(15,9))==BitAnd(BitNot(15),BitNot(9))\n");
    for ([_]struct { []const u8, i64 }{
        .{ "A", 8 },   .{ "B", 42 }, .{ "C", 14 }, .{ "D", -1 }, .{ "E", 6 }, .{ "F", 0 }, .{ "G", -1 },
        .{ "H", -13 }, .{ "I", 2 },  .{ "J", 0 },  .{ "K", 11 }, .{ "L", 2 }, .{ "M", 8 }, .{ "N", 0 },
    }) |case| try expectInt(x, case[0], case[1]);
    try expectLogic(x, "O", true);
    try expectLogic(x, "P", true);
}

test "bitwise intrinsics are total at the edges of i64 and never overflow" {
    const h = try harness.create();
    defer scratch.release(h);
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    // The least i64 has no literal; inverting the greatest one makes it.
    const x = try h.execute("Max:i64=9223372036854775807\nMin:i64=BitNot(Max)\n" ++
        "A<public>:i64=Min\nB<public>:i64=BitNot(Min)\nC<public>:i64=BitAnd(Min,Max)\nD<public>:i64=BitOr(Min,Max)\n" ++
        "E<public>:i64=BitXor(Min,Max)\nF<public>:i64=BitXor(Min,-1)\nG<public>:i64=BitAnd(Min,-1)\nH<public>:i64=BitOr(Min,1)\n" ++
        "I<public>:i64=BitXor(Min,Min)\nJ<public>:i64=BitNot(BitNot(Min))\nK<public>:i64=BitAnd(Max,Max-1)\n");
    for ([_]struct { []const u8, i64 }{
        .{ "A", min }, .{ "B", max },     .{ "C", 0 }, .{ "D", -1 },  .{ "E", -1 },      .{ "F", max },
        .{ "G", min }, .{ "H", min + 1 }, .{ "I", 0 }, .{ "J", min }, .{ "K", max - 1 },
    }) |case| try expectInt(x, case[0], case[1]);
}

test "every pair of small integers agrees with Zig, as a root operation and inside a function" {
    const h = try harness.create();
    defer scratch.release(h);
    const low: i64 = -8;
    const high: i64 = 7;
    var a = low;
    while (a <= high) : (a += 1) {
        var buffer: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Bs:[]i64=array{");
        var b = low;
        while (b <= high) : (b += 1) try out.print("{s}{d}", .{ if (b == low) "" else ",", b });
        try out.print("}}\nMix(A:i64,B:i64)<computes>:tuple(i64,i64,i64,i64)=tuple{{BitAnd(A,B),BitOr(A,B),BitXor(A,B),BitNot(B)}}\n" ++
            "Rows<public>:[]tuple(i64,i64,i64,i64)=For(B:Bs,Mix({d},B))\n" ++
            "Ands<public>:[]i64=For(B:Bs,BitAnd({d},B))\nOrs<public>:[]i64=For(B:Bs,BitOr(B,{d}))\nXors<public>:[]i64=For(B:Bs,BitXor({d},B))\nInv<public>:i64=BitNot({d})\n", .{ a, a, a, a, a });
        const x = try h.execute(out.buffered());
        const rows = x.elements(x.get("Rows").?).?;
        const ands = x.elements(x.get("Ands").?).?;
        const ors = x.elements(x.get("Ors").?).?;
        const xors = x.elements(x.get("Xors").?).?;
        try std.testing.expectEqual(@as(usize, @intCast(high - low + 1)), rows.len);
        try expectInt(x, "Inv", ~a);
        b = low;
        for (rows, ands, ors, xors) |row, and_value, or_value, xor_value| {
            const mixed = x.elements(row).?;
            try std.testing.expectEqual(a & b, mixed[0].integer);
            try std.testing.expectEqual(a | b, mixed[1].integer);
            try std.testing.expectEqual(a ^ b, mixed[2].integer);
            try std.testing.expectEqual(~b, mixed[3].integer);
            try std.testing.expectEqual(a & b, and_value.integer);
            try std.testing.expectEqual(a | b, or_value.integer);
            try std.testing.expectEqual(a ^ b, xor_value.integer);
            b += 1;
        }
    }
}

/// A random expression of the four intrinsics over named values, written as source and
/// evaluated by Zig at the same time.
const BitModel = struct {
    random: std.Random,
    names: []const []const u8,
    values: []const i64,

    fn write(self: *BitModel, out: *std.Io.Writer, depth: usize) !i64 {
        const leaf = depth == 0 or self.random.uintLessThan(u8, 5) == 0;
        if (leaf) {
            if (self.random.boolean()) {
                const index = self.random.uintLessThan(usize, self.names.len);
                try out.writeAll(self.names[index]);
                return self.values[index];
            }
            // A literal: a small number, a wide one, or all ones. The lexer has no negative
            // literal wider than the positive range, so the least i64 comes from the names.
            const value: i64 = switch (self.random.uintLessThan(u8, 4)) {
                0 => self.random.intRangeAtMost(i64, -16, 16),
                1 => self.random.int(i64) >> self.random.uintLessThan(u6, 63),
                2 => -1,
                else => @as(i64, 1) << self.random.uintLessThan(u6, 63),
            };
            if (value == std.math.minInt(i64)) {
                try out.writeAll("BitNot(9223372036854775807)");
            } else try out.print("{d}", .{value});
            return value;
        }
        switch (self.random.uintLessThan(u8, 4)) {
            0 => {
                try out.writeAll("BitNot(");
                const operand = try self.write(out, depth - 1);
                try out.writeAll(")");
                return ~operand;
            },
            else => |which| {
                try out.writeAll(switch (which) {
                    1 => "BitAnd(",
                    2 => "BitOr(",
                    else => "BitXor(",
                });
                const lhs = try self.write(out, depth - 1);
                try out.writeAll(",");
                const rhs = try self.write(out, depth - 1);
                try out.writeAll(")");
                return switch (which) {
                    1 => lhs & rhs,
                    2 => lhs | rhs,
                    else => lhs ^ rhs,
                };
            },
        }
    }
};

test "random bitwise expressions agree with Zig in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x72_b1_75);
    const random = prng.random();
    const globals = [_][]const u8{ "V0", "V1", "V2", "V3", "V4", "V5" };
    const parameters = [_][]const u8{ "A", "B", "C" };
    var negative: usize = 0;
    for (0..300) |round| {
        var buffer: [8192]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        // The edges are always among the values; the rest are random bits.
        var values: [globals.len]i64 = .{ 0, -1, std.math.maxInt(i64), std.math.minInt(i64), random.int(i64), random.int(i64) >> random.uintLessThan(u6, 63) };
        random.shuffle(i64, &values);
        for (globals, values) |name, value| {
            if (value == std.math.minInt(i64)) try out.print("{s}:i64=BitNot(9223372036854775807)\n", .{name}) else try out.print("{s}:i64={d}\n", .{ name, value });
        }
        // A function body runs as bytecode of its own in the VM and as a template in the reference.
        const arguments = [_]usize{ random.uintLessThan(usize, globals.len), random.uintLessThan(usize, globals.len), random.uintLessThan(usize, globals.len) };
        const bound = [_]i64{ values[arguments[0]], values[arguments[1]], values[arguments[2]] };
        var inner: BitModel = .{ .random = random, .names = &parameters, .values = &bound };
        try out.writeAll("F(A:i64,B:i64,C:i64)<computes>:i64=");
        const called = try inner.write(&out, 4);
        try out.print("\nR0<public>:i64=F({s},{s},{s})\n", .{ globals[arguments[0]], globals[arguments[1]], globals[arguments[2]] });
        var outer: BitModel = .{ .random = random, .names = &globals, .values = &values };
        var expected: [3]i64 = undefined;
        for (&expected, 1..) |*want, index| {
            try out.print("R{d}<public>:i64=", .{index});
            want.* = try outer.write(&out, 4);
            try out.writeAll("\n");
        }
        const x = h.execute(out.buffered()) catch |err| {
            std.debug.print("round {d}\n{s}", .{ round, out.buffered() });
            return err;
        };
        if (called != try int(x, "R0")) std.debug.print("round {d}\n{s}", .{ round, out.buffered() });
        try std.testing.expectEqual(called, try int(x, "R0"));
        for (expected, 1..) |want, index| {
            var name: [4]u8 = undefined;
            const got = try int(x, try std.fmt.bufPrint(&name, "R{d}", .{index}));
            if (want != got) std.debug.print("round {d} R{d}\n{s}", .{ round, index, out.buffered() });
            try std.testing.expectEqual(want, got);
            negative += @intFromBool(want < 0);
        }
    }
    // Both signs occur, so sign extension is exercised and not only small positive masks.
    try std.testing.expect(negative > 100 and negative < 800);
}

test "a bitwise operation is one node and one unit, as an addition is" {
    const h = try harness.create();
    defer scratch.release(h);
    const least = struct {
        fn fuel(harnessed: *harness.Harness, program: types.Program) !u64 {
            var low: u64 = 0;
            var high: u64 = 4096;
            while (low + 1 < high) {
                const middle = low + (high - low) / 2;
                const result = try harnessed.run(program, middle);
                if (result == .ok) high = middle else {
                    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
                    low = middle;
                }
            }
            return high;
        }
    }.fuel;
    // In a function, so that the run is charged per executed operation.
    const prelude = "var Cell:i64=6\nF(A:i64,B:i64)<transacts>:i64=";
    const sum = try h.compile(prelude ++ "Block{set Cell=A+B;Cell}\nR<public>:i64=F(6,3)");
    const sum_nodes = sum.function_nodes.len;
    const sum_fuel = try least(h, sum);
    inline for (.{ "BitAnd(A,B)", "BitOr(A,B)", "BitXor(A,B)" }) |operation| {
        const program = try h.compile(prelude ++ "Block{set Cell=" ++ operation ++ ";Cell}\nR<public>:i64=F(6,3)");
        try std.testing.expectEqual(sum_nodes, program.function_nodes.len);
        try std.testing.expectEqual(sum_fuel, try least(h, program));
    }
    // `BitNot(A)` is `A` exclusive-or the literal -1: the operation and its literal, as `A+1` is.
    // (A program borrows the compiler's storage until the next compile, so each is measured first.)
    const increment = try h.compile(prelude ++ "Block{set Cell=A+1;Cell}\nR<public>:i64=F(6,3)");
    const increment_nodes = increment.function_nodes.len;
    const increment_fuel = try least(h, increment);
    const inverted = try h.compile(prelude ++ "Block{set Cell=BitNot(A);Cell}\nR<public>:i64=F(6,3)");
    try std.testing.expectEqual(increment_nodes, inverted.function_nodes.len);
    try std.testing.expectEqual(increment_fuel, try least(h, inverted));
    try expectInt((try h.run(inverted, 4096)).ok, "R", -7);
}

test "bitwise intrinsics take integers only and yield to a program's own functions" {
    const h = try harness.create();
    defer scratch.release(h);
    for ([_]struct { []const u8, types.Diagnostic.Code }{
        .{ "A:i64=BitAnd(1)", .argument_count },
        .{ "A:i64=BitAnd(1,2,3)", .argument_count },
        .{ "A:i64=BitNot(1,2)", .argument_count },
        .{ "A:i64=BitNot()", .expected_expression },
        .{ "A:i64=BitOr()", .expected_expression },
        .{ "A:i64=BitNot(1.5)", .type_mismatch },
        .{ "A:i64=BitAnd(1,true)", .type_mismatch },
        .{ "A:i64=BitXor(\"a\",1)", .type_mismatch },
        .{ "A:float=BitOr(1,2)", .type_mismatch },
        .{ "A:logic=BitAnd(1,2)", .type_mismatch },
        // They are calls with parentheses: they cannot fail, so the failable spelling is no call.
        .{ "A:i64=Attempt(BitAnd[1,2],0)", .unknown_name },
        // And not values.
        .{ "A:=BitAnd", .unknown_name },
        // The Book lists these four; there is no shift.
        .{ "A:i64=BitShiftLeft(1,2)", .unknown_name },
        .{ "A:i64=ShiftLeft(1,2)", .unknown_name },
    }) |case| try expectRejected(h, case[0], case[1]);
    // A function a program already has keeps its meaning: the names are not reserved.
    const x = try h.execute("BitAnd(A:i64,B:i64)<computes>:i64=A*100+B\nBitNot(A:string)<computes>:string=A+\"!\"\n" ++
        "A<public>:i64=BitAnd(12,10)\nB<public>:string=BitNot(\"x\")\nC<public>:i64=BitOr(12,10)\n");
    try expectInt(x, "A", 1210);
    try std.testing.expectEqualStrings("x!", x.get("B").?.string);
    try expectInt(x, "C", 14);
    // In every position an expression has: arguments, conditions, loops, patterns' guards.
    const y = try h.execute("Xs:[]i64=array{1,2,3,4,5,6}\n" ++
        "Odd<public>:[]i64=For(X:Xs,BitAnd(X,1)==1,X)\n" ++
        "Fold<public>:i64=Iterate(Fn(S:i64){BitXor(S*2,S+1)},5,1)\n" ++
        "Kind<public>:i64=Case(6,N:i64 where BitAnd(N,3)==2=>BitOr(N,8),_=>0)\n" ++
        "Mask<public>:i64=If(BitAnd(255,BitNot(15))==240,1,0)\n");
    try expectIntegers(y, "Odd", &.{ 1, 3, 5 });
    var fold: i64 = 1;
    for (0..5) |_| fold = (fold * 2) ^ (fold + 1);
    try expectInt(y, "Fold", fold);
    try expectInt(y, "Kind", 14);
    try expectInt(y, "Mask", 1);
}

test "forged bitwise operators on floats and mistyped operands are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("X:i64=6\nY:i64=3\nA<public>:i64=BitAnd(X,Y)\nU:float=1.5\nV:float=2.5\nB<public>:float=U+V\nL:logic=true");
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    var integer: usize = 0;
    var floating: usize = 0;
    var float_value: u32 = 0;
    var logic_value: u32 = 0;
    for (nodes, 0..) |node, index| {
        if (node.kind == .binary) integer = index;
        if (node.kind == .float_binary) floating = index;
        if (node.kind == .floating and float_value == 0) float_value = @intCast(index);
        if (node.kind == .boolean) logic_value = @intCast(index);
    }
    try std.testing.expectEqual(types.BinaryOp.bit_and, nodes[integer].kind.binary.op);
    _ = try h.run(forged, 10_000);
    // No bitwise operator is defined on floats.
    for ([_]types.BinaryOp{ .bit_and, .bit_or, .bit_xor }) |op| {
        nodes[floating].kind.float_binary.op = op;
        try harness.invalid(h, forged);
    }
    nodes[floating] = p.nodes[floating];
    // An integer operation retyped as a float one, with either result type.
    nodes[integer].kind = .{ .float_binary = p.nodes[integer].kind.binary };
    try harness.invalid(h, forged);
    nodes[integer].value_type = .float;
    try harness.invalid(h, forged);
    nodes[integer] = p.nodes[integer];
    nodes[integer].value_type = .float;
    try harness.invalid(h, forged);
    nodes[integer].value_type = .logic;
    try harness.invalid(h, forged);
    nodes[integer] = p.nodes[integer];
    // Operands that are not integers, that are the operation itself, or that lie outside the program.
    for ([_]types.BinaryOp{ .bit_and, .bit_or, .bit_xor }) |op| {
        nodes[integer].kind.binary.op = op;
        _ = try h.run(forged, 10_000);
        for ([_]u32{ float_value, logic_value, @intCast(integer), @intCast(nodes.len) }) |operand| {
            if (operand > integer and operand < nodes.len) continue;
            nodes[integer].kind.binary.lhs = operand;
            try harness.invalid(h, forged);
            nodes[integer].kind.binary.lhs = p.nodes[integer].kind.binary.lhs;
            nodes[integer].kind.binary.rhs = operand;
            try harness.invalid(h, forged);
            nodes[integer].kind.binary.rhs = p.nodes[integer].kind.binary.rhs;
        }
    }
    nodes[integer] = p.nodes[integer];
    _ = try h.run(forged, 10_000);
}

test "forged bitwise operators inside function bodies are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("F(A:float,B:float)<computes>:float=A+B\nG(A:i64,B:i64)<computes>:i64=BitXor(A,B)\nV<public>:float=F(1.0,2.0)\nW<public>:i64=G(5,3)");
    var forged = p;
    forged.function_nodes = h.body[0..p.function_nodes.len];
    @memcpy(h.body[0..p.function_nodes.len], p.function_nodes);
    try expectInt((try h.run(forged, 10_000)).ok, "W", 6);
    var floats: usize = 0;
    var integers: usize = 0;
    for (p.function_nodes, 0..) |entry, index| {
        if (entry.node.kind == .float_binary) {
            floats += 1;
            for ([_]types.BinaryOp{ .bit_and, .bit_or, .bit_xor }) |op| {
                h.body[index].node.kind.float_binary.op = op;
                try harness.invalid(h, forged);
            }
            h.body[index] = entry;
        }
        if (entry.node.kind == .binary and entry.node.kind.binary.op == .bit_xor) {
            integers += 1;
            h.body[index].node.value_type = .float;
            try harness.invalid(h, forged);
            h.body[index].node.kind = .{ .float_binary = entry.node.kind.binary };
            try harness.invalid(h, forged);
            h.body[index] = entry;
            h.body[index].node.kind.binary.rhs = @intCast(index);
            try harness.invalid(h, forged);
            h.body[index] = entry;
        }
    }
    try std.testing.expect(floats != 0 and integers != 0);
    try expectInt((try h.run(forged, 10_000)).ok, "W", 6);
}

// ---------------------------------------------------------------------------------------
// logic{...}
// ---------------------------------------------------------------------------------------

test "logic{} is true when its expression succeeds and false when it fails" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{1,2}\nSome:option(i64)=option{7}\nNone:option(i64)=option{}\nM:map(string,i64)=map{\"a\"=>1}\n" ++
        "Pos(X:i64)<computes><decides>:i64=Block{Require[X>0];X}\n" ++
        "A<public>:logic=logic{Xs[1]}\nB<public>:logic=logic{Xs[5]}\n" ++
        "C<public>:logic=logic{Some?}\nD<public>:logic=logic{None?}\n" ++
        "E<public>:logic=logic{Pos[3]}\nF<public>:logic=logic{Pos[0]}\n" ++
        "G<public>:logic=logic{M[\"a\"]}\nH<public>:logic=logic{M[\"b\"]}\n" ++
        "I<public>:logic=logic{Require[1<2]}\nJ<public>:logic=logic{Require[2<1]}\n" ++
        // The value of the expression does not matter: a `false` that is computed is a success.
        "K<public>:logic=logic{Xs[0]>100}\n" ++
        // Several statements: all must succeed, in order.
        "L<public>:logic=logic{Xs[0];Xs[1]}\nN<public>:logic=logic{Xs[0];Xs[2];Xs[1]}\n" ++
        "O<public>:logic=logic{Y:=Xs[1];Require[Y==2]}\nP<public>:logic=logic{Y:=Xs[1]\nRequire[Y==3]}\n" ++
        "Q<public>:logic=logic{Floor[1.5]}\nR<public>:logic=logic{Not[Xs[9]]}\nS<public>:logic=logic{Not[Xs[0]]}\n" ++
        "T<public>:i64=If(logic{Xs[9]},1,0)+If(logic{Xs[0]},10,0)\n" ++
        "U<public>:logic=logic{Xs[0]} and not logic{Xs[9]}\n");
    for ([_]struct { []const u8, bool }{
        .{ "A", true },  .{ "B", false }, .{ "C", true },  .{ "D", false }, .{ "E", true }, .{ "F", false },
        .{ "G", true },  .{ "H", false }, .{ "I", true },  .{ "J", false }, .{ "K", true }, .{ "L", true },
        .{ "N", false }, .{ "O", true },  .{ "P", false }, .{ "Q", true },  .{ "R", true }, .{ "S", false },
        .{ "U", true },
    }) |case| try expectLogic(x, case[0], case[1]);
    try expectInt(x, "T", 10);
}

test "a failed logic{} undoes its writes and instances, and a successful one keeps them" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Log:i64=0\nXs:[]i64=array{1,2}\nBox:=class{var V:i64}\nvar Held:option(Box)=option{}\n" ++
        "A<public>:logic=logic{Block{set Log=Log+100;Xs[9]}}\nLA<public>:i64=Log\n" ++
        "B<public>:logic=logic{Block{set Log=Log+10;Xs[1]}}\nLB<public>:i64=Log\n" ++
        "Keep(N:i64)<transacts><decides>:i64=Block{set Held=option{Box{V:=N}};Require[N>0];N}\n" ++
        "C<public>:logic=logic{Keep[0]}\nHC<public>:logic=Held.IsSet\n" ++
        "D<public>:logic=logic{Keep[5]}\nHD<public>:logic=Held.IsSet\n" ++
        // Locals assigned inside are restored or kept the same way.
        "F()<transacts>:i64=Block{var N:i64=1;L:=logic{set N=5;Xs[9]};If(L,0-N,N)}\n" ++
        "G()<transacts>:i64=Block{var N:i64=1;L:=logic{set N=5;Xs[1]};If(L,0-N,N)}\n" ++
        "E<public>:i64=F()\nH<public>:i64=G()\n");
    try expectLogic(x, "A", false);
    try expectInt(x, "LA", 0);
    try expectLogic(x, "B", true);
    try expectInt(x, "LB", 10);
    try expectLogic(x, "C", false);
    try expectLogic(x, "HC", false);
    try expectLogic(x, "D", true);
    try expectLogic(x, "HD", true);
    try expectInt(x, "E", 1);
    try expectInt(x, "H", -5);
    // One instance survives: the one made by the attempt that succeeded.
    try std.testing.expectEqual(@as(usize, 2), x.object_cells.len);
}

test "logic{} nests, and works in <decides> functions, For clauses and Case guards" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Log:i64=0\nXs:[]i64=array{1,2,3,4}\n" ++
        // In a failable function the failure is still caught: the function succeeds with `false`.
        "Probe(I:i64)<transacts><decides>:logic=logic{Block{set Log=Log+1;Xs[I]}}\n" ++
        "A<public>:logic=Attempt(Probe[9],true)\nB<public>:logic=Attempt(Probe[0],false)\nLB<public>:i64=Log\n" ++
        // Nested: the inner one decides a branch, the outer one catches what follows.
        "C<public>:logic=logic{If(logic{Xs[9]},Xs[0],Xs[8])}\nD<public>:logic=logic{If(logic{Xs[0]},Xs[0],Xs[8])}\n" ++
        "E<public>:logic=logic{Require[logic{Xs[9]}]}\nF<public>:logic=logic{Require[not logic{Xs[9]}]}\n" ++
        // As a body, a filter and a binding of a For; the loop variable is the element, not an index.
        "G<public>:[]logic=For(X:Xs,logic{Xs[X]})\n" ++
        "H<public>:[]i64=For(X:Xs,logic{Xs[X]},X)\n" ++
        "I<public>:[]i64=For(X:Xs,Ok:=logic{Xs[X+1]},If(Ok,X,0-X))\n" ++
        "J<public>:[]i64=For(Z:0..5,Ok:=logic{Xs[Z]},not Ok,Z)\n" ++
        // As the guard of a Case arm.
        "Pick(N:i64)<computes>:i64=Case(N,K:i64 where logic{Xs[K+5]}=>1,K:i64 where logic{Xs[K]}=>2,_=>3)\n" ++
        "K<public>:i64=Pick(0)*100+Pick(3)*10+Pick(4)\n" ++
        // In a While condition and an If with bindings.
        "Count()<transacts>:i64=Block{var Z:i64=0;While(logic{Xs[Z]},set Z=Z+1);Z}\nL<public>:i64=Count()\n" ++
        "M<public>:i64=If(V:=Xs[1],logic{Xs[V]},V*10,0)\n");
    try expectLogic(x, "A", false);
    try expectLogic(x, "B", true);
    // The write of the probe that failed is undone; the one that succeeded stays.
    try expectInt(x, "LB", 1);
    try expectLogic(x, "C", false);
    try expectLogic(x, "D", true);
    try expectLogic(x, "E", false);
    try expectLogic(x, "F", true);
    const g = x.elements(x.get("G").?).?;
    try std.testing.expectEqual(@as(usize, 4), g.len);
    for (g, [_]bool{ true, true, true, false }) |got, want| try std.testing.expectEqual(want, got.boolean);
    try expectIntegers(x, "H", &.{ 1, 2, 3 });
    try expectIntegers(x, "I", &.{ 1, 2, -3, -4 });
    try expectIntegers(x, "J", &.{ 4, 5 });
    try expectInt(x, "K", 2 * 100 + 2 * 10 + 3);
    try expectInt(x, "L", 4);
    try expectInt(x, "M", 20);
}

test "logic{} needs an expression that can fail, as the Book requires" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "Xs:[]i64=array{1,2}\nPos(X:i64)<computes><decides>:i64=Block{Require[X>0];X}\nTwice[T:type](X:T)<computes><decides>:T{Block{Require[1<2];X}}\n";
    for ([_]struct { []const u8, types.Diagnostic.Code }{
        .{ "A:logic=logic{0}", .failure_expected },
        .{ "A:logic=logic{true}", .failure_expected },
        .{ "A:logic=logic{Xs.Length>1}", .failure_expected },
        .{ "A:logic=logic{Xs.Length;1+2}", .failure_expected },
        // A comparison is a `logic` value here and cannot fail; `Require[...]` makes it a test.
        .{ "A:logic=logic{1==1}", .failure_expected },
        // What an inner region catches cannot fail the outer one.
        .{ "A:logic=logic{logic{Xs[9]}}", .failure_expected },
        .{ "A:logic=logic{Attempt(Xs[9],0)}", .failure_expected },
        .{ "A:logic=logic{For(I:0..9,Xs[I]).Length}", .failure_expected },
        .{ "A:logic=logic{If(Xs[9]>0,1,2)}", .failure_expected },
        // Nor what would fail a function that is only made, not called.
        .{ "A:logic=logic{Fn(I:i64)<computes><decides>:i64{Xs[I]}}", .failure_expected },
        .{ "A:logic=logic{}", .expected_expression },
        .{ "A:logic=logic{;}", .expected_expression },
        .{ "A:i64=logic{Xs[0]}", .type_mismatch },
        .{ "A:logic=logic{Xs[0]", .unmatched_parenthesis },
        .{ "A:logic=logic{Xs[\"a\"]}", .type_mismatch },
        .{ "A:logic=logic{Missing[0]}", .unknown_name },
        // `logic` stays a type name; only `logic{` is the new form.
        .{ "A:logic=logic(Xs[0])", .not_callable },
        .{ "logic:i64=1", .expected_name },
    }) |case| {
        var buffer: [512]u8 = undefined;
        expectRejected(h, try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, case[0] }), case[1]) catch |err| {
            std.debug.print("case {s}\n", .{case[0]});
            return err;
        };
    }
    // What can fail after a region that catches still counts, and so does a failable call of
    // every kind: a function, a function value, a generic specialization, a method, a cast.
    const x = try h.execute(prelude ++ "Shape:=class{V:i64\n  Get()<transacts><decides>:i64=Block{Require[Self.V>0];Self.V}\n}\nDisc:=class(Shape){}\n" ++
        "S:Shape=Disc{V:=0}\nT:Shape=Shape{V:=4}\n" ++
        "A<public>:logic=logic{Attempt(Xs[9],0);Xs[9]}\nB<public>:logic=logic{Attempt(0,Xs[1])}\n" ++
        "C<public>:logic=logic{Pos[1]}\nD<public>:logic=logic{Fn(I:i64)<computes><decides>:i64{Xs[I]}[9]}\n" ++
        "E<public>:logic=logic{Twice[i64][3]}\n" ++
        "G()<transacts>:tuple(logic,logic,logic,logic)=tuple{logic{S.Get[]},logic{T.Get[]},logic{Disc[S]},logic{Disc[T]}}\nF<public>:tuple(logic,logic,logic,logic)=G()\n");
    try expectLogic(x, "A", false);
    try expectLogic(x, "B", true);
    try expectLogic(x, "C", true);
    try expectLogic(x, "D", false);
    try expectLogic(x, "E", true);
    const f = x.elements(x.get("F").?).?;
    for (f, [_]bool{ false, true, true, false }) |got, want| try std.testing.expectEqual(want, got.boolean);
    // The compiler is healthy after every rejection above.
    try expectLogic(try h.execute("Xs:[]i64=array{1}\nA<public>:logic=logic{Xs[0]}"), "A", true);
}

test "logic{} is an Attempt: the same nodes, steps and fuel as the spelled form" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "var Log:i64=0\nXs:[]i64=array{1,2}\nT(I:i64)<transacts><decides>:i64=Block{set Log=Log+1;Xs[I]}\n";
    const Kind = std.meta.Tag(@FieldType(types.Node, "kind"));
    const short = try h.compile(prelude ++ "A<public>:logic=logic{T[0];T[9]}\nB<public>:logic=logic{T[1]}\n");
    // A program borrows the compiler's storage until the next compile: keep what is compared.
    const kinds = try std.testing.allocator.alloc(Kind, short.nodes.len);
    defer std.testing.allocator.free(kinds);
    for (short.nodes, kinds) |node, *kind| kind.* = node.kind;
    const one = (try h.run(short, 10_000)).ok;
    const short_steps = one.call_steps.len;
    try expectLogic(one, "A", false);
    try expectLogic(one, "B", true);
    try expectInt(one, "Log", 1);
    try std.testing.expectEqual(@as(u32, 1), one.failure_count);
    const spelled = try h.compile(prelude ++ "A<public>:logic=Attempt(Block{T[0];T[9];true},false)\nB<public>:logic=Attempt(Block{T[1];true},false)\n");
    try std.testing.expectEqual(spelled.nodes.len, kinds.len);
    for (spelled.nodes, kinds) |want, got| try std.testing.expectEqual(@as(Kind, want.kind), got);
    const other = (try h.run(spelled, 10_000)).ok;
    try std.testing.expectEqual(short_steps, other.call_steps.len);
    try std.testing.expectEqual(@as(u32, 1), other.failure_count);
}

// ---------------------------------------------------------------------------------------
// option{...}
// ---------------------------------------------------------------------------------------

test "option{} outside a failure context turns a failure into the empty option" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{1,2}\nM:map(string,i64)=map{\"a\"=>1}\nSome:option(i64)=option{7}\nNone:option(i64)=option{}\n" ++
        "Pos(X:i64)<computes><decides>:i64=Block{Require[X>0];X}\n" ++
        "A<public>:option(i64)=option{Xs[1]}\nB<public>:option(i64)=option{Xs[5]}\n" ++
        "C<public>:option(i64)=option{Pos[3]}\nD<public>:option(i64)=option{Pos[0]}\n" ++
        "E<public>:option(i64)=option{Some?+1}\nF<public>:option(i64)=option{None?+1}\n" ++
        "G<public>:option(i64)=option{M[\"b\"]}\n" ++
        // The type is inferred from the expression as for any option, and the Book's inverse holds.
        "H<public>:=option{Xs[0]+Xs[1]}\nI<public>:i64=Attempt(option{Xs[1]}?,-1)\nJ<public>:i64=Attempt(option{Xs[9]}?,-1)\n" ++
        // A block of statements inside.
        "K<public>:option(i64)=option{Block{Y:=Xs[0];Require[Y>5];Y}}\nL<public>:option(i64)=option{Block{Y:=Xs[0];Require[Y<5];Y}}\n" ++
        // In a function that is not failable, as the Book's `FindOptional`.
        "Find(Z:i64)<computes>:option(i64)=option{Xs[Z]}\nN<public>:option(i64)=Find(0)\nO<public>:option(i64)=Find(3)\n" ++
        "P<public>:i64=Or(option{Xs[9]},-5)\n");
    try std.testing.expectEqual(@as(i64, 2), inside(x, "A").?.integer);
    try std.testing.expect(inside(x, "B") == null);
    try std.testing.expectEqual(@as(i64, 3), inside(x, "C").?.integer);
    try std.testing.expect(inside(x, "D") == null);
    try std.testing.expectEqual(@as(i64, 8), inside(x, "E").?.integer);
    try std.testing.expect(inside(x, "F") == null);
    try std.testing.expect(inside(x, "G") == null);
    try std.testing.expectEqual(@as(i64, 3), inside(x, "H").?.integer);
    try expectInt(x, "I", 2);
    try expectInt(x, "J", -1);
    try std.testing.expect(inside(x, "K") == null);
    try std.testing.expectEqual(@as(i64, 1), inside(x, "L").?.integer);
    try std.testing.expectEqual(@as(i64, 1), inside(x, "N").?.integer);
    try std.testing.expect(inside(x, "O") == null);
    try expectInt(x, "P", -5);
}

test "a caught option{} undoes the writes of its expression and keeps those of a success" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Log:i64=0\nXs:[]i64=array{1,2}\nBox:=class{var V:i64}\n" ++
        "A<public>:option(i64)=option{Block{set Log=Log+1000;Xs[9]}}\nLA<public>:i64=Log\n" ++
        "B<public>:option(i64)=option{Block{set Log=Log+10;Xs[1]}}\nLB<public>:i64=Log\n" ++
        "Make(N:i64)<transacts><decides>:Box=Block{Bx:=Box{V:=N};Require[N>0];Bx}\n" ++
        "C<public>:option(Box)=option{Make[0]}\nD<public>:option(Box)=option{Make[4]}\n" ++
        "F()<transacts>:i64=Block{var N:i64=1;O:=option{Block{set N=5;Xs[9]}};If(O.IsSet,0-N,N)}\n" ++
        "G()<transacts>:i64=Block{var N:i64=1;O:=option{Block{set N=5;Xs[1]}};If(O.IsSet,0-N,N)}\n" ++
        "E<public>:i64=F()\nH<public>:i64=G()\n");
    try std.testing.expect(inside(x, "A") == null);
    try expectInt(x, "LA", 0);
    try std.testing.expectEqual(@as(i64, 2), inside(x, "B").?.integer);
    try expectInt(x, "LB", 10);
    try std.testing.expect(inside(x, "C") == null);
    try std.testing.expect(inside(x, "D").? == .object);
    // The instance of the failed constructor is gone with its attempt.
    try std.testing.expectEqual(@as(usize, 2), x.object_cells.len);
    try expectInt(x, "E", 1);
    try expectInt(x, "H", -5);
}

test "an option{} that cannot fail compiles to what it always did" {
    const h = try harness.create();
    defer scratch.release(h);
    // Nodes of each program, as the compiler before RFC-0072 emitted them: a literal or a
    // read and the aggregate, with no region. Brackets that cannot fail make no difference.
    for ([_]struct { []const u8, usize }{
        .{ "A<public>:option(i64)=option{3}", 2 },
        .{ "A<public>:option(i64)=option{}", 1 },
        .{ "A<public>:=option{1+2}", 4 },
        .{ "A<public>:option(option(i64))=option{option{3}}", 3 },
        .{ "M:map(string,i64)=map{\"a\"=>1}\nA<public>:option(map(string,i64))=option{WithIndex[M,\"b\",2]}", 7 },
        .{ "Xs:[]i64=array{1}\nA<public>:option(i64)=option{Attempt(Xs[9],0)}", 0 },
        .{ "N:i64=2\nA<public>:option(function(tuple(i64),i64))=option{Fn(X:i64):i64{X+N}}", 0 },
        .{ "N:i64=2\nA<public>:option([]i64)=option{For(X:array{1,2},X+N)}", 0 },
    }) |case| {
        const program = try h.compile(case[0]);
        if (case[1] != 0) try std.testing.expectEqual(case[1], program.nodes.len);
        // At most the region the program wrote itself.
        try std.testing.expectEqual(@as(usize, std.mem.count(u8, case[0], "Attempt(")), count(program, .attempt_begin));
        try std.testing.expectEqual(@as(u32, 0), h.front.option_caught_count);
        _ = try h.run(program, 10_000);
    }
    // One that can fail is a region around the constructor, node for node. RFC-0076 rule 7: the
    // old spelling `Attempt(option{E}, option{})` no longer shows that, because the constructor
    // in the body now catches by itself; binding `E` first leaves a constructor that cannot fail.
    const short = try h.compile("Xs:[]i64=array{1,2}\nA<public>:option(i64)=option{Xs[5]}\nB<public>:option(i64)=option{Xs[0]}\nC<public>:option(i64)=option{9}");
    try std.testing.expectEqual(@as(u32, 2), h.front.option_caught_count);
    const short_kinds = try std.testing.allocator.alloc(std.meta.Tag(@FieldType(types.Node, "kind")), short.nodes.len);
    defer std.testing.allocator.free(short_kinds);
    for (short.nodes, short_kinds) |node, *kind| kind.* = node.kind;
    const short_steps = (try h.run(short, 10_000)).ok.call_steps.len;
    const spelled = try h.compile("Xs:[]i64=array{1,2}\nA<public>:option(i64)=Attempt(Block{V:=Xs[5];option{V}},option{})\nB<public>:option(i64)=Attempt(Block{V:=Xs[0];option{V}},option{})\nC<public>:option(i64)=option{9}");
    try std.testing.expectEqual(@as(u32, 0), h.front.option_caught_count);
    try std.testing.expectEqual(spelled.nodes.len, short_kinds.len);
    for (spelled.nodes, short_kinds) |want, got| try std.testing.expectEqual(std.meta.activeTag(want.kind), got);
    try std.testing.expectEqual(@as(usize, 2), count(spelled, .attempt_begin));
    try std.testing.expectEqual(short_steps, (try h.run(spelled, 10_000)).ok.call_steps.len);
    // The old spelling: each constructor in an `Attempt` body catches as it does anywhere (rule
    // 7), so both are noted and each has its own region inside the one the program wrote. The
    // outer alternative is never taken: A is the empty option of the constructor, not `option{7}`.
    const nested = try h.compile("Xs:[]i64=array{1,2}\nA<public>:option(i64)=Attempt(option{Xs[5]},option{7})\nB<public>:option(i64)=Attempt(option{Xs[0]},option{7})\nC<public>:option(i64)=option{9}");
    try std.testing.expectEqual(@as(u32, 2), h.front.option_caught_count);
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    try std.testing.expectEqual(@as(usize, 4), count(nested, .attempt_begin));
    const y = (try h.run(nested, 10_000)).ok;
    try std.testing.expect(inside(y, "A") == null);
    try std.testing.expectEqual(@as(i64, 1), inside(y, "B").?.integer);
}

test "an option{} inside a failure context catches the failure of its expression" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076 rule 7: before, the option here was a plain constructor and what failed inside
    // failed the region, the iteration or the function around it. Now it catches everywhere.
    // Every expected value below is derived by hand from Xs = {1,2}.
    const x = try h.execute("var Log:i64=0\nXs:[]i64=array{1,2}\n" ++
        // Xs[5] fails and the constructor catches: the body of the Attempt succeeds with the
        // empty option, so the alternative `option{7}` is not taken (it was).
        "A<public>:option(i64)=Attempt(option{Xs[5]},option{7})\n" ++
        // A `<decides>` function whose only failable thing is caught never fails: Get[5] is the
        // empty option (it was a failure, hence `option{8}`); Get[1] is option{2} as before.
        "Get(I:i64)<computes><decides>:option(i64)=option{Xs[I]}\n" ++
        "B<public>:option(i64)=Attempt(Get[5],option{8})\nC<public>:option(i64)=Attempt(Get[1],option{8})\n" ++
        // An iteration of a `For` is no longer skipped, whether the call is general by its shape
        // or was sent to the general lowering by another failure. D: I=0..3 gives {1},{2},{},{}
        // (it had two elements). D2: X=1 gives {2}, X=2 gives {} (it had one).
        "D<public>:[]option(i64)=For(I:0..3,option{Xs[I]})\n" ++
        "D2<public>:[]option(i64)=For(X:Xs,option{Xs[X]})\n" ++
        // D3: X=1 gives Or({2},0)+Xs[0] = 3; X=2 gives Or({},0)+Xs[1] = 2 (it was skipped). The
        // `Xs[X-1]` outside the constructor still makes the iteration a failure context.
        "D3<public>:[]i64=For(X:Xs,Or(option{Xs[X]},0)+Xs[X-1])\n" ++
        // D4: what fails outside the constructor still skips: X=1 gives Xs[1]+0 = 2; X=2 fails in Xs[2].
        "D4<public>:[]i64=For(X:Xs,Xs[X]+Or(option{Xs[X+7]},0))\n" ++
        // Conditions: the one of a plain `If` and those of an `If` that binds. The condition
        // no longer fails; it is the empty option, which is not set. E and F keep their values
        // (2 and 0) for that new reason; E2 and F2 tell the two readings apart: `not IsSet` of
        // the empty option is true, so each is 1 (a failed condition gave 2 and 0).
        "E<public>:i64=If(option{Xs[5]}.IsSet,1,2)\n" ++
        "E2<public>:i64=If(not option{Xs[5]}.IsSet,1,2)\n" ++
        "F<public>:i64=If(V:=option{Xs[5]},V.IsSet,1,0)\n" ++
        "F2<public>:i64=If(V:=option{Xs[5]},not V.IsSet,1,0)\n" ++
        // The writes of a failed expression are undone, those of a success stay: Put[5] is the
        // empty option and Log stays 0; Put[0] is option{1} and Log is 1. Neither call fails.
        "Put(I:i64)<transacts><decides>:option(i64)=option{Block{set Log=Log+1;Xs[I]}}\n" ++
        "G<public>:option(i64)=Attempt(Put[5],option{9})\nLG<public>:i64=Log\n" ++
        "H<public>:option(i64)=Attempt(Put[0],option{9})\nLH<public>:i64=Log\n");
    try std.testing.expect(inside(x, "A") == null);
    try std.testing.expect(inside(x, "B") == null);
    try std.testing.expectEqual(@as(i64, 2), inside(x, "C").?.integer);
    const d = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(usize, 4), d.len);
    for (d, [_]usize{ 1, 1, 0, 0 }) |got, want| try std.testing.expectEqual(want, x.elements(got).?.len);
    try std.testing.expectEqual(@as(i64, 1), x.elements(d[0]).?[0].integer);
    try std.testing.expectEqual(@as(i64, 2), x.elements(d[1]).?[0].integer);
    const d2 = x.elements(x.get("D2").?).?;
    try std.testing.expectEqual(@as(usize, 2), d2.len);
    try std.testing.expectEqual(@as(i64, 2), x.elements(d2[0]).?[0].integer);
    try std.testing.expectEqual(@as(usize, 0), x.elements(d2[1]).?.len);
    try expectIntegers(x, "D3", &.{ 3, 2 });
    try expectIntegers(x, "D4", &.{2});
    try expectInt(x, "E", 2);
    try expectInt(x, "E2", 1);
    try expectInt(x, "F", 0);
    try expectInt(x, "F2", 1);
    try std.testing.expect(inside(x, "G") == null);
    try expectInt(x, "LG", 0);
    try std.testing.expectEqual(@as(i64, 1), inside(x, "H").?.integer);
    try expectInt(x, "LH", 1);
    // Every constructor above that holds something failable is noted (it was none, rule 7):
    // A, Get, D, D2, D3, D4, E, E2, F, F2 and Put. `option{7}`, `option{8}` and `option{9}`
    // cannot fail and are not.
    try std.testing.expectEqual(@as(u32, 11), h.front.option_caught_count);
    // In a bounded number of compiles: every constructor a compile reaches is noted by that
    // compile, and the compiles beyond the two of a plain program are those the two loops found
    // by their error (D3, D4) and the binding conditions (F, F2) take with or without a
    // constructor. (Counts by the number of constructors are in the test of the passes below.)
    try std.testing.expect(h.front.passes <= 6);
}

test "nested option{} forms: each catches the failure of its own expression" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{1,2,3}\n" ++
        // The inner constructor is the nearest: the outer one holds its empty option.
        "A<public>:option(option(i64))=option{option{Xs[9]}}\nB<public>:option(option(i64))=option{option{Xs[1]}}\n" ++
        // A `For` around it does not change that (RFC-0076 rule 7; the iteration was skipped):
        // X=1 gives {2}, X=2 gives {3}, X=3 gives the empty option. A `For` inside the
        // constructor skips its own iteration and the constructor has nothing to catch.
        "C<public>:[]option(i64)=For(X:Xs,option{Xs[X]})\n" ++
        "D<public>:option([]i64)=option{For(X:Xs,Xs[X])}\n" ++
        // Two in one expression, and one whose failure lies after a nested one that succeeded.
        "E<public>:tuple(option(i64),option(i64))=tuple{option{Xs[0]},option{Xs[7]}}\n" ++
        "F<public>:option(i64)=option{Or(option{Xs[9]},5)+Xs[8]}\n" ++
        "G<public>:option(i64)=option{Or(option{Xs[9]},5)+Xs[0]}\n" ++
        // Inside the alternative of a region, where failures are not caught by that region.
        "H<public>:option(i64)=Attempt(option{4},option{Xs[9]})\nI<public>:option(i64)=If(Xs.Length>9,option{1},option{Xs[9]})\n" ++
        // The same sum the other way round: which failure the compiler meets first does not matter.
        "G2<public>:option(i64)=option{Xs[0]+Or(option{Xs[9]},5)}\n" ++
        // Inside `logic{...}` and a clause of `First[...]`, which are failure contexts of
        // RFC-0072, a constructor catches as well.
        "L1<public>:logic=logic{Require[option{Xs[9]}.IsSet]}\nL2<public>:logic=logic{Require[option{Xs[1]}.IsSet]}\n" ++
        "L3<public>:i64=Attempt(First[X:Xs,not option{Xs[X+1]}.IsSet,X],-1)\n" ++
        // Inside an `Attempt` inside a `logic{...}` too (rule 7; it was a constructor there): the
        // Attempt yields the empty option of its body, never its alternative, so `?` fails in
        // both and both are false (L4 was true by the alternative `option{1}`).
        "L4<public>:logic=logic{Attempt(option{Xs[9]},option{1})?}\nL5<public>:logic=logic{Attempt(option{Xs[9]},option{})?}\n" ++
        // Inside a record field and an argument.
        "Wrap:=struct{O:option(i64)}\nShow(O:option(i64))<computes>:i64=Or(O,-1)\n" ++
        "J<public>:i64=Or(Wrap{O:=option{Xs[9]}}.O,-2)\nK<public>:i64=Show(option{Xs[9]})+Show(option{Xs[2]})\n");
    const a = x.elements(inside(x, "A").?).?;
    try std.testing.expectEqual(@as(usize, 0), a.len);
    try std.testing.expectEqual(@as(i64, 2), x.elements(inside(x, "B").?).?[0].integer);
    const c = x.elements(x.get("C").?).?;
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectEqual(@as(i64, 2), x.elements(c[0]).?[0].integer);
    try std.testing.expectEqual(@as(i64, 3), x.elements(c[1]).?[0].integer);
    try std.testing.expectEqual(@as(usize, 0), x.elements(c[2]).?.len);
    // The loop inside skips its failing iteration, so the option holds what remains.
    const d = x.elements(inside(x, "D").?).?;
    try std.testing.expectEqual(@as(usize, 2), d.len);
    const e = x.elements(x.get("E").?).?;
    try std.testing.expectEqual(@as(usize, 1), x.elements(e[0]).?.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(e[1]).?.len);
    try std.testing.expect(inside(x, "F") == null);
    try std.testing.expectEqual(@as(i64, 6), inside(x, "G").?.integer);
    try std.testing.expectEqual(@as(i64, 4), inside(x, "H").?.integer);
    try std.testing.expect(inside(x, "I") == null);
    try std.testing.expectEqual(@as(i64, 6), inside(x, "G2").?.integer);
    try expectLogic(x, "L1", false);
    try expectLogic(x, "L2", true);
    // Xs[2] and Xs[3] exist for X=1 and X=2... no: Xs has three elements, so X=2 is the first without a successor.
    try expectInt(x, "L3", 2);
    try expectLogic(x, "L4", false);
    try expectLogic(x, "L5", false);
    try expectInt(x, "J", -2);
    try expectInt(x, "K", 2);
    // A constructor that catches leaves nothing for a `logic{...}` around it to catch.
    try expectRejected(h, "Xs:[]i64=array{1}\nA:logic=logic{option{Xs[5]}}", .failure_expected);
    try expectRejected(h, "Xs:[]i64=array{1}\nA:logic=logic{option{Xs[5]}.IsSet}", .failure_expected);
}

test "option{} catches in every module of a bundle, by its place in its own module" {
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:option(i64)=option{L.Items[9]}\nB<public>:option(i64)=L.At(1)\nC<public>:option(i64)=L.At(7)\nD<public>:[]option(i64)=For(X:L.Items,option{L.Items[X]})" },
        .{ .path = "lib.forb", .source = "Items<public>:[]i64=array{1,2}\nAt<public>(I:i64)<computes>:option(i64)=option{Items[I]}\nFirstOne<public>:option(i64)=option{Items[0]}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path, bundled.failed.diagnostic.span.start });
    try std.testing.expect(bundled == .ok);
    const x = (try h.run(bundled.ok, 131072)).ok;
    try std.testing.expect(inside(x, "A") == null);
    try std.testing.expectEqual(@as(i64, 2), inside(x, "B").?.integer);
    try std.testing.expect(inside(x, "C") == null);
    // In a `For` the constructor catches too (RFC-0076 rule 7; the iteration was skipped):
    // X=1 gives option{Items[1]} = option{2}, X=2 gives the empty option.
    const d = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expectEqual(@as(i64, 2), x.elements(d[0]).?[0].integer);
    try std.testing.expectEqual(@as(usize, 0), x.elements(d[1]).?.len);
}

test "an option{} cannot catch what fails in a function it only names, and the compile ends" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "Xs:[]i64=array{1,2}\nHead[T:type](Items:[]T)<computes>:T{Items[0]}\n";
    for ([_]struct { []const u8, types.Diagnostic.Code }{
        // The body of a function value is its own function.
        .{ "A:=option{Fn(I:i64):i64{Xs[I]}}", .failure_context_required },
        // The body of a generic specialization too, though it is instantiated from inside.
        .{ "A:=option{Head[i64](Xs)}", .failure_context_required },
        .{ "A:option(i64)=option{Xs[0],Xs[1]}", .option_arity },
        .{ "A:option(string)=option{Xs[0]}", .type_mismatch },
        .{ "A:option(i64)=option{Xs[0]", .unmatched_parenthesis },
        .{ "A:option(i64)=option{Xs[true]}", .type_mismatch },
    }) |case| {
        var buffer: [512]u8 = undefined;
        expectRejected(h, try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, case[0] }), case[1]) catch |err| {
            std.debug.print("case {s}\n", .{case[0]});
            return err;
        };
    }
    try std.testing.expectEqual(@as(i64, 1), inside(try h.execute("Xs:[]i64=array{1}\nA<public>:option(i64)=option{Xs[0]}"), "A").?.integer);
}

test "every option{} that must catch is found in one pass, however many there are" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [16384]u8 = undefined;
    // One and two hundred constructors take the same two passes: the one that notes them and
    // the one that compiles them. (A binding each, and the bootstrap profile has 256.)
    for ([_]usize{ 1, 200 }) |options| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Xs:[]i64=array{1,2,3}\n");
        for (0..options) |index| try out.print("O{d}<public>:option(i64)=option{{Xs[{d}]}}\n", .{ index, index % 5 });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(@as(u32, @intCast(options)), h.front.option_caught_count);
        try std.testing.expectEqual(@as(u32, 2), h.front.passes);
        for (0..options) |index| {
            var name: [8]u8 = undefined;
            const value = inside(x, try std.fmt.bufPrint(&name, "O{d}", .{index}));
            if (index % 5 < 3) try std.testing.expectEqual(@as(i64, @intCast(index % 5 + 1)), value.?.integer) else try std.testing.expect(value == null);
        }
    }
    // Nested ones, and one inside a loop that itself needs the general lowering. The loop is
    // noted in the pass that notes the constructors (it took a compile of its own, found by
    // the error it caused); its iteration is then a failure context, in which the
    // constructor catches all the same (RFC-0076 rule 7; X=3 was skipped): X=1 gives 2+1,
    // X=2 gives 3+2, X=3 gives Or({},0)+Xs[2] = 0+3.
    const x = try h.execute("Xs:[]i64=array{1,2,3}\n" ++
        "A<public>:option(i64)=option{Xs[0]+Or(option{Xs[9]},5)+Or(option{Xs[1]},7)}\n" ++
        "B<public>:[]i64=For(X:Xs,Or(option{Xs[X]},0)+Xs[X-1])\n");
    try std.testing.expectEqual(@as(i64, 8), inside(x, "A").?.integer);
    try expectIntegers(x, "B", &.{ 3, 5, 3 });
    // The three of A and, by rule 7, the one in the loop of B (it was three: that one did not catch).
    try std.testing.expectEqual(@as(u32, 4), h.front.option_caught_count);
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    // RFC-0076 rule 7: constructors inside a failure context catch as well, and are found the
    // same way: one and twenty of them take the same number of compiles, in an `Attempt` body,
    // an iteration of a `For`, a condition, a binding condition and a `<decides>` function.
    inline for (.{
        "O{d}<public>:option(i64)=Attempt(option{{Xs[{d}]}},option{{7}})\n",
        "O{d}<public>:[]option(i64)=For(X:Xs,option{{Xs[X+{d}]}})\n",
        "O{d}<public>:[]i64=For(X:Xs,Or(option{{Xs[X+{d}]}},0)+X)\n",
        "O{d}<public>:i64=If(option{{Xs[{d}]}}.IsSet,1,2)\n",
        "O{d}<public>:i64=If(V:=option{{Xs[{d}]}},V.IsSet,1,0)\n",
        "G{d}(I:i64)<computes><decides>:option(i64)=option{{Xs[I+{d}]}}\n",
    }) |line| {
        var passes: [2]u32 = undefined;
        for ([_]usize{ 1, 20 }, &passes) |options, *taken| {
            var out = std.Io.Writer.fixed(&buffer);
            try out.writeAll("Xs:[]i64=array{1,2,3}\n");
            for (0..options) |index| try out.print(line, .{ index, index % 5 });
            _ = try h.execute(out.buffered());
            try std.testing.expectEqual(@as(u32, @intCast(options)), h.front.option_caught_count);
            taken.* = h.front.passes;
        }
        try std.testing.expectEqual(passes[0], passes[1]);
        try std.testing.expect(passes[0] <= 3);
    }
    // A loop that is only found by the error it causes takes a compile of its own, as it did
    // (one loop is sent to the general lowering per compile); a constructor in it is noted by
    // the compile that reaches it, which ends at that error. So at most two compiles a loop.
    for ([_]usize{ 1, 2, 5 }) |loops| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("Xs:[]i64=array{1,2,3}\n");
        for (0..loops) |index| try out.print("O{d}<public>:[]i64=For(X:Xs,Or(option{{Xs[X+{d}]}},0)+Xs[X-1])\n", .{ index, index });
        const y = try h.execute(out.buffered());
        try std.testing.expectEqual(@as(u32, @intCast(loops)), h.front.option_caught_count);
        try std.testing.expect(h.front.passes <= 2 * loops + 1);
        // No iteration is skipped. O0: X=1,2,3 give Or(option{Xs[X]},0)+Xs[X-1] = 2+1, 3+2, 0+3.
        try expectIntegers(y, "O0", &.{ 3, 5, 3 });
    }
    // A program without such a constructor is compiled once, as ever.
    _ = try h.execute("Xs:[]i64=array{1,2,3}\nA<public>:option(i64)=option{3}\nB<public>:i64=Attempt(Xs[0],0)");
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
    try std.testing.expectEqual(@as(u32, 0), h.front.option_caught_count);
}

// ---------------------------------------------------------------------------------------
// First[...]
// ---------------------------------------------------------------------------------------

test "First yields the body of the first iteration that succeeds and fails when there is none" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{5,6,7}\nNone:[]i64=array{}\nM:map(string,i64)=map{\"a\"=>1,\"b\"=>2,\"c\"=>2}\n" ++
        "Player:=struct{Name:string,Score:i64}\nRoster:[]Player=array{Player{Name:=\"Ada\",Score:=10},Player{Name:=\"Bo\",Score:=99}}\n" ++
        // The Book's examples: a search that yields the element, and one that yields its index.
        "Top(Players:[]Player,Threshold:i64)<computes><decides>:Player=First[P:Players,P.Score>Threshold,P]\n" ++
        "IndexOf(Items:[]i64,Target:i64)<computes><decides>:i64=First[I->V:Items,V==Target,I]\n" ++
        "A<public>:string=Attempt(Top[Roster,50].Name,\"-\")\nB<public>:string=Attempt(Top[Roster,100].Name,\"-\")\n" ++
        "C<public>:i64=Attempt(IndexOf[Xs,7],-1)\nD<public>:i64=Attempt(IndexOf[Xs,9],-1)\n" ++
        // Without a filter the first element; over nothing, a failure.
        "E<public>:i64=Attempt(First[X:Xs,X*10],-1)\nF<public>:i64=Attempt(First[X:None,X],-1)\n" ++
        // Ranges, maps, bindings, several filters, several generators.
        "G<public>:i64=Attempt(First[I:1..100,I*I>50,I],-1)\nH<public>:i64=Attempt(First[I:3..2,I],-1)\n" ++
        "I<public>:string=Attempt(First[K->V:M,V==2,K],\"-\")\nJ<public>:i64=Attempt(First[V:M,V>1,V*10],-1)\n" ++
        "K<public>:i64=Attempt(First[X:Xs,Y:=X*2,Y>10,X!=6,Y],-1)\n" ++
        "L<public>:i64=Attempt(First[X:Xs,Y:Xs,X+Y==13,X<Y,X*10+Y],-1)\n" ++
        "N<public>:i64=Attempt(First[U:1..9,V:U..9,W:V..9,U*U+V*V==W*W,U*100+V*10+W],-1)\n" ++
        "O<public>:i64=Attempt(First[X:Xs,Y:Xs,X+Y==99,X],-1)\n" ++
        // The Book's wrappers: an `If` with a fallback and an option.
        "FindOrDefault(Items:[]i64,Target:i64)<computes>:i64=If(Index:=First[Z->V:Items,V==Target,Z],Index>=0,Index,-1)\n" ++
        "FindOptional(Items:[]i64,Target:i64)<computes>:option(i64)=option{First[Z->V:Items,V==Target,Z]}\n" ++
        "P<public>:i64=FindOrDefault(Xs,9)*100+FindOrDefault(Xs,6)\nQ<public>:i64=Attempt(FindOptional(Xs,7)?,-1)\nR<public>:logic=FindOptional(Xs,8).IsSet\n" ++
        // Any type of body.
        "S<public>:tuple(i64,string)=Attempt(First[Z->X:Xs,X>5,tuple{Z,\"{X}\"}],tuple{-1,\"\"})\n" ++
        "T<public>:[]i64=Attempt(First[X:Xs,X>6,array{X,X}],array{})\n");
    try std.testing.expectEqualStrings("Bo", x.get("A").?.string);
    try std.testing.expectEqualStrings("-", x.get("B").?.string);
    try expectInt(x, "C", 2);
    try expectInt(x, "D", -1);
    try expectInt(x, "E", 50);
    try expectInt(x, "F", -1);
    try expectInt(x, "G", 8);
    try expectInt(x, "H", -1);
    try std.testing.expectEqualStrings("b", x.get("I").?.string);
    try expectInt(x, "J", 20);
    // X=5 gives Y=10, not above 10; X=6 is excluded; X=7 gives 14.
    try expectInt(x, "K", 14);
    try expectInt(x, "L", 67);
    try expectInt(x, "N", 345);
    try expectInt(x, "O", -1);
    try expectInt(x, "P", -100 + 1);
    try expectInt(x, "Q", 2);
    try expectLogic(x, "R", false);
    const s = x.elements(x.get("S").?).?;
    try std.testing.expectEqual(@as(i64, 1), s[0].integer);
    try std.testing.expectEqualStrings("6", s[1].string);
    try expectIntegers(x, "T", &.{ 7, 7 });
}

test "First stops at its first success: nothing after it is evaluated" {
    const h = try harness.create();
    defer scratch.release(h);
    // An iteration after the first success would end the run with a division by zero.
    const x = try h.execute("Xs:[]i64=array{4,2,0,1}\nRows:[][]i64=array{array{9},array{1,0},array{0}}\n" ++
        "A<public>:i64=Attempt(First[X:Xs,100/X>30,X],-1)\n" ++
        "B<public>:i64=Attempt(First[I:1..1000000000000,10/(3-I)>4,I],-1)\n" ++
        // Neither a later element of the inner source nor a later outer source.
        "C<public>:i64=Attempt(First[R:Rows,X:R,10/X>5,X],-1)\n" ++
        "D<public>:i64=Attempt(First[X:Xs,Y:array{2,X-4},X/Y==2,Y],-1)\n" ++
        // Nor a later filter or binding of an iteration, once one of them is false.
        "E<public>:i64=Attempt(First[X:Xs,X>0,Y:=8/X,Y>4,X],-1)\n");
    try expectInt(x, "A", 2);
    try expectInt(x, "B", 1);
    try expectInt(x, "C", 1);
    // X=4 with Y=2 is the hit; the next Y would be 0.
    try expectInt(x, "D", 2);
    // X=4: Y=2 fails; X=2: Y=4 fails; X=0 stops at X>0, so 8/0 is never computed; X=1: Y=8.
    try expectInt(x, "E", 1);
    // The steps of a search grow with the position of the hit, not with the range.
    const near = (try h.run(try h.compile("A<public>:i64=Attempt(First[I:1..1000000,I>=3,I],-1)"), 131072)).ok;
    const far = (try h.run(try h.compile("A<public>:i64=Attempt(First[I:1..1000000,I>=23,I],-1)"), 131072)).ok;
    const per_iteration = (far.call_steps.len - near.call_steps.len) / 20;
    try std.testing.expectEqual(near.call_steps.len + 20 * per_iteration, far.call_steps.len);
    try std.testing.expect(near.call_steps.len < 5 * per_iteration);
    // And a fatal error before any success is still fatal.
    const fatal = try h.run(try h.compile("Xs:[]i64=array{0,1}\nA<public>:i64=Attempt(First[X:Xs,10/X>5,X],-1)"), 131072);
    try std.testing.expectEqual(types.Diagnostic.Code.division_by_zero, fatal.failed.code);
}

test "First keeps the writes of the iteration it yields and undoes every other" {
    const h = try harness.create();
    defer scratch.release(h);
    // A clause or body has the effects of the function it is written in, so each search that
    // writes is in a `<transacts>` function.
    const x = try h.execute("var Log:i64=0\nXs:[]i64=array{1,2,3,4}\nBox:=class{var V:i64}\nvar Held:option(Box)=option{}\n" ++
        "Note(X:i64)<transacts>:i64=Block{set Log=Log+X;X}\n" ++
        // Filters and the body write: of 1, 2 and 3 only the iteration of 3 remains.
        "Find(Min:i64)<transacts><decides>:i64=First[X:Xs,Note(X)>Min,Note(X*100)]\n" ++
        "A<public>:i64=Attempt(Find[2],-1)\nLA<public>:i64=Log\n" ++
        // Nothing matches: every write is undone, by each iteration before the whole fails.
        "B<public>:i64=Attempt(Find[9],-1)\nLB<public>:i64=Log\n" ++
        // A body that fails is an iteration that fails, with its writes.
        "Body()<transacts>:i64=Attempt(First[X:Xs,Block{Note(X*1000);Require[X>3];X}],-1)\n" ++
        "C<public>:i64=Body()\nLC<public>:i64=Log\n" ++
        // An outer iteration whose inner level finds nothing is undone with its own clauses.
        "Inner(Gap:i64)<transacts>:i64=Attempt(First[X:Xs,Note(X*10000)>0,Y:Xs,Y>X+Gap,X*10+Y],-1)\n" ++
        "D<public>:i64=Inner(2)\nLD<public>:i64=Log\nE<public>:i64=Inner(9)\nLE<public>:i64=Log\n" ++
        // Instances and locals follow the same rule.
        "Make(N:i64)<transacts><decides>:i64=Block{set Held=option{Box{V:=N}};Require[N>2];N}\n" ++
        "Made()<transacts>:i64=Attempt(First[X:Xs,Make[X]],-1)\nF<public>:i64=Made()\n" ++
        // As a failable expression of a `<decides>` function, a miss fails the function and its writes.
        "Both(Min:i64)<transacts><decides>:i64=Block{set Log=Log+7;First[X:Xs,X>Min,X]}\n" ++
        "I<public>:i64=Attempt(Both[8],-1)\nLI<public>:i64=Log\nJ<public>:i64=Attempt(Both[1],-1)\nLJ<public>:i64=Log\n");
    try expectInt(x, "A", 300);
    try expectInt(x, "LA", 303);
    try expectInt(x, "B", -1);
    try expectInt(x, "LB", 303);
    try expectInt(x, "C", 4);
    try expectInt(x, "LC", 4303);
    // X=1: the inner level finds Y=4.
    try expectInt(x, "D", 14);
    try expectInt(x, "LD", 14303);
    try expectInt(x, "E", -1);
    try expectInt(x, "LE", 14303);
    try expectInt(x, "F", 3);
    // Only the instance of the iteration that succeeded exists.
    try std.testing.expectEqual(@as(usize, 2), x.object_cells.len);
    try expectInt(x, "I", -1);
    try expectInt(x, "LI", 14303);
    try expectInt(x, "J", 2);
    try expectInt(x, "LJ", 14310);
    // A clause cannot write where its function cannot. At the root it may, as the root may
    // (RFC-0079, `fix2`): the loop's function declares what its clauses do.
    try expectRejected(h, "var Log:i64=0\nXs:[]i64=array{1}\nNote(X:i64)<transacts>:i64=Block{set Log=Log+X;X}\nG()<computes>:i64=Attempt(First[X:Xs,Note(X)],-1)", .call_requires_transacts);
    const root = try h.execute("var Log:i64=0\nXs:[]i64=array{1}\nNote(X:i64)<transacts>:i64=Block{set Log=Log+X;X}\nA:i64=Attempt(First[X:Xs,Note(X)],-1)\nL:i64=Log");
    try expectInt(root, "A", 1);
    try expectInt(root, "L", 1);
}

test "First works in For clauses, Case guards, conditions and inside itself" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Xs:[]i64=array{1,2,3,4}\nRows:[][]i64=array{array{},array{7,8},array{9}}\n" ++
        // As a binding and as the body of a For: an iteration without a hit is skipped.
        "A<public>:[]i64=For(X:Xs,Y:=First[Z:Xs,Z>X,Z],X*10+Y)\n" ++
        "B<public>:[]i64=For(X:Xs,First[Z:Xs,Z>X+1,Z])\n" ++
        "C<public>:[]i64=For(R:Rows,First[V:R,V])\n" ++
        "D<public>:[]i64=For(X:Xs,First[Z:Xs,Z>X,Z]>3,X)\n" ++
        // As the source of a generator and in the bounds of a range.
        "E<public>:[]i64=Attempt(For(V:First[R:Rows,R.Length>1,R],V+1),array{})\n" ++
        "F<public>:[]i64=Attempt(For(I:First[X:Xs,X>2,X]..4,I),array{})\n" ++
        "F2<public>:[]i64=For(X:Xs,V:First[R:Rows,R.Length>X,R],V+X)\n" ++
        // In a Case guard and in an arm.
        "Pick(N:i64)<computes>:i64=Case(N,K:i64 where First[Z:Xs,Z>K,Z]>3=>K*2,K:i64 where logic{First[Z:Xs,Z==K,Z]}=>K,_=>0)\n" ++
        "G<public>:i64=Pick(3)*100+Pick(1)*10+Pick(9)\n" ++
        // In conditions: a plain If, one with bindings, a While.
        "H<public>:i64=If(First[Z:Xs,Z>3,Z]>3,1,0)+If(First[Z:Xs,Z>4,Z]>3,10,0)\n" ++
        "I<public>:i64=If(V:=First[Z:Xs,Z>2,Z],W:=First[Z:Xs,Z>V,Z],V*10+W,0)\n" ++
        "Count()<transacts>:i64=Block{var T:i64=0;While(N:=First[Z:Xs,Z>T,Z],N>0,set T=N);T}\nJ<public>:i64=Count()\n");
    try expectIntegers(x, "A", &.{ 12, 23, 34 });
    try expectIntegers(x, "B", &.{ 3, 4 });
    try expectIntegers(x, "C", &.{ 7, 9 });
    try expectIntegers(x, "D", &.{3});
    try expectIntegers(x, "E", &.{ 8, 9 });
    try expectIntegers(x, "F", &.{ 3, 4 });
    // An inner source that finds no row skips the iteration: only X=1 has a row longer than itself.
    try expectIntegers(x, "F2", &.{ 8, 9 });
    try expectInt(x, "G", 6 * 100 + 1 * 10 + 0);
    try expectInt(x, "H", 1);
    try expectInt(x, "I", 34);
    try expectInt(x, "J", 4);
    // (Two programs: every generator is two functions, and the bootstrap profile has 64.)
    const y = try h.execute("Xs:[]i64=array{1,2,3,4}\nRows:[][]i64=array{array{},array{7,8},array{9}}\n" ++
        // Nested: in a binding, a filter, the body and the source of another First.
        "K<public>:i64=Attempt(First[X:Xs,Y:=First[Z:Xs,Z>X+1,Z],X*10+Y],-1)\n" ++
        "L<public>:i64=Attempt(First[X:Xs,First[Z:Xs,Z==X*2,Z]>3,X],-1)\n" ++
        "N<public>:i64=Attempt(First[X:Xs,First[Z:Xs,Z>X+2,Z*X]],-1)\n" ++
        "O<public>:i64=Attempt(First[V:First[R:Rows,R.Length>0,R],V>7,V],-1)\n" ++
        "P<public>:i64=Attempt(Attempt(First[X:Xs,X>9,X],First[X:Xs,X>3,X]),-1)\n" ++
        // Next to a program's own failable function of the same name, which is still a call.
        "Q<public>:logic=logic{First[X:Xs,X>3,X]} and not logic{First[X:Xs,X>4,X]}\n");
    try expectInt(y, "K", 13);
    try expectInt(y, "L", 2);
    try expectInt(y, "N", 4);
    try expectInt(y, "O", 8);
    try expectInt(y, "P", 4);
    try expectLogic(y, "Q", true);
}

test "a program's own function named First is still called, with either bracket" {
    const h = try harness.create();
    defer scratch.release(h);
    const own = "First(Xs:[]i64)<computes><decides>:i64=Xs[0]\nFirst(Xs:[]string)<computes><decides>:string=Xs[0]\nEmpty:[]i64=array{}\nItems:[]i64=array{7,8}\n" ++
        "A<public>:i64=Attempt(First[Items],-1)\nB<public>:string=Attempt(First[array{\"x\"}],\"-\")\nC<public>:i64=Attempt(First[Empty],-1)\n";
    const program = try h.compile(own);
    // No macro is used, so the module has no library block, as before RFC-0072.
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
    try std.testing.expectEqual(own.len, program.source.len);
    const x = (try h.run(program, 131072)).ok;
    try expectInt(x, "A", 7);
    try std.testing.expectEqualStrings("x", x.get("B").?.string);
    try expectInt(x, "C", -1);
    // The form and the function live side by side: a generator at the head makes it the form.
    const y = try h.execute(own ++ "D<public>:i64=Attempt(First[X:Items,X>7,X]+First[Items],-1)\n");
    try expectInt(y, "D", 15);
    const z = try h.execute("First(X:i64)<computes>:i64=X+1\nXs:[]i64=array{3}\nA<public>:i64=First(2)+Attempt(First[X:Xs,First(X)],0)\n");
    try expectInt(z, "A", 7);
}

test "First reports malformed clauses, a missing failure context and type errors at the call" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "Xs:[]i64=array{1,2}\nN:i64=3\n";
    for ([_]struct { []const u8, types.Diagnostic.Code, []const u8 }{
        // It can fail, so it needs a failure context, and the report names the call.
        .{ "A:i64=First[X:Xs,X]", .failure_context_required, "First" },
        .{ "F()<computes>:i64=First[X:Xs,X>1,X]", .failure_context_required, "First" },
        .{ "A:[]i64=For(X:Xs,Fn(Y:i64):i64{First[Z:Xs,Z>Y,Z]}(X))", .failure_context_required, "First" },
        // The last argument is the body.
        .{ "A:i64=Attempt(First[X:Xs],0)", .for_syntax, "First" },
        .{ "A:i64=Attempt(First[X:Xs,Y:Xs],0)", .for_syntax, "Y" },
        .{ "A:i64=Attempt(First[X:Xs,Y:=3],0)", .for_syntax, "Y" },
        .{ "A:i64=Attempt(First[X:Xs,Y:1..2],0)", .for_syntax, "Y" },
        // Clauses that lack a part.
        .{ "A:i64=Attempt(First[X:Xs,,X],0)", .for_syntax, "First" },
        .{ "A:i64=Attempt(First[X:Xs,Y:,X],0)", .for_syntax, "Y" },
        .{ "A:i64=Attempt(First[X:1..,X],0)", .for_syntax, "X" },
        .{ "A:i64=Attempt(First[X:..3,X],0)", .for_syntax, "X" },
        .{ "A:i64=Attempt(First[I->X:1..3,X],0)", .for_syntax, "I" },
        .{ "A:i64=Attempt(First[X:Xs,I->Y,X],0)", .for_syntax, "I" },
        .{ "A:i64=Attempt(First[X:Xs,X),0)", .for_syntax, "First" },
        .{ "A:i64=Attempt(First[X:Xs,X", .for_syntax, "First" },
        // Without a generator at the head it is a call of a function, which does not exist.
        .{ "A:i64=Attempt(First[Xs],0)", .unknown_name, "First" },
        .{ "A:i64=Attempt(First[N>2,X:Xs,X],0)", .unknown_name, "First" },
        .{ "A:i64=Attempt(First[Y:=3,X:Xs,X],0)", .unknown_name, "First" },
        .{ "A:i64=Attempt(First(X:Xs,X),0)", .unknown_name, "First" },
        // Types.
        .{ "A:i64=Attempt(First[X:N,X],0)", .type_mismatch, "" },
        .{ "A:i64=Attempt(First[X:1.5..3,X],0)", .type_mismatch, "" },
        .{ "A:string=Attempt(First[X:Xs,X],\"\")", .type_mismatch, "" },
        .{ "A:i64=Attempt(First[X:Xs,X+1,X],0)", .type_mismatch, "" },
        .{ "A:i64=Attempt(First[X:Xs,Missing>1,X],0)", .unknown_name, "Missing" },
        .{ "A:i64=Attempt(First[X:Xs,Y:=1,Y:=2,X],0)", .duplicate_name, "Y" },
        // Generated names stay out of reach.
        .{ "A:i64=Attempt(First[X:Xs,__for_s(0)],0)", .unknown_name, "__for_s" },
        .{ "A:i64=Attempt(First[X:Xs,__for_items.Length>0,X],0)", .unknown_name, "__for_items" },
        .{ "A:i64=Attempt(First[__for_f:Xs,__for_f],0)", .expected_parameter, "__for_f" },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, case[0] });
        const result = h.front.compile(source);
        if (result == .ok) std.debug.print("compiled: {s}\n", .{case[0]});
        try std.testing.expect(result == .failed);
        if (result.failed.code != case[1]) std.debug.print("{s}: {s}\n", .{ case[0], result.failed.message() });
        try std.testing.expectEqual(case[1], result.failed.code);
        // The report lies in the program's own text, at the word it is about.
        try std.testing.expect(result.failed.span.end <= source.len);
        if (case[2].len != 0) {
            const blamed = source[result.failed.span.start..result.failed.span.end];
            if (!std.mem.eql(u8, case[2], blamed)) std.debug.print("{s}: blamed '{s}'\n", .{ case[0], blamed });
            try std.testing.expectEqualStrings(case[2], blamed);
        }
    }
    try expectInt(try h.execute("Xs:[]i64=array{1,2}\nA<public>:i64=Attempt(First[X:Xs,X>1,X],0)"), "A", 2);
}

test "First with many generators gets the Fn words its pool lacks, in every module" {
    const h = try harness.create();
    defer scratch.release(h);
    const one = "A<public>:i64=Attempt(First[X:1..2,X],0)";
    // A module that uses the form carries its templates and the words for its functions as
    // generated lines after everything else in its block; the pool is sized without it.
    try std.testing.expectEqual(one.len + macros.libraryLength(0, .{ .first = true, .words = 4 }), (try h.compile(one)).source.len);
    const five = "A<public>:i64=Attempt(First[V:1..3,B:1..3,C:V..B,D:C..3,E:D..3,V+B+C+D+E>11,V*10000+B*1000+C*100+D*10+E],0)";
    const program = try h.compile(five);
    try std.testing.expect(program.source.len > five.len + macros.libraryLength(0, .{ .first = true, .words = 10 }));
    // The first tuple in order whose sum passes 11: (1,3,1..3,...) reaches 1+3+2+3+3 = 12.
    try expectInt((try h.run(program, 1 << 20)).ok, "A", 13233);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64=Attempt(First[X:L.Items,Y:1..3,Z:L.Pairs(X),Z>X+Y+20,X+Y+Z],-1)\nB<public>:option(i64)=option{L.Find[99]}\nC<public>:i64=Attempt(L.Find[20],-1)" },
        .{ .path = "lib.forb", .source = "Items<public>:[]i64=array{10,20}\nPairs<public>(V:i64)<computes>:[]i64=For(X:1..2,Y:X..2,Q:=V+X,Q>0,Q*Y)\nFind<public>(V:i64)<computes><decides>:i64=First[I->X:Items,X==V,I]" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path, bundled.failed.diagnostic.span.start });
    try std.testing.expect(bundled == .ok);
    const x = (try h.run(bundled.ok, 1 << 20)).ok;
    // Pairs(10) = 11, 22, 24: X=10, Y=1 needs Z > 31, none; Y=2 and 3 neither. Pairs(20) = 21, 42, 44: Y=1, Z=42.
    try expectInt(x, "A", 20 + 1 + 42);
    try std.testing.expect(inside(x, "B") == null);
    try expectInt(x, "C", 1);
}

test "a First iteration costs its state and its region, and fuel is exact in both machines" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const short = (try h.run(try h.compile("A<public>:i64=Attempt(First[I:1..200,I>10,I],-1)"), 131072)).ok;
    const long = (try h.run(try h.compile("A<public>:i64=Attempt(First[I:1..200,I>110,I],-1)"), 131072)).ok;
    // An iteration that fails leaves its state tuple, the tuple's option and its own empty option.
    try std.testing.expectEqual(@as(usize, 300), long.aggregate_values.len - short.aggregate_values.len);
    const steps = (long.call_steps.len - short.call_steps.len) / 100;
    try std.testing.expectEqual(short.call_steps.len + 100 * steps, long.call_steps.len);
    // Two more than before RFC-0076: the loop's `not Found and Index < Count` is a conditional
    // now, and each visit that continues passes its `otherwise` and `merge`.
    try std.testing.expectEqual(@as(usize, 33), steps);
    try std.testing.expectEqual(@as(u32, 100), long.failure_count - short.failure_count);
    const program = try h.compile("Xs:[]i64=array{3,1,2}\nA<public>:i64=Attempt(First[X:Xs,Y:1..X,Z:=Xs[Y],Z>1,X*10+Z],-1)");
    var low: u64 = 0;
    var high: u64 = 131072;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        const result = try h.run(program, middle);
        if (result == .ok) high = middle else {
            try std.testing.expectEqual(types.Diagnostic.Code.work_limit, result.failed.code);
            low = middle;
        }
    }
    try std.testing.expect(high > 50 and high < 4096);
    // X=3: Y=1 gives Xs[1]=1, Y=2 gives Xs[2]=2.
    try expectInt((try h.run(program, high)).ok, "A", 32);
    try std.testing.expectEqual(types.Diagnostic.Code.work_limit, (try h.run(program, high - 1)).failed.code);
    // A range too long to count is the overflow a `For` over it is.
    const overflow = try h.run(try h.compile("Max:i64=9223372036854775807\nA<public>:i64=Attempt(First[I:0-Max..Max,I>0,I],-1)"), 131072);
    try std.testing.expectEqual(types.Diagnostic.Code.arithmetic_overflow, overflow.failed.code);
    // An empty range far apart is not: its count is zero.
    try expectInt(try h.execute("Max:i64=9223372036854775807\nA<public>:i64=Attempt(First[I:Max..0-Max,I],-1)"), "A", -1);
    try expectInt(try h.execute("Max:i64=9223372036854775807\nA<public>:i64=Attempt(First[I:Max-1..Max,I==Max,I],-1)"), "A", std.math.maxInt(i64));
}

/// A generated search: one or two generators over two arrays and ranges, with filters and a
/// body that write a cell, so that the model also says which writes survive.
const FirstModel = struct {
    xs: [5]i64 = undefined,
    xs_len: usize = 0,
    ys: [5]i64 = undefined,
    ys_len: usize = 0,
    /// The outer filter is `T(X) + outer_add > outer_min`.
    outer_add: i64 = 0,
    outer_min: i64 = 0,
    two: bool = false,
    /// The inner generator is `Y:Ys`, `J->Y:Ys` (the body adds J) or `Y:X..range_high`.
    inner: enum { array, keyed, range } = .array,
    range_high: i64 = 0,
    /// The inner filter is `T(Y) * X == product` or `T(Y) != X`.
    product: ?i64 = null,
    /// The body fails unless its value is above `body_min`.
    body_min: i64 = 0,

    fn generate(self: *FirstModel, random: std.Random) void {
        self.xs_len = random.uintLessThan(usize, 6);
        self.ys_len = random.uintLessThan(usize, 6);
        for (self.xs[0..self.xs_len]) |*x| x.* = random.intRangeAtMost(i64, 0, 6);
        for (self.ys[0..self.ys_len]) |*y| y.* = random.intRangeAtMost(i64, 0, 6);
        self.outer_add = random.intRangeAtMost(i64, 0, 3);
        self.outer_min = random.intRangeAtMost(i64, 0, 7);
        self.two = random.uintLessThan(u8, 3) != 0;
        self.inner = random.enumValue(@TypeOf(self.inner));
        self.range_high = random.intRangeAtMost(i64, 0, 7);
        self.product = if (random.boolean()) random.intRangeAtMost(i64, 0, 12) else null;
        self.body_min = random.intRangeAtMost(i64, 0, 30);
    }

    fn writeSource(self: *const FirstModel, out: *std.Io.Writer) !void {
        try out.writeAll("var Log:i64=0\nT(V:i64)<transacts>:i64=Block{set Log=Log*3+V+1;V}\nXs:[]i64=array{");
        for (self.xs[0..self.xs_len], 0..) |x, index| try out.print("{s}{d}", .{ if (index == 0) "" else ",", x });
        try out.writeAll("}\nYs:[]i64=array{");
        for (self.ys[0..self.ys_len], 0..) |y, index| try out.print("{s}{d}", .{ if (index == 0) "" else ",", y });
        try out.print("}}\nRun()<transacts>:i64=Attempt(First[X:Xs,T(X)+{d}>{d}", .{ self.outer_add, self.outer_min });
        if (self.two) {
            switch (self.inner) {
                .array => try out.writeAll(",Y:Ys"),
                .keyed => try out.writeAll(",J->Y:Ys"),
                .range => try out.print(",Y:X..{d}", .{self.range_high}),
            }
            if (self.product) |product| try out.print(",T(Y)*X=={d}", .{product}) else try out.writeAll(",T(Y)!=X");
            try out.print(",Block{{V:=T(X*{d}+Y);Require[V>{d}];V}}", .{ @as(i64, if (self.inner == .keyed) 0 else 10), self.body_min });
            // The keyed form yields the position instead, which the model tracks separately.
            if (self.inner == .keyed) try out.writeAll("*100+J");
        } else try out.print(",Block{{V:=T(X*10);Require[V>{d}];V}}", .{self.body_min});
        try out.writeAll("],-1)\nR<public>:i64=Run()\nL<public>:i64=Log\n");
    }

    fn note(log: *i64, value: i64) i64 {
        log.* = log.* * 3 + value + 1;
        return value;
    }

    /// The value and the cell after the search: a log that only the surviving iteration wrote.
    fn evaluate(self: *const FirstModel) struct { value: i64, log: i64 } {
        for (self.xs[0..self.xs_len]) |x| {
            var outer_log: i64 = 0;
            if (!(note(&outer_log, x) + self.outer_add > self.outer_min)) continue;
            if (!self.two) {
                const value = note(&outer_log, x * 10);
                if (value > self.body_min) return .{ .value = value, .log = outer_log };
                continue;
            }
            var position: i64 = 0;
            var y_range = x;
            while (true) : (position += 1) {
                const y = switch (self.inner) {
                    .array, .keyed => blk: {
                        if (position >= self.ys_len) break;
                        break :blk self.ys[@intCast(position)];
                    },
                    .range => blk: {
                        if (y_range > self.range_high) break;
                        defer y_range += 1;
                        break :blk y_range;
                    },
                };
                // An inner iteration starts from what its outer iteration wrote so far.
                var log = outer_log;
                const passes = if (self.product) |product| note(&log, y) * x == product else note(&log, y) != x;
                if (!passes) continue;
                const value = note(&log, x * @as(i64, if (self.inner == .keyed) 0 else 10) + y);
                if (value <= self.body_min) continue;
                return .{ .value = if (self.inner == .keyed) value * 100 + position else value, .log = log };
            }
        }
        return .{ .value = -1, .log = 0 };
    }
};

test "generated First searches agree with a model on their value and on the writes that survive" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x72_f1_57);
    const random = prng.random();
    var found: usize = 0;
    var nested: usize = 0;
    for (0..400) |round| {
        var model: FirstModel = .{};
        model.generate(random);
        var buffer: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try model.writeSource(&out);
        const program = h.compile(out.buffered()) catch |err| {
            std.debug.print("round {d}\n", .{round});
            return err;
        };
        const result = try h.run(program, 1 << 20);
        if (result == .failed) std.debug.print("round {d}: {s}\n{s}", .{ round, result.failed.message(), out.buffered() });
        const want = model.evaluate();
        const value = try int(result.ok, "R");
        const log = try int(result.ok, "L");
        if (want.value != value or want.log != log) std.debug.print("round {d}: {d} log {d}, model {d} log {d}\n{s}", .{ round, value, log, want.value, want.log, out.buffered() });
        try std.testing.expectEqual(want.value, value);
        try std.testing.expectEqual(want.log, log);
        found += @intFromBool(want.value != -1);
        nested += @intFromBool(want.value != -1 and model.two);
    }
    // The generator is worth its name: searches hit and miss, with one level and with two.
    try std.testing.expect(found > 120 and found < 360);
    try std.testing.expect(nested > 40);
}

// ---------------------------------------------------------------------------------------
// Optional chaining
// ---------------------------------------------------------------------------------------

test "optional chaining reads fields, calls methods and indexes through an option, failing when it is empty" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Entity:=class{\n  Name:string=\"Unknown\"\n  var Health:i64=100\n  TakeDamage(D:i64)<transacts>:i64=Block{set Self.Health=Self.Health-D;Self.Health}\n" ++
        "  Check(Min:i64)<transacts><decides>:i64=Block{Require[Self.Health>Min];Self.Health}\n}\n" ++
        "Link:=class{\n  Value:i64\n  var Next:option(Link)\n}\nPoint:=struct{X:i64,Y:i64}\n" ++
        "Some:option(Entity)=option{Entity{}}\nNobody:option(Entity)=option{}\n" ++
        "Tail:=Link{Value:=2,Next:=option{}}\nHead:option(Link)=option{Link{Value:=1,Next:=option{Tail}}}\n" ++
        "P:option(Point)=option{Point{X:=3,Y:=4}}\nNoPoint:option(Point)=option{}\n" ++
        "Pair:option(tuple(i64,string))=option{tuple{42,\"answer\"}}\nNoPair:option(tuple(i64,string))=option{}\n" ++
        "Items:option([]i64)=option{array{7,8}}\nTable:option(map(string,i64))=option{map{\"k\"=>5}}\n" ++
        "Deep:option(option(i64))=option{option{6}}\nHollow:option(option(i64))=option{option{}}\n" ++
        "Run()<transacts>:[]i64=array{\n" ++
        // The Book's examples: a field, a method that runs only when present, a chain.
        "  If(N:=Some?.Name,N==\"Unknown\",1,0),\n" ++
        "  Attempt(Some?.TakeDamage(10),-1),\n  Attempt(Some?.Health,-1),\n" ++
        "  Attempt(Nobody?.TakeDamage(10),-1),\n  Attempt(Nobody?.Health,-1),\n" ++
        "  Attempt(Head?.Next?.Value,-1),\n  Attempt(Head?.Next?.Next?.Value,-1),\n  Attempt(Head?.Value,-1),\n" ++
        // A failable method after the chain, and a struct field.
        "  Attempt(Some?.Check[50],-1),\n  Attempt(Some?.Check[95],-1),\n" ++
        "  Attempt(P?.X+P?.Y,-1),\n  Attempt(NoPoint?.X,-1),\n" ++
        // The positional forms: a tuple element and an array or map element.
        "  Attempt(Pair?(0),-1),\n  Attempt(NoPair?(0),-1),\n" ++
        "  Attempt(Items?[1],-1),\n  Attempt(Items?[5],-1),\n  Attempt(Table?[\"k\"],-1),\n  Attempt(Table?[\"z\"],-1),\n" ++
        // Nested options unwrap one level per `?`.
        "  Attempt(Deep??,-1),\n  Attempt(Hollow??,-1),\n  Attempt(If(Hollow?.IsSet,1,0),-1)\n}\n" ++
        "R<public>:[]i64=Run()\nS<public>:string=Attempt(Pair?(1),\"-\")\n" ++
        "T<public>:logic=logic{Head?.Next?.Next?.Value}\nU<public>:option(i64)=option{NoPoint?.X}\nV<public>:option(i64)=option{P?.Y}\n");
    try expectIntegers(x, "R", &.{ 1, 90, 90, -1, -1, 2, -1, 1, 90, -1, 7, -1, 42, -1, 8, -1, 5, -1, 6, -1, 0 });
    try std.testing.expectEqualStrings("answer", x.get("S").?.string);
    try expectLogic(x, "T", false);
    try std.testing.expect(inside(x, "U") == null);
    try std.testing.expectEqual(@as(i64, 4), inside(x, "V").?.integer);
    // The chain is failable like the unwrap it is: outside a failure context it is rejected.
    try expectRejected(h, "P:option(tuple(i64,i64))=option{tuple{1,2}}\nA:i64=P?(0)", .failure_context_required);
    try expectRejected(h, "Point:=struct{X:i64}\nP:option(Point)=option{Point{X:=1}}\nA:i64=P?.X", .failure_context_required);
    try expectRejected(h, "Point:=struct{X:i64}\nP:Point=Point{X:=1}\nA:i64=Attempt(P?.X,0)", .type_mismatch);
    try expectRejected(h, "Point:=struct{X:i64}\nP:option(Point)=option{Point{X:=1}}\nA:i64=Attempt(P?.Z,0)", .unknown_field);
    // Without the `?` the option itself has no such member.
    try expectRejected(h, "Point:=struct{X:i64}\nP:option(Point)=option{Point{X:=1}}\nA:i64=Attempt(P.X,0)", .unknown_field);
}

test "a method reached through an empty option does not run, and one in a failed chain is undone" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Calls:i64=0\nCounter:=class{\n  var N:i64=0\n  Bump()<transacts>:option(Counter)=Block{set Self.N=Self.N+1;set Calls=Calls+1;option{}}\n" ++
        "  Same()<transacts>:option(Counter)=Block{set Self.N=Self.N+10;set Calls=Calls+1;option{Self}}\n}\n" ++
        "C:=Counter{}\nSome:option(Counter)=option{C}\nNone:option(Counter)=option{}\n" ++
        "Run()<transacts>:[]i64=array{\n" ++
        "  Attempt(None?.Same()?.N,-1),\n  Calls,\n" ++
        // `Bump` runs and writes, then its empty result fails the chain: the write is undone.
        "  Attempt(Some?.Bump()?.N,-1),\n  Calls,\n  C.N,\n" ++
        "  Attempt(Some?.Same()?.Same()?.N,-1),\n  Calls,\n  C.N\n}\nR<public>:[]i64=Run()\n");
    try expectIntegers(x, "R", &.{ -1, 0, -1, 0, 0, 20, 2, 20 });
}

// ---------------------------------------------------------------------------------------
// Programs that compiled before RFC-0072
// ---------------------------------------------------------------------------------------

test "a program's own generic function named First compiles as it did" {
    const h = try harness.create();
    defer scratch.release(h);
    // The header `First[T:type](...)` starts `Name:` like a generator; the kind word tells it apart.
    for ([_]struct { []const u8, i64 }{
        .{ "First[T:type](X:T)<computes>:T{X}\nA<public>:i64=First[i64](41)", 41 },
        .{ "Xs:[]i64=array{7,8}\nFirst[T:type](Items:[]T)<computes><decides>:T{Items[0]}\nA<public>:i64=Attempt(First[i64][Xs],-1)", 7 },
        .{ "First[T:comparable](X:T,Y:T)<computes>:i64{If(X==Y,1,0)}\nA<public>:i64=First[i64](4,4)", 1 },
        .{ "var Cell:i64=0\nFirst[T:type,E:effect](F:function<E>(tuple(T),T),X:T)<E>:T{F(X)}\nBump(X:i64)<transacts>:i64=Block{set Cell=Cell+X;Cell}\nA<public>:i64=First[i64,transacts](Bump,5)", 5 },
        .{ "First [ T : type ] (X:T)<computes>:T{X}\nA<public>:i64=First[i64](41)", 41 },
    }) |case| {
        const program = try h.compile(case[0]);
        // No macro: one pass and no library block.
        try std.testing.expectEqual(@as(u32, 1), h.front.passes);
        try std.testing.expectEqual(case[0].len, program.source.len);
        try expectInt((try h.run(program, 131072)).ok, "A", case[1]);
    }
    // Next to a `For`, and next to the form itself.
    const with_for = "Xs:[]i64=array{7,8}\nFirst[T:type](X:T)<computes>:T{X}\nA<public>:[]i64=For(X:Xs,First[i64](X))";
    const program = try h.compile(with_for);
    try std.testing.expectEqual(with_for.len + macros.libraryLength(1, .{}), program.source.len);
    try expectIntegers((try h.run(program, 131072)).ok, "A", &.{ 7, 8 });
    const both = try h.execute("Xs:[]i64=array{7,8}\nFirst[T:type](X:T)<computes>:T{X}\nA<public>:i64=Attempt(First[X:Xs,X>7,First[i64](X)],-1)");
    try expectInt(both, "A", 8);
}

test "a module without the forms of RFC-0072 has the library block and the spans it had" {
    const h = try harness.create();
    defer scratch.release(h);
    // Three generators need `Fn` words beyond the pool, which lie after the templates: the
    // places of the six functions are those the compiler before RFC-0072 reported, less the
    // line of `Case` words that every block had then and this module, which has no pattern
    // `Case`, has no more.
    const source = "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,Y:Xs,Z:Xs,X*100+Y*10+Z)\n";
    const case_line: u32 = macros.case_text.len + 2;
    const expected = [_]u32{ 77, 3244 - case_line, 74, 3247 - case_line, 71, 3250 - case_line };
    {
        const program = try h.compile(source);
        try std.testing.expectEqual(source.len + macros.libraryLength(1, .{ .words = 9, .loops = true }), program.source.len);
        try std.testing.expectEqual(expected.len, program.functions.len);
        for (expected, program.functions) |want, function| try std.testing.expectEqual(want, function.name.start);
    }
    // Text that only looks like the form (a comment, a string) changes nothing but its own length.
    const tail = "# First[X:Xs, X>1, X] First[I->V:Xs,V]\nS:string=\"First[X:Xs,X]\"\n";
    const program = try h.compile(source ++ tail);
    try std.testing.expectEqual(source.len + tail.len + macros.libraryLength(1, .{ .words = 9, .loops = true }), program.source.len);
    for (expected, program.functions) |want, function| try std.testing.expectEqual(want + @as(u32, if (want > source.len) tail.len else 0), function.name.start);
    // A module that does use the form gets its templates after all of that.
    const uses = try h.compile(source ++ "B<public>:i64=Attempt(First[X:Xs,X>1,X],-1)\n");
    try std.testing.expect(uses.source.len > source.len + macros.libraryLength(1, .{ .words = 9, .first = true, .loops = true }));
}

test "a program at the source and token limits of the bootstrap profile still compiles" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const head = "Xs:[]i64=array{1,2}\nA<public>:[]i64=For(X:Xs,X+1)\n#";
    // The longest comment that fits beside the block of one `For`, as before RFC-0072.
    const room = types.limits.source_bytes - head.len - macros.libraryLength(1, .{});
    const buffer = try std.testing.allocator.alloc(u8, types.limits.source_bytes + 1);
    defer std.testing.allocator.free(buffer);
    @memcpy(buffer[0..head.len], head);
    @memset(buffer[head.len..], 'c');
    try expectIntegers((try h.run(try h.compile(buffer[0 .. head.len + room]), 131072)).ok, "A", &.{ 2, 3 });
    try expectRejected(h, buffer[0 .. head.len + room + 1], .source_limit);
}

test "an intrinsic name inside a class that has a member of that name is not the intrinsic" {
    const h = try harness.create();
    defer scratch.release(h);
    inline for (.{ "BitAnd", "BitOr", "BitXor", "BitNot" }) |name| {
        const arguments = if (comptime std.mem.eql(u8, name, "BitNot")) "(1)" else "(1,2)";
        const parameters = if (comptime std.mem.eql(u8, name, "BitNot")) "(A:i64)" else "(A:i64,B:i64)";
        // A method of the name, in the class or inherited, and a field of the name: the bare
        // name is the unknown name it was before RFC-0072, in methods before and after it.
        try expectRejected(h, "Box:=class{\n  N:i64\n  Use()<transacts>:i64=" ++ name ++ arguments ++ "\n  " ++ name ++ parameters ++ "<transacts>:i64=A+Self.N\n}", .unknown_name);
        try expectRejected(h, "Box:=class{\n  N:i64\n  " ++ name ++ parameters ++ "<transacts>:i64=A+Self.N\n  Use()<transacts>:i64=" ++ name ++ arguments ++ "\n}", .unknown_name);
        try expectRejected(h, "Base:=class{\n  " ++ name ++ parameters ++ "<transacts>:i64=A\n}\nBox:=class(Base){\n  Use()<transacts>:i64=" ++ name ++ arguments ++ "\n}", .unknown_name);
        try expectRejected(h, "Box:=class{\n  " ++ name ++ ":i64\n  Use()<transacts>:i64=" ++ name ++ arguments ++ "\n}", .unknown_name);
        // Through `Self` it is the member; in a class without such a member, and outside
        // classes, it is the intrinsic.
        const x = try h.execute("Box:=class{\n  N:i64\n  " ++ name ++ parameters ++ "<transacts>:i64=A+Self.N\n  Use()<transacts>:i64=Self." ++ name ++ arguments ++ "\n}\n" ++
            "Other:=class{\n  Use()<transacts>:i64=" ++ name ++ arguments ++ "\n}\n" ++
            "A<public>:i64=Box{N:=100}.Use()\nB<public>:i64=Other{}.Use()\nC<public>:i64=" ++ name ++ arguments ++ "\n");
        try expectInt(x, "A", 101);
        try expectInt(x, "B", try int(x, "C"));
    }
}

test "a constructor in a generic body is one constructor however often it is specialized" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("At[T:type](Items:[]T,I:i64)<computes>:option(T){option{Items[I]}}\nXs:[]i64=array{1,2}\n" ++
        "A<public>:option(i64)=At[i64](Xs,1)\nB<public>:option(i64)=At[i64](Xs,4)\nC<public>:option(string)=At[string](array{\"a\"},0)\n" ++
        "D<public>:option(logic)=At[logic](array{true},3)\nE<public>:option(float)=At[float](array{1.5},0)\n");
    try std.testing.expectEqual(@as(i64, 2), inside(x, "A").?.integer);
    try std.testing.expect(inside(x, "B") == null);
    try std.testing.expectEqualStrings("a", inside(x, "C").?.string);
    try std.testing.expect(inside(x, "D") == null);
    try std.testing.expect(inside(x, "E") != null);
    // Four specializations noted it; it is kept once.
    try std.testing.expectEqual(@as(u32, 1), h.front.option_caught_count);
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
}
