//! `<predicts>` (RFC-0085, I12): a checked effect with no runtime meaning (V21). A function, a
//! method, an `Fn`, a function type or a class may give up `dictates`; a predicting function
//! runs only predicting code, which the compiler checks at every form and both admissions and
//! the replay check by rule 9. Execution, fuel and reports are those of the same program
//! without the specifier.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const native = @import("native.zig");
const native_std = @import("native_std.zig");
const inspection = @import("inspection.zig");
const harness = @import("generic_function_tests.zig");
const live = @import("live_tests.zig");
test {
    _ = @import("predicts_forgery_tests.zig");
}

/// The fixture `tests/conformance/predicts.forb`.
pub const contract =
    \\# RFC-0085, I12: `<predicts>` is a checked effect. A predicting function runs only predicting code.
    \\var Health:i64 = 50
    \\# The Book's 13:157 and 13:414, with the heap effect Forbic requires.
    \\CheckPlayerStatus()<reads><predicts>:i64 = Health
    \\HandleJumpInput()<computes><predicts>:void = tuple{}
    \\Double(X:i64)<computes><predicts>:i64 = X * 2
    \\Scaled(Xs:[]i64)<computes><predicts>:[]i64 = For(X:Xs, Double(X))
    \\Root(X:float)<computes><predicts>:float = Sqrt(X)
    \\Say(S:string)<transacts><predicts>:void = Print(S)
    \\Apply(F:function<computes><predicts>(tuple(i64), i64), X:i64)<computes><predicts>:i64 = F(X)
    \\Adder(K:i64)<computes><predicts>:function<computes><predicts>(tuple(i64), i64) = Fn(X:i64){ X + K }
    \\# A dictating function calls predicting ones, and a predicting function is a dictating value.
    \\Dictating(X:i64)<computes>:i64 = Double(X) + 1
    \\Through:function<computes>(tuple(i64), i64) = Double
    \\shape := class<computes><predicts>{
    \\    Size:i64 = 2
    \\    Area()<reads><predicts>:i64 = Self.Size * Self.Size
    \\}
    \\square := class(shape){
    \\    Area<override>()<reads><predicts>:i64 = Self.Size * 4
    \\}
    \\Measure(S:shape)<reads><predicts>:i64 = S.Area()
    \\Build()<allocates><predicts>:shape = square{}
    \\Wait()<transacts><suspends><predicts>:i64 = Block{ Sleep(1.0); Double(3) }
    \\A:i64 = CheckPlayerStatus()
    \\B:void = HandleJumpInput()
    \\C:[]i64 = Scaled(array{1, 2, 3})
    \\D:float = Root(9.0)
    \\E:void = Say("predicted")
    \\F:i64 = Apply(Double, 5)
    \\G:i64 = Adder(10)(1)
    \\H:i64 = Dictating(4)
    \\I:i64 = Through(6)
    \\J:tuple(i64, i64) = tuple{Measure(shape{}), Measure(Build())}
    \\T:task(i64) = Spawn{ Wait() }
;

test "predicts: the source contract, in both machines, the replay and every trace mode" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h, contract);
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"Health\":50,\"Through\":{\"function\":{\"name\":\"Double\",\"module\":null}},\"A\":50,\"B\":[],\"C\":[2,4,6],\"D\":3,\"E\":[],\"F\":10,\"G\":11,\"H\":9,\"I\":12,\"J\":[4,8],\"T\":{\"$task\":{\"sequence\":1,\"state\":\"completed\",\"result\":6}},\"$scheduler\":{\"tick_rate\":60,\"tick\":60,\"created\":1,\"completed\":1,\"canceled\":0,\"switches\":3,\"waiting\":[]}}\n",
        try live.report(x, &buffer),
    );
    try std.testing.expectEqual(@as(u64, 1), x.effects.output.count);
    try live.expectEveryMode(contract);
}

/// The least budget `source` runs in, found by halving: both machines stop at every smaller
/// one with the same diagnostic (`harness.run` compares them).
fn fuelNeeded(h: *harness.Harness, source: []const u8) !u64 {
    const p = try h.compile(source);
    var low: u64 = 0;
    var high: u64 = live.fuel;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if ((try h.run(p, middle)) == .ok) high = middle else low = middle + 1;
    }
    return low;
}

