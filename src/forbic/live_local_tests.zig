//! Live locals, RFC-0085 I14 (RFC-0084 P4.8): a guard that names a local `var` shares it
//! (S1b), and so does a `set live` of it or a `var live` declaration (S1c); the local is then a
//! variable cell `ref(T)`, which a guard depends on through `ref_get` and which carries a live
//! record through `object_live` at field 0, as a module cell or a field does. Both machines and
//! the replay run every program here (`live.run`), and the programs that say so in every trace
//! mode (`live.expectEveryMode`).
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
const trace_replay = @import("trace_replay.zig");

const allocator = std.testing.allocator;

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse return error.TestUnexpectedResult;
    return value.integer;
}

fn expectInt(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    const x = try live.run(h, source);
    const got = try integer(x, name);
    if (got != expected) std.debug.print("{s} = {d}, expected {d}: {s}\n", .{ name, got, expected, source });
    try std.testing.expectEqual(expected, got);
}

/// How many `object_live` nodes attach to a variable cell, and how many to anything else.
const Attachments = struct { cells: usize = 0, others: usize = 0, ref_new: usize = 0 };
fn attachments(p: types.Program) Attachments {
    var out: Attachments = .{};
    for (p.nodes) |n| count(&out, p, n, p.nodes);
    for (p.functions) |f| {
        const body = p.function_nodes[f.body.start..f.body.end];
        for (body) |entry| if (entry.input == .operation) {
            if (entry.node.kind == .ref_new) out.ref_new += 1;
            if (entry.node.kind == .object_live) {
                const object = body[entry.node.kind.object_live.object].node.value_type;
                if (catalogue.isRef(object, p.definitions)) out.cells += 1 else out.others += 1;
            }
        };
    }
    return out;
}
fn count(out: *Attachments, p: types.Program, n: types.Node, nodes: []const types.Node) void {
    if (n.kind == .ref_new) out.ref_new += 1;
    if (n.kind != .object_live) return;
    if (catalogue.isRef(nodes[n.kind.object_live.object].value_type, p.definitions)) out.cells += 1 else out.others += 1;
}

test "the Book's 15:325 and 15:533 over locals, in Forbic spelling" {
    const h = try harness.create();
    defer scratch.release(h);
    // 15:325, `Diverge`: `Y` follows `X + 1` and `X` follows `Y`, which never settles: the run
    // ends with `live_unstable` at the record evaluated beyond the bound. (The Book's function
    // is `:void`; this one yields `X`, so that its block ends with a value.)
    try live.expectFailure(h,
        \\Diverge()<transacts>:i64 = Block{
        \\    var X:i64 = 1
        \\    var live Y:i64 = If(X > 0, X + 1, 0)
        \\    set live X = Y
        \\    X
        \\}
        \\V:i64 = Diverge()
    , .live_unstable, "Y");
    // 15:533, `StopObserving`: the cancelled `Upon` never runs, so `Y` remains 0.
    const stopped =
        \\var Seen:i64 = -1
        \\StopObserving()<transacts><suspends>:void = Block{
        \\    var X:i64 = 0
        \\    var Y:i64 = 0
        \\    Watch := Upon(X > 5, Set(Y, X))
        \\    Watch.Cancel()
        \\    set X = 10
        \\    Set(Seen, Y)
        \\}
        \\S:task(void) = Spawn{ StopObserving() }
    ;
    var x = try live.run(h, stopped);
    try std.testing.expectEqual(@as(i64, 0), x.cells[0].value.integer);
    try live.expectEveryMode(stopped);
    // Without the cancel the write of `X` fires it, and `Y` copies `X`.
    x = try live.run(h,
        \\var Seen:i64 = -1
        \\Observing()<transacts><suspends>:void = Block{
        \\    var X:i64 = 0
        \\    var Y:i64 = 0
        \\    Watch := Upon(X > 5, Set(Y, X))
        \\    set X = 10
        \\    Set(Seen, Y)
        \\}
        \\S:task(void) = Spawn{ Observing() }
    );
    try std.testing.expectEqual(@as(i64, 10), x.cells[0].value.integer);
    // The Book's converging cycle (15:297) over locals settles where the module form does.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 2; var Y:i64 = 2; set live X = If(Y < 0, 0, Y - 1); set live Y = If(X < 0, 0, X - 1); X * 10 + Y }\nV:i64 = F()", "V", -10);
}

