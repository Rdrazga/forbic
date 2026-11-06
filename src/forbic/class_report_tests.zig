//! Class instances in reports, through arrays, and the diagnostics of class declarations.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");

test "instances inside arrays are updated through their element" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Box:=class{var N:i64}
        \\Reset(Items:[]Box,Value:i64)<transacts><decides>:i64=Block{set Items[1].N=Value;Items[1].N}
        \\A:=Box{N:=1}
        \\B:=Box{N:=2}
        \\All:=array{A,B}
        \\Done:i64=Attempt(Reset[All,40],-1)
        \\Missing:i64=Attempt(Reset[array{A},41],-1)
        \\Seen:i64=B.N
        \\Untouched:i64=A.N
    );
    try std.testing.expectEqual(@as(i64, 40), x.get("Done").?.integer);
    try std.testing.expectEqual(@as(i64, -1), x.get("Missing").?.integer);
    try std.testing.expectEqual(@as(i64, 40), x.get("Seen").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Untouched").?.integer);
}

test "the report lists each instance once and names references by address" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Node:=class{Value:i64,var Next:option(Node)}
        \\A:=Node{Value:=1,Next:=option{}}
        \\B:=Node{Value:=2,Next:=option{A}}
        \\set A.Next=option{B}
        \\Head:=A
    );
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 0), root.get("A").?.object.get("$object").?.integer);
    try std.testing.expectEqual(@as(i64, 0), root.get("Head").?.object.get("$object").?.integer);
    const table = root.get("$objects").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), table.len);
    try std.testing.expectEqualStrings("Node", table[0].object.get("class").?.string);
    try std.testing.expectEqual(@as(i64, 3), table[1].object.get("id").?.integer);
    // The two nodes point at each other without the report recursing.
    const next = table[0].object.get("fields").?.object.get("Next").?.array.items;
    try std.testing.expectEqual(@as(i64, 3), next[0].object.get("$object").?.integer);
}

