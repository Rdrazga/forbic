//! Modules declared inside files, access levels and exported aliases (RFC-0074).
const std = @import("std");
const scratch = @import("scratch.zig");
const compiler = @import("compiler.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const inspection = @import("inspection.zig");
const reporting = @import("value_report.zig");
const types = @import("types.zig");
const vm = @import("vm.zig");
const harness = @import("generic_function_tests.zig");

const fuel = 1 << 20;

pub fn compile(h: *harness.Harness, inputs: []const modules.Input) !types.Program {
    return switch (h.front.compileBundle(.{ .root = "main.forb", .modules = inputs })) {
        .ok => |ir| ir,
        .failed => |problem| {
            const where = problem.diagnostic.location(problem.source);
            std.debug.print("nested compile failed: {s}:{d}:{d}: {s}\n", .{ problem.path, where.line, where.column, problem.diagnostic.message() });
            return error.UnexpectedCompile;
        },
    };
}

/// Runs the bundle on both machines, which the shared harness holds to the same values,
/// cells, failures and call witness, and whose reports it replays.
pub fn execute(h: *harness.Harness, inputs: []const modules.Input) !evaluator.Execution {
    const result = try h.run(try compile(h, inputs), fuel);
    if (result == .failed) {
        std.debug.print("nested run failed: {s}\n", .{result.failed.message()});
        return error.UnexpectedFailure;
    }
    return result.ok;
}

pub fn one(h: *harness.Harness, source: []const u8) !evaluator.Execution {
    return execute(h, &.{.{ .path = "main.forb", .source = source }});
}

/// The diagnostic of a bundle that must not compile, located in its file.
fn rejected(h: *harness.Harness, inputs: []const modules.Input) !modules.LocatedDiagnostic {
    return switch (h.front.compileBundle(.{ .root = "main.forb", .modules = inputs })) {
        .ok => error.UnexpectedAdmission,
        .failed => |problem| problem,
    };
}

fn expectCode(h: *harness.Harness, expected: types.Diagnostic.Code, source: []const u8) !void {
    const problem = rejected(h, &.{.{ .path = "main.forb", .source = source }}) catch |err| {
        std.debug.print("nested admitted:\n{s}\n", .{source});
        return err;
    };
    if (problem.diagnostic.code != expected) std.debug.print("nested diagnostic for:\n{s}\n", .{source});
    try std.testing.expectEqual(expected, problem.diagnostic.code);
}

/// `source` is refused with `expected`, reported at its `ordinal`-th occurrence of `text`.
fn expectAt(h: *harness.Harness, expected: types.Diagnostic.Code, text: []const u8, ordinal: usize, source: []const u8) !void {
    const problem = rejected(h, &.{.{ .path = "main.forb", .source = source }}) catch |err| {
        std.debug.print("nested admitted:\n{s}\n", .{source});
        return err;
    };
    if (problem.diagnostic.code != expected) std.debug.print("nested diagnostic for:\n{s}\n", .{source});
    try std.testing.expectEqual(expected, problem.diagnostic.code);
    var at: usize = 0;
    for (0..ordinal) |_| at = std.mem.indexOfPos(u8, source, at, text).? + text.len;
    at = std.mem.indexOfPos(u8, source, at, text).?;
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

/// The root node that calls the function named `callee` from the text of module `module`.
fn callIn(program: types.Program, module: []const u8, callee: []const u8) !u32 {
    const scope = for (program.nested) |entry| {
        if (std.mem.eql(u8, entry.name.text(program.source), module)) break entry.source;
    } else return error.NoSuchModule;
    for (program.nodes, 0..) |node, index| {
        if (node.kind != .call or !modules.within(scope, node.span, program.nested)) continue;
        if (std.mem.eql(u8, program.functions[node.kind.call.function].name.text(program.source), callee)) return @intCast(index);
    }
    std.debug.print("no call of {s} in {s}\n", .{ callee, module });
    return error.NoSuchCall;
}

fn functionNamed(program: types.Program, name: []const u8, ordinal: usize) !u32 {
    var seen: usize = 0;
    for (program.functions, 0..) |function, index| {
        if (!std.mem.eql(u8, function.name.text(program.source), name)) continue;
        if (seen == ordinal) return @intCast(index);
        seen += 1;
    }
    return error.NoSuchFunction;
}

const forged_source =
    \\t:=struct{x:i64=0}
    \\Outer<public>:=module{
    \\  s:=struct{y:i64=0}
    \\  Inner:=module{
    \\    Open<public>(X:i64)<transacts>:i64=X+1
    \\    Shut(X:i64)<transacts>:i64=X+2
    \\    var Cell<public>:i64=5
    \\    var Mine:i64=6
    \\    Use:i64=Shut(1)+Mine
    \\    u<public>:=struct{z:i64=0}
    \\    Give<public>(X:i64)<transacts>:u=u{z:=X}
    \\  }
    \\  Mid:i64=Inner.Open(1)+Inner.Cell
    \\  Pass(X:i64)<transacts>:Inner.u=Inner.Give(X)
    \\  Got:i64=Pass(7).z
    \\  Pub<public>(X:i64)<transacts>:i64=X+3
    \\  Keep(X:i64)<transacts>:i64=X+4
    \\  Made(X:i64)<transacts>:s=s{y:=X}
    \\  holder:=struct{inner:s}
    \\  Own:i64=Keep(1)+Made(2).y
    \\  Deep<public>:=module{
    \\    Open<public>(X:i64)<transacts>:i64=X+5
    \\    Back:i64=Keep(2)+Inner.Open(3)
    \\  }
    \\}
    \\Sib:=module{
    \\  Far:i64=Outer.Pub(1)+Outer.Deep.Open(2)
    \\}
    \\Top<public>:i64=Outer.Pub(2)
    \\Hold:t=t{}
;

test "both admissions reject references that cross a boundary the declaration does not" {
    const h = try harness.create();
    defer scratch.release(h);
    const program = try compile(h, &.{.{ .path = "main.forb", .source = forged_source }});
    _ = try h.run(program, fuel);
    const nodes = try std.testing.allocator.dupe(types.Node, program.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = program;
    forged.nodes = nodes;
    const open = try functionNamed(program, "Open", 0);
    const shut = try functionNamed(program, "Shut", 0);
    const keep = try functionNamed(program, "Keep", 0);
    const pub_function = try functionNamed(program, "Pub", 0);
    const Retarget = struct { module: []const u8, callee: []const u8, target: u32, admitted: bool };
    for ([_]Retarget{
        // What the program already does, said again: still admitted.
        .{ .module = "Sib", .callee = "Pub", .target = pub_function, .admitted = true },
        // A function that is not public, called from outside its module.
        .{ .module = "Sib", .callee = "Pub", .target = keep, .admitted = false },
        .{ .module = "Outer", .callee = "Keep", .target = shut, .admitted = false },
        // A public function of a module that is not public, called from beyond the scope that
        // declares the module: `Sib` cannot name `Outer.Inner`.
        .{ .module = "Sib", .callee = "Pub", .target = open, .admitted = false },
        // The same function is in reach of `Outer` and of every module nested in `Outer`.
        .{ .module = "Outer", .callee = "Keep", .target = open, .admitted = true },
        .{ .module = "Deep", .callee = "Keep", .target = open, .admitted = true },
        // What an enclosing module keeps to itself is in reach of the modules nested in it.
        .{ .module = "Deep", .callee = "Keep", .target = shut, .admitted = false },
    }) |case| {
        @memcpy(nodes, program.nodes);
        const at = try callIn(program, case.module, case.callee);
        nodes[at].kind.call.function = case.target;
        if (case.admitted) {
            if (evaluator.validate(forged, h.values.len) != null) std.debug.print("refused: {s} calls function {d}\n", .{ case.module, case.target });
            try std.testing.expect(evaluator.validate(forged, h.values.len) == null);
            try std.testing.expect(h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, fuel) == .ok);
        } else {
            harness.invalid(h, forged) catch |err| {
                std.debug.print("admitted: {s} calls function {d}\n", .{ case.module, case.target });
                return err;
            };
        }
    }
    // A cell that is not public, read from outside its module; a public cell of a module that
    // is not public, read from beyond the scope that declares the module.
    @memcpy(nodes, program.nodes);
    var mine: u32 = 0;
    var cell: u32 = 0;
    for (program.source_cells, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name.text(program.source), "Mine")) mine = @intCast(index);
        if (std.mem.eql(u8, entry.name.text(program.source), "Cell")) cell = @intCast(index);
    }
    const outer = program.nested[0].source;
    const read = for (program.nodes, 0..) |node, index| {
        if (node.kind == .cell_read and node.kind.cell_read == cell and modules.within(outer, node.span, program.nested)) break index;
    } else return error.NoCellRead;
    nodes[read].kind.cell_read = mine;
    try harness.invalid(h, forged);
    @memcpy(nodes, program.nodes);
    // The read of `Inner.Cell`, moved to where `Sib` calls `Outer.Pub`: outside `Outer`.
    nodes[read].span = program.nodes[try callIn(program, "Sib", "Pub")].span;
    try harness.invalid(h, forged);
    _ = try h.run(program, fuel);
}

test "both admissions reject a public declaration that exposes a type its users cannot name" {
    const h = try harness.create();
    defer scratch.release(h);
    const program = try compile(h, &.{.{ .path = "main.forb", .source = forged_source }});
    const functions = try std.testing.allocator.dupe(types.RuntimeFunction, program.functions);
    defer std.testing.allocator.free(functions);
    const cells = try std.testing.allocator.dupe(types.SourceCell, program.source_cells);
    defer std.testing.allocator.free(cells);
    const bindings = try std.testing.allocator.dupe(types.Binding, program.bindings);
    defer std.testing.allocator.free(bindings);
    const definitions = try std.testing.allocator.dupe(types.Definition, program.definitions);
    defer std.testing.allocator.free(definitions);
    var forged = program;
    forged.functions = functions;
    forged.source_cells = cells;
    forged.bindings = bindings;
    forged.definitions = definitions;
    // `Made` returns `s`, which only `Outer` and the modules nested in it can name: public, it
    // would hand `s` to every importer of the file.
    const made = try functionNamed(program, "Made", 0);
    functions[made].is_public = true;
    try harness.invalid(h, forged);
    functions[made].is_public = false;
    // `Hold` is a binding of the root file with the file's private type `t`.
    const hold = for (program.bindings, 0..) |binding, index| {
        if (std.mem.eql(u8, binding.name.text(program.source), "Hold")) break index;
    } else return error.NoBinding;
    bindings[hold].is_public = true;
    try harness.invalid(h, forged);
    bindings[hold].is_public = false;
    // Were `s` public, `Made` could be too: `Outer` is public, so both reach every importer.
    const s = for (program.definitions, 0..) |item, index| {
        if (item == .record and std.mem.eql(u8, item.record.name.text(program.source), "s")) break index;
    } else return error.NoType;
    definitions[s].record.is_public = true;
    functions[made].is_public = true;
    try std.testing.expect(evaluator.validate(forged, h.values.len) == null);
    try std.testing.expect(h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, fuel) == .ok);
    definitions[s].record.is_public = false;
    functions[made].is_public = false;
    // `u` is a public type of `Inner`, which is not public: it reaches `Outer` and no further.
    // `Give`, public in `Inner`, reaches exactly as far and may return it. `Pass` is `Outer`'s:
    // public, it would carry `u` to importers who cannot name `Outer.Inner`.
    const pass = try functionNamed(program, "Pass", 0);
    functions[pass].is_public = true;
    try harness.invalid(h, forged);
    functions[pass].is_public = false;
    // A public record is nameable by every importer, and so must the types of its fields be.
    const holder = for (program.definitions, 0..) |item, index| {
        if (item == .record and std.mem.eql(u8, item.record.name.text(program.source), "holder")) break index;
    } else return error.NoType;
    definitions[holder].record.is_public = true;
    try harness.invalid(h, forged);
    definitions[holder].record.is_public = false;
    // A cell is tied to the node that initialises it, so its name cannot be moved to a scope
    // from which it would be in reach; two functions of one scope cannot share a signature,
    // so a private function cannot take the name of a public one.
    const mine = for (program.source_cells, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name.text(program.source), "Mine")) break index;
    } else return error.NoCell;
    cells[mine].name = program.nested[0].name;
    try harness.invalid(h, forged);
    cells[mine] = program.source_cells[mine];
    functions[try functionNamed(program, "Keep", 0)].name = functions[try functionNamed(program, "Pub", 0)].name;
    try harness.invalid(h, forged);
    @memcpy(functions, program.functions);
    // A table cannot make `Outer` private either: the source says `<public>`.
    const nested = try std.testing.allocator.dupe(types.NestedModule, program.nested);
    defer std.testing.allocator.free(nested);
    forged.nested = nested;
    nested[0].is_public = false;
    try std.testing.expect(evaluator.validate(forged, h.values.len) != null);
    var raw = bytecode.lower(program, &h.runtime.instructions).ok;
    raw.nested = nested;
    try std.testing.expect(vm.verify(raw, &h.runtime.machine.register_types) == .failed);
    // A binding of a nested module is not a binding of the program.
    forged = program;
    forged.bindings = bindings;
    bindings[hold].name = for (program.nodes) |node| {
        if (node.kind == .cell_init and std.mem.eql(u8, node.span.text(program.source), "Mine")) break node.span;
    } else return error.NoCell;
    try harness.invalid(h, forged);
    _ = try h.run(program, fuel);
}

test "both admissions tie every entry of the nested table to the text that declares it" {
    const h = try harness.create();
    defer scratch.release(h);
    const program = try compile(h, &.{.{ .path = "main.forb", .source = forged_source }});
    try std.testing.expectEqual(@as(usize, 4), program.nested.len);
    var table: [5]types.NestedModule = undefined;
    var forged = program;
    var generator = std.Random.DefaultPrng.init(0x7400740074);
    const random = generator.random();
    var rejected_count: usize = 0;
    for (0..4000) |_| {
        @memcpy(table[0..4], program.nested);
        forged.nested = table[0..4];
        const index = random.uintLessThan(usize, 4);
        const value = random.uintLessThan(u32, @intCast(program.source.len + 4));
        const before = table[index];
        switch (random.uintLessThan(u8, 12)) {
            0 => table[index].source.start = value,
            1 => table[index].source.end = value,
            2 => table[index].name.start = value,
            3 => table[index].name.end = value,
            4 => table[index].parent = random.uintLessThan(u32, 6),
            5 => table[index].parent = types.no_parent,
            6 => table[index].is_public = !table[index].is_public,
            7 => std.mem.swap(types.NestedModule, &table[index], &table[random.uintLessThan(usize, 4)]),
            8 => forged.nested = table[0..random.uintLessThan(usize, 4)],
            9 => {
                table[4] = table[index];
                forged.nested = table[0..5];
            },
            10 => table[index].name = table[random.uintLessThan(usize, 4)].name,
            11 => table[index].source = table[random.uintLessThan(usize, 4)].source,
            else => unreachable,
        }
        const same = forged.nested.len == 4 and std.meta.eql(before, table[index]) and std.meta.eql(table[0], program.nested[0]) and std.meta.eql(table[1], program.nested[1]) and std.meta.eql(table[2], program.nested[2]) and std.meta.eql(table[3], program.nested[3]);
        const reference = evaluator.validate(forged, h.values.len);
        // Lowering refuses a malformed table as it refuses a malformed file table; the VM is
        // asked on its own as well, with the code of the true program and the forged table.
        if (bytecode.lower(forged, &h.runtime.instructions) != .ok) try std.testing.expect(reference != null);
        var raw = bytecode.lower(program, &h.runtime.instructions).ok;
        raw.nested = forged.nested;
        const actual = vm.verify(raw, &h.runtime.machine.register_types);
        // The two machines agree on every table, and admit the true one only.
        try std.testing.expectEqual(reference == null, actual != .failed);
        if (same) try std.testing.expect(reference == null);
        // Whatever differs from the text is refused, a table that drops modules included.
        if (!same) {
            if (reference == null) for (forged.nested, 0..) |entry, at| std.debug.print("forged table admitted: {d}: name {d}..{d} source {d}..{d} parent {d} public {}\n", .{ at, entry.name.start, entry.name.end, entry.source.start, entry.source.end, entry.parent, entry.is_public });
            try std.testing.expect(reference != null);
            rejected_count += 1;
        }
    }
    try std.testing.expect(rejected_count > 2000);
    _ = try h.run(program, fuel);
}

