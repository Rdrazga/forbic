//! `weak_map(K, V)` (RFC-0087, P5.1): the type, single-key lookup and update (W1, W2), the
//! conversion from a map and contextual literals (W3), the refusals `weak_map_operation` and
//! `weak_map_key`, the name's yielding, inspection, every trace mode, and an oracle: a random
//! program over a `weak_map` agrees with a model of its entries and with the same program over
//! a `map`, value for value and fuel for fuel. Forged IR is in `weak_map_forgery_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const inspection = @import("inspection.zig");
const modules = @import("modules.zig");
const catalogue = @import("aggregate_types.zig");
const harness = @import("generic_function_tests.zig");
const live_tests = @import("live_tests.zig");

const Code = types.Diagnostic.Code;
const allocator = std.testing.allocator;

fn expectRefused(h: *harness.Harness, source: []const u8, code: Code, at: []const u8) !void {
    const result = h.front.compile(source);
    if (result != .failed) {
        std.debug.print("compiled, expected {t}: {s}\n", .{ code, source });
        return error.Compiled;
    }
    if (result.failed.code != code or !std.mem.eql(u8, result.failed.span.text(source), at)) std.debug.print("{t} at `{s}`, expected {t} at `{s}`: {s}\n", .{ result.failed.code, result.failed.span.text(source), code, at, source });
    try std.testing.expectEqual(code, result.failed.code);
    try std.testing.expectEqualStrings(at, result.failed.span.text(source));
}

fn expectInt(x: evaluator.Execution, name: []const u8, expected: i64) !void {
    try std.testing.expectEqual(expected, x.get(name).?.integer);
}

/// The members of the aggregate `name` is bound to, as integers.
fn expectEntries(x: evaluator.Execution, name: []const u8, expected: []const i64) !void {
    const members = x.elements(x.get(name).?).?;
    try std.testing.expectEqual(expected.len, members.len);
    for (expected, members) |want, got| try std.testing.expectEqual(want, got.integer);
}

/// The type `name` is bound to.
fn bindingType(p: types.Program, name: []const u8) types.Type {
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), name)) return binding.value_type;
    unreachable;
}

test "Book 03:1098: a local weak_map is looked up and set one key at a time, and reassigned whole" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Book()<transacts>:tuple(i64,i64,i64) = Block{
        \\    var MyWeakMap:weak_map(i64,i64) = map{}
        \\    set MyWeakMap[0] = 1
        \\    First := Attempt(MyWeakMap[0], -1)
        \\    set MyWeakMap = map{0 => 2}
        \\    tuple{First, Attempt(MyWeakMap[0], -1), Attempt(MyWeakMap[1], -1)}
        \\}
        \\R:tuple(i64,i64,i64) = Book()
    ;
    const x = try h.execute(source);
    const r = x.elements(x.get("R").?).?;
    try std.testing.expectEqual(@as(i64, 1), r[0].integer);
    try std.testing.expectEqual(@as(i64, 2), r[1].integer);
    try std.testing.expectEqual(@as(i64, -1), r[2].integer);
    try live_tests.expectEveryMode(source);
    // A top-level `var` of a `weak_map` type is an ordinary cell (W4, Q8): read and written one
    // key at a time and reassigned, its writes undone with a region that fails.
    const cell_source =
        \\var MyWeakMap:weak_map(i64,i64) = map{}
        \\set MyWeakMap[0] = 1
        \\A:logic = Attempt(Block{Require[MyWeakMap[0] == 1]; true}, false)
        \\set MyWeakMap = map{0 => 2}
        \\B:logic = Attempt(Block{Require[MyWeakMap[0] == 2]; true}, false)
        \\Bump(K:i64)<transacts>:i64 = Block{
        \\    set MyWeakMap[K] = Attempt(MyWeakMap[K], 0) + 1
        \\    Attempt(MyWeakMap[K], 0)
        \\}
        \\C:i64 = Bump(0) + Bump(5)
        \\D:i64 = Attempt(Block{set MyWeakMap[5] = 100; MyWeakMap[7]}, -1)
        \\E:i64 = Attempt(MyWeakMap[5], -1)
    ;
    const y = try h.execute(cell_source);
    try std.testing.expect(y.get("A").?.boolean and y.get("B").?.boolean);
    try expectInt(y, "C", 4);
    try expectInt(y, "D", -1);
    try expectInt(y, "E", 1);
    // The report shows the cell as a map of its entries (W8), in insertion order.
    try expectEntries(y, "MyWeakMap", &.{ 0, 3, 5, 1 });
    try live_tests.expectEveryMode(cell_source);
}

