//! The join of `If` and `Attempt` arms that are functions, and the variance of function types
//! (RFC-0078 "Sub-effecting", `fix2`). Two arms of function types join to the narrowest type
//! both are values of: the wider of the two, or the same parameters and result with the
//! effects of either (the Book's union, 13:626). A function type admits a function whose
//! parameters are the expected ones or classes above them and whose result is the expected one
//! or a class below it (06:771). The first arm is widened by its `merge`, which both machines
//! and the replay admit as they admit an `upcast`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");

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

/// The function type of the binding `name`.
fn bindingType(p: types.Program, name: []const u8) types.Type {
    for (p.bindings) |binding| if (std.mem.eql(u8, binding.name.text(p.source), name)) return binding.value_type;
    unreachable;
}

const functions =
    \\var Count:i64=0
    \\Pure(X:i64)<computes>:i64=X+1
    \\Bump(X:i64)<transacts>:i64=Block{set Count=Count+X;Count}
    \\Look(X:i64)<reads>:i64=X+Count
    \\Note(X:i64)<writes>:i64=Block{set Count=X;X}
    \\Check(X:i64)<computes><decides>:i64=Block{Require[X>0];X}
    \\
;

test "function arms of an If or an Attempt join to the narrowest type both are values of" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(functions ++
        \\Pick(Flag:logic)<computes>:function<transacts>(tuple(i64),i64)=If(Flag,Pure,Bump)
        \\Late(Flag:logic)<computes>:function<transacts>(tuple(i64),i64)=Block{F:=If(Flag,Bump,Pure);F}
        \\A:i64=Pick(true)(1)
        \\B:i64=Pick(false)(5)
        \\C:i64=Late(false)(1)
        \\Both:=If(A>1,Look,Note)
        \\D:i64=Both(7)
        \\E:i64=Count
        \\Caught:=Attempt(Check,Pure)
        \\F:i64=Attempt(Caught[3],-1)
        \\Root:=If(true,Pure,Bump)
        \\G:i64=Root(9)
    );
    try expectInt(x, "A", 2);
    try expectInt(x, "B", 5);
    try expectInt(x, "C", 2);
    // `A > 1`: the join of `<reads>` and `<writes>` is `<reads><writes>`; `Look` ran, and read
    // what `Bump` left.
    try expectInt(x, "D", 12);
    try expectInt(x, "E", 5);
    try expectInt(x, "F", 3);
    try expectInt(x, "G", 10);
    const p = x.program;
    const both = catalogue.definition(bindingType(p, "Both"), p.definitions).?.callable.effects();
    try std.testing.expect(both.reads and both.writes and !both.allocates and !both.decides);
    const caught = catalogue.definition(bindingType(p, "Caught"), p.definitions).?.callable.effects();
    try std.testing.expect(caught.decides and !caught.reads and !caught.writes);
    const root = catalogue.definition(bindingType(p, "Root"), p.definitions).?.callable.effects();
    try std.testing.expect(root.reads and root.writes and root.allocates);
    // The joined type is what the value is: no narrower type takes it.
    try expectRefused(h, functions ++ "G:function<computes>(tuple(i64),i64)=If(true,Pure,Bump)", .type_mismatch);
    try expectRefused(h, functions ++ "G:function<reads>(tuple(i64),i64)=If(true,Look,Note)", .type_mismatch);
    // Effects that cannot stand together, and functions of other shapes, do not join.
    try expectRefused(h, functions ++ "Wait(X:i64)<computes><suspends>:i64=X\nG:=If(true,Check,Wait)", .type_mismatch);
    try expectRefused(h, functions ++ "Two(X:i64,Y:i64)<computes>:i64=X\nG:=If(true,Pure,Two)", .type_mismatch);
    try expectRefused(h, functions ++ "Text(X:i64)<computes>:string=\"t\"\nG:=If(true,Pure,Text)", .type_mismatch);
    try expectRefused(h, functions ++ "G:=If(true,Pure,1)", .type_mismatch);
    // Arms that carry the versions of the locals they assign do not join.
    try expectRefused(h, functions ++ "F()<transacts>:i64=Block{var L:i64=0;G:=If(true,Block{set L=1;Pure},Bump);G(L)}", .type_mismatch);
}

const animals =
    \\animal<public>:=class{N<public>:i64=1}
    \\dog<public>:=class(animal){M<public>:i64=2}
    \\pet<public>:=interface{}
    \\cat<public>:=class(animal,pet){}
    \\Feed(A:animal)<allocates>:dog=dog{N:=11}
    \\Back(D:dog)<computes>:animal=D
    \\
;

