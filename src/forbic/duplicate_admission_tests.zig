//! Both admissions find duplicate declarations through a hash index instead of comparing every
//! pair. These forgeries declare one name twice in each way the IR allows, with the name alone
//! in its slot of the index and with a different name already occupying that slot, so a probe
//! that stops early or skips a neighbour shows up as an admitted duplicate. Each forgery has a
//! control that changes the same field without creating a duplicate and must still be admitted.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
const name_index = @import("name_index.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");

fn admitted(h: *harness.Harness, p: types.Program) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    if (reference == .failed) std.debug.print("reference rejected a control: {s}\n", .{reference.failed.message()});
    try std.testing.expect(reference == .ok);
    const actual = h.runtime.machine.run(bytecode.lower(p, &h.runtime.instructions).ok, 100_000);
    if (actual == .failed) std.debug.print("vm rejected a control: {s}\n", .{actual.failed.message()});
    try std.testing.expect(actual == .ok);
}

/// Positions among items entered in order into an index of their number: `alone` shares its
/// home slot with no other item, `crowded` finds an earlier item of another key in its home slot.
const Places = struct { alone: usize, crowded: usize, neighbour: usize };

fn places(hashes: []const u64) !Places {
    const mask = name_index.slotCount(hashes.len).? - 1;
    var alone: ?usize = null;
    var crowded: ?usize = null;
    var neighbour: usize = 0;
    for (hashes, 0..) |hash, index| {
        var shared = false;
        for (hashes, 0..) |other, other_index| {
            if (other_index == index or (other & mask) != (hash & mask)) continue;
            try std.testing.expect(other != hash);
            shared = true;
            if (other_index < index and crowded == null) {
                crowded = index;
                neighbour = other_index;
            }
        }
        if (!shared and alone == null) alone = index;
    }
    return .{ .alone = alone orelse return error.NoLoneName, .crowded = crowded orelse return error.NoCrowdedName, .neighbour = neighbour };
}

fn sharesHome(hashes: []const u64, index: usize) bool {
    const mask = name_index.slotCount(hashes.len).? - 1;
    for (hashes, 0..) |other, other_index| if (other_index != index and (other & mask) == (hashes[index] & mask)) return true;
    return false;
}

fn spanOf(source: []const u8, text: []const u8) types.Span {
    const start = std.mem.indexOf(u8, source, text).?;
    return .{ .start = @intCast(start), .end = @intCast(start + text.len) };
}

test "forged duplicate function names are rejected wherever they fall in the index" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const count = 40;
    for (0..count) |i| try source.print(std.testing.allocator, "F{d}(N:i64)<computes>:i64=N+{d}\n", .{ i, i });
    // Iterate keeps every function a published runtime function instead of an inlined template.
    for (0..count) |i| try source.print(std.testing.allocator, "B{d}:i64=Iterate(F{d},1,{d})\n", .{ i, i, i });
    const p = try h.compile(source.items);
    try std.testing.expectEqual(@as(usize, count), p.functions.len);
    var hashes: [count]u64 = undefined;
    for (p.functions, &hashes) |f, *hash| {
        try std.testing.expect(!f.anonymous);
        hash.* = name_index.hashName(0, f.name.text(p.source));
    }
    const at = try places(&hashes);
    var forged = p;
    forged.functions = h.metadata[0..count];

    // Control: the names move but stay distinct, across a crowded slot and a lone one.
    @memcpy(h.metadata[0..count], p.functions);
    std.mem.swap(types.Span, &h.metadata[at.alone].name, &h.metadata[at.crowded].name);
    try admitted(h, forged);
    @memcpy(h.metadata[0..count], p.functions);
    std.mem.swap(types.Span, &h.metadata[at.neighbour].name, &h.metadata[at.crowded].name);
    try admitted(h, forged);

    // Every function in turn takes the name of every tenth other one, earlier and later.
    for (0..count) |target| {
        for ([_]usize{ 1, 11, 21, 31 }) |step| {
            const copy = (target + step) % count;
            @memcpy(h.metadata[0..count], p.functions);
            h.metadata[copy].name = p.functions[target].name;
            try harness.invalid(h, forged);
        }
    }
    // The named places, each with the duplicate declared after and before the original.
    for ([_]usize{ at.alone, at.crowded, at.neighbour }) |target| {
        for ([_]usize{ 0, count - 1 }) |copy| {
            if (copy == target) continue;
            @memcpy(h.metadata[0..count], p.functions);
            h.metadata[copy].name = p.functions[target].name;
            try harness.invalid(h, forged);
        }
    }
    // An overload is the same name with other parameter types; the forgery above kept the types.
    _ = try h.execute("F(X:i64)<computes>:i64=X\nF(X:string)<computes>:i64=X.Length\nA:i64=Iterate(F,1,1)\nB<public>:i64=F(\"ab\")+A");
}