test "W2: weak_maps as parameters, results, fields, elements and options; nested updates and compound sets" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Inv := struct{Items:weak_map(string, []i64)}
        \\Box := class{var Store:weak_map(i64, string) = map{}}
        \\Put(W:weak_map(i64,i64), K:i64, V:i64)<transacts>:weak_map(i64,i64) = Block{
        \\    var C:weak_map(i64,i64) = W
        \\    set C[K] = V
        \\    C
        \\}
        \\F()<transacts>:i64 = Block{
        \\    var W:weak_map(i64,i64) = map{1 => 10}
        \\    Attempt(Block{set W[1] += 5; 0}, 0)
        \\    set W[2] = 7
        \\    var Arr:weak_map(i64, []i64) = map{0 => array{1, 2, 3}}
        \\    Attempt(Block{set Arr[0][1] = 99; 0}, 0)
        \\    var I:Inv = Inv{Items := map{"a" => array{4}}}
        \\    Attempt(Block{set I.Items["a"][0] = 44; 0}, 0)
        \\    W2 := Put(W, 9, 90)
        \\    Attempt(W[1], 0) + Attempt(W[2], 0) * 100 + Attempt(Arr[0][1], 0) * 10000 + Attempt(I.Items["a"][0], 0) * 1000000 + Attempt(W2[9], 0) * 100000000 + Attempt(W[9], 0)
        \\}
        \\R:i64 = F()
        \\G()<transacts>:string = Block{
        \\    B := Box{}
        \\    set B.Store[3] = "x"
        \\    Attempt(B.Store[3], "none")
        \\}
        \\S:string = G()
        \\Opt:option(weak_map(i64,i64)) = option{map{1 => 2}}
        \\T:i64 = Attempt(Opt?[1], 0)
        \\Tup:tuple(weak_map(i64,i64), i64) = tuple{map{5 => 6}, 1}
        \\U:i64 = Attempt(Tup(0)[5], 0)
        \\Ws:[]weak_map(i64,i64) = array{map{1 => 1}, map{}}
        \\V:i64 = Attempt(Ws[0][1], 0) + Attempt(Ws[1][1], 10)
        \\First:weak_map(i64,i64) = Attempt(Ws[0], map{})
        \\Found:option(i64) = Lookup(First, 1)
        \\Missing:option(i64) = Lookup(First, 2)
    ;
    const x = try h.execute(source);
    try expectInt(x, "R", 9_044_990_715);
    try std.testing.expectEqualStrings("x", x.get("S").?.string);
    try expectInt(x, "T", 2);
    try expectInt(x, "U", 6);
    try expectInt(x, "V", 11);
    try expectEntries(x, "Found", &.{1});
    try expectEntries(x, "Missing", &.{});
    try live_tests.expectEveryMode(source);
}

