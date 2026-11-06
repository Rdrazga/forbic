//! Public reports (RFC-0063 "Reports", `fix2`): a `public_only` report shows nothing the public
//! API of the program cannot reach. Its public bindings; an instance as the nearest class that
//! another module can name, its own or one above it, with that class's fields that another
//! module can read; an instance of no such class as an entry of no class and no fields; and a
//! function value without its captures. A single file is public like a file of a bundle. A
//! whole-program report is unchanged. Stored and replayed reports stay byte-identical.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");
const replay = @import("trace_replay.zig");

fn reportOf(x: evaluator.Execution, public_only: bool, buffer: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(buffer);
    _ = try reporting.write(&out, x, public_only, .{});
    return out.buffered();
}

fn bundleOf(h: *harness.Harness, main: []const u8, lib: []const u8) !types.Program {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |p| p,
        .failed => |f| {
            std.debug.print("bundle failed: {s} in {s}\n", .{ f.diagnostic.message(), f.path });
            return error.Compile;
        },
    };
}

fn hiddenCount(p: types.Program) usize {
    var count: usize = 0;
    for (p.fields) |field| count += @intFromBool(field.hidden);
    return count;
}

test "a public report shows an instance as the class the public API names, with the fields other modules read" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Square` is private, so the API sees `Box` as a `Shape`: its own field `Side` is out of
    // reach, as is the internal `Scale`; the protected `Tag` is read by subclasses anywhere.
    // `vault` has no public class above it: its instance is listed, with no class and no field.
    const x = try h.execute(
        \\Shape<public>:=class<abstract>{
        \\  Name<public>:string
        \\  var Scale:i64=1
        \\  Tag<protected>:i64=7
        \\  Area<public><abstract>()<transacts>:i64
        \\}
        \\Square:=class(Shape){
        \\  Side<public>:i64
        \\  Area<override>()<transacts>:i64=Self.Side*Self.Side*Self.Scale
        \\}
        \\vault:=class{Code<public>:i64}
        \\Box<public>:Shape=Square{Name:="sq",Side:=3}
        \\Kept<public>:any=any(vault{Code:=55})
        \\Pair<public>:tuple(Shape,any)=tuple{Box,Kept}
        \\Measured<public>:i64=Box.Area()
    );
    var buffer: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"Box\":{\"$object\":0},\"Kept\":{\"$object\":3},\"Pair\":[{\"$object\":0},{\"$object\":3}],\"Measured\":9,\"$objects\":[" ++
            "{\"id\":0,\"class\":\"Shape\",\"fields\":{\"Name\":\"sq\",\"Tag\":7}}," ++
            "{\"id\":3,\"class\":null,\"fields\":{}}]}\n",
        try reportOf(x, true, &buffer),
    );
    // The whole-program report is no boundary and shows everything, as before.
    try std.testing.expectEqualStrings(
        "{\"Box\":{\"$object\":0},\"Kept\":{\"$object\":5},\"Pair\":[{\"$object\":0},{\"$object\":5}],\"Measured\":9,\"$objects\":[" ++
            "{\"id\":0,\"class\":\"Square\",\"fields\":{\"Name\":\"sq\",\"Scale\":1,\"Tag\":7,\"Side\":3}}," ++
            "{\"id\":5,\"class\":\"vault\",\"fields\":{\"Code\":55}}]}\n",
        try reportOf(x, false, &buffer),
    );
    // A single file marks the fields of a public class as a bundle does: `Scale` is internal.
    // `Square` is below `Shape` and takes the marks of what it inherits; its own field and
    // every field of `vault`, which is above no public class, stay unmarked.
    try std.testing.expectEqual(@as(usize, 2), hiddenCount(x.program));
}

test "a public report shows no capture, so no value only a capture holds" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Secret` is private and `Hidden` is an internal field: the function values that captured
    // them are shown by name only, and the instance only `Held`'s capture reaches is not listed.
    const x = try h.execute(
        \\Secret:i64=42
        \\Add(A:i64,B:i64)<computes>:i64=A+B
        \\Plus<public>:function<computes>(tuple(i64),i64)=Bind(Add,Secret)
        \\Box<public>:=class{
        \\  Hidden:i64=77
        \\  Peek<public>()<transacts>:function<computes>(tuple(i64),i64)=Bind(Add,Self.Hidden)
        \\}
        \\Made:=Box{}
        \\Leak<public>:function<computes>(tuple(i64),i64)=Made.Peek()
        \\Read(B:Box,K:i64)<transacts>:i64=B.Hidden+K
        \\Held<public>:function<transacts>(tuple(i64),i64)=Bind(Read,Made)
        \\Sum<public>:i64=Plus(1)+Leak(1)+Held(1)
    );
    var buffer: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"Plus\":{\"function\":{\"name\":\"Add\",\"module\":null}},\"Leak\":{\"function\":{\"name\":\"Add\",\"module\":null}},\"Held\":{\"function\":{\"name\":\"Read\",\"module\":null}},\"Sum\":199}\n",
        try reportOf(x, true, &buffer),
    );
    const whole = try reportOf(x, false, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, whole, "\"captures\":[42]") != null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "\"captures\":[77]") != null);
    try std.testing.expect(std.mem.indexOf(u8, whole, "\"class\":\"Box\",\"fields\":{\"Hidden\":77}") != null);
}