test "set live on a local follows what its guard reads, until a plain set detaches it" {
    const h = try harness.create();
    defer scratch.release(h);
    // S1c: the target is shared; the guard reads another local, which S1b shares.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; set live Y = X * 10; set X = 4; Y }\nV:i64 = F()", "V", 40);
    // A plain `set` of the target detaches it (L2): later writes of `X` leave it.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; set live Y = X * 10; set Y = 7; set X = 4; Y }\nV:i64 = F()", "V", 7);
    // A second `set live` replaces the guard.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Z:i64 = 5; var Y:i64 = 0; set live Y = X; set live Y = Z + 1; set X = 100; set Z = 9; Y }\nV:i64 = F()", "V", 10);
    // A guard over a module var and a local, and a local target of a module var's guard.
    try expectInt(h, "var M:i64 = 1\nF()<transacts>:i64 = Block{ var L:i64 = 2; var Y:i64 = 0; set live Y = M + L; set M = 10; set L = 20; Y }\nV:i64 = F()", "V", 30);
    try expectInt(h, "var M:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; set live M = L + 1; set L = 5; M }\nV:i64 = F()", "V", 6);
    // At the root, a block's locals are locals too.
    try expectInt(h, "V:i64 = Block{ var X:i64 = 3; var Y:i64 = 0; set live Y = X * X; set X = 5; Y }", "V", 25);
    // The statement's value is nothing: a block cannot end with it, as with `set`.
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; set live X = 2 }", .expected_expression, "}");
}

test "var live locals start from the default of their type and follow their guard" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 2; var live Y:i64 = X * 10; set X = 3; Y }\nV:i64 = F()", "V", 30);
    // A chain declared in dependency order, and a detach in the middle.
    try expectInt(h, "F()<transacts>:i64 = Block{ var A:i64 = 1; var live B:i64 = A + 1; var live C:i64 = B * 2; set A = 5; C }\nV:i64 = F()", "V", 12);
    try expectInt(h, "F()<transacts>:i64 = Block{ var A:i64 = 1; var live B:i64 = A + 1; var live C:i64 = B * 2; set B = 0; set A = 5; C * 100 + B }\nV:i64 = F()", "V", 0);
    // Strings, floats, options and structs have defaults; their guards give the values.
    try expectInt(h, "pt := struct{ X:i64 = 0, Y:i64 = 0 }\nF()<transacts>:i64 = Block{ var N:i64 = 2; var live S:string = \"n{N}\"; var live P:pt = pt{ X := N, Y := N * 2 }; set N = 4; S.Length * 100 + P.X * 10 + P.Y }\nV:i64 = F()", "V", 248);
    // It is a local `var`: `set` writes it (and detaches it).
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 2; var live Y:i64 = X; set Y += 5; set X = 100; Y }\nV:i64 = F()", "V", 7);
    // The guard is compiled once, as the guard: a `For` and an `Fn` inside it are published once.
    try expectInt(h, "F()<transacts>:i64 = Block{ var S:i64 = 1; var live V:i64 = For(K:1..3, K + S).Length + (Fn()<reads>:i64{ S * 10 })(); set S = 2; V }\nV:i64 = F()", "V", 23);
}

