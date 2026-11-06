//! The breaking alignments of RFC-0076: short-circuit `and`/`or`, comparison chains and the
//! dropped-comparison error, no shadowing, `<internal>` members, `class<unique>` equality,
//! distinct overloads, `option{E}` and `If` conditions that catch everywhere, parameter
//! defaults that read earlier parameters, and extension methods beside `using`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");

const Code = types.Diagnostic.Code;

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value.integer != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.integer, expected });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectLogic(x: anytype, name: []const u8, expected: bool) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value.boolean != expected) std.debug.print("{s}: {}, expected {}\n", .{ name, value.boolean, expected });
    try std.testing.expectEqual(expected, value.boolean);
}

/// The source is refused with `code`, and the diagnostic covers exactly `text`.
fn expectRefused(h: *harness.Harness, source: []const u8, code: Code, text: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.Compiled;
    }
    if (result.failed.code != code or !std.mem.eql(u8, result.failed.span.text(source), text)) std.debug.print("{s} at `{s}`, expected {s} at `{s}`: {s}\n", .{ @tagName(result.failed.code), result.failed.span.text(source), @tagName(code), text, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(text, result.failed.span.text(source));
}

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

fn bundleRefused(h: *harness.Harness, main: []const u8, lib: []const u8, code: Code, path: []const u8) !void {
    const result = bundle(h, main, lib);
    if (result != .failed) {
        std.debug.print("bundle compiled, expected {s}: {s}\n", .{ @tagName(code), main });
        return error.Compiled;
    }
    if (result.failed.diagnostic.code != code) std.debug.print("{s} in {s}, expected {s}: {s}\n", .{ @tagName(result.failed.diagnostic.code), result.failed.path, @tagName(code), main });
    try std.testing.expectEqual(code, result.failed.diagnostic.code);
    try std.testing.expectEqualStrings(path, result.failed.path);
}

fn bundleRuns(h: *harness.Harness, main: []const u8, lib: []const u8) !evaluator.Execution {
    const result = bundle(h, main, lib);
    if (result != .ok) {
        std.debug.print("bundle failed: {s} in {s} at {d}\n", .{ result.failed.diagnostic.message(), result.failed.path, result.failed.diagnostic.span.start });
        return error.Compile;
    }
    return (try h.run(result.ok, 1 << 20)).ok;
}

fn count(nodes: anytype, comptime kind: []const u8) usize {
    var total: usize = 0;
    for (nodes) |entry| {
        const node = if (@hasField(@TypeOf(entry), "node")) entry.node else entry;
        if (std.mem.eql(u8, @tagName(node.kind), kind)) total += 1;
    }
    return total;
}

/// The least fuel a program completes with; every budget probed is held to both machines.
fn leastFuel(h: *harness.Harness, program: types.Program) !u64 {
    var low: u64 = 0;
    var high: u64 = 1 << 16;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        const result = try h.run(program, middle);
        if (result == .ok) high = middle else {
            try std.testing.expectEqual(Code.work_limit, result.failed.code);
            low = middle;
        }
    }
    return high;
}

// ---- D2: `and` and `or`

test "and and or evaluate the right operand only when the left one does not decide" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Calls:i64=0
        \\Hit(V:logic)<transacts>:logic=Block{set Calls=Calls+1;V}
        \\Items:[]i64=array{4,5}
        \\Safe(I:i64)<computes>:logic=I<Items.Length and Attempt(Items[I],0)>4
        \\A<public>:logic=false and Hit(true)
        \\A1<public>:i64=Calls
        \\B<public>:logic=true or Hit(false)
        \\B1<public>:i64=Calls
        \\C<public>:logic=true and Hit(true)
        \\C1<public>:i64=Calls
        \\D<public>:logic=false or Hit(false)
        \\D1<public>:i64=Calls
        \\E<public>:logic=false and (1/0==0)
        \\F<public>:logic=true or (1/0==0)
        \\G<public>:logic=Safe(1) and not Safe(7)
        \\H<public>:logic=Hit(false) and Hit(true) or Hit(true) and Hit(false) or Hit(true)
        \\H1<public>:i64=Calls
    );
    try expectLogic(x, "A", false);
    try expectInt(x, "A1", 0);
    try expectLogic(x, "B", true);
    try expectInt(x, "B1", 0);
    try expectLogic(x, "C", true);
    try expectInt(x, "C1", 1);
    try expectLogic(x, "D", false);
    try expectInt(x, "D1", 2);
    try expectLogic(x, "E", false);
    try expectLogic(x, "F", true);
    try expectLogic(x, "G", true);
    // false, (skipped); true, false; true: four calls.
    try expectLogic(x, "H", true);
    try expectInt(x, "H1", 6);
    // When the left operand does not decide, the right one runs and its error is the run's.
    for ([_][]const u8{ "A:logic=true and (1/0==0)", "A:logic=false or (1/0==0)", "F(B:logic)<computes>:logic=B and 1/0==0\nA:logic=F(true)" }) |source| {
        const result = try h.run(try h.compile(source), 4096);
        try std.testing.expectEqual(Code.division_by_zero, result.failed.code);
    }
    try expectRefused(h, "A:logic=1 and true", .type_mismatch, "and");
    try expectRefused(h, "F()<computes>:i64=1\nA:logic=true and F()", .type_mismatch, "and");
    try expectRefused(h, "F()<computes>:i64=1\nA:logic=true or F()", .type_mismatch, "or");
}

test "a plain right operand keeps the strict node and anything else is a conditional" {
    const h = try harness.create();
    defer scratch.release(h);
    // Plain: literals, names of logic, i64 and float values, comparisons, not, and, or, parentheses.
    inline for (.{
        "F(A:i64,B:i64,L:logic)<computes>:logic=A<B and B<10",
        "F(A:i64,B:i64,L:logic)<computes>:logic=L or not (A==-1) and 2.5>1.0",
        "F(A:i64,B:i64,L:logic)<computes>:logic=Block{C:i64=A+B;L and (C>0 or true)}",
        "K:i64=3\nF(A:i64,B:i64,L:logic)<computes>:logic=L and K>A",
    }) |source| {
        const program = try h.compile(source ++ "\nR<public>:logic=F(1,2,true)");
        try std.testing.expectEqual(@as(usize, 0), count(program.function_nodes, "if_begin"));
        try std.testing.expect(count(program.function_nodes, "logic_binary") >= 1);
    }
    // Not plain: a call, an index, a field, arithmetic, a string, a module variable.
    inline for (.{
        "G()<computes>:logic=true\nF(A:i64,B:i64,L:logic)<computes>:logic=L and G()",
        "Xs:[]i64=array{1}\nF(A:i64,B:i64,L:logic)<computes>:logic=L and Xs.Length>A",
        "F(A:i64,B:i64,L:logic)<computes>:logic=L or A+1>B",
        "F(A:i64,B:i64,L:logic)<computes>:logic=L or A/B>0",
        "S:string=\"a\"\nF(A:i64,B:i64,L:logic)<computes>:logic=L and S==\"a\"",
        "var V:i64=3\nF(A:i64,B:i64,L:logic)<transacts>:logic=L and V>A",
    }) |source| {
        const program = try h.compile(source ++ "\nR<public>:logic=F(1,2,true)");
        try std.testing.expectEqual(@as(usize, 1), count(program.function_nodes, "if_begin"));
        try std.testing.expectEqual(@as(usize, 1), count(program.function_nodes, "merge"));
        try std.testing.expectEqual(@as(usize, 0), count(program.function_nodes, "logic_binary"));
        _ = try h.run(program, 4096);
    }
    // A left-associated run of operators nests nothing: each conditional closes before the next opens.
    // The depth is a capacity of the profile, so the text is sized from it.
    const buffer = try std.testing.allocator.alloc(u8, 256 + 16 * (types.limits.control_depth + 8));
    defer std.testing.allocator.free(buffer);
    var out = std.Io.Writer.fixed(buffer);
    try out.writeAll("T()<computes>:logic=true\nR<public>:logic=T()");
    for (0..types.limits.control_depth + 8) |_| try out.writeAll(" and T()");
    try expectLogic(try h.execute(out.buffered()), "R", true);
    // Nested to the right they do nest, and the control budget is the limit.
    out = std.Io.Writer.fixed(buffer);
    try out.writeAll("T()<computes>:logic=true\nR<public>:logic=");
    for (0..types.limits.control_depth + 1) |_| try out.writeAll("T() and (");
    try out.writeAll("T()");
    for (0..types.limits.control_depth + 1) |_| try out.writeAll(")");
    try std.testing.expectEqual(Code.control_limit, h.front.compile(out.buffered()).failed.code);
}

test "a skipped operand costs no fuel and both machines agree at every budget" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "var Calls:i64=0\nSlow(N:i64)<transacts>:logic=Block{set Calls=Calls+Iterate(Fn(S:i64)<computes>:i64{S+1},N,0);true}\nF(L:logic)<transacts>:logic=";
    const skipped = try leastFuel(h, try h.compile(prelude ++ "L and Slow(200)\nR<public>:logic=F(false)\nC<public>:i64=Calls"));
    const taken = try leastFuel(h, try h.compile(prelude ++ "L and Slow(200)\nR<public>:logic=F(true)\nC<public>:i64=Calls"));
    const skipped_or = try leastFuel(h, try h.compile(prelude ++ "L or Slow(200)\nR<public>:logic=F(true)\nC<public>:i64=Calls"));
    // The 200 visits are paid for only when the operand runs.
    try std.testing.expect(taken > skipped + 200);
    try std.testing.expect(skipped < 64 and skipped_or < 64);
    // Every budget from nothing to enough: the same outcome in both machines, checked by `run`.
    const program = try h.compile(prelude ++ "L and Slow(3) or Slow(2)\nR<public>:logic=F(false)\nC<public>:i64=Calls");
    const enough = try leastFuel(h, program);
    var budget: u64 = 0;
    while (budget <= enough) : (budget += 1) {
        const result = try h.run(program, budget);
        if (budget < enough) try std.testing.expectEqual(Code.work_limit, result.failed.code) else try expectInt(result.ok, "C", 2);
    }
}

test "an operand that assigns a local hands the assignment on only when it ran" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\F(L:logic)<transacts>:i64=Block{var N:i64=1;K:logic=L and Block{set N=N+10;true};var M:i64=N;J:logic=L or Block{set M=M+100;false};M*2+If(K or J,1,0)}
        \\A<public>:i64=F(true)
        \\B<public>:i64=F(false)
    );
    // true: N becomes 11, the `or` skips its write: 11*2+1. false: N stays 1, M becomes 101.
    try expectInt(x, "A", 23);
    try expectInt(x, "B", 202);
}

// ---- D1: chains and the dropped comparison