test "a private subclass of another file is shown as its public parent, and a public class may have a private parent" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\secret:=struct{x:i64=77}
        \\Box<public>:=class{
        \\  Hidden:secret=secret{}
        \\  Shown<public>:i64=1
        \\  Count:i64=5
        \\}
        \\Mid<public>:=class(Box){Extra<public>:i64=2}
        \\sub:=class(Mid){Own<public>:i64=3}
        \\Make<public>()<transacts>:Box=sub{}
        \\base:=class{Inner:secret=secret{},Seen<public>:i64=4}
        \\Open<public>:=class(base){}
        \\MakeOpen<public>()<transacts>:Open=Open{}
    ;
    const p = try bundleOf(h, "L:=import{\"lib.forb\"}\nB<public>:L.Box=L.Make()\nO<public>:L.Open=L.MakeOpen()", lib);
    const x = (try h.run(p, 100_000)).ok;
    var buffer: [2048]u8 = undefined;
    // `sub` is private, so `B` is a `Mid`: `Own` is out of reach. `Hidden` and `Count` are
    // internal. `Open` holds the internal `Inner` of its private parent hidden: until `fix2`
    // that was `private_type_escape`, because the field would have been shown.
    try std.testing.expectEqualStrings(
        "{\"B\":{\"$object\":0},\"O\":{\"$object\":3},\"$objects\":[" ++
            "{\"id\":0,\"class\":\"Mid\",\"fields\":{\"Shown\":1,\"Extra\":2}}," ++
            "{\"id\":3,\"class\":\"Open\",\"fields\":{\"Seen\":4}}]}\n",
        try reportOf(x, true, &buffer),
    );
    try std.testing.expect(std.mem.indexOf(u8, try reportOf(x, false, &buffer), "\"class\":\"sub\"") != null);
}

test "forged marks only show what the author's own program holds, and must agree down a class chain" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(
        \\Box<public>:=class{Inner:i64=5,Shown<public>:i64=1}
        \\more:=class(Box){}
        \\B<public>:Box=more{}
    );
    try std.testing.expectEqual(@as(usize, 2), hiddenCount(p));
    var buffer: [1024]u8 = undefined;
    const x = (try h.run(p, 10_000)).ok;
    try std.testing.expectEqualStrings("{\"B\":{\"$object\":0},\"$objects\":[{\"id\":0,\"class\":\"Box\",\"fields\":{\"Shown\":1}}]}\n", try reportOf(x, true, &buffer));
    const fields = try std.testing.allocator.dupe(types.Field, p.fields);
    defer std.testing.allocator.free(fields);
    // A mark says what a public report prints, not who may read a field, which stays a
    // compiler rule (RFC-0076): a program whose author clears it shows its own field.
    for (fields) |*field| field.hidden = false;
    var shown = p;
    shown.fields = fields;
    const y = (try h.run(shown, 10_000)).ok;
    try std.testing.expectEqualStrings("{\"B\":{\"$object\":0},\"$objects\":[{\"id\":0,\"class\":\"Box\",\"fields\":{\"Inner\":5,\"Shown\":1}}]}\n", try reportOf(y, true, &buffer));
    // A subclass must hold its parent's fields with the parent's marks: both machines refuse
    // a chain that disagrees.
    @memcpy(fields, p.fields);
    for (fields, 0..) |*field, index| if (index >= 2 and field.hidden) {
        field.hidden = false;
    };
    var disagreeing = p;
    disagreeing.fields = fields;
    try harness.invalid(h, disagreeing);
}