/// A model of module visibility, kept apart from the implementation: scopes are numbered, 0 is
/// the root file and `lib` the imported one; each has a parent, a public flag for the module
/// itself and one for the value it declares.
const Forest = struct {
    const capacity = 26;
    parent: [capacity]u8 = undefined,
    module_public: [capacity]bool = undefined,
    value_public: [capacity]bool = undefined,
    count: u8 = 0,
    lib: u8 = 0,

    fn isFile(self: *const Forest, scope: u8) bool {
        return scope == 0 or scope == self.lib;
    }

    fn fileOf(self: *const Forest, scope: u8) u8 {
        var at = scope;
        while (!self.isFile(at)) at = self.parent[at];
        return at;
    }

    fn depth(self: *const Forest, scope: u8) u8 {
        var at = scope;
        var levels: u8 = 0;
        while (!self.isFile(at)) : (at = self.parent[at]) levels += 1;
        return levels;
    }

    /// Whether `inner` is `outer` or declared somewhere inside it.
    fn inside(self: *const Forest, inner: u8, outer: u8) bool {
        var at = inner;
        while (true) {
            if (at == outer) return true;
            if (self.isFile(at)) return false;
            at = self.parent[at];
        }
    }

    /// The scope on the way from `target` up to its file that the code in `user` names first:
    /// the outermost one whose declaring scope is around `user`, or the imported file itself.
    fn entry(self: *const Forest, user: u8, target: u8) u8 {
        var at = target;
        while (!self.isFile(at) and !self.inside(user, self.parent[at])) at = self.parent[at];
        return at;
    }

    /// Whether code in `user` can name module `target`: every module from the entry down to
    /// the target, the entry excepted, must be public, since each is named from outside its parent.
    fn nameable(self: *const Forest, user: u8, target: u8) bool {
        if (self.inside(user, target)) return true;
        const first = self.entry(user, target);
        var at = target;
        while (at != first) : (at = self.parent[at]) if (!self.module_public[at]) return false;
        // The root file imports the other, never the reverse.
        return !self.isFile(first) or (first == self.lib and self.fileOf(user) == 0);
    }

    /// Whether the entry of the path is declared before the code at the end of `user`'s body:
    /// a module is named after its declaration. Scopes are numbered in declaration order.
    fn declaredBefore(self: *const Forest, user: u8, target: u8) bool {
        const first = self.entry(user, target);
        if (self.isFile(first)) return true;
        const around = self.parent[first];
        if (around == user) return true;
        var mine = user;
        while (self.parent[mine] != around) mine = self.parent[mine];
        return first < mine;
    }

    fn writePath(self: *const Forest, out: *std.Io.Writer, user: u8, target: u8) !void {
        var chain: [capacity]u8 = undefined;
        var length: usize = 0;
        const first = self.entry(user, target);
        var at = target;
        while (true) : (at = self.parent[at]) {
            chain[length] = at;
            length += 1;
            if (at == first) break;
        }
        while (length != 0) {
            length -= 1;
            if (self.isFile(chain[length])) try out.writeAll("L") else try out.print("M{d}", .{chain[length]});
            if (length != 0) try out.writeByte('.');
        }
    }

    const Probe = struct { user: u8, target: u8, using: bool };

    fn writeScope(self: *const Forest, out: *std.Io.Writer, scope: u8, probe: Probe) !void {
        try out.print("V{d}{s}:i64={d}\n", .{ scope, if (self.value_public[scope]) "<public>" else "", 100 + @as(u32, scope) });
        for (scope + 1..self.count) |child| {
            if (self.isFile(@intCast(child)) or self.parent[child] != scope) continue;
            try out.print("M{d}{s}:=module{{\n", .{ child, if (self.module_public[child]) "<public>" else "" });
            try self.writeScope(out, @intCast(child), probe);
            try out.writeAll("}\n");
        }
        if (scope != probe.user) return;
        if (self.inside(probe.user, probe.target)) {
            try out.print("set Probe=V{d}\n", .{probe.target});
        } else if (probe.using) {
            try out.writeAll("using{");
            try self.writePath(out, probe.user, probe.target);
            try out.print("}}\nset Probe=V{d}\n", .{probe.target});
        } else {
            try out.writeAll("set Probe=");
            try self.writePath(out, probe.user, probe.target);
            try out.print(".V{d}\n", .{probe.target});
        }
    }
};

test "600 random module trees agree with a model of visibility, in the compiler and on both machines" {
    const h = try harness.create();
    defer scratch.release(h);
    var generator = std.Random.DefaultPrng.init(0x7407407407);
    const random = generator.random();
    const main_text = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(main_text);
    const lib_text = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(lib_text);
    var outcomes: [3]u32 = @splat(0);
    for (0..600) |_| {
        var forest: Forest = .{};
        const main_modules = random.uintLessThan(u8, 12);
        const lib_modules = random.uintLessThan(u8, 12);
        forest.count = 2 + main_modules + lib_modules;
        forest.lib = 1 + main_modules;
        for (0..forest.count) |index| {
            const scope: u8 = @intCast(index);
            forest.module_public[scope] = random.boolean();
            forest.value_public[scope] = random.boolean();
            if (forest.isFile(scope)) continue;
            // A module of either file, declared by the file or by an earlier module of it.
            const file: u8 = if (scope < forest.lib) 0 else forest.lib;
            var around = file + random.uintLessThan(u8, scope - file);
            while (forest.depth(around) >= 4) around = forest.parent[around];
            forest.parent[scope] = around;
        }
        const probe: Forest.Probe = .{ .user = random.uintLessThan(u8, forest.lib), .target = random.uintLessThan(u8, forest.count), .using = random.boolean() };
        var main_out: std.Io.Writer = .fixed(main_text);
        try main_out.writeAll("L:=import{\"lib.forb\"}\nvar Probe:i64=0\n");
        try forest.writeScope(&main_out, 0, probe);
        try main_out.writeAll("Out<public>:i64=Probe\n");
        var lib_out: std.Io.Writer = .fixed(lib_text);
        try forest.writeScope(&lib_out, forest.lib, probe);
        const inputs = [_]modules.Input{ .{ .path = "main.forb", .source = main_out.buffered() }, .{ .path = "lib.forb", .source = lib_out.buffered() } };
        // The model: what is declared around the code is in reach; anything else is reached by
        // a path that starts at a module already declared and passes only public modules.
        const lexical = forest.inside(probe.user, probe.target);
        var expected: ?types.Diagnostic.Code = null;
        if (!lexical) {
            if (!forest.declaredBefore(probe.user, probe.target)) {
                expected = .unknown_name;
            } else if (!forest.nameable(probe.user, probe.target)) {
                expected = .private_name;
            } else if (!forest.value_public[probe.target]) {
                // `using` brings the public names along; a path names the private one and is refused.
                expected = if (probe.using) .unknown_name else .private_name;
            }
        }
        const result = h.front.compileBundle(.{ .root = "main.forb", .modules = &inputs });
        if ((result == .ok) != (expected == null) or (result == .failed and result.failed.diagnostic.code != expected.?)) {
            std.debug.print("visibility differs from the model (user {d}, target {d}, using {}): expected {?}, got {s}\n--- main\n{s}--- lib\n{s}", .{ probe.user, probe.target, probe.using, expected, if (result == .ok) "admission" else result.failed.diagnostic.message(), inputs[0].source, inputs[1].source });
            return error.ModelMismatch;
        }
        if (expected) |code| {
            outcomes[if (code == .private_name) 1 else 2] += 1;
            continue;
        }
        outcomes[0] += 1;
        const execution = (try h.run(result.ok, fuel)).ok;
        try std.testing.expectEqual(@as(i64, 100 + @as(i64, probe.target)), try integer(execution, "Out"));
    }
    // Every outcome is exercised often enough to mean something.
    for (outcomes) |seen| try std.testing.expect(seen > 40);
}

test "a module declared in a file is a namespace reached by path, with its own public names" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try one(h,
        \\Base:i64=10
        \\Outer:=module{
        \\  Scale<public>:i64=3
        \\  Hidden:i64=Base+1
        \\  Twice<public>(X:i64)<computes>:i64=X*2+Hidden
        \\  Inner<public>:=module{
        \\    Deep<public>:i64=Scale*Hidden
        \\    Add<public>(X:i64)<computes>:i64=X+Deep+Base
        \\  }
        \\  Again<public>:i64=Inner.Deep+1
        \\}
        \\A<public>:i64=Outer.Scale
        \\B<public>:i64=Outer.Twice(4)
        \\C<public>:i64=Outer.Inner.Deep
        \\D<public>:i64=Outer.Inner.Add(1)
        \\E<public>:i64=Outer.Again
    );
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 19), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 33), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 44), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 34), try integer(execution, "E"));
    // Only the root file's own bindings are published; those of its modules are not.
    try std.testing.expectEqual(@as(usize, 6), execution.program.bindings.len);
    try std.testing.expect(execution.get("Scale") == null and execution.get("Deep") == null and execution.get("Hidden") == null);
    try std.testing.expectEqual(@as(usize, 2), execution.program.nested.len);
}

test "every kind of declaration lives in a nested module and is used from inside and outside" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try one(h,
        \\Kit<public>:=module{
        \\  point<public>:=struct{x:i64=1,y:i64=2}
        \\  mode<public>:=enum<closed>{dark,light}
        \\  shape<public>:=interface{Area<public>()<transacts>:i64}
        \\  square<public>:=class(shape){side<public>:i64=3,Area<override>()<transacts>:i64=Self.side*Self.side}
        \\  node<public>:=class{value<public>:i64=0,next<public>:option(node)=option{}}
        \\  Grid<public>:=[]i64
        \\  var Count<public>:i64=0
        \\  Limit<public>:i64=7
        \\  Sum<public>(G:Grid)<computes>:i64=Attempt(G[0]+G[1],-1)
        \\  Pick<public>[t:type](A:t,B:t)<computes>:t{B}
        \\  (P:point).Total<public>()<computes>:i64=P.x+P.y
        \\  Bump<public>()<transacts>:i64=Block{set Count=Count+Limit;Count}
        \\  Own:point=point{x:=5}
        \\  OwnTotal<public>:i64=Own.Total()+Sum(array{1,2})
        \\}
        \\P:Kit.point=Kit.point{y:=9}
        \\A<public>:i64=P.x+P.y
        \\M:Kit.mode=Kit.mode.light
        \\B<public>:logic=M==Kit.mode.light
        \\S:Kit.square=Kit.square{side:=4}
        \\C<public>:i64=S.Area()
        \\G:Kit.Grid=array{20,22}
        \\D<public>:i64=Kit.Sum(G)
        \\E<public>:i64=Kit.Pick[i64](1,2)
        \\F<public>:i64=Kit.Bump()+Kit.Bump()
        \\H<public>:i64=Kit.OwnTotal
        \\N:Kit.node=Kit.node{value:=3,next:=option{Kit.node{value:=4}}}
        \\I<public>:i64=Kit.Count
        \\set Kit.Count=Kit.Count+1
        \\J<public>:i64=Kit.Count
    );
    try std.testing.expectEqual(@as(i64, 10), try integer(execution, "A"));
    try std.testing.expectEqual(true, execution.get("B").?.boolean);
    try std.testing.expectEqual(@as(i64, 16), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 42), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 2), try integer(execution, "E"));
    try std.testing.expectEqual(@as(i64, 21), try integer(execution, "F"));
    try std.testing.expectEqual(@as(i64, 10), try integer(execution, "H"));
    try std.testing.expectEqual(@as(i64, 14), try integer(execution, "I"));
    try std.testing.expectEqual(@as(i64, 15), try integer(execution, "J"));
}

test "names resolve lexically through enclosing modules, and no module redeclares a name declared earlier around it" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0076: a module may not shadow what a scope around it has already declared, so each
    // level has its own name here; before, all three were `Value` and the nearest one won.
    const execution = try one(h,
        \\Value:i64=1
        \\Help(X:i64)<computes>:i64=X+100
        \\kind:=enum<closed>{a,b}
        \\Outer:=module{
        \\  Own:i64=2
        \\  Mid<public>:=module{
        \\    Seen<public>:i64=Own
        \\    Far<public>:i64=Help(Own)
        \\    Inner<public>:=module{
        \\      Deepest:i64=3
        \\      Near<public>:i64=Deepest
        \\      Up<public>:i64=Outer.Own+Help(0)
        \\      Tag<public>:kind=kind.b
        \\    }
        \\  }
        \\  Sibling<public>:=module{
        \\    Other<public>:i64=Mid.Inner.Near+Mid.Seen
        \\  }
        \\}
        \\A<public>:i64=Outer.Mid.Seen
        \\B<public>:i64=Outer.Mid.Far
        \\C<public>:i64=Outer.Mid.Inner.Near
        \\D<public>:i64=Outer.Mid.Inner.Up
        \\E<public>:i64=Outer.Sibling.Other
        \\F<public>:logic=Outer.Mid.Inner.Tag==kind.b
        \\G<public>:i64=Value
    );
    try std.testing.expectEqual(@as(i64, 2), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 102), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 102), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 5), try integer(execution, "E"));
    try std.testing.expectEqual(true, execution.get("F").?.boolean);
    try std.testing.expectEqual(@as(i64, 1), try integer(execution, "G"));
    // The name of a scope around the module, declared earlier: refused at the inner declaration,
    // one level in or two, whatever either of them names.
    try expectAt(h, .shadowed_name, "Value", 1, "Value:i64=1\nOuter:=module{\n  Value:i64=2\n}");
    try expectAt(h, .shadowed_name, "Value", 1, "Outer:=module{\n  Value:i64=2\n  Mid:=module{\n    Inner:=module{\n      Value:i64=3\n    }\n  }\n}");
    try expectAt(h, .shadowed_name, "Help", 1, "Help(X:i64)<computes>:i64=X+100\nOuter:=module{Help:i64=2}");
    try expectAt(h, .shadowed_name, "kind", 1, "kind:=enum<closed>{a,b}\nOuter:=module{kind:=struct{x:i64=0}}");
    try expectAt(h, .shadowed_name, "Outer", 1, "Outer:=module{Mid:=module{Outer:i64=1}}");
    // A name the scope around declares later is no such name: the nearest declaration is meant.
    const later = try one(h,
        \\Outer:=module{
        \\  Value:i64=2
        \\  Mid<public>:=module{
        \\    Seen<public>:i64=Value
        \\  }
        \\}
        \\Value:i64=1
        \\A<public>:i64=Outer.Mid.Seen*10+Value
    );
    try std.testing.expectEqual(@as(i64, 21), try integer(later, "A"));
}

test "access across module boundaries follows the path: every step must be in reach" {
    const h = try harness.create();
    defer scratch.release(h);
    // A member that is not public is used by its module and the modules nested in it only.
    try expectCode(h, .private_name, "M:=module{Secret:i64=1}\nA:i64=M.Secret");
    try expectCode(h, .private_name, "M:=module{Secret<internal>:i64=1}\nA:i64=M.Secret");
    try expectCode(h, .private_name, "M:=module{F()<computes>:i64=1}\nA:i64=M.F()");
    try expectCode(h, .private_name, "M:=module{t:=struct{x:i64=1}}\nA:M.t=M.t{}");
    try expectCode(h, .private_name, "M:=module{G:=[]i64}\nA:M.G=array{1}");
    try expectCode(h, .private_name, "M:=module{var C:i64=1}\nset M.C=2");
    try expectCode(h, .private_name, "M:=module{Id[t:type](X:t)<computes>:t{X}}\nA:i64=M.Id[i64](1)");
    // A module that is not public is named by the scope that declares it, not from further out.
    try expectCode(h, .private_name, "A:=module{B<public>:=module{C:=module{V<public>:i64=1}}}\nX:i64=A.B.C.V");
    try expectCode(h, .private_name, "A:=module{B:=module{V<public>:i64=1}}\nX:=module{Y:i64=A.B.V}");
    // A module is not a value, and is named only after its declaration.
    try expectCode(h, .unknown_name, "M:=module{V<public>:i64=1}\nA:i64=M");
    try expectCode(h, .unknown_name, "A:i64=M.V\nM:=module{V<public>:i64=1}");
    try expectCode(h, .unknown_name, "M:=module{V<public>:i64=1}\nA:i64=M.W");
    try expectCode(h, .unknown_name, "M:=module{V<public>:i64=1}\nA:i64=V");
    try expectCode(h, .unknown_name, "M:=module{A:i64=Later}\nLater:i64=1");
    // Names of one scope are distinct, whatever they name.
    try expectCode(h, .duplicate_name, "M:=module{}\nM:=module{}");
    try expectCode(h, .duplicate_name, "M:i64=1\nM:=module{}");
    try expectCode(h, .duplicate_name, "M:=module{}\nM:i64=1");
    try expectCode(h, .duplicate_name, "M:=module{}\nM()<computes>:i64=1");
    try expectCode(h, .duplicate_name, "O:=module{M:=module{}\nM:=struct{x:i64}}");
    // What a module body may not hold, and how it must end.
    try expectCode(h, .late_import, "M:=module{L:=import{\"main.forb\"}}");
    try expectCode(h, .unsupported_specifier, "M<private>:=module{}");
    try expectCode(h, .unsupported_specifier, "M:=module{V<protected>:i64=1}");
    try expectCode(h, .unexpected_token, "M:=module{V:i64=1} A:i64=2");
    try expectCode(h, .unexpected_token, "M:=module{V:i64=1");
    try expectCode(h, .expected_name, "If:=module{}");
    try expectCode(h, .expected_name, "__m:=module{}");
    // Inside its own module or a nested one, a qualified path reaches what is not public.
    const execution = try one(h,
        \\A:=module{
        \\  Secret:i64=5
        \\  B:=module{
        \\    Hidden:i64=7
        \\    Read<public>:i64=A.Secret+A.B.Hidden
        \\  }
        \\  Out<public>:i64=B.Read
        \\}
        \\X<public>:i64=A.Out
    );
    try std.testing.expectEqual(@as(i64, 12), try integer(execution, "X"));
}