test "forged duplicate anonymous functions are rejected by position, not by text" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const count = 24;
    for (0..count) |i| try source.print(std.testing.allocator, "M{d}:function(tuple(i64),i64)=Fn[X:i64={d}](N:i64)<computes>:i64{{X+N}}\n", .{ i, i });
    try source.appendSlice(std.testing.allocator, "A<public>:i64=M3(4)\n");
    const p = try h.compile(source.items);
    try std.testing.expectEqual(@as(usize, count), p.functions.len);
    var hashes: [count]u64 = undefined;
    for (p.functions, &hashes) |f, *hash| {
        try std.testing.expect(f.anonymous);
        try std.testing.expectEqualStrings("Fn", f.name.text(p.source));
        hash.* = name_index.hashSpan(f.name.start, f.name.end);
    }
    const at = try places(&hashes);
    var forged = p;
    forged.functions = h.metadata[0..count];
    // Control: all of them are named `Fn` already, and exchanging two positions is no duplicate.
    try admitted(h, p);
    @memcpy(h.metadata[0..count], p.functions);
    std.mem.swap(types.Span, &h.metadata[at.neighbour].name, &h.metadata[at.crowded].name);
    try admitted(h, forged);
    for (0..count) |target| {
        for ([_]usize{ 1, 9, 17 }) |step| {
            const copy = (target + step) % count;
            @memcpy(h.metadata[0..count], p.functions);
            h.metadata[copy].name = p.functions[target].name;
            try harness.invalid(h, forged);
        }
    }
    for ([_]usize{ at.alone, at.crowded, at.neighbour }) |target| {
        for ([_]usize{ 0, count - 1 }) |copy| {
            if (copy == target) continue;
            @memcpy(h.metadata[0..count], p.functions);
            h.metadata[copy].name = p.functions[target].name;
            try harness.invalid(h, forged);
        }
    }
}

