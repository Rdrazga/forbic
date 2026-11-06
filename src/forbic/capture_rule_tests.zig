//! The one capture rule (RFC-0085, I13, Q1, S1e): a local `var` that any closure form names is
//! shared, and the closure refers to the variable. Everything else stays by value: immutable
//! locals, parameters, explicit captures `Fn[C:T = X]`, and the locals that no closure names.
//!
//! The switch `Workspace.share_names` (default on) compiles with the rules of I2 to I14 alone, so
//! each test can show what a program meant before Q1. The randomised oracles are in
//! `shared_local_tests.zig` and `closure_composition_tests.zig`, which run both models.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const inspection = @import("inspection.zig");
const reporting = @import("value_report.zig");
const harness = @import("generic_function_tests.zig");

const allocator = std.testing.allocator;

/// The integer binding `name`, or the result of the task `name`, of a run of `source`.
fn valueOf(h: *harness.Harness, source: []const u8, name: []const u8, task: bool) !i64 {
    const x = try h.execute(source);
    if (!task) return (x.get(name) orelse return error.MissingBinding).integer;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try reporting.write(&out, x, false, .{});
    const text = out.buffered();
    var key: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&key, "\"{s}\":{{\"$task\":{{", .{name});
    const at = std.mem.indexOf(u8, text, head) orelse {
        std.debug.print("no task {s}: {s}\n", .{ name, text });
        return error.MissingBinding;
    };
    const result = "\"result\":";
    const from = (std.mem.indexOfPos(u8, text, at, result) orelse return error.MissingBinding) + result.len;
    var end = from;
    while (end < text.len and (text[end] == '-' or std.ascii.isDigit(text[end]))) end += 1;
    return std.fmt.parseInt(i64, text[from..end], 10);
}

fn refuses(h: *harness.Harness, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    switch (h.front.compile(source)) {
        .ok => {
            std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
            return error.Compiled;
        },
        .failed => |d| {
            if (d.code != code or !std.mem.eql(u8, source[d.span.start..d.span.end], at)) {
                std.debug.print("got {s} at '{s}', expected {s} at '{s}': {s}\n", .{ @tagName(d.code), source[d.span.start..d.span.end], @tagName(code), at, source });
                return error.WrongDiagnostic;
            }
        },
    }
}

/// Whether the program has a variable cell type.
fn hasCell(p: types.Program) bool {
    for (p.definitions) |d| if (d == .ref) return true;
    return false;
}

/// How many cells a program makes (`ref_new`), in functions and at the root.
fn cells(p: types.Program) usize {
    var count: usize = 0;
    for (p.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .ref_new) {
        count += 1;
    };
    for (p.nodes) |node| if (node.kind == .ref_new) {
        count += 1;
    };
    return count;
}

