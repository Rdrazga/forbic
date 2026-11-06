//! Module paths and folder modules (RFC-0093): a bundle given as a folder tree, whose folders are
//! modules made of their files, named by `/Domain/Path` in `import` and `using`.
const std = @import("std");
const scratch = @import("scratch.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");

const fuel = 1 << 20;

pub fn compileTree(h: *harness.Harness, root: []const u8, inputs: []const modules.Input) !types.Program {
    return switch (h.front.compileBundle(.{ .root = root, .modules = inputs })) {
        .ok => |ir| ir,
        .failed => |problem| {
            const where = problem.diagnostic.location(problem.source);
            std.debug.print("folder compile failed: {s}:{d}:{d}: {s}\n", .{ problem.path, where.line, where.column, problem.diagnostic.message() });
            return error.UnexpectedCompile;
        },
    };
}

/// Runs the tree on both machines, which the shared harness holds to the same values, cells,
/// failures and call witness, and whose reports it replays.
pub fn executeTree(h: *harness.Harness, root: []const u8, inputs: []const modules.Input) !evaluator.Execution {
    const result = try h.run(try compileTree(h, root, inputs), fuel);
    if (result == .failed) {
        std.debug.print("folder run failed: {s}\n", .{result.failed.message()});
        return error.UnexpectedFailure;
    }
    return result.ok;
}

/// The diagnostic of a tree that must not compile, located in its file.
pub fn rejectedTree(h: *harness.Harness, root: []const u8, inputs: []const modules.Input) !modules.LocatedDiagnostic {
    return switch (h.front.compileBundle(.{ .root = root, .modules = inputs })) {
        .ok => error.UnexpectedAdmission,
        .failed => |problem| problem,
    };
}

/// The tree is refused with `code`, in file `path` at the first occurrence of `text` in it.
fn expectRefused(h: *harness.Harness, root: []const u8, inputs: []const modules.Input, code: types.Diagnostic.Code, path: []const u8, text: []const u8) !void {
    const problem = rejectedTree(h, root, inputs) catch |err| {
        std.debug.print("folder tree admitted, expected {s}\n", .{@tagName(code)});
        return err;
    };
    if (problem.diagnostic.code != code or !std.mem.eql(u8, problem.path, path)) std.debug.print("folder diagnostic {s} in {s} at {d}\n", .{ @tagName(problem.diagnostic.code), problem.path, problem.diagnostic.span.start });
    try std.testing.expectEqual(code, problem.diagnostic.code);
    try std.testing.expectEqualStrings(path, problem.path);
    const source = for (inputs) |input| {
        if (std.mem.eql(u8, input.path, path)) break input.source;
    } else "";
    if (text.len == 0) {
        try std.testing.expectEqual(@as(u32, 0), problem.diagnostic.span.start);
        return;
    }
    const at = std.mem.indexOf(u8, source, text).?;
    try std.testing.expectEqualStrings(text, problem.diagnostic.span.text(problem.source));
    try std.testing.expectEqual(at, @as(usize, problem.diagnostic.span.start));
}

fn integer(execution: evaluator.Execution, name: []const u8) !i64 {
    const value = execution.get(name) orelse {
        std.debug.print("no binding {s}\n", .{name});
        return error.MissingBinding;
    };
    return value.integer;
}

test "a folder is a module of its files, named by its path in import and using" {
    const h = try harness.create();
    defer scratch.release(h);
    const tree = [_]modules.Input{
        .{ .path = "user@example.com/App/main.forb", .source = "Shapes := import{/user@example.com/App/Kit}\nusing{/user@example.com/Lib}\nArea<public>:i64 = Shapes.Area(3, 4) + Twice(5)\n" },
        .{ .path = "user@example.com/App/Kit/seed.forb", .source = "Area<public>(W:i64, H:i64)<computes>:i64 = W * H + Seed\n" },
        .{ .path = "user@example.com/App/Kit/base.forb", .source = "Seed:i64 = 1\n" },
        .{ .path = "user@example.com/Lib/twice.forb", .source = "Twice<public>(X:i64)<computes>:i64 = X * 2\n" },
    };
    const execution = try executeTree(h, "/user@example.com/App", &tree);
    try std.testing.expectEqual(@as(i64, 23), try integer(execution, "Area"));
}

const root_app = "/example.com/App";

