//! Prepare once, run many (TASK-0109 W4.3; RFC-0088 A1, A3, A4 and the first part of A5).
//!
//! `prepare` copies a compiled program into one block the handle owns, lowers that copy for the
//! VM, and then has each machine admit its own representation: the reference evaluator's
//! `validate` admits the IR, the VM's `verify` admits the bytecode. Neither uses the other's
//! success. A handle exists only when both succeeded, and it holds the two successes as two
//! records of distinct opaque types (`ReferenceAdmission`, `VmAdmission`) that nothing outside
//! this file can construct or change. Each machine's trusted entry (`evaluator.evaluateAdmitted`,
//! `vm.Machine.runAdmitted`) takes only its own record, so no run skips an admission that was
//! not made for it, and no raw program reaches either without its checked entry point.
//!
//! The handle never points into what it was given: source, IR, strings, module maps, catalogues,
//! function tables and the native table with its names and signatures are copied, so a later
//! compile in the same workspace, or a rewritten source buffer, changes nothing it holds. It is
//! immutable after preparation: its fields are not reachable, and the one buffer a run writes,
//! the string pool's tail, belongs to the run's storage (`VmRun`, `ReferenceRun`), into which
//! each run copies the literals first. Everything else a run changes (fuel, effects, grants,
//! handles, input logs, cells, scheduler, pools, undo records, results) is in that storage and is
//! reset by the run, and every host choice a run depends on is given again in `Options` each
//! time, so nothing of an earlier run or an earlier host setting reaches the next run.
//!
//! The handle is the host's: it is made with the host's allocator and freed by `destroy`.
//! There is no cache and no global state here (RFC-0088 A5's cache and A2's identity are W4.4).
const std = @import("std");
const types = @import("types.zig");
const native = @import("native.zig");
const vm = @import("vm.zig");
const lowering = @import("bytecode.zig");
const evaluator = @import("evaluator.zig");
const scratch = @import("scratch.zig");
const effects = @import("effects.zig");
const source_state = @import("source_state.zig");
const call_frames = @import("call_frames.zig");

const assert = std.debug.assert;

/// An immutable, independently admitted program. Made only by `prepare` and `prepareLowered`.
pub const Prepared = opaque {
    /// The frozen IR: every slice is the handle's own. Its `strings` are the literals alone and
    /// its `string_tail` is empty, so a run of it through a checked entry point has no room to
    /// build strings; runs go through `runVm` and `runReference`. For diagnostics, inspection
    /// and anything else that reads a program.
    pub fn program(self: *const Prepared) types.Program {
        return handle(self).reference.program;
    }
    /// The bytes the handle holds: the snapshot, the native table, the bytecode, the register
    /// types and the handle itself, in one block.
    pub fn bytes(self: *const Prepared) usize {
        return handle(self).block.len;
    }
    /// The reference evaluator's admission of the IR.
    pub fn referenceAdmission(self: *const Prepared) *const ReferenceAdmission {
        return @ptrCast(&handle(self).reference);
    }
    /// The VM's admission of the bytecode.
    pub fn vmAdmission(self: *const Prepared) *const VmAdmission {
        return @ptrCast(&handle(self).machine);
    }

    /// A run on the VM, in `run`'s storage, which must not be in use by another run. The result
    /// borrows that storage until its next run.
    pub fn runVm(self: *const Prepared, run: *VmRun, options: Options) error{InvalidOptions}!evaluator.Result {
        try options.check();
        options.apply(&run.machine.control);
        const held = handle(self);
        const result = run.machine.runAdmitted(self.vmAdmission(), &run.strings, options.work_budget);
        return lowering.execution(over(held.reference.program, &run.strings), &run.machine, result);
    }
    /// A run on the reference evaluator, in `run`'s storage.
    pub fn runReference(self: *const Prepared, run: *ReferenceRun, options: Options) error{InvalidOptions}!evaluator.Result {
        try options.check();
        options.apply(&run.control);
        return evaluator.evaluateAdmitted(self.referenceAdmission(), &run.strings, &run.values, &run.members, &run.control, &run.state, &run.frames, options.work_budget);
    }
    /// The IR over `pool`, the `strings` of the storage (`VmRun` or `ReferenceRun`) a reported
    /// run used, for a report that replays the run (`trace_replay.Storage.producer`): its second
    /// run builds the same strings in the same pool. The replay admits this program itself
    /// (`evaluator.evaluateWithRuntimeStorage`); nothing here vouches for it.
    pub fn replayProgram(self: *const Prepared, pool: *[types.limits.string_bytes]u8) types.Program {
        return over(handle(self).reference.program, pool);
    }

    /// Frees the handle. Nothing that borrows it, results of its runs included, may be used after.
    pub fn destroy(self: *Prepared) void {
        const held: *Handle = @ptrCast(@alignCast(self));
        const allocator = held.allocator;
        const block = held.block;
        held.* = undefined;
        allocator.free(block);
    }
};

