//! Forged IR around variable cells (RFC-0085, "Forged-IR cases", F1 to F17): every case is
//! refused by both machines' admissions, each in its own code, and by the report replay, which
//! admits the program again before it replays. Each is made from a valid program by changing
//! one thing; the program it is made from runs. The programs are written with a class `Cell` of
//! one field and made into programs over `ref(T)` (`ref_cells.fromClass`), as in
//! `ref_cell_tests.zig`.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const catalogue = @import("aggregate_types.zig");
const ref_cells = @import("ref_cells.zig");
const harness = @import("generic_function_tests.zig");

const fuel: u64 = 1 << 20;
const allocator = std.testing.allocator;

/// The program every case of F1 to F12 and F15, F16 is made from. `Side` holds a cell that
/// nothing reads after it, a read and a write of it, so that a change there touches nothing else.
const base =
    \\Cell:=class{var V:i64}
    \\Other:=class{var W:i64}
    \\Make(N:i64)<transacts>:Cell=Cell{V:=N}
    \\Get(C:Cell)<transacts>:i64=C.V
    \\Put(C:Cell,N:i64)<transacts>:i64=Block{set C.V=N;N}
    \\Pick(B:logic,N:i64)<transacts>:i64=Block{X:=If(B,N+1,N+2);Y:=Cell{V:=X};Y.V}
    \\Side(C:Cell,O:Other)<transacts>:i64=Block{T:=Cell{V:=7};U:=T.V;set T.V=U+1;C.V+O.W-3}
    \\Eq(C:Cell,D:Cell)<transacts>:logic=If(C.V==D.V,true,false)
    \\O:Other=Other{W:=3}
    \\A:Cell=Make(4)
    \\B:i64=Get(A)
    \\D:i64=Put(A,9)
    \\P:i64=Pick(true,1)
    \\S:i64=Side(A,O)
    \\E:logic=Eq(A,Make(9))
    \\R:Cell=Cell{V:=5}
    \\set R.V=R.V+1
;

const Copy = struct {
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    functions: []types.RuntimeFunction,
    definitions: std.ArrayList(types.Definition),
    program: types.Program,
    original: types.Program,

    fn of(p: types.Program) !Copy {
        var copy: Copy = .{
            .nodes = try allocator.dupe(types.Node, p.nodes),
            .function_nodes = try allocator.dupe(types.FunctionNode, p.function_nodes),
            .functions = try allocator.dupe(types.RuntimeFunction, p.functions),
            .definitions = .empty,
            .program = p,
            .original = p,
        };
        try copy.definitions.appendSlice(allocator, p.definitions);
        copy.program.nodes = copy.nodes;
        copy.program.function_nodes = copy.function_nodes;
        copy.program.functions = copy.functions;
        copy.program.definitions = copy.definitions.items;
        return copy;
    }
    fn free(self: *Copy) void {
        self.definitions.deinit(allocator);
        allocator.free(self.functions);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
    }
    fn restore(self: *Copy) void {
        @memcpy(self.nodes, self.original.nodes);
        @memcpy(self.function_nodes, self.original.function_nodes);
        @memcpy(self.functions, self.original.functions);
        self.definitions.items.len = self.original.definitions.len;
        @memcpy(self.definitions.items, self.original.definitions);
        self.program = self.original;
        self.program.nodes = self.nodes;
        self.program.function_nodes = self.function_nodes;
        self.program.functions = self.functions;
        self.program.definitions = self.definitions.items;
    }
    /// Appends a definition, which takes the next type id.
    fn define(self: *Copy, item: types.Definition) !types.Type {
        try self.definitions.append(allocator, item);
        self.program.definitions = self.definitions.items;
        return @fromBackingInt(@intCast(self.definitions.items.len - 1 + catalogue.builtin_count));
    }
    fn function(self: *const Copy, name: []const u8) usize {
        for (self.original.functions, 0..) |f, index| if (std.mem.eql(u8, f.name.text(self.original.source), name)) return index;
        unreachable;
    }
    /// The `nth` node of `kind` in the body of the function `name`, by its place in the body.
    fn body(self: *const Copy, name: []const u8, comptime kind: std.meta.Tag(@FieldType(types.Node, "kind")), nth: usize) u32 {
        const f = self.original.functions[self.function(name)];
        var seen: usize = 0;
        for (self.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .operation and entry.node.kind == kind) {
            if (seen == nth) return @intCast(index);
            seen += 1;
        };
        unreachable;
    }
    /// The body entry `index` of the function `name`, to change.
    fn at(self: *Copy, name: []const u8, index: u32) *types.Node {
        return &self.function_nodes[self.original.functions[self.function(name)].body.start + index].node;
    }
    /// The body's entry that reads parameter `n`.
    fn parameter(self: *const Copy, name: []const u8, n: u32) u32 {
        const f = self.original.functions[self.function(name)];
        for (self.original.function_nodes[f.body.start..f.body.end], 0..) |entry, index| if (entry.input == .parameter and entry.input.parameter == n) return @intCast(index);
        unreachable;
    }
};

