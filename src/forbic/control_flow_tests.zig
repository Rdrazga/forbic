//! Control-flow completion (RFC-0090, B2): `If` without an else, `For` without a generator and
//! with clauses before its first generator, and the Book's rules for `Case`: unreachable arms
//! and the types a constant arm compares.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

fn expectIntegers(x: anytype, name: []const u8, expected: []const i64) !void {
    const elements = x.elements(x.get(name).?).?;
    if (expected.len != elements.len) std.debug.print("{s}: {d} elements, expected {d}\n", .{ name, elements.len, expected.len });
    try std.testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |want, got| try std.testing.expectEqual(want, got.integer);
}

fn expectInteger(x: anytype, name: []const u8, expected: i64) !void {
    const got = x.get(name).?.integer;
    if (got != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, got, expected });
    try std.testing.expectEqual(expected, got);
}

const Refusal = struct { []const u8, types.Diagnostic.Code };

/// Each source is refused with its code, at a place inside the program's own text.
fn expectRefusals(h: *harness.Harness, prelude: []const u8, cases: []const Refusal) !void {
    for (cases) |case| {
        var buffer: [1024]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prelude, case[0] });
        const r = h.front.compile(source);
        if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{case[0]});
        try std.testing.expect(r == .failed);
        if (r.failed.code != case[1]) std.debug.print("diagnostic for {s}: {s}\n", .{ case[0], r.failed.message() });
        try std.testing.expectEqual(case[1], r.failed.code);
        try std.testing.expect(r.failed.span.end <= source.len);
        try std.testing.expect(r.failed.span.start >= prelude.len);
    }
}

test "an If without an else runs its arm for what it does and yields the unit value" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("var Count:i64=0\nItems:[]i64=array{5,7}\n" ++
        "Bump(N:i64)<transacts>:void=If(N>0,Set(Count,Count+N))\n" ++
        // The condition may fail (`Items[I]`), or bind; a failure is the false case.
        "Look(I:i64)<transacts>:i64=Block{If(Items[I]>6,Set(Count,Count+100));If(X:=Items[I],Set(Count,Count+X));Count}\n" ++
        // An assigned local: the arm's writes are kept when it runs and absent when it does not.
        "Local(N:i64)<transacts>:i64=Block{var Y:i64=1;If(N>1,Block{set Y=Y+N;set Y=Y*2;0});Y}\n" ++
        // An arm that leaves.
        "Early(N:i64)<computes>:i64=Block{If(N>1,Return(7));N}\n" ++
        // Nested, and as the arm of a void If.
        "Nest(A:logic,B:logic)<transacts>:void=If(A,If(B,Set(Count,Count+1000)),If(B,Set(Count,Count-1)))\n" ++
        "Run()<transacts>:i64=Block{Bump(3);Bump(-1);L:=Look(0)+Look(9)+Look(1);Nest(true,true);Nest(true,false);Nest(false,true);L*100000+Count}\n" ++
        "A<public>:i64=Run()\nB<public>:i64=Local(3)*100+Local(0)\nC<public>:i64=Early(5)*10+Early(0)\n" ++
        "U<public>:void=If(true,1)\n");
    // Bump: 3. Look(0): 5 is not > 6, then +5 (8). Look(9): both fail (8). Look(1): +100, +7 (115).
    // L = 8 + 8 + 115 = 131. Nest: +1000, nothing, -1: Count 1114.
    try expectInteger(x, "A", 131 * 100000 + 1114);
    try expectInteger(x, "B", 8 * 100 + 1);
    try expectInteger(x, "C", 70);
    try std.testing.expectEqual(@as(usize, 0), x.elements(x.get("U").?).?.len);
}