test "forged duplicates among cells, captured bindings, bindings and functions are rejected" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const count = 12;
    var uses: [count]types.Span = undefined;
    for (0..count) |i| try source.print(std.testing.allocator, "var C{d}:i64={d}\n", .{ i, i });
    for (0..count) |i| try source.print(std.testing.allocator, "G{d}:i64={d}\n", .{ i, i });
    try source.appendSlice(std.testing.allocator, "Use(N:i64)<transacts>:i64=N");
    for (0..count) |i| try source.print(std.testing.allocator, "+G{d}", .{i});
    for (0..count) |i| {
        try source.append(std.testing.allocator, '+');
        const start: u32 = @intCast(source.items.len);
        try source.print(std.testing.allocator, "C{d}", .{i});
        uses[i] = .{ .start = start, .end = @intCast(source.items.len) };
    }
    try source.appendSlice(std.testing.allocator, "\nSpare:i64=7\nTotal<public>:i64=Iterate(Use,1,1)\n");
    const p = try h.compile(source.items);
    try std.testing.expectEqual(@as(usize, count), p.source_cells.len);
    try std.testing.expectEqual(@as(usize, count), p.globals.len);
    try std.testing.expectEqual(@as(usize, 1), p.functions.len);
    try admitted(h, p);

    // Function admission enters the cells and then the captured bindings into one index.
    var hashes: [2 * count]u64 = undefined;
    for (p.source_cells, hashes[0..count]) |cell, *hash| hash.* = name_index.hashName(0, cell.name.text(p.source));
    for (p.globals, hashes[count..]) |global, *hash| hash.* = name_index.hashName(0, global.name.text(p.source));
    const at = try places(&hashes);
    // Cell admission enters the cells alone; every cell is forged below, so both kinds of place are.
    _ = try places(hashes[0..count]);

    var globals: [count]types.Binding = undefined;
    var bindings: [4 * count]types.Binding = undefined;
    try std.testing.expect(p.bindings.len <= bindings.len);
    const spare = for (p.bindings, 0..) |binding, index| {
        if (std.mem.eql(u8, binding.name.text(p.source), "Spare")) break index;
    } else return error.NoSpareBinding;
    const parameter = spanOf(p.source, "N:i64");
    const unused: types.Span = .{ .start = parameter.start, .end = parameter.start + 1 };

    // Captured bindings: controls exchange two names, forgeries repeat one.
    var forged = p;
    forged.globals = &globals;
    @memcpy(&globals, p.globals);
    std.mem.swap(types.Span, &globals[0].name, &globals[count - 1].name);
    try admitted(h, forged);
    for (0..count) |target| {
        for ([_]usize{ 1, 5, 9 }) |step| {
            @memcpy(&globals, p.globals);
            globals[(target + step) % count].name = p.globals[target].name;
            try harness.invalid(h, forged);
        }
        // A captured binding named like a cell, for every pairing of slots.
        for (0..count) |cell| {
            @memcpy(&globals, p.globals);
            globals[target].name = p.source_cells[cell].name;
            try harness.invalid(h, forged);
        }
    }
    for ([_]usize{ at.alone, at.crowded, at.neighbour }) |target| {
        const name = if (target < count) p.source_cells[target].name else p.globals[target - count].name;
        for ([_]usize{ 0, count - 1 }) |copy| {
            if (copy + count == target) continue;
            @memcpy(&globals, p.globals);
            globals[copy].name = name;
            try harness.invalid(h, forged);
        }
    }

    // A function: the control names it like nothing else, the forgeries like each cell and
    // each captured binding in turn.
    forged = p;
    forged.functions = h.metadata[0..1];
    h.metadata[0] = p.functions[0];
    h.metadata[0].name = unused;
    try admitted(h, forged);
    for (0..2 * count) |target| {
        h.metadata[0].name = if (target < count) p.source_cells[target].name else p.globals[target - count].name;
        try harness.invalid(h, forged);
    }

    // A binding with the text of a cell must be that cell's own binding. The control gives the
    // spare binding a name no cell has; the forgeries give it each cell's name from another place.
    forged = p;
    forged.bindings = bindings[0..p.bindings.len];
    @memcpy(bindings[0..p.bindings.len], p.bindings);
    bindings[spare].name = unused;
    try admitted(h, forged);
    for (0..count) |cell| {
        try std.testing.expectEqualStrings(p.source_cells[cell].name.text(p.source), uses[cell].text(p.source));
        try std.testing.expect(!std.meta.eql(p.source_cells[cell].name, uses[cell]));
        @memcpy(bindings[0..p.bindings.len], p.bindings);
        bindings[spare].name = uses[cell];
        try harness.invalid(h, forged);
    }
}