/// Refused by both machines (`harness.invalid`) and by the replay, given a report of a run of
/// the valid program.
fn refused(h: *harness.Harness, run: evaluator.Execution, forged: types.Program) !void {
    try harness.invalid(h, forged);
    var x = run;
    x.program = forged;
    try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
}

/// Admitted and run by both machines, on a harness of its own so that the run whose report the
/// replay reads stays as it was.
fn admitted(p: types.Program) !void {
    const h = try harness.create();
    defer scratch.release(h);
    try std.testing.expect(try h.run(p, fuel) == .ok);
}

fn converted(h: *harness.Harness, source: []const u8, options: ref_cells.Options) !ref_cells.Converted {
    const p = try h.compile(source);
    return ref_cells.fromClass(allocator, p, ref_cells.classNamed(p, "Cell").?, options);
}

test "F1 to F9: forged cell constructions, reads and writes are refused by both machines and the replay" {
    const h = try harness.create();
    defer scratch.release(h);
    const made = try converted(h, base, .{});
    defer made.deinit(allocator);
    // The program they are made from runs, and its report is admitted.
    const run = (try h.run(made.program, fuel)).ok;
    // The replay below reads this run's report: the storage it borrows is not run again.
    var c = try Copy.of(made.program);
    defer c.free();
    const ref = made.ref;
    const side_new = c.body("Side", .ref_new, 0);
    const side_get = c.body("Side", .ref_get, 0);
    const side_set = c.body("Side", .ref_set, 0);

    // F1: a cell of another value type than its operand's.
    const floats = try c.define(.{ .ref = .float });
    c.at("Side", side_new).value_type = floats;
    try refused(h, run, c.program);
    c.restore();
    // The definition alone, which nothing uses, is admitted: the node is what is refused.
    _ = try c.define(.{ .ref = .float });
    try admitted(c.program);
    c.restore();
    // F2: a construction whose type is not a cell.
    for ([_]types.Type{ .i64, c_other(made.program) }) |not_ref| {
        c.at("Side", side_new).value_type = not_ref;
        try refused(h, run, c.program);
        c.restore();
    }
    // F3: in a function without `writes`. The class's construction needs `allocates` alone,
    // and its program is admitted so.
    c.functions[c.function("Make")].detail.no_writes = true;
    try refused(h, run, c.program);
    c.restore();
    // F4: of a later operand, of itself, and of one that only an arm not taken makes.
    c.at("Side", side_new).kind = .{ .ref_new = side_new };
    try refused(h, run, c.program);
    c.restore();
    c.at("Side", side_new).kind = .{ .ref_new = side_new + 1 };
    try refused(h, run, c.program);
    c.restore();
    const arm = c.body("Pick", .binary, 0);
    c.at("Pick", c.body("Pick", .ref_new, 0)).kind = .{ .ref_new = arm };
    try refused(h, run, c.program);
    c.restore();
    // F5: a read of what is not a cell: an instance of a class of one field, and an integer.
    c.at("Side", side_get).kind = .{ .ref_get = c.parameter("Side", 1) };
    try refused(h, run, c.program);
    c.restore();
    c.at("Side", side_get).kind = .{ .ref_get = c.body("Side", .integer, 0) };
    try refused(h, run, c.program);
    c.restore();
    // F6: a read whose type is not the cell's value type.
    for ([_]types.Type{ .string, .logic, ref }) |wrong| {
        c.at("Side", side_get).value_type = wrong;
        try refused(h, run, c.program);
        c.restore();
    }
    // F7: in a function without `reads`.
    c.functions[c.function("Get")].detail.no_reads = true;
    try refused(h, run, c.program);
    c.restore();
    // F8: a write of a value of another type, and a write of what is not a cell.
    c.at("Side", side_set).kind.ref_set.value = c.parameter("Side", 1);
    try refused(h, run, c.program);
    c.restore();
    c.at("Side", side_set).kind.ref_set.value = side_new;
    try refused(h, run, c.program);
    c.restore();
    c.at("Side", side_set).kind.ref_set.ref = c.parameter("Side", 1);
    try refused(h, run, c.program);
    c.restore();
    c.at("Side", side_set).value_type = .string;
    try refused(h, run, c.program);
    c.restore();
    // F9: in a function without `writes`.
    c.functions[c.function("Put")].detail.no_writes = true;
    try refused(h, run, c.program);
    c.restore();
    // And the same three at the root, where an operand is a root register.
    const root_get = for (c.original.nodes, 0..) |node, index| {
        if (node.kind == .ref_get) break index;
    } else unreachable;
    c.nodes[root_get].value_type = .string;
    try refused(h, run, c.program);
    c.restore();
    for (c.original.nodes, 0..) |node, index| if (node.kind == .ref_set) {
        c.nodes[index].kind.ref_set.ref = node.kind.ref_set.value;
        try refused(h, run, c.program);
        c.restore();
    };
    for (c.original.nodes, 0..) |node, index| if (node.kind == .ref_new) {
        c.nodes[index].value_type = try c.define(.{ .ref = .float });
        try refused(h, run, c.program);
        c.restore();
    };
    try admitted(c.program);
}