test "W3: a map is a weak_map where one is expected; literals are built at the weak_map type; nothing converts back" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Get(W:weak_map(i64,i64), K:i64)<computes>:i64 = Attempt(W[K], -1)
        \\Mk(M:map(i64,i64))<computes>:weak_map(i64,i64) = M
        \\S := struct{W:weak_map(i64,i64)}
        \\M:map(i64,i64) = map{1 => 6, 2 => 7}
        \\F()<transacts>:i64 = Block{
        \\    var W:weak_map(i64,i64) = map{}
        \\    set W = M
        \\    X := S{W := M}
        \\    Get(M, 1) + Get(W, 2) * 10 + Attempt(Mk(M)[1], 0) * 100 + Attempt(X.W[2], 0) * 1000
        \\}
        \\R:i64 = F()
        \\G:weak_map(i64,i64) = Mk(map{3 => 4})
        \\H:i64 = Get(map{5 => 6}, 5)
        \\L:weak_map(i64,i64) = map{8 => 9}
    ;
    const p = try h.compile(source);
    const x = (try h.run(p, 1 << 20)).ok;
    try expectInt(x, "R", 7676);
    try expectInt(x, "H", 6);
    try expectEntries(x, "G", &.{ 3, 4 });
    // A literal where a `weak_map` is expected is one node of the `weak_map` type; a map value
    // passes through one `upcast` that changes only its type.
    const weak = bindingType(p, "L");
    try std.testing.expect(catalogue.isWeakMap(weak, p.definitions));
    var upcasts: usize = 0;
    for (p.nodes) |node| if (node.kind == .upcast) {
        try std.testing.expect(catalogue.weakens(p.nodes[node.kind.upcast].value_type, node.value_type, p.definitions));
        upcasts += 1;
    };
    for (p.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .upcast) {
        upcasts += 1;
    };
    try std.testing.expect(upcasts >= 4);
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), "L")) try std.testing.expect(p.nodes[binding.node].kind == .aggregate);
    // A value held as `any` keeps being a `weak_map`: a cast finds the `weak_map`, never the
    // map it was made from, and a map stays a map.
    const held = try h.execute(
        \\Tm := map(i64,i64)
        \\Tw := weak_map(i64,i64)
        \\W:weak_map(i64,i64) = map{1 => 5}
        \\M:map(i64,i64) = map{1 => 6}
        \\A:any = any(W)
        \\B:any = any(M)
        \\X:i64 = Attempt(Tm[A].Length, -1)
        \\Y:i64 = Attempt(Tw[A][1], -1)
        \\Z:i64 = Attempt(Tw[B][1], -1)
        \\U:i64 = Attempt(Tm[B][1], -1)
        \\V:Tw = M
        \\Q:i64 = Attempt(Tm[any(V)].Length, -1)
        \\K(P:any)<computes>:string = Case(P, N:Tm => "map", S:Tw => "weak", _ => "other")
        \\Ks:[]string = array{K(A), K(B), K(any(V))}
    );
    try expectInt(held, "X", -1);
    try expectInt(held, "Y", 5);
    try expectInt(held, "Z", -1);
    try expectInt(held, "U", 6);
    try expectInt(held, "Q", -1);
    const kinds = held.elements(held.get("Ks").?).?;
    for (kinds, [_][]const u8{ "weak", "map", "weak" }) |kind, want| try std.testing.expectEqualStrings(want, kind.string);
    // A type parameter that stands for a `weak_map` builds one with `T{...}`, as for a map.
    const generic = try h.execute("F[T:type](X:T)<computes>:T{ T{} }\nG[T:type](X:T)<computes>:T{ T{1 => 2} }\nY:weak_map(i64,i64) = F[weak_map(i64,i64)](map{})\nZ:weak_map(i64,i64) = G[weak_map(i64,i64)](map{})\nN:i64 = Attempt(Z[1], 0)");
    try expectEntries(generic, "Y", &.{});
    try expectInt(generic, "N", 2);
}