test "guards name locals directly, through closures and through loops (S1b)" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0085 Q10: an `Fn` that attaches a guard over an outer local follows the local, not a
    // copy (it was `guard_capture_var` before P4.8).
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; G := Fn()<transacts>:i64{ Block{ set live Y = L + 1; 0 } }; set L = 5; A := G(); set L = 9; Y }\nV:i64 = F()", "V", 10);
    // Through two `Fn`s, and an `Fn` in the guard.
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; G := Fn()<transacts>:i64{ Block{ H := Fn()<transacts>:i64{ Block{ set live Y = L; 0 } }; H() } }; A := G(); set L = 3; Y }\nV:i64 = F()", "V", 3);
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; set live Y = (Fn()<reads>:i64{ L * 2 })(); set L = 4; Y }\nV:i64 = F()", "V", 8);
    // A guard in a loop's body names the local of the code around it: it follows it after the
    // loop (I2-D8: before P4.8 it followed a copy).
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; Xs := For(I:1..1, Block{ set live Y = L + I; 0 }); set L = 10; Y }\nV:i64 = F()", "V", 11);
    // One that the loop also assigns: no loop carries a shared local (S2).
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; Xs := For(I:1..3, Block{ set L = L + I; set live Y = L * 10; 0 }); set L = L + 1; Y }\nV:i64 = F()", "V", 80);
    // The shared local of an `Fn` that assigns it (I2) is a dependency too.
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; W := Fn()<transacts>:void{ Set(L, 2) }; set live Y = L + 1; W(); Y }\nV:i64 = F()", "V", 3);
    // In a `Batch{}` and a `Loop{}` of the declaring function.
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; B := Batch{ set live Y = L + 1; 0 }; set L = 10; Y }\nV:i64 = F()", "V", 11);
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; Loop{ set live Y = L + 1; Break() }; set L = 20; Y }\nV:i64 = F()", "V", 21);
    // An explicit capture is a value: its guard reads the copy.
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; G := Fn[C:i64 = L]()<transacts>:i64{ Block{ set live Y = C + 1; 0 } }; A := G(); set L = 9; Y }\nV:i64 = F()", "V", 2);
    // An immutable local and a parameter are captured by value, as before.
    try expectInt(h, "var Y:i64 = 0\nF(P:i64)<transacts>:i64 = Block{ L:i64 = P * 2; set live Y = L + P; Y }\nV:i64 = F(3)", "V", 9);
}

test "reactions and awaits depend on locals (S1b), and bodies assign them (S1d)" {
    const h = try harness.create();
    defer scratch.release(h);
    // A `When` counts every write of a local, also writes of an equal value (15:500).
    var x = try live.run(h,
        \\var Count:i64 = 0
        \\Run()<transacts><suspends>:void = Block{
        \\    var X:i64 = 0
        \\    var N:i64 = 0
        \\    W:task(void) = When(X, Set(N, N + 1))
        \\    set X = 1
        \\    set X = 1
        \\    set X = 2
        \\    Set(Count, N)
        \\}
        \\T:task(void) = Spawn{ Run() }
    );
    try std.testing.expectEqual(@as(i64, 4), x.cells[0].value.integer);
    // An `Await` on a local that a task writes after a sleep.
    x = try live.run(h,
        \\var Got:i64 = 0
        \\Run()<transacts><suspends>:void = Block{
        \\    var X:i64 = 0
        \\    T := Spawn{ Sleep(1.0); Set(X, 7) }
        \\    V := Await(X > 5)
        \\    Set(Got, X)
        \\}
        \\T:task(void) = Spawn{ Run() }
    );
    try std.testing.expectEqual(@as(i64, 7), x.cells[0].value.integer);
    // A reaction outlives its frame: the function returns, a closure it handed on writes the
    // local later, and the `When` still runs.
    x = try live.run(h,
        \\var Fired:i64 = 0
        \\Make()<transacts>:function<transacts>(tuple(i64), i64) = Block{
        \\    var L:i64 = 0
        \\    W:task(void) = When(L > 2, Set(Fired, Fired + L))
        \\    Fn(V:i64)<transacts>:i64{ Set(L, V) }
        \\}
        \\S:function<transacts>(tuple(i64), i64) = Make()
        \\A:i64 = S(1)
        \\B:i64 = S(3)
        \\C:i64 = S(5)
    );
    try std.testing.expectEqual(@as(i64, 8), x.cells[0].value.integer);
    try live.expectEveryMode(
        \\var Fired:i64 = 0
        \\Make()<transacts>:function<transacts>(tuple(i64), i64) = Block{
        \\    var L:i64 = 0
        \\    W:task(void) = When(L > 2, Set(Fired, Fired + L))
        \\    Fn(V:i64)<transacts>:i64{ Set(L, V) }
        \\}
        \\S:function<transacts>(tuple(i64), i64) = Make()
        \\A:i64 = S(1)
        \\B:i64 = S(3)
        \\C:i64 = S(5)
    );
}