test "using names a module by path, holds for the modules nested in its scope, and yields to declarations" {
    const h = try harness.create();
    defer scratch.release(h);
    // The three ways the Book imports a nested module (16_modules.md, "Nested Imports").
    const execution = try one(h,
        \\GameSystems:=module{
        \\  Inventory<public>:=module{
        \\    Slots<public>:i64=8
        \\    Hidden:i64=1
        \\  }
        \\  Limit<public>:i64=100
        \\}
        \\Loadout:=module{
        \\  using{GameSystems}
        \\  using{Inventory}
        \\  Total<public>:i64=Slots*2
        \\}
        \\Storage:=module{
        \\  using{GameSystems.Inventory}
        \\  Total<public>:i64=Slots*3
        \\}
        \\Vault:=module{
        \\  using{GameSystems}
        \\  Total<public>:i64=Inventory.Slots*4+Limit
        \\  Deep<public>:=module{
        \\    Least:i64=1
        \\    Seen<public>:i64=Inventory.Slots+Least
        \\  }
        \\}
        \\A<public>:i64=Loadout.Total
        \\B<public>:i64=Storage.Total
        \\C<public>:i64=Vault.Total
        \\D<public>:i64=Vault.Deep.Seen
    );
    try std.testing.expectEqual(@as(i64, 16), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 24), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 132), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 9), try integer(execution, "D"));
    // The Book: the parent is imported before the child, and only public names come along.
    try expectCode(h, .unknown_name, "G:=module{I<public>:=module{S<public>:i64=8}}\nBad:=module{using{I}\nusing{G}\nT:i64=S}");
    try expectCode(h, .unknown_name, "G:=module{I<public>:=module{S:i64=8}}\nusing{G.I}\nT:i64=S");
    try expectCode(h, .private_name, "G:=module{I:=module{S<public>:i64=8}}\nB:=module{using{G.I}\nT:i64=S}");
    try expectCode(h, .unknown_name, "G:=module{I<public>:=module{S<public>:i64=8}}\nusing{G.J}");
    try expectCode(h, .unknown_name, "G:=module{I:=module{S<public>:i64=8}}\nB:=module{using{G}\nT:i64=I.S}");
    // A `using` inside a module does not reach the scope around it or a sibling.
    try expectCode(h, .unknown_name, "G:=module{S<public>:i64=8}\nA:=module{using{G}}\nT:i64=S");
    try expectCode(h, .unknown_name, "G:=module{S<public>:i64=8}\nA:=module{using{G}}\nB:=module{T:i64=S}");
    // Two used modules that both export the name leave it ambiguous; qualified use is not.
    try expectCode(h, .ambiguous_call, "M:=module{Bonus<public>:i64=2}\nS:=module{Bonus<public>:i64=3}\nusing{M}\nusing{S}\nX:i64=Bonus");
    const both = try one(h, "M:=module{Bonus<public>:i64=2}\nS:=module{Bonus<public>:i64=3}\nusing{M}\nusing{S}\nX<public>:i64=M.Bonus+S.Bonus");
    try std.testing.expectEqual(@as(i64, 5), try integer(both, "X"));
    // A `using` may not bring in a name that a scope around it has declared already (RFC-0076
    // D5): that declaration used to win over the name that came through `using`, silently.
    try expectAt(h, .shadowed_name, "G", 1, "G:=module{S<public>:i64=8}\nS:i64=1\nA:=module{using{G}\nT<public>:i64=S}\nX<public>:i64=A.T");
    // Declared after the module that uses it, it is not visible there yet.
    const later = try one(h, "G:=module{S<public>:i64=8}\nA:=module{using{G}\nT<public>:i64=S}\nS:i64=1\nX<public>:i64=A.T+S");
    try std.testing.expectEqual(@as(i64, 9), try integer(later, "X"));
    // RFC-0076: where a `using` is in effect, no declaration takes a name it exports (`Deep`
    // above declared its own `Limit` under `using{GameSystems}`, and that one was meant).
    try expectAt(h, .shadowed_name, "Limit", 1, "G:=module{Limit<public>:i64=100}\nV:=module{using{G}\nDeep:=module{\nLimit:i64=1}}");
    try expectAt(h, .shadowed_name, "Limit", 1, "G:=module{Limit<public>:i64=100}\nV:=module{using{G}\nLimit:i64=1}");
    // A name the used module keeps to itself is not exported, and so is free.
    const kept = try one(h, "G:=module{Limit:i64=100}\nV:=module{using{G}\nLimit<public>:i64=1}\nX<public>:i64=V.Limit");
    try std.testing.expectEqual(@as(i64, 1), try integer(kept, "X"));
}

test "nested modules cross files: paths through an import, using, and boundaries that are not public" {
    const h = try harness.create();
    defer scratch.release(h);
    const lib =
        \\Seed:i64=4
        \\Shapes<public>:=module{
        \\  point<public>:=struct{x:i64=1}
        \\  Unit<public>:i64=Seed
        \\  Flat<public>:=module{
        \\    Area<public>(P:point)<computes>:i64=P.x*Unit
        \\    kind<public>:=enum<closed>{round,square}
        \\  }
        \\  Private:=module{
        \\    Open<public>:i64=9
        \\  }
        \\  Peek<public>:i64=Private.Open
        \\}
        \\Closed:=module{
        \\  Value<public>:i64=1
        \\}
    ;
    const execution = try execute(h, &.{
        .{ .path = "main.forb", .source =
        \\L:=import{"lib.forb"}
        \\using{L.Shapes}
        \\P:L.Shapes.point=L.Shapes.point{x:=5}
        \\A<public>:i64=L.Shapes.Flat.Area(P)
        \\B<public>:i64=Flat.Area(point{x:=2})+Unit
        \\K:L.Shapes.Flat.kind=L.Shapes.Flat.kind.square
        \\C<public>:logic=K==Flat.kind.square
        \\D<public>:i64=L.Shapes.Peek
        \\Mine:=module{
        \\  using{L.Shapes.Flat}
        \\  Twice<public>(X:i64)<computes>:i64=Area(L.Shapes.point{x:=X})*2
        \\}
        \\E<public>:i64=Mine.Twice(3)
        },
        .{ .path = "lib.forb", .source = lib },
    });
    try std.testing.expectEqual(@as(i64, 20), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 12), try integer(execution, "B"));
    try std.testing.expectEqual(true, execution.get("C").?.boolean);
    try std.testing.expectEqual(@as(i64, 9), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 24), try integer(execution, "E"));
    try std.testing.expectEqual(@as(usize, 5), execution.program.nested.len);
    const Case = struct { root: []const u8, code: types.Diagnostic.Code };
    for ([_]Case{
        .{ .root = "L:=import{\"lib.forb\"}\nA:i64=L.Closed.Value", .code = .private_name },
        .{ .root = "L:=import{\"lib.forb\"}\nA:i64=L.Shapes.Private.Open", .code = .private_name },
        .{ .root = "L:=import{\"lib.forb\"}\nusing{L.Closed}", .code = .private_name },
        .{ .root = "L:=import{\"lib.forb\"}\nusing{L.Shapes.Private}", .code = .private_name },
        .{ .root = "L:=import{\"lib.forb\"}\nA:i64=L.Seed", .code = .private_name },
        .{ .root = "L:=import{\"lib.forb\"}\nA:i64=L.Shapes.Seed", .code = .unknown_name },
        .{ .root = "L:=import{\"lib.forb\"}\nA:i64=Shapes.Unit", .code = .unknown_name },
        .{ .root = "L:=import{\"lib.forb\"}\nM:=module{L:i64=1}", .code = .duplicate_name },
    }) |case| {
        const problem = rejected(h, &.{ .{ .path = "main.forb", .source = case.root }, .{ .path = "lib.forb", .source = lib } }) catch |err| {
            std.debug.print("nested admitted:\n{s}\n", .{case.root});
            return err;
        };
        if (problem.diagnostic.code != case.code) std.debug.print("nested diagnostic for:\n{s}\n", .{case.root});
        try std.testing.expectEqual(case.code, problem.diagnostic.code);
        try std.testing.expectEqualStrings("main.forb", problem.path);
    }
    // A diagnostic inside a nested module of an imported file is located in that file.
    const located = try rejected(h, &.{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA:i64=1" },
        .{ .path = "lib.forb", .source = "A:=module{\n  B:=module{\n    V:i64=Missing\n  }\n}" },
    });
    try std.testing.expectEqualStrings("lib.forb", located.path);
    try std.testing.expectEqual(types.Diagnostic.Code.unknown_name, located.diagnostic.code);
    try std.testing.expectEqual(@as(u32, 3), located.diagnostic.location(located.source).line);
}

test "a public type alias is named from other modules and cannot expose a type they cannot name" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try execute(h, &.{
        .{ .path = "main.forb", .source =
        \\L:=import{"lib.forb"}
        \\using{L}
        \\G:L.Grid=array{array{1,2},array{3,4}}
        \\A<public>:i64=L.Total(G)
        \\H:Grid=array{array{5}}
        \\B<public>:i64=Total(H)
        \\P:L.Geo.Pair=tuple{6,7}
        \\C<public>:i64=P(0)*P(1)
        \\Local<public>:=L.Grid
        \\W:L.Spot=L.spot{x:=8}
        \\D<public>:i64=W.x
        },
        .{ .path = "lib.forb", .source =
        \\Grid<public>:=[][]i64
        \\Row:=[]i64
        \\spot<public>:=struct{x:i64=0}
        \\Spot<public>:=spot
        \\Length(G:Grid)<computes>:i64=G.Length
        \\Total<public>(G:Grid)<computes>:i64=Attempt(G[0][0]+G[Length(G)-1][0],-1)
        \\Geo<public>:=module{
        \\  Pair<public>:=tuple(i64,i64)
        \\  Inner<internal>:=[]i64
        \\}
        },
    });
    try std.testing.expectEqual(@as(i64, 4), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 10), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 42), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 8), try integer(execution, "D"));
    const Case = struct { root: []const u8, dependency: []const u8, code: types.Diagnostic.Code, path: []const u8 = "main.forb" };
    for ([_]Case{
        .{ .root = "L:=import{\"b.forb\"}\nA:L.Row=array{1}", .dependency = "Row:=[]i64", .code = .private_name },
        .{ .root = "L:=import{\"b.forb\"}\nA:L.Row=array{1}", .dependency = "Row<internal>:=[]i64", .code = .private_name },
        .{ .root = "L:=import{\"b.forb\"}\nusing{L}\nA:Row=array{1}", .dependency = "Row:=[]i64", .code = .unsupported_type },
        .{ .root = "L:=import{\"b.forb\"}\nA:L.Geo.Inner=array{1}", .dependency = "Geo<public>:=module{Inner:=[]i64}", .code = .private_name },
        .{ .root = "L:=import{\"b.forb\"}", .dependency = "secret:=struct{x:i64=0}\nOpen<public>:=secret", .code = .private_type_escape, .path = "b.forb" },
        .{ .root = "L:=import{\"b.forb\"}", .dependency = "secret:=enum{a}\nOpen<public>:=[]option(secret)", .code = .private_type_escape, .path = "b.forb" },
        .{ .root = "L:=import{\"b.forb\"}", .dependency = "M:=module{secret:=struct{x:i64=0}\nOpen<public>:=secret}", .code = .private_type_escape, .path = "b.forb" },
        .{ .root = "L:=import{\"b.forb\"}", .dependency = "Open<private>:=[]i64", .code = .unsupported_specifier, .path = "b.forb" },
    }) |case| {
        const problem = rejected(h, &.{ .{ .path = "main.forb", .source = case.root }, .{ .path = "b.forb", .source = case.dependency } }) catch |err| {
            std.debug.print("nested admitted:\n{s}\n{s}\n", .{ case.root, case.dependency });
            return err;
        };
        if (problem.diagnostic.code != case.code) std.debug.print("nested diagnostic for:\n{s}\n{s}\n", .{ case.root, case.dependency });
        try std.testing.expectEqual(case.code, problem.diagnostic.code);
        try std.testing.expectEqualStrings(case.path, problem.path);
    }
    // A public alias is still only a second name: a program without modules may say it too.
    const plain = try h.execute("Grid<public>:=[]i64\nG:Grid=array{1,2}\nA:i64=G.Length");
    try std.testing.expectEqual(@as(i64, 2), plain.get("A").?.integer);
}

test "a public declaration exposes only types nameable wherever it can be used" {
    const h = try harness.create();
    defer scratch.release(h);
    // A type private to a nested module leaves it through nothing public.
    try expectCode(h, .private_type_escape, "M:=module{t:=struct{x:i64=0}\nMake<public>()<computes>:t=t{}}");
    try expectCode(h, .private_type_escape, "M:=module{t:=struct{x:i64=0}\nV<public>:t=t{}}");
    try expectCode(h, .private_type_escape, "M:=module{t:=struct{x:i64=0}\nvar V<public>:[]t=array{}}");
    try expectCode(h, .private_type_escape, "M:=module{t:=struct{x:i64=0}\nTake<public>(X:t)<computes>:i64=X.x}");
    try expectCode(h, .private_type_escape, "M:=module{t:=struct{x:i64=0}\nwrap<public>:=struct{inner:t}}");
    try expectCode(h, .private_type_escape, "M:=module{t:=enum{a}\nbox<public>:=class{inner<public>:option(t)=option{}}}");
    try expectCode(h, .private_type_escape, "M:=module{t:=enum{a}\nbox<public>:=class{inner<protected>:option(t)=option{}}}");
    try expectCode(h, .private_type_escape, "M:=module{t:=struct{x:i64=0}\nId<public>[u:type](X:u,Y:t)<computes>:u{X}}");
    // A public type of a module that is not public is nameable inside the scope that declares
    // the module, and no further: the root file's public binding would carry it to importers.
    try expectCode(h, .private_type_escape, "M:=module{t<public>:=struct{x:i64=0}}\nV<public>:M.t=M.t{}");
    try expectCode(h, .private_type_escape, "A<public>:=module{B:=module{t<public>:=struct{x:i64=0}}\nV<public>:B.t=B.t{}}");
    try expectCode(h, .private_type_escape, "A:=module{B:=module{C:=module{t<public>:=struct{x:i64=0}}\nV<public>:C.t=C.t{}}}");
    // The same declarations are fine where their users can all name the type.
    const execution = try one(h,
        \\secret:=struct{x:i64=3}
        \\M:=module{
        \\  t<public>:=struct{x:i64=4}
        \\  Make<public>()<computes>:t=t{}
        \\  Keep<public>()<computes>:secret=secret{}
        \\  Inner:=module{
        \\    u<public>:=struct{y:i64=5}
        \\    Build<public>()<computes>:u=u{}
        \\  }
        \\  Sum<public>:i64=Inner.Build().y+Make().x
        \\}
        \\Pub<public>:=module{
        \\  t<public>:=struct{x:i64=6}
        \\  Nest<public>:=module{
        \\    Make<public>()<computes>:t=t{}
        \\  }
        \\}
        \\Held:M.t=M.Make()
        \\A<public>:i64=Held.x+M.Keep().x+M.Sum
        \\B<public>:Pub.t=Pub.Nest.Make()
        \\C<public>:i64=B.x
    );
    try std.testing.expectEqual(@as(i64, 16), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 6), try integer(execution, "C"));
}

test "a var field may be read more widely than it is assigned" {
    const h = try harness.create();
    defer scratch.release(h);
    // The Book, 12_access.md "Separating Read and Write Access".
    const source =
        \\state:=class{
        \\  var<protected> Score<public>:i64=0
        \\  var<private> Count<public>:i64=0
        \\  var<private> Session<internal>:string="s"
        \\  var<public> Open<public>:i64=1
        \\  var Plain:i64=2
        \\  Win()<transacts>:i64=Block{set Self.Score=Self.Score+10;set Self.Count=Self.Count+1;Self.Score}
        \\}
        \\child:=class(state){
        \\  Bonus()<transacts>:i64=Block{set Self.Score=Self.Score+5;Self.Score+Self.Count}
        \\}
        \\Read(S:state)<transacts>:i64=S.Score+S.Count+S.Open+S.Plain
        \\Poke(S:state)<transacts>:i64=Block{set S.Open=7;set S.Plain=8;S.Open+S.Plain}
        \\S:state=state{Session:="s1"}
        \\A<public>:i64=S.Win()
        \\B<public>:i64=Read(S)
        \\C:child=child{}
        \\D<public>:i64=C.Win()+C.Bonus()
        \\E<public>:i64=Poke(S)
    ;
    const execution = try one(h, source);
    try std.testing.expectEqual(@as(i64, 10), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 14), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 26), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 15), try integer(execution, "E"));
    const single = try h.execute(source);
    try std.testing.expectEqual(@as(i64, 15), single.get("E").?.integer);
    const prefix = "state:=class{var<protected> Score<public>:i64=0,var<private> Count<public>:i64=0}\nchild:=class(state){Reset()<transacts>:i64=Block{set Self.Score=0;0}}\n";
    const Case = struct { []const u8, types.Diagnostic.Code };
    for ([_]Case{
        .{ "Bad(S:state)<transacts>:i64=Block{set S.Score=1;1}", .inaccessible_member },
        .{ "Bad(S:state)<transacts>:i64=Block{set S.Count=1;1}", .inaccessible_member },
        .{ "Bad(S:state)<transacts>:i64=Block{set S.Count+=1;1}", .inaccessible_member },
        .{ "worse:=class(state){Bad()<transacts>:i64=Block{set Self.Count=1;1}}", .inaccessible_member },
        // The write access is never wider than the read access, and belongs to `var` fields.
        .{ "c:=class{var<public> X<private>:i64=0}", .unsupported_specifier },
        .{ "c:=class{var<protected> X<private>:i64=0}", .unsupported_specifier },
        .{ "c:=class{var<friend> X:i64=0}", .unsupported_specifier },
        .{ "c:=class{var<private><private> X:i64=0}", .expected_field },
        .{ "i:=interface{var<private> X:i64}", .invalid_interface },
        .{ "c:=class(state){var<public> Score<override>:i64=3}", .override_mismatch },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, case[0] });
        const result = h.front.compile(text);
        if (result == .ok) std.debug.print("write access admitted: {s}\n", .{case[0]});
        try std.testing.expect(result == .failed);
        if (result.failed.code != case[1]) std.debug.print("write access diagnostic for {s}: {s}\n", .{ case[0], result.failed.message() });
        try std.testing.expectEqual(case[1], result.failed.code);
    }
    // An override that restates both accesses as they are is accepted.
    _ = try h.execute(prefix ++ "c:=class(state){var<protected> Score<override><public>:i64=3}\nX:c=c{}\nA:i64=1");
}