test "a function type takes functions of wider parameters and narrower results, classes only" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(animals ++
        \\Feeder:function<allocates>(tuple(dog),animal)=Feed
        \\Fed:i64=Feeder(dog{N:=4}).N
        \\Apply(F:function<transacts>(tuple(cat),animal),C:cat)<transacts>:i64=F(C).N
        \\Applied:i64=Apply(Feed,cat{N:=5})
        \\Bound:function<allocates>(tuple(),animal)=Bind(Feed,dog{N:=6})
        \\Called:i64=Bound().N
        \\Joined:=If(Fed<0,Feeder,Back)
        \\Again:i64=Joined(dog{N:=7}).N
    );
    try expectInt(x, "Fed", 11);
    try expectInt(x, "Applied", 11);
    try expectInt(x, "Called", 11);
    // `Back` is a value of `Feeder`'s type: the arms join to that type, and `Back` ran.
    try expectInt(x, "Again", 7);
    // The wrong way round, through containers, and through `any`, a function type is exact.
    try expectRefused(h, animals ++ "F:function<computes>(tuple(animal),animal)=Back", .type_mismatch);
    try expectRefused(h, animals ++ "F:function<allocates>(tuple(animal),cat)=Feed", .type_mismatch);
    try expectRefused(h, animals ++ "Many(As:[]animal)<computes>:i64=1\nF:function<computes>(tuple([]dog),i64)=Many", .type_mismatch);
    try expectRefused(h, animals ++ "Any(A:any)<computes>:i64=1\nF:function<computes>(tuple(i64),i64)=Any", .type_mismatch);
    try expectRefused(h, animals ++ "Opt(A:animal)<computes>:option(dog)=option{}\nF:function<computes>(tuple(dog),option(animal))=Opt", .type_mismatch);
    // Effects still only widen.
    try expectRefused(h, animals ++ "F:function<computes>(tuple(dog),animal)=Feed", .type_mismatch);
    // A function returning a function is exact in that result.
    try expectRefused(h, animals ++ "Back2(A:animal)<computes>:animal=A\nMaker()<computes>:function<computes>(tuple(animal),animal)=Back2\nF:function<computes>(tuple(),function<transacts>(tuple(animal),animal))=Maker", .type_mismatch);
}

test "both machines and the replay refuse a merge or an upcast that does not widen" {
    const h = try harness.create();
    defer scratch.release(h);
    const join = try h.compile(functions ++ "Root:=If(true,Pure,Bump)\nUse:i64=Root(1)");
    const merge = for (join.nodes, 0..) |node, index| {
        if (node.kind == .merge) break index;
    } else unreachable;
    const arms = join.nodes[merge].kind.merge;
    try std.testing.expect(join.nodes[arms.left].value_type != join.nodes[merge].value_type);
    try std.testing.expectEqual(join.nodes[arms.right].value_type, join.nodes[merge].value_type);
    _ = (try h.run(join, 10_000)).ok;
    const nodes = try std.testing.allocator.dupe(types.Node, join.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = join;
    forged.nodes = nodes;
    // The merge narrowed to its first arm: the second arm would widen into it.
    nodes[merge].value_type = join.nodes[arms.left].value_type;
    try harness.invalid(h, forged);
    // The arms swapped: the second arm narrower than the merge.
    @memcpy(nodes, join.nodes);
    nodes[merge].kind = .{ .merge = .{ .begin = arms.begin, .left = arms.right, .right = arms.left } };
    try harness.invalid(h, forged);

    // An upcast that would narrow a parameter.
    const variant = try h.compile(animals ++ "Feeder:function<allocates>(tuple(dog),animal)=Feed\nWide:function<allocates>(tuple(dog),animal)=Back\nNarrow:function<allocates>(tuple(animal),dog)=Feed");
    _ = (try h.run(variant, 10_000)).ok;
    const shapes = try std.testing.allocator.dupe(types.Node, variant.nodes);
    defer std.testing.allocator.free(shapes);
    var reversed = variant;
    reversed.nodes = shapes;
    const narrow = bindingType(variant, "Narrow");
    var found = false;
    for (shapes, 0..) |*node, index| if (node.kind == .upcast and variant.nodes[node.kind.upcast].kind == .function_value and std.mem.eql(u8, variant.functions[variant.nodes[node.kind.upcast].kind.function_value].name.text(variant.source), "Back")) {
        // `Back` takes a dog and returns an animal: it is no value of `function(animal)->dog`.
        node.value_type = narrow;
        _ = index;
        found = true;
    };
    try std.testing.expect(found);
    try harness.invalid(h, reversed);
}

test "the replay refuses a function value whose function does not fit its type" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(animals ++ "Feeder:function<allocates>(tuple(dog),animal)=Feed\nNarrow:function<allocates>(tuple(animal),dog)=Feed\nHeld:function<computes>(tuple(dog),animal)=Back");
    const values = try std.testing.allocator.dupe(types.Value, x.values);
    defer std.testing.allocator.free(values);
    var forged = x;
    forged.values = values;
    _ = try reporting.validate(x, false, .{});
    // `Held`'s value claimed for `Narrow`'s type: `Back` returns no dog.
    for (x.program.bindings) |binding| if (std.mem.eql(u8, binding.name.text(x.program.source), "Held")) {
        values[binding.node].callable.value_type = bindingType(x.program, "Narrow");
    };
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
}