test "a comparison chain holds when every link does and evaluates each operand once" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Calls:i64=0
        \\Mid(V:i64)<transacts>:i64=Block{set Calls=Calls+1;V}
        \\In(V:i64)<computes>:logic=0<=V<=100
        \\A<public>:logic=In(0) and In(100) and In(57)
        \\B<public>:logic=In(-1) or In(101)
        \\C<public>:logic=1<2<3<4<5
        \\D<public>:logic=1<2>3
        \\E<public>:logic=1<=1<2==2!=3>=3>2
        \\F<public>:logic=1<Mid(5)<9
        \\F1<public>:i64=Calls
        \\G<public>:logic=3<Mid(2)<Mid(9)
        \\G1<public>:i64=Calls
        \\H<public>:logic=2<1<1/0
        \\I<public>:logic=1.5<2.0<=2.0
        \\J<public>:logic=not (1<2<3) or 3>2>1
        \\K<public>:i64=If(1<2<3,7,8)
    );
    try expectLogic(x, "A", true);
    try expectLogic(x, "B", false);
    try expectLogic(x, "C", true);
    try expectLogic(x, "D", false);
    try expectLogic(x, "E", true);
    try expectLogic(x, "F", true);
    // The middle operand is one call, though two links read it.
    try expectInt(x, "F1", 1);
    // The first link fails, so the last operand is not evaluated.
    try expectLogic(x, "G", false);
    try expectInt(x, "G1", 2);
    try expectLogic(x, "H", false);
    try expectLogic(x, "I", true);
    try expectLogic(x, "J", true);
    try expectInt(x, "K", 7);
    const reached = try h.run(try h.compile("A:logic=1<2<1/0"), 4096);
    try std.testing.expectEqual(Code.division_by_zero, reached.failed.code);
    // Operands of a link have one type, as in a single comparison.
    inline for (.{ "A:logic=1<2<3.0", "A:logic=1<2.0<3.0", "A:logic=\"a\"==\"a\"<\"b\"" }) |source| try std.testing.expectEqual(Code.type_mismatch, h.front.compile(source).failed.code);
    // With `logic` operands a chain would silently replace `(A == B) == C`: parentheses decide.
    try expectRefused(h, "A:logic=true==true==true", .type_mismatch, "==");
    try std.testing.expectEqual(Code.type_mismatch, h.front.compile("A:logic=1==1==true").failed.code);
    try expectLogic(try h.execute("A<public>:logic=(1==1)==true"), "A", true);
    try expectLogic(try h.execute("A<public>:logic=true==(2==3)"), "A", false);
}

test "a comparison whose result is dropped is refused, and Require makes it a check" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "F(X:i64)<computes><decides>:i64=Block{0<=X;X}", .discarded_comparison, "<=");
    try expectRefused(h, "F(X:i64)<computes>:i64=Block{0<=X<=9;X}", .discarded_comparison, "<=");
    try expectRefused(h, "F(X:i64)<computes>:i64=Block{(X==1);X}", .discarded_comparison, "==");
    try expectRefused(h, "F(X:i64)<computes>:i64=Block{not (X==1);X}", .discarded_comparison, "not");
    try expectRefused(h, "G()<computes>:logic=true\nF(X:i64)<computes>:i64=Block{X>0 and G();X}", .discarded_comparison, "and");
    try expectRefused(h, "G()<computes>:logic=true\nF(X:i64)<computes>:i64=Block{G() or X>0\nX}", .discarded_comparison, "or");
    try expectRefused(h, "A:i64=Block{1!=2;3}", .discarded_comparison, "!=");
    // The statements of a loop body, of deferred code and of a class's block clause are dropped too.
    try expectRefused(h, "F(N:i64)<transacts>:i64=Block{var I:i64=0;While(I<N,Block{I<3;set I=I+1});I}", .discarded_comparison, "<");
    try expectRefused(h, "F(N:i64)<transacts>:i64=Block{var I:i64=0;Loop{set I=I+1;If(I>N,Break(),true);I>3};I}", .discarded_comparison, ">");
    try expectRefused(h, "F(N:i64)<transacts>:i64=Block{Defer{N>3};N}", .discarded_comparison, ">");
    try expectRefused(h, "C:=class{var N:i64=0\nBlock{Self.N==0}}", .discarded_comparison, "==");
    // What is used, bound, returned or handed on is not dropped.
    const x = try h.execute(
        \\G(L:logic)<computes>:logic=L
        \\F(X:i64)<computes><decides>:logic=Block{Require[0<=X<=9];K:logic=X>3;G(X>1);If(X>2,1,2);Block{X>5};K and X>4}
        \\Check(X:i64)<computes><decides>:logic=Block{Require[X>0];X>4}
        \\A<public>:i64=Attempt(If(Check[5],1,2),3)
        \\B<public>:i64=Attempt(Block{V:=Check[0];If(V,1,2)},3)
        \\C<public>:i64=Attempt(If(Check[2],1,2),3)
    );
    try expectInt(x, "A", 1);
    try expectInt(x, "B", 3);
    try expectInt(x, "C", 2);
}

/// A random predicate over `and`, `or`, `not`, parentheses, comparisons and chains, whose
/// operands are literals or calls that log their order, against a model that evaluates lazily.
const Oracle = struct {
    random: std.Random,
    out: *std.Io.Writer,
    /// What the calls logged, as the program computes it: `Log*3+K` for each call, in order.
    log: i64 = 0,
    calls: u32 = 0,
    /// False while the model is in an operand that the rule says is skipped.
    live: bool = true,

    const max_calls = 24;

    fn integer(self: *Oracle) !i64 {
        const value = self.random.intRangeAtMost(i64, -2, 3);
        if (self.calls < max_calls and self.random.uintLessThan(u8, 3) == 0) {
            const key = self.random.intRangeAtMost(i64, 1, 2);
            try self.out.print("N({d},{d})", .{ key, value });
            self.calls += 1;
            if (self.live) self.log = self.log * 3 + key;
        } else if (value < 0) try self.out.print("({d})", .{value}) else try self.out.print("{d}", .{value});
        return value;
    }

    fn compare(op: u8, a: i64, b: i64) bool {
        return switch (op) {
            0 => a < b,
            1 => a <= b,
            2 => a > b,
            3 => a >= b,
            4 => a == b,
            else => a != b,
        };
    }

    /// A comparison or a chain of up to four links.
    fn chain(self: *Oracle) !bool {
        const outer = self.live;
        var left = try self.integer();
        var holds = true;
        const links = self.random.intRangeAtMost(u8, 1, 4);
        for (0..links) |_| {
            const op = self.random.uintLessThan(u8, 6);
            try self.out.writeAll(([_][]const u8{ "<", "<=", ">", ">=", "==", "!=" })[op]);
            // A link is reached only if every link before it held.
            self.live = outer and holds;
            const right = try self.integer();
            if (holds) holds = compare(op, left, right);
            left = right;
        }
        self.live = outer;
        return holds;
    }

    fn atom(self: *Oracle, depth: u8) anyerror!bool {
        const choice = self.random.uintLessThan(u8, 10);
        if (choice == 0 and depth < 4) {
            // `not` binds tighter than a comparison, so its operand is parenthesised.
            try self.out.writeAll("not (");
            const value = try self.atom(depth + 1);
            try self.out.writeAll(")");
            return !value;
        }
        if (choice <= 2 and depth < 4) {
            try self.out.writeAll("(");
            const value = try self.either(depth + 1);
            try self.out.writeAll(")");
            return value;
        }
        if (choice == 3) {
            const value = self.random.boolean();
            try self.out.writeAll(if (value) "true" else "false");
            return value;
        }
        if (choice == 4 and self.calls < max_calls) {
            const value = self.random.boolean();
            const key = self.random.intRangeAtMost(i64, 1, 2);
            try self.out.print("B({d},{s})", .{ key, if (value) "true" else "false" });
            self.calls += 1;
            if (self.live) self.log = self.log * 3 + key;
            return value;
        }
        return self.chain();
    }

    fn both(self: *Oracle, depth: u8) anyerror!bool {
        const outer = self.live;
        var value = try self.atom(depth);
        while (self.random.uintLessThan(u8, 3) == 0) {
            try self.out.writeAll(" and ");
            self.live = outer and value;
            const right = try self.atom(depth);
            value = value and right;
        }
        self.live = outer;
        return value;
    }

    fn either(self: *Oracle, depth: u8) anyerror!bool {
        const outer = self.live;
        var value = try self.both(depth);
        while (self.random.uintLessThan(u8, 3) == 0) {
            try self.out.writeAll(" or ");
            self.live = outer and !value;
            const right = try self.both(depth);
            value = value or right;
        }
        self.live = outer;
        return value;
    }
};

test "500 random predicates of and, or, not and chains meet a lazy model on both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    var generator = std.Random.DefaultPrng.init(0x19b_d2d1);
    var buffer: [8192]u8 = undefined;
    var lazy: usize = 0;
    var skipped: usize = 0;
    for (0..500) |round| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("var Log:i64=0\nN(K:i64,V:i64)<transacts>:i64=Block{set Log=Log*3+K;V}\nB(K:i64,V:logic)<transacts>:logic=Block{set Log=Log*3+K;V}\n");
        // Half at the root and half in a function, where the operands are template nodes.
        const in_function = round % 2 == 0;
        try out.writeAll(if (in_function) "F()<transacts>:logic=" else "R<public>:logic=");
        var oracle: Oracle = .{ .random = generator.random(), .out = &out };
        const expected = try oracle.either(0);
        if (in_function) try out.writeAll("\nR<public>:logic=F()");
        try out.writeAll("\nL<public>:i64=Log");
        const source = out.buffered();
        const program = h.compile(source) catch |err| {
            std.debug.print("round {d}\n", .{round});
            return err;
        };
        if (count(program.nodes, "if_begin") + count(program.function_nodes, "if_begin") != 0) lazy += 1;
        const result = try h.run(program, 1 << 16);
        if (result != .ok) {
            std.debug.print("round {d} failed with {s}: {s}\n", .{ round, result.failed.message(), source });
            return error.Execute;
        }
        const x = result.ok;
        if (x.get("R").?.boolean != expected or x.get("L").?.integer != oracle.log) std.debug.print("round {d}: {s}\n", .{ round, source });
        try expectLogic(x, "R", expected);
        try expectInt(x, "L", oracle.log);
        // The log of a program whose calls all ran is 3^calls-ish; one with fewer skipped something.
        var all: i64 = 0;
        _ = &all;
        if (oracle.calls != 0 and oracle.log < std.math.pow(i64, 3, oracle.calls - 1)) skipped += 1;
    }
    // The generator reaches both lowerings and programs that skip calls.
    try std.testing.expect(lazy > 100 and lazy < 500 and skipped > 50);
}

// ---- D5: shadowing