test "a path reaches the modules a folder's files declare, by segments or by dots, with their access" {
    const h = try harness.create();
    defer scratch.release(h);
    const kit = "Geometry<public> := module{\n  Flat<public> := module{ Area<public>(W:i64, H:i64)<computes>:i64 = W * H }\n  Hidden := module{ Secret<public>:i64 = 99 }\n  Unit<public>:i64 = 1\n}\n";
    for ([_][]const u8{
        "using{/example.com/Kit/Geometry/Flat}\nArea2<public>:i64 = Area(2, 3)\n",
        "using{/example.com/Kit/Geometry.Flat}\nArea2<public>:i64 = Area(2, 3)\n",
        "using{/example.com/Kit/Geometry}\nArea2<public>:i64 = Flat.Area(2, 3) * Unit\n",
        "K := import{/example.com/Kit}\nusing{K.Geometry.Flat}\nArea2<public>:i64 = Area(2, 3)\n",
        "K := import{/example.com/Kit}\nArea2<public>:i64 = K.Geometry.Flat.Area(2, 3)\n",
    }) |main| {
        const tree = [_]modules.Input{
            .{ .path = "example.com/App/main.forb", .source = main },
            .{ .path = "example.com/Kit/shapes.forb", .source = kit },
        };
        try std.testing.expectEqual(@as(i64, 6), try integer(try executeTree(h, root_app, &tree), "Area2"));
    }
    const refusals = [_]struct { main: []const u8, code: types.Diagnostic.Code, at: []const u8 }{
        .{ .main = "using{/example.com/Kit/Geometry/Hidden}\nX:i64 = Secret\n", .code = .private_name, .at = "Hidden" },
        .{ .main = "using{/example.com/Kit/Geometry/Round}\nX:i64 = 1\n", .code = .unknown_name, .at = "Round" },
        .{ .main = "using{/example.com/Kit/Geometry.Round}\nX:i64 = 1\n", .code = .unknown_name, .at = "Round" },
        .{ .main = "K := import{/example.com/Kit/Geometry}\nX:i64 = 1\n", .code = .path_import_required, .at = "/example.com/Kit/Geometry" },
        .{ .main = "using{/example.com/Gone}\nX:i64 = 1\n", .code = .missing_module, .at = "/example.com/Gone" },
        .{ .main = "K := import{/example.com/Gone}\nX:i64 = 1\n", .code = .missing_module, .at = "/example.com/Gone" },
        .{ .main = "K := import{\"../Kit/shapes.forb\"}\nX:i64 = 1\n", .code = .path_import_required, .at = "\"../Kit/shapes.forb\"" },
        .{ .main = "using{/example.com/App}\nX:i64 = 1\n", .code = .module_cycle, .at = "/example.com/App" },
        .{ .main = "using{/Example.com/Kit}\nX:i64 = 1\n", .code = .missing_module, .at = "/Example.com/Kit" },
    };
    for (refusals) |case| {
        const tree = [_]modules.Input{
            .{ .path = "example.com/App/main.forb", .source = case.main },
            .{ .path = "example.com/Kit/shapes.forb", .source = kit },
        };
        try expectRefused(h, root_app, &tree, case.code, "example.com/App/main.forb", case.at);
    }
}

test "a folder module whose files use the forms of the library block compiles, its block after its last file" {
    const h = try harness.create();
    defer scratch.release(h);
    const tree = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "Doubled<public>:[]i64 = For(X:array{1, 2, 3}, X * 2)\n" },
        .{ .path = "example.com/App/b.forb", .source = "Sum(Xs:[]i64)<transacts>:i64 = Block{var S:i64 = 0; For(X:Xs, Block{set S = S + X; S}); S}\nTotal<public>:i64 = Sum(Doubled)\n" },
        .{ .path = "example.com/Lib/l.forb", .source = "Count<public>(Xs:[]i64)<computes>:i64 = For(X:Xs, X + 1).Length\n" },
        .{ .path = "example.com/App/c.forb", .source = "using{/example.com/Lib}\nN<public>:i64 = Count(Doubled)\n" },
    };
    const execution = try executeTree(h, root_app, &tree);
    try std.testing.expectEqual(@as(i64, 12), try integer(execution, "Total"));
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "N"));
    // A diagnostic in the last file of such a module is still located in that file.
    const problem = try rejectedTree(h, root_app, &.{
        tree[0],
        .{ .path = "example.com/App/b.forb", .source = "B:i64 = 1\nC:i64 = \"three\"\n" },
    });
    try std.testing.expectEqualStrings("example.com/App/b.forb", problem.path);
    try std.testing.expectEqual(@as(u32, 2), problem.diagnostic.location(problem.source).line);
}