// Random effect sets for two arms, against the lattice: the arms join exactly when the union
// of their sets is one (`<decides>` and `<suspends>` exclude each other), and the joined
// value is a value of a type exactly when the union lies within that type's set.
test "random arm effects join to their union, and the union decides what takes the value" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x10f2);
    const random = prng.random();
    const Set = packed struct(u5) { reads: bool, writes: bool, allocates: bool, decides: bool, suspends: bool };
    var buffer: [1024]u8 = undefined;
    var spelled: [3][64]u8 = undefined;
    for (0..250) |_| {
        var sets: [3]Set = undefined;
        for (&sets) |*set| {
            set.* = @bitCast(random.int(u5));
            if (set.decides and set.suspends) set.suspends = false;
        }
        for (sets, 0..) |set, index| {
            var out = std.Io.Writer.fixed(&spelled[index]);
            if (!set.reads and !set.writes and !set.allocates) try out.writeAll("<computes>") else {
                if (set.reads) try out.writeAll("<reads>");
                if (set.writes) try out.writeAll("<writes>");
                if (set.allocates) try out.writeAll("<allocates>");
            }
            if (set.decides) try out.writeAll("<decides>");
            if (set.suspends) try out.writeAll("<suspends>");
            spelled[index][out.buffered().len] = 0;
        }
        const union_set: Set = @bitCast(@as(u5, @bitCast(sets[0])) | @as(u5, @bitCast(sets[1])));
        const joins = !(union_set.decides and union_set.suspends);
        const within = @as(u5, @bitCast(union_set)) & ~@as(u5, @bitCast(sets[2])) == 0;
        const source = try std.fmt.bufPrint(&buffer, "F0(X:i64){s}:i64=X\nF1(X:i64){s}:i64=X\nG:=If(true,F0,F1)\nH:function{s}(tuple(i64),i64)=G", .{ std.mem.sliceTo(&spelled[0], 0), std.mem.sliceTo(&spelled[1], 0), std.mem.sliceTo(&spelled[2], 0) });
        const result = h.front.compile(source);
        const accepted = joins and within;
        if ((result == .ok) != accepted or (result == .failed and result.failed.code != .type_mismatch)) {
            std.debug.print("{s}\nexpected {s}, got {s}\n", .{ source, if (accepted) "success" else "type_mismatch", if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.TestUnexpectedResult;
        }
        if (result == .ok) {
            const joined = catalogue.definition(bindingType(result.ok, "G"), result.ok.definitions).?.callable.effects();
            try std.testing.expectEqual(union_set.reads, joined.reads);
            try std.testing.expectEqual(union_set.writes, joined.writes);
            try std.testing.expectEqual(union_set.allocates, joined.allocates);
            try std.testing.expectEqual(union_set.decides, joined.decides);
            try std.testing.expectEqual(union_set.suspends, joined.suspends);
            // A program that suspends at no point runs; one with such values only holds them.
            _ = (try h.run(result.ok, 10_000)).ok;
        }
    }
}

test "a cast out of any takes a function of wider parameters and a narrower result, as a place does" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0081 lets a cast out of `any` take a function with fewer effects; the variance of
    // `fix2` is the same relation (`catalogue.widens`), so the cast takes it too, and the
    // function comes out at the type it was cast to.
    const x = try h.execute(animals ++
        \\Dogger:=function<allocates>(tuple(dog),animal)
        \\Narrow:=function<allocates>(tuple(animal),dog)
        \\Held:any=any(Feed)
        \\Fed:i64=Attempt(Dogger[Held],Back)(dog{N:=4}).N
        \\Kept:any=any(Back)
        \\Wrong:i64=Attempt(Narrow[Kept](dog{N:=4}).N,-1)
    );
    try expectInt(x, "Fed", 11);
    try expectInt(x, "Wrong", -1);
}