test "a name may not be declared where it is already visible" {
    const h = try harness.create();
    defer scratch.release(h);
    const rows = [_]struct { source: []const u8, text: []const u8 }{
        // A local against a parameter, a local of a block around it, the function, a module name.
        .{ .source = "F(N:i64)<computes>:i64=Block{N:i64=2;N}", .text = "N" },
        .{ .source = "F(N:i64)<computes>:i64=Block{M:i64=2;Block{M:=3;M}+M}", .text = "M" },
        .{ .source = "F(N:i64)<transacts>:i64=Block{var K:i64=2;Block{var K:i64=3;K}+K}", .text = "K" },
        .{ .source = "F(N:i64)<computes>:i64=Block{F:i64=1;F+N}", .text = "F" },
        .{ .source = "Count:i64=0\nF()<computes>:i64=Block{Count:i64=2;Count}", .text = "Count" },
        .{ .source = "var Cell:i64=0\nA:i64=Block{Cell:=2;Cell}", .text = "Cell" },
        .{ .source = "G()<computes>:i64=1\nA:i64=Block{G:=2;G}", .text = "G" },
        .{ .source = "point:=struct{x:i64=0}\nA:i64=Block{point:=2;point}", .text = "point" },
        .{ .source = "mode:=enum{on,off}\nF(N:i64)<computes>:i64=Block{mode:=N;mode}", .text = "mode" },
        .{ .source = "Thing:=class{N:i64=0}\nF(N:i64)<computes>:i64=Block{Thing:=N;Thing}", .text = "Thing" },
        // The binding or local whose value is being computed.
        .{ .source = "M:option(i64)=option{1}\nX:i64=Case(M,option{X}=>X,_=>0)", .text = "X" },
        .{ .source = "A:i64=Block{T:=Block{T:=1;T};T}", .text = "T" },
        .{ .source = "Row:=[]i64\nA:i64=Block{Row:=2;Row}", .text = "Row" },
        .{ .source = "Id[T:type](X:T)<computes>:T{X}\nA:i64=Block{Id:=2;Id}", .text = "Id" },
        // A parameter against a module name and against its own function.
        .{ .source = "X:i64=5\nF(X:i64)<computes>:i64=X", .text = "X" },
        .{ .source = "G()<computes>:i64=1\nF(G:i64)<computes>:i64=G", .text = "G" },
        .{ .source = "F(F:i64)<computes>:i64=1", .text = "F" },
        .{ .source = "X:i64=5\nC:=class{N:i64=0\nGet(X:i64)<computes>:i64=X}", .text = "X" },
        .{ .source = "X:i64=5\nId[T:type](X:T)<computes>:T{X}\nA:i64=Id[i64](1)", .text = "X" },
        // The parameters and captures of an `Fn` against what is around it.
        .{ .source = "F(N:i64)<computes>:i64=Block{G:=Fn(N:i64){N*2};G(1)}", .text = "N" },
        .{ .source = "F(N:i64)<computes>:i64=Block{K:=1;G:=Fn(M:i64){Block{K:=M;K}};G(1)+K}", .text = "K" },
        .{ .source = "F(N:i64)<computes>:i64=Block{K:=1;G:=Fn[N:i64=K](M:i64)<computes>:i64{N+M};G(1)}", .text = "N" },
        .{ .source = "F(N:i64)<computes>:i64=Block{K:=1;G:=Fn[J:i64=K](M:i64)<computes>:i64{Block{N:=M;N+J}};G(1)+N}", .text = "N" },
        .{ .source = "X:i64=5\nG:function(tuple(i64),i64)=Fn(X:i64)<computes>:i64{X}", .text = "X" },
        // The names that `For`, `First`, `Case` and `If` bind.
        .{ .source = "Xs:[]i64=array{1}\nF(X:i64)<computes>:[]i64=For(X:Xs,X)", .text = "X" },
        .{ .source = "Xs:[]i64=array{1}\nX:i64=1\nA:[]i64=For(X:Xs,X)", .text = "X" },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=For(X:Xs,X:=X+1,X)", .text = "X" },
        .{ .source = "Xs:[]i64=array{1}\nA:[]i64=For(I->X:Xs,Y:Xs,I:=Y,I)", .text = "I" },
        .{ .source = "Xs:[]i64=array{1}\nF(X:i64)<computes>:i64=Attempt(First[X:Xs,X>0,X],0)", .text = "X" },
        .{ .source = "F(M:option(i64),X:i64)<computes>:i64=Case(M,option{X}=>X,_=>0)", .text = "X" },
        .{ .source = "F(M:option(i64),X:i64)<computes>:i64=If(X:=M?,X,0)", .text = "X" },
    };
    for (rows) |row| try expectRefused(h, row.source, .shadowed_name, row.text);
    // Not shadowing: a later declaration, a sibling scope, a field, a named argument, `Self`
    // members, the same explicit capture, the locals a loop carries, a generic's caller.
    const x = try h.execute(
        \\point:=struct{X:i64=0,Y:i64=0}
        \\Before(Total:i64)<computes>:i64=Block{Left:=Block{T:=Total;T+1};Right:=Block{T:=Total;T+2};Kind:=Left;Kind*Right}
        \\Total:i64=3
        \\Kind:=class{N:i64=0}
        \\Fields(X:i64,Y:i64)<computes>:i64=Block{P:=point{X:=X,Y:=Y};P.X*10+P.Y}
        \\Named(Low:i64,High:i64)<computes>:i64=High-Low
        \\Arms(M:option(i64))<computes>:i64=Case(M,option{V} where V>5=>V,option{V}=>0-V,_=>0)
        \\Box:=class{var N:i64=0
        \\  Put(N:i64)<transacts>:i64=Block{set Self.N=N;Self.N}}
        \\Capture(Step:i64)<computes>:i64=Block{G:=Fn[Step:i64=Step](M:i64)<computes>:i64{Step+M};G(1)}
        \\Count(N:i64)<transacts>:i64=Block{var I:i64=0;var S:i64=0;While(I<N,Block{set S=S+I;set I=I+1});For(K:0..N,Block{set S=S+K;K});S}
        \\Apply[T:type](Item:T)<computes>:T{Block{Copy:=Item;Copy}}
        \\Caller(Item:i64)<computes>:i64=Block{Copy:=Apply[i64](Item);Copy+1}
        \\A<public>:i64=Before(1)
        \\B<public>:i64=Fields(4,2)
        \\C<public>:i64=Named(High:=9,Low:=2)
        \\D<public>:i64=Arms(option{7})+Arms(option{3})
        \\E<public>:i64=Box{}.Put(6)
        \\F<public>:i64=Capture(41)
        \\G<public>:i64=Count(4)
        \\H<public>:i64=Caller(8)
    );
    try expectInt(x, "A", 6);
    try expectInt(x, "B", 42);
    try expectInt(x, "C", 7);
    try expectInt(x, "D", 4);
    try expectInt(x, "E", 6);
    try expectInt(x, "F", 42);
    try expectInt(x, "G", 16);
    try expectInt(x, "H", 9);
    // A program cannot write a generated name, so none of its names can clash with one.
    try std.testing.expectEqual(Code.expected_name, h.front.compile("A:i64=Block{__for_items:=1;__for_items}").failed.code);
}

test "names of modules, imports and using may not be shadowed either" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "Limit<public>:i64=10\nScale<public>(X:i64)<computes>:i64=X*2\nHidden:i64=1\nKit<public>:=module{Step<public>:i64=3\nInner<public>:=module{Deep<public>:i64=4}}";
    // An import alias and a module are names like any other.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nF(L:i64)<computes>:i64=L", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nA:i64=Block{L:=1;L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "M:=module{V<public>:i64=1}\nF(M:i64)<computes>:i64=M", lib, .shadowed_name, "main.forb");
    // What a `using` brings in is visible: neither a local nor a declaration may take its name.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nusing{L}\nF(Limit:i64)<computes>:i64=Limit", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nusing{L}\nA:i64=Block{Scale:=1;Scale}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nusing{L}\nLimit:i64=1", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nusing{L.Kit}\nStep:i64=1", lib, .shadowed_name, "main.forb");
    // A name the used module keeps to itself is not visible, so it is free.
    try expectInt(try bundleRuns(h, "L:=import{\"lib.forb\"}\nusing{L}\nHidden:i64=5\nA<public>:i64=Hidden+Limit", lib), "A", 15);
    // A module may not redeclare a name of a scope around it, whatever kind either is.
    try bundleRefused(h, "Seed:i64=1\nM:=module{Seed:i64=2}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "Seed:i64=1\nM:=module{Inner:=module{Seed()<computes>:i64=2}}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "Seed()<computes>:i64=1\nM:=module{Seed(X:i64)<computes>:i64=X}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "Seed:i64=1\nM:=module{F(Seed:i64)<computes>:i64=Seed}", lib, .shadowed_name, "main.forb");
    // Sibling modules do not see each other's names, and a later declaration is not visible yet.
    const x = try bundleRuns(h, "A:=module{Seed<public>:i64=2}\nB:=module{Seed<public>:i64=3\nF<public>(After:i64)<computes>:i64=After+Seed}\nAfter:i64=10\nR<public>:i64=A.Seed*100+B.F(After)", lib);
    try expectInt(x, "R", 213);
}

// ---- D14: member access