test "predicts: execution and fuel are those of the program without the specifier" {
    const h = try harness.create();
    defer scratch.release(h);
    // The same program with every `<predicts>` taken out: the bit changes nothing that runs.
    // `Through` is left out of both: a predicting function as a value of a dictating type is
    // widened to it by an `upcast`, which costs its node as every widening of a value does.
    var once: [contract.len]u8 = undefined;
    const first = std.mem.replace(u8, contract, "Through:function<computes>(tuple(i64), i64) = Double\n", "", &once);
    var twice: [contract.len]u8 = undefined;
    const second = std.mem.replace(u8, once[0 .. contract.len - first * "Through:function<computes>(tuple(i64), i64) = Double\n".len], "I:i64 = Through(6)\n", "", &twice);
    try std.testing.expectEqual(@as(usize, 2), first + second);
    const predicting_text = twice[0 .. contract.len - "Through:function<computes>(tuple(i64), i64) = Double\n".len - "I:i64 = Through(6)\n".len];
    var stripped: [contract.len]u8 = undefined;
    const removed = std.mem.replace(u8, predicting_text, "<predicts>", "", &stripped);
    const plain_text = stripped[0 .. predicting_text.len - removed * "<predicts>".len];
    var buffer: [4096]u8 = undefined;
    const x = try live.run(h, predicting_text);
    const predicted = try std.testing.allocator.dupe(u8, try live.report(x, &buffer));
    defer std.testing.allocator.free(predicted);
    const y = try live.run(h, plain_text);
    try std.testing.expectEqualStrings(predicted, try live.report(y, &buffer));
    try std.testing.expectEqual(try fuelNeeded(h, plain_text), try fuelNeeded(h, predicting_text));
}

test "predicts: the bit in signatures, function types, closures and the classes' clauses" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(contract);
    for (p.functions) |f| {
        const name = f.name.text(p.source);
        // Every function of the contract predicts but `Dictating` and the body of the `Spawn`
        // at the root, which dictates (V23); the closures written in predicting code inherit
        // the bit, as they inherit its heap effects.
        const dictates = std.mem.eql(u8, name, "Dictating") or std.mem.eql(u8, name, "Spawn");
        try std.testing.expectEqual(!dictates, f.detail.predicts);
        try std.testing.expectEqual(dictates, f.effects().dictates);
    }
    // The function types written with `<predicts>` are other types than those without it.
    var predicting: usize = 0;
    var dictating: usize = 0;
    for (p.definitions) |item| if (item == .callable) {
        if (item.callable.detail.predicts) predicting += 1 else dictating += 1;
        try std.testing.expect(types.effectsCanonical(item.callable.transacts, item.callable.decides, item.callable.detail));
    };
    try std.testing.expect(predicting > 0 and dictating > 0);
    // A heap set never holds the bit, so heap comparisons are what they were.
    try std.testing.expect(!types.effectSet(true, false, .{ .predicts = true }).heap().dictates);
    try std.testing.expect(!types.effectSet(true, false, .{}).heap().dictates);
    try std.testing.expect(types.effectSet(false, false, .{}).dictates);
    // Fewer effects is the subtype: a predicting set is within a dictating one, not the reverse.
    const pure = types.effectSet(false, false, .{ .predicts = true });
    const plain = types.effectSet(false, false, .{});
    try std.testing.expect(pure.within(plain) and !plain.within(pure));
    // A program without the specifier has no bit set anywhere.
    const none = try h.compile("F(X:i64)<computes>:i64 = X + 1\nG:function<computes>(tuple(i64), i64) = F\nA:i64 = G(1)");
    for (none.functions) |f| try std.testing.expect(!f.detail.predicts);
    for (none.definitions) |item| if (item == .callable) try std.testing.expect(!item.callable.detail.predicts);
}