test "Book 03:1133 and the other refusals: weak_map_operation and weak_map_key, at their places" {
    const h = try harness.create();
    defer scratch.release(h);
    const local = "F()<transacts>:i64 = Block{\n    var W:weak_map(i64,i64) = map{1 => 2}\n";
    // No `Length` (03:1112), and no other member.
    try expectRefused(h, local ++ "    W.Length\n}\nR:i64 = F()", .weak_map_operation, "Length");
    try expectRefused(h, local ++ "    W.Size\n}\nR:i64 = F()", .unknown_field, "Size");
    // No iteration, by `For` or by position.
    const walk = h.front.compile(local ++ "    For(E:W, E)\n    0\n}\nR:i64 = F()");
    try std.testing.expectEqual(Code.weak_map_operation, walk.failed.code);
    // No equality, so no comparison and no `comparable` argument.
    try expectRefused(h, "F()<transacts>:logic = Block{\n    var W:weak_map(i64,i64) = map{1 => 2}\n    W == W\n}\nR:logic = F()", .weak_map_operation, "==");
    try expectRefused(h, "F()<transacts>:logic = Block{\n    var W:weak_map(i64,i64) = map{1 => 2}\n    W != W\n}\nR:logic = F()", .weak_map_operation, "!=");
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("Same[T:comparable](A:T,B:T)<computes>:logic{A==B}\nW:weak_map(i64,i64) = map{}\nR:logic = Same[weak_map(i64,i64)](W, W)").failed.code);
    // No conversion back to a map: a binding, an argument, a result, an arm (03:1133's `Joined`).
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("W:weak_map(i64,i64) = map{}\nM:map(i64,i64) = W").failed.code);
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("Size(M:map(i64,i64))<computes>:i64 = M.Length\nW:weak_map(i64,i64) = map{}\nN:i64 = Size(W)").failed.code);
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile(local ++ "    0\n}\nG(W:weak_map(i64,i64))<computes>:map(i64,i64) = W\nR:i64 = F()").failed.code);
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("F()<transacts><decides>:map(i64,i64) = Block{\n    var W:weak_map(i64,i64) = map{1 => 2}\n    If(true, W, map{3 => 4})\n}\nR:i64 = 0").failed.code);
    // Another `weak_map` is another type, as for maps, and so is a map of other types.
    try std.testing.expectEqual(Code.type_mismatch, h.front.compile("W:weak_map(i64,i64) = map{}\nV:weak_map(i64,string) = W").failed.code);
    try std.testing.expectEqual(Code.type_mismatch, h.front.compile("W:weak_map(i64,i64) = map{}\nM:map(i64,string) = W").failed.code);
    // The searches of an array ask its elements for equality.
    for ([_][]const u8{ "Attempt(A.Find[W], -1)", "A.RemoveAllElements(W).Length", "Attempt(A.RemoveFirstElement[W].Length, -1)" }) |use| {
        var text: [256]u8 = undefined;
        const source = try std.fmt.bufPrint(&text, "W:weak_map(i64,i64) = map{{1 => 2}}\nA:[]weak_map(i64,i64) = array{{W, W}}\nX:i64 = {s}", .{use});
        try std.testing.expectEqual(Code.weak_map_operation, h.front.compile(source).failed.code);
    }
    // No joining, either way round, and no removal (Q11).
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("W:weak_map(i64,i64) = map{}\nM:map(i64,i64) = ConcatenateMaps(W, W)").failed.code);
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("W:weak_map(i64,i64) = map{}\nN:map(i64,i64) = map{}\nM:map(i64,i64) = ConcatenateMaps(N, W)").failed.code);
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("W:weak_map(i64,i64) = map{1 => 2}\nM:i64 = Attempt(Block{Without[W, 1]; 0}, 1)").failed.code);
    // Not a map key, in a type or in a literal.
    try expectRefused(h, "M:map(weak_map(i64,i64), i64) = map{}", .weak_map_operation, "map");
    try std.testing.expectEqual(Code.weak_map_operation, h.front.compile("W:weak_map(i64,i64) = map{}\nM:map(weak_map(i64,i64),i64) = map{W => 1}").failed.code);
    try expectRefused(h, "W:weak_map(i64,i64) = map{}\nF()<computes>:i64 = Block{M := map{W => 1}; 0}", .weak_map_operation, "W");
    // A key must be comparable (`weak_map_key`): not a function, a class that is not `<unique>`,
    // or a `weak_map`.
    try expectRefused(h, "W:weak_map(function(tuple(),i64), i64) = map{}", .weak_map_key, "weak_map");
    try expectRefused(h, "C := class{}\nW:weak_map(C, i64) = map{}", .weak_map_key, "weak_map");
    try expectRefused(h, "W:weak_map(weak_map(i64,i64), i64) = map{}", .weak_map_key, "weak_map");
    // A `<unique>` class is a key, as for a map.
    const keyed = try h.execute("C := class<unique>{}\nK:C = C{}\nW:weak_map(C, i64) = map{K => 3}\nR:i64 = Attempt(W[K], 0)");
    try expectInt(keyed, "R", 3);
    // The literal's keys are a map's: two equal keys are the fatal error they are for a map.
    const twice = try h.run(try h.compile("W:weak_map(i64,i64) = map{1 => 2, 1 => 3}"), 1 << 16);
    try std.testing.expectEqual(Code.duplicate_map_key, twice.failed.code);
    // `weak_map` takes two types.
    try std.testing.expectEqual(Code.expected_type, h.front.compile("W:weak_map(i64) = map{}").failed.code);
}