/// What the reference evaluator's `validate` admitted: the frozen IR, for storage of at least
/// `capacity` registers.
pub const ReferenceAdmission = opaque {
    /// The registers a run's storage must have.
    pub fn capacity(self: *const ReferenceAdmission) usize {
        return referenceRecord(self).program.nodes.len;
    }
    /// The admitted IR over `strings`: the literals are copied to its start and the rest is the
    /// pool's tail. Null when `strings` cannot hold the literals.
    pub fn view(self: *const ReferenceAdmission, strings: []u8) ?types.Program {
        return rebase(referenceRecord(self).program, strings);
    }
};

/// What the VM's `verify` admitted: the frozen bytecode and the register types it worked out.
pub const VmAdmission = opaque {
    pub fn registers(self: *const VmAdmission) []const types.Type {
        return vmRecord(self).registers;
    }
    /// The admitted bytecode over `strings`, as `ReferenceAdmission.view`.
    pub fn view(self: *const VmAdmission, strings: []u8) ?vm.Program {
        return rebase(vmRecord(self).program, strings);
    }
};

comptime {
    // A3: the two admissions are different types; neither entry point accepts the other's.
    assert(ReferenceAdmission != VmAdmission);
    assert(@typeInfo(@TypeOf(evaluator.evaluateAdmitted)).@"fn".param_types[0].? == *const ReferenceAdmission);
    assert(@typeInfo(@TypeOf(vm.Machine.runAdmitted)).@"fn".param_types[1].? == *const VmAdmission);
}

/// Which admission refused a program: a machine's, or, for `prepareLowered`, the check that the
/// bytecode is the lowering of the IR (`lowering`), made after both machines admitted theirs.
pub const Admission = enum { reference, vm, lowering };
pub const Refusal = struct { by: Admission, diagnostic: types.Diagnostic };
pub const Preparation = union(enum) { ok: *Prepared, failed: Refusal };

/// The host's choices for one run, all given again for every run so that none is left from an
/// earlier one. The defaults are those of fresh machine storage.
pub const Options = struct {
    work_budget: u64 = types.limits.evaluation_work,
    seed: u64 = effects.default_seed,
    tick_rate: u64 = types.Scheduler.default_tick_rate,
    trace: types.TraceMode = .full,
    trace_window: u32 = types.ControlStorage.default_trace_window,
    reclaim_floor: u32 = types.ControlStorage.default_reclaim_floor,
    /// RFC-0086, H1: what the host grants this run. Borrowed for the run.
    grants: []const effects.Grant = &.{},
    source: ?effects.InputSource = null,
    /// The record of an earlier run this one must agree with (RFC-0086, I3). Borrowed.
    prefix: effects.InputRecord = .{},
    sink: ?effects.Sink = null,
    journal: ?effects.InputJournal = null,

    /// The choices a run cannot be given: checked for every run, as the grants of a run are
    /// its own (RFC-0088, A4).
    fn check(self: Options) error{InvalidOptions}!void {
        if (!types.Scheduler.validRate(self.tick_rate) or !effects.validGrants(self.grants)) return error.InvalidOptions;
    }
    fn apply(self: Options, control: *types.ControlStorage) void {
        control.trace = self.trace;
        control.trace_window = self.trace_window;
        control.trace_sink = null;
        control.reclaim_floor = self.reclaim_floor;
        control.tick_rate = self.tick_rate;
        control.effects.seed = self.seed;
        control.effects.sink = self.sink;
        control.effects.inputs.source = self.source;
        control.effects.inputs.prefix = self.prefix;
        control.effects.inputs.grants = self.grants;
        control.effects.inputs.journal = self.journal;
    }
};

