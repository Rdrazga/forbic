//! Session cells (RFC-0087, P5.4): `session` and `GetSession()` (K1), keyed cells (W4 to W8):
//! single-key reads and writes, nested and compound updates, rollback, tasks, live variables and
//! guards, the refusals `weak_map_whole` and `weak_map_initializer`, the names in their roles and
//! in bundles, reports, inspection, every trace mode, and an oracle: random programs of reads and
//! writes of a session cell in regions that commit and fail agree with a model of the cell. Forged
//! IR is in `keyed_cell_forgery_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const inspection = @import("inspection.zig");
const modules = @import("modules.zig");
const harness = @import("generic_function_tests.zig");
const live_tests = @import("live_tests.zig");

const Code = types.Diagnostic.Code;
const allocator = std.testing.allocator;

fn expectInt(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    try std.testing.expectEqual(expected, x.get(name).?.integer);
}

/// The report of a run of `source` on both machines, which must contain `expected`.
fn expectReported(h: *harness.Harness, source: []const u8, expected: []const u8) !evaluator.Execution {
    const x = try live_tests.run(h, source);
    const buffer = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(buffer);
    const text = try live_tests.report(x, buffer);
    if (std.mem.indexOf(u8, text, expected) == null) {
        std.debug.print("report {s}\nlacks {s}\n", .{ text, expected });
        return error.TestUnexpectedResult;
    }
    return x;
}

test "Book 16:620: a per-session counter in a weak_map(session, int)" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var GlobalCounter:weak_map(session, i64) = map{}
        \\IncrementCounter()<reads><writes>:i64 = Block{
        \\    CurrentValue := Attempt(GlobalCounter[GetSession()], 0)
        \\    set GlobalCounter[GetSession()] = CurrentValue + 1
        \\    CurrentValue + 1
        \\}
        \\A:i64 = IncrementCounter()
        \\B:i64 = IncrementCounter()
        \\C:i64 = Attempt(GlobalCounter[GetSession()], -1)
    ;
    const x = try expectReported(h, source, "{\"GlobalCounter\":[{\"$session\":0},2],\"A\":1,\"B\":2,\"C\":2}");
    try expectInt(x, "A", 1);
    try live_tests.expectEveryMode(source);
}

test "K1: one session per run, comparable, a map key, held as a value; it builds nothing" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\S:session = GetSession()
        \\Same:logic = Attempt(Block{Require[S == GetSession()]; true}, false)
        \\M:map(session, string) = map{S => "one"}
        \\T:tuple(session, i64) = tuple{GetSession(), 1}
        \\O:option(session) = option{S}
        \\Read()<reads>:session = GetSession()
        \\R:logic = Attempt(Block{Require[Read() == S]; true}, false)
        \\A:[]session = array{S, Read()}
    ;
    const x = try expectReported(h, source, "{\"S\":{\"$session\":0},\"Same\":true,\"M\":[{\"$session\":0},\"one\"],\"T\":[{\"$session\":0},1],\"O\":[{\"$session\":0}],\"R\":true,\"A\":[{\"$session\":0},{\"$session\":0}]}");
    try std.testing.expectEqual(@as(u32, 0), x.get("S").?.enumeration.index);
    try live_tests.expectEveryMode(source);
}

test "W4 to W6: single-key reads and writes, nested and compound updates, and rollback three deep" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\point := struct{X:i64, Y:i64}
        \\var Items:weak_map(session, []i64) = map{}
        \\var Points:weak_map(session, point) = map{}
        \\var Names:weak_map(session, string) = map{}
        \\S:session = GetSession()
        \\Missing:i64 = Attempt(Items[S][0], -1)
        \\set Items[S] = array{1, 2, 3}
        \\set Points[S] = point{X := 1, Y := 2}
        \\Update()<reads><writes><decides>:i64 = Block{
        \\    K := GetSession()
        \\    set Items[K][1] = 99
        \\    set Points[K].Y = 20
        \\    set Points[K].X += 5
        \\    Items[K][1] + Points[K].X + Points[K].Y
        \\}
        \\U:i64 = Attempt(Update[], -1)
        \\Deep:i64 = Attempt(Block{
        \\    set Names[S] = "a"
        \\    Attempt(Block{
        \\        set Names[S] = "b"
        \\        Attempt(Block{set Names[S] = "c"; Require[false]; 0}, 0)
        \\        Require[Names[S] == "b"]
        \\        Require[false]
        \\        0
        \\    }, 0)
        \\    Require[Names[S] == "a"]
        \\    1
        \\}, -1)
        \\Kept:string = Attempt(Names[S], "")
        \\Failed:i64 = Attempt(Block{set Items[S][7] = 0; 1}, -2)
        \\After:i64 = Attempt(Items[S][1], -1)
    ;
    const x = try expectReported(h, source, "\"Items\":[{\"$session\":0},[1,99,3]],\"Points\":[{\"$session\":0},{\"X\":6,\"Y\":20}],\"Names\":[{\"$session\":0},\"a\"]");
    try expectInt(x, "Missing", -1);
    try expectInt(x, "U", 125);
    try expectInt(x, "Deep", 1);
    try std.testing.expectEqualStrings("a", x.get("Kept").?.string);
    try expectInt(x, "Failed", -2);
    try expectInt(x, "After", 99);
    try live_tests.expectEveryMode(source);
}