test "a local's cell and its record outlive the frame that declared them" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var M:i64 = 0
        \\Make(K:i64)<transacts>:function<transacts>(tuple(i64), i64) = Block{
        \\    var L:i64 = 1
        \\    set live M = L * K
        \\    Fn(V:i64)<transacts>:i64{ Set(L, V) }
        \\}
        \\S:function<transacts>(tuple(i64), i64) = Make(3)
        \\A:i64 = M
        \\B:i64 = S(7)
        \\C:i64 = M
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 3), try integer(x, "A"));
    try std.testing.expectEqual(@as(i64, 21), try integer(x, "C"));
    try live.expectEveryMode(source);
    // A `var live` local whose frame ended: its record reads a module var, so a write of the
    // module var evaluates it in every trace mode alike (RFC-0084 C24).
    const kept =
        \\var M:i64 = 1
        \\var Seen:i64 = 0
        \\Make()<transacts>:function<reads>(tuple(), i64) = Block{
        \\    var live L:i64 = M * 2
        \\    Fn()<reads>:i64{ L }
        \\}
        \\R:function<reads>(tuple(), i64) = Make()
        \\Q:i64 = Block{ set M = 5; R() }
        \\Lost:i64 = Block{ Make(); set M = 6; M }
    ;
    const y = try live.run(h, kept);
    try std.testing.expectEqual(@as(i64, 10), try integer(y, "Q"));
    try live.expectEveryMode(kept);
}

test "regions take back a live local's record, its link and its value (R1)" {
    const h = try harness.create();
    defer scratch.release(h);
    // A `set live` in a region that fails is undone; one that commits stays.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; R := Attempt(Block{ set live Y = X + 10; Require[X > 5]; 1 }, 0); set X = 2; Y * 10 + R }\nV:i64 = F()", "V", 0);
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; R := Attempt(Block{ set live Y = X + 10; Require[X > 0]; 1 }, 0); set X = 2; Y * 10 + R }\nV:i64 = F()", "V", 121);
    // A detach in a region that fails is undone: the guard follows again.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; set live Y = X; R := Attempt(Block{ set Y = 50; Require[false]; 1 }, 0); set X = 3; Y }\nV:i64 = F()", "V", 3);
    // A `var live` made in a region that fails is forgotten with it (R2).
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; R := Attempt(Block{ var live Y:i64 = X + 1; Require[Y > 5]; Y }, 0); set X = 9; R }\nV:i64 = F()", "V", 0);
    // Propagation in a region writes the local's cell, and the failure restores it.
    try expectInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var live Y:i64 = X * 2; R := Attempt(Block{ set X = 30; Require[Y < 10]; 1 }, 0); Y * 10 + R }\nV:i64 = F()", "V", 20);
    try live.expectEveryMode("F()<transacts>:i64 = Block{ var X:i64 = 1; var live Y:i64 = X * 2; R := Attempt(Block{ set X = 30; Require[Y < 10]; 1 }, 0); Xs := For(I:1..3, array{I, I}); Y * 10 + R + Xs.Length }\nV:i64 = F()");
}

test "live locals in loops: a cell and a record per visit, reclaimed in digest runs" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\var M:i64 = 1
        \\Visit(I:i64)<transacts>:i64 = Block{ var live L:i64 = M + I; G:[]i64 = array{L, L, L}; set M = M + 1; L + G.Length }
        \\Xs:[]i64 = For(I:1..40, Visit(I))
        \\V:i64 = Xs.Length
    ;
    const x = try live.run(h, source);
    try std.testing.expectEqual(@as(i64, 40), try integer(x, "V"));
    try std.testing.expectEqual(@as(u64, 40), x.live.records);
    try std.testing.expect(try live.everyMode(source) > 0);
}

test "the lowering: a cell, its ref_new of the default and object_live at field 0" {
    const h = try harness.create();
    defer scratch.release(h);
    var p = try h.compile("F()<transacts>:i64 = Block{ var X:i64 = 1; var live Y:i64 = X + 1; var Z:i64 = 0; set live Z = Y; Z }\nV:i64 = F()");
    var a = attachments(p);
    try std.testing.expectEqual(@as(usize, 2), a.cells);
    try std.testing.expectEqual(@as(usize, 0), a.others);
    try std.testing.expectEqual(@as(usize, 3), a.ref_new);
    // A local no guard names and no `set live` targets is not a cell; a program that has no
    // live local makes none.
    p = try h.compile("var M:i64 = 0\nF()<transacts>:i64 = Block{ var X:i64 = 1; set X = 2; set live M = 3; X }\nV:i64 = F()");
    a = attachments(p);
    try std.testing.expectEqual(@as(usize, 0), a.cells + a.ref_new);
    // A field's attachment stays a field's.
    p = try h.compile("box := class{ var V:i64 = 0 }\nF()<transacts>:i64 = Block{ B := box{}; var L:i64 = 1; set live B.V = L; B.V }\nV:i64 = F()");
    a = attachments(p);
    try std.testing.expectEqual(@as(usize, 1), a.cells + a.others - 0);
    try std.testing.expectEqual(@as(usize, 1), a.others);
}

