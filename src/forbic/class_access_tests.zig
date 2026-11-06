//! Access specifiers: `<private>` members are used only by the methods of their class,
//! `<protected>` ones also by the methods of subclasses, everything else from anywhere.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

test "private and protected members are reachable from inside their class and subclasses" {
    const h = try harness.create();
    defer scratch.release(h);
    const x = try h.execute(
        \\Account:=class{
        \\  Owner:string
        \\  var Balance<private>:i64=0
        \\  var Audits<protected>:i64=0
        \\  Check<private>(Amount:i64)<transacts><decides>:i64=Block{Require[Amount>0];Amount}
        \\  Note<protected>()<transacts>:i64=Block{set Self.Audits=Self.Audits+1;Self.Audits}
        \\  Deposit(Amount:i64)<transacts>:i64=Block{
        \\    Added:=Attempt(Self.Check[Amount],0)
        \\    set Self.Balance=Self.Balance+Added
        \\    Self.Balance
        \\  }
        \\  Twin()<transacts>:Account=Account{Owner:=Self.Owner,Balance:=Self.Balance}
        \\}
        \\Savings:=class(Account){
        \\  Note<override>()<transacts>:i64=Super.Note()+100
        \\  Audit()<transacts>:i64=Block{First:=Self.Note();Self.Audits}
        \\}
        \\A:=Account{Owner:="ann"}
        \\One:i64=A.Deposit(5)
        \\Two:i64=A.Deposit(-3)
        \\Copy:=A.Twin()
        \\Three:i64=Copy.Deposit(1)
        \\S:=Savings{Owner:="sam"}
        \\Seen:i64=S.Audit()
    );
    try std.testing.expectEqual(@as(i64, 5), x.get("One").?.integer);
    try std.testing.expectEqual(@as(i64, 5), x.get("Two").?.integer);
    try std.testing.expectEqual(@as(i64, 6), x.get("Three").?.integer);
    try std.testing.expectEqual(@as(i64, 1), x.get("Seen").?.integer);
}

test "members are refused outside the scope their specifier allows" {
    const h = try harness.create();
    defer scratch.release(h);
    const base =
        \\A:=class{
        \\  var P<private>:i64=1
        \\  var Q<protected>:i64=2
        \\  F<private>()<transacts>:i64=1
        \\  G<protected>()<transacts>:i64=2
        \\}
        \\K:=A{}
        \\
    ;
    const cases = [_]struct { tail: []const u8, code: types.Diagnostic.Code }{
        .{ .tail = "X:i64=K.P", .code = .inaccessible_member },
        .{ .tail = "X:i64=K.Q", .code = .inaccessible_member },
        .{ .tail = "set K.P=3", .code = .inaccessible_member },
        .{ .tail = "X:i64=K.F()", .code = .inaccessible_member },
        .{ .tail = "X:i64=K.G()", .code = .inaccessible_member },
        .{ .tail = "J:=A{P:=4}", .code = .inaccessible_member },
        .{ .tail = "Read(V:A)<transacts>:i64=V.Q", .code = .inaccessible_member },
        .{ .tail = "B:=class(A){H()<transacts>:i64=Self.P}", .code = .inaccessible_member },
        .{ .tail = "B:=class(A){H()<transacts>:i64=Self.F()}", .code = .inaccessible_member },
        // RFC-0092 (B4): an override may narrow its access, never widen it.
        .{ .tail = "B:=class(A){G<override><public>()<transacts>:i64=3}", .code = .override_mismatch },
        .{ .tail = "B:=class(A){F<override>()<transacts>:i64=3}", .code = .inaccessible_member },
        .{ .tail = "B:=class(A){F()<transacts>:i64=3}", .code = .inaccessible_member },
        .{ .tail = "B:=class{Foo:i64=1\nFoo()<transacts>:i64=2}", .code = .duplicate_name },
        .{ .tail = "B:=class(A){G:i64=1}", .code = .duplicate_name },
        .{ .tail = "B:=class{Z<secret>:i64}", .code = .unsupported_specifier },
        .{ .tail = "B:=class{Z<private><private>()<transacts>:i64=1}", .code = .unsupported_specifier },
    };
    var buffer: [1024]u8 = undefined;
    for (cases) |case| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, case.tail });
        const result = h.front.compile(source);
        if (result == .ok or result.failed.code != case.code) {
            std.debug.print("access diagnostic for: {s}\nexpected {s}, got {s}\n", .{ case.tail, @tagName(case.code), if (result == .ok) "success" else @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
    // The same members are fine where the specifier allows them.
    const allowed = [_][]const u8{
        "B:=class(A){H()<transacts>:i64=Self.Q+Self.G()}",
        "B:=class(A){G<override>()<transacts>:i64=3}",
        "B:=class(A){G<override><protected>()<transacts>:i64=3}",
    };
    for (allowed) |tail| {
        const source = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, tail });
        const result = h.front.compile(source);
        if (result != .ok) {
            std.debug.print("expected success for: {s}\ngot {s}\n", .{ tail, @tagName(result.failed.code) });
            return error.WrongDiagnostic;
        }
    }
}

