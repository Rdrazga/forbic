//! Mutual recursion among module functions (RFC-0091, B3): a function body may call a module
//! function declared further down. The call is a `call` of a later function, which both
//! machines admit only for a named function available exactly where the caller is, and whose
//! effect on the caller's summary is that of an `invoke` of its signature.
//!
//! `h.execute` runs a program in both machines, compares their results, fuel-visible steps and
//! member pools, and replays each run in the report validator.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

const Expected = struct { []const u8, i64 };

fn expectIntegers(x: evaluator.Execution, expected: []const Expected) !void {
    for (expected) |entry| {
        const value = x.get(entry[0]) orelse {
            std.debug.print("no binding {s}\n", .{entry[0]});
            return error.Missing;
        };
        if (value.integer != entry[1]) std.debug.print("{s}: expected {d}, found {d}\n", .{ entry[0], entry[1], value.integer });
        try std.testing.expectEqual(entry[1], value.integer);
    }
}

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    try std.testing.expect(r.failed.span.end <= source.len);
}

test "module functions call functions declared after them, in cycles of any length" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\IsEven(N:i64)<computes>:logic=If(N==0,true,IsOdd(N-1))
        \\IsOdd(N:i64)<computes>:logic=If(N==0,false,IsEven(N-1))
        \\A0(N:i64)<computes>:i64=If(N<=0,0,A1(N-1)+1)
        \\A1(N:i64)<computes>:i64=If(N<=0,10,A2(N-1)+10)
        \\A2(N:i64)<computes>:i64=If(N<=0,100,A0(N-1)+100)
        \\Up(N:i64)<computes>:i64=Later(N)+Later(N+1)
        \\Later(N:i64)<computes>:i64=N*2
        \\Even<public>:logic=IsEven(10)
        \\Odd<public>:logic=IsEven(7)
        \\Ring<public>:i64=A0(7)
        \\Twice<public>:i64=Up(3)
    );
    try std.testing.expect(x.get("Even").?.boolean);
    try std.testing.expect(!x.get("Odd").?.boolean);
    // 1 + 10 + 100 + 1 + 10 + 100 + 1, and A1(0) = 10 at the end.
    try expectIntegers(x, &.{ .{ "Ring", 1 + 10 + 100 + 1 + 10 + 100 + 1 + 10 }, .{ "Twice", 6 + 8 } });
}

test "a later function writes, fails and rolls back like any callee" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\var Log:i64=0
        \\Ping(N:i64)<transacts>:i64=If(N<=0,Log,Block{set Log=Log*10+1;Pong(N-1)})
        \\Pong(N:i64)<transacts>:i64=If(N<=0,Log,Block{set Log=Log*10+2;Ping(N-1)})
        \\Even(N:i64)<computes><decides>:logic=If(N==0,true,Odd[N-1])
        \\Odd(N:i64)<computes><decides>:logic=Block{Require[N>=0];If(N==0,Fail["odd"],Even[N-1])}
        \\Guarded(N:i64)<transacts><decides>:i64=Block{set Log=Log+1000;Check[N]}
        \\Check(N:i64)<transacts><decides>:i64=Block{set Log=Log+1;Require[N>0];N}
        \\A<public>:i64=Ping(4)
        \\B<public>:logic=Attempt(Block{Even[4]},false)
        \\C<public>:logic=Attempt(Block{Even[5]},false)
        \\D<public>:i64=Attempt(Guarded[0],-1)
        \\E<public>:i64=Log
        \\F<public>:i64=Attempt(Guarded[3],-1)
        \\G<public>:i64=Log
    );
    try std.testing.expect(x.get("B").?.boolean);
    try std.testing.expect(!x.get("C").?.boolean);
    // The failed attempt undoes the writes of both functions; the successful one keeps them.
    try expectIntegers(x, &.{ .{ "A", 1212 }, .{ "D", -1 }, .{ "E", 1212 }, .{ "F", 3 }, .{ "G", 1212 + 1001 } });
}