test "keyed cells in tasks, read by a live variable's guard and by Await, written across switches" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var Counts:weak_map(session, i64) = map{}
        \\var live Double:i64 = Attempt(Counts[GetSession()], 0) * 2
        \\Bump()<reads><writes>:i64 = Block{
        \\    S := GetSession()
        \\    set Counts[S] = Attempt(Counts[S], 0) + 1
        \\    1
        \\}
        \\Worker()<suspends><transacts>:i64 = Block{
        \\    Bump()
        \\    Sleep(1.0)
        \\    Bump()
        \\    Attempt(Counts[GetSession()], -1)
        \\}
        \\Waiter()<suspends><transacts>:i64 = Await(Block{ N := Counts[GetSession()]; Require[N > 10]; N })
        \\T := Spawn{Worker()}
        \\W := Spawn{Waiter()}
        \\A:i64 = Double
        \\set Counts[GetSession()] = 10
        \\B:i64 = Double
        \\Rolled:i64 = Attempt(Block{set Counts[GetSession()] = 100; Require[false]; 0}, Double)
    ;
    const x = try expectReported(h, source, "{\"Counts\":[{\"$session\":0},11],\"Double\":22,");
    try expectInt(x, "A", 2);
    try expectInt(x, "B", 20);
    try expectInt(x, "Rolled", 20);
    const buffer = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(buffer);
    const text = try live_tests.report(x, buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"W\":{\"$task\":{\"sequence\":2,\"state\":\"completed\",\"result\":11}}") != null);
    try live_tests.expectEveryMode(source);
}