const modules = @import("modules.zig");
const reporting = @import("value_report.zig");
const inspection = @import("inspection.zig");

fn bundleOf(h: *harness.Harness, main: []const u8, lib: []const u8) @import("compiler.zig").BundleResult {
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main }, .{ .path = "lib.forb", .source = lib } };
    return h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
}

fn expectBundle(h: *harness.Harness, main: []const u8, lib: []const u8, code: ?types.Diagnostic.Code) !void {
    const result = bundleOf(h, main, lib);
    const got: ?types.Diagnostic.Code = if (result == .ok) null else result.failed.diagnostic.code;
    if (got != code) {
        std.debug.print("bundle {s} / {s}: expected {s}, got {s}\n", .{ main, lib, if (code) |c| @tagName(c) else "success", if (got) |c| @tagName(c) else "success" });
        return error.WrongDiagnostic;
    }
}

test "a public class of a flat bundle may hold its own type, and classes may hold each other" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Node<public>:=class{
        \\  Value<public>:i64=0
        \\  var Next<public>:option(Node)=option{}
        \\  Rest<public>:[]Node=array{}
        \\}
        \\Ping<public>:=class{Other<public>:option(Pong)=option{}}
        \\Pong<public>:=class{Other<public>:option(Ping)=option{},Back<public>:map(i64,tuple(Pong,Ping))=map{}}
        \\Chain<public>(N:i64)<transacts>:Node=Node{Value:=N,Next:=option{Node{Value:=N+1}}}
    ;
    const main =
        \\L:=import{"lib.forb"}
        \\Head<public>:L.Node=L.Chain(4)
        \\Second<public>:i64=Attempt(Head.Next?.Value,-1)
        \\Both<public>:L.Pong=L.Pong{Other:=option{L.Ping{}}}
    ;
    const bundled = bundleOf(h, main, lib);
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const x = (try h.run(bundled.ok, 100_000)).ok;
    try std.testing.expectEqual(@as(i64, 5), x.get("Second").?.integer);
    // A private type still makes what holds it private, through a class that holds itself too.
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nNode<public>:=class{Next<public>:option(Node)=option{},Leak<public>:option(secret)=option{}}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "hidden:=class{Other:option(Open)=option{}}\nOpen<public>:=class{Other<public>:option(hidden)=option{}}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "hidden:=class{Self:option(hidden)=option{}}\nOpen<public>(X:hidden)<transacts>:i64=1", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "Node:=class{Next:option(Node)=option{}}\nA<public>:option(Node)=option{}", .private_type_escape);
}

