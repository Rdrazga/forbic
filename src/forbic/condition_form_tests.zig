//! Conditions that the first increments left out: a single condition that binds, in `If` and
//! `While` (RFC-0059, RFC-0060), and a condition whose only failable part has no bracket, a
//! lone `?` (RFC-0049).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");

fn expectInt(x: anytype, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.Missing;
    };
    if (value.integer != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.integer, expected });
    try std.testing.expectEqual(expected, value.integer);
}

fn expectCode(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const r = h.front.compile(source);
    if (r == .ok) std.debug.print("unexpected admission: {s}\n", .{source});
    try std.testing.expect(r == .failed);
    if (r.failed.code != code) std.debug.print("diagnostic for {s}: {s}\n", .{ source, r.failed.message() });
    try std.testing.expectEqual(code, r.failed.code);
    try std.testing.expect(r.failed.span.end <= source.len);
}

const prelude = "Xs:[]i64=array{3,4,5}\nNext(I:i64)<computes><decides>:i64=Xs[I]\n";

test "a While with one condition that binds runs until the binding fails" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++
        "Sum()<transacts>:i64=Block{var I:i64=0;var T:i64=0;While(N:=Next[I],Block{set T=T+N;set I=I+1});T}\n" ++
        // The binding is visible in the body only, and a later statement sees the locals.
        "Last()<transacts>:i64=Block{var I:i64=0;var L:i64=-1;While(N:=Xs[I],Block{set L=N;set I=I+1});L*10+I}\n" ++
        // With an exit in the body the loop is the state loop of RFC-0068.
        "First(K:i64)<transacts>:i64=Block{var I:i64=0;While(N:=Next[I],Block{If(N>K,Return(N),false);set I=I+1});-1}\n" ++
        "Leave()<transacts>:i64=Block{var I:i64=0;Loop{While(N:=Next[I],Block{If(N==4,Break(),false);set I=I+1});Break()};I}\n" ++
        // The two-condition form is unchanged.
        "Two()<transacts>:i64=Block{var I:i64=0;var T:i64=0;While(N:=Next[I],N<5,Block{set T=T+N;set I=I+1});T}\n" ++
        "A<public>:i64=Sum()\nB<public>:i64=Last()\nC<public>:i64=First(3)\nD<public>:i64=First(9)\nE<public>:i64=Leave()\nF<public>:i64=Two()\n");
    try expectInt(x, "A", 12);
    try expectInt(x, "B", 53);
    try expectInt(x, "C", 4);
    try expectInt(x, "D", -1);
    try expectInt(x, "E", 1);
    try expectInt(x, "F", 7);
}

test "an If with one condition that binds selects by the binding and undoes a failed one" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(prelude ++ "var Log:i64=0\n" ++
        "Note(I:i64)<transacts><decides>:i64=Block{set Log=Log+1;Xs[I]}\n" ++
        "Pick(I:i64)<computes>:i64=If(N:=Next[I],N*10,-1)\n" ++
        "Seen(I:i64)<transacts>:i64=If(N:=Note[I],N,0)\n" ++
        "A<public>:i64=Pick(1)\nB<public>:i64=Pick(7)\nC<public>:i64=Seen(2)+Seen(8)\nD<public>:i64=Log\n" ++
        // At top level, and with the binding shadowing nothing afterwards.
        "E<public>:i64=If(N:=Xs[0],N+1,0)\nN:i64=100\nF<public>:i64=N\n");
    try expectInt(x, "A", 40);
    try expectInt(x, "B", -1);
    try expectInt(x, "C", 5);
    // The failed condition's write is undone: one call counts.
    try expectInt(x, "D", 1);
    try expectInt(x, "E", 4);
    try expectInt(x, "F", 100);
    // The branches have one type, and the binding does not reach the else branch.
    try expectCode(h, prelude ++ "A<public>:i64=If(N:=Next[0],N,\"none\")", .type_mismatch);
    try expectCode(h, prelude ++ "A<public>:i64=If(N:=Next[0],1,N)", .unknown_name);
    // A three-argument `If` whose condition is no binding is the `If` it was.
    try expectInt(try h.execute(prelude ++ "A<public>:i64=If(Xs[9]>0,1,2)"), "A", 2);
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
}

