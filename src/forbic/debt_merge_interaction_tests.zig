//! Where the amendments to loops, conditions and blame (RFC-0064 "Assigned locals", RFC-0049,
//! RFC-0056 "Blame") and the hashed lookups meet constructor functions and class `Block{...}`
//! clauses (RFC-0075) and modules declared inside files (RFC-0074). Each was written against
//! a compiler without the other; these programs need both.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");

const fuel = 1 << 20;

fn compile(h: *harness.Harness, inputs: []const modules.Input) !types.Program {
    return switch (h.front.compileBundle(.{ .root = "main.forb", .modules = inputs })) {
        .ok => |ir| ir,
        .failed => |problem| {
            const where = problem.diagnostic.location(problem.source);
            std.debug.print("interaction compile failed: {s}:{d}:{d}: {s}\n", .{ problem.path, where.line, where.column, problem.diagnostic.message() });
            return error.UnexpectedCompile;
        },
    };
}

fn execute(h: *harness.Harness, inputs: []const modules.Input) !evaluator.Execution {
    const result = try h.run(try compile(h, inputs), fuel);
    if (result == .failed) {
        std.debug.print("interaction run failed: {s}\n", .{result.failed.message()});
        return error.UnexpectedFailure;
    }
    return result.ok;
}

fn one(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    return execute(h, &.{.{ .path = "main.forb", .source = source }});
}

fn expectInt(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    const value = x.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.MissingBinding;
    };
    if (value.integer != expected) std.debug.print("{s}: {d}, expected {d}\n", .{ name, value.integer, expected });
    try std.testing.expectEqual(expected, value.integer);
}

/// A bundle of one file that must be refused with `code` at `line`:`column`.
fn expectRefused(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, line: u32, column: u32) !void {
    const result = h.front.compileBundle(.{ .root = "main.forb", .modules = &.{.{ .path = "main.forb", .source = source }} });
    if (result == .ok) {
        std.debug.print("interaction admitted:\n{s}\n", .{source});
        return error.UnexpectedAdmission;
    }
    const where = result.failed.diagnostic.location(result.failed.source);
    if (result.failed.diagnostic.code != code or where.line != line or where.column != column) std.debug.print("interaction diagnostic {s} at {d}:{d} for:\n{s}\n", .{ @tagName(result.failed.diagnostic.code), where.line, where.column, source });
    try std.testing.expectEqual(code, result.failed.diagnostic.code);
    try std.testing.expectEqual(line, where.line);
    try std.testing.expectEqual(column, where.column);
}

const xs = "Xs:[]i64=array{1,2,3}\n";

test "a For carries a local inside a constructor function and inside a class Block clause" {
    const h = try harness.create();
    defer scratch.release(h);
    // The clause sums the elements into its own `N`; the constructor's body sums them, scaled,
    // into `T` before its archetype. Neither compiled before loops carried locals.
    const x = try one(h, xs ++
        \\Acc:=class{
        \\  var Total:i64=0
        \\  var Seen:i64=0
        \\  Block{
        \\    var N:i64=0
        \\    For(X:Xs,Block{set N=N+X;N})
        \\    set Self.Seen=N
        \\  }
        \\}
        \\MakeAcc<constructor>(Scale:i64)<transacts>:Acc=Block{var T:i64=0;For(X:Xs,Block{set T=T+X*Scale;T});Acc{Total:=T}}
        \\Wide:=class(Acc){
        \\  var Extra:i64=0
        \\  Block{
        \\    var M:i64=0
        \\    For(X:Xs,X!=2,Block{set M=M+X;M})
        \\    set Self.Extra=M+Self.Seen
        \\  }
        \\}
        \\MakeWide<constructor>(Scale:i64)<transacts>:=Wide{MakeAcc<constructor>(Scale)}
        \\Run()<transacts>:i64=Block{P:=MakeAcc(2);P.Total*100+P.Seen}
        \\Both()<transacts>:i64=Block{W:=MakeWide(3);W.Total*1000+W.Seen*100+W.Extra}
        \\A<public>:i64=Run()
        \\B<public>:i64=Both()
    );
    // 2*(1+2+3) = 12 and 1+2+3 = 6.
    try expectInt(x, "A", 1206);
    // Delegation takes the constructor's carried sum (18); both clauses run, the superclass's
    // first: Seen = 6, then Extra = (1+3) + 6.
    try expectInt(x, "B", 18000 + 600 + 10);
    // A field is no local of the method that names its class: the loop writes it through
    // `Self` and carries nothing, and a local spelled like a field is the method's own.
    const y = try one(h, xs ++
        \\Acc:=class{
        \\  var Total:i64=0
        \\  Add()<transacts>:i64=Block{For(X:Xs,Block{set Self.Total=Self.Total+X;X});Self.Total}
        \\  Own()<transacts>:i64=Block{var Total:i64=100;For(X:Xs,Block{set Total=Total+X;X});Total}
        \\}
        \\Run()<transacts>:i64=Block{P:=Acc{};P.Add()*1000+P.Own()*1+P.Total*1000000}
        \\A<public>:i64=Run()
    );
    try expectInt(y, "A", 6 * 1000 + 106 + 6 * 1000000);
    // The bare name of a field is unknown in a loop of a method, as it is outside one.
    try expectRefused(h, xs ++
        \\Acc:=class{
        \\  var Total:i64=0
        \\  Add()<transacts>:i64=Block{For(X:Xs,Block{set Total=Total+X;X});0}
        \\}
    , .unknown_name, 4, 49);
}

