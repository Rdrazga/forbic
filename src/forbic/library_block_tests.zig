//! What a module's library block holds (`macros.zig`): the fixed templates, and the lines of
//! each form only where a module uses that form. A block's length is room a program near the
//! source limit depends on, and the places of its `Fn` words are printed by inspections, so
//! both are pinned here for one module of every kind.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const macros = @import("macros.zig");
const harness = @import("generic_function_tests.zig");

const values = "Xs:[]i64=array{1,2,3}\n";
const classic = "A<public>:[]i64=For(X:Xs,X>1,X+1)\n";
const general = "B<public>:[]i64=For(X:Xs,Y:Xs,Z:Xs,X<Y,Y<Z,X*100+Y*10+Z)\n";
const pattern = "Half(M:option(i64))<computes>:i64=Case(M,option{V} where V>1=>V,option{_}=>1,option{}=>0)\nC<public>:i64=Half(option{7})\n";
const first = "D<public>:i64=Attempt(First[X:Xs,Y:Xs,X+Y>4,X*10+Y],0)\n";
const exits = "Find(T:i64)<transacts>:i64=Block{var I:i64=0;Loop{If(I>=T,Break(),false);set I=I+1};I}\nE<public>:i64=Find(4)\n";

/// The block of `source`, compiled alone: its extension, its length and how many compiles it took.
fn expectBlock(h: *harness.Harness, source: []const u8, calls: usize, extension: ?macros.Extension, passes: u32) !types.Program {
    const program = try h.compile(source);
    const got = h.front.library_extension[0];
    if (passes != h.front.passes or (extension != null and !std.meta.eql(extension.?, got))) std.debug.print("block of {s}: passes={d} words={d} temporaries={d} numerals={} first={} exits={} loops={} cases={}\n", .{ source, h.front.passes, got.words, got.temporaries, got.numerals, got.first, got.exits, got.loops, got.cases });
    try std.testing.expectEqual(passes, h.front.passes);
    try std.testing.expectEqual(calls, macros.callCount(source));
    const wanted = extension orelse {
        // No block at all: the program is its own text.
        try std.testing.expectEqual(source.len, program.source.len);
        return program;
    };
    try std.testing.expectEqualDeep(wanted, h.front.library_extension[0]);
    try std.testing.expectEqual(source.len + macros.libraryLength(calls, wanted), program.source.len);
    var block: [16384]u8 = undefined;
    macros.writeLibrary(&block, calls, wanted);
    try std.testing.expectEqualStrings(block[0..macros.libraryLength(calls, wanted)], program.source[source.len..]);
    return program;
}

/// Where the functions of `program` that are named by a generated `Fn` word are named,
/// relative to the first template line of the block that follows `source`, in ascending order.
fn expectWords(program: types.Program, source: []const u8, calls: usize, expected: []const u32) !void {
    const start: u32 = @intCast(source.len + macros.templatesOffset(calls));
    var places: [64]u32 = undefined;
    var found: usize = 0;
    for (program.functions) |function| {
        if (function.name.start < start) continue;
        try std.testing.expectEqualStrings("Fn", program.source[function.name.start..][0..2]);
        places[found] = function.name.start - start;
        found += 1;
    }
    std.mem.sort(u32, places[0..found], {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, expected, places[0..found]);
}

test "each kind of module carries the fixed templates and the lines of the forms it uses" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // The fixed lines are those of before RFC-0064: 2,207 bytes and nine per counted call.
    const fixed = macros.templates_length;
    try std.testing.expectEqual(@as(usize, 2207), macros.libraryLength(0, .{}));
    // No macro: no block.
    _ = try expectBlock(h, values ++ "A<public>:i64=Xs.Length\n", 0, null, 1);
    // The forms of RFC-0056: the fixed block, in one compile.
    var program = try expectBlock(h, values ++ classic, 1, .{}, 1);
    try std.testing.expectEqual(@as(usize, 2216), program.source.len - (values ++ classic).len);
    try expectWords(program, values ++ classic, 1, &.{});
    // A general `For`: its five templates, asked for once, then the words its pool lacks.
    program = try expectBlock(h, values ++ general, 1, .{ .loops = true, .words = 13 }, 3);
    try expectWords(program, values ++ general, 1, &.{ fixed + 842, fixed + 845, fixed + 848 });
    // A pattern `Case` alone: a block with the one line of its words, asked for with the block.
    program = try expectBlock(h, pattern, 0, .{ .cases = true }, 2);
    try std.testing.expectEqual(@as(usize, 2207 + macros.case_text.len + 2), program.source.len - pattern.len);
    // `First` alone: its templates and words at the end of the fixed block.
    program = try expectBlock(h, values ++ first, 0, .{ .first = true, .words = 8 }, 3);
    try expectWords(program, values ++ first, 0, &.{ fixed + 1, fixed + 4, fixed + 7, fixed + 10 });
    // The early-exit forms alone: the line of their words.
    program = try expectBlock(h, exits, 1, .{ .exits = true }, 2);
    try std.testing.expectEqual(@as(usize, 2216 + macros.exit_words.len + 2), program.source.len - exits.len);
    // The classic `For` beside each of them keeps its three pooled words and adds no line.
    _ = try expectBlock(h, values ++ classic ++ pattern, 1, .{ .cases = true }, 2);
    _ = try expectBlock(h, values ++ classic ++ exits, 2, .{ .exits = true }, 2);
}