test "macros expand inside nested modules and their generated names stay out of reach" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try one(h,
        \\Outer:=module{
        \\  Items:[]i64=array{1,2,3,4}
        \\  Inner<public>:=module{
        \\    kind:=enum<closed>{small,big}
        \\    Doubled<public>()<computes>:[]i64=For(X:Items,X*2)
        \\    Evens<public>()<computes>:[]i64=For(I->X:Items,X>2,X+I)
        \\    Name(K:kind)<computes>:i64=Case(K,kind.small=>1,kind.big=>2)
        \\    Sized<public>(X:i64)<computes>:i64=Name(If(X>2,kind.big,kind.small))
        \\    Found<public>()<computes><decides>:i64=First[X:Items,X>2,X]
        \\    Count<public>()<transacts>:i64=Block{var N:i64=0;Loop{If(N>=5,Break(),false);set N=N+1};N}
        \\    Pair<public>()<computes>:i64=Block{(A,B):=tuple{20,22};A+B}
        \\    Early<public>(X:i64)<computes>:i64=Block{If(X>0,Return(X),false);0-X}
        \\    Walk<public>()<transacts>:i64=Block{var T:i64=0;While(T<10,Block{set T=T+3});T}
        \\    Deep<public>:=module{
        \\      Sum<public>()<computes>:i64=For(X:Items,Y:Items,X<Y,X*Y).Length
        \\    }
        \\  }
        \\}
        \\A<public>:[]i64=Outer.Inner.Doubled()
        \\B<public>:[]i64=Outer.Inner.Evens()
        \\C<public>:i64=Outer.Inner.Sized(1)+Outer.Inner.Sized(5)
        \\D<public>:i64=Attempt(Outer.Inner.Found[],0)
        \\E<public>:i64=Outer.Inner.Count()
        \\F<public>:i64=Outer.Inner.Pair()
        \\G<public>:i64=Outer.Inner.Early(4)+Outer.Inner.Early(-3)
        \\H<public>:i64=Outer.Inner.Walk()
        \\I<public>:i64=Outer.Inner.Deep.Sum()
    );
    const doubled = execution.elements(execution.get("A").?).?;
    try std.testing.expectEqual(@as(usize, 4), doubled.len);
    try std.testing.expectEqual(@as(i64, 8), doubled[3].integer);
    const evens = execution.elements(execution.get("B").?).?;
    try std.testing.expectEqual(@as(usize, 2), evens.len);
    try std.testing.expectEqual(@as(i64, 5), evens[0].integer);
    try std.testing.expectEqual(@as(i64, 7), evens[1].integer);
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 5), try integer(execution, "E"));
    try std.testing.expectEqual(@as(i64, 42), try integer(execution, "F"));
    try std.testing.expectEqual(@as(i64, 7), try integer(execution, "G"));
    try std.testing.expectEqual(@as(i64, 12), try integer(execution, "H"));
    try std.testing.expectEqual(@as(i64, 6), try integer(execution, "I"));
    // Generated names are library text: no module, however nested, can spell one.
    for ([_][]const u8{
        "M:=module{F()<computes>:[]i64=For(X:array{1},__for_items.Length)}",
        "M:=module{N:=module{F()<computes>:[]i64=For(X:array{1},__for_f(X))}}",
        "M:=module{__t0:i64=1}",
        "M:=module{F()<computes>:i64=Block{(A,B):=tuple{1,2};__t0(0)}}",
        "M:=module{F(X:i64)<computes>:i64=Block{If(X>0,Return(X),false);__ret}}",
        "M:=module{V<public>:i64=1}\nA:i64=M.__t0",
        "M:=module{F()<transacts>:i64=Block{var N:i64=0;Loop{set N=N+1;If(N>2,Break(),false)};__exit_s}}",
    }) |source| {
        const problem = rejected(h, &.{.{ .path = "main.forb", .source = source }}) catch |err| {
            std.debug.print("generated name admitted:\n{s}\n", .{source});
            return err;
        };
        const refused = problem.diagnostic.code == .unknown_name or problem.diagnostic.code == .expected_name or problem.diagnostic.code == .expected_type;
        if (!refused) std.debug.print("generated name diagnostic: {s} for\n{s}\n", .{ problem.diagnostic.message(), source });
        try std.testing.expect(refused);
        try std.testing.expect(problem.diagnostic.span.end <= source.len);
    }
}

test "classes of nested modules are declared ahead, inherit across modules and keep member access" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try one(h,
        \\shape:=interface{Area<public>()<transacts>:i64}
        \\Geo:=module{
        \\  base<public>:=class{
        \\    var Seen<protected>:i64=0
        \\    link:option(leaf)=option{}
        \\    Touch<public>()<transacts>:i64=Block{set Self.Seen=Self.Seen+1;Self.Seen}
        \\  }
        \\  leaf<public>:=class(base,shape){
        \\    side<public>:i64=2
        \\    Area<override>()<transacts>:i64=Self.side*Self.side+Self.Seen
        \\    Touch<override>()<transacts>:i64=Super.Touch()+100
        \\  }
        \\  More<public>:=module{
        \\    twig<public>:=class(leaf){
        \\      Area<override>()<transacts>:i64=Super.Area()+1000
        \\    }
        \\    Make<public>()<transacts>:twig=twig{side:=3}
        \\  }
        \\}
        \\Measure(S:shape)<transacts>:i64=S.Area()
        \\L:Geo.leaf=Geo.leaf{side:=5}
        \\A<public>:i64=L.Touch()
        \\B<public>:i64=Measure(L)
        \\T:Geo.More.twig=Geo.More.Make()
        \\C<public>:i64=Measure(T)
        \\D<public>:i64=T.Touch()
    );
    try std.testing.expectEqual(@as(i64, 101), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 26), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 1009), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 101), try integer(execution, "D"));
    try expectCode(h, .inaccessible_member, "G:=module{c<public>:=class{var Seen<protected>:i64=0}}\nRead(X:G.c)<transacts>:i64=X.Seen");
    try expectCode(h, .private_name, "G:=module{c:=class{v:i64=0}}\nX:G.c=G.c{}");
    // Two modules may each declare a type, a function and a cell of one name. RFC-0076: not a
    // module inside the other, so `B` stands beside `A` here; the file's own come later.
    const twins = try one(h,
        \\A:=module{
        \\  t<public>:=struct{x:i64=1}
        \\  F<public>()<computes>:i64=10
        \\  var C<public>:i64=100
        \\  Sum<public>()<transacts>:i64=F()+C+t{}.x
        \\}
        \\B:=module{
        \\  t<public>:=struct{x:i64=2,y:i64=3}
        \\  F<public>()<computes>:i64=20
        \\  var C<public>:i64=200
        \\  Sum<public>()<transacts>:i64=F()+C+t{}.y
        \\}
        \\t:=struct{z:i64=4}
        \\F()<computes>:i64=30
        \\var C:i64=300
        \\X<public>:i64=A.Sum()+B.Sum()+F()+C+t{}.z
    );
    try std.testing.expectEqual(@as(i64, 111 + 223 + 334), try integer(twins, "X"));
    try expectAt(h, .shadowed_name, "rec", 1, "A:=module{\n  rec:=struct{x:i64=1}\n  B:=module{\n    rec:=struct{y:i64=3}\n  }\n}");
    try expectAt(h, .shadowed_name, "F", 1, "A:=module{\n  F()<computes>:i64=10\n  B:=module{\n    F()<computes>:i64=20\n  }\n}");
    try expectAt(h, .shadowed_name, "C", 1, "A:=module{\n  var C:i64=100\n  B:=module{\n    var C:i64=200\n  }\n}");
}

test "nested modules stop exactly at the module capacity and at the nesting depth" {
    try @import("profile.zig").requireBootstrap();
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    // As many modules as the table holds, side by side; one more is refused where it is declared.
    for ([_]usize{ types.limits.modules, types.limits.modules + 1 }) |count| {
        source.clearRetainingCapacity();
        for (0..count) |index| try source.writer.print("M{d}<public>:=module{{V<public>:i64={d}}}\n", .{ index, index });
        try source.writer.print("Last<public>:i64=M{d}.V\n", .{types.limits.modules - 1});
        if (count == types.limits.modules) {
            const execution = try one(h, source.written());
            try std.testing.expectEqual(@as(i64, types.limits.modules - 1), try integer(execution, "Last"));
            try std.testing.expectEqual(count, execution.program.nested.len);
        } else {
            const problem = try rejected(h, &.{.{ .path = "main.forb", .source = source.written() }});
            try std.testing.expectEqual(types.Diagnostic.Code.module_limit, problem.diagnostic.code);
            try std.testing.expectEqualStrings("M64", problem.diagnostic.span.text(problem.source));
        }
    }
    // As deep as modules nest, each reading the one around it; one level more is refused.
    for ([_]usize{ types.limits.module_depth, types.limits.module_depth + 1 }) |depth| {
        source.clearRetainingCapacity();
        try source.writer.writeAll("D0<public>:=module{\nW0<public>:i64=1\n");
        for (1..depth) |level| try source.writer.print("D{d}<public>:=module{{\nW{d}<public>:i64=W{d}+1\n", .{ level, level, level - 1 });
        for (0..depth) |_| try source.writer.writeAll("}\n");
        try source.writer.writeAll("Deepest<public>:i64=D0");
        for (1..depth) |level| try source.writer.print(".D{d}", .{level});
        try source.writer.print(".W{d}\n", .{depth - 1});
        if (depth == types.limits.module_depth) {
            const execution = try one(h, source.written());
            try std.testing.expectEqual(@as(i64, @intCast(depth)), try integer(execution, "Deepest"));
            // The chain without its outermost entry is as well formed, but it is not what the
            // text declares: a table may not drop a module.
            var table: [types.limits.module_depth]types.NestedModule = undefined;
            @memcpy(&table, execution.program.nested);
            var forged = execution.program;
            forged.nested = table[1..];
            for (table[1..]) |*entry| entry.parent -%= 1;
            table[1].parent = types.no_parent;
            try std.testing.expect(!modules.validateNested(forged.source, forged.modules, forged.nested));
            forged.nested = &.{};
            try std.testing.expect(!modules.validateNested(forged.source, forged.modules, forged.nested));
        } else {
            const problem = try rejected(h, &.{.{ .path = "main.forb", .source = source.written() }});
            try std.testing.expectEqual(types.Diagnostic.Code.module_limit, problem.diagnostic.code);
            try std.testing.expectEqualStrings("D16", problem.diagnostic.span.text(problem.source));
        }
    }
    _ = try one(h, "M:=module{V<public>:i64=1}\nA<public>:i64=M.V");
}

test "a program that declares a type named module keeps constructing values of it" {
    const h = try harness.create();
    defer scratch.release(h);
    // `Name := module{...}` meant this before modules could nest, and still does here.
    const execution = try one(h, "module:=struct{x:i64=1,y:i64=2}\nM:=module{x:=40}\nA<public>:i64=M.x+M.y");
    try std.testing.expectEqual(@as(i64, 42), try integer(execution, "A"));
    try std.testing.expectEqual(@as(usize, 0), execution.program.nested.len);
    const imported = try execute(h, &.{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nM:=module{x:=5}\nA<public>:i64=M.x" },
        .{ .path = "lib.forb", .source = "module<public>:=struct{x:i64=1}" },
    });
    try std.testing.expectEqual(@as(i64, 5), try integer(imported, "A"));
    // Without a bundle there are no modules to nest: the line is the unknown type it was.
    try std.testing.expect(h.front.compile("M:=module{V:i64=1}") == .failed);
    const plain = try h.execute("module:=struct{x:i64=1}\nM:=module{x:=7}\nA:i64=M.x");
    try std.testing.expectEqual(@as(i64, 7), plain.get("A").?.integer);
    // Only a statement of a module body declares a module: the same words inside an
    // expression, or split over lines, are not a declaration.
    try expectCode(h, .unknown_name, "F()<computes>:i64=Block{M:=module{};1}");
    try std.testing.expect((rejected(h, &.{.{ .path = "main.forb", .source = "M:=module\n{V<public>:i64=1}\nA:i64=M.V" }}) catch unreachable).diagnostic.code != .module_limit);
    const spaced = try one(h, "M <public> := module {\n  V<public>:i64=3 }\nN\t:=\tmodule{}; A<public>:i64=M.V");
    try std.testing.expectEqual(@as(i64, 3), try integer(spaced, "A"));
    try std.testing.expectEqual(@as(usize, 2), spaced.program.nested.len);
}

test "cells of nested modules roll back with a failed attempt and report through their module" {
    const h = try harness.create();
    defer scratch.release(h);
    const source =
        \\Bank<public>:=module{
        \\  var Balance<public>:i64=100
        \\  Vault<public>:=module{
        \\    var Count<public>:i64=0
        \\    tone<public>:=enum<closed>{calm,loud}
        \\    Take<public>(N:i64)<transacts><decides>:i64=Block{set Balance=Balance-N;set Count=Count+1;Require[Balance>=0];Balance}
        \\    Step<public>(X:i64)<computes>:i64=X+1
        \\  }
        \\  Try<public>(N:i64)<transacts>:i64=Attempt(Vault.Take[N],-1)
        \\}
        \\A<public>:i64=Bank.Try(30)
        \\B<public>:i64=Bank.Try(500)
        \\C<public>:i64=Bank.Balance
        \\D<public>:i64=Bank.Vault.Count
        \\E<public>:Bank.Vault.tone=Bank.Vault.tone.loud
        \\F<public>:function(tuple(i64),i64)=Bank.Vault.Step
    ;
    const execution = try one(h, source);
    try std.testing.expectEqual(@as(i64, 70), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, -1), try integer(execution, "B"));
    // The failed withdrawal left neither the balance nor the count changed.
    try std.testing.expectEqual(@as(i64, 70), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 1), try integer(execution, "D"));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try reporting.write(&out.writer, execution, true, .{});
    try std.testing.expectEqualStrings("{\"A\":70,\"B\":-1,\"C\":70,\"D\":1,\"E\":\"main.forb::Bank.Vault.tone.loud\",\"F\":{\"function\":{\"name\":\"Step\",\"module\":\"main.forb\"}}}\n", out.written());
    // Inspection lists the modules of a file; a bundle without any prints what it always did.
    const workspace = try scratch.storage(inspection.Workspace);
    defer scratch.release(workspace);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out.writer, execution.program));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"nested_modules\":[{\"index\":0,\"name\":\"Bank\",\"module\":0,\"parent\":null,\"public\":true,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "{\"index\":1,\"name\":\"Vault\",\"module\":0,\"parent\":0,\"public\":true,") != null);
    var bad = execution.program;
    bad.nested = bad.nested[1..];
    out.clearRetainingCapacity();
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, (try workspace.write(&out.writer, bad)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    const flat = try execute(h, &.{ .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nA<public>:i64=L.V" }, .{ .path = "lib.forb", .source = "V<public>:i64=1" } });
    out.clearRetainingCapacity();
    try std.testing.expectEqual(inspection.Result.ok, try workspace.write(&out.writer, flat.program));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "nested_modules") == null);
}