test "an If without an else has no value: a place that needs one refuses it" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefusals(h, "N:i64=3\n", &.{
        .{ "F(C:logic)<computes>:i64=If(C,1)", .if_without_else },
        .{ "A:=If(N>1,1)", .if_without_else },
        .{ "A:i64=If(N>1,1)", .if_without_else },
        .{ "F(C:logic)<computes>:i64=Block{X:=If(C,1);2}", .if_without_else },
        .{ "F(C:logic)<transacts>:i64=Block{var X:void=If(C,1);2}", .if_without_else },
        .{ "G(X:i64)<computes>:i64=X\nA:i64=G(If(N>1,1))", .if_without_else },
        .{ "F:=Fn(C:logic)<computes>:i64{If(C,1)}", .if_without_else },
        .{ "F(C:logic)<computes>:i64=If(X:=N,X)", .if_without_else },
        .{ "F(C:logic)<computes>:i64=Block{R:=If(C,Return(1));2}", .if_without_else },
        // `Then`'s value is dropped as a statement's is.
        .{ "F(X:i64)<computes>:i64=Block{If(X>1,X==2);2}", .discarded_comparison },
        // One condition, and it must be one.
        .{ "F(X:i64)<computes>:i64=Block{If(X,1);2}", .type_mismatch },
        .{ "F(X:i64)<computes>:i64=Block{If(X>1,);2}", .expected_expression },
        .{ "F(X:i64)<computes>:i64=Block{If(X:=N,);2}", .macro_syntax },
    });
    // Two arguments were refused before (an If had both arms); three are still the plain If.
    const x = try h.execute("N:i64=3\nA<public>:i64=If(N>1,1,2)\nB<public>:i64=If(X:=N,X,0)\nF(C:logic)<computes>:void=If(C,1)\nV<public>:void=F(true)\n");
    try expectInteger(x, "A", 1);
    try expectInteger(x, "B", 3);
}

test "a For without a generator runs its body at most once, in one region" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("Some:option(i64)=option{7}\nNone:option(i64)=option{}\nItems:[]i64=array{1,2,3}\nvar Count:i64=0\n" ++
        // The Book's `for(Some?) { 1 }`, written with a binding: Forbic's conditions are logic.
        "A<public>:[]i64=For(X:=Some?,X*10)\nB<public>:[]i64=For(X:=None?,X*10)\n" ++
        "C<public>:[]i64=For(true,1)\nD<public>:[]i64=For(false,1)\n" ++
        "E<public>:[]i64=For(Y:=Items[1],Z:=Y+1,Z>2,Y*10+Z)\n" ++
        // A failing body, or a failing clause after a write: nothing is kept.
        "Try(I:i64,Ok:logic)<transacts>:[]i64=For(Block{set Count=Count+1;Ok},Block{set Count=Count+10;Items[I]})\n" ++
        "Run()<transacts>:i64=Block{P:=Try(0,true);Q:=Try(5,true);R:=Try(0,false);P.Length*1000+Q.Length*100+R.Length*10+Count}\n" ++
        "F<public>:i64=Run()\n" ++
        // An assigned local of the code around it is written directly, and restored on failure.
        "Local(N:i64)<transacts>:i64=Block{var T:i64=1;For(N>0,Block{set T=T+N;T});For(Block{set T=T*2;N>5},T);T}\n" ++
        "G<public>:i64=Local(4)*100+Local(-1)\n");
    try expectIntegers(x, "A", &.{70});
    try expectIntegers(x, "B", &.{});
    try expectIntegers(x, "C", &.{1});
    try expectIntegers(x, "D", &.{});
    try expectIntegers(x, "E", &.{23});
    // Try(0,true) keeps 11; Try(5,true) and Try(0,false) undo theirs.
    try expectInteger(x, "F", 1000 + 11);
    try expectInteger(x, "G", 5 * 100 + 1);
}