test "a condition whose only failable part is a lone unwrap selects the else branch" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("P:=class{X:i64=0}\nSome:option(P)=option{P{X:=5}}\nNone:option(P)=option{}\nE:option(i64)=option{}\nF:option(i64)=option{7}\n" ++
        "Pick(O:option(P))<transacts>:i64=If(O?.X>0,1,-1)\n" ++
        "Num(O:option(i64))<computes>:i64=If(O?>3 and O?<10,1,If(O?>=10,2,3))\n" ++
        "A<public>:i64=Pick(Some)*10+Pick(None)\n" ++
        "B<public>:i64=Num(option{5})*100+Num(option{12})*10+Num(option{})\n" ++
        "C<public>:i64=If(E?>3,1,0)+If(F?>3,10,0)\n" ++
        // The unwrap may be anywhere in the condition: in an argument, in a branch of an inner `If`.
        "Twice(N:i64)<computes>:i64=N*2\n" ++
        "D<public>:i64=If(Twice(E?)>3,1,2)*10+If(If(true,F?,0)>3,1,2)\n" ++
        // A `While` with one condition is such an `If`.
        "Drain()<transacts>:i64=Block{var O:option(i64)=option{3};var N:i64=0;While(O?>0,Block{set N=N+1;set O=If(N<3,option{3-N},option{})});N}\n" ++
        "G<public>:i64=Drain()\n");
    try expectInt(x, "A", 9);
    try expectInt(x, "B", 123);
    try expectInt(x, "C", 10);
    try expectInt(x, "D", 21);
    try expectInt(x, "G", 3);
}

test "a condition is its own failure context inside a failure context that existed" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076: in a `<decides>` function and in an `Attempt` body the unwrap fails the
    // condition, not the function or the attempt, so the else branch is taken, as in the Book.
    // (Before, it failed the context around the `If`: A was -7 and B was -8.)
    const x = try h.execute("E:option(i64)=option{}\nXs:[]i64=array{1,2}\n" ++
        "Dec(O:option(i64))<computes><decides>:i64=If(O?>3,1,0)\n" ++
        "A<public>:i64=Attempt(Dec[E],-7)\n" ++
        "B<public>:i64=Attempt(If(E?>3,1,0),-8)\n" ++
        // In an iteration of a `For` too: the element is no longer skipped.
        "Os:[]option(i64)=array{option{5},option{},option{1}}\n" ++
        "C<public>:[]i64=For(O:Os,If(O?>3,1,0))\n" ++
        // And an `option{}` around the condition catches, as RFC-0072 made it.
        "D<public>:option(i64)=option{If(E?>3,1,0)}\n");
    try expectInt(x, "A", 0);
    try expectInt(x, "B", 0);
    // 5 > 3; the empty option fails the condition; 1 > 3 does not hold.
    const kept = x.elements(x.get("C").?).?;
    try std.testing.expectEqual(@as(usize, 3), kept.len);
    try std.testing.expectEqual(@as(i64, 1), kept[0].integer);
    try std.testing.expectEqual(@as(i64, 0), kept[1].integer);
    try std.testing.expectEqual(@as(i64, 0), kept[2].integer);
    // The condition is nearer than the `option{}` around the `If`, so it catches first.
    const caught = x.elements(x.get("D").?).?;
    try std.testing.expectEqual(@as(usize, 1), caught.len);
    try std.testing.expectEqual(@as(i64, 0), caught[0].integer);
}