test "class and interface members are internal to their module unless marked public" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Account<public>:=class{
        \\  var Balance:i64=0
        \\  Owner<public>:string="none"
        \\  var<internal> Visits<public>:i64=0
        \\  Add(N:i64)<transacts>:i64=Block{set Self.Balance=Self.Balance+N;Self.Balance}
        \\  Deposit<public>(N:i64)<transacts>:i64=Block{set Self.Visits=Self.Visits+1;Self.Add(N)}
        \\}
        \\Open<public>(N:i64)<transacts>:Account=Block{A:=Account{Balance:=N};set A.Visits=1;A}
        \\Peek<public>(A:Account)<transacts>:i64=A.Balance
        \\Named<public>:=interface{
        \\  Label<public>()<transacts>:string
        \\  Code()<transacts>:i64
        \\  Rank<public>:i64=1
        \\  Weight:i64=2
        \\}
        \\Tag<public>:=class(Named){
        \\  Label<override>()<transacts>:string="tag"
        \\  Code<override>()<transacts>:i64=7
        \\}
        \\CodeOf<public>(N:Named)<transacts>:i64=N.Code()+N.Weight
    ;
    const head = "L:=import{\"lib.forb\"}\nA:=L.Open(5)\n";
    // The module that declares the class uses every member; another module only the public ones.
    const x = try bundleRuns(h, head ++ "D<public>:i64=A.Deposit(3)\nP<public>:i64=L.Peek(A)\nV<public>:i64=A.Visits\nO<public>:string=A.Owner\n" ++
        "B:=L.Account{Owner:=\"me\"}\nT:=L.Tag{}\nN:L.Named=T\nR<public>:i64=N.Rank*100+L.CodeOf(N)\nS<public>:string=T.Label()", lib);
    try expectInt(x, "D", 8);
    try expectInt(x, "P", 8);
    try expectInt(x, "V", 2);
    try expectInt(x, "R", 109);
    inline for (.{
        "X:i64=A.Balance",
        "set A.Balance=1",
        "X:i64=A.Add(1)",
        "B:=L.Account{Balance:=3}",
        "set A.Visits=9",
        "T:=L.Tag{}\nX:i64=T.Code()",
        "T:=L.Tag{}\nN:L.Named=T\nX:i64=N.Code()",
        "T:=L.Tag{}\nN:L.Named=T\nX:i64=N.Weight",
        "T:=L.Tag{}\nX:i64=T.Weight",
        "F(Q:L.Account)<transacts>:i64=Q.Balance",
        "Mine:=class(L.Account){Get()<transacts>:i64=Self.Balance}",
    }) |use| try bundleRefused(h, head ++ use, lib, .internal_member, "main.forb");
    // A nested module is inside its file: what the file's class keeps internal it may use, and
    // what a nested module's class keeps internal the file around it may not.
    const nested = try bundleRuns(h,
        \\Box:=class{var N:i64=4}
        \\Inner:=module{
        \\  Read<public>(B:Box)<transacts>:i64=B.N
        \\  Coin<public>:=class{Value:i64=2,Face<public>:i64=9}
        \\  Worth<public>(C:Coin)<transacts>:i64=C.Value
        \\}
        \\R<public>:i64=Inner.Read(Box{})*100+Inner.Worth(Inner.Coin{})*10+Inner.Coin{}.Face
    , lib);
    try expectInt(nested, "R", 429);
    try bundleRefused(h, "Inner:=module{Coin<public>:=class{Value:i64=2}}\nR:i64=Inner.Coin{}.Value", lib, .internal_member, "main.forb");
    // In a program of one file everything is one module.
    try expectInt(try h.execute("Box:=class{var N:i64=4\nGet()<transacts>:i64=Self.N}\nR<public>:i64=Box{}.Get()+Box{N:=1}.N"), "R", 5);
    // `<internal>` and `<protected>` are not ordered: neither may be the write access of the other.
    try expectRefused(h, "C:=class{var<protected> N<internal>:i64=0}", .unsupported_specifier, "N");
    try expectRefused(h, "C:=class{var<internal> N<protected>:i64=0}", .unsupported_specifier, "N");
    try expectRefused(h, "C:=class{var<public> N:i64=0}", .unsupported_specifier, "N");
    _ = try h.compile("C:=class{var<private> N:i64=0\nvar<private> M<internal>:i64=0\nvar<internal> K<public>:i64=0}");
    // An interface member is public or internal, never kept to a class; an override keeps the
    // access or narrows it (RFC-0092, B4), and `internal` and `protected` are not ordered.
    try expectRefused(h, "I:=interface{F<private>()<transacts>:i64}", .invalid_interface, "F");
    try expectRefused(h, "I:=interface{N<protected>:i64=0}", .invalid_interface, "N");
    try expectRefused(h, "I:=interface{F()<transacts>:i64}\nC:=class(I){F<override><protected>()<transacts>:i64=1}", .override_mismatch, "F");
    try expectRefused(h, "B:=class{F()<transacts>:i64=1}\nC:=class(B){F<override><public>()<transacts>:i64=2}", .override_mismatch, "F");
}

// ---- D15: equality of instances

test "only instances of a unique class are compared or used as keys" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Token:=class<unique>{Id:i64=0}
        \\Gold:=class<unique>(Token){Carat:i64=24}
        \\Pair:=struct{T:Token,N:i64}
        \\Same[T:comparable](A:T,B:T)<computes>:logic{A==B}
        \\T1:=Token{}
        \\T2:=Token{}
        \\G:=Gold{}
        \\Up:Token=G
        \\A<public>:logic=T1==T1 and T1!=T2 and not (T1==T2)
        \\B<public>:logic=Up==G and G!=T1
        \\Owners:map(Token,i64)=map{T1=>1,G=>2}
        \\C<public>:i64=Attempt(Owners[T1]*10+Owners[Up],-1)
        \\D<public>:i64=Attempt(Owners[T2],-1)
        \\E<public>:logic=Pair{T:=T1,N:=1}==Pair{T:=T1,N:=1} and Pair{T:=T1,N:=1}!=Pair{T:=T2,N:=1}
        \\F<public>:logic=Same[Token](T1,T1) and not Same[Token](T1,T2) and array{T1,T2}==array{T1,T2}
    );
    try expectLogic(x, "A", true);
    try expectLogic(x, "B", true);
    try expectInt(x, "C", 12);
    try expectInt(x, "D", -1);
    try expectLogic(x, "E", true);
    try expectLogic(x, "F", true);
    const plain = "Box:=class{N:i64=0}\nB:=Box{}\n";
    try expectRefused(h, plain ++ "A:logic=B==B", .not_unique, "==");
    try expectRefused(h, plain ++ "A:logic=B!=B", .not_unique, "!=");
    try expectRefused(h, plain ++ "A:logic=array{B}==array{B}", .not_unique, "==");
    try expectRefused(h, plain ++ "A:logic=option{B}==option{B}", .not_unique, "==");
    try expectRefused(h, plain ++ "A:logic=tuple{B,1}==tuple{B,1}", .not_unique, "==");
    try expectRefused(h, plain ++ "Holder:=struct{Item:Box}\nA:logic=Holder{Item:=B}==Holder{Item:=B}", .not_unique, "==");
    try std.testing.expectEqual(Code.not_unique, h.front.compile(plain ++ "M:map(Box,i64)=map{}").failed.code);
    try std.testing.expectEqual(Code.not_unique, h.front.compile(plain ++ "M:=map{B=>1}").failed.code);
    try std.testing.expectEqual(Code.not_unique, h.front.compile(plain ++ "Same[T:comparable](X:T,Y:T)<computes>:logic{X==Y}\nA:logic=Same[Box](B,B)").failed.code);
    // A function still has no equality at all, which is not a matter of `<unique>`.
    try std.testing.expectEqual(Code.not_comparable, h.front.compile("F()<computes>:i64=1\nG:function(tuple(),i64)=F\nA:logic=G==G").failed.code);
    // A class below a unique class says so itself; seen as its superclass it is compared.
    try expectRefused(h, "Token:=class<unique>{Id:i64=0}\nGold:=class(Token){Carat:i64=24}", .not_unique, "Gold");
    // A superclass that is not unique is not made so by a subclass that is.
    try expectRefused(h, "Base:=class{N:i64=0}\nKey:=class<unique>(Base){}\nK:=Key{}\nUp:Base=K\nA:logic=Up==Up", .not_unique, "==");
    try expectLogic(try h.execute("Base:=class{N:i64=0}\nKey:=class<unique>(Base){}\nK:=Key{}\nA<public>:logic=K==K"), "A", true);
    // An interface has no instances of its own to be unique.
    try std.testing.expectEqual(Code.unsupported_specifier, h.front.compile("I:=interface<unique>{F()<transacts>:i64}").failed.code);
    try expectRefused(h, "I:=interface{F()<transacts>:i64}\nC:=class<unique>(I){F<override>()<transacts>:i64=1}\nV:I=C{}\nA:logic=V==V", .not_unique, "==");
    // Parametric and late-declared classes carry the word too.
    const late = try h.execute("Cell[T:type]:=class<unique>{V:T}\nWide:=class<unique>(Cell[i64]){W:i64=0}\nC:=Cell[i64]{V:=1}\nW:=Wide{V:=2}\nUp:Cell[i64]=W\nA<public>:logic=C==C and C!=Up and Up==W");
    try expectLogic(late, "A", true);
    try expectRefused(h, "Cell[T:type]:=class{V:T}\nC:=Cell[i64]{V:=1}\nA:logic=C==C", .not_unique, "==");
    try expectRefused(h, "Cell[T:type]:=class<unique>{V:T}\nWide:=class(Cell[i64]){W:i64=0}", .not_unique, "Wide");
}

