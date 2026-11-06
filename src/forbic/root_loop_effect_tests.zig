//! Loops at the root (RFC-0079 "Remaining work", `fix2`). A module's initialisers run with every
//! heap effect (RFC-0078), and a loop's body is the code around the loop, so a loop at the root
//! may do what the root does: read and write module `var`s, declare local `var`s, build
//! instances, print and draw. The function a macro writes for such a loop declares exactly the
//! heap effects its body uses, so a loop that uses none compiles to what it compiled to before.
//! `For`, `While`, `First` and `Loop{...}` follow the one rule. A function the program writes
//! inside such a loop keeps the `<computes>` it has at the root.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const World = @import("native_effect_tests.zig").World;

fn expectInt(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse return error.MissingBinding;
    try std.testing.expectEqual(expected, value.integer);
}

fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code) !void {
    const result = h.front.compile(source);
    if (result == .ok or result.failed.code != code) {
        std.debug.print("expected {s} for:\n{s}\ngot {s}\n", .{ @tagName(code), source, if (result == .ok) "success" else @tagName(result.failed.code) });
        return error.WrongDiagnostic;
    }
}

/// The union of the heap effects the program's functions declare.
fn declared(p: types.Program) types.EffectSet {
    var set: types.EffectSet = .{ .diverges = false };
    for (p.functions) |f| {
        const own = f.effects();
        set.reads = set.reads or own.reads;
        set.writes = set.writes or own.writes;
        set.allocates = set.allocates or own.allocates;
    }
    return set;
}

test "a loop at the root prints, draws, reads and writes as the root does" {
    const w = try World.create();
    defer w.destroy();
    const x = try w.expect(
        \\var Count:i64=0
        \\Xs:[]i64=array{1,2,3}
        \\Shown:[]tuple()=For(X:Xs, Print("for {X}"))
        \\Summed:[]i64=For(X:Xs, Block{set Count=Count+X;Count})
        \\Walked:i64=Block{var I:i64=0;While(I<2,Block{Print("while {I}");set I=I+1});I}
        \\Found:i64=Attempt(First[X:Xs,X>1,Block{Print("first {X}");X*10}],-1)
        \\Looped:i64=Block{Loop{Print("loop");Break()};1}
        \\Drawn:[]i64=For(X:Xs, GetRandomInt(1,6))
        \\Seen:i64=Count
    , "for 1\nfor 2\nfor 3\nwhile 0\nwhile 1\nfirst 2\nloop\n");
    try expectInt(x, "Walked", 2);
    try expectInt(x, "Found", 20);
    try expectInt(x, "Looped", 1);
    try expectInt(x, "Seen", 6);
    try std.testing.expectEqual(@as(u64, 3), x.effects.draws);
    const summed = x.get("Summed").?.aggregate;
    try std.testing.expectEqual(@as(i64, 6), x.aggregate_values[summed.elements.end - 1].integer);
}

test "the function of a loop at the root declares what its body uses, and nothing for a pure loop" {
    const h = try harness.create();
    defer scratch.release(h);
    // A loop that uses no state compiles as before: every function is `<computes>`.
    const pure = try h.compile("Xs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, X*2)\nW:i64=Block{var I:i64=0;While(I<3,Block{set I=I+1});I}");
    const none = declared(pure);
    try std.testing.expect(!none.reads and !none.allocates);
    // `While` carries `I` in a local `var`: its function writes, and only that.
    try std.testing.expect(none.writes);
    const pure_for = declared(try h.compile("Xs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, X*2)"));
    try std.testing.expect(!pure_for.reads and !pure_for.writes and !pure_for.allocates);
    // A loop that reads a `var` reads, and only that.
    const reading = declared(try h.compile("var C:i64=1\nXs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, X+C)"));
    try std.testing.expect(reading.reads and !reading.writes and !reading.allocates);
    // One that builds an instance allocates, and only that.
    const building = declared(try h.compile("box:=class{N:i64=1}\nXs:[]i64=array{1,2}\nD:[]box=For(X:Xs, box{})"));
    try std.testing.expect(!building.reads and !building.writes and building.allocates);
    // An effect native needs all three.
    const printing = declared(try h.compile("Xs:[]i64=array{1,2}\nD:[]tuple()=For(X:Xs, Print(\"x\"))"));
    try std.testing.expect(printing.reads and printing.writes and printing.allocates);
}

test "inside a function a loop still does only what its function may, and an Fn of the program stays computes" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectRefused(h, "Xs:[]i64=array{1,2}\nF()<computes>:[]tuple()=For(X:Xs, Print(\"x\"))", .call_requires_transacts);
    try expectRefused(h, "var C:i64=0\nXs:[]i64=array{1,2}\nF()<reads>:[]i64=For(X:Xs, Block{set C=X;X})", .set_requires_writes);
    try expectRefused(h, "var C:i64=0\nXs:[]i64=array{1,2}\nF()<computes>:i64=Block{var I:i64=0;While(I<2,Block{set I=I+1});I}", .local_var_requires_writes);
    // A function the program writes inside a loop at the root has the type it has at the root.
    const h2 = try h.execute("Xs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, Block{F:=Fn(Y:i64){Y+1};G:function<computes>(tuple(i64),i64)=F;G(X)})");
    const d = h2.get("D").?.aggregate;
    try std.testing.expectEqual(@as(i64, 3), h2.aggregate_values[d.elements.end - 1].integer);
    try expectRefused(h, "var C:i64=0\nXs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, Block{F:=Fn(Y:i64){Y+C};F(X)})", .variable_read_requires_reads);
    // A loop inside a function of the program at the root is that function's.
    try expectRefused(h, "var C:i64=0\nXs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, Block{F:=Fn(Y:i64){For(Z:Xs, Block{set C=Z;Z}).Length};F(X)})", .set_requires_writes);
}