test "internal says the default aloud on every declaration, and generic functions cross scopes" {
    const h = try harness.create();
    defer scratch.release(h);
    // With or without a bundle, `<internal>` is what no specifier is.
    const plain =
        \\Limit<internal>:i64=4
        \\var Count<internal>:i64=1
        \\rec<internal>:=struct{x:i64=2}
        \\tone<internal>:=enum<closed>{low,high}
        \\box<internal>:=class{v:i64=3}
        \\Grid<internal>:=[]i64
        \\Twice<internal>(X:i64)<computes>:i64=X*2
        \\Id<internal>[t:type](X:t)<computes>:t{X}
        \\(R:rec).Get<internal>()<computes>:i64=R.x
        \\A:i64=Twice(Limit)+Count+rec{}.Get()+Id[i64](5)
    ;
    try std.testing.expectEqual(@as(i64, 16), (try h.execute(plain)).get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 16), try integer(try one(h, plain), "A"));
    // Across a file boundary each of them is private.
    const Case = struct { use: []const u8, code: types.Diagnostic.Code = .private_name };
    for ([_]Case{
        .{ .use = "A:i64=L.Limit" },
        .{ .use = "A:i64=L.Count" },
        .{ .use = "A:L.rec=L.rec{}" },
        .{ .use = "A:L.tone=L.tone.low" },
        .{ .use = "A:L.box=L.box{}" },
        .{ .use = "A:L.Grid=array{1}" },
        .{ .use = "A:i64=L.Twice(1)" },
        .{ .use = "A:i64=L.Id[i64](1)" },
    }) |case| {
        var buffer: [128]u8 = undefined;
        const root = try std.fmt.bufPrint(&buffer, "L:=import{{\"lib.forb\"}}\n{s}", .{case.use});
        const problem = rejected(h, &.{ .{ .path = "main.forb", .source = root }, .{ .path = "lib.forb", .source = plain } }) catch |err| {
            std.debug.print("internal declaration admitted: {s}\n", .{case.use});
            return err;
        };
        if (problem.diagnostic.code != case.code) std.debug.print("internal diagnostic for {s}: {s}\n", .{ case.use, problem.diagnostic.message() });
        try std.testing.expectEqual(case.code, problem.diagnostic.code);
    }
    // A generic function is compiled where it is declared, whoever asks for it: its body
    // reads the scope of its own module, not the caller's. RFC-0076: a module may not redeclare
    // a name the file has declared before it, so each file's `Bias` now follows its module.
    const execution = try execute(h, &.{
        .{ .path = "main.forb", .source =
        \\L:=import{"lib.forb"}
        \\Wrap[t:type](X:t)<computes>:t{X}
        \\Mine:=module{
        \\  Bias:i64=1
        \\  Add<public>[t:type](X:t)<computes>:i64{Bias}
        \\  Near<public>:i64=Wrap[i64](Bias)+L.Kit.Shift[i64](5)
        \\  Deep<public>:=module{
        \\    Far<public>:i64=Add[i64](7)+Wrap[i64](20)
        \\  }
        \\}
        \\Bias:i64=1000
        \\A<public>:i64=Mine.Add[string]("x")+Bias
        \\B<public>:i64=Mine.Near
        \\C<public>:i64=Mine.Deep.Far
        \\D<public>:i64=L.Kit.Shift[i64](1)
        },
        .{ .path = "lib.forb", .source =
        \\Kit<public>:=module{
        \\  Bias:i64=40
        \\  Shift<public>[t:type](X:t)<computes>:i64{Bias}
        \\}
        \\Bias:i64=300
        },
    });
    try std.testing.expectEqual(@as(i64, 1001), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 41), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 21), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 40), try integer(execution, "D"));
    // The example of the language guide.
    const guide = try one(h,
        \\Geometry<public> := module{
        \\  point<public> := struct{x:i64=0, y:i64=0}
        \\  Seed<internal>:i64 = 10
        \\  Flat<public> := module{
        \\    Area<public>(P:point)<computes>:i64 = P.x*P.y + Seed
        \\  }
        \\}
        \\using{Geometry.Flat}
        \\Twelve<public>:i64 = Area(Geometry.point{x:=1, y:=2})
    );
    try std.testing.expectEqual(@as(i64, 12), try integer(guide, "Twelve"));
}

test "loops in nested modules write the module's cells, not copies of them" {
    const h = try harness.create();
    defer scratch.release(h);
    // A loop carries the locals it assigns through its state; a cell is no local, wherever
    // it is declared, and a function called from the loop sees every write as it happens.
    const execution = try one(h,
        \\var Top:i64=0
        \\M:=module{
        \\  var Count<public>:i64=0
        \\  Peek()<transacts>:i64=Count+Top
        \\  Run<public>()<transacts>:i64=Block{var Seen:i64=0;While(Count<3,Block{set Count=Count+1;set Top=Top+10;set Seen=Seen+Peek()});Seen}
        \\  Inner<public>:=module{
        \\    var Steps<public>:i64=0
        \\    Read()<transacts>:i64=Steps*100+Count
        \\    Walk<public>()<transacts>:i64=Block{var Sum:i64=0;Loop{If(Steps>=2,Break(),false);set Steps=Steps+1;set Count=Count+1;set Sum=Sum+Read()};Sum}
        \\  }
        \\}
        \\A<public>:i64=M.Run()
        \\B<public>:i64=M.Count
        \\C<public>:i64=M.Inner.Walk()
        \\D<public>:i64=M.Count*1000+M.Inner.Steps*10+Top
    );
    try std.testing.expectEqual(@as(i64, 11 + 22 + 33), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 104 + 205), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 5050), try integer(execution, "D"));
}

test "macros at the top level of a nested module declare into that module" {
    const h = try harness.create();
    defer scratch.release(h);
    // A destructuring at module level binds its names in the module; the temporary it goes
    // through is library text and is published by no module.
    const execution = try one(h,
        \\(P,Q):=tuple{1,2}
        \\M:=module{
        \\  (A,B):=tuple{20,22}
        \\  Sum<public>:i64=A+B+P
        \\  N<public>:=module{
        \\    (E,C):=tuple{300,400}
        \\    Total<public>:i64=E+B+C+Q
        \\    Picked<public>:i64=If(E>0,D:=E+1,D>300,D,0)
        \\    Listed<public>:[]i64=For(X:array{E,B,C},X>21,X)
        \\  }
        \\}
        \\X<public>:i64=M.Sum
        \\Y<public>:i64=M.N.Total
        \\Z<public>:i64=M.N.Picked+M.N.Listed.Length
    );
    try std.testing.expectEqual(@as(i64, 43), try integer(execution, "X"));
    try std.testing.expectEqual(@as(i64, 724), try integer(execution, "Y"));
    try std.testing.expectEqual(@as(i64, 304), try integer(execution, "Z"));
    // The names of a nested module's destructuring are that module's, not the file's.
    try std.testing.expect(execution.get("A") == null and execution.get("B") == null and execution.get("C") == null);
    try std.testing.expectEqual(@as(i64, 1), try integer(execution, "P"));
    for (execution.program.bindings) |binding| try std.testing.expect(modules.innermost(binding.name, execution.program.nested) == null);
    try expectCode(h, .unknown_name, "M:=module{(A,B):=tuple{1,2}}\nX:i64=A");
    try expectCode(h, .private_name, "M:=module{(A,B):=tuple{1,2}}\nX:i64=M.A");
    try expectCode(h, .duplicate_name, "M:=module{(A,B):=tuple{1,2}\nA:i64=3}");
}

test "a function's own name is itself only where it resolves to its own scope" {
    const h = try harness.create();
    defer scratch.release(h);
    // Functions of one name in every relation the language still has: a path names the other
    // one, the bare name the function being compiled. RFC-0076: a module may not redeclare a
    // function a scope around it has declared before, so `B` and `C` stand beside `A` (they
    // were nested in it) and the file's own `F`, `G` and `Id` follow the modules.
    const execution = try one(h,
        \\A:=module{
        \\  F<public>(X:i64)<computes>:i64=X+10
        \\  G<public>(X:i64)<computes>:i64=X*2
        \\  Down<public>(X:i64)<computes>:i64=If(X<=0,0,Down(X-1)+1)
        \\}
        \\B:=module{
        \\  F<public>(X:i64)<computes>:i64=A.F(X)+100
        \\  G<public>(X:i64,Y:i64,Z:i64)<computes>:i64=A.G(X)+Y+Z
        \\  Down<public>(X:i64)<computes>:i64=If(X<=0,1000,Down(X-1))+A.Down(X)
        \\  Value<public>:function(tuple(i64),i64)=A.F
        \\  Id<public>[t:type](X:t)<computes>:i64{7}
        \\  Uses<public>:i64=Id[i64](1)
        \\}
        \\C:=module{
        \\  F<public>(X:i64)<computes>:i64=B.F(X)+1000
        \\  Up<public>(X:i64)<computes>:i64=F(X)
        \\}
        \\F(X:i64)<computes>:i64=X+1
        \\G(X:i64,Y:i64)<computes>:i64=X+Y
        \\Id[t:type](X:t)<computes>:t{X}
        \\R1<public>:i64=B.F(1)
        \\R2<public>:i64=B.G(1,2,3)
        \\R3<public>:i64=B.Down(2)
        \\R4<public>:i64=B.Value(5)
        \\R5<public>:i64=C.F(1)
        \\R6<public>:i64=C.Up(1)
        \\R7<public>:i64=B.Uses+Id[i64](1)+F(1)+G(1,1)
    );
    // The nested relation is refused where the inner function is declared, whatever its
    // parameters, and so is a generic function of the name.
    try expectAt(h, .shadowed_name, "F", 1, "F(X:i64)<computes>:i64=X+1\nA:=module{\n  F<public>(X:i64)<computes>:i64=X+10\n}");
    try expectAt(h, .shadowed_name, "G", 1, "A:=module{\n  G(X:i64)<computes>:i64=X*2\n  B:=module{\n    G(X:i64,Y:i64,Z:i64)<computes>:i64=X+Y+Z\n  }\n}");
    try expectAt(h, .shadowed_name, "Id", 1, "Id[t:type](X:t)<computes>:t{X}\nA:=module{Id[t:type](X:t)<computes>:i64{7}}");
    try std.testing.expectEqual(@as(i64, 111), try integer(execution, "R1"));
    try std.testing.expectEqual(@as(i64, 7), try integer(execution, "R2"));
    // Down(2) = (Down(1) + A.Down(2)); Down(1) = Down(0) + A.Down(1); Down(0) = 1000 + 0.
    try std.testing.expectEqual(@as(i64, 1003), try integer(execution, "R3"));
    try std.testing.expectEqual(@as(i64, 15), try integer(execution, "R4"));
    try std.testing.expectEqual(@as(i64, 1111), try integer(execution, "R5"));
    try std.testing.expectEqual(@as(i64, 1111), try integer(execution, "R6"));
    try std.testing.expectEqual(@as(i64, 7 + 1 + 2 + 2), try integer(execution, "R7"));
    // A method of the name of a module function, and the function called from the method. The
    // file's `Area` follows the module (RFC-0076, as above); a member name shadows nothing.
    const classes = try one(h,
        \\M:=module{
        \\  Area<public>(X:i64)<computes>:i64=X+1
        \\  box<public>:=class{side:i64=3,Area<public>()<transacts>:i64=M.Area(Self.side)}
        \\}
        \\Area(X:i64)<computes>:i64=X*X
        \\B:M.box=M.box{}
        \\R<public>:i64=B.Area()+Area(2)
    );
    try std.testing.expectEqual(@as(i64, 8), try integer(classes, "R"));
}

test "a bundle that declares its own module type is compiled as it always was, at any size" {
    const h = try harness.create();
    defer scratch.release(h);
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    // More constructions than the module table holds, and deeper than modules nest.
    try source.writer.writeAll("module:=struct{x:i64=0}\n");
    for (0..types.limits.modules + 6) |index| try source.writer.print("V{d}:=module{{x:={d}}}\n", .{ index, index });
    try source.writer.print("Last<public>:i64=V{d}.x\n", .{types.limits.modules + 5});
    const wide = try one(h, source.written());
    try std.testing.expectEqual(@as(i64, types.limits.modules + 5), try integer(wide, "Last"));
    try std.testing.expectEqual(@as(usize, 0), wide.program.nested.len);
    try std.testing.expectEqual(@as(i64, types.limits.modules + 5), (try h.execute(source.written())).get("Last").?.integer);
    source.clearRetainingCapacity();
    try source.writer.writeAll("module:=struct{x:i64=0}\nwrap:=struct{inner:module=module{}}\nDeep<public>:i64=Block{\n");
    for (0..types.limits.module_depth + 3) |index| try source.writer.print("L{d}:=module{{x:={d}}}\nBlock{{\n", .{ index, index });
    try source.writer.print("L{d}.x", .{types.limits.module_depth + 2});
    for (0..types.limits.module_depth + 4) |_| try source.writer.writeAll("}");
    try source.writer.writeAll("\n");
    const deep = try one(h, source.written());
    try std.testing.expectEqual(@as(i64, types.limits.module_depth + 2), try integer(deep, "Deep"));
    // The type may come from another file, declared after the constructions are read.
    const imported = try execute(h, &.{
        .{ .path = "main.forb", .source = "L:=import{\"lib.forb\"}\nusing{L}\nA:=module{x:=1}\nB:=module{x:=2}" },
        .{ .path = "lib.forb", .source = "module<public>:=struct{x:i64=1}" },
    });
    _ = imported;
}

test "separate write access holds through interfaces, overrides and paths" {
    const h = try harness.create();
    defer scratch.release(h);
    // An interface's `var` field is assigned by anyone who holds the interface, so only a
    // field that anyone may assign can stand for it; a field that is not `var` is only read.
    const Case = struct { field: []const u8, interface: []const u8, code: ?types.Diagnostic.Code };
    for ([_]Case{
        .{ .field = "var Health:i64=3", .interface = "var Health:i64", .code = null },
        // RFC-0076: an interface member is `<internal>` unless it says `<public>`, and the field
        // that stands in for it has its access; these three fields are public, so their
        // interface says so too.
        .{ .field = "var<public> Health<public>:i64=3", .interface = "var Health<public>:i64", .code = null },
        .{ .field = "var<private> Health<public>:i64=3", .interface = "var Health<public>:i64", .code = .inaccessible_member },
        .{ .field = "var<protected> Health<public>:i64=3", .interface = "var Health<public>:i64", .code = .inaccessible_member },
        // A stand-in of another access than the interface's is no stand-in, either way round.
        .{ .field = "var<public> Health<public>:i64=3", .interface = "var Health:i64", .code = .duplicate_name },
        .{ .field = "var Health:i64=3", .interface = "var Health<public>:i64", .code = .duplicate_name },
        .{ .field = "var<private> Health<private>:i64=3", .interface = "var Health:i64", .code = .duplicate_name },
        .{ .field = "var<protected> Health<protected>:i64=3", .interface = "var Health:i64", .code = .duplicate_name },
        .{ .field = "Health:i64=3", .interface = "Health:i64", .code = null },
        .{ .field = "Health<private>:i64=3", .interface = "Health:i64", .code = .duplicate_name },
        .{ .field = "var<private> Health<public>:i64=3", .interface = "Health<public>:i64", .code = .duplicate_name },
    }) |case| {
        var buffer: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "Entity:=interface{{{s}}}\nbase:=class{{{s}}}\nmob:=class(base,Entity){{}}\nA:i64=1", .{ case.interface, case.field });
        const result = h.front.compile(text);
        if ((result == .ok) != (case.code == null) or (result == .failed and result.failed.code != case.code.?)) {
            std.debug.print("interface field {s} against {s}: {s}\n", .{ case.field, case.interface, if (result == .ok) "admitted" else result.failed.message() });
            return error.InterfaceField;
        }
    }
    // The write the reviewer found: through the interface, into a field only the class assigns.
    try std.testing.expectEqual(types.Diagnostic.Code.inaccessible_member, h.front.compile("Entity:=interface{var Health<public>:i64}\nbase:=class{var<private> Health<public>:i64=3}\nmob:=class(base,Entity){}\nPoke(E:Entity)<transacts>:i64=Block{set E.Health=99;E.Health}\nM:mob=mob{}\nA:i64=Poke(M)").failed.code);
    const prefix = "counter:=class{var<private> Count<public>:i64=0}\nholder:=class{Inner:counter=counter{}}\nEntity:=interface{var Health:i64=10}\n";
    for ([_][]const u8{
        "H:holder=holder{}\nPoke()<transacts>:i64=Block{set H.Inner.Count=9;1}",
        "C:counter=counter{}\nPoke()<transacts>:i64=Block{D:=WithField(C,Count,9);1}",
        "C:counter=counter{}\nPoke()<transacts>:i64=Block{set C.Count+=1;1}",
        "child:=class(counter){var<public> Count<override><public>:i64=5}",
        "sub:=class(counter){}\nPoke(S:sub)<transacts>:i64=Block{set S.Count=1;1}",
        "mob:=class(Entity){var<private> Health<override>:i64=3}",
        "s:=struct{var<private> x<public>:i64=0}",
    }) |tail| {
        var buffer: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{s}{s}\nA:i64=1", .{ prefix, tail });
        const result = h.front.compile(text);
        if (result == .ok) std.debug.print("write access admitted: {s}\n", .{tail});
        try std.testing.expect(result == .failed);
    }
    // A class without the form assigns its fields as it always did, interface fields included.
    const plain = try h.execute("Entity:=interface{var Health:i64=10}\nbase:=class{var Health:i64=3}\nmob:=class(base,Entity){}\nPoke(E:Entity)<transacts>:i64=Block{set E.Health=99;E.Health}\nM:mob=mob{}\nA:i64=Poke(M)");
    try std.testing.expectEqual(@as(i64, 99), plain.get("A").?.integer);
}