test "what stays refused, and the effects a live local needs, at the exact place" {
    const h = try harness.create();
    defer scratch.release(h);
    // A type without a default (RFC-0084 C26).
    try live.expectRefused(h, "point := class{ X:i64 = 0 }\nF()<transacts>:i64 = Block{ var live P:point = point{}; 1 }", .live_local_default, "P");
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var live G:function<reads>(tuple(), i64) = Fn()<reads>:i64{ 1 }; 1 }", .live_local_default, "G");
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var live A:any = any(1); 1 }", .live_local_default, "A");
    // A live-only local, an immutable local, a parameter, an explicit capture.
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ live L:i64 = 1; L }", .live_target, "L");
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ L:i64 = 1; set live L = 2; L }", .live_target, "L");
    try live.expectRefused(h, "F(P:i64)<transacts>:i64 = Block{ set live P = 2; P }", .live_target, "P");
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; G := Fn[Y:i64 = X]()<transacts>:i64{ Block{ set live Y = 2; Y } }; G() }", .live_target, "Y");
    // A local whose type is a function stays no live target (RFC-0084 C41, RFC-0085 Q8).
    try live.expectRefused(h, "M(A:i64)<reads>:i64 = A\nF()<transacts>:i64 = Block{ var live X:M = 1; X }", .live_target, "X");
    try live.expectRefused(h, "M(A:i64)<reads>:i64 = A\nF()<transacts>:i64 = Block{ var X:M = 1; X }", .live_target, "X");
    // A `var live` needs a type, and a guard.
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var live X := 1; X }", .expected_type, "X");
    // Effects: a local `var` needs <writes>, attaching a guard all three heap effects.
    try live.expectRefused(h, "F()<computes>:i64 = Block{ var live X:i64 = 1; X }", .local_var_requires_writes, "X");
    try live.expectRefused(h, "F()<reads><writes>:i64 = Block{ var live X:i64 = 1; X }", .call_requires_allocates, "X");
    try live.expectRefused(h, "F()<writes><allocates>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; set live Y = 2; 0 }", .call_requires_reads, "Y");
    // A guard cannot write a local, or declare one.
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var Y:i64 = 0; set live Y = Set(X, 2); Y }", .guard_effect, "X");
    // `<predicts>` holds no live form (RFC-0085, I12).
    try live.expectRefused(h, "F()<transacts><predicts>:i64 = Block{ var live X:i64 = 1; X }", .form_requires_dictates, "X");
    // A shared local read in a function without <reads>.
    try live.expectRefused(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var live Y:i64 = X; G := Fn()<writes>:i64{ Y }; G() }", .local_read_requires_reads, "Y");
}

test "programs without the forms keep their meaning: `live` names a local, a guard's copies stay copies" {
    const h = try harness.create();
    defer scratch.release(h);
    try expectInt(h, "F()<transacts>:i64 = Block{ var live:i64 = 3; set live = 4; live }\nV:i64 = F()", "V", 4);
    try expectInt(h, "F()<transacts>:i64 = Block{ live:i64 = 3; live + 1 }\nV:i64 = F()", "V", 4);
    // An `Fn` that only reads a local reads the variable since Q1 (RFC-0085, I13), as it reads the
    // one a guard shares: `R()` is 50, where RFC-0054's snapshot gave 1 (12 in all).
    try expectInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; var K:i64 = 1; R := Fn(){ K }; set live Y = L; set K = 50; set L = 2; R() * 10 + Y }\nV:i64 = F()", "V", 502);
}