test "the files of a folder share one namespace in the order of their names, whatever the inventory order" {
    const h = try harness.create();
    defer scratch.release(h);
    const tree = [_]modules.Input{
        .{ .path = "example.com/App/b.forb", .source = "Total<public>:i64 = Base + Shared.Half(Base)\n" },
        .{ .path = "example.com/App/a.forb", .source = "Shared := import{/example.com/Lib}\nBase:i64 = 10\n" },
        .{ .path = "example.com/Lib/half.forb", .source = "Half<public>(X:i64)<computes>:i64 = X - 5\n" },
    };
    const first = try compileTree(h, root_app, &tree);
    const text = try std.testing.allocator.dupe(u8, first.source);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(i64, 15), try integer(try executeTree(h, root_app, &tree), "Total"));
    const reversed = [_]modules.Input{ tree[2], tree[1], tree[0] };
    const second = try compileTree(h, root_app, &reversed);
    try std.testing.expectEqualStrings(text, second.source);
    try std.testing.expectEqual(@as(usize, 3), second.parts.len);
    try std.testing.expectEqualStrings("example.com/App/a.forb", second.parts[1].path.text(second.file_paths));
    try std.testing.expectEqualStrings("/example.com/App", second.modules[1].path.text(second.paths));
    // A name the earlier file declares is the folder's; a later file may not declare it again.
    const twice = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "Base:i64 = 10\n" },
        .{ .path = "example.com/App/b.forb", .source = "Base:i64 = 11\n" },
    };
    try expectRefused(h, root_app, &twice, .duplicate_name, "example.com/App/b.forb", "Base");
    // An alias is a name of the module too.
    const aliases = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "L := import{/example.com/Lib}\nA:i64 = 1\n" },
        .{ .path = "example.com/App/b.forb", .source = "L := import{/example.com/Lib}\nB<public>:i64 = L.Half(4)\n" },
        tree[2],
    };
    try expectRefused(h, root_app, &aliases, .duplicate_name, "example.com/App/b.forb", "L");
    // Imports start a file; one after a declaration is late.
    const late = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "A:i64 = 1\nL := import{/example.com/Lib}\n" },
        tree[2],
    };
    try expectRefused(h, root_app, &late, .late_import, "example.com/App/a.forb", "L");
    // A `using` holds to the end of its module, through the files after it.
    const used = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "using{/example.com/Lib}\nA:i64 = 1\n" },
        .{ .path = "example.com/App/b.forb", .source = "using{/example.com/Lib}\nB<public>:i64 = Half(8)\n" },
        .{ .path = "example.com/App/c.forb", .source = "C<public>:i64 = Half(14) + B\n" },
        tree[2],
    };
    try std.testing.expectEqual(@as(i64, 12), try integer(try executeTree(h, root_app, &used), "C"));
}