test "in a nested module a For carries the locals of its function and writes the cells of the modules around it" {
    const h = try harness.create();
    defer scratch.release(h);
    // `T` is a cell of `Outer`: the loop in `Inner` writes it, as it did before loops carried
    // anything. `S` is a local of `Local`: the loop carries it and leaves the cell alone.
    const x = try one(h, xs ++
        \\Outer:=module{
        \\  var T<public>:i64=0
        \\  Inner<public>:=module{
        \\    Sum<public>()<transacts>:i64=Block{For(X:Xs,Block{set T=T+X;X});T}
        \\    Local<public>()<transacts>:i64=Block{var S:i64=0;For(X:Xs,Block{set S=S+X;S});S*10+T}
        \\  }
        \\}
        \\A<public>:i64=Outer.Inner.Sum()
        \\B<public>:i64=Outer.T
        \\C<public>:i64=Outer.Inner.Local()
        \\D<public>:i64=Outer.T
    );
    try expectInt(x, "A", 6);
    try expectInt(x, "B", 6);
    try expectInt(x, "C", 66);
    try expectInt(x, "D", 6);
    // A function that opens the module's braces on its own line, and one that follows a cell
    // of the module on one line: the braces of a module are no block around the loop.
    const y = try one(h, xs ++
        \\Outer:=module{Local<public>()<transacts>:i64=Block{var Q:i64=0;For(X:Xs,Block{set Q=Q+X;Q});Q}}
        \\Other:=module{var S<public>:i64=0;Add<public>()<transacts>:i64=Block{For(X:Xs,Block{set S=S+X;S});S}}
        \\A<public>:i64=Outer.Local()
        \\B<public>:i64=Other.Add()*10+Other.S
    );
    try expectInt(y, "A", 6);
    try expectInt(y, "B", 66);
    // A name that some module declares as a cell is never carried, in a file or in a module
    // nested in one: a local of that name assigned in a loop is refused where it always was.
    // RFC-0076: the cell is declared after the function here; a local may not have the name
    // of a cell declared before it at all, which the two programs below were (`not_mutable`
    // at 5:74 and 3:62) and are now refused for at the local.
    try expectRefused(h, xs ++
        \\Outer:=module{
        \\  Inner<public>:=module{
        \\    Shadow<public>()<transacts>:i64=Block{var T:i64=5;For(X:Xs,Block{set T=T+X;T});T}
        \\  }
        \\  var T<public>:i64=0
        \\}
    , .not_mutable, 4, 74);
    try expectRefused(h, xs ++
        \\Shadow()<transacts>:i64=Block{var T:i64=5;For(X:Xs,Block{set T=T+X;T});T}
        \\var T:i64=0
    , .not_mutable, 2, 62);
    try expectRefused(h, xs ++
        \\Outer:=module{
        \\  var T<public>:i64=0
        \\  Inner<public>:=module{
        \\    Shadow<public>()<transacts>:i64=Block{var T:i64=5;For(X:Xs,Block{set T=T+X;T});T}
        \\  }
        \\}
    , .shadowed_name, 5, 47);
    try expectRefused(h, xs ++
        \\var T:i64=0
        \\Shadow()<transacts>:i64=Block{var T:i64=5;For(X:Xs,Block{set T=T+X;T});T}
    , .shadowed_name, 3, 35);
}