test "predicts: every refused call, form and construction, at its place" {
    const h = try harness.create();
    defer scratch.release(h);
    const r = live.expectRefused;
    // Calls of what dictates: a function, a function value, a method, an `Fn` that says its
    // own effect, an extension method, a loop's function, a native that draws.
    try r(h, "Plain(X:i64)<computes>:i64 = X\nP(X:i64)<computes><predicts>:i64 = Plain(X)", .call_requires_dictates, "Plain");
    try r(h, "P(F:function<computes>(tuple(i64), i64))<computes><predicts>:i64 = F(1)", .call_requires_dictates, "(");
    try r(h, "c := class{ M()<computes>:i64 = 1 }\nP(C:c)<computes><predicts>:i64 = C.M()", .call_requires_dictates, "(");
    try r(h, "P()<computes><predicts>:i64 = Block{ G := Fn(X:i64)<computes>:i64{ X }; G(1) }", .call_requires_dictates, "(");
    try r(h, "(V:i64).Up()<computes>:i64 = V + 1\nP()<computes><predicts>:i64 = (1).Up()", .call_requires_dictates, "Up");
    try r(h, "Step(N:i64)<computes>:i64 = N + 1\nP()<computes><predicts>:i64 = Iterate(Step, 2, 0)", .call_requires_dictates, "Step");
    try r(h, "P()<transacts><predicts>:i64 = GetRandomInt(1, 6)", .call_requires_dictates, "GetRandomInt");
    try r(h, "P()<transacts><predicts>:float = GetRandomFloat(0.0, 1.0)", .call_requires_dictates, "GetRandomFloat");
    try r(h, "P()<transacts><predicts>:[]i64 = Shuffle(array{1, 2})", .call_requires_dictates, "Shuffle");
    // A body that calls a dictating function, in a loop and in a closure the context predicts.
    try r(h, "Plain(X:i64)<computes>:i64 = X\nP(Xs:[]i64)<computes><predicts>:[]i64 = For(X:Xs, Plain(X))", .call_requires_dictates, "Plain");
    try r(h, "Plain(X:i64)<computes>:i64 = X\nP()<computes><predicts>:i64 = Block{ G := Fn(X:i64){ Plain(X) }; G(1) }", .call_requires_dictates, "Plain");
    try r(h, "Plain()<transacts><suspends>:i64 = 1\nP()<transacts><suspends><predicts>:task(i64) = Spawn{ Plain() }", .call_requires_dictates, "Plain");
    // A default of a parameter runs in the caller.
    try r(h, "Plain()<computes>:i64 = 5\nU(X:i64 = Plain())<computes><predicts>:i64 = X\nP()<computes><predicts>:i64 = U()", .call_requires_dictates, "U");
    // A subscribable event's `Signal` calls its callbacks, whose type dictates.
    try r(h, "E:subscribable_event(i64) = subscribable_event(i64){}\nP()<transacts><predicts>:void = E.Signal(1)", .call_requires_dictates, "Signal");
    // The live forms.
    try r(h, "var X:i64 = 0\nP()<transacts><predicts>:i64 = Block{ set live X = 1; 0 }", .form_requires_dictates, "X");
    try r(h, "box := class{ var N:i64 = 0 }\nB:box = box{}\nP()<transacts><predicts>:i64 = Block{ set live B.N = 1; 0 }", .form_requires_dictates, "N");
    try r(h, "var X:i64 = 0\nP()<transacts><predicts>:task(void) = When(X, 1)", .form_requires_dictates, "When");
    try r(h, "var X:i64 = 0\nP()<transacts><predicts>:task(i64) = Upon(X > 1, 1)", .form_requires_dictates, "Upon");
    try r(h, "var X:i64 = 0\nP()<transacts><suspends><predicts>:logic = Await(X > 5)", .form_requires_dictates, "Await");
    try r(h, "var X:i64 = 0\nP()<transacts><predicts>:i64 = Batch{ set X = 1; 2 }", .form_requires_dictates, "Batch");
    // Constructions: block clauses and field defaults that dictate, here and in a class that
    // says it predicts.
    try r(h, "c := class{ var V:i64 = 1; Block{ set Self.V = 2 } }\nP()<transacts><predicts>:c = c{}", .construction_requires_dictates, "c");
    try r(h, "Plain()<computes>:i64 = 5\ns := struct{ V:i64 = Plain() }\nP()<computes><predicts>:s = s{}", .construction_requires_dictates, "s");
    try r(h, "Plain()<computes>:i64 = 5\nc := class<computes><predicts>{ V:i64 = Plain() }", .construction_requires_dictates, "c");
    // An override and an inherited implementation predict where the slot does.
    try r(h, "c := class{ M()<computes><predicts>:i64 = 1 }\nd := class(c){ M<override>()<computes>:i64 = 2 }", .override_widens_dictates, "M");
    try r(h, "i := interface{ M()<computes><predicts>:i64 }\nb := class{ M()<computes>:i64 = 1 }\nd := class(b, i){}", .override_widens_dictates, "d");
    // A function type: a dictating function is no value of a predicting type.
    try r(h, "Plain(X:i64)<computes>:i64 = X\nF:function<computes><predicts>(tuple(i64), i64) = Plain", .type_mismatch, "Plain");
    // The specifier is no heap effect, and is written once.
    try r(h, "P()<predicts>:i64 = 1", .expected_computes, "predicts");
    try r(h, "P()<computes><predicts><predicts>:i64 = 1", .effect_specifier_repeated, "predicts");
    try r(h, "c := class<predicts>{ V:i64 = 1 }", .expected_computes, "c");
}