test "every refusal of a folder tree points at the file and the text it is about" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib: modules.Input = .{ .path = "example.com/Lib/l.forb", .source = "V<public>:i64 = 1\n" };
    // The inventory: a file at the top, a folder that is no name, a path twice, no root.
    try expectRefused(h, root_app, &.{ .{ .path = "main.forb", .source = "" }, lib }, .invalid_module_path, "main.forb", "");
    try expectRefused(h, root_app, &.{ .{ .path = "example.com/9x/a.forb", .source = "" }, lib }, .invalid_module_path, "example.com/9x/a.forb", "");
    try expectRefused(h, root_app, &.{ .{ .path = "-x/A/a.forb", .source = "" }, lib }, .invalid_module_path, "-x/A/a.forb", "");
    try expectRefused(h, root_app, &.{ lib, lib }, .duplicate_module, "example.com/Lib/l.forb", "");
    try expectRefused(h, root_app, &.{lib}, .missing_module, root_app, "");
    try expectRefused(h, "/example.com/App/", &.{lib}, .invalid_module_path, "/example.com/App/", "");
    // A cycle between two folders.
    try expectRefused(h, root_app, &.{
        .{ .path = "example.com/App/a.forb", .source = "using{/example.com/Lib}\nA:i64 = 1\n" },
        .{ .path = "example.com/Lib/l.forb", .source = "using{/example.com/App}\nV<public>:i64 = 1\n" },
    }, .module_cycle, "example.com/Lib/l.forb", "/example.com/App");
    // A module a file declares that a subfolder of its folder names.
    try expectRefused(h, root_app, &.{
        .{ .path = "example.com/App/a.forb", .source = "Kit := module{ V<public>:i64 = 1 }\nA:i64 = 1\n" },
        .{ .path = "example.com/App/Kit/k.forb", .source = "W<public>:i64 = 2\n" },
    }, .duplicate_name, "example.com/App/a.forb", "Kit");
    // A name another folder keeps to itself.
    try expectRefused(h, root_app, &.{
        .{ .path = "example.com/App/a.forb", .source = "L := import{/example.com/Lib}\nA:i64 = L.Hidden\n" },
        .{ .path = "example.com/Lib/l.forb", .source = "Hidden:i64 = 1\n" },
    }, .private_name, "example.com/App/a.forb", "L.Hidden");
    // A type error in the second file of a folder, at that file's line.
    const problem = try rejectedTree(h, root_app, &.{
        .{ .path = "example.com/App/a.forb", .source = "A:i64 = 1\n" },
        .{ .path = "example.com/App/b.forb", .source = "B:i64 = 2\nC:i64 = \"three\"\n" },
    });
    try std.testing.expectEqualStrings("example.com/App/b.forb", problem.path);
    try std.testing.expectEqual(@as(u32, 2), problem.diagnostic.location(problem.source).line);
    // A path in a single file, and in a bundle of files.
    switch (h.front.compile("using{/example.com/Lib}\nX:i64 = 1\n")) {
        .ok => return error.UnexpectedAdmission,
        .failed => |diagnostic| try std.testing.expectEqual(types.Diagnostic.Code.module_bundle_required, diagnostic.code),
    }
    const files = h.front.compileBundle(.{ .root = "main.forb", .modules = &.{.{ .path = "main.forb", .source = "X:i64 = 1\nusing{/example.com/Lib}\n" }} });
    try std.testing.expectEqual(types.Diagnostic.Code.folder_bundle_required, files.failed.diagnostic.code);
    try std.testing.expectEqualStrings("/example.com/Lib", files.failed.diagnostic.span.text(files.failed.source));
    const quoted = h.front.compileBundle(.{ .root = "main.forb", .modules = &.{.{ .path = "main.forb", .source = "L := import{/example.com/Lib}\nX:i64 = 1\n" }} });
    try std.testing.expectEqual(types.Diagnostic.Code.folder_bundle_required, quoted.failed.diagnostic.code);
}

test "a comment ends with its file, and a run's failure is located in its file" {
    const h = try harness.create();
    defer scratch.release(h);
    // An indented comment on the last line of a file does not take the next file's indented lines.
    const tree = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "A:i64 = 1\n<#> a note\n" },
        .{ .path = "example.com/App/b.forb", .source = "    B<public>:i64 = A + 1\n" },
    };
    try std.testing.expectEqual(@as(i64, 2), try integer(try executeTree(h, root_app, &tree), "B"));
    // A statement ends with its file: brackets a file opens it must close, as in a bundle of files.
    for ([_][2][]const u8{
        .{ "X<public>:i64 = (1 +", "2)\n" },
        .{ "M := module{\n  V<public>:i64 = 1\n", "}\nB:i64 = M.V\n" },
    }) |texts| {
        const problem = try rejectedTree(h, root_app, &.{
            .{ .path = "example.com/App/a.forb", .source = texts[0] },
            .{ .path = "example.com/App/b.forb", .source = texts[1] },
        });
        try std.testing.expectEqual(types.Diagnostic.Code.unmatched_parenthesis, problem.diagnostic.code);
        try std.testing.expectEqualStrings("example.com/App/a.forb", problem.path);
        try std.testing.expectEqual(@as(u32, @intCast(texts[0].len)), problem.diagnostic.span.start);
    }
    // A block comment that does not close in its file is refused there.
    try expectRefused(h, root_app, &.{
        .{ .path = "example.com/App/a.forb", .source = "A:i64 = 1\n<# open\n" },
        .{ .path = "example.com/App/b.forb", .source = "#>\nB:i64 = 2\n" },
    }, .unterminated_comment, "example.com/App/a.forb", "<#");
    const failing = [_]modules.Input{
        .{ .path = "example.com/App/a.forb", .source = "Zero:i64 = 0\n" },
        .{ .path = "example.com/App/b.forb", .source = "B:i64 = 1\nC<public>:i64 = 1 / Zero\n" },
    };
    const program = try compileTree(h, root_app, &failing);
    const result = try h.run(program, fuel);
    const located = modules.locateIn(program, result.failed, root_app);
    try std.testing.expectEqualStrings("example.com/App/b.forb", located.path);
    try std.testing.expectEqual(@as(u32, 2), located.diagnostic.location(located.source).line);
}