test "extension methods of enclosing and used scopes, locals named like modules, and generic bodies" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try execute(h, &.{
        .{ .path = "main.forb", .source =
        \\L:=import{"lib.forb"}
        \\p:=struct{x:i64=1}
        \\q:=class{var x:i64=1}
        \\(N:i64).Twice()<computes>:i64=N*2
        \\X:i64=5
        \\Local(Cell:p)<transacts>:i64=Block{var M:p=p{};set M.x=5;M.x+Cell.x}
        \\Object(M:q)<transacts>:i64=Block{set M.x=7;M.x}
        \\Each()<transacts>:i64=For(M:array{q{},q{}},Block{set M.x=3;M.x}).Length
        \\Bound(O:option(q))<transacts>:i64=If(M:=O?,M.x>0,Block{set M.x=4;M.x},0)
        \\M:=module{
        \\  Get<public>[t:type](V:t)<computes>:i64{X}
        \\  Four<public>:i64=2.Twice()
        \\  using{L.Ext}
        \\  Inner<public>:=module{
        \\    Eight<public>:i64=4.Twice()+1.Thrice()
        \\    (N:i64).Twice()<computes>:i64=N*200
        \\    Far<public>:i64=1.Twice()
        \\  }
        \\  Own:i64=6
        \\  After<public>:i64=Get[i64](0)+Own
        \\}
        \\Cell:=module{var C<public>:i64=1}
        \\set Cell.C=Cell.C+10
        \\A<public>:i64=M.Four
        \\B<public>:i64=M.Inner.Eight
        \\C<public>:i64=M.Inner.Far
        \\D<public>:i64=M.After
        \\E<public>:i64=Local(p{x:=2})
        \\F<public>:i64=Object(q{})+Each()+Bound(option{q{}})
        \\G<public>:i64=Cell.C
        \\H<public>:i64=M.Get[string]("s")
        },
        .{ .path = "lib.forb", .source =
        \\Ext<public>:=module{
        \\  (N:i64).Thrice<public>()<computes>:i64=N*3
        \\  (N:i64).Hidden()<computes>:i64=N*4
        \\}
        },
    });
    try std.testing.expectEqual(@as(i64, 4), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 11), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 200), try integer(execution, "C"));
    // The body of `Get` means the file's `X`: 5, then the module's own 6. RFC-0076: the module
    // may not declare an `X` of its own after that (it did, and `Get` kept the file's), so the
    // 6 is `Own`; and a local may have the name of a module only if the module comes later,
    // so the four functions with a local `M` or `Cell` now stand before the two modules.
    try std.testing.expectEqual(@as(i64, 11), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 7), try integer(execution, "E"));
    try std.testing.expectEqual(@as(i64, 7 + 2 + 4), try integer(execution, "F"));
    try std.testing.expectEqual(@as(i64, 11), try integer(execution, "G"));
    try std.testing.expectEqual(@as(i64, 5), try integer(execution, "H"));
    try expectCode(h, .private_name, "E:=module{(N:i64).Hidden()<computes>:i64=N*4}\nM:=module{using{E}\nA:i64=1.Hidden()}");
    try expectCode(h, .private_name, "E:=module{(N:i64).Hidden()<computes>:i64=N*4}\nusing{E}\nA:i64=1.Hidden()");
    // A later declaration at any level is not what an earlier generic body meant.
    try expectCode(h, .unknown_name, "A:=module{Get<public>[t:type](V:t)<computes>:i64{Y}\nY:i64=1}\nR:i64=A.Get[i64](0)");
    // RFC-0076: with a `Y` already declared around them, the later ones at the levels between
    // are refused (they were admitted, and the body kept meaning the file's `Y`); under other
    // names the body reads the file's, as it did.
    const levels = try one(h,
        \\Y:i64=1
        \\A:=module{
        \\  B<public>:=module{
        \\    Get<public>[t:type](V:t)<computes>:i64{Y}
        \\    Y3:i64=3
        \\  }
        \\  Y2:i64=2
        \\  R<public>:i64=B.Get[i64](0)
        \\}
        \\R<public>:i64=A.R+A.B.Get[logic](true)
    );
    try std.testing.expectEqual(@as(i64, 2), try integer(levels, "R"));
    try expectAt(h, .shadowed_name, "Y", 2, "Y:i64=1\nA:=module{\n  B<public>:=module{\n    Get<public>[t:type](V:t)<computes>:i64{Y}\n    Y:i64=3\n  }\n}");
    try expectAt(h, .shadowed_name, "Y", 2, "Y:i64=1\nA:=module{\n  B<public>:=module{\n    Get<public>[t:type](V:t)<computes>:i64{Y}\n  }\n  Y:i64=2\n}");
    // A local, a parameter, a `For` variable and an `If` binding of the name of a module that
    // is already declared.
    try expectAt(h, .shadowed_name, "Cell", 1, "p:=struct{x:i64=1}\nCell:=module{}\nLocal(Cell:p)<computes>:i64=Cell.x");
    try expectAt(h, .shadowed_name, "M", 1, "p:=struct{x:i64=1}\nM:=module{}\nLocal()<transacts>:i64=Block{var M:p=p{};M.x}");
    try expectAt(h, .shadowed_name, "M", 1, "q:=class{var x:i64=1}\nM:=module{}\nEach()<transacts>:i64=For(M:array{q{},q{}},M.x).Length");
    try expectAt(h, .shadowed_name, "M", 1, "q:=class{var x:i64=1}\nM:=module{}\nBound(O:option(q))<transacts>:i64=If(M:=O?,M.x>0,M.x,0)");
}

test "every macro form works at the top level of nested modules, also in an imported file" {
    const h = try harness.create();
    defer scratch.release(h);
    const body =
        \\  Items:[]i64=array{1,2,3,4}
        \\  kind:=enum<closed>{small,big}
        \\  Deep<public>:=module{
        \\    (A,B):=tuple{20,22}
        \\    Mapped:[]i64=For(X:Items,X>1,X*A)
        \\    Found:i64=Attempt(First[X:Items,X>2,X],0)
        \\    Picked:i64=If(A>0,D:=A+1,D>20,D,0)
        \\    Named:i64=Case(If(B>21,kind.big,kind.small),kind.small=>1,kind.big=>2)
        \\    var Count:i64=0
        \\    Walk()<transacts>:i64=Block{Defer{set Count=Count+100};While(Count<3,Block{set Count=Count+1});Loop{If(Count>=6,Break(),false);set Count=Count+1};Count}
        \\    Walked:i64=Walk()
        \\    Refused:logic=logic{Not[Require[A>B]]}
        \\    Sum<public>:i64=Mapped.Length+Found+Picked+Named+Walked+Count+If(Refused,1000,0)
        \\  }
    ;
    var main: [2048]u8 = undefined;
    var lib: [2048]u8 = undefined;
    const execution = try execute(h, &.{
        .{ .path = "main.forb", .source = try std.fmt.bufPrint(&main, "L:=import{{\"lib.forb\"}}\nOuter:=module{{\n{s}\n}}\nMine<public>:i64=Outer.Deep.Sum\nTheirs<public>:i64=L.Outer.Deep.Sum\n", .{body}) },
        .{ .path = "lib.forb", .source = try std.fmt.bufPrint(&lib, "Outer<public>:=module{{\n{s}\n}}\n", .{body}) },
    });
    // 3 mapped, 3 found, 21 picked, 2 named, 6 walked, cell 106 after the Defer, 1000.
    try std.testing.expectEqual(@as(i64, 3 + 3 + 21 + 2 + 6 + 106 + 1000), try integer(execution, "Mine"));
    try std.testing.expectEqual(try integer(execution, "Mine"), try integer(execution, "Theirs"));
}

test "a table cannot name a module the text does not declare, or leave one out" {
    const h = try harness.create();
    defer scratch.release(h);
    const Case = struct { source: []const u8, name: []const u8 };
    for ([_]Case{
        // A construction of the program's own `module` type has the shape of a declaration.
        .{ .source = "module:=struct{x:i64=0}\nV:=module{x:=3}\nA<public>:i64=V.x", .name = "V" },
        // So have words in a comment and inside an expression.
        .{ .source = "# C:=module{}\nA<public>:i64=1", .name = "C" },
        .{ .source = "rec:=struct{x:i64=0}\nF()<computes>:i64=Block{M:=rec{}\nM.x}\nA<public>:i64=F()", .name = "M" },
    }) |case| {
        const program = try compile(h, &.{.{ .path = "main.forb", .source = case.source }});
        try std.testing.expectEqual(@as(usize, 0), program.nested.len);
        // The entry a forger would write: the name, and the braces after it.
        const at: u32 = @intCast(std.mem.indexOf(u8, program.source, case.name).?);
        const open: u32 = @intCast(std.mem.indexOfScalarPos(u8, program.source, at, '{').?);
        const close: u32 = @intCast(std.mem.indexOfScalarPos(u8, program.source, open, '}').?);
        const table = [_]types.NestedModule{.{ .name = .{ .start = at, .end = at + @as(u32, @intCast(case.name.len)) }, .source = .{ .start = open + 1, .end = close }, .parent = types.no_parent, .is_public = false }};
        var forged = program;
        forged.nested = &table;
        try std.testing.expect(evaluator.validate(forged, h.values.len) != null);
        try std.testing.expect(bytecode.lower(forged, &h.runtime.instructions) != .ok);
        var raw = bytecode.lower(program, &h.runtime.instructions).ok;
        raw.nested = &table;
        try std.testing.expect(vm.verify(raw, &h.runtime.machine.register_types) == .failed);
        _ = try h.run(program, fuel);
    }
    // Without its table, a module's private names would be the file's: refused as well.
    const program = try compile(h, &.{.{ .path = "main.forb", .source = "M:=module{Secret:i64=1}\nA<public>:i64=2" }});
    var bare = program;
    bare.nested = &.{};
    try std.testing.expect(evaluator.validate(bare, h.values.len) != null);
    var raw = bytecode.lower(program, &h.runtime.instructions).ok;
    raw.nested = &.{};
    try std.testing.expect(vm.verify(raw, &h.runtime.machine.register_types) == .failed);
}

// ---- RFC-0074 together with RFC-0075: constructor functions, delegation, class `Block{...}`
// clauses, `<final>` and extension methods, in modules declared inside the files of a bundle.

const lib_import = "L:=import{\"lib.forb\"}\n";

/// The values of `main` over `lib`, both files of one bundle.
fn pair(h: *harness.Harness, comptime main: []const u8, lib: []const u8) !evaluator.Execution {
    return execute(h, &.{ .{ .path = "main.forb", .source = lib_import ++ main }, .{ .path = "lib.forb", .source = lib } });
}

/// `main` over `lib` must be refused with `expected`.
fn pairCode(h: *harness.Harness, expected: types.Diagnostic.Code, comptime main: []const u8, lib: []const u8) !void {
    const problem = rejected(h, &.{ .{ .path = "main.forb", .source = lib_import ++ main }, .{ .path = "lib.forb", .source = lib } }) catch |err| {
        std.debug.print("bundle admitted:\n{s}\n", .{main});
        return err;
    };
    if (problem.diagnostic.code != expected) std.debug.print("bundle diagnostic {s} for:\n{s}\n", .{ @tagName(problem.diagnostic.code), main });
    try std.testing.expectEqual(expected, problem.diagnostic.code);
}

/// The function `name` that the nested module `module` declares.
fn functionIn(program: types.Program, module: []const u8, name: []const u8) !u32 {
    const scope = for (program.nested) |entry| {
        if (std.mem.eql(u8, entry.name.text(program.source), module)) break entry.source;
    } else return error.NoSuchModule;
    for (program.functions, 0..) |function, index| {
        if (modules.within(scope, function.name, program.nested) and std.mem.eql(u8, function.name.text(program.source), name)) return @intCast(index);
    }
    std.debug.print("no function {s} in {s}\n", .{ name, module });
    return error.NoSuchFunction;
}

const constructor_lib =
    \\Seed:i64=2
    \\Shapes<public>:=module{
    \\  shape<public>:=class{Id<public>:i64=0,var Tag<public>:i64=0,Block{set Self.Tag=Self.Id+Seed}}
    \\  Make<public><constructor>(Id:i64)<transacts>:=shape{Id:=Id*Seed}
    \\  Hidden<constructor>(Id:i64)<transacts>:=shape{Id:=Id+100}
    \\  Local<constructor><internal>(Id:i64)<transacts>:shape=Block{var T:i64=Id;set T=T+Seed;shape{Id:=T}}
    \\  Lent<public><constructor>(Id:i64)<transacts>:shape=Block{var T:i64=Id;set T=T+1;shape{Id:=T}}
    \\  Deep<public>:=module{
    \\    square<public>:=class(shape){Edge<public>:i64=1,Block{set Self.Tag=Self.Tag*10+Self.Edge}}
    \\    MakeSquare<public><constructor>(Id:i64,Edge:i64)<transacts>:=square{Edge:=Edge,Hidden<constructor>(Id)}
    \\    ByPath<public><constructor>(Id:i64)<transacts>:=square{Shapes.Hidden<constructor>(Id)}
    \\    Bound<public><constructor>(Id:i64)<transacts>:=square{Local<constructor>(Id)}
    \\  }
    \\  Vault:=module{
    \\    Secret<public><constructor>(Id:i64)<transacts>:=shape{Id:=Id+7}
    \\  }
    \\  ViaVault<public><constructor>(Id:i64)<transacts>:=shape{Vault.Secret<constructor>(Id)}
    \\}
;