/// The storage of runs on the VM: one worker's, never shared by two runs at once. Make it with
/// `scratch.storage` and `scratch.initialise`; only what a run uses is ever touched.
pub const VmRun = struct {
    machine: vm.Machine = .{},
    /// The run's string pool: the literals, copied in by each run, then the strings it builds.
    /// As large as the compiler's, so a run has the room a compile-and-run has.
    strings: [types.limits.string_bytes]u8 = undefined,
};

/// The storage of runs on the reference evaluator, as `VmRun`.
pub const ReferenceRun = struct {
    values: [types.limits.nodes]types.Value = undefined,
    members: [types.limits.aggregate_elements]types.Value = undefined,
    control: types.ControlStorage = .{},
    state: source_state.ReferenceState = .{},
    frames: call_frames.ReferenceStorage = .{},
    strings: [types.limits.string_bytes]u8 = undefined,
};

/// Copies `program`, lowers the copy and has both machines admit it. Out of memory is the
/// host's allocator; a program either admission refuses is `failed`, and then nothing is kept.
pub fn prepare(allocator: std.mem.Allocator, program: types.Program) error{OutOfMemory}!Preparation {
    return prepareFrom(allocator, program, null);
}

/// As `prepare`, with bytecode the host lowered or kept itself: it is copied and admitted by
/// the VM on its own, as the IR is by the reference evaluator, so neither one's success
/// vouches for the other's input (RFC-0088, A1: IR and bytecode are kept apart). Then the
/// bytecode must be, instruction by instruction, the lowering of the IR (`.lowering`): two
/// representations that each admit but differ are not one program.
pub fn prepareLowered(allocator: std.mem.Allocator, program: types.Program, code: []const vm.Instruction) error{OutOfMemory}!Preparation {
    return prepareFrom(allocator, program, code);
}

/// Each admission's own record, kept in the handle. Not public: only `prepareFrom` makes them,
/// and only after the admission it names succeeded.
const ReferenceRecord = struct { program: types.Program };
const VmRecord = struct { program: vm.Program, registers: []const types.Type };

const Handle = struct {
    allocator: std.mem.Allocator,
    /// Everything the handle holds, itself included.
    block: []align(block_alignment.toByteUnits()) u8,
    reference: ReferenceRecord,
    machine: VmRecord,
};

fn handle(prepared: *const Prepared) *const Handle {
    return @ptrCast(@alignCast(prepared));
}
fn referenceRecord(admission: *const ReferenceAdmission) *const ReferenceRecord {
    return @ptrCast(@alignCast(admission));
}
fn vmRecord(admission: *const VmAdmission) *const VmRecord {
    return @ptrCast(@alignCast(admission));
}

/// `program` over `strings`, with the literals copied in first.
fn rebase(program: anytype, strings: []u8) ?@TypeOf(program) {
    const literals = program.strings.len;
    if (strings.len < literals) return null;
    @memcpy(strings[0..literals], program.strings);
    return over(program, strings);
}
/// `program` over `strings`, which already hold its literals.
fn over(program: anytype, strings: []u8) @TypeOf(program) {
    const literals = program.strings.len;
    assert(strings.len >= literals);
    var view = program;
    view.strings = strings[0..literals];
    view.string_tail = strings[literals..];
    return view;
}

/// Whether `T` holds a pointer anywhere: such an element cannot be copied as bytes.
fn pointerFree(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    return switch (@typeInfo(T)) {
        .pointer => false,
        .@"struct" => |s| for (s.field_types) |field| {
            if (!pointerFree(field)) break false;
        } else true,
        .@"union" => |u| for (u.field_types) |field| {
            if (!pointerFree(field)) break false;
        } else true,
        .optional => |o| pointerFree(o.child),
        .array => |a| pointerFree(a.child),
        .bool, .int, .float, .@"enum", .void => true,
        else => false,
    };
}

const program_fields = @typeInfo(types.Program).@"struct";

