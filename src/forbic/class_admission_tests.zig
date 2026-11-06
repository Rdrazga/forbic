//! Independent admission of the class operations: both machines reject every forged variant of
//! instance construction, field access, conversions and method dispatch before running anything.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

const Forge = struct {
    nodes: []types.Node,
    definitions: []types.Definition,
    slots: []types.Slot,
    dispatch: []types.Dispatch,
    program: types.Program,

    fn init(p: types.Program) !Forge {
        return .{
            .nodes = try std.testing.allocator.dupe(types.Node, p.nodes),
            .definitions = try std.testing.allocator.dupe(types.Definition, p.definitions),
            .slots = try std.testing.allocator.dupe(types.Slot, p.slots),
            .dispatch = try std.testing.allocator.dupe(types.Dispatch, p.dispatch),
            .program = p,
        };
    }
    fn deinit(self: *Forge) void {
        std.testing.allocator.free(self.nodes);
        std.testing.allocator.free(self.definitions);
        std.testing.allocator.free(self.slots);
        std.testing.allocator.free(self.dispatch);
    }
    fn view(self: *const Forge) types.Program {
        var forged = self.program;
        forged.nodes = self.nodes;
        forged.definitions = self.definitions;
        forged.slots = self.slots;
        forged.dispatch = self.dispatch;
        return forged;
    }
    fn first(self: *const Forge, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind"))) usize {
        for (self.nodes, 0..) |node, index| if (node.kind == kind) return index;
        unreachable;
    }
    fn reset(self: *Forge) void {
        @memcpy(self.nodes, self.program.nodes);
        @memcpy(self.definitions, self.program.definitions);
        @memcpy(self.slots, self.program.slots);
        @memcpy(self.dispatch, self.program.dispatch);
    }
};

test "the unmodified class programs are admitted" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Box:=class{N:i64,var M:i64}\nB:=Box{N:=1,M:=2}\nset B.M=3\nX:i64=B.N");
    var forge = try Forge.init(p);
    defer forge.deinit();
    _ = try h.run(forge.view(), 10_000);
}

test "forged object construction and field access are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Box:=class{N:i64,var M:i64}\nB:=Box{N:=1,M:=2}\nset B.M=3\nX:i64=B.N");
    var forge = try Forge.init(p);
    defer forge.deinit();
    const get = forge.first(.object_get);
    const set = forge.first(.object_set);
    const make = forge.first(.object_new);
    // A field that does not exist.
    forge.nodes[get].kind.object_get.index = 2;
    try harness.invalid(h, forge.view());
    forge.reset();
    // The wrong result type for the field.
    forge.nodes[get].value_type = .logic;
    try harness.invalid(h, forge.view());
    forge.reset();
    // Assigning an immutable field.
    forge.nodes[set].kind.object_set.index = 0;
    try harness.invalid(h, forge.view());
    forge.reset();
    // Assigning a value of another type.
    forge.nodes[set].kind.object_set.value = forge.nodes[set].kind.object_set.object;
    try harness.invalid(h, forge.view());
    forge.reset();
    // Missing and surplus constructor arguments.
    forge.nodes[make].kind.object_new.arguments.end -= 1;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A constructor of something that is not a class.
    forge.nodes[make].value_type = .i64;
    try harness.invalid(h, forge.view());
    forge.reset();
    // An abstract class has no instances.
    forge.definitions[0].class.is_abstract = true;
    try harness.invalid(h, forge.view());
    forge.reset();
    // Reading a field of a value that is not an instance.
    forge.nodes[get].kind.object_get.value = 0;
    try harness.invalid(h, forge.view());
    forge.reset();
    _ = try h.run(forge.view(), 10_000);
}