const forged_tree = [_]modules.Input{
    .{ .path = "example.com/Lib/l.forb", .source = "V<public>:i64 = 1\n" },
    .{ .path = "example.com/Kit/k.forb", .source = "W<public>:i64 = 2\n" },
    .{ .path = "example.com/Kit/Sub/s.forb", .source = "S<public>:i64 = 3\n" },
    .{ .path = "example.com/App/a.forb", .source = "K := import{/example.com/Kit}\nusing{/example.com/Lib}\nA:i64 = V + K.W\n" },
    .{ .path = "example.com/App/b.forb", .source = "using{/example.com/Kit/Sub}\nB<public>:i64 = A + S\n" },
};

test "both admissions refuse a folder tree's module, file and import tables when any entry is forged" {
    const h = try harness.create();
    defer scratch.release(h);
    const program = try compileTree(h, root_app, &forged_tree);
    try std.testing.expectEqual(@as(i64, 6), try integer(try executeTree(h, root_app, &forged_tree), "B"));
    // Modules come dependencies first: Kit, Lib, Kit/Sub, then App with its three imports.
    for ([_][]const u8{ "/example.com/Kit", "/example.com/Lib", "/example.com/Kit/Sub", "/example.com/App" }, program.modules) |path, module| try std.testing.expectEqualStrings(path, module.path.text(program.paths));
    try std.testing.expectEqual(@as(usize, 3), program.imports.len);
    try std.testing.expectEqual(@as(usize, 5), program.parts.len);
    const allocator = std.testing.allocator;
    const imports = try allocator.dupe(types.Import, program.imports);
    defer allocator.free(imports);
    const parts = try allocator.dupe(types.ModulePart, program.parts);
    defer allocator.free(parts);
    const paths = try allocator.dupe(u8, program.paths);
    defer allocator.free(paths);
    const file_paths = try allocator.dupe(u8, program.file_paths);
    defer allocator.free(file_paths);
    const modules_copy = try allocator.dupe(types.Module, program.modules);
    defer allocator.free(modules_copy);
    var forged = program;
    forged.imports = imports;
    forged.parts = parts;
    forged.paths = paths;
    forged.file_paths = file_paths;
    forged.modules = modules_copy;
    // The copies, unchanged, are admitted.
    _ = try h.run(forged, fuel);
    const Edit = enum {
        retarget,
        self_target,
        shorter_prefix,
        inside_literal,
        alias_elsewhere,
        alias_prefix,
        part_end,
        part_order,
        part_folder,
        no_parts,
        stray_files,
        twin_paths,
        relative_path,
        file_moved,
    };
    for (std.enums.values(Edit)) |edit| {
        @memcpy(imports, program.imports);
        @memcpy(parts, program.parts);
        @memcpy(paths, program.paths);
        @memcpy(file_paths, program.file_paths);
        @memcpy(modules_copy, program.modules);
        forged.parts = parts;
        forged.file_paths = file_paths;
        switch (edit) {
            // A `using` path names another module than the one it spells.
            .retarget => imports[1].target = 0,
            .self_target => imports[2].target = 3,
            // `/example.com/Kit/Sub` names the subfolder, not the module of `Kit`.
            .shorter_prefix => {
                imports[2].path.end = imports[2].path.start + @as(u32, "/example.com/Kit".len);
                imports[2].target = 0;
            },
            // A path that starts inside what is written, `/Lib` of `/example.com/Lib`.
            .inside_literal => {
                imports[1].path.start += @as(u32, "/example.com".len);
                imports[1].alias = .{ .start = imports[1].path.start, .end = imports[1].path.start };
            },
            .alias_elsewhere => imports[1].alias = .{ .start = imports[1].path.start - 1, .end = imports[1].path.start - 1 },
            // An alias's path is the whole of what is written.
            .alias_prefix => imports[0].path.end -= 1,
            .part_end => parts[3].source.end -= 1,
            // The files of App in the order of their names: `b` cannot come first.
            .part_order => {
                const at = std.mem.indexOf(u8, file_paths, "App/a.forb").? + 4;
                file_paths[at] = 'c';
            },
            .part_folder => {
                const at = std.mem.indexOf(u8, file_paths, "Lib/l.forb").?;
                file_paths[at + 2] = 'x';
            },
            .no_parts => {
                forged.parts = &.{};
                forged.file_paths = "";
            },
            .stray_files => forged.parts = parts[0..4],
            // Two modules of one path.
            .twin_paths => {
                const kit = program.modules[0].path;
                const lib = program.modules[1].path;
                @memcpy(paths[lib.start..lib.end], paths[kit.start..kit.end]);
            },
            .relative_path => paths[program.modules[1].path.start] = 'x',
            // A file of App said to be part of Kit/Sub.
            .file_moved => {
                parts[2].source.end = parts[3].source.end;
                parts[3] = parts[2];
            },
        }
        refusedByBoth(h, program, forged) catch |err| {
            std.debug.print("forged folder table admitted: {s}\n", .{@tagName(edit)});
            return err;
        };
    }
    // A bundle of files with a table of files: its modules are files, not folders.
    const files = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{.{ .path = "main.forb", .source = "X:i64 = 1\n" }} })) {
        .ok => |ir| ir,
        .failed => return error.UnexpectedCompile,
    };
    var with_parts = files;
    const fake = [_]types.ModulePart{.{ .path = .{ .start = 0, .end = 10 }, .source = files.modules[0].source }};
    with_parts.parts = &fake;
    with_parts.file_paths = "main.forb";
    try refusedByBoth(h, files, with_parts);
}