/// The alignment of the block: the largest of anything placed in it.
const block_alignment: std.mem.Alignment = blk: {
    var largest: usize = @max(@alignOf(std.mem.Allocator), @alignOf(usize), @alignOf(vm.Instruction), @alignOf(types.Type), @alignOf(native.Entry), @alignOf(native.Shape));
    for (program_fields.field_types) |field| if (@typeInfo(field) == .pointer) {
        largest = @max(largest, @alignOf(@typeInfo(field).pointer.child));
    };
    break :blk .fromByteUnits(largest);
};

comptime {
    // A1, by construction: every slice of a program is copied, and every element type copied as
    // bytes holds no pointer, so nothing in a handle can point into what it was given. A new
    // field of another kind must be taught to `copyProgram` before this compiles.
    for (program_fields.field_names, program_fields.field_types) |name, field| switch (@typeInfo(field)) {
        .pointer => |pointer| {
            assert(pointer.size == .slice);
            if (std.mem.eql(u8, name, "natives")) {
                assert(pointer.child == native.Entry);
            } else if (std.mem.eql(u8, name, "string_tail")) {
                assert(!pointer.attrs.@"const");
            } else {
                assert(pointer.attrs.@"const");
                if (!pointerFree(pointer.child)) @compileError("types.Program." ++ name ++ " holds pointers: copy it deeply");
            }
        },
        .int => {},
        else => @compileError("types.Program." ++ name ++ " is neither a slice nor a count"),
    };
    // A native entry is copied field by field: its name and its parameters, and the function,
    // which is the host's code and lives as long as the process.
    const entry = @typeInfo(native.Entry).@"struct";
    for (entry.field_names, entry.field_types) |name, field| {
        if (std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "params") or std.mem.eql(u8, name, "call")) continue;
        // TASK-0109, W4.4: the host's context, which the host lends for as long as the handle may run.
        if (std.mem.eql(u8, name, "host")) continue;
        if (!pointerFree(field)) @compileError("native.Entry." ++ name ++ " holds pointers: copy it deeply");
    }
    assert(pointerFree(native.Shape) and pointerFree(vm.Instruction) and pointerFree(types.Type));
    assert(@alignOf(Handle) <= block_alignment.toByteUnits());
}

/// Places items in the block: the first pass only measures (`block` empty), the second copies.
const Cursor = struct {
    block: []align(block_alignment.toByteUnits()) u8,
    at: usize = 0,
    /// Set when a size does not fit `usize`: the program is then refused, nothing allocated.
    overflow: bool = false,

    fn many(self: *Cursor, comptime T: type, count: usize) []T {
        if (self.overflow) return &.{};
        // The padding is added with a check too: rounding up `at` can itself overflow.
        const padding = (@alignOf(T) - self.at % @alignOf(T)) % @alignOf(T);
        const start = std.math.add(usize, self.at, padding) catch return self.overflowed(T);
        const size = std.math.mul(usize, @sizeOf(T), count) catch return self.overflowed(T);
        const end = std.math.add(usize, start, size) catch return self.overflowed(T);
        self.at = end;
        if (self.block.len == 0) return &.{};
        assert(end <= self.block.len);
        const base: [*]T = @ptrCast(@alignCast(self.block[start..].ptr));
        return base[0..count];
    }
    fn copy(self: *Cursor, comptime T: type, items: []const T) []const T {
        const place = self.many(T, items.len);
        if (self.block.len != 0) @memcpy(place, items);
        return place;
    }
    fn overflowed(self: *Cursor, comptime T: type) []T {
        self.overflow = true;
        return &.{};
    }
};

/// The program with every slice in the block (or measured, on the first pass). The tail of the
/// string pool is not the handle's: each run brings its own.
fn copyProgram(cursor: *Cursor, program: types.Program) types.Program {
    var copied: types.Program = undefined;
    inline for (program_fields.field_names, program_fields.field_types) |name, field| {
        if (comptime @typeInfo(field) == .pointer) {
            const Element = @typeInfo(field).pointer.child;
            if (comptime std.mem.eql(u8, name, "natives")) {
                @field(copied, name) = copyNatives(cursor, program.natives);
            } else if (comptime std.mem.eql(u8, name, "string_tail")) {
                @field(copied, name) = &.{};
            } else {
                @field(copied, name) = cursor.copy(Element, @field(program, name));
            }
        } else {
            @field(copied, name) = @field(program, name);
        }
    }
    return copied;
}

