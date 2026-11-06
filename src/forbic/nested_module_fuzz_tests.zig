//! Forged IR against a brute-force model of module visibility (RFC-0074). The model was
//! written by the independent review of the increment, over the tables alone: it shares no
//! code with either admission.
const std = @import("std");
const scratch = @import("scratch.zig");
const modules = @import("modules.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

const lib_source =
    \\lt<public>:=struct{q:i64=0}
    \\hidden:=struct{q:i64=0}
    \\Kit<public>:=module{
    \\  kt<public>:=struct{z:i64=0}
    \\  Offset<public>:i64=3
    \\  var Count<public>:i64=0
    \\  Add<public>(X:i64)<transacts>:i64=Block{set Count=Count+1;X+Offset}
    \\  Deep:=module{
    \\    Low<public>(X:i64)<computes>:i64=X+9
    \\    dt<public>:=struct{w:i64=0}
    \\  }
    \\  Use:i64=Deep.Low(1)
    \\}
    \\LibTop<public>(X:i64)<transacts>:i64=Kit.Add(X)
;
const main_source =
    \\L:=import{"lib.forb"}
    \\t:=struct{x:i64=0}
    \\Outer<public>:=module{
    \\  s:=struct{y:i64=0}
    \\  Inner:=module{
    \\    Open<public>(X:i64)<transacts>:i64=X+1
    \\    Shut(X:i64)<transacts>:i64=X+2
    \\    var Cell<public>:i64=5
    \\    var Mine:i64=6
    \\    Base:i64=4
    \\    Use:i64=Shut(1)+Mine
    \\    u<public>:=struct{z:i64=0}
    \\    Give<public>(X:i64)<transacts>:u=u{z:=X}
    \\    Cap<public>()<computes>:i64=Base
    \\  }
    \\  Mid:i64=Inner.Open(1)+Inner.Cell+Inner.Cap()
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
    \\    F:function<transacts>(tuple(i64),i64)=Keep
    \\  }
    \\}
    \\Sib:=module{
    \\  Far:i64=Outer.Pub(1)+Outer.Deep.Open(2)+L.Kit.Add(1)+L.LibTop(2)+L.Kit.Count
    \\  K:L.Kit.kt=L.Kit.kt{}
    \\}
    \\Top<public>:i64=Outer.Pub(2)
    \\Hold:t=t{}
    \\Lt<public>:L.lt=L.lt{}
;