test "a root loop's function forged to declare less than it does is refused by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("var C:i64=0\nXs:[]i64=array{1,2}\nD:[]i64=For(X:Xs, Block{set C=C+X;C})\nE:i64=C");
    const x = (try h.run(p, 10_000)).ok;
    try expectInt(x, "E", 3);
    const forged_functions = try std.testing.allocator.dupe(types.RuntimeFunction, p.functions);
    defer std.testing.allocator.free(forged_functions);
    var changed = false;
    for (forged_functions) |*f| if (f.transacts) {
        const own = f.effects();
        // Take away one effect it uses.
        if (own.writes) {
            f.detail.no_writes = true;
            if (f.detail.no_reads and f.detail.no_allocates) {
                f.transacts = false;
                f.detail = .{};
            }
            changed = true;
        }
    };
    try std.testing.expect(changed);
    var forged = p;
    forged.functions = forged_functions;
    try harness.invalid(h, forged);
}

// Random root loops of the four forms whose bodies read, write, build or print, against a
// model: the program compiles, the loop's functions declare the union of what the bodies use
// (an effect native is all three), and the counter ends where the model says.
test "random loops at the root compile and declare exactly what they use" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x7007);
    const random = prng.random();
    var buffer: [2048]u8 = undefined;
    for (0..200) |_| {
        var out = std.Io.Writer.fixed(&buffer);
        try out.writeAll("var C:i64=0\nbox:=class{N:i64=1}\nXs:[]i64=array{1,2,3}\n");
        var reads = false;
        var writes = false;
        var allocates = false;
        var counter: i64 = 0;
        const loops = 1 + random.uintLessThan(usize, 3);
        for (0..loops) |index| {
            const op = random.uintLessThan(u8, 5);
            const body: []const u8 = switch (op) {
                0 => "X",
                1 => "X+C",
                2 => "Block{set C=C+X;X}",
                3 => "box{}.N",
                else => "Block{Print(\"p\");X}",
            };
            switch (op) {
                1 => reads = true,
                2 => {
                    reads = true;
                    writes = true;
                },
                // Reading the field of the new instance reads.
                3 => {
                    reads = true;
                    allocates = true;
                },
                4 => {
                    reads = true;
                    writes = true;
                    allocates = true;
                },
                else => {},
            }
            const form = random.uintLessThan(u8, 3);
            switch (form) {
                0 => {
                    try out.print("L{d}:[]i64=For(X:Xs, {s})\n", .{ index, body });
                    if (op == 2) counter += 6;
                },
                1 => {
                    // `First` stops at the first element: it alone is visited.
                    try out.print("L{d}:i64=Attempt(First[X:Xs, {s}],-1)\n", .{ index, body });
                    if (op == 2) counter += 1;
                },
                else => {
                    try out.print("L{d}:i64=Block{{var I:i64=0;While(I<3,Block{{X:=I+1;set I=I+1;D:={s};D}});I}}\n", .{ index, body });
                    writes = true;
                    if (op == 2) counter += 6;
                },
            }
        }
        try out.writeAll("Final:i64=C");
        const p = h.compile(out.buffered()) catch |err| {
            std.debug.print("random root loops failed:\n{s}\n", .{out.buffered()});
            return err;
        };
        const set = declared(p);
        if (set.reads != reads or set.writes != writes or set.allocates != allocates) {
            std.debug.print("{s}\ndeclared {any}, expected reads {} writes {} allocates {}\n", .{ out.buffered(), set, reads, writes, allocates });
            return error.TestUnexpectedResult;
        }
        const x = (try h.run(p, 1_000_000)).ok;
        try expectInt(x, "Final", counter);
    }
}

test "a Loop at the root and what is written inside it compile as they did before" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Loop{...}` at the root always had all three heap effects, and an `Fn` written inside it
    // took them: both are kept (review of `fix2`), so this reads `C` and joins `Bump` in a map.
    const x = try h.execute(
        \\var C:i64=4
        \\Bump(X:i64)<transacts>:i64=Block{set C=C+X;X}
        \\Looped:i64=Block{var R:i64=0;Loop{F:=Fn(Y:i64){Y+C};M:=map{1=>F,2=>Bump};set R=Attempt(M[1],Bump)(1);Break()};R}
    );
    try expectInt(x, "Looped", 5);
    // A stateless `Loop{...}` at the root still declares all three, as before.
    const p = try h.compile("Looped:i64=Block{Loop{Break()};1}");
    const set = declared(p);
    try std.testing.expect(set.reads and set.writes and set.allocates);
    // A `For` inside a root `Loop{...}` takes the loop's effects, as before; one at the root
    // declares what it uses.
    const nested = declared(try h.compile("Xs:[]i64=array{1}\nL:i64=Block{Loop{D:=For(X:Xs, X);Break()};1}"));
    try std.testing.expect(nested.reads and nested.writes and nested.allocates);
}