test "both machines refuse forged equality of instances that are not unique" {
    const h = try harness.create();
    defer scratch.release(h);
    const source = "Token:=class<unique>{Id:i64=0}\nGold:=class<unique>(Token){Carat:i64=24}\nT:=Token{}\nG:=Gold{}\nUp:Token=G\nA<public>:logic=T==Up\nM:map(Token,i64)=map{T=>1}";
    const program = try h.compile(source);
    _ = try h.run(program, 4096);
    const definitions = try std.testing.allocator.dupe(types.Definition, program.definitions);
    defer std.testing.allocator.free(definitions);
    var classes: [2]usize = undefined;
    var found: usize = 0;
    for (definitions, 0..) |item, index| if (item == .class) {
        classes[found] = index;
        found += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    var forged = program;
    forged.definitions = definitions;
    // The compared class without the word: the comparison and the map key have no meaning.
    definitions[classes[0]].class.is_unique = false;
    definitions[classes[1]].class.is_unique = false;
    try harness.invalid(h, forged);
    // A class below a unique class that is not unique itself would be compared through it.
    definitions[classes[0]].class.is_unique = true;
    try harness.invalid(h, forged);
    definitions[classes[1]].class.is_unique = true;
    _ = try h.run(forged, 4096);
    // An interface is never unique.
    const with_interface = try h.compile("I:=interface{F()<transacts>:i64}\nC:=class<unique>(I){F<override>()<transacts>:i64=1}\nV:=C{}\nA<public>:logic=V==V");
    const copy = try std.testing.allocator.dupe(types.Definition, with_interface.definitions);
    defer std.testing.allocator.free(copy);
    var second = with_interface;
    second.definitions = copy;
    _ = try h.run(second, 4096);
    for (copy) |*item| if (item.* == .class and item.class.is_interface) {
        item.class.is_unique = true;
    };
    try harness.invalid(h, second);
}

// ---- D16: overloads

test "overloads whose parameters are related by subtyping are refused where they are declared" {
    const h = try harness.create();
    defer scratch.release(h);
    const classes = "Animal:=class{N:i64=0}\nDog:=class(Animal){}\nCat:=class<final>(Animal){}\nRock:=class<final>{}\nWalker:=interface{Walk()<transacts>:i64}\nRunner:=interface{Run()<transacts>:i64}\n";
    try expectRefused(h, classes ++ "Speak(A:Animal)<computes>:i64=1\nSpeak(D:Dog)<computes>:i64=2", .related_overloads, "Speak");
    try expectRefused(h, classes ++ "Speak(D:Dog)<computes>:i64=2\nSpeak(A:Animal)<computes>:i64=1", .related_overloads, "Speak");
    try expectRefused(h, classes ++ "Meet(A:Animal,D:Dog)<computes>:i64=1\nMeet(D:Dog,A:Animal)<computes>:i64=2", .related_overloads, "Meet");
    // An interface and a class that may still get a subclass, or two interfaces: one value could fit both.
    try expectRefused(h, classes ++ "Go(W:Walker)<computes>:i64=1\nGo(A:Animal)<computes>:i64=2", .related_overloads, "Go");
    try expectRefused(h, classes ++ "Go(W:Walker)<computes>:i64=1\nGo(R:Runner)<computes>:i64=2", .related_overloads, "Go");
    try expectRefused(h, classes ++ "(A:Animal).Show()<computes>:i64=1\n(D:Dog).Show()<computes>:i64=2", .related_overloads, "Show");
    // Distinct in one position is distinct: unrelated classes, a final class against an interface
    // it does not implement, or another type altogether.
    const x = try h.execute(classes ++
        \\Speak(D:Dog)<computes>:i64=2
        \\Speak(C:Cat)<computes>:i64=3
        \\Speak(N:i64)<computes>:i64=4
        \\Go(W:Walker)<computes>:i64=5
        \\Go(R:Rock)<computes>:i64=6
        \\Meet(A:Animal,N:i64)<computes>:i64=7
        \\Meet(D:Dog,S:string)<computes>:i64=8
        \\(D:Dog).Show()<computes>:i64=9
        \\(C:Cat).Show()<computes>:i64=10
        \\A<public>:i64=Speak(Dog{})*100+Speak(Cat{})*10+Speak(1)
        \\B<public>:i64=Go(Rock{})*100+Meet(Dog{},1)*10+Meet(Dog{},"s")
        \\C<public>:i64=Dog{}.Show()+Cat{}.Show()
    );
    try expectInt(x, "A", 234);
    try expectInt(x, "B", 678);
    try expectInt(x, "C", 19);
}

/// Refused with `code` at the name that begins `at` in `source` (its first occurrence).
fn expectRefusedAt(h: *harness.Harness, source: []const u8, code: Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
        return error.Compiled;
    }
    const expected = std.mem.indexOf(u8, source, at).?;
    if (result.failed.code != code or result.failed.span.start != expected) std.debug.print("{s} at {d}, expected {s} at {d}: {s}\n", .{ @tagName(result.failed.code), result.failed.span.start, @tagName(code), expected, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqual(expected, result.failed.span.start);
}

test "overloads over a chain of classes are refused in every order of the classes and the functions" {
    const h = try harness.create();
    defer scratch.release(h);
    const classes = "B:=class{N:i64=0}\nD:=class(B){}\nE:=class(D){}\n";
    const signatures = [_][]const u8{ "F(X:B,Y:D)<computes>:i64=1", "F(X:D,Y:B)<computes>:i64=2", "F(X:D,Y:D)<computes>:i64=3" };
    const orders = [_][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 0, 2 }, .{ 1, 2, 0 }, .{ 2, 0, 1 }, .{ 2, 1, 0 } };
    for (orders) |order| {
        var source: [768]u8 = undefined;
        // RFC-0076 D16: no two of the signatures are admitted. With the classes declared first,
        // the second signature is refused where it is declared.
        const before = try std.fmt.bufPrint(&source, "{s}{s}\n{s}\n{s}\n", .{ classes, signatures[order[0]], signatures[order[1]], signatures[order[2]] });
        try expectRefusedAt(h, before, .related_overloads, signatures[order[1]]);
        // Declared before the classes they take, the signatures are not yet known to be related:
        // the declaration of `D` relates them, and the same signature is refused, before any call.
        // (This order was admitted, and its calls chose the narrowest signature, 331.)
        const after = try std.fmt.bufPrint(&source, "{s}\n{s}\n{s}\n{s}A<public>:i64=F(E{{}},E{{}})*100+F(D{{}},D{{}})*10+F(B{{}},D{{}})\n", .{ signatures[order[0]], signatures[order[1]], signatures[order[2]], classes });
        try expectRefusedAt(h, after, .related_overloads, signatures[order[1]]);
    }
    // Two that no call could choose between are refused as related, not at the call (was
    // `type_mismatch` at `F(D{},D{})`).
    try expectRefusedAt(h, "F(X:B,Y:D)<computes>:i64=1\nF(X:D,Y:B)<computes>:i64=2\n" ++ classes ++ "A<public>:i64=F(D{},D{})", .related_overloads, "F(X:D,Y:B)");
    // The definitions that are admitted, apart in some position, each take their own calls, with
    // the classes declared before them or after.
    const y = try h.execute(classes ++ "F(X:B,Y:i64)<computes>:i64=1\nF(X:D,Y:string)<computes>:i64=2\nA<public>:i64=F(E{},1)*10+F(E{},\"s\")");
    try expectInt(y, "A", 12);
    const z = try h.execute("F(X:B,Y:i64)<computes>:i64=1\nF(X:D,Y:string)<computes>:i64=2\n" ++ classes ++ "A<public>:i64=F(E{},1)*10+F(E{},\"s\")");
    try expectInt(z, "A", 12);
}

test "overloads on related classes are refused whatever the order of the classes and the functions, in a block too" {
    const h = try harness.create();
    defer scratch.release(h);
    // One parameter: the call took the narrower definition (2) where the classes came last.
    try expectRefusedAt(h, "F(X:B)<computes>:i64=1\nF(X:D)<computes>:i64=2\nB:=class{N:i64=0}\nD:=class(B){}\nA<public>:i64=F(D{})", .related_overloads, "F(X:D)");
    try expectRefusedAt(h, "F(X:D)<computes>:i64=2\nB:=class{N:i64=0}\nF(X:B)<computes>:i64=1\nD:=class(B){}\nA<public>:i64=F(D{})", .related_overloads, "F(X:B)");
    // An interface and a class declared later that may get a subclass implementing it.
    try expectRefusedAt(h, "Go(W:Walker)<computes>:i64=1\nGo(A:Animal)<computes>:i64=2\nWalker:=interface{Walk()<transacts>:i64}\nAnimal:=class{N:i64=0}", .related_overloads, "Go(A:Animal)");
    // A later class that is final and does not implement the interface keeps them apart, as it
    // does when it comes first (this order was refused where `Go(R:Rock)` was declared).
    const rock = try h.execute("Walker:=interface{Walk()<transacts>:i64}\nGo(W:Walker)<computes>:i64=5\nGo(R:Rock)<computes>:i64=6\nRock:=class<final>{}\nA<public>:i64=Go(Rock{})");
    try expectInt(rock, "A", 6);
    // An extension method on a subclass declared last and a method of the class above it, in
    // either order (the extension first was admitted and `E{}.Show()` gave the method's 2).
    try expectRefusedAt(h, "(X:E).Show()<computes>:i64=1\nD:=class{Show()<computes>:i64=2}\nE:=class(D){}\nA<public>:i64=E{}.Show()", .related_overloads, "Show()<computes>:i64=2");
    try expectRefusedAt(h, "D:=class{Show()<computes>:i64=2}\n(X:E).Show()<computes>:i64=1\nE:=class(D){}\nA<public>:i64=E{}.Show()", .related_overloads, "Show()<computes>:i64=1");
    // The same with an argument of the method that names classes declared after both.
    try expectRefusedAt(h, "Base:=class{}\n(X:Base).F(Y:P)<computes>:i64=1\nC:=class(Base){F(Y:Q)<computes>:i64=2}\nP:=class{}\nQ:=class(P){}\nA<public>:i64=C{}.F(Q{})", .related_overloads, "F(Y:Q)");
    // Apart in some position, declared before their classes: each takes its own calls.
    const apart = try h.execute(
        \\F(X:B,Y:i64)<computes>:i64=1
        \\F(X:D,Y:string)<computes>:i64=2
        \\F(X:C)<computes>:i64=3
        \\F(X:B)<computes>:i64=4
        \\B:=class{N:i64=0}
        \\D:=class(B){}
        \\C:=class{}
        \\A<public>:i64=F(D{},1)*1000+F(D{},"s")*100+F(C{})*10+F(D{})
    );
    try expectInt(apart, "A", 1234);
    // Nested functions of a block, declared above the classes they take, are refused where the
    // classes relate them, after the block has closed.
    try expectRefusedAt(h,
        \\Run()<computes>:i64 = Block{
        \\    F(X:B,Y:D)<computes>:i64 = 1
        \\    F(X:D,Y:B)<computes>:i64 = 2
        \\    F(X:D,Y:D)<computes>:i64 = 3
        \\    0
        \\}
        \\B:=class{N:i64=0}
        \\D:=class(B){}
        \\E:=class(D){}
        \\A<public>:i64=Run()
    , .related_overloads, "F(X:D,Y:B)");
    try expectRefusedAt(h,
        \\Run(V:D)<computes>:i64 = Block{
        \\    F(X:B)<computes>:i64 = 1
        \\    F(X:D)<computes>:i64 = 2
        \\    F(V)
        \\}
        \\B:=class{N:i64=0}
        \\D:=class(B){}
        \\A<public>:i64=Run(D{})
    , .related_overloads, "F(X:D)");
    const nested = try h.execute(
        \\Run(V:C)<computes>:i64 = Block{
        \\    F(X:B)<computes>:i64 = 1
        \\    F(X:C)<computes>:i64 = 2
        \\    F(V)
        \\}
        \\B:=class{N:i64=0}
        \\C:=class{N:i64=0}
        \\A<public>:i64=Run(C{})
    );
    try expectInt(nested, "A", 2);
    // Two blocks that each declare one of the signatures are not overloads of each other.
    const blocks = try h.execute(
        \\One()<computes>:i64 = Block{
        \\    F(X:B)<computes>:i64 = 1
        \\    0
        \\}
        \\Two()<computes>:i64 = Block{
        \\    F(X:D)<computes>:i64 = 2
        \\    0
        \\}
        \\B:=class{N:i64=0}
        \\D:=class(B){}
        \\A<public>:i64=One()+Two()
    );
    try expectInt(blocks, "A", 0);
    // Two specializations of one generic body are not overloads of each other: in each, the
    // nested functions take unrelated classes.
    const specialized = try h.execute(
        \\Run[T:type,U:type]()<computes>:i64{Block{
        \\ F(X:T)<computes>:i64=1
        \\ F(X:U)<computes>:i64=2
        \\ 0
        \\}}
        \\A<public>:i64=Run[C,E]()
        \\Z<public>:i64=Run[E,C]()
        \\C:=class{}
        \\E:=class{}
    );
    try expectInt(specialized, "A", 0);
    try expectInt(specialized, "Z", 0);
}

test "an option beside logic at one parameter is refused as overloads in every order, in a block too" {
    const h = try harness.create();
    defer scratch.release(h);
    // The Book's `false` is an empty option and a `logic` (06:1777): no position keeps them apart.
    try expectRefusedAt(h, "F(X:option(i64))<computes>:i64=1\nF(X:logic)<computes>:i64=2\nA<public>:i64=F(true)", .option_logic_overloads, "F(X:logic)");
    try expectRefusedAt(h, "F(X:logic)<computes>:i64=2\nF(X:option(i64))<computes>:i64=1\nA<public>:i64=F(true)", .option_logic_overloads, "F(X:option(i64))");
    // Beside a position that waits for classes declared later: refused where they relate it.
    try expectRefusedAt(h, "F(X:logic,Y:B)<computes>:i64=2\nF(X:option(string),Y:D)<computes>:i64=1\nB:=class{}\nD:=class(B){}", .option_logic_overloads, "F(X:option(string)");
    try expectRefusedAt(h, "Run()<computes>:i64=Block{\n  F(X:logic)<computes>:i64=2\n  F(X:option(i64))<computes>:i64=1\n  0\n}\nA<public>:i64=Run()", .option_logic_overloads, "F(X:option(i64))");
    // Apart in another position, or two options: still distinct.
    const apart = try h.execute("F(X:option(i64),Y:i64)<computes>:i64=1\nF(X:logic,Y:string)<computes>:i64=2\nG(X:option(i64))<computes>:i64=3\nG(X:option(logic))<computes>:i64=4\nA<public>:i64=F(option{1},1)+F(true,\"s\")+G(option{1})+G(option{true})");
    try expectInt(apart, "A", 10);
}

test "a call with no receiver chooses among functions only: a method of the name is reached through a receiver" {
    const h = try harness.create();
    defer scratch.release(h);
    // A method declared after the functions took the plain call (it gave 7).
    const later = try h.execute("B:=class{N:i64=0}\nF(X:B,Y:B)<computes>:i64=1\nF(X:string)<computes>:i64=2\nD:=class(B){\n  F(Y:B)<computes>:i64=7\n}\nA<public>:i64=F(D{},D{})");
    try expectInt(later, "A", 1);
    // A method of a subclass that also took the call left it with no most specific candidate
    // (`type_mismatch`); a method of another name never did.
    const below = try h.execute("B:=class{N:i64=0}\nD:=class(B){N2:i64=0}\nF(X:B,Y:D)<computes>:i64=1\nF(X:string)<computes>:i64=2\nE:=class(D){\n  F(Y:B)<computes>:i64=7\n}\nA<public>:i64=F(E{},E{})");
    try expectInt(below, "A", 1);
    const other = try h.execute("B:=class{N:i64=0}\nD:=class(B){N2:i64=0}\nF(X:B,Y:D)<computes>:i64=1\nF(X:string)<computes>:i64=2\nE:=class(D){\n  G(Y:B)<computes>:i64=7\n}\nA<public>:i64=F(E{},E{})");
    try expectInt(other, "A", 1);
    // A method declared before the functions is not their overload either (they were refused as
    // related to it, RFC-0076 D16).
    const earlier = try h.execute("B:=class{N:i64=0}\nD:=class(B){\n  F(Y:B)<computes>:i64=7\n}\nF(X:B,Y:D)<computes>:i64=1\nF(X:string)<computes>:i64=2\nA<public>:i64=F(D{},D{})");
    try expectInt(earlier, "A", 1);
    // Through a receiver the method is called. In the class's own methods `Self.G` is the method
    // and a bare `G` the functions, as before.
    const through = try h.execute("G(S:string)<computes>:i64=100\nG(X:float)<computes>:i64=200\nC:=class{\n  G(Y:i64)<computes>:i64=Y+1\n  H()<computes>:i64=Self.G(10)+G(\"s\")\n}\nA<public>:i64=C{}.H()*1000+C{}.G(5)+G(\"s\")+G(1.0)");
    try expectInt(through, "A", 111306);
    // A bare call in a method does not reach the method, even where only the method takes it.
    try expectRefusedAt(h, "G(S:string)<computes>:i64=100\nG(X:float)<computes>:i64=200\nC:=class{\n  G(Y:i64)<computes>:i64=Y+1\n  H()<computes>:i64=G(10)\n}", .type_mismatch, "G(10)");
    // Nor its own name: the bare call was a recursion of the method taking `Self` first, which
    // skipped dispatch (an override was never run) and the module function of the name.
    try expectRefusedAt(h, "c:=class{M(N:i64)<computes>:i64=If(N<=0,0,M(N-1)+1)}\nX:i64=c{}.M(3)", .unknown_name, "M(N-1)");
    try expectRefusedAt(h, "c:=class{M(P:c,N:i64)<computes>:i64=If(N<=0,1,M(P,P,N-1))}\nd:=class(c){M<override>(P:c,N:i64)<computes>:i64=100}\nD:d=d{}\nBare:i64=c{}.M(D,1)", .unknown_name, "M(P,P,N-1)");
    const module = try h.execute("M(N:i64)<computes>:i64=N*100\nc:=class{M(N:i64)<computes>:i64=If(N<=0,0,M(N-1)+1)}\nX<public>:i64=c{}.M(3)");
    try expectInt(module, "X", 201);
    const typed = try h.execute("c:=class{}\nM(O:c,N:i64)<computes>:i64=N*100\nd:=class(c){M(N:i64)<computes>:i64=If(N<=0,0,M(Self,N-1)+1)}\nX<public>:i64=d{}.M(3)");
    try expectInt(typed, "X", 201);
    // A method recurs through `Self`, which dispatches; nested and module functions still recur
    // by their bare name, in a method's body too.
    const recursion = try h.execute("c:=class{\n  M(N:i64)<computes>:i64=If(N<=0,0,Self.M(N-1)+1)\n  K(N:i64)<computes>:i64=Block{\n    Down(I:i64)<computes>:i64=If(I<=0,0,Down(I-1)+2)\n    Down(N)\n  }\n}\nd:=class(c){M<override>(N:i64)<computes>:i64=If(N<=0,0,Self.M(N-1)+10)}\nF(N:i64)<computes>:i64=If(N<=0,0,F(N-1)+100)\nX<public>:i64=c{}.M(3)+d{}.M(2)+c{}.K(4)+F(5)");
    try expectInt(recursion, "X", 3 + 20 + 8 + 500);
    // An extension method is still checked against a method of a class it overlaps (`checkPlainClash`).
    try expectRefused(h, "Animal:=class{}\nDog:=class(Animal){Speak()<computes>:string=\"dog\"}\n(A:Animal).Speak()<computes>:string=\"animal\"", .related_overloads, "Speak");
}

// ---- `option{E}` and `If` conditions

test "option{E} catches the failure of E inside every failure context and undoes its writes" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Cell:i64=0
        \\M:map(i64,i64)=map{1=>10,2=>20}
        \\Xs:[]i64=array{1,5,2}
        \\Find(K:i64)<computes><decides>:option(i64)=option{M[K]}
        \\Write(K:i64)<transacts><decides>:option(i64)=option{Block{set Cell=Cell+100;M[K]}}
        \\Both(K:i64)<transacts><decides>:i64=Block{O:=option{Block{set Cell=Cell+1;M[K]}};set Cell=Cell+1000;Require[K>0];If(O.IsSet,1,2)}
        \\A<public>:option(i64)=Attempt(Find[5],option{-1})
        \\B<public>:option(i64)=Attempt(Find[2],option{-1})
        \\C<public>:i64=Attempt(Block{O:=option{M[7]};If(O.IsSet,1,2)},3)
        \\D<public>:[]option(i64)=For(X:Xs,option{M[X]})
        \\E<public>:option(i64)=Attempt(Write[9],option{-1})
        \\E1<public>:i64=Cell
        \\F<public>:option(i64)=Attempt(Write[1],option{-1})
        \\F1<public>:i64=Cell
        \\G<public>:i64=Attempt(Both[9],-1)
        \\G1<public>:i64=Cell
        \\H<public>:i64=Attempt(Both[0],-1)
        \\H1<public>:i64=Cell
        \\I<public>:option(option(i64))=option{option{M[8]}}
        \\J<public>:i64=Attempt(First[X:Xs,O:=option{M[X]},not O.IsSet,X],-1)
    );
    // The lookup fails inside the constructor: the function succeeds with the empty option.
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("A").?).?.len);
    try std.testing.expectEqual(@as(i64, 20), x.elements(x.get("B").?).?[0].integer);
    try expectInt(x, "C", 2);
    // No iteration is skipped: the middle element is the empty option.
    const each = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(usize, 3), each.len);
    try std.testing.expectEqual(@as(usize, 1), x.elements(each[0]).?.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(each[1]).?.len);
    try std.testing.expectEqual(@as(usize, 1), x.elements(each[2]).?.len);
    // The write of a failed expression is undone; that of one that succeeds is kept.
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("E").?).?.len);
    try expectInt(x, "E1", 0);
    try std.testing.expectEqual(@as(i64, 10), x.elements(x.get("F").?).?[0].integer);
    try expectInt(x, "F1", 100);
    // The constructor's region is undone alone; what the function did after it stays.
    try expectInt(x, "G", 2);
    try expectInt(x, "G1", 1100);
    // A failure after the constructor fails the function, and the attempt around it undoes everything.
    try expectInt(x, "H", -1);
    try expectInt(x, "H1", 1100);
    // The nearest constructor catches: the outer one holds an empty option.
    const outer = x.elements(x.get("I").?).?;
    try std.testing.expectEqual(@as(usize, 1), outer.len);
    try std.testing.expectEqual(@as(usize, 0), x.elements(outer[0]).?.len);
    try expectInt(x, "J", 5);
    // One that cannot fail is the constructor it always was: no region.
    const plain = try h.compile("F(K:i64)<computes><decides>:option(i64)=Block{Require[K>0];option{K+1}}\nA<public>:option(i64)=Attempt(F[1],option{})");
    try std.testing.expectEqual(@as(usize, 1), count(plain.function_nodes, "attempt_begin") + count(plain.nodes, "attempt_begin"));
    const caught = try h.compile("M:map(i64,i64)=map{}\nF(K:i64)<computes><decides>:option(i64)=Block{Require[K>0];option{M[K]}}\nA<public>:option(i64)=Attempt(F[1],option{-1})");
    try std.testing.expectEqual(@as(usize, 2), count(caught.function_nodes, "attempt_begin") + count(caught.nodes, "attempt_begin"));
    try std.testing.expectEqual(@as(usize, 0), x.elements((try h.run(caught, 4096)).ok.get("A").?).?.len);
}