fn copyNatives(cursor: *Cursor, natives: []const native.Entry) []const native.Entry {
    const entries = cursor.many(native.Entry, natives.len);
    for (natives, 0..) |entry, index| {
        const id = cursor.copy(u8, entry.id);
        const params = cursor.copy(native.Shape, entry.params);
        if (cursor.block.len == 0) continue;
        entries[index] = entry;
        entries[index].id = id;
        entries[index].params = params;
    }
    return entries;
}

/// The most elements a compiled program has in each table: the capacity of the storage the
/// compiler builds it in. Every slice of `types.Program` must have one (a new field does not
/// compile until it does), so no length a program states sizes an allocation beyond what an
/// honest program can have.
fn bound(comptime name: []const u8) usize {
    @setEvalBranchQuota(100_000);
    const limits = types.limits;
    const table = .{
        .{ "source", limits.source_bytes },                .{ "nodes", limits.nodes },
        .{ "bindings", limits.bindings },                  .{ "strings", limits.string_bytes },
        .{ "definitions", limits.user_types },             .{ "fields", limits.fields },
        .{ "members", limits.aggregate_elements },         .{ "cases", limits.cases },
        .{ "tuple_elements", limits.tuple_elements },      .{ "paths", limits.module_paths_bytes },
        .{ "modules", limits.modules },                    .{ "imports", limits.imports },
        .{ "nested", limits.modules },                     .{ "parts", limits.module_files },
        .{ "file_paths", limits.module_file_paths_bytes }, .{ "source_cells", limits.source_cells },
        .{ "call_arguments", limits.call_arguments },      .{ "functions", limits.functions },
        .{ "function_nodes", limits.template_nodes },      .{ "function_members", limits.aggregate_elements },
        .{ "function_arguments", limits.call_arguments },  .{ "globals", limits.bindings },
        .{ "slots", limits.methods },                      .{ "dispatch", limits.dispatch },
        .{ "constants", limits.template_nodes },           .{ "constant_members", limits.aggregate_elements },
        // The host's native table: a `native_call` names an entry with 16 bits.
        .{ "natives", std.math.maxInt(u16) + 1 },
    };
    inline for (table) |entry| if (comptime std.mem.eql(u8, entry[0], name)) return entry[1];
    @compileError("types.Program." ++ name ++ " has no bound in `prepared.bound`");
}

/// Whether every table of `program` is within its bound, and every native entry's name and
/// parameters within theirs: checked in time proportional to the native table, before anything
/// is measured or allocated.
fn bounded(program: types.Program) bool {
    inline for (program_fields.field_names, program_fields.field_types) |name, field| {
        if (comptime @typeInfo(field) == .pointer and !std.mem.eql(u8, name, "string_tail")) {
            if (@field(program, name).len > comptime bound(name)) return false;
        }
    }
    for (program.natives) |entry| if (entry.id.len > types.limits.identifier_bytes or entry.params.len > native.max_parameters) return false;
    return true;
}

/// Whether two values of a pointer-free type are equal field by field, floats by their bits:
/// what `prepareLowered` compares bytecode with, so that padding never matters and a NaN
/// literal equals itself.
fn same(comptime T: type, a: T, b: T) bool {
    @setEvalBranchQuota(100_000);
    return switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names) |name| {
            if (!same(@FieldType(T, name), @field(a, name), @field(b, name))) break false;
        } else true,
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            if (@as(Tag, a) != @as(Tag, b)) return false;
            return switch (a) {
                inline else => |payload, tag| same(@TypeOf(payload), payload, @field(b, @tagName(tag))),
            };
        },
        .optional => |o| if (a == null or b == null) a == null and b == null else same(o.child, a.?, b.?),
        .array => |array| for (a, b) |x, y| {
            if (!same(array.child, x, y)) break false;
        } else true,
        .float => @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(a)) == @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(b)),
        .bool, .int, .@"enum" => a == b,
        .void => true,
        else => @compileError("cannot compare " ++ @typeName(T)),
    };
}