/// The chain of nested modules that hold a position, by brute force.
fn chainOf(p: types.Program, span: types.Span, out: *[64]u32) usize {
    var count: usize = 0;
    for (p.nested, 0..) |module, index| if (span.start >= module.source.start and span.end <= module.source.end) {
        out[count] = @intCast(index);
        count += 1;
    };
    return count;
}
fn fileOf(p: types.Program, span: types.Span) ?usize {
    for (p.modules, 0..) |module, index| if (span.start >= module.source.start and span.end <= module.source.end) return index;
    return null;
}
/// A declaration is usable in the scope its privacy reaches: its own scope when not public,
/// else the scope around the innermost non-public module on its path, else everywhere its file is imported.
fn modelVisible(p: types.Program, name: types.Span, public: bool, use: types.Span) bool {
    var decl: [64]u32 = undefined;
    var user: [64]u32 = undefined;
    const decl_count = chainOf(p, name, &decl);
    const user_count = chainOf(p, use, &user);
    const decl_file = fileOf(p, name) orelse return false;
    const user_file = fileOf(p, use) orelse return false;
    // Modules are listed outermost first (table order). Find how deep the reach is.
    var keep: usize = if (public) 0 else decl_count;
    if (public) for (decl[0..decl_count], 0..) |module, depth| {
        if (!p.nested[module].is_public) keep = depth;
    };
    // The user must be inside the first `keep` modules of the declaration's chain.
    if (keep == 0 and public) {
        if (decl_file == user_file) return true;
        const imports = p.modules[user_file].imports;
        for (p.imports[imports.start..imports.end]) |edge| if (edge.target == decl_file) return true;
        return false;
    }
    if (decl_file != user_file or user_count < keep) return false;
    for (decl[0..keep], user[0..keep]) |x, y| if (x != y) return false;
    return true;
}
fn modelCheck(p: types.Program) ?[]const u8 {
    for (p.nodes) |node| switch (node.kind) {
        .call => |c| if (!modelVisible(p, p.functions[c.function].name, p.functions[c.function].is_public, node.span)) return "call",
        .cell_read => |c| if (!modelVisible(p, p.source_cells[c].name, p.source_cells[c].is_public, node.span)) return "cell_read",
        .cell_write => |c| if (!modelVisible(p, p.source_cells[c.cell].name, p.source_cells[c.cell].is_public, node.span)) return "cell_write",
        .function_value => |id| if (!modelVisible(p, p.functions[id].name, p.functions[id].is_public or p.functions[id].template_public, node.span)) return "function_value",
        else => {},
    };
    for (p.function_nodes) |entry| switch (entry.node.kind) {
        .call => |c| if (!modelVisible(p, p.functions[c.function].name, p.functions[c.function].is_public, entry.node.span)) return "body call",
        .cell_read => |c| if (!modelVisible(p, p.source_cells[c].name, p.source_cells[c].is_public, entry.node.span)) return "body cell_read",
        .cell_write => |c| if (!modelVisible(p, p.source_cells[c.cell].name, p.source_cells[c.cell].is_public, entry.node.span)) return "body cell_write",
        .function_value => |id| if (!modelVisible(p, p.functions[id].name, p.functions[id].is_public or p.functions[id].template_public, entry.node.span)) return "body function_value",
        else => {},
    };
    return null;
}