test "the condition of an If is its own failure context inside a decides function" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Cell:i64=0
        \\Bump()<transacts>:logic=Block{set Cell=Cell+1;true}
        \\Big(O:option(i64))<computes><decides>:i64=If(O?>3,1,0)
        \\Later(O:option(i64),P:option(i64))<computes><decides>:i64=Block{Q:=P?;If(O?>3,Q,2)}
        \\Undo(O:option(i64))<transacts><decides>:i64=If(Bump() and O?>3,1,0)
        \\A<public>:i64=Attempt(Big[option{5}]*100+Big[option{}]*10+Big[option{1}],-1)
        \\B<public>:i64=Attempt(Later[option{},option{7}],-1)
        \\C<public>:i64=Attempt(Later[option{9},option{}],-1)
        \\D<public>:i64=Attempt(Undo[option{}],-1)
        \\D1<public>:i64=Cell
        \\E<public>:i64=Attempt(Undo[option{4}],-1)
        \\E1<public>:i64=Cell
        \\F<public>:i64=Attempt(If(option{1}?>3,1,0),-1)
    );
    // An empty option fails the condition and selects the else branch: the function goes on.
    try expectInt(x, "A", 100);
    try expectInt(x, "B", 2);
    // An unwrap outside the condition still fails the function.
    try expectInt(x, "C", -1);
    // What the failed condition wrote is undone before the else branch runs.
    try expectInt(x, "D", 0);
    try expectInt(x, "D1", 0);
    try expectInt(x, "E", 1);
    try expectInt(x, "E1", 1);
    try expectInt(x, "F", 0);
}