test "what is not a failable condition is refused as it was" {
    const h = try harness.create();
    defer scratch.release(h);
    const prefix = "E:option(i64)=option{}\nXs:[]i64=array{1,2}\n";
    // The branches are no failure context.
    try expectCode(h, prefix ++ "A<public>:i64=If(true,E?,0)", .failure_context_required);
    try expectCode(h, prefix ++ "A<public>:i64=If(E?>0,E?,0)", .failure_context_required);
    // An explicit `Require` says the region around the `If` should fail (RFC-0049): it is not
    // made a failable condition, with or without an unwrap beside it.
    try expectCode(h, prefix ++ "A<public>:i64=If(Require[Xs.Length>0],1,0)", .failure_context_required);
    try expectCode(h, prefix ++ "A<public>:i64=If(E?>0 and Require[Xs.Length>0],1,0)", .failure_context_required);
    // A function body inside the condition is a context of its own.
    try expectCode(h, prefix ++ "A<public>:i64=If(Fn()<computes>:i64{E?}()>0,1,0)", .failure_context_required);
    // Outside any condition nothing changed.
    try expectCode(h, prefix ++ "A<public>:i64=E?", .failure_context_required);
    try expectCode(h, prefix ++ "A<public>:i64=Block{E?}", .failure_context_required);
    // Deferred code cannot fail, but a condition inside it can be failable.
    const x = try h.execute(prefix ++ "var Log:i64=0\nF()<transacts>:i64=Block{Defer{set Log=If(E?>0,1,2)};5}\nA<public>:i64=F()\nB<public>:i64=Log\n");
    try expectInt(x, "A", 5);
    try expectInt(x, "B", 2);
}

test "every condition that must be failable is found in one pass, in generic bodies and bundles too" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [16384]u8 = undefined;
    for ([_]usize{ 1, 100 }) |conditions| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("E:option(i64)=option{}\nF:option(i64)=option{9}\n");
        for (0..conditions) |index| try out.print("C{d}<public>:i64=If({s}?>3,{d},-1)\n", .{ index, if (index % 2 == 0) "E" else "F", index });
        const x = try h.execute(out.buffered());
        try std.testing.expectEqual(@as(u32, @intCast(conditions)), h.front.condition_forced_count);
        try std.testing.expectEqual(@as(u32, 2), h.front.passes);
        for (0..conditions) |index| {
            var name: [8]u8 = undefined;
            try expectInt(x, try std.fmt.bufPrint(&name, "C{d}", .{index}), if (index % 2 == 0) -1 else @intCast(index));
        }
    }
    // One condition in a generic body is noted once per specialization and kept once.
    const x = try h.execute("Over[T:type](O:option(T),Limit:i64,N:i64)<computes>:i64{If(O?==O? and N>Limit,1,0)}\n" ++
        "A<public>:i64=Over[i64](option{1},2,3)+Over[string](option{},2,3)*10+Over[logic](option{true},5,3)*100\n");
    try expectInt(x, "A", 1);
    try std.testing.expectEqual(@as(u32, 1), h.front.condition_forced_count);
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    // A program with no such condition is compiled once, as ever.
    _ = try h.execute("Xs:[]i64=array{1}\nA<public>:i64=If(Xs[0]>0,1,2)\nB<public>:i64=If(Xs.Length>0,1,2)");
    try std.testing.expectEqual(@as(u32, 1), h.front.passes);
    try std.testing.expectEqual(@as(u32, 0), h.front.condition_forced_count);
    // In a bundle the conditions of each module are its own.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nE:option(i64)=option{}\nA<public>:i64=If(E?>0,1,2)*10+L.Pick(option{4})" },
        .{ .path = "lib.forb", .source = "Pick<public>(O:option(i64))<computes>:i64=If(O?>3,1,2)" },
    };
    const program = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |program| program,
        .failed => |problem| {
            std.debug.print("bundle: {s}:{d}: {s}\n", .{ problem.path, problem.diagnostic.span.start, problem.diagnostic.message() });
            return error.Compile;
        },
    };
    try std.testing.expectEqual(@as(u32, 2), h.front.condition_forced_count);
    try expectInt((try h.run(program, 131072)).ok, "A", 21);
}