/// Both machines refuse the module tables of `forged`, each on its own: the reference
/// evaluator's admission, lowering, and the VM's admission of tables put on bytecode that was
/// lowered from `program`.
pub fn refusedByBoth(h: *harness.Harness, program: types.Program, forged: types.Program) !void {
    try std.testing.expect(evaluator.validate(forged, h.values.len) != null);
    try std.testing.expect(bytecode.lower(forged, &h.runtime.instructions) != .ok);
    var raw = bytecode.lower(program, &h.runtime.instructions).ok;
    raw.paths = forged.paths;
    raw.modules = forged.modules;
    raw.imports = forged.imports;
    raw.nested = forged.nested;
    raw.parts = forged.parts;
    raw.file_paths = forged.file_paths;
    try std.testing.expect(vm.verify(raw, &h.runtime.machine.register_types) == .failed);
}

test "a module path never means two modules: no folder is or lies below a nested module's path" {
    const h = try harness.create();
    defer scratch.release(h);
    const root = "/example.com/R";
    const nested: modules.Input = .{ .path = "example.com/A/x.forb", .source = "M<public> := module{ B<public> := module{ Q<public>:i64 = 1 } }\n" };
    // The import keeps `/example.com/A` in the program when a folder `/example.com/A/M` would
    // take the `using`.
    const user: modules.Input = .{ .path = "example.com/R/r.forb", .source = "L := import{/example.com/A}\nusing{/example.com/A/M.B}\nX<public>:i64 = Q\n" };
    // `/example.com/A/M/B` was the folder, `/example.com/A/M.B` the nested module (c1-1): a
    // folder added below a folder `/example.com/A/M` with no file of its own changed what an
    // existing `using` meant. Every folder below `M`'s path is refused, at `M`.
    for ([_][]const u8{ "example.com/A/M/B/y.forb", "example.com/A/M/B/C/y.forb", "example.com/A/M/Other/y.forb", "example.com/A/M/y.forb" }) |path| {
        try expectRefused(h, root, &.{ nested, .{ .path = path, .source = "Q<public>:i64 = 2\n" }, user }, .duplicate_name, "example.com/A/x.forb", "M");
    }
    // So where nothing else reaches `/example.com/A`: the path read the folder and gave 2, and
    // without the folder the nested module and 1. A folder the path passes through is checked
    // at the segment that follows it, whichever folder of the path it is.
    const plain: modules.Input = .{ .path = "example.com/R/r.forb", .source = "using{/example.com/A/M/B}\nX<public>:i64 = Q\n" };
    try expectRefused(h, root, &.{ nested, .{ .path = "example.com/A/M/B/y.forb", .source = "Q<public>:i64 = 2\n" }, plain }, .duplicate_name, "example.com/A/x.forb", "M");
    try std.testing.expectEqual(@as(i64, 1), try integer(try executeTree(h, root, &.{ nested, plain }), "X"));
    try expectRefused(h, root, &.{ .{ .path = "example.com/A/M/m.forb", .source = "B<public> := module{ Q<public>:i64 = 1 }\n" }, .{ .path = "example.com/A/M/B/y.forb", .source = "Q<public>:i64 = 2\n" }, plain }, .duplicate_name, "example.com/A/M/m.forb", "B");
    // A module of such a folder that the path does not name is no concern of the program's.
    const unrelated = try executeTree(h, root, &.{ .{ .path = "example.com/A/x.forb", .source = "K<public> := module{ Q<public>:i64 = 1 }\n" }, .{ .path = "example.com/A/K/Z/z.forb", .source = "W<public>:i64 = 0\n" }, .{ .path = "example.com/A/M/B/y.forb", .source = "Q<public>:i64 = 2\n" }, plain });
    try std.testing.expectEqual(@as(i64, 2), try integer(unrelated, "X"));
    // Its modules take no room of the program's: more than any program may nest, none `M`.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(std.testing.allocator);
    for (0..types.limits.modules + 6) |index| try many.print(std.testing.allocator, "N{d}<public> := module{{}}\n", .{index});
    const crowded = try executeTree(h, root, &.{ .{ .path = "example.com/A/x.forb", .source = many.items }, .{ .path = "example.com/A/M/B/y.forb", .source = "Q<public>:i64 = 2\n" }, plain });
    try std.testing.expectEqual(@as(i64, 2), try integer(crowded, "X"));
    // A folder whose path only begins with the same bytes is another module.
    const apart = try executeTree(h, root, &.{ nested, .{ .path = "example.com/A/M2/B/y.forb", .source = "Q<public>:i64 = 2\n" }, .{ .path = "example.com/A/MB/y.forb", .source = "Q<public>:i64 = 3\n" }, user });
    try std.testing.expectEqual(@as(i64, 1), try integer(apart, "X"));
    // A forged table cannot make one either: both admissions refuse a folder renamed to the
    // nested module's path, and admit the same rename to a path that is free.
    const tree = [_]modules.Input{
        nested,
        .{ .path = "example.com/A/N/B/y.forb", .source = "Q<public>:i64 = 2\n" },
        .{ .path = "example.com/R/r.forb", .source = "K := import{/example.com/A/N/B}\nusing{/example.com/A/M.B}\nX<public>:i64 = Q * 10 + K.Q\n" },
    };
    const program = try compileTree(h, root, &tree);
    try std.testing.expectEqual(@as(i64, 12), try integer(try executeTree(h, root, &tree), "X"));
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, program.source);
    defer allocator.free(source);
    const paths = try allocator.dupe(u8, program.paths);
    defer allocator.free(paths);
    const file_paths = try allocator.dupe(u8, program.file_paths);
    defer allocator.free(file_paths);
    for ([_]u8{ 'M', 'P' }) |letter| {
        for ([_][]u8{ source, paths, file_paths }) |text| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, text, at, "A/N/B")) |found| : (at = found + 1) text[found + 2] = letter;
        }
        var forged = program;
        forged.source = source;
        forged.paths = paths;
        forged.file_paths = file_paths;
        if (letter == 'M') {
            try refusedByBoth(h, program, forged);
        } else {
            try std.testing.expect(try h.run(forged, fuel) == .ok);
        }
        @memcpy(source, program.source);
        @memcpy(paths, program.paths);
        @memcpy(file_paths, program.file_paths);
    }
}