test "weak_map_whole and weak_map_initializer, each at its place; ordinary weak_map cells keep their meaning" {
    const h = try harness.create();
    defer scratch.release(h);
    const head = "var X:weak_map(session, i64) = map{}\n";
    const Case = struct { []const u8, Code, []const u8 };
    const cases = [_]Case{
        .{ "A:weak_map(session, i64) = X", .weak_map_whole, "X" },
        .{ "set X = map{}", .weak_map_whole, "X" },
        .{ "F()<transacts>:i64 = Block{ set X = map{}; 0 }", .weak_map_whole, "X" },
        .{ "F()<transacts>:void = Set(X, map{})", .weak_map_whole, "X" },
        .{ "G(W:weak_map(session, i64))<computes>:i64 = 0\nA:i64 = G(X)", .weak_map_whole, "X" },
        .{ "set live X = Fn()<reads>:weak_map(session, i64){ map{} }", .weak_map_whole, "X" },
        .{ "A:i64 = Attempt(Lookup(X, GetSession())?, 0)", .weak_map_whole, "X" },
        .{ "A:i64 = X.Length", .weak_map_whole, "X" },
        .{ "F()<reads>:logic = Block{ Y := X; true }", .weak_map_whole, "X" },
        .{ "A:i64 = Attempt(WithIndex[X, GetSession(), 1][GetSession()], 0)", .weak_map_whole, "X" },
        .{ "F()<computes>:i64 = Attempt(X[GetSession()], 0)", .variable_read_requires_reads, "X" },
        .{ "F()<reads>:i64 = Block{ set X[GetSession()] = 1; 1 }", .set_requires_writes, "X" },
        .{ "A:i64 = X[GetSession()]", .failure_context_required, "[" },
        .{ "A:i64 = Attempt(X[1], 0)", .type_mismatch, "1" },
        .{ "set X[GetSession()] = \"s\"", .type_mismatch, "\"s\"" },
        .{ "set X += map{}", .weak_map_whole, "X" },
        .{ "F()<transacts>:i64 = Block{ set X += map{}; 0 }", .weak_map_whole, "X" },
        // A variable whose type is a function (RFC-0084, P4.3) holds its raw value and its
        // result whole, in cells of their own.
        .{ "Make(A:i64)<reads>:weak_map(session, i64) = map{}\nvar Out:Make = 1", .weak_map_whole, "Out" },
        .{ "Use(A:weak_map(session, i64))<reads>:i64 = 1\nvar Out:Use = map{}", .weak_map_whole, "Out" },
        .{ "Use(A:weak_map(session, i64))<reads>:i64 = 1\nOut:Use = map{}", .weak_map_whole, "Out" },
    };
    for (cases) |case| {
        const source = try std.mem.concat(allocator, u8, &.{ head, case[0] });
        defer allocator.free(source);
        try live_tests.expectRefused(h, source, case[1], case[2]);
    }
    try live_tests.expectRefused(h, "var X:weak_map(session, i64) = map{GetSession() => 1}", .weak_map_initializer, "map{GetSession() => 1}");
    try live_tests.expectRefused(h, "M:map(session, i64) = map{}\nvar X:weak_map(session, i64) = M", .weak_map_initializer, "M");
    try live_tests.expectRefused(h, "var live X:weak_map(session, i64) = map{}", .weak_map_whole, "X");
    try live_tests.expectRefused(h, "live X:weak_map(session, i64) = map{}", .weak_map_whole, "X");
    try live_tests.expectRefused(h, "F()<computes>:session = GetSession()", .call_requires_reads, "GetSession");
    try live_tests.expectRefused(h, "S:session = session{}", .unknown_name, "session");
    try live_tests.expectRefused(h, "S:i64 = GetSession().Value", .unknown_field, "Value");
    // A `weak_map` of another key, a local and an immutable binding of a session type stay
    // ordinary values (W4, Q8).
    const x = try live_tests.run(h,
        \\var W:weak_map(i64, i64) = map{}
        \\set W = map{1 => 2}
        \\L:weak_map(session, i64) = map{GetSession() => 3}
        \\F()<transacts>:i64 = Block{
        \\    var Local:weak_map(session, i64) = map{}
        \\    set Local[GetSession()] = 4
        \\    set Local = map{}
        \\    Attempt(Local[GetSession()], 5)
        \\}
        \\A:i64 = Attempt(W[1], 0) + Attempt(L[GetSession()], 0) * 10 + F() * 100
    );
    try expectInt(x, "A", 532);
}