/// The scale tests of live locals (RFC-0085, I14), each a `digest` run on both machines whose
/// report the replay works out again (`live_field_tests.timed`): a chain of `chain` cells, each a
/// `var live` local of its own frame that follows the one before through the closure that frame
/// handed on, written at its head (one evaluation each); `writes` writes of a local that another
/// local follows; and `visits` visits that each make a live local and drop it, which only a run
/// that reclaims the cells and their records holds in `object_cells`.
pub fn scale(f: trace_replay.Fixture, chain: usize, writes: usize, visits: usize) !void {
    const live_fields = @import("live_field_tests.zig");
    var text: [1024]u8 = undefined;
    var source = try std.fmt.bufPrint(&text,
        \\var S:i64 = 0
        \\Link:=function<reads>(tuple(), i64)
        \\Make(Prev:Link)<transacts>:Link = Block{{ var live L:i64 = Prev() + 1; Fn()<reads>:i64{{ L }} }}
        \\Tail:Link = Iterate(Make, {d}, Fn()<reads>:i64{{ S }})
        \\A:i64 = Block{{ set S = 1000; Tail() }}
    , .{chain});
    var x = try live_fields.timed(f, "a chain of live locals", source);
    try std.testing.expectEqual(@as(i64, 1000 + @as(i64, @intCast(chain))), x.get("A").?.integer);
    try std.testing.expectEqual(@as(u64, chain), x.live.records);
    // One establishing evaluation per record, then the write at the head evaluates each once.
    try std.testing.expectEqual(@as(u64, 2 * chain), x.live.evaluations);
    source = try std.fmt.bufPrint(&text,
        \\F()<transacts>:i64 = Block{{ var X:i64 = 0; var live Y:i64 = X * 2; Xs := For(I:1..{d}, Set(X, I) > {d}, I); Y + Xs.Length }}
        \\V:i64 = F()
    , .{ writes, writes - 1 });
    x = try live_fields.timed(f, "writes of a local another follows", source);
    try std.testing.expectEqual(@as(i64, 2 * @as(i64, @intCast(writes)) + 1), x.get("V").?.integer);
    try std.testing.expectEqual(@as(u64, writes + 1), x.live.evaluations);
    source = try std.fmt.bufPrint(&text,
        \\Visit(I:i64)<transacts>:i64 = Block{{ var live L:i64 = I * 2; G:[]i64 = array{{L, L}}; L + G.Length }}
        \\Xs:[]i64 = For(K:1..{d}, Visit(K) > {d}, K)
        \\V:i64 = Xs.Length
    , .{ visits, 2 * visits });
    x = try live_fields.timed(f, "live locals made and dropped", source);
    try std.testing.expectEqual(@as(i64, 1), x.get("V").?.integer);
    try std.testing.expectEqual(@as(u64, visits), x.live.records);
    // Only reclamation keeps a million cells and records in the program profile's stores.
    if (visits >= 100_000) try std.testing.expect(x.reclaims > 0);
}

test "live locals at the bootstrap profile's scale" {
    try @import("profile.zig").requireBootstrap();
    const f = try trace_replay.Fixture.create();
    defer f.destroy();
    try scale(f, 100, 1000, 1000);
}

/// One program, run on both machines with the replay (`expectInt`) and then in every trace mode.
fn expectEveryModeInt(h: *harness.Harness, source: []const u8, name: []const u8, expected: i64) !void {
    try expectInt(h, source, name, expected);
    try live.expectEveryMode(source);
}