test "the package of a type in a folder tree is its module path, not `/` and the path again" {
    const h = try harness.create();
    defer scratch.release(h);
    // It was `//example.com/A` and `//example.com/A/M` (c1-4). A bundle of files and a single
    // file keep `/main.forb` and `/`.
    const tree = [_]modules.Input{
        .{ .path = "example.com/A/a.forb", .source = "p := struct<persistable>{X:i64 = 1}\nM<public> := module{ q<public> := struct<persistable>{Y:i64 = 2} }\nP<public>:string = ToJson(p{})\nQ<public>:string = ToJson(M.q{})\nBack<public>:i64 = Attempt(FromJson[p][P].X, -1)\nOld<public>:i64 = Attempt(FromJson[p][\"\\{\\\"$package_name\\\":\\\"//example.com/A\\\",\\\"x_X\\\":7\\}\"].X, -1)\n" },
    };
    const execution = try executeTree(h, "/example.com/A", &tree);
    try std.testing.expectEqualStrings("{\"$package_name\":\"/example.com/A\",\"$class_name\":\"p\",\"x_X\":1}", execution.get("P").?.string);
    try std.testing.expectEqualStrings("{\"$package_name\":\"/example.com/A/M\",\"$class_name\":\"q\",\"x_Y\":2}", execution.get("Q").?.string);
    try std.testing.expectEqual(@as(i64, 1), try integer(execution, "Back"));
    try std.testing.expectEqual(@as(i64, -1), try integer(execution, "Old"));
    const files = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{.{ .path = "main.forb", .source = "p := struct<persistable>{X:i64 = 1}\nP<public>:string = ToJson(p{})\n" }} })) {
        .ok => |ir| ir,
        .failed => return error.UnexpectedCompile,
    };
    const bundled = try h.run(files, fuel);
    try std.testing.expectEqualStrings("{\"$package_name\":\"/main.forb\",\"$class_name\":\"p\",\"x_X\":1}", bundled.ok.get("P").?.string);
    const single = try h.execute("p := struct<persistable>{X:i64 = 1}\nP<public>:string = ToJson(p{})\n");
    try std.testing.expectEqualStrings("{\"$package_name\":\"/\",\"$class_name\":\"p\",\"x_X\":1}", single.get("P").?.string);
}