test "session, GetSession and keyed cells yield to every declaration of the names, and work in bundles" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try h.execute("session := struct{A:i64}\nS:session = session{A := 1}\nX:i64 = S.A");
    try expectInt(x, "X", 1);
    x = try h.execute("GetSession()<computes>:i64 = 7\nX:i64 = GetSession()");
    try expectInt(x, "X", 7);
    x = try h.execute("F()<computes>:i64 = Block{ session := 3; session }\nX:i64 = F()");
    try expectInt(x, "X", 3);
    x = try h.execute("F(GetSession:i64)<computes>:i64 = GetSession + 1\nX:i64 = F(2)");
    try expectInt(x, "X", 3);
    x = try h.execute("session := enum{One, Two}\nvar X:weak_map(session, i64) = map{}\nset X = map{session.One => 1}\nY:i64 = Attempt(X[session.One], 0)");
    try expectInt(x, "Y", 1);
    // A declaration further down gives the name its meaning above it too.
    try std.testing.expect(h.front.compile("S:session = GetSession()\nsession := struct{}") == .failed);
    // No local takes the cell's name (RFC-0076: no shadowing).
    try live_tests.expectRefused(h, "var X:weak_map(session, i64) = map{}\nF()<computes>:i64 = Block{ X := 4; X }", .shadowed_name, "X");
    // A keyed cell of an imported file, read and written by its own functions and through
    // the alias, one key at a time; and named whole through the alias, refused.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nA:i64 = L.Visit()\nB:i64 = L.Visit()\nC:i64 = Attempt(L.Visits[GetSession()], -1)" },
        .{ .path = "lib.forb", .source = "var Visits<public>:weak_map(session, i64) = map{}\nVisit<public>()<reads><writes>:i64 = Block{\n    S := GetSession()\n    N := Attempt(Visits[S], 0) + 1\n    set Visits[S] = N\n    N\n}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("{t} at {d}\n", .{ bundled.failed.diagnostic.code, bundled.failed.diagnostic.span.start });
    const run = (try h.run(bundled.ok, live_tests.fuel)).ok;
    try expectInt(run, "B", 2);
    try expectInt(run, "C", 2);
    const whole = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nG(W:weak_map(session, i64))<computes>:i64 = 0\nA:i64 = G(L.Visits)" },
        inputs[1],
    };
    const refused = h.front.compileBundle(.{ .root = "main.forb", .modules = &whole });
    try std.testing.expect(refused == .failed and refused.failed.diagnostic.code == .weak_map_whole);
    // A keyed cell of a nested module (RFC-0074), written by its function and read from
    // outside through the module's path.
    const nested = [_]modules.Input{
        .{ .path = "main.forb", .source =
        \\M:=module{
        \\  var X<public>:weak_map(session, string) = map{}
        \\  Put<public>(S:string)<reads><writes>:string = Block{ set X[GetSession()] = S; S }
        \\}
        \\A:string = M.Put("a")
        \\B:string = Attempt(M.X[GetSession()], "")
        \\C:string = Attempt(Block{ M.Put("c"); Require[false]; "" }, Attempt(M.X[GetSession()], "-"))
        },
    };
    const inner = h.front.compileBundle(.{ .root = "main.forb", .modules = &nested });
    if (inner == .failed) std.debug.print("{t} at {d}\n", .{ inner.failed.diagnostic.code, inner.failed.diagnostic.span.start });
    const inner_run = (try h.run(inner.ok, live_tests.fuel)).ok;
    try std.testing.expectEqualStrings("a", inner_run.get("B").?.string);
    try std.testing.expectEqualStrings("a", inner_run.get("C").?.string);
    try std.testing.expect(inner.ok.source_cells[0].keyed == .session);
    // A single-key write through a qualified name, `set M.X[K] = V`, is no form for any cell
    // yet (the macro pass rewrites only a path that starts with a plain name): it is refused
    // at the `[` as an ordinary cell's is, at the root and in a function, nested or not, and
    // through an import's alias. Named whole through a path, a keyed cell is `weak_map_whole`.
    const module_head = "L := import{\"lib.forb\"}\nM:=module{\n  var X<public>:weak_map(session, i64) = map{}\n  var N<public>:weak_map(session, []i64) = map{}\n  var O<public>:weak_map(i64, i64) = map{}\n}\n";
    const lib = "var X<public>:weak_map(session, i64) = map{}\nvar O<public>:weak_map(i64, i64) = map{}\n";
    const Qualified = struct { []const u8, Code, []const u8 };
    const qualified = [_]Qualified{
        .{ "set M.X[GetSession()] = 2", .expected_equal, "[" },
        .{ "F()<reads><writes>:i64 = Block{ set M.X[GetSession()] = 2; 2 }", .expected_equal, "[" },
        .{ "S:session = GetSession()\nset M.N[S][0] = 2", .expected_equal, "[" },
        .{ "S:session = GetSession()\nF()<reads><writes>:i64 = Attempt(Block{ set M.X[S] += 2; 2 }, 0)", .expected_equal, "[" },
        .{ "set M.O[1] = 2", .expected_equal, "[" },
        .{ "set L.X[GetSession()] = 2", .expected_equal, "[" },
        .{ "set L.O[1] = 2", .expected_equal, "[" },
        .{ "set M.X = map{}", .weak_map_whole, "M.X" },
        .{ "F()<transacts>:i64 = Block{ set M.X = map{}; 0 }", .weak_map_whole, "M.X" },
        .{ "Y:weak_map(session, i64) = M.X", .weak_map_whole, "M.X" },
        .{ "set L.X = map{}", .weak_map_whole, "L.X" },
    };
    for (qualified) |case| {
        const source = try std.mem.concat(allocator, u8, &.{ module_head, case[0] });
        defer allocator.free(source);
        const bundle = [_]modules.Input{ .{ .path = "main.forb", .source = source }, .{ .path = "lib.forb", .source = lib } };
        const result = h.front.compileBundle(.{ .root = "main.forb", .modules = &bundle });
        if (result != .failed) {
            std.debug.print("expected {t}: {s}\n", .{ case[1], source });
            return error.TestUnexpectedResult;
        }
        const span = result.failed.diagnostic.span;
        if (result.failed.diagnostic.code != case[1] or !std.mem.eql(u8, case[2], source[span.start..span.end])) std.debug.print("got {t} at '{s}' for {s}\n", .{ result.failed.diagnostic.code, source[span.start..span.end], source });
        try std.testing.expectEqual(case[1], result.failed.diagnostic.code);
        try std.testing.expectEqualStrings(case[2], source[span.start..span.end]);
        // At the written place, after the module.
        try std.testing.expect(span.start >= module_head.len);
    }
}

