//! Forged class tables: every mutation of the slots, the dispatch table and the supertypes
//! of the classes (parent, interfaces, kind) of a program that dispatches through a class
//! and an interface. Whatever one machine admits the other admits, and whatever both admit
//! they run alike, never reading outside a table.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");

const source =
    \\Shape:=interface{
    \\  Area()<transacts>:i64
    \\  Name()<transacts>:string="shape"
    \\}
    \\Base:=class(Shape){
    \\  var Side:i64=2
    \\  Area<override>()<transacts>:i64=Self.Side*Self.Side
    \\  Grow(N:i64)<transacts>:i64=Block{set Self.Side=Self.Side+N;Self.Side}
    \\}
    \\Sq:=class(Base){
    \\  Area<override>()<transacts>:i64=Self.Side*Self.Side+1
    \\}
    \\Tri:=class(Shape){
    \\  Area<override>()<transacts>:i64=3
    \\  Name<override>()<transacts>:string="tri"
    \\}
    \\Use(S:Shape)<transacts>:i64=S.Area()
    \\A:Shape=Sq{}
    \\B:Shape=Tri{}
    \\C:Base=Sq{}
    \\R1:i64=Use(A)+Use(B)
    \\R2:i64=C.Grow(1)+C.Area()
    \\R3:string=A.Name()+B.Name()
    \\Up:Shape=C
    \\R4:i64=Attempt(Block{T:=Tri[Up];T.Area()},0-1)
;

const Counts = struct { refused: usize = 0, ran: usize = 0, failed: usize = 0 };

/// Runs a forged program: both admissions agree, and a program both admit runs alike
/// (`harness.run` compares everything the two machines leave behind).
fn attempt(h: *harness.Harness, p: types.Program, what: []const u8, a: usize, b: usize, counts: *Counts) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    const lowered = bytecode.lower(p, &h.runtime.instructions);
    const vm_refused = lowered != .ok or vm_refused: {
        const actual = h.runtime.machine.run(lowered.ok, 100_000);
        break :vm_refused actual == .failed and actual.failed.code == .invalid_bytecode;
    };
    const reference_refused = reference == .failed and reference.failed.code == .invalid_ir;
    if (reference_refused != vm_refused) {
        std.debug.print("DIVERGE admission {s} {d} {d}: reference {s}, vm {s}\n", .{ what, a, b, if (reference_refused) "refused" else "admitted", if (vm_refused) "refused" else "admitted" });
        return error.TestUnexpectedResult;
    }
    if (reference_refused) {
        counts.refused += 1;
        return;
    }
    const result = h.run(p, 100_000) catch |err| {
        std.debug.print("FINDING {s} {d} {d}: {s}\n", .{ what, a, b, @errorName(err) });
        return err;
    };
    if (result == .ok) counts.ran += 1 else counts.failed += 1;
}