// I14-D11: a guard or a reaction body that fails inside a region of its own publishes failure
// traces, though the root holds no cell and no `Spawn`; the replay worked out a failure the
// machines had not published (`invalid typed IR`). Base58 had the same bug for a class field.
test "a region that fails inside a guard or a reaction body, in a program with no cell at the root" {
    const h = try harness.create();
    defer scratch.release(h);
    const fails = "Attempt(Block{ Require[false]; 5 }, 0 - 1)";
    // `var live`, `set live`, and a guard that reads a local before it fails.
    try expectEveryModeInt(h, "F()<transacts>:i64 = Block{ var live Y:i64 = " ++ fails ++ "; Y }\nV:i64 = F()", "V", -1);
    try expectEveryModeInt(h, "F()<transacts>:i64 = Block{ var Y:i64 = 0; set live Y = " ++ fails ++ "; Y }\nV:i64 = F()", "V", -1);
    try expectEveryModeInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var live Y:i64 = Attempt(Block{ Require[X > 2]; X }, 0 - 1); set X = 3; Y * 10 + X }\nV:i64 = F()", "V", 33);
    // `When`: the guard's region, and the body's region (the body runs once now and once after the write).
    try expectEveryModeInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 0; var N:i64 = 0; W:task(void) = When(Attempt(Block{ Require[X > 5]; 1 }, 2), Set(N, N + 1)); set X = 1; N }\nV:i64 = F()", "V", 2);
    try expectEveryModeInt(h, "F()<transacts>:i64 = Block{ var X:i64 = 0; var N:i64 = 0; W:task(void) = When(X, Set(N, Attempt(Block{ Require[X > 0]; X }, 0 - 1))); set X = 4; N }\nV:i64 = F()", "V", 4);
    // The same on a class field, which base58 also got wrong.
    try expectEveryModeInt(h, "box := class{ var V:i64 = 0 }\nF()<transacts>:i64 = Block{ B := box{}; set live B.V = " ++ fails ++ "; B.V }\nV:i64 = F()", "V", -1);
    try expectEveryModeInt(h, "box := class{ var V:i64 = 0 }\nF()<transacts>:i64 = Block{ B := box{}; var N:i64 = 0; W:task(void) = When(Attempt(Block{ Require[B.V > 5]; B.V }, 7), Set(N, N + 1)); set B.V = 1; N }\nV:i64 = F()", "V", 2);
    // A failing guard region does not hide a failing one that the region does not take back.
    try live.expectFailure(h, "F()<transacts>:i64 = Block{ var X:i64 = 1; var live Y:i64 = 10 / (X - 1); Y }\nV:i64 = F()", .division_by_zero, "/");
}

// I14-D3: sharing a local for a guard in a loop body makes every `Fn` that reads it follow it too.
test "a read-only Fn of a local that a guard in a loop body shares follows the local" {
    const h = try harness.create();
    defer scratch.release(h);
    // base58: 102 (the `Fn` kept a snapshot of 1, and `Y` followed a copy); now 1011.
    try expectEveryModeInt(h, "var Y:i64 = 0\nF()<transacts>:i64 = Block{ var L:i64 = 1; R := Fn()<reads>:i64{ L }; Xs := For(I:1..1, Block{ set live Y = L + I; 0 }); set L = 10; R() * 100 + Y }\nV:i64 = F()", "V", 1011);
}

// TASK-0109 w15, I14-D6 (accepted, RFC-0085 "Amendment: w15"): a `var live` local of a frame that
// has returned keeps its record, which every write of a module `var` its guard reads evaluates.
// Dropping such a record would change what a program observes: a guard can fail (the run stops
// where it did), it is charged as fuel and, in a `full` trace, recorded.
test "w15: a dead live local's guard runs at every write of what it reads, and what it does is observable" {
    const h = try harness.create();
    defer scratch.release(h);
    // `L` is dead once `Visit` returns; the write of 3 makes its guard divide by zero.
    try live.expectFailure(h, "var M:i64 = 0\nVisit(I:i64)<transacts>:i64 = Block{ var live L:i64 = 10 / (M - 3); I }\nRun()<transacts>:i64 = Block{ X := Visit(1); set M = 1; set M = 2; set M = 3; X }\nV:i64 = Run()", .division_by_zero, "/");
    try expectInt(h, "var M:i64 = 0\nVisit(I:i64)<transacts>:i64 = Block{ var live L:i64 = 10 / (M - 3); I }\nRun()<transacts>:i64 = Block{ X := Visit(1); set M = 1; set M = 2; set M = 4; X }\nV:i64 = Run()", "V", 1);
    // `n` calls leave `n` records, and the write in the `k`-th call evaluates the `k` that exist:
    // `n` establishing evaluations and `n(n+1)/2` more.
    var buffer: [512]u8 = undefined;
    for ([_]u64{ 10, 20, 40 }) |n| {
        const source = try std.fmt.bufPrint(&buffer, "var M:i64 = 0\nVisit(I:i64)<transacts>:i64 = Block{{ var live L:i64 = M + I; set M = M + 1; L }}\nXs:[]i64 = For(I:1..{d}, Visit(I))\nN:i64 = Xs.Length", .{n});
        const x = try live.run(h, source);
        try std.testing.expectEqual(n + n * (n + 1) / 2, x.live.evaluations);
        try std.testing.expectEqual(@as(i64, @intCast(n)), try integer(x, "N"));
    }
}