test "an internal or private member of a public class may have a private type, which no public report shows" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\secret:=struct{x:i64=77}
        \\vault:=class{Code:i64=55}
        \\Box<public>:=class{
        \\  Hidden:secret=secret{}
        \\  Shown<public>:i64=1
        \\  Kept<private>:option(vault)=option{}
        \\  Later<public>:string="s"
        \\  Inner(S:secret)<transacts>:i64=S.x
        \\  Peek<public>()<transacts>:i64=Self.Inner(Self.Hidden)+Attempt(Self.Kept?.Code,0)
        \\  Fill<public>()<transacts>:Box=Box{Kept:=option{vault{}}}
        \\}
        \\Make<public>()<transacts>:Box=Box{}.Fill()
    ;
    const main =
        \\L:=import{"lib.forb"}
        \\B<public>:L.Box=L.Make()
        \\Other<public>:L.Box=L.Make()
        \\A<public>:i64=B.Peek()+1
    ;
    const bundled = bundleOf(h, main, lib);
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const x = (try h.run(bundled.ok, 100_000)).ok;
    try std.testing.expectEqual(@as(i64, 133), x.get("A").?.integer);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, true, .{});
    // Neither hidden field is printed, the `vault` instances are not listed, and the ids count
    // what is printed: a header and two fields for each `Box`.
    try std.testing.expectEqualStrings(
        "{\"B\":{\"$object\":0},\"Other\":{\"$object\":3},\"A\":133,\"$objects\":[" ++
            "{\"id\":0,\"class\":\"Box\",\"fields\":{\"Shown\":1,\"Later\":\"s\"}}," ++
            "{\"id\":3,\"class\":\"Box\",\"fields\":{\"Shown\":1,\"Later\":\"s\"}}]}\n",
        out.buffered(),
    );
    // The whole-program report is not a boundary and shows everything.
    out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"Hidden\":{\"x\":77}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"class\":\"vault\",\"fields\":{\"Code\":55}") != null);
    // Exactly the two fields are marked, and inspection says so.
    var hidden: usize = 0;
    for (x.program.fields) |field| hidden += @intFromBool(field.hidden);
    try std.testing.expectEqual(@as(usize, 2), hidden);
    const document = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(document);
    var writer = std.Io.Writer.fixed(document);
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    try std.testing.expect(try workspace.write(&writer, x.program) == .ok);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, writer.buffered(), "\"hidden\":true"));
    // The mark is what lets the class cross: forged away, on either field, both admissions
    // refuse the program, as they refused the class before the mark existed.
    const forged_fields = try std.testing.allocator.dupe(types.Field, x.program.fields);
    defer std.testing.allocator.free(forged_fields);
    for (x.program.fields, 0..) |field, index| if (field.hidden) {
        forged_fields[index].hidden = false;
        var forged = bundled.ok;
        forged.fields = forged_fields;
        try harness.invalid(h, forged);
        forged_fields[index].hidden = true;
    };
    // Forged onto every field, it only hides more: the program runs and the report is smaller.
    for (forged_fields) |*field| field.hidden = true;
    var all_hidden = bundled.ok;
    all_hidden.fields = forged_fields;
    const y = (try h.run(all_hidden, 100_000)).ok;
    out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, y, true, .{});
    try std.testing.expectEqualStrings("{\"B\":{\"$object\":0},\"Other\":{\"$object\":1},\"A\":133,\"$objects\":[{\"id\":0,\"class\":\"Box\",\"fields\":{}},{\"id\":1,\"class\":\"Box\",\"fields\":{}}]}\n", out.buffered());

    // The member stays unusable outside its module, and a member that does leave the module
    // may not have a private type.
    try expectBundle(h, "L:=import{\"lib.forb\"}\nB:=L.Make()\nA<public>:i64=B.Hidden.x", lib, .internal_member);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nBox<public>:=class{Seen<public>:secret=secret{}}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nBox<public>:=class{Seen<protected>:secret=secret{}}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nBox<public>:=class{var<private> Seen<public>:secret=secret{}}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nBox<public>:=struct{Seen:secret=secret{}}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nBox<public>:=class{Seen<internal>:[]secret=array{}}", null);
    // A subclass in another module inherits the field hidden.
    try expectBundle(h, "L:=import{\"lib.forb\"}\nMore<public>:=class(L.Box){Extra<public>:i64=2}\nM<public>:More=More{}", lib, null);
    // Since `fix2` every internal field of a public class is marked, whatever its type: its
    // value is nothing the public API reaches. A public field is not.
    const plain = bundleOf(h, "L:=import{\"lib.forb\"}\nB<public>:L.Box=L.Box{}", "Box<public>:=class{Inner:i64=1,Seen<public>:i64=2}").ok;
    for (plain.fields) |field| try std.testing.expectEqual(std.mem.eql(u8, field.name.text(plain.source), "Inner"), field.hidden);
}

test "modules declared in files hide an internal member of a private type the same way" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Kit<public>:=module{
        \\  secret:=struct{x:i64=77}
        \\  Box<public>:=class{
        \\    Hidden:secret=secret{}
        \\    Shown<public>:i64=1
        \\    Peek<public>()<transacts>:i64=Self.Hidden.x
        \\  }
        \\  Make<public>()<transacts>:Box=Box{}
        \\}
    ;
    const main =
        \\L:=import{"lib.forb"}
        \\B<public>:L.Kit.Box=L.Kit.Make()
        \\A<public>:i64=B.Peek()+1
    ;
    const bundled = bundleOf(h, main, lib);
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    const x = (try h.run(bundled.ok, 100_000)).ok;
    try std.testing.expectEqual(@as(i64, 78), x.get("A").?.integer);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, true, .{});
    try std.testing.expectEqualStrings("{\"B\":{\"$object\":0},\"A\":78,\"$objects\":[{\"id\":0,\"class\":\"Box\",\"fields\":{\"Shown\":1}}]}\n", out.buffered());
    try expectBundle(h, "L:=import{\"lib.forb\"}", "Kit<public>:=module{\nsecret:=struct{x:i64=1}\nBox<public>:=class{Seen<public>:secret=secret{}}\n}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}\nB:=L.Kit.Make()\nA<public>:i64=B.Hidden.x", lib, .internal_member);
}