/// Compiles `source`, which compiled before conditions could be made failable, and checks that
/// it is the program it was: one more compile than `passes` or another count of function nodes
/// than the compiler before gave (59, 89 and 109 for the three programs below) would mean that
/// a condition was wrapped. No function of it may fail.
fn expectUnchanged(h: *harness.Harness, source: []const u8, passes: u32, function_nodes: usize, name: []const u8, expected: i64) !void {
    const program = try h.compile(source);
    try std.testing.expectEqual(@as(u32, 0), h.front.condition_forced_count);
    try std.testing.expectEqual(passes, h.front.passes);
    if (program.function_nodes.len != function_nodes) std.debug.print("function nodes of {s}: {d}\n", .{ source, program.function_nodes.len });
    try std.testing.expectEqual(function_nodes, program.function_nodes.len);
    for (program.functions) |function| try std.testing.expect(!function.decides and function.transacts);
    var attempts: usize = 0;
    for (program.function_nodes) |entry| attempts += @intFromBool(entry.node.kind == .attempt_begin);
    try std.testing.expectEqual(@as(usize, 1), attempts);
    try expectInt((try h.run(program, 131072)).ok, name, expected);
}

test "a loop function that asks whether a failure would be caught makes no condition failable" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // A loop that can be left early, in a condition without a bracket. The loop's function
    // takes its effect from where it stands and asks whether a failure there is caught: the
    // answer is no, as it was, and the condition is not turned into a region for the asking.
    // The `option{...}` in the second and third still catches its unwrap (the one attempt).
    try expectUnchanged(h, "Maybe:option(i64)=option{}\n" ++
        "F()<transacts>:i64=If(Block{var I:i64=0;var N:i64=0;Loop{If(I>2,Break(),false);set I=I+1;Z:=option{Maybe?+1};set N=N+1};N>2},1,2)\n" ++
        "A<public>:i64=F()\n", 3, 89, "A", 1);
    try expectUnchanged(h, "Maybe:option(i64)=option{}\nXs:[]i64=array{1,2,3}\n" ++
        "F()<transacts>:i64=If(Block{var N:i64=0;While(N<3,Block{Z:=option{Maybe?+1};If(N>5,Return(7),false);set N=N+1});N>2},1,2)\n" ++
        "A<public>:i64=F()\n", 3, 109, "A", 1);
    // Without anything that can fail the loop in a condition has no attempt at all.
    const plain = try h.compile("Count(L:i64)<transacts>:i64=If(Block{var I:i64=0;Loop{If(I>L,Break(),false);set I=I+1};I>2},1,2)\nA<public>:i64=Count(5)\nB<public>:i64=Count(0)\n");
    try std.testing.expectEqual(@as(u32, 2), h.front.passes);
    try std.testing.expectEqual(@as(u32, 0), h.front.condition_forced_count);
    for (plain.functions) |function| try std.testing.expect(!function.decides);
    for (plain.function_nodes) |entry| try std.testing.expect(entry.node.kind != .attempt_begin);
    if (plain.function_nodes.len != 59) std.debug.print("function nodes of the plain loop: {d}\n", .{plain.function_nodes.len});
    try std.testing.expectEqual(@as(usize, 59), plain.function_nodes.len);
    const x = (try h.run(plain, 131072)).ok;
    try expectInt(x, "A", 1);
    try expectInt(x, "B", 2);
}

test "a lone unwrap makes its condition failable wherever it stands in it" {
    const h = try harness.create();
    defer scratch.release(h);
    // The condition is known by its `If`, so one that begins with generated code (a general
    // `For`) is found like one that begins with the unwrap.
    const x = try h.execute("Xs:[]i64=array{1,2,3}\n" ++
        "F(O:option(i64))<transacts>:i64=If(O?<For(X:Xs,Y:Xs,X).Length,1,2)\n" ++
        "G(O:option(i64))<transacts>:i64=If(For(X:Xs,Y:Xs,X).Length>O?,1,2)\n" ++
        // A condition that begins with an `If` of its own: each is known apart.
        "H(O:option(i64))<computes>:i64=If(If(O?>0,O?,0)>1,1,2)\n" ++
        "A<public>:i64=F(option{})*10+F(option{4})\nB<public>:i64=G(option{})*10+G(option{4})\nC<public>:i64=H(option{})*10+H(option{4})\n");
    try expectInt(x, "A", 21);
    try expectInt(x, "B", 21);
    // The inner branch `O?` stands in no failure context of its own but in the outer condition.
    try expectInt(x, "C", 21);
}