test "stored and replayed public reports are byte-identical, with dropped captures and unnamed classes" {
    var f = try replay.Fixture.create();
    defer f.destroy();
    const h = f.h;
    // Many instances are made and dropped in loops, so a digest run reclaims while the
    // listed ones survive.
    const p = try h.compile(
        \\Node<public>:=class{Value<public>:i64,Link:i64=0}
        \\cell:=class{N<public>:i64}
        \\Add(A:i64,B:i64)<computes>:i64=A+B
        \\Spin(N:i64)<transacts>:i64=Block{var T:i64=0;For(I:0..N, Block{set T=T+Node{Value:=I}.Value+cell{N:=I}.N;I});T}
        \\Total<public>:i64=Spin(100)
        \\Keep<public>:=Node{Value:=Total}
        \\Odd<public>:any=any(cell{N:=Spin(3)})
        \\Plus<public>:function<computes>(tuple(i64),i64)=Bind(Add,Total)
    );
    var stored: [2][4096]u8 = undefined;
    var stored_len: [2]usize = undefined;
    f.mode(.full, types.ControlStorage.default_trace_window);
    const full = h.runtime.evaluate(p, 1 << 30);
    try std.testing.expect(full == .ok);
    for ([_]bool{ true, false }, 0..) |public_only, index| {
        var out = std.Io.Writer.fixed(&stored[index]);
        _ = try reporting.write(&out, full.ok, public_only, .{});
        stored_len[index] = out.buffered().len;
    }
    try std.testing.expectEqualStrings(
        "{\"Total\":10100,\"Keep\":{\"$object\":0},\"Odd\":{\"$object\":2},\"Plus\":{\"function\":{\"name\":\"Add\",\"module\":null}},\"$objects\":[{\"id\":0,\"class\":\"Node\",\"fields\":{\"Value\":10100}},{\"id\":2,\"class\":null,\"fields\":{}}]}\n",
        stored[0][0..stored_len[0]],
    );
    for ([_]u32{ 7, 64 }) |window| {
        f.mode(.digest, window);
        h.control.reclaim_floor = 0;
        h.runtime.machine.control.reclaim_floor = 0;
        f.again.control.trace_window = window;
        f.again.control.reclaim_floor = 0;
        const digest = h.runtime.evaluate(p, 1 << 30);
        try std.testing.expect(digest == .ok);
        try std.testing.expect(digest.ok.reclaims != 0);
        for ([_]bool{ true, false }, 0..) |public_only, index| {
            var buffer: [4096]u8 = undefined;
            var out = std.Io.Writer.fixed(&buffer);
            _ = try reporting.writeReplayed(&out, digest.ok, f.again.producer(p, 1 << 30), public_only, .{ .work = 1 << 26 });
            try std.testing.expectEqualStrings(stored[index][0..stored_len[index]], out.buffered());
        }
    }
    f.mode(.full, types.ControlStorage.default_trace_window);
    h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
}