test "calls of later functions from methods, loops, closures, nested functions and with named arguments" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\counter:=class{V:i64=1;Get()<reads>:i64=Self.V+Hundred(2)}
        \\Sum(Xs:[]i64)<computes>:[]i64=For(X:Xs,Twice(X))
        \\Apply(X:i64)<computes>:i64=Block{K:=Fn(Y:i64)<computes>:i64{Inc(Y)};K(X)}
        \\Outer(N:i64)<computes>:i64=Block{
        \\  Inner(X:i64)<computes>:i64=Inc(X)*2
        \\  Inner(N)
        \\}
        \\Named(A:i64)<computes>:i64=Pair(Y:=A,X:=1)
        \\Hundred(N:i64)<computes>:i64=N*100
        \\Twice(X:i64)<computes>:i64=X*2
        \\Inc(Y:i64)<computes>:i64=Y+1
        \\Pair(X:i64,Y:i64)<computes>:i64=X*10+Y
        \\Alias(X:i64)<computes>:i64=Same(X)
        \\Same(X:i64)<computes>:i64=X
        \\A<public>:i64=counter{}.Get()
        \\B<public>:i64=Sum(array{1,2,3}).Length
        \\C<public>:i64=Apply(5)
        \\D<public>:i64=Outer(3)
        \\E<public>:i64=Named(7)
        \\F<public>:i64=Alias(9)
    );
    try expectIntegers(x, &.{ .{ "A", 201 }, .{ "B", 3 }, .{ "C", 6 }, .{ "D", 8 }, .{ "E", 17 }, .{ "F", 9 } });
}

test "a later function is what its header says, and nothing that runs at the root lies between" {
    const h = try harness.create();
    defer scratch.release(h);
    // A value between the two, and a call of the first one between them.
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nX:i64=5\nG(N:i64)<computes>:i64=N", .forward_value_between);
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nA:i64=F(1)\nG(N:i64)<computes>:i64=N", .forward_value_between);
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nX:i64=1\nH(N:i64)<computes>:i64=G(N)\nG(N:i64)<computes>:i64=N", .forward_value_between);
    // Types, classes and functions between are no values.
    _ = try h.execute("F(N:i64)<computes>:i64=G(N)\np:=struct{X:i64}\nc:=class{Y:i64=2}\nK(N:i64)<computes>:i64=N\nG(N:i64)<computes>:i64=N+1\nA:i64=F(1)");
    // Overloads, a transparent result, and a type the header names that is declared after the call.
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nG(N:i64)<computes>:i64=N\nG(N:float)<computes>:float=N", .forward_signature);
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nG(N:i64)<computes>:=N", .forward_signature);
    try expectCode(h, "F(N:i64)<computes>:i64=Block{G(N);0}\np:=struct{X:i64}\nG(N:i64)<computes>:p=p{X:=N}", .forward_signature);
    // A default is compiled with the declaration.
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nG(N:i64,M:i64=2)<computes>:i64=N+M", .forward_arguments);
    _ = try h.execute("F(N:i64)<computes>:i64=G(N,3)\nG(N:i64,M:i64=2)<computes>:i64=N+M\nA:i64=F(1)");
    // Effects, failure contexts and arguments are checked against the header.
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nG(N:i64)<transacts>:i64=N", .call_requires_transacts);
    try expectCode(h, "F(N:i64)<computes>:i64=G(N)\nG(N:i64)<computes><decides>:i64=N", .failure_context_required);
    try expectCode(h, "F(N:i64)<computes>:i64=G(N,1)\nG(N:i64)<computes>:i64=N", .argument_count);
    try expectCode(h, "F(N:i64)<computes>:i64=G(\"a\")\nG(N:i64)<computes>:i64=N", .type_mismatch);
    try expectCode(h, "F(N:i64)<computes>:i64=G(Z:=N)\nG(N:i64)<computes>:i64=N", .unknown_parameter);
    // The root, a parameter default and a function value still need the declaration first.
    try expectCode(h, "A:i64=G(1)\nG(N:i64)<computes>:i64=N", .unknown_name);
    try expectCode(h, "F(N:i64=G(1))<computes>:i64=N\nG(N:i64)<computes>:i64=N", .unknown_name);
    try expectCode(h, "F(N:i64)<computes>:function(tuple(i64),i64)=G\nG(N:i64)<computes>:i64=N", .unknown_name);
    // A generic body and a constructor function keep the rule of earlier declarations.
    try expectCode(h, "Id[T:type](X:T)<computes>:i64{G(1)}\nG(N:i64)<computes>:i64=N\nA:i64=Id[i64](1)", .unknown_name);
}

fn expectShadowedAt(h: *harness.Harness, source: []const u8, at: []const u8) !void {
    try expectCode(h, source, .shadowed_name);
    try std.testing.expectEqual(std.mem.indexOf(u8, source, at).?, h.front.compile(source).failed.span.start);
}