fn prepareFrom(allocator: std.mem.Allocator, program: types.Program, given: ?[]const vm.Instruction) error{OutOfMemory}!Preparation {
    const origin: types.Span = .{ .start = 0, .end = 0 };
    const code_count = if (given) |code| code.len else program.nodes.len;
    // Every length is checked against what a compiled program can have before anything is
    // measured or allocated, so a forged length never sizes an allocation; the admissions then
    // check the same bounds again on the frozen copy.
    if (!bounded(program)) return .{ .failed = .{ .by = .reference, .diagnostic = .{ .span = origin, .code = .invalid_ir } } };
    if (code_count > types.limits.nodes) return .{ .failed = .{ .by = .vm, .diagnostic = .{ .span = origin, .code = .invalid_ir } } };
    var measure: Cursor = .{ .block = &.{} };
    _ = measure.many(Handle, 1);
    _ = copyProgram(&measure, program);
    _ = measure.many(vm.Instruction, code_count);
    _ = measure.many(types.Type, code_count);
    if (measure.overflow) return error.OutOfMemory;
    const block = try allocator.alignedAlloc(u8, block_alignment, measure.at);
    var done = false;
    defer if (!done) allocator.free(block);
    var cursor: Cursor = .{ .block = block };
    const held = &cursor.many(Handle, 1)[0];
    // A1: the snapshot is frozen before either admission reads it.
    const snapshot = copyProgram(&cursor, program);
    const code = cursor.many(vm.Instruction, code_count);
    const registers = cursor.many(types.Type, code_count);
    assert(cursor.at == measure.at and !cursor.overflow);
    if (given) |lowered| @memcpy(code, lowered) else {
        for (snapshot.nodes, code) |node, *instruction| instruction.* = vm.instructionFromNode(node);
    }
    const machine_program = lowering.borrow(snapshot, code);
    // A3: the VM's verifier admits the bytecode. Its register types are kept for the runs.
    const scratch_registers = scratch.alloc(types.Type, types.limits.nodes) orelse return .{ .failed = .{ .by = .vm, .diagnostic = .{ .span = origin, .code = .scratch_unavailable } } };
    defer scratch.free(scratch_registers);
    const register_count = switch (vm.verify(machine_program, scratch_registers[0..types.limits.nodes])) {
        .ok => |count| count,
        .failed => |diagnostic| return .{ .failed = .{ .by = .vm, .diagnostic = .{ .span = diagnostic.span, .code = if (diagnostic.code == .invalid_bytecode) .invalid_ir else diagnostic.code } } },
    };
    assert(register_count <= code_count);
    @memcpy(registers[0..register_count], scratch_registers[0..register_count]);
    // A3: the reference evaluator's validation admits the IR, for registers of its own size.
    if (evaluator.validate(snapshot, snapshot.nodes.len)) |diagnostic| return .{ .failed = .{ .by = .reference, .diagnostic = diagnostic } };
    // Two representations each admitted are not yet one program: given bytecode must be the
    // lowering of the IR, or the machines would run different programs under one handle.
    if (given != null) {
        if (code.len != snapshot.nodes.len) return .{ .failed = .{ .by = .lowering, .diagnostic = .{ .span = origin, .code = .invalid_ir } } };
        for (snapshot.nodes, code) |node, instruction| if (!same(vm.Instruction, vm.instructionFromNode(node), instruction)) {
            return .{ .failed = .{ .by = .lowering, .diagnostic = .{ .span = instruction.span, .code = .invalid_ir } } };
        };
    }
    held.* = .{
        .allocator = allocator,
        .block = block,
        .reference = .{ .program = snapshot },
        .machine = .{ .program = machine_program, .registers = registers[0..register_count] },
    };
    done = true;
    return .{ .ok = @ptrCast(held) };
}

test "the cursor refuses a size that overflows, the rounding to an alignment included" {
    var cursor: Cursor = .{ .block = &.{}, .at = std.math.maxInt(usize) - 1 };
    _ = cursor.many(u64, 0);
    try std.testing.expect(cursor.overflow);
    cursor = .{ .block = &.{}, .at = 8 };
    _ = cursor.many(u64, std.math.maxInt(usize) / 4);
    try std.testing.expect(cursor.overflow);
    cursor = .{ .block = &.{}, .at = 1 };
    _ = cursor.many(u64, 2);
    try std.testing.expect(!cursor.overflow and cursor.at == 24);
    // Once overflowed, nothing after it is measured.
    cursor.overflow = true;
    _ = cursor.many(u8, 5);
    try std.testing.expectEqual(@as(usize, 24), cursor.at);
}