test "12000 forged programs: the machines agree and admit nothing the visibility model refuses" {
    const h = try harness.create();
    defer scratch.release(h);
    const a = std.testing.allocator;
    const program = switch (h.front.compileBundle(.{ .root = "main.forb", .modules = &.{ .{ .path = "main.forb", .source = main_source }, .{ .path = "lib.forb", .source = lib_source } } })) {
        .ok => |ir| ir,
        .failed => |problem| {
            const where = problem.diagnostic.location(problem.source);
            std.debug.print("fuzz compile failed {s} {s}:{d}:{d}\n", .{ @tagName(problem.diagnostic.code), problem.path, where.line, where.column });
            return error.Compile;
        },
    };
    _ = try h.run(program, 1 << 16);
    const nodes = try a.dupe(types.Node, program.nodes);
    defer a.free(nodes);
    const functions = try a.dupe(types.RuntimeFunction, program.functions);
    defer a.free(functions);
    const cells = try a.dupe(types.SourceCell, program.source_cells);
    defer a.free(cells);
    const bindings = try a.dupe(types.Binding, program.bindings);
    defer a.free(bindings);
    const definitions = try a.dupe(types.Definition, program.definitions);
    defer a.free(definitions);
    const globals = try a.dupe(@TypeOf(program.globals[0]), program.globals);
    defer a.free(globals);
    const function_nodes = try a.dupe(types.FunctionNode, program.function_nodes);
    defer a.free(function_nodes);
    const nested = try a.dupe(types.NestedModule, program.nested);
    defer a.free(nested);
    // Every span that names something: the pool the mutations draw from.
    var pool: std.ArrayList(types.Span) = .empty;
    defer pool.deinit(a);
    for (program.functions) |f| try pool.append(a, f.name);
    for (program.source_cells) |c| try pool.append(a, c.name);
    for (program.bindings) |b| try pool.append(a, b.name);
    for (program.globals) |g| try pool.append(a, g.name);
    for (program.nested) |n| try pool.append(a, n.name);
    for (program.nodes) |n| try pool.append(a, n.span);
    for (program.function_nodes) |n| try pool.append(a, n.node.span);
    var generator = std.Random.DefaultPrng.init(0x1234_5678);
    const random = generator.random();
    var admitted: usize = 0;
    var disagreements: usize = 0;
    var violations: usize = 0;
    try std.testing.expect(modelCheck(program) == null);
    var kinds: [12]usize = @splat(0);
    for (0..12000) |round| {
        @memcpy(nodes, program.nodes);
        @memcpy(functions, program.functions);
        @memcpy(cells, program.source_cells);
        @memcpy(bindings, program.bindings);
        @memcpy(definitions, program.definitions);
        @memcpy(globals, program.globals);
        @memcpy(function_nodes, program.function_nodes);
        @memcpy(nested, program.nested);
        var forged = program;
        forged.nodes = nodes;
        forged.functions = functions;
        forged.source_cells = cells;
        forged.bindings = bindings;
        forged.definitions = definitions;
        forged.globals = globals;
        forged.function_nodes = function_nodes;
        forged.nested = nested;
        const span = pool.items[random.uintLessThan(usize, pool.items.len)];
        const kind = random.uintLessThan(u8, 12);
        const steps = 1 + random.uintLessThan(u8, 2);
        for (0..steps) |_| switch (if (steps == 1) kind else random.uintLessThan(u8, 12)) {
            0 => nodes[random.uintLessThan(usize, nodes.len)].span = span,
            1 => function_nodes[random.uintLessThan(usize, function_nodes.len)].node.span = span,
            2 => functions[random.uintLessThan(usize, functions.len)].name = span,
            3 => {
                const f = &functions[random.uintLessThan(usize, functions.len)];
                f.is_public = !f.is_public;
            },
            4 => if (cells.len != 0) {
                cells[random.uintLessThan(usize, cells.len)].name = span;
            },
            5 => if (cells.len != 0) {
                const c = &cells[random.uintLessThan(usize, cells.len)];
                c.is_public = !c.is_public;
            },
            6 => if (globals.len != 0) {
                globals[random.uintLessThan(usize, globals.len)].name = span;
            },
            7 => if (globals.len != 0) {
                const g = &globals[random.uintLessThan(usize, globals.len)];
                g.is_public = !g.is_public;
            },
            8 => {
                const b = &bindings[random.uintLessThan(usize, bindings.len)];
                if (random.boolean()) b.is_public = !b.is_public else b.name = span;
            },
            9 => switch (definitions[random.uintLessThan(usize, definitions.len)]) {
                .record => |*record| if (random.boolean()) {
                    record.is_public = !record.is_public;
                } else {
                    record.name = span;
                },
                else => {},
            },
            10 => forged.nested = nested[0..random.uintLessThan(usize, nested.len + 1)],
            11 => {
                // Retarget a call to another function.
                const at = random.uintLessThan(usize, nodes.len);
                if (nodes[at].kind == .call) nodes[at].kind.call.function = random.uintLessThan(u32, @intCast(functions.len));
            },
            else => unreachable,
        };
        const reference = evaluator.validate(forged, h.values.len);
        const lowered = bytecode.lower(forged, &h.runtime.instructions);
        if (lowered != .ok) {
            if (reference == null) {
                disagreements += 1;
                if (disagreements < 6) std.debug.print("DISAGREE round {d} kind {d}: lowering refuses, evaluator admits\n", .{ round, kind });
            }
            continue;
        }
        const actual = vm.verify(lowered.ok, &h.runtime.machine.register_types);
        if ((reference == null) != (actual != .failed)) {
            disagreements += 1;
            kinds[kind] += 1;
            if (disagreements < 6) std.debug.print("DISAGREE round {d} kind {d} steps {d}: evaluator admits={} vm admits={}\n", .{ round, kind, steps, reference == null, actual != .failed });
        }
        if (reference == null) {
            admitted += 1;
            if (modelCheck(forged)) |what| {
                violations += 1;
                if (violations < 8) std.debug.print("MODEL round {d} kind {d} steps {d}: admitted but the model refuses a {s}\n", .{ round, kind, steps, what });
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), disagreements);
    try std.testing.expectEqual(@as(usize, 0), violations);
    // The mutations are not all refused out of hand: the model is asked of admitted programs.
    try std.testing.expect(admitted > 500);
    _ = try h.run(program, 1 << 16);
}