test "forged conversions between classes are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Animal:=class{Name:string}
        \\Dog:=class(Animal){Tricks:i64}
        \\Other:=class{Name:string}
        \\D:=Dog{Name:="rex",Tricks:=1}
        \\O:=Other{Name:="o"}
        \\Up:Animal=D
        \\Hit:i64=Attempt(Block{Down:=Dog[Up];Down.Tricks},0)
    );
    var forge = try Forge.init(p);
    defer forge.deinit();
    const up = forge.first(.upcast);
    const down = forge.first(.downcast);
    const test_node = forge.first(.instance_of);
    const dog = forge.nodes[up].kind.upcast;
    const other = blk: {
        for (forge.nodes, 0..) |node, index| if (node.kind == .object_new and index != dog) break :blk index;
        unreachable;
    };
    // An upcast to a class that is not a superclass of its operand.
    forge.nodes[up].kind.upcast = @intCast(other);
    try harness.invalid(h, forge.view());
    forge.reset();
    // An upcast that does not change the type.
    forge.nodes[up].value_type = forge.nodes[dog].value_type;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A downcast to a superclass, and from an unrelated class.
    forge.nodes[down].value_type = forge.nodes[up].value_type;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.nodes[down].kind.downcast = @intCast(other);
    try harness.invalid(h, forge.view());
    forge.reset();
    // A type test for an unrelated class, and one whose result is not logic.
    forge.nodes[test_node].kind.instance_of.class = forge.nodes[other].value_type;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.nodes[test_node].value_type = .i64;
    try harness.invalid(h, forge.view());
    forge.reset();
    _ = try h.run(forge.view(), 10_000);
}

test "forged method slots and dispatch tables are rejected by both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Animal:=class{
        \\  Name:string
        \\  Sound()<transacts>:string="..."
        \\  Rename(To:string)<transacts>:string=To
        \\}
        \\Dog:=class(Animal){
        \\  Sound<override>()<transacts>:string="woof"
        \\}
        \\D:=Dog{Name:="rex"}
        \\A:Animal=D
        \\Said:string=A.Sound()
    );
    try std.testing.expect(p.dispatch.len >= 4);
    var forge = try Forge.init(p);
    defer forge.deinit();
    const lookup = forge.first(.method_value);
    // A slot that does not exist, and a result type other than the slot's.
    forge.nodes[lookup].kind.method_value.slot = @intCast(forge.slots.len);
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.nodes[lookup].kind.method_value.slot = 1;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.nodes[lookup].value_type = .i64;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A receiver that is not an instance of the slot's class.
    forge.nodes[lookup].kind.method_value.receiver = 0;
    try harness.invalid(h, forge.view());
    forge.reset();
    // Dispatch tables must stay sorted, unique and consistent with their slots and functions.
    std.mem.swap(types.Dispatch, &forge.dispatch[0], &forge.dispatch[1]);
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.dispatch[0].function = @intCast(p.functions.len);
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.dispatch[1] = forge.dispatch[0];
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.dispatch[0].slot = 1;
    try harness.invalid(h, forge.view());
    forge.reset();
    forge.slots[0].owner = forge.nodes[lookup].value_type;
    try harness.invalid(h, forge.view());
    forge.reset();
    // A class that can be built must resolve every slot: dropping the last entry leaves a gap.
    var short = forge.view();
    short.dispatch = forge.dispatch[0 .. forge.dispatch.len - 1];
    try harness.invalid(h, short);
    const run = try h.run(forge.view(), 10_000);
    try std.testing.expectEqualStrings("woof", run.ok.get("Said").?.string);
}

test "a method applied to another receiver than it was looked up for traps in both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile("Base:=class{\n  F()<transacts>:i64=1\n}\nWide:=class(Base){\n  var Extra:i64=7\n  F<override>()<transacts>:i64=Self.Extra\n}\nX:=Wide{}\nY:=Base{}\nUp:Base=X\nR:i64=Up.F()");
    const arguments = try std.testing.allocator.dupe(u32, p.call_arguments);
    defer std.testing.allocator.free(arguments);
    var forged = p;
    forged.call_arguments = arguments;
    const run = try h.run(forged, 10_000);
    try std.testing.expectEqual(@as(i64, 7), run.ok.get("R").?.integer);
    // The lookup still uses the Wide instance, but the call passes the plain Base one. Every type
    // matches the slot's signature, so only the override's own narrowing of `Self` can notice.
    var call: ?types.Invoke = null;
    for (p.nodes) |node| if (node.kind == .invoke) {
        call = node.kind.invoke;
    };
    var other: ?u32 = null;
    var seen: u32 = 0;
    for (p.nodes, 0..) |node, index| if (node.kind == .object_new) {
        seen += 1;
        if (seen == 2) other = @intCast(index);
    };
    try std.testing.expect(p.nodes[other.?].value_type == p.nodes[arguments[call.?.arguments.start]].value_type);
    arguments[call.?.arguments.start] = other.?;
    try harness.traps(h, forged, 10_000);
}
