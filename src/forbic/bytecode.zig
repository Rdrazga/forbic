//! Lower the pure indexed IR into dense-register VM instructions.
const std = @import("std");
const types = @import("types.zig");
const vm = @import("vm.zig");
const evaluator = @import("evaluator.zig");
const modules = @import("modules.zig");
const lowering = @This();
pub const Result = union(enum) { ok: vm.Program, failed: types.Diagnostic };
pub const Workspace = struct {
    instructions: [types.limits.nodes]vm.Instruction = undefined,
    machine: vm.Machine = .{},

    pub fn evaluate(self: *Workspace, program: types.Program, work_budget: u64) evaluator.Result {
        return lowering.evaluate(program, &self.instructions, &self.machine, work_budget);
    }
};

/// Storage and source/IR strings must outlive the returned borrowed program.
pub fn lower(program: types.Program, storage: []vm.Instruction) Result {
    if (program.nodes.len > storage.len or program.nodes.len > types.limits.nodes) return invalid();
    if (program.bindings.len > types.limits.bindings or program.source.len > types.limits.source_bytes or program.strings.len > types.limits.string_bytes) return invalid();
    if (!modules.validateBundle(program.source, program.paths, program.modules, program.imports, program.nested, program.parts, program.file_paths)) return invalid();
    for (program.nodes, 0..) |node, index| {
        storage[index] = vm.instructionFromNode(node);
    }
    std.debug.assert(program.nodes.len <= storage.len);
    return .{ .ok = borrow(program, storage[0..program.nodes.len]) };
}

/// The VM's program over `code` and the tables of `program`, which it borrows. Nothing is
/// checked: the VM admits what it runs (`vm.verify`).
pub fn borrow(program: types.Program, code: []const vm.Instruction) vm.Program {
    return .{ .source = program.source, .strings = program.strings, .code = code, .bindings = program.bindings, .definitions = program.definitions, .fields = program.fields, .members = program.members, .cases = program.cases, .tuple_elements = program.tuple_elements, .paths = program.paths, .modules = program.modules, .imports = program.imports, .nested = program.nested, .string_comparisons = program.string_comparisons, .control_ops = program.control_ops, .source_cells = program.source_cells, .source_ops = program.source_ops, .call_ops = program.call_ops, .call_arguments = program.call_arguments, .functions = program.functions, .function_nodes = program.function_nodes, .function_members = program.function_members, .function_arguments = program.function_arguments, .globals = program.globals, .natives = program.natives, .string_tail = program.string_tail, .slots = program.slots, .dispatch = program.dispatch, .constants = program.constants, .constant_members = program.constant_members, .parts = program.parts, .file_paths = program.file_paths };
}

pub fn evaluate(program: types.Program, storage: []vm.Instruction, machine: *vm.Machine, work_budget: u64) evaluator.Result {
    const bytecode = switch (lower(program, storage)) {
        .failed => |diagnostic| return .{ .failed = diagnostic },
        .ok => |bytecode| bytecode,
    };
    return execution(program, machine, machine.run(bytecode, work_budget));
}

/// What a run of the machine reports, over the IR `program` it was lowered from.
pub fn execution(program: types.Program, machine: *vm.Machine, result: vm.Result) evaluator.Result {
    return switch (result) {
        .ok => |values| .{ .ok = .{ .program = extended: {
            var view = program;
            view.strings = program.strings.ptr[0..machine.string_used];
            break :extended view;
        }, .values = values, .aggregate_values = machine.aggregate_values[0..machine.aggregate_count], .activity = if (!types.sparse(program)) &.{} else machine.control.activity[0..values.len], .failures = if (types.sparse(program) or types.failureCalls(program)) machine.control.traces[0..machine.control.trace_count] else &.{}, .failure_count = if (types.sparse(program) or types.failureCalls(program)) machine.control.failure_count else 0, .call_steps = machine.control.calls[0..machine.control.call_count], .trace = if (types.cold(program)) machine.control.trace else .full, .witness = if (types.cold(program) and machine.control.trace == .digest) machine.control.witness else .{}, .reclaim_floor = machine.control.reclaim_floor, .reclaims = if (types.cold(program)) machine.control.reclaims else 0, .object_cells = if (machine.source.cell_count > program.source_cells.len) machine.source.cells[program.source_cells.len..machine.source.cell_count] else &.{}, .effects = if (types.cold(program)) machine.control.effects.record() else .{}, .scheduler = if (types.cold(program)) machine.schedulerRecord() else .{ .tick_rate = machine.control.tick_rate }, .cells = if (machine.source.cell_count >= program.source_cells.len and (evaluator.spawns(program) or machine.live.on or types.keyedCells(program))) machine.source.cells[0..program.source_cells.len] else &.{}, .live = if (types.cold(program)) machine.live.record else .{} } },
        .failed => |diagnostic| .{ .failed = .{ .span = diagnostic.span, .code = if (diagnostic.code == .invalid_bytecode) .invalid_ir else diagnostic.code } },
    };
}

fn invalid() Result {
    return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .invalid_ir } };
}