test "clauses before the first generator feed it and skip it when they fail" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("GetThing()<transacts><decides>:i64=2\nPassesFilter()<transacts><decides>:logic=true\n" ++
        "Items:[]i64=array{1,2,3}\nvar Sources:i64=0\n" ++
        // The Book's examples (07:902).
        "A<public>:[]i64=For(PassesFilter[],N:1..3,N)\n" ++
        "B<public>:[]i64=For(Thing:=GetThing[],N:Thing..Thing+2,Thing*10+N)\n" ++
        // The generator's source is evaluated only when the clauses before it succeed.
        "Source(N:i64)<transacts>:[]i64=Block{set Sources=Sources+1;array{N,N+1}}\n" ++
        "Feed(I:i64)<transacts>:[]i64=For(Y:=Items[I],Z:Source(Y),W:Items,W>Z,Z*10+W)\n" ++
        "Run()<transacts>:i64=Block{P:=Feed(0);Q:=Feed(7);P.Length*100+Q.Length*10+Sources}\n" ++
        "C<public>:[]i64=Feed(0)\nD<public>:i64=Run()\n" ++
        // A failing inner source still skips one iteration only.
        "E<public>:[]i64=For(true,X:Items,V:array{Items[X]},V)\n");
    try expectIntegers(x, "A", &.{ 1, 2, 3 });
    try expectIntegers(x, "B", &.{ 22, 23, 24 });
    // Y = 1: Z over [1, 2], W over Items: 12, 13, 23.
    try expectIntegers(x, "C", &.{ 12, 13, 23 });
    try expectInteger(x, "D", 300 + 0 + 2);
    try expectIntegers(x, "E", &.{ 2, 3 });
}

test "a For whose first clause is not a generator is refused where it cannot be lowered" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefusals(h, "Xs:[]i64=array{1,2}\nN:i64=3\n", &.{
        .{ "F(X:i64)<computes>:i64=Block{For(X>0,Return(1));2}", .for_clause_exit },
        .{ "F(X:i64)<computes>:i64=Block{For(X>0,Y:Xs,Return(Y));2}", .for_clause_exit },
        .{ "F(X:i64)<transacts>:i64=Block{Loop{For(X>0,Break());Break()};2}", .for_clause_exit },
        // A body shaped like a clause has lost the body, as before.
        .{ "A:[]i64=For(N>2,Y:Xs)", .for_syntax },
        .{ "A:[]i64=For(N>2,Y:=1)", .for_syntax },
        .{ "A:[]i64=For(Y:=1,Y:=2,Y)", .duplicate_name },
        .{ "A:[]i64=For(N:=1,N)", .shadowed_name },
        .{ "A:[]i64=For(N,1)", .type_mismatch },
        .{ "A:[]i64=For(Y:=Xs,Y:Y,Y)", .shadowed_name },
        .{ "F()<computes>:[]i64=For(Block{set N=1;true},1)", .not_mutable },
    });
}

test "Case(...) refuses an arm that no value can select, as Case[...] does" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefusals(h, "Color:=enum{Red,Green,Blue}\nAnimal:=class{}\nDog:=class(Animal){}\n", &.{
        // The Book's duplicate case (09:421), in the constant form and the pattern form.
        .{ "F(N:i64)<computes>:i64=Case(N,1=>10,1=>20,_=>0)", .unreachable_arm },
        .{ "F(C:Color)<computes>:i64=Case(C,Color.Red=>1,Color.Green=>2,Color.Red=>3,Color.Blue=>4)", .unreachable_arm },
        .{ "F(N:i64)<computes>:i64=Case(N+1,2=>20,2=>30,_=>0)", .unreachable_arm },
        .{ "F(M:option(i64))<computes>:i64=Case(M,option{}=>0,option{}=>1,option{X}=>X)", .unreachable_arm },
        .{ "F(A:Animal)<transacts>:i64=Case(A,D:Dog=>1,E:Dog=>2,_=>0)", .unreachable_arm },
        // An arm whose type an earlier arm takes (RFC-0083's rule, now in Case(...) too).
        .{ "F(A:Animal)<transacts>:i64=Case(A,X:Animal=>1,D:Dog=>2,_=>0)", .subsumed_arm },
        // A case after the wildcard, as before.
        .{ "F(N:i64)<computes>:i64=Case(N,_=>0,1=>1)", .case_arms },
    });
    // Arms that differ, guarded arms, and a redundant wildcard after every case of an enum:
    // the Book warns about that one (07:424), and Forbic, which has no warnings, accepts it.
    const x = try h.execute("Color:=enum{Red,Green,Blue}\nN:i64=2\n" ++
        "F(C:Color)<computes>:i64=Case(C,Color.Red=>1,Color.Green=>2,Color.Blue=>3,_=>-1)\n" ++
        "G(M:i64)<computes>:i64=Case(M,X:i64 where X>5=>1,X:i64 where X>5=>2,1=>3,_=>4)\n" ++
        "A<public>:i64=F(Color.Blue)*10+G(N)\n");
    try expectInteger(x, "A", 34);
    // A generic function that specializes itself inside an arm compiles the same `Case(...)`
    // again in the middle of the first compilation; neither specialization subsumes an arm.
    const nested = try h.execute("F[T:type](V:any,N:i64)<computes>:i64{Case(V,M:T=>If(N>0,F[[]i64](V,0),1),K:[]T=>2,_=>0)}\n" ++
        "A<public>:i64=F[i64](any(1),1)\nB<public>:i64=F[i64](any(array{1}),1)\n");
    try expectInteger(nested, "A", 0);
    try expectInteger(nested, "B", 2);
}