test "class declarations and uses are rejected with exact diagnostics" {
    const h = try harness.create();
    defer scratch.release(h);
    const cases = [_]struct { source: []const u8, code: types.Diagnostic.Code }{
        .{ .source = "Box:=class{N:i64}\nK:=Box{N:=1}\nset K.N=2", .code = .not_mutable },
        .{ .source = "Box:=class{var N:i64}\nK:=Box{N:=1}\nset K.N=\"x\"", .code = .type_mismatch },
        .{ .source = "Box:=class{var N:i64}\nGet(B:Box)<computes>:i64=B.N", .code = .field_read_requires_reads },
        .{ .source = "Box:=class{var N:i64}\nMake()<computes>:Box=Box{N:=1}", .code = .construction_requires_allocates },
        .{ .source = "Box:=class{N:i64}\nK:=Box{}", .code = .missing_field },
        .{ .source = "Box:=class{N:i64}\nK:=Box{M:=1}", .code = .unknown_field },
        .{ .source = "Box:=class{N:i64}\nK:=Box{N:=1}\nA:i64=K.M", .code = .unknown_field },
        .{ .source = "R:=struct{A:i64}\nP:=R{A:=1}\nset P.A=2", .code = .not_mutable },
        .{ .source = "X:=1\nset X=2", .code = .not_mutable },
        .{ .source = "K:=Box{N:=1}\nBox:=class{var N:i64}", .code = .unknown_name },
        .{ .source = "Box:=class{N:i64}\nBox:=class{M:i64}", .code = .duplicate_name },
        .{ .source = "Box:=class{N:i64,N:i64}", .code = .duplicate_field },
        .{ .source = "Box:=class{N:Missing}", .code = .unsupported_type },
        .{ .source = "Box:=class{N:i64}\nM:map(function(tuple(Box),i64),i64)=map{}", .code = .invalid_map_key },
        .{ .source = "Box:=class{N:i64}\nK:=Box{N:=1}\nS:string=ToString(K)", .code = .type_mismatch },
        .{ .source = "Box:=class{var N:i64}\nK:=Box{N:=1}\nL:=K<K", .code = .type_mismatch },
    };
    for (cases) |case| {
        const result = h.front.compile(case.source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("class diagnostic for:\n{s}\nexpected {s}, got {s}\n", .{ case.source, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
}

fn reportOf(x: @import("evaluator.zig").Execution, public_only: bool, buffer: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    _ = try reporting.write(&out, x, public_only, .{});
    return out.buffered();
}

test "a public report lists only the instances its public bindings reach, under dense ids" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Secret` is held by a private binding only, the instance of `Dropped` by nothing at all;
    // `Linked` is private too, but a public binding reaches it through a field. `Node` and its
    // fields are public: a public report shows only what the public API can name (`fix2`).
    const x = try h.execute(
        \\Node<public>:=class{Value<public>:i64,var Next<public>:option(Node)}
        \\Secret:=Node{Value:=41,Next:=option{}}
        \\Linked:=Node{Value:=7,Next:=option{}}
        \\Dropped<public>:i64=Node{Value:=99,Next:=option{}}.Value
        \\Shown<public>:=Node{Value:=1,Next:=option{Linked}}
        \\Pair<public>:tuple(i64,[]Node)=tuple{5,array{Shown}}
    );
    var buffer: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"Dropped\":99,\"Shown\":{\"$object\":3},\"Pair\":[5,[{\"$object\":3}]],\"$objects\":[" ++
            "{\"id\":0,\"class\":\"Node\",\"fields\":{\"Value\":7,\"Next\":[]}}," ++
            "{\"id\":3,\"class\":\"Node\",\"fields\":{\"Value\":1,\"Next\":[{\"$object\":0}]}}]}\n",
        try reportOf(x, true, &buffer),
    );
    // The whole-program report keeps what a private binding holds and still drops what none does.
    try std.testing.expectEqualStrings(
        "{\"Secret\":{\"$object\":0},\"Linked\":{\"$object\":3},\"Dropped\":99,\"Shown\":{\"$object\":6},\"Pair\":[5,[{\"$object\":6}]],\"$objects\":[" ++
            "{\"id\":0,\"class\":\"Node\",\"fields\":{\"Value\":41,\"Next\":[]}}," ++
            "{\"id\":3,\"class\":\"Node\",\"fields\":{\"Value\":7,\"Next\":[]}}," ++
            "{\"id\":6,\"class\":\"Node\",\"fields\":{\"Value\":1,\"Next\":[{\"$object\":3}]}}]}\n",
        try reportOf(x, false, &buffer),
    );
}

test "a report without a reachable instance has no instance list, and captures and cycles are followed" {
    const h = try harness.create();
    defer scratch.release(h);
    var buffer: [2048]u8 = undefined;
    const none = try h.execute("Leaf:=class{Value:i64}\nA:=Leaf{Value:=1}\nB<public>:i64=A.Value");
    try std.testing.expectEqualStrings("{\"B\":1}\n", try reportOf(none, true, &buffer));
    const ring = try h.execute(
        \\Node<public>:=class{Value<public>:i64,var Next<public>:option(Node)}
        \\Lost:=Node{Value:=5,Next:=option{}}
        \\A:=Node{Value:=1,Next:=option{}}
        \\B:=Node{Value:=2,Next:=option{A}}
        \\set A.Next=option{B}
        \\Read(N:Node,K:i64)<transacts>:i64=N.Value+K
        \\Held<public>:function<transacts>(tuple(i64),i64)=Bind(Read,B)
        \\Shown:=Held
    );
    // A public report shows no capture (`fix2`), so nothing only the capture of `Held` reaches.
    try std.testing.expectEqualStrings("{\"Held\":{\"function\":{\"name\":\"Read\",\"module\":null}}}\n", try reportOf(ring, true, &buffer));
    // The whole-program report follows it: the capture reaches `B`, `B` reaches `A`, and `A`
    // reaches `B` again, and `Lost` is held by a binding of its own.
    const text = try reportOf(ring, false, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Held\":{\"function\":{\"name\":\"Read\",\"module\":null,\"captures\":[{\"$object\":6}]}}") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\"$objects\":[{\"id\":0,\"class\":\"Node\",\"fields\":{\"Value\":5,\"Next\":[]}},{\"id\":3,\"class\":\"Node\",\"fields\":{\"Value\":1,\"Next\":[{\"$object\":6}]}},{\"id\":6,\"class\":\"Node\",\"fields\":{\"Value\":2,\"Next\":[{\"$object\":3}]}}]}\n"));
}
