//! Defects closed by the `fix2` pass that need no file of their own: late classes found by
//! exact names, the VM's straight-line run of a value held as `any`, and a report whose binding
//! names are checked through an index.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const harness = @import("generic_function_tests.zig");
const reporting = @import("value_report.zig");

fn bundle(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

test "a class is declared late only for a late name its file can reach" {
    const h = try harness.create();
    defer scratch.release(h);
    // `lateSeen` reads the late declarations a name can mean: its own file's, and the public
    // ones of a file it imports, by `Alias.Name` or after a `using` of that file.
    const Case = struct { main: []const u8, lib: []const u8, late: u32 };
    const cases = [_]Case{
        // A private template of the library, not reachable: only the template is late.
        .{ .main = "Box<public>:=class{N<public>:i64=1}\nSub<public>:=class(Box){}\nV:i64=Sub{}.N", .lib = "Box[T:type]:=class{V:T}\nHeld:Box[i64]=Box[i64]{V:=1}", .late = 1 },
        // Public, but without a `using` the unqualified `Box` is this file's own.
        .{ .main = "Box<public>:=class{N<public>:i64=1}\nSub<public>:=class(Box){}\nV:i64=Sub{}.N", .lib = "Box<public>[T:type]:=class{V<public>:T}", .late = 1 },
        // After `using{L}` a public template of the library is reachable unqualified, so
        // `Sub` may be below one of its instantiations and waits for it.
        .{ .main = "using{L}\nSub<public>:=class(Crate[i64]){}\nV:i64=Sub{V:=3}.V", .lib = "Crate<public>[T:type]:=class{V<public>:T}", .late = 2 },
        // Qualified, a public one is reachable without a `using`.
        .{ .main = "Sub<public>:=class(L.Crate[i64]){}\nV:i64=Sub{V:=3}.V", .lib = "Crate<public>[T:type]:=class{V<public>:T}", .late = 2 },
    };
    for (cases) |case| {
        var text: [512]u8 = undefined;
        const main = try std.fmt.bufPrint(&text, "L:=import{{\"lib.forb\"}}\n{s}", .{case.main});
        const result = bundle(h, main, case.lib);
        if (result == .failed) {
            std.debug.print("bundle failed: {s} in {s}\n{s}\n", .{ result.failed.diagnostic.message(), result.failed.path, main });
            return error.Compile;
        }
        try std.testing.expectEqual(case.late, h.front.late_count);
        const x = (try h.run(result.ok, 10_000)).ok;
        try std.testing.expect(x.get("V").?.integer != 0);
    }
}

test "the VM holds a scalar of type any in a run without control" {
    const h = try harness.create();
    defer scratch.release(h);
    // A program with no branch or call runs on the VM's straight-line path, which asserted
    // that a register of a catalogue type holds an aggregate: `any(0)` stopped the VM.
    const x = try h.execute(
        \\A:any=any(0)
        \\B:any=any(1.5)
        \\C:any=any("s")
        \\D:any=any(true)
        \\E:any=any('c')
        \\F:i64=1
    );
    try std.testing.expectEqual(@as(i64, 0), x.get("A").?.integer);
    try std.testing.expectEqualStrings("s", x.get("C").?.string);
    try std.testing.expectEqual(@as(i64, 1), x.get("F").?.integer);
}

test "a report refuses a repeated binding name, found through its index" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute("A:i64=1\nB:i64=2\nC:i64=3");
    _ = try reporting.validate(x, false, .{});
    const bindings = try std.testing.allocator.dupe(types.Binding, x.program.bindings);
    defer std.testing.allocator.free(bindings);
    var forged = x;
    forged.program.bindings = bindings;
    // The last binding renamed as the first: the report would print a name twice.
    bindings[2].name = bindings[0].name;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(forged, false, .{}));
}

test "a public alias, and a using written across lines, reach a late class of another file" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib = "Box<public>[T:type]:=class{V<public>:T}\nInts<public>:=Box[i64]\nMid<public>:=class(Box[i64]){}";
    const mains = [_][]const u8{
        "L:=import{\"lib.forb\"}\nSub<public>:=class(L.Ints){}\nV<public>:i64=Sub{V:=3}.V",
        "L:=import{\"lib.forb\"}\nusing{L}\nSub<public>:=class(Ints){}\nV<public>:i64=Sub{V:=3}.V",
        "L:=import{\"lib.forb\"}\nusing{\nL\n}\nSub<public>:=class(Mid){}\nV<public>:i64=Sub{V:=3}.V",
        "L:=import{\"lib.forb\"}\nusing{L}\nSub<public>:=class(Mid){}\nV<public>:i64=Sub{V:=3}.V",
        "L:=import{\"lib.forb\"}\nSub<public>:=class(L.Mid){}\nV<public>:i64=Sub{V:=3}.V",
    };
    for (mains) |main| {
        const result = bundle(h, main, lib);
        if (result == .failed) {
            std.debug.print("bundle failed: {s} in {s}\n{s}\n", .{ result.failed.diagnostic.message(), result.failed.path, main });
            return error.Compile;
        }
        const x = (try h.run(result.ok, 10_000)).ok;
        try std.testing.expectEqual(@as(i64, 3), x.get("V").?.integer);
    }
}

test "overloads whose function types one function can be a value of are refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const animals = "animal:=class{N:i64=1}\ndog:=class(animal){}\ncat:=class(animal){}\n";
    const refused = [_][]const u8{
        // Effects only: a `<computes>` function is a value of both (base19 accepted this).
        "A(F:function<computes>(tuple(i64),i64))<computes>:i64=1\nA(F:function<transacts>(tuple(i64),i64))<computes>:i64=2",
        "A(F:function<reads>(tuple(i64),i64))<computes>:i64=1\nA(F:function<writes>(tuple(i64),i64))<computes>:i64=2",
        // Parameters: a function of an `animal` is a value of both.
        animals ++ "A(F:function<computes>(tuple(dog),i64))<computes>:i64=1\nA(F:function<computes>(tuple(animal),i64))<computes>:i64=2",
        animals ++ "A(F:function<computes>(tuple(dog),i64))<computes>:i64=1\nA(F:function<computes>(tuple(cat),i64))<computes>:i64=2",
        // Results: a function returning a `dog` is a value of both.
        animals ++ "A(F:function<computes>(tuple(),animal))<computes>:i64=1\nA(F:function<computes>(tuple(),dog))<computes>:i64=2",
    };
    for (refused) |source| {
        const result = h.front.compile(source);
        if (result == .ok or result.failed.code != .related_overloads) {
            std.debug.print("expected related_overloads for:\n{s}\ngot {s}\n", .{ source, if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
    // Function types no function is a value of both of stay distinct.
    const distinct = [_][]const u8{
        "A(F:function<computes>(tuple(i64),i64))<computes>:i64=1\nA(F:function<computes>(tuple(string),i64))<computes>:i64=2\nR:i64=A(Fn(X:i64){X})",
        "A(F:function<computes>(tuple(i64),i64))<computes>:i64=1\nA(F:function<computes>(tuple(i64),string))<computes>:i64=2\nR:i64=A(Fn(X:i64){X})",
        "A(F:function<computes>(tuple(i64),i64))<computes>:i64=1\nA(F:function<computes>(tuple(i64,i64),i64))<computes>:i64=2\nR:i64=A(Fn(X:i64){X})",
        "A(F:function<computes>(tuple([]i64),i64))<computes>:i64=1\nA(F:function<computes>(tuple([]string),i64))<computes>:i64=2\nR:i64=1",
    };
    for (distinct) |source| _ = try h.execute(source);
}