// ---- Defaults and extension methods

test "a parameter default reads the parameters before it, once, and Self in a method" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Calls:i64=0
        \\Next()<transacts>:i64=Block{set Calls=Calls+1;Calls}
        \\F(X:i64,Y:i64=X*2,Z:i64=X+Y)<computes>:i64=X*100+Y*10+Z
        \\G(X:i64,Y:i64=X+X)<transacts>:i64=Y
        \\Animal:=class{N:i64=0}
        \\Dog:=class(Animal){}
        \\Same(A:Animal,B:Animal=A)<transacts>:i64=A.N+B.N
        \\Box:=class{var N:i64=5
        \\  Add(K:i64,M:i64=Self.N+K)<transacts>:i64=K*100+M
        \\  Twice(K:i64,M:i64=K*2)<computes>:i64=K+M}
        \\Sub:=class(Box){Add<override>(K:i64,M:i64=Self.N*1000)<transacts>:i64=M+K}
        \\Make<constructor>(P:i64,Q:i64=P+1)<transacts>:=Box{N:=P*10+Q}
        \\A<public>:i64=F(1)
        \\B<public>:i64=F(1,3)
        \\C<public>:i64=F(1,Z:=0)
        \\D<public>:i64=G(Next())
        \\D1<public>:i64=Calls
        \\E<public>:i64=Same(Dog{N:=4})
        \\Bx:=Box{}
        \\H<public>:i64=Bx.Add(1)
        \\I<public>:i64=Bx.Twice(4)
        \\S:=Sub{N:=2}
        \\J<public>:i64=S.Add(1)
        \\Up:Box=S
        \\K<public>:i64=Up.Add(1)
        \\L<public>:i64=Make(1).N
    );
    try expectInt(x, "A", 123);
    try expectInt(x, "B", 134);
    try expectInt(x, "C", 120);
    // The argument is evaluated once by the caller; the default reads its value twice.
    try expectInt(x, "D", 2);
    try expectInt(x, "D1", 1);
    try expectInt(x, "E", 8);
    try expectInt(x, "H", 106);
    try expectInt(x, "I", 12);
    try expectInt(x, "J", 2001);
    // The declaration the static type sees gives the default; the instance's class the body.
    try expectInt(x, "K", 4);
    try expectInt(x, "L", 12);
    // A default does not read a later parameter, and reading a field of `Self` needs `<transacts>`.
    try expectRefused(h, "F(X:i64=Y,Y:i64=1)<computes>:i64=X", .unknown_name, "Y");
    try expectRefused(h, "Box:=class{N:i64=5\nGet(K:i64=Self.N)<computes>:i64=K}", .field_read_requires_reads, "N");
    // A default still reads a module name declared before the function.
    try expectInt(try h.execute("Base:i64=40\nF(X:i64,Y:i64=Base+X)<computes>:i64=Y\nA<public>:i64=F(2)"), "A", 42);
}

test "a local extension method does not hide the plain function a used module exports" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "Double<public>(X:i64)<computes>:i64=X*2\nSize<public>(X:i64)<computes>:i64=X+1";
    const x = try bundleRuns(h, "L:=import{\"lib.forb\"}\nusing{L}\n(S:string).Double()<computes>:i64=S.Length*2\nA<public>:i64=Double(4)*100+\"abc\".Double()*10+Size(1)", lib);
    try expectInt(x, "A", 862);
    const nested = try bundleRuns(h, "L:=import{\"lib.forb\"}\nusing{L}\nM:=module{(S:string).Double()<computes>:i64=S.Length\nR<public>:i64=Double(5)+\"ab\".Double()}\nA<public>:i64=M.R", lib);
    try expectInt(nested, "A", 12);
}

// ---- Found by the independent review

test "a line break inside parentheses does not end the operand that decides laziness" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var G:i64=0\nBump()<transacts>:i64=Block{set G=G+1;G}\nZero:i64=0\n" ++
        "A<public>:i64=If(false and\n  Bump()>0,1,0)\n" ++
        "B<public>:i64=If(3<2<\n  Bump(),1,0)\n" ++
        "C<public>:i64=If(true or 1>0\n  and Bump()>0,1,0)\n" ++
        "D<public>:logic=(false and\n  1/Zero>0)\n" ++
        "E<public>:i64=G\n" ++
        "F(N:i64)<transacts>:i64=Block{var X:i64=0\nR:=(N>100 and\n  Block{set X=X+1;true})\nIf(R,X,X+10)}\n" ++
        "H<public>:i64=F(1)");
    try expectInt(x, "A", 0);
    try expectInt(x, "B", 0);
    try expectInt(x, "C", 1);
    try expectLogic(x, "D", false);
    // No skipped operand ran.
    try expectInt(x, "E", 0);
    try expectInt(x, "H", 10);
    // In a block a line break ends the statement, so the operand before it may be plain.
    const plain = try h.compile("F(A:i64,L:logic)<computes>:logic=Block{K:=L and A>0\nK}\nR<public>:logic=F(1,true)");
    try std.testing.expectEqual(@as(usize, 0), count(plain.function_nodes, "if_begin"));
}

test "a statement is a dropped comparison only if it is one itself" {
    const h = try harness.create();
    defer scratch.release(h);
    // A call after a local function whose body ends in a comparison, and a bare name bound to one.
    const x = try h.execute(
        \\var T:i64=0
        \\Note(N:i64)<transacts>:i64=Block{set T=T+N;T}
        \\F(N:i64)<transacts>:i64=Block{G:=Fn(M:i64)<computes>:logic{M>0};Note(N);G(N);If(G(N),1,0)}
        \\K(N:i64)<computes>:i64=Block{L:=N>0;L;N}
        \\W(N:i64)<transacts>:i64=Block{var I:i64=0;While(I<N,Block{L:=I>0;set I=I+1;L});I}
        \\A<public>:i64=F(1)*100+K(2)*10+W(3)
        \\B<public>:i64=T
    );
    try expectInt(x, "A", 123);
    try expectInt(x, "B", 1);
}

test "receivers, a parametric type's own name and members across modules follow the rules" {
    const h = try harness.create();
    defer scratch.release(h);
    // The receiver of an extension method is a parameter like the others.
    try expectRefused(h, "V:i64=1\n(V:i64).Double()<computes>:i64=V*2", .shadowed_name, "V");
    try expectRefused(h, "G()<computes>:i64=1\n(G:i64).Double()<computes>:i64=G*2", .shadowed_name, "G");
    // Inside a parametric type its own name is taken.
    try expectRefused(h, "Box[T:type]:=class{V:T\nGet(Box:i64)<computes>:i64=Box}\nA:i64=Box[i64]{V:=1}.Get(2)", .shadowed_name, "Box");
    try expectRefused(h, "Pt[T:type]:=struct{V:T,W:i64=Block{Pt:=3;Pt}}\nA:=Pt[i64]{V:=1}", .shadowed_name, "Pt");
    // An extension method and a method of an overlapping class, in either order.
    try expectRefused(h, "Animal:=class{}\n(A:Animal).Speak()<computes>:string=\"animal\"\nDog:=class(Animal){Speak()<computes>:string=\"dog\"}", .related_overloads, "Speak");
    try expectRefused(h, "Animal:=class{}\nDog:=class(Animal){Speak()<computes>:string=\"dog\"}\n(A:Animal).Speak()<computes>:string=\"animal\"", .related_overloads, "Speak");
    try expectRefused(h, "I:=interface{}\n(V:I).Speak()<computes>:string=\"i\"\nC:=class(I){Speak()<computes>:string=\"c\"}", .related_overloads, "Speak");
    // An interface's internal field stays the interface's through every way to reach it.
    const lib =
        \\Ent<public>:=interface{var Health:i64=100,Name<public>:string="n"
        \\  Rank()<transacts>:i64=1}
        \\Kn:=class(Ent){}
        \\Make<public>()<transacts>:Ent=Kn{}
        \\Read<public>(E:Ent)<transacts>:i64=E.Health
        \\U<public>:=class{Label()<transacts>:string="u"}
        \\Base<public>:=class{Hidden:i64=1
        \\  Get()<transacts>:i64=Self.Hidden}
    ;
    const head = "L:=import{\"lib.forb\"}\n";
    inline for (.{
        "F(E:L.Ent)<transacts>:i64=Block{set E.Health=5;L.Read(E)}",
        "F(E:L.Ent)<transacts>:i64=E.Health",
        "Mine:=class(L.Ent){}\nM1:=Mine{Health:=4}",
        "Mine:=class(L.Ent){}\nM1:=Mine{}\nset M1.Health=6",
        "Mine:=class(L.Ent){}\nM1:=Mine{}\nA:i64=M1.Health",
        "Mine:=class(L.Ent){Rank<override>()<transacts>:i64=2}",
        "Sub:=class(L.Base){Get<override>()<transacts>:i64=2}",
        "Sub:=class(L.Base){Hidden<override>:i64=9}",
    }) |use| try bundleRefused(h, head ++ use, lib, .internal_member, "main.forb");
    // Another module's internal method does not stand in for this module's interface member.
    try bundleRefused(h, head ++ "I:=interface{Label()<transacts>:string}\nK:=class(L.U,I){}", lib, .duplicate_name, "main.forb");
    // What is public works from there, and the class of another module still implements the interface.
    const x = try bundleRuns(h, head ++ "Mine:=class(L.Ent){}\nM1:=Mine{Name:=\"m\"}\nA<public>:i64=L.Read(M1)+M1.Name.Length", lib);
    try expectInt(x, "A", 101);
}