// A random hierarchy of classes in one file, against a model of the rule: each class is
// public or not and may extend an earlier one; each owns up to two `i64` fields of a random
// access; each binding makes an instance and is public or not. The public report lists the
// instances of public bindings in creation order, each as the nearest public class of its
// chain with that class's public and protected fields, or as an entry of no class.
test "public reports of random class hierarchies are what the rule says" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xf1c2);
    const random = prng.random();
    const Class = struct { public: bool, parent: ?usize, own: usize, access: [2]u8, value: [2]i64 };
    const accesses = [_][]const u8{ "", "<public>", "<protected>", "<private>" };
    var source: [4096]u8 = undefined;
    var expected_public: [4096]u8 = undefined;
    var expected_whole: [4096]u8 = undefined;
    var buffer: [4096]u8 = undefined;
    for (0..300) |_| {
        var classes: [5]Class = undefined;
        const class_count = 1 + random.uintLessThan(usize, 5);
        var out = std.Io.Writer.fixed(&source);
        for (classes[0..class_count], 0..) |*class, index| {
            class.* = .{ .public = random.boolean(), .parent = if (index != 0 and random.boolean()) random.uintLessThan(usize, index) else null, .own = random.uintLessThan(usize, 3), .access = undefined, .value = undefined };
            try out.print("K{d}{s}:=class", .{ index, if (class.public) "<public>" else "" });
            if (class.parent) |parent| try out.print("(K{d})", .{parent});
            try out.writeAll("{");
            for (0..class.own) |field| {
                class.access[field] = random.uintLessThan(u8, 4);
                class.value[field] = random.intRangeAtMost(i64, -50, 50);
                try out.print("{s}F{d}x{d}{s}:i64={d}", .{ if (field != 0) "," else "", index, field, accesses[class.access[field]], class.value[field] });
            }
            try out.writeAll("}\n");
        }
        const binding_count = 1 + random.uintLessThan(usize, 5);
        var made: [5]usize = undefined;
        var public_binding: [5]bool = undefined;
        for (0..binding_count) |index| {
            made[index] = random.uintLessThan(usize, class_count);
            public_binding[index] = random.boolean();
            try out.print("B{d}{s}:=K{d}{{}}\n", .{ index, if (public_binding[index]) "<public>" else "", made[index] });
        }
        // The fields of a class, inherited ones first, as (class, field) pairs.
        const Field = struct { class: usize, index: usize };
        const fieldsOf = struct {
            fn get(all: []const Class, class: usize, into: []Field) usize {
                var count: usize = 0;
                if (all[class].parent) |parent| count = get(all, parent, into);
                for (0..all[class].own) |field| {
                    into[count] = .{ .class = class, .index = field };
                    count += 1;
                }
                return count;
            }
        }.get;
        for ([_]bool{ true, false }) |public_only| {
            var model = std.Io.Writer.fixed(if (public_only) &expected_public else &expected_whole);
            try model.writeAll("{");
            var first = true;
            var id: usize = 0;
            var ids: [5]usize = undefined;
            for (0..binding_count) |index| {
                if (public_only and !public_binding[index]) continue;
                if (!first) try model.writeAll(",");
                first = false;
                try model.print("\"B{d}\":{{\"$object\":{d}}}", .{ index, id });
                ids[index] = id;
                var shown: ?usize = made[index];
                if (public_only) while (shown) |class| : (shown = classes[class].parent) {
                    if (classes[class].public) break;
                };
                var fields: [16]Field = undefined;
                const count = if (shown) |class| fieldsOf(classes[0..class_count], class, &fields) else 0;
                var printed: usize = 0;
                for (fields[0..count]) |field| {
                    const access = classes[field.class].access[field.index];
                    if (!public_only or access == 1 or access == 2) printed += 1;
                }
                id += 1 + printed;
            }
            if (!first) {
                try model.writeAll(",\"$objects\":[");
                var listed = false;
                for (0..binding_count) |index| {
                    if (public_only and !public_binding[index]) continue;
                    if (listed) try model.writeAll(",");
                    listed = true;
                    var shown: ?usize = made[index];
                    if (public_only) while (shown) |class| : (shown = classes[class].parent) {
                        if (classes[class].public) break;
                    };
                    const class = shown orelse {
                        try model.print("{{\"id\":{d},\"class\":null,\"fields\":{{}}}}", .{ids[index]});
                        continue;
                    };
                    try model.print("{{\"id\":{d},\"class\":\"K{d}\",\"fields\":{{", .{ ids[index], class });
                    var fields: [16]Field = undefined;
                    const count = fieldsOf(classes[0..class_count], class, &fields);
                    var printed: usize = 0;
                    for (fields[0..count]) |field| {
                        const access = classes[field.class].access[field.index];
                        if (public_only and access != 1 and access != 2) continue;
                        if (printed != 0) try model.writeAll(",");
                        printed += 1;
                        try model.print("\"F{d}x{d}\":{d}", .{ field.class, field.index, classes[field.class].value[field.index] });
                    }
                    try model.writeAll("}}");
                }
                try model.writeAll("]");
            }
            try model.writeAll("}\n");
        }
        const x = h.execute(out.buffered()) catch |err| {
            std.debug.print("random hierarchy failed:\n{s}\n", .{out.buffered()});
            return err;
        };
        const public_report = try reportOf(x, true, &buffer);
        const wanted = expected_public[0 .. std.mem.indexOfScalar(u8, &expected_public, '\n').? + 1];
        if (!std.mem.eql(u8, public_report, wanted)) {
            std.debug.print("program:\n{s}\nexpected {s}got      {s}", .{ out.buffered(), wanted, public_report });
            return error.TestUnexpectedResult;
        }
        const whole = try reportOf(x, false, &buffer);
        try std.testing.expectEqualStrings(expected_whole[0 .. std.mem.indexOfScalar(u8, &expected_whole, '\n').? + 1], whole);
    }
}