test "F3 control: the class a cell is made from builds its instances with `allocates` alone" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(base);
    var c = try Copy.of(p);
    defer c.free();
    // `Make` constructs: an instance needs `allocates`, not `writes`.
    c.functions[c.function("Make")].detail.no_writes = true;
    try admitted(c.program);
}

test "F10 to F14: no class operation reaches a variable cell" {
    const h = try harness.create();
    defer scratch.release(h);
    const made = try converted(h, base, .{});
    defer made.deinit(allocator);
    const run = (try h.run(made.program, fuel)).ok;
    var c = try Copy.of(made.program);
    defer c.free();
    const side_new = c.body("Side", .ref_new, 0);
    const side_get = c.body("Side", .ref_get, 0);
    const side_set = c.body("Side", .ref_set, 0);
    // F10: a field read or write of a cell, at index 0 (its value) and 1 (past it).
    for ([_]u32{ 0, 1 }) |index| {
        c.at("Side", side_get).kind = .{ .object_get = .{ .value = side_new, .index = index } };
        try refused(h, run, c.program);
        c.restore();
        const written = c.at("Side", side_set).kind.ref_set.value;
        c.at("Side", side_set).kind = .{ .object_set = .{ .object = side_new, .index = index, .value = written } };
        try refused(h, run, c.program);
        c.restore();
    }
    // F11: a construction of a cell by `object_new`.
    {
        const kept = try converted(h, base, .{ .keep_constructions = true });
        defer kept.deinit(allocator);
        try refused(h, run, kept.program);
    }
    // F12: an equality of two cells, and a map keyed by cells.
    const compare = c.body("Eq", .compare, 0);
    c.at("Eq", compare).kind.compare.lhs = c.parameter("Eq", 0);
    c.at("Eq", compare).kind.compare.rhs = c.parameter("Eq", 1);
    try refused(h, run, c.program);
    c.restore();
    _ = try c.define(.{ .map = .{ .key = made.ref, .value = .i64 } });
    try refused(h, run, c.program);
    c.restore();
    // F13: into and out of `any`, and a test against a cell type. (A class cast of a cell needs
    // a class on both sides, `isClass`, which a `ref(T)` is not.)
    for ([_][]const u8{
        "Cell:=class{var V:i64}\nA:any=any(Cell{V:=1})",
        "Cell:=class{var V:i64}\nW:any=any(5)\nB:i64=Attempt(Cell[W].V,-1)",
        "Cell:=class{var V:i64}\nAnimal:=class{}\nC:Cell=Cell{V:=1}\nK(X:any)<computes>:i64=Case(X,Y:Cell=>1,_=>0)\nN:i64=K(any(2))",
    }) |source| {
        const cast = try converted(h, source, .{});
        defer cast.deinit(allocator);
        try harness.invalid(h, cast.program);
    }
    {
        // A test of an `any` against a cell type alone, its cast left to `i64`.
        const p = try h.compile("Cell:=class{var V:i64}\nW:any=any(5)\nB:i64=Attempt(i64[W],-1)\nC:Cell=Cell{V:=1}");
        const cast = try ref_cells.fromClass(allocator, p, ref_cells.classNamed(p, "Cell").?, .{});
        defer cast.deinit(allocator);
        _ = try h.run(cast.program, fuel);
        var d = try Copy.of(cast.program);
        defer d.free();
        for (d.original.nodes, 0..) |node, index| if (node.kind == .instance_of) {
            d.nodes[index].kind.instance_of.class = cast.ref;
        };
        try harness.invalid(h, d.program);
    }
    // F14: a live attachment to a cell is admitted at field 0 since I14 (admission rule 6), and
    // refused at field 1 and with a guard of another type (`live_local_forgery_tests.zig` has
    // the rest of rule 6, on compiled live locals).
    {
        const live = try converted(h, "Cell:=class{var V:i64}\nvar Y:i64=1\nC:Cell=Cell{V:=0}\nAttach()<transacts>:i64=Block{set live C.V=Y+1;C.V}\nN:i64=Attach()", .{});
        defer live.deinit(allocator);
        try admitted(live.program);
        const live_run = (try h.run(live.program, fuel)).ok;
        var d = try Copy.of(live.program);
        defer d.free();
        for (d.original.function_nodes, 0..) |entry, index| if (entry.input == .operation and entry.node.kind == .object_live) {
            d.function_nodes[index].node.kind.object_live.field = 1;
        };
        try refused(h, live_run, d.program);
        d.restore();
        for (d.original.function_nodes, 0..) |entry, index| if (entry.input == .operation and entry.node.kind == .object_live) {
            d.function_nodes[index].node.value_type = .string;
        };
        try refused(h, live_run, d.program);
    }
}