test "forged duplicate cells of one module are rejected and equal names in two modules are not" {
    const h = try harness.create();
    defer scratch.release(h);
    var library: std.ArrayList(u8) = .empty;
    defer library.deinit(std.testing.allocator);
    const count = 40;
    for (0..count) |i| try library.print(std.testing.allocator, "var C{d}<public>:i64={d}\n", .{ i, i });
    try library.appendSlice(std.testing.allocator, "Sum<public>(N:i64)<transacts>:i64=N");
    for (0..count) |i| try library.print(std.testing.allocator, "+C{d}", .{i});
    // The root module declares cells of the same names: a module is its own namespace.
    var root: std.ArrayList(u8) = .empty;
    defer root.deinit(std.testing.allocator);
    try root.appendSlice(std.testing.allocator, "L:=import{\"lib.forb\"}\n");
    for (0..count) |i| try root.print(std.testing.allocator, "var C{d}:i64={d}\n", .{ i, 100 + i });
    try root.appendSlice(std.testing.allocator, "Total<public>:i64=Iterate(L.Sum,1,1)+C3\n");
    const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = root.items }, .{ .path = "lib.forb", .source = library.items } };
    const bundled = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
    if (bundled == .failed) std.debug.print("bundle failed: {s} in {s}\n", .{ bundled.failed.diagnostic.message(), bundled.failed.path });
    try std.testing.expect(bundled == .ok);
    const p = bundled.ok;
    try std.testing.expectEqual(@as(usize, 2 * count), p.source_cells.len);
    try std.testing.expectEqual(@as(usize, 2), p.modules.len);
    try admitted(h, p);

    var cells: [2 * count]types.SourceCell = undefined;
    var nodes: [2048]types.Node = undefined;
    try std.testing.expect(p.nodes.len <= nodes.len);
    var forged = p;
    forged.source_cells = &cells;
    forged.nodes = nodes[0..p.nodes.len];
    var hashes: [2 * count]u64 = undefined;
    for (p.source_cells, &hashes) |cell, *hash| hash.* = name_index.hashName(modules.owner(cell.name, p.modules).?, cell.name.text(p.source));
    // Both situations occur among the library's cells, every pair of which is forged below.
    var lone = false;
    var crowded = false;
    const mask = name_index.slotCount(hashes.len).? - 1;
    for (p.source_cells, 0..) |cell, index| if (modules.owner(cell.name, p.modules).? == 0) {
        if (!sharesHome(&hashes, index)) lone = true;
        // An earlier cell in the home slot stands between this cell and a later copy of it.
        for (hashes[0..index]) |earlier| if ((earlier & mask) == (hashes[index] & mask)) {
            crowded = true;
        };
    };
    try std.testing.expect(lone and crowded);

    // The library's cells are used once more in `Sum`: those places give a cell the text of
    // another one without giving it that cell's span, which its initialiser would contradict.
    const body = p.modules[0].source.start + @as(u32, @intCast(std.mem.indexOf(u8, library.items, "=N+").?));
    for (0..2 * count) |renamed| {
        if (modules.owner(p.source_cells[renamed].name, p.modules).? != 0) continue;
        for (0..count) |target| {
            var text: [8]u8 = undefined;
            const wanted = try std.fmt.bufPrint(&text, "+C{d}", .{target});
            var start = body + @as(u32, @intCast(std.mem.indexOf(u8, p.source[body..p.modules[0].source.end], wanted).?)) + 1;
            // "+C1" also begins "+C10" and "+C11"; take the use that ends the name.
            while (start + wanted.len - 1 < p.modules[0].source.end and std.ascii.isDigit(p.source[start + wanted.len - 1])) {
                start += @as(u32, @intCast(std.mem.indexOf(u8, p.source[start..p.modules[0].source.end], wanted).?)) + 1;
            }
            const use: types.Span = .{ .start = start, .end = start + @as(u32, @intCast(wanted.len - 1)) };
            try std.testing.expectEqualStrings(wanted[1..], use.text(p.source));
            @memcpy(&cells, p.source_cells);
            @memcpy(nodes[0..p.nodes.len], p.nodes);
            cells[renamed].name = use;
            nodes[p.source_cells[renamed].initial].span = use;
            const own = std.mem.eql(u8, p.source_cells[renamed].name.text(p.source), use.text(p.source));
            // Control: a cell may be declared at the other place under its own name.
            if (own) try admitted(h, forged) else try harness.invalid(h, forged);
        }
    }
}