test "a public report hides a value of a type the public API cannot name" {
    var f = try replay.Fixture.create();
    defer f.destroy();
    const h = f.h;
    // `rec`, `mode` and `pair` are private: held as `any`, or behind a hidden field, nothing
    // outside can name them to read them back. A public type built of public parts prints.
    const p = try h.compile(
        \\rec:=struct{Code:i64}
        \\mode:=enum{Fast,Slow}
        \\Box<public>:=class{Inner:i64=1,Shown<public>:i64=2}
        \\Note(X:i64)<transacts>:i64=Block{For(I:0..X, Box{}.Shown);X}
        \\K<public>:any=any(rec{Code:=55})
        \\M<public>:any=any(mode.Slow)
        \\T<public>:any=any(tuple{rec{Code:=1},2})
        \\S<public>:any=any(array{1,Note(40)})
        \\B<public>:any=any(Box{})
    );
    var stored: [2][2048]u8 = undefined;
    var stored_len: [2]usize = undefined;
    f.mode(.full, types.ControlStorage.default_trace_window);
    const full = h.runtime.evaluate(p, 1 << 30);
    try std.testing.expect(full == .ok);
    for ([_]bool{ true, false }, 0..) |public_only, index| {
        var out = std.Io.Writer.fixed(&stored[index]);
        _ = try reporting.write(&out, full.ok, public_only, .{});
        stored_len[index] = out.buffered().len;
    }
    try std.testing.expectEqualStrings(
        "{\"K\":{\"$hidden\":true},\"M\":{\"$hidden\":true},\"T\":{\"$hidden\":true},\"S\":[1,40],\"B\":{\"$object\":0},\"$objects\":[{\"id\":0,\"class\":\"Box\",\"fields\":{\"Shown\":2}}]}\n",
        stored[0][0..stored_len[0]],
    );
    try std.testing.expect(std.mem.indexOf(u8, stored[1][0..stored_len[1]], "\"K\":{\"Code\":55}") != null);
    f.mode(.digest, 7);
    h.control.reclaim_floor = 0;
    h.runtime.machine.control.reclaim_floor = 0;
    f.again.control.trace_window = 7;
    f.again.control.reclaim_floor = 0;
    const digest = h.runtime.evaluate(p, 1 << 30);
    try std.testing.expect(digest == .ok);
    for ([_]bool{ true, false }, 0..) |public_only, index| {
        var buffer: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        _ = try reporting.writeReplayed(&out, digest.ok, f.again.producer(p, 1 << 30), public_only, .{ .work = 1 << 26 });
        try std.testing.expectEqualStrings(stored[index][0..stored_len[index]], out.buffered());
    }
    f.mode(.full, types.ControlStorage.default_trace_window);
    h.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
    h.runtime.machine.control.reclaim_floor = types.ControlStorage.default_reclaim_floor;
}

test "a public report hides a metatype held as any and shows a generic method's value without its receiver" {
    const h = try harness.create();
    defer scratch.release(h);
    // A metatype is a record of the library (RFC-0081): at its own type a public binding
    // reaches it, and held as `any` it is shown when its type can be named to cast it back:
    // here `Component` is public. Over a private class nothing outside can name it. A generic
    // method's value binds its receiver, a capture, which a public report does not show.
    const x = try h.execute(
        \\Component<public>:=class<castable>{}
        \\Physics<public>:=class(Component){}
        \\secret:=class<castable>{}
        \\inner:=class(secret){}
        \\Sk:castable_subtype(secret)=inner
        \\Private<public>:any=any(Sk)
        \\Box<public>:=class{
        \\  N<public>:i64=1
        \\  Get<public>[T:type](X:T)<computes>:T{X}
        \\}
        \\Wanted<public>:castable_subtype(Component)=Physics
        \\Hidden<public>:any=any(Wanted)
        \\B:=Box{}
        \\Got<public>:function<computes>(tuple(i64),i64)=B.Get[i64]
    );
    var buffer: [2048]u8 = undefined;
    const public = try reportOf(x, true, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, public, "\"Private\":{\"$hidden\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, public, "\"Hidden\":{\"$hidden\":true}") == null);
    try std.testing.expect(std.mem.indexOf(u8, public, "captures") == null);
    try std.testing.expect(std.mem.indexOf(u8, public, "$objects") == null);
    try std.testing.expect(std.mem.indexOf(u8, public, "\"Wanted\":{") != null);
    const whole = try reportOf(x, false, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, whole, "captures") != null);
}