test "the name weak_map yields to whatever the program declares by it" {
    const h = try harness.create();
    defer scratch.release(h);
    var x = try h.execute("weak_map := struct{N:i64}\nA:weak_map = weak_map{N := 3}\nX:i64 = A.N");
    try expectInt(x, "X", 3);
    x = try h.execute("weak_map(A:i64, B:i64)<computes>:i64 = A * 5 + B\nX:i64 = weak_map(1, 2)");
    try expectInt(x, "X", 7);
    x = try h.execute("F()<computes>:i64 = Block{ weak_map:i64 = 4; weak_map + 1 }\nX:i64 = F()");
    try expectInt(x, "X", 5);
    x = try h.execute("F(weak_map:i64)<computes>:i64 = weak_map + 1\nX:i64 = F(2)");
    try expectInt(x, "X", 3);
    // A local of the name after an inner block that calls its own local of the name: the type
    // form is no use of anything a local could follow.
    x = try h.execute("H(X:i64)<computes>:i64 = X + 1\nF()<computes>:i64 = Block{\nA := Block{ weak_map := H; weak_map(1) }\nweak_map := 3\nA + weak_map\n}\nX:i64 = F()");
    try expectInt(x, "X", 5);
    x = try h.execute("weak_map[K:type,V:type] := struct{Key:K, Value:V}\nA:weak_map[i64,string] = weak_map[i64,string]{Key := 1, Value := \"v\"}\nX:i64 = A.Key");
    try expectInt(x, "X", 1);
    // A declaration further down gives the name its meaning above it too.
    try std.testing.expect(h.front.compile("W:weak_map(i64,i64) = map{}\nweak_map(A:i64, B:i64)<computes>:i64 = A") == .failed);
    // Through `using`, in a bundle.
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nusing{L}\nA:weak_map = weak_map{N := 2}\nX:i64 = A.N" },
        .{ .path = "lib.forb", .source = "weak_map<public> := struct{N:i64}" },
    };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    try std.testing.expect(bundled == .ok);
    const run = (try h.run(bundled.ok, 1 << 20)).ok;
    try expectInt(run, "X", 2);
    // And the type in a module of a bundle that declares nothing by the name.
    const typed = [_]modules.Input{
        .{ .path = "main.forb", .source = "L := import{\"lib.forb\"}\nX:i64 = L.Get(L.Start, 4)" },
        .{ .path = "lib.forb", .source = "Start<public>:weak_map(i64,i64) = map{4 => 40}\nGet<public>(W:weak_map(i64,i64), K:i64)<computes>:i64 = Attempt(W[K], -1)" },
    };
    const both = h.front.compileBundle(.{ .root = "main.forb", .modules = &typed });
    try std.testing.expect(both == .ok);
    try expectInt((try h.run(both.ok, 1 << 20)).ok, "X", 40);
}

test "inspection format 36 prints the weak_map definition; a program without one keeps its format" {
    const h = try harness.create();
    defer scratch.release(h);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    const buffer = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(buffer);
    const p = try h.compile("W:weak_map(i64,string) = map{1 => \"a\"}\nR:string = Attempt(W[1], \"\")");
    var out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, p));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 36), parsed.value.object.get("format").?.integer);
    var found = false;
    for (parsed.value.object.get("type_definitions").?.array.items) |item| if (std.mem.eql(u8, item.object.get("kind").?.string, "weak_map")) {
        try std.testing.expectEqual(@as(i64, @backingInt(bindingType(p, "W"))), item.object.get("id").?.integer);
        try std.testing.expectEqualStrings("i64", item.object.get("key").?.string);
        try std.testing.expectEqualStrings("string", item.object.get("value").?.string);
        found = true;
    };
    try std.testing.expect(found);
    // The same program over a map has no `weak_map` definition and an older format.
    const plain = try h.compile("W:map(i64,string) = map{1 => \"a\"}\nR:string = Attempt(W[1], \"\")");
    for (plain.definitions) |item| try std.testing.expect(item != .weak_map);
    out = std.Io.Writer.fixed(buffer);
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out, plain));
    const original = try std.json.parseFromSlice(std.json.Value, allocator, out.buffered(), .{});
    defer original.deinit();
    try std.testing.expect(original.value.object.get("format").?.integer < 32);
}