test "constructor functions of nested modules are called and delegated to as far as their names reach" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try pair(h,
        \\using{L.Shapes}
        \\Mine:=module{
        \\  cube<public>:=class(Deep.square){Depth<public>:i64=0,Block{set Self.Tag=Self.Tag+Self.Depth*1000}}
        \\  MakeCube<public><constructor>(Id:i64)<transacts>:=cube{Depth:=3,L.Shapes.Deep.MakeSquare<constructor>(Id,4)}
        \\  Used<public><constructor>(Id:i64)<transacts>:=cube{Make<constructor>(Id)}
        \\  Far<public><constructor>(Id:i64)<transacts>:=cube{Deep.ByPath<constructor>(Id)}
        \\}
        \\S1:=L.Shapes.Make(3)
        \\S2:=Deep.MakeSquare(5,6)
        \\S3:=L.Shapes.Deep.ByPath(1)
        \\S4:=L.Shapes.Deep.Bound(8)
        \\S5:=L.Shapes.ViaVault(1)
        \\S6:=L.Shapes.Lent(1)
        \\C1:=Mine.MakeCube(2)
        \\C2:=Mine.Used(4)
        \\C3:=Mine.Far(9)
        \\C4:=Mine.cube{Depth:=1,L.Shapes.Make<constructor>(10)}
        \\A<public>:i64=S1.Id*1000+S1.Tag
        \\B<public>:i64=S2.Id*10000+S2.Tag
        \\C<public>:i64=S3.Id*10000+S3.Tag
        \\D<public>:i64=S4.Id*10000+S4.Tag
        \\E<public>:i64=S5.Id*1000+S5.Tag
        \\F<public>:i64=C1.Id*100000+C1.Tag
        \\G<public>:i64=C2.Id*100000+C2.Tag
        \\H<public>:i64=C3.Id*100000+C3.Tag
        \\I<public>:i64=C4.Id*100000+C4.Tag
        \\J<public>:i64=S6.Id*1000+S6.Tag
    , constructor_lib);
    // `Make` reads the file's `Seed` from inside the module; the clause of `shape` adds it.
    try std.testing.expectEqual(@as(i64, 6 * 1000 + 8), try integer(execution, "A"));
    // `Hidden` is not public: in reach of the module nested in its own, by name. The clauses
    // run once on the one instance, the superclass's first: (105+2)*10+6.
    try std.testing.expectEqual(@as(i64, 105 * 10000 + 1076), try integer(execution, "B"));
    // The same constructor by a path written inside the module it names.
    try std.testing.expectEqual(@as(i64, 101 * 10000 + 1031), try integer(execution, "C"));
    // `Local` assigns a local, which a template lends only inside its file: `Deep` is in it.
    try std.testing.expectEqual(@as(i64, 10 * 10000 + 121), try integer(execution, "D"));
    // A public constructor of a module that is not public, delegated to by the module around it.
    try std.testing.expectEqual(@as(i64, 8 * 1000 + 10), try integer(execution, "E"));
    // From another file: by path through three scopes, through the file's `using` inside a
    // module of the file, and through a public module of the module in `using`.
    try std.testing.expectEqual(@as(i64, 102 * 100000 + 4044), try integer(execution, "F"));
    try std.testing.expectEqual(@as(i64, 8 * 100000 + 101), try integer(execution, "G"));
    try std.testing.expectEqual(@as(i64, 109 * 100000 + 1111), try integer(execution, "H"));
    try std.testing.expectEqual(@as(i64, 20 * 100000 + 1221), try integer(execution, "I"));
    // What cannot be lent to another file can still be called from it.
    try std.testing.expectEqual(@as(i64, 2 * 1000 + 4), try integer(execution, "J"));

    // A constructor function that is not public, called and delegated to from outside.
    try pairCode(h, .private_name, "X:=L.Shapes.Hidden(1)", constructor_lib);
    try pairCode(h, .private_name, "X:=L.Shapes.Local(1)", constructor_lib);
    try pairCode(h, .private_name, "X:=L.Shapes.shape{L.Shapes.Hidden<constructor>(1)}", constructor_lib);
    try pairCode(h, .private_name, "M:=module{X:=L.Shapes.Deep.square{L.Shapes.Hidden<constructor>(1)}}", constructor_lib);
    // A public one of a module that is not: the path stops at the module.
    try pairCode(h, .private_name, "X:=L.Shapes.shape{L.Shapes.Vault.Secret<constructor>(1)}", constructor_lib);
    try pairCode(h, .private_name, "X:=L.Shapes.Vault.Secret(1)", constructor_lib);
    // `using` supplies public names only.
    try pairCode(h, .unknown_name, "using{L.Shapes}\nX:=shape{Hidden<constructor>(1)}", constructor_lib);
    try pairCode(h, .unknown_name, "M:=module{using{L.Shapes}\nX:=Hidden(1)}", constructor_lib);
    // A template with a local assignment is bound to its file, also when it was taken over.
    try pairCode(h, .invalid_delegation, "X:=L.Shapes.shape{L.Shapes.Lent<constructor>(1)}", constructor_lib);
    try pairCode(h, .invalid_delegation, "M:=module{X:=L.Shapes.Deep.square{L.Shapes.Deep.Bound<constructor>(1)}}", constructor_lib);
    // Between modules of one file.
    try expectCode(h, .private_name, "A:=module{c<public>:=class{X:i64=0}\nHid<constructor>(X:i64)<transacts>:=c{X:=X}}\nB:=module{P:A.c=A.c{A.Hid<constructor>(1)}}");
    try expectCode(h, .private_name, "A:=module{In:=module{c<public>:=class{X:i64=0}\nMk<public><constructor>(X:i64)<transacts>:=c{X:=X}}\nd<public>:=class{X:i64=0}}\nP:A.d=A.d{A.In.Mk<constructor>(1)}");
    // A module and a constructor function of one name in one scope.
    try expectCode(h, .duplicate_name, "c:=class{X:i64=0}\nM:=module{}\nM<constructor>(X:i64)<transacts>:=c{X:=X}");
    try expectCode(h, .unsupported_specifier, "c:=class{X:i64=0}\nMk<private><constructor>(X:i64)<transacts>:=c{X:=X}\nM:=module{}");
    // The access word stands on either side of `<constructor>`.
    const sides = try one(h, "M:=module{c<public>:=class{X:i64=0}\nP<internal><constructor>(X:i64)<transacts>:=c{X:=X}\nQ<constructor><internal>(X:i64)<transacts>:=c{X:=X}\nA<public>:i64=P(1).X+Q(2).X}\nA<public>:i64=M.A");
    try std.testing.expectEqual(@as(i64, 3), try integer(sides, "A"));
    // Overloads are told apart per scope: three scopes each have a `Mk` of one parameter, and
    // a bare `Mk` is the nearest one, which inside its own body is the function itself.
    // RFC-0076: a module inside `M` may not declare a `Mk` after `M` has, so `In` stands
    // beside `M` (it was nested in it) and names `M.c`; the file's `Mk` comes after both.
    const overloads = try one(h,
        \\M:=module{
        \\  c<public>:=class{X:i64=0,Y<public>:i64=0}
        \\  Mk<public><constructor>(X:i64,Y:i64)<transacts>:=c{X:=X,Y:=Y}
        \\  Mk<public><constructor>(X:i64)<transacts>:=c{Mk<constructor>(X,7)}
        \\  Near<public>:i64=Mk(1).Y
        \\}
        \\In:=module{
        \\  Mk<public><constructor>(X:i64)<transacts>:=M.c{M.Mk<constructor>(X,9)}
        \\  Near<public>:i64=Mk(1).Y
        \\}
        \\Mk<constructor>(X:i64)<transacts>:=M.c{M.Mk<constructor>(X)}
        \\A<public>:i64=M.Mk(1).Y*100+M.Mk(1,2).Y*10+In.Mk(3).Y+Mk(4).Y*1000
        \\B<public>:i64=M.Near*10+In.Near
    );
    try std.testing.expectEqual(@as(i64, 7729), try integer(overloads, "A"));
    try std.testing.expectEqual(@as(i64, 79), try integer(overloads, "B"));
    try expectAt(h, .shadowed_name, "Mk", 1, "M:=module{\n  c<public>:=class{X:i64=0}\n  Mk<constructor>(X:i64)<transacts>:=c{X:=X}\n  In:=module{\n    Mk<constructor>(X:i64)<transacts>:=c{X:=X}\n  }\n}");
    // A template that reads and writes a cell of its module is lent to the module beside it:
    // both admissions bind such nodes to the file, and judge the cell by the module that wrote them.
    const beside = try one(h,
        \\V:=module{
        \\  c<public>:=class{X<public>:i64=0}
        \\  var G:i64=5
        \\  Mk<public><constructor>(X:i64)<transacts>:c=Block{var T:i64=X;set T=T+G;set G=G+1;c{X:=T}}
        \\}
        \\W:=module{
        \\  d<public>:=class(V.c){}
        \\  Md<public><constructor>(X:i64)<transacts>:=d{V.Mk<constructor>(X)}
        \\}
        \\A<public>:i64=W.Md(1).X*10+W.Md(1).X
    );
    try std.testing.expectEqual(@as(i64, 67), try integer(beside, "A"));
    // Inside its own body the bare name is the function itself, not the file's. RFC-0076: the
    // file's `Mk` follows the module; declared before it, the module's is refused as a shadow.
    try expectCode(h, .unknown_name, "c:=class{X:i64=0}\nM:=module{Mk<public><constructor>(X:i64)<transacts>:=c{Mk<constructor>(X)}}\nMk<constructor>(X:i64)<transacts>:=c{X:=X}");
    try expectAt(h, .shadowed_name, "Mk", 1, "c:=class{X:i64=0}\nMk<constructor>(X:i64)<transacts>:=c{X:=X}\nM:=module{Mk<public><constructor>(X:i64)<transacts>:=c{Mk<constructor>(X)}}");
}

const clause_lib =
    \\var Log:i64=0
    \\Note(X:i64)<transacts>:i64=Block{set Log=Log*10+X;Log}
    \\Zoo<public>:=module{
    \\  var Born:i64=0
    \\  Count(X:i64)<transacts>:i64=Block{set Born=Born+X;Born}
    \\  animal<public>:=class{
    \\    Legs<public>:i64=4
    \\    var Seen<public>:i64=0
    \\    Block{set Self.Seen=Count(Self.Legs)}
    \\    Block{Note(1)}
    \\  }
    \\  Total<public>()<transacts>:i64=Born
    \\  Cage:=module{
    \\    bird<public>:=class(animal){
    \\      Wings:i64=2
    \\      Block{set Self.Seen=Self.Seen*100+Count(Self.Wings);Note(2)}
    \\    }
    \\    Hatch<public>()<transacts>:bird=bird{Legs:=2}
    \\  }
    \\  Free<public>()<transacts>:animal=Cage.Hatch()
    \\}
    \\Trace<public>()<transacts>:i64=Log
;

test "block clauses of classes in nested modules run in their own module wherever the instance is built" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try pair(h,
        \\Farm:=module{
        \\  using{L.Zoo}
        \\  cow<public>:=class(animal){
        \\    Milk<public>:i64=7
        \\    Block{set Self.Seen=Self.Seen+Self.Milk}
        \\  }
        \\  Buy<public><constructor>(Milk:i64)<transacts>:=cow{Milk:=Milk}
        \\}
        \\P:=L.Zoo.animal{}
        \\Q:=L.Zoo.Free()
        \\R:=Farm.Buy(5)
        \\S:=Farm.cow{Legs:=1}
        \\A<public>:i64=P.Seen
        \\B<public>:i64=Q.Seen
        \\C<public>:i64=R.Seen
        \\D<public>:i64=S.Seen
        \\E<public>:i64=L.Zoo.Total()
        \\F<public>:i64=L.Trace()
    , clause_lib);
    // The clauses of `animal` call a function of `Zoo` and one of its file, neither public,
    // and write a cell of each: they are code of `Zoo`, also for an instance built elsewhere.
    try std.testing.expectEqual(@as(i64, 4), try integer(execution, "A"));
    // A class of a module that is not public, built inside it: 6, then 6*100+8.
    try std.testing.expectEqual(@as(i64, 608), try integer(execution, "B"));
    // A subclass in a module of another file, through its constructor function and plainly:
    // the clauses of `animal` first, then its own.
    try std.testing.expectEqual(@as(i64, 12 + 5), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 13 + 7), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 13), try integer(execution, "E"));
    // Every clause in the order of construction: 1, then 1 and 2 for the bird, 1, 1.
    try std.testing.expectEqual(@as(i64, 11211), try integer(execution, "F"));

    // A clause is held to the reach of the module that writes it.
    try pairCode(h, .private_name, "c:=class{var S:i64=0,Block{set Self.S=L.Zoo.Count(1)}}", clause_lib);
    try pairCode(h, .private_name, "M:=module{c:=class{var S:i64=0,Block{set Self.S=L.Note(1)}}}", clause_lib);
    try pairCode(h, .private_name, "M:=module{c:=class(L.Zoo.Cage.bird){}}", clause_lib);
    try pairCode(h, .unknown_name, "M:=module{using{L.Zoo}\nc:=class{var S:i64=0,Block{set Self.S=Count(1)}}}", clause_lib);
    try expectCode(h, .private_name, "A:=module{Hid()<transacts>:i64=1}\nB:=module{c:=class{var S:i64=0,Block{set Self.S=A.Hid()}}}");
    // Inside a module as anywhere: no instance of the class in its own clause, and no clause in an interface.
    try expectCode(h, .construction_cycle, "M:=module{c<public>:=class{X:i64=0,Block{c{}}}}");
    try expectCode(h, .invalid_interface, "M:=module{i<public>:=interface{X:i64=0,Block{1}}}");
    // A clause of a nested module's class reaches what the scopes around the module declare.
    const around = try one(h,
        \\var Hits:i64=0
        \\Outer:=module{
        \\  Step:i64=3
        \\  Inner<public>:=module{
        \\    c<public>:=class{X<public>:i64=0,Block{set Hits=Hits+Step+Self.X}}
        \\  }
        \\}
        \\P:=Outer.Inner.c{X:=4}
        \\Q:=Outer.Inner.c{}
        \\A<public>:i64=Hits
    );
    try std.testing.expectEqual(@as(i64, 10), try integer(around, "A"));
}

const final_lib =
    \\Kit<public>:=module{
    \\  gauge<public>:=interface{var Level<public>:i64=1,var Cap<public><final>:i64=9}
    \\  meter<public>:=class{
    \\    var<private> Ticks<public><final>:i64=3
    \\    var<protected> Peak<final><public>:i64=4
    \\    var Level<public>:i64=5
    \\    Tick<public>()<transacts>:i64=Block{set Self.Ticks=Self.Ticks+1;Self.Ticks}
    \\  }
    \\  dial<public>:=class(meter,gauge){
    \\    Raise<public>()<transacts>:i64=Block{set Self.Peak=Self.Peak+10;Self.Peak}
    \\  }
    \\}
;

test "a final field keeps its split write access, and an interface field its stand-in rules, across modules" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try pair(h,
        \\Use:=module{
        \\  using{L.Kit}
        \\  Fill<public>(G:gauge)<transacts>:i64=Block{set G.Level=G.Level+20;set G.Cap=G.Cap+1;G.Level+G.Cap}
        \\  wide<public>:=class(dial){
        \\    Extra<public>:i64=0
        \\    Lift<public>()<transacts>:i64=Block{set Self.Peak=Self.Peak+1;Self.Peak}
        \\  }
        \\}
        \\D:=L.Kit.dial{}
        \\A<public>:i64=D.Tick()+D.Ticks
        \\B<public>:i64=D.Raise()+D.Peak
        \\C<public>:i64=Use.Fill(D)
        \\E<public>:i64=D.Level*100+D.Cap
        \\W:=Use.wide{Extra:=2,Level:=6}
        \\F<public>:i64=W.Ticks+W.Peak+W.Level+W.Cap+W.Extra
        \\G<public>:i64=W.Lift()
    , final_lib);
    // `<final>` and the two access words stand together, in either order: every instance
    // starts with the default, the class assigns, everyone reads.
    try std.testing.expectEqual(@as(i64, 8), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 28), try integer(execution, "B"));
    // `meter.Level` stands in for the interface's `var Level`: anyone may assign it. The final
    // `var Cap` the class acquires is assigned through the interface, never given.
    try std.testing.expectEqual(@as(i64, 25 + 10), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 2510), try integer(execution, "E"));
    try std.testing.expectEqual(@as(i64, 3 + 4 + 6 + 9 + 2), try integer(execution, "F"));
    // A protected write access admits the subclass of another file's module.
    try std.testing.expectEqual(@as(i64, 5), try integer(execution, "G"));

    const Case = struct { []const u8, types.Diagnostic.Code };
    inline for ([_]Case{
        // Nobody gives a final field, whoever may read or assign it.
        .{ "D:=L.Kit.dial{Ticks:=1}", .final_field },
        .{ "D:=L.Kit.dial{Peak:=1}", .final_field },
        .{ "D:=L.Kit.dial{Cap:=1}", .final_field },
        .{ "M:=module{using{L.Kit}\nD:=dial{Ticks:=1}}", .final_field },
        // The write access guards `set` as it does without `<final>`.
        .{ "Poke(D:L.Kit.dial)<transacts>:i64=Block{set D.Ticks=1;1}", .inaccessible_member },
        .{ "Poke(D:L.Kit.dial)<transacts>:i64=Block{set D.Peak=1;1}", .inaccessible_member },
        .{ "M:=module{sub:=class(L.Kit.meter){Bad()<transacts>:i64=Block{set Self.Ticks=1;1}}}", .inaccessible_member },
        // No class below restates a final field, with its accesses said again or not.
        .{ "sub:=class(L.Kit.meter){var<private> Ticks<override><public>:i64=5}", .final_field },
        .{ "sub:=class(L.Kit.meter){var Ticks<override>:i64=5}", .final_field },
        .{ "sub:=class(L.Kit.meter){var<public> Ticks<override>:i64=5}", .override_mismatch },
        // A field assigned by its class only cannot stand in for an interface's `var` field,
        // and no field of a superclass stands in for a final one.
        .{ "i:=interface{var Ticks<public>:i64}\nsub:=class(L.Kit.meter,i){}", .inaccessible_member },
        .{ "i:=interface{var Peak<public>:i64}\nM:=module{sub:=class(L.Kit.meter,i){}}", .inaccessible_member },
        .{ "i:=interface{var Level<public><final>:i64=1}\nsub:=class(L.Kit.meter,i){}", .final_field },
        .{ "i:=interface{var Ticks<public><final>:i64=1}\nsub:=class(L.Kit.meter,i){}", .final_field },
        // A delegated constructor gives no final field either.
        .{ "Mk<constructor>(X:i64)<transacts>:=L.Kit.meter{Ticks:=X}", .final_field },
    }) |case| try pairCode(h, case[1], case[0], final_lib);
    // An interface states no access, a write access is never the wider one, and a final
    // field has its default, with or without a write access.
    try expectCode(h, .invalid_interface, "M:=module{i:=interface{var<private> X<final>:i64=1}}");
    try expectCode(h, .unsupported_specifier, "M:=module{c:=class{var<public> X<private><final>:i64=1}}");
    try expectCode(h, .final_field, "M:=module{c:=class{var<private> X<public><final>:i64}}");
    try expectCode(h, .unsupported_specifier, "M:=module{c:=class{var<final> X<public>:i64=1}}");
    // `<override><final>` seals a field with a split access where a subclass restates it.
    const sealed = try one(h,
        \\M:=module{
        \\  base<public>:=class{var<protected> N<public>:i64=1}
        \\  mid<public>:=class(base){var<protected> N<override><final><public>:i64=5,Up<public>()<transacts>:i64=Block{set Self.N=Self.N+1;Self.N}}
        \\}
        \\X:=M.mid{}
        \\A<public>:i64=X.N*10+X.Up()
    );
    try std.testing.expectEqual(@as(i64, 56), try integer(sealed, "A"));
    try expectCode(h, .final_field, "M:=module{base<public>:=class{var<protected> N<public>:i64=1}\nmid<public>:=class(base){var N<override><final>:i64=5}}\nlow:=class(M.mid){var N<override>:i64=6}");
}