test "a lone unwrap makes its condition failable inside a nested module and inside a constructor function" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try one(h, "E:option(i64)=option{}\nF:option(i64)=option{7}\n" ++
        \\M:=module{
        \\  Pick<public>(O:option(i64))<computes>:i64=If(O?>3,1,2)
        \\  Deep<public>:=module{
        \\    Both<public>(O:option(i64))<computes>:i64=If(O?>3 and O?<10,5,6)
        \\  }
        \\}
        \\P:=class{
        \\  X:i64=0
        \\  var Y:i64=0
        \\  Block{set Self.Y=If(F?>Self.X,1,2)}
        \\}
        \\MakeP<constructor>(O:option(i64))<transacts>:=P{X:=If(O?>3,10,20)}
        \\Run()<transacts>:i64=Block{A:=MakeP(E);B:=MakeP(F);(A.X+B.X)*100+A.Y*10+B.Y}
        \\A<public>:i64=M.Pick(E)*10+M.Pick(F)
        \\B<public>:i64=M.Deep.Both(E)*10+M.Deep.Both(F)
        \\C<public>:i64=Run()
    );
    try expectInt(x, "A", 21);
    try expectInt(x, "B", 65);
    // X is 20 then 10; the clause compares 7 with each: 7>20 fails, 7>10 fails.
    try expectInt(x, "C", 3000 + 22);
    // What exempts a condition exempts it in a module too: a branch is no failure context.
    try expectRefused(h, "E:option(i64)=option{}\nM:=module{\nBad<public>()<computes>:i64=If(true,E?,0)\n}", .failure_context_required, 3, 38);
}

test "a failing filter in a nested module of an imported file is traced to that file and to the filter" {
    const h = try harness.create();
    defer scratch.release(h);
    const main = "L:=import{\"lib.forb\"}\nYs:[]i64=array{5}\nPlain<public>:[]i64=For(Y:Ys,Y)\nA<public>:[]i64=L.Kit.Odd()\nB<public>:i64=A.Length";
    const library = "Xs:[]i64=array{1,2,3}\nPlain<public>:[]i64=For(X:Xs,X*2)\nKit<public>:=module{\nOdd<public>()<computes>:[]i64=For(X:Xs,Y:Xs,X!=2,Y>2,X*10+Y)\n}";
    const program = try compile(h, &.{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = library } });
    const result = try h.run(program, fuel);
    try std.testing.expect(result == .ok);
    const x = result.ok;
    try expectInt(x, "B", 2);
    const kit = for (program.nested) |entry| {
        if (std.mem.eql(u8, entry.name.text(program.source), "Kit")) break entry.source;
    } else return error.NoSuchModule;
    const failures = x.failures[0..@min(x.failures.len, x.failure_count)];
    // X = 1 and X = 3: two elements fail `Y>2`. X = 2: `X!=2` fails for each of the three.
    const expected = [_][]const u8{ "Y>2", "Y>2", "X!=2", "X!=2", "X!=2", "Y>2", "Y>2" };
    try std.testing.expectEqual(expected.len, failures.len);
    for (failures, expected) |failure, text| {
        // In the library's file, inside the braces of its module, at the user's expression:
        // not at the first macro call of the file, and not at one of the root's.
        const file = modules.owner(failure.span, program.modules) orelse return error.OutsideEveryFile;
        try std.testing.expectEqualStrings("lib.forb", program.modules[file].path.text(program.paths));
        try std.testing.expect(modules.contains(kit, failure.span));
        try std.testing.expectEqualStrings(text, failure.span.text(program.source));
    }
    // A diagnostic about the generated code of a loop in that module names the file and the loop.
    const broken = "Xs:[]i64=array{1,2,3}\nPlain<public>:[]i64=For(X:Xs,X*2)\nKit<public>:=module{\nOk()<computes>:[]i64=For(X:Xs,X)\nOdd<public>()<computes>:[]i64=For(X:Xs,Y:9,X*Y)\n}";
    const refused = h.front.compileBundle(.{ .root = "main.forb", .modules = &.{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = broken } } });
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqualStrings("lib.forb", refused.failed.path);
    try std.testing.expectEqual(types.Diagnostic.Code.type_mismatch, refused.failed.diagnostic.code);
    const where = refused.failed.diagnostic.location(refused.failed.source);
    try std.testing.expectEqual(@as(u32, 5), where.line);
    try std.testing.expectEqual(@as(u32, 31), where.column);
    try std.testing.expectEqualStrings("For", refused.failed.diagnostic.span.text(refused.failed.source));
}