test "every forged slot, dispatch entry and supertype of a class is refused by both machines or run alike" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(source);
    const original = (try h.run(p, 100_000)).ok;
    try std.testing.expectEqual(@as(i64, 8), original.get("R1").?.integer);
    try std.testing.expectEqual(@as(i64, 13), original.get("R2").?.integer);
    try std.testing.expectEqualStrings("shapetri", original.get("R3").?.string);
    try std.testing.expectEqual(@as(i64, -1), original.get("R4").?.integer);
    const a = std.testing.allocator;
    const slots = try a.dupe(types.Slot, p.slots);
    defer a.free(slots);
    // Room for one more entry, for a duplicate.
    const dispatch = try a.alloc(types.Dispatch, p.dispatch.len + 1);
    defer a.free(dispatch);
    const definitions = try a.dupe(types.Definition, p.definitions);
    defer a.free(definitions);
    var forged = p;
    forged.slots = slots;
    forged.dispatch = dispatch[0..p.dispatch.len];
    forged.definitions = definitions;
    @memcpy(dispatch[0..p.dispatch.len], p.dispatch);
    var counts: Counts = .{};
    // Every type of the catalogue, every builtin, and one past the catalogue.
    var candidates: [types.limits.user_types + 8]types.Type = undefined;
    var candidate_count: usize = 0;
    for ([_]types.Type{ .i64, .float, .logic, .string }) |builtin| {
        candidates[candidate_count] = builtin;
        candidate_count += 1;
    }
    for (0..p.definitions.len + 1) |index| {
        candidates[candidate_count] = @fromBackingInt(@as(u16, @intCast(@import("aggregate_types.zig").builtin_count + index)));
        candidate_count += 1;
    }
    const types_tried = candidates[0..candidate_count];
    try std.testing.expect(p.slots.len >= 3 and p.dispatch.len >= 6);

    // Slots: another owner, another function type.
    for (p.slots, 0..) |slot, index| {
        for (types_tried, 0..) |other, ordinal| {
            slots[index] = slot;
            slots[index].owner = other;
            try attempt(h, forged, "slot owner", index, ordinal, &counts);
            slots[index] = slot;
            slots[index].callable = other;
            try attempt(h, forged, "slot callable", index, ordinal, &counts);
        }
        slots[index] = slot;
    }
    // Dispatch entries: another class, slot or function, beyond each table too.
    for (p.dispatch, 0..) |entry, index| {
        for (types_tried, 0..) |other, ordinal| {
            dispatch[index] = entry;
            dispatch[index].class = other;
            try attempt(h, forged, "dispatch class", index, ordinal, &counts);
        }
        for (0..p.slots.len + 2) |slot| {
            dispatch[index] = entry;
            dispatch[index].slot = @intCast(slot);
            try attempt(h, forged, "dispatch slot", index, slot, &counts);
        }
        for (0..p.functions.len + 2) |function| {
            dispatch[index] = entry;
            dispatch[index].function = @intCast(function);
            try attempt(h, forged, "dispatch function", index, function, &counts);
        }
        dispatch[index] = entry;
    }
    // Entries swapped, dropped and repeated.
    for (0..p.dispatch.len) |first| {
        for (first + 1..p.dispatch.len) |second| {
            std.mem.swap(types.Dispatch, &dispatch[first], &dispatch[second]);
            try attempt(h, forged, "dispatch swap", first, second, &counts);
            std.mem.swap(types.Dispatch, &dispatch[first], &dispatch[second]);
        }
        // Without entry `first`: the ones after it move down.
        @memcpy(dispatch[first .. p.dispatch.len - 1], p.dispatch[first + 1 ..]);
        forged.dispatch = dispatch[0 .. p.dispatch.len - 1];
        try attempt(h, forged, "dispatch drop", first, 0, &counts);
        // Entry `first` twice, in place.
        @memcpy(dispatch[0..p.dispatch.len], p.dispatch);
        std.mem.copyBackwards(types.Dispatch, dispatch[first + 1 .. p.dispatch.len + 1], p.dispatch[first..]);
        forged.dispatch = dispatch[0 .. p.dispatch.len + 1];
        try attempt(h, forged, "dispatch repeat", first, 0, &counts);
        forged.dispatch = dispatch[0..p.dispatch.len];
        @memcpy(dispatch[0..p.dispatch.len], p.dispatch);
    }
    // Supertypes and kinds of each class: another parent, another or one more interface, an
    // interface that is not one, a class that is abstract or final after all.
    for (p.definitions, 0..) |item, index| {
        if (item != .class) continue;
        const class = item.class;
        for (types_tried, 0..) |other, ordinal| {
            definitions[index].class.parent = other;
            try attempt(h, forged, "class parent", index, ordinal, &counts);
            definitions[index] = item;
            if (class.interface_count != 0) {
                definitions[index].class.interfaces[0] = other;
                try attempt(h, forged, "class interface", index, ordinal, &counts);
                definitions[index] = item;
            }
            if (class.interface_count < types.Class.max_interfaces) {
                definitions[index].class.interfaces[class.interface_count] = other;
                definitions[index].class.interface_count += 1;
                try attempt(h, forged, "class extra interface", index, ordinal, &counts);
                definitions[index] = item;
            }
        }
        definitions[index].class.parent = null;
        try attempt(h, forged, "class no parent", index, 0, &counts);
        definitions[index] = item;
        definitions[index].class.is_interface = !class.is_interface;
        try attempt(h, forged, "class kind", index, 0, &counts);
        definitions[index] = item;
        definitions[index].class.is_abstract = !class.is_abstract;
        try attempt(h, forged, "class abstract", index, 0, &counts);
        definitions[index] = item;
        definitions[index].class.is_final = !class.is_final;
        try attempt(h, forged, "class final", index, 0, &counts);
        definitions[index] = item;
    }
    // The unchanged tables still run, and the forgeries were not all refused for one reason.
    try std.testing.expectEqual(@as(i64, 8), (try h.run(p, 100_000)).ok.get("R1").?.integer);
    try std.testing.expect(counts.refused > 400 and counts.ran > 10);
}