const extension_lib =
    \\(N:i64).BitAnd(O:i64)<computes>:i64=N+O
    \\(N:i64).Quotient(O:i64)<computes>:i64=N-O
    \\Mod(A:i64,B:i64)<computes>:i64=A*B
    \\rational(N:i64)<computes>:i64=N*2
    \\(N:i64).Triple()<computes>:i64=N*3
    \\Outer<public>:=module{
    \\  A<public>:i64=BitAnd(6,3)
    \\  B<public>:i64=6.BitAnd(3)
    \\  C<public>:i64=Attempt(Quotient[7,2],0)
    \\  D<public>:i64=Mod(7,2)
    \\  R:=rational
    \\  E<public>:i64=R(4)
    \\  (N:i64).Mod(O:i64)<computes>:i64=N+O+100
    \\  F<public>:i64=Mod(7,2)+7.Mod(2)
    \\  Inner<public>:=module{
    \\    (N:i64).BitOr(O:i64)<computes>:i64=N*O
    \\    G<public>:i64=BitOr(6,3)+6.BitOr(3)
    \\    H<public>:i64=Mod(5,5)+5.Triple()+5.Mod(1)
    \\  }
    \\}
    \\Ext<public>:=module{
    \\  (N:i64).Hid()<computes>:i64=N
    \\  (N:i64).Shown<public>()<computes>:i64=N+1
    \\  Plain(N:i64)<computes>:i64=N
    \\  Open<public>(N:i64)<computes>:i64=N+2
    \\}
;

test "an extension method leaves the bare name to the scopes around a nested module and to the intrinsics" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try pair(h,
        \\Mine:=module{
        \\  using{L.Outer}
        \\  (N:i64).BitXor(O:i64)<computes>:i64=N+O+1000
        \\  I<public>:i64=BitXor(6,3)+6.BitXor(3)
        \\  J<public>:i64=A+F
        \\  Deep<public>:=module{
        \\    using{L.Ext}
        \\    K<public>:i64=BitXor(5,1)+5.BitXor(1)+1.Shown()+Open(1)
        \\  }
        \\}
        \\A<public>:i64=L.Outer.A
        \\B<public>:i64=L.Outer.B
        \\C<public>:i64=L.Outer.C
        \\D<public>:i64=L.Outer.D
        \\E<public>:i64=L.Outer.E
        \\F<public>:i64=L.Outer.F
        \\G<public>:i64=L.Outer.Inner.G
        \\H<public>:i64=L.Outer.Inner.H
        \\I<public>:i64=Mine.I
        \\J<public>:i64=Mine.J
        \\K<public>:i64=Mine.Deep.K
    , extension_lib);
    // An extension method of the scope around the module: the bare name is the intrinsic,
    // the name after a receiver the method.
    try std.testing.expectEqual(@as(i64, 2), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 9), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 3), try integer(execution, "C"));
    // A plain function of the scope around hides the intrinsic, and is a value under the
    // name of a type the compiler knows.
    try std.testing.expectEqual(@as(i64, 14), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 8), try integer(execution, "E"));
    // An extension method declared by the module itself leaves the bare name what it was
    // before: the function of the file, not the intrinsic.
    try std.testing.expectEqual(@as(i64, 14 + 109), try integer(execution, "F"));
    try std.testing.expectEqual(@as(i64, 7 + 18), try integer(execution, "G"));
    // Two scopes further in: the file's function, the file's extension, the module's extension.
    try std.testing.expectEqual(@as(i64, 25 + 15 + 106), try integer(execution, "H"));
    try std.testing.expectEqual(@as(i64, 5 + 1009), try integer(execution, "I"));
    try std.testing.expectEqual(@as(i64, 2 + 123), try integer(execution, "J"));
    // The extension of the module around, a public extension and a public function in `using`.
    try std.testing.expectEqual(@as(i64, 4 + 1006 + 2 + 3), try integer(execution, "K"));

    // An extension method is not called by its bare name, from any depth.
    try pairCode(h, .unknown_name, "(N:i64).Twice()<computes>:i64=N*2\nM:=module{X:i64=Twice(1)}", extension_lib);
    try pairCode(h, .unknown_name, "M:=module{using{L.Ext}\nX:i64=Shown(1)}", extension_lib);
    // What a module does not make public stays in it: an extension method and a function.
    try pairCode(h, .private_name, "M:=module{using{L.Ext}\nX:i64=1.Hid()}", extension_lib);
    try pairCode(h, .private_name, "M:=module{X:i64=L.Ext.Plain(1)}", extension_lib);
    try pairCode(h, .unknown_name, "M:=module{using{L.Ext}\nX:i64=Plain(1)}", extension_lib);
    // RFC-0076: an extension method of a scope around the code is named only after a receiver,
    // so the bare name is the function a module in `using` exports (it used to be kept from it).
    const beside = try pair(h, "using{L.Ext}\n(N:i64).Open()<computes>:i64=N\nM:=module{X<public>:i64=Open(1)*10+7.Open()}\nR<public>:i64=M.X", extension_lib);
    try std.testing.expectEqual(@as(i64, 37), try integer(beside, "R"));
    // A type alias of a name the compiler knows, where only an extension method has it.
    const alias = try one(h,
        \\(N:i64).rational()<computes>:i64=N*2
        \\M:=module{
        \\  r<public>:=rational
        \\  Half<public>()<computes>:r=Attempt(Rational[1,2],MakeRationalFromInt(0))
        \\}
        \\A<public>:logic=M.Half()==M.Half()
    );
    try std.testing.expect(alias.get("A").?.boolean);
}

test "both admissions hold delegated templates and clause calls to the reach of the module that wrote them" {
    const h = try harness.create();
    defer scratch.release(h);
    const program = try compile(h, &.{
        .{ .path = "main.forb", .source =
        \\L:=import{"lib.forb"}
        \\Keep:=module{
        \\  Shut(X:i64)<transacts>:i64=X+40
        \\  Spy(I:L.Box.item)<transacts>:logic=I.X>2
        \\  Wrap<public><constructor>(X:i64)<transacts>:=L.Box.item{L.Box.Make<constructor>(X)}
        \\}
        \\P:=L.Box.item{L.Box.Make<constructor>(4)}
        \\Q:=Keep.Wrap(5)
        \\A<public>:i64=P.X*100+P.Y
        \\B<public>:i64=Q.X*100+Q.Y
        },
        .{ .path = "lib.forb", .source =
        \\Box<public>:=module{
        \\  item<public>:=class{X<public>:i64=0,var Y<public>:i64=0,Block{set Self.Y=Self.X+1}}
        \\  Pick(X:i64)<transacts>:i64=X+10
        \\  Make<public><constructor>(X:i64)<transacts>:=item{X:=Pick(X)}
        \\}
        \\Side<public>:=module{
        \\  Open<public>(X:i64)<transacts>:i64=X+20
        \\  Shut(X:i64)<transacts>:i64=X+30
        \\  Watch<public>(I:Box.item)<transacts>:logic=I.X>0
        \\  Spy(I:Box.item)<transacts>:logic=I.X>1
        \\}
        },
    });
    const run = try h.run(program, fuel);
    try std.testing.expectEqual(@as(i64, 1415), run.ok.get("A").?.integer);
    try std.testing.expectEqual(@as(i64, 1516), run.ok.get("B").?.integer);
    const nodes = try std.testing.allocator.dupe(types.Node, program.nodes);
    defer std.testing.allocator.free(nodes);
    const function_nodes = try std.testing.allocator.dupe(types.FunctionNode, program.function_nodes);
    defer std.testing.allocator.free(function_nodes);
    var forged = program;
    forged.nodes = nodes;
    forged.function_nodes = function_nodes;

    // The archetype of `P` in the root file took over the call of `Pick`, a function of `Box`
    // that is not public, and is followed by the call of the clause of `item`: both are
    // blamed on the text of `Box`, which is what lets another file hold them.
    const pick = try callIn(program, "Box", "Pick");
    const clause = try callIn(program, "Box", "Block");
    const built = for (program.nodes, 0..) |node, index| {
        if (node.kind == .object_new and modules.home(node.span, program.modules, program.nested).? == program.modules.len - 1) break index;
    } else return error.NoArchetype;
    try std.testing.expect(pick < built and built < clause);
    const Retarget = struct { node: u32, module: []const u8, name: []const u8, admitted: bool };
    for ([_]Retarget{
        // A public function of a module the file of `Box` declares: in reach of `Box`.
        .{ .node = pick, .module = "Side", .name = "Open", .admitted = true },
        .{ .node = clause, .module = "Side", .name = "Watch", .admitted = true },
        // One that is not public, in a module beside `Box` and in a module of the other file.
        .{ .node = pick, .module = "Side", .name = "Shut", .admitted = false },
        .{ .node = pick, .module = "Keep", .name = "Shut", .admitted = false },
        .{ .node = clause, .module = "Side", .name = "Spy", .admitted = false },
        .{ .node = clause, .module = "Keep", .name = "Spy", .admitted = false },
    }) |case| {
        @memcpy(nodes, program.nodes);
        nodes[case.node].kind.call.function = try functionIn(program, case.module, case.name);
        if (case.admitted) {
            if (evaluator.validate(forged, h.values.len) != null) std.debug.print("refused: {s}.{s}\n", .{ case.module, case.name });
            try std.testing.expect(evaluator.validate(forged, h.values.len) == null);
            try std.testing.expect(h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, fuel) == .ok);
        } else {
            harness.invalid(h, forged) catch |err| {
                std.debug.print("admitted: {s}.{s}\n", .{ case.module, case.name });
                return err;
            };
        }
    }
    // The same two calls blamed on the archetype that holds them, in the other file: neither
    // function is public, so the text of the root file may not call it.
    for ([_]u32{ pick, clause }) |at| {
        @memcpy(nodes, program.nodes);
        nodes[at].span = program.nodes[built].span;
        try harness.invalid(h, forged);
    }
    @memcpy(nodes, program.nodes);

    // Inside a function: the template of `Keep.Wrap` holds the same two calls.
    const wrap = program.functions[try functionIn(program, "Keep", "Wrap")];
    var inner_pick: ?usize = null;
    var inner_clause: ?usize = null;
    for (program.function_nodes[wrap.body.start..wrap.body.end], wrap.body.start..) |entry, index| {
        if (entry.input != .operation or entry.node.kind != .call) continue;
        const name = program.functions[entry.node.kind.call.function].name.text(program.source);
        if (std.mem.eql(u8, name, "Pick")) inner_pick = index;
        if (std.mem.eql(u8, name, "Block")) inner_clause = index;
    }
    const Inner = struct { node: usize, module: []const u8, name: []const u8, admitted: bool };
    for ([_]Inner{
        .{ .node = inner_pick.?, .module = "Side", .name = "Open", .admitted = true },
        .{ .node = inner_clause.?, .module = "Side", .name = "Watch", .admitted = true },
        .{ .node = inner_pick.?, .module = "Side", .name = "Shut", .admitted = false },
        // `Wrap` is a function of `Keep`, but the call it took over is still code of `Box`.
        .{ .node = inner_pick.?, .module = "Keep", .name = "Shut", .admitted = false },
        .{ .node = inner_clause.?, .module = "Side", .name = "Spy", .admitted = false },
        .{ .node = inner_clause.?, .module = "Keep", .name = "Spy", .admitted = false },
    }) |case| {
        @memcpy(function_nodes, program.function_nodes);
        function_nodes[case.node].node.kind.call.function = try functionIn(program, case.module, case.name);
        if (case.admitted) {
            if (evaluator.validate(forged, h.values.len) != null) std.debug.print("refused in Wrap: {s}.{s}\n", .{ case.module, case.name });
            try std.testing.expect(evaluator.validate(forged, h.values.len) == null);
            try std.testing.expect(h.runtime.machine.run(bytecode.lower(forged, &h.runtime.instructions).ok, fuel) == .ok);
        } else {
            harness.invalid(h, forged) catch |err| {
                std.debug.print("admitted in Wrap: {s}.{s}\n", .{ case.module, case.name });
                return err;
            };
        }
    }
    // Blamed on `Wrap` itself, each call would be one from `Keep` into what `Box` keeps.
    for ([_]usize{ inner_pick.?, inner_clause.? }) |at| {
        @memcpy(function_nodes, program.function_nodes);
        function_nodes[at].node.span = wrap.name;
        try harness.invalid(h, forged);
    }
    @memcpy(function_nodes, program.function_nodes);
    _ = try h.run(program, fuel);
}

test "a loop in a nested module writes through a name that is not a var local, as in a file" {
    const h = try harness.create();
    defer scratch.release(h);
    // RFC-0075 tells a `var` local, which a loop carries, from a `var` field of the class
    // around the method by where the word stands; the braces of a module are no such place.
    const lib =
        \\Game<public>:=module{
        \\  point<public>:=class{var x<public>:i64=0}
        \\  spot:=struct{x:i64=0}
        \\  counter<public>:=class{
        \\    var Pos<public>:i64=7
        \\    var N<public>:i64=0
        \\    Block{
        \\      var I:i64=0
        \\      While(I<2,Block{set Self.N=Self.N+5;set I=I+1})
        \\    }
        \\    Run<public>(Pos:point,Times:i64)<transacts>:i64=Block{
        \\      var I:i64=0
        \\      While(I<Times,Block{set Pos.x=Pos.x+1;set Self.N=Self.N+1;set I=I+1})
        \\      Loop{
        \\        If(I>=Times+2,Break(),false)
        \\        set Pos.x=Pos.x+10
        \\        set I=I+1
        \\      }
        \\      Pos.x
        \\    }
        \\  }
        \\  Carried<public>(Times:i64)<transacts>:i64=Block{
        \\    var Pos:spot=spot{}
        \\    var I:i64=0
        \\    While(I<Times,Block{set Pos.x=Pos.x+2;set I=I+1})
        \\    Pos.x
        \\  }
        \\  Inner<public>:=module{
        \\    Feed<public>(P:point,Times:i64)<transacts>:i64=Block{
        \\      var I:i64=0
        \\      While(I<Times,Block{set P.x=P.x+3;set I=I+1})
        \\      P.x
        \\    }
        \\  }
        \\}
    ;
    const execution = try pair(h,
        \\Mine:=module{
        \\  using{L.Game}
        \\  tall<public>:=class(counter){
        \\    var Seen<public>:i64=0
        \\    Walk<public>(Seen:point)<transacts>:i64=Block{
        \\      var I:i64=0
        \\      While(I<4,Block{set Seen.x=Seen.x+1;set I=I+1})
        \\      Seen.x
        \\    }
        \\  }
        \\}
        \\C:=L.Game.counter{}
        \\P:=L.Game.point{}
        \\A<public>:i64=C.Run(P,3)
        \\B<public>:i64=C.N*100+C.Pos
        \\D<public>:i64=L.Game.Carried(4)
        \\E<public>:i64=L.Game.Inner.Feed(P,2)
        \\T:=Mine.tall{}
        \\F<public>:i64=T.Walk(P)+T.Seen
    , lib);
    // The parameter `Pos` names an instance; the field `Pos` of the class is not a local.
    try std.testing.expectEqual(@as(i64, 3 + 20), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, (10 + 3) * 100 + 7), try integer(execution, "B"));
    // A `var` local that holds a struct is carried, as before.
    try std.testing.expectEqual(@as(i64, 8), try integer(execution, "D"));
    try std.testing.expectEqual(@as(i64, 23 + 6), try integer(execution, "E"));
    try std.testing.expectEqual(@as(i64, 29 + 4), try integer(execution, "F"));
    // The same class in the file itself means the same.
    const flat = try one(h,
        \\point:=class{var x:i64=0}
        \\counter:=class{
        \\  var Pos:i64=7
        \\  Run(Pos:point)<transacts>:i64=Block{
        \\    var I:i64=0
        \\    While(I<3,Block{set Pos.x=Pos.x+1;set I=I+1})
        \\    Pos.x
        \\  }
        \\}
        \\Side:=module{}
        \\A<public>:i64=counter{}.Run(point{})
    );
    try std.testing.expectEqual(@as(i64, 3), try integer(flat, "A"));
    // A parameter is still not assigned, in a module as in a file.
    try expectCode(h, .not_mutable, "M:=module{F(P:i64)<transacts>:i64=Block{var I:i64=0\nWhile(I<2,Block{set P=P+1;set I=I+1})\nP}}");
}

test "two classes of one nested module each have their clauses, and a subclass both" {
    const h = try harness.create();
    defer scratch.release(h);
    const execution = try pair(h,
        \\using{L.M}
        \\f:=class(d){Block{set Self.T=Self.T+7}}
        \\A<public>:i64=L.M.d{X:=2}.T
        \\B<public>:i64=L.M.e{}.U
        \\C<public>:i64=f{X:=1}.T
        \\D<public>:i64=L.M.Both()
    ,
        \\M<public>:=module{
        \\  c<public>:=class{X<public>:i64=0,var T<public>:i64=0,Block{set Self.T=Self.X+1}}
        \\  d<public>:=class(c){Block{set Self.T=Self.T*10}}
        \\  e<public>:=class{Y:i64=5,var U<public>:i64=0,Block{set Self.U=Self.Y}}
        \\  Both<public>()<transacts>:i64=d{X:=3}.T+e{Y:=1}.U
        \\}
    );
    try std.testing.expectEqual(@as(i64, 30), try integer(execution, "A"));
    try std.testing.expectEqual(@as(i64, 5), try integer(execution, "B"));
    try std.testing.expectEqual(@as(i64, 27), try integer(execution, "C"));
    try std.testing.expectEqual(@as(i64, 41), try integer(execution, "D"));
}