test "a body that called a later function does not declare its name after the call" {
    const h = try harness.create();
    defer scratch.release(h);
    // The local `G` and the module function `G` were both reached in one block (it gave 3, and
    // the nested function 1); with the module function first the block was refused already.
    try expectShadowedAt(h, "F()<computes>:i64=Block{\n  A:=G()\n  G:i64=2\n  A+G\n}\nG()<computes>:i64=1\nX:i64=F()", "G:i64=2");
    try expectShadowedAt(h, "F()<computes>:i64=Block{\n  A()<computes>:i64=G()\n  G()<computes>:i64=2\n  A()\n}\nG()<computes>:i64=1\nX:i64=F()", "G()<computes>:i64=2");
    try expectShadowedAt(h, "G()<computes>:i64=1\nF()<computes>:i64=Block{\n  A()<computes>:i64=G()\n  G()<computes>:i64=2\n  A()\n}\nX:i64=F()", "G()<computes>:i64=2");
    // In an inner block, as a parameter of a nested function, and after a call from an `Fn`.
    try expectShadowedAt(h, "F()<computes>:i64=Block{\n  A:=G()\n  Block{G:i64=2;G}+A\n}\nG()<computes>:i64=1\nX:i64=F()", "G:i64=2");
    try expectShadowedAt(h, "F()<computes>:i64=Block{\n  A:=G()\n  P(G:i64)<computes>:i64=G\n  A+P(1)\n}\nG()<computes>:i64=1\nX:i64=F()", "G:i64)");
    try expectShadowedAt(h, "F()<computes>:i64=Block{\n  K:=Fn()<computes>:i64{G()}\n  G:i64=2\n  K()+G\n}\nG()<computes>:i64=1\nX:i64=F()", "G:i64=2");
    // Another body that does not call it may use the name, and `(local:)` is a local's own.
    const apart = try h.execute("F()<computes>:i64=G()\nH()<computes>:i64=Block{\n  G:i64=2\n  G\n}\nK()<computes>:i64=Block{\n  A:=G()\n  (local:)G:i64=20\n  A+(local:)G\n}\nG()<computes>:i64=1\nX<public>:i64=F()+H()+K()");
    try expectIntegers(apart, &.{.{ "X", 1 + 2 + 21 }});
}

test "mutual recursion is bounded by the frames of both machines" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Down(N:i64)<computes>:i64=If(N<=0,0,Up(N-1)+1)\nUp(N:i64)<computes>:i64=If(N<=0,0,Down(N-1)+1)\nA:i64=Down(20)\nB:i64=Down(1000)");
    const r = try h.run(p, 1 << 20);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, r.failed.code);
    // A cycle without a base case runs out of frames, not of the host's stack.
    const q = try h.compile("Down(N:i64)<computes>:i64=Up(N)+1\nUp(N:i64)<computes>:i64=Down(N)+1\nA:i64=Down(1)");
    const s = try h.run(q, 1 << 20);
    try std.testing.expectEqual(types.Diagnostic.Code.call_depth_limit, s.failed.code);
}

test "both machines refuse forged calls of later functions" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("var Log:i64=0\nF(N:i64)<transacts>:i64=If(N<=0,Log,G(N-1)+1)\nG(N:i64)<transacts>:i64=Block{set Log=Log+1;F(N)}\nH(N:string)<computes>:string=N+\"x\"\nA:i64=F(3)");
    _ = try h.run(p, 1 << 20);
    var forward: usize = 0;
    var function: usize = 0;
    for (p.functions, 0..) |f, id| for (p.function_nodes[f.body.start..f.body.end], f.body.start..) |entry, index| {
        if (entry.input == .operation and entry.node.kind == .call and entry.node.kind.call.function > id) {
            forward = index;
            function = id;
        }
    };
    try std.testing.expect(forward != 0);
    const n = p.functions.len;
    const nodes = p.function_nodes.len;
    var forged = p;
    forged.functions = h.metadata[0..n];
    forged.function_nodes = h.body[0..nodes];
    for (0..10) |case| {
        @memcpy(h.metadata[0..n], p.functions);
        @memcpy(h.body[0..nodes], p.function_nodes);
        const call = &h.body[forward].node.kind.call;
        switch (case) {
            // The later function becomes available later than its caller.
            0 => for (h.metadata[function + 1 .. n]) |*f| {
                f.available_at += 1;
            },
            // The caller claims less than what a call it cannot see into may do.
            1 => h.metadata[function].member_work = 0,
            2 => h.metadata[function].has_control = false,
            3 => h.metadata[function].has_failure = false,
            // A call of itself is a `recur`, and a target past the catalogue is none.
            4 => call.function = @intCast(function),
            5 => call.function = @intCast(n),
            // A target whose signature does not match the call.
            6 => call.function = @intCast(n - 1),
            7 => call.arguments.end -= 1,
            // A later target that is anonymous, or holds a class's clauses.
            8 => h.metadata[call.function].anonymous = true,
            9 => h.metadata[call.function].clauses_of = .i64,
            else => unreachable,
        }
        errdefer std.debug.print("forged case {d} was admitted\n", .{case});
        try harness.invalid(h, forged);
    }
    @memcpy(h.metadata[0..n], p.functions);
    @memcpy(h.body[0..nodes], p.function_nodes);
    _ = try h.run(forged, 1 << 20);
}