test "a module that uses every form has every line, in a bounded number of compiles" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const all = values ++ classic ++ general ++ pattern ++ first ++ exits;
    const program = try expectBlock(h, all, 3, .{ .loops = true, .cases = true, .first = true, .exits = true, .words = 27 }, 5);
    const x = (try h.run(program, 1 << 20)).ok;
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("A").?).?.len);
    try std.testing.expectEqual(@as(usize, 1), x.elements(x.get("B").?).?.len);
    try std.testing.expectEqual(@as(i64, 7), x.get("C").?.integer);
    try std.testing.expectEqual(@as(i64, 23), x.get("D").?.integer);
    try std.testing.expectEqual(@as(i64, 4), x.get("E").?.integer);
    // The lines stand in this order, whatever order the forms are met in.
    const block = program.source[all.len..];
    const order = [_][]const u8{ macros.text[macros.text.len - 1], macros.for_text[0], macros.case_text, "#Fn Fn ", macros.first_text[0], macros.exit_words, "\n#}" };
    var at: usize = macros.templatesOffset(3);
    for (order) |piece| {
        const next = std.mem.indexOfPos(u8, block, at, piece) orelse return error.TestUnexpectedResult;
        at = next + piece.len;
    }
    try std.testing.expectEqual(block.len, at);
}

test "in a bundle each module gets the lines of its own forms and no other" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "main.forb", .source = "L:=import{\"loops.forb\"}\nP:=import{\"pick.forb\"}\nQ:=import{\"plain.forb\"}\nA<public>:i64=L.Sum()+P.Half(option{8})+Q.Count()" },
        .{ .path = "loops.forb", .source = "Xs:[]i64=array{1,2,3}\nSum<public>()<computes>:i64=For(X:Xs,Y:X..3,X*Y).Length" },
        .{ .path = "pick.forb", .source = "Half<public>(M:option(i64))<computes>:i64=Case(M,option{V} where V>1=>V,option{_}=>1,option{}=>0)" },
        .{ .path = "plain.forb", .source = "Xs:[]i64=array{4,5}\nCount<public>()<computes>:i64=For(X:Xs,X).Length" },
    };
    const program = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs })) {
        .ok => |program| program,
        .failed => |problem| {
            std.debug.print("bundle: {s}:{d}: {s}\n", .{ problem.path, problem.diagnostic.span.start, problem.diagnostic.message() });
            return error.Compile;
        },
    };
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, program.source, "#" ++ macros.for_text[0] ++ "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, program.source, "#" ++ macros.case_text ++ "\n"));
    // `main` has no macro and no block; the other three have one each.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, program.source, "\n#}"));
    var total: usize = 0;
    for (inputs) |input| total += input.source.len;
    // The modules are joined by a newline each.
    try std.testing.expectEqual(total + inputs.len - 1 + macros.libraryLength(1, .{ .loops = true, .words = 7 }) + macros.libraryLength(0, .{ .cases = true }) + macros.libraryLength(1, .{}), program.source.len);
    // The block, then the general templates for `loops`; the `Case` words come with the block
    // of `pick`: one compile per request and no more.
    try std.testing.expect(h.front.passes <= 4);
    const x = (try h.run(program, 1 << 20)).ok;
    // Six pairs, and 8, and 2.
    try std.testing.expectEqual(@as(i64, 16), x.get("A").?.integer);
}

test "a For sent to the general lowering by what its body does gets the templates with that retry" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // The index needs a failure context, which only the general lowering gives: the compile
    // that finds this out is the one that would have asked for the templates.
    const source = values ++ "A<public>:[]i64=For(X:Xs,Xs[X])\n";
    const program = try expectBlock(h, source, 1, .{ .loops = true }, 2);
    const x = (try h.run(program, 1 << 20)).ok;
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("A").?).?.len);
}

test "a program that fills the source limit beside the smaller block compiles" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    // The room the general `For` templates and the `Case` words took from every module with a
    // macro belongs to the program again.
    const head = values ++ classic ++ "#";
    const room = types.limits.source_bytes - head.len - macros.libraryLength(1, .{});
    const buffer = try std.testing.allocator.alloc(u8, types.limits.source_bytes + 1);
    defer std.testing.allocator.free(buffer);
    @memcpy(buffer[0..head.len], head);
    @memset(buffer[head.len..], 'c');
    const x = (try h.run(try h.compile(buffer[0 .. head.len + room]), 131072)).ok;
    try std.testing.expectEqual(@as(usize, 2), x.elements(x.get("A").?).?.len);
    try std.testing.expect(h.front.compile(buffer[0 .. head.len + room + 1]) == .failed);
    try std.testing.expectEqual(@as(usize, 960), macros.libraryLength(1, .{ .loops = true, .cases = true }) - macros.libraryLength(1, .{}));
}