test "namesakes in sibling nested modules and in the file each resolve to their own scope" {
    const h = try harness.create();
    defer scratch.release(h);
    // A class, a function and a generic function of one name in the file and in two sibling
    // modules. Each scope means its own; a module that declares none means the file's; a
    // path means the module it names. Debug builds check every lookup against the scan.
    // RFC-0076: a module may not redeclare a name the file declared before it, so the file's
    // three follow `A` and `B` (they led); `C`, declared after them, and the file's functions mean them.
    const x = try one(h,
        \\A:=module{
        \\  Thing<public>:=class{V<public>:i64=2}
        \\  Get<public>()<computes>:i64=2
        \\  Id<public>[t:type](X:t)<computes>:i64{2}
        \\  Own<public>()<transacts>:i64=Thing{}.V*100+Get()*10+Id[i64](0)
        \\}
        \\B:=module{
        \\  Thing<public>:=class{V<public>:i64=3}
        \\  Get<public>()<computes>:i64=3
        \\  Id<public>[t:type](X:t)<computes>:i64{3}
        \\  Own<public>()<transacts>:i64=Thing{}.V*100+Get()*10+Id[i64](0)
        \\}
        \\Thing:=class{V:i64=1}
        \\Get()<computes>:i64=1
        \\Id[t:type](X:t)<computes>:i64{1}
        \\C:=module{
        \\  Own<public>()<transacts>:i64=Thing{}.V*100+Get()*10+Id[i64](0)
        \\}
        \\Own()<transacts>:i64=Thing{}.V*100+Get()*10+Id[i64](0)
        \\Cross()<transacts>:i64=A.Thing{}.V*100+B.Get()*10+A.Id[i64](0)
        \\RA<public>:i64=A.Own()
        \\RB<public>:i64=B.Own()
        \\RC<public>:i64=C.Own()
        \\RF<public>:i64=Own()
        \\RX<public>:i64=Cross()
    );
    try expectInt(x, "RA", 222);
    try expectInt(x, "RB", 333);
    try expectInt(x, "RC", 111);
    try expectInt(x, "RF", 111);
    try expectInt(x, "RX", 232);
    // Many sibling modules that declare the same three names: every one is found in its own
    // scope, through tables that grow several times on the way.
    var buffer: [16384]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const siblings = 24;
    for (1..siblings + 1) |index| try out.print("M{d}:=module{{\nThing<public>:=class{{V<public>:i64={d}}}\nGet<public>()<computes>:i64={d}\nOwn<public>()<transacts>:i64=Thing{{}}.V*100+Get()\n}}\n", .{ index, index, index });
    // The file's own two come after the modules (RFC-0076, as above).
    try out.writeAll("Thing:=class{V:i64=0}\nGet()<computes>:i64=0\nSum()<transacts>:i64=Thing{}.V+Get()");
    for (1..siblings + 1) |index| try out.print("+M{d}.Own()+M{d}.Thing{{}}.V+M{d}.Get()", .{ index, index, index });
    try out.writeAll("\nR<public>:i64=Sum()");
    const y = try one(h, out.buffered());
    // Each module gives 101*i + i + i.
    try expectInt(y, "R", 103 * (siblings * (siblings + 1) / 2));
    // A module that follows the file's declaration of the name is refused at its own.
    try expectRefused(h, "Thing:=class{V:i64=1}\nA:=module{\n  Thing<public>:=class{V:i64=2}\n}", .shadowed_name, 3, 3);
    try expectRefused(h, "Get()<computes>:i64=1\nA:=module{\n  Get<public>()<computes>:i64=2\n}", .shadowed_name, 3, 3);
    try expectRefused(h, "Id[t:type](X:t)<computes>:i64{1}\nA:=module{\n  Id<public>[t:type](X:t)<computes>:i64{2}\n}", .shadowed_name, 3, 3);
}
