//! A randomized oracle for folder modules and module paths (RFC-0093): generated folder trees,
//! whose folders hold files of values that name each other, their own folder's, and those of
//! the folders they import or are `using`, are held to a model of the rules written over the
//! generated tree itself: a folder is one namespace in the order of its files; another folder's
//! names are reached only through a stated path, public names only; a module declared in a file
//! is reached through its folder and its own access. Accepted trees run on both machines, and a
//! shuffled inventory compiles to the same program.
const std = @import("std");
const scratch = @import("scratch.zig");
const modules = @import("modules.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const paths = @import("module_path_tests.zig");

const max_folders = 6;
const max_files = 3;
const max_values = 2;
const text_bytes = 1024;

const Use = enum { none, using, alias };
const Reference = union(enum) {
    none,
    /// A value of the same folder, by file, ordinal.
    own: struct { file: u8, value: u8 },
    /// A public value of a folder imported or in `using`.
    other: struct { folder: u8, file: u8, value: u8 },
    /// The value of a folder's nested module.
    nested: u8,
};
const Value = struct { public: bool, constant: i64, reference: Reference = .none, model: i64 = 0 };
const Folder = struct {
    path: [64]u8 = undefined,
    path_len: usize = 0,
    files: u8 = 1,
    uses: [max_folders]Use = @splat(.none),
    /// Null: the folder's first file declares no module.
    nested_public: ?bool = null,
    nested_value: i64 = 0,
    values: [max_files][max_values]Value = undefined,
    counts: [max_files]u8 = @splat(0),

    fn name(self: *const Folder) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// The one reference of the root folder that the model says is refused, and how.
const Bad = enum { later_own, internal_using, internal_alias, private_nested_alias, private_nested_using, unstated, missing_path };

const Tree = struct {
    folders: [max_folders]Folder = undefined,
    count: usize = 0,
    bad: ?Bad = null,
    /// Where the root's bad reference stands: its file and the value it initialises.
    bad_file: u8 = 0,
    bad_target: u8 = 0,
};

fn generate(random: std.Random, tree: *Tree) void {
    tree.* = .{};
    tree.count = random.intRangeAtMost(usize, 2, max_folders);
    // The domain folder itself is a module in some trees, so a path must find the longest one.
    const domain_module = random.boolean();
    for (0..tree.count) |k| {
        const folder = &tree.folders[k];
        folder.* = .{};
        var out = std.Io.Writer.fixed(&folder.path);
        if (k == 0 and domain_module) {
            out.writeAll("/d.org") catch unreachable;
        } else {
            // Under the domain, or under an earlier folder (never the root, which is last).
            const parent = random.uintLessThan(usize, k + 1);
            if (parent == k or tree.folders[parent].path_len > 40) out.print("/d.org/F{d}", .{k}) catch unreachable else out.print("{s}/F{d}", .{ tree.folders[parent].name(), k }) catch unreachable;
        }
        folder.path_len = out.end;
        folder.files = random.intRangeAtMost(u8, 1, max_files);
        if (random.uintLessThan(u8, 3) == 0) folder.nested_public = random.boolean();
        folder.nested_value = random.intRangeAtMost(i64, 1, 50);
        for (0..k) |m| folder.uses[m] = switch (random.uintLessThan(u8, 3)) {
            0 => .none,
            1 => .using,
            else => .alias,
        };
        for (0..folder.files) |file| {
            folder.counts[file] = random.intRangeAtMost(u8, 1, max_values);
            for (0..folder.counts[file]) |ordinal| {
                var value: Value = .{ .public = random.boolean(), .constant = random.intRangeAtMost(i64, 1, 100) };
                value.reference = pick(random, tree, k, @intCast(file), @intCast(ordinal));
                value.model = value.constant + modelOf(tree, k, value.reference);
                folder.values[file][ordinal] = value;
            }
        }
    }
    // The root folder may have one reference the rules refuse.
    if (random.boolean()) plant(random, tree);
}

/// A reference the rules admit, for value `ordinal` of `file` in folder `k`.
fn pick(random: std.Random, tree: *const Tree, k: usize, file: u8, ordinal: u8) Reference {
    const folder = &tree.folders[k];
    switch (random.uintLessThan(u8, 4)) {
        0 => {
            // An earlier value of this folder, in an earlier file or earlier in this one.
            if (file == 0 and ordinal == 0) return .none;
            const at = random.uintAtMost(u8, file);
            const limit = if (at == file) ordinal else folder.counts[at];
            if (limit == 0) return .none;
            return .{ .own = .{ .file = at, .value = random.uintLessThan(u8, limit) } };
        },
        1, 2 => {
            const m = random.uintLessThan(usize, max_folders);
            if (m >= k or folder.uses[m] == .none) return .none;
            const other = &tree.folders[m];
            const at = random.uintLessThan(u8, other.files);
            const index = random.uintLessThan(u8, other.counts[at]);
            if (!other.values[at][index].public) return .none;
            return .{ .other = .{ .folder = @intCast(m), .file = at, .value = index } };
        },
        else => {
            const m = random.uintLessThan(usize, max_folders);
            if (m >= k or folder.uses[m] == .none) return .none;
            if (tree.folders[m].nested_public != true) return .none;
            return .{ .nested = @intCast(m) };
        },
    }
}

fn modelOf(tree: *const Tree, k: usize, reference: Reference) i64 {
    return switch (reference) {
        .none => 0,
        .own => |own| tree.folders[k].values[own.file][own.value].model,
        .other => |other| tree.folders[other.folder].values[other.file][other.value].model,
        .nested => |m| tree.folders[m].nested_value,
    };
}

/// Puts one refused reference in the root folder, if the tree has what it needs.
fn plant(random: std.Random, tree: *Tree) void {
    const root = tree.count - 1;
    const bad: Bad = @fromBackingInt(@intCast(random.uintLessThan(u8, std.enums.values(Bad).len)));
    const needs = switch (bad) {
        .later_own => tree.folders[root].files > 1,
        .internal_using, .internal_alias => internalOf(tree, if (bad == .internal_using) .using else .alias) != null,
        .private_nested_alias, .private_nested_using => privateNestedOf(tree, if (bad == .private_nested_using) .using else .alias) != null,
        .unstated => unstatedOf(tree) != null,
        .missing_path => true,
    };
    if (!needs) return;
    tree.bad = bad;
    // The first file's first value, so the bad reference is the first thing the root refuses.
    tree.bad_file = 0;
    tree.bad_target = 0;
}

fn internalOf(tree: *const Tree, style: Use) ?struct { folder: u8, file: u8, value: u8 } {
    const root = &tree.folders[tree.count - 1];
    for (0..tree.count - 1) |m| {
        if (root.uses[m] != style) continue;
        const other = &tree.folders[m];
        for (0..other.files) |file| for (0..other.counts[file]) |index| {
            if (!other.values[file][index].public) return .{ .folder = @intCast(m), .file = @intCast(file), .value = @intCast(index) };
        };
    }
    return null;
}
fn privateNestedOf(tree: *const Tree, style: Use) ?u8 {
    const root = &tree.folders[tree.count - 1];
    for (0..tree.count - 1) |m| if (root.uses[m] == style and tree.folders[m].nested_public == false) return @intCast(m);
    return null;
}
fn unstatedOf(tree: *const Tree) ?struct { folder: u8, file: u8, value: u8 } {
    const root = &tree.folders[tree.count - 1];
    for (0..tree.count - 1) |m| {
        if (root.uses[m] != .none) continue;
        return .{ .folder = @intCast(m), .file = 0, .value = 0 };
    }
    return null;
}

fn expectedCode(tree: *const Tree, bad: Bad) types.Diagnostic.Code {
    return switch (bad) {
        .later_own, .internal_using, .private_nested_using, .unstated => .unknown_name,
        .internal_alias, .private_nested_alias => .private_name,
        // Where the domain is a module, `/d.org/Nowhere` is the module `Nowhere` it does not declare.
        .missing_path => if (std.mem.eql(u8, tree.folders[0].name(), "/d.org")) .unknown_name else .missing_module,
    };
}

fn valueName(out: *std.Io.Writer, folder: usize, file: usize, value: usize) !void {
    try out.print("V{d}x{d}x{d}", .{ folder, file, value });
}

fn writeReference(out: *std.Io.Writer, tree: *const Tree, k: usize, reference: Reference) !void {
    switch (reference) {
        .none => {},
        .own => |own| {
            try out.writeAll(" + ");
            try valueName(out, k, own.file, own.value);
        },
        .other => |other| {
            try out.writeAll(" + ");
            if (tree.folders[k].uses[other.folder] == .alias) try out.print("D{d}.", .{other.folder});
            try valueName(out, other.folder, other.file, other.value);
        },
        .nested => |m| {
            try out.writeAll(" + ");
            if (tree.folders[k].uses[m] == .alias) try out.print("D{d}.", .{m});
            try out.print("N{d}.X{d}", .{ m, m });
        },
    }
}

fn writeBad(out: *std.Io.Writer, tree: *const Tree) !void {
    const root = tree.count - 1;
    try out.writeAll(" + ");
    switch (tree.bad.?) {
        .later_own => try valueName(out, root, 1, 0),
        .internal_using, .internal_alias => {
            const found = internalOf(tree, if (tree.bad.? == .internal_using) .using else .alias).?;
            if (tree.bad.? == .internal_alias) try out.print("D{d}.", .{found.folder});
            try valueName(out, found.folder, found.file, found.value);
        },
        .private_nested_alias => {
            const m = privateNestedOf(tree, .alias).?;
            try out.print("D{d}.N{d}.X{d}", .{ m, m, m });
        },
        .private_nested_using => {
            const m = privateNestedOf(tree, .using).?;
            try out.print("N{d}.X{d}", .{ m, m });
        },
        .unstated => {
            const found = unstatedOf(tree).?;
            try valueName(out, found.folder, found.file, found.value);
        },
        .missing_path => try out.writeAll("0"),
    }
}

/// The text of file `file` of folder `k`.
fn writeFile(out: *std.Io.Writer, tree: *const Tree, k: usize, file: usize) !void {
    const folder = &tree.folders[k];
    const root = k == tree.count - 1;
    if (file == 0) {
        // Imports start the file; `using` follows them and holds for the folder's later files.
        for (0..k) |m| if (folder.uses[m] == .alias) try out.print("D{d} := import{{{s}}}\n", .{ m, tree.folders[m].name() });
        for (0..k) |m| if (folder.uses[m] == .using) try out.print("using{{{s}}}\n", .{tree.folders[m].name()});
        if (root and tree.bad == .missing_path) try out.writeAll("using{/d.org/Nowhere}\n");
        if (folder.nested_public) |public| try out.print("N{d}{s} := module{{ X{d}<public>:i64 = {d} }}\n", .{ k, if (public) "<public>" else "", k, folder.nested_value });
    }
    for (0..folder.counts[file]) |ordinal| {
        const value = folder.values[file][ordinal];
        try valueName(out, k, file, ordinal);
        try out.print("{s}:i64 = {d}", .{ if (value.public) "<public>" else "", value.constant });
        try writeReference(out, tree, k, value.reference);
        if (root and tree.bad != null and file == tree.bad_file and ordinal == tree.bad_target) try writeBad(out, tree);
        try out.writeByte('\n');
    }
}

test "folder trees agree with a model of module paths, in the compiler and on both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0xb7_0093);
    const random = prng.random();
    var tree: Tree = .{};
    var texts: [max_folders * max_files + 1][text_bytes]u8 = undefined;
    var names: [max_folders * max_files + 1][96]u8 = undefined;
    var inputs: [max_folders * max_files + 1]modules.Input = undefined;
    var admitted: usize = 0;
    var refused: usize = 0;
    for (0..400) |_| {
        generate(random, &tree);
        var count: usize = 0;
        for (0..tree.count) |k| for (0..tree.folders[k].files) |file| {
            var out = std.Io.Writer.fixed(&texts[count]);
            try writeFile(&out, &tree, k, file);
            var name = std.Io.Writer.fixed(&names[count]);
            try name.print("{s}/f{d}.forb", .{ tree.folders[k].name()[1..], file });
            inputs[count] = .{ .path = name.buffered(), .source = out.buffered() };
            count += 1;
        };
        // A folder nothing imports is joined but never read: its text does not matter.
        if (random.boolean()) {
            var name = std.Io.Writer.fixed(&names[count]);
            try name.writeAll("d.org/Unused/u.forb");
            inputs[count] = .{ .path = name.buffered(), .source = "X := (" };
            count += 1;
        }
        random.shuffle(modules.Input, inputs[0..count]);
        const root_path = tree.folders[tree.count - 1].name();
        const result = h.front.compileBundle(.{ .root = root_path, .modules = inputs[0..count] });
        if (tree.bad) |bad| {
            if (result == .ok or result.failed.diagnostic.code != expectedCode(&tree, bad)) {
                std.debug.print("folder tree refusal differs from the model: {s}, expected {s}, got {s}\n", .{ @tagName(bad), @tagName(expectedCode(&tree, bad)), if (result == .ok) "admission" else @tagName(result.failed.diagnostic.code) });
                for (inputs[0..count]) |input| std.debug.print("--- {s}\n{s}", .{ input.path, input.source });
                return error.ModelDisagrees;
            }
            refused += 1;
            continue;
        }
        if (result == .failed) {
            const where = result.failed.diagnostic.location(result.failed.source);
            std.debug.print("folder tree refused: {s}:{d}:{d}: {s}\n", .{ result.failed.path, where.line, where.column, result.failed.diagnostic.message() });
            for (inputs[0..count]) |input| std.debug.print("--- {s}\n{s}", .{ input.path, input.source });
            return error.ModelDisagrees;
        }
        const source = try std.testing.allocator.dupe(u8, result.ok.source);
        defer std.testing.allocator.free(source);
        const execution = try paths.executeTree(h, root_path, inputs[0..count]);
        const root = &tree.folders[tree.count - 1];
        for (0..root.files) |file| for (0..root.counts[file]) |ordinal| {
            var name_buffer: [32]u8 = undefined;
            var name = std.Io.Writer.fixed(&name_buffer);
            try valueName(&name, tree.count - 1, file, ordinal);
            const got = execution.get(name.buffered()) orelse return error.MissingBinding;
            try std.testing.expectEqual(root.values[file][ordinal].model, got.integer);
        };
        // The inventory's order is not the program's.
        std.mem.reverse(modules.Input, inputs[0..count]);
        const again = try paths.compileTree(h, root_path, inputs[0..count]);
        try std.testing.expectEqualStrings(source, again.source);
        admitted += 1;
    }
    // Both kinds of tree are met often.
    try std.testing.expect(admitted > 100 and refused > 50);
}