/// The least fuel `program` completes with; every budget probed is held to both machines.
fn leastFuel(h: *harness.Harness, program: types.Program) !u64 {
    var low: u64 = 0;
    var high: u64 = 1 << 16;
    try std.testing.expect(try h.run(program, high) == .ok);
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

/// The entries of a `weak_map` as the model keeps them: keys and values in insertion order.
const Model = struct {
    keys: [8]i64 = undefined,
    values: [8]i64 = undefined,
    count: usize = 0,

    fn set(self: *Model, key: i64, value: i64) void {
        for (self.keys[0..self.count], 0..) |k, index| if (k == key) {
            self.values[index] = value;
            return;
        };
        self.keys[self.count] = key;
        self.values[self.count] = value;
        self.count += 1;
    }
    fn get(self: *const Model, key: i64) i64 {
        for (self.keys[0..self.count], self.values[0..self.count]) |k, v| if (k == key) return v;
        return -1;
    }
};

/// A random program of updates, lookups, updates in regions that fail, and reassignments from
/// literals and from map values, over a local of type `kind`; and what the model says it yields.
fn generate(random: std.Random, kind: []const u8, out: *std.Io.Writer, expected: *std.ArrayList(i64), from_maps: *usize) !void {
    var model: Model = .{};
    try out.print("F()<transacts>:[]i64 = Block{{\n    var W:{s}(i64,i64) = map{{}}\n", .{kind});
    const steps = 4 + random.uintLessThan(usize, 10);
    var results: usize = 0;
    for (0..steps) |_| {
        const key: i64 = random.uintLessThan(u8, 6);
        const value: i64 = random.uintLessThan(u8, 100);
        switch (random.uintLessThan(u8, 5)) {
            0 => {
                try out.print("    set W[{d}] = {d}\n", .{ key, value });
                model.set(key, value);
            },
            1 => {
                try out.print("    R{d} := Attempt(W[{d}], -1)\n", .{ results, key });
                try expected.append(allocator, model.get(key));
                results += 1;
            },
            // The lookup of key 9 fails, so the update is undone with its region.
            2 => try out.print("    Attempt(Block{{set W[{d}] = {d}; W[9]}}, 0)\n", .{ key, value }),
            3 => {
                // A whole literal at the local's type, its keys distinct.
                const other = @mod(key + 1, 6);
                try out.print("    set W = map{{{d} => {d}, {d} => {d}}}\n", .{ key, value, other, value + 1 });
                model = .{};
                model.set(key, value);
                model.set(other, value + 1);
            },
            else => {
                // A map value, which a `weak_map` takes by `upcast`.
                try out.print("    M{d}:map(i64,i64) = map{{{d} => {d}}}\n", .{ from_maps.*, key, value });
                try out.print("    set W = M{d}\n", .{from_maps.*});
                model = .{};
                model.set(key, value);
                from_maps.* += 1;
            },
        }
    }
    try out.writeAll("    array{");
    for (0..results) |index| try out.print("R{d}, ", .{index});
    for (0..6) |key| {
        try out.print("Attempt(W[{d}], -1){s}", .{ key, if (key == 5) "" else ", " });
        try expected.append(allocator, model.get(@intCast(key)));
    }
    try out.writeAll("}\n}\nOut:[]i64 = F()\n");
}

test "oracle: random programs over a weak_map agree with a model of its entries and with the same program over a map, in values and in fuel" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5715_0087);
    const random = prng.random();
    var weak_text: [4096]u8 = undefined;
    var map_text: [4096]u8 = undefined;
    var expected: std.ArrayList(i64) = .empty;
    defer expected.deinit(allocator);
    var discarded: std.ArrayList(i64) = .empty;
    defer discarded.deinit(allocator);
    var upcast_programs: usize = 0;
    for (0..60) |case| {
        expected.clearRetainingCapacity();
        discarded.clearRetainingCapacity();
        var from_maps: usize = 0;
        var ignored: usize = 0;
        var weak_out = std.Io.Writer.fixed(&weak_text);
        var map_out = std.Io.Writer.fixed(&map_text);
        // The same draws make both programs.
        var twin = prng;
        try generate(random, "weak_map", &weak_out, &expected, &from_maps);
        try generate(twin.random(), "map", &map_out, &discarded, &ignored);
        try std.testing.expectEqualSlices(i64, expected.items, discarded.items);
        const weak = try h.compile(weak_out.buffered());
        const x = (try h.run(weak, 1 << 20)).ok;
        const got = x.elements(x.get("Out").?).?;
        try std.testing.expectEqual(expected.items.len, got.len);
        for (expected.items, got) |want, value| try std.testing.expectEqual(want, value.integer);
        const weak_fuel = try leastFuel(h, weak);
        // The programs differ only in the local's type and in one `upcast` per map value taken,
        // which is one node of fuel. (A compiled program borrows the compiler's storage, so the
        // first one is read before the second is compiled.)
        var upcasts: usize = 0;
        for (weak.function_nodes) |entry| upcasts += @intFromBool(entry.input == .operation and entry.node.kind == .upcast);
        try std.testing.expectEqual(from_maps, upcasts);
        const weak_nodes = weak.function_nodes.len;
        const plain = try h.compile(map_out.buffered());
        for (plain.function_nodes) |entry| try std.testing.expect(entry.input != .operation or entry.node.kind != .upcast);
        for (plain.definitions) |item| try std.testing.expect(item != .weak_map);
        try std.testing.expectEqual(plain.function_nodes.len + upcasts, weak_nodes);
        const plain_fuel = try leastFuel(h, plain);
        try std.testing.expectEqual(plain_fuel + upcasts, weak_fuel);
        upcast_programs += @intFromBool(upcasts != 0);
        _ = case;
    }
    try std.testing.expect(upcast_programs > 10);
}