test "a constant arm of Case compares a scrutinee of a type the Book's case takes" {
    const h = try harness.create();
    defer scratch.release(h);
    const prelude = "Age:=type{_X:i64 where 0<=_X,_X<=150}\nRatio:=type{_X:float where 0.0<=_X,_X<=1.0}\nPoint:=struct{X:i64}\nOrigin:Point=Point{X:=0}\nPair:tuple(i64,i64)=tuple{0,0}\nNone:option(i64)=option{}\n";
    try expectRefusals(h, prelude, &.{
        .{ "F(X:float)<computes>:i64=Case(X,1.0=>1,_=>0)", .case_scrutinee_type },
        .{ "F(X:float)<computes>:i64=Case(X*2.0,1.0=>1,_=>0)", .case_scrutinee_type },
        .{ "F(R:Ratio)<computes>:i64=Case(R,0.5=>1,_=>0)", .case_scrutinee_type },
        .{ "F(P:Point)<computes>:i64=Case(P,Origin=>1,_=>0)", .case_scrutinee_type },
        .{ "F(T:tuple(i64,i64))<computes>:i64=Case(T,Pair=>1,_=>0)", .case_scrutinee_type },
        .{ "F(M:option(i64))<computes>:i64=Case(M,None=>1,_=>0)", .case_scrutinee_type },
        .{ "F(X:float)<computes><decides>:i64=Case[X,1.0=>1]", .case_scrutinee_type },
    });
    // Every type the Book lists, and the extension's patterns over the others.
    const x = try h.execute(prelude ++ "Color:=enum{Red,Green}\nWay:=enum<open>{Up,Down}\n" ++
        "FA(N:i64)<computes>:i64=Case(N,1=>10,_=>0)\nFB(L:logic)<computes>:i64=Case(L,true=>1,_=>0)\n" ++
        "FC(S:string)<computes>:i64=Case(S,\"a\"=>1,_=>0)\nFD(K:char)<computes>:i64=Case(K,'a'=>1,_=>0)\n" ++
        "FE(K:char32)<computes>:i64=Case(K,0u1f600=>1,_=>0)\nFG(C:Color)<computes>:i64=Case(C,Color.Red=>1,Color.Green=>2)\n" ++
        "FH(W:Way)<computes>:i64=Case(W,Way.Up=>1,_=>0)\nFI(A:Age)<computes>:i64=Case(A,3=>1,_=>0)\n" ++
        "FJ(X:float)<computes>:i64=Case(X,Y:float where Y==1.0=>1,_=>0)\nFK(T:tuple(i64,i64))<computes>:i64=Case(T,tuple{1,Y}=>Y,_=>0)\n" ++
        "FL(M:option(i64))<computes>:i64=Case(M,option{3}=>1,_=>0)\n" ++
        "V<public>:i64=FA(1)+FB(true)+FC(\"a\")+FD('a')+FE(0u1f600)+FG(Color.Green)+FH(Way.Up)+FI(3)+FJ(1.0)+FK(tuple{1,5})+FL(option{3})\n");
    try expectInteger(x, "V", 1 * 10 + 1 + 1 + 1 + 1 + 2 + 1 + 1 + 1 + 5 + 1);
}