test "the capacities of a folder tree are exact: its files, its modules and a written path" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var names: [types.limits.module_files + 1][40]u8 = undefined;
    var inputs: [types.limits.module_files + 1]modules.Input = undefined;
    // As many files as a tree may have, in one folder: one module.
    for (&inputs, &names, 0..) |*input, *name, index| input.* = .{ .path = try std.fmt.bufPrint(name, "example.com/App/f{d:0>3}.forb", .{index}), .source = "" };
    inputs[0].source = "A<public>:i64 = 1\n";
    const program = try compileTree(h, root_app, inputs[0..types.limits.module_files]);
    try std.testing.expectEqual(@as(usize, types.limits.module_files), program.parts.len);
    try expectRefused(h, root_app, inputs[0 .. types.limits.module_files + 1], .module_limit, root_app, "");
    // As many folders as a tree may have modules, each a module of one file; one more is refused
    // (here also one file more than a tree may have, so the refusal is the inventory's).
    for (inputs[0 .. types.limits.modules + 1], names[0 .. types.limits.modules + 1], 0..) |*input, *name, index| input.* = .{ .path = try std.fmt.bufPrint(name, "example.com/M{d:0>3}/f.forb", .{index}), .source = "A<public>:i64 = 1\n" };
    _ = try compileTree(h, "/example.com/M000", inputs[0..types.limits.modules]);
    try expectRefused(h, "/example.com/M000", inputs[0 .. types.limits.modules + 1], .module_limit, "/example.com/M000", "");
    // A written path longer than a path may be.
    var long: [types.limits.module_path_bytes + 64]u8 = undefined;
    var out = std.Io.Writer.fixed(&long);
    try out.writeAll("using{/example.com");
    while (out.end < types.limits.module_path_bytes + 6) try out.writeAll("/Abcdefgh");
    try out.writeAll("}\n");
    const written = out.buffered();
    try expectRefused(h, root_app, &.{.{ .path = "example.com/App/a.forb", .source = written }}, .invalid_module_path, "example.com/App/a.forb", written[6 .. written.len - 2]);
}