test "F15 and F16: the catalogue of cell types and the count of source operations" {
    const h = try harness.create();
    defer scratch.release(h);
    const made = try converted(h, base, .{});
    defer made.deinit(allocator);
    const run = (try h.run(made.program, fuel)).ok;
    var c = try Copy.of(made.program);
    defer c.free();
    // F15: a cell of a cell; a second cell type of one value type; a cell type before its
    // value type. Each is a definition nothing uses: the catalogue alone is refused.
    _ = try c.define(.{ .ref = made.ref });
    try refused(h, run, c.program);
    c.restore();
    _ = try c.define(.{ .ref = .i64 });
    try refused(h, run, c.program);
    c.restore();
    const next: types.Type = @fromBackingInt(@intCast(c.definitions.items.len + 1 + catalogue.builtin_count));
    _ = try c.define(.{ .ref = next });
    _ = try c.define(.rational);
    try refused(h, run, c.program);
    c.restore();
    // The same value type after its definition is admitted.
    _ = try c.define(.rational);
    _ = try c.define(.{ .ref = @fromBackingInt(@backingInt(next) - 1) });
    try admitted(c.program);
    c.restore();
    // F16: a count of source operations that leaves one of the three out, in the program and
    // in a function.
    c.program.source_ops -= 1;
    try refused(h, run, c.program);
    c.restore();
    for ([_][]const u8{ "Make", "Get", "Put" }) |name| {
        c.functions[c.function(name)].source_ops -= 1;
        try refused(h, run, c.program);
        c.restore();
    }
    // A function that holds one says it has source.
    c.functions[c.function("Get")].has_source = false;
    try refused(h, run, c.program);
    c.restore();
}

test "F17: a report whose cell entry is not a cell of its type is refused" {
    const h = try harness.create();
    defer scratch.release(h);
    const made = try converted(h, base, .{});
    defer made.deinit(allocator);
    const run = (try h.run(made.program, fuel)).ok;
    _ = try reporting.validate(run, false, .{ .work = 1 << 24 });
    const object_cells = try allocator.dupe(@TypeOf(run.object_cells[0]), run.object_cells);
    defer allocator.free(object_cells);
    var x = run;
    x.object_cells = object_cells;
    // Find a cell's header, then make it name another type, and its value of another type.
    var at: usize = 0;
    var changed: usize = 0;
    while (at < object_cells.len) {
        const class: types.Type = @fromBackingInt(@intCast(object_cells[at].value.integer));
        const count = catalogue.classCells(class, made.program.definitions).?;
        if (class == made.ref) {
            const header = object_cells[at];
            const value = object_cells[at + catalogue.ref_value];
            object_cells[at].value = .{ .integer = @backingInt(c_other(made.program)) };
            try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
            object_cells[at] = header;
            object_cells[at + catalogue.ref_value].value = .{ .string = "" };
            try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
            object_cells[at + catalogue.ref_value].initialized = false;
            try std.testing.expectError(error.InvalidExecution, reporting.validate(x, false, .{ .work = 1 << 24 }));
            object_cells[at + catalogue.ref_value] = value;
            changed += 1;
        }
        at += count;
    }
    try std.testing.expect(changed >= 3);
    _ = try reporting.validate(x, false, .{ .work = 1 << 24 });
}
/// The class `Other`, with as many cells as a cell has.
fn c_other(p: types.Program) types.Type {
    return ref_cells.classNamed(p, "Other").?;
}