/// A random `For` whose clauses before the first generator write a cell, bind and filter, with
/// an optional range generator, a clause after it and a body that may fail or run an `If`
/// without an else; the model runs the Book's rules for it: one region for the leading clauses
/// and everything after them, one region per iteration.
const Generated = struct {
    const Leading = union(enum) { write: struct { add: i64, below: i64 }, bind: u32, test_bound: i64 };
    items: [3]i64 = undefined,
    leading: [3]Leading = undefined,
    leading_count: usize = 0,
    /// The range `low..high`; with `low_bound` its low end is the last bound name instead of `low`.
    generator: bool = false,
    low: i64 = 0,
    high: i64 = 0,
    low_bound: bool = false,
    after: enum { none, filter, bind } = .none,
    after_value: i64 = 0,
    body: enum { plain, failing, elseless } = .plain,
    body_value: i64 = 0,

    fn generate(self: *Generated, random: std.Random) void {
        for (&self.items) |*item| item.* = random.intRangeAtMost(i64, 0, 9);
        self.leading_count = if (random.boolean()) 1 + random.uintLessThan(usize, 3) else random.uintLessThan(usize, 2);
        for (self.leading[0..self.leading_count]) |*clause| clause.* = switch (random.uintLessThan(u32, 3)) {
            0 => .{ .write = .{ .add = random.intRangeAtMost(i64, 1, 4), .below = random.intRangeAtMost(i64, 0, 12) } },
            1 => .{ .bind = random.uintLessThan(u32, 4) },
            else => .{ .test_bound = random.intRangeAtMost(i64, 0, 9) },
        };
        self.generator = self.leading_count == 0 or random.uintLessThan(u32, 3) != 0;
        self.low = random.intRangeAtMost(i64, 0, 3);
        self.high = random.intRangeAtMost(i64, 0, 5);
        self.low_bound = random.boolean();
        self.after = if (self.generator) @fromBackingInt(@intCast(random.uintLessThan(u32, 3))) else .none;
        self.after_value = random.intRangeAtMost(i64, 0, 4);
        self.body = @fromBackingInt(@intCast(random.uintLessThan(u32, 3)));
        self.body_value = random.intRangeAtMost(i64, 0, 4);
    }

    /// The index of the last bound name before leading clause `index`, if any.
    fn boundBefore(self: *const Generated, index: usize) ?usize {
        var found: ?usize = null;
        for (self.leading[0..index], 0..) |clause, at| if (clause == .bind) {
            found = at;
        };
        return found;
    }

    fn writeSource(self: *const Generated, out: *std.Io.Writer) !void {
        try out.print("var C:i64=0\nXs:[]i64=array{{{d},{d},{d}}}\nRun()<transacts>:[]i64=For(", .{ self.items[0], self.items[1], self.items[2] });
        for (self.leading[0..self.leading_count], 0..) |clause, index| {
            switch (clause) {
                .write => |w| try out.print("Block{{set C=C+{d};C<{d}}}", .{ w.add, w.below }),
                .bind => |at| try out.print("Y{d}:=Xs[{d}]", .{ index, at }),
                .test_bound => |limit| if (self.boundBefore(index)) |at| try out.print("Y{d}<{d}", .{ at, limit }) else try out.print("{d}<{d}", .{ self.items[0], limit }),
            }
            try out.writeAll(",");
        }
        const last = self.boundBefore(self.leading_count);
        if (self.generator) {
            if (self.low_bound and last != null) try out.print("N:Y{d}..{d},", .{ last.?, self.high }) else try out.print("N:{d}..{d},", .{ self.low, self.high });
            switch (self.after) {
                .none => {},
                .filter => try out.print("Block{{set C=C+1;N>{d}}},", .{self.after_value}),
                .bind => try out.writeAll("Z:=Xs[N],"),
            }
        }
        const n = if (self.generator) "N" else "0";
        switch (self.body) {
            .plain => try out.print("Block{{set C=C+10;{s}*10+{d}}}", .{ n, self.body_value }),
            .failing => try out.print("Block{{set C=C+10;Xs[{s}+{d}]}}", .{ n, self.body_value }),
            .elseless => try out.print("Block{{If({s}>{d},Set(C,C+100));{s}}}", .{ n, self.body_value, n }),
        }
        try out.writeAll(")\nR<public>:[]i64=Run()\nK<public>:i64=C\n");
    }

    const Outcome = struct { results: [8]i64 = undefined, count: usize = 0, cell: i64 = 0 };

    fn element(self: *const Generated, index: i64) ?i64 {
        if (index < 0 or index >= self.items.len) return null;
        return self.items[@intCast(index)];
    }

    fn evaluate(self: *const Generated) Outcome {
        var outcome: Outcome = .{};
        var cell: i64 = 0;
        var bound: [3]i64 = undefined;
        // The leading clauses: a failure undoes their writes and leaves the array empty.
        for (self.leading[0..self.leading_count], 0..) |clause, index| {
            const holds = switch (clause) {
                .write => |w| write: {
                    cell += w.add;
                    break :write cell < w.below;
                },
                .bind => |at| bind: {
                    bound[index] = self.element(at) orelse break :bind false;
                    break :bind true;
                },
                .test_bound => |limit| (if (self.boundBefore(index)) |at| bound[at] else self.items[0]) < limit,
            };
            if (!holds) return outcome;
        }
        const last = self.boundBefore(self.leading_count);
        var low = self.low;
        if (self.generator and self.low_bound and last != null) low = bound[last.?];
        const high = if (self.generator) self.high else 0;
        if (!self.generator) low = 0;
        var n = low;
        while (n <= high) : (n += 1) {
            // One iteration: a failure undoes what it wrote.
            var iteration = cell;
            const kept: ?i64 = iteration: {
                if (self.generator) switch (self.after) {
                    .none => {},
                    .filter => {
                        iteration += 1;
                        if (!(n > self.after_value)) break :iteration null;
                    },
                    .bind => _ = self.element(n) orelse break :iteration null,
                };
                switch (self.body) {
                    .plain => {
                        iteration += 10;
                        break :iteration n * 10 + self.body_value;
                    },
                    .failing => {
                        iteration += 10;
                        break :iteration self.element(n + self.body_value) orelse null;
                    },
                    .elseless => {
                        if (n > self.body_value) iteration += 100;
                        break :iteration n;
                    },
                }
            };
            if (kept) |value| {
                cell = iteration;
                outcome.results[outcome.count] = value;
                outcome.count += 1;
            } else if (!self.generator) {
                // Without a generator the body is in the leading clauses' region, which fails.
                return outcome;
            }
        }
        outcome.cell = cell;
        return outcome;
    }
};

test "generated For calls with leading clauses and If without an else agree with a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x0b_02_90);
    const random = prng.random();
    var nonempty: usize = 0;
    var empty: usize = 0;
    for (0..300) |round| {
        var generated: Generated = .{};
        generated.generate(random);
        var buffer: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        try generated.writeSource(&out);
        const expected = generated.evaluate();
        const x = h.execute(out.buffered()) catch |err| {
            std.debug.print("round {d}:\n{s}", .{ round, out.buffered() });
            return err;
        };
        const elements = x.elements(x.get("R").?).?;
        errdefer std.debug.print("round {d}: {d} elements, model {d}; cell {d}, model {d}\n{s}", .{ round, elements.len, expected.count, x.get("K").?.integer, expected.cell, out.buffered() });
        try std.testing.expectEqual(expected.count, elements.len);
        for (expected.results[0..expected.count], elements) |want, got| try std.testing.expectEqual(want, got.integer);
        try std.testing.expectEqual(expected.cell, x.get("K").?.integer);
        if (expected.count == 0) empty += 1 else nonempty += 1;
    }
    // Both outcomes are common, so neither rule is tested vacuously.
    try std.testing.expect(empty > 30 and nonempty > 100);
}