test "predicts: what predicting code may do" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try live.run(h,
        \\var C:i64 = 1
        \\Pure(X:i64)<computes><predicts>:i64 = X + 1
        \\Triple(X:i64)<computes><predicts>:i64 = X * 3
        \\# The join of two predicting function types predicts (13:626).
        \\Pick(B:logic)<computes><predicts>:i64 = Block{ G := If(B, Pure, Triple); G(5) }
        \\# Reads and writes, state and suspension; awaiting and signalling a plain event.
        \\E:event(i64) = event(i64){}
        \\Bump()<transacts><predicts>:i64 = Block{ set C += 1; C }
        \\Hand()<transacts><suspends><predicts>:i64 = Block{ Sleep(0.5); E.Signal(4); Pure(1) }
        \\Take()<transacts><suspends><predicts>:i64 = E.Await()
        \\# An override narrows a dictating slot.
        \\c := class{ M()<computes>:i64 = 1 }
        \\d := class(c){ M<override>()<computes><predicts>:i64 = 2 }
        \\Call(V:c)<computes>:i64 = V.M()
        \\# A class that predicts builds in predicting code, its clauses predicting too.
        \\k := class<transacts><predicts>{ var N:i64 = 1; Block{ set Self.N = Pure(Self.N) } }
        \\Make()<transacts><predicts>:k = k{}
        \\A:tuple(i64, i64) = tuple{Pick(true), Pick(false)}
        \\B:i64 = Bump()
        \\T1:task(i64) = Spawn{ Take() }
        \\T2:task(i64) = Spawn{ Hand() }
        \\D:i64 = Call(d{})
        \\K:i64 = Make().N
    );
    const a = x.elements(x.get("A").?).?;
    try std.testing.expectEqual(@as(i64, 6), a[0].integer);
    try std.testing.expectEqual(@as(i64, 15), a[1].integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("B").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 2), x.get("K").?.integer);
}

test "predicts: the library rule, and natives (V22)" {
    // Every native that only computes predicts; of the effect natives only the string `Print`.
    for (native_std.table) |entry| {
        try std.testing.expect(native.wellFormed(entry));
        if (entry.effect == .none) try std.testing.expect(!native.dictates(entry));
        const print = std.mem.eql(u8, entry.id, "std.print");
        if (entry.effect != .none) try std.testing.expectEqual(!print, native.dictates(entry));
    }
    // A host table cannot widen the rule: `predicts` on a draw, or on an action of anything
    // but one string, is no well formed entry (F22).
    for (native_std.table) |entry| if (entry.effect == .draw) {
        var forged = entry;
        forged.predicts = true;
        try std.testing.expect(!native.wellFormed(forged));
    };
}

test "predicts: inspection format 31; every other program keeps its format" {
    const h = try harness.create();
    defer scratch.release(h);
    const report = try scratch.storage(inspection.Workspace);
    defer scratch.release(report);
    const out_buffer = try std.testing.allocator.alloc(u8, 1 << 18);
    defer std.testing.allocator.free(out_buffer);
    var out = std.Io.Writer.fixed(out_buffer);
    const p = try h.compile("P(X:i64)<computes><predicts>:i64 = X + 1\nQ(X:i64)<reads>:i64 = X + 1\nA:i64 = P(Q(1))");
    try std.testing.expect(try report.write(&out, p) == .ok);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 31), parsed.value.object.get("format").?.integer);
    const effects = parsed.value.object.get("function_effects").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), effects[0].array.items.len);
    try std.testing.expectEqualStrings("predicts", effects[0].array.items[0].string);
    try std.testing.expectEqualStrings("reads", effects[1].array.items[0].string);
    // A function type alone that predicts is format 31 too.
    out.end = 0;
    const typed = try h.compile("F:function<computes><predicts>(tuple(i64), i64) = Fn(X:i64){ X }\nA:i64 = F(1)");
    try std.testing.expect(try report.write(&out, typed) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":31,"));
    out.end = 0;
    const plain = try h.compile("P(X:i64)<computes>:i64 = X + 1\nQ(X:i64)<reads>:i64 = X + 1\nA:i64 = P(Q(1))");
    try std.testing.expect(try report.write(&out, plain) == .ok);
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":26,"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "predicts") == null);
}