/// A program whose closure of one form names the local `X` and does not assign it; the code
/// around it (or another task) writes `X` after the closure is built. `after` is the value
/// with Q1, `before` the value of the rules before it.
const Row = struct { form: []const u8, source: []const u8, name: []const u8, task: bool, after: i64, before: i64, cell: bool = true };
const forms = [_]Row{
    .{ .form = "Fn", .source = "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};set X=5;R()}\nV:i64=F()", .name = "V", .task = false, .after = 5, .before = 1 },
    .{ .form = "Fn built in a loop body", .source = "var Keep:option(function<reads>(tuple(),i64))=option{}\nF()<transacts>:i64=Block{var X:i64=0;For(I:1..3,Block{set X=X+I;set Keep=option{Fn()<reads>:i64{X}};0});set X=100;Attempt(Keep?(),-1)}\nV:i64=F()", .name = "V", .task = false, .after = 100, .before = 6 },
    .{ .form = "nested function", .source = "F()<transacts>:i64=Block{var X:i64=1;R()<reads>:i64=X;set X=5;R()}\nV:i64=F()", .name = "V", .task = false, .after = 5, .before = 5 },
    .{ .form = "Spawn", .source = "F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);X+1};set X=5;T.Await()}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 6, .before = 2 },
    .{ .form = "Branch", .source = "var Out:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;Branch{Sleep(1.0);Set(Out,X)};set X=5;Sleep(2.0);Out}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 5, .before = 1 },
    .{ .form = "Upon body", .source = "var Out:i64=0\nvar G:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;U:task(i64)=Upon(G>0,Set(Out,X));set X=7;set G=5;Sleep(1.0);Out}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 7, .before = 1 },
    .{ .form = "When body", .source = "var Out:i64=0\nvar G:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;W:task(void)=When(G>0,Set(Out,X));set X=7;set G=5;Sleep(1.0);Out}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 7, .before = 1 },
    // The forms below run where they stand or while the code around them waits, so nothing
    // changes the local between their building and their reads: the same value, now through a cell
    // (but a landing, which reads at its site, takes no cell, I13-D5).
    .{ .form = "Sync arm", .source = "F()<transacts><suspends>:i64=Block{var X:i64=1;R:=Sync(Block{Sleep(1.0);X},Block{Sleep(2.0);X+10});set X=5;R(0)*100+R(1)+X}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 116, .before = 116 },
    .{ .form = "Race arm", .source = "F()<transacts><suspends>:i64=Block{var X:i64=1;R:=Race(Block{Sleep(1.0);X},Block{Sleep(2.0);X+10});set X=5;R*100+X}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 105, .before = 105 },
    .{ .form = "Batch body", .source = "F()<transacts>:i64=Block{var X:i64=1;B:i64=Batch{X+1};set X=5;B*100+X}\nV:i64=F()", .name = "V", .task = false, .after = 205, .before = 205 },
    // A `Rush` returns at its first arm; the loser goes on, and reads the creator's write.
    .{ .form = "Rush loser", .source = "var Out:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=1;W:=Rush(Block{Sleep(1.0);2},Block{Sleep(3.0);set Out=X;3});set X=9;Sleep(5.0);W*100+Out}\nP:task(i64)=Spawn{F()}", .name = "P", .task = true, .after = 209, .before = 201 },
    .{ .form = "landing", .source = "var M:i64=0\nF()<transacts><suspends>:i64=Block{var N:i64=4;Defer{set M=N*10};Sleep(5.0);N}\nG()<transacts><suspends>:i64=Block{W:=Race(F(),Block{Sleep(1.0);2});W*100+M}\nP:task(i64)=Spawn{G()}", .name = "P", .task = true, .after = 240, .before = 240, .cell = false },
};

test "each closure form refers to a local var it only names, and the rules before Q1 copied it" {
    const h = try harness.create();
    defer scratch.release(h);
    var changed: usize = 0;
    for (forms) |row| {
        h.front.share_names = true;
        const after = try valueOf(h, row.source, row.name, row.task);
        try std.testing.expectEqual(row.cell, hasCell(try h.compile(row.source)));
        h.front.share_names = false;
        const before = try valueOf(h, row.source, row.name, row.task);
        const old = try h.compile(row.source);
        // A nested function shared what it named already (S1a).
        try std.testing.expectEqual(std.mem.eql(u8, row.form, "nested function"), hasCell(old));
        h.front.share_names = true;
        if (after != row.after or before != row.before) std.debug.print("{s}: {d} (expected {d}) after, {d} (expected {d}) before: {s}\n", .{ row.form, after, row.after, before, row.before, row.source });
        try std.testing.expectEqual(row.after, after);
        try std.testing.expectEqual(row.before, before);
        if (after != before) changed += 1;
    }
    // The forms whose meaning changes are the ones that outlive the moment they are built in
    // while the variable changes: an `Fn`, a task body, a `Branch`, the bodies of reactions and
    // the loser of a `Rush` (review).
    try std.testing.expectEqual(@as(usize, 7), changed);
}

test "the Book's rule: Snap yields 51" {
    const h = try harness.create();
    defer scratch.release(h);
    try std.testing.expectEqual(@as(i64, 51), try valueOf(h, "Snap()<transacts>:i64=Block{var L:i64=1;F:=Fn(X:i64){L+X};set L=50;F(1)}\nV:i64=Snap()", "V", false));
}

test "what stays by value: immutable locals, parameters, explicit captures, locals no closure names" {
    const h = try harness.create();
    defer scratch.release(h);
    const stays = [_]struct { []const u8, i64 }{
        // An immutable local and a parameter.
        .{ "F(P:i64)<computes>:i64=Block{X:=P+1;R:=Fn()<computes>:i64{X+P};R()}\nV:i64=F(2)", 5 },
        // An explicit capture list says "this value": `X` is read where the `Fn` is built.
        .{ "F()<transacts>:i64=Block{var X:i64=1;R:=Fn[C:i64=X]()<computes>:i64{C};set X=5;R()}\nV:i64=F()", 1 },
        // A local that only the function itself reads and writes, beside a closure of another.
        .{ "F()<transacts>:i64=Block{var X:i64=1;var Y:i64=2;R:=Fn()<reads>:i64{Y};set X=X+10;set Y=Y+10;X*100+R()}\nV:i64=F()", 1112 },
        // A `For` that carries a local no closure names.
        .{ "F()<transacts>:i64=Block{var X:i64=0;For(I:1..4,Block{set X=X+I;0});X}\nV:i64=F()", 10 },
        // A local the closure declares itself and no closure inside it names.
        .{ "F()<transacts>:i64=Block{R:=Fn()<transacts>:i64{Block{var Y:i64=1;set Y=Y+4;Y}};R()}\nV:i64=F()", 5 },
    };
    var shares: usize = 0;
    for (stays, 0..) |entry, index| {
        const p = try h.compile(entry[0]);
        try std.testing.expectEqual(@as(i64, entry[1]), try valueOf(h, entry[0], "V", false));
        // Only the third program has a cell: `Y`, named by the `Fn`.
        if (hasCell(p)) shares += 1;
        try std.testing.expectEqual(index == 2, hasCell(p));
    }
    try std.testing.expectEqual(@as(usize, 1), shares);
    // An explicit capture cannot be assigned, shared local or not, as before.
    try refuses(h, "F()<transacts>:i64=Block{var X:i64=1;R:=Fn[C:i64=X]()<transacts>:i64{Set(C,2)};R()}\nV:i64=F()", .not_mutable, "C");
}

test "a program that names no local var in any closure compiles to the same program" {
    const h = try harness.create();
    defer scratch.release(h);
    const report_space = try scratch.storage(inspection.Workspace);
    defer scratch.release(report_space);
    const first = try allocator.alloc(u8, 1 << 18);
    defer allocator.free(first);
    const second = try allocator.alloc(u8, 1 << 18);
    defer allocator.free(second);
    const sources = [_][]const u8{
        "F(Xs:[]i64)<transacts>:i64=Block{var T:i64=0;For(K:Xs,Block{set T=T+K;0});T}\nV:i64=F(array{1,2,3})",
        "F()<transacts>:i64=Block{var X:i64=1;Y:=Attempt(Block{set X=9;Require[false];0},3);X+Y}\nV:i64=F()",
        "F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);7};set X=5;T.Await()+X}\nP:task(i64)=Spawn{F()}",
        "var M:i64=0\nF()<transacts>:i64=Block{var X:i64=1;R:=Fn()<transacts>:i64{Set(M,M+1)};R();set X=X+M;X}\nV:i64=F()",
        "F(N:i64)<transacts>:i64=Block{L:=N+1;R:=Fn()<computes>:i64{L*2};var X:i64=R();set X=X+1;G()<computes>:i64=L;X+G()}\nV:i64=F(3)",
    };
    for (sources) |source| {
        var texts: [2][]const u8 = undefined;
        var passes: [2]u32 = undefined;
        for ([_]bool{ true, false }, &texts, &passes, [_][]u8{ first, second }) |names, *text, *count, buffer| {
            h.front.share_names = names;
            const p = try h.compile(source);
            count.* = h.front.passes;
            try std.testing.expectEqual(@as(u32, 0), h.front.share_key_count);
            var out = std.Io.Writer.fixed(buffer);
            try std.testing.expect(try report_space.write(&out, p) == .ok);
            text.* = out.buffered();
        }
        h.front.share_names = true;
        try std.testing.expectEqualStrings(texts[1], texts[0]);
        try std.testing.expectEqual(passes[1], passes[0]);
    }
}

test "a program that gains a shared local takes one compile more, however many it gains" {
    const h = try harness.create();
    defer scratch.release(h);
    const sources = [_][]const u8{
        "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};set X=5;R()}\nV:i64=F()",
        "F()<transacts>:i64=Block{var X:i64=1;var Y:i64=2;var Z:i64=3;R:=Fn()<reads>:i64{X+Y};S:=Fn()<reads>:i64{Z+X};set X=5;R()+S()+Y+Z}\nV:i64=F()",
        "F()<transacts><suspends>:i64=Block{var X:i64=1;T:=Spawn{Sleep(1.0);X+1};U:=Spawn{Sleep(2.0);X+2};set X=5;T.Await()+U.Await()}\nP:task(i64)=Spawn{F()}",
        "F(Xs:[]i64)<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};For(K:Xs,Block{set X=X+K;Require[K>0];0});R()}\nV:i64=F(array{1,2})",
    };
    for (sources) |source| {
        h.front.share_names = false;
        _ = try h.compile(source);
        const before = h.front.passes;
        h.front.share_names = true;
        const p = try h.compile(source);
        try std.testing.expect(hasCell(p));
        if (h.front.passes != before + 1) std.debug.print("{d} passes against {d}: {s}\n", .{ h.front.passes, before, source });
        try std.testing.expectEqual(before + 1, h.front.passes);
    }
}

test "the migration list: the declarations only Q1 shares are the ones a closure names and nothing assigns" {
    const h = try harness.create();
    defer scratch.release(h);
    // A is named by an `Fn` and written by the code around it (meaning changes); B is assigned by an
    // `Fn` (shared before Q1); C is named by no closure; D is named by a task body and never written.
    const source = "F()<transacts><suspends>:i64=Block{\nvar A:i64=1\nvar B:i64=2\nvar C:i64=3\nvar D:i64=4\nR:=Fn()<reads>:i64{A}\nW:=Fn()<transacts>:i64{Set(B,B+1)}\nT:=Spawn{D+1}\nset A=A+10\nset C=C+1\nW()+R()+T.Await()+C}\nP:task(i64)=Spawn{F()}";
    h.front.share_names = false;
    _ = try h.compile(source);
    var before: [4]u32 = undefined;
    const before_count = h.front.share_key_count;
    for (h.front.share_keys[0..before_count], before[0..before_count]) |key, *offset| offset.* = key.offset;
    h.front.share_names = true;
    _ = try h.compile(source);
    const after_count = h.front.share_key_count;
    try std.testing.expectEqual(@as(u32, 1), before_count);
    try std.testing.expectEqual(@as(u32, 3), after_count);
    // Declarations are keyed by where their names stand; the list is what Q1 adds.
    var listed: [3][]const u8 = undefined;
    var listed_count: usize = 0;
    for (h.front.share_keys[0..after_count]) |key| {
        const known = for (before[0..before_count]) |offset| {
            if (offset == key.offset) break true;
        } else false;
        if (!known) {
            listed[listed_count] = source[key.offset..][0..1];
            listed_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), listed_count);
    try std.testing.expectEqualStrings("A", listed[0]);
    try std.testing.expectEqualStrings("D", listed[1]);
}

test "S6: a function whose closure reads a local var needs <reads>, in every form" {
    const h = try harness.create();
    defer scratch.release(h);
    // The program is plain: the closure only names X. Before Q1 these compiled; now the read of
    // the shared local is loud (V3).
    const refused = [_][]const u8{
        "F()<writes>:i64=Block{var X:i64=2;R:=Fn()<computes>:i64{X+1};R()}\nV:i64=F()",
        "F()<writes><allocates><suspends>:i64=Block{var X:i64=2;T:=Spawn{X+1};0}\nP:task(i64)=Spawn{F()}",
        "F()<writes><allocates><suspends>:i64=Block{var X:i64=2;R:=Sync(Block{Sleep(1.0);X},Block{Sleep(1.0);3});0}\nP:task(i64)=Spawn{F()}",
        "F()<writes>:i64=Block{var X:i64=2;B:i64=Batch{X+1};B}\nV:i64=F()",
    };
    for (refused) |source| {
        h.front.share_names = false;
        _ = try h.compile(source);
        h.front.share_names = true;
        switch (h.front.compile(source)) {
            .ok => {
                std.debug.print("compiled: {s}\n", .{source});
                return error.Compiled;
            },
            .failed => |d| {
                if (d.code != .local_read_requires_reads or !std.mem.eql(u8, source[d.span.start..d.span.end], "X")) {
                    std.debug.print("got {s} at '{s}': {s}\n", .{ @tagName(d.code), source[d.span.start..d.span.end], source });
                    return error.WrongDiagnostic;
                }
            },
        }
    }
    // With `<reads>` they compile and run.
    try std.testing.expectEqual(@as(i64, 3), try valueOf(h, "F()<reads><writes>:i64=Block{var X:i64=2;R:=Fn()<reads>:i64{X+1};R()}\nV:i64=F()", "V", false));
}

test "rollback: a region that fails restores a local a closure only names" {
    const h = try harness.create();
    defer scratch.release(h);
    // The closure sees the write made inside the region, and the restored value once it fails.
    const failing = "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};A:=Attempt(Block{set X=9;B:=R();Require[false];B},R());A*100+R()}\nV:i64=F()";
    try std.testing.expectEqual(@as(i64, 101), try valueOf(h, failing, "V", false));
    // And the committed write once it succeeds: 9 where the snapshot of the rules before Q1 read 1.
    const committed = "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};A:=Attempt(Block{set X=9;R()},0);A*100+R()}\nV:i64=F()";
    try std.testing.expectEqual(@as(i64, 909), try valueOf(h, committed, "V", false));
    h.front.share_names = false;
    try std.testing.expectEqual(@as(i64, 101), try valueOf(h, committed, "V", false));
    h.front.share_names = true;
    // A write by the closure itself inside a region that fails is undone as before.
    try std.testing.expectEqual(@as(i64, 1), try valueOf(h, "F()<transacts>:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};W:=Fn()<transacts>:i64{Set(X,50)};Attempt(Block{W();Require[false];0},0);R()}\nV:i64=F()", "V", false));
}

test "the rule holds at any depth, at the root, in generic functions and in methods" {
    const h = try harness.create();
    defer scratch.release(h);
    const Entry = struct { []const u8, i64, i64 };
    const entries = [_]Entry{
        // An `Fn` in an `Fn`: the inner one names the local through the outer one's capture.
        .{ "F()<transacts>:i64=Block{var X:i64=1;O:=Fn()<transacts>:i64{Block{I:=Fn()<reads>:i64{X};I()}};set X=9;O()}\nV:i64=F()", 9, 1 },
        // A closure in a task body, in a nested function, in an `Fn`.
        .{ "F()<transacts><suspends>:i64=Block{var X:i64=1;Get()<transacts><suspends>:i64=Block{T:=Spawn{Sleep(1.0);Fn()<reads>:i64{X}};R:=T.Await();R()};set X=4;Get()}\nP:task(i64)=Spawn{F()}", 4, 4 },
        // The root.
        .{ "V:i64=Block{var X:i64=1;R:=Fn()<reads>:i64{X};set X=5;R()}", 5, 1 },
        // A generic function compiled for two types notes the local once.
        .{ "G[T:type](Y:T)<transacts>:i64{Block{var L:i64=1;R:=Fn()<reads>:i64{L};set L=7;R()}}\nV:i64=G[i64](1)+G[string](\"a\")", 14, 2 },
        // A method.
        .{ "c:=class{ var N:i64 = 0\n  M()<transacts>:i64 = Block{ var X:i64 = 1; R:=Fn()<reads>:i64{X}; set X = Self.N + 5; R() } }\nV:i64 = c{N := 2}.M()", 7, 1 },
    };
    for (entries, 0..) |entry, index| {
        h.front.share_names = true;
        const task = std.mem.indexOf(u8, entry[0], "P:task") != null;
        const after = try valueOf(h, entry[0], if (task) "P" else "V", task);
        try std.testing.expect(hasCell(try h.compile(entry[0])));
        h.front.share_names = false;
        const before = try valueOf(h, entry[0], if (task) "P" else "V", task);
        h.front.share_names = true;
        if (after != entry[1] or before != entry[2]) std.debug.print("entry {d}: {d} after (expected {d}), {d} before (expected {d})\n", .{ index, after, entry[1], before, entry[2] });
        try std.testing.expectEqual(entry[1], after);
        try std.testing.expectEqual(entry[2], before);
    }
}

test "a label of the name before a use of it does not keep the closure on a snapshot (review)" {
    const h = try harness.create();
    defer scratch.release(h);
    const Entry = struct { []const u8, []const u8, bool, i64 };
    const entries = [_]Entry{
        .{ "G(X:i64)<computes>:i64 = X\nF()<transacts>:i64 = Block{ var X:i64 = 1; R := Fn()<reads>:i64{ G(X := 0) + X }; set X = 5; R() }\nV:i64 = F()", "V", false, 5 },
        .{ "G(X:i64)<computes>:i64 = X\nF()<transacts>:i64 = Block{ var X:i64 = 1; R := Fn()<reads>:i64{ X + G(X := 0) }; set X = 5; R() }\nV:i64 = F()", "V", false, 5 },
        .{ "p := struct{ X:i64 = 0 }\nF()<transacts>:i64 = Block{ var X:i64 = 1; R := Fn()<reads>:i64{ p{X := X}.X }; set X = 5; R() }\nV:i64 = F()", "V", false, 5 },
        .{ "G(X:i64)<computes>:i64 = X\nF()<transacts>:i64 = Block{ var X:i64 = 1; R := Fn()<reads>:i64{ G(X := X) }; set X = 5; R() }\nV:i64 = F()", "V", false, 5 },
        .{ "p := struct{ X:i64 = 0 }\nF()<transacts>:i64 = Block{ var X:i64 = 1; R := Fn()<reads>:i64{ WithField(p{}, X, X).X }; set X = 5; R() }\nV:i64 = F()", "V", false, 5 },
        .{ "p := struct{ X:i64 = 0 }\nF()<transacts><suspends>:i64 = Block{ var X:i64 = 1; T := Spawn{ Sleep(1.0); p{X := X}.X }; set X = 5; T.Await() }\nP:task(i64) = Spawn{ F() }", "P", true, 5 },
        .{ "G(X:i64)<computes>:i64 = X\nvar Out:i64 = 0\nvar W:i64 = 0\nF()<transacts><suspends>:i64 = Block{ var X:i64 = 1; U:task(i64) = Upon(W > 0, Set(Out, G(X := X))); set X = 7; set W = 1; Sleep(1.0); Out }\nP:task(i64) = Spawn{ F() }", "P", true, 7 },
    };
    for (entries, 0..) |entry, index| {
        const value = try valueOf(h, entry[0], entry[1], entry[2]);
        if (value != entry[3]) std.debug.print("entry {d}: {d}, expected {d}\n", .{ index, value, entry[3] });
        try std.testing.expectEqual(entry[3], value);
        try std.testing.expect(hasCell(try h.compile(entry[0])));
    }
    // And the read is loud in a function without `<reads>`, whatever stands before it.
    try refuses(h, "p := struct{ X:i64 = 0 }\nF()<writes>:i64 = Block{ var X:i64 = 1; R := Fn()<computes>:i64{ p{X := X}.X }; set X = 5; R() }\nV:i64 = F()", .local_read_requires_reads, "X");
}

test "a landing takes no cell for a local it only reads: the program around it needs nothing more (review)" {
    const h = try harness.create();
    defer scratch.release(h);
    // `F` has no closure; a `Sync` elsewhere makes its `Defer` a landing. The landing reads `N`
    // at its site, which is the value the cancellation would read: no cell, no `<reads>`.
    const source = "var M:i64 = 0\nF()<writes><suspends>:i64 = Block{ var N:i64 = 4; Defer{ set M = N * 10 }; Sleep(1.0); set N = 5; 0 }\nH()<transacts><suspends>:i64 = Block{ W := Sync(Block{ Sleep(1.0); 1 }, Block{ Sleep(1.0); 2 }); W(1) }\nP:task(i64) = Spawn{ F() }\nQ:task(i64) = Spawn{ H() }";
    const p = try h.compile(source);
    try std.testing.expect(!hasCell(p));
    const with = h.front.passes;
    h.front.share_names = false;
    _ = try h.compile(source);
    try std.testing.expectEqual(h.front.passes, with);
    h.front.share_names = true;
    // `M` is the program's first cell, written by the task after the root ended.
    try std.testing.expectEqual(@as(i64, 50), (try h.execute(source)).cells[0].value.integer);
}

test "an Fn with no effect at the root is <computes>, so one that names a local var is refused there" {
    const h = try harness.create();
    defer scratch.release(h);
    // The root's `Fn` without a specifier keeps `<computes>` (RFC-0079), and a shared local needs
    // `<reads>` (S6): what compiled as a snapshot is loud now (review); the specifier fixes it.
    try refuses(h, "V:i64 = Block{ var X:i64 = 1; R := Fn(){ X }; set X = 5; R() }", .local_read_requires_reads, "X");
    try std.testing.expectEqual(@as(i64, 5), try valueOf(h, "V:i64 = Block{ var X:i64 = 1; R := Fn()<reads>:i64{ X }; set X = 5; R() }", "V", false));
}