/// Compiles a two-file bundle that must run, and returns its `public_only` report.
fn publicReport(h: *harness.Harness, main: []const u8, lib: []const u8, buffer: []u8) ![]const u8 {
    const bundled = bundleOf(h, main, lib);
    if (bundled == .failed) {
        std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
        return error.WrongDiagnostic;
    }
    const x = (try h.run(bundled.ok, 100_000)).ok;
    var out = std.Io.Writer.fixed(buffer);
    _ = try reporting.write(&out, x, true, .{});
    return out.buffered();
}

test "a subclass of any kind holds a hidden field of its parent hidden" {
    const h = try harness.create();
    defer scratch.release(h);
    // Admission requires a subclass to repeat its parent's fields exactly, the mark included:
    // a private subclass, or one in another file, once kept the field shown, and the program
    // compiled and was then refused by both machines.
    const box =
        \\secret:=struct{x:i64=77}
        \\Box<public>:=class{
        \\  Hidden:secret=secret{}
        \\  Shown<public>:i64=1
        \\}
    ;
    var buffer: [2048]u8 = undefined;
    // A public report names the class the public API can name (`fix2`): the private `sub` is
    // shown as `Box`, or as the public `Mid` below `Box`, with that class's fields only.
    const expected = "{\"B\":{\"$object\":0},\"$objects\":[{\"id\":0,\"class\":\"Box\",\"fields\":{\"Shown\":1}}]}\n";
    // A private subclass in the same file, returned as its public parent.
    try std.testing.expectEqualStrings(expected, try publicReport(h, "L:=import{\"lib.forb\"}\nB<public>:L.Box=L.Make()", box ++ "\nsub:=class(Box){}\nMake<public>()<transacts>:Box=sub{}", &buffer));
    // Below a public subclass, with a field of its own.
    try std.testing.expectEqualStrings(
        "{\"B\":{\"$object\":0},\"$objects\":[{\"id\":0,\"class\":\"Mid\",\"fields\":{\"Shown\":1}}]}\n",
        try publicReport(h, "L:=import{\"lib.forb\"}\nB<public>:L.Box=L.Make()", box ++ "\nMid<public>:=class(Box){}\nsub:=class(Mid){Own<public>:i64=2}\nMake<public>()<transacts>:Box=sub{}", &buffer),
    );
    // A private subclass in the importing file.
    try std.testing.expectEqualStrings(
        "{\"A\":1}\n",
        try publicReport(h, "L:=import{\"lib.forb\"}\nmore:=class(L.Box){}\nB:=more{}\nA<public>:i64=B.Shown", box, &buffer),
    );
    // Inside a module declared in a file.
    try std.testing.expectEqualStrings(expected, try publicReport(h, "L:=import{\"lib.forb\"}\nB<public>:L.Kit.Box=L.Kit.Make()", "Kit<public>:=module{\n" ++ box ++ "\nsub:=class(Box){}\nMake<public>()<transacts>:Box=sub{}\n}", &buffer));
    // A public subclass of a private parent holds the parent's internal field hidden too, so its
    // type may be private (`fix2`; until then the field was shown and the class refused). A
    // field the parent makes public still may not have a private type.
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nbase:=class{Hidden:secret=secret{}}\nOpen<public>:=class(base){}", null);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "Kit<public>:=module{\nsecret:=struct{x:i64=1}\nbase:=class{Hidden:secret=secret{}}\nOpen<public>:=class(base){}\n}", null);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "secret:=struct{x:i64=1}\nbase:=class{Seen<public>:secret=secret{}}\nOpen<public>:=class(base){}", .private_type_escape);
    try expectBundle(h, "L:=import{\"lib.forb\"}", "Kit<public>:=module{\nsecret:=struct{x:i64=1}\nbase:=class{Seen<public>:secret=secret{}}\nOpen<public>:=class(base){}\n}", .private_type_escape);
}
