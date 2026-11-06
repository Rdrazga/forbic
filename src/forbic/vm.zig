//! Verified, bounded dense-register bytecode. No native execution or suspension.
const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const catalogue = @import("aggregate_types.zig");
const native = @import("native.zig");
const run_strings = @import("run_strings.zig");
const array_concat = @import("array_concat.zig");
const scratch = @import("scratch.zig");
const name_index = @import("name_index.zig");
const keys = @import("map_keys.zig");
const modules = @import("modules.zig");
const transaction = @import("transaction.zig");
const source_state = @import("source_state.zig");
const call_frames = @import("call_frames.zig");
const live_machine = @import("live_machine.zig");
const effects = @import("effects.zig");
const persistable = @import("persistable.zig");
const persist_json = @import("persist_json.zig");
const prepared = @import("prepared.zig");
const assert = std.debug.assert;
comptime {
    // Scalar Value tags and stable builtin Type IDs share this exact ordering.
    // Keep the checked dispatch shortcut explicit if either representation grows.
    assert(@backingInt(std.meta.Tag(types.Value).integer) == @backingInt(types.Type.i64));
    assert(@backingInt(std.meta.Tag(types.Value).boolean) == @backingInt(types.Type.logic));
    assert(@backingInt(std.meta.Tag(types.Value).string) == @backingInt(types.Type.string));
    assert(@backingInt(std.meta.Tag(types.Value).floating) == @backingInt(types.Type.float));
}
/// Instruction slack beyond one per node; twice the node capacity (16K under bootstrap).
pub const max_instructions = 2 * types.limits.nodes;
pub const Instruction = struct {
    span: types.Span = .{ .start = 0, .end = 0 },
    value_type: ?types.Type = null,
    op: union(enum) {
        integer: i64,
        boolean: bool,
        string: types.Span,
        negate: u32,
        binary: types.Binary,
        begin,
        commit,
        abort,
        load_cell: u32,
        store_cell: struct { cell: u32, value: u32 },
        require: u32,
        enqueue: struct { kind: u32, argument: u32 },
        floating: f64,
        float_negate: u32,
        int_to_float: u32,
        float_to_int: types.FloatToInt,
        float_binary: types.Binary,
        rational: types.RationalNode,
        aggregate: types.Span,
        field: types.FieldAccess,
        array_length: u32,
        enumeration: u32,
        tuple_element: types.FieldAccess,
        option_present: u32,
        option_value: u32,
        option_or: types.Choice,
        map_lookup: types.Lookup,
        array_get: types.ArrayIndex,
        map_key: types.ArrayIndex,
        map_value: types.ArrayIndex,
        native_call: types.NativeCall,
        string_concat: types.StringPair,
        array_concat: types.StringPair,
        array_set: types.ArraySet,
        map_set: types.MapSet,
        map_remove: types.Lookup,
        string_length: u32,
        to_string: u32,
        compare: types.Comparison,
        logic_not: u32,
        logic_binary: types.LogicBinary,
        if_begin: types.Branch,
        attempt_begin: types.Branch,
        otherwise: u32,
        merge: types.Merge,
        demand: u32,
        fail: u32,
        /// Function bodies only: return the operand, committing the regions the frame has open.
        exit: u32,
        /// Ends the run with `runtime_error`; the operand is the message.
        err: u32,
        cell_init: types.CellWrite,
        cell_read: u32,
        cell_write: types.CellWrite,
        object_new: types.ObjectNew,
        object_get: types.FieldAccess,
        object_set: types.ObjectSet,
        upcast: u32,
        downcast: u32,
        instance_of: types.InstanceOf,
        method_value: types.MethodValue,
        local_set: u32,
        call: types.Call,
        iterate: types.Iteration,
        recur: types.Span,
        function_value: u32,
        self_value,
        invoke: types.Invoke,
        bind: types.Invoke,
        iterate_value: types.CallableIteration,
        loop: types.StateLoop,
        character: u32,
        text: types.Text,
        /// RFC-0082: see `types.Node`.
        spawn: u32,
        sleep: u32,
        canceling,
        cancel_exit,
        /// RFC-0083: see `types.Node`.
        refine: u32,
        task_await: u32,
        event_new,
        event_signal: types.EventSignal,
        event_await: u32,
        /// RFC-0082, P3.3: see `types.Node`.
        structured: types.Structured,
        /// RFC-0082, P3.4: see `types.Node`.
        branch: u32,
        /// RFC-0084: see `types.Node`.
        cell_live: types.CellLive,
        object_live: types.ObjectLive,
        /// RFC-0082, P3.6: see `types.Node`.
        arm_exit: u32,
        arm_exited,
        arm_exit_value,
        /// RFC-0084, P4.4: see `types.Node`.
        reaction: types.Reaction,
        /// RFC-0082, P3.7: see `types.Node`.
        task_cancel: u32,
        elapsed_time,
        /// RFC-0084, P4.5: see `types.Node`.
        batch: u32,
        /// RFC-0084, P4.6: see `types.Node`.
        await_guard: u32,
        /// RFC-0082, P3.9: see `types.Node`.
        event_subscribe: types.EventSubscribe,
        subscription_cancel: u32,
        event_notify: types.Invoke,
        /// RFC-0085, I1: see `types.Node`.
        ref_new: u32,
        ref_get: u32,
        ref_set: types.RefSet,
        /// RFC-0086, P2.3: see `types.Node`.
        grant: types.Grant,
        /// RFC-0087, P5.4: see `types.Node`.
        weak_init: u32,
        weak_get: types.WeakGet,
        weak_set: types.WeakSet,
        /// RFC-0087, P5.3: see `types.Node`.
        json_encode: u32,
        json_decode: u32,
    },
    pub fn invocationWith(self: Instruction, values: []const types.Value) ?types.Invocation {
        if (self.op == .invoke) return .{ .call = .{ .function = values[self.op.invoke.callable].callable.function, .arguments = self.op.invoke.arguments, .captures = values[self.op.invoke.callable].callable.captures } };
        if (self.op == .loop) {
            const l = self.op.loop;
            return .{ .loop = .{ .function = values[l.callable].callable.function, .initial = l.initial, .captures = values[l.callable].callable.captures } };
        }
        if (self.op == .iterate_value) {
            const i = self.op.iterate_value;
            return .{ .iterate = .{ .function = values[i.callable].callable.function, .count = i.count, .initial = i.initial, .captures = values[i.callable].callable.captures } };
        }
        return self.invocation();
    }
    pub fn invocation(self: Instruction) ?types.Invocation {
        return switch (self.op) {
            .call => |c| .{ .call = .{ .function = c.function, .arguments = c.arguments } },
            .iterate => |i| .{ .iterate = .{ .function = i.function, .count = i.count, .initial = i.initial } },
            else => null,
        };
    }
};
pub fn instructionFromNode(node: types.Node) Instruction {
    return .{ .span = node.span, .value_type = node.value_type, .op = switch (node.kind) {
        .call => |c| .{ .call = .{ .function = c.function, .arguments = c.arguments } },
        .iterate => |i| .{ .iterate = .{ .function = i.function, .count = i.count, .initial = i.initial } },
        .recur => |r| .{ .recur = r },
        .function_value => |id| .{ .function_value = id },
        .self_value => .self_value,
        .invoke => |i| .{ .invoke = i },
        .bind => |b| .{ .bind = b },
        .iterate_value => |i| .{ .iterate_value = i },
        .loop => |l| .{ .loop = l },
        .if_begin => |b| .{ .if_begin = b },
        .attempt_begin => |b| .{ .attempt_begin = b },
        .otherwise => |b| .{ .otherwise = b },
        .merge => |m| .{ .merge = m },
        .cell_init => |c| .{ .cell_init = c },
        .local_set => |n| .{ .local_set = n },
        .upcast => |n| .{ .upcast = n },
        .downcast => |n| .{ .downcast = n },
        .instance_of => |c| .{ .instance_of = c },
        .method_value => |m| .{ .method_value = m },
        .cell_read => |c| .{ .cell_read = c },
        .cell_write => |c| .{ .cell_write = c },
        .object_new => |c| .{ .object_new = c },
        .object_get => |a| .{ .object_get = a },
        .object_set => |c| .{ .object_set = c },
        .demand => |n| .{ .demand = n },
        .fail => |n| .{ .fail = n },
        .exit => |n| .{ .exit = n },
        .err => |n| .{ .err = n },
        .integer => |value| .{ .integer = value },
        .floating => |value| .{ .floating = value },
        .boolean => |value| .{ .boolean = value },
        .string => |span| .{ .string = span },
        .negate => |operand| .{ .negate = operand },
        .float_negate => |operand| .{ .float_negate = operand },
        .int_to_float => |operand| .{ .int_to_float = operand },
        .float_to_int => |c| .{ .float_to_int = c },
        .binary => |binary| .{ .binary = .{ .op = binary.op, .lhs = binary.lhs, .rhs = binary.rhs } },
        .float_binary => |binary| .{ .float_binary = binary },
        .rational => |r| .{ .rational = r },
        .aggregate => |range| .{ .aggregate = range },
        .field => |access| .{ .field = access },
        .array_length => |operand| .{ .array_length = operand },
        .enumeration => |case_index| .{ .enumeration = case_index },
        .tuple_element => |access| .{ .tuple_element = access },
        .option_present => |operand| .{ .option_present = operand },
        .option_value => |operand| .{ .option_value = operand },
        .option_or => |choice| .{ .option_or = choice },
        .map_lookup => |lookup| .{ .map_lookup = lookup },
        .array_get => |access| .{ .array_get = access },
        .map_key => |access| .{ .map_key = access },
        .map_value => |access| .{ .map_value = access },
        .native_call => |c| .{ .native_call = c },
        .string_concat => |c| .{ .string_concat = c },
        .array_concat => |c| .{ .array_concat = c },
        .array_set => |c| .{ .array_set = c },
        .map_set => |c| .{ .map_set = c },
        .map_remove => |c| .{ .map_remove = c },
        .string_length => |operand| .{ .string_length = operand },
        .to_string => |operand| .{ .to_string = operand },
        .compare => |comparison| .{ .compare = comparison },
        .logic_not => |operand| .{ .logic_not = operand },
        .logic_binary => |binary| .{ .logic_binary = binary },
        .character => |code| .{ .character = code },
        .text => |t| .{ .text = t },
        .spawn => |n| .{ .spawn = n },
        .sleep => |n| .{ .sleep = n },
        .task_await => |n| .{ .task_await = n },
        .event_new => .event_new,
        .event_signal => |s| .{ .event_signal = s },
        .event_await => |n| .{ .event_await = n },
        .canceling => .canceling,
        .cancel_exit => .cancel_exit,
        .refine => |n| .{ .refine = n },
        .structured => |s| .{ .structured = s },
        .branch => |n| .{ .branch = n },
        .cell_live => |c| .{ .cell_live = c },
        .object_live => |c| .{ .object_live = c },
        .arm_exit => |n| .{ .arm_exit = n },
        .arm_exited => .arm_exited,
        .arm_exit_value => .arm_exit_value,
        .reaction => |r| .{ .reaction = r },
        .task_cancel => |n| .{ .task_cancel = n },
        .elapsed_time => .elapsed_time,
        .batch => |n| .{ .batch = n },
        .await_guard => |n| .{ .await_guard = n },
        .event_subscribe => |s| .{ .event_subscribe = s },
        .subscription_cancel => |n| .{ .subscription_cancel = n },
        .event_notify => |i| .{ .event_notify = i },
        .ref_new => |n| .{ .ref_new = n },
        .ref_get => |n| .{ .ref_get = n },
        .ref_set => |r| .{ .ref_set = r },
        .grant => |g| .{ .grant = g },
        .weak_init => |c| .{ .weak_init = c },
        .weak_get => |g| .{ .weak_get = g },
        .weak_set => |c| .{ .weak_set = c },
        .json_encode => |n| .{ .json_encode = n },
        .json_decode => |n| .{ .json_decode = n },
    } };
}

pub const Program = struct {
    source: []const u8 = "",
    strings: []const u8 = "",
    code: []const Instruction,
    bindings: []const types.Binding = &.{},
    definitions: []const types.Definition = &.{},
    fields: []const types.Field = &.{},
    members: []const u32 = &.{},
    cases: []const types.Span = &.{},
    tuple_elements: []const types.Type = &.{},
    paths: []const u8 = "",
    modules: []const types.Module = &.{},
    imports: []const types.Import = &.{},
    nested: []const types.NestedModule = &.{},
    /// RFC-0093: the files of a folder tree's modules, for diagnostics; admitted with the rest.
    parts: []const types.ModulePart = &.{},
    file_paths: []const u8 = "",
    string_comparisons: u32 = 0,
    control_ops: u32 = 0,
    source_cells: []const types.SourceCell = &.{},
    source_ops: u32 = 0,
    call_ops: u32 = 0,
    call_arguments: []const u32 = &.{},
    functions: []const types.RuntimeFunction = &.{},
    function_nodes: []const types.FunctionNode = &.{},
    function_members: []const u32 = &.{},
    function_arguments: []const u32 = &.{},
    globals: []const types.Binding = &.{},
    natives: []const native.Entry = &.{},
    string_tail: []u8 = &.{},
    slots: []const types.Slot = &.{},
    dispatch: []const types.Dispatch = &.{},
    constants: []const types.Constant = &.{},
    constant_members: []const u32 = &.{},
};
pub const Result = union(enum) { ok: []const types.Value, failed: types.Diagnostic };
const VerifyError = error{ InvalidBytecode, DepthLimit };
const RuntimeError = transaction.Error || source_state.Error || keys.Error || error{ Overflow, DivisionByZero, IndexRange, RequirementFailed, InvalidBytecode, AggregateLimit, NativeFailed, StringLimit, InvalidNative, EffectLimit, EffectPrepareFailed, EffectCommitFailed } || effects.InputError || error{ TaskLimit, SchedulerActionLimit, SuspendedFrameLimit, CallTraceLimit, CallDepthLimit, CallRegisterLimit, InvalidSleepDuration };

pub const Machine = struct {
    values: [types.limits.nodes]types.Value = undefined,
    register_types: [types.limits.nodes]types.Type = undefined,
    /// The types of the running program's registers: the prefix of `register_types` that
    /// `verify` filled, or the immutable table of a prepared handle (`runAdmitted`).
    registers: []const types.Type = &.{},
    aggregate_values: [types.limits.aggregate_elements]types.Value = undefined,
    aggregate_count: usize = 0,
    /// Bytes of the string pool in use: literals plus run-built strings.
    string_used: usize = 0,
    /// `run_strings.Pool.stale` of the pool: where its tail is not the newest string's end.
    string_stale: usize = run_strings.Pool.fresh,
    journal: transaction.Journal = .{},
    control: types.ControlStorage = .{},
    source: source_state.Journal = .{},
    calls: call_frames.VmStorage = .{},
    /// Levels of a structural walk below the ones on the native stack. The machine owns them,
    /// so a comparison or lookup never asks the host for memory, however deep its operands.
    key_levels: keys.FarLevels = undefined,
    /// Lends `key_levels` during a run and holds the table of a large map literal until its
    /// end. Its count of host requests runs over the machine's whole life.
    key_work: keys.Work = .{},
    /// Working memory of a reclamation: one entry per member above the mark, and one more.
    reclaim_hops: [types.limits.aggregate_elements + 1]u32 = undefined,
    /// And what it needs for cells and strings.
    reclaim_work: call_frames.ReclaimWork = .{},
    /// The machine's scheduler (RFC-0082).
    scheduler: call_frames.VmScheduler = .{},
    /// The machine's live records (RFC-0084), and the depth below which a guard's frame loop
    /// leaves the frames alone.
    live: call_frames.VmLive = .{},
    guard_floor: u32 = 0,
    /// RFC-0082, P3.5: per body node, the newest register before it that is available there
    /// (`no_link` for none), worked out at a run's first reclamation that roots suspended
    /// frames (`prepareLinks`).
    reclaim_links: [types.limits.template_nodes]u32 = undefined,
    links_ready: bool = false,
    /// RFC-0082, P3.9: the run's catalogue, by which a `Signal` carried out from the commit
    /// queue tells a sticky event from another.
    event_definitions: []const types.Definition = &.{},
    /// RFC-0087, P5.3 (E6): the JSON codec's stack, made at a run's first encode or decode and
    /// given back at its end.
    json_stack: ?*persist_json.Stack = null,

    /// Requires an idle journal and immutable borrowed input. Results borrow
    /// machine registers until the next run, and strings from program.strings.
    pub fn run(self: *Machine, program: Program, work_budget: u64) Result {
        if (self.journal.depth != 0 or self.source.depth != 0 or self.calls.depth != 0 or self.calls.count != 0) return failure(.{ .start = 0, .end = 0 }, .invalid_bytecode);
        // Before verification: a program that is refused leaves no output of an earlier run.
        self.control.effects.reset(self.control.trace == .full);
        const registers = switch (verify(program, &self.register_types)) {
            .ok => |count| count,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        self.registers = self.register_types[0..registers];
        return self.admitted(program, registers, work_budget);
    }
    /// TASK-0109, W4.3 (RFC-0088, A3 and A4): a run of the bytecode that this machine's own
    /// verifier admitted when a handle was prepared (`prepared.VmAdmission`, which only a
    /// successful `verify` of the handle's frozen bytecode makes), so `verify` is not repeated.
    /// The register types it worked out are borrowed from the handle, which is immutable; the
    /// literal strings are copied into `strings`, whose remainder is the pool's tail for this
    /// run. The rest is `run`: idle storage is required and every per-run state is reset.
    pub fn runAdmitted(self: *Machine, admission: *const prepared.VmAdmission, strings: []u8, work_budget: u64) Result {
        if (self.journal.depth != 0 or self.source.depth != 0 or self.calls.depth != 0 or self.calls.count != 0) return failure(.{ .start = 0, .end = 0 }, .invalid_bytecode);
        self.control.effects.reset(self.control.trace == .full);
        const program = admission.view(strings) orelse return failure(.{ .start = 0, .end = 0 }, .invalid_bytecode);
        self.registers = admission.registers();
        return self.admitted(program, self.registers.len, work_budget);
    }
    /// What `run` and `runAdmitted` do once the program is admitted, with `registers` typed in
    /// `self.registers`.
    fn admitted(self: *Machine, program: Program, registers: usize, work_budget: u64) Result {
        assert(registers == self.registers.len and registers <= self.values.len);
        self.control.call_count = 0;
        self.control.trace_count = 0;
        self.control.failure_count = 0;
        self.links_ready = false;
        // Lent anew for each run: the machine may have been moved since the last one.
        self.key_work.far = &self.key_levels;
        self.key_work.far_lent = true;
        defer self.key_work.release();
        defer if (self.json_stack) |stack| {
            scratch.release(stack);
            self.json_stack = null;
        };
        if (program.source_ops == 0 and self.source.cell_count != 0) self.source.reset(0);
        if (program.control_ops != 0 or program.source_ops != 0 or program.call_ops != 0) return self.executeControl(program, work_budget);
        // Verified bytecode is straight-line: every instruction is visited once
        // and canonical constructor ranges copy each member exactly once. Fully
        // funding this exact total permits skipping only per-step fuel checks.
        // Jumps, loops and runtime calls must change this admission model first.
        const fully_funded = work_budget >= program.code.len + program.members.len and !keys.dynamic(program.definitions) and program.string_comparisons == 0;
        if (fully_funded) return self.execute(program, registers, work_budget, true);
        return self.execute(program, registers, work_budget, false);
    }
    // Specialize fuel checks at the loop boundary. Calls that prove complete
    // straight-line funding keep budget-address aliasing off the scalar loop.
    fn execute(self: *Machine, program: Program, registers: usize, work_budget: u64, comptime fully_funded: bool) Result {
        assert(registers <= self.values.len and self.journal.depth == 0);
        var complete = false;
        defer if (!complete) self.journal.abortAll();
        var count: usize = 0;
        var remaining: u64 = work_budget;
        self.aggregate_count = 0;
        self.string_used = program.strings.len;
        self.string_stale = run_strings.Pool.fresh;
        for (program.code) |instruction| {
            assert(count <= registers);
            if (!fully_funded) {
                const cost: u32 = 1 + switch (instruction.op) {
                    .aggregate => |range| range.end - range.start,
                    // Exhaustiveness forces new control-flow/native opcodes to
                    // audit both this cost and the straight-line funding proof.
                    .integer, .boolean, .string, .negate, .binary, .begin, .commit, .abort, .load_cell, .store_cell, .require, .enqueue, .floating, .float_negate, .int_to_float, .float_to_int, .float_binary, .rational, .field, .array_length, .enumeration, .tuple_element, .option_present, .option_value, .option_or, .map_lookup, .array_get, .map_key, .map_value, .string_length, .compare, .logic_not, .logic_binary, .local_set, .upcast, .downcast, .instance_of, .method_value, .function_value, .character, .refine => @as(u32, 0),
                    // A text operation whose cost depends on its operand is a control operation.
                    .text => |t| if (t.op.walks()) unreachable else @as(u32, 0),
                    .if_begin, .attempt_begin, .otherwise, .merge, .demand, .fail, .exit, .err, .cell_init, .cell_read, .cell_write, .object_new, .object_get, .object_set, .call, .iterate, .recur, .self_value, .invoke, .iterate_value, .loop, .bind, .native_call, .string_concat, .array_concat, .array_set, .map_set, .map_remove, .to_string => unreachable,
                    .spawn, .sleep, .canceling, .cancel_exit => unreachable,
                    .task_await, .event_new, .event_signal, .event_await => unreachable,
                    .structured => unreachable,
                    .branch => unreachable,
                    .cell_live => unreachable,
                    .object_live => unreachable,
                    .arm_exit, .arm_exited, .arm_exit_value => unreachable,
                    .reaction => unreachable,
                    .task_cancel, .elapsed_time => unreachable,
                    .batch => unreachable,
                    .await_guard => unreachable,
                    .event_subscribe, .subscription_cancel, .event_notify => unreachable,
                    .ref_new, .ref_get, .ref_set => unreachable,
                    .grant => unreachable,
                    .weak_init, .weak_get, .weak_set => unreachable,
                    .json_encode, .json_decode => unreachable,
                };
                if (cost > remaining) return failure(instruction.span, .work_limit);
                remaining -= cost;
            }
            const value = self.step(instruction, program, self.values[0..count], &remaining, fully_funded) catch |err| {
                return failure(instruction.span, runtimeCode(err));
            };
            if (value) |result| {
                assert(count < self.values.len and instruction.value_type != null);
                const expected_type = self.registers[count];
                // A register of type `any` holds a value of any form unchanged (RFC-0080): a
                // scalar there is what `any(5)` makes, not a mistyped register.
                if (expected_type == types.Type.any) {} else if (@backingInt(expected_type) < 4) {
                    assert(@backingInt(std.meta.activeTag(result)) == @backingInt(expected_type));
                } else switch (result) {
                    .aggregate => |typed_value| assert(typed_value.value_type == expected_type),
                    .enumeration => |typed_value| assert(typed_value.value_type == expected_type),
                    .callable => |typed_value| assert(typed_value.value_type == expected_type),
                    .rational => assert(catalogue.isRational(expected_type, program.definitions)),
                    // A refinement (RFC-0083) holds the scalar of its base.
                    .integer, .floating => assert(catalogue.refinementOf(expected_type, program.definitions) != null),
                    else => unreachable, // The verified opcode cannot yield a scalar here.
                }
                assert(instruction.value_type == expected_type);
                self.values[count] = result;
                count += 1;
            }
        }
        assert(count == registers and self.journal.depth == 0);
        assert(self.aggregate_count == program.members.len);
        complete = true;
        return .{ .ok = self.values[0..count] };
    }
    fn executeControl(self: *Machine, program: Program, work_budget: u64) Result {
        var complete = false;
        defer if (!complete) {
            self.control.call_count = 0;
            self.control.trace_count = 0;
            self.control.failure_count = 0;
        };
        defer if (!complete) self.journal.abortAll();
        const has_source = needsSource(program);
        if (has_source) {
            self.source.reset(program.source_cells.len);
            self.source.begin() catch unreachable;
        }
        defer if (!complete and has_source) self.source.abortAll();
        // What is pending at a fatal error never happened; what was committed stays.
        defer if (!complete) self.control.effects.abortAll();
        // Sparse registers have legal placeholders even under forged activity.
        if (program.control_ops != 0 or program.source_ops != 0) for (self.values[0..program.code.len]) |*value| {
            value.* = .{ .integer = 0 };
        };
        self.control.reset(program.code.len);
        self.control.strings = program.strings.ptr;
        self.control.string_used = &self.string_used;
        self.resetScheduler();
        self.event_definitions = program.definitions;
        // RFC-0084: a program with a `cell_live` tracks, detaches and propagates.
        live_machine.start(&self.live, holdsLive(program), program.definitions, program.fields, program.tuple_elements);
        self.live.reacts = holdsReaction(program);
        self.guard_floor = 0;
        if (has_source) self.control.programCells(program.source_cells.len);
        self.aggregate_count = 0;
        self.string_used = program.strings.len;
        self.string_stale = run_strings.Pool.fresh;
        var catchers: [types.limits.control_depth]u32 = undefined;
        var depth: usize = 0;
        var remaining: u64 = work_budget;
        var pc: u32 = 0;
        while (pc < program.code.len) {
            const instruction = program.code[pc];
            const cost: u32 = 1 + if (instruction.op == .aggregate) instruction.op.aggregate.end - instruction.op.aggregate.start else if (instruction.op == .object_new) instruction.op.object_new.arguments.end - instruction.op.object_new.arguments.start else if (instruction.op == .ref_new) @as(u32, 1) else if (instruction.op == .bind) bind: {
                const b = instruction.op.bind;
                const original = self.values[b.callable].callable;
                break :bind original.captures.end - original.captures.start + b.arguments.end - b.arguments.start;
            } else @as(u32, 0);
            if (cost > remaining) return failure(instruction.span, .work_limit);
            remaining -= cost;
            var next = pc + 1;
            var result: types.Value = undefined;
            switch (instruction.op) {
                .call, .iterate, .invoke, .iterate_value, .loop => result = switch (self.executeCall(program, instruction.invocationWith(self.values[0..pc]).?, instruction.op == .invoke, pc, &remaining)) {
                    .ok => |value| value,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                    .language => {
                        assert(depth != 0);
                        depth -= 1;
                        const begin = catchers[depth];
                        self.journal.abort() catch unreachable;
                        if (has_source) self.source.abort() catch unreachable;
                        self.abortRegion();
                        self.values[begin] = .{ .boolean = false };
                        pc = controlBranch(program.code[begin]).alternative + 1;
                        continue;
                    },
                },
                .if_begin => |b| {
                    result = self.values[b.condition];
                    if (!result.boolean) next = b.alternative + 1;
                },
                .attempt_begin => {
                    self.journal.begin() catch |err| return failure(instruction.span, runtimeCode(err));
                    if (has_source) self.source.begin() catch |err| return failure(instruction.span, runtimeCode(err));
                    self.control.effects.begin();
                    catchers[depth] = pc;
                    depth += 1;
                    result = .{ .boolean = true };
                },
                .otherwise => |begin| {
                    if (program.code[begin].op == .attempt_begin) {
                        assert(depth != 0 and catchers[depth - 1] == begin);
                        self.journal.commit() catch |err| return failure(instruction.span, runtimeCode(err));
                        if (has_source) self.source.commit() catch unreachable;
                        // The guest's state is committed; a sink that fails now ends the run. What
                        // the region started takes its turn after this node (below).
                        _ = self.commitRegion() catch |err| return failure(instruction.span, runtimeCode(err));
                        depth -= 1;
                    }
                    next = controlBranch(program.code[begin]).end;
                    result = .{ .boolean = true };
                },
                .cell_read => |c| result = self.source.read(c) catch |err| return failure(instruction.span, runtimeCode(err)),
                .cell_init, .cell_write => |c| {
                    result = self.values[c.value];
                    // RFC-0084, L2: a program write detaches, then propagates.
                    const written = instruction.op == .cell_write and self.live.on;
                    if (written) live_machine.unlink(&self.live, &self.source, c.cell, &remaining) catch |err| return failure(instruction.span, liveRuntimeCode(err));
                    self.source.write(c.cell, result, instruction.op == .cell_init) catch |err| return failure(instruction.span, runtimeCode(err));
                    if (written) if (self.livePropagate(program, c.cell, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic };
                },
                .object_new => |c| result = self.newObject(instruction.value_type.?, program.call_arguments[c.arguments.start..c.arguments.end], self.values[0..pc]) catch |err| return failure(instruction.span, runtimeCode(err)),
                // RFC-0085, I1: a variable cell, an instance with one cell.
                .ref_new => |operand| result = self.newRef(instruction.value_type.?, self.values[operand]) catch |err| return failure(instruction.span, runtimeCode(err)),
                .ref_get => |operand| result = self.source.read(self.values[operand].object.id + catalogue.ref_value) catch |err| return failure(instruction.span, runtimeCode(err)),
                .ref_set => |r| {
                    const cell = self.values[r.ref].object.id + catalogue.ref_value;
                    result = self.values[r.value];
                    // RFC-0084, L2: a program write detaches, then propagates.
                    if (self.live.on) live_machine.unlink(&self.live, &self.source, cell, &remaining) catch |err| return failure(instruction.span, liveRuntimeCode(err));
                    self.source.write(cell, result, false) catch |err| return failure(instruction.span, runtimeCode(err));
                    if (self.live.on) if (self.livePropagate(program, cell, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic };
                },
                .object_get, .object_set => {
                    // RFC-0084, L2: a program write of a field detaches its record (P4.2).
                    if (instruction.op == .object_set and self.live.on) live_machine.unlink(&self.live, &self.source, self.values[instruction.op.object_set.object].object.id + 1 + instruction.op.object_set.index, &remaining) catch |err| return failure(instruction.span, liveRuntimeCode(err));
                    result = self.objectAccess(instruction, self.values[0..pc]) catch |err| return failure(instruction.span, runtimeCode(err));
                    if (instruction.op == .object_set and self.live.on) {
                        const c = instruction.op.object_set;
                        if (self.livePropagate(program, self.values[c.object].object.id + 1 + c.index, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic };
                    }
                },
                // RFC-0084: the establishing write of a module cell.
                .cell_live => |c| result = switch (self.liveEstablish(program, cellSpot(program, c), self.values[c.guard].callable, pc, instruction.span, pc, &remaining)) {
                    .ok => |value| value,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                },
                // RFC-0084, P4.2: the establishing write of a field.
                .object_live => |c| result = switch (self.liveEstablish(program, fieldSpot(self.values[c.object].object, c, instruction.value_type.?), self.values[c.guard].callable, pc, instruction.span, pc, &remaining)) {
                    .ok => |value| value,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                },
                .merge => |m| result = upcastValue(self.values[if (self.values[m.begin].boolean) m.left else m.right], instruction.value_type.?),
                .native_call => |c| {
                    // An effect outside every function leaves a step (`CallStep`). Its room is
                    // found first: an action must not be committed and then go unrecorded.
                    const effect = program.natives[c.native].effect != .none;
                    if (effect and self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return failure(instruction.span, .call_trace_limit);
                    result = (self.step(instruction, program, self.values[0..pc], &remaining, false) catch |err| return failure(instruction.span, runtimeCode(err))).?;
                    if (effect) {
                        self.control.calls[self.control.call_count] = .{ .function = 0, .pc = pc, .value = result, .kind = .root };
                        self.control.call_count += 1;
                        if (self.control.trace_sink != null) self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
                    }
                },
                .err => return failure(instruction.span, .runtime_error),
                .exit => unreachable, // Verification keeps exits inside function bodies.
                .arm_exit, .arm_exited, .arm_exit_value => unreachable,
                // RFC-0084, P4.4: a reaction at the root starts at once outside every region; a
                // body that fires runs on the empty stack.
                .reaction => |r| {
                    const slot = self.reactionNew(program, instruction.value_type.?, r, self.values[r.guard], self.values[r.body], pc, instruction.span, &remaining) catch |err| return failure(instruction.span, runtimeCode(err));
                    result = self.scheduler.tasks[slot].handle;
                    if (self.control.effects.depth > 0) {
                        self.holdStart(slot) catch |err| return failure(instruction.span, runtimeCode(err));
                    } else switch (self.reactionStart(program, slot, .node, instruction.span, pc, &remaining)) {
                        .fired => if (self.atRoot(program, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic },
                        .waits => {},
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                },
                // RFC-0084, P4.5: a batch of the root calls its body on the empty stack with the
                // count of open batches raised; its return is a delivery point (below).
                .batch => |operand| {
                    const body = self.values[operand].callable;
                    self.live.batches += 1;
                    result = switch (self.executeCall(program, .{ .call = .{ .function = body.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures } }, true, pc, &remaining)) {
                        .ok => |value| value,
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                        .language => unreachable, // A body cannot fail.
                    };
                    assert(self.live.batches != 0);
                    self.live.batches -= 1;
                },
                .spawn => |operand| {
                    // RFC-0082: outside every region the task runs now, on the empty stack, until
                    // it first waits or settles; inside one its start waits for the commit.
                    const slot = self.spawnTask(program, instruction.value_type.?, self.values[operand], pc, &remaining) catch |err| return failure(instruction.span, runtimeCode(err));
                    result = self.scheduler.tasks[slot].handle;
                    if (self.control.effects.depth > 0) {
                        self.holdStart(slot) catch |err| return failure(instruction.span, runtimeCode(err));
                    } else if (self.runTask(program, slot, false, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic };
                },
                // Root code has no site and so no check (admission rule 1).
                .sleep, .canceling, .cancel_exit, .task_await, .event_await, .structured => unreachable,
                .branch => unreachable,
                .task_cancel => unreachable,
                .await_guard => unreachable,
                // P3.7: the clock, which stands still while the root runs.
                .elapsed_time => result = .{ .floating = self.elapsedTime() },
                // RFC-0086, P2.3: a handle of the run's grants, or `option{}`.
                .grant => |g| result = if (g.kind == .session) sessionValue(instruction.value_type.?) else self.openGrant(g, self.values[g.name].string, instruction.value_type.?, program, &remaining) catch |err| return failure(instruction.span, runtimeCode(err)),
                // RFC-0087, P5.4 (W4): a keyed cell starts as the empty map of its type.
                .weak_init => |c| {
                    if (program.source_cells[c].keyed == .persistent) {
                        // RFC-0087, P5.5 (S4): a persistent cell starts as its loaded entries. Like
                        // a JSON instruction at the root it leaves a step, so that a replay is told
                        // at once, while the pool still holds the strings the decodes built.
                        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return failure(instruction.span, .call_trace_limit);
                        result = switch (self.loads(program, c, instruction.value_type.?, &remaining)) {
                            .ok => |made| made,
                            .failed => |code| return failure(instruction.span, code),
                        };
                        self.control.calls[self.control.call_count] = .{ .function = 0, .pc = pc, .value = result, .kind = .root };
                        self.control.call_count += 1;
                        if (self.control.trace_sink != null) self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
                    } else result = .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = @intCast(self.aggregate_count), .end = @intCast(self.aggregate_count) } } };
                    self.source.write(c, result, true) catch |err| return failure(instruction.span, runtimeCode(err));
                },
                .weak_get => |g| {
                    const map = self.source.read(g.cell) catch |err| return failure(instruction.span, runtimeCode(err));
                    result = self.keyedLookup(map, self.values[g.key], instruction.value_type.?, &remaining) catch |err| return failure(instruction.span, runtimeCode(err));
                },
                // W6: a program write, as `cell_write` is.
                .weak_set => |c| {
                    const map = self.source.read(c.cell) catch |err| return failure(instruction.span, runtimeCode(err));
                    const written = self.keyedUpdate(map, self.values[c.key], self.values[c.value], &remaining) catch |err| return failure(instruction.span, runtimeCode(err));
                    result = self.values[c.value];
                    if (self.live.on) live_machine.unlink(&self.live, &self.source, c.cell, &remaining) catch |err| return failure(instruction.span, liveRuntimeCode(err));
                    self.source.write(c.cell, written, false) catch |err| return failure(instruction.span, runtimeCode(err));
                    // RFC-0087, P5.5 (S5): a persistent cell's write is also an action on the store channel.
                    if (self.storeAction(program, c, self.values[c.key], self.values[c.value], &remaining)) |code| return failure(instruction.span, code);
                    if (self.live.on) if (self.livePropagate(program, c.cell, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic };
                },
                // RFC-0087, P5.3: `ToJson` and `FromJson`, each leaving a step at the root, as an
                // effect native does, of which a replay is told at once.
                .json_encode, .json_decode => |operand| {
                    if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return failure(instruction.span, .call_trace_limit);
                    result = switch (self.json(program, instruction.op == .json_encode, self.registers[operand], self.values[operand], instruction.value_type.?, &remaining)) {
                        .ok => |made| made,
                        .failed => |code| return failure(instruction.span, code),
                    };
                    self.control.calls[self.control.call_count] = .{ .function = 0, .pc = pc, .value = result, .kind = .root };
                    self.control.call_count += 1;
                    if (self.control.trace_sink != null) self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
                },
                // P3.2: events are built at the root, and signalled: at once outside every
                // region, held by the innermost one inside.
                .event_new => result = self.newEvent(program, instruction.value_type.?) catch |err| return failure(instruction.span, runtimeCode(err)),
                .event_signal => |signal| {
                    result = .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = 0, .end = 0 } } };
                    if (self.control.effects.depth > 0) {
                        self.holdSignal(self.values[signal.event], self.values[signal.value]) catch |err| return failure(instruction.span, runtimeCode(err));
                    } else self.signalEvent(self.values[signal.event].object, self.values[signal.value], &remaining) catch |err| return failure(instruction.span, runtimeCode(err));
                },
                // P3.9: subscriptions are made and ended at the root too, and a `Signal` there
                // calls each callback as a call of the root (C109, C110).
                .event_subscribe => |c| result = self.subscribe(self.values[c.event].object, self.values[c.callback], instruction.value_type.?) catch |err| return failure(instruction.span, runtimeCode(err)),
                .subscription_cancel => |operand| {
                    self.unsubscribe(self.values[operand].object) catch |err| return failure(instruction.span, runtimeCode(err));
                    result = .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = 0, .end = 0 } } };
                },
                .event_notify => |n| {
                    const event = self.values[n.callable].object;
                    const limit = (self.source.read(event.id + catalogue.subscription_count) catch unreachable).integer;
                    var from = self.source.read(event.id + catalogue.subscription_first) catch unreachable;
                    while (self.nextSubscription(from, limit, &remaining) catch |err| return failure(instruction.span, runtimeCode(err))) |subscription| {
                        const callback = (self.source.read(subscription.id + catalogue.cancelable_callback) catch unreachable).callable;
                        switch (self.executeCall(program, .{ .call = .{ .function = callback.function, .arguments = n.arguments, .captures = callback.captures } }, true, pc, &remaining)) {
                            .ok => {},
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                            .language => unreachable, // A callback cannot fail (C108).
                        }
                        // It was made before the call, so no reclamation in the call moved it.
                        from = self.source.read(subscription.id + catalogue.cancelable_after) catch unreachable;
                    }
                    result = .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = 0, .end = 0 } } };
                },
                .demand, .fail => |operand| {
                    if (instruction.op == .fail or !self.values[operand].boolean) {
                        assert(depth != 0);
                        depth -= 1;
                        const begin = catchers[depth];
                        self.journal.abort() catch unreachable;
                        if (has_source) self.source.abort() catch unreachable;
                        self.abortRegion();
                        self.values[begin] = .{ .boolean = false };
                        self.control.record(.{ .instruction = pc, .span = instruction.span, .code = if (instruction.op == .fail) .language_failure else .requirement_failed, .reason = if (instruction.op == .fail) self.values[operand].string else null });
                        pc = controlBranch(program.code[begin]).alternative + 1;
                        continue;
                    }
                    result = .{ .boolean = true };
                },
                .bind => |b| {
                    const original = self.values[b.callable].callable;
                    const old = original.captures.end - original.captures.start;
                    const count = old + b.arguments.end - b.arguments.start;
                    if (count > self.aggregate_values.len - self.aggregate_count) return failure(instruction.span, .aggregate_limit);
                    const span: types.Span = .{ .start = @intCast(self.aggregate_count), .end = @intCast(self.aggregate_count + count) };
                    assert(original.captures.end <= self.aggregate_count and count <= types.limits.parameters);
                    @memcpy(self.aggregate_values[span.start .. span.start + old], self.aggregate_values[original.captures.start..original.captures.end]);
                    for (program.call_arguments[b.arguments.start..b.arguments.end], self.aggregate_values[span.start + old .. span.end]) |operand, *out| out.* = self.values[operand];
                    self.aggregate_count = span.end;
                    result = .{ .callable = .{ .value_type = instruction.value_type.?, .function = original.function, .captures = span } };
                },
                .aggregate => |range| {
                    if (range.end - range.start > self.aggregate_values.len - self.aggregate_count) return failure(instruction.span, .aggregate_limit);
                    const physical: types.Span = .{ .start = @intCast(self.aggregate_count), .end = @intCast(self.aggregate_count + range.end - range.start) };
                    for (program.members[range.start..range.end], self.aggregate_values[physical.start..physical.end]) |operand, *destination| destination.* = self.values[operand];
                    if (keyedAggregate(program, instruction.value_type.?)) keys.unique(&self.key_work, &self.aggregate_values, self.aggregate_values[physical.start..physical.end], &remaining) catch |err| return failure(instruction.span, runtimeCode(err));
                    self.aggregate_count = physical.end;
                    result = .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = physical } };
                },
                else => result = (self.step(instruction, program, self.values[0..pc], &remaining, false) catch |err| return failure(instruction.span, runtimeCode(err))).?,
            }
            self.values[pc] = result;
            self.control.activity[pc] = true;
            // What the root committed starts now, each in turn until it waits or settles, and its
            // committed signals are carried out between the starts, in order.
            while (self.nextStart(pc, &remaining) catch |err| return failure(instruction.span, runtimeCode(err))) |slot| {
                // RFC-0084, P4.4: a reaction's start observes its guard, and may fire it.
                if (reactive(&self.scheduler.tasks[slot])) {
                    switch (self.reactionStart(program, slot, .start, instruction.span, pc, &remaining)) {
                        .fired => if (self.atRoot(program, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic },
                        .waits => {},
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                    continue;
                }
                if (self.runTask(program, slot, false, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic };
            }
            // RFC-0084, P4.4: a write, an establishing write or a commit of the root delivers
            // what is pending, after the drain it began.
            if (self.live.on and (instruction.op == .cell_write or instruction.op == .weak_set or instruction.op == .object_set or instruction.op == .ref_set or instruction.op == .cell_live or instruction.op == .object_live or instruction.op == .batch or (instruction.op == .otherwise and program.code[instruction.op.otherwise].op == .attempt_begin))) switch (self.deliveryPoint(program, instruction.span, pc, &remaining)) {
                .fired => if (self.atRoot(program, instruction.span, pc, &remaining)) |diagnostic| return .{ .failed = diagnostic },
                .done => {},
                .failed => |diagnostic| return .{ .failed = diagnostic },
            };
            pc = next;
        }
        assert(depth == 0 and self.journal.depth == 0 and self.aggregate_count <= self.aggregate_values.len);
        assert(self.control.effects.depth == 0);
        // P3.5: what the root holds now never moves.
        self.control.rootEnded(self.usage());
        // The root is done (S1): the tasks run until the run is quiescent.
        if (self.runScheduler(program, &remaining)) |diagnostic| return .{ .failed = diagnostic };
        if (has_source) self.source.commit() catch unreachable;
        complete = true;
        if (self.control.trace != .full) self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
        return .{ .ok = self.values[0..program.code.len] };
    }

    fn pushCall(self: *Machine, program: Program, call: types.ResolvedCall, caller_base: ?u32) ?types.Diagnostic.Code {
        const size = program.functions[call.function].body.end - program.functions[call.function].body.start;
        if (self.calls.depth == self.calls.frames.len) return .call_depth_limit;
        if (size > self.calls.values.len - self.calls.count) return .call_register_limit;
        self.calls.frames[self.calls.depth] = .{ .function = call.function, .base = self.calls.count, .pc = 0, .arguments = call.arguments, .caller_base = caller_base, .captures = call.captures, .mark = @intCast(self.aggregate_count), .string_mark = @intCast(self.string_used), .cell_mark = if (self.source.depth != 0) @intCast(self.source.cell_count) else 0, .switches = self.scheduler.switches };
        self.calls.count += size;
        self.calls.depth += 1;
        return null;
    }
    fn startInvocation(self: *Machine, program: Program, invocation: types.Invocation, caller_base: ?u32, remaining: *u64) call_frames.Start {
        switch (invocation) {
            .call => |call| {
                if (self.pushCall(program, call, caller_base)) |code| return .{ .failed = code };
            },
            .loop => |transition| {
                const values = if (caller_base) |base| self.calls.values[base..self.calls.count] else self.values[0..program.code.len];
                const seed = values[transition.initial];
                if (remaining.* == 0) return .{ .failed = .work_limit };
                remaining.* -= 1;
                if (self.pushCall(program, .{ .function = transition.function, .arguments = .{ .start = 0, .end = 0 }, .captures = transition.captures }, caller_base)) |code| return .{ .failed = code };
                const frame = &self.calls.frames[self.calls.depth - 1];
                frame.state_loop = true;
                frame.remaining_visits = 1;
                frame.iteration_seed = seed;
            },
            .iterate => |iteration| {
                const values = if (caller_base) |base| self.calls.values[base..self.calls.count] else self.values[0..program.code.len];
                const count = values[iteration.count].integer;
                const seed = values[iteration.initial];
                if (count < 0) return .{ .failed = .negative_iteration_count };
                if (count == 0) return .{ .immediate = seed };
                if (remaining.* == 0) return .{ .failed = .work_limit };
                remaining.* -= 1;
                if (self.pushCall(program, .{ .function = iteration.function, .arguments = .{ .start = 0, .end = 0 }, .captures = iteration.captures }, caller_base)) |code| return .{ .failed = code };
                const frame = &self.calls.frames[self.calls.depth - 1];
                frame.remaining_visits = @intCast(count);
                frame.iteration_seed = seed;
            },
        }
        return .pushed;
    }
    // Unwind only admitted decides frames. A failed caller continuation either
    // selects its own catcher or carries the same defining cause onward.
    fn unwindCall(self: *Machine, program: Program, root_target: u32, root_pc: u32, cause: types.CallFailure) ?call_frames.Result {
        while (self.calls.depth != 0) {
            const leaving = self.calls.frames[self.calls.depth - 1];
            assert(leaving.catch_depth == 0 and program.functions[leaving.function].decides);
            self.calls.count = leaving.base;
            self.calls.depth -= 1;
            if (self.calls.depth == 0) {
                if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = program.code[root_pc].span, .code = .call_trace_limit } };
                self.control.calls[self.control.call_count] = .{ .function = root_target, .pc = root_pc, .value = cause.value, .kind = .root_failure };
                self.control.call_count += 1;
                return .{ .language = cause };
            }
            const parent = &self.calls.frames[self.calls.depth - 1];
            const f = program.functions[parent.function];
            const node = program.function_nodes[f.body.start + parent.pc].node;
            assert(node.isInvocation());
            if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } };
            self.control.calls[self.control.call_count] = .{ .function = parent.function, .pc = parent.pc, .value = cause.value, .kind = .propagate };
            self.control.call_count += 1;
            if (parent.catch_depth != 0) {
                if (f.has_source) self.source.abort() catch unreachable;
                self.abortRegion();
                parent.catch_depth -= 1;
                const begin = parent.catchers[parent.catch_depth];
                self.calls.values[parent.base + begin] = .{ .boolean = false };
                parent.pc = program.function_nodes[f.body.start + begin].node.kind.attempt_begin.alternative + 1;
                return null;
            }
        }
        unreachable;
    }
    // The VM holds parent call PCs and indirect argument references. Returning
    // fills that PC before advancing it. No guest frame borrows native locals.
    fn executeCall(self: *Machine, program: Program, invocation: types.Invocation, force_trace: bool, root_pc: u32, remaining: *u64) call_frames.Result {
        assert(self.calls.depth == 0 and self.calls.count == 0);
        defer {
            self.calls.depth = 0;
            self.calls.count = 0;
        }
        const span = program.code[root_pc].span;
        const f = program.functions[invocation.target()];
        const tracing = force_trace or invocation != .call or f.has_control or f.has_source or f.has_local;
        if (invocation == .call) {
            if (self.pushCall(program, invocation.call, null)) |code| return .{ .failed = .{ .span = span, .code = code } };
        } else switch (self.startInvocation(program, invocation, null, remaining)) {
            .pushed => {},
            .immediate => |value| return .{ .ok = value },
            .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
        }
        // A replay is told where the string pool stands when a traced call begins: once with
        // the steps still held, and once more for a replay that only then reaches the call.
        if (tracing and self.control.trace_sink != null) for (0..2) |_| self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
        return self.runFrames(program, invocation.target(), tracing, span, root_pc, remaining);
    }
    /// The frame loop, until the stack is empty: a call from the root returned, or a task that
    /// ran on the empty stack waits or settled (RFC-0082). A task handed off to runs on top of
    /// the frame that spawned it and leaves, by waiting or settling, as a callee returns.
    fn runFrames(self: *Machine, program: Program, root_target: u32, tracing: bool, span: types.Span, root_pc: u32, remaining: *u64) call_frames.Result {
        const s = &self.scheduler;
        // The loop of a guard (RFC-0084) stops where its frame returns, above the frames below it.
        while (self.calls.depth > self.guard_floor) {
            // RFC-0084, P4.4: a drain's next turn, which the turn before left for here.
            if (self.live.drain_due) {
                self.live.drain_due = false;
                switch (self.drainTurn(program, self.calls.frames[self.calls.depth - 1].drain_span, root_pc, remaining)) {
                    .pushed, .done => continue,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                }
            }
            const frame = &self.calls.frames[self.calls.depth - 1];
            const definition = program.functions[frame.function];
            const length = definition.body.end - definition.body.start;
            if (frame.pc == length) {
                assert(frame.catch_depth == 0);
                // P3.4: a frame that ended by `cancel_exit` while it owned tasks has waited for
                // them; it ends cancelled now.
                if (frame.canceled_end) switch (self.canceledEnd(program, siteSpan(program, frame.function, definition.root), root_pc, remaining)) {
                    .going => continue,
                    .empty => return .{ .ok = .{ .boolean = false } },
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                };
                // P3.4: at the end of a frame, or of a visit of a loop's function (a call of it),
                // the tasks it keeps are asked to cancel first, and its task waits here until they
                // are settled; it comes back here when they are, and the end goes on.
                if (frame.owned_first != call_frames.no_task) switch (self.ownedEnd(program, root_pc, remaining)) {
                    .going => continue,
                    .empty => return .{ .ok = .{ .boolean = false } },
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                };
                var result = self.calls.values[frame.base + definition.root];
                if (frame.state_loop) {
                    assert(result == .aggregate);
                    const option = result.aggregate.elements;
                    assert(option.end - option.start <= 1 and option.end <= self.aggregate_count);
                    if (option.start == option.end) {
                        result = frame.iteration_seed;
                    } else {
                        const dispatch_span = if (self.calls.depth == 1) span else dispatch: {
                            const parent = self.calls.frames[self.calls.depth - 2];
                            break :dispatch program.function_nodes[program.functions[parent.function].body.start + parent.pc].node.span;
                        };
                        if (remaining.* == 0) return .{ .failed = .{ .span = dispatch_span, .code = .work_limit } };
                        remaining.* -= 1;
                        frame.iteration_seed = self.aggregate_values[option.start];
                        // The visit is over: of what it built, only the next state is still in use.
                        if (tracing and !self.live.tracking and self.control.reclaimNow(self.usage(), self.reclaimMarks(frame), self.calls.depth, false, self.acrossUnits(frame))) self.reclaim(program, frame, &frame.iteration_seed);
                        frame.pc = 0;
                        continue;
                    }
                } else if (frame.remaining_visits > 1) {
                    const dispatch_span = if (self.calls.depth == 1) span else dispatch: {
                        const parent = self.calls.frames[self.calls.depth - 2];
                        break :dispatch program.function_nodes[program.functions[parent.function].body.start + parent.pc].node.span;
                    };
                    if (remaining.* == 0) return .{ .failed = .{ .span = dispatch_span, .code = .work_limit } };
                    remaining.* -= 1;
                    frame.remaining_visits -= 1;
                    frame.iteration_seed = result;
                    if (tracing and !self.live.tracking and self.control.reclaimNow(self.usage(), self.reclaimMarks(frame), self.calls.depth, false, self.acrossUnits(frame))) self.reclaim(program, frame, &frame.iteration_seed);
                    frame.pc = 0;
                    continue;
                }
                // The frame is over: of what it built, only its result is still in use. The
                // caller's step for the call records the result where it lies afterwards. After
                // another task ran since its push, with the suspended frames as roots too
                // (RFC-0082, the P3.5 rule). Never while a guard runs (RFC-0084): its reads and
                // the dirty set name cells. A frame that saw a switch waits for the last
                // reclamation to be paid for (RFC-0085, I6-D3): other tasks built above its marks.
                if (tracing and !self.live.tracking and self.control.reclaimReturn(self.usage(), self.reclaimMarks(frame), self.calls.depth, true, frame.switches, self.scheduler.switches, (if (self.source.depth != 0) self.source.undo_count + live_machine.measure(&self.live, &self.source) else 0) + self.acrossUnits(frame))) self.reclaim(program, frame, &result);
                const ended_task = frame.task;
                const ended_handoff = frame.handoff;
                const ended_function = frame.function;
                self.calls.count = frame.base;
                self.calls.depth -= 1;
                if (ended_task != call_frames.no_task) {
                    // A task's entry frame: the task completed.
                    const blame = program.function_nodes[definition.body.start + definition.root].node.span;
                    // Or a reaction's body returned (RFC-0084, P4.4).
                    if (reactive(&s.tasks[ended_task])) switch (self.reactionFired(program, ended_task, ended_function, result, ended_handoff, blame, root_pc, remaining)) {
                        .going => continue,
                        .empty => return .{ .ok = result },
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    };
                    var leave: VmLeave = .{ .handoff = ended_handoff, .handle = .{ .boolean = false }, .owner = call_frames.no_task };
                    if (s.tasks[ended_task].kind == .arm and s.tasks[ended_task].owner != call_frames.no_task) {
                        // An arm (P3.3): its expression learns it, and goes on starting arms if
                        // it was doing so below.
                        leave.owner = s.tasks[ended_task].owner;
                        self.armSettled(program, ended_task, ended_function, result, false, remaining) catch |err| return .{ .failed = .{ .span = blame, .code = runtimeCode(err) } };
                    } else if (s.tasks[ended_task].keeper != call_frames.no_task) {
                        // P3.4: a branch, or a `Rush`'s loser, leaves the frame that keeps it; a
                        // branch's creator gets the unit value if it handed off to it.
                        if (s.tasks[ended_task].kind == .branch) leave.handle = s.tasks[ended_task].handle;
                        self.ownedSettled(program, ended_task, ended_function, result, false) catch |err| return .{ .failed = .{ .span = blame, .code = runtimeCode(err) } };
                    } else {
                        leave.handle = s.tasks[ended_task].handle;
                        self.settleTask(program, ended_task, ended_function, result) catch |err| return .{ .failed = .{ .span = blame, .code = runtimeCode(err) } };
                    }
                    if (self.calls.depth == 0) return .{ .ok = result };
                    switch (self.taskLeft(program, leave, blame, root_pc, remaining)) {
                        .going => continue,
                        .empty => return .{ .ok = result },
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                }
                if (self.calls.depth == self.guard_floor) return .{ .ok = result };
                const parent = &self.calls.frames[self.calls.depth - 1];
                // P3.9: a callback of a subscribable event's `Signal` returned: the next
                // subscription's is called, and the node yields only after the last (C109, C115).
                const returned_to = program.function_nodes[program.functions[parent.function].body.start + parent.pc];
                if (returned_to.input == .operation and returned_to.node.kind == .event_notify) {
                    const from = self.source.read(parent.notify_cursor.id + catalogue.cancelable_after) catch unreachable;
                    switch (self.notifyFrom(program, parent, returned_to.node.kind.event_notify, from, remaining)) {
                        .pushed => continue,
                        .done => result = .{ .aggregate = .{ .value_type = returned_to.node.value_type, .elements = .{ .start = 0, .end = 0 } } },
                        .failed => |code| return .{ .failed = .{ .span = returned_to.node.span, .code = code } },
                    }
                }
                if (tracing) {
                    if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = program.function_nodes[program.functions[parent.function].body.start + parent.pc].node.span, .code = .call_trace_limit } };
                    self.control.calls[self.control.call_count] = .{ .function = parent.function, .pc = parent.pc, .value = result };
                    self.control.call_count += 1;
                }
                self.calls.values[parent.base + parent.pc] = result;
                // RFC-0084, P4.5: a batch's body returned to its node: one batch fewer is open,
                // and the return is a delivery point.
                const caller = program.function_nodes[program.functions[parent.function].body.start + parent.pc];
                parent.pc += 1;
                if (caller.input == .operation and caller.node.kind == .batch) {
                    assert(self.live.batches != 0);
                    self.live.batches -= 1;
                    if (self.live.on) switch (self.deliveryPoint(program, caller.node.span, root_pc, remaining)) {
                        .fired, .done => {},
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    };
                }
                continue;
            }
            const entry = program.function_nodes[definition.body.start + frame.pc];
            const node = entry.node;
            const cost: u32 = 1 + if (entry.input == .operation and node.kind == .aggregate) node.kind.aggregate.end - node.kind.aggregate.start else if (entry.input == .operation and node.kind == .object_new) node.kind.object_new.arguments.end - node.kind.object_new.arguments.start else if (entry.input == .operation and node.kind == .ref_new) @as(u32, 1) else if (entry.input == .operation and node.kind == .bind) bind: {
                const b = node.kind.bind;
                const original = self.calls.values[frame.base + b.callable].callable;
                break :bind original.captures.end - original.captures.start + b.arguments.end - b.arguments.start;
            } else @as(u32, 0);
            if (cost > remaining.*) return .{ .failed = .{ .span = node.span, .code = .work_limit } };
            if (tracing and self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } };
            remaining.* -= cost;
            const pc = frame.pc;
            var next = pc + 1;
            var value: types.Value = undefined;
            // Set when this node commits a region to depth 0 and begins a drain (RFC-0082).
            var drains = false;
            // Set when it is a delivery point (RFC-0084, P4.4).
            var point = false;
            switch (entry.input) {
                .parameter => |parameter| {
                    const count = frame.captures.end - frame.captures.start;
                    if (parameter < count) {
                        assert(frame.captures.end <= self.aggregate_count);
                        value = self.aggregate_values[frame.captures.start + parameter];
                    } else if (frame.remaining_visits != 0) {
                        assert(parameter == count);
                        value = frame.iteration_seed;
                    } else {
                        const args = if (frame.caller_base == null) program.call_arguments else program.function_arguments;
                        const index = args[frame.arguments.start + parameter - count];
                        value = if (frame.caller_base) |base| self.calls.values[base + index] else self.values[index];
                    }
                },
                .global => |capture| value = self.values[program.globals[capture].node],
                .operation => switch (node.kind) {
                    .if_begin => |b| {
                        value = self.calls.values[frame.base + b.condition];
                        if (!value.boolean) next = b.alternative + 1;
                    },
                    .attempt_begin => {
                        if (definition.has_source) self.source.begin() catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        self.control.effects.begin();
                        frame.catchers[frame.catch_depth] = pc;
                        frame.catch_depth += 1;
                        value = .{ .boolean = true };
                    },
                    .otherwise => |begin| {
                        value = .{ .boolean = true };
                        const marker = program.function_nodes[definition.body.start + begin].node;
                        if (marker.kind == .attempt_begin) {
                            assert(frame.catch_depth != 0 and frame.catchers[frame.catch_depth - 1] == begin);
                            if (definition.has_source) self.source.commit() catch unreachable;
                            drains = self.commitRegion() catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                            frame.catch_depth -= 1;
                            point = true;
                        }
                        next = (if (marker.kind == .if_begin) marker.kind.if_begin else marker.kind.attempt_begin).end;
                    },
                    .demand, .fail => |operand| {
                        const reason = self.calls.values[frame.base + operand];
                        if (node.kind == .fail or !reason.boolean) {
                            assert(tracing);
                            self.control.calls[self.control.call_count] = .{ .function = frame.function, .pc = pc, .value = reason, .kind = .failure };
                            self.control.call_count += 1;
                            self.control.record(.{ .instruction = root_pc, .function = frame.function, .pc = pc, .span = node.span, .code = if (node.kind == .fail) .language_failure else .requirement_failed, .reason = if (node.kind == .fail) reason.string else null });
                            if (frame.catch_depth == 0) {
                                const cause: types.CallFailure = .{ .function = frame.function, .pc = pc, .value = reason };
                                if (self.unwindCall(program, root_target, root_pc, cause)) |outcome| return outcome;
                                continue;
                            }
                            if (definition.has_source) self.source.abort() catch unreachable;
                            self.abortRegion();
                            frame.catch_depth -= 1;
                            const begin = frame.catchers[frame.catch_depth];
                            self.calls.values[frame.base + begin] = .{ .boolean = false };
                            frame.pc = program.function_nodes[definition.body.start + begin].node.kind.attempt_begin.alternative + 1;
                            continue;
                        }
                        value = .{ .boolean = true };
                    },
                    .exit => |operand| {
                        // Not a failure: the frame's open regions are committed, innermost first,
                        // and the frame then ends as if its body had produced the operand.
                        assert(tracing);
                        const committed = frame.catch_depth != 0;
                        while (frame.catch_depth != 0) {
                            if (definition.has_source) self.source.commit() catch unreachable;
                            if (self.commitRegion() catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } }) drains = true;
                            frame.catch_depth -= 1;
                        }
                        const result = self.calls.values[frame.base + operand];
                        self.control.calls[self.control.call_count] = .{ .function = frame.function, .pc = pc, .value = result, .kind = .exit };
                        self.control.call_count += 1;
                        self.calls.values[frame.base + definition.root] = result;
                        frame.pc = length;
                        // What it committed starts first, each in turn, before the frame ends.
                        if (drains) self.calls.frames[self.calls.depth - 1].drain_span = node.span;
                        if (drains) self.drainFromTop(program, root_pc, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        // RFC-0084, P4.4: a commit to depth 0 delivers, after its drain.
                        if (committed and !drains and self.live.on) switch (self.deliveryPoint(program, node.span, root_pc, remaining)) {
                            .fired, .done => {},
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        };
                        continue;
                    },
                    .spawn => |operand| {
                        const slot = self.spawnTask(program, node.value_type, self.calls.values[frame.base + operand], root_pc, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        value = s.tasks[slot].handle;
                        if (self.control.effects.depth > 0) {
                            // Held by its region; the handle is the node's value now.
                            self.holdStart(slot) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        } else {
                            // Hand-off (S2): the task runs on top; this frame stays at the node
                            // and gets the handle when the task first leaves the stack.
                            self.startTask(program, slot, true) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                            continue;
                        }
                    },
                    .sleep => |operand| {
                        if (self.canceledAtSite(frame, pc)) continue;
                        const seconds = self.calls.values[frame.base + operand].floating;
                        if (types.isNan(seconds)) return .{ .failed = .{ .span = node.span, .code = .invalid_sleep_duration } };
                        if (sleepUntil(seconds, s.now, s.rate)) |wake| switch (self.waitAt(program, .{ .sleep = wake }, node.span, root_pc, remaining)) {
                            .going => continue,
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        };
                        // A negative duration completes now (RFC-0082, "Time").
                        value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } };
                    },
                    // P3.2: a handle whose task completed gives its result now; otherwise the
                    // task joins the awaited one's awaiters. An event is always waited on.
                    .task_await, .event_await => |operand| waits: {
                        if (self.canceledAtSite(frame, pc)) continue;
                        const instance = self.calls.values[frame.base + operand].object;
                        var wait: VmWait = .{ .event = instance };
                        // P3.9: a sticky event that was signalled gives its value now (C105).
                        if (self.stickyHeld(program, instance)) |held| {
                            value = held;
                            break :waits;
                        }
                        // P3.7: an `awaitable(T)` may hold an event, which is waited on as such.
                        if (node.kind == .task_await and !catalogue.isEvent(instance.value_type, program.definitions)) {
                            const state = (self.source.read(instance.id + catalogue.task_state) catch unreachable).integer;
                            if (state == catalogue.task_completed) {
                                const held = (self.source.read(instance.id + catalogue.task_result) catch unreachable).aggregate.elements;
                                assert(held.end - held.start == 1);
                                value = self.aggregate_values[held.start];
                                break :waits;
                            }
                            if (state == catalogue.task_canceled) {
                                // P3.7 (Q3): the awaiter's own task is asked to cancel, and the
                                // site yields cancelled now.
                                self.awaitCanceled(frame, pc, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                                continue;
                            }
                            // A handle that has not settled names a live task.
                            assert(state == catalogue.task_active);
                            const sequence: u64 = @intCast((self.source.read(instance.id + catalogue.task_sequence) catch unreachable).integer);
                            wait = .{ .task = .{ .handle = instance, .slot = self.slotOf(sequence).? } };
                        }
                        switch (self.waitAt(program, wait, node.span, root_pc, remaining)) {
                            .going => continue,
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    },
                    // P3.3: a structured expression. Its record is the running task's, and its
                    // first arm runs at once on top (S2); each arm that leaves the stack hands
                    // the start phase on (`taskLeft`).
                    .structured => |structured| {
                        if (self.canceledAtSite(frame, pc)) continue;
                        const owner = self.calls.frames[self.entryDepth()].task;
                        // No task on the stack is asked to cancel in P3.3 (`makeRequests`).
                        assert(!s.tasks[owner].cancel);
                        s.tasks[owner].record = .{ .kind = structured.kind, .pc = pc, .arms = structured.arms.end - structured.arms.start, .starting = true };
                        self.startArm(program, owner, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        continue;
                    },
                    // P3.4: a task this frame keeps, handed off to at once (S2); the frame stays at
                    // the node and gets the unit value when the task first leaves the stack.
                    .branch => |operand| {
                        if (self.canceledAtSite(frame, pc)) continue;
                        self.branchTask(program, self.calls.values[frame.base + operand], node.value_type, root_pc, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        continue;
                    },
                    // P3.7: a request to the task of a handle, and the clock.
                    .task_cancel => |operand| {
                        if (self.canceledAtSite(frame, pc)) continue;
                        self.cancelTask(self.calls.values[frame.base + operand].object, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } };
                    },
                    .elapsed_time => value = .{ .floating = self.elapsedTime() },
                    // RFC-0086, P2.3: a handle of the run's grants, or `option{}`.
                    .grant => |g| value = if (g.kind == .session) sessionValue(node.value_type) else self.openGrant(g, self.calls.values[frame.base + g.name].string, node.value_type, program, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } },
                    // RFC-0087, P5.3: `ToJson` and `FromJson`.
                    .json_encode, .json_decode => |operand| value = switch (self.json(program, node.kind == .json_encode, program.function_nodes[definition.body.start + operand].node.value_type, self.calls.values[frame.base + operand], node.value_type, remaining)) {
                        .ok => |made| made,
                        .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                    },
                    // RFC-0084, P4.6: `Await(G)`. The guard is evaluated with tracking; when it
                    // holds the site yields its value, otherwise the task waits on it here.
                    .await_guard => |operand| {
                        if (self.canceledAtSite(frame, pc)) continue;
                        switch (self.awaitObserve(program, self.calls.values[frame.base + operand].callable, node.span, root_pc, remaining)) {
                            .holds => |held| {
                                value = held;
                                // Its guard left steps: the site's own needs room again.
                                if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } };
                            },
                            .waits => switch (self.waitAt(program, .guard, node.span, root_pc, remaining)) {
                                .going => continue,
                                .empty => return .{ .ok = .{ .boolean = false } },
                                .failed => |diagnostic| return .{ .failed = diagnostic },
                            },
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    },
                    .event_new => value = self.newEvent(program, node.value_type) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } },
                    .event_signal => |signal| {
                        value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } };
                        const event = self.calls.values[frame.base + signal.event];
                        const carried = self.calls.values[frame.base + signal.value];
                        if (self.control.effects.depth > 0) {
                            self.holdSignal(event, carried) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        } else self.signalEvent(event.object, carried, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                    },
                    // P3.9: a subscription made or ended, journalled like a field's write.
                    .event_subscribe => |c| value = self.subscribe(self.calls.values[frame.base + c.event].object, self.calls.values[frame.base + c.callback], node.value_type) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } },
                    .subscription_cancel => |operand| {
                        self.unsubscribe(self.calls.values[frame.base + operand].object) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } };
                    },
                    // P3.9: the first callback runs on top; this frame stays at the node until the
                    // last has returned (the return path above).
                    .event_notify => |n| {
                        const event = self.calls.values[frame.base + n.callable].object;
                        frame.notify_limit = (self.source.read(event.id + catalogue.subscription_count) catch unreachable).integer;
                        const from = self.source.read(event.id + catalogue.subscription_first) catch unreachable;
                        switch (self.notifyFrom(program, frame, n, from, remaining)) {
                            .pushed => continue,
                            .done => value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } },
                            .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                        }
                    },
                    // P3.3: whether the site before it yielded cancelled, which only it can.
                    .canceling => {
                        value = .{ .boolean = s.just_canceled };
                        s.just_canceled = false;
                    },
                    // P3.6: whether the site before its check yielded an arm's pending exit,
                    // which only it can, and that exit's value, which the code after reads.
                    .arm_exited => {
                        value = .{ .boolean = s.just_exited };
                        s.just_exited = false;
                    },
                    .arm_exit_value => value = s.exit_value,
                    .arm_exit => |operand| {
                        // P3.6: as an `exit`, in the entry frame of an arm (admission lets nothing
                        // else run its function); the expression learns of the pending exit when
                        // the frame has ended and settles the arm.
                        assert(tracing and frame.task != call_frames.no_task and s.tasks[frame.task].kind == .arm);
                        const committed = frame.catch_depth != 0;
                        while (frame.catch_depth != 0) {
                            if (definition.has_source) self.source.commit() catch unreachable;
                            if (self.commitRegion() catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } }) drains = true;
                            frame.catch_depth -= 1;
                        }
                        const pending = self.calls.values[frame.base + operand];
                        self.control.calls[self.control.call_count] = .{ .function = frame.function, .pc = pc, .value = pending, .kind = .arm_exit };
                        self.control.call_count += 1;
                        s.tasks[frame.task].exited = true;
                        self.calls.values[frame.base + definition.root] = pending;
                        frame.pc = length;
                        if (drains) self.calls.frames[self.calls.depth - 1].drain_span = node.span;
                        if (drains) self.drainFromTop(program, root_pc, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        // RFC-0084, P4.4: a commit to depth 0 delivers, after its drain, as `exit`.
                        if (committed and !drains and self.live.on) switch (self.deliveryPoint(program, node.span, root_pc, remaining)) {
                            .fired, .done => {},
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        };
                        continue;
                    },
                    .cancel_exit => {
                        // The landing has run: the frame ends cancelled, writes no register of its
                        // caller and reclaims nothing.
                        assert(tracing and frame.catch_depth == 0);
                        self.control.calls[self.control.call_count] = .{ .function = frame.function, .pc = pc, .value = .{ .boolean = false }, .kind = .cancel_exit };
                        self.control.call_count += 1;
                        if (frame.owned_first != call_frames.no_task) {
                            // P3.4: it keeps tasks, which it asks to cancel and waits for at its
                            // end, before it ends cancelled.
                            frame.canceled_end = true;
                            frame.pc = length;
                            switch (self.ownedEnd(program, root_pc, remaining)) {
                                .going => continue,
                                .empty => return .{ .ok = .{ .boolean = false } },
                                .failed => |diagnostic| return .{ .failed = diagnostic },
                            }
                        }
                        switch (self.canceledEnd(program, node.span, root_pc, remaining)) {
                            .going => continue,
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    },
                    .err => return .{ .failed = .{ .span = node.span, .code = .runtime_error } },
                    .cell_read => |cell| {
                        value = self.source.read(cell) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        // RFC-0084, L3: the running guard depends on what it reads.
                        if (self.live.tracking) live_machine.noteRead(&self.live, &self.source, cell);
                    },
                    .cell_write => |cell| {
                        value = self.calls.values[frame.base + cell.value];
                        if (self.live.on) live_machine.unlink(&self.live, &self.source, cell.cell, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveRuntimeCode(err) } };
                        self.source.write(cell.cell, value, false) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        if (self.live.on) if (self.livePropagate(program, cell.cell, node.span, root_pc, remaining)) |diagnostic| return .{ .failed = diagnostic };
                        point = self.live.on;
                    },
                    .cell_init => unreachable,
                    // RFC-0087, P5.4: a keyed cell's lookup, on which the running guard depends
                    // as on a read of the cell (L3), and its update, a program write (W6).
                    .weak_get => |g| {
                        const map = self.source.read(g.cell) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        if (self.live.tracking) live_machine.noteRead(&self.live, &self.source, g.cell);
                        value = self.keyedLookup(map, self.calls.values[frame.base + g.key], node.value_type, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                    },
                    .weak_set => |c| {
                        const map = self.source.read(c.cell) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        const written = self.keyedUpdate(map, self.calls.values[frame.base + c.key], self.calls.values[frame.base + c.value], remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        value = self.calls.values[frame.base + c.value];
                        if (self.live.on) live_machine.unlink(&self.live, &self.source, c.cell, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveRuntimeCode(err) } };
                        self.source.write(c.cell, written, false) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        // RFC-0087, P5.5 (S5): and, for a persistent cell, its action on the store channel.
                        if (self.storeAction(program, c, self.calls.values[frame.base + c.key], self.calls.values[frame.base + c.value], remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        if (self.live.on) if (self.livePropagate(program, c.cell, node.span, root_pc, remaining)) |diagnostic| return .{ .failed = diagnostic };
                        point = self.live.on;
                    },
                    .weak_init => unreachable,
                    .object_new => |c| value = self.newObject(node.value_type, program.function_arguments[c.arguments.start..c.arguments.end], self.calls.values[frame.base .. frame.base + pc]) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } },
                    // RFC-0085, I1: a variable cell. Its value can change, so the running guard
                    // depends on what it reads of it (S9, L3), and a write is a program write (L2).
                    .ref_new => |operand| value = self.newRef(node.value_type, self.calls.values[frame.base + operand]) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } },
                    .ref_get => |operand| {
                        const cell = self.calls.values[frame.base + operand].object.id + catalogue.ref_value;
                        value = self.source.read(cell) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        if (self.live.tracking) live_machine.noteRead(&self.live, &self.source, cell);
                    },
                    .ref_set => |r| {
                        const cell = self.calls.values[frame.base + r.ref].object.id + catalogue.ref_value;
                        value = self.calls.values[frame.base + r.value];
                        if (self.live.on) live_machine.unlink(&self.live, &self.source, cell, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveRuntimeCode(err) } };
                        self.source.write(cell, value, false) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        if (self.live.on) if (self.livePropagate(program, cell, node.span, root_pc, remaining)) |diagnostic| return .{ .failed = diagnostic };
                        point = self.live.on;
                    },
                    .object_get, .object_set => {
                        const registers = self.calls.values[frame.base .. frame.base + pc];
                        // RFC-0084, L2: a program write of a field detaches its record (P4.2).
                        if (node.kind == .object_set and self.live.on) live_machine.unlink(&self.live, &self.source, registers[node.kind.object_set.object].object.id + 1 + node.kind.object_set.index, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveRuntimeCode(err) } };
                        value = self.objectAccess(instructionFromNode(node), registers) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        if (node.kind == .object_get and self.live.tracking) {
                            // A `var` field is a dependency, and so is a live-only one, which its
                            // guard writes; an immutable one never changes (L3).
                            const a = node.kind.object_get;
                            const instance = registers[a.value].object;
                            const field = catalogue.classFieldAt(instance.value_type, a.index, program.definitions, program.fields).?;
                            if (field.is_var or field.live_only) live_machine.noteRead(&self.live, &self.source, instance.id + 1 + a.index);
                        }
                        if (node.kind == .object_set and self.live.on) {
                            const c = node.kind.object_set;
                            if (self.livePropagate(program, registers[c.object].object.id + 1 + c.index, node.span, root_pc, remaining)) |diagnostic| return .{ .failed = diagnostic };
                            point = true;
                        }
                    },
                    // RFC-0084: `set live` in a function.
                    .cell_live => |c| {
                        value = switch (self.liveEstablish(program, cellSpot(program, c), self.calls.values[frame.base + c.guard].callable, (@as(i64, frame.function) + 1) << 32 | pc, node.span, root_pc, remaining)) {
                            .ok => |established| established,
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        };
                        point = true;
                    },
                    // RFC-0084, P4.2: `set live E.F = G`, and a live field's attachment.
                    .object_live => |c| {
                        value = switch (self.liveEstablish(program, fieldSpot(self.calls.values[frame.base + c.object].object, c, node.value_type), self.calls.values[frame.base + c.guard].callable, (@as(i64, frame.function) + 1) << 32 | pc, node.span, root_pc, remaining)) {
                            .ok => |established| established,
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        };
                        point = true;
                    },
                    // RFC-0084, P4.4: `Upon` or `When`, started now outside every region; a body
                    // that fires runs on top, and this frame stays at the node until it returns.
                    .reaction => |r| {
                        const slot = self.reactionNew(program, node.value_type, r, self.calls.values[frame.base + r.guard], self.calls.values[frame.base + r.body], root_pc, node.span, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        value = s.tasks[slot].handle;
                        if (self.control.effects.depth > 0) {
                            self.holdStart(slot) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        } else switch (self.reactionStart(program, slot, .node, node.span, root_pc, remaining)) {
                            .fired => continue,
                            // Its guard left steps: the node's own needs room again.
                            .waits => if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } },
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    },
                    // RFC-0084, P4.5: `Batch{...}`: its body's frame on top, with one more batch open;
                    // this frame gets the body's result when it returns, which delivers then.
                    .batch => |operand| {
                        const body = self.calls.values[frame.base + operand].callable;
                        if (self.pushCall(program, .{ .function = body.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures }, frame.base)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        self.live.batches += 1;
                        continue;
                    },
                    .merge => |m| value = upcastValue(self.calls.values[frame.base + if (self.calls.values[frame.base + m.begin].boolean) m.left else m.right], node.value_type),
                    .self_value => value = .{ .callable = .{ .value_type = node.value_type, .function = frame.function } },
                    .invoke => {
                        const child = node.invocationWith(frame.function, self.calls.values[frame.base .. frame.base + pc]).?.call;
                        if (self.pushCall(program, child, frame.base)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        continue;
                    },
                    .recur => |arguments| {
                        const child: types.ResolvedCall = .{ .function = frame.function, .arguments = arguments };
                        if (self.pushCall(program, child, frame.base)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        continue;
                    },
                    .call => |child| {
                        if (self.pushCall(program, .{ .function = child.function, .arguments = child.arguments }, frame.base)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        continue;
                    },
                    .iterate, .iterate_value, .loop => switch (self.startInvocation(program, node.invocationWith(frame.function, self.calls.values[frame.base .. frame.base + pc]).?, frame.base, remaining)) {
                        .pushed => continue,
                        .immediate => |seed| value = seed,
                        .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                    },
                    .bind => |b| {
                        const original = self.calls.values[frame.base + b.callable].callable;
                        const old = original.captures.end - original.captures.start;
                        const count = old + b.arguments.end - b.arguments.start;
                        if (count > self.aggregate_values.len - self.aggregate_count) return .{ .failed = .{ .span = node.span, .code = .aggregate_limit } };
                        const capture_range: types.Span = .{ .start = @intCast(self.aggregate_count), .end = @intCast(self.aggregate_count + count) };
                        assert(original.captures.end <= self.aggregate_count and count <= types.limits.parameters);
                        @memcpy(self.aggregate_values[capture_range.start .. capture_range.start + old], self.aggregate_values[original.captures.start..original.captures.end]);
                        for (program.function_arguments[b.arguments.start..b.arguments.end], self.aggregate_values[capture_range.start + old .. capture_range.end]) |operand, *out| out.* = self.calls.values[frame.base + operand];
                        self.aggregate_count = capture_range.end;
                        value = .{ .callable = .{ .value_type = node.value_type, .function = original.function, .captures = capture_range } };
                    },
                    .aggregate => |range| {
                        const count = range.end - range.start;
                        if (count > self.aggregate_values.len - self.aggregate_count) return .{ .failed = .{ .span = node.span, .code = .aggregate_limit } };
                        const physical: types.Span = .{ .start = @intCast(self.aggregate_count), .end = @intCast(self.aggregate_count + count) };
                        for (program.function_members[range.start..range.end], self.aggregate_values[physical.start..physical.end]) |operand, *destination| destination.* = self.calls.values[frame.base + operand];
                        if (keyedAggregate(program, node.value_type)) keys.unique(&self.key_work, &self.aggregate_values, self.aggregate_values[physical.start..physical.end], remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
                        self.aggregate_count = physical.end;
                        value = .{ .aggregate = .{ .value_type = node.value_type, .elements = physical } };
                    },
                    else => value = (self.step(instructionFromNode(node), program, self.calls.values[frame.base .. frame.base + frame.pc], remaining, false) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } }).?,
                },
            }
            if (tracing) {
                self.control.calls[self.control.call_count] = .{ .function = frame.function, .pc = pc, .value = value };
                self.control.call_count += 1;
                // And where it stands after a native, which may build strings its result does not name.
                if (self.control.trace_sink != null and entry.input == .operation and (node.kind == .native_call or node.kind == .json_decode)) self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
            }
            self.calls.values[frame.base + pc] = value;
            frame.pc = next;
            if (drains) self.calls.frames[self.calls.depth - 1].drain_span = node.span;
            if (drains) self.drainFromTop(program, root_pc, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = runtimeCode(err) } };
            // RFC-0084, P4.4: what the node notified is delivered now, unless held back; after a
            // drain it begins, when that ends.
            if (point and !drains and self.live.on) switch (self.deliveryPoint(program, node.span, root_pc, remaining)) {
                .fired, .done => {},
                .failed => |diagnostic| return .{ .failed = diagnostic },
            };
        }
        unreachable;
    }
    /// What the run holds of the three stores a reclamation compacts.
    inline fn usage(self: *const Machine) types.ControlStorage.Usage {
        return .{ .members = self.aggregate_count, .strings = self.string_used, .cells = if (self.source.depth != 0) self.source.cell_count else 0 };
    }
    /// Frees what the frame that ends built and nothing can reach any more: members, run
    /// strings and class instances above the three marks taken when the frame was pushed. See
    /// `ControlStorage.reclaim_floor` for the rule. `root` is the one value the frame hands on.
    /// Registers of the frames below, captures and what a rollback restores were all written
    /// before the frame was pushed and so name nothing above its marks. The cells that existed
    /// then can have been given newer values, so they are roots too, as is an instance that an
    /// open region holds a record for, and the reasons of the failure traces.
    ///
    /// Reachability is found breadth first. `hops[i]` is `i` while member `mark + i` has not
    /// been reached and leads towards the next such member afterwards, so that going through a
    /// span skips what an earlier span already covered. Members that can name something queue
    /// in `list`; instances queue through the entry of their second cell.
    ///
    /// What stays slides down to its mark in order, in each store, and every value still in
    /// use is rewritten to name it where it lies afterwards.
    noinline fn reclaim(self: *Machine, program: Program, frame: *const call_frames.VmFrame, root: *types.Value) void {
        @branchHint(.cold);
        const now = self.usage();
        // RFC-0082, P3.5: a frame that saw another task run since its push reclaims above the
        // marks `reclaimMarks` gives, and what every suspended frame holds is a root too.
        const across = frame.switches != self.scheduler.switches;
        const before = self.reclaimMarks(frame);
        const top: u32 = @intCast(self.aggregate_count);
        const mark: u32 = @intCast(before.members);
        const cell_mark: u32 = @intCast(before.cells);
        const string_mark: u32 = @intCast(before.strings);
        const cell_top: u32 = @intCast(now.cells);
        assert(mark <= top and top <= self.aggregate_values.len and cell_mark <= cell_top and string_mark <= self.string_used);
        // Every switch is made outside every region, so none is open at the end of such a frame.
        assert(!across or (self.control.effects.depth == 0 and self.source.undo_count == 0));
        if (across and !self.links_ready) self.prepareLinks(program);
        // A sink checks the steps it has not seen against the pools they were recorded with.
        self.control.foldCalls(self.aggregate_values[0..top]);
        const size = top - mark;
        const pool = self.aggregate_values[mark..top];
        const cells = self.source.cells[0..cell_top];
        const hops = self.reclaim_hops[0 .. size + 1];
        const places = self.reclaim_work.cells[0 .. cell_top - cell_mark];
        var walk: Walk = .{ .definitions = program.definitions, .pool = pool, .mark = mark, .cells = cells, .cell_mark = cell_mark, .hops = hops, .places = places, .queue = &self.reclaim_work.list };
        for (hops, 0..) |*hop, index| hop.* = @intCast(index);
        @memset(places, 0);
        walk.see(root.*);
        // The scheduler's values (RFC-0082): live tasks' handles, unstarted tasks' closures, and
        // from P3.2 what a ready task resumes with, what a waiting one waits on, and the events
        // and values of signals not yet carried out.
        // From P3.3 an arm has no handle, and one that completed holds its result.
        for (self.scheduler.tasks[0..self.scheduler.high]) |task| switch (task.phase) {
            .free => {},
            .held, .queued => {
                walk.see(task.handle);
                walk.see(task.closure);
            },
            .running => if (task.kind == .spawn) walk.see(task.handle),
            .ready => {
                if (task.kind == .spawn) walk.see(task.handle);
                walk.see(task.resume_value);
            },
            .waiting => {
                if (task.kind == .spawn) walk.see(task.handle);
                if (task.waits == .event or task.waits == .task) walk.see(task.on);
            },
            .settled => if (task.done) walk.see(task.result),
        };
        // RFC-0084, P4.4: a reaction holds its handle, its guard and its body while it lives.
        for (self.scheduler.tasks[0..self.scheduler.high]) |*task| if (task.phase != .free and reactive(task)) {
            walk.see(task.handle);
            walk.see(task.closure);
            walk.see(task.body);
        };
        for (0..self.scheduler.held_count) |offset| {
            const place = (self.scheduler.held_first + offset) % self.scheduler.held.len;
            if (self.scheduler.held[place] != call_frames.no_task) continue;
            walk.see(self.scheduler.held_signals[place].event);
            walk.see(self.scheduler.held_signals[place].value);
        }
        // P3.5: the registers of the suspended frames that are available where each stands,
        // their iteration seeds and their captures.
        if (across) {
            var held: SavedRoots = .{ .frames = .init(&self.scheduler), .program = program, .links = &self.reclaim_links };
            while (held.next()) |value| walk.see(value.*);
            var frames: SavedFrames = .init(&self.scheduler);
            while (frames.next()) |saved| walk.seeSpan(saved.frame.captures);
        }
        for (cells[0..cell_mark]) |cell| walk.see(cell.value);
        // RFC-0084: a link reaches its record, and so its guard. A record that reads a cell
        // below the mark stays too, since a write of the cell would evaluate it (C24); failed
        // regions are undone first, so that the chains hold the valid entries.
        if (self.live.on) {
            live_machine.beforeReclaim(&self.live, &self.source);
            for (cells[0..cell_mark]) |cell| if (cell.link != source_state.no_link and cell.link >= cell_mark) walk.seeInstance(cell.link);
            for (self.live.entries[0..self.live.count]) |entry| if (entry.chained and entry.cell < cell_mark and entry.record >= cell_mark and entry.record & call_frames.observer_entry == 0) walk.seeInstance(entry.record);
        }
        // An instance with a record stays until its region ends: the record keeps its cell.
        var first: u32 = cell_mark;
        while (first < cell_top) {
            const count = walk.instanceCells(first);
            var cell = first;
            while (cell < first + count) : (cell += 1) if (self.source.holds(cell)) break;
            if (cell != first + count) walk.seeInstance(first);
            first += count;
        }
        while (walk.head != walk.tail or walk.oldest != Walk.none) {
            while (walk.head != walk.tail) {
                walk.head += 1;
                walk.see(pool[walk.queue[walk.head - 1]]);
            }
            if (walk.oldest != Walk.none) {
                const offset = walk.oldest;
                walk.oldest = places[offset + 1];
                if (walk.oldest == Walk.none) walk.newest = Walk.none;
                const count = walk.instanceCells(cell_mark + offset);
                for (cells[cell_mark + offset + 1 ..][0 .. count - 1], cell_mark + offset + 1..) |cell, id| {
                    walk.see(cell.value);
                    if (cell.link != source_state.no_link and cell.link >= cell_mark) walk.seeInstance(cell.link);
                    // The records that read a field that stays stay too (C24).
                    if (self.live.on and id < self.live.known) {
                        var at = self.live.oldest[id];
                        while (live_machine.readerAfter(&self.live, &at)) |reader| {
                            if (reader >= cell_mark) walk.seeInstance(reader);
                        }
                    }
                }
            }
        }
        // `hops` becomes the number of members that stay below each position, and `places`
        // one more than the number of cells that stay below each cell that stays itself.
        var kept: u32 = 0;
        for (hops[0..size], 0..) |*hop, index| {
            const stays = hop.* != index;
            hop.* = kept;
            kept += @intFromBool(stays);
        }
        hops[size] = kept;
        var kept_cells: u32 = 0;
        first = cell_mark;
        while (first < cell_top) {
            const count = walk.instanceCells(first);
            const entries = places[first - cell_mark ..][0..count];
            if (entries[0] == 0) {
                @memset(entries, 0);
            } else for (entries) |*entry| {
                kept_cells += 1;
                entry.* = kept_cells;
            }
            first += count;
        }
        // The entries move or go before any value is renumbered: validity reads the cells.
        if (self.live.on) live_machine.moveEntries(&self.live, &self.source, cell_mark, places);
        const live_count = live_machine.measure(&self.live, &self.source);
        const traces = self.control.traces[0..self.control.trace_count];
        var text: Text = .{ .origin = @intFromPtr(program.strings.ptr), .mark = string_mark, .top = @intCast(self.string_used), .bits = &self.reclaim_work.starts, .ranks = &self.reclaim_work.ranks, .ends = &self.reclaim_work.list };
        var string_kept: u32 = text.top;
        // P3.5: the suspended frames' values are held too.
        const saved_roots: ?SavedRoots = if (across) .{ .frames = .init(&self.scheduler), .program = program, .links = &self.reclaim_links } else null;
        if (text.top != text.mark) {
            // Three passes over the values still in use: where their strings start, how far
            // the strings that start at one place reach, and then, below, where each went.
            // A suspended frame's string mark is an empty string at its place: it moves so.
            @memset(text.bits[0 .. (text.top - text.mark) / 64 + 1], 0);
            var holders: Holders = .{ .machine = self, .walk = &walk, .root = root, .traces = traces, .saved = saved_roots };
            while (holders.next()) |value| if (value.* == .string) text.start(value.string);
            holders.endTrace();
            if (across) {
                var frames: SavedFrames = .init(&self.scheduler);
                while (frames.next()) |saved| text.start(text.at(saved.frame.string_mark));
            }
            text.number();
            holders = .{ .machine = self, .walk = &walk, .root = root, .traces = traces, .saved = saved_roots };
            while (holders.next()) |value| if (value.* == .string) text.reach(value.string);
            holders.endTrace();
            if (across) {
                var frames: SavedFrames = .init(&self.scheduler);
                while (frames.next()) |saved| text.reach(text.at(saved.frame.string_mark));
            }
            string_kept = text.slide(@constCast(program.strings.ptr));
        }
        var holders: Holders = .{ .machine = self, .walk = &walk, .root = root, .traces = traces, .saved = saved_roots };
        while (holders.next()) |value| switch (value.*) {
            .aggregate => |*aggregate| aggregate.elements = renumberedSpan(hops, mark, aggregate.elements),
            .callable => |*callable| callable.captures = renumberedSpan(hops, mark, callable.captures),
            .object => |*object| if (object.id >= cell_mark) {
                assert(places[object.id - cell_mark] != 0);
                object.id = cell_mark + places[object.id - cell_mark] - 1;
            },
            .string => |*string| if (text.top != text.mark) {
                string.* = text.moved(string.*);
            },
            else => {},
        };
        holders.endTrace();
        if (across) self.remapSaved(&walk, &text, mark, cell_mark, cell_top);
        for (pool, 0..) |member, offset| {
            if (hops[offset + 1] != hops[offset]) pool[hops[offset]] = member;
        }
        if (self.source.depth != 0) self.source.relocate(cell_mark, places);
        if (self.live.on) for (self.source.cells[0..self.source.cell_count]) |*cell| {
            if (cell.link != source_state.no_link and cell.link >= cell_mark) cell.link = cell_mark + places[cell.link - cell_mark] - 1;
        };
        self.aggregate_count = mark + kept;
        self.string_stale = run_strings.staleAfter(self.string_stale, self.string_used, string_kept, text.newest);
        self.string_used = string_kept;
        self.control.reclaimed(now, .{ .members = self.aggregate_count, .strings = string_kept, .cells = cell_mark + kept_cells }, types.ControlStorage.reclaimExamined(now, before, (if (self.source.depth != 0) self.source.undo_count + live_count else 0) + self.acrossUnits(frame)), self.calls.depth, self.scheduler.switches);
    }
    /// RFC-0082, P3.5: the marks the end of `frame` reclaims above, and what rooting the
    /// suspended frames adds to the measure of that reclamation and to the decision to make it.
    /// A frame that saw no other task run since its push keeps its own marks and adds nothing:
    /// what other tasks hold was all built below them (the P3.1 rule).
    inline fn reclaimMarks(self: *const Machine, frame: *const call_frames.VmFrame) types.ControlStorage.Usage {
        const marks: types.ControlStorage.Usage = .{ .members = frame.mark, .strings = frame.string_mark, .cells = frame.cell_mark };
        return if (frame.switches == self.scheduler.switches) marks else self.control.acrossMarks(marks);
    }
    /// The suspended frames and the registers and parameters they count (C13), for a frame
    /// that saw a switch: a bound on what rooting them examines.
    inline fn acrossUnits(self: *const Machine, frame: *const call_frames.VmFrame) u64 {
        const s = &self.scheduler;
        if (frame.switches == s.switches) return 0;
        return @as(u64, s.frames_used) + s.values_used + s.parameters_used;
    }
    /// For every body node, the newest register before it that is available there: in its own
    /// arm or an enclosing one, not in an arm that has closed or one not taken. The registers
    /// available at a node are that one, the one before it by the same rule, and so on, which is
    /// the analysis that admits operands (`verifyControlBody`), kept per node so that rooting a
    /// frame costs its available registers and not its body.
    fn prepareLinks(self: *Machine, program: Program) void {
        for (program.functions) |f| {
            // The newest available register before each arm that is open.
            var open: [types.limits.control_depth]u32 = undefined;
            var depth: usize = 0;
            var newest: u32 = no_link;
            for (program.function_nodes[f.body.start..f.body.end], f.body.start.., 0..) |entry, at, index| {
                switch (entry.node.kind) {
                    .if_begin, .attempt_begin => {
                        self.reclaim_links[at] = newest;
                        open[depth] = newest;
                        depth += 1;
                    },
                    // The first arm's registers are not available in the second.
                    .otherwise => {
                        newest = open[depth - 1];
                        self.reclaim_links[at] = newest;
                    },
                    // Nor are either arm's after the merge, which holds the value.
                    .merge => {
                        depth -= 1;
                        self.reclaim_links[at] = open[depth];
                        newest = @intCast(index);
                    },
                    else => {
                        self.reclaim_links[at] = newest;
                        newest = @intCast(index);
                    },
                }
            }
            assert(depth == 0);
        }
        self.links_ready = true;
    }
    /// After a reclamation that rooted the suspended frames: their captures name members where
    /// they lie now, and each of their marks above the reclaiming ones becomes the number of
    /// what stays below its old place, in each store. Called once every value is rewritten and
    /// before anything moves: the cells' headers are still where they were.
    fn remapSaved(self: *Machine, walk: *const Walk, text: *const Text, mark: u32, cell_mark: u32, cell_top: u32) void {
        var frames: SavedFrames = .init(&self.scheduler);
        while (frames.next()) |saved| {
            const frame = saved.frame;
            frame.captures = renumberedSpan(walk.hops, mark, frame.captures);
            if (frame.mark > mark) frame.mark = mark + walk.hops[frame.mark - mark];
            if (frame.string_mark > text.mark) frame.string_mark = @intCast(@intFromPtr(text.moved(text.at(frame.string_mark)).ptr) - text.origin);
        }
        if (cell_top == cell_mark) return;
        // The cells that stay below each instance's first cell, and below the top. The work
        // list is free again: the strings have moved.
        const below = self.reclaim_work.list[0 .. cell_top - cell_mark + 1];
        var kept: u32 = 0;
        var first = cell_mark;
        while (first < cell_top) {
            const count = walk.instanceCells(first);
            below[first - cell_mark] = kept;
            if (walk.places[first - cell_mark] != 0) kept += count;
            first += count;
        }
        below[cell_top - cell_mark] = kept;
        frames = .init(&self.scheduler);
        while (frames.next()) |saved| {
            if (saved.frame.cell_mark > cell_mark) saved.frame.cell_mark = cell_mark + below[saved.frame.cell_mark - cell_mark];
        }
    }
    const no_link = std.math.maxInt(u32);
    /// RFC-0082, P3.5: every frame of every suspended task, in the order their runs lie, each
    /// with its task's registers.
    const SavedFrames = struct {
        scheduler: *call_frames.VmScheduler,
        slot: u32,
        at: u32 = 0,

        const Saved = struct { frame: *call_frames.VmSavedFrame, values: []types.Value };

        fn init(scheduler: *call_frames.VmScheduler) SavedFrames {
            return .{ .scheduler = scheduler, .slot = scheduler.first_saved };
        }
        fn next(self: *SavedFrames) ?Saved {
            while (self.slot != call_frames.no_task) {
                const task = &self.scheduler.tasks[self.slot];
                if (self.at < task.frames) {
                    self.at += 1;
                    return .{ .frame = &self.scheduler.saved[task.first_frame + self.at - 1], .values = self.scheduler.saved_values[task.first_value..][0..task.values] };
                }
                self.slot = task.next;
                self.at = 0;
            }
            return null;
        }
    };
    /// The values the suspended frames hold, one after another: per frame, the iteration seed
    /// of a loop's frame, and the registers available where it stands. A frame waiting at a site
    /// or in a call stands at that node, whose own register is not yet written; one waiting at
    /// its end for the tasks it owns holds only its result, and one that ends cancelled nothing.
    const SavedRoots = struct {
        frames: SavedFrames,
        program: Program,
        links: []const u32,
        current: ?SavedFrames.Saved = null,
        seed: bool = false,
        register: u32 = no_link,

        fn next(self: *SavedRoots) ?*types.Value {
            while (true) {
                if (self.current) |saved| {
                    if (self.seed) {
                        self.seed = false;
                        return &saved.frame.iteration_seed;
                    }
                    if (self.register != no_link) {
                        const register = self.register;
                        const f = self.program.functions[saved.frame.function];
                        self.register = if (saved.frame.pc == f.body.end - f.body.start) no_link else self.links[f.body.start + register];
                        return &saved.values[saved.frame.base + register];
                    }
                }
                const saved = self.frames.next() orelse return null;
                self.current = saved;
                self.seed = saved.frame.state_loop or saved.frame.remaining_visits != 0;
                const f = self.program.functions[saved.frame.function];
                self.register = if (saved.frame.pc != f.body.end - f.body.start) self.links[f.body.start + saved.frame.pc] else if (saved.frame.canceled_end) no_link else f.root;
            }
        }
    };
    /// The walk that finds what is reachable above the marks.
    const Walk = struct {
        definitions: []const types.Definition,
        pool: []const types.Value,
        mark: u32,
        cells: []const source_state.Cell,
        cell_mark: u32,
        hops: []u32,
        places: []u32,
        queue: []u32,
        head: usize = 0,
        tail: usize = 0,
        /// Instances whose fields are still to be read, first and last, by cell above the mark.
        oldest: u32 = none,
        newest: u32 = none,

        const none = std.math.maxInt(u32);

        fn instanceCells(self: *const Walk, first: u32) u32 {
            const header = self.cells[first].value;
            assert(header == .integer);
            return catalogue.classCells(@fromBackingInt(@intCast(header.integer)), self.definitions).?;
        }
        /// The first member at or after `from` that has not been reached. Every entry passed
        /// is pointed two steps on, which keeps later searches short.
        fn unreached(self: *Walk, from: u32) u32 {
            var at = from;
            while (self.hops[at] != at) {
                const after = self.hops[at];
                self.hops[at] = self.hops[after];
                at = after;
            }
            return at;
        }
        fn see(self: *Walk, value: types.Value) void {
            const span = switch (value) {
                .aggregate => |aggregate| aggregate.elements,
                .callable => |callable| callable.captures,
                .object => |object| return if (object.id >= self.cell_mark) self.seeInstance(object.id),
                else => return,
            };
            self.seeSpan(span);
        }
        fn seeSpan(self: *Walk, span: types.Span) void {
            if (span.end <= self.mark or span.start == span.end) return;
            assert(span.start < span.end and span.end - self.mark <= self.pool.len);
            // A span that began below the mark is reachable from the mark upwards.
            var at = self.unreached(span.start -| self.mark);
            while (at < span.end - self.mark) {
                self.hops[at] = at + 1;
                const member = self.pool[at];
                if (member == .aggregate or member == .callable or member == .object) {
                    self.queue[self.tail] = at;
                    self.tail += 1;
                }
                at = self.unreached(at + 1);
            }
            // An array in use keeps the room that begins where it ends (`array_concat`), so that
            // it grows as it would have without this reclamation, for the same fuel.
            if (span.end - self.mark < self.pool.len) if (array_concat.placeholderLimit(self.pool[span.end - self.mark])) |limit| {
                assert(limit - self.mark < self.pool.len);
                at = self.unreached(span.end - self.mark);
                while (at <= limit - self.mark) : (at = self.unreached(at + 1)) self.hops[at] = at + 1;
            };
        }
        fn seeInstance(self: *Walk, first: u32) void {
            assert(first < self.cells.len);
            const offset = first - self.cell_mark;
            if (self.places[offset] != 0) return;
            self.places[offset] = 1;
            // An instance without fields names nothing.
            if (self.instanceCells(first) == 1) return;
            self.places[offset + 1] = none;
            if (self.newest == none) self.oldest = offset else self.places[self.newest + 1] = offset;
            self.newest = offset;
        }
    };
    /// Every value still in use that can name something above a mark, one after another: the
    /// handed-on value, the reasons of the failure traces, the cells that existed before the
    /// frame, the cells of the instances that stay, and the members that stay. A reason is
    /// lent as a value and written back by the next call, or by `endTrace` after the last.
    const Holders = struct {
        machine: *Machine,
        walk: *const Walk,
        root: *types.Value,
        traces: []types.FailureTrace,
        /// RFC-0082, P3.5: the suspended frames' values, when the frame that ends saw a switch.
        saved: ?SavedRoots = null,
        stage: enum { root, tasks, signals, traces, cells, members, done, saved } = .root,
        at: u32 = 0,
        lent: types.Value = undefined,
        lent_to: ?*types.FailureTrace = null,

        fn endTrace(self: *Holders) void {
            if (self.lent_to) |trace| trace.reason = self.lent.string;
            self.lent_to = null;
        }
        fn next(self: *Holders) ?*types.Value {
            self.endTrace();
            while (true) switch (self.stage) {
                .root => {
                    self.stage = .tasks;
                    return self.root;
                },
                .tasks => {
                    // A handle, then a closure for a task that has not started, the value a ready
                    // one resumes with, what a waiting one waits on, and the result of an arm
                    // that completed (P3.3); from P4.4 a reaction's guard and body, which it holds
                    // while it lives: `at` counts all six.
                    const s = &self.machine.scheduler;
                    while (self.at < 6 * s.high) {
                        const task = &s.tasks[self.at / 6];
                        const which = self.at % 6;
                        self.at += 1;
                        if (task.phase == .free) continue;
                        switch (which) {
                            0 => if (task.kind == .spawn or reactive(task)) return &task.handle,
                            1 => if (task.phase == .held or task.phase == .queued or reactive(task)) return &task.closure,
                            2 => if (task.phase == .ready) return &task.resume_value,
                            3 => if (task.phase == .waiting and (task.waits == .event or task.waits == .task)) return &task.on,
                            4 => if (task.phase == .settled and task.done) return &task.result,
                            else => if (reactive(task)) return &task.body,
                        }
                    }
                    self.stage = .signals;
                    self.at = 0;
                },
                .signals => {
                    // The event and the value of each signal held or committed (P3.2).
                    const s = &self.machine.scheduler;
                    while (self.at < 2 * s.held_count) {
                        const place = (s.held_first + self.at / 2) % s.held.len;
                        const value = self.at % 2 == 1;
                        self.at += 1;
                        if (s.held[place] != call_frames.no_task) continue;
                        return if (value) &s.held_signals[place].value else &s.held_signals[place].event;
                    }
                    self.stage = .saved;
                    self.at = 0;
                },
                .saved => {
                    if (self.saved) |*held| if (held.next()) |value| return value;
                    self.stage = .traces;
                },
                .traces => {
                    while (self.at < self.traces.len) {
                        const trace = &self.traces[self.at];
                        self.at += 1;
                        const reason = trace.reason orelse continue;
                        self.lent = .{ .string = reason };
                        self.lent_to = trace;
                        return &self.lent;
                    }
                    self.stage = .cells;
                    self.at = 0;
                },
                .cells => {
                    const walk = self.walk;
                    // Above the mark, the cells of an instance that goes are passed over whole.
                    while (self.at < walk.cells.len) {
                        const cell = self.at;
                        if (cell >= walk.cell_mark and walk.places[cell - walk.cell_mark] == 0) {
                            self.at += 1;
                            continue;
                        }
                        self.at += 1;
                        return &self.machine.source.cells[cell].value;
                    }
                    self.stage = .members;
                    self.at = 0;
                },
                .members => {
                    const hops = self.walk.hops;
                    while (self.at + 1 < hops.len) {
                        const offset = self.at;
                        self.at += 1;
                        if (hops[offset + 1] != hops[offset]) return &self.machine.aggregate_values[self.walk.mark + offset];
                    }
                    self.stage = .done;
                },
                .done => return null,
            };
        }
    };
    /// The run strings above the frame's mark. A string still in use keeps its bytes; the bytes
    /// no string names close up. `bits` has a bit per place a string starts at, `ranks` counts
    /// the bits before each word, and `ends` holds, per start in order, first the furthest end
    /// of the strings starting there and then the number of bytes dropped before it.
    const Text = struct {
        origin: usize,
        mark: u32,
        top: u32,
        bits: []u64,
        ranks: []u32,
        ends: []u32,
        newest: bool = true,

        /// The offset of a string that reclaiming concerns: one that names a byte above the
        /// mark, or an empty one that stands above it and so moves with its place.
        fn offsetOf(self: *const Text, string: []const u8) ?u32 {
            const offset = @intFromPtr(string.ptr) -% self.origin;
            if (offset > self.top or offset + string.len <= self.mark) return null;
            assert(offset + string.len <= self.top);
            return @intCast(offset);
        }
        fn start(self: *Text, string: []const u8) void {
            const offset = self.offsetOf(string) orelse return;
            // Bytes below the mark stay, so a string that began there counts from the mark.
            const bit = (if (offset < self.mark) self.mark else offset) - self.mark;
            self.bits[bit >> 6] |= @as(u64, 1) << @intCast(bit & 63);
        }
        fn number(self: *Text) void {
            var total: u32 = 0;
            const words = (self.top - self.mark) / 64 + 1;
            for (0..words) |word| {
                self.ranks[word] = total;
                total += @popCount(self.bits[word]);
            }
            @memset(self.ends[0..total], 0);
        }
        fn ordinal(self: *const Text, offset: u32) u32 {
            const bit = (if (offset < self.mark) self.mark else offset) - self.mark;
            const earlier = self.bits[bit >> 6] & ((@as(u64, 1) << @intCast(bit & 63)) - 1);
            return self.ranks[bit >> 6] + @popCount(earlier);
        }
        fn reach(self: *Text, string: []const u8) void {
            const offset = self.offsetOf(string) orelse return;
            const slot = &self.ends[self.ordinal(offset)];
            const end = offset + @as(u32, @intCast(string.len));
            if (end > slot.*) slot.* = end;
        }
        /// Closes the gaps. `covered` is how far the strings met so far reach; a start beyond
        /// it leaves a gap of bytes nothing names, which is dropped. Bytes are moved a run at
        /// a time, once the run's end is known. Returns the bytes in use afterwards. `newest`
        /// is set when a string still in use names the last byte (c7-1).
        fn slide(self: *Text, bytes: [*]u8) u32 {
            self.newest = false;
            var dropped: u32 = 0;
            var covered: u32 = self.mark;
            var run_from: u32 = self.mark;
            var ordinal_now: u32 = 0;
            const words = (self.top - self.mark) / 64 + 1;
            for (0..words) |word| {
                var rest = self.bits[word];
                while (rest != 0) {
                    const offset = self.mark + @as(u32, @intCast(word)) * 64 + @ctz(rest);
                    rest &= rest - 1;
                    if (offset > covered) {
                        if (dropped != 0 and covered != run_from) std.mem.copyForwards(u8, bytes[run_from - dropped .. covered - dropped], bytes[run_from..covered]);
                        dropped += offset - covered;
                        run_from = offset;
                        covered = offset;
                    }
                    const end = self.ends[ordinal_now];
                    assert(end >= offset and end <= self.top);
                    if (end == self.top and end > offset) self.newest = true;
                    if (end > covered) covered = end;
                    self.ends[ordinal_now] = dropped;
                    ordinal_now += 1;
                }
            }
            if (dropped != 0 and covered != run_from) std.mem.copyForwards(u8, bytes[run_from - dropped .. covered - dropped], bytes[run_from..covered]);
            return covered - dropped;
        }
        /// The empty string at `offset` of the pool, which moves with its place.
        fn at(self: *const Text, offset: u32) []const u8 {
            return @as([*]const u8, @ptrFromInt(self.origin + offset))[0..0];
        }
        fn moved(self: *const Text, string: []const u8) []const u8 {
            const offset = self.offsetOf(string) orelse return string;
            if (offset <= self.mark) return string;
            return @as([*]const u8, @ptrFromInt(self.origin + offset - self.ends[self.ordinal(offset)]))[0..string.len];
        }
    };
    fn renumberedSpan(hops: []const u32, mark: u32, span: types.Span) types.Span {
        const limit = mark + @as(u32, @intCast(hops.len - 1));
        return .{
            .start = if (span.start <= mark or span.start > limit) span.start else mark + hops[span.start - mark],
            .end = if (span.end <= mark or span.end > limit) span.end else mark + hops[span.end - mark],
        };
    }
    /// Creates an instance of `class` from the operand registers named by `arguments`.
    fn newObject(self: *Machine, class: types.Type, arguments: []const u32, registers: []const types.Value) RuntimeError!types.Value {
        assert(arguments.len <= types.limits.record_fields);
        var cells: [types.limits.record_fields + 1]types.Value = undefined;
        cells[0] = .{ .integer = @backingInt(class) };
        for (arguments, cells[1..][0..arguments.len]) |operand, *out| out.* = registers[operand];
        return .{ .object = .{ .value_type = class, .id = try self.source.allocate(cells[0 .. arguments.len + 1]) } };
    }
    /// RFC-0087, P5.3: `ToJson` of `operand`, a value of `operand_type`, or `FromJson` of the text
    /// `operand` as the option `value_type`, on this machine's pools. The codec's stack is made at
    /// the run's first JSON instruction.
    fn json(self: *Machine, program: Program, encode: bool, operand_type: types.Type, operand: types.Value, value_type: types.Type, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
        if (self.json_stack == null) self.json_stack = scratch.storage(persist_json.Stack) catch return .{ .failed = .scratch_unavailable };
        var host: MachineJson = .{ .source = &self.source };
        const cat = persist_json.Catalogue.of(program);
        var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
        defer self.string_used = pool.used;
        const outcome: persist_json.Error!types.Value = if (encode)
            if (persist_json.encode(cat, &host, self.aggregate_values[0..self.aggregate_count], operand_type, operand, &pool, self.json_stack.?, remaining)) |text| .{ .string = text } else |err| err
        else
            persist_json.decode(cat, &host, .{ .slots = &self.aggregate_values, .count = &self.aggregate_count }, value_type, operand.string, &pool, self.json_stack.?, &self.key_work, remaining);
        const made = outcome catch |err| return .{ .failed = switch (err) {
            error.WorkLimit => .work_limit,
            error.StringLimit => .string_limit,
            error.AggregateLimit => .aggregate_limit,
            error.DepthLimit => .json_depth_limit,
            error.ScratchUnavailable => .scratch_unavailable,
            error.InvalidValue => .invalid_bytecode,
            error.Host => runtimeCode(host.problem),
        } };
        return .{ .ok = made };
    }
    /// RFC-0087, P5.5 (S4): the map a persistent cell starts as. Each key grant in order is asked
    /// for the cell's entry (an input of kind `load`, tick 0), the answers are read back from the
    /// record, and the present ones are decoded as the cell's value type (E3), each laid out as a
    /// value is: its members first. While they are decoded each value waits in the top of the pool,
    /// outside the room the decodes have; then the entries' pairs, keys and values side by side,
    /// are laid out after the last value, as a map literal's are. Charges 1 per load, what each
    /// decode charges, and 2 per entry. A text that does not decode ends the run, `load_invalid`.
    fn loads(self: *Machine, program: Program, cell: u32, map_type: types.Type, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
        const shape = switch (catalogue.definition(map_type, program.definitions) orelse return .{ .failed = .invalid_bytecode }) {
            .weak_map => |entries| entries,
            else => return .{ .failed = .invalid_bytecode },
        };
        const log = &self.control.effects;
        const grants = log.inputs.grants;
        const first = log.inputs.count;
        var asked: u32 = 0;
        for (grants, 0..) |grant, index| {
            if (grant.kind != .key) continue;
            if (remaining.* == 0) return .{ .failed = .work_limit };
            remaining.* -= 1;
            _ = log.inputs.read(.{ .kind = .load, .request = effects.loadRequest(cell, @intCast(index)), .tick = 0 }) catch |err| return .{ .failed = runtimeCode(err) };
            asked += 1;
        }
        var present: usize = 0;
        for (log.inputs.entries[first .. first + asked]) |entry| present += @intFromBool(entry.status == .value);
        const pool_room = self.aggregate_values[0..];
        const base = self.aggregate_count;
        if (present > pool_room.len - base) return .{ .failed = .aggregate_limit };
        // The values wait at the top, beyond the room the decodes have.
        const room = pool_room[0 .. pool_room.len - present];
        if (present != 0) {
            if (self.json_stack == null) self.json_stack = scratch.storage(persist_json.Stack) catch return .{ .failed = .scratch_unavailable };
            var host: MachineJson = .{ .source = &self.source };
            const cat = persist_json.Catalogue.of(program);
            var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
            defer self.string_used = pool.used;
            var waiting: usize = 0;
            var ordinal: u32 = 0;
            for (grants) |grant| {
                if (grant.kind != .key) continue;
                const entry = log.inputs.entries[first + ordinal];
                ordinal += 1;
                if (entry.status != .value) continue;
                const made = persist_json.decodeEntry(cat, &host, .{ .slots = room, .count = &self.aggregate_count }, shape.value, log.inputs.bytes[entry.start..entry.end], &pool, self.json_stack.?, &self.key_work, remaining) catch |err| return .{ .failed = jsonCode(err, host.problem) };
                pool_room[pool_room.len - 1 - waiting] = made orelse return .{ .failed = .load_invalid };
                waiting += 1;
            }
        }
        const start = self.aggregate_count;
        if (2 * present > room.len - start) return .{ .failed = .aggregate_limit };
        if (2 * present > remaining.*) return .{ .failed = .work_limit };
        remaining.* -= 2 * present;
        var pair: usize = 0;
        var ordinal: u32 = 0;
        for (grants, 0..) |grant, index| {
            if (grant.kind != .key) continue;
            const entry = log.inputs.entries[first + ordinal];
            ordinal += 1;
            if (entry.status != .value) continue;
            room[start + 2 * pair] = .{ .enumeration = .{ .value_type = shape.key, .index = @intCast(index) } };
            room[start + 2 * pair + 1] = pool_room[pool_room.len - 1 - pair];
            pair += 1;
        }
        self.aggregate_count = start + 2 * present;
        return .{ .ok = .{ .aggregate = .{ .value_type = map_type, .elements = .{ .start = @intCast(start), .end = @intCast(start + 2 * present) } } } };
    }
    fn jsonCode(err: persist_json.Error, host: RuntimeError) types.Diagnostic.Code {
        return switch (err) {
            error.WorkLimit => .work_limit,
            error.StringLimit => .string_limit,
            error.AggregateLimit => .aggregate_limit,
            error.DepthLimit => .json_depth_limit,
            error.ScratchUnavailable => .scratch_unavailable,
            error.InvalidValue => .invalid_bytecode,
            error.Host => runtimeCode(host),
        };
    }
    /// RFC-0087, P5.5 (S5): the store action of a `weak_set` of a persistent cell, prepared on the
    /// store channel right after the write: `{"cell":NAME,"key":NAME,"value":TEXT}`. The text is
    /// built in the string pool and given back to it once the log has its copy. Null when the
    /// cell is not persistent, or when the action was prepared; otherwise the diagnostic.
    fn storeAction(self: *Machine, program: Program, c: types.WeakSet, key: types.Value, value: types.Value, remaining: *u64) ?types.Diagnostic.Code {
        const cell = program.source_cells[c.cell];
        if (cell.keyed != .persistent) return null;
        const grants = self.control.effects.inputs.grants;
        if (key != .enumeration or key.enumeration.index >= grants.len or grants[key.enumeration.index].kind != .key) return .invalid_bytecode;
        const entry = persistable.persistentValue(cell.value_type, program.definitions) orelse return .invalid_bytecode;
        if (self.json_stack == null) self.json_stack = scratch.storage(persist_json.Stack) catch return .scratch_unavailable;
        var host: MachineJson = .{ .source = &self.source };
        var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
        const text = persist_json.encodeStoreAction(persist_json.Catalogue.of(program), &host, self.aggregate_values[0..self.aggregate_count], entry, value, cell.name, grants[key.enumeration.index].name, &pool, self.json_stack.?, remaining) catch |err| return jsonCode(err, host.problem);
        self.control.effects.prepareOn(effects.store_channel, text) catch |err| return native.effectErrorCode(err);
        return null;
    }
    /// RFC-0086, P2.3 (H3): the handle of the first of the run's grants of `g.kind` named `name`,
    /// as an option of `option_type` whose member is the next of the pool, or `option{}`. Each
    /// grant of the kind looked at costs a unit, the one found included.
    /// RFC-0087, P5.4: the entry of `key` in a keyed cell's map: an option viewing its value,
    /// as `map_lookup` gives it, or empty.
    fn keyedLookup(self: *Machine, map: types.Value, key: types.Value, option_type: types.Type, remaining: *u64) RuntimeError!types.Value {
        const range = map.aggregate.elements;
        const offset = try keys.lookup(&self.key_work, &self.aggregate_values, self.aggregate_values[range.start..range.end], key, remaining);
        const start: u32 = if (offset) |position| range.start + @as(u32, @intCast(position)) else range.end;
        return .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = start, .end = start + @as(u32, if (offset == null) 0 else 1) } } };
    }
    /// RFC-0087, P5.4: a keyed cell's map with the entry of `key` replaced, or appended, in the
    /// next members, as `map_set` builds it.
    fn keyedUpdate(self: *Machine, map: types.Value, key: types.Value, value: types.Value, remaining: *u64) RuntimeError!types.Value {
        const range = map.aggregate.elements;
        const found = try keys.lookup(&self.key_work, &self.aggregate_values, self.aggregate_values[range.start..range.end], key, remaining);
        const length = range.end - range.start;
        const total: u32 = length + if (found == null) @as(u32, 2) else 0;
        if (total > self.aggregate_values.len - self.aggregate_count) return error.AggregateLimit;
        if (total > remaining.*) return error.WorkLimit;
        remaining.* -= total;
        const base = self.aggregate_count;
        @memcpy(self.aggregate_values[base .. base + length], self.aggregate_values[range.start..range.end]);
        if (found) |position| {
            self.aggregate_values[base + position] = value;
        } else {
            self.aggregate_values[base + length] = key;
            self.aggregate_values[base + length + 1] = value;
        }
        self.aggregate_count += total;
        return .{ .aggregate = .{ .value_type = map.aggregate.value_type, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
    }
    fn openGrant(self: *Machine, g: types.Grant, name: []const u8, option_type: types.Type, program: Program, remaining: *u64) RuntimeError!types.Value {
        const grants = self.control.effects.inputs.grants;
        var at: usize = 0;
        const found = while (at < grants.len) : (at += 1) {
            if (grants[at].kind != g.kind) continue;
            if (remaining.* < 1) return error.WorkLimit;
            remaining.* -= 1;
            if (std.mem.eql(u8, grants[at].name, name)) break true;
        } else false;
        const first: u32 = @intCast(self.aggregate_count);
        if (found) {
            if (self.aggregate_count == self.aggregate_values.len) return error.AggregateLimit;
            const handle = catalogue.definition(option_type, program.definitions).?.option;
            self.aggregate_values[first] = .{ .enumeration = .{ .value_type = handle, .index = @intCast(at) } };
            self.aggregate_count += 1;
        }
        return .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = first, .end = @intCast(self.aggregate_count) } } };
    }
    /// RFC-0085, I1: a variable cell of type `ref_type` holding `initial`.
    fn newRef(self: *Machine, ref_type: types.Type, initial: types.Value) RuntimeError!types.Value {
        const cells = [catalogue.ref_cells]types.Value{ .{ .integer = @backingInt(ref_type) }, initial };
        return .{ .object = .{ .value_type = ref_type, .id = try self.source.allocate(&cells) } };
    }
    fn objectAccess(self: *Machine, instruction: Instruction, registers: []const types.Value) RuntimeError!types.Value {
        switch (instruction.op) {
            .object_get => |a| return self.source.read(registers[a.value].object.id + 1 + a.index),
            .object_set => |c| {
                const value = registers[c.value];
                try self.source.write(registers[c.object].object.id + 1 + c.index, value, false);
                return value;
            },
            else => unreachable,
        }
    }
    /// Appends one of the machine's own steps (RFC-0084), finding room for it first.
    fn liveStep(self: *Machine, span: types.Span, step_value: types.CallStep) ?types.Diagnostic {
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .span = span, .code = .call_trace_limit };
        self.control.calls[self.control.call_count] = step_value;
        self.control.call_count += 1;
        return null;
    }
    /// A guard, evaluated with tracking (L3): a unit of fuel, its step (`live_eval` with the record,
    /// or from P4.4 `observe` with a reaction's sequence) and its frame on top of the stack, run
    /// until that frame returns. `span` is the node that started it.
    fn liveGuard(self: *Machine, program: Program, closure: types.CallableValue, kind: @FieldType(types.CallStep, "kind"), told: types.Value, span: types.Span, root_pc: u32, remaining: *u64) LiveOutcome {
        if (remaining.* == 0) return .{ .failed = .{ .span = span, .code = .work_limit } };
        remaining.* -= 1;
        live_machine.prepare(&self.live, &self.source);
        live_machine.startGuard(&self.live, &self.source);
        self.live.record.evaluations += 1;
        if (self.liveStep(span, .{ .function = closure.function, .pc = 0, .value = told, .kind = kind })) |diagnostic| return .{ .failed = diagnostic };
        const below = self.calls.depth;
        const floor = self.guard_floor;
        defer self.guard_floor = floor;
        defer if (below == 0) {
            self.calls.depth = 0;
            self.calls.count = 0;
        };
        if (self.pushCall(program, .{ .function = closure.function, .arguments = .{ .start = 0, .end = 0 }, .captures = closure.captures }, null)) |code| return .{ .failed = .{ .span = span, .code = code } };
        if (below == 0 and self.control.trace_sink != null) for (0..2) |_| self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
        self.guard_floor = below;
        const outcome = self.runFrames(program, closure.function, true, span, root_pc, remaining);
        live_machine.endGuard(&self.live);
        return switch (outcome) {
            .ok => |value| .{ .ok = value },
            .failed => |diagnostic| .{ .failed = diagnostic },
            .language => unreachable, // A guard never fails (admission rule 1).
        };
    }
    fn liveSettled(self: *Machine, program: Program, function: u32, written: bool, span: types.Span) ?types.Diagnostic {
        const body = program.functions[function].body;
        return self.liveStep(span, .{ .function = function, .pc = body.end - body.start, .value = .{ .boolean = written }, .kind = .live_settle });
    }
    /// The establishing write (L2) of `c`: guard, record, link, entries and height, the value,
    /// then the propagation. `origin` names the node for `live_unstable`.
    fn liveEstablish(self: *Machine, program: Program, c: LiveSpot, closure: types.CallableValue, origin: i64, span: types.Span, root_pc: u32, remaining: *u64) LiveOutcome {
        const store = &self.live;
        const journal = &self.source;
        const record_type = liveTypeFor(program, c.value_type).?;
        live_machine.prepare(store, journal);
        const record: u32 = @intCast(journal.cell_count);
        const value = switch (self.liveGuard(program, closure, .live_eval, .{ .object = .{ .value_type = record_type, .id = record } }, span, root_pc, remaining)) {
            .ok => |established| established,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        if (self.liveSettled(program, closure.function, true, span)) |diagnostic| return .{ .failed = diagnostic };
        live_machine.prepare(store, journal);
        if (remaining.* < 1 + catalogue.live_cells) return .{ .failed = .{ .span = span, .code = .work_limit } };
        remaining.* -= 1 + catalogue.live_cells;
        const stamp = journal.live.stamp;
        var cells: [catalogue.live_cells]types.Value = undefined;
        cells[0] = .{ .integer = @backingInt(record_type) };
        cells[catalogue.live_guard] = .{ .callable = closure };
        cells[catalogue.live_stamp] = .{ .integer = @intCast(stamp) };
        cells[catalogue.live_height] = .{ .integer = @intCast(live_machine.heightAfter(store, journal, record, c.cell)) };
        cells[catalogue.live_owner] = .{ .object = c.owner orelse .{ .value_type = record_type, .id = record } };
        cells[catalogue.live_place] = .{ .integer = c.place };
        cells[catalogue.live_origin] = .{ .integer = origin };
        const first = journal.allocate(&cells) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        assert(first == record);
        store.record.records += 1;
        if (c.initialize) journal.write(c.cell, value, true) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        live_machine.link(store, journal, c.cell, record, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
        live_machine.admit(store, journal, 0, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
        live_machine.store_reads(store, journal, record, stamp, 0, 0);
        live_machine.raiseReaders(store, journal, record, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
        if (!c.initialize) journal.write(c.cell, value, false) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        if (self.livePropagate(program, c.cell, span, root_pc, remaining)) |diagnostic| return .{ .failed = diagnostic };
        return .{ .ok = value };
    }
    /// L5 to L7 after a write of `cell` at the node `span`: dirty records by (height, id), the
    /// per-record bound first, each evaluated and recorded, its readers raised; a comparable
    /// result equal to the target's value is not written, any other is, and dirties its readers.
    fn livePropagate(self: *Machine, program: Program, cell: u32, span: types.Span, root_pc: u32, remaining: *u64) ?types.Diagnostic {
        const store = &self.live;
        const journal = &self.source;
        live_machine.prepare(store, journal);
        live_machine.beginPropagation(store);
        live_machine.markDirty(store, journal, cell, self.control.effects.depth, remaining) catch |err| return .{ .span = span, .code = liveRuntimeCode(err) };
        var evaluations: u64 = 0;
        while (live_machine.next(store, journal)) |record| {
            if (live_machine.tallied(store, record) > types.limits.live_record_evaluations) return .{ .span = liveOrigin(program, journal, record), .code = .live_unstable };
            evaluations += 1;
            if (evaluations > types.limits.live_evaluations) return .{ .span = span, .code = .live_propagation_limit };
            const guard = journal.cells[record + catalogue.live_guard].value.callable;
            const record_type: types.Type = @fromBackingInt(@intCast(journal.cells[record].value.integer));
            const value = switch (self.liveGuard(program, guard, .live_eval, .{ .object = .{ .value_type = record_type, .id = record } }, span, root_pc, remaining)) {
                .ok => |result| result,
                .failed => |diagnostic| return diagnostic,
            };
            live_machine.prepare(store, journal);
            const old = live_machine.entriesOf(store, journal, record);
            live_machine.admit(store, journal, old, remaining) catch |err| return .{ .span = span, .code = liveRuntimeCode(err) };
            const stamp = journal.live.stamp;
            const previous = live_machine.stampOf(journal, record);
            journal.write(record + catalogue.live_stamp, .{ .integer = @intCast(stamp) }, false) catch |err| return .{ .span = span, .code = runtimeCode(err) };
            live_machine.store_reads(store, journal, record, stamp, previous, old);
            const target = live_machine.targetOf(journal, record);
            journal.write(record + catalogue.live_height, .{ .integer = @intCast(live_machine.heightAfter(store, journal, record, target)) }, false) catch |err| return .{ .span = span, .code = runtimeCode(err) };
            live_machine.raiseReaders(store, journal, record, remaining) catch |err| return .{ .span = span, .code = liveRuntimeCode(err) };
            const target_type = catalogue.definition(record_type, program.definitions).?.live;
            var stable = false;
            if (live_machine.comparable(store, target_type)) {
                // Charged as `==` is: a unit, and the walk of the values.
                if (remaining.* == 0) return .{ .span = span, .code = .work_limit };
                remaining.* -= 1;
                stable = compareValues(.equal, value, journal.cells[target].value, self.aggregate_values[0..self.aggregate_count], &self.key_work, remaining, false) catch |err| return .{ .span = span, .code = runtimeCode(err) };
            }
            if (self.liveSettled(program, guard.function, !stable, span)) |diagnostic| return diagnostic;
            if (stable) continue;
            if (remaining.* == 0) return .{ .span = span, .code = .work_limit };
            remaining.* -= 1;
            journal.write(target, value, false) catch |err| return .{ .span = span, .code = runtimeCode(err) };
            live_machine.markDirty(store, journal, target, self.control.effects.depth, remaining) catch |err| return .{ .span = span, .code = liveRuntimeCode(err) };
        }
        // The writing node's own step comes next: it needs room as every step does.
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .span = span, .code = .call_trace_limit };
        return null;
    }

    // Reactions (RFC-0084, P4.4), in the VM: a reaction is a task without frames, whose slot
    // keeps its guard and body and whose dependencies the live store keeps while it waits on its
    // guard. Its body runs on top of the stack as its task's entry frame, inside an implicit batch
    // (`firing_depth`), and the delivery loop it belongs to goes on when the body returns.

    fn reactive(task: *const call_frames.VmTask) bool {
        return task.kind == .upon or task.kind == .when;
    }
    /// `reaction`: a unit for the creation, a slot, the handle with the next sequence; its guard
    /// and body wait in the slot. It is started or held by the caller.
    fn reactionNew(self: *Machine, program: Program, handle_type: types.Type, r: types.Reaction, guard: types.Value, body: types.Value, origin: u32, span: types.Span, remaining: *u64) RuntimeError!u32 {
        const slot = try self.spawnTask(program, handle_type, guard, origin, remaining);
        const task = &self.scheduler.tasks[slot];
        task.kind = if (r.kind == .upon) .upon else .when;
        task.body = body;
        task.site_span = span;
        live_machine.watchReset(&self.live, slot);
        return slot;
    }
    /// The reaction in `slot` starts (N5): it waits on its guard, evaluated now, and fires if
    /// that succeeded.
    fn reactionStart(self: *Machine, program: Program, slot: u32, by: call_frames.Firing, span: types.Span, root_pc: u32, remaining: *u64) union(enum) { fired, waits, failed: types.Diagnostic } {
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        s.created += 1;
        task.phase = .waiting;
        task.waits = .guard;
        task.wake = call_frames.never;
        switch (self.reactionObserve(program, slot, span, root_pc, remaining)) {
            .ok => |succeeded| if (!succeeded) return .waits,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        }
        if (self.reactionFire(program, slot, by, span, remaining)) |diagnostic| return .{ .failed = diagnostic };
        return .fired;
    }
    /// The reaction's guard, evaluated with tracking as an `observe`; what it read becomes the
    /// reaction's dependencies. Whether the option it gave is present.
    fn reactionObserve(self: *Machine, program: Program, slot: u32, span: types.Span, root_pc: u32, remaining: *u64) union(enum) { ok: bool, failed: types.Diagnostic } {
        const task = &self.scheduler.tasks[slot];
        const value = switch (self.liveGuard(program, task.closure.callable, .observe, .{ .integer = @intCast(task.sequence) }, span, root_pc, remaining)) {
            .ok => |result| result,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        live_machine.prepare(&self.live, &self.source);
        live_machine.watchAdmit(&self.live, &self.source, slot, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
        live_machine.watchStore(&self.live, &self.source, slot, self.source.live.stamp);
        const option = value.aggregate.elements;
        return .{ .ok = option.end != option.start };
    }
    /// RFC-0084, P4.6: the guard of the `Await` the task on top stands at, evaluated with
    /// tracking as an `observe` with the task's sequence, its reads recorded as the task's
    /// dependencies (N7). When it holds they let go at once, a unit each, as at a firing, and the
    /// site yields the option's value; otherwise the task is to wait on them.
    fn awaitObserve(self: *Machine, program: Program, guard: types.CallableValue, span: types.Span, root_pc: u32, remaining: *u64) union(enum) { holds: types.Value, waits, failed: types.Diagnostic } {
        const s = &self.scheduler;
        const slot = s.current;
        assert(slot != call_frames.no_task and !reactive(&s.tasks[slot]));
        // A task that is not waiting on a guard holds no entries and is not notified: a wait
        // ends by a delivery, which takes it off the list, or by a request, after which it never
        // reaches a site again. Its slot's entry is made so before the guard runs.
        live_machine.watchReset(&self.live, slot);
        const value = switch (self.liveGuard(program, guard, .observe, .{ .integer = @intCast(s.tasks[slot].sequence) }, span, root_pc, remaining)) {
            .ok => |result| result,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        live_machine.prepare(&self.live, &self.source);
        live_machine.watchAdmit(&self.live, &self.source, slot, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
        live_machine.watchStore(&self.live, &self.source, slot, self.source.live.stamp);
        const option = value.aggregate.elements;
        if (option.end == option.start) return .waits;
        live_machine.watchRelease(&self.live, &self.source, slot, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
        return .{ .holds = self.aggregate_values[option.start] };
    }
    /// Fires the reaction in `slot`: a unit and one per entry it lets go, the `fire` step, and
    /// its body's frame on top, its task's entry frame, inside a batch. A node that made it gets
    /// the handle when the body ends (`handoff`).
    fn reactionFire(self: *Machine, program: Program, slot: u32, by: call_frames.Firing, span: types.Span, remaining: *u64) ?types.Diagnostic {
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        if (remaining.* == 0) return .{ .span = span, .code = .work_limit };
        remaining.* -= 1;
        live_machine.watchRelease(&self.live, &self.source, slot, remaining) catch |err| return .{ .span = span, .code = liveRuntimeCode(err) };
        self.live.record.firings += 1;
        task.phase = .running;
        task.fired_by = by;
        task.fire_span = span;
        const body = task.body.callable;
        if (self.liveStep(span, .{ .function = body.function, .pc = 0, .value = .{ .integer = @intCast(task.sequence) }, .kind = .fire })) |diagnostic| return diagnostic;
        self.live.firing_depth += 1;
        const below = self.calls.depth;
        if (self.pushCall(program, .{ .function = body.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures }, null)) |code| return .{ .span = span, .code = code };
        const frame = &self.calls.frames[self.calls.depth - 1];
        frame.task = slot;
        frame.handoff = by == .node and below != 0;
        task.below = s.current;
        task.entry_at = below;
        s.current = slot;
        if (below == 0 and self.control.trace_sink != null) for (0..2) |_| self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
        return null;
    }
    /// The body of the reaction in `slot` (its entry frame `function`) returned `result`: an
    /// `Upon` settles, a `When` observes again. Then the node that made it gets its handle, the
    /// delivery loop goes on, or the drain delivers and takes its next turn.
    fn reactionFired(self: *Machine, program: Program, slot: u32, function: u32, result: types.Value, handoff: bool, blame: types.Span, root_pc: u32, remaining: *u64) VmLeft {
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        assert(self.live.firing_depth != 0 and task.phase == .running and s.current == slot);
        self.live.firing_depth -= 1;
        const by = task.fired_by;
        const span = task.fire_span;
        const handle = task.handle;
        const site = task.site_span;
        if (task.kind == .upon) {
            // P4.7: asked while it fired, its body has finished all the same: it completes (N6).
            self.settleTask(program, slot, function, result) catch |err| return .{ .failed = .{ .span = blame, .code = runtimeCode(err) } };
        } else if (task.cancel) {
            // P4.7 (N6): a `When` asked while it fired settles cancelled now, with a cancelled
            // task's `settle` step, and registers no more.
            if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = blame, .code = .call_trace_limit } };
            s.current = task.below;
            task.below = call_frames.no_task;
            const body = program.functions[function].body;
            self.control.calls[self.control.call_count] = .{ .function = function, .pc = body.end - body.start, .value = .{ .boolean = false }, .kind = .settle };
            self.control.call_count += 1;
            self.reactionCanceled(slot, remaining) catch |err| return .{ .failed = .{ .span = blame, .code = runtimeCode(err) } };
        } else {
            // A `When` waits on its guard again, with what it reads now (15:524).
            s.current = task.below;
            task.below = call_frames.no_task;
            task.phase = .waiting;
            task.waits = .guard;
            switch (self.reactionObserve(program, slot, span, root_pc, remaining)) {
                .ok => {},
                .failed => |diagnostic| return .{ .failed = diagnostic },
            }
        }
        var at = span;
        switch (by) {
            .loop => return switch (self.deliver(program, root_pc, remaining)) {
                .fired => .going,
                .done => self.continueDrain(program, root_pc, remaining),
                .failed => |diagnostic| .{ .failed = diagnostic },
            },
            .node => {
                if (handoff) {
                    const below = &self.calls.frames[self.calls.depth - 1];
                    if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = site, .code = .call_trace_limit } };
                    self.control.calls[self.control.call_count] = .{ .function = below.function, .pc = below.pc, .value = handle };
                    self.control.call_count += 1;
                    self.calls.values[below.base + below.pc] = handle;
                    below.pc += 1;
                }
                at = site;
            },
            .start => {},
        }
        return switch (self.deliveryPoint(program, at, root_pc, remaining)) {
            .fired => .going,
            .done => self.continueDrain(program, root_pc, remaining),
            .failed => |diagnostic| .{ .failed = diagnostic },
        };
    }
    const Delivered = union(enum) { fired, done, failed: types.Diagnostic };
    /// A delivery point at `span` (N3): the delivery loop begins when nothing holds it back.
    fn deliveryPoint(self: *Machine, program: Program, span: types.Span, root_pc: u32, remaining: *u64) Delivered {
        if (!live_machine.mayDeliver(&self.live, self.control.effects.depth)) return .done;
        self.live.delivering = true;
        self.live.delivery_span = span;
        self.live.delivered = 0;
        return self.deliver(program, root_pc, remaining);
    }
    /// The delivery loop (N4) goes on: each notified reaction in order is counted, charged and
    /// delivered to; one waiting on its guard observes it and fires when it holds.
    fn deliver(self: *Machine, program: Program, root_pc: u32, remaining: *u64) Delivered {
        const s = &self.scheduler;
        const span = self.live.delivery_span;
        assert(self.live.delivering and self.live.firing_depth == 0);
        while (live_machine.nextNotified(&self.live)) |slot| {
            self.live.delivered += 1;
            if (self.live.delivered > types.limits.deliveries) return .{ .failed = .{ .span = span, .code = .reaction_limit } };
            if (remaining.* == 0) return .{ .failed = .{ .span = span, .code = .work_limit } };
            remaining.* -= 1;
            self.live.record.deliveries += 1;
            const task = &s.tasks[slot];
            if (self.liveStep(span, .{ .function = 0, .pc = 0, .value = .{ .integer = @intCast(task.sequence) }, .kind = .deliver })) |diagnostic| return .{ .failed = diagnostic };
            // RFC-0084, P4.7: a reaction cancelled while this was pending gets nothing, and its
            // slot goes now (C74).
            if (task.phase == .settled and reactive(task)) {
                self.dropSlot(slot);
                continue;
            }
            if (task.phase != .waiting or task.waits != .guard) continue;
            if (!reactive(task)) {
                // P4.6: a task at an `Await` stops waiting, its entries let go, a unit each, and
                // joins the ready queue (S4); it evaluates its guard again when it runs (N7).
                live_machine.prepare(&self.live, &self.source);
                live_machine.watchRelease(&self.live, &self.source, slot, remaining) catch |err| return .{ .failed = .{ .span = span, .code = liveRuntimeCode(err) } };
                self.makeReady(slot, .{ .boolean = true });
                continue;
            }
            switch (self.reactionObserve(program, slot, span, root_pc, remaining)) {
                .ok => |succeeded| if (!succeeded) continue,
                .failed => |diagnostic| return .{ .failed = diagnostic },
            }
            if (self.reactionFire(program, slot, .loop, span, remaining)) |diagnostic| return .{ .failed = diagnostic };
            return .fired;
        }
        self.live.delivering = false;
        return .done;
    }
    /// The frame on top drains: its next turn, or the end of the drain and its delivery.
    fn continueDrain(self: *Machine, program: Program, root_pc: u32, remaining: *u64) VmLeft {
        if (self.calls.depth == 0) return .empty;
        if (!self.calls.frames[self.calls.depth - 1].drains) return .going;
        return switch (self.drainTurn(program, self.calls.frames[self.calls.depth - 1].drain_span, root_pc, remaining)) {
            .pushed, .done => .going,
            .failed => |diagnostic| .{ .failed = diagnostic },
        };
    }
    /// The next turn of the drain of the frame on top (C10, P4.4): signals before it are carried
    /// out; a task starts by hand-off, a reaction observes and may fire, and one that does not
    /// gives the turn on at once. With nothing left the drain ends and delivers at `span`.
    fn drainTurn(self: *Machine, program: Program, span: types.Span, root_pc: u32, remaining: *u64) union(enum) { pushed, done, failed: types.Diagnostic } {
        while (true) {
            const slot = (self.nextStart(root_pc, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } }) orelse {
                self.calls.frames[self.calls.depth - 1].drains = false;
                return switch (self.deliveryPoint(program, span, root_pc, remaining)) {
                    .fired => .pushed,
                    .done => .done,
                    .failed => |diagnostic| .{ .failed = diagnostic },
                };
            };
            if (reactive(&self.scheduler.tasks[slot])) switch (self.reactionStart(program, slot, .start, span, root_pc, remaining)) {
                .fired => return .pushed,
                .waits => continue,
                .failed => |diagnostic| return .{ .failed = diagnostic },
            };
            self.startTask(program, slot, false) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
            return .pushed;
        }
    }
    /// A firing at the root: the body's frame, on the empty stack, runs until the stack is empty.
    fn atRoot(self: *Machine, program: Program, span: types.Span, root_pc: u32, remaining: *u64) ?types.Diagnostic {
        assert(self.calls.depth == 1);
        defer {
            self.calls.depth = 0;
            self.calls.count = 0;
        }
        return switch (self.runFrames(program, self.calls.frames[0].function, true, span, root_pc, remaining)) {
            .ok => null,
            .failed => |diagnostic| diagnostic,
            .language => unreachable, // A body cannot fail.
        };
    }
    /// The text operations (RFC-0069). Positions are byte positions; the compiler's guards make
    /// the rejected cases unreachable from source, and forged code traps on each of them.
    fn textStep(self: *Machine, t: types.Text, result: types.Type, program: Program, values: []const types.Value, remaining: *u64) RuntimeError!types.Value {
        switch (t.op) {
            .unit => {
                const text = values[t.a].string;
                const position = values[t.b].integer;
                if (position < 0 or position >= text.len) return error.IndexRange;
                return .{ .enumeration = .{ .value_type = types.Type.char, .index = text[@intCast(position)] } };
            },
            .boundary => return .{ .boolean = textBoundary(values[t.a].string, values[t.b].integer) },
            .slice => {
                const text = values[t.a].string;
                const start = values[t.b].integer;
                const end = values[t.c].integer;
                if (start < 0 or end > text.len or end < start) return error.InvalidBytecode;
                // An empty slice splits nothing; it is the empty view at the start of the string.
                if (end == start) return .{ .string = text[0..0] };
                if (!textBoundary(text, start) or !textBoundary(text, end)) return error.InvalidBytecode;
                return .{ .string = text[@intCast(start)..@intCast(end)] };
            },
            .scalar => {
                const text = values[t.a].string;
                const position = values[t.b].integer;
                if (position < 0 or position >= text.len) return error.InvalidBytecode;
                const scalar = decodeScalar(text[@intCast(position)..]) orelse return error.InvalidBytecode;
                return .{ .enumeration = .{ .value_type = types.Type.char32, .index = scalar.code } };
            },
            .code => return .{ .integer = values[t.a].enumeration.index },
            .from_code => {
                const code = values[t.a].integer;
                if (!characterCode(result, code)) return error.InvalidBytecode;
                return .{ .enumeration = .{ .value_type = result, .index = @intCast(code) } };
            },
            .valid => {
                const range = values[t.a].aggregate.elements;
                assert(range.start <= range.end and range.end <= self.aggregate_count);
                const count = range.end - range.start;
                if (count > remaining.*) return error.WorkLimit;
                remaining.* -= count;
                return .{ .boolean = validUnits(self.aggregate_values[range.start..range.end]) };
            },
            .join => {
                const range = values[t.a].aggregate.elements;
                assert(range.start <= range.end and range.end <= self.aggregate_count);
                const units = self.aggregate_values[range.start..range.end];
                if (units.len > remaining.*) return error.WorkLimit;
                remaining.* -= units.len;
                var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
                const out = try run_strings.reserve(&pool, units.len, remaining);
                self.string_used = pool.used;
                // Checked on the units, so bytes that are not text are never written as a string.
                if (!validUnits(units)) return error.InvalidBytecode;
                for (out, units) |*byte, unit| byte.* = @intCast(unit.enumeration.index);
                return .{ .string = out };
            },
        }
    }
    fn step(self: *Machine, instruction: Instruction, program: Program, values: []const types.Value, remaining: *u64, comptime fully_funded: bool) RuntimeError!?types.Value {
        @setFloatMode(.strict);
        switch (instruction.op) {
            .if_begin, .attempt_begin, .otherwise, .merge, .demand, .fail, .exit, .err, .cell_init, .cell_read, .cell_write, .object_new, .object_get, .object_set, .call, .iterate, .recur, .self_value, .invoke, .iterate_value, .loop, .bind => unreachable,
            .spawn, .sleep, .canceling, .cancel_exit => unreachable,
            .task_await, .event_new, .event_signal, .event_await => unreachable,
            .structured => unreachable,
            .branch => unreachable,
            .cell_live => unreachable,
            .object_live => unreachable,
            .arm_exit, .arm_exited, .arm_exit_value => unreachable,
            .reaction => unreachable,
            .task_cancel, .elapsed_time => unreachable,
            .batch => unreachable,
            .await_guard => unreachable,
            .event_subscribe, .subscription_cancel, .event_notify => unreachable,
            .ref_new, .ref_get, .ref_set => unreachable,
            .grant => unreachable,
            .weak_init, .weak_get, .weak_set => unreachable,
            .json_encode, .json_decode => unreachable,
            .function_value => |id| return .{ .callable = .{ .value_type = instruction.value_type.?, .function = id } },
            .local_set => |n| return values[n],
            .upcast => |n| return upcastValue(values[n], instruction.value_type.?),
            // The compiler guards a refinement with a `demand` of its bounds; forged code traps.
            .refine => |n| {
                if (catalogue.refinementOf(instruction.value_type.?, program.definitions)) |refinement| if (!withinBounds(refinement, values[n])) return error.InvalidBytecode;
                return values[n];
            },
            .downcast => |n| {
                // The compiler guards this with an `instance_of` check; forged code traps.
                if (!hasType(program, values[n], instruction.value_type.?)) return error.InvalidBytecode;
                // A function comes out at the type it is cast to, as an upcast gives it (RFC-0081).
                return upcastValue(values[n], instruction.value_type.?);
            },
            .instance_of => |c| return .{ .boolean = hasType(program, values[c.value], c.class) },
            .method_value => |m| {
                const function = catalogue.dispatchLookup(program.dispatch, values[m.receiver].object.value_type, m.slot) orelse return error.InvalidBytecode;
                return .{ .callable = .{ .value_type = instruction.value_type.?, .function = function } };
            },
            .integer => |value| return .{ .integer = value },
            .floating => |value| return .{ .floating = types.canonicalFloat(value) },
            .boolean => |value| return .{ .boolean = value },
            .string => |span| return .{ .string = program.strings[span.start..span.end] },
            .negate => |operand| return .{ .integer = try std.math.sub(i64, 0, values[operand].integer) },
            .binary => |binary| return .{ .integer = try arithmetic(binary.op, values[binary.lhs].integer, values[binary.rhs].integer) },
            .float_negate => |operand| return .{ .floating = types.canonicalFloat(-values[operand].floating) },
            .int_to_float => |operand| return .{ .floating = @floatFromInt(values[operand].integer) },
            .float_to_int => |c| {
                const x = values[c.operand].floating;
                // The compiler guards this conversion; forged code traps as invalid bytecode.
                if (!(x >= -types.integer_float_bound and x < types.integer_float_bound)) return error.InvalidBytecode;
                const below = @floor(x);
                const fraction = x - below;
                const rounded = switch (c.mode) {
                    .floor => below,
                    .ceil => if (fraction == 0) below else below + 1,
                    .truncate => if (x < 0 and fraction != 0) below + 1 else below,
                    .round_even => if (fraction < 0.5) below else if (fraction > 0.5) below + 1 else if (@mod(below, 2) == 0) below else below + 1,
                };
                return .{ .integer = @intFromFloat(rounded) };
            },
            .logic_not => |operand| return .{ .boolean = !values[operand].boolean },
            .logic_binary => |binary| return .{ .boolean = if (binary.op == .both) values[binary.lhs].boolean and values[binary.rhs].boolean else values[binary.lhs].boolean or values[binary.rhs].boolean },
            .compare => |comparison| return .{ .boolean = try compareValues(comparison.op, values[comparison.lhs], values[comparison.rhs], &self.aggregate_values, &self.key_work, remaining, fully_funded) },
            .float_binary => |binary| return .{ .floating = floatArithmetic(binary.op, values[binary.lhs].floating, values[binary.rhs].floating) },
            .rational => |r| return try rationalStep(r, values),
            .aggregate => |range| {
                assert(range.start == self.aggregate_count);
                assert(range.end <= self.aggregate_values.len);
                for (program.members[range.start..range.end], self.aggregate_values[range.start..range.end]) |operand, *destination| destination.* = values[operand];
                if (!fully_funded and keyedAggregate(program, instruction.value_type.?)) try keys.unique(&self.key_work, &self.aggregate_values, self.aggregate_values[range.start..range.end], remaining);
                self.aggregate_count = range.end;
                return .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = range } };
            },
            .field, .tuple_element => |access| {
                const range = values[access.value].aggregate.elements;
                assert(range.end <= self.aggregate_count);
                assert(access.index < range.end - range.start);
                return self.aggregate_values[range.start + access.index];
            },
            .array_length => |operand| {
                const range = values[operand].aggregate.elements;
                assert(range.start <= range.end and range.end <= self.aggregate_count);
                if (fully_funded) return .{ .integer = range.end - range.start };
                const shape = catalogue.definition(values[operand].aggregate.value_type, program.definitions).?;
                return .{ .integer = (range.end - range.start) / @as(u32, if (shape == .map) 2 else 1) };
            },
            .option_present => |operand| return .{ .boolean = values[operand].aggregate.elements.start != values[operand].aggregate.elements.end },
            .option_value => |operand| {
                const range = values[operand].aggregate.elements;
                // The compiler guards this read with a presence `demand`; forged code traps.
                if (range.start == range.end) return error.InvalidBytecode;
                return self.aggregate_values[range.start];
            },
            .option_or => |choice| {
                const range = values[choice.option].aggregate.elements;
                return if (range.start == range.end) values[choice.fallback] else self.aggregate_values[range.start];
            },
            .array_concat => |c| {
                const left = values[c.lhs].aggregate.elements;
                const right = values[c.rhs].aggregate.elements;
                const joined = array_concat.plan(left, right, self.aggregate_count, array_concat.roomIn(self.aggregate_values[0..self.aggregate_count], left, right, self.aggregate_values.len, if (self.calls.depth == 0) array_concat.contextOf(0, false, 0, self.scheduler.switches != 0, self.scheduler.frames_used != 0) else array_concat.contextOf(self.calls.frames[self.calls.depth - 1].mark, self.control.root_ended, self.control.root_end.members, self.calls.frames[self.calls.depth - 1].switches != self.scheduler.switches, self.scheduler.frames_used != 0)));
                if (joined.appended() > self.aggregate_values.len - self.aggregate_count) return error.AggregateLimit;
                if (joined.copy > remaining.*) return error.WorkLimit;
                remaining.* -= joined.copy;
                array_concat.apply(&self.aggregate_values, &self.aggregate_count, left, right, joined);
                return .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = joined.span } };
            },
            .string_concat => |c| {
                var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
                pool.stale = self.string_stale;
                const joined = try run_strings.concat(&pool, values[c.lhs].string, values[c.rhs].string, remaining);
                self.string_used = pool.used;
                return .{ .string = joined };
            },
            .string_length => |operand| return .{ .integer = @intCast(values[operand].string.len) },
            .to_string => |operand| {
                var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
                const text = try run_strings.convert(&pool, values[operand], remaining);
                self.string_used = pool.used;
                return .{ .string = text };
            },
            .native_call => |c| {
                var arguments: [native.max_parameters]types.Value = undefined;
                for (c.args[0..c.count], 0..) |operand, i| arguments[i] = values[operand];
                var pool = run_strings.Pool.resumed(program.strings, program.string_tail, self.string_used);
                // An effect native is lent the port of this machine's effect log; a pure one nothing.
                const outcome = native.invokeWith(program.natives[c.native], instruction.value_type.?, arguments[0..c.count], &self.aggregate_values, &self.aggregate_count, &pool, &self.key_work, remaining, self.control.effects.port(self.scheduler.now));
                self.string_used = pool.used;
                // The faults of an effect have diagnostics of their own.
                if (outcome == .fault) switch (outcome.fault) {
                    .effect_limit => return error.EffectLimit,
                    .effect_prepare_failed => return error.EffectPrepareFailed,
                    .effect_commit_failed => return error.EffectCommitFailed,
                    .input_limit => return error.InputLimit,
                    .input_failed => return error.InputFailed,
                    .input_unavailable => return error.InputUnavailable,
                    .input_invalid => return error.InputInvalid,
                    .input_diverged => return error.InputDiverged,
                    else => {},
                };
                switch (outcome) {
                    .ok => |value| return value,
                    .fault => |fault| return switch (native.faultError(fault)) {
                        error.WorkLimit => error.WorkLimit,
                        error.AggregateLimit => error.AggregateLimit,
                        error.StringLimit => error.StringLimit,
                        error.Overflow => error.Overflow,
                        error.ScratchUnavailable => error.ScratchUnavailable,
                        error.Failed => if (fault == .invalid) error.InvalidNative else error.NativeFailed,
                    },
                }
            },
            .map_set => |c| {
                if (fully_funded) unreachable; // Full funding also proves a map-free catalogue.
                const range = values[c.map].aggregate.elements;
                const found = try keys.lookup(&self.key_work, &self.aggregate_values, self.aggregate_values[range.start..range.end], values[c.key], remaining);
                const length = range.end - range.start;
                const total: u32 = length + if (found == null) @as(u32, 2) else 0;
                if (total > self.aggregate_values.len - self.aggregate_count) return error.AggregateLimit;
                if (total > remaining.*) return error.WorkLimit;
                remaining.* -= total;
                const base = self.aggregate_count;
                @memcpy(self.aggregate_values[base .. base + length], self.aggregate_values[range.start..range.end]);
                if (found) |position| {
                    self.aggregate_values[base + position] = values[c.value];
                } else {
                    self.aggregate_values[base + length] = values[c.key];
                    self.aggregate_values[base + length + 1] = values[c.value];
                }
                self.aggregate_count += total;
                return .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
            },
            .map_remove => |c| {
                if (fully_funded) unreachable; // Full funding also proves a map-free catalogue.
                const range = values[c.map].aggregate.elements;
                // The operand is the option the guarding lookup returned: where it points is the
                // entry, and no key is compared again. Code whose option is empty or points
                // anywhere but at a value of this map is forged.
                const view = values[c.key].aggregate.elements;
                if (view.end - view.start != 1 or view.start < range.start or view.start >= range.end) return error.InvalidBytecode;
                const offset = view.start - range.start;
                if (offset & 1 == 0) return error.InvalidBytecode;
                const kept = range.end - range.start - 2;
                if (kept > self.aggregate_values.len - self.aggregate_count) return error.AggregateLimit;
                if (kept > remaining.*) return error.WorkLimit;
                remaining.* -= kept;
                const base = self.aggregate_count;
                const head = offset - 1;
                const source = self.aggregate_values[range.start..range.end];
                var out: usize = base;
                for (source[0..head]) |member| {
                    self.aggregate_values[out] = member;
                    out += 1;
                }
                for (source[head + 2 ..]) |member| {
                    self.aggregate_values[out] = member;
                    out += 1;
                }
                assert(out == base + kept);
                self.aggregate_count = out;
                return .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = @intCast(base), .end = @intCast(out) } } };
            },
            .array_set => |c| {
                const range = values[c.array].aggregate.elements;
                const position = values[c.index].integer;
                if (position < 0 or position >= range.end - range.start) return error.InvalidBytecode;
                const total = range.end - range.start;
                if (total > self.aggregate_values.len - self.aggregate_count) return error.AggregateLimit;
                if (total > remaining.*) return error.WorkLimit;
                remaining.* -= total;
                const base = self.aggregate_count;
                @memcpy(self.aggregate_values[base .. base + total], self.aggregate_values[range.start..range.end]);
                self.aggregate_values[base + @as(u32, @intCast(position))] = values[c.value];
                self.aggregate_count += total;
                return .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
            },
            .array_get => |access| {
                const range = values[access.array].aggregate.elements;
                const position = values[access.index].integer;
                // `Items[I]` guards this read with a bounds `demand`; `ElementAt` does not, so an
                // index outside the array is a fatal error, never a read outside the pool.
                if (position < 0 or position >= range.end - range.start) return error.IndexRange;
                return self.aggregate_values[range.start + @as(u32, @intCast(position))];
            },
            .map_key, .map_value => |access| {
                // Entries are key and value side by side, in insertion order.
                const range = values[access.array].aggregate.elements;
                const position = values[access.index].integer;
                if (position < 0 or position >= (range.end - range.start) / 2) return error.IndexRange;
                return self.aggregate_values[range.start + 2 * @as(u32, @intCast(position)) + @intFromBool(instruction.op == .map_value)];
            },
            .map_lookup => |lookup| {
                if (fully_funded) unreachable; // Full funding also proves a map-free catalogue.
                const range = values[lookup.map].aggregate.elements;
                const offset = try keys.lookup(&self.key_work, &self.aggregate_values, self.aggregate_values[range.start..range.end], values[lookup.key], remaining);
                const start: u32 = if (offset) |position| range.start + @as(u32, @intCast(position)) else range.end;
                return .{ .aggregate = .{ .value_type = instruction.value_type.?, .elements = .{ .start = start, .end = start + @as(u32, if (offset == null) 0 else 1) } } };
            },
            .enumeration => |index| {
                assert(instruction.value_type != null);
                assert(catalogue.caseAt(instruction.value_type.?, index, program.definitions, program.cases) != null);
                return .{ .enumeration = .{ .value_type = instruction.value_type.?, .index = index } };
            },
            .character => |code| {
                assert(characterCode(instruction.value_type.?, code));
                return .{ .enumeration = .{ .value_type = instruction.value_type.?, .index = code } };
            },
            .text => |t| return try self.textStep(t, instruction.value_type.?, program, values, remaining),
            .begin => try self.journal.begin(),
            .commit => try self.journal.commit(),
            .abort => try self.journal.abort(),
            .load_cell => |cell| return .{ .integer = try self.journal.read(cell) },
            .store_cell => |store| try self.journal.write(store.cell, values[store.value].integer),
            .require => |operand| if (!values[operand].boolean) {
                return error.RequirementFailed;
            },
            .enqueue => |intent| try self.journal.enqueue(.{ .kind = intent.kind, .argument = values[intent.argument].integer }),
        }
        return null;
    }

    // Structured concurrency (RFC-0082): the VM's scheduler, rules S1 to S6 in this machine's
    // own form. Free slots are a stack, the ready queue a ring with a first index and a count,
    // the timers a heap of slots keyed by their task's (wake, order), and held starts a ring
    // whose committed prefix waits for its turns.

    fn resetScheduler(self: *Machine) void {
        const s = &self.scheduler;
        assert(types.Scheduler.validRate(self.control.tick_rate));
        s.spare_count = 0;
        s.high = 0;
        s.live = 0;
        s.ready_first = 0;
        s.ready_count = 0;
        s.heap_count = 0;
        s.held_first = 0;
        s.held_committed = 0;
        s.held_count = 0;
        s.held_mark_count = 0;
        s.sequence_count = 0;
        s.frame_end = 0;
        s.value_end = 0;
        s.frames_used = 0;
        s.values_used = 0;
        s.parameters_used = 0;
        s.first_saved = call_frames.no_task;
        s.last_saved = call_frames.no_task;
        s.now = 0;
        s.rate = self.control.tick_rate;
        s.sequence = 0;
        s.order = 0;
        s.switches = 0;
        s.created = 0;
        s.completed = 0;
        s.waiting_count = 0;
        s.canceled = 0;
        s.requests = call_frames.no_task;
        s.just_canceled = false;
        s.current = call_frames.no_task;
        s.just_exited = false;
    }

    pub fn schedulerRecord(self: *const Machine) types.Scheduler {
        const s = &self.scheduler;
        return .{ .tick_rate = s.rate, .tick = s.now, .created = s.created, .completed = s.completed, .canceled = s.canceled, .switches = s.switches, .waiting = s.waiting[0..s.waiting_count] };
    }

    fn takeSlot(self: *Machine) ?u32 {
        const s = &self.scheduler;
        if (s.live == s.tasks.len) return null;
        const slot = if (s.spare_count != 0) spare: {
            s.spare_count -= 1;
            break :spare s.spare[s.spare_count];
        } else fresh: {
            s.high += 1;
            break :fresh s.high - 1;
        };
        s.live += 1;
        s.tasks[slot] = .{};
        return slot;
    }

    fn dropSlot(self: *Machine, slot: u32) void {
        const s = &self.scheduler;
        assert(s.tasks[slot].phase != .free and s.live > 0);
        self.forgetSequence(s.tasks[slot].sequence);
        s.tasks[slot].phase = .free;
        s.spare[s.spare_count] = slot;
        s.spare_count += 1;
        s.live -= 1;
    }

    /// `spawn` with `closure`: one unit for the creation, a slot, and a handle instance with
    /// the next sequence, active and without a result.
    fn spawnTask(self: *Machine, program: Program, handle_type: types.Type, closure: types.Value, origin: u32, remaining: *u64) RuntimeError!u32 {
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        const slot = self.takeSlot() orelse return error.TaskLimit;
        const s = &self.scheduler;
        s.sequence += 1;
        const option = catalogue.definition(handle_type, program.definitions).?.task.option;
        var cells: [catalogue.task_cells]types.Value = undefined;
        cells[0] = .{ .integer = @backingInt(handle_type) };
        cells[catalogue.task_sequence] = .{ .integer = @intCast(s.sequence) };
        cells[catalogue.task_state] = .{ .integer = catalogue.task_active };
        cells[catalogue.task_result] = .{ .aggregate = .{ .value_type = option, .elements = .{ .start = 0, .end = 0 } } };
        const id = try self.source.allocate(&cells);
        s.tasks[slot] = .{ .sequence = s.sequence, .phase = .running, .handle = .{ .object = .{ .value_type = handle_type, .id = id } }, .closure = closure, .origin = origin };
        self.noteSequence(s.sequence, slot);
        return slot;
    }

    /// A start in a region waits for it to commit (Q5).
    fn holdStart(self: *Machine, slot: u32) RuntimeError!void {
        const s = &self.scheduler;
        s.held[try self.heldPlace()] = slot;
        s.tasks[slot].phase = .held;
    }

    /// A signal in a region is held with the starts, in program order (Q5, P3.2).
    fn holdSignal(self: *Machine, event: types.Value, value: types.Value) RuntimeError!void {
        const s = &self.scheduler;
        assert(event == .object);
        const place = try self.heldPlace();
        s.held[place] = call_frames.no_task;
        s.held_signals[place] = .{ .event = event, .value = value };
    }

    /// The ring index of the next action held by the innermost region.
    fn heldPlace(self: *Machine) RuntimeError!u32 {
        const s = &self.scheduler;
        const depth = self.control.effects.depth;
        assert(depth > 0);
        if (s.held_count == s.held.len) return error.SchedulerActionLimit;
        if (s.held_mark_count == 0 or s.held_marks[s.held_mark_count - 1].depth != depth) {
            s.held_marks[s.held_mark_count] = .{ .depth = depth, .count = s.held_count };
            s.held_mark_count += 1;
        }
        const place: u32 = @intCast((s.held_first + s.held_count) % s.held.len);
        s.held_count += 1;
        return place;
    }

    /// Commits the innermost region: effects first, then the starts it holds, which go to the
    /// region around it or, outside every region, wait their turns. True when that begins a
    /// drain: none waited before (a drain under way takes them in turn).
    fn commitRegion(self: *Machine) RuntimeError!bool {
        const s = &self.scheduler;
        const closing = self.control.effects.depth;
        try self.control.effects.commit();
        // RFC-0084, P4.4: what it notified goes to the region around it.
        if (self.live.on) live_machine.notifiedCommit(&self.live, closing);
        if (s.held_mark_count != 0 and s.held_marks[s.held_mark_count - 1].depth == closing) {
            const outer = closing - 1;
            if (outer == 0 or (s.held_mark_count > 1 and s.held_marks[s.held_mark_count - 2].depth == outer)) {
                s.held_mark_count -= 1;
            } else s.held_marks[s.held_mark_count - 1].depth = outer;
        }
        if (closing != 1) return false;
        assert(s.held_mark_count == 0);
        const begins = s.held_committed == 0;
        while (s.held_committed < s.held_count) : (s.held_committed += 1) {
            const slot = s.held[(s.held_first + s.held_committed) % s.held.len];
            if (slot == call_frames.no_task) continue; // A signal, carried out in its turn.
            assert(s.tasks[slot].phase == .held);
            s.tasks[slot].phase = .queued;
        }
        return begins and s.held_committed != 0;
    }

    /// Fails the innermost region: its effects and its starts are dropped. The starts' handles
    /// are forgotten by the rollback, and their slots and sequence numbers are free again.
    fn abortRegion(self: *Machine) void {
        const s = &self.scheduler;
        const closing = self.control.effects.depth;
        self.control.effects.abort();
        // RFC-0084, P4.4 (R2): what it notified is not notified.
        if (self.live.on) live_machine.notifiedAbort(&self.live, closing);
        if (s.held_mark_count == 0 or s.held_marks[s.held_mark_count - 1].depth != closing) return;
        s.held_mark_count -= 1;
        const keep = s.held_marks[s.held_mark_count].count;
        assert(keep >= s.held_committed and keep < s.held_count);
        while (s.held_count > keep) {
            s.held_count -= 1;
            const slot = s.held[(s.held_first + s.held_count) % s.held.len];
            if (slot == call_frames.no_task) continue; // A held signal goes with its region.
            assert(s.tasks[slot].phase == .held and s.tasks[slot].sequence == s.sequence);
            s.sequence -= 1;
            self.dropSlot(slot);
        }
    }

    /// The oldest committed start, now taking its turn, counted under the root instruction
    /// `origin` of the drain in failure traces. The committed signals ahead of it are carried
    /// out first, in order (P3.2). Null when nothing committed is left.
    fn nextStart(self: *Machine, origin: u32, remaining: *u64) RuntimeError!?u32 {
        const s = &self.scheduler;
        while (s.held_committed != 0) {
            const place = s.held_first;
            const slot = s.held[place];
            s.held_first = (s.held_first + 1) % @as(u32, @intCast(s.held.len));
            s.held_committed -= 1;
            s.held_count -= 1;
            if (slot == call_frames.no_task) {
                const signal = s.held_signals[place];
                try self.signalEvent(signal.event.object, signal.value, remaining);
                continue;
            }
            // RFC-0084, P4.7: a reaction cancelled before its turn never starts (N6).
            if (s.tasks[slot].phase == .settled) {
                assert(reactive(&s.tasks[slot]));
                self.dropSlot(slot);
                continue;
            }
            assert(s.tasks[slot].phase == .queued);
            s.tasks[slot].origin = origin;
            return slot;
        }
        return null;
    }

    /// The frame on top committed a region to depth 0: the first start it committed takes its
    /// turn on top of it, and the next ones as each leaves the stack (`taskLeft`).
    fn drainFromTop(self: *Machine, program: Program, root_pc: u32, remaining: *u64) RuntimeError!void {
        // RFC-0084, P4.4: in a live run the frame loop takes each turn (`drainTurn`), where a
        // reaction's start can run its guard and body; the drain delivers when it ends.
        if (self.live.reacts) {
            self.calls.frames[self.calls.depth - 1].drains = true;
            self.live.drain_due = true;
            return;
        }
        const slot = (try self.nextStart(root_pc, remaining)) orelse return;
        self.calls.frames[self.calls.depth - 1].drains = true;
        try self.startTask(program, slot, false);
    }

    /// Pushes the entry frame of the task in `slot`, which runs from the next turn of the frame
    /// loop. The switch is counted first, so the entry frame's mark includes it.
    fn startTask(self: *Machine, program: Program, slot: u32, handoff: bool) RuntimeError!void {
        assert(self.control.effects.depth == 0);
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        const closure = task.closure.callable;
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        s.switches += 1;
        const entry_at = self.calls.depth;
        if (self.pushCall(program, .{ .function = closure.function, .arguments = .{ .start = 0, .end = 0 }, .captures = closure.captures }, null)) |code| return switch (code) {
            .call_depth_limit => error.CallDepthLimit,
            .call_register_limit => error.CallRegisterLimit,
            else => unreachable,
        };
        const frame = &self.calls.frames[self.calls.depth - 1];
        frame.task = slot;
        frame.handoff = handoff;
        task.phase = .running;
        // P3.4: it runs above the task that started it, which runs again when this one leaves.
        task.below = s.current;
        task.entry_at = entry_at;
        s.current = slot;
        s.created += 1;
        self.control.calls[self.control.call_count] = .{ .function = closure.function, .pc = 0, .value = .{ .integer = @intCast(task.sequence) }, .kind = .start };
        self.control.call_count += 1;
    }

    /// The depth of the entry frame of the task on top of the stack.
    fn entryDepth(self: *const Machine) u32 {
        var depth = self.calls.depth;
        while (depth > 0) : (depth -= 1) {
            if (self.calls.frames[depth - 1].task != call_frames.no_task) return depth - 1;
        }
        unreachable; // Root code reaches no site.
    }

    /// Room at the end of the saved stores for `frames` frames and `values` registers. When there
    /// is none, the runs of the suspended tasks close up, in the order they lie.
    fn savedRoom(self: *Machine, frames: u32, values: u32) void {
        const s = &self.scheduler;
        if (s.saved.len - s.frame_end >= frames and s.saved_values.len - s.value_end >= values) return;
        var frame_end: u32 = 0;
        var value_end: u32 = 0;
        var slot = s.first_saved;
        while (slot != call_frames.no_task) {
            const task = &s.tasks[slot];
            if (task.first_frame != frame_end) std.mem.copyForwards(call_frames.VmSavedFrame, s.saved[frame_end .. frame_end + task.frames], s.saved[task.first_frame .. task.first_frame + task.frames]);
            if (task.first_value != value_end) std.mem.copyForwards(types.Value, s.saved_values[value_end .. value_end + task.values], s.saved_values[task.first_value .. task.first_value + task.values]);
            task.first_frame = frame_end;
            task.first_value = value_end;
            frame_end += task.frames;
            value_end += task.values;
            slot = task.next;
        }
        assert(frame_end == s.frames_used and value_end == s.values_used);
        s.frame_end = frame_end;
        s.value_end = value_end;
        assert(s.saved.len - s.frame_end >= frames and s.saved_values.len - s.value_end >= values);
    }

    /// What a task waits for (P3.2): the tick to wake at (`never` for none), an event's next
    /// signal, or the end of the task in `slot`, whose handle it awaits.
    const VmWait = union(enum) { sleep: u64, event: types.ObjectRef, task: struct { handle: types.ObjectRef, slot: u32 }, record: u32, frame_end: u32, guard };

    /// The task on top waits at the site its top frame stands at for `wait`. Its frames, from
    /// its entry frame up, go to the saved stores. Charges a unit per frame and per eight
    /// registers moved. Returns its task and whether a `spawn` handed off to it, for its creator.
    fn suspendTask(self: *Machine, program: Program, wait: VmWait, remaining: *u64) RuntimeError!struct { task: u32, handoff: bool } {
        assert(self.control.effects.depth == 0);
        const s = &self.scheduler;
        const entry = self.entryDepth();
        const first = self.calls.frames[entry].base;
        const slot = self.calls.frames[entry].task;
        const handoff = self.calls.frames[entry].handoff;
        const frames: u32 = self.calls.depth - entry;
        const values: u32 = self.calls.count - first;
        const cost = @as(u64, frames) + (@as(u64, values) + 7) / 8;
        if (remaining.* < cost) return error.WorkLimit;
        remaining.* -= cost;
        // The frames' parameters count with their registers against one limit.
        var parameters: u32 = 0;
        for (self.calls.frames[entry..self.calls.depth]) |frame| parameters += program.functions[frame.function].parameter_count;
        if (s.frames_used + frames > types.limits.saved_frames or @as(u64, s.values_used) + s.parameters_used + values + parameters > types.limits.saved_registers) return error.SuspendedFrameLimit;
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        const top = self.calls.frames[self.calls.depth - 1];
        const told: types.Value = switch (wait) {
            .sleep => |wake| if (wake == call_frames.never) .{ .boolean = false } else .{ .integer = @intCast(wake) },
            .event => |event| .{ .object = event },
            .task => |awaited| .{ .object = awaited.handle },
            // P3.3: how many arms the expression has.
            .record => |arms| .{ .integer = arms },
            // P3.4: how many tasks the frame keeps.
            .frame_end => |kept| .{ .integer = kept },
            // RFC-0084, P4.6: a guard, which no clock ends.
            .guard => .{ .boolean = false },
        };
        self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = told, .kind = .@"suspend" };
        self.control.call_count += 1;
        s.switches += 1;
        self.savedRoom(frames, values);
        const task = &s.tasks[slot];
        task.first_frame = s.frame_end;
        task.frames = frames;
        task.first_value = s.value_end;
        task.values = values;
        task.parameters = parameters;
        for (self.calls.frames[entry..self.calls.depth], s.saved[s.frame_end..][0..frames]) |frame, *saved| {
            assert(frame.catch_depth == 0 and frame.base >= first);
            saved.* = .{
                .function = frame.function,
                .base = frame.base - first,
                .pc = frame.pc,
                .arguments = frame.arguments,
                // An entry frame takes no arguments; a frame above it reads its caller's window.
                .caller_base = if (frame.caller_base) |base| base - first else null,
                .remaining_visits = frame.remaining_visits,
                .iteration_seed = frame.iteration_seed,
                .state_loop = frame.state_loop,
                .captures = frame.captures,
                .mark = frame.mark,
                .string_mark = frame.string_mark,
                .cell_mark = frame.cell_mark,
                .switches = frame.switches,
                .task = frame.task,
                .owned_first = frame.owned_first,
                .owned_last = frame.owned_last,
                .canceled_end = frame.canceled_end,
            };
        }
        @memcpy(s.saved_values[s.value_end..][0..values], self.calls.values[first..self.calls.count]);
        s.frame_end += frames;
        s.value_end += values;
        s.frames_used += frames;
        s.values_used += values;
        s.parameters_used += parameters;
        task.previous = s.last_saved;
        task.next = call_frames.no_task;
        if (s.last_saved == call_frames.no_task) s.first_saved = slot else s.tasks[s.last_saved].next = slot;
        s.last_saved = slot;
        task.phase = .waiting;
        task.wake = call_frames.never;
        task.after = call_frames.no_task;
        switch (wait) {
            .sleep => |wake| {
                task.waits = .sleep;
                task.wake = wake;
                if (wake != call_frames.never) {
                    s.order += 1;
                    task.order = s.order;
                    self.timerInsert(slot);
                }
            },
            .event => |event| {
                task.waits = .event;
                task.on = .{ .object = event };
                self.joinEvent(event, slot);
            },
            .task => |awaited| {
                task.waits = .task;
                task.on = .{ .object = awaited.handle };
                task.awaiting = awaited.slot;
                const target = &s.tasks[awaited.slot];
                task.before = target.awaiters_end;
                if (target.awaiters_end == call_frames.no_task) target.awaiters = slot else s.tasks[target.awaiters_end].after = slot;
                target.awaiters_end = slot;
            },
            // P3.3: until its arms are settled.
            .record => task.waits = .record,
            // P3.4: until the tasks its top frame keeps are settled.
            .frame_end => task.waits = .frame_end,
            // RFC-0084, P4.6: until a write of what its guard read notifies it; the live store
            // keeps those dependencies.
            .guard => task.waits = .guard,
        }
        // P3.4: the task below it on the stack runs again.
        assert(s.current == slot);
        s.current = task.below;
        task.below = call_frames.no_task;
        self.calls.depth = entry;
        self.calls.count = first;
        return .{ .task = slot, .handoff = handoff };
    }

    /// Puts a ready task back on the empty stack; its site yields `resume_value`. Charges a unit
    /// per frame and per eight registers moved.
    fn restoreTask(self: *Machine, program: Program, slot: u32, remaining: *u64) RuntimeError!void {
        assert(self.calls.depth == 0 and self.calls.count == 0 and self.control.effects.depth == 0);
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        assert(task.phase == .ready);
        const cost = @as(u64, task.frames) + (@as(u64, task.values) + 7) / 8;
        if (remaining.* < cost) return error.WorkLimit;
        remaining.* -= cost;
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        s.switches += 1;
        for (s.saved[task.first_frame..][0..task.frames], self.calls.frames[0..task.frames]) |saved, *frame| {
            frame.* = .{
                .function = saved.function,
                .base = saved.base,
                .pc = saved.pc,
                .arguments = saved.arguments,
                .caller_base = saved.caller_base,
                .remaining_visits = saved.remaining_visits,
                .iteration_seed = saved.iteration_seed,
                .state_loop = saved.state_loop,
                .captures = saved.captures,
                .mark = saved.mark,
                .string_mark = saved.string_mark,
                .cell_mark = saved.cell_mark,
                .switches = saved.switches,
                .task = saved.task,
                .owned_first = saved.owned_first,
                .owned_last = saved.owned_last,
                .canceled_end = saved.canceled_end,
            };
        }
        @memcpy(self.calls.values[0..task.values], s.saved_values[task.first_value..][0..task.values]);
        self.calls.depth = task.frames;
        self.calls.count = task.values;
        s.frames_used -= task.frames;
        s.values_used -= task.values;
        s.parameters_used -= task.parameters;
        if (task.previous == call_frames.no_task) s.first_saved = task.next else s.tasks[task.previous].next = task.next;
        if (task.next == call_frames.no_task) s.last_saved = task.previous else s.tasks[task.next].previous = task.previous;
        task.previous = call_frames.no_task;
        task.next = call_frames.no_task;
        // The site completes with the value and the frame goes on after it. A frame waiting at its
        // end (P3.4) goes on ending, whether or not its task was asked to cancel meanwhile.
        assert(s.current == call_frames.no_task);
        s.current = slot;
        task.below = call_frames.no_task;
        task.entry_at = 0;
        // P3.5: depths compare within the run of the task on the stack, which begins here.
        self.control.reclaim_depth = 0;
        const top = &self.calls.frames[self.calls.depth - 1];
        // RFC-0084, P4.6: a task woken at an `Await` stands at the site again and evaluates its
        // guard there: the site's register is not written, and the frame does not move on.
        const again = task.waits == .guard and !task.cancel;
        if (task.waits == .frame_end or again) {
            self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = task.resume_value, .kind = .@"resume" };
            self.control.call_count += 1;
        } else if (task.cancel) {
            // P3.3: a task asked to cancel only yields cancelled; its check is next.
            self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = .{ .integer = @intCast(task.sequence) }, .kind = .resume_canceled };
            self.control.call_count += 1;
            s.just_canceled = true;
        } else if (task.waits == .record and task.record.exited) {
            // P3.6: an expression an arm's exit abandoned yields that pending exit to its check;
            // the site's register is not written.
            const pending = s.tasks[task.record.winner].result;
            self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = pending, .kind = .resume_exited };
            self.control.call_count += 1;
            s.just_exited = true;
            s.exit_value = pending;
        } else {
            // An expression yields its winner's result, or the tuple of its results built now.
            var value = task.resume_value;
            if (task.waits == .record) value = switch (task.record.kind) {
                .race, .rush => s.tasks[task.record.winner].result,
                .sync => try self.syncTuple(program, &task.record, top.function, remaining),
            };
            self.calls.values[top.base + top.pc] = value;
            self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = value, .kind = .@"resume" };
            self.control.call_count += 1;
        }
        // An expression's arms end with it.
        if (task.waits == .record) self.releaseArms(&task.record);
        if (task.waits != .frame_end and !again) top.pc += 1;
        task.phase = .running;
    }

    /// The task in `slot` settles with `result`: its handle is marked completed with
    /// `option{result}`, one member, and its slot is free again.
    fn settleTask(self: *Machine, program: Program, slot: u32, function: u32, result: types.Value) RuntimeError!void {
        assert(self.control.effects.depth == 0 and self.source.depth == 1);
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        assert(task.phase == .running);
        if (self.aggregate_count == self.aggregate_values.len) return error.AggregateLimit;
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        // P3.4: the task below it on the stack runs again.
        assert(s.current == slot);
        s.current = task.below;
        const handle = task.handle.object;
        const option = catalogue.definition(handle.value_type, program.definitions).?.task.option;
        const at: u32 = @intCast(self.aggregate_count);
        self.aggregate_values[at] = result;
        self.aggregate_count += 1;
        // The root region holds no record: what the scheduler writes is never rolled back.
        self.source.write(handle.id + catalogue.task_state, .{ .integer = catalogue.task_completed }, false) catch unreachable;
        self.source.write(handle.id + catalogue.task_result, .{ .aggregate = .{ .value_type = option, .elements = .{ .start = at, .end = at + 1 } } }, false) catch unreachable;
        const body = program.functions[function].body;
        self.control.calls[self.control.call_count] = .{ .function = function, .pc = body.end - body.start, .value = result, .kind = .settle };
        self.control.call_count += 1;
        s.completed += 1;
        // Those awaiting it go to the ready queue with the result, first come first (P3.2).
        var awaiter = task.awaiters;
        while (awaiter != call_frames.no_task) {
            const after = s.tasks[awaiter].after;
            assert(s.tasks[awaiter].phase == .waiting and s.tasks[awaiter].waits == .task);
            self.makeReady(awaiter, result);
            awaiter = after;
        }
        self.dropSlot(slot);
    }

    /// Appends the task in `slot` to the ready queue, to resume with `value`.
    fn makeReady(self: *Machine, slot: u32, value: types.Value) void {
        const s = &self.scheduler;
        assert(s.ready_count < s.ready.len);
        const task = &s.tasks[slot];
        task.phase = .ready;
        task.resume_value = value;
        task.after = call_frames.no_task;
        task.before = call_frames.no_task;
        s.ready[(s.ready_first + s.ready_count) % s.ready.len] = slot;
        s.ready_count += 1;
    }

    /// `event(T){}`: an event no task waits on yet (P3.2).
    fn newEvent(self: *Machine, program: Program, event_type: types.Type) RuntimeError!types.Value {
        // P3.9: a sticky event's latch is clear, and a subscribable event has no subscription.
        var cells: [catalogue.subscribable_cells]types.Value = undefined;
        const kind = catalogue.eventShape(event_type, program.definitions).?.kind;
        cells[0] = .{ .integer = @backingInt(event_type) };
        cells[catalogue.event_waiting] = .{ .integer = 0 };
        cells[catalogue.event_first] = .{ .integer = 0 };
        cells[catalogue.event_last] = .{ .integer = 0 };
        switch (kind) {
            .plain => {},
            .sticky => {
                cells[catalogue.sticky_latch] = .{ .integer = 0 };
                cells[catalogue.sticky_value] = .{ .integer = 0 };
            },
            .subscribable => {
                cells[catalogue.subscription_first] = .{ .boolean = false };
                cells[catalogue.subscription_last] = .{ .boolean = false };
                cells[catalogue.subscription_count] = .{ .integer = 0 };
            },
        }
        const id = try self.source.allocate(cells[0..catalogue.eventCells(kind)]);
        return .{ .object = .{ .value_type = event_type, .id = id } };
    }

    /// P3.9: what a sticky event that was signalled holds; null for one that was not, and for
    /// any other instance.
    fn stickyHeld(self: *const Machine, program: Program, instance: types.ObjectRef) ?types.Value {
        const shape = catalogue.eventShape(instance.value_type, program.definitions) orelse return null;
        if (shape.kind != .sticky or self.eventCell(instance, catalogue.sticky_latch) == 0) return null;
        return self.source.read(instance.id + catalogue.sticky_value) catch unreachable;
    }

    /// P3.9 (C107): `E.Subscribe(F)`, a `cancelable` at the end of the event's list. Program
    /// state: a region journals these writes, and one that fails forgets the instance.
    fn subscribe(self: *Machine, event: types.ObjectRef, callback: types.Value, cancelable_type: types.Type) RuntimeError!types.Value {
        const number = try self.source.read(event.id + catalogue.subscription_count);
        const last = try self.source.read(event.id + catalogue.subscription_last);
        var cells: [catalogue.cancelable_cells]types.Value = undefined;
        cells[0] = .{ .integer = @backingInt(cancelable_type) };
        cells[catalogue.cancelable_state] = .{ .integer = catalogue.cancelable_active };
        cells[catalogue.cancelable_callback] = callback;
        cells[catalogue.cancelable_event] = .{ .object = event };
        cells[catalogue.cancelable_before] = last;
        cells[catalogue.cancelable_after] = .{ .boolean = false };
        cells[catalogue.cancelable_number] = number;
        const created: types.Value = .{ .object = .{ .value_type = cancelable_type, .id = try self.source.allocate(&cells) } };
        try self.source.write(if (last == .object) last.object.id + catalogue.cancelable_after else event.id + catalogue.subscription_first, created, false);
        try self.source.write(event.id + catalogue.subscription_last, created, false);
        try self.source.write(event.id + catalogue.subscription_count, .{ .integer = number.integer + 1 }, false);
        return created;
    }

    /// P3.9 (C111, C112): `C.Cancel()`. An active subscription leaves its event's list but keeps
    /// its link to the one after it; any other is left as it is.
    fn unsubscribe(self: *Machine, subscription: types.ObjectRef) RuntimeError!void {
        if ((try self.source.read(subscription.id + catalogue.cancelable_state)).integer != catalogue.cancelable_active) return;
        const event = (try self.source.read(subscription.id + catalogue.cancelable_event)).object;
        const before = try self.source.read(subscription.id + catalogue.cancelable_before);
        const after = try self.source.read(subscription.id + catalogue.cancelable_after);
        try self.source.write(if (before == .object) before.object.id + catalogue.cancelable_after else event.id + catalogue.subscription_first, after, false);
        try self.source.write(if (after == .object) after.object.id + catalogue.cancelable_before else event.id + catalogue.subscription_last, before, false);
        try self.source.write(subscription.id + catalogue.cancelable_state, .{ .integer = catalogue.cancelable_canceled }, false);
    }

    /// P3.9 (C109, C112, C114): from `from`, a subscription or `false`, along the list, the first
    /// active subscription numbered below `limit`, for a unit of fuel per subscription reached.
    fn nextSubscription(self: *Machine, from: types.Value, limit: i64, remaining: *u64) RuntimeError!?types.ObjectRef {
        var at = from;
        while (at == .object) {
            if ((try self.source.read(at.object.id + catalogue.cancelable_number)).integer >= limit) return null;
            if (remaining.* == 0) return error.WorkLimit;
            remaining.* -= 1;
            if ((try self.source.read(at.object.id + catalogue.cancelable_state)).integer == catalogue.cancelable_active) return at.object;
            at = try self.source.read(at.object.id + catalogue.cancelable_after);
        }
        return null;
    }

    /// P3.9: the next callback of the `event_notify` the frame stands at, from `from` on, pushed
    /// on top with the node's argument; `done` when there is none.
    fn notifyFrom(self: *Machine, program: Program, frame: *call_frames.VmFrame, n: types.Invoke, from: types.Value, remaining: *u64) union(enum) { pushed, done, failed: types.Diagnostic.Code } {
        const found = self.nextSubscription(from, frame.notify_limit, remaining) catch |err| return .{ .failed = runtimeCode(err) };
        const subscription = found orelse return .done;
        frame.notify_cursor = subscription;
        const callback = (self.source.read(subscription.id + catalogue.cancelable_callback) catch unreachable).callable;
        if (self.pushCall(program, .{ .function = callback.function, .arguments = n.arguments, .captures = callback.captures }, frame.base)) |code| return .{ .failed = code };
        return .pushed;
    }

    /// An event's hidden cells, which only the scheduler writes, at region depth 0.
    fn eventCell(self: *const Machine, event: types.ObjectRef, cell: u32) i64 {
        return (self.source.read(event.id + cell) catch unreachable).integer;
    }
    fn setEventCell(self: *Machine, event: types.ObjectRef, cell: u32, value: i64) void {
        assert(self.control.effects.depth == 0);
        self.source.write(event.id + cell, .{ .integer = value }, false) catch unreachable;
    }

    /// The task in `slot` waits last on `event`, whose cells count its waiters and name the
    /// first and the last by sequence.
    fn joinEvent(self: *Machine, event: types.ObjectRef, slot: u32) void {
        const s = &self.scheduler;
        const count = self.eventCell(event, catalogue.event_waiting);
        const sequence: i64 = @intCast(s.tasks[slot].sequence);
        if (count == 0) self.setEventCell(event, catalogue.event_first, sequence) else {
            const last = self.slotOf(@intCast(self.eventCell(event, catalogue.event_last))).?;
            s.tasks[last].after = slot;
            s.tasks[slot].before = last;
        }
        self.setEventCell(event, catalogue.event_last, sequence);
        self.setEventCell(event, catalogue.event_waiting, count + 1);
    }

    /// `Signal` outside every region (Q1): the tasks waiting on the event now go to the ready
    /// queue in the order they began to wait, each with `value`, for a unit of fuel each. With
    /// no waiter the value is lost (14:1490).
    fn signalEvent(self: *Machine, event: types.ObjectRef, value: types.Value, remaining: *u64) RuntimeError!void {
        const count: u64 = @intCast(self.eventCell(event, catalogue.event_waiting));
        if (remaining.* < count) return error.WorkLimit;
        remaining.* -= count;
        // P3.9 (C104): a sticky event keeps the value, which every later `Await` gets at once.
        if (catalogue.eventShape(event.value_type, self.event_definitions).?.kind == .sticky) {
            self.setEventCell(event, catalogue.sticky_latch, 1);
            self.source.write(event.id + catalogue.sticky_value, value, false) catch unreachable;
        }
        if (count == 0) return;
        var slot = self.slotOf(@intCast(self.eventCell(event, catalogue.event_first))).?;
        var woken: u64 = 0;
        while (slot != call_frames.no_task) : (woken += 1) {
            const after = self.scheduler.tasks[slot].after;
            assert(self.scheduler.tasks[slot].phase == .waiting and self.scheduler.tasks[slot].waits == .event);
            self.makeReady(slot, value);
            slot = after;
        }
        assert(woken == count);
        self.setEventCell(event, catalogue.event_waiting, 0);
        self.setEventCell(event, catalogue.event_first, 0);
        self.setEventCell(event, catalogue.event_last, 0);
    }

    /// The table from sequence to slot (P3.2): sequences arrive in ascending order; a task that
    /// ends leaves a gap, trailing gaps are dropped, and a full table closes up its gaps.
    fn noteSequence(self: *Machine, sequence: u64, slot: u32) void {
        const s = &self.scheduler;
        if (s.sequence_count == s.sequences.len) {
            var kept: u32 = 0;
            for (s.sequences[0..s.sequence_count]) |entry| {
                if (entry.slot == call_frames.no_task) continue;
                s.sequences[kept] = entry;
                kept += 1;
            }
            assert(kept < s.tasks.len);
            s.sequence_count = kept;
        }
        assert(s.sequence_count == 0 or s.sequences[s.sequence_count - 1].sequence < sequence);
        s.sequences[s.sequence_count] = .{ .sequence = sequence, .slot = slot };
        s.sequence_count += 1;
    }
    fn sequenceIndex(self: *const Machine, sequence: u64) ?usize {
        const s = &self.scheduler;
        const entries = s.sequences[0..s.sequence_count];
        const at = std.sort.lowerBound(call_frames.VmSequenceSlot, entries, sequence, struct {
            fn order(wanted: u64, entry: call_frames.VmSequenceSlot) std.math.Order {
                return std.math.order(wanted, entry.sequence);
            }
        }.order);
        if (at == entries.len or entries[at].sequence != sequence) return null;
        return at;
    }
    fn slotOf(self: *const Machine, sequence: u64) ?u32 {
        const at = self.sequenceIndex(sequence) orelse return null;
        const slot = self.scheduler.sequences[at].slot;
        return if (slot == call_frames.no_task) null else slot;
    }
    fn forgetSequence(self: *Machine, sequence: u64) void {
        const s = &self.scheduler;
        const at = self.sequenceIndex(sequence).?;
        assert(s.sequences[at].slot != call_frames.no_task);
        s.sequences[at].slot = call_frames.no_task;
        while (s.sequence_count != 0 and s.sequences[s.sequence_count - 1].slot == call_frames.no_task) s.sequence_count -= 1;
    }

    /// What a task that left the stack owes the frame below it: the handle, when a `spawn` there
    /// handed off to it; the turn of the start phase of the expression of `owner`, when it is an
    /// arm handed off to by that phase (P3.3).
    const VmLeave = struct { handoff: bool, handle: types.Value, owner: u32 };
    /// Where the frame loop goes after a task left the stack.
    const VmLeft = union(enum) { going, empty, failed: types.Diagnostic };

    /// What the task in `slot`, which has just left the stack, owes the frame below, if any.
    fn leaveOf(self: *const Machine, slot: u32, handoff: bool) VmLeave {
        const task = &self.scheduler.tasks[slot];
        return .{ .handoff = handoff, .handle = if (task.kind != .arm) task.handle else .{ .boolean = false }, .owner = if (task.kind == .arm and self.calls.depth != 0) task.owner else call_frames.no_task };
    }

    /// A task left the stack: the frame below gets the handle when a `spawn` there handed off to
    /// it; the next arm starts, or the expression yields or waits, when it was an arm; and if that
    /// frame drains committed starts, the next one goes. A task whose start phase ended with it
    /// waiting leaves in turn, and so on down (`empty` when the stack is). `span` is where a
    /// failure other than the start phase's falls.
    fn taskLeft(self: *Machine, program: Program, first: VmLeave, span: types.Span, root_pc: u32, remaining: *u64) VmLeft {
        var leave = first;
        while (true) {
            assert(self.calls.depth != 0);
            const below = &self.calls.frames[self.calls.depth - 1];
            if (leave.handoff) {
                if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
                self.control.calls[self.control.call_count] = .{ .function = below.function, .pc = below.pc, .value = leave.handle };
                self.control.call_count += 1;
                self.calls.values[below.base + below.pc] = leave.handle;
                below.pc += 1;
            }
            if (leave.owner != call_frames.no_task) {
                switch (self.startPhase(program, leave.owner, remaining)) {
                    .started, .completed => return .going,
                    .waits => |next| {
                        if (self.calls.depth == 0) return .empty;
                        leave = next;
                        continue;
                    },
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                }
            }
            if (!below.drains) return .going;
            // RFC-0084, P4.4: the frame loop takes the next turn of a live run's drain.
            if (self.live.reacts) {
                self.live.drain_due = true;
                return .going;
            }
            const slot = (self.nextStart(root_pc, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } }) orelse {
                below.drains = false;
                return .going;
            };
            self.startTask(program, slot, false) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
            return .going;
        }
    }

    /// The task on top waits at its site for `wait`; what it owes the frame below follows.
    fn waitAt(self: *Machine, program: Program, wait: VmWait, span: types.Span, root_pc: u32, remaining: *u64) VmLeft {
        const left = self.suspendTask(program, wait, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        if (self.calls.depth == 0) return .empty;
        return self.taskLeft(program, self.leaveOf(left.task, left.handoff), span, root_pc, remaining);
    }

    // P3.3: `Sync` and `Race`, cancellation requests and unwinding.

    /// The next arm of `owner`'s expression starts, its frame on top at the site: a unit for the
    /// creation, a slot, the next sequence, and its entry frame handed off to on top.
    fn startArm(self: *Machine, program: Program, owner: u32, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        const record = &s.tasks[owner].record;
        assert(record.starting and record.started < record.arms and record.winner == call_frames.no_task);
        const top = self.calls.frames[self.calls.depth - 1];
        assert(top.pc == record.pc);
        const arms = program.function_nodes[program.functions[top.function].body.start + record.pc].node.kind.structured.arms;
        const closure = self.calls.values[top.base + program.function_arguments[arms.start + record.started]];
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        const slot = self.takeSlot() orelse return error.TaskLimit;
        s.sequence += 1;
        s.tasks[slot] = .{ .sequence = s.sequence, .phase = .running, .closure = closure, .origin = s.tasks[owner].origin, .kind = .arm, .owner = owner };
        self.noteSequence(s.sequence, slot);
        if (record.last == call_frames.no_task) record.first = slot else s.tasks[record.last].sibling = slot;
        record.last = slot;
        record.started += 1;
        try self.startTask(program, slot, false);
    }

    /// Whether an expression is over: a `Sync` with every arm completed, a won `Race` with every
    /// started arm settled. One asked to cancel is never: it yields cancelled.
    fn recordDone(record: *const call_frames.VmRecord) bool {
        if (record.canceling) return false;
        // P3.6: one abandoned by an arm's exit, when its started arms are settled.
        if (record.exited) return record.settled == record.started;
        return switch (record.kind) {
            .sync => record.settled == record.arms,
            // A resolved `Rush` keeps its settled arms only (P3.4).
            .race, .rush => record.winner != call_frames.no_task and record.settled == record.started,
        };
    }

    /// A `Sync`'s value: the tuple of its arms' results in order, an aggregate charged as one.
    fn syncTuple(self: *Machine, program: Program, record: *const call_frames.VmRecord, function: u32, remaining: *u64) RuntimeError!types.Value {
        const s = &self.scheduler;
        assert(record.kind == .sync and record.settled == record.arms);
        if (remaining.* < record.arms) return error.WorkLimit;
        remaining.* -= record.arms;
        if (record.arms > self.aggregate_values.len - self.aggregate_count) return error.AggregateLimit;
        const start: u32 = @intCast(self.aggregate_count);
        var arm = record.first;
        while (arm != call_frames.no_task) : (arm = s.tasks[arm].sibling) {
            assert(s.tasks[arm].phase == .settled and s.tasks[arm].done);
            self.aggregate_values[self.aggregate_count] = s.tasks[arm].result;
            self.aggregate_count += 1;
        }
        const node = program.function_nodes[program.functions[function].body.start + record.pc].node;
        return .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = start, .end = @intCast(self.aggregate_count) } } };
    }

    /// An expression is over: its arms' slots are free, in order.
    fn releaseArms(self: *Machine, record: *call_frames.VmRecord) void {
        var arm = record.first;
        while (arm != call_frames.no_task) {
            const next = self.scheduler.tasks[arm].sibling;
            assert(self.scheduler.tasks[arm].phase == .settled);
            self.dropSlot(arm);
            arm = next;
        }
        record.first = call_frames.no_task;
        record.last = call_frames.no_task;
    }

    /// `owner`'s expression goes on with its frame on top: the next arm starts while one is left
    /// and the expression is not resolved; then it yields at once, or `owner` waits for its arms.
    const VmPhase = union(enum) { started, completed, waits: VmLeave, failed: types.Diagnostic };
    fn startPhase(self: *Machine, program: Program, owner: u32, remaining: *u64) VmPhase {
        const s = &self.scheduler;
        const record = &s.tasks[owner].record;
        const top = &self.calls.frames[self.calls.depth - 1];
        assert(top.pc == record.pc and record.starting);
        const span = siteSpan(program, top.function, record.pc);
        // P3.7: an arm asked `owner` to cancel while it ran: no arm starts after it.
        if (s.tasks[owner].cancel) return self.startCanceled(program, owner, span, remaining);
        if (record.started < record.arms and record.winner == call_frames.no_task) {
            self.startArm(program, owner, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
            return .started;
        }
        record.starting = false;
        if (recordDone(record) and record.exited) {
            // P3.6: an arm's pending exit, which the site yields to its check at once.
            const pending = s.tasks[record.winner].result;
            self.releaseArms(record);
            if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
            self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = pending, .kind = .resume_exited };
            self.control.call_count += 1;
            s.just_exited = true;
            s.exit_value = pending;
            top.pc += 1;
            return .completed;
        }
        if (recordDone(record)) {
            const value: types.Value = switch (record.kind) {
                .race, .rush => s.tasks[record.winner].result,
                .sync => self.syncTuple(program, record, top.function, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } },
            };
            self.releaseArms(record);
            if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
            self.control.calls[self.control.call_count] = .{ .function = top.function, .pc = top.pc, .value = value };
            self.control.call_count += 1;
            self.calls.values[top.base + top.pc] = value;
            top.pc += 1;
            return .completed;
        }
        const left = self.suspendTask(program, .{ .record = record.arms }, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        return .{ .waits = self.leaveOf(left.task, left.handoff) };
    }

    /// The start phase of `owner`'s expression ends because `owner` was asked to cancel (P3.7):
    /// the expression is cancelled as a request to a task waiting on it would, and the site yields
    /// cancelled now when every started arm is settled, or after `owner` waits for them. A resolved
    /// `Rush` has handed its losers to the frame already.
    fn startCanceled(self: *Machine, program: Program, owner: u32, span: types.Span, remaining: *u64) VmPhase {
        const s = &self.scheduler;
        const record = &s.tasks[owner].record;
        record.starting = false;
        assert(!record.canceling and s.requests == call_frames.no_task);
        record.canceling = true;
        self.pushArms(record);
        self.makeRequests(remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        if (record.settled == record.started) {
            self.releaseArms(record);
            if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
            const top = &self.calls.frames[self.calls.depth - 1];
            const yielded = self.canceledAtSite(top, record.pc);
            assert(yielded);
            return .completed;
        }
        const left = self.suspendTask(program, .{ .record = record.arms }, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        return .{ .waits = self.leaveOf(left.task, left.handoff) };
    }

    /// The arm in `slot`, whose entry frame of `function` ended, settled: completed with `result`
    /// or cancelled. Its expression counts it; a `Race`'s first completion wins and the other
    /// started arms are asked to cancel in order; a task waiting on an expression now over is
    /// ready.
    fn armSettled(self: *Machine, program: Program, slot: u32, function: u32, result: types.Value, canceled: bool, remaining: *u64) RuntimeError!void {
        assert(self.control.effects.depth == 0);
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        assert(task.kind == .arm and task.phase == .running);
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        // P3.4: the task below it on the stack runs again.
        assert(s.current == slot);
        s.current = task.below;
        const body = program.functions[function].body;
        self.control.calls[self.control.call_count] = .{ .function = function, .pc = body.end - body.start, .value = if (canceled) .{ .boolean = false } else result, .kind = .settle };
        self.control.call_count += 1;
        task.phase = .settled;
        task.done = !canceled;
        task.result = result;
        if (canceled) s.canceled += 1 else s.completed += 1;
        const owner = task.owner;
        const record = &s.tasks[owner].record;
        record.settled += 1;
        // P3.6: an arm that ended with a pending exit abandons its expression if nothing has
        // resolved it: the other started arms are asked to cancel, in order, and no arm starts.
        const exited = !canceled and task.exited;
        if (exited and record.winner == call_frames.no_task and !record.canceling) {
            record.winner = slot;
            record.exited = true;
            self.pushArms(record);
            try self.makeRequests(remaining);
        }
        if (!canceled and !exited and record.kind == .race and record.winner == call_frames.no_task and !record.canceling) {
            record.winner = slot;
            self.pushArms(record);
            try self.makeRequests(remaining);
        }
        // P3.4: a `Rush`'s first completion resolves it; its other started arms go on, kept by
        // the frame that runs it.
        if (!canceled and !exited and record.kind == .rush and record.winner == call_frames.no_task and !record.canceling) {
            record.winner = slot;
            self.adoptLosers(owner);
        }
        // P3.7: an arm cancelled from outside its expression (it awaited a cancelled task) asks
        // `owner` to cancel, unless the expression is cancelling or resolved, which take it for a
        // loser.
        if (canceled and record.winner == call_frames.no_task and !record.canceling) {
            assert(s.requests == call_frames.no_task);
            s.tasks[owner].request = call_frames.no_task;
            s.requests = owner;
            try self.makeRequests(remaining);
        }
        const parked = s.tasks[owner].phase == .waiting and s.tasks[owner].waits == .record;
        if (parked and record.settled == record.started and (record.canceling or recordDone(record))) self.makeReady(owner, .{ .boolean = false });
    }

    /// The started arms of `record` not yet settled go on top of the requests, the first on top.
    fn pushArms(self: *Machine, record: *const call_frames.VmRecord) void {
        const s = &self.scheduler;
        var head: u32 = call_frames.no_task;
        var tail: u32 = call_frames.no_task;
        var arm = record.first;
        while (arm != call_frames.no_task) : (arm = s.tasks[arm].sibling) {
            if (s.tasks[arm].phase == .settled) continue;
            if (tail == call_frames.no_task) head = arm else s.tasks[tail].request = arm;
            tail = arm;
        }
        if (tail == call_frames.no_task) return;
        s.tasks[tail].request = s.requests;
        s.requests = head;
    }

    /// The cancellation requests waiting, a unit each, the last pushed first: depth first in arm
    /// order, in a loop. A settled or flagged task takes no more. A sleeper or an awaiter leaves
    /// its wait and is ready to yield cancelled; a task waiting on an expression marks it and
    /// its arms are asked next. In P3.3 only a ready or waiting task is ever asked.
    fn makeRequests(self: *Machine, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        while (s.requests != call_frames.no_task) {
            const slot = s.requests;
            const task = &s.tasks[slot];
            s.requests = task.request;
            task.request = call_frames.no_task;
            if (remaining.* == 0) {
                s.requests = call_frames.no_task;
                return error.WorkLimit;
            }
            remaining.* -= 1;
            if (task.phase == .settled or task.cancel) continue;
            task.cancel = true;
            switch (task.phase) {
                .ready => {},
                .waiting => switch (task.waits) {
                    .sleep => {
                        if (task.wake != call_frames.never) self.timerRemove(slot);
                        self.makeReady(slot, .{ .boolean = false });
                    },
                    .event => {
                        self.leaveEvent(task.on.object, slot);
                        self.makeReady(slot, .{ .boolean = false });
                    },
                    .task => {
                        self.leaveAwaiters(slot);
                        self.makeReady(slot, .{ .boolean = false });
                    },
                    .record => {
                        task.record.canceling = true;
                        self.pushArms(&task.record);
                    },
                    // P3.4: its frame is already ending and has asked its own tasks; the flag
                    // waits for its next site.
                    .frame_end => {},
                    // RFC-0084, P4.7: only a `Cancel` of a reaction's handle asks a reaction, and
                    // `cancelTask` does that itself. P4.6: a task at an `Await`
                    // stops waiting, its entries let go, a unit each, to yield cancelled.
                    .guard => {
                        assert(!reactive(task));
                        live_machine.prepare(&self.live, &self.source);
                        live_machine.watchRelease(&self.live, &self.source, slot, remaining) catch {
                            s.requests = call_frames.no_task;
                            return error.WorkLimit;
                        };
                        self.makeReady(slot, .{ .boolean = false });
                    },
                },
                // P3.7: a task on the stack, or a committed start waiting for its turn, finds the
                // flag at its next site. Requests are made at depth 0, where no region holds a
                // start.
                .running, .queued => {},
                .free, .held, .settled => unreachable,
            }
        }
    }

    /// `T.Cancel()` (P3.7): a request to the handle's task, a unit, also when it has settled and
    /// its slot is gone.
    fn cancelTask(self: *Machine, handle: types.ObjectRef, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        assert(s.requests == call_frames.no_task and self.source.depth == 1);
        const state = (self.source.read(handle.id + catalogue.task_state) catch unreachable).integer;
        if (state != catalogue.task_active) {
            if (remaining.* == 0) return error.WorkLimit;
            remaining.* -= 1;
            return;
        }
        const sequence: u64 = @intCast((self.source.read(handle.id + catalogue.task_sequence) catch unreachable).integer);
        const slot = self.slotOf(sequence).?;
        // RFC-0084, P4.7: a request to a reaction does what N6 says.
        if (reactive(&s.tasks[slot])) return self.cancelReaction(slot, remaining);
        s.tasks[slot].request = call_frames.no_task;
        s.requests = slot;
        try self.makeRequests(remaining);
    }

    /// RFC-0084, P4.7 (N6): a request to the reaction in `slot`, a unit. Waiting on its guard it
    /// settles cancelled now, its entries let go, a unit each; queued for its turn in a drain it
    /// settles cancelled now and its start does nothing; firing (asked by a task its body handed
    /// off to) it is flagged, and its body's end decides. Only `T.Cancel()` reaches a reaction.
    fn cancelReaction(self: *Machine, slot: u32, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        const task = &s.tasks[slot];
        if (task.cancel) return;
        switch (task.phase) {
            .running => {
                task.cancel = true;
                return;
            },
            .waiting => {
                assert(task.waits == .guard);
                live_machine.prepare(&self.live, &self.source);
                live_machine.watchRelease(&self.live, &self.source, slot, remaining) catch return error.WorkLimit;
            },
            // It never starts; made and cancelled, it counts as created (C73).
            .queued => s.created += 1,
            .free, .held, .ready, .settled => unreachable,
        }
        try self.reactionCanceled(slot, remaining);
    }

    /// The reaction in `slot` settles cancelled (N6): its handle says so and holds no result,
    /// it counts in `canceled`, and its awaiters are asked to cancel, first come first, a unit
    /// each (Q3). Its slot goes, unless a notification for it is pending or its start queued:
    /// then it stays settled until the delivery loop or the drain reaches it (C74).
    fn reactionCanceled(self: *Machine, slot: u32, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        assert(self.source.depth == 1 and s.requests == call_frames.no_task);
        const task = &s.tasks[slot];
        // The root region holds no record: what the scheduler writes is never rolled back.
        self.source.write(task.handle.object.id + catalogue.task_state, .{ .integer = catalogue.task_canceled }, false) catch unreachable;
        s.canceled += 1;
        var awaiter = task.awaiters;
        while (awaiter != call_frames.no_task) : (awaiter = s.tasks[awaiter].after) {
            assert(s.tasks[awaiter].phase == .waiting and s.tasks[awaiter].waits == .task);
            s.tasks[awaiter].request = s.tasks[awaiter].after;
        }
        s.requests = task.awaiters;
        try self.makeRequests(remaining);
        assert(task.awaiters == call_frames.no_task);
        if (task.phase == .queued or (task.phase == .waiting and self.live.watch_pending[slot])) task.phase = .settled else self.dropSlot(slot);
    }

    /// An `Await` of a cancelled task (P3.7, Q3): a request to the awaiter's own task, a unit,
    /// and the site at `pc` of `frame` yields cancelled now, as at its entry.
    fn awaitCanceled(self: *Machine, frame: *call_frames.VmFrame, pc: u32, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        assert(s.current != call_frames.no_task and !s.tasks[s.current].cancel);
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        s.tasks[s.current].cancel = true;
        const yielded = self.canceledAtSite(frame, pc);
        assert(yielded);
    }

    /// The clock in seconds (P3.7): `now / R` in binary64.
    fn elapsedTime(self: *const Machine) f64 {
        @setFloatMode(.strict);
        return @as(f64, @floatFromInt(self.scheduler.now)) / @as(f64, @floatFromInt(self.scheduler.rate));
    }

    /// The spawned task in `slot` settles cancelled (P3.7): its handle says so and holds no
    /// result, every task awaiting it is asked to cancel, first come first, a unit each (Q3), and
    /// its slot is free again.
    fn settleCanceled(self: *Machine, program: Program, slot: u32, function: u32, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        assert(self.control.effects.depth == 0 and self.source.depth == 1 and s.requests == call_frames.no_task);
        const task = &s.tasks[slot];
        assert(task.phase == .running and task.kind == .spawn and task.keeper == call_frames.no_task);
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        assert(s.current == slot);
        s.current = task.below;
        // The root region holds no record: what the scheduler writes is never rolled back.
        self.source.write(task.handle.object.id + catalogue.task_state, .{ .integer = catalogue.task_canceled }, false) catch unreachable;
        const body = program.functions[function].body;
        self.control.calls[self.control.call_count] = .{ .function = function, .pc = body.end - body.start, .value = .{ .boolean = false }, .kind = .settle };
        self.control.call_count += 1;
        s.canceled += 1;
        var awaiter = task.awaiters;
        while (awaiter != call_frames.no_task) : (awaiter = s.tasks[awaiter].after) {
            assert(s.tasks[awaiter].phase == .waiting and s.tasks[awaiter].waits == .task);
            s.tasks[awaiter].request = s.tasks[awaiter].after;
        }
        s.requests = task.awaiters;
        try self.makeRequests(remaining);
        assert(task.awaiters == call_frames.no_task);
        self.dropSlot(slot);
    }

    /// The task in `slot` leaves the waiters of `event`, whose cells name the first and last.
    fn leaveEvent(self: *Machine, event: types.ObjectRef, slot: u32) void {
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        const count = self.eventCell(event, catalogue.event_waiting);
        assert(count > 0);
        if (task.before == call_frames.no_task) self.setEventCell(event, catalogue.event_first, if (task.after == call_frames.no_task) 0 else @intCast(s.tasks[task.after].sequence)) else s.tasks[task.before].after = task.after;
        if (task.after == call_frames.no_task) self.setEventCell(event, catalogue.event_last, if (task.before == call_frames.no_task) 0 else @intCast(s.tasks[task.before].sequence)) else s.tasks[task.after].before = task.before;
        self.setEventCell(event, catalogue.event_waiting, count - 1);
        task.after = call_frames.no_task;
        task.before = call_frames.no_task;
    }

    /// The task in `slot` leaves the awaiters of the task it awaits.
    fn leaveAwaiters(self: *Machine, slot: u32) void {
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        const target = &s.tasks[task.awaiting];
        if (task.before == call_frames.no_task) target.awaiters = task.after else s.tasks[task.before].after = task.after;
        if (task.after == call_frames.no_task) target.awaiters_end = task.before else s.tasks[task.after].before = task.before;
        task.after = call_frames.no_task;
        task.before = call_frames.no_task;
    }

    fn timerFirst(self: *const Machine, a: u32, b: u32) bool {
        const x = &self.scheduler.tasks[a];
        const y = &self.scheduler.tasks[b];
        if (x.wake != y.wake) return x.wake < y.wake;
        return x.order < y.order;
    }

    /// The slot at `hole` of the heap, which its task remembers (P3.3: a cancellation takes it out).
    fn timerSet(self: *Machine, hole: u32, slot: u32) void {
        self.scheduler.heap[hole] = slot;
        self.scheduler.tasks[slot].heap_at = hole;
    }

    fn timerRaise(self: *Machine, start: u32, slot: u32) void {
        const s = &self.scheduler;
        var hole = start;
        while (hole > 0 and self.timerFirst(slot, s.heap[(hole - 1) >> 1])) {
            self.timerSet(hole, s.heap[(hole - 1) >> 1]);
            hole = (hole - 1) >> 1;
        }
        self.timerSet(hole, slot);
    }

    fn timerSink(self: *Machine, start: u32, slot: u32) void {
        const s = &self.scheduler;
        var hole = start;
        while (true) {
            var child = 2 * hole + 1;
            if (child >= s.heap_count) break;
            if (child + 1 < s.heap_count and self.timerFirst(s.heap[child + 1], s.heap[child])) child += 1;
            if (!self.timerFirst(s.heap[child], slot)) break;
            self.timerSet(hole, s.heap[child]);
            hole = child;
        }
        self.timerSet(hole, slot);
    }

    fn timerInsert(self: *Machine, slot: u32) void {
        const s = &self.scheduler;
        const hole = s.heap_count;
        s.heap_count += 1;
        self.timerRaise(hole, slot);
    }

    fn timerRemoveFirst(self: *Machine) u32 {
        const s = &self.scheduler;
        assert(s.heap_count > 0);
        const first = s.heap[0];
        s.heap_count -= 1;
        s.tasks[first].heap_at = call_frames.no_task;
        if (s.heap_count == 0) return first;
        self.timerSink(0, s.heap[s.heap_count]);
        return first;
    }

    /// Takes the timer of the task in `slot` out: it was asked to cancel (P3.3).
    fn timerRemove(self: *Machine, slot: u32) void {
        const s = &self.scheduler;
        const hole = s.tasks[slot].heap_at;
        assert(hole < s.heap_count and s.heap[hole] == slot);
        s.heap_count -= 1;
        s.tasks[slot].heap_at = call_frames.no_task;
        if (hole == s.heap_count) return;
        const moved = s.heap[s.heap_count];
        if (hole > 0 and self.timerFirst(moved, s.heap[(hole - 1) >> 1])) self.timerRaise(hole, moved) else self.timerSink(hole, moved);
    }

    // P3.4: `Rush` and `Branch`, the tasks a frame keeps, and the wait at a frame's end.

    /// Whether the task running was asked to cancel (while it waited at a frame's end, which went
    /// on), so that the site at `pc` of `frame`, the frame on top, yields cancelled at once: a
    /// `resume_canceled` step with its sequence, its register unwritten, its check next.
    fn canceledAtSite(self: *Machine, frame: *call_frames.VmFrame, pc: u32) bool {
        const s = &self.scheduler;
        if (s.current == call_frames.no_task or !s.tasks[s.current].cancel) return false;
        // A task's frames are traced, and the site's step was made room for.
        self.control.calls[self.control.call_count] = .{ .function = frame.function, .pc = pc, .value = .{ .integer = @intCast(s.tasks[s.current].sequence) }, .kind = .resume_canceled };
        self.control.call_count += 1;
        s.just_canceled = true;
        frame.pc = pc + 1;
        return true;
    }

    /// `branch` of `closure` in the frame on top: a unit for the creation, a slot, the next
    /// sequence, the end of the frame's list of the tasks it keeps, and its entry frame on top,
    /// handed off to (S2). Its handle is the unit value, the frame's when the task leaves.
    fn branchTask(self: *Machine, program: Program, closure: types.Value, unit: types.Type, origin: u32, remaining: *u64) RuntimeError!void {
        const s = &self.scheduler;
        assert(self.control.effects.depth == 0 and s.current != call_frames.no_task);
        if (remaining.* == 0) return error.WorkLimit;
        remaining.* -= 1;
        const slot = self.takeSlot() orelse return error.TaskLimit;
        s.sequence += 1;
        const keeper = s.current;
        const at = self.calls.depth - 1;
        const frame = &self.calls.frames[at];
        s.tasks[slot] = .{ .sequence = s.sequence, .phase = .running, .handle = .{ .aggregate = .{ .value_type = unit, .elements = .{ .start = 0, .end = 0 } } }, .closure = closure, .origin = origin, .kind = .branch, .keeper = keeper, .keeper_frame = at - s.tasks[keeper].entry_at, .owned_prior = frame.owned_last };
        self.noteSequence(s.sequence, slot);
        if (frame.owned_last == call_frames.no_task) frame.owned_first = slot else s.tasks[frame.owned_last].owned_next = slot;
        frame.owned_last = slot;
        try self.startTask(program, slot, true);
    }

    /// The ends of the list of the tasks kept by the frame at `index` (from the entry frame) of
    /// `keeper`: on the stack while the keeper runs, in the saved store while it is suspended.
    const VmKept = struct { first: *u32, last: *u32 };
    fn keptBy(self: *Machine, keeper: u32, index: u32) VmKept {
        const task = &self.scheduler.tasks[keeper];
        if (task.phase == .running) {
            assert(task.entry_at + index < self.calls.depth);
            const frame = &self.calls.frames[task.entry_at + index];
            return .{ .first = &frame.owned_first, .last = &frame.owned_last };
        }
        assert(index < task.frames);
        const saved = &self.scheduler.saved[task.first_frame + index];
        return .{ .first = &saved.owned_first, .last = &saved.owned_last };
    }

    /// A kept task (a branch, or a `Rush`'s loser) settled, completed with `result` or cancelled:
    /// it leaves its frame's list and its slot is free; a keeper waiting at that frame's end,
    /// whose list is now empty, is ready to end it.
    fn ownedSettled(self: *Machine, program: Program, slot: u32, function: u32, result: types.Value, canceled: bool) RuntimeError!void {
        assert(self.control.effects.depth == 0);
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        assert(task.keeper != call_frames.no_task and task.phase == .running and s.current == slot);
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return error.CallTraceLimit;
        const body = program.functions[function].body;
        self.control.calls[self.control.call_count] = .{ .function = function, .pc = body.end - body.start, .value = if (canceled) .{ .boolean = false } else result, .kind = .settle };
        self.control.call_count += 1;
        if (canceled) s.canceled += 1 else s.completed += 1;
        s.current = task.below;
        const kept = self.keptBy(task.keeper, task.keeper_frame);
        if (task.owned_prior == call_frames.no_task) kept.first.* = task.owned_next else s.tasks[task.owned_prior].owned_next = task.owned_next;
        if (task.owned_next == call_frames.no_task) kept.last.* = task.owned_prior else s.tasks[task.owned_next].owned_prior = task.owned_prior;
        const keeper = &s.tasks[task.keeper];
        if (kept.first.* == call_frames.no_task and keeper.phase == .waiting and keeper.waits == .frame_end and task.keeper_frame + 1 == keeper.frames) self.makeReady(task.keeper, .{ .boolean = true });
        self.dropSlot(slot);
    }

    /// The frame on top is at its end and keeps tasks: each is asked to cancel in the order it
    /// came to the frame, a unit each, and the task waits at the frame's end until they are
    /// settled; being asked settles none.
    fn ownedEnd(self: *Machine, program: Program, root_pc: u32, remaining: *u64) VmLeft {
        const s = &self.scheduler;
        const frame = &self.calls.frames[self.calls.depth - 1];
        const definition = program.functions[frame.function];
        const span = siteSpan(program, frame.function, definition.root);
        assert(frame.pc == definition.body.end - definition.body.start and s.requests == call_frames.no_task and frame.owned_first != call_frames.no_task);
        var count: u32 = 0;
        var slot = frame.owned_first;
        while (slot != call_frames.no_task) : (slot = s.tasks[slot].owned_next) {
            count += 1;
            s.tasks[slot].request = s.tasks[slot].owned_next;
        }
        s.requests = frame.owned_first;
        self.makeRequests(remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
        assert(frame.owned_first != call_frames.no_task);
        return self.waitAt(program, .{ .frame_end = count }, span, root_pc, remaining);
    }

    /// The frame on top ended by `cancel_exit` and keeps no task that is not settled: it ends
    /// cancelled, its result unwritten, reclaiming nothing. A task's entry frame settles it
    /// cancelled (it runs on the empty stack, restored to unwind); any other's caller yields
    /// cancelled at its call, whose check is next. `span` places a failure of the settling.
    fn canceledEnd(self: *Machine, program: Program, span: types.Span, root_pc: u32, remaining: *u64) VmLeft {
        const s = &self.scheduler;
        const frame = self.calls.frames[self.calls.depth - 1];
        assert(frame.owned_first == call_frames.no_task);
        self.calls.count = frame.base;
        self.calls.depth -= 1;
        const ending = frame.task;
        if (ending != call_frames.no_task) {
            // An arm tells its expression; a branch or a `Rush`'s loser leaves its frame (P3.4);
            // a spawned task (P3.7) is marked cancelled in its handle.
            const task = s.tasks[ending];
            var leave: VmLeave = .{ .handoff = frame.handoff, .handle = .{ .boolean = false }, .owner = call_frames.no_task };
            if (task.kind == .arm and task.owner != call_frames.no_task) {
                leave.owner = task.owner;
                self.armSettled(program, ending, frame.function, .{ .boolean = false }, true, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
            } else if (task.keeper != call_frames.no_task) {
                if (task.kind == .branch) leave.handle = task.handle;
                self.ownedSettled(program, ending, frame.function, .{ .boolean = false }, true) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
            } else {
                leave.handle = task.handle;
                self.settleCanceled(program, ending, frame.function, remaining) catch |err| return .{ .failed = .{ .span = span, .code = runtimeCode(err) } };
            }
            // P3.7: a task cancelled in its first run, before it first left the stack, leaves its
            // creator what a task that completes there leaves it.
            if (self.calls.depth == 0) return .empty;
            return self.taskLeft(program, leave, span, root_pc, remaining);
        }
        // Its caller's call yields cancelled; the check after it is next.
        const caller = &self.calls.frames[self.calls.depth - 1];
        if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .failed = .{ .span = program.function_nodes[program.functions[caller.function].body.start + caller.pc].node.span, .code = .call_trace_limit } };
        self.control.calls[self.control.call_count] = .{ .function = caller.function, .pc = caller.pc, .value = .{ .boolean = false }, .kind = .call_canceled };
        self.control.call_count += 1;
        caller.pc += 1;
        s.just_canceled = true;
        return .going;
    }

    /// `owner`'s `Rush` resolved: its started arms that are not settled leave the record, in arm
    /// order, for the end of the list of the frame that runs it (on top of the stack in the
    /// start phase, the top saved frame of a task waiting on it), and go on as its own.
    fn adoptLosers(self: *Machine, owner: u32) void {
        const s = &self.scheduler;
        const parent = &s.tasks[owner];
        const record = &parent.record;
        assert(record.kind == .rush and record.winner != call_frames.no_task);
        const index = if (parent.phase == .running) self.calls.depth - 1 - parent.entry_at else parent.frames - 1;
        if (parent.phase == .running) assert(self.calls.frames[self.calls.depth - 1].pc == record.pc);
        const kept = self.keptBy(owner, index);
        var first: u32 = call_frames.no_task;
        var last: u32 = call_frames.no_task;
        var adopted: u32 = 0;
        var arm = record.first;
        while (arm != call_frames.no_task) {
            const task = &s.tasks[arm];
            const next = task.sibling;
            task.sibling = call_frames.no_task;
            if (task.phase == .settled) {
                if (last == call_frames.no_task) first = arm else s.tasks[last].sibling = arm;
                last = arm;
            } else {
                task.owner = call_frames.no_task;
                task.keeper = owner;
                task.keeper_frame = index;
                task.owned_prior = kept.last.*;
                task.owned_next = call_frames.no_task;
                if (kept.last.* == call_frames.no_task) kept.first.* = arm else s.tasks[kept.last.*].owned_next = arm;
                kept.last.* = arm;
                adopted += 1;
            }
            arm = next;
        }
        record.first = first;
        record.last = last;
        record.started -= adopted;
    }

    fn siteSpan(program: Program, function: u32, pc: u32) types.Span {
        const f = program.functions[function];
        // A wait at a frame's end (P3.4) is placed at the frame's result.
        const at = if (pc == f.body.end - f.body.start) f.root else pc;
        return program.function_nodes[f.body.start + at].node.span;
    }

    /// Runs a task on the empty stack until it waits or settles: a root `spawn` handing off, a
    /// start the root committed, or (`slice`) a ready task of the scheduler.
    fn runTask(self: *Machine, program: Program, slot: u32, slice: bool, root_pc: u32, remaining: *u64) ?types.Diagnostic {
        assert(self.calls.depth == 0 and self.calls.count == 0);
        defer {
            self.calls.depth = 0;
            self.calls.count = 0;
        }
        const s = &self.scheduler;
        const task = &s.tasks[slot];
        const top = if (slice) s.saved[task.first_frame + task.frames - 1] else undefined;
        const span = if (slice) siteSpan(program, top.function, top.pc) else program.code[root_pc].span;
        // The replay is told where the string pool stands as a slice begins.
        if (self.control.trace_sink != null) for (0..2) |_| self.control.foldCalls(self.aggregate_values[0..self.aggregate_count]);
        const entry_function = if (slice) s.saved[task.first_frame].function else task.closure.callable.function;
        (if (slice) self.restoreTask(program, slot, remaining) else self.startTask(program, slot, false)) catch |err| return .{ .span = span, .code = runtimeCode(err) };
        return switch (self.runFrames(program, entry_function, true, span, root_pc, remaining)) {
            .ok => null,
            .failed => |diagnostic| diagnostic,
            .language => unreachable, // A task's entry function cannot fail.
        };
    }

    /// After the root (S3): ready tasks run in turn; with none, the clock jumps to the earliest
    /// deadline and wakes what is due; with no timer either, the run is quiescent.
    fn runScheduler(self: *Machine, program: Program, remaining: *u64) ?types.Diagnostic {
        const s = &self.scheduler;
        assert(self.calls.depth == 0 and self.control.effects.depth == 0 and s.held_count == 0);
        while (true) {
            if (s.ready_count != 0) {
                const slot = s.ready[s.ready_first];
                s.ready_first = (s.ready_first + 1) % @as(u32, @intCast(s.ready.len));
                s.ready_count -= 1;
                if (self.runTask(program, slot, true, s.tasks[slot].origin, remaining)) |diagnostic| return diagnostic;
                continue;
            }
            if (s.heap_count == 0) break;
            const due = s.tasks[s.heap[0]];
            const site = s.saved[due.first_frame + due.frames - 1];
            const span = siteSpan(program, site.function, site.pc);
            if (remaining.* == 0) return .{ .span = span, .code = .work_limit };
            remaining.* -= 1;
            if (self.control.call_count == self.control.call_limit and !self.control.makeRoom(self.aggregate_values[0..self.aggregate_count])) return .{ .span = span, .code = .call_trace_limit };
            assert(due.wake > s.now);
            s.now = due.wake;
            self.control.calls[self.control.call_count] = .{ .function = 0, .pc = 0, .value = .{ .integer = @intCast(s.now) }, .kind = .tick };
            self.control.call_count += 1;
            while (s.heap_count != 0 and s.tasks[s.heap[0]].wake == s.now) {
                const slot = self.timerRemoveFirst();
                const task = &s.tasks[slot];
                const waiting = s.saved[task.first_frame + task.frames - 1];
                const node = program.function_nodes[program.functions[waiting.function].body.start + waiting.pc].node;
                assert(task.phase == .waiting and node.kind == .sleep);
                task.phase = .ready;
                task.resume_value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } };
                s.ready[(s.ready_first + s.ready_count) % s.ready.len] = slot;
                s.ready_count += 1;
            }
        }
        // Quiescent: the tasks still waiting are abandoned, and recorded by sequence.
        var slot: u32 = 0;
        while (slot < s.high) : (slot += 1) {
            const task = s.tasks[slot];
            // A settled arm waits for nothing: its expression keeps its slot (P3.3).
            if (task.phase == .free or task.phase == .settled) continue;
            assert(task.phase == .waiting and task.wake == call_frames.never);
            // A reaction has no frames: it waits where its node made it (RFC-0084, P4.4).
            const span = if (reactive(&task)) task.site_span else at_site: {
                const site = s.saved[task.first_frame + task.frames - 1];
                break :at_site siteSpan(program, site.function, site.pc);
            };
            s.waiting[s.waiting_count] = .{ .task = task.sequence, .kind = task.kind, .wait = task.waits, .span = span };
            s.waiting_count += 1;
        }
        // By sequence: slots are reused, so their order is not the tasks'.
        std.mem.sort(types.Scheduler.Waiting, s.waiting[0..s.waiting_count], {}, struct {
            fn lower(_: void, a: types.Scheduler.Waiting, b: types.Scheduler.Waiting) bool {
                return a.task < b.task;
            }
        }.lower);
        return null;
    }
};

/// Whether `code` is a value of a character type, in the VM's own words: a byte, or a code
/// point up to U+10FFFF outside the surrogates D800..DFFF.
fn characterCode(value_type: types.Type, code: i64) bool {
    if (code < 0) return false;
    if (value_type == types.Type.char) return code < 0x100;
    return value_type == types.Type.char32 and code < 0x110000 and code >> 11 != 0x1B;
}
/// A position that does not split an encoded scalar: an end of the string, or a byte that is
/// not a continuation byte (`10xxxxxx`).
fn textBoundary(text: []const u8, position: i64) bool {
    if (position < 0 or position > text.len) return false;
    return position == text.len or text[@intCast(position)] & 0xc0 != 0x80;
}
/// The scalar value encoded at the start of `bytes`, or null when no well-formed encoding
/// starts there. The second byte of a three- or four-byte form has a narrower range for the
/// lead bytes E0, ED, F0 and F4, which is what excludes overlong forms, surrogates and code
/// points past U+10FFFF.
pub fn decodeScalar(bytes: []const u8) ?struct { code: u32, length: u3 } {
    if (bytes.len == 0) return null;
    const lead = bytes[0];
    if (lead < 0x80) return .{ .code = lead, .length = 1 };
    const length: u3 = if (lead >= 0xc2 and lead <= 0xdf) 2 else if (lead >= 0xe0 and lead <= 0xef) 3 else if (lead >= 0xf0 and lead <= 0xf4) 4 else return null;
    if (bytes.len < length) return null;
    const low: u8 = if (lead == 0xe0) 0xa0 else if (lead == 0xf0) 0x90 else 0x80;
    const high: u8 = if (lead == 0xed) 0x9f else if (lead == 0xf4) 0x8f else 0xbf;
    if (bytes[1] < low or bytes[1] > high) return null;
    var code: u32 = lead & (@as(u8, 0x7f) >> length);
    code = code << 6 | (bytes[1] & 0x3f);
    for (bytes[2..length]) |byte| {
        if (byte & 0xc0 != 0x80) return null;
        code = code << 6 | (byte & 0x3f);
    }
    return .{ .code = code, .length = length };
}
/// Whether `char` values, in order, are valid UTF-8. Public, like `decodeScalar`, for the test
/// that compares the three validators.
pub fn validUnits(units: []const types.Value) bool {
    var index: usize = 0;
    while (index < units.len) {
        var encoded: [4]u8 = undefined;
        const count = @min(4, units.len - index);
        for (units[index .. index + count], encoded[0..count]) |unit, *byte| byte.* = @intCast(unit.enumeration.index);
        const scalar = decodeScalar(encoded[0..count]) orelse return false;
        index += scalar.length;
    }
    return true;
}

pub const Verification = union(enum) { ok: usize, failed: types.Diagnostic };
/// Calls of `verify` in a test build, so that tests can show a prepared run admits nothing
/// again (TASK-0109, W4.3). Never read outside tests.
pub var verifications: usize = 0;
/// Full validation only: no execution or journal access. Scratch's initialized
/// prefix describes the returned register count; it is not a cached trust token.
/// Inputs must remain immutable for this call, and scratch has one writer.
pub fn verify(program: Program, registers: *[types.limits.nodes]types.Type) Verification {
    if (@import("builtin").is_test) verifications += 1;
    if (program.code.len > max_instructions or program.source.len > types.limits.source_bytes or program.strings.len > types.limits.string_bytes or program.bindings.len > types.limits.bindings) return invalid();
    if (!std.unicode.utf8ValidateSlice(program.source) or !std.unicode.utf8ValidateSlice(program.strings)) return invalid();
    if (!modules.validateBundle(program.source, program.paths, program.modules, program.imports, program.nested, program.parts, program.file_paths)) return invalid();
    if (program.definitions.len > types.limits.user_types) return invalid();
    // One pass over the catalogue answers every comparison and constraint this admission meets.
    const comparable = scratch.alloc(bool, program.definitions.len) orelse return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .scratch_unavailable } };
    defer scratch.free(comparable);
    catalogue.comparableTypes(program.definitions, program.fields, program.tuple_elements, comparable);
    if (!catalogue.validateAllIn(program.definitions, program.fields, program.cases, program.tuple_elements, program.source, program.modules, program.nested, comparable) or program.members.len > types.limits.aggregate_elements) return invalid();
    var exposed: [types.limits.user_types]bool = undefined;
    if (program.modules.len != 0) catalogue.exportableTypes(program.definitions, program.fields, program.tuple_elements, &exposed);
    var reach: Reach = .{};
    if (!reach.open(program)) return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .scratch_unavailable } };
    defer reach.close();
    if (reach.privacy) |held| if (!held.fieldsAdmitted(program.definitions, program.fields)) return invalid();
    // RFC-0087, P5.3 (admission rule 6): what the types of JSON instructions are, when there is one.
    reach.json = verifyJsonFacts(program) catch return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .scratch_unavailable } };
    if (!verifySourceCells(program, &reach) or !catalogue.validDispatch(program.slots, program.dispatch, program.definitions, program.tuple_elements, program.functions)) return invalid();
    // RFC-0087, P5.2 (admission rule 2).
    verifyPersistable(program) catch |err| return if (err == error.ScratchUnavailable) .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .scratch_unavailable } } else invalid();
    // RFC-0092, B4: the marks of restricted hierarchies, in this machine's own terms.
    verifyFinalSupers(program.definitions) catch return invalid();
    // RFC-0084, P4.2: the clauses of a class with live fields are no method, and only a program
    // that has some tells which register each upcast reads (`casts`), and which register holds
    // the latest construction (`latest`).
    var clauses = false;
    for (program.functions) |f| clauses = clauses or f.clauses_of != null;
    for (program.dispatch) |entry| if (entry.function < program.functions.len and program.functions[entry.function].clauses_of != null) return invalid();
    // RFC-0082, P3.6: an arm that may exit runs only as an arm, so nothing dispatches to it.
    for (program.dispatch) |entry| if (entry.function < program.functions.len and program.functions[entry.function].exits != null) return invalid();
    const casts: []u32 = if (clauses) scratch.alloc(u32, program.code.len) orelse return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .scratch_unavailable } } else &.{};
    defer if (clauses) scratch.free(casts);
    var latest: u32 = no_register;
    var call_ops: u32 = 0;
    var argument_count: u32 = 0;
    var source_ops: u32 = 0;
    var count: usize = 0;
    var depth: usize = 0;
    var member_count: u32 = 0;
    var string_comparisons: u32 = 0;
    var control_ops: u32 = 0;
    for (program.code, 0..) |instruction, pc| {
        if (!validSpan(instruction.span, program.source.len)) return invalid();
        if (program.modules.len != 0 and modules.owner(instruction.span, program.modules) == null) return invalid();
        const result_type = verifyOperation(instruction, registers[0..count], program, comparable, &depth, &member_count) catch |err| {
            return .{ .failed = .{ .span = instruction.span, .code = if (err == error.DepthLimit) .transaction_limit else .invalid_bytecode } };
        };
        if (result_type != instruction.value_type) return invalid();
        if (!verifyJson(instruction.op, instruction.value_type, registers[0..count], program, reach.json)) return invalid();
        if (suspendsAtRoot(instruction, registers[0..count], program)) return invalid();
        // P3.6: nor does root code name it: it has no site to start it from.
        if (namesExitingArm(program, instruction)) return invalid();
        // RFC-0084, P4.2: root code attaches no live-only field, and hands a class's clauses
        // only an instance it has just built.
        if (instruction.op == .object_live and liveSpotOf(program, registers[instruction.op.object_live.object], instruction.op.object_live.field).?.live_only) return invalid();
        if (!clausesReached(instruction, program, casts[0..@min(count, casts.len)], latest)) return invalid();
        if (clauses and result_type != null and count < casts.len) {
            casts[count] = if (instruction.op == .upcast) instruction.op.upcast else no_register;
            if (instruction.op == .object_new) latest = @intCast(count);
        }
        switch (instruction.op) {
            .function_value => |id| if (program.functions[id].available_at > pc) {
                return invalid();
            },
            .invoke, .bind, .event_notify => |i| {
                if (i.arguments.start != argument_count) return invalid();
                argument_count = i.arguments.end;
                if (instruction.op == .invoke) call_ops += 1;
            },
            .call => |c| {
                if (c.arguments.start != argument_count or program.functions[c.function].available_at > pc) return invalid();
                argument_count = c.arguments.end;
                call_ops += 1;
            },
            .object_new => |c| {
                if (c.arguments.start != argument_count or !catalogue.dispatchReady(program.dispatch, program.functions, instruction.value_type.?, @intCast(pc))) return invalid();
                argument_count = c.arguments.end;
            },
            .iterate => |i| if (program.functions[i.function].available_at > pc) {
                return invalid();
            },
            else => {},
        }
        if (controlOperation(instruction)) control_ops += 1;
        if (sourceOperation(instruction)) source_ops += 1;
        if (instruction.op == .compare and catalogue.walkedEquality(registers[instruction.op.compare.lhs], program.definitions)) string_comparisons += 1;
        if (result_type) |value_type| {
            if (count == registers.len) return invalid();
            registers[count] = value_type;
            count += 1;
        }
    }
    if (source_ops != program.source_ops or control_ops != program.control_ops or call_ops != program.call_ops or argument_count != program.call_arguments.len or ((control_ops != 0 or source_ops != 0 or call_ops != 0 or program.functions.len != 0) and !verifyControl(program))) return invalid();
    if (!verifyFunctions(program, registers[0..count], comparable, &reach)) return invalid();
    if (depth != 0 or member_count != program.members.len or string_comparisons != program.string_comparisons) return invalid();
    for (program.bindings) |binding| {
        if (!validSpan(binding.name, program.source.len) or binding.node >= count) return invalid();
        if (program.modules.len != 0 and (!modules.contains(program.modules[program.modules.len - 1].source, binding.name) or modules.innermost(binding.name, program.nested) != null or !reach.exposes(exposed[0..program.definitions.len], binding.value_type, binding.name, binding.is_public))) return invalid();
        if (registers[binding.node] != binding.value_type) return invalid();
    }
    assert(count <= registers.len and depth == 0);
    return .{ .ok = count };
}
fn verifyOperation(instruction: Instruction, registers: []const types.Type, program: Program, comparable: []const bool, depth: *usize, member_count: *u32) VerifyError!?types.Type {
    switch (instruction.op) {
        .recur, .self_value => return error.InvalidBytecode,
        .function_value => |id| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (id >= program.functions.len or !signatureMatches(program, value_type, program.functions[id]) or !functionVisible(program, program.functions[id].name, program.functions[id].is_public or program.functions[id].template_public, instruction.span)) return error.InvalidBytecode;
            return value_type;
        },
        .invoke => |i| {
            if (i.callable >= registers.len or !validSpan(i.arguments, program.call_arguments.len)) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[i.callable], program.definitions) orelse return error.InvalidBytecode;
            if (shape != .callable) return error.InvalidBytecode;
            const parameters = catalogue.definition(shape.callable.parameters, program.definitions).?.tuple;
            if (i.arguments.end - i.arguments.start != parameters.end - parameters.start) return error.InvalidBytecode;
            for (program.call_arguments[i.arguments.start..i.arguments.end], program.tuple_elements[parameters.start..parameters.end]) |operand, required| try operandType(operand, registers, required);
            return shape.callable.result;
        },
        .bind => |b| {
            if (b.callable >= registers.len or !validSpan(b.arguments, program.call_arguments.len)) return error.InvalidBytecode;
            const original = catalogue.definition(registers[b.callable], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            const residual = catalogue.definition(result_type, program.definitions) orelse return error.InvalidBytecode;
            if (original != .callable or residual != .callable) return error.InvalidBytecode;
            const a = original.callable;
            const r = residual.callable;
            const params = catalogue.definition(a.parameters, program.definitions).?.tuple;
            const rest = catalogue.definition(r.parameters, program.definitions).?.tuple;
            const count = b.arguments.end - b.arguments.start;
            if (count == 0 or count > params.end - params.start or rest.end - rest.start != params.end - params.start - count or a.result != r.result or a.transacts != r.transacts or a.decides != r.decides or @as(u8, @bitCast(a.detail)) != @as(u8, @bitCast(r.detail))) return error.InvalidBytecode;
            if (!std.mem.eql(types.Type, program.tuple_elements[rest.start..rest.end], program.tuple_elements[params.start + count .. params.end])) return error.InvalidBytecode;
            for (program.call_arguments[b.arguments.start..b.arguments.end], program.tuple_elements[params.start .. params.start + count]) |operand, required| try operandType(operand, registers, required);
            return result_type;
        },
        .loop => |l| {
            if (l.callable >= registers.len) return error.InvalidBytecode;
            const definition = catalogue.definition(registers[l.callable], program.definitions) orelse return error.InvalidBytecode;
            if (definition != .callable) return error.InvalidBytecode;
            const shape = definition.callable;
            const parameters = catalogue.definition(shape.parameters, program.definitions).?.tuple;
            const result = catalogue.definition(shape.result, program.definitions) orelse return error.InvalidBytecode;
            if (result != .option or parameters.end - parameters.start != 1 or program.tuple_elements[parameters.start] != result.option) return error.InvalidBytecode;
            try operandType(l.initial, registers, result.option);
            return result.option;
        },
        .iterate_value => |i| {
            if (i.callable >= registers.len) return error.InvalidBytecode;
            const definition = catalogue.definition(registers[i.callable], program.definitions) orelse return error.InvalidBytecode;
            if (definition != .callable) return error.InvalidBytecode;
            const shape = definition.callable;
            const parameters = catalogue.definition(shape.parameters, program.definitions).?.tuple;
            if (parameters.end - parameters.start != 1 or program.tuple_elements[parameters.start] != shape.result) return error.InvalidBytecode;
            try operandType(i.count, registers, .i64);
            try operandType(i.initial, registers, shape.result);
            return shape.result;
        },
        .iterate => |i| {
            if (i.function >= program.functions.len) return error.InvalidBytecode;
            const f = program.functions[i.function];
            if (f.parameter_count != 1 or f.parameters[0] != f.value_type or !functionVisible(program, f.name, f.is_public, instruction.span)) return error.InvalidBytecode;
            try operandType(i.count, registers, .i64);
            try operandType(i.initial, registers, f.value_type);
            return f.value_type;
        },
        .call => |c| {
            if (c.function >= program.functions.len or !validSpan(c.arguments, program.call_arguments.len)) return error.InvalidBytecode;
            const f = program.functions[c.function];
            if (f.parameter_count > types.limits.parameters or c.arguments.end - c.arguments.start != f.parameter_count or !functionVisible(program, f.name, f.is_public, instruction.span)) return error.InvalidBytecode;
            for (program.call_arguments[c.arguments.start..c.arguments.end], f.parameters[0..f.parameter_count]) |operand, required| try operandType(operand, registers, required);
            return f.value_type;
        },
        .local_set => |n| {
            if (n >= registers.len) return error.InvalidBytecode;
            return registers[n];
        },
        .upcast => |n| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (n >= registers.len or registers[n] == value_type) return error.InvalidBytecode;
            // RFC-0080: every other type goes up to `any`, but a task handle (RFC-0082) is no
            // value of a class and passes through no cast.
            if (value_type == types.Type.any) {
                if (!catalogue.validType(registers[n], program.definitions) or catalogue.isScheduled(registers[n], program.definitions)) return error.InvalidBytecode;
                // Nor does a refinement (RFC-0083): its value would answer type tests as its base.
                if (catalogue.refinementOf(registers[n], program.definitions) != null) return error.InvalidBytecode;
                return value_type;
            }
            // To a supertype of an instance's class, or to a function type that allows more effects (RFC-0078).
            const instance = classType(program, value_type) and catalogue.subtype(registers[n], value_type, program.definitions);
            // P3.7: a handle or an event as an interface it implements.
            // RFC-0087, W3: a map as a `weak_map` of its key and value types, and nothing back.
            if (!instance and !catalogue.widens(registers[n], value_type, program.definitions, program.tuple_elements) and !catalogue.implements(registers[n], value_type, program.definitions) and !catalogue.weakens(registers[n], value_type, program.definitions)) return error.InvalidBytecode;
            return value_type;
        },
        .downcast => |n| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (n >= registers.len or registers[n] == value_type) return error.InvalidBytecode;
            if (registers[n] == types.Type.any) {
                if (!catalogue.validType(value_type, program.definitions) or catalogue.isScheduled(value_type, program.definitions) or catalogue.refinementOf(value_type, program.definitions) != null) return error.InvalidBytecode;
                return value_type;
            }
            if (!classType(program, registers[n]) or !catalogue.castable(value_type, registers[n], program.definitions)) return error.InvalidBytecode;
            return value_type;
        },
        .method_value => |m| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (m.receiver >= registers.len or m.slot >= program.slots.len or !classType(program, registers[m.receiver])) return error.InvalidBytecode;
            if (!catalogue.subtype(registers[m.receiver], program.slots[m.slot].owner, program.definitions) or program.slots[m.slot].callable != value_type) return error.InvalidBytecode;
            return value_type;
        },
        .instance_of => |c| {
            if (c.value >= registers.len) return error.InvalidBytecode;
            if (registers[c.value] == types.Type.any) {
                // A value of `any` is asked whether it is of any one other type.
                if (c.class == types.Type.any or !catalogue.validType(c.class, program.definitions) or catalogue.isScheduled(c.class, program.definitions) or catalogue.refinementOf(c.class, program.definitions) != null) return error.InvalidBytecode;
                return .logic;
            }
            if (!classType(program, registers[c.value]) or !classType(program, c.class) or !catalogue.castable(c.class, registers[c.value], program.definitions)) return error.InvalidBytecode;
            return .logic;
        },
        .cell_init, .cell_write => |c| {
            if (c.cell >= program.source_cells.len) return error.InvalidBytecode;
            const cell = program.source_cells[c.cell];
            if ((if (instruction.op == .cell_init) cell.initial != registers.len else cell.initial >= registers.len) or !sourceVisible(program, c.cell, instruction.span)) return error.InvalidBytecode;
            // Only its guard writes a live-only cell (RFC-0084, admission rule 3).
            if (cell.live_only) return error.InvalidBytecode;
            try operandType(c.value, registers, cell.value_type);
            return cell.value_type;
        },
        // RFC-0084, rules 1 and 2: a guard of the cell's type within `<reads>`; the declaration
        // of the cell where its initialisation would stand, or a later attachment.
        .cell_live => |c| {
            if (c.cell >= program.source_cells.len or c.guard >= registers.len) return error.InvalidBytecode;
            const cell = program.source_cells[c.cell];
            if (if (c.initialize) cell.initial != registers.len else (cell.initial >= registers.len or cell.live_only)) return error.InvalidBytecode;
            if (!sourceVisible(program, c.cell, instruction.span) or !guardShape(program, registers[c.guard], cell.value_type) or liveTypeFor(program, cell.value_type) == null) return error.InvalidBytecode;
            return cell.value_type;
        },
        // RFC-0084, P4.2, rules 1 and 2: a `var` or live-only field of a class instance, and a
        // guard of its type within `<reads>`. Who may attach a live-only field is asked where
        // the instruction stands (`verify`, `verifyFunctions`).
        .object_live => |c| {
            if (c.object >= registers.len or c.guard >= registers.len) return error.InvalidBytecode;
            const field = liveSpotOf(program, registers[c.object], c.field) orelse return error.InvalidBytecode;
            if (!guardShape(program, registers[c.guard], field.value_type) or liveTypeFor(program, field.value_type) == null) return error.InvalidBytecode;
            return field.value_type;
        },
        // RFC-0084, P4.4, rules 1 and 4: a guard within `<reads>` that yields an option, a body
        // that neither decides nor suspends, and the handle of the body's result, or of the unit
        // value for a `when`. What the body may do is the function's matter (`verifyFunctions`).
        .reaction => |r| {
            if (r.guard >= registers.len or r.body >= registers.len) return error.InvalidBytecode;
            const guard = switch (catalogue.definition(registers[r.guard], program.definitions) orelse return error.InvalidBytecode) {
                .callable => |shape| shape,
                else => return error.InvalidBytecode,
            };
            const guard_parameters = catalogue.definition(guard.parameters, program.definitions) orelse return error.InvalidBytecode;
            if (guard_parameters != .tuple or guard_parameters.tuple.end != guard_parameters.tuple.start) return error.InvalidBytecode;
            const yielded = catalogue.definition(guard.result, program.definitions) orelse return error.InvalidBytecode;
            const effect = guard.effects();
            if (yielded != .option or effect.writes or effect.allocates or effect.decides or effect.suspends) return error.InvalidBytecode;
            const body = switch (catalogue.definition(registers[r.body], program.definitions) orelse return error.InvalidBytecode) {
                .callable => |shape| shape,
                else => return error.InvalidBytecode,
            };
            const body_parameters = catalogue.definition(body.parameters, program.definitions) orelse return error.InvalidBytecode;
            if (body_parameters != .tuple or body_parameters.tuple.end != body_parameters.tuple.start or body.decides or body.detail.suspends) return error.InvalidBytecode;
            const handle = instruction.value_type orelse return error.InvalidBytecode;
            const target = catalogue.definition(handle, program.definitions) orelse return error.InvalidBytecode;
            if (target != .task) return error.InvalidBytecode;
            switch (r.kind) {
                .upon => if (target.task.result != body.result) return error.InvalidBytecode,
                .when => {
                    const unit = catalogue.definition(target.task.result, program.definitions) orelse return error.InvalidBytecode;
                    if (unit != .tuple or unit.tuple.end != unit.tuple.start) return error.InvalidBytecode;
                },
            }
            return handle;
        },
        // RFC-0084, P4.5, rule 4: a body of no parameters that neither decides nor suspends, whose
        // result is the instruction's. What it may do is the function's matter (`verifyFunctions`).
        .batch => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const body = switch (catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode) {
                .callable => |shape| shape,
                else => return error.InvalidBytecode,
            };
            const parameters = catalogue.definition(body.parameters, program.definitions) orelse return error.InvalidBytecode;
            if (parameters != .tuple or parameters.tuple.end != parameters.tuple.start or body.decides or body.detail.suspends) return error.InvalidBytecode;
            const result = instruction.value_type orelse return error.InvalidBytecode;
            if (result != body.result) return error.InvalidBytecode;
            return result;
        },
        .cell_read => |c| {
            if (c >= program.source_cells.len or program.source_cells[c].initial >= registers.len or !sourceVisible(program, c, instruction.span)) return error.InvalidBytecode;
            return program.source_cells[c].value_type;
        },
        // RFC-0087, P5.4 (rules 4 and 5): a keyed cell declared where it is, then looked up and
        // updated with its own key and value types.
        .weak_init => |c| {
            if (c >= program.source_cells.len or program.source_cells[c].keyed == .none or program.source_cells[c].initial != registers.len or !sourceVisible(program, c, instruction.span)) return error.InvalidBytecode;
            if (instruction.value_type != program.source_cells[c].value_type) return error.InvalidBytecode;
            return program.source_cells[c].value_type;
        },
        .weak_get => |g| {
            const entries = keyedEntries(program, g.cell) orelse return error.InvalidBytecode;
            if (program.source_cells[g.cell].initial >= registers.len or !sourceVisible(program, g.cell, instruction.span)) return error.InvalidBytecode;
            try operandType(g.key, registers, entries.key);
            const made = instruction.value_type orelse return error.InvalidBytecode;
            const option = catalogue.definition(made, program.definitions) orelse return error.InvalidBytecode;
            if (option != .option or option.option != entries.value) return error.InvalidBytecode;
            return made;
        },
        .weak_set => |c| {
            const entries = keyedEntries(program, c.cell) orelse return error.InvalidBytecode;
            if (program.source_cells[c.cell].initial >= registers.len or !sourceVisible(program, c.cell, instruction.span)) return error.InvalidBytecode;
            try operandType(c.key, registers, entries.key);
            try operandType(c.value, registers, entries.value);
            if (instruction.value_type != entries.value) return error.InvalidBytecode;
            return entries.value;
        },
        .object_new => |c| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            const shape = catalogue.definition(value_type, program.definitions) orelse return error.InvalidBytecode;
            if (shape != .class or shape.class.is_abstract or !validSpan(c.arguments, program.call_arguments.len) or !validSpan(shape.class.fields, program.fields.len)) return error.InvalidBytecode;
            if (c.arguments.end - c.arguments.start != shape.class.fields.end - shape.class.fields.start) return error.InvalidBytecode;
            for (program.call_arguments[c.arguments.start..c.arguments.end], program.fields[shape.class.fields.start..shape.class.fields.end]) |operand, field| try operandType(operand, registers, field.value_type);
            return value_type;
        },
        .object_get => |access| {
            if (access.value >= registers.len) return error.InvalidBytecode;
            const field = catalogue.classFieldAt(registers[access.value], access.index, program.definitions, program.fields) orelse return error.InvalidBytecode;
            return field.value_type;
        },
        .object_set => |c| {
            if (c.object >= registers.len) return error.InvalidBytecode;
            const field = catalogue.classFieldAt(registers[c.object], c.index, program.definitions, program.fields) orelse return error.InvalidBytecode;
            if (!field.is_var) return error.InvalidBytecode;
            try operandType(c.value, registers, field.value_type);
            return field.value_type;
        },
        .if_begin => |b| {
            try operandType(b.condition, registers, .logic);
            return .logic;
        },
        .attempt_begin => |b| {
            if (b.condition != std.math.maxInt(u32)) return error.InvalidBytecode;
            return .logic;
        },
        .otherwise => |begin| {
            try operandType(begin, registers, .logic);
            return .logic;
        },
        .merge => |m| {
            try operandType(m.begin, registers, .logic);
            const result = instruction.value_type orelse return error.InvalidBytecode;
            // The first arm may be a function the result widens (RFC-0078, `fix2`).
            if (m.left >= registers.len) return error.InvalidBytecode;
            if (registers[m.left] != result and !catalogue.widens(registers[m.left], result, program.definitions, program.tuple_elements)) return error.InvalidBytecode;
            try operandType(m.right, registers, result);
            return result;
        },
        .demand => |n| {
            try operandType(n, registers, .logic);
            return .logic;
        },
        .fail, .err => |n| {
            try operandType(n, registers, .string);
            const result = instruction.value_type orelse return error.InvalidBytecode;
            if (!catalogue.validType(result, program.definitions)) return error.InvalidBytecode;
            return result;
        },
        // Only a function body may hold an exit; its verification types the operand.
        .exit => return error.InvalidBytecode,
        // RFC-0082, P3.6: nor any of these, whose shape `verifySites` checks.
        .arm_exit, .arm_exited, .arm_exit_value => return error.InvalidBytecode,
        .integer => return .i64,
        .floating => return .float,
        .boolean => return .logic,
        .string => |span| {
            if (!validSpan(span, program.strings.len)) return error.InvalidBytecode;
            // The pool is already valid UTF-8. Check only code-point boundaries,
            // avoiding rescanning overlapping slices for every instruction.
            if (!stringBoundary(span.start, program.strings) or !stringBoundary(span.end, program.strings)) return error.InvalidBytecode;
            return .string;
        },
        .negate => |operand| {
            try operandType(operand, registers, .i64);
            return .i64;
        },
        .binary => |binary| {
            try operandType(binary.lhs, registers, .i64);
            try operandType(binary.rhs, registers, .i64);
            return .i64;
        },
        .float_negate => |operand| {
            try operandType(operand, registers, .float);
            return .float;
        },
        .int_to_float => |operand| {
            try operandType(operand, registers, .i64);
            return .float;
        },
        // RFC-0083: a refinement from its base, or the base from a refinement.
        .refine => |n| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (n >= registers.len) return error.InvalidBytecode;
            if (catalogue.refinementOf(value_type, program.definitions)) |refinement| {
                if (refinement.base != registers[n]) return error.InvalidBytecode;
            } else {
                const refinement = catalogue.refinementOf(registers[n], program.definitions) orelse return error.InvalidBytecode;
                if (refinement.base != value_type) return error.InvalidBytecode;
            }
            return value_type;
        },
        .float_to_int => |c| {
            try operandType(c.operand, registers, .float);
            return .i64;
        },
        .float_binary => |binary| {
            // Euclidean division is an integer operation.
            if (binary.op == .quotient or binary.op == .modulo) return error.InvalidBytecode;
            // Bitwise operators are defined on integers only (RFC-0072).
            if (binary.op.bitwise()) return error.InvalidBytecode;
            try operandType(binary.lhs, registers, .float);
            try operandType(binary.rhs, registers, .float);
            return .float;
        },
        .rational => |r| {
            if (r.lhs >= registers.len or r.rhs >= registers.len) return error.InvalidBytecode;
            if (r.op == .make) {
                // The only producer of a rational: what it stores is in lowest terms.
                try operandType(r.lhs, registers, .i64);
                try operandType(r.rhs, registers, .i64);
                const result = instruction.value_type orelse return error.InvalidBytecode;
                if (!catalogue.isRational(result, program.definitions)) return error.InvalidBytecode;
                return result;
            }
            const input = registers[r.lhs];
            if (!catalogue.isRational(input, program.definitions)) return error.InvalidBytecode;
            try operandType(r.rhs, registers, input);
            if (r.op.unary() and r.lhs != r.rhs) return error.InvalidBytecode;
            return switch (r.op) {
                .make => unreachable,
                .add, .subtract, .multiply, .negate => input,
                .floor, .ceil => .i64,
                .to_float => .float,
            };
        },
        .aggregate => |range| {
            if (!validSpan(range, program.members.len) or range.start != member_count.*) return error.InvalidBytecode;
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            const definition = catalogue.definition(value_type, program.definitions) orelse return error.InvalidBytecode;
            switch (definition) {
                .record => |record| {
                    if (range.end - range.start != record.fields.end - record.fields.start) return error.InvalidBytecode;
                    for (program.members[range.start..range.end], program.fields[record.fields.start..record.fields.end]) |operand, field| try operandType(operand, registers, field.value_type);
                },
                .array => |element_type| for (program.members[range.start..range.end]) |operand| try operandType(operand, registers, element_type),
                .option => |element_type| {
                    if (range.end - range.start > 1) return error.InvalidBytecode;
                    for (program.members[range.start..range.end]) |operand| try operandType(operand, registers, element_type);
                },
                // RFC-0087, W3: a map literal built at a `weak_map` type has a map's layout.
                .map, .weak_map => |shape| {
                    if ((range.end - range.start) % 2 != 0) return error.InvalidBytecode;
                    for (program.members[range.start..range.end], 0..) |operand, ordinal| try operandType(operand, registers, if (ordinal % 2 == 0) shape.key else shape.value);
                },
                .enumeration, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant => return error.InvalidBytecode,
                .tuple => |span| {
                    if (range.end - range.start != span.end - span.start) return error.InvalidBytecode;
                    for (program.members[range.start..range.end], program.tuple_elements[span.start..span.end]) |operand, element| try operandType(operand, registers, element);
                },
            }
            member_count.* = range.end;
            return value_type;
        },
        .field => |access| {
            if (access.value >= registers.len) return error.InvalidBytecode;
            const field = catalogue.fieldAt(registers[access.value], access.index, program.definitions, program.fields) orelse return error.InvalidBytecode;
            return field.value_type;
        },
        .array_length => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const definition = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
            if (definition != .array and definition != .map) return error.InvalidBytecode;
            return .i64;
        },
        .enumeration => |index| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (catalogue.caseAt(value_type, index, program.definitions, program.cases) == null) return error.InvalidBytecode;
            return value_type;
        },
        .tuple_element => |access| {
            if (access.value >= registers.len) return error.InvalidBytecode;
            return catalogue.tupleElementAt(registers[access.value], access.index, program.definitions, program.tuple_elements) orelse error.InvalidBytecode;
        },
        .option_present => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
            if (shape != .option) return error.InvalidBytecode;
            return .logic;
        },
        .option_or => |choice| {
            if (choice.option >= registers.len or choice.fallback >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[choice.option], program.definitions) orelse return error.InvalidBytecode;
            if (shape != .option or shape.option != registers[choice.fallback]) return error.InvalidBytecode;
            return shape.option;
        },
        .array_concat => |c| {
            if (c.lhs >= registers.len or c.rhs >= registers.len or registers[c.lhs] != registers[c.rhs]) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[c.lhs], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            if (shape != .array or result_type != registers[c.lhs]) return error.InvalidBytecode;
            return result_type;
        },
        .string_concat => |c| {
            try operandType(c.lhs, registers, .string);
            try operandType(c.rhs, registers, .string);
            return .string;
        },
        .string_length => |operand| {
            try operandType(operand, registers, .string);
            return .i64;
        },
        .to_string => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const input = registers[operand];
            if (input != .i64 and input != .float and input != .logic and input != types.Type.char and input != types.Type.char32) return error.InvalidBytecode;
            return .string;
        },
        .character => |code| {
            const value_type = instruction.value_type orelse return error.InvalidBytecode;
            if (!characterCode(value_type, code)) return error.InvalidBytecode;
            return value_type;
        },
        .text => |t| {
            // Each operand an operation takes is typed here; the ones it does not take are zero.
            if (t.a >= registers.len) return error.InvalidBytecode;
            switch (t.op) {
                .unit, .boundary, .scalar => {
                    if (t.c != 0) return error.InvalidBytecode;
                    try operandType(t.a, registers, .string);
                    try operandType(t.b, registers, .i64);
                    return switch (t.op) {
                        .unit => types.Type.char,
                        .boundary => .logic,
                        else => types.Type.char32,
                    };
                },
                .slice => {
                    try operandType(t.a, registers, .string);
                    try operandType(t.b, registers, .i64);
                    try operandType(t.c, registers, .i64);
                    return .string;
                },
                .code => {
                    if (t.b != 0 or t.c != 0) return error.InvalidBytecode;
                    if (registers[t.a] != types.Type.char and registers[t.a] != types.Type.char32) return error.InvalidBytecode;
                    return .i64;
                },
                .from_code => {
                    if (t.b != 0 or t.c != 0) return error.InvalidBytecode;
                    try operandType(t.a, registers, .i64);
                    const value_type = instruction.value_type orelse return error.InvalidBytecode;
                    if (value_type != types.Type.char and value_type != types.Type.char32) return error.InvalidBytecode;
                    return value_type;
                },
                .valid, .join => {
                    if (t.b != 0 or t.c != 0) return error.InvalidBytecode;
                    const shape = catalogue.definition(registers[t.a], program.definitions) orelse return error.InvalidBytecode;
                    if (shape != .array or shape.array != types.Type.char) return error.InvalidBytecode;
                    return if (t.op == .valid) .logic else .string;
                },
            }
        },
        .native_call => |c| {
            if (c.native >= program.natives.len or c.count > native.max_parameters) return error.InvalidBytecode;
            const entry = program.natives[c.native];
            if (!native.wellFormed(entry) or c.count != entry.params.len) return error.InvalidBytecode;
            var operand_types: [native.max_parameters]types.Type = undefined;
            for (c.args[0..c.count], operand_types[0..c.count]) |operand, *operand_type| {
                if (operand >= registers.len) return error.InvalidBytecode;
                operand_type.* = registers[operand];
            }
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            if (!native.admits(entry, operand_types[0..c.count], result_type, program.definitions, comparable)) return error.InvalidBytecode;
            return result_type;
        },
        .option_value => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
            if (shape != .option) return error.InvalidBytecode;
            return shape.option;
        },
        .map_set => |c| {
            if (c.map >= registers.len or c.key >= registers.len or c.value >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[c.map], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            // RFC-0087, W2: a `weak_map` is updated as a map is, one key at a time.
            if (shape != .map and shape != .weak_map) return error.InvalidBytecode;
            const entries = catalogue.entryShape(registers[c.map], program.definitions).?;
            if (result_type != registers[c.map] or entries.key != registers[c.key] or entries.value != registers[c.value]) return error.InvalidBytecode;
            return result_type;
        },
        .map_remove => |c| {
            if (c.map >= registers.len or c.key >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[c.map], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            if (shape != .map or result_type != registers[c.map]) return error.InvalidBytecode;
            // Not a key: the option a lookup in this map produces.
            const found = catalogue.definition(registers[c.key], program.definitions) orelse return error.InvalidBytecode;
            if (found != .option or found.option != shape.map.value) return error.InvalidBytecode;
            return result_type;
        },
        .array_set => |c| {
            if (c.array >= registers.len or c.index >= registers.len or c.value >= registers.len or registers[c.index] != .i64) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[c.array], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            if (shape != .array or result_type != registers[c.array] or shape.array != registers[c.value]) return error.InvalidBytecode;
            return result_type;
        },
        .array_get => |access| {
            if (access.array >= registers.len or access.index >= registers.len or registers[access.index] != .i64) return error.InvalidBytecode;
            const array = catalogue.definition(registers[access.array], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            if (array != .array or array.array != result_type) return error.InvalidBytecode;
            return result_type;
        },
        .map_key, .map_value => |access| {
            if (access.array >= registers.len or access.index >= registers.len or registers[access.index] != .i64) return error.InvalidBytecode;
            const map = catalogue.definition(registers[access.array], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            if (map != .map or result_type != (if (instruction.op == .map_key) map.map.key else map.map.value)) return error.InvalidBytecode;
            return result_type;
        },
        .map_lookup => |lookup| {
            if (lookup.map >= registers.len or lookup.key >= registers.len) return error.InvalidBytecode;
            const map = catalogue.definition(registers[lookup.map], program.definitions) orelse return error.InvalidBytecode;
            const result_type = instruction.value_type orelse return error.InvalidBytecode;
            const result = catalogue.definition(result_type, program.definitions) orelse return error.InvalidBytecode;
            // RFC-0087, W2: a `weak_map` is looked up as a map is.
            if (map != .map and map != .weak_map) return error.InvalidBytecode;
            const entries = catalogue.entryShape(registers[lookup.map], program.definitions).?;
            if (result != .option or entries.key != registers[lookup.key] or result.option != entries.value) return error.InvalidBytecode;
            return result_type;
        },
        .logic_not => |operand| {
            try operandType(operand, registers, .logic);
            return .logic;
        },
        .logic_binary => |binary| {
            try operandType(binary.lhs, registers, .logic);
            try operandType(binary.rhs, registers, .logic);
            return .logic;
        },
        .compare => |comparison| {
            if (comparison.lhs >= registers.len or comparison.rhs >= registers.len) return error.InvalidBytecode;
            const input_type = registers[comparison.lhs];
            try operandType(comparison.rhs, registers, input_type);
            if (comparison.op == .equal or comparison.op == .unequal) {
                if (!catalogue.comparableIn(input_type, comparable)) return error.InvalidBytecode;
            } else if (input_type != .i64 and input_type != .float and !catalogue.isRational(input_type, program.definitions)) return error.InvalidBytecode;
            return .logic;
        },
        .load_cell => |cell| {
            try validCell(cell);
            return .i64;
        },
        .begin => {
            if (depth.* == transaction.default_bounds.depth) return error.DepthLimit;
            depth.* += 1;
        },
        .commit, .abort => {
            if (depth.* == 0) return error.InvalidBytecode;
            depth.* -= 1;
        },
        .store_cell => |store| {
            if (depth.* == 0) return error.InvalidBytecode;
            try validCell(store.cell);
            try operandType(store.value, registers, .i64);
        },
        .require => |operand| try operandType(operand, registers, .logic),
        .enqueue => |intent| {
            if (depth.* == 0) return error.InvalidBytecode;
            try operandType(intent.argument, registers, .i64);
        },
        // RFC-0082. Where these may stand is the body's matter (`verifySites`).
        .spawn => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
            if (shape != .callable or shape.callable.decides or !shape.callable.detail.suspends) return error.InvalidBytecode;
            const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return error.InvalidBytecode;
            if (parameters != .tuple or parameters.tuple.end != parameters.tuple.start) return error.InvalidBytecode;
            const handle = instruction.value_type orelse return error.InvalidBytecode;
            const target = catalogue.definition(handle, program.definitions) orelse return error.InvalidBytecode;
            if (target != .task or target.task.result != shape.callable.result) return error.InvalidBytecode;
            return handle;
        },
        .sleep => |operand| {
            try operandType(operand, registers, .float);
            const unit = instruction.value_type orelse return error.InvalidBytecode;
            const shape = catalogue.definition(unit, program.definitions) orelse return error.InvalidBytecode;
            if (shape != .tuple or shape.tuple.end != shape.tuple.start) return error.InvalidBytecode;
            return unit;
        },
        .canceling => return .logic,
        .cancel_exit => {
            const result = instruction.value_type orelse return error.InvalidBytecode;
            if (!catalogue.validType(result, program.definitions)) return error.InvalidBytecode;
            return result;
        },
        // P3.2: what an await yields is its task's result or its event's value, and a signal
        // carries a value of the event's type and is the unit value.
        .task_await, .event_await => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
            const yields: types.Type = switch (shape) {
                .task => |task| if (instruction.op == .task_await) task.result else return error.InvalidBytecode,
                .event => |event| if (instruction.op == .event_await) event.value else return error.InvalidBytecode,
                // P3.7: `Await` of an `awaitable(T)`, which holds a handle or an event.
                .scheduled_interface => |interface| if (instruction.op == .task_await and interface.kind == .awaitable) interface.value else return error.InvalidBytecode,
                else => return error.InvalidBytecode,
            };
            if (instruction.value_type != yields) return error.InvalidBytecode;
            return yields;
        },
        .event_new => {
            const event = instruction.value_type orelse return error.InvalidBytecode;
            if (!catalogue.isEvent(event, program.definitions)) return error.InvalidBytecode;
            return event;
        },
        .event_signal => |signal| {
            if (signal.event >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[signal.event], program.definitions) orelse return error.InvalidBytecode;
            // P3.7: or a `signalable(T)`, which only an event is.
            const carried: types.Type = switch (shape) {
                .event => |event| event.value,
                .scheduled_interface => |interface| if (interface.kind == .signalable) interface.value else return error.InvalidBytecode,
                else => return error.InvalidBytecode,
            };
            try operandType(signal.value, registers, carried);
            const unit = instruction.value_type orelse return error.InvalidBytecode;
            const unit_shape = catalogue.definition(unit, program.definitions) orelse return error.InvalidBytecode;
            if (unit_shape != .tuple or unit_shape.tuple.end != unit_shape.tuple.start) return error.InvalidBytecode;
            return unit;
        },
        // P3.3 (rule 4): each arm a callable of no parameters that suspends and cannot fail; a
        // `sync` is the tuple of the arms' results in order, a `race` the result they share.
        .structured => |s| {
            if (!validSpan(s.arms, program.call_arguments.len)) return error.InvalidBytecode;
            const count = s.arms.end - s.arms.start;
            if (count < 2 or count > types.limits.parameters) return error.InvalidBytecode;
            const yields = instruction.value_type orelse return error.InvalidBytecode;
            const tuple: ?types.Span = if (s.kind == .sync) tuple: {
                const shape = catalogue.definition(yields, program.definitions) orelse return error.InvalidBytecode;
                if (shape != .tuple or shape.tuple.end - shape.tuple.start != count or !validSpan(shape.tuple, program.tuple_elements.len)) return error.InvalidBytecode;
                break :tuple shape.tuple;
            } else null;
            for (program.call_arguments[s.arms.start..s.arms.end], 0..) |operand, ordinal| {
                if (operand >= registers.len) return error.InvalidBytecode;
                const shape = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
                if (shape != .callable or shape.callable.decides or !shape.callable.detail.suspends) return error.InvalidBytecode;
                const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return error.InvalidBytecode;
                if (parameters != .tuple or parameters.tuple.end != parameters.tuple.start) return error.InvalidBytecode;
                const wanted = if (tuple) |elements| program.tuple_elements[elements.start + ordinal] else yields;
                if (shape.callable.result != wanted) return error.InvalidBytecode;
            }
            return yields;
        },
        // P3.4 (rule 4): a callable of no parameters that suspends, cannot fail and yields the
        // unit value, which the branch yields too.
        .branch => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const shape = catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode;
            if (shape != .callable or shape.callable.decides or !shape.callable.detail.suspends) return error.InvalidBytecode;
            const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return error.InvalidBytecode;
            if (parameters != .tuple or parameters.tuple.end != parameters.tuple.start) return error.InvalidBytecode;
            const unit = instruction.value_type orelse return error.InvalidBytecode;
            const unit_shape = catalogue.definition(unit, program.definitions) orelse return error.InvalidBytecode;
            if (unit_shape != .tuple or unit_shape.tuple.end != unit_shape.tuple.start or shape.callable.result != unit) return error.InvalidBytecode;
            return unit;
        },
        // P3.7: a request to a task by its handle, which is the unit value; and the clock.
        .task_cancel => |operand| {
            if (operand >= registers.len or !catalogue.isTask(registers[operand], program.definitions)) return error.InvalidBytecode;
            const unit = instruction.value_type orelse return error.InvalidBytecode;
            const unit_shape = catalogue.definition(unit, program.definitions) orelse return error.InvalidBytecode;
            if (unit_shape != .tuple or unit_shape.tuple.end != unit_shape.tuple.start) return error.InvalidBytecode;
            return unit;
        },
        .elapsed_time => {
            if (instruction.value_type != .float) return error.InvalidBytecode;
            return .float;
        },
        // RFC-0087, P5.3 (admission rule 6): a `string` of an earlier register, and an option of
        // an earlier `string`; that the types are persistable, `verifyJson`.
        .json_encode => |operand| {
            if (operand >= registers.len or instruction.value_type != .string) return error.InvalidBytecode;
            return .string;
        },
        .json_decode => |operand| {
            try operandType(operand, registers, .string);
            const made = instruction.value_type orelse return error.InvalidBytecode;
            const shape = catalogue.definition(made, program.definitions) orelse return error.InvalidBytecode;
            if (shape != .option) return error.InvalidBytecode;
            return made;
        },
        // RFC-0086, P2.3 (admission rule 2): a known kind, a name that is a `string`, and the
        // type `option(grant(kind))` the catalogue holds.
        .grant => |g| {
            // RFC-0087, P5.4 (rule 3): the session has no name and is no option.
            if (g.kind == .session) {
                const made = instruction.value_type orelse return error.InvalidBytecode;
                if (g.name != types.no_grant_name or catalogue.grantKind(made, program.definitions) != types.GrantKind.session) return error.InvalidBytecode;
                return made;
            }
            if (g.kind != .reader and g.kind != .writer and g.kind != .key) return error.InvalidBytecode;
            try operandType(g.name, registers, .string);
            const made = instruction.value_type orelse return error.InvalidBytecode;
            const option = switch (catalogue.definition(made, program.definitions) orelse return error.InvalidBytecode) {
                .option => |element| element,
                else => return error.InvalidBytecode,
            };
            if (catalogue.grantKind(option, program.definitions) != g.kind) return error.InvalidBytecode;
            return made;
        },
        // RFC-0084, P4.6, rule 1: a guard within `<reads>` of no parameters that yields an
        // option of what the site yields.
        .await_guard => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const guard = switch (catalogue.definition(registers[operand], program.definitions) orelse return error.InvalidBytecode) {
                .callable => |shape| shape,
                else => return error.InvalidBytecode,
            };
            const parameters = catalogue.definition(guard.parameters, program.definitions) orelse return error.InvalidBytecode;
            if (parameters != .tuple or parameters.tuple.end != parameters.tuple.start) return error.InvalidBytecode;
            const yielded = catalogue.definition(guard.result, program.definitions) orelse return error.InvalidBytecode;
            const effect = guard.effects();
            if (yielded != .option or effect.writes or effect.allocates or effect.decides or effect.suspends) return error.InvalidBytecode;
            if (instruction.value_type != yielded.option) return error.InvalidBytecode;
            return yielded.option;
        },
        // P3.9 (C113): a subscription of a subscribable event, whose callback has exactly the
        // callback type of the event's value type, is a `cancelable`.
        .event_subscribe => |s| {
            if (s.event >= registers.len or s.callback >= registers.len) return error.InvalidBytecode;
            const event = catalogue.eventShape(registers[s.event], program.definitions) orelse return error.InvalidBytecode;
            if (event.kind != .subscribable or !subscriptionCallback(program, registers[s.callback], event.value)) return error.InvalidBytecode;
            const made = instruction.value_type orelse return error.InvalidBytecode;
            if (!catalogue.isCancelable(made, program.definitions)) return error.InvalidBytecode;
            return made;
        },
        .subscription_cancel => |operand| {
            if (operand >= registers.len or !catalogue.isCancelable(registers[operand], program.definitions)) return error.InvalidBytecode;
            const unit = instruction.value_type orelse return error.InvalidBytecode;
            const unit_shape = catalogue.definition(unit, program.definitions) orelse return error.InvalidBytecode;
            if (unit_shape != .tuple or unit_shape.tuple.end != unit_shape.tuple.start) return error.InvalidBytecode;
            return unit;
        },
        // The second half of a subscribable event's `Signal`: one argument, the value.
        .event_notify => |n| {
            if (n.callable >= registers.len or !validSpan(n.arguments, program.call_arguments.len) or n.arguments.end - n.arguments.start != 1) return error.InvalidBytecode;
            const event = catalogue.eventShape(registers[n.callable], program.definitions) orelse return error.InvalidBytecode;
            if (event.kind != .subscribable) return error.InvalidBytecode;
            try operandType(program.call_arguments[n.arguments.start], registers, event.value);
            const unit = instruction.value_type orelse return error.InvalidBytecode;
            const unit_shape = catalogue.definition(unit, program.definitions) orelse return error.InvalidBytecode;
            if (unit_shape != .tuple or unit_shape.tuple.end != unit_shape.tuple.start) return error.InvalidBytecode;
            return unit;
        },
        // RFC-0085, I1 (admission rules 2 to 4): a variable cell of the operand's type; a read of
        // one, which yields its value type; a write of a value of that type, which it yields.
        .ref_new => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            const made = instruction.value_type orelse return error.InvalidBytecode;
            const held = catalogue.refValue(made, program.definitions) orelse return error.InvalidBytecode;
            if (held != registers[operand]) return error.InvalidBytecode;
            return made;
        },
        .ref_get => |operand| {
            if (operand >= registers.len) return error.InvalidBytecode;
            return catalogue.refValue(registers[operand], program.definitions) orelse error.InvalidBytecode;
        },
        .ref_set => |r| {
            if (r.ref >= registers.len) return error.InvalidBytecode;
            const held = catalogue.refValue(registers[r.ref], program.definitions) orelse return error.InvalidBytecode;
            try operandType(r.value, registers, held);
            return held;
        },
    }
    return null;
}
/// P3.9 (C108): whether `value_type` is the callback type of a `subscribable_event(value)`:
/// `function<transacts>(tuple(value), void)`, no more and no less.
fn subscriptionCallback(program: Program, value_type: types.Type, value: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    if (shape != .callable or !shape.callable.transacts or shape.callable.decides or @as(u8, @bitCast(shape.callable.detail)) != @as(u8, @bitCast(types.EffectDetail{}))) return false;
    const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start != 1 or !validSpan(parameters.tuple, program.tuple_elements.len) or program.tuple_elements[parameters.tuple.start] != value) return false;
    const result = catalogue.definition(shape.callable.result, program.definitions) orelse return false;
    return result == .tuple and result.tuple.end == result.tuple.start;
}
/// What each state operation needs of the function it is in (RFC-0078): `reads` to observe an
/// instance or a cell, `writes` to change one, `allocates` to make an instance.
fn heapPermits(node: types.Node, declared: types.EffectSet) bool {
    switch (node.kind) {
        .object_new, .spawn, .event_new => return declared.allocates,
        .cell_read, .object_get, .task_await, .event_await => return declared.reads,
        .cell_init, .cell_write, .object_set, .event_signal => return declared.writes,
        // P3.7: a request writes, as a signal does; the clock is read.
        .task_cancel => return declared.writes,
        .elapsed_time => return declared.reads,
        // RFC-0086, P2.3: the run's grants are read.
        .grant => return declared.reads,
        // RFC-0087, P5.4: a keyed cell is read and written as a cell is.
        .weak_get => return declared.reads,
        .weak_init, .weak_set => return declared.writes,
        // RFC-0084, rule 6: reads for the guard, writes for the cell, allocates for the record.
        .cell_live, .object_live => return declared.reads and declared.writes and declared.allocates,
        // P4.4: reads for the guard, allocates for the handle.
        .reaction => return declared.reads and declared.allocates,
        // P4.6: reads for the guard of an `Await`.
        .await_guard => return declared.reads,
        // P3.9: a subscription writes its event and builds its `cancelable`; a cancellation
        // writes; the callbacks of a `Signal` may do all three (C113).
        .event_subscribe => return declared.writes and declared.allocates,
        .subscription_cancel => return declared.writes,
        .event_notify => return declared.reads and declared.writes and declared.allocates,
        // RFC-0085, I1: a declaration makes a variable cell and writes it (nothing observable is
        // allocated, V4); a read reads it and an assignment writes it.
        .ref_new, .ref_set => return declared.writes,
        .ref_get => return declared.reads,
        else => return true,
    }
}
/// Whether a function declaring `caller` may call one declaring `callee`: every heap effect of
/// the callee is the caller's too, and only a suspending function calls a suspending one.
fn callAllowed(callee: types.EffectSet, caller: types.EffectSet) bool {
    if (callee.suspends and !caller.suspends) return false;
    // RFC-0085, rule 9: only what predicts is called from what predicts.
    if (callee.dictates and !caller.dictates) return false;
    return callee.heap().within(caller);
}
/// Whether a predicting function may hold `node` whatever its operands (RFC-0085, rule 9):
/// not a native that dictates, a live form or a notification of callbacks, which dictate.
fn predictsHere(p: Program, node: types.Node) bool {
    switch (node.kind) {
        .native_call => |c| return c.native < p.natives.len and !native.dictates(p.natives[c.native]),
        .cell_live, .object_live, .reaction, .batch, .await_guard, .event_notify => return false,
        else => return true,
    }
}
/// Root code never suspends (RFC-0078), so it calls nothing that may. For a verified instruction.
fn suspendsAtRoot(instruction: Instruction, registers: []const types.Type, program: Program) bool {
    switch (instruction.op) {
        .call => |c| return program.functions[c.function].detail.suspends,
        .iterate => |i| return program.functions[i.function].detail.suspends,
        .invoke => |i| return catalogue.definition(registers[i.callable], program.definitions).?.callable.detail.suspends,
        .loop => |l| return catalogue.definition(registers[l.callable], program.definitions).?.callable.detail.suspends,
        .iterate_value => |i| return catalogue.definition(registers[i.callable], program.definitions).?.callable.detail.suspends,
        // Nor does it sleep, await, wait for arms or check for cancellation (RFC-0082).
        .sleep, .canceling, .cancel_exit, .task_await, .event_await, .structured => return true,
        .branch => return true,
        // Nor ask a task to cancel (P3.7), nor await a guard (RFC-0084, P4.6).
        .task_cancel => return true,
        .await_guard => return true,
        else => return false,
    }
}
/// The value an upcast yields: an instance unchanged, a function at the wider type it is now
/// used at (RFC-0078). A function held as `any` keeps its own type, which a type test asks
/// for (RFC-0080).
fn upcastValue(value: types.Value, value_type: types.Type) types.Value {
    if (value_type == types.Type.any) return value;
    // RFC-0087, W3: the aggregate of a map made a `weak_map` carries its new type.
    if (value == .aggregate) return .{ .aggregate = .{ .value_type = value_type, .elements = value.aggregate.elements } };
    if (value != .callable) return value;
    var widened = value;
    widened.callable.value_type = value_type;
    return widened;
}
/// Whether an aggregate of this type is a map's, whose keys are checked when it is built: a
/// `map(K, V)` or, from RFC-0087, a `weak_map(K, V)` literal.
fn keyedAggregate(program: Program, value_type: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions).?;
    return shape == .map or shape == .weak_map;
}
/// The dynamic type test of `instance_of` and `downcast`. Instances answer by their class and
/// what it inherits; a value of any other form has the one type its form or its tag names,
/// which is how a value held as `any` (RFC-0080) is told apart without boxing it.
fn hasType(program: Program, value: types.Value, wanted: types.Type) bool {
    switch (value) {
        .object => |object| return catalogue.subtype(object.value_type, wanted, program.definitions),
        .aggregate => |aggregate| return aggregate.value_type == wanted,
        .enumeration => |enumeration| return enumeration.value_type == wanted,
        // A function is also of every function type that allows more effects (RFC-0081).
        .callable => |callable| return callable.value_type == wanted or catalogue.widens(callable.value_type, wanted, program.definitions, program.tuple_elements),
        .rational => return catalogue.isRational(wanted, program.definitions),
        .integer => return wanted == .i64,
        .floating => return wanted == .float,
        .boolean => return wanted == .logic,
        .string => return wanted == .string,
    }
}

/// Whether a value of a refinement's base lies within its bounds (RFC-0083). No comparison holds
/// for a NaN, so none is within any.
fn withinBounds(refinement: types.Refinement, value: types.Value) bool {
    if (refinement.base == .i64) {
        const low: i64 = @bitCast(refinement.low);
        const high: i64 = @bitCast(refinement.high);
        return value.integer >= low and value.integer <= high;
    }
    const x = value.floating;
    const low: f64 = @bitCast(refinement.low);
    const high: f64 = @bitCast(refinement.high);
    const above = if (refinement.low_open) x > low else x >= low;
    const below = if (refinement.high_open) x < high else x <= high;
    return above and below;
}

fn classType(program: Program, value_type: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    return shape == .class and !catalogue.pendingClass(shape.class);
}
fn operandType(index: u32, registers: []const types.Type, required: types.Type) VerifyError!void {
    if (index >= registers.len or registers[index] != required) return error.InvalidBytecode;
}
fn validCell(cell: u32) VerifyError!void {
    if (cell >= transaction.default_bounds.cells) return error.InvalidBytecode;
}
fn validSpan(span: types.Span, length: usize) bool {
    return span.start <= span.end and span.end <= length;
}
fn stringBoundary(index: u32, strings: []const u8) bool {
    assert(index <= strings.len);
    return index == strings.len or strings[index] & 0xc0 != 0x80;
}
fn arithmetic(op: types.BinaryOp, lhs: i64, rhs: i64) RuntimeError!i64 {
    return switch (op) {
        .add => std.math.add(i64, lhs, rhs),
        .subtract => std.math.sub(i64, lhs, rhs),
        .multiply => std.math.mul(i64, lhs, rhs),
        .divide => blk: {
            if (rhs == 0) return error.DivisionByZero;
            if (lhs == std.math.minInt(i64) and rhs == -1) return error.Overflow;
            break :blk @divTrunc(lhs, rhs);
        },
        .quotient, .modulo => blk: {
            // Euclidean division from the truncating pair: a negative remainder moves up by
            // |rhs| and the quotient one step away from it. The pair whose quotient does not
            // fit is an error for both operations.
            if (rhs == 0) return error.DivisionByZero;
            if (lhs == std.math.minInt(i64) and rhs == -1) return error.Overflow;
            const truncated = @divTrunc(lhs, rhs);
            const remainder = @rem(lhs, rhs);
            if (remainder >= 0) break :blk if (op == .quotient) truncated else remainder;
            // Here |remainder| < |rhs|, so neither correction can leave the range.
            if (op == .quotient) break :blk if (rhs > 0) truncated - 1 else truncated + 1;
            break :blk if (rhs > 0) remainder + rhs else remainder - rhs;
        },
        .bit_and => @as(i64, @bitCast(@as(u64, @bitCast(lhs)) & @as(u64, @bitCast(rhs)))),
        .bit_or => @as(i64, @bitCast(@as(u64, @bitCast(lhs)) | @as(u64, @bitCast(rhs)))),
        .bit_xor => @as(i64, @bitCast(@as(u64, @bitCast(lhs)) ^ @as(u64, @bitCast(rhs)))),
    };
}
/// Greatest common divisor by shifts and subtraction; `gcd(0, n)` is `n`.
fn commonDivisor(first: u64, second: u64) u64 {
    if (first == 0) return second;
    if (second == 0) return first;
    var a = first;
    var b = second;
    const shared: u6 = @intCast(@ctz(a | b));
    a >>= @intCast(@ctz(a));
    while (true) {
        b >>= @intCast(@ctz(b));
        if (a > b) std.mem.swap(u64, &a, &b);
        b -= a;
        if (b == 0) return a << shared;
    }
}
/// A term of a rational from its magnitude and sign, or an overflow outside `i64`.
fn rationalTerm(magnitude: u128, negative: bool) RuntimeError!i64 {
    const limit: u128 = @as(u128, std.math.maxInt(i64)) + @intFromBool(negative);
    if (magnitude > limit) return error.Overflow;
    if (!negative) return @intCast(magnitude);
    return @intCast(-@as(i128, @intCast(magnitude)));
}
/// Rational arithmetic by cross-reduction: common factors leave before terms are multiplied,
/// so with operands in lowest terms the result is in lowest terms and an operation overflows
/// exactly when a term of that result is outside `i64`. Written apart from the reference
/// evaluator, which reduces the full 128-bit answer instead.
fn rationalStep(r: types.RationalNode, values: []const types.Value) RuntimeError!types.Value {
    if (r.op == .make) {
        if (values[r.lhs] != .integer or values[r.rhs] != .integer) return error.InvalidBytecode;
        const top = values[r.lhs].integer;
        const bottom = values[r.rhs].integer;
        // The compiler guards the divisor; forged code is rejected here.
        if (bottom == 0) return error.DivisionByZero;
        const shared = commonDivisor(@abs(top), @abs(bottom));
        const negative = top != 0 and (top < 0) != (bottom < 0);
        return .{ .rational = .{ .numerator = try rationalTerm(@abs(top) / shared, negative), .denominator = try rationalTerm(@abs(bottom) / shared, false) } };
    }
    if (values[r.lhs] != .rational or values[r.rhs] != .rational) return error.InvalidBytecode;
    const a = values[r.lhs].rational;
    const b = values[r.rhs].rational;
    if (a.denominator <= 0 or b.denominator <= 0) return error.InvalidBytecode;
    const a_bottom: u64 = @intCast(a.denominator);
    const b_bottom: u64 = @intCast(b.denominator);
    switch (r.op) {
        .make => unreachable,
        .multiply => {
            const left = commonDivisor(@abs(a.numerator), b_bottom);
            const right = commonDivisor(@abs(b.numerator), a_bottom);
            const top = @as(u128, @abs(a.numerator) / left) * (@abs(b.numerator) / right);
            const bottom = @as(u128, a_bottom / right) * (b_bottom / left);
            return .{ .rational = .{ .numerator = try rationalTerm(top, top != 0 and (a.numerator < 0) != (b.numerator < 0)), .denominator = try rationalTerm(bottom, false) } };
        },
        .add, .subtract => {
            const shared = commonDivisor(a_bottom, b_bottom);
            const ours = @as(i128, a.numerator) * (b_bottom / shared);
            const theirs = @as(i128, b.numerator) * (a_bottom / shared);
            const sum = if (r.op == .add) ours + theirs else ours - theirs;
            // What the sum still shares with the denominators divides their common part.
            const rest = commonDivisor(@intCast(@abs(sum) % shared), shared);
            const bottom = @as(u128, a_bottom / shared) * (b_bottom / rest);
            return .{ .rational = .{ .numerator = try rationalTerm(@abs(sum) / rest, sum < 0), .denominator = try rationalTerm(bottom, false) } };
        },
        .negate => return .{ .rational = .{ .numerator = try std.math.negate(a.numerator), .denominator = a.denominator } },
        .floor => {
            const truncated = @divTrunc(a.numerator, a.denominator);
            return .{ .integer = if (a.numerator < 0 and @rem(a.numerator, a.denominator) != 0) truncated - 1 else truncated };
        },
        .ceil => {
            const truncated = @divTrunc(a.numerator, a.denominator);
            return .{ .integer = if (a.numerator > 0 and @rem(a.numerator, a.denominator) != 0) truncated + 1 else truncated };
        },
        .to_float => return .{ .floating = rationalToFloat(a) },
    }
}
/// The binary64 nearest to the fraction, ties to even: a quotient of 55 or 56 bits, rounded
/// by hand to 53 with the division's remainder as the sticky bit, then scaled exactly.
fn rationalToFloat(value: types.Rational) f64 {
    @setFloatMode(.strict);
    if (value.numerator == 0) return 0.0;
    const top: u64 = @abs(value.numerator);
    const bottom: u64 = @intCast(value.denominator);
    // 2^(width-1) < top/bottom < 2^(width+1), so the shifted quotient lies in (2^54, 2^56).
    const width: i32 = @as(i32, 64 - @as(i32, @clz(top))) - @as(i32, 64 - @as(i32, @clz(bottom)));
    const shift: i32 = 55 - width;
    const dividend: u128 = if (shift >= 0) @as(u128, top) << @intCast(shift) else top;
    const divisor: u128 = if (shift >= 0) bottom else @as(u128, bottom) << @intCast(-shift);
    const quotient: u64 = @intCast(dividend / divisor);
    const inexact = dividend % divisor != 0;
    const extra: u6 = if (quotient >> 55 != 0) 3 else 2;
    var mantissa = quotient >> extra;
    const dropped = quotient & ((@as(u64, 1) << extra) - 1);
    const half = @as(u64, 1) << (extra - 1);
    if (dropped > half or (dropped == half and (inexact or mantissa & 1 == 1))) mantissa += 1;
    // At most 2^53, which converts exactly; the scale is a power of two in the normal range.
    const magnitude = std.math.scalbn(@as(f64, @floatFromInt(mantissa)), @as(i32, extra) - shift);
    return if (value.numerator < 0) -magnitude else magnitude;
}
fn floatArithmetic(op: types.BinaryOp, lhs: f64, rhs: f64) f64 {
    @setFloatMode(.strict);
    assert(types.isCanonicalFloat(lhs));
    assert(types.isCanonicalFloat(rhs));
    const result = switch (op) {
        .add => lhs + rhs,
        .subtract => lhs - rhs,
        .multiply => lhs * rhs,
        .divide => lhs / rhs,
        .quotient, .modulo => unreachable, // The verifier keeps these on integers.
        // The verifier rejects a bitwise operator on floats.
        .bit_and, .bit_or, .bit_xor => unreachable,
    };
    return types.canonicalFloat(result);
}
/// RFC-0087, P5.4 (K1): the run's one session.
fn sessionValue(session_type: types.Type) types.Value {
    return .{ .enumeration = .{ .value_type = session_type, .index = 0 } };
}
fn runtimeCode(err: RuntimeError) types.Diagnostic.Code {
    return switch (err) {
        error.Overflow => .arithmetic_overflow,
        error.DivisionByZero => .division_by_zero,
        error.IndexRange => .index_out_of_range,
        error.RequirementFailed => .requirement_failed,
        error.AggregateLimit => .aggregate_limit,
        error.NativeFailed => .native_failed,
        error.StringLimit => .string_limit,
        error.InvalidNative => .invalid_native,
        error.WorkLimit => .work_limit,
        error.DuplicateKey => .duplicate_map_key,
        // The host, not the guest's budget: the machine lends its own levels, so this is the
        // table of a map literal too large for the native stack.
        error.ScratchUnavailable => .scratch_unavailable,
        error.DepthLimit => .transaction_limit,
        error.UndoLimit, error.SourceUndoLimit => .undo_limit,
        error.SourceDepthLimit => .transaction_limit,
        error.ObjectLimit => .object_limit,
        error.IntentLimit => .intent_limit,
        error.OutboxLimit => .outbox_limit,
        error.EffectLimit => .effect_limit,
        error.EffectPrepareFailed => .effect_prepare_failed,
        error.EffectCommitFailed => .effect_commit_failed,
        error.InputLimit => .input_limit,
        error.InputFailed => .input_failed,
        error.InputUnavailable => .input_unavailable,
        error.InputInvalid => .input_invalid,
        error.InputDiverged => .input_diverged,
        error.TaskLimit => .task_limit,
        error.SchedulerActionLimit => .scheduler_action_limit,
        error.SuspendedFrameLimit => .suspended_frame_limit,
        error.CallTraceLimit => .call_trace_limit,
        error.CallDepthLimit => .call_depth_limit,
        error.CallRegisterLimit => .call_register_limit,
        error.InvalidSleepDuration => .invalid_sleep_duration,
        else => .invalid_bytecode,
    };
}
fn failure(span: types.Span, code: types.Diagnostic.Code) Result {
    return .{ .failed = .{ .span = span, .code = code } };
}
const LiveOutcome = union(enum) { ok: types.Value, failed: types.Diagnostic };
fn liveRuntimeCode(err: live_machine.Error) types.Diagnostic.Code {
    return switch (err) {
        error.LiveEdgeLimit => .live_edge_limit,
        error.WorkLimit => .work_limit,
        else => |other| runtimeCode(other),
    };
}
/// Whether a verified program holds a `cell_live` or an `object_live` (RFC-0084), at the root
/// or in a function.
fn holdsLive(program: Program) bool {
    for (program.code) |instruction| if (instruction.op == .cell_live or instruction.op == .object_live or instruction.op == .reaction or instruction.op == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .cell_live or entry.node.kind == .object_live or entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}
/// P4.4: a program with a `reaction` takes a drain's turns one at a time at the top of the loop.
fn holdsReaction(program: Program) bool {
    for (program.code) |instruction| if (instruction.op == .reaction or instruction.op == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}
/// Where an establishing write puts its record: a module cell, its own owner, or the field
/// `place` of the instance `owner` (P4.2), which is the cell `cell` of the run.
const LiveSpot = struct { cell: u32, owner: ?types.ObjectRef, place: u32, value_type: types.Type, initialize: bool };
fn cellSpot(program: Program, c: types.CellLive) LiveSpot {
    return .{ .cell = c.cell, .owner = null, .place = c.cell, .value_type = program.source_cells[c.cell].value_type, .initialize = c.initialize };
}
/// The place an `object_live` writes, by the type of its object register: a `var` or
/// live-only field of a class (RFC-0084, rule 2), or field 0 of a variable cell `ref(T)`, its
/// value (RFC-0085, rule 6, I14), which is never live-only. Null for anything else.
const LiveSpotType = struct { value_type: types.Type, live_only: bool };
fn liveSpotOf(p: Program, object_type: types.Type, field: u32) ?LiveSpotType {
    const item = catalogue.definition(object_type, p.definitions) orelse return null;
    switch (item) {
        .ref => |held| return if (field == 0) .{ .value_type = held, .live_only = false } else null,
        .class => {
            const declared = catalogue.classFieldAt(object_type, field, p.definitions, p.fields) orelse return null;
            if (!declared.is_var and !declared.live_only) return null;
            return .{ .value_type = declared.value_type, .live_only = declared.live_only };
        },
        else => return null,
    }
}
fn fieldSpot(instance: types.ObjectRef, c: types.ObjectLive, value_type: types.Type) LiveSpot {
    return .{ .cell = instance.id + 1 + c.field, .owner = instance, .place = c.field, .value_type = value_type, .initialize = false };
}
const no_register = std.math.maxInt(u32);
/// RFC-0084, P4.2: a call of the clauses of a class with live fields hands them the instance of
/// the latest construction (`latest`), or one upcast of it (`casts` says which register each
/// upcast reads); nothing else reaches them (C28).
fn clausesReached(instruction: Instruction, program: Program, casts: []const u32, latest: u32) bool {
    switch (instruction.op) {
        .function_value => |id| return id >= program.functions.len or program.functions[id].clauses_of == null,
        .iterate => |i| return i.function >= program.functions.len or program.functions[i.function].clauses_of == null,
        .call => |c| {
            if (c.function >= program.functions.len or program.functions[c.function].clauses_of == null) return true;
            if (!validSpan(c.arguments, program.call_arguments.len) or c.arguments.end - c.arguments.start != 1) return false;
            var operand = program.call_arguments[c.arguments.start];
            if (operand < casts.len and casts[operand] != no_register) operand = casts[operand];
            return operand == latest;
        },
        else => return true,
    }
}
/// RFC-0084, P4.2: the clauses of a class are a named `(Self:Class):logic` that neither decides
/// nor suspends.
fn clausesForm(p: Program, f: types.RuntimeFunction) bool {
    const class = f.clauses_of orelse return true;
    const item = catalogue.definition(class, p.definitions) orelse return false;
    if (item != .class or item.class.is_interface or f.anonymous or f.decides or f.detail.suspends) return false;
    return f.parameter_count == 1 and f.parameters[0] == class and f.value_type == .logic;
}
/// The record type of a target type, which verification found in the catalogue.
fn liveTypeFor(program: Program, target: types.Type) ?types.Type {
    for (program.definitions, 0..) |item, index| {
        if (item == .live and item.live == target) return @fromBackingInt(@intCast(catalogue.builtin_count + index));
    }
    return null;
}
/// The node that made a record: a root instruction, or a function's node (upper half one more
/// than the function).
fn liveOrigin(program: Program, journal: *const source_state.Journal, record: u32) types.Span {
    const origin: u64 = @bitCast(journal.cells[record + catalogue.live_origin].value.integer);
    const pc: u32 = @truncate(origin);
    if (origin >> 32 == 0) return program.code[pc].span;
    const f = program.functions[(origin >> 32) - 1];
    return program.function_nodes[f.body.start + pc].node.span;
}
/// RFC-0084, admission rule 1: no parameters, the target's type, within `<reads>`.
fn guardShape(program: Program, guard: types.Type, target: types.Type) bool {
    const callable = switch (catalogue.definition(guard, program.definitions) orelse return false) {
        .callable => |shape| shape,
        else => return false,
    };
    const parameters = catalogue.definition(callable.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.end != parameters.tuple.start or callable.result != target) return false;
    const effect = callable.effects();
    return !effect.writes and !effect.allocates and !effect.decides and !effect.suspends;
}
fn invalid() Verification {
    return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .invalid_bytecode } };
}

/// RFC-0092, B4: each class marked `final_super` names a superclass that is a class, and each
/// class directly below a `final_super_base` class is marked; interfaces and instantiations
/// carry neither mark.
fn verifyFinalSupers(definitions: []const types.Definition) error{InvalidBytecode}!void {
    for (definitions, 0..) |item, index| {
        if (item != .class) continue;
        const class = item.class;
        if (class.is_interface or class.arguments != null) {
            if (class.final_super or class.final_super_base) return error.InvalidBytecode;
        }
        if (class.parent) |parent| {
            const id = @backingInt(parent);
            if (id < catalogue.builtin_count or id - catalogue.builtin_count >= index) return error.InvalidBytecode;
            const above = definitions[id - catalogue.builtin_count];
            if (above != .class) return error.InvalidBytecode;
            if (above.class.final_super_base and !class.final_super) return error.InvalidBytecode;
        } else if (class.final_super) return error.InvalidBytecode;
    }
}

/// RFC-0087, P5.2, admission rule 2, in this machine's own terms: the constants first, each a
/// value of a persistable type built of earlier constants, then the definitions that carry the
/// flag, each keeping the rules of its kind, then the fields that name a constant.
fn verifyPersistable(program: Program) error{ InvalidBytecode, ScratchUnavailable }!void {
    const definitions = program.definitions;
    const constants = program.constants;
    const pool = program.constant_members;
    if (constants.len > types.limits.template_nodes or pool.len > types.limits.aggregate_elements) return error.InvalidBytecode;
    var any_flag = false;
    for (definitions) |item| {
        if (item == .record and item.record.persistable) any_flag = true;
        if (item == .class and item.class.persistable) any_flag = true;
        if (item == .enumeration and item.enumeration.persistable) any_flag = true;
    }
    if (!any_flag) {
        if (constants.len + pool.len != 0) return error.InvalidBytecode;
        for (program.fields) |field| if (field.constant != null) return error.InvalidBytecode;
        return;
    }
    const kinds = scratch.alloc(bool, definitions.len) orelse return error.ScratchUnavailable;
    defer scratch.free(kinds);
    persistable.persistableTypes(definitions, program.tuple_elements, kinds);
    var maps: usize = 0;
    for (constants, 0..) |constant, index| {
        const value_type = constant.value_type;
        if (!persistable.isPersistable(value_type, definitions, kinds)) return error.InvalidBytecode;
        switch (constant.kind) {
            .integer => if (value_type != .i64) return error.InvalidBytecode,
            .boolean => if (value_type != .logic) return error.InvalidBytecode,
            .floating => |value| if (value_type != .float or !types.isCanonicalFloat(value)) return error.InvalidBytecode,
            .string => |span| if (value_type != .string or !validSpan(span, program.strings.len) or !stringBoundary(span.start, program.strings) or !stringBoundary(span.end, program.strings)) return error.InvalidBytecode,
            .character => |code| if (!value_type.isCharacter() or !types.validCharacter(value_type, code)) return error.InvalidBytecode,
            .enumeration => |case| {
                const shape = catalogue.definition(value_type, definitions) orelse return error.InvalidBytecode;
                if (shape != .enumeration or case >= shape.enumeration.cases.end - shape.enumeration.cases.start) return error.InvalidBytecode;
            },
            .aggregate => |span| {
                if (!validSpan(span, pool.len)) return error.InvalidBytecode;
                const parts = pool[span.start..span.end];
                for (parts) |part| if (part >= index) return error.InvalidBytecode;
                const shape = catalogue.definition(value_type, definitions) orelse return error.InvalidBytecode;
                switch (shape) {
                    .option => |element| if (parts.len > 1 or (parts.len == 1 and constants[parts[0]].value_type != element)) return error.InvalidBytecode,
                    .array => |element| for (parts) |part| if (constants[part].value_type != element) return error.InvalidBytecode,
                    .map => |entry| {
                        if (parts.len & 1 != 0) return error.InvalidBytecode;
                        var at: usize = 0;
                        while (at < parts.len) : (at += 2) if (constants[parts[at]].value_type != entry.key or constants[parts[at + 1]].value_type != entry.value) return error.InvalidBytecode;
                        maps += 1;
                    },
                    .tuple => |elements| {
                        if (parts.len != elements.end - elements.start) return error.InvalidBytecode;
                        for (parts, elements.start..) |part, at| if (constants[part].value_type != program.tuple_elements[at]) return error.InvalidBytecode;
                    },
                    .record => |record| {
                        if (parts.len != record.fields.end - record.fields.start) return error.InvalidBytecode;
                        for (parts, record.fields.start..) |part, at| if (constants[part].value_type != program.fields[at].value_type) return error.InvalidBytecode;
                    },
                    else => return error.InvalidBytecode,
                }
            },
        }
    }
    // Every field, by the definition that holds it: a flagged one's fields are persistable and
    // may name a constant of their type; no other field names one.
    for (definitions) |item| {
        var flagged = false;
        var span: types.Span = .{ .start = 0, .end = 0 };
        switch (item) {
            .record => |record| {
                span = record.fields;
                flagged = record.persistable;
                if (flagged and (record.arguments != null or record.metatype)) return error.InvalidBytecode;
            },
            .class => |class| {
                span = class.fields;
                flagged = class.persistable;
                if (flagged and (class.is_interface or class.is_abstract or !class.is_final or class.is_unique or class.parent != null or class.inherited != 0 or class.interface_count != 0 or class.arguments != null)) return error.InvalidBytecode;
            },
            else => continue,
        }
        for (program.fields[span.start..span.end]) |field| {
            if (!flagged) {
                if (field.constant != null) return error.InvalidBytecode;
                continue;
            }
            if (field.is_var or field.live_only or !persistable.isPersistable(field.value_type, definitions, kinds)) return error.InvalidBytecode;
            if (field.constant) |constant| if (constant >= constants.len or constants[constant].value_type != field.value_type) return error.InvalidBytecode;
        }
    }
    if (maps == 0) return;
    // No map constant has two keys the language calls equal.
    const classes = scratch.alloc(u32, constants.len) orelse return error.ScratchUnavailable;
    defer scratch.free(classes);
    const table = scratch.alloc(u32, persistable.workSize(constants.len)) orelse return error.ScratchUnavailable;
    defer scratch.free(table);
    persistable.equalityClasses(constants, pool, program.strings, classes, table);
    // A key's class is marked while its map is checked and cleared after, so each map costs
    // what it holds.
    const marked = scratch.alloc(bool, constants.len) orelse return error.ScratchUnavailable;
    defer scratch.free(marked);
    @memset(marked, false);
    for (constants) |constant| {
        if (constant.kind != .aggregate or catalogue.definition(constant.value_type, definitions).? != .map) continue;
        const parts = pool[constant.kind.aggregate.start..constant.kind.aggregate.end];
        var at: usize = 0;
        var duplicate = false;
        while (at < parts.len) : (at += 2) {
            if (marked[classes[parts[at]]]) duplicate = true;
            marked[classes[parts[at]]] = true;
        }
        at = 0;
        while (at < parts.len) : (at += 2) marked[classes[parts[at]]] = false;
        if (duplicate) return error.InvalidBytecode;
    }
}

test "enum literals cost one instruction and partial fuel rolls back active writes" {
    const machine = try scratch.storage(Machine);
    defer scratch.release(machine);
    scratch.initialise(machine);
    const mode: types.Type = @fromBackingInt(@intCast(4));
    const cases = [_]types.Span{.{ .start = 5, .end = 9 }};
    const definitions = [_]types.Definition{.{ .enumeration = .{
        .name = .{ .start = 0, .end = 4 },
        .cases = .{ .start = 0, .end = 1 },
        .is_public = false,
    } }};
    var code = [_]Instruction{
        .{ .value_type = .i64, .op = .{ .integer = 29 } },
        .{ .op = .begin },
        .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
        .{ .value_type = mode, .op = .{ .enumeration = 0 } },
        .{ .op = .commit },
    };
    const program: Program = .{ .source = "mode Dark", .code = &code, .definitions = &definitions, .cases = &cases };
    try machine.journal.begin();
    try machine.journal.write(0, 11);
    try machine.journal.enqueue(.{ .kind = 7, .argument = 11 });
    try machine.journal.commit();
    for (0..code.len) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.work_limit, machine.run(program, @intCast(budget)).failed.code);
        try std.testing.expectEqual(@as(i64, 11), try machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 0), machine.journal.depth);
        try std.testing.expectEqual(@as(usize, 0), machine.journal.undo_count);
        try std.testing.expectEqual(@as(usize, 1), machine.journal.committed().len);
        try std.testing.expectEqual(@as(i64, 11), machine.journal.committed()[0].argument);
    }
    const values = machine.run(program, code.len).ok;
    try std.testing.expectEqual(@as(i64, 29), try machine.journal.read(0));
    try std.testing.expectEqualDeep(types.EnumValue{ .value_type = mode, .index = 0 }, values[1].enumeration);
    const prior_values = machine.values[0..2].*;
    code[3].op.enumeration = 1;
    // The full verifier rejects the unreachable bad case before any write,
    // independently of both zero fuel and the previous successfully run code.
    for ([_]u32{ 0, code.len }) |budget| {
        try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, machine.run(program, budget).failed.code);
        try std.testing.expectEqualDeep(prior_values, machine.values[0..2].*);
        try std.testing.expectEqual(@as(i64, 29), try machine.journal.read(0));
        try std.testing.expectEqual(@as(usize, 1), machine.journal.committed().len);
    }
    code[3].op.enumeration = 0;
    try std.testing.expectEqualDeep(prior_values, machine.run(program, code.len).ok[0..2].*);
}

fn numericCompare(op: types.CompareOp, left: anytype, right: @TypeOf(left)) bool {
    return switch (op) {
        // NaN is told by its bits (`types.isNan`), not by comparing a float with itself.
        .equal => left == right or (if (@TypeOf(left) == f64) types.isNan(left) and types.isNan(right) else false),
        .unequal => !(left == right or (if (@TypeOf(left) == f64) types.isNan(left) and types.isNan(right) else false)),
        .less => left < right,
        .less_equal => left <= right,
        .greater => left > right,
        .greater_equal => left >= right,
    };
}
fn compareValues(op: types.CompareOp, left: types.Value, right: types.Value, members: []const types.Value, key_work: *keys.Work, remaining: *u64, comptime fully_funded: bool) RuntimeError!bool {
    return switch (left) {
        .integer => |value| numericCompare(op, value, right.integer),
        .floating => |value| numericCompare(op, value, right.floating),
        .boolean => |value| if (op == .equal) value == right.boolean else value != right.boolean,
        .enumeration => |value| if (op == .equal) value.index == right.enumeration.index else value.index != right.enumeration.index,
        .object => |value| if (op == .equal) value.id == right.object.id else value.id != right.object.id,
        // Positive denominators keep the order of the cross products, which are exact.
        .rational => |value| numericCompare(op, std.math.mulWide(i64, value.numerator, right.rational.denominator), std.math.mulWide(i64, right.rational.numerator, value.denominator)),
        .string => |value| string: {
            if (fully_funded) unreachable; // The independently recomputed count excludes this path.
            const cost = @min(value.len, right.string.len);
            if (cost > remaining.*) return error.WorkLimit;
            remaining.* -= cost;
            const equal = std.mem.eql(u8, value, right.string);
            break :string if (op == .equal) equal else !equal;
        },
        .aggregate => structure: {
            if (fully_funded) unreachable; // The independently recomputed count excludes this path.
            // Only `==` and `!=` are admitted for structural types.
            const same = try keys.equal(key_work, members, left, right, remaining);
            break :structure if (op == .equal) same else !same;
        },
        .callable => unreachable, // Whole-bytecode operand admission excludes it.
    };
}

fn sourceOperation(instruction: Instruction) bool {
    return switch (instruction.op) {
        .cell_init, .cell_read, .cell_write, .object_new, .object_get, .object_set, .spawn => true,
        .task_await, .event_new, .event_signal, .event_await => true,
        .cell_live => true,
        .object_live => true,
        .reaction => true,
        .task_cancel => true,
        .await_guard => true,
        .event_subscribe, .subscription_cancel, .event_notify => true,
        .ref_new, .ref_get, .ref_set => true,
        // RFC-0087, P5.4.
        .weak_init, .weak_get, .weak_set => true,
        // RFC-0087, P5.3: the codec reads and builds instances.
        .json_encode, .json_decode => true,
        else => false,
    };
}
/// The source operations on instances, which name no cell: `spawn` builds its handle, and the
/// operations of P3.2 build events and read or write handles and events.
fn objectOperation(node: types.Node) bool {
    return switch (node.kind) {
        .object_new, .object_get, .object_set, .spawn, .task_await, .event_new, .event_signal, .event_await => true,
        .object_live => true,
        .reaction => true,
        .task_cancel => true,
        // RFC-0084, P4.6: an `Await` names no cell; its guard reads what it reads.
        .await_guard => true,
        .event_subscribe, .subscription_cancel, .event_notify => true,
        // RFC-0085, I1: variable cells are instances.
        .ref_new, .ref_get, .ref_set => true,
        // RFC-0087, P5.3: the codec reads and builds instances, and names no cell.
        .json_encode, .json_decode => true,
        else => false,
    };
}
fn controlOperation(instruction: Instruction) bool {
    return switch (instruction.op) {
        .if_begin, .attempt_begin, .otherwise, .merge, .demand, .fail, .exit, .err, .iterate, .recur, .invoke, .iterate_value, .loop, .bind, .native_call, .string_concat, .array_concat, .array_set, .map_set, .map_remove, .to_string => true,
        .text => |t| t.op == .valid or t.op == .join,
        .spawn, .sleep, .canceling, .cancel_exit => true,
        .task_await, .event_new, .event_signal, .event_await => true,
        .structured => true,
        .branch => true,
        .cell_live => true,
        .object_live => true,
        .arm_exit, .arm_exited, .arm_exit_value => true,
        .reaction => true,
        .task_cancel, .elapsed_time => true,
        .batch => true,
        .await_guard => true,
        .event_notify => true,
        // RFC-0086, P2.3: as a native call, it reads what the run was given.
        .grant => true,
        // RFC-0087, P5.4: it builds a map, as `map_set` does.
        .weak_set => true,
        // RFC-0087, P5.3: the codec runs in the control loop, which holds the instances.
        .json_encode, .json_decode => true,
        else => false,
    };
}
fn controlBranch(instruction: Instruction) types.Branch {
    return if (instruction.op == .if_begin) instruction.op.if_begin else instruction.op.attempt_begin;
}
const Available = struct {
    bits: [types.limits.nodes / 64 + 1]u64 = undefined,
    limit: usize = 0,
    /// Clears the bits of `count` registers; the rest are never read by a body of that length.
    fn init(self: *Available, count: usize) void {
        @memset(self.bits[0 .. count / 64 + 1], 0);
        self.limit = count;
    }
    fn has(self: *const Available, index: u32) bool {
        return index < self.limit and (self.bits[index / 64] & (@as(u64, 1) << @as(u6, @intCast(index % 64)))) != 0;
    }
    fn set(self: *Available, index: usize, value: bool) void {
        const bit = @as(u64, 1) << @as(u6, @intCast(index % 64));
        if (value) self.bits[index / 64] |= bit else self.bits[index / 64] &= ~bit;
    }
};
// Independent availability/intersection pass. The first-arm root is checked at
// its boundary, then its entire register interval is hidden before the fallback.
// Nested merges survive inside their arm; nested arm-local values cannot escape.
fn verifyControl(program: Program) bool {
    return verifyControlBody(program, false, &.{}, null, false);
}
fn controlAt(program: Program, comptime body: bool, nodes: []const types.FunctionNode, index: usize) Instruction {
    return if (body) instructionFromNode(nodes[index].node) else program.code[index];
}
fn verifyControlBody(program: Program, comptime body: bool, nodes: []const types.FunctionNode, root: ?u32, allows_failure: bool) bool {
    const length = if (body) nodes.len else program.code.len;
    if (length > types.limits.nodes) return false;
    const Frame = struct { begin: u32, second: bool = false };
    var frames: [types.limits.control_depth]Frame = undefined;
    var depth: usize = 0;
    var available: Available = undefined;
    available.init(length);
    for (0..length) |index| {
        const instruction = controlAt(program, body, nodes, index);
        if (instruction.value_type == null) return false; // Control programs use 1:1 registers, no legacy journal op mixing.
        switch (instruction.op) {
            .cell_init, .cell_write => |c| if (!available.has(c.value)) {
                return false;
            },
            .object_new => |c| for (program.call_arguments[c.arguments.start..c.arguments.end]) |operand| {
                if (!available.has(operand)) return false;
            },
            .object_get => |a| if (!available.has(a.value)) {
                return false;
            },
            .instance_of => |c| if (!available.has(c.value)) {
                return false;
            },
            .method_value => |m| if (!available.has(m.receiver)) {
                return false;
            },
            .object_set => |c| if (!available.has(c.object) or !available.has(c.value)) {
                return false;
            },
            .negate, .float_negate, .int_to_float, .string_length, .to_string, .logic_not, .array_length, .option_present, .demand, .fail, .exit, .err, .local_set, .upcast, .downcast, .spawn, .sleep, .refine, .task_await, .event_await, .branch, .arm_exit, .task_cancel, .await_guard => |operand| if (!available.has(operand)) {
                return false;
            },
            .event_signal => |signal| if (!available.has(signal.event) or !available.has(signal.value)) {
                return false;
            },
            .cell_live => |c| if (!available.has(c.guard)) {
                return false;
            },
            .object_live => |c| if (!available.has(c.object) or !available.has(c.guard)) {
                return false;
            },
            .reaction => |r| if (!available.has(r.guard) or !available.has(r.body)) {
                return false;
            },
            .batch => |n| if (!available.has(n)) {
                return false;
            },
            .event_subscribe => |s| if (!available.has(s.event) or !available.has(s.callback)) {
                return false;
            },
            .subscription_cancel => |n| if (!available.has(n)) {
                return false;
            },
            .ref_new, .ref_get => |n| if (!available.has(n)) {
                return false;
            },
            .ref_set => |r| if (!available.has(r.ref) or !available.has(r.value)) {
                return false;
            },
            .grant => |g| if (g.kind != .session and !available.has(g.name)) {
                return false;
            },
            .weak_get => |g| if (!available.has(g.key)) {
                return false;
            },
            .weak_set => |c| if (!available.has(c.key) or !available.has(c.value)) {
                return false;
            },
            // RFC-0087, P5.3: the value or the text.
            .json_encode, .json_decode => |n| if (!available.has(n)) {
                return false;
            },
            .event_notify => |n| {
                if (!available.has(n.callable)) return false;
                for (program.call_arguments[n.arguments.start..n.arguments.end]) |operand| if (!available.has(operand)) return false;
            },
            .structured => |s| for (program.call_arguments[s.arms.start..s.arms.end]) |operand| {
                if (!available.has(operand)) return false;
            },
            .binary, .float_binary => |b| if (!available.has(b.lhs) or !available.has(b.rhs)) {
                return false;
            },
            .rational => |b| if (!available.has(b.lhs) or !available.has(b.rhs)) {
                return false;
            },
            .logic_binary => |b| if (!available.has(b.lhs) or !available.has(b.rhs)) {
                return false;
            },
            .compare => |b| if (!available.has(b.lhs) or !available.has(b.rhs)) {
                return false;
            },
            .field, .tuple_element => |a| if (!available.has(a.value)) {
                return false;
            },
            .option_or => |c| if (!available.has(c.option) or !available.has(c.fallback)) {
                return false;
            },
            .map_lookup, .map_remove => |l| if (!available.has(l.map) or !available.has(l.key)) {
                return false;
            },
            .float_to_int => |c| if (!available.has(c.operand)) {
                return false;
            },
            .array_get, .map_key, .map_value => |a| if (!available.has(a.array) or !available.has(a.index)) {
                return false;
            },
            .array_set => |a| if (!available.has(a.array) or !available.has(a.index) or !available.has(a.value)) {
                return false;
            },
            .map_set => |a| if (!available.has(a.map) or !available.has(a.key) or !available.has(a.value)) {
                return false;
            },
            .option_value => |operand| if (!available.has(operand)) {
                return false;
            },
            .native_call => |c| for (c.args[0..c.count]) |operand| {
                if (!available.has(operand)) return false;
            },
            .string_concat, .array_concat => |c| if (!available.has(c.lhs) or !available.has(c.rhs)) {
                return false;
            },
            .text => |t| switch (t.op) {
                .code, .from_code, .valid, .join => if (!available.has(t.a)) return false,
                .unit, .boundary, .scalar => if (!available.has(t.a) or !available.has(t.b)) return false,
                .slice => if (!available.has(t.a) or !available.has(t.b) or !available.has(t.c)) return false,
            },
            .loop => |l| if (!available.has(l.callable) or !available.has(l.initial)) {
                return false;
            },
            .iterate_value => |i| if (!available.has(i.callable) or !available.has(i.count) or !available.has(i.initial)) {
                return false;
            },
            .iterate => |i| if (!available.has(i.count) or !available.has(i.initial)) {
                return false;
            },
            .invoke, .bind => |i| {
                if (!available.has(i.callable)) return false;
                for (program.call_arguments[i.arguments.start..i.arguments.end]) |operand| if (!available.has(operand)) return false;
            },
            .recur => |r| for (program.call_arguments[r.start..r.end]) |operand| {
                if (!available.has(operand)) return false;
            },
            .call => |c| for (program.call_arguments[c.arguments.start..c.arguments.end]) |operand| {
                if (!available.has(operand)) return false;
            },
            .aggregate => |r| for (program.members[r.start..r.end]) |operand| {
                if (!available.has(operand)) return false;
            },
            .if_begin => |b| if (!available.has(b.condition)) {
                return false;
            },
            else => {},
        }
        switch (instruction.op) {
            .cell_init => if (depth != 0) {
                return false;
            },
            // RFC-0087, P5.4: and a keyed cell's.
            .weak_init => if (depth != 0) {
                return false;
            },
            // A live declaration initialises its cell as `cell_init` does (RFC-0084).
            .cell_live => |c| if (c.initialize and depth != 0) {
                return false;
            },
            .if_begin, .attempt_begin => |b| {
                if (depth == frames.len or b.alternative <= index or b.end <= b.alternative or b.end >= length) return false;
                const alternate = controlAt(program, body, nodes, b.alternative);
                const merge = controlAt(program, body, nodes, b.end);
                if (alternate.op != .otherwise or alternate.op.otherwise != index or merge.op != .merge or merge.op.merge.begin != index) return false;
                frames[depth] = .{ .begin = @intCast(index) };
                depth += 1;
            },
            .otherwise => |begin| {
                if (depth == 0 or frames[depth - 1].begin != begin or frames[depth - 1].second or controlBranch(controlAt(program, body, nodes, begin)).alternative != index) return false;
                const merge = controlAt(program, body, nodes, controlBranch(controlAt(program, body, nodes, begin)).end);
                if (!available.has(merge.op.merge.left)) return false;
                for (begin + 1..index) |register| available.set(register, false);
                frames[depth - 1].second = true;
            },
            .merge => |m| {
                if (depth == 0 or frames[depth - 1].begin != m.begin or !frames[depth - 1].second or controlBranch(controlAt(program, body, nodes, m.begin)).end != index or !available.has(m.right)) return false;
                for (m.begin..index) |register| available.set(register, false);
                depth -= 1;
            },
            .demand, .fail, .call, .iterate, .invoke, .iterate_value, .loop => {
                if (instruction.op == .invoke or instruction.op == .iterate_value or instruction.op == .loop) {
                    const operand = if (instruction.op == .invoke) instruction.op.invoke.callable else if (instruction.op == .iterate_value) instruction.op.iterate_value.callable else instruction.op.loop.callable;
                    const callee_type = controlAt(program, body, nodes, operand).value_type.?;
                    if (!catalogue.definition(callee_type, program.definitions).?.callable.decides) {
                        available.set(index, true);
                        continue;
                    }
                }
                if (instruction.invocation()) |invocation| {
                    if (!program.functions[invocation.target()].decides) {
                        available.set(index, true);
                        continue;
                    }
                }
                var caught = allows_failure;
                for (frames[0..depth]) |frame| if (!frame.second and controlAt(program, body, nodes, frame.begin).op == .attempt_begin) {
                    caught = true;
                };
                if (!caught) return false;
            },
            .begin, .commit, .abort, .load_cell, .store_cell, .require, .enqueue => return false,
            else => {},
        }
        if (instruction.op != .if_begin and instruction.op != .attempt_begin and instruction.op != .otherwise) available.set(index, true);
    }
    if (depth != 0) return false;
    for (program.bindings) |binding| if (!available.has(binding.node)) return false;
    for (program.globals) |global| if (!available.has(global.node)) return false;
    if (root) |index| if (!available.has(index)) return false;
    return true;
}

fn sourceVisible(program: Program, index: u32, span: types.Span) bool {
    return functionVisible(program, program.source_cells[index].name, program.source_cells[index].is_public, span);
}

/// What a public declaration may expose when files declare modules (RFC-0074); unused, and
/// costing nothing, for a program without them.
const Reach = struct {
    privacy: ?catalogue.Privacy = null,
    /// RFC-0087, P5.3: the facts admission rule 6 reads, when the program has a JSON node.
    json: persistable.JsonFacts = .{},

    fn open(self: *Reach, program: Program) bool {
        if (program.nested.len == 0) return true;
        self.privacy = catalogue.Privacy.create(program.definitions, program.tuple_elements, program.modules, program.nested);
        return self.privacy != null;
    }

    fn close(self: *Reach) void {
        if (self.privacy) |held| held.destroy();
        self.json.release();
    }

    /// Whether the declaration at `name` may mention `value_type`.
    fn exposes(self: *const Reach, exposed: []const bool, value_type: types.Type, name: types.Span, is_public: bool) bool {
        if (!is_public) return true;
        if (self.privacy) |held| return held.admits(value_type, name, true);
        return catalogue.exportable(value_type, exposed);
    }
};
/// RFC-0087, P5.3: the facts of admission rule 6, worked out when the program holds a JSON
/// instruction or node.
fn verifyJsonFacts(program: Program) error{OutOfMemory}!persistable.JsonFacts {
    var needed = false;
    for (program.code) |instruction| needed = needed or instruction.op == .json_encode or instruction.op == .json_decode;
    for (program.function_nodes) |entry| needed = needed or (entry.input == .operation and (entry.node.kind == .json_encode or entry.node.kind == .json_decode));
    if (!needed) return .{};
    return persistable.JsonFacts.of(program.definitions, program.tuple_elements, program.fields);
}
/// RFC-0087, P5.3 (admission rule 6): an encode's value and a decode's result are persistable.
/// `verifyOperation` has typed the operand.
fn verifyJson(op: @FieldType(Instruction, "op"), value_type: ?types.Type, registers: []const types.Type, program: Program, json: persistable.JsonFacts) bool {
    switch (op) {
        .json_encode => |operand| return operand < registers.len and json.persistableType(registers[operand], program.definitions),
        .json_decode => {
            const made = value_type orelse return false;
            const shape = catalogue.definition(made, program.definitions) orelse return false;
            return shape == .option and json.persistableType(shape.option, program.definitions);
        },
        else => return true,
    }
}
/// RFC-0087, P5.3 (admission rule 6): a function that encodes what reaches a class reads, and
/// one that decodes it allocates.
fn jsonPermits(node: types.Node, registers: []const types.Type, program: Program, json: persistable.JsonFacts, declared: types.EffectSet) bool {
    switch (node.kind) {
        .json_encode => |operand| return operand < registers.len and (declared.reads or !json.reachesClass(registers[operand], program.definitions)),
        .json_decode => {
            const shape = catalogue.definition(node.value_type, program.definitions) orelse return false;
            return shape == .option and (declared.allocates or !json.reachesClass(shape.option, program.definitions));
        },
        else => return true,
    }
}
/// RFC-0087, P5.3: the machine's host of the JSON codec, whose instances are the journal's cells.
const MachineJson = struct {
    source: *source_state.Journal,
    problem: source_state.Error = error.SourceCellIndex,

    pub fn field(self: *MachineJson, object: types.ObjectRef, index: u32) error{Host}!types.Value {
        return self.source.read(object.id + 1 + index) catch |err| {
            self.problem = err;
            return error.Host;
        };
    }
    pub fn instance(self: *MachineJson, class: types.Type, cells: []const types.Value, block: u32) error{Host}!u32 {
        _ = class;
        _ = block;
        return self.source.allocate(cells) catch |err| {
            self.problem = err;
            return error.Host;
        };
    }
    pub fn instanceMark(self: *MachineJson) usize {
        return self.source.cell_count;
    }
    pub fn instanceDrop(self: *MachineJson, mark: usize) void {
        self.source.truncate(mark);
    }
};
fn verifySourceCells(program: Program, reach: *const Reach) bool {
    if (program.source_cells.len > types.limits.source_cells) return false;
    if (program.source_cells.len == 0) return true; // Typed operation/count admission remains mandatory.
    var exposed: [types.limits.user_types]bool = undefined;
    if (program.modules.len != 0) catalogue.exportableTypes(program.definitions, program.fields, program.tuple_elements, &exposed);
    var last_write: ?usize = null;
    for (program.code, 0..) |instruction, index| if (instruction.op == .cell_init or instruction.op == .cell_write or instruction.op == .cell_live) {
        last_write = index;
    };
    // One table of the cells by module and name replaces a scan of the earlier cells for each
    // cell and a scan of all bindings for each cell: both grew with the product of the counts.
    var table = name_index.Index.create(program.source_cells.len) orelse return false;
    defer table.destroy();
    const last_module: u32 = if (program.modules.len == 0) 0 else @intCast(program.modules.len - 1);
    var bound = false;
    for (program.source_cells, 0..) |cell, id| {
        if (!validSpan(cell.name, program.source.len) or !catalogue.validType(cell.value_type, program.definitions) or cell.initial >= program.code.len) return false;
        // RFC-0087, P5.4 (rule 4): a cell is keyed exactly when its type says so.
        if (cell.keyed != catalogue.keyedKind(cell.value_type, program.definitions)) return false;
        const text = cell.name.text(program.source);
        if (text.len == 0 or text.len > types.limits.identifier_bytes) return false;
        for (text, 0..) |byte, position| {
            if (byte == '_' or std.ascii.isAlphabetic(byte) or (position != 0 and std.ascii.isDigit(byte))) continue;
            return false;
        }
        const defining = if (program.modules.len == 0) null else modules.home(cell.name, program.modules, program.nested) orelse return false;
        if (defining != null and !reach.exposes(exposed[0..program.definitions.len], cell.value_type, cell.name, cell.is_public)) return false;
        const init = program.code[cell.initial];
        // Declared by its initialisation: a `cell_init`, or a `cell_live` that initialises, the
        // only one a live-only cell may have (RFC-0084).
        const declares = switch (init.op) {
            .cell_init => |c| c.cell == id and !cell.live_only,
            .cell_live => |c| c.cell == id and c.initialize,
            .weak_init => |c| c == id and cell.keyed != .none and !cell.live_only,
            else => false,
        };
        if (!declares or init.value_type != cell.value_type or !std.meta.eql(init.span, cell.name)) return false;
        var slot = table.probe(name_index.hashName(defining orelse 0, text));
        while (slot.next()) |other_id| {
            const other = program.source_cells[other_id];
            if ((defining == null or modules.home(other.name, program.modules, program.nested) == defining) and std.mem.eql(u8, other.name.text(program.source), text)) return false;
        }
        slot.claim(@intCast(id));
        if (defining == null or defining.? == last_module) bound = true;
    }
    if (!keyedOperations(program)) return false;
    // RFC-0087, P5.5 (rule 4): a persistent cell saves its entries, so its value type is persistable.
    if (!(persistable.persistentCellsValid(program.definitions, program.tuple_elements, program.source_cells) catch false)) return false;
    // Bindings belong to the last module; they are checked only against the cells declared there.
    if (!bound) return true;
    for (program.bindings) |binding| {
        if (!validSpan(binding.name, program.source.len)) return false;
        const text = binding.name.text(program.source);
        var slot = table.probe(name_index.hashName(last_module, text));
        while (slot.next()) |id| {
            const cell = program.source_cells[id];
            if (program.modules.len != 0 and modules.home(cell.name, program.modules, program.nested).? != last_module) continue;
            if (!std.mem.eql(u8, text, cell.name.text(program.source))) continue;
            // RFC-0087, P5.4 (W8): a keyed cell's binding is its declaration, never a read.
            if (cell.keyed != .none) {
                if (binding.node != cell.initial or binding.value_type != cell.value_type or binding.is_public != cell.is_public or !std.meta.eql(binding.name, cell.name)) return false;
                continue;
            }
            if (binding.node >= program.code.len or binding.node <= last_write.? or binding.value_type != cell.value_type or binding.is_public != cell.is_public or !std.meta.eql(binding.name, cell.name)) return false;
            const read = program.code[binding.node];
            if (read.op != .cell_read or read.op.cell_read != id) return false;
        }
    }
    return true;
}

/// RFC-0087, P5.4 (rule 4): no operation of a cell names a keyed one, and no operation of a
/// keyed cell names another, at the root or in a function.
fn keyedOperations(program: Program) bool {
    for (program.code) |instruction| if (!keyedOperand(program, instruction)) return false;
    for (program.function_nodes) |entry| if (entry.input == .operation and !keyedOperand(program, instructionFromNode(entry.node))) return false;
    return true;
}
fn keyedOperand(program: Program, instruction: Instruction) bool {
    const id: u32, const of_keyed = switch (instruction.op) {
        .cell_init, .cell_write => |c| .{ c.cell, false },
        .cell_read => |c| .{ c, false },
        .cell_live => |c| .{ c.cell, false },
        .weak_init => |c| .{ c, true },
        .weak_get => |g| .{ g.cell, true },
        .weak_set => |c| .{ c.cell, true },
        else => return true,
    };
    if (id >= program.source_cells.len) return true; // Refused where it is typed.
    return of_keyed == (program.source_cells[id].keyed != .none);
}
/// RFC-0087, P5.4: the key and value types of a keyed cell; null for any other cell.
fn keyedEntries(program: Program, cell: u32) ?types.Map {
    if (cell >= program.source_cells.len or program.source_cells[cell].keyed == .none) return null;
    const shape = catalogue.definition(program.source_cells[cell].value_type, program.definitions) orelse return null;
    return if (shape == .weak_map) shape.weak_map else null;
}

// Independent bytecode catalogue/type admission. Body nodes are immutable
// borrowed encoding; decode maps tags only, never trusts IR validation.
/// Whether the code at `use` may name the declaration at `name` (RFC-0074). Climbing from the
/// declaration's module to its file, the user is either inside the scope reached, where
/// everything climbed past is in sight, or outside it, and then what was climbed past must be
/// public: first the declaration, then each module around it. A file is left through an import.
fn functionVisible(p: Program, name: types.Span, public: bool, use: types.Span) bool {
    if (p.modules.len == 0) return true;
    const using = modules.home(use, p.modules, p.nested) orelse return false;
    var scope = modules.home(name, p.modules, p.nested) orelse return false;
    var leaves = public;
    var steps: usize = 0;
    while (steps <= types.limits.module_depth + 1) : (steps += 1) {
        if (modules.inside(using, scope, p.modules, p.nested)) return true;
        if (!leaves) return false;
        if (scope < p.modules.len) {
            const file = modules.owner(use, p.modules).?;
            for (p.imports[p.modules[file].imports.start..p.modules[file].imports.end]) |edge| if (edge.target == scope) return true;
            return false;
        }
        leaves = p.nested[scope - p.modules.len].is_public;
        scope = modules.enclosing(scope, p.modules, p.nested).?;
    }
    return false;
}
fn verifyFunctions(p: Program, root_types: []const types.Type, comparable: []const bool, reach: *const Reach) bool {
    if (p.functions.len > types.limits.functions or p.function_nodes.len > types.limits.template_nodes or p.function_members.len > types.limits.aggregate_elements or p.function_arguments.len > types.limits.call_arguments or p.call_arguments.len > types.limits.call_arguments or p.globals.len > types.limits.bindings) return false;
    var exposed: [types.limits.user_types]bool = undefined;
    if (p.modules.len != 0) catalogue.exportableTypes(p.definitions, p.fields, p.tuple_elements, &exposed);
    // Names of cells and captured bindings, found by hash. Scanning them for every binding and
    // every function cost the product of the counts on each admission.
    const cell_count: u32 = @intCast(p.source_cells.len);
    var taken = name_index.Index.create(p.source_cells.len + p.globals.len) orelse return false;
    defer taken.destroy();
    for (p.source_cells, 0..) |cell, id| {
        // Cell names were checked against each other by `verifySourceCells`; here they are only entered.
        var slot = taken.probe(nameHash(p, cell.name));
        while (slot.next()) |_| {}
        slot.claim(@intCast(id));
    }
    for (p.globals, 0..) |g, id| {
        if (!validSpan(g.name, p.source.len) or !functionName(g.name.text(p.source)) or g.node >= root_types.len or root_types[g.node] != g.value_type) return false;
        if (p.modules.len != 0 and (modules.owner(g.name, p.modules) == null or !reach.exposes(exposed[0..p.definitions.len], g.value_type, g.name, g.is_public))) return false;
        var slot = taken.probe(nameHash(p, g.name));
        while (slot.next()) |item| if (sameName(p, g.name, if (item < cell_count) p.source_cells[item].name else p.globals[item - cell_count].name)) return false;
        slot.claim(cell_count + @as(u32, @intCast(id)));
    }
    var body_end: u32 = 0;
    var member_end: u32 = 0;
    var argument_end: u32 = 0;
    var available: u32 = 0;
    var longest_body: usize = 0;
    for (p.functions) |f| {
        if (f.body.end >= f.body.start and f.body.end <= p.function_nodes.len) longest_body = @max(longest_body, f.body.end - f.body.start);
    }
    const local = scratch.alloc(types.Type, longest_body) orelse return false;
    defer scratch.free(local);
    const methods = catalogue.methodFunctions(p.dispatch);
    var declared = name_index.Index.create(p.functions.len) orelse return false;
    defer declared.destroy();
    const groups = scratch.alloc(NameGroup, p.functions.len) orelse return false;
    defer scratch.free(groups);
    for (p.functions, 0..) |f, id| {
        if (!validSpan(f.name, p.source.len) or !functionName(f.name.text(p.source)) or !validSpan(f.body, p.function_nodes.len) or f.body.start != body_end or f.body.start == f.body.end or f.root >= f.body.end - f.body.start or f.parameter_count > types.limits.parameters or !catalogue.validType(f.value_type, p.definitions) or f.available_at < available or f.available_at > p.code.len) return false;
        const anonymous_name = std.mem.eql(u8, f.name.text(p.source), "Fn");
        // The body of a `Spawn{...}` is anonymous too, named by its keyword (RFC-0082); a function
        // a program names `Spawn` is not.
        const spawn_body = f.anonymous and std.mem.eql(u8, f.name.text(p.source), "Spawn");
        // So is that of a `Branch{...}` (P3.4).
        const branch_body = f.anonymous and std.mem.eql(u8, f.name.text(p.source), "Branch");
        // So is a live guard, by the word `live` (RFC-0084).
        const guard_body = f.anonymous and std.mem.eql(u8, f.name.text(p.source), "live");
        // RFC-0085, I3 (admission rule 8): a nested function is anonymous and named by its
        // declared name, which the flag alone admits.
        const nested_function = f.nested and nestedFunction(p, f);
        if (f.nested and !nested_function) return false;
        if (!nested_function and ((f.anonymous != anonymous_name and !spawn_body and !branch_body and !guard_body) or (f.anonymous and f.is_public))) return false;
        if (!validGenericCode(p, f, comparable) or !clausesForm(p, f)) return false;
        // RFC-0082, P3.6: an arm that may exit is an anonymous function that suspends, and its
        // pending exits have a type.
        if (f.exits) |exits| if (!f.anonymous or !f.detail.suspends or f.decides or f.clauses_of != null or !catalogue.validType(exits, p.definitions)) return false;
        if (p.modules.len != 0 and modules.owner(f.name, p.modules) == null) return false;
        if (p.modules.len != 0 and !reach.exposes(exposed[0..p.definitions.len], f.value_type, f.name, f.is_public)) return false;
        for (f.parameters[0..f.parameter_count]) |t| if (!catalogue.validType(t, p.definitions) or (p.modules.len != 0 and !reach.exposes(exposed[0..p.definitions.len], t, f.name, f.is_public))) return false;
        {
            // The earlier functions that can clash with this one have its name (its position, when it
            // is anonymous). The first of them owns the slot and two lists; every later one joins a list.
            var slot = declared.probe(if (f.anonymous) name_index.hashSpan(f.name.start, f.name.end) else nameHash(p, f.name));
            const first: ?u32 = while (slot.next()) |other| {
                const candidate = &p.functions[other];
                if (f.anonymous != candidate.anonymous) continue;
                if (if (f.anonymous) std.meta.eql(f.name, candidate.name) else sameName(p, f.name, candidate.name)) break other;
            } else null;
            const is_method = methods.isSet(id);
            const mine: u32 = @intCast(id);
            if (first) |group| {
                // Implementations of a method share a name and a signature by design and are
                // exempt from each other, so a method is not walked past the other methods.
                const lists = [2]u32{ groups[group].others, if (is_method) name_index.none else groups[group].methods };
                for (lists, 0..) |list, which| {
                    // A list of the other kind holds what only the dispatch table names, or what
                    // only a name does (`methodClash`).
                    const across = is_method or which == 1;
                    var old_id = list;
                    while (old_id != name_index.none) : (old_id = groups[old_id].following) if (if (across) methodClash(p, f, p.functions[old_id]) else clash(p, f, p.functions[old_id])) return false;
                }
                const list = if (is_method) &groups[group].methods else &groups[group].others;
                groups[mine] = .{ .following = list.*, .others = name_index.none, .methods = name_index.none };
                list.* = mine;
            } else {
                slot.claim(mine);
                groups[mine] = .{ .following = name_index.none, .others = if (is_method) name_index.none else mine, .methods = if (is_method) mine else name_index.none };
            }
        }
        if (!f.anonymous) {
            var slot = taken.probe(nameHash(p, f.name));
            while (slot.next()) |item| if (sameName(p, f.name, if (item < cell_count) p.source_cells[item].name else p.globals[item - cell_count].name)) return false;
        }
        var body_p = p;
        body_p.members = p.function_members;
        body_p.call_arguments = p.function_arguments;
        var depth: usize = 0;
        var work: u32 = 0;
        var controls: u32 = 0;
        var controlled = false;
        var failures = false;
        var failable_calls = false;
        var source_ops: u32 = 0;
        var has_source = false;
        var has_local = false;
        var recursive = false;
        // The declared effect is one of the canonical sets, and no body is vouched to converge:
        // only a native's entry is (RFC-0078). Each operation below is checked against the set.
        if (!types.effectsCanonical(f.transacts, f.decides, f.detail) or f.detail.converges) return false;
        const allowed = f.effects();
        var latest: u32 = no_register;
        for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, index| {
            const node = entry.node;
            if (!validSpan(node.span, p.source.len) or (p.modules.len != 0 and modules.owner(node.span, p.modules) == null)) return false;
            switch (entry.input) {
                .parameter => |n| {
                    if (n >= f.parameter_count or node.value_type != f.parameters[n] or node.kind != .integer or node.kind.integer != 0) return false;
                },
                .global => |n| {
                    if (n >= p.globals.len or node.kind != .integer or node.kind.integer != 0) return false;
                    const g = p.globals[n];
                    if (g.node >= f.available_at or node.value_type != g.value_type or !functionVisible(p, g.name, g.is_public, node.span)) return false;
                },
                .operation => {
                    if (node.kind == .local_set) {
                        if (!allowed.writes or (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules))) return false;
                        has_local = true;
                    }
                    if (types.sourceOp(node)) {
                        if (!heapPermits(node, allowed) or (!objectOperation(node) and !verifyFunctionCell(p, f, node, local[0..index]))) return false;
                        source_ops += 1;
                        has_source = true;
                    }
                    // RFC-0087, P5.3 (admission rule 6): what reaches a class is read or built.
                    if (!jsonPermits(node, local[0..index], p, reach.json, allowed)) return false;
                    // RFC-0086, P2.3 (admission rule 2): a `grant` reads the run's grants, and
                    // `elapsed_time` the clock (RFC-0082 rule 5, C96): what `heapPermits` asks of
                    // an operation that is no source operation is checked here.
                    if (!types.sourceOp(node) and !heapPermits(node, allowed)) return false;
                    // RFC-0084, P4.2: a class's clauses are called on an instance just built, and
                    // only they attach a live-only field of their class, on their own `Self`.
                    if (!clausesCalled(p, f, node, index, latest)) return false;
                    if (node.kind == .object_new) latest = @intCast(index);
                    // The clauses never call themselves: that would hand them any instance.
                    if (f.clauses_of != null and (node.kind == .recur or node.kind == .self_value)) return false;
                    // P3.6: nor does an arm that may exit, which runs only as an arm; and no
                    // call starts one.
                    if (f.exits != null and (node.kind == .recur or node.kind == .self_value)) return false;
                    if (namesExitingArm(p, instructionFromNode(node)) and node.kind != .function_value) return false;
                    if (node.kind == .object_live) {
                        const c = node.kind.object_live;
                        if (c.object >= index) return false;
                        const field = liveSpotOf(p, local[c.object], c.field) orelse return false;
                        if (field.live_only and !ownSelf(p, f, c, local[c.object])) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    // Acting on the world, or drawing from it, is not computing (RFC-0079).
                    if (node.kind == .native_call) {
                        const called = node.kind.native_call.native;
                        if (called < p.natives.len and p.natives[called].effect != .none and !(allowed.reads and allowed.writes and allowed.allocates)) return false;
                    }
                    // RFC-0085, rule 9: what a predicting function holds predicts.
                    if (!allowed.dictates and !predictsHere(p, node)) return false;
                    if (node.kind == .object_new) {
                        const c = node.kind.object_new;
                        if (c.arguments.start != argument_end or !catalogue.dispatchReady(p.dispatch, p.functions, node.value_type, f.available_at)) return false;
                        argument_end = c.arguments.end;
                    }
                    if (node.kind == .demand or node.kind == .fail) failures = true;
                    if (types.controlOp(node)) {
                        controls += 1;
                        controlled = true;
                    }
                    if (node.kind == .iterate) {
                        const i = node.kind.iterate;
                        if (i.function >= id) return false;
                        const step = p.functions[i.function];
                        if (!callAllowed(step.effects(), allowed)) return false;
                        has_source = has_source or step.has_source;
                        has_local = has_local or step.has_local;
                        failures = failures or step.has_failure;
                        failable_calls = failable_calls or step.decides;
                        if (step.member_work != 0) work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .function_value) {
                        if (node.kind.function_value >= id) return false;
                        const child = p.functions[node.kind.function_value];
                        if (child.anonymous and f.specialization != null and modules.contains(f.generic_source, child.name) and (child.specialization != f.specialization or !sameTemplate(f.generic_source, child.generic_source))) return false;
                    }
                    if (node.kind == .self_value) {
                        if (!signatureMatches(p, node.value_type, f) or (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules))) return false;
                    }
                    if (node.kind == .loop) {
                        const l = node.kind.loop;
                        if (l.callable >= index) return false;
                        const definition = catalogue.definition(local[l.callable], p.definitions) orelse return false;
                        if (definition != .callable or !callAllowed(definition.callable.effects(), allowed)) return false;
                        has_source = has_source or definition.callable.transacts;
                        has_local = has_local or definition.callable.transacts;
                        failures = true;
                        failable_calls = failable_calls or definition.callable.decides;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .iterate_value) {
                        const i = node.kind.iterate_value;
                        if (i.callable >= index) return false;
                        const definition = catalogue.definition(local[i.callable], p.definitions) orelse return false;
                        if (definition != .callable or !callAllowed(definition.callable.effects(), allowed)) return false;
                        has_source = has_source or definition.callable.transacts;
                        has_local = has_local or definition.callable.transacts;
                        failures = true;
                        failable_calls = failable_calls or definition.callable.decides;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .bind) {
                        const b = node.kind.bind;
                        if (b.arguments.start != argument_end) return false;
                        argument_end = b.arguments.end;
                        work = @min(types.limits.aggregate_elements + 1, work + types.limits.parameters);
                    }
                    if (node.kind == .event_notify) {
                        // P3.9: it calls callbacks of `<transacts>` (heapPermits), as an `invoke`
                        // does: its regions journal what they write, and what they build is not
                        // known here.
                        const n = node.kind.event_notify;
                        if (n.callable >= index or n.arguments.start != argument_end) return false;
                        has_local = true;
                        failures = true;
                        work = types.limits.aggregate_elements + 1;
                        argument_end = n.arguments.end;
                    }
                    if (node.kind == .invoke) {
                        const i = node.kind.invoke;
                        if (i.callable >= index or i.arguments.start != argument_end) return false;
                        const shape = catalogue.definition(local[i.callable], p.definitions) orelse return false;
                        if (shape != .callable or !callAllowed(shape.callable.effects(), allowed)) return false;
                        has_source = has_source or shape.callable.transacts;
                        has_local = has_local or shape.callable.transacts;
                        failures = true;
                        failable_calls = failable_calls or shape.callable.decides;
                        work = types.limits.aggregate_elements + 1;
                        argument_end = i.arguments.end;
                    }
                    if (node.kind == .recur) {
                        recursive = true;
                        const range = node.kind.recur;
                        if (!validSpan(range, p.function_arguments.len) or range.start != argument_end or range.end - range.start != f.parameter_count or node.value_type != f.value_type) return false;
                        if (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules)) return false;
                        for (p.function_arguments[range.start..range.end], f.parameters[0..f.parameter_count]) |operand, required| if (operand >= index or local[operand] != required) return false;
                        argument_end = range.end;
                    }
                    if (node.kind == .spawn) {
                        // What the body may do lies within what the spawner may (rule 4); what a
                        // task builds is unknown to its spawner.
                        if (node.kind.spawn >= index) return false;
                        const shape = catalogue.definition(local[node.kind.spawn], p.definitions) orelse return false;
                        if (shape != .callable or !callAllowed(shape.callable.effects().heap(), allowed) or (shape.callable.effects().dictates and !allowed.dictates)) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if ((node.kind == .sleep or node.kind == .task_await or node.kind == .event_await or node.kind == .task_cancel or node.kind == .await_guard) and !allowed.suspends) return false;
                    // What a guard and the propagation after it build is not known here.
                    if (node.kind == .cell_live) work = types.limits.aggregate_elements + 1;
                    // RFC-0084, P4.6: nor what the guard of an `Await` builds.
                    if (node.kind == .await_guard) work = types.limits.aggregate_elements + 1;
                    // Guards and reaction bodies may fail inside regions of their own (I14-D11).
                    if (node.kind == .cell_live or node.kind == .object_live or node.kind == .reaction or node.kind == .await_guard) failures = true;
                    if (node.kind == .reaction) {
                        // P4.4 (rule 4): what the body may do lies within what the function may;
                        // what the guard and the body build is not known here.
                        const r = node.kind.reaction;
                        if (r.body >= index) return false;
                        const shape = catalogue.definition(local[r.body], p.definitions) orelse return false;
                        if (shape != .callable or !callAllowed(shape.callable.effects().heap(), allowed)) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .batch) {
                        // P4.5 (rule 4): what the body may do lies within what the function may.
                        // It is called as an `invoke` is: its regions journal what it writes,
                        // and what it builds is not known here.
                        if (node.kind.batch >= index) return false;
                        const shape = catalogue.definition(local[node.kind.batch], p.definitions) orelse return false;
                        if (shape != .callable or !callAllowed(shape.callable.effects().heap(), allowed)) return false;
                        has_source = has_source or shape.callable.transacts;
                        has_local = has_local or shape.callable.transacts;
                        failures = true;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .structured) {
                        // P3.3: what each arm may do lies within what the function may (rule 4);
                        // the arms follow the arguments before them; what they build is unknown.
                        const arms = node.kind.structured.arms;
                        if (!allowed.suspends or !validSpan(arms, p.function_arguments.len) or arms.start != argument_end) return false;
                        for (p.function_arguments[arms.start..arms.end]) |operand| {
                            if (operand >= index) return false;
                            const shape = catalogue.definition(local[operand], p.definitions) orelse return false;
                            if (shape != .callable or !callAllowed(shape.callable.effects().heap(), allowed) or (shape.callable.effects().dictates and !allowed.dictates)) return false;
                        }
                        argument_end = arms.end;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .branch) {
                        // P3.4: what the body may do lies within what the function may (rule 4).
                        if (!allowed.suspends or node.kind.branch >= index) return false;
                        const shape = catalogue.definition(local[node.kind.branch], p.definitions) orelse return false;
                        if (shape != .callable or !callAllowed(shape.callable.effects().heap(), allowed) or (shape.callable.effects().dictates and !allowed.dictates)) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .call) {
                        const c = node.kind.call;
                        if (c.function >= p.functions.len or c.function == id or c.arguments.start != argument_end) return false;
                        const callee = p.functions[c.function];
                        if (!callAllowed(callee.effects(), allowed)) return false;
                        failable_calls = failable_calls or callee.decides;
                        argument_end = c.arguments.end;
                        if (c.function < id) {
                            has_source = has_source or callee.has_source;
                            has_local = has_local or callee.has_local;
                            work = @min(types.limits.aggregate_elements + 1, work + callee.member_work);
                            controlled = controlled or callee.has_control;
                            failures = failures or callee.has_failure;
                        } else {
                            // RFC-0091, F1: the callee's body comes later. Only a named function
                            // published with this one's availability may be called so; its
                            // signature is all that is known of it, as for a callable.
                            if (callee.available_at != f.available_at or callee.anonymous or callee.nested or callee.clauses_of != null or callee.exits != null) return false;
                            has_source = has_source or callee.transacts;
                            has_local = has_local or callee.transacts;
                            work = types.limits.aggregate_elements + 1;
                            controlled = true;
                            failures = true;
                        }
                    }
                    if (node.kind == .exit) {
                        // What an exit returns has the result type; the exit itself has the type its
                        // place in the body expects and never yields a value there.
                        const operand = node.kind.exit;
                        if (operand >= index or local[operand] != f.value_type or !catalogue.validType(node.value_type, p.definitions)) return false;
                    }
                    if (node.kind == .arm_exit) {
                        // P3.6: what an arm's exit hands on has the type of its pending exits.
                        const operand = node.kind.arm_exit;
                        const exits = f.exits orelse return false;
                        if (operand >= index or local[operand] != exits or !catalogue.validType(node.value_type, p.definitions)) return false;
                    }
                    // `verifySites` types the two tests of a check.
                    const checks = node.kind == .arm_exit or node.kind == .arm_exited or node.kind == .arm_exit_value;
                    const t = if ((types.sourceOp(node) and !objectOperation(node)) or node.kind == .recur or node.kind == .self_value or node.kind == .exit or checks) node.value_type else verifyOperation(instructionFromNode(node), local[0..index], body_p, comparable, &depth, &member_end) catch return false;
                    if (t != node.value_type or depth != 0) return false;
                    if (!verifyJson(instructionFromNode(node).op, node.value_type, local[0..index], body_p, reach.json)) return false;
                    if (node.kind == .aggregate) work = @min(types.limits.aggregate_elements + 1, work + node.kind.aggregate.end - node.kind.aggregate.start);
                    if ((node.kind == .native_call and @backingInt(node.value_type) >= 4) or node.kind == .array_concat or node.kind == .array_set or node.kind == .map_set or node.kind == .map_remove) work = types.limits.aggregate_elements + 1;
                    // RFC-0086, P2.3: a `grant` builds an option, of a member or none.
                    if (node.kind == .grant) work = types.limits.aggregate_elements + 1;
                    // RFC-0087, P5.4: a keyed cell's update builds its map.
                    if (node.kind == .weak_set) work = types.limits.aggregate_elements + 1;
                    // RFC-0087, P5.3: a decode builds what its text holds.
                    if (node.kind == .json_decode) work = types.limits.aggregate_elements + 1;
                },
            }
            local[index] = node.value_type;
        }
        if (recursive and work != 0) work = types.limits.aggregate_elements + 1;
        if (local[f.root] != f.value_type or f.member_work != work or controls != f.control_ops or controlled != f.has_control or failures != f.has_failure or source_ops != f.source_ops or has_source != f.has_source or has_local != f.has_local) return false;
        body_p.bindings = &.{};
        body_p.globals = &.{};
        // A body with no local markers visits every verified earlier register.
        // A branching child cannot change its caller's schedule.
        if ((controls != 0 or failable_calls) and !verifyControlBody(body_p, true, p.function_nodes[f.body.start..f.body.end], f.root, f.decides)) return false;
        if (!verifySites(body_p, f, p.function_nodes[f.body.start..f.body.end], local[0 .. f.body.end - f.body.start])) return false;
        available = f.available_at;
        body_end = f.body.end;
    }
    return body_end == p.function_nodes.len and member_end == p.function_members.len and argument_end == p.function_arguments.len;
}
/// RFC-0084, P4.2: in a function, the instance handed to a class's clauses was built by the
/// latest construction before the call (`latest`), and is that node or one upcast of it; no
/// function value or iteration names them (C28).
fn clausesCalled(p: Program, f: types.RuntimeFunction, node: types.Node, index: usize, latest: u32) bool {
    const body = p.function_nodes[f.body.start..f.body.end];
    switch (node.kind) {
        .function_value => |id| return id >= p.functions.len or p.functions[id].clauses_of == null,
        .iterate => |i| return i.function >= p.functions.len or p.functions[i.function].clauses_of == null,
        .call => |c| {
            if (c.function >= p.functions.len or p.functions[c.function].clauses_of == null) return true;
            if (!validSpan(c.arguments, p.function_arguments.len) or c.arguments.end - c.arguments.start != 1) return false;
            var operand = p.function_arguments[c.arguments.start];
            if (operand >= index) return false;
            if (body[operand].input == .operation and body[operand].node.kind == .upcast) operand = body[operand].node.kind.upcast;
            return operand == latest and body[operand].input == .operation and body[operand].node.kind == .object_new;
        },
        else => return true,
    }
}
/// RFC-0084, P4.2: a live-only field is attached by the clauses of the class that declares it,
/// to the instance they were handed, which their first parameter reads.
fn ownSelf(p: Program, f: types.RuntimeFunction, c: types.ObjectLive, object_type: types.Type) bool {
    const class = f.clauses_of orelse return false;
    if (object_type != class) return false;
    const entry = p.function_nodes[f.body.start + c.object];
    if (entry.input != .parameter or entry.input.parameter != 0) return false;
    return c.field >= catalogue.definition(class, p.definitions).?.class.inherited;
}
// Independent body-source typing with root-relative declaration admission.
fn verifyFunctionCell(p: Program, f: types.RuntimeFunction, node: types.Node, prior: []const types.Type) bool {
    if (node.kind == .cell_init) return false;
    // RFC-0087, P5.4: a keyed cell is declared at the root; a function looks it up and updates it.
    if (node.kind == .weak_init) return false;
    if (node.kind == .weak_get or node.kind == .weak_set) {
        const cell, const key = switch (node.kind) {
            .weak_get => |g| .{ g.cell, g.key },
            .weak_set => |c| .{ c.cell, c.key },
            else => unreachable,
        };
        const entries = keyedEntries(p, cell) orelse return false;
        if (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules)) return false;
        if (p.source_cells[cell].initial >= f.available_at or !sourceVisible(p, cell, node.span)) return false;
        if (key >= prior.len or prior[key] != entries.key) return false;
        if (node.kind == .weak_set) {
            const value = node.kind.weak_set.value;
            return value < prior.len and prior[value] == entries.value and node.value_type == entries.value;
        }
        const option = catalogue.definition(node.value_type, p.definitions) orelse return false;
        return option == .option and option.option == entries.value;
    }
    const id = switch (node.kind) {
        .cell_read => |c| c,
        .cell_write => |c| c.cell,
        .cell_live => |c| c.cell,
        else => return false,
    };
    if (id >= p.source_cells.len) return false;
    const cell = p.source_cells[id];
    if (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules)) return false;
    if (cell.initial >= f.available_at or cell.value_type != node.value_type or !sourceVisible(p, id, node.span)) return false;
    if (node.kind == .cell_write) {
        const value = node.kind.cell_write.value;
        if (value >= prior.len or prior[value] != cell.value_type or cell.live_only) return false;
    }
    // RFC-0084: a function attaches a guard to a cell it does not declare and that is not live-only.
    if (node.kind == .cell_live) {
        const c = node.kind.cell_live;
        if (c.initialize or cell.live_only or c.guard >= prior.len or !guardShape(p, prior[c.guard], cell.value_type) or liveTypeFor(p, cell.value_type) == null) return false;
    }
    return true;
}
/// RFC-0085, admission rule 8: what a `nested` entry must be. Anonymous and private, no arm
/// exits and no clauses, and named by an identifier that `(` follows in the source.
fn nestedFunction(p: Program, f: types.RuntimeFunction) bool {
    if (f.is_public or !f.anonymous) return false;
    if (f.clauses_of != null or f.exits != null) return false;
    if (f.name.end >= p.source.len) return false;
    return p.source[f.name.end] == '(';
}

fn functionName(text: []const u8) bool {
    if (text.len == 0 or text.len > types.limits.identifier_bytes) return false;
    for (text, 0..) |c, index| if (c != '_' and !std.ascii.isAlphabetic(c) and !(index != 0 and std.ascii.isDigit(c))) return false;
    return true;
}
/// Functions of one name are overloads when their parameter types differ.
fn sameParameters(a: types.RuntimeFunction, b: types.RuntimeFunction) bool {
    return a.parameter_count == b.parameter_count and std.mem.eql(types.Type, a.parameters[0..a.parameter_count], b.parameters[0..b.parameter_count]);
}

fn sameName(p: Program, a: types.Span, b: types.Span) bool {
    return (p.modules.len == 0 or modules.home(a, p.modules, p.nested) == modules.home(b, p.modules, p.nested)) and std.mem.eql(u8, a.text(p.source), b.text(p.source));
}

/// Names that `sameName` accepts as one hash alike. A name outside every module gets a module
/// number no module has, because `sameName` treats two such names as sharing an owner.
fn nameHash(p: Program, name: types.Span) u64 {
    var module: u32 = 0;
    if (p.modules.len != 0) module = modules.home(name, p.modules, p.nested) orelse name_index.none;
    return name_index.hashName(module, name.text(p.source));
}

/// Per function: `following` links the functions of one name; in the first function of the
/// name, `others` and `methods` start the list of ordinary functions and the list of
/// functions the dispatch table names.
const NameGroup = struct { following: u32, others: u32, methods: u32 };

/// A second declaration of one function: the same anonymous position, or the same name with the
/// same parameter types, unless both are different specializations of one generic source.
fn clash(p: Program, f: types.RuntimeFunction, old: types.RuntimeFunction) bool {
    if (f.anonymous and old.anonymous) {
        return std.meta.eql(f.name, old.name) and (f.specialization == null or old.specialization == null or f.specialization == old.specialization or !std.meta.eql(f.generic_source, old.generic_source));
    } else if (!f.anonymous and !old.anonymous and sameName(p, f.name, old.name) and (sameParameters(f, old) or f.specialization != null or old.specialization != null)) {
        // A generic method's specialization belongs to its class (RFC-0081): it shares a name
        // with a function of the module, generic or not, without clashing.
        if (memberSpecialization(p, f) != memberSpecialization(p, old)) return false;
        // Specializations of generic methods of different classes do not clash (RFC-0081).
        if (f.specialization != null and old.specialization != null and f.specialization != old.specialization) {
            if (methodClass(p, f)) |mine| if (methodClass(p, old)) |theirs| if (mine != theirs) return false;
        }
        return f.specialization == null or old.specialization == null or f.specialization == old.specialization or !std.meta.eql(f.generic_source, old.generic_source);
    }
    return false;
}

/// Whether `inner` is the span of a function of the template that `outer` identifies. The span
/// of an anonymous function whose name lies in a module's library block, such as the body of a
/// `For`, is widened to reach it; one the author wrote inside that body keeps the template's own
/// span. Templates start apart, so the start tells the template, and the inner span lies within
/// the outer one (`pf2`).
fn sameTemplate(outer: types.Span, inner: types.Span) bool {
    return outer.start == inner.start and inner.end <= outer.end;
}

/// A function the dispatch table names and one called by name clash as two functions called by
/// name do, unless one is a specialization: that is reached by its template and type arguments
/// and a method only through its class, so a method may have a generic function's name, or
/// a generic method's of another class (found by `pf2`; the compiler accepts both).
fn methodClash(p: Program, f: types.RuntimeFunction, old: types.RuntimeFunction) bool {
    if (f.specialization != null or old.specialization != null) return false;
    return clash(p, f, old);
}

/// Whether `f` specializes a generic method (RFC-0081): its key has one argument more than the
/// header of its template, admitted by `validGenericCode`, declares, the receiver's class.
fn memberSpecialization(p: Program, f: types.RuntimeFunction) bool {
    const key = f.specialization orelse return false;
    const shape = catalogue.definition(key, p.definitions) orelse return false;
    if (shape != .tuple) return false;
    const source = f.generic_source.text(p.source);
    var nesting: usize = 0;
    var declared: usize = 1;
    var at: usize = 0;
    // The header opens at the first bracket outside a comment and closes with it; a text that
    // does not balance there is no generic method's.
    while (at < source.len) : (at += 1) switch (source[at]) {
        // The loop's step moves from the last byte of a comment to the byte after it.
        '#', '<' => if (lexer.commentOpens(source, at)) {
            at = lexer.commentEnd(source, at) - 1;
        },
        '[' => nesting += 1,
        '(' => {
            if (nesting == 0) return false;
            nesting += 1;
        },
        ')', ']' => {
            if (nesting == 0) return false;
            nesting -= 1;
            if (nesting == 0) break;
        },
        ',' => if (nesting == 1) {
            declared += 1;
        },
        else => {},
    } else return false;
    return shape.tuple.end - shape.tuple.start == declared + 1;
}

fn methodClass(p: Program, f: types.RuntimeFunction) ?types.Type {
    const key = catalogue.definition(f.specialization.?, p.definitions) orelse return null;
    if (key != .tuple or key.tuple.end == key.tuple.start or key.tuple.end > p.tuple_elements.len or f.parameter_count == 0) return null;
    const receiver = p.tuple_elements[key.tuple.end - 1];
    if (receiver != f.parameters[0] or !classType(p, receiver)) return null;
    return receiver;
}

// Bytecode admission uses its own exact signature comparison.
fn signatureMatches(p: Program, value_type: types.Type, f: types.RuntimeFunction) bool {
    const d = catalogue.definition(value_type, p.definitions) orelse return false;
    if (d != .callable) return false;
    const signature = d.callable;
    if (signature.result != f.value_type or signature.transacts != f.transacts or signature.decides != f.decides or @as(u8, @bitCast(signature.detail)) != @as(u8, @bitCast(f.detail))) return false;
    const args = catalogue.definition(signature.parameters, p.definitions) orelse return false;
    if (args != .tuple or !validSpan(args.tuple, p.tuple_elements.len) or f.parameter_count > types.limits.parameters or args.tuple.end - args.tuple.start != f.parameter_count) return false;
    for (p.tuple_elements[args.tuple.start..args.tuple.end], 0..) |required, index| if (required != f.parameters[index]) return false;
    return true;
}
fn needsSource(p: Program) bool {
    if (p.source_ops != 0) return true;
    for (p.code) |instruction| {
        if (instruction.op == .invoke or instruction.op == .iterate_value or instruction.op == .loop) {
            const operand = if (instruction.op == .invoke) instruction.op.invoke.callable else if (instruction.op == .iterate_value) instruction.op.iterate_value.callable else instruction.op.loop.callable;
            if (catalogue.definition(p.code[operand].value_type.?, p.definitions).?.callable.transacts) return true;
        }
        // RFC-0084, P4.5: so does the body of a batch.
        if (instruction.op == .batch and catalogue.definition(p.code[instruction.op.batch].value_type.?, p.definitions).?.callable.transacts) return true;
        if (instruction.invocation()) |i| if (p.functions[i.target()].has_source) return true;
    }
    return false;
}

fn validGenericCode(p: Program, f: types.RuntimeFunction, comparable: []const bool) bool {
    const key = f.specialization orelse {
        if (f.template_public or f.generic_source.start != 0 or f.generic_source.end != 0) return false;
        if (!f.anonymous) {
            const suffix = p.source[f.name.end..];
            var at: usize = 0;
            skipGenericCodeSpace(suffix, &at);
            if (at < suffix.len and suffix[at] == '<') {
                at += 1;
                skipGenericCodeSpace(suffix, &at);
                // `<public>` or `<internal>` (RFC-0074) stands between the name and a generic header.
                const word: usize = if (std.mem.startsWith(u8, suffix[at..], "public")) 6 else if (std.mem.startsWith(u8, suffix[at..], "internal")) 8 else 0;
                if (word != 0) {
                    at += word;
                    skipGenericCodeSpace(suffix, &at);
                    if (at < suffix.len and suffix[at] == '>') at += 1;
                    skipGenericCodeSpace(suffix, &at);
                }
            }
            if (at < suffix.len and suffix[at] == '[') return false;
        }
        return true;
    };
    if (f.is_public or !validSpan(f.generic_source, p.source.len) or f.generic_source.start == f.generic_source.end or !modules.contains(f.generic_source, f.name)) return false;
    if (p.modules.len != 0 and modules.owner(f.generic_source, p.modules) != modules.owner(f.name, p.modules)) return false;
    const shape = catalogue.definition(key, p.definitions) orelse return false;
    if (shape != .tuple) return false;
    const n = shape.tuple.end - shape.tuple.start;
    if (n == 0 or n > types.limits.parameters) return false;
    if (!f.anonymous and n + f.parameter_count > types.limits.parameters) return false;
    const source = f.generic_source.text(p.source);
    if (source[source.len - 1] != '}') return false;
    var at: usize = 0;
    if (!std.ascii.isAlphabetic(source[0]) and source[0] != '_') return false;
    while (at < source.len and (std.ascii.isAlphanumeric(source[at]) or source[at] == '_')) at += 1;
    if (!f.anonymous and (f.name.start != f.generic_source.start or f.name.end != f.generic_source.start + at)) return false;
    var source_public = false;
    skipGenericCodeSpace(source, &at);
    // `<private>`, `<protected>` and `<final>` stand before a generic method's parameters
    // (RFC-0081), at most two specifiers in all.
    var stated: usize = 0;
    while (at < source.len and source[at] == '<') {
        stated += 1;
        if (stated > 2) return false;
        at += 1;
        skipGenericCodeSpace(source, &at);
        // `<internal>` says what no specifier means (RFC-0074): the template is not public.
        const length: usize = specifierLength(source[at..]);
        if (length == 0) return false;
        if (std.mem.startsWith(u8, source[at..], "public")) {
            if (source_public) return false;
            source_public = true;
        }
        at += length;
        skipGenericCodeSpace(source, &at);
        if (at == source.len or source[at] != '>') return false;
        at += 1;
        skipGenericCodeSpace(source, &at);
    }
    if (f.template_public != (!f.anonymous and source_public)) return false;
    if (at == source.len or source[at] != '[') return false;
    at += 1;
    var names: [types.limits.parameters][]const u8 = undefined;
    var count: usize = 0;
    while (at < source.len and count < names.len) {
        skipGenericCodeSpace(source, &at);
        const begin = at;
        if (at == source.len or (!std.ascii.isAlphabetic(source[at]) and source[at] != '_')) return false;
        while (at < source.len and (std.ascii.isAlphanumeric(source[at]) or source[at] == '_')) at += 1;
        const text = source[begin..at];
        if (text.len > types.limits.identifier_bytes) return false;
        for (names[0..count]) |old| if (std.mem.eql(u8, old, text)) return false;
        names[count] = text;
        count += 1;
        if (count > n) return false;
        skipGenericCodeSpace(source, &at);
        if (at == source.len or source[at] != ':') return false;
        at += 1;
        skipGenericCodeSpace(source, &at);
        if (std.mem.startsWith(u8, source[at..], "effect")) {
            if (!catalogue.effectWitness(p.tuple_elements[shape.tuple.start + count - 1], p.definitions, p.tuple_elements)) return false;
            at += 6;
        } else if (std.mem.startsWith(u8, source[at..], "comparable")) {
            if (!catalogue.comparableIn(p.tuple_elements[shape.tuple.start + count - 1], comparable)) return false;
            at += 10;
        } else if (std.mem.startsWith(u8, source[at..], "type")) {
            at += 4;
        } else if (subtypeWord(source[at..]) != 0) {
            // `T:subtype(Base)` (RFC-0073), `castable_subtype(Base)`, `concrete_subtype(Base)`
            // (RFC-0081). The bound is a contract the compiler checked where the template was
            // named; the specialized code carries its own types, so only the shape of the
            // declaration is read here.
            at += subtypeWord(source[at..]);
            skipGenericCodeSpace(source, &at);
            if (at == source.len or source[at] != '(') return false;
            var open: usize = 0;
            while (at < source.len) : (at += 1) {
                if (lexer.commentOpens(source, at)) {
                    // Brackets in a comment do not count. The step of the loop leaves the byte
                    // after the comment, so stop on the last byte of it.
                    const end = lexer.commentEnd(source, at);
                    if (end == source.len) return false;
                    at = end - 1;
                    continue;
                }
                if (source[at] == '(' or source[at] == '[') open += 1;
                if (source[at] == ')' or source[at] == ']') {
                    open -= 1;
                    if (open == 0) break;
                }
            }
            if (at == source.len) return false;
            at += 1;
        } else return false;
        skipGenericCodeSpace(source, &at);
        if (at == source.len) return false;
        if (source[at] == ']') {
            if (count == n) return true;
            // A generic method's specialization ends with its receiver's class (RFC-0081).
            const receiver = p.tuple_elements[shape.tuple.end - 1];
            return count + 1 == n and classType(p, receiver) and (f.anonymous or (f.parameter_count > 0 and f.parameters[0] == receiver));
        }
        if (source[at] != ',') return false;
        at += 1;
    }
    return false;
}

fn specifierLength(text: []const u8) usize {
    const words = [_][]const u8{ "public", "internal", "private", "protected", "final" };
    for (words) |word| {
        if (!std.mem.startsWith(u8, text, word)) continue;
        if (text.len > word.len and (std.ascii.isAlphanumeric(text[word.len]) or text[word.len] == '_')) continue;
        return word.len;
    }
    return 0;
}

fn subtypeWord(text: []const u8) usize {
    if (std.mem.startsWith(u8, text, "subtype")) return "subtype".len;
    if (std.mem.startsWith(u8, text, "castable_subtype")) return "castable_subtype".len;
    if (std.mem.startsWith(u8, text, "concrete_subtype")) return "concrete_subtype".len;
    if (std.mem.startsWith(u8, text, "castable_concrete_subtype")) return "castable_concrete_subtype".len;
    return 0;
}

fn skipGenericCodeSpace(source: []const u8, at: *usize) void {
    while (at.* < source.len) {
        if (std.ascii.isWhitespace(source[at.*])) {
            at.* += 1;
        } else if (lexer.commentOpens(source, at.*)) {
            at.* = lexer.commentEnd(source, at.*);
        } else break;
    }
}

// Structured concurrency (RFC-0082): the VM's admission of sites. The scheduler itself is in
// `Machine` (`spawnTask` and what follows it).

/// Whether a value of this type is a function that suspends.
fn suspendingCallable(program: Program, value_type: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    return switch (shape) {
        .callable => |callable| callable.detail.suspends,
        else => false,
    };
}

/// Whether the body node `node` is a site of the function `f`: it sleeps, or calls what may
/// suspend. `local` holds the types of the body's registers.
fn siteNode(p: Program, f: types.RuntimeFunction, node: types.Node, local: []const types.Type) bool {
    switch (node.kind) {
        .sleep, .task_await, .event_await, .structured => return true,
        .branch => return true,
        .task_cancel => return true,
        .await_guard => return true,
        .recur => return f.detail.suspends,
        .call => |c| return p.functions[c.function].detail.suspends,
        .iterate => |i| return p.functions[i.function].detail.suspends,
        .invoke => |i| return suspendingCallable(p, local[i.callable]),
        .iterate_value => |i| return suspendingCallable(p, local[i.callable]),
        .loop => |l| return suspendingCallable(p, local[l.callable]),
        else => return false,
    }
}

/// The VM's statement of admission rules 1 to 3 for one body. `sites` gets a bit per site, and
/// `checked` a bit per node that belongs to a check (its `canceling`, `cancel_exit` and
/// `merge`), each checked against the shape the site must be followed by. Then every node's
/// operands are read: no one but its own merge may read a site's register.
fn verifySites(p: Program, f: types.RuntimeFunction, nodes: []const types.FunctionNode, local: []const types.Type) bool {
    var sites: Available = undefined;
    var checked: Available = undefined;
    sites.init(nodes.len);
    checked.init(nodes.len);
    // How many `attempt_begin`s are open in their first arm.
    var regions: usize = 0;
    var index: usize = 0;
    while (index < nodes.len) : (index += 1) {
        const node = nodes[index].node;
        if (nodes[index].input != .operation) continue;
        if (node.kind == .attempt_begin) regions += 1;
        if (node.kind == .otherwise and node.kind.otherwise < nodes.len and nodes[node.kind.otherwise].node.kind == .attempt_begin) {
            if (regions == 0) return false;
            regions -= 1;
        }
        if (!siteNode(p, f, node, local)) continue;
        if (!f.detail.suspends or regions != 0 or checked.has(@intCast(index))) return false;
        sites.set(index, true);
        // canceling, if_begin, landing, cancel_exit, otherwise, merge.
        if (nodes.len - index < 6) return false;
        const test_node = nodes[index + 1];
        const branch_node = nodes[index + 2];
        if (test_node.input != .operation or test_node.node.kind != .canceling) return false;
        if (branch_node.input != .operation or branch_node.node.kind != .if_begin) return false;
        const b = branch_node.node.kind.if_begin;
        // P3.6: the check of a `structured` site whose arms may exit tests next whether one did.
        const exiting = node.kind == .structured and b.alternative + 1 < nodes.len and nodes[b.alternative + 1].input == .operation and nodes[b.alternative + 1].node.kind == .arm_exited;
        if (b.condition != index + 1 or b.alternative <= index + 3 or b.end >= nodes.len or (!exiting and b.end != b.alternative + 1)) return false;
        const last = nodes[b.alternative - 1];
        const other = nodes[b.alternative];
        const join = nodes[b.end];
        if (last.input != .operation or last.node.kind != .cancel_exit or last.node.value_type != node.value_type) return false;
        if (other.input != .operation or other.node.kind != .otherwise or other.node.kind.otherwise != index + 2) return false;
        if (join.input != .operation or join.node.kind != .merge) return false;
        const m = join.node.kind.merge;
        if (m.begin != index + 2 or m.left != b.alternative - 1) return false;
        if (exiting) {
            // `arm_exited`, an `if_begin` on it whose first arm begins with `arm_exit_value` and
            // carries the exit on, an empty `otherwise`, a `merge` of that arm and the site, and
            // the check's `merge` of the landing and that.
            const a = b.alternative;
            if (a + 4 >= nodes.len or nodes[a + 1].node.value_type != .logic) return false;
            const inner = nodes[a + 2];
            const value_at = nodes[a + 3];
            if (inner.input != .operation or inner.node.kind != .if_begin) return false;
            const c = inner.node.kind.if_begin;
            if (c.condition != a + 1 or c.alternative <= a + 4 or c.end != c.alternative + 1 or c.end + 1 != b.end) return false;
            if (value_at.input != .operation or value_at.node.kind != .arm_exit_value or !catalogue.validType(value_at.node.value_type, p.definitions)) return false;
            const empty = nodes[c.alternative];
            const joined = nodes[c.end];
            if (empty.input != .operation or empty.node.kind != .otherwise or empty.node.kind.otherwise != a + 2) return false;
            if (joined.input != .operation or joined.node.kind != .merge or joined.node.value_type != node.value_type) return false;
            const n = joined.node.kind.merge;
            if (n.begin != a + 2 or n.left <= a + 2 or n.left >= c.alternative or n.right != index or m.right != c.end) return false;
            // What carries the exit on holds no site and no node of a check.
            var code = a + 4;
            while (code < c.alternative) : (code += 1) {
                const carried = nodes[code];
                if (carried.input != .operation) continue;
                switch (carried.node.kind) {
                    .canceling, .cancel_exit, .arm_exited, .arm_exit_value => return false,
                    else => if (siteNode(p, f, carried.node, local)) return false,
                }
            }
            for ([_]usize{ a + 1, a + 3, c.end }) |position| {
                if (checked.has(@intCast(position))) return false;
                checked.set(position, true);
            }
        } else if (m.right != index) return false;
        var landing = index + 3;
        while (landing + 1 < b.alternative) : (landing += 1) {
            const landed = nodes[landing];
            if (landed.input != .operation) continue;
            switch (landed.node.kind) {
                .exit, .canceling, .cancel_exit => return false,
                .arm_exit, .arm_exited, .arm_exit_value => return false,
                else => if (siteNode(p, f, landed.node, local)) return false,
            }
        }
        for ([_]usize{ index + 1, b.alternative - 1, b.end }) |position| {
            if (checked.has(@intCast(position))) return false;
            checked.set(position, true);
        }
    }
    if (regions != 0) return false;
    // A site's register is read by its check's merge alone: never as the function's result.
    if (sites.has(f.root)) return false;
    // P3.6: nor is an arm that may exit: it is started by its expression and by nothing else.
    if (exitingArm(p, nodes, f.root) != null) return false;
    for (nodes, 0..) |entry, at| {
        if (entry.input != .operation) continue;
        const node = entry.node;
        switch (node.kind) {
            // A check's own nodes are where its site put them; nowhere else.
            .canceling => if (!checked.has(@intCast(at)) or at == 0 or !sites.has(@intCast(at - 1))) return false,
            .cancel_exit => if (!checked.has(@intCast(at)) or at + 2 >= nodes.len or nodes[at + 1].node.kind != .otherwise) return false,
            .arm_exited, .arm_exit_value => if (!checked.has(@intCast(at))) return false,
            .merge => |m| {
                if (sites.has(m.left)) return false;
                // A check's merge reads its site: the first test's, or (P3.6) the second test's,
                // whose condition is `arm_exited`.
                if (sites.has(m.right) and !(checked.has(@intCast(at)) and nodes[m.begin].node.kind == .if_begin and (m.begin == m.right + 2 or nodes[nodes[m.begin].node.kind.if_begin.condition].node.kind == .arm_exited))) return false;
                // P3.6: a merge never hands on the closure of an arm that may exit; operand
                // enumeration does not list a merge's arms.
                if (exitingArm(p, nodes, m.left) != null or exitingArm(p, nodes, m.right) != null) return false;
            },
            else => {},
        }
        for (0..types.operandCount(node, p.function_members)) |ordinal| {
            const operand = types.operandAt(node, ordinal, p.function_members, p.function_arguments);
            if (sites.has(operand)) return false;
            if (exitingArm(p, nodes, operand)) |exits| if (!startsExitingArm(p, nodes, at, node, ordinal, operand, exits)) return false;
        }
    }
    return true;
}

/// RFC-0082, P3.6: the type of the pending exits of the arm whose closure is the register
/// `index` of a body, if it is the closure of one that may exit: a `function_value` of it, or
/// a `bind` of such a `function_value`.
fn exitingArm(p: Program, nodes: []const types.FunctionNode, index: u32) ?types.Type {
    if (index >= nodes.len or nodes[index].input != .operation) return null;
    const named: u32 = switch (nodes[index].node.kind) {
        .function_value => |id| id,
        .bind => |b| bound: {
            if (b.callable >= nodes.len or nodes[b.callable].input != .operation or nodes[b.callable].node.kind != .function_value) return null;
            break :bound nodes[b.callable].node.kind.function_value;
        },
        else => return null,
    };
    return if (named < p.functions.len) p.functions[named].exits else null;
}
/// Whether the node at `at` may read the closure `operand` of an arm whose pending exits have
/// the type `exits` as its operand `ordinal`: a `bind` of a `function_value`, or an arm of a
/// `structured` site whose check reads pending exits of that type.
fn startsExitingArm(p: Program, nodes: []const types.FunctionNode, at: usize, node: types.Node, ordinal: usize, operand: u32, exits: types.Type) bool {
    _ = p;
    switch (node.kind) {
        .bind => return ordinal == 0 and nodes[operand].node.kind == .function_value,
        .structured => {
            // A site, whose check `verifySites` has seen.
            const alternative = nodes[at + 2].node.kind.if_begin.alternative;
            if (alternative + 3 >= nodes.len or nodes[alternative + 1].node.kind != .arm_exited) return false;
            return nodes[alternative + 3].node.value_type == exits;
        },
        else => return false,
    }
}
/// P3.6: whether an instruction names an arm that may exit: a closure of it, a call of it or an
/// iteration of it.
fn namesExitingArm(p: Program, instruction: Instruction) bool {
    const named: u32 = switch (instruction.op) {
        .function_value => |id| id,
        .call => |c| c.function,
        .iterate => |i| i.function,
        else => return false,
    };
    return named < p.functions.len and p.functions[named].exits != null;
}

/// `Sleep(seconds)` at tick `now`, in the VM's words: null for a wait that ends at once, the
/// tick to wake at, or `never`.
fn sleepUntil(seconds: f64, now: u64, rate: u64) ?u64 {
    @setFloatMode(.strict);
    assert(!types.isNan(seconds));
    if (seconds < 0) return null;
    // The next tick, unless that is the clock's limit.
    if (seconds == 0) return if (now + 1 >= types.Scheduler.clock_limit) call_frames.never else now + 1;
    // `+inf` times the rate is `+inf`, which is no tick below the limit either.
    const ticks = @ceil(seconds * @as(f64, @floatFromInt(rate)));
    const limit: f64 = @floatFromInt(types.Scheduler.clock_limit);
    if (ticks >= limit) return call_frames.never;
    const count: u64 = @intFromFloat(ticks);
    const room = types.Scheduler.clock_limit - now;
    return if (count >= room) call_frames.never else now + @max(count, 1);
}