test "inspection format 43 prints keyed cells, their operations and the session; other programs keep their format" {
    const h = try harness.create();
    defer scratch.release(h);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    const buffer = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(buffer);
    const p = try h.compile("var X:weak_map(session, i64) = map{}\nset X[GetSession()] = 1\nA:i64 = Attempt(X[GetSession()], 0)");
    var out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, p));
    const text = out.buffered();
    for ([_][]const u8{ "{\"format\":43,", "{\"id\":4,\"kind\":\"grant\",\"grant\":\"session\"}", "\"keyed\":\"session\"", "{\"weak_init\":0}", "{\"grant\":{\"kind\":\"session\"}}", "{\"weak_set\":{\"cell\":0,\"key\":1,\"value\":2}}", "{\"weak_get\":{\"cell\":0,\"key\":" }) |part| {
        if (std.mem.indexOf(u8, text, part) == null) {
            std.debug.print("{s}\nlacks {s}\n", .{ text, part });
            return error.TestUnexpectedResult;
        }
    }
    // The empty initialiser leaves no node: the declaration is the first.
    try std.testing.expect(p.nodes[0].kind == .weak_init);
    out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, try h.compile("var X:weak_map(i64, i64) = map{}\nA:i64 = Attempt(X[1], 0)")));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":36,"));
}

/// The oracle's model of a session cell of `i64`: absent, or a value; with the images of the
/// regions open around the code being generated.
const Model = struct { value: ?i64 = null };

test "oracle: random programs of reads and writes of a session cell, in regions that commit and fail, agree with a model" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5054_5ce1);
    const random = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (0..40) |_| {
        text.items.len = 0;
        try text.appendSlice(allocator, "var X:weak_map(session, i64) = map{}\nS:session = GetSession()\n");
        var model: Model = .{};
        var expected: [24]i64 = undefined;
        const count = 4 + random.uintLessThan(usize, 20);
        for (0..count) |index| {
            const constant = random.intRangeAtMost(i64, -50, 50);
            switch (random.uintLessThan(u8, 5)) {
                // A write at the root.
                0 => {
                    try text.print(allocator, "R{d}:i64 = Block{{ set X[S] = {d}; {d} }}\n", .{ index, constant, constant });
                    model.value = constant;
                    expected[index] = constant;
                },
                // A compound update, which fails when the entry is absent.
                1 => {
                    try text.print(allocator, "R{d}:i64 = Attempt(Block{{ set X[S] += {d}; X[S] }}, -1000)\n", .{ index, constant });
                    if (model.value) |value| {
                        model.value = value + constant;
                        expected[index] = value + constant;
                    } else expected[index] = -1000;
                },
                // A write in a region that fails: undone.
                2 => {
                    try text.print(allocator, "R{d}:i64 = Attempt(Block{{ set X[S] = {d}; Require[false]; 0 }}, Attempt(X[S], -2000))\n", .{ index, constant });
                    expected[index] = model.value orelse -2000;
                },
                // A write in a function, inside a region that commits.
                3 => {
                    try text.print(allocator, "F{d}()<reads><writes>:i64 = Block{{ K := GetSession(); set X[K] = Attempt(X[K], 0) * 2 + {d}; Attempt(X[K], 0) }}\nR{d}:i64 = Attempt(F{d}(), -3000)\n", .{ index, constant, index, index });
                    model.value = (model.value orelse 0) * 2 + constant;
                    expected[index] = model.value.?;
                },
                // A read.
                else => {
                    try text.print(allocator, "R{d}:i64 = Attempt(X[S], -4000)\n", .{index});
                    expected[index] = model.value orelse -4000;
                },
            }
        }
        const x = try live_tests.run(h, text.items);
        for (expected[0..count], 0..) |want, index| {
            var name: [8]u8 = undefined;
            const got = x.get(try std.fmt.bufPrint(&name, "R{d}", .{index})).?.integer;
            if (got != want) {
                std.debug.print("R{d} = {d}, model {d}:\n{s}\n", .{ index, got, want, text.items });
                return error.TestUnexpectedResult;
            }
        }
        // The cell's final value is the model's (W8).
        const cell = x.cells[x.program.nodes[0].kind.weak_init];
        const entries = x.elements(cell.value).?;
        if (model.value) |value| {
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            try std.testing.expectEqual(value, entries[1].integer);
        } else try std.testing.expectEqual(@as(usize, 0), entries.len);
    }
    try live_tests.expectEveryMode(text.items);
}