const Shape = struct {
    base: i64,
    step: i64,
    add: i64,
    first: usize,
    second: ?usize,
};

/// The model of one call of function `i` of `shapes`, as the generated source runs it: the
/// writes of a level come before its calls, and the calls run from left to right.
fn model(shapes: []const Shape, i: usize, n: i64, log: *i64, logged: bool, fails_at: ?i64) error{Failed}!i64 {
    const s = shapes[i];
    if (n <= 0) return (if (logged) log.* else 0) + s.base;
    if (logged) log.* = log.* * 2 + s.step;
    if (fails_at) |at| if (n == at) return error.Failed;
    var result = try model(shapes, s.first, n - 1, log, logged, fails_at);
    if (s.second) |second| result += try model(shapes, second, n - 2, log, logged, fails_at);
    return result + s.add;
}

test "mutual recursion agrees with a direct model on 400 random call graphs in declaration orders of every kind" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xB3);
    const random = prng.random();
    var shapes: [5]Shape = undefined;
    var order: [5]usize = undefined;
    for (0..400) |round| {
        const count = 2 + random.uintLessThan(usize, 4);
        // 0: computes, 1: transacts with a log, 2: transacts and decides, failing at one depth.
        const kind = round % 3;
        const two = random.boolean();
        const depth: i64 = if (two) random.intRangeAtMost(i64, 0, 6) else random.intRangeAtMost(i64, 0, 12);
        for (shapes[0..count]) |*s| s.* = .{
            .base = random.intRangeAtMost(i64, -5, 5),
            .step = random.intRangeAtMost(i64, 0, 9),
            .add = random.intRangeAtMost(i64, -9, 9),
            .first = random.uintLessThan(usize, count),
            .second = if (two and random.boolean()) random.uintLessThan(usize, count) else null,
        };
        for (order[0..count], 0..) |*o, i| o.* = i;
        random.shuffle(usize, order[0..count]);
        const fails_at: ?i64 = if (kind == 2 and random.boolean()) random.intRangeAtMost(i64, 1, @max(1, depth)) else null;
        var out = std.Io.Writer.fixed(&h.text);
        if (kind != 0) try out.writeAll("var Log:i64=0\n");
        for (order[0..count]) |i| {
            const s = shapes[i];
            const effect = switch (kind) {
                0 => "<computes>",
                1 => "<transacts>",
                else => "<transacts><decides>",
            };
            const open: u8 = if (kind == 2) '[' else '(';
            const close: u8 = if (kind == 2) ']' else ')';
            try out.print("F{d}(N:i64){s}:i64=If(N<=0,{s}{d},Block{{", .{ i, effect, if (kind == 0) "" else "Log+", s.base });
            if (kind != 0) try out.print("set Log=Log*2+{d};", .{s.step});
            if (kind == 2) try out.print("Require[N!={d}];", .{fails_at orelse -1});
            try out.print("F{d}{c}N-1{c}", .{ s.first, open, close });
            if (s.second) |second| try out.print("+F{d}{c}N-2{c}", .{ second, open, close });
            try out.print("+{d}}})\n", .{s.add});
        }
        if (kind == 2) try out.print("A:i64=Attempt(F0[{d}],-1000000)\n", .{depth}) else try out.print("A:i64=F0({d})\n", .{depth});
        if (kind != 0) try out.writeAll("B:i64=Log\n");
        var log: i64 = 0;
        const expected = model(shapes[0..count], 0, depth, &log, kind != 0, fails_at) catch failed: {
            log = 0;
            break :failed -1000000;
        };
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(expected, x.get("A").?.integer);
        if (kind != 0) try std.testing.expectEqual(log, x.get("B").?.integer);
    }
}