test "type parameters may not take a visible name, and nothing in their scope may take theirs" {
    const h = try harness.create();
    defer scratch.release(h);
    // A type parameter is a declaration like any other: checked where it is written, whether
    // or not the template is ever instantiated.
    try expectRefused(h, "Count:i64=1\nId[Count:type](X:Count)<computes>:Count{X}", .shadowed_name, "Count");
    try expectRefused(h, "Seen()<computes>:i64=1\nId[Seen:type](X:Seen)<computes>:Seen{X}", .shadowed_name, "Seen");
    try expectRefused(h, "pt:=struct{X:i64=0}\nId[pt:type](V:pt)<computes>:pt{V}", .shadowed_name, "pt");
    try expectRefused(h, "Kind:=enum{A,B}\nBox[Kind:type]:=class{V:Kind}", .shadowed_name, "Kind");
    try expectRefused(h, "Other[t:type](X:t)<computes>:t{X}\nBox[Other:type]:=struct{V:Other}", .shadowed_name, "Other");
    try expectRefused(h, "Id[Id:type](X:Id)<computes>:Id{X}", .shadowed_name, "Id");
    try expectRefused(h, "Box[Box:type]:=class{V:Box}", .shadowed_name, "Box");
    try expectRefused(h, "Flag:i64=1\nRun[Flag:effect](F:function<Flag>(tuple(),i64))<Flag>:i64{F()}", .shadowed_name, "Flag");
    // Inside the template the parameter is visible: a local of its name is refused when the
    // body is compiled, and where the declaration alone shows it, at the declaration.
    try expectRefused(h, "Id[t:type](X:t)<computes>:t{Block{t:=X;t}}", .shadowed_name, "t");
    try expectRefused(h, "Id[t:type](X:t)<computes>:t{Block{t:=X;t}}\nA:i64=Id[i64](1)", .shadowed_name, "t");
    try expectRefused(h, "Box[T:type]:=class{V:T\nGet()<transacts>:i64=Block{T:=1;T}}\nA:i64=Box[i64]{V:=1}.Get()", .shadowed_name, "T");
    // A name declared later, and a sibling template's parameter, are free.
    const x = try h.execute("Id[t:type](X:t)<computes>:t{X}\nTwo[t:type](X:t)<computes>:t{X}\nBox[t:type]:=struct{V:t}\nLater:i64=Id[i64](3)+Two[i64](4)+Box[i64]{V:=5}.V\nId2[Later2:type](X:Later2)<computes>:Later2{X}\nLater2:i64=Id2[i64](1)\nR<public>:i64=Later+Later2");
    try expectInt(x, "R", 13);
}

test "a generic function that is never called is still checked for the shadowing its declaration shows" {
    const h = try harness.create();
    defer scratch.release(h);
    const rows = [_]struct { source: []const u8, text: []const u8 }{
        // A local, typed or not, a `var`, the names a `For`, an `If` and an `Fn` bind: against
        // the parameters, the function's own name and what the scopes around it declared.
        .{ .source = "Id[t:type](X:t)<computes>:t{Block{X:=X;X}}", .text = "X" },
        .{ .source = "Id[t:type](X:t,N:i64)<computes>:i64{Block{N:i64=2;N}}", .text = "N" },
        .{ .source = "Id[t:type](X:t,N:i64)<transacts>:i64{Block{var N:i64=2;N}}", .text = "N" },
        .{ .source = "Id[t:type](X:t)<computes>:i64{Block{Id:=1;Id}}", .text = "Id" },
        .{ .source = "Count:i64=1\nId[t:type](X:t)<computes>:i64{Block{Count:=2;Count}}", .text = "Count" },
        .{ .source = "Count()<computes>:i64=1\nId[t:type](X:t)<computes>:i64{Block{A:=1;Block{Count:i64=2;Count+A}}}", .text = "Count" },
        .{ .source = "Sum[t:type](Xs:[]t,N:i64)<computes>:i64{For(N:Xs,1).Length}", .text = "N" },
        .{ .source = "Sum[t:type](Xs:[]t,N:i64)<computes>:i64{For(I->N:Xs,I).Length}", .text = "N" },
        .{ .source = "Pick[t:type](O:option(t),N:t)<computes>:t{If(N:=O?,N,N)}", .text = "N" },
        .{ .source = "Wrap[t:type](X:t)<computes>:function(tuple(t),t){Fn(X:t){X}}", .text = "X" },
        .{ .source = "pt:=struct{V:i64=0}\nId[t:type](X:t)<computes>:i64{Block{pt:=1;pt}}", .text = "pt" },
    };
    for (rows) |row| try expectRefused(h, row.source, .shadowed_name, row.text);
    // What is not a declaration is not taken for one: named arguments, archetype fields, a
    // name declared later, and names that only siblings share.
    const x = try h.execute(
        \\pt:=struct{X:i64=0,N:i64=0}
        \\Add(X:i64,N:i64=1)<computes>:i64=X+N
        \\Id[t:type](X:t,N:i64)<computes>:i64{Block{
        \\  P:=pt{X:=N,N:=2}
        \\  Q:=Add(N:=N,X:=P.X)
        \\  A:=If(Q>0,Block{Same:=1;Same},Block{Same:=2;Same})
        \\  After:=A+Q+P.N
        \\  After
        \\}}
        \\After:i64=5
        \\R<public>:i64=Id[string]("s",3)+After
    );
    try expectInt(x, "R", 14);
}

test "a using may not bring in a name that is already declared where it stands" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "Limit<public>:i64=10\nScale<public>(X:i64)<computes>:i64=X*2\nHidden:i64=1\nshape<public>:=struct{W:i64=1}\nUnit<public>:=shape\nTwice<public>[t:type](X:t)<computes>:t{X}\nKit<public>:=module{Step<public>:i64=3}";
    // Each kind of export against an earlier declaration of the file, of any kind.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nLimit:i64=1\nusing{L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nScale:i64=1\nusing{L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nLimit()<computes>:i64=1\nusing{L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nshape:=struct{H:i64=2}\nusing{L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nUnit:i64=1\nusing{L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nTwice:i64=1\nusing{L}", lib, .shadowed_name, "main.forb");
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nStep:i64=1\nusing{L.Kit}", lib, .shadowed_name, "main.forb");
    // A scope around the `using` counts as its own does.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nLimit:i64=1\nM:=module{using{L}\nV<public>:i64=2}", lib, .shadowed_name, "main.forb");
    // What the used module keeps to itself is not brought in; a later declaration is refused
    // where it is written, as before; two modules may export one name until it is used.
    try expectInt(try bundleRuns(h, "L:=import{\"lib.forb\"}\nHidden:i64=5\nusing{L}\nA<public>:i64=Hidden+Limit", lib), "A", 15);
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nusing{L}\nLimit:i64=1", lib, .shadowed_name, "main.forb");
    try expectInt(try bundleRuns(h, "L:=import{\"lib.forb\"}\nusing{L}\nusing{L}\nM:=module{using{L}\nV<public>:i64=Limit}\nA<public>:i64=M.V+Scale(1)", lib), "A", 12);
    // A `using` of the same module in a scope that is not around this one asks nothing for it.
    try bundleRefused(h, "L:=import{\"lib.forb\"}\nM:=module{using{L}\nV<public>:i64=Limit}\nLimit:i64=1\nusing{L}", lib, .shadowed_name, "main.forb");
    // A module that uses a module around it, or itself, brings in nothing new.
    try expectInt(try bundleRuns(h, "Outer:=module{Seed<public>:i64=4\nInner<public>:=module{using{Outer}\nV<public>:i64=Seed+1}}\nA<public>:i64=Outer.Inner.V", lib), "A", 5);
}

test "a shadowed name's diagnostic names the declaration it already belongs to" {
    const h = try harness.create();
    defer scratch.release(h);
    const rows = [_]struct { source: []const u8, first: []const u8, at: usize }{
        // The text of the earlier declaration and the position it starts at.
        .{ .source = "Count:i64=0\nNext(Count:i64)<computes>:i64=Count+1", .first = "Count", .at = 0 },
        .{ .source = "F(N:i64)<computes>:i64=Block{N:i64=2;N}", .first = "N", .at = 2 },
        .{ .source = "F(N:i64)<computes>:i64=Block{A:=1;Block{A:=2;A}}", .first = "A", .at = 29 },
        .{ .source = "F(N:i64)<computes>:i64=Block{G:=Fn(K:i64){Block{N:=K;N}};G(1)}", .first = "N", .at = 2 },
        .{ .source = "Step(N:i64)<computes>:i64=Block{Step:=N;Step}", .first = "Step", .at = 0 },
        .{ .source = "Id[t:type](X:t)<computes>:t{Block{t:=X;t}}", .first = "t", .at = 3 },
        .{ .source = "Id[t:type](X:t)<computes>:t{Block{X:=X;X}}", .first = "X", .at = 11 },
        .{ .source = "pt:=struct{V:i64=0}\nId[pt:type](X:pt)<computes>:pt{X}", .first = "pt", .at = 0 },
    };
    for (rows) |row| {
        const failed = h.front.compile(row.source).failed;
        try std.testing.expectEqual(Code.shadowed_name, failed.code);
        if (failed.related.start != row.at or !std.mem.eql(u8, failed.related.text(row.source), row.first)) {
            std.debug.print("{s}: related {d}..{d}, expected `{s}` at {d}\n", .{ row.source, failed.related.start, failed.related.end, row.first, row.at });
            return error.WrongSite;
        }
        const first = failed.relatedLocation(row.source).?;
        try std.testing.expectEqual(@as(u32, 1), first.line);
    }
    // Other diagnostics name one place, as before.
    try std.testing.expect(h.front.compile("A:i64=B").failed.relatedLocation("A:i64=B") == null);
    // In a bundle the place is given in its own file; a name that came through `using` is
    // declared in another file and is not named.
    const lib = "Limit<public>:i64=10";
    const same = bundle(h, "L:=import{\"lib.forb\"}\nSeed:i64=1\nF(Seed:i64)<computes>:i64=Seed", lib).failed;
    try std.testing.expectEqualStrings("Seed", same.diagnostic.related.text(same.source));
    try std.testing.expectEqual(@as(u32, 2), same.diagnostic.relatedLocation(same.source).?.line);
    const used = bundle(h, "L:=import{\"lib.forb\"}\nusing{L}\nF(Limit:i64)<computes>:i64=Limit", lib).failed;
    try std.testing.expectEqual(Code.shadowed_name, used.diagnostic.code);
    try std.testing.expect(used.diagnostic.relatedLocation(used.source) == null);
    const late = bundle(h, "L:=import{\"lib.forb\"}\nLimit:i64=1\nusing{L}", lib).failed;
    try std.testing.expectEqualStrings("L", late.diagnostic.span.text(late.source));
    try std.testing.expectEqualStrings("Limit", late.diagnostic.related.text(late.source));
}
