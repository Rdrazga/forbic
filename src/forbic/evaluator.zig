const std = @import("std");
const builtin = @import("builtin");
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
const source_state = @import("source_state.zig");
const call_frames = @import("call_frames.zig");
const effects = @import("effects.zig");
const live_reference = @import("live_reference.zig");
const persistable = @import("persistable.zig");
const persist_json = @import("persist_json.zig");
const prepared = @import("prepared.zig");
comptime {
    std.debug.assert(@backingInt(std.meta.Tag(types.Value).integer) == @backingInt(types.Type.i64));
    std.debug.assert(@backingInt(std.meta.Tag(types.Value).boolean) == @backingInt(types.Type.logic));
    std.debug.assert(@backingInt(std.meta.Tag(types.Value).string) == @backingInt(types.Type.string));
    std.debug.assert(@backingInt(std.meta.Tag(types.Value).floating) == @backingInt(types.Type.float));
}
pub const Execution = struct {
    program: types.Program,
    values: []const types.Value,
    aggregate_values: []const types.Value = &.{},
    activity: []const bool = &.{},
    failures: []const types.FailureTrace = &.{},
    failure_count: u32 = 0,
    call_steps: []const types.CallStep = &.{},
    /// Where the call witness is: `full` in `call_steps`, `digest` in `witness` alone, `off` nowhere.
    /// A program without calls or control records no step in any mode and reports `full`.
    trace: types.TraceMode = .full,
    witness: types.Witness = .{},
    /// The run's `ControlStorage.reclaim_floor`: with it a replay reclaims where the run did.
    reclaim_floor: u32 = types.ControlStorage.default_reclaim_floor,
    /// How often the run reclaimed members. A replay counts for itself and must agree.
    reclaims: u64 = 0,
    /// Final state of every class instance, in creation order after the program's own cells.
    /// An instance's value names the first of its cells; borrowed from the caller's state storage.
    object_cells: []const source_state.Cell = &.{},
    /// What the run did to the world and drew from it (RFC-0079). A report replay works it
    /// out again from the steps and refuses a record that differs.
    effects: effects.Record = .{},
    /// What its scheduler did (RFC-0082), worked out again by the replay in the same way.
    scheduler: types.Scheduler = .{},
    /// The program's own cells when the run ended, for a program that spawns tasks: those run
    /// after the root, so a binding of a `var` is reported with its final value, not with the
    /// one the root read. Empty for every other program, whose root reads come last. A live
    /// program (RFC-0084) records them too.
    cells: []const source_state.Cell = &.{},
    /// What its live variables did (RFC-0084), worked out again by the replay.
    live: types.Live = .{},

    /// The count and digest of the run's step stream, or null for a run that recorded nothing.
    pub fn callWitness(self: Execution) ?types.Witness {
        return switch (self.trace) {
            .full => .of(self.call_steps, self.program.strings.ptr),
            .digest => self.witness,
            .off => null,
        };
    }
    pub fn active(self: Execution, index: usize) bool {
        return index < self.values.len and (if (self.activity.len == 0) !types.sparse(self.program) else index < self.activity.len and self.activity[index]);
    }

    /// Return only a checked borrowed aggregate range. Scalar values and forged
    /// descriptors are rejected rather than indexing caller-supplied storage.
    pub fn elements(self: Execution, value: types.Value) ?[]const types.Value {
        if (value != .aggregate) return null;
        const aggregate = value.aggregate;
        const definition = catalogue.definition(aggregate.value_type, self.program.definitions) orelse return null;
        if (!validSpan(aggregate.elements, self.aggregate_values.len)) return null;
        switch (definition) {
            .record => |record| {
                if (!validSpan(record.fields, self.program.fields.len)) return null;
                if (aggregate.elements.end - aggregate.elements.start != record.fields.end - record.fields.start) return null;
            },
            .array => {},
            .option => if (aggregate.elements.end - aggregate.elements.start > 1) return null,
            .map, .weak_map => if ((aggregate.elements.end - aggregate.elements.start) % 2 != 0) return null,
            .tuple => |span| {
                if (!validSpan(span, self.program.tuple_elements.len) or span.end - span.start > types.limits.tuple_arity) return null;
                if (aggregate.elements.end - aggregate.elements.start != span.end - span.start) return null;
            },
            .enumeration, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant => return null,
        }
        return self.aggregate_values[aggregate.elements.start..aggregate.elements.end];
    }
    /// The final field cells of an instance, or null for anything that is not a live instance.
    pub fn fields(self: Execution, value: types.Value) ?[]const source_state.Cell {
        const cells = self.objectCells(value) orelse return null;
        return cells[1..];
    }
    /// Every cell of an instance: its header, then its fields.
    pub fn objectCells(self: Execution, value: types.Value) ?[]const source_state.Cell {
        if (value != .object) return null;
        const count = catalogue.classCells(value.object.value_type, self.program.definitions) orelse return null;
        const base = self.program.source_cells.len;
        if (value.object.id < base or value.object.id - base + count > self.object_cells.len) return null;
        return self.object_cells[value.object.id - base ..][0..count];
    }
    pub fn get(self: Execution, name: []const u8) ?types.Value {
        for (self.program.bindings) |binding| {
            if (std.mem.eql(u8, binding.name.text(self.program.source), name)) return if (self.active(binding.node)) self.values[binding.node] else null;
        }
        return null;
    }
};
pub const Result = union(enum) { ok: Execution, failed: types.Diagnostic };
pub const EvalError = keys.Error || error{ InvalidIr, Overflow, DivisionByZero, IndexRange, AggregateLimit, NativeFailed, StringLimit, InvalidNative };

/// Input must remain immutable and outlive the result; values must not alias it.
/// Results borrow caller storage until it is written again. Validation is a
/// separate bounded pass and consumes no execution fuel, as with the VM.
pub fn evaluate(program: types.Program, values: []types.Value, work_budget: u64) Result {
    return evaluateWithStorage(program, values, &.{}, work_budget);
}

/// Register and aggregate storage must be disjoint from each other and inputs.
/// Aggregate values are shallow immutable descriptors; nested members share
/// earlier ranges rather than recursively copying or allocating guest data.
pub fn evaluateWithStorage(program: types.Program, values: []types.Value, aggregate_values: []types.Value, work_budget: u64) Result {
    if (validate(program, values.len)) |diagnostic| return .{ .failed = diagnostic };
    return evaluateStraight(program, values, aggregate_values, work_budget);
}

/// `evaluateWithStorage` after `validate` has admitted `program` for storage of `values.len`.
fn evaluateStraight(program: types.Program, values: []types.Value, aggregate_values: []types.Value, work_budget: u64) Result {
    if (needsSource(program)) return failure(.{ .start = 0, .end = 0 }, .state_storage_required);
    if (program.control_ops != 0 or types.controlledCalls(program)) return failure(.{ .start = 0, .end = 0 }, .control_storage_required);
    if (program.members.len > aggregate_values.len) return failure(.{ .start = 0, .end = 0 }, .aggregate_limit);
    if (program.call_ops != 0) {
        const control = scratch.create(types.ControlStorage) orelse return failure(.{ .start = 0, .end = 0 }, .scratch_unavailable);
        defer scratch.destroy(control);
        return evaluateCold(program, values, aggregate_values, control, null, work_budget);
    }
    // The validated straight-line graph visits each node and member once.
    // Fully funded evaluation skips only per-node fuel bookkeeping; partial
    // funding retains exact early exhaustion. Future control flow must revise
    // this funding model before execution can use those constructs.
    const fully_funded = work_budget >= program.nodes.len + program.members.len and !keys.dynamic(program.definitions) and program.string_comparisons == 0;
    std.debug.assert(program.nodes.len <= values.len and program.members.len <= aggregate_values.len);
    var remaining: u64 = work_budget;
    var aggregate_count: usize = 0;
    var pool = run_strings.Pool.init(program.strings, program.string_tail);
    // Kept for the whole evaluation: no comparison or lookup asks the host for memory of its own.
    var key_work: keys.Work = .{};
    defer key_work.release();
    for (program.nodes, 0..) |node, index| {
        if (!fully_funded) {
            const cost: u32 = 1 + switch (node.kind) {
                .aggregate => |range| range.end - range.start,
                // Adding nodes requires auditing the straight-line funding
                // proof as well as their partial-execution work cost.
                .integer, .boolean, .string, .negate, .binary, .floating, .float_negate, .int_to_float, .float_to_int, .float_binary, .rational, .field, .array_length, .enumeration, .tuple_element, .option_present, .option_value, .option_or, .map_lookup, .array_get, .map_key, .map_value, .string_length, .compare, .logic_not, .logic_binary, .local_set, .upcast, .downcast, .instance_of, .method_value, .function_value, .character, .refine => @as(u32, 0),
                // The text operations that reach this loop touch at most one encoded scalar.
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
            if (cost > remaining) return failure(node.span, .work_limit);
            remaining -= cost;
        }
        values[index] = evaluateNode(node, @intCast(index), values[0..index], program, aggregate_values, &aggregate_count, &pool, &key_work, &remaining, .{}) catch |err| {
            return failure(node.span, switch (err) {
                error.InvalidIr => .invalid_ir,
                error.Overflow => .arithmetic_overflow,
                error.DivisionByZero => .division_by_zero,
                error.IndexRange => .index_out_of_range,
                error.AggregateLimit => .aggregate_limit,
                error.NativeFailed => .native_failed,
                error.StringLimit => .string_limit,
                error.InvalidNative => .invalid_native,
                error.WorkLimit => .work_limit,
                error.DuplicateKey => .duplicate_map_key,
                error.ScratchUnavailable => .scratch_unavailable,
            });
        };
        // A node of type `any` holds a value of any form unchanged (RFC-0080): a scalar there
        // is what `any(5)` makes. Admission typed its operand.
        if (node.value_type == types.Type.any) {} else if (@backingInt(node.value_type) < 4) {
            if (@backingInt(std.meta.activeTag(values[index])) != @backingInt(node.value_type)) return failure(node.span, .invalid_ir);
        } else switch (values[index]) {
            .aggregate => |value| if (value.value_type != node.value_type) return failure(node.span, .invalid_ir),
            .enumeration => |value| if (value.value_type != node.value_type) return failure(node.span, .invalid_ir),
            .callable => |value| if (value.value_type != node.value_type) return failure(node.span, .invalid_ir),
            .rational => if (!catalogue.isRational(node.value_type, program.definitions)) return failure(node.span, .invalid_ir),
            // A refinement (RFC-0083) holds the scalar of its base.
            .integer, .floating => {
                const refinement = catalogue.refinementOf(node.value_type, program.definitions) orelse return failure(node.span, .invalid_ir);
                if (@backingInt(std.meta.activeTag(values[index])) != @backingInt(refinement.base)) return failure(node.span, .invalid_ir);
            },
            else => return failure(node.span, .invalid_ir),
        }
    }
    std.debug.assert(aggregate_count == program.members.len);
    std.debug.assert(aggregate_count <= aggregate_values.len);
    var extended = program;
    extended.strings = pool.view(program.strings);
    return .{ .ok = .{ .program = extended, .values = values[0..program.nodes.len], .aggregate_values = aggregate_values[0..aggregate_count] } };
}

/// Calls of `validate` in a test build, so that tests can show a prepared run admits nothing
/// again (TASK-0109, W4.3). Never read outside tests.
pub var validations: usize = 0;

// Independent typed-IR validation keeps malformed tails from being hidden by
// earlier arithmetic/fuel failures. It deliberately does not lower into the VM.
pub fn validate(program: types.Program, capacity: usize) ?types.Diagnostic {
    if (builtin.is_test) validations += 1;
    const origin: types.Span = .{ .start = 0, .end = 0 };
    if (program.nodes.len > capacity or program.nodes.len > types.limits.nodes) return .{ .span = origin, .code = .invalid_ir };
    if (program.bindings.len > types.limits.bindings or program.source.len > types.limits.source_bytes or program.strings.len > types.limits.string_bytes) return .{ .span = origin, .code = .invalid_ir };
    if (!std.unicode.utf8ValidateSlice(program.source) or !std.unicode.utf8ValidateSlice(program.strings)) return .{ .span = origin, .code = .invalid_ir };
    if (!modules.validateBundle(program.source, program.paths, program.modules, program.imports, program.nested, program.parts, program.file_paths)) return .{ .span = origin, .code = .invalid_ir };
    if (program.definitions.len > types.limits.user_types) return .{ .span = origin, .code = .invalid_ir };
    // Which types have an equality is decided once for the catalogue and asked per node below.
    const comparable = scratch.alloc(bool, program.definitions.len) orelse return .{ .span = origin, .code = .scratch_unavailable };
    defer scratch.free(comparable);
    catalogue.comparableTypes(program.definitions, program.fields, program.tuple_elements, comparable);
    if (!catalogue.validateAllIn(program.definitions, program.fields, program.cases, program.tuple_elements, program.source, program.modules, program.nested, comparable) or program.members.len > types.limits.aggregate_elements) return .{ .span = origin, .code = .invalid_ir };
    var exposed: [types.limits.user_types]bool = undefined;
    if (program.modules.len != 0) catalogue.exportableTypes(program.definitions, program.fields, program.tuple_elements, &exposed);
    const privacy = nestedPrivacy(program) catch return .{ .span = origin, .code = .scratch_unavailable };
    defer if (privacy) |held| held.destroy();
    if (privacy) |held| if (!held.fieldsAdmitted(program.definitions, program.fields)) return .{ .span = origin, .code = .invalid_ir };
    if (!validSourceCells(program, privacy) or !catalogue.validDispatch(program.slots, program.dispatch, program.definitions, program.tuple_elements, program.functions)) return .{ .span = origin, .code = .invalid_ir };
    // RFC-0087, P5.2 (admission rule 2): the persistable flags and the field constants.
    switch (validPersistable(program)) {
        .valid => {},
        .invalid => return .{ .span = origin, .code = .invalid_ir },
        .no_scratch => return .{ .span = origin, .code = .scratch_unavailable },
    }
    // RFC-0092, B4: the marks of restricted hierarchies.
    if (!validFinalSupers(program.definitions)) return .{ .span = origin, .code = .invalid_ir };
    // RFC-0087, P5.3 (admission rule 6): what the types of JSON nodes are, when there is one.
    const json = jsonFacts(program) catch return .{ .span = origin, .code = .scratch_unavailable };
    defer json.release();
    // RFC-0084, P4.2: a class's block-clause function with live fields is no method.
    for (program.dispatch) |entry| if (entry.function < program.functions.len and program.functions[entry.function].clauses_of != null) return .{ .span = origin, .code = .invalid_ir };
    // RFC-0082, P3.6: an arm that may exit runs only as an arm: no method is one.
    for (program.dispatch) |entry| if (entry.function < program.functions.len and program.functions[entry.function].exits != null) return .{ .span = origin, .code = .invalid_ir };
    var argument_count: u32 = 0;
    var call_ops: u32 = 0;
    var member_count: u32 = 0;
    var source_ops: u32 = 0;
    var string_comparisons: u32 = 0;
    var control_ops: u32 = 0;
    // RFC-0084, P4.2: the latest construction, the only instance a class's clauses are handed.
    var last_new: u32 = no_construction;
    for (program.nodes, 0..) |node, index| {
        if (!validSpan(node.span, program.source.len)) return .{ .span = origin, .code = .invalid_ir };
        if (program.modules.len != 0 and modules.owner(node.span, program.modules) == null) return .{ .span = origin, .code = .invalid_ir };
        if (!validNode(node, program.nodes[0..index], program, comparable, &member_count)) return .{ .span = node.span, .code = .invalid_ir };
        if (!validJson(node, program.nodes[0..index], program, json)) return .{ .span = node.span, .code = .invalid_ir };
        if (rootSuspends(node, program.nodes[0..index], program)) return .{ .span = node.span, .code = .invalid_ir };
        // P3.6: the root starts no arm, so it names none that may exit.
        if (exitingArmNamed(program, node)) return .{ .span = node.span, .code = .invalid_ir };
        // RFC-0084, P4.2: the root attaches no live-only field and calls a class's clauses only
        // on an instance it has just built.
        if (!clausesHeld(node, program.nodes[0..index], program, program.call_arguments, last_new)) return .{ .span = node.span, .code = .invalid_ir };
        if (node.kind == .object_new) last_new = @intCast(index);
        if (node.kind == .object_live and liveField(program, program.nodes[node.kind.object_live.object].value_type, node.kind.object_live.field).?.live_only) return .{ .span = node.span, .code = .invalid_ir };
        switch (node.kind) {
            .function_value => |id| if (program.functions[id].available_at > index) {
                return .{ .span = node.span, .code = .invalid_ir };
            },
            .invoke, .bind, .event_notify => |i| {
                if (i.arguments.start != argument_count) return .{ .span = node.span, .code = .invalid_ir };
                argument_count = i.arguments.end;
                if (node.kind == .invoke) call_ops += 1;
            },
            .call => |c| {
                if (c.arguments.start != argument_count or program.functions[c.function].available_at > index) return .{ .span = node.span, .code = .invalid_ir };
                argument_count = c.arguments.end;
                call_ops += 1;
            },
            .object_new => |c| {
                if (c.arguments.start != argument_count or !catalogue.dispatchReady(program.dispatch, program.functions, node.value_type, @intCast(index))) return .{ .span = node.span, .code = .invalid_ir };
                argument_count = c.arguments.end;
            },
            .iterate => |i| if (program.functions[i.function].available_at > index) {
                return .{ .span = node.span, .code = .invalid_ir };
            },
            else => {},
        }
        if (types.controlOp(node)) control_ops += 1;
        if (types.sourceOp(node)) source_ops += 1;
        if (node.kind == .compare and catalogue.walkedEquality(program.nodes[node.kind.compare.lhs].value_type, program.definitions)) string_comparisons += 1;
    }
    if (source_ops != program.source_ops) return .{ .span = origin, .code = .invalid_ir };
    if (control_ops != program.control_ops) return .{ .span = origin, .code = .invalid_ir };
    if ((control_ops != 0 or source_ops != 0 or call_ops != 0 or program.functions.len != 0) and !validateControl(program)) return .{ .span = origin, .code = .invalid_ir };
    if (call_ops != program.call_ops or argument_count != program.call_arguments.len or !validFunctions(program, comparable, privacy, json)) return .{ .span = origin, .code = .invalid_ir };
    if (string_comparisons != program.string_comparisons or member_count != program.members.len) return .{ .span = origin, .code = .invalid_ir };
    for (program.bindings) |binding| {
        if (binding.node >= program.nodes.len or !validSpan(binding.name, program.source.len)) return .{ .span = origin, .code = .invalid_ir };
        if (program.modules.len != 0 and (!modules.contains(program.modules[program.modules.len - 1].source, binding.name) or modules.innermost(binding.name, program.nested) != null or !signatureAdmitted(privacy, exposed[0..program.definitions.len], binding.value_type, binding.name, binding.is_public))) return .{ .span = origin, .code = .invalid_ir };
        if (binding.value_type != program.nodes[binding.node].value_type) return .{ .span = binding.name, .code = .invalid_ir };
    }
    return null;
}

const PersistableCheck = enum { valid, invalid, no_scratch };

/// RFC-0092, B4: a `final_super` class has a superclass; neither mark is on an interface or an
/// instantiation of a parametric type; a class whose superclass is `final_super_base` is
/// `final_super`. No machine reads the marks to run anything (the compiler lowers
/// `GetCastableFinalSuperClass` to a call of a family function of `instance_of` tests), so
/// these keep the table a program carries truthful.
fn validFinalSupers(definitions: []const types.Definition) bool {
    for (definitions) |item| {
        if (item != .class) continue;
        const class = item.class;
        const marked = class.final_super or class.final_super_base;
        if (marked and (class.is_interface or class.arguments != null)) return false;
        if (class.final_super and class.parent == null) return false;
        const parent = class.parent orelse continue;
        const above = catalogue.definition(parent, definitions) orelse return false;
        if (above != .class) return false;
        if (above.class.final_super_base and !class.final_super) return false;
    }
    return true;
}

/// RFC-0087, P5.2, admission rule 2. The flags are recomputed from the catalogue: a flagged
/// class is final, not unique, has no superclass and no interface, is no instantiation, and has
/// no `var` or live field; a flagged struct is no instantiation and no metatype; the fields of
/// both are of persistable types (T2). A field names a constant only in a flagged struct or
/// class, and one of its own type. Each constant is a value of a persistable type: a scalar of
/// the type its kind gives, a string on character boundaries, a case of its enum, a code its
/// character type has, or an aggregate of earlier constants laid out as a value of its type is,
/// a map with no two equal keys. Nothing a constant holds is an instance: no constant kind is.
fn validPersistable(program: types.Program) PersistableCheck {
    const constants = program.constants;
    const members = program.constant_members;
    if (constants.len > types.limits.template_nodes or members.len > types.limits.aggregate_elements) return .invalid;
    var flagged = false;
    for (program.definitions) |item| switch (item) {
        .record => |record| flagged = flagged or record.persistable,
        .class => |class| flagged = flagged or class.persistable,
        .enumeration => |enumeration| flagged = flagged or enumeration.persistable,
        else => {},
    };
    if (!flagged) {
        // A program without the specifier holds nothing of this, as it did before P5.2.
        if (constants.len != 0 or members.len != 0) return .invalid;
        for (program.fields) |field| if (field.constant != null) return .invalid;
        return .valid;
    }
    const kinds = scratch.alloc(bool, program.definitions.len) orelse return .no_scratch;
    defer scratch.free(kinds);
    persistable.persistableTypes(program.definitions, program.tuple_elements, kinds);
    // Which fields belong to a flagged struct or class: every field belongs to exactly one
    // definition (the catalogue admits that), so a field outside them holds no constant.
    const owned = scratch.alloc(bool, program.fields.len) orelse return .no_scratch;
    defer scratch.free(owned);
    @memset(owned, false);
    for (program.definitions) |item| {
        const span: types.Span = switch (item) {
            .record => |record| if (!record.persistable) continue else blk: {
                if (record.arguments != null or record.metatype) return .invalid;
                break :blk record.fields;
            },
            .class => |class| if (!class.persistable) continue else blk: {
                if (!class.is_final or class.is_unique or class.is_abstract or class.is_interface or class.parent != null or class.interface_count != 0 or class.inherited != 0 or class.arguments != null) return .invalid;
                break :blk class.fields;
            },
            else => continue,
        };
        for (program.fields[span.start..span.end], span.start..) |field, index| {
            if (field.is_var or field.live_only or !persistable.isPersistable(field.value_type, program.definitions, kinds)) return .invalid;
            owned[index] = true;
        }
    }
    for (program.fields, owned) |field, owner| if (field.constant) |constant| {
        if (!owner or constant >= constants.len or constants[constant].value_type != field.value_type) return .invalid;
    };
    for (constants, 0..) |constant, index| {
        if (!persistable.isPersistable(constant.value_type, program.definitions, kinds)) return .invalid;
        const fits = switch (constant.kind) {
            .integer => constant.value_type == .i64,
            .boolean => constant.value_type == .logic,
            .floating => |value| constant.value_type == .float and types.isCanonicalFloat(value),
            .string => |span| constant.value_type == .string and validSpan(span, program.strings.len) and stringBoundary(span.start, program.strings) and stringBoundary(span.end, program.strings),
            .character => |code| types.validCharacter(constant.value_type, code),
            .enumeration => |case| catalogue.caseAt(constant.value_type, case, program.definitions, program.cases) != null,
            .aggregate => |span| validConstantAggregate(constant.value_type, span, index, program),
        };
        if (!fits) return .invalid;
    }
    // A map constant has no two equal keys, by the language's equality.
    var maps = false;
    for (constants) |constant| maps = maps or (constant.kind == .aggregate and catalogue.definition(constant.value_type, program.definitions).? == .map);
    if (!maps) return .valid;
    const classes = scratch.alloc(u32, constants.len) orelse return .no_scratch;
    defer scratch.free(classes);
    const table = scratch.alloc(u32, persistable.workSize(constants.len)) orelse return .no_scratch;
    defer scratch.free(table);
    persistable.equalityClasses(constants, members, program.strings, classes, table);
    // The constant whose keys last claimed each class: a key claimed by its own map is a duplicate.
    const claimed = scratch.alloc(u32, constants.len) orelse return .no_scratch;
    defer scratch.free(claimed);
    @memset(claimed, std.math.maxInt(u32));
    for (constants, 0..) |constant, index| {
        if (constant.kind != .aggregate or catalogue.definition(constant.value_type, program.definitions).? != .map) continue;
        const span = constant.kind.aggregate;
        var at = span.start;
        while (at < span.end) : (at += 2) {
            const class = classes[members[at]];
            if (claimed[class] == index) return .invalid;
            claimed[class] = @intCast(index);
        }
    }
    return .valid;
}

/// The members of the aggregate constant `index` of `value_type`: earlier constants, as many
/// and of the types a value of `value_type` has.
fn validConstantAggregate(value_type: types.Type, span: types.Span, index: usize, program: types.Program) bool {
    if (!validSpan(span, program.constant_members.len)) return false;
    const held = program.constant_members[span.start..span.end];
    for (held) |member| if (member >= index) return false;
    const constants = program.constants;
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    switch (shape) {
        .option => |element| {
            if (held.len > 1) return false;
            for (held) |member| if (constants[member].value_type != element) return false;
        },
        .array => |element| for (held) |member| if (constants[member].value_type != element) return false,
        .tuple => |elements| {
            const wanted = program.tuple_elements[elements.start..elements.end];
            if (held.len != wanted.len) return false;
            for (held, wanted) |member, element| if (constants[member].value_type != element) return false;
        },
        .record => |record| {
            const wanted = program.fields[record.fields.start..record.fields.end];
            if (held.len != wanted.len) return false;
            for (held, wanted) |member, field| if (constants[member].value_type != field.value_type) return false;
        },
        .map => |entry| {
            if (held.len % 2 != 0) return false;
            for (held, 0..) |member, position| if (constants[member].value_type != if (position % 2 == 0) entry.key else entry.value) return false;
        },
        else => return false,
    }
    return true;
}

fn validNode(node: types.Node, prior: []const types.Node, program: types.Program, comparable: []const bool, member_count: *u32) bool {
    return switch (node.kind) {
        .recur, .self_value => false,
        .function_value => |id| id < program.functions.len and signatureMatches(program, node.value_type, program.functions[id]) and runtimeVisible(program, program.functions[id].name, program.functions[id].is_public or program.functions[id].template_public, node.span),
        .invoke => |i| blk: {
            if (i.callable >= prior.len or !validSpan(i.arguments, program.call_arguments.len)) break :blk false;
            const shape = catalogue.definition(prior[i.callable].value_type, program.definitions) orelse break :blk false;
            if (shape != .callable or shape.callable.result != node.value_type) break :blk false;
            const parameters = catalogue.definition(shape.callable.parameters, program.definitions).?.tuple;
            if (i.arguments.end - i.arguments.start != parameters.end - parameters.start) break :blk false;
            for (program.call_arguments[i.arguments.start..i.arguments.end], program.tuple_elements[parameters.start..parameters.end]) |operand, t| if (operand >= prior.len or prior[operand].value_type != t) break :blk false;
            break :blk true;
        },
        .bind => |b| blk: {
            if (b.callable >= prior.len or !validSpan(b.arguments, program.call_arguments.len)) break :blk false;
            const original = catalogue.definition(prior[b.callable].value_type, program.definitions) orelse break :blk false;
            const residual = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            if (original != .callable or residual != .callable) break :blk false;
            const a = original.callable;
            const r = residual.callable;
            const params = catalogue.definition(a.parameters, program.definitions).?.tuple;
            const rest = catalogue.definition(r.parameters, program.definitions).?.tuple;
            const count = b.arguments.end - b.arguments.start;
            if (count == 0 or count > params.end - params.start or rest.end - rest.start != params.end - params.start - count or a.result != r.result or a.transacts != r.transacts or a.decides != r.decides or @as(u8, @bitCast(a.detail)) != @as(u8, @bitCast(r.detail))) break :blk false;
            if (!std.mem.eql(types.Type, program.tuple_elements[rest.start..rest.end], program.tuple_elements[params.start + count .. params.end])) break :blk false;
            for (program.call_arguments[b.arguments.start..b.arguments.end], program.tuple_elements[params.start .. params.start + count]) |operand, required| if (operand >= prior.len or prior[operand].value_type != required) break :blk false;
            break :blk true;
        },
        .loop => |l| blk: {
            if (l.callable >= prior.len or l.initial >= prior.len) break :blk false;
            const definition = catalogue.definition(prior[l.callable].value_type, program.definitions) orelse break :blk false;
            if (definition != .callable) break :blk false;
            const shape = definition.callable;
            const parameters = catalogue.definition(shape.parameters, program.definitions).?.tuple;
            const result = catalogue.definition(shape.result, program.definitions) orelse break :blk false;
            break :blk result == .option and parameters.end - parameters.start == 1 and program.tuple_elements[parameters.start] == result.option and node.value_type == result.option and prior[l.initial].value_type == result.option;
        },
        .iterate_value => |i| blk: {
            if (i.callable >= prior.len or i.count >= prior.len or i.initial >= prior.len) break :blk false;
            const definition = catalogue.definition(prior[i.callable].value_type, program.definitions) orelse break :blk false;
            if (definition != .callable) break :blk false;
            const shape = definition.callable;
            const parameters = catalogue.definition(shape.parameters, program.definitions).?.tuple;
            break :blk parameters.end - parameters.start == 1 and program.tuple_elements[parameters.start] == shape.result and node.value_type == shape.result and prior[i.count].value_type == .i64 and prior[i.initial].value_type == shape.result;
        },
        .iterate => |i| blk: {
            if (i.function >= program.functions.len or i.count >= prior.len or i.initial >= prior.len) break :blk false;
            const f = program.functions[i.function];
            break :blk f.parameter_count == 1 and f.parameters[0] == f.value_type and f.value_type == node.value_type and prior[i.count].value_type == .i64 and prior[i.initial].value_type == f.value_type and runtimeVisible(program, f.name, f.is_public, node.span);
        },
        .call => |c| blk: {
            if (c.function >= program.functions.len or !validSpan(c.arguments, program.call_arguments.len)) break :blk false;
            const f = program.functions[c.function];
            if (f.parameter_count > types.limits.parameters or f.value_type != node.value_type or c.arguments.end - c.arguments.start != f.parameter_count or !runtimeVisible(program, f.name, f.is_public, node.span)) break :blk false;
            for (program.call_arguments[c.arguments.start..c.arguments.end], f.parameters[0..f.parameter_count]) |operand, t| if (operand >= prior.len or prior[operand].value_type != t) break :blk false;
            break :blk true;
        },
        .object_new => |c| blk: {
            const shape = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            if (shape != .class or shape.class.is_abstract or !validSpan(c.arguments, program.call_arguments.len) or !validSpan(shape.class.fields, program.fields.len)) break :blk false;
            if (c.arguments.end - c.arguments.start != shape.class.fields.end - shape.class.fields.start) break :blk false;
            for (program.call_arguments[c.arguments.start..c.arguments.end], program.fields[shape.class.fields.start..shape.class.fields.end]) |operand, field| {
                if (operand >= prior.len or prior[operand].value_type != field.value_type) break :blk false;
            }
            break :blk true;
        },
        .object_get => |access| blk: {
            if (access.value >= prior.len) break :blk false;
            const field = catalogue.classFieldAt(prior[access.value].value_type, access.index, program.definitions, program.fields) orelse break :blk false;
            break :blk node.value_type == field.value_type;
        },
        .object_set => |c| blk: {
            if (c.object >= prior.len or c.value >= prior.len) break :blk false;
            const field = catalogue.classFieldAt(prior[c.object].value_type, c.index, program.definitions, program.fields) orelse break :blk false;
            break :blk field.is_var and node.value_type == field.value_type and prior[c.value].value_type == field.value_type;
        },
        .cell_init, .cell_write => |c| c.cell < program.source_cells.len and node.value_type == program.source_cells[c.cell].value_type and c.value < prior.len and prior[c.value].value_type == node.value_type and (if (node.kind == .cell_init) program.source_cells[c.cell].initial == prior.len else program.source_cells[c.cell].initial < prior.len) and cellVisible(program, c.cell, node.span) and !program.source_cells[c.cell].live_only,
        .local_set => |n| n < prior.len and prior[n].value_type == node.value_type,
        // A subclass instance is used as its superclass only through an explicit upcast, so every
        // other operation keeps comparing exact types.
        // A function is likewise used at a type that allows more effects only through one (RFC-0078).
        // RFC-0080: a value of any other type is also used as `any`, and a value of `any` as
        // the type it turns out to have, through the same two operations and nothing else.
        // A refinement (RFC-0083) is held as `any` by no value: a type test could not tell it
        // from its base.
        .upcast => |n| n < prior.len and prior[n].value_type != node.value_type and (if (node.value_type == types.Type.any) catalogue.validType(prior[n].value_type, program.definitions) and !catalogue.isScheduled(prior[n].value_type, program.definitions) and catalogue.refinementOf(prior[n].value_type, program.definitions) == null else (isClass(program, node.value_type) and catalogue.subtype(prior[n].value_type, node.value_type, program.definitions)) or catalogue.widens(prior[n].value_type, node.value_type, program.definitions, program.tuple_elements) or catalogue.implements(prior[n].value_type, node.value_type, program.definitions) or catalogue.weakens(prior[n].value_type, node.value_type, program.definitions)),
        .downcast => |n| n < prior.len and prior[n].value_type != node.value_type and (if (prior[n].value_type == types.Type.any) catalogue.validType(node.value_type, program.definitions) and !catalogue.isScheduled(node.value_type, program.definitions) and catalogue.refinementOf(node.value_type, program.definitions) == null else isClass(program, prior[n].value_type) and catalogue.castable(node.value_type, prior[n].value_type, program.definitions)),
        .method_value => |m| m.slot < program.slots.len and m.receiver < prior.len and isClass(program, prior[m.receiver].value_type) and catalogue.subtype(prior[m.receiver].value_type, program.slots[m.slot].owner, program.definitions) and node.value_type == program.slots[m.slot].callable,
        .instance_of => |c| node.value_type == .logic and c.value < prior.len and (if (prior[c.value].value_type == types.Type.any) c.class != types.Type.any and catalogue.validType(c.class, program.definitions) and !catalogue.isScheduled(c.class, program.definitions) and catalogue.refinementOf(c.class, program.definitions) == null else isClass(program, prior[c.value].value_type) and isClass(program, c.class) and catalogue.castable(c.class, prior[c.value].value_type, program.definitions)),
        // RFC-0083: between a refinement and its base, in either direction.
        .refine => |n| n < prior.len and refinedPair(program, prior[n].value_type, node.value_type),
        .cell_read => |c| c < program.source_cells.len and node.value_type == program.source_cells[c].value_type and program.source_cells[c].initial < prior.len and cellVisible(program, c, node.span),
        .if_begin => |b| node.value_type == .logic and b.condition < prior.len and prior[b.condition].value_type == .logic,
        .attempt_begin => |b| node.value_type == .logic and b.condition == std.math.maxInt(u32),
        .otherwise => |b| node.value_type == .logic and b < prior.len,
        // The arms join (RFC-0078, `fix2`): the first may be a function that the merge's type
        // widens, as an `upcast` would; the second is the merge's type.
        .merge => |m| m.begin < prior.len and m.left < prior.len and m.right < prior.len and (prior[m.left].value_type == node.value_type or catalogue.widens(prior[m.left].value_type, node.value_type, program.definitions, program.tuple_elements)) and prior[m.right].value_type == node.value_type,
        .demand => |n| node.value_type == .logic and n < prior.len and prior[n].value_type == .logic,
        .fail => |n| catalogue.validType(node.value_type, program.definitions) and n < prior.len and prior[n].value_type == .string,
        // An exit belongs to a function body, whose admission checks it against the result type.
        .exit => false,
        // RFC-0082, P3.6: so does an arm's exit; the tests of a check are where `validSites`
        // says, and the root has none (`rootSuspends`).
        .arm_exit => false,
        .arm_exited => node.value_type == .logic,
        .arm_exit_value => catalogue.validType(node.value_type, program.definitions),
        .err => |n| catalogue.validType(node.value_type, program.definitions) and n < prior.len and prior[n].value_type == .string,
        .integer => node.value_type == .i64,
        .floating => node.value_type == .float,
        .boolean => node.value_type == .logic,
        .string => |span| node.value_type == .string and validSpan(span, program.strings.len) and stringBoundary(span.start, program.strings) and stringBoundary(span.end, program.strings),
        .negate => |operand| node.value_type == .i64 and integerNode(operand, prior),
        .binary => |binary| node.value_type == .i64 and integerNode(binary.lhs, prior) and integerNode(binary.rhs, prior),
        .float_negate => |operand| node.value_type == .float and floatNode(operand, prior),
        .int_to_float => |operand| node.value_type == .float and integerNode(operand, prior),
        .float_to_int => |c| node.value_type == .i64 and floatNode(c.operand, prior),
        .float_binary => |binary| node.value_type == .float and !binary.op.bitwise() and floatNode(binary.lhs, prior) and floatNode(binary.rhs, prior) and @backingInt(binary.op) <= @backingInt(types.BinaryOp.divide),
        .rational => |r| blk: {
            if (r.lhs >= prior.len or r.rhs >= prior.len) break :blk false;
            const left = prior[r.lhs].value_type;
            if (left != prior[r.rhs].value_type) break :blk false;
            // Only this node builds a rational, so every one a run holds is normalised.
            if (r.op == .make) break :blk left == .i64 and catalogue.isRational(node.value_type, program.definitions);
            if (!catalogue.isRational(left, program.definitions)) break :blk false;
            break :blk switch (r.op) {
                .make => unreachable,
                .add, .subtract, .multiply => node.value_type == left,
                .negate => r.lhs == r.rhs and node.value_type == left,
                .floor, .ceil => r.lhs == r.rhs and node.value_type == .i64,
                .to_float => r.lhs == r.rhs and node.value_type == .float,
            };
        },
        .aggregate => |range| blk: {
            if (!validSpan(range, program.members.len) or range.start != member_count.*) break :blk false;
            const definition = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            switch (definition) {
                .record => |record| {
                    if (range.end - range.start != record.fields.end - record.fields.start) break :blk false;
                    for (program.members[range.start..range.end], program.fields[record.fields.start..record.fields.end]) |operand, field| {
                        if (operand >= prior.len or prior[operand].value_type != field.value_type) break :blk false;
                    }
                },
                .array => |element_type| for (program.members[range.start..range.end]) |operand| {
                    if (operand >= prior.len or prior[operand].value_type != element_type) break :blk false;
                },
                .option => |element_type| {
                    if (range.end - range.start > 1) break :blk false;
                    for (program.members[range.start..range.end]) |operand| if (operand >= prior.len or prior[operand].value_type != element_type) break :blk false;
                },
                // RFC-0087, W3: a map literal where a `weak_map` is expected is built at its type.
                .map, .weak_map => |shape| {
                    if ((range.end - range.start) % 2 != 0) break :blk false;
                    for (program.members[range.start..range.end], 0..) |operand, ordinal| {
                        if (operand >= prior.len or prior[operand].value_type != if (ordinal % 2 == 0) shape.key else shape.value) break :blk false;
                    }
                },
                .enumeration, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant => break :blk false,
                .tuple => |span| {
                    if (range.end - range.start != span.end - span.start) break :blk false;
                    for (program.members[range.start..range.end], program.tuple_elements[span.start..span.end]) |operand, element| {
                        if (operand >= prior.len or prior[operand].value_type != element) break :blk false;
                    }
                },
            }
            member_count.* = range.end;
            break :blk true;
        },
        .field => |access| blk: {
            if (access.value >= prior.len) break :blk false;
            const field = catalogue.fieldAt(prior[access.value].value_type, access.index, program.definitions, program.fields) orelse break :blk false;
            break :blk node.value_type == field.value_type;
        },
        .array_length => |operand| blk: {
            if (node.value_type != .i64 or operand >= prior.len) break :blk false;
            const definition = catalogue.definition(prior[operand].value_type, program.definitions) orelse break :blk false;
            break :blk definition == .array or definition == .map;
        },
        .enumeration => |index| catalogue.caseAt(node.value_type, index, program.definitions, program.cases) != null,
        .tuple_element => |access| blk: {
            if (access.value >= prior.len) break :blk false;
            const element = catalogue.tupleElementAt(prior[access.value].value_type, access.index, program.definitions, program.tuple_elements) orelse break :blk false;
            break :blk node.value_type == element;
        },
        .option_present => |operand| blk: {
            if (node.value_type != .logic or operand >= prior.len) break :blk false;
            const shape = catalogue.definition(prior[operand].value_type, program.definitions) orelse break :blk false;
            break :blk shape == .option;
        },
        .option_or => |choice| blk: {
            if (choice.option >= prior.len or choice.fallback >= prior.len) break :blk false;
            const shape = catalogue.definition(prior[choice.option].value_type, program.definitions) orelse break :blk false;
            break :blk shape == .option and shape.option == prior[choice.fallback].value_type and node.value_type == shape.option;
        },
        .logic_not => |operand| node.value_type == .logic and operand < prior.len and prior[operand].value_type == .logic,
        .logic_binary => |binary| node.value_type == .logic and binary.lhs < prior.len and binary.rhs < prior.len and prior[binary.lhs].value_type == .logic and prior[binary.rhs].value_type == .logic,
        .compare => |comparison| blk: {
            if (node.value_type != .logic or comparison.lhs >= prior.len or comparison.rhs >= prior.len) break :blk false;
            const input_type = prior[comparison.lhs].value_type;
            if (input_type != prior[comparison.rhs].value_type) break :blk false;
            break :blk if (comparison.op == .equal or comparison.op == .unequal) catalogue.comparableIn(input_type, comparable) else input_type == .i64 or input_type == .float or catalogue.isRational(input_type, program.definitions);
        },
        .array_concat => |c| blk: {
            if (c.lhs >= prior.len or c.rhs >= prior.len or prior[c.lhs].value_type != prior[c.rhs].value_type or node.value_type != prior[c.lhs].value_type) break :blk false;
            const shape = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            break :blk shape == .array;
        },
        .option_value => |operand| blk: {
            if (operand >= prior.len) break :blk false;
            const shape = catalogue.definition(prior[operand].value_type, program.definitions) orelse break :blk false;
            break :blk shape == .option and shape.option == node.value_type;
        },
        .map_set => |c| blk: {
            if (c.map >= prior.len or c.key >= prior.len or c.value >= prior.len or prior[c.map].value_type != node.value_type) break :blk false;
            const shape = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            // RFC-0087, W2: `set W[K] = V` on a `weak_map` is the update of a map.
            const entries: types.Map = switch (shape) {
                .map, .weak_map => |entries| entries,
                else => break :blk false,
            };
            break :blk entries.key == prior[c.key].value_type and entries.value == prior[c.value].value_type;
        },
        .map_remove => |c| blk: {
            if (c.map >= prior.len or c.key >= prior.len or prior[c.map].value_type != node.value_type) break :blk false;
            const shape = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            // The second operand is what a lookup in this map yields, not a key to look up again.
            const entry = catalogue.definition(prior[c.key].value_type, program.definitions) orelse break :blk false;
            break :blk shape == .map and entry == .option and entry.option == shape.map.value;
        },
        .array_set => |c| blk: {
            if (c.array >= prior.len or c.index >= prior.len or c.value >= prior.len or prior[c.array].value_type != node.value_type or prior[c.index].value_type != .i64) break :blk false;
            const shape = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            break :blk shape == .array and shape.array == prior[c.value].value_type;
        },
        .string_concat => |c| node.value_type == .string and c.lhs < prior.len and c.rhs < prior.len and prior[c.lhs].value_type == .string and prior[c.rhs].value_type == .string,
        .string_length => |operand| node.value_type == .i64 and operand < prior.len and prior[operand].value_type == .string,
        .to_string => |operand| node.value_type == .string and operand < prior.len and (prior[operand].value_type == .i64 or prior[operand].value_type == .float or prior[operand].value_type == .logic or prior[operand].value_type.isCharacter()),
        .character => |code| types.validCharacter(node.value_type, code),
        .text => |t| validText(t, node.value_type, prior, program),
        .native_call => |c| blk: {
            if (c.native >= program.natives.len or c.count > native.max_parameters) break :blk false;
            const entry = program.natives[c.native];
            if (!native.wellFormed(entry) or c.count != entry.params.len) break :blk false;
            var operand_types: [native.max_parameters]types.Type = undefined;
            for (c.args[0..c.count], operand_types[0..c.count]) |operand, *operand_type| {
                if (operand >= prior.len) break :blk false;
                operand_type.* = prior[operand].value_type;
            }
            break :blk native.admits(entry, operand_types[0..c.count], node.value_type, program.definitions, comparable);
        },
        .array_get => |access| blk: {
            if (access.array >= prior.len or access.index >= prior.len) break :blk false;
            const array = catalogue.definition(prior[access.array].value_type, program.definitions) orelse break :blk false;
            break :blk array == .array and prior[access.index].value_type == .i64 and array.array == node.value_type;
        },
        .map_key, .map_value => |access| blk: {
            if (access.array >= prior.len or access.index >= prior.len) break :blk false;
            const map = catalogue.definition(prior[access.array].value_type, program.definitions) orelse break :blk false;
            break :blk map == .map and prior[access.index].value_type == .i64 and node.value_type == (if (node.kind == .map_key) map.map.key else map.map.value);
        },
        .map_lookup => |lookup| blk: {
            if (lookup.map >= prior.len or lookup.key >= prior.len) break :blk false;
            const map = catalogue.definition(prior[lookup.map].value_type, program.definitions) orelse break :blk false;
            const result = catalogue.definition(node.value_type, program.definitions) orelse break :blk false;
            // RFC-0087, W2: `W[K]` on a `weak_map` is the lookup of a map.
            const entries: types.Map = switch (map) {
                .map, .weak_map => |entries| entries,
                else => break :blk false,
            };
            break :blk result == .option and entries.key == prior[lookup.key].value_type and result.option == entries.value;
        },
        // RFC-0082. Where these stand, and what checks a site, is a body's matter (`validSites`).
        .spawn => |operand| operand < prior.len and spawnTyped(program, prior[operand].value_type, node.value_type),
        .sleep => |operand| floatNode(operand, prior) and unitTyped(program, node.value_type),
        .canceling => node.value_type == .logic,
        .cancel_exit => catalogue.validType(node.value_type, program.definitions),
        // P3.2: an await yields what its task or event gives; a signal carries the event's type.
        .task_await => |operand| operand < prior.len and sameType(awaitedResult(program, prior[operand].value_type), node.value_type),
        .event_new => catalogue.isEvent(node.value_type, program.definitions),
        .event_signal => |signal| signal.event < prior.len and signal.value < prior.len and sameType(signalValue(program, prior[signal.event].value_type), prior[signal.value].value_type) and unitTyped(program, node.value_type),
        .event_await => |operand| operand < prior.len and sameType(eventValue(program, prior[operand].value_type), node.value_type),
        // P3.7: a cancellation request to a task, by its handle, which yields the unit value; and
        // the clock in seconds.
        .task_cancel => |operand| operand < prior.len and catalogue.isTask(prior[operand].value_type, program.definitions) and unitTyped(program, node.value_type),
        .elapsed_time => node.value_type == .float,
        // P3.3 (admission rule 4): arms are callables of no parameters that suspend and cannot
        // fail; a `sync` yields the tuple of their results in order, a `race` the one result
        // type they all have.
        .structured => structuredTyped(program, node, prior),
        // P3.4: a callable of no parameters that suspends, cannot fail and yields the unit
        // value, which the node yields too.
        .branch => |operand| operand < prior.len and branchTyped(program, prior[operand].value_type, node.value_type),
        // RFC-0084 (admission rules 1 to 3): a guard of the cell's type that only reads, and the
        // declaration of a cell where its `cell_init` would stand.
        .cell_live => |c| c.cell < program.source_cells.len and node.value_type == program.source_cells[c.cell].value_type and c.guard < prior.len and guardTyped(program, prior[c.guard].value_type, node.value_type) and (if (c.initialize) program.source_cells[c.cell].initial == prior.len else program.source_cells[c.cell].initial < prior.len and !program.source_cells[c.cell].live_only) and cellVisible(program, c.cell, node.span) and liveRecordType(program, node.value_type) != null,
        // RFC-0084, P4.2 (admission rules 1 and 2): a guard of the field's type that only reads,
        // on a `var` or live-only field of a class instance. Where a live-only field may be the
        // target is the function's matter (`clausesHeld`, `validFunctions`).
        .object_live => |c| blk: {
            if (c.object >= prior.len or c.guard >= prior.len) break :blk false;
            const field = liveField(program, prior[c.object].value_type, c.field) orelse break :blk false;
            break :blk node.value_type == field.value_type and guardTyped(program, prior[c.guard].value_type, field.value_type) and liveRecordType(program, field.value_type) != null;
        },
        // RFC-0084, P4.4 (admission rules 1 and 4): a guard that only reads and yields an
        // option, a body that cannot fail or suspend, and the handle of the body's result (an
        // `upon`) or of the unit value (a `when`). The body's heap effects are its function's
        // matter (`validFunctions`); at the root it may do anything.
        .reaction => |r| r.guard < prior.len and r.body < prior.len and reactionTyped(program, r, prior[r.guard].value_type, prior[r.body].value_type, node.value_type),
        // RFC-0084, P4.5 (admission rule 4): a body that cannot fail or suspend, whose result
        // the node yields. Its heap effects are its function's matter (`validFunctions`).
        .batch => |operand| operand < prior.len and batchTyped(program, prior[operand].value_type, node.value_type),
        // RFC-0084, P4.6 (admission rule 1): the guard of an `Await`, which only reads and yields
        // an option of what the site yields. Where a site stands is a body's matter.
        .await_guard => |operand| operand < prior.len and awaitTyped(program, prior[operand].value_type, node.value_type),
        // RFC-0082, P3.9 (C113): a subscription of a subscribable event, its callback exactly of
        // the callback type of the event's value type, is a `cancelable`; a cancellation of one
        // is the unit value; the calls of a `Signal` take the one value, of the event's type.
        .event_subscribe => |s| s.event < prior.len and s.callback < prior.len and subscribableValue(program, prior[s.event].value_type) != null and callbackTyped(program, prior[s.callback].value_type, subscribableValue(program, prior[s.event].value_type).?) and catalogue.isCancelable(node.value_type, program.definitions),
        .subscription_cancel => |operand| operand < prior.len and catalogue.isCancelable(prior[operand].value_type, program.definitions) and unitTyped(program, node.value_type),
        .event_notify => |n| n.callable < prior.len and validSpan(n.arguments, program.call_arguments.len) and n.arguments.end - n.arguments.start == 1 and program.call_arguments[n.arguments.start] < prior.len and sameType(subscribableValue(program, prior[n.callable].value_type), prior[program.call_arguments[n.arguments.start]].value_type) and unitTyped(program, node.value_type),
        // RFC-0085, I1 (admission rules 2 to 4): a variable cell `ref(T)` of an operand of type
        // `T`; a read of a `ref(T)`, which yields a `T`; a write of a `T` to a `ref(T)`, which
        // yields the `T` written. Their effects are their function's matter (`stateAllowed`).
        .ref_new => |operand| operand < prior.len and refHolds(program, node.value_type, prior[operand].value_type),
        .ref_get => |operand| operand < prior.len and refHolds(program, prior[operand].value_type, node.value_type),
        .ref_set => |r| r.ref < prior.len and r.value < prior.len and refHolds(program, prior[r.ref].value_type, node.value_type) and prior[r.value].value_type == node.value_type,
        // RFC-0086, P2.3 (admission rule 2): a known kind, an earlier name of type `string`, and
        // the type `option(grant(kind))`, whose definitions the catalogue holds.
        // RFC-0087, P5.4 (admission rule 3): of kind `session`, no name and the type
        // `grant(session)` itself.
        .grant => |g| if (g.kind == .session) g.name == types.no_grant_name and catalogue.grantKind(node.value_type, program.definitions) == types.GrantKind.session else (g.kind == .reader or g.kind == .writer or g.kind == .key) and g.name < prior.len and prior[g.name].value_type == .string and grantTyped(program, g.kind, node.value_type),
        // RFC-0087, P5.4 (admission rules 4 and 5): a keyed cell's declaration where it is
        // declared, and its lookup and update after it, of the cell's key and value types.
        .weak_init => |c| c < program.source_cells.len and program.source_cells[c].keyed != .none and node.value_type == program.source_cells[c].value_type and program.source_cells[c].initial == prior.len and cellVisible(program, c, node.span),
        .weak_get, .weak_set => keyedTyped(program, node, prior) and program.source_cells[keyedCellOf(node)].initial < prior.len and cellVisible(program, keyedCellOf(node), node.span),
        // RFC-0087, P5.3 (admission rule 6): a `string` of an earlier value, and an option of an
        // earlier `string`; that the value's or the option's type is persistable, `validJson`.
        .json_encode => |operand| operand < prior.len and node.value_type == .string,
        .json_decode => |operand| operand < prior.len and prior[operand].value_type == .string and catalogue.definition(node.value_type, program.definitions) != null and catalogue.definition(node.value_type, program.definitions).? == .option,
    };
}

/// RFC-0087, P5.4: the cell a `weak_get` or `weak_set` names.
fn keyedCellOf(node: types.Node) u32 {
    return switch (node.kind) {
        .weak_get => |g| g.cell,
        .weak_set => |c| c.cell,
        else => unreachable,
    };
}

/// RFC-0087, P5.4 (admission rule 5): a `weak_get` of a keyed cell has an earlier key of the
/// cell's key type and the type `option(V)`; a `weak_set` also an earlier value of type `V`,
/// and the type `V`.
fn keyedTyped(program: types.Program, node: types.Node, prior: []const types.Node) bool {
    const cell = keyedCellOf(node);
    if (cell >= program.source_cells.len or program.source_cells[cell].keyed == .none) return false;
    const entries = catalogue.entryShape(program.source_cells[cell].value_type, program.definitions) orelse return false;
    switch (node.kind) {
        .weak_get => |g| {
            if (g.key >= prior.len or prior[g.key].value_type != entries.key) return false;
            const option = catalogue.definition(node.value_type, program.definitions) orelse return false;
            return option == .option and option.option == entries.value;
        },
        .weak_set => |c| return c.key < prior.len and c.value < prior.len and prior[c.key].value_type == entries.key and prior[c.value].value_type == entries.value and node.value_type == entries.value,
        else => unreachable,
    }
}

/// RFC-0087, P5.4 (admission rule 4): every cell operation of the program, at the root and in
/// a function, names a keyed cell exactly when it is one of the three that may.
fn keyedNamesValid(program: types.Program) bool {
    for (program.nodes) |node| if (!keyedNamed(program, node)) return false;
    for (program.function_nodes) |entry| if (entry.input == .operation and !keyedNamed(program, entry.node)) return false;
    return true;
}
fn keyedNamed(program: types.Program, node: types.Node) bool {
    const cell: u32, const keyed = switch (node.kind) {
        .cell_init, .cell_write => |c| .{ c.cell, false },
        .cell_read => |c| .{ c, false },
        .cell_live => |c| .{ c.cell, false },
        .weak_init => |c| .{ c, true },
        .weak_get => |g| .{ g.cell, true },
        .weak_set => |c| .{ c.cell, true },
        else => return true,
    };
    // A cell no program has is refused where the operation is admitted.
    if (cell >= program.source_cells.len) return true;
    return (program.source_cells[cell].keyed != .none) == keyed;
}

/// RFC-0087, P5.3: the facts admission rule 6 reads, worked out when the program holds a JSON
/// node, at its root or in a function.
fn jsonFacts(program: types.Program) error{OutOfMemory}!persistable.JsonFacts {
    const needed = for (program.nodes) |node| {
        if (node.kind == .json_encode or node.kind == .json_decode) break true;
    } else for (program.function_nodes) |entry| {
        if (entry.input == .operation and (entry.node.kind == .json_encode or entry.node.kind == .json_decode)) break true;
    } else false;
    if (!needed) return .{};
    return persistable.JsonFacts.of(program.definitions, program.tuple_elements, program.fields);
}

/// RFC-0087, P5.3 (admission rule 6): an encode's value and a decode's result are of a
/// persistable type. `validNode` has admitted the operand.
fn validJson(node: types.Node, prior: []const types.Node, program: types.Program, json: persistable.JsonFacts) bool {
    return switch (node.kind) {
        .json_encode => |operand| operand < prior.len and json.persistableType(prior[operand].value_type, program.definitions),
        .json_decode => {
            const shape = catalogue.definition(node.value_type, program.definitions) orelse return false;
            return shape == .option and json.persistableType(shape.option, program.definitions);
        },
        else => true,
    };
}

/// RFC-0087, P5.3 (admission rule 6): an encode of a type that reaches a class reads instances
/// and a decode of one builds them, so the function declares `<reads>` or `<allocates>`.
fn jsonAllowed(node: types.Node, prior: []const types.Node, program: types.Program, json: persistable.JsonFacts, allowed: types.EffectSet) bool {
    return switch (node.kind) {
        .json_encode => |operand| operand < prior.len and (allowed.reads or !json.reachesClass(prior[operand].value_type, program.definitions)),
        .json_decode => {
            const shape = catalogue.definition(node.value_type, program.definitions) orelse return false;
            return shape == .option and (allowed.allocates or !json.reachesClass(shape.option, program.definitions));
        },
        else => true,
    };
}

/// RFC-0087, P5.3: the reference's host of the JSON codec, whose instances are the state's cells.
const ReferenceJson = struct {
    state: ?*source_state.ReferenceState,
    problem: source_state.Error = error.SourceCellIndex,

    pub fn field(self: *ReferenceJson, object: types.ObjectRef, index: u32) error{Host}!types.Value {
        const state = self.state orelse return error.Host;
        return state.read(object.id + 1 + index) catch |err| {
            self.problem = err;
            return error.Host;
        };
    }
    pub fn instance(self: *ReferenceJson, class: types.Type, cells: []const types.Value, block: u32) error{Host}!u32 {
        _ = class;
        _ = block;
        const state = self.state orelse return error.Host;
        return state.allocate(cells) catch |err| {
            self.problem = err;
            return error.Host;
        };
    }
    pub fn instanceMark(self: *ReferenceJson) usize {
        return if (self.state) |state| state.cell_count else 0;
    }
    pub fn instanceDrop(self: *ReferenceJson, mark: usize) void {
        if (self.state) |state| state.truncate(mark);
    }
};

/// RFC-0087, P5.3: `ToJson` or `FromJson` of `operand`, a value of `operand_type`, on the
/// reference's pools. The codec's stack is made at the run's first JSON node.
fn referenceJson(program: types.Program, node: types.Node, operand_type: types.Type, operand: types.Value, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, frames: *call_frames.ReferenceStorage, state: ?*source_state.ReferenceState, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
    if (frames.json == null) frames.json = scratch.storage(persist_json.Stack) catch return .{ .failed = .scratch_unavailable };
    var host: ReferenceJson = .{ .state = state };
    const cat = persist_json.Catalogue.of(program);
    const room = members[0..@min(members.len, types.limits.aggregate_elements)];
    const outcome: persist_json.Error!types.Value = switch (node.kind) {
        .json_encode => if (persist_json.encode(cat, &host, room[0..member_count.*], operand_type, operand, pool, frames.json.?, remaining)) |text| .{ .string = text } else |err| err,
        .json_decode => persist_json.decode(cat, &host, .{ .slots = room, .count = member_count }, node.value_type, operand.string, pool, frames.json.?, key_work, remaining),
        else => unreachable,
    };
    const made = outcome catch |err| return .{ .failed = switch (err) {
        error.WorkLimit => .work_limit,
        error.StringLimit => .string_limit,
        error.AggregateLimit => .aggregate_limit,
        error.DepthLimit => .json_depth_limit,
        error.ScratchUnavailable => .scratch_unavailable,
        error.InvalidValue => .invalid_ir,
        error.Host => source_state.diagnostic(host.problem),
    } };
    return .{ .ok = made };
}

/// RFC-0087, P5.5 (S4): the map a persistent cell starts as. Each key grant in order is asked
/// for the cell's entry (an input of kind `load`, tick 0), the answers are read back from the
/// record, and the present ones are decoded as the cell's value type (E3), each laid out as a
/// value is: its members first. While they are decoded each value waits in the top of the pool,
/// outside the room the decodes have; then the entries' pairs, keys and values side by side, are
/// laid out after the last value, as a map literal's are. Charges 1 per load, what each decode
/// charges, and 2 per entry. A text that does not decode ends the run, `load_invalid`.
fn referenceLoads(program: types.Program, cell: u32, node: types.Node, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, frames: *call_frames.ReferenceStorage, log: *effects.Log, state: ?*source_state.ReferenceState, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
    const shape = catalogue.definition(node.value_type, program.definitions) orelse return .{ .failed = .invalid_ir };
    if (shape != .weak_map) return .{ .failed = .invalid_ir };
    const grants = log.inputs.grants;
    const first = log.inputs.count;
    var asked: u32 = 0;
    for (grants, 0..) |grant, index| {
        if (grant.kind != .key) continue;
        if (remaining.* == 0) return .{ .failed = .work_limit };
        remaining.* -= 1;
        _ = log.inputs.read(.{ .kind = .load, .request = effects.loadRequest(cell, @intCast(index)), .tick = 0 }) catch |err| return .{ .failed = native.inputErrorCode(err) };
        asked += 1;
    }
    var present: usize = 0;
    for (log.inputs.entries[first .. first + asked]) |entry| present += @intFromBool(entry.status == .value);
    const pool_room = members[0..@min(members.len, types.limits.aggregate_elements)];
    const base = member_count.*;
    if (base > pool_room.len or present > pool_room.len - base) return .{ .failed = .aggregate_limit };
    // The values wait at the top, beyond the room the decodes have.
    const room = pool_room[0 .. pool_room.len - present];
    if (present != 0) {
        if (frames.json == null) frames.json = scratch.storage(persist_json.Stack) catch return .{ .failed = .scratch_unavailable };
        var host: ReferenceJson = .{ .state = state };
        const cat = persist_json.Catalogue.of(program);
        var waiting: usize = 0;
        var ordinal: u32 = 0;
        for (grants) |grant| {
            if (grant.kind != .key) continue;
            const entry = log.inputs.entries[first + ordinal];
            ordinal += 1;
            if (entry.status != .value) continue;
            const made = persist_json.decodeEntry(cat, &host, .{ .slots = room, .count = member_count }, shape.weak_map.value, log.inputs.bytes[entry.start..entry.end], pool, frames.json.?, key_work, remaining) catch |err| return .{ .failed = jsonCode(err, host.problem) };
            pool_room[pool_room.len - 1 - waiting] = made orelse return .{ .failed = .load_invalid };
            waiting += 1;
        }
    }
    const start = member_count.*;
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
        room[start + 2 * pair] = .{ .enumeration = .{ .value_type = shape.weak_map.key, .index = @intCast(index) } };
        room[start + 2 * pair + 1] = pool_room[pool_room.len - 1 - pair];
        pair += 1;
    }
    member_count.* = start + 2 * present;
    return .{ .ok = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = @intCast(start), .end = @intCast(start + 2 * present) } } } };
}

/// The diagnostic of a codec error (`host` is what the reference's host kept).
fn jsonCode(err: persist_json.Error, host: source_state.Error) types.Diagnostic.Code {
    return switch (err) {
        error.WorkLimit => .work_limit,
        error.StringLimit => .string_limit,
        error.AggregateLimit => .aggregate_limit,
        error.DepthLimit => .json_depth_limit,
        error.ScratchUnavailable => .scratch_unavailable,
        error.InvalidValue => .invalid_ir,
        error.Host => source_state.diagnostic(host),
    };
}

/// RFC-0087, P5.5 (S5): the store action of a `weak_set` of a persistent cell, prepared on the
/// store channel right after the write: `{"cell":NAME,"key":NAME,"value":TEXT}`. The text is
/// built in the string pool and given back to it once the log has its copy. Null when the
/// cell is not persistent, or when the action was prepared; otherwise the diagnostic.
fn referenceStoreAction(program: types.Program, c: types.WeakSet, key: types.Value, value: types.Value, members: []types.Value, member_count: usize, pool: *run_strings.Pool, frames: *call_frames.ReferenceStorage, log: *effects.Log, state: ?*source_state.ReferenceState, remaining: *u64) ?types.Diagnostic.Code {
    const cell = program.source_cells[c.cell];
    if (cell.keyed != .persistent) return null;
    const grants = log.inputs.grants;
    if (key != .enumeration or key.enumeration.index >= grants.len or grants[key.enumeration.index].kind != .key) return .invalid_ir;
    const entry = persistable.persistentValue(cell.value_type, program.definitions) orelse return .invalid_ir;
    if (frames.json == null) frames.json = scratch.storage(persist_json.Stack) catch return .scratch_unavailable;
    var host: ReferenceJson = .{ .state = state };
    const saved = pool.used;
    defer pool.used = saved;
    const room = members[0..@min(members.len, types.limits.aggregate_elements)];
    const text = persist_json.encodeStoreAction(persist_json.Catalogue.of(program), &host, room[0..member_count], entry, value, cell.name, grants[key.enumeration.index].name, pool, frames.json.?, remaining) catch |err| return jsonCode(err, host.problem);
    log.prepareOn(effects.store_channel, text) catch |err| return native.effectErrorCode(err);
    return null;
}

/// RFC-0086, P2.3: whether `option_type` is `option(grant(kind))`, the type of a `grant`.
fn grantTyped(program: types.Program, kind: types.GrantKind, option_type: types.Type) bool {
    const shape = catalogue.definition(option_type, program.definitions) orelse return false;
    if (shape != .option) return false;
    const handle = catalogue.grantKind(shape.option, program.definitions) orelse return false;
    return handle == kind;
}

/// RFC-0086, P2.3 (H3): the handle of the first of the run's grants of kind `g.kind` named
/// `name`, as an option of `option_type` whose one member is the next of the pool; `option{}`
/// when none is. One unit is charged per grant of the kind compared, the matching one included,
/// before anything is built. `room` is how many members the pool can still take.
fn referenceGrant(grants: []const effects.Grant, g: types.Grant, name: []const u8, option_type: types.Type, program: types.Program, members: []types.Value, member_count: *usize, room: usize, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
    const handle = catalogue.definition(option_type, program.definitions).?.option;
    const found: ?u32 = for (grants, 0..) |grant, index| {
        if (grant.kind != g.kind) continue;
        if (remaining.* == 0) return .{ .failed = .work_limit };
        remaining.* -= 1;
        if (std.mem.eql(u8, grant.name, name)) break @intCast(index);
    } else null;
    const start = member_count.*;
    if (found) |index| {
        if (room == 0) return .{ .failed = .aggregate_limit };
        members[start] = .{ .enumeration = .{ .value_type = handle, .index = index } };
        member_count.* = start + 1;
    }
    return .{ .ok = .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = @intCast(start), .end = @intCast(member_count.*) } } } };
}

/// RFC-0087, P5.4 (K1): the run's one session, index 0 of its type, which builds nothing.
fn referenceSession(session_type: types.Type) types.Value {
    return .{ .enumeration = .{ .value_type = session_type, .index = 0 } };
}

/// RFC-0087, P5.4: the entry of `key` in a keyed cell's map, as `map_lookup` finds it: an
/// option viewing the value, or empty.
fn referenceWeakGet(map: types.Value, key: types.Value, option_type: types.Type, members: []types.Value, key_work: *keys.Work, remaining: *u64) EvalError!types.Value {
    const range = map.aggregate.elements;
    const offset = try keys.lookup(key_work, members, members[range.start..range.end], key, remaining);
    const start: u32 = if (offset) |position| range.start + @as(u32, @intCast(position)) else range.end;
    return .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = start, .end = start + @intFromBool(offset != null) } } };
}

/// RFC-0087, P5.4: a keyed cell's map with the entry of `key` replaced or appended, built in the
/// next members as `map_set` builds it, at the same cost.
fn referenceWeakSet(map: types.Value, key: types.Value, value: types.Value, members: []types.Value, member_count: *usize, key_work: *keys.Work, remaining: *u64) EvalError!types.Value {
    const range = map.aggregate.elements;
    const found = try keys.lookup(key_work, members, members[range.start..range.end], key, remaining);
    const length = range.end - range.start;
    const total: u32 = length + if (found == null) @as(u32, 2) else 0;
    const capacity = @min(members.len, types.limits.aggregate_elements);
    if (total > capacity - member_count.*) return error.AggregateLimit;
    if (total > remaining.*) return error.WorkLimit;
    remaining.* -= total;
    const base = member_count.*;
    @memcpy(members[base .. base + length], members[range.start..range.end]);
    if (found) |position| {
        members[base + position] = value;
    } else {
        members[base + length] = key;
        members[base + length + 1] = value;
    }
    member_count.* += total;
    return .{ .aggregate = .{ .value_type = map.aggregate.value_type, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
}

/// The diagnostic of a keyed cell's lookup or update that could not complete.
fn keyedCode(err: EvalError) types.Diagnostic.Code {
    return switch (err) {
        error.AggregateLimit => .aggregate_limit,
        error.WorkLimit => .work_limit,
        error.ScratchUnavailable => .scratch_unavailable,
        else => .invalid_ir,
    };
}

/// RFC-0085, I1: whether `ref_type` is the variable cell type `ref(value_type)`.
fn refHolds(program: types.Program, ref_type: types.Type, value_type: types.Type) bool {
    const value = catalogue.refValue(ref_type, program.definitions) orelse return false;
    return value == value_type;
}

/// RFC-0084, P4.6: the guard of an `await_guard` site is a function of no parameters whose
/// effect lies within `<reads>`, yielding `option(T)` for the site's type `T`.
fn awaitTyped(program: types.Program, guard: types.Type, yields: types.Type) bool {
    const shape = catalogue.definition(guard, program.definitions) orelse return false;
    if (shape != .callable) return false;
    const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.start != parameters.tuple.end) return false;
    const option = catalogue.definition(shape.callable.result, program.definitions) orelse return false;
    return option == .option and option.option == yields and shape.callable.effects().within(.{ .reads = true });
}

/// P3.9: the value type of a `subscribable_event(T)`; null for any other type.
fn subscribableValue(program: types.Program, value_type: types.Type) ?types.Type {
    const shape = catalogue.definition(value_type, program.definitions) orelse return null;
    return if (shape == .event and shape.event.kind == .subscribable) shape.event.value else null;
}
/// P3.9 (C108): whether `callback` is `function<transacts>(tuple(value), void)` exactly.
fn callbackTyped(program: types.Program, callback: types.Type, value: types.Type) bool {
    const shape = catalogue.definition(callback, program.definitions) orelse return false;
    if (shape != .callable) return false;
    const c = shape.callable;
    if (!c.transacts or c.decides or c.detail.no_reads or c.detail.no_writes or c.detail.no_allocates or c.detail.suspends or c.detail.converges or c.detail.predicts or c.detail.reserved != 0) return false;
    const parameters = catalogue.definition(c.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start != 1 or parameters.tuple.end > program.tuple_elements.len or program.tuple_elements[parameters.tuple.start] != value) return false;
    return unitTyped(program, c.result);
}

/// RFC-0084, P4.5: the body of a `batch` is a closure of no parameters that neither decides nor
/// suspends, and yields the node's type.
fn batchTyped(program: types.Program, body: types.Type, result: types.Type) bool {
    const shape = catalogue.definition(body, program.definitions) orelse return false;
    if (shape != .callable or shape.callable.decides or shape.callable.detail.suspends or shape.callable.result != result) return false;
    const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
    return parameters == .tuple and parameters.tuple.start == parameters.tuple.end;
}

/// RFC-0084, P4.4: the types of a `reaction`, its guard's, its body's and its handle's.
fn reactionTyped(program: types.Program, r: types.Reaction, guard: types.Type, body: types.Type, handle: types.Type) bool {
    const guard_shape = catalogue.definition(guard, program.definitions) orelse return false;
    if (guard_shape != .callable) return false;
    const guard_parameters = catalogue.definition(guard_shape.callable.parameters, program.definitions) orelse return false;
    if (guard_parameters != .tuple or guard_parameters.tuple.start != guard_parameters.tuple.end) return false;
    const yielded = catalogue.definition(guard_shape.callable.result, program.definitions) orelse return false;
    if (yielded != .option or !guard_shape.callable.effects().within(.{ .reads = true })) return false;
    const body_shape = catalogue.definition(body, program.definitions) orelse return false;
    if (body_shape != .callable or body_shape.callable.decides or body_shape.callable.detail.suspends) return false;
    const body_parameters = catalogue.definition(body_shape.callable.parameters, program.definitions) orelse return false;
    if (body_parameters != .tuple or body_parameters.tuple.start != body_parameters.tuple.end) return false;
    const target = catalogue.definition(handle, program.definitions) orelse return false;
    if (target != .task) return false;
    return switch (r.kind) {
        .upon => target.task.result == body_shape.callable.result,
        .when => unitTyped(program, target.task.result),
    };
}

const no_construction = std.math.maxInt(u32);
/// RFC-0084, P4.2: a function that holds the clauses of a class with live fields
/// (`clauses_of`) is reached only by a `call` handed the instance of the latest `object_new`
/// before it in the same body, or one upcast of it; no function value, iteration or dispatch
/// names it (C28).
fn clausesHeld(node: types.Node, prior: []const types.Node, program: types.Program, arguments: []const u32, last_new: u32) bool {
    switch (node.kind) {
        .function_value => |id| return id >= program.functions.len or program.functions[id].clauses_of == null,
        .iterate => |i| return i.function >= program.functions.len or program.functions[i.function].clauses_of == null,
        .call => |c| {
            if (c.function >= program.functions.len or program.functions[c.function].clauses_of == null) return true;
            if (!validSpan(c.arguments, arguments.len) or c.arguments.end - c.arguments.start != 1) return false;
            var operand = arguments[c.arguments.start];
            if (operand >= prior.len) return false;
            if (prior[operand].kind == .upcast) operand = prior[operand].kind.upcast;
            return operand == last_new and prior[operand].kind == .object_new;
        },
        else => return true,
    }
}
/// RFC-0084, P4.2: a function that says it holds the clauses of a class is shaped as the
/// compiler writes one: named, `(Self:Class):logic`, without `<decides>` or `<suspends>`.
fn clausesShaped(p: types.Program, f: types.RuntimeFunction) bool {
    const class = f.clauses_of orelse return true;
    const shape = catalogue.definition(class, p.definitions) orelse return false;
    return shape == .class and !shape.class.is_interface and !f.anonymous and f.parameter_count == 1 and f.parameters[0] == class and f.value_type == .logic and !f.decides and !f.detail.suspends;
}

/// RFC-0084, admission rule 1: a live guard is a function of no parameters yielding the target's
/// type, whose effect lies within `<reads>`: it cannot write, allocate, fail or suspend.
fn guardTyped(program: types.Program, guard: types.Type, target: types.Type) bool {
    const shape = catalogue.definition(guard, program.definitions) orelse return false;
    if (shape != .callable or shape.callable.result != target) return false;
    const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.start != parameters.tuple.end) return false;
    const allowed: types.EffectSet = .{ .reads = true };
    return shape.callable.effects().within(allowed);
}
/// The record type `live(T)` of a cell of type `T` (RFC-0084): admission requires it in the
/// catalogue for every target, so every record a run builds has it.
fn liveRecordType(program: types.Program, target: types.Type) ?types.Type {
    for (program.definitions, 0..) |item, index| if (item == .live and item.live == target) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    return null;
}

/// Admission rule 4 for a `structured` node (RFC-0082, P3.3), whose arms lie in the argument
/// pool of `program` (a body's, when a body is admitted).
fn structuredTyped(program: types.Program, node: types.Node, prior: []const types.Node) bool {
    const arms = node.kind.structured.arms;
    if (!validSpan(arms, program.call_arguments.len)) return false;
    const count = arms.end - arms.start;
    if (count < 2 or count > types.limits.parameters) return false;
    var results: [types.limits.parameters]types.Type = undefined;
    for (program.call_arguments[arms.start..arms.end], results[0..count]) |operand, *result| {
        if (operand >= prior.len) return false;
        const shape = catalogue.definition(prior[operand].value_type, program.definitions) orelse return false;
        if (shape != .callable) return false;
        const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
        if (parameters != .tuple or parameters.tuple.start != parameters.tuple.end) return false;
        if (shape.callable.decides or !shape.callable.detail.suspends) return false;
        result.* = shape.callable.result;
    }
    switch (node.kind.structured.kind) {
        .sync => {
            const shape = catalogue.definition(node.value_type, program.definitions) orelse return false;
            if (shape != .tuple or shape.tuple.end - shape.tuple.start != count or shape.tuple.end > program.tuple_elements.len) return false;
            for (program.tuple_elements[shape.tuple.start..shape.tuple.end], results[0..count]) |element, result| if (element != result) return false;
        },
        .race, .rush => for (results[0..count]) |result| if (result != node.value_type) return false,
    }
    return true;
}

/// Admission rule 4 for a `branch` (RFC-0082, P3.4): its callable takes no parameters, suspends,
/// cannot fail and yields the unit value, which is the node's type.
fn branchTyped(program: types.Program, callable: types.Type, unit: types.Type) bool {
    const shape = catalogue.definition(callable, program.definitions) orelse return false;
    if (shape != .callable or shape.callable.decides or !shape.callable.detail.suspends) return false;
    const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.start != parameters.tuple.end) return false;
    return unitTyped(program, unit) and shape.callable.result == unit;
}

/// Whether `value` is a value of type `target`: what `instance_of` answers and `downcast`
/// requires. An instance is one of its class and of everything above it. Every other value is
/// of exactly one type, which it carries or which its form implies, so a value held as `any`
/// (RFC-0080) says what it is without a tag of its own.
fn valueIs(program: types.Program, value: types.Value, target: types.Type) bool {
    return switch (value) {
        .integer => target == .i64,
        .boolean => target == .logic,
        .string => target == .string,
        .floating => target == .float,
        .rational => catalogue.isRational(target, program.definitions),
        .aggregate => |aggregate| aggregate.value_type == target,
        .enumeration => |enumeration| enumeration.value_type == target,
        // A function is also of every function type that allows more effects (RFC-0081): what
        // sub-effecting gives every place a value meets a declared type, a cast out of `any` gives.
        .callable => |callable| callable.value_type == target or catalogue.widens(callable.value_type, target, program.definitions, program.tuple_elements),
        .object => |object| catalogue.subtype(object.value_type, target, program.definitions),
    };
}

/// Whether `refine` may take a value of `from` to `to`: one is a refinement and the other its base.
fn refinedPair(program: types.Program, from: types.Type, to: types.Type) bool {
    if (catalogue.refinementOf(to, program.definitions)) |refinement| return refinement.base == from;
    if (catalogue.refinementOf(from, program.definitions)) |refinement| return refinement.base == to;
    return false;
}

/// Whether a value of a refinement's base lies within its bounds (RFC-0083). A NaN lies within
/// none: every comparison with it is false.
fn referenceWithin(refinement: types.Refinement, value: types.Value) bool {
    switch (refinement.base) {
        .i64 => {
            const x = value.integer;
            return @as(i64, @bitCast(refinement.low)) <= x and x <= @as(i64, @bitCast(refinement.high));
        },
        .float => {
            const x = value.floating;
            const low: f64 = @bitCast(refinement.low);
            const high: f64 = @bitCast(refinement.high);
            return (if (refinement.low_open) low < x else low <= x) and (if (refinement.high_open) x < high else x <= high);
        },
        else => return false,
    }
}

fn isClass(program: types.Program, value_type: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    return shape == .class and !catalogue.pendingClass(shape.class);
}

/// Operand and result types of a text operation (RFC-0069), and one encoding per operation.
fn validText(t: types.Text, result: types.Type, prior: []const types.Node, program: types.Program) bool {
    if (!t.canonical() or t.a >= prior.len) return false;
    const first = prior[t.a].value_type;
    return switch (t.op) {
        .unit => result == types.Type.char and first == .string and integerNode(t.b, prior),
        .boundary => result == .logic and first == .string and integerNode(t.b, prior),
        .scalar => result == types.Type.char32 and first == .string and integerNode(t.b, prior),
        .slice => result == .string and first == .string and integerNode(t.b, prior) and integerNode(t.c, prior),
        .code => result == .i64 and first.isCharacter(),
        .from_code => result.isCharacter() and first == .i64,
        .valid, .join => units: {
            const shape = catalogue.definition(first, program.definitions) orelse break :units false;
            break :units shape == .array and shape.array == types.Type.char and result == @as(types.Type, if (t.op == .valid) .logic else .string);
        },
    };
}

fn integerNode(index: u32, nodes: []const types.Node) bool {
    return index < nodes.len and nodes[index].value_type == .i64;
}

fn floatNode(index: u32, nodes: []const types.Node) bool {
    return index < nodes.len and nodes[index].value_type == .float;
}

fn validSpan(span: types.Span, length: usize) bool {
    return span.start <= span.end and span.end <= length;
}

fn stringBoundary(index: u32, strings: []const u8) bool {
    std.debug.assert(index <= strings.len);
    if (index == strings.len) return true;
    _ = std.unicode.utf8ByteSequenceLength(strings[index]) catch return false;
    return true;
}

/// `join` is what an array join needs to know of the run (`array_concat.Context`).
fn evaluateNode(node: types.Node, index: u32, values: []const types.Value, program: types.Program, aggregate_values: []types.Value, aggregate_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, remaining: *u64, join: array_concat.Context) EvalError!types.Value {
    @setFloatMode(.strict);
    const strings = program.strings;
    const members = program.members;
    std.debug.assert(index == values.len);
    return switch (node.kind) {
        .function_value => |id| .{ .callable = .{ .value_type = node.value_type, .function = id } },
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
        .local_set => |n| values[n],
        .upcast => |n| retyped(values[n], node.value_type),
        .downcast => |n| blk: {
            // The compiler guards this with an `instance_of` check; forged code is rejected.
            if (!valueIs(program, values[n], node.value_type)) return error.InvalidIr;
            // A function comes out at the type it is cast to, as an upcast gives it (RFC-0081).
            break :blk retyped(values[n], node.value_type);
        },
        .instance_of => |c| .{ .boolean = valueIs(program, values[c.value], c.class) },
        // The compiler guards a refinement with a `demand` of its bounds; forged code is rejected.
        .refine => |n| blk: {
            if (catalogue.refinementOf(node.value_type, program.definitions)) |refinement| if (!referenceWithin(refinement, values[n])) return error.InvalidIr;
            break :blk values[n];
        },
        .method_value => |m| .{ .callable = .{ .value_type = node.value_type, .function = catalogue.dispatchLookup(program.dispatch, values[m.receiver].object.value_type, m.slot) orelse return error.InvalidIr } },
        .integer => |value| .{ .integer = value },
        .floating => |value| .{ .floating = types.canonicalFloat(value) },
        .boolean => |value| .{ .boolean = value },
        .string => |span| blk: {
            if (span.start > span.end or span.end > strings.len) return error.InvalidIr;
            break :blk .{ .string = strings[span.start..span.end] };
        },
        .negate => |operand| blk: {
            const value = try integerOperand(operand, values);
            const result = @subWithOverflow(@as(i64, 0), value);
            if (result[1] != 0) return error.Overflow;
            break :blk .{ .integer = result[0] };
        },
        .binary => |binary| .{ .integer = try calculate(binary.op, try integerOperand(binary.lhs, values), try integerOperand(binary.rhs, values)) },
        .float_negate => |operand| .{ .floating = types.canonicalFloat(-(try floatOperand(operand, values))) },
        .int_to_float => |operand| .{ .floating = @floatFromInt(values[operand].integer) },
        .float_to_int => |c| .{ .integer = try referenceFloatToInt(c.mode, try floatOperand(c.operand, values)) },
        .logic_not => |operand| .{ .boolean = !values[operand].boolean },
        .logic_binary => |binary| .{ .boolean = if (binary.op == .both) values[binary.lhs].boolean and values[binary.rhs].boolean else values[binary.lhs].boolean or values[binary.rhs].boolean },
        .compare => |comparison| .{ .boolean = try referenceCompare(comparison.op, values[comparison.lhs], values[comparison.rhs], aggregate_values, key_work, remaining) },
        .float_binary => |binary| .{ .floating = calculateFloat(binary.op, try floatOperand(binary.lhs, values), try floatOperand(binary.rhs, values)) },
        .rational => |r| try referenceRational(r, values),
        .aggregate => |range| blk: {
            std.debug.assert(range.start == aggregate_count.*);
            std.debug.assert(range.end <= aggregate_values.len);
            for (members[range.start..range.end], aggregate_values[range.start..range.end]) |operand, *destination| destination.* = values[operand];
            if (catalogue.entryShape(node.value_type, program.definitions) != null) try keys.unique(key_work, aggregate_values, aggregate_values[range.start..range.end], remaining);
            aggregate_count.* = range.end;
            break :blk .{ .aggregate = .{ .value_type = node.value_type, .elements = range } };
        },
        .field, .tuple_element => |access| blk: {
            const range = values[access.value].aggregate.elements;
            std.debug.assert(range.end <= aggregate_count.*);
            std.debug.assert(access.index < range.end - range.start);
            break :blk aggregate_values[range.start + access.index];
        },
        .array_length => |operand| blk: {
            const range = values[operand].aggregate.elements;
            std.debug.assert(range.start <= range.end and range.end <= aggregate_count.*);
            const shape = catalogue.definition(values[operand].aggregate.value_type, program.definitions).?;
            break :blk .{ .integer = (range.end - range.start) / @as(u32, if (shape == .map) 2 else 1) };
        },
        .option_present => |operand| .{ .boolean = values[operand].aggregate.elements.start != values[operand].aggregate.elements.end },
        .option_or => |choice| choice: {
            const range = values[choice.option].aggregate.elements;
            break :choice if (range.start == range.end) values[choice.fallback] else aggregate_values[range.start];
        },
        .array_concat => |c| blk: {
            const left = values[c.lhs].aggregate.elements;
            const right = values[c.rhs].aggregate.elements;
            const capacity = @min(aggregate_values.len, types.limits.aggregate_elements);
            const joined = array_concat.plan(left, right, aggregate_count.*, array_concat.roomIn(aggregate_values[0..aggregate_count.*], left, right, capacity, join));
            if (joined.appended() > capacity - aggregate_count.*) return error.AggregateLimit;
            if (joined.copy > remaining.*) return error.WorkLimit;
            remaining.* -= joined.copy;
            array_concat.apply(aggregate_values, aggregate_count, left, right, joined);
            break :blk .{ .aggregate = .{ .value_type = node.value_type, .elements = joined.span } };
        },
        .string_concat => |c| .{ .string = try run_strings.concat(pool, values[c.lhs].string, values[c.rhs].string, remaining) },
        .string_length => |operand| .{ .integer = @intCast(values[operand].string.len) },
        .to_string => |operand| .{ .string = try run_strings.convert(pool, values[operand], remaining) },
        .native_call => |c| blk: {
            var arguments: [native.max_parameters]types.Value = undefined;
            for (c.args[0..c.count], 0..) |operand, i| arguments[i] = values[operand];
            break :blk switch (native.invoke(program.natives[c.native], node.value_type, arguments[0..c.count], aggregate_values[0..@min(aggregate_values.len, types.limits.aggregate_elements)], aggregate_count, pool, key_work, remaining)) {
                .ok => |value| value,
                .fault => |fault| return switch (native.faultError(fault)) {
                    error.WorkLimit => error.WorkLimit,
                    error.AggregateLimit => error.AggregateLimit,
                    error.StringLimit => error.StringLimit,
                    error.Overflow => error.Overflow,
                    error.ScratchUnavailable => error.ScratchUnavailable,
                    error.Failed => if (fault == .invalid) error.InvalidNative else error.NativeFailed,
                },
            };
        },
        .option_value => |operand| blk: {
            const range = values[operand].aggregate.elements;
            if (range.start == range.end) return error.InvalidIr;
            break :blk aggregate_values[range.start];
        },
        .map_set => |c| blk: {
            const range = values[c.map].aggregate.elements;
            const found = try keys.lookup(key_work, aggregate_values, aggregate_values[range.start..range.end], values[c.key], remaining);
            const length = range.end - range.start;
            const total: u32 = length + if (found == null) @as(u32, 2) else 0;
            const capacity = @min(aggregate_values.len, types.limits.aggregate_elements);
            if (total > capacity - aggregate_count.*) return error.AggregateLimit;
            if (total > remaining.*) return error.WorkLimit;
            remaining.* -= total;
            const base = aggregate_count.*;
            @memcpy(aggregate_values[base .. base + length], aggregate_values[range.start..range.end]);
            if (found) |position| {
                aggregate_values[base + position] = values[c.value];
            } else {
                aggregate_values[base + length] = values[c.key];
                aggregate_values[base + length + 1] = values[c.value];
            }
            aggregate_count.* += total;
            break :blk .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
        },
        .map_remove => |c| blk: {
            const range = values[c.map].aggregate.elements;
            // The lookup that guards `Without[M, K]` returned a view of the value it found, so
            // the entry is known without a second scan. Anything else is forged: an absent
            // option, or one that is not the value of an entry of this map.
            const entry = values[c.key].aggregate.elements;
            if (entry.end - entry.start != 1 or entry.start < range.start or entry.start >= range.end or (entry.start - range.start) % 2 != 1) return error.InvalidIr;
            const found = entry.start - range.start;
            const total = range.end - range.start - 2;
            const capacity = @min(aggregate_values.len, types.limits.aggregate_elements);
            if (total > capacity - aggregate_count.*) return error.AggregateLimit;
            if (total > remaining.*) return error.WorkLimit;
            remaining.* -= total;
            // The entries before the removed pair, then the ones after it, in their order.
            const base = aggregate_count.*;
            const before = found - 1;
            @memcpy(aggregate_values[base .. base + before], aggregate_values[range.start .. range.start + before]);
            @memcpy(aggregate_values[base + before .. base + total], aggregate_values[range.start + before + 2 .. range.end]);
            aggregate_count.* += total;
            break :blk .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
        },
        .array_set => |c| blk: {
            const range = values[c.array].aggregate.elements;
            const position = values[c.index].integer;
            if (position < 0 or position >= range.end - range.start) return error.InvalidIr;
            const total = range.end - range.start;
            const capacity = @min(aggregate_values.len, types.limits.aggregate_elements);
            if (total > capacity - aggregate_count.*) return error.AggregateLimit;
            if (total > remaining.*) return error.WorkLimit;
            remaining.* -= total;
            const base = aggregate_count.*;
            @memcpy(aggregate_values[base .. base + total], aggregate_values[range.start..range.end]);
            aggregate_values[base + @as(u32, @intCast(position))] = values[c.value];
            aggregate_count.* += total;
            break :blk .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = @intCast(base), .end = @intCast(base + total) } } };
        },
        .array_get => |access| blk: {
            const range = values[access.array].aggregate.elements;
            const position = values[access.index].integer;
            if (position < 0 or position >= range.end - range.start) return error.IndexRange;
            break :blk aggregate_values[range.start + @as(u32, @intCast(position))];
        },
        .map_key, .map_value => |access| blk: {
            // Entries are key and value side by side, in insertion order.
            const range = values[access.array].aggregate.elements;
            const position = values[access.index].integer;
            if (position < 0 or position >= (range.end - range.start) / 2) return error.IndexRange;
            break :blk aggregate_values[range.start + 2 * @as(u32, @intCast(position)) + @intFromBool(node.kind == .map_value)];
        },
        .map_lookup => |lookup| lookup: {
            const range = values[lookup.map].aggregate.elements;
            const offset = try keys.lookup(key_work, aggregate_values, aggregate_values[range.start..range.end], values[lookup.key], remaining);
            const start: u32 = if (offset) |position| range.start + @as(u32, @intCast(position)) else range.end;
            break :lookup .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = start, .end = start + @as(u32, if (offset == null) 0 else 1) } } };
        },
        .enumeration => |case_index| blk: {
            // Whole-program admission proved this closed nominal case exists.
            std.debug.assert(@backingInt(node.value_type) >= 4);
            std.debug.assert(case_index < types.limits.enum_cases);
            break :blk .{ .enumeration = .{ .value_type = node.value_type, .index = case_index } };
        },
        // Admission proved the code is a value of the node's character type.
        .character => |code| types.characterValue(node.value_type, code),
        .text => |t| try referenceText(t, node.value_type, values, aggregate_values, pool, remaining),
    };
}

/// The reference text operations, written against `std.unicode`; the VM decodes by hand.
/// A string value is always valid UTF-8 that starts and ends on scalar boundaries of the pool,
/// so a position is a boundary of the string exactly when it is one of the pool.
fn referenceText(t: types.Text, result: types.Type, values: []const types.Value, members: []const types.Value, pool: *run_strings.Pool, remaining: *u64) EvalError!types.Value {
    switch (t.op) {
        .unit => {
            const text = values[t.a].string;
            const position = values[t.b].integer;
            if (position < 0 or position >= text.len) return error.IndexRange;
            return types.characterValue(types.Type.char, text[@intCast(position)]);
        },
        .boundary => return .{ .boolean = referenceBoundary(values[t.a].string, values[t.b].integer) },
        .slice => {
            const text = values[t.a].string;
            const start = values[t.b].integer;
            const end = values[t.c].integer;
            // `S.Slice[A, B]` guards this with a `demand`; forged code is rejected.
            if (start < 0 or start > end or end > text.len) return error.InvalidIr;
            if (start == end) return .{ .string = text[0..0] };
            if (!referenceBoundary(text, start) or !referenceBoundary(text, end)) return error.InvalidIr;
            return .{ .string = text[@intCast(start)..@intCast(end)] };
        },
        .scalar => {
            const text = values[t.a].string;
            const position = values[t.b].integer;
            // `S.ScalarAt[I]` guards this with a `demand`; forged code is rejected. A position
            // inside an encoding holds a continuation byte, which starts no sequence.
            if (position < 0 or position >= text.len) return error.InvalidIr;
            const rest = text[@intCast(position)..];
            const length = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.InvalidIr;
            if (length > rest.len) return error.InvalidIr;
            const code = std.unicode.utf8Decode(rest[0..length]) catch return error.InvalidIr;
            return types.characterValue(types.Type.char32, code);
        },
        .code => return .{ .integer = values[t.a].enumeration.index },
        .from_code => {
            const code = values[t.a].integer;
            // `N.ToChar[]` and `N.ToChar32[]` guard this with a range `demand`; forged code is rejected.
            if (code < 0 or !types.validCharacter(result, @intCast(code))) return error.InvalidIr;
            return types.characterValue(result, @intCast(code));
        },
        .valid => {
            const range = values[t.a].aggregate.elements;
            const units = members[range.start..range.end];
            // One unit of fuel per code unit read.
            if (units.len > remaining.*) return error.WorkLimit;
            remaining.* -= units.len;
            return .{ .boolean = referenceValidUnits(units) };
        },
        .join => {
            const range = values[t.a].aggregate.elements;
            const units = members[range.start..range.end];
            // One unit of fuel per code unit read, then the string's bytes as for any string built.
            if (units.len > remaining.*) return error.WorkLimit;
            remaining.* -= units.len;
            const out = try run_strings.reserve(pool, units.len, remaining);
            for (out, units) |*byte, unit| byte.* = @intCast(unit.enumeration.index);
            // `string[Units]` guards this with a `valid` demand; forged code is rejected, so the
            // bytes just written are never the content of a string value.
            if (!std.unicode.utf8ValidateSlice(out)) return error.InvalidIr;
            return .{ .string = out };
        },
    }
}

fn referenceBoundary(text: []const u8, position: i64) bool {
    if (position < 0 or position > text.len) return false;
    if (position == text.len) return true;
    _ = std.unicode.utf8ByteSequenceLength(text[@intCast(position)]) catch return false;
    return true;
}

/// Whether `char` values, in order, are valid UTF-8: every scalar is decoded from its own
/// (at most four) units, so nothing the size of the array is needed. Public for the test that
/// compares the three validators.
pub fn referenceValidUnits(units: []const types.Value) bool {
    var index: usize = 0;
    while (index < units.len) {
        var encoded: [4]u8 = undefined;
        encoded[0] = @intCast(units[index].enumeration.index);
        const length = std.unicode.utf8ByteSequenceLength(encoded[0]) catch return false;
        if (length > units.len - index) return false;
        for (units[index + 1 .. index + length], encoded[1..length]) |unit, *byte| byte.* = @intCast(unit.enumeration.index);
        _ = std.unicode.utf8Decode(encoded[0..length]) catch return false;
        index += length;
    }
    return true;
}
/// Reference conversion: ties are detected on the truncated remainder.
pub fn referenceFloatToInt(mode: types.FloatRounding, x: f64) EvalError!i64 {
    if (!(x >= -types.integer_float_bound and x < types.integer_float_bound)) return error.InvalidIr;
    const whole = @trunc(x);
    const rounded = switch (mode) {
        .floor => if (x < whole) whole - 1 else whole,
        .ceil => if (x > whole) whole + 1 else whole,
        .truncate => whole,
        .round_even => blk: {
            const remainder = @abs(x - whole);
            if (remainder < 0.5) break :blk whole;
            const away = if (x < 0) whole - 1 else whole + 1;
            if (remainder > 0.5) break :blk away;
            break :blk if (@mod(whole, 2) == 0) whole else away;
        },
    };
    return @intFromFloat(rounded);
}
fn floatOperand(index: u32, values: []const types.Value) EvalError!f64 {
    if (index >= values.len) return error.InvalidIr;
    return switch (values[index]) {
        .floating => |value| value,
        else => error.InvalidIr,
    };
}

// Keep arithmetic independent of the bytecode implementation for differential
// testing. Strict mode rounds each IR operation, without FMA contraction.
pub fn calculateFloat(op: types.BinaryOp, lhs: f64, rhs: f64) f64 {
    @setFloatMode(.strict);
    std.debug.assert(types.isCanonicalFloat(lhs));
    std.debug.assert(types.isCanonicalFloat(rhs));
    const result = switch (op) {
        .add => lhs + rhs,
        .subtract => lhs - rhs,
        .multiply => lhs * rhs,
        .divide => lhs / rhs,
        .quotient, .modulo => unreachable, // Admission keeps these on integers.
        // Admission rejects a bitwise operator on floats.
        .bit_and, .bit_or, .bit_xor => unreachable,
    };
    return types.canonicalFloat(result);
}
fn integerOperand(index: u32, values: []const types.Value) EvalError!i64 {
    if (index >= values.len) return error.InvalidIr;
    return switch (values[index]) {
        .integer => |value| value,
        else => error.InvalidIr,
    };
}
pub fn calculate(op: types.BinaryOp, lhs: i64, rhs: i64) EvalError!i64 {
    if (op == .divide) {
        if (rhs == 0) return error.DivisionByZero;
        if (lhs == std.math.minInt(i64) and rhs == -1) return error.Overflow;
        return @divTrunc(lhs, rhs);
    }
    if (op == .quotient or op == .modulo) {
        // Euclidean division (RFC-0070): the remainder is in [0, |rhs|) and the quotient is
        // what makes `quotient * rhs + remainder` the dividend. The one pair whose quotient
        // does not fit is an error for both, as the Book has it.
        if (rhs == 0) return error.DivisionByZero;
        if (lhs == std.math.minInt(i64) and rhs == -1) return error.Overflow;
        const remainder = @mod(@as(i128, lhs), @as(i128, @abs(rhs)));
        return @intCast(if (op == .modulo) remainder else @divExact(@as(i128, lhs) - remainder, @as(i128, rhs)));
    }
    // The bits of an i64 are its two's-complement representation, so these are total.
    switch (op) {
        .bit_and => return lhs & rhs,
        .bit_or => return lhs | rhs,
        .bit_xor => return lhs ^ rhs,
        else => {},
    }
    const result = switch (op) {
        .add => @addWithOverflow(lhs, rhs),
        .subtract => @subWithOverflow(lhs, rhs),
        .multiply => @mulWithOverflow(lhs, rhs),
        .divide, .quotient, .modulo, .bit_and, .bit_or, .bit_xor => unreachable,
    };
    if (result[1] != 0) return error.Overflow;
    return result[0];
}
fn rationalOperand(index: u32, values: []const types.Value) EvalError!types.Rational {
    if (index >= values.len) return error.InvalidIr;
    return switch (values[index]) {
        .rational => |value| if (value.denominator > 0) value else error.InvalidIr,
        else => error.InvalidIr,
    };
}
/// Reference rational arithmetic: the exact answer in 128 bits, then one reduction. An
/// operation overflows exactly when its reduced answer has a term outside `i64`; nothing
/// along the way can, since a product of two `i64` terms and a sum of two such fit 128 bits.
pub fn referenceRational(r: types.RationalNode, values: []const types.Value) EvalError!types.Value {
    @setFloatMode(.strict);
    if (r.op == .make) {
        const divisor = try integerOperand(r.rhs, values);
        if (divisor == 0) return error.DivisionByZero;
        return .{ .rational = try reduced(try integerOperand(r.lhs, values), divisor) };
    }
    const a = try rationalOperand(r.lhs, values);
    const b = try rationalOperand(r.rhs, values);
    const an: i128 = a.numerator;
    const ad: i128 = a.denominator;
    const bn: i128 = b.numerator;
    const bd: i128 = b.denominator;
    return switch (r.op) {
        .make => unreachable,
        .add => .{ .rational = try reduced(an * bd + bn * ad, ad * bd) },
        .subtract => .{ .rational = try reduced(an * bd - bn * ad, ad * bd) },
        .multiply => .{ .rational = try reduced(an * bn, ad * bd) },
        .negate => .{ .rational = try reduced(-an, ad) },
        .floor => .{ .integer = @divFloor(a.numerator, a.denominator) },
        .ceil => .{ .integer = @divFloor(a.numerator, a.denominator) + @intFromBool(@mod(a.numerator, a.denominator) != 0) },
        .to_float => .{ .floating = referenceRationalToFloat(a) },
    };
}
/// Lowest terms with a positive denominator, or an overflow when a term leaves `i64`.
fn reduced(numerator: i128, denominator: i128) EvalError!types.Rational {
    std.debug.assert(denominator != 0);
    var a: u128 = @abs(numerator);
    var b: u128 = @abs(denominator);
    while (b != 0) {
        const next = a % b;
        a = b;
        b = next;
    }
    const divisor: i128 = @intCast(a);
    const sign: i128 = if (denominator < 0) -1 else 1;
    const top = @divExact(numerator, divisor) * sign;
    const bottom = @divExact(denominator, divisor) * sign;
    if (top < std.math.minInt(i64) or top > std.math.maxInt(i64) or bottom > std.math.maxInt(i64)) return error.Overflow;
    return .{ .numerator = @intCast(top), .denominator = @intCast(bottom) };
}
/// The binary64 nearest to the fraction, ties to even. Both terms are shifted to full width,
/// so the 128-bit quotient has at least 64 significant bits; a nonzero remainder is kept as
/// a low bit, far below the rounding position, and one conversion then rounds once.
fn referenceRationalToFloat(value: types.Rational) f64 {
    @setFloatMode(.strict);
    if (value.numerator == 0) return 0.0;
    const top: u64 = @abs(value.numerator);
    const bottom: u64 = @intCast(value.denominator);
    const top_shift: u7 = @clz(top);
    const bottom_shift: u7 = @clz(bottom);
    const dividend = @as(u128, top << @intCast(top_shift)) << 64;
    const divisor: u128 = bottom << @intCast(bottom_shift);
    var quotient = dividend / divisor;
    if (dividend % divisor != 0) quotient |= 1;
    const magnitude = std.math.ldexp(@as(f64, @floatFromInt(quotient)), @as(i32, bottom_shift) - @as(i32, top_shift) - 64);
    return if (value.numerator < 0) -magnitude else magnitude;
}
/// A host without memory for a key check is its own outcome, not a budget the guest exhausted.
fn keyCode(err: keys.Error) types.Diagnostic.Code {
    return switch (err) {
        error.WorkLimit => .work_limit,
        error.DuplicateKey => .duplicate_map_key,
        error.ScratchUnavailable => .scratch_unavailable,
    };
}

fn failure(span: types.Span, code: types.Diagnostic.Code) Result {
    return .{ .failed = .{ .span = span, .code = code } };
}

// Independent relation calculation: the VM dispatches direct operators instead.
pub fn referenceCompare(op: types.CompareOp, left: types.Value, right: types.Value, members: []const types.Value, key_work: *keys.Work, remaining: *u64) EvalError!bool {
    var equal: bool = undefined;
    var less = false;
    var greater = false;
    var unordered = false;
    switch (left) {
        .integer => |value| {
            equal = value == right.integer;
            less = value < right.integer;
            greater = value > right.integer;
        },
        .floating => |value| {
            // NaN is told by its bits (`types.isNan`), not by comparing a float with itself.
            unordered = types.isNan(value) or types.isNan(right.floating);
            equal = (types.isNan(value) and types.isNan(right.floating)) or value == right.floating;
            less = value < right.floating;
            greater = value > right.floating;
        },
        .boolean => |value| equal = value == right.boolean,
        .enumeration => |value| equal = value.index == right.enumeration.index,
        .rational => |value| {
            // Denominators are positive, so cross products keep the order; they fit 128 bits.
            const ours = @as(i128, value.numerator) * right.rational.denominator;
            const theirs = @as(i128, right.rational.numerator) * value.denominator;
            equal = ours == theirs;
            less = ours < theirs;
            greater = ours > theirs;
        },
        .object => |value| equal = value.id == right.object.id,
        .string => |value| {
            const cost = @min(value.len, right.string.len);
            if (cost > remaining.*) return error.WorkLimit;
            remaining.* -= cost;
            equal = std.mem.eql(u8, value, right.string);
        },
        // Structural equality is key equality: one definition for `==` and for map keys.
        .aggregate => equal = try keys.equal(key_work, members, left, right, remaining),
        .callable => unreachable, // Independent admission excludes this type.
    }
    return switch (op) {
        .equal => equal,
        .unequal => !equal,
        .less => less,
        .greater => greater,
        .less_equal => !unordered and (less or equal),
        .greater_equal => !unordered and (greater or equal),
    };
}

// Lexical-context dominance, independent of the VM's availability bitset pass.
fn accessible(program: types.Program, contexts: []const u32, operand: u32, context: u32) bool {
    if (operand >= contexts.len or types.marker(program.nodes[operand])) return false;
    var current = context;
    while (true) {
        if (contexts[operand] == current) return true;
        if (current == 0) return false;
        current = contexts[(current - 1) / 2];
    }
}
fn validateControl(program: types.Program) bool {
    return validateControlRoot(program, null, false);
}
fn validateControlRoot(program: types.Program, root: ?u32, allows_failure: bool) bool {
    const contexts = scratch.alloc(u32, program.nodes.len) orelse return false;
    defer scratch.free(contexts);
    const Frame = struct { begin: u32, alternative: bool = false };
    var frames: [types.limits.control_depth]Frame = undefined;
    var depth: usize = 0;
    var context: u32 = 0;
    for (program.nodes, 0..) |node, index| {
        contexts[index] = context;
        for (0..types.operandCount(node, program.members)) |ordinal| {
            if (!accessible(program, contexts[0..index], types.operandAt(node, ordinal, program.members, program.call_arguments), context)) return false;
        }
        switch (node.kind) {
            .cell_init => if (context != 0) {
                return false;
            },
            // RFC-0087, P5.4: so does a keyed cell's.
            .weak_init => if (context != 0) {
                return false;
            },
            // A cell declared live is initialised where its declaration stands (RFC-0084).
            .cell_live => |c| if (c.initialize and context != 0) {
                return false;
            },
            .if_begin, .attempt_begin => |b| {
                if (depth == frames.len or b.alternative <= index or b.end <= b.alternative or b.end >= program.nodes.len) return false;
                const otherwise = program.nodes[b.alternative];
                const merge = program.nodes[b.end];
                if (otherwise.kind != .otherwise or otherwise.kind.otherwise != index or merge.kind != .merge or merge.kind.merge.begin != index) return false;
                frames[depth] = .{ .begin = @intCast(index) };
                depth += 1;
                context = @intCast(index * 2 + 1);
            },
            .otherwise => |begin| {
                if (depth == 0 or frames[depth - 1].begin != begin or frames[depth - 1].alternative) return false;
                const b = branch(program.nodes[begin]);
                if (b.alternative != index) return false;
                frames[depth - 1].alternative = true;
                context = @intCast(begin * 2 + 2);
            },
            .merge => |m| {
                if (depth == 0 or frames[depth - 1].begin != m.begin or !frames[depth - 1].alternative) return false;
                if (branch(program.nodes[m.begin]).end != index) return false;
                if (!accessible(program, contexts[0..index], m.left, @intCast(m.begin * 2 + 1)) or !accessible(program, contexts[0..index], m.right, @intCast(m.begin * 2 + 2))) return false;
                depth -= 1;
                context = contexts[m.begin];
                contexts[index] = context;
            },
            .demand, .fail, .call, .iterate, .invoke, .iterate_value, .loop => {
                if (node.kind == .invoke or node.kind == .iterate_value or node.kind == .loop) {
                    const operand = if (node.kind == .invoke) node.kind.invoke.callable else if (node.kind == .iterate_value) node.kind.iterate_value.callable else node.kind.loop.callable;
                    if (!catalogue.definition(program.nodes[operand].value_type, program.definitions).?.callable.decides) continue;
                }
                if (node.invocation()) |invocation| {
                    if (!program.functions[invocation.target()].decides) continue;
                }
                var caught = allows_failure;
                for (frames[0..depth]) |frame| if (!frame.alternative and program.nodes[frame.begin].kind == .attempt_begin) {
                    caught = true;
                };
                if (!caught) return false;
            },
            else => {},
        }
    }
    if (depth != 0) return false;
    for (program.bindings) |binding| {
        if (binding.node >= program.nodes.len or !accessible(program, contexts[0..program.nodes.len], binding.node, 0)) return false;
    }
    for (program.globals) |global| if (!accessible(program, contexts[0..program.nodes.len], global.node, 0)) return false;
    if (root) |index| if (!accessible(program, contexts[0..program.nodes.len], index, 0)) return false;
    return true;
}
fn branch(node: types.Node) types.Branch {
    return if (node.kind == .if_begin) node.kind.if_begin else node.kind.attempt_begin;
}

/// Control programs require persistent caller storage. All returned slices borrow
/// it until reuse. Admission precedes initialization and consumes no guest fuel.
pub fn evaluateWithControlStorage(program: types.Program, values: []types.Value, aggregate_values: []types.Value, control: *types.ControlStorage, work_budget: u64) Result {
    return evaluateCold(program, values, aggregate_values, control, null, work_budget);
}
pub fn evaluateWithStateStorage(program: types.Program, values: []types.Value, aggregate_values: []types.Value, control: *types.ControlStorage, state: *source_state.ReferenceState, work_budget: u64) Result {
    return evaluateCold(program, values, aggregate_values, control, state, work_budget);
}
fn evaluateCold(program: types.Program, values: []types.Value, aggregate_values: []types.Value, control: *types.ControlStorage, supplied_state: ?*source_state.ReferenceState, work_budget: u64) Result {
    const frames = scratch.create(call_frames.ReferenceStorage) orelse return failure(.{ .start = 0, .end = 0 }, .scratch_unavailable);
    defer scratch.destroy(frames);
    return evaluateWithRuntimeStorage(program, values, aggregate_values, control, supplied_state, frames, work_budget);
}
/// Persistent scratch avoids the compatibility API's cold stack reservation.
/// Results borrow only root/member/control/program storage, never frame values.
pub fn evaluateWithRuntimeStorage(program: types.Program, values: []types.Value, aggregate_values: []types.Value, control: *types.ControlStorage, supplied_state: ?*source_state.ReferenceState, frames: *call_frames.ReferenceStorage, work_budget: u64) Result {
    return runtimeEvaluation(false, program, values, aggregate_values, control, supplied_state, frames, work_budget);
}

/// TASK-0109, W4.3 (RFC-0088, A3 and A4): a run of the program that this evaluator's own
/// admission of a prepared handle admitted (`prepared.ReferenceAdmission`, which only a
/// successful `validate` of the handle's frozen snapshot makes), so `validate` is not repeated.
/// Everything else is `evaluateWithRuntimeStorage`: the run's storage is checked and reset, and
/// every run-specific check (grants, inputs, the store's loads) is made as it runs. The literal
/// strings are copied into `strings`, whose remainder is the pool's tail for this run: the
/// handle is never written. Results borrow `strings` and the storage until they are reused.
pub fn evaluateAdmitted(admission: *const prepared.ReferenceAdmission, strings: []u8, values: []types.Value, aggregate_values: []types.Value, control: *types.ControlStorage, supplied_state: ?*source_state.ReferenceState, frames: *call_frames.ReferenceStorage, work_budget: u64) Result {
    // The admission was made for storage of `capacity` registers; a smaller one, or a string
    // buffer without room for the literals, is refused, and leaves no output of an earlier run.
    const program = (if (values.len < admission.capacity()) null else admission.view(strings)) orelse {
        control.effects.reset(control.trace == .full);
        return failure(.{ .start = 0, .end = 0 }, .invalid_ir);
    };
    return runtimeEvaluation(true, program, values, aggregate_values, control, supplied_state, frames, work_budget);
}

/// `admitted` is true only for `evaluateAdmitted`, whose program `validate` admitted when its
/// handle was prepared; every other caller is checked here.
fn runtimeEvaluation(comptime admitted: bool, program: types.Program, values: []types.Value, aggregate_values: []types.Value, control: *types.ControlStorage, supplied_state: ?*source_state.ReferenceState, frames: *call_frames.ReferenceStorage, work_budget: u64) Result {
    // Before admission: a run that is refused leaves no output of an earlier one behind.
    control.effects.reset(control.trace == .full);
    if (frames.depth != 0 or frames.count != 0) return failure(.{ .start = 0, .end = 0 }, .invalid_ir);
    if (!types.cold(program)) {
        if (supplied_state) |storage| {
            if (!admitted) if (validate(program, values.len)) |diagnostic| return .{ .failed = diagnostic };
            if (storage.depth != 0) return failure(.{ .start = 0, .end = 0 }, .invalid_ir);
            storage.reset(0);
        }
        var result = if (admitted) evaluateStraight(program, values, aggregate_values, work_budget) else evaluateWithStorage(program, values, aggregate_values, work_budget);
        // The run's clock went at the rate it was given, though nothing waited on it.
        if (result == .ok) result.ok.scheduler = .{ .tick_rate = control.tick_rate };
        if (result == .ok or result.failed.code != .invalid_ir) {
            control.call_count = 0;
            control.trace_count = 0;
            control.failure_count = 0;
        }
        return result;
    }
    if (!admitted) if (validate(program, values.len)) |diagnostic| return .{ .failed = diagnostic };
    if (program.members.len > aggregate_values.len) return failure(.{ .start = 0, .end = 0 }, .aggregate_limit);
    if (!needsSource(program)) if (supplied_state) |storage| {
        if (storage.depth != 0) return failure(.{ .start = 0, .end = 0 }, .invalid_ir);
        storage.reset(0);
    };
    const state = if (needsSource(program)) supplied_state orelse return failure(.{ .start = 0, .end = 0 }, .state_storage_required) else null;
    if (state) |storage| {
        if (storage.depth != 0) return failure(.{ .start = 0, .end = 0 }, .invalid_ir);
        storage.reset(program.source_cells.len);
        storage.begin() catch unreachable;
    }
    var complete = false;
    defer if (!complete) {
        control.call_count = 0;
        control.trace_count = 0;
        control.failure_count = 0;
        if (state) |storage| storage.abortAll();
    };
    // RFC-0087, P5.3 (E6): the JSON codec's stack lives as long as the run.
    defer if (frames.json) |stack| {
        scratch.release(stack);
        frames.json = null;
    };
    // A fatal error drops what is pending; what was committed has happened and stays.
    defer if (!complete) control.effects.abortAll();
    // Legal inactive placeholders protect borrowed storage from a forged mask.
    // This bounded host initialization consumes no guest instruction fuel.
    if (types.sparse(program)) for (values[0..program.nodes.len]) |*value| {
        value.* = .{ .integer = 0 };
    };
    control.reset(program.nodes.len);
    control.strings = program.strings.ptr;
    referenceSchedulerReset(&frames.scheduler, control.tick_rate);
    frames.scheduler.event_definitions = program.definitions;
    // RFC-0084: only a program that holds a `cell_live` tracks, detaches and propagates.
    live_reference.reset(&frames.live, live(program), program.definitions, program.fields, program.tuple_elements);
    frames.live.reacts = reacts(program);
    frames.guard_floor = 0;
    frames.links_ready = false;
    var catchers: [types.limits.control_depth]u32 = undefined;
    var depth: usize = 0;
    var remaining: u64 = work_budget;
    var aggregate_count: usize = 0;
    var pool = run_strings.Pool.init(program.strings, program.string_tail);
    control.string_used = &pool.used;
    if (state != null) control.programCells(program.source_cells.len);
    defer control.string_used = null;
    // Kept for the whole evaluation, calls included.
    var key_work: keys.Work = .{};
    defer key_work.release();
    var pc: u32 = 0;
    while (pc < program.nodes.len) {
        const node = program.nodes[pc];
        const cost: u32 = 1 + if (node.kind == .aggregate) node.kind.aggregate.end - node.kind.aggregate.start else if (node.kind == .object_new) node.kind.object_new.arguments.end - node.kind.object_new.arguments.start else if (node.kind == .ref_new) @as(u32, 1) else if (node.kind == .bind) bind: {
            const b = node.kind.bind;
            const original = values[b.callable].callable;
            break :bind original.captures.end - original.captures.start + b.arguments.end - b.arguments.start;
        } else @as(u32, 0);
        if (cost > remaining) return failure(node.span, .work_limit);
        remaining -= cost;
        var next = pc + 1;
        var value: types.Value = undefined;
        switch (node.kind) {
            .call, .iterate, .invoke, .iterate_value, .loop => value = switch (referenceCall(program, node.invocationWith(null, values).?, node.kind == .invoke, pc, values, aggregate_values, &aggregate_count, &pool, &key_work, frames, control, state, &remaining)) {
                .ok => |result| result,
                .failed => |diagnostic| return .{ .failed = diagnostic },
                .language => {
                    std.debug.assert(depth > 0);
                    depth -= 1;
                    const begin = catchers[depth];
                    if (state) |storage| storage.abort() catch unreachable;
                    referenceRegionAbort(control, &frames.scheduler);
                    values[begin] = .{ .boolean = false };
                    pc = branch(program.nodes[begin]).alternative + 1;
                    continue;
                },
            },
            .native_call => |c| {
                // An effect outside every function leaves a step (`CallStep`): room for it is
                // found before the native runs, so that nothing is committed and then not recorded.
                const effect = program.natives[c.native].effect != .none;
                if (effect and control.call_count >= control.call_limit and !control.makeRoom(aggregate_values[0..aggregate_count])) return failure(node.span, .call_trace_limit);
                value = switch (referenceNative(c, node.value_type, values[0..pc], program, aggregate_values, &aggregate_count, &pool, &key_work, &control.effects, frames.scheduler.now, &remaining)) {
                    .ok => |result| result,
                    .failed => |code| return failure(node.span, code),
                };
                if (effect) {
                    control.calls[control.call_count] = .{ .function = 0, .pc = pc, .value = value, .kind = .root };
                    control.call_count += 1;
                    // A replay reads the text of an action from the pool: it is told at once,
                    // while the pool still holds what the native was given.
                    if (control.trace_sink != null) control.foldCalls(aggregate_values[0..aggregate_count]);
                }
            },
            .if_begin => |b| {
                value = values[b.condition];
                if (!value.boolean) next = b.alternative + 1;
            },
            .attempt_begin => {
                if (state) |storage| storage.begin() catch |err| return failure(node.span, source_state.diagnostic(err));
                control.effects.begin();
                value = .{ .boolean = true };
                std.debug.assert(depth < catchers.len);
                catchers[depth] = pc;
                depth += 1;
            },
            .otherwise => |begin| {
                if (program.nodes[begin].kind == .attempt_begin) {
                    std.debug.assert(depth != 0 and catchers[depth - 1] == begin);
                    depth -= 1;
                    if (state) |storage| storage.commit() catch unreachable;
                    // Guest state is committed by now; a sink that fails here ends the run.
                    // The root drains what it commits after the node (below).
                    _ = referenceRegionCommit(control, &frames.scheduler) catch return failure(node.span, .effect_commit_failed);
                }
                value = .{ .boolean = true };
                next = branch(program.nodes[begin]).end;
            },
            .cell_read => |c| value = state.?.read(c) catch |err| return failure(node.span, source_state.diagnostic(err)),
            .cell_init, .cell_write => |c| {
                value = values[c.value];
                // RFC-0084, L2: a program write detaches the cell's record and propagates.
                if (node.kind == .cell_write and frames.live.on) live_reference.detach(&frames.live, state.?, c.cell, &remaining) catch |err| return failure(node.span, liveCode(err));
                state.?.write(c.cell, value, node.kind == .cell_init) catch |err| return failure(node.span, source_state.diagnostic(err));
                if (node.kind == .cell_write and frames.live.on) {
                    const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                    if (referencePropagate(&run, c.cell)) |diagnostic| return .{ .failed = diagnostic };
                }
            },
            .object_new => |c| value = referenceObject(state.?, node.value_type, program.call_arguments[c.arguments.start..c.arguments.end], values) catch |err| return failure(node.span, source_state.diagnostic(err)),
            // RFC-0085, I1: a variable cell is an instance with one cell, built, read and written
            // as a `var` field is.
            .ref_new => |operand| value = referenceRef(state.?, node.value_type, values[operand]) catch |err| return failure(node.span, source_state.diagnostic(err)),
            .ref_get => |operand| value = state.?.read(values[operand].object.id + catalogue.ref_value) catch |err| return failure(node.span, source_state.diagnostic(err)),
            .ref_set => |r| {
                value = values[r.value];
                const cell = values[r.ref].object.id + catalogue.ref_value;
                if (frames.live.on) live_reference.detach(&frames.live, state.?, cell, &remaining) catch |err| return failure(node.span, liveCode(err));
                state.?.write(cell, value, false) catch |err| return failure(node.span, source_state.diagnostic(err));
                if (frames.live.on) {
                    const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                    if (referencePropagate(&run, cell)) |diagnostic| return .{ .failed = diagnostic };
                }
            },
            .object_get => |a| value = state.?.read(values[a.value].object.id + 1 + a.index) catch |err| return failure(node.span, source_state.diagnostic(err)),
            .object_set => |c| {
                value = values[c.value];
                // RFC-0084, L2: a program write of a field detaches its record (P4.2).
                if (frames.live.on) live_reference.detach(&frames.live, state.?, values[c.object].object.id + 1 + c.index, &remaining) catch |err| return failure(node.span, liveCode(err));
                state.?.write(values[c.object].object.id + 1 + c.index, value, false) catch |err| return failure(node.span, source_state.diagnostic(err));
                if (frames.live.on) {
                    const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                    if (referencePropagate(&run, values[c.object].object.id + 1 + c.index)) |diagnostic| return .{ .failed = diagnostic };
                }
            },
            // RFC-0084: the establishing write of a module cell, and its propagation.
            .cell_live => |c| {
                const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                value = switch (referenceEstablish(&run, moduleTarget(program, c), values[c.guard].callable, pc)) {
                    .ok => |established| established,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                };
            },
            // RFC-0084, P4.2: the same for a field of an instance.
            .object_live => |c| {
                const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                value = switch (referenceEstablish(&run, fieldTarget(values[c.object].object, c, node.value_type), values[c.guard].callable, pc)) {
                    .ok => |established| established,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                };
            },
            .merge => |m| value = retyped(values[if (values[m.begin].boolean) m.left else m.right], node.value_type),
            .err => return failure(node.span, .runtime_error),
            .exit => unreachable, // Admission keeps exits inside function bodies.
            .arm_exit, .arm_exited, .arm_exit_value => unreachable,
            // RFC-0084, P4.4: a reaction at the root starts at once outside every region, and its
            // body, if its guard holds, runs on the empty stack.
            .reaction => |r| {
                const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                const slot = switch (referenceReaction(&run, node.value_type, r, values[r.guard], values[r.body], pc)) {
                    .ok => |slot| slot,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                };
                value = frames.scheduler.tasks[slot].handle;
                if (control.effects.depth != 0) {
                    if (!referenceHold(&frames.scheduler, slot, control.effects.depth)) return failure(node.span, .scheduler_action_limit);
                } else switch (referenceReactionStart(&run, slot, .node)) {
                    .fired => if (referenceAtRoot(&run, node.span)) |diagnostic| return .{ .failed = diagnostic },
                    .waits => {},
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                }
            },
            // RFC-0084, P4.5: a batch of the root calls its body on the empty stack with the batch
            // count raised; its return is a delivery point (below).
            .batch => |operand| {
                const body = values[operand].callable;
                frames.live.batch += 1;
                value = switch (referenceCall(program, .{ .call = .{ .function = body.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures } }, true, pc, values, aggregate_values, &aggregate_count, &pool, &key_work, frames, control, state, &remaining)) {
                    .ok => |result| result,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                    // A body cannot fail: admission keeps `decides` out of its type.
                    .language => unreachable,
                };
                std.debug.assert(frames.live.batch != 0);
                frames.live.batch -= 1;
            },
            .spawn => |operand| {
                // A spawn at the root (RFC-0082): outside every region the task runs at once,
                // on the empty active stack, until it first waits or settles; inside one its
                // start is held by the region.
                const slot = switch (referenceSpawn(program, node.value_type, values[operand], pc, &frames.scheduler, state.?, &remaining)) {
                    .ok => |slot| slot,
                    .failed => |code| return failure(node.span, code),
                };
                value = frames.scheduler.tasks[slot].handle;
                if (control.effects.depth != 0) {
                    if (!referenceHold(&frames.scheduler, slot, control.effects.depth)) return failure(node.span, .scheduler_action_limit);
                } else if (referenceSlice(program, slot, false, pc, values, aggregate_values, &aggregate_count, &pool, &key_work, frames, control, state, &remaining)) |diagnostic| return .{ .failed = diagnostic };
            },
            // Root code holds no site (admission rule 1), so no check either.
            .sleep, .canceling, .cancel_exit, .task_await, .event_await, .structured => unreachable,
            .branch => unreachable,
            .task_cancel => unreachable,
            .await_guard => unreachable,
            // P3.7: the clock, which stands still while the root runs.
            .elapsed_time => value = .{ .floating = referenceElapsed(&frames.scheduler) },
            // RFC-0086, P2.3: a handle of the run's grants, or `option{}`.
            .grant => |g| value = if (g.kind == .session) referenceSession(node.value_type) else switch (referenceGrant(control.effects.inputs.grants, g, values[g.name].string, node.value_type, program, aggregate_values, &aggregate_count, @min(aggregate_values.len, types.limits.aggregate_elements) - aggregate_count, &remaining)) {
                .ok => |made| made,
                .failed => |code| return failure(node.span, code),
            },
            // RFC-0087, P5.4 (W4): a keyed cell starts as the empty map of its type.
            .weak_init => |c| {
                if (program.source_cells[c].keyed == .persistent) {
                    // RFC-0087, P5.5 (S4): a persistent cell starts as its loaded entries. Like a
                    // JSON node at the root it leaves a step, so that a replay is told at once,
                    // while the pool still holds the strings the decodes built.
                    if (control.call_count >= control.call_limit and !control.makeRoom(aggregate_values[0..aggregate_count])) return failure(node.span, .call_trace_limit);
                    value = switch (referenceLoads(program, c, node, aggregate_values, &aggregate_count, &pool, &key_work, frames, &control.effects, state, &remaining)) {
                        .ok => |made| made,
                        .failed => |code| return failure(node.span, code),
                    };
                    control.calls[control.call_count] = .{ .function = 0, .pc = pc, .value = value, .kind = .root };
                    control.call_count += 1;
                    if (control.trace_sink != null) control.foldCalls(aggregate_values[0..aggregate_count]);
                } else value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = @intCast(aggregate_count), .end = @intCast(aggregate_count) } } };
                state.?.write(c, value, true) catch |err| return failure(node.span, source_state.diagnostic(err));
            },
            .weak_get => |g| {
                const map = state.?.read(g.cell) catch |err| return failure(node.span, source_state.diagnostic(err));
                value = referenceWeakGet(map, values[g.key], node.value_type, aggregate_values, &key_work, &remaining) catch |err| return failure(node.span, keyedCode(err));
            },
            // W6: a program write of the cell, as `cell_write` is.
            .weak_set => |c| {
                const map = state.?.read(c.cell) catch |err| return failure(node.span, source_state.diagnostic(err));
                const written = referenceWeakSet(map, values[c.key], values[c.value], aggregate_values, &aggregate_count, &key_work, &remaining) catch |err| return failure(node.span, keyedCode(err));
                value = values[c.value];
                if (frames.live.on) live_reference.detach(&frames.live, state.?, c.cell, &remaining) catch |err| return failure(node.span, liveCode(err));
                state.?.write(c.cell, written, false) catch |err| return failure(node.span, source_state.diagnostic(err));
                // RFC-0087, P5.5 (S5): a persistent cell's write is also an action on the store channel.
                if (referenceStoreAction(program, c, values[c.key], values[c.value], aggregate_values, aggregate_count, &pool, frames, &control.effects, state, &remaining)) |code| return failure(node.span, code);
                if (frames.live.on) {
                    const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                    if (referencePropagate(&run, c.cell)) |diagnostic| return .{ .failed = diagnostic };
                }
            },
            // RFC-0087, P5.3: `ToJson` and `FromJson`. Outside every function each leaves a step,
            // as an effect native does, and a replay is told at once, while the pool still holds
            // the text and the strings of what it built.
            .json_encode, .json_decode => |operand| {
                if (control.call_count >= control.call_limit and !control.makeRoom(aggregate_values[0..aggregate_count])) return failure(node.span, .call_trace_limit);
                value = switch (referenceJson(program, node, program.nodes[operand].value_type, values[operand], aggregate_values, &aggregate_count, &pool, &key_work, frames, state, &remaining)) {
                    .ok => |made| made,
                    .failed => |code| return failure(node.span, code),
                };
                control.calls[control.call_count] = .{ .function = 0, .pc = pc, .value = value, .kind = .root };
                control.call_count += 1;
                if (control.trace_sink != null) control.foldCalls(aggregate_values[0..aggregate_count]);
            },
            // P3.2: an event is an instance; a signal at depth 0 wakes its waiters at once, and
            // inside a region it is held there, as a start is.
            .event_new => value = referenceEvent(program, state.?, node.value_type) catch |err| return failure(node.span, source_state.diagnostic(err)),
            .event_signal => |signal| {
                value = referenceUnit(program, node);
                if (control.effects.depth != 0) {
                    if (!referenceHoldSignal(&frames.scheduler, values[signal.event], values[signal.value], control.effects.depth)) return failure(node.span, .scheduler_action_limit);
                } else if (referenceSignal(&frames.scheduler, state.?, values[signal.event].object, values[signal.value], &remaining)) |code| return failure(node.span, code);
            },
            // P3.9: subscriptions at the root, and the callbacks of a `Signal` there, each a call
            // of the root (C109, C110).
            .event_subscribe => |c| value = referenceSubscribe(state.?, values[c.event].object, values[c.callback], node.value_type) catch |err| return failure(node.span, source_state.diagnostic(err)),
            .subscription_cancel => |operand| {
                referenceUnsubscribe(state.?, values[operand].object) catch |err| return failure(node.span, source_state.diagnostic(err));
                value = referenceUnit(program, node);
            },
            .event_notify => |n| {
                const event = values[n.callable].object;
                const limit = (state.?.read(event.id + catalogue.subscription_count) catch unreachable).integer;
                var from = state.?.read(event.id + catalogue.subscription_first) catch unreachable;
                while (true) {
                    const subscription = switch (referenceNextSubscription(state.?, from, limit, &remaining)) {
                        .found => |found| found,
                        .none => break,
                        .failed => |code| return failure(node.span, code),
                    };
                    const callback = (state.?.read(subscription.id + catalogue.cancelable_callback) catch unreachable).callable;
                    switch (referenceCall(program, .{ .call = .{ .function = callback.function, .arguments = n.arguments, .captures = callback.captures } }, true, pc, values, aggregate_values, &aggregate_count, &pool, &key_work, frames, control, state, &remaining)) {
                        .ok => {},
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                        .language => unreachable, // A callback cannot fail (C108).
                    }
                    from = state.?.read(subscription.id + catalogue.cancelable_after) catch unreachable;
                }
                value = referenceUnit(program, node);
            },
            .demand, .fail => |operand| {
                if (node.kind == .fail or !values[operand].boolean) {
                    std.debug.assert(depth != 0);
                    depth -= 1;
                    const begin = catchers[depth];
                    if (state) |storage| storage.abort() catch unreachable;
                    referenceRegionAbort(control, &frames.scheduler);
                    values[begin] = .{ .boolean = false };
                    control.record(.{ .instruction = pc, .span = node.span, .code = if (node.kind == .fail) .language_failure else .requirement_failed, .reason = if (node.kind == .fail) values[operand].string else null });
                    pc = branch(program.nodes[begin]).alternative + 1;
                    continue;
                }
                value = .{ .boolean = true };
            },
            .bind => |b| {
                const original = values[b.callable].callable;
                const old = original.captures.end - original.captures.start;
                const count = old + b.arguments.end - b.arguments.start;
                if (count > @min(aggregate_values.len, types.limits.aggregate_elements) - aggregate_count) return failure(node.span, .aggregate_limit);
                const span: types.Span = .{ .start = @intCast(aggregate_count), .end = @intCast(aggregate_count + count) };
                std.debug.assert(original.captures.end <= aggregate_count and count <= types.limits.parameters);
                @memcpy(aggregate_values[span.start .. span.start + old], aggregate_values[original.captures.start..original.captures.end]);
                for (program.call_arguments[b.arguments.start..b.arguments.end], aggregate_values[span.start + old .. span.end]) |operand, *out| out.* = values[operand];
                aggregate_count = span.end;
                value = .{ .callable = .{ .value_type = node.value_type, .function = original.function, .captures = span } };
            },
            .aggregate => |range| {
                if (range.end - range.start > @min(aggregate_values.len, types.limits.aggregate_elements) - aggregate_count) return failure(node.span, .aggregate_limit);
                const physical: types.Span = .{ .start = @intCast(aggregate_count), .end = @intCast(aggregate_count + range.end - range.start) };
                for (program.members[range.start..range.end], aggregate_values[physical.start..physical.end]) |operand, *destination| destination.* = values[operand];
                if (catalogue.entryShape(node.value_type, program.definitions) != null) keys.unique(&key_work, aggregate_values, aggregate_values[physical.start..physical.end], &remaining) catch |err| return failure(node.span, keyCode(err));
                aggregate_count = physical.end;
                value = .{ .aggregate = .{ .value_type = node.value_type, .elements = physical } };
            },
            else => value = evaluateNode(node, pc, values[0..pc], program, aggregate_values, &aggregate_count, &pool, &key_work, &remaining, array_concat.contextOf(0, false, 0, frames.scheduler.switches != 0, frames.scheduler.frames_live != 0)) catch |err| return failure(node.span, switch (err) {
                error.InvalidIr => .invalid_ir,
                error.Overflow => .arithmetic_overflow,
                error.DivisionByZero => .division_by_zero,
                error.IndexRange => .index_out_of_range,
                error.AggregateLimit => .aggregate_limit,
                error.NativeFailed => .native_failed,
                error.StringLimit => .string_limit,
                error.InvalidNative => .invalid_native,
                error.WorkLimit => .work_limit,
                error.DuplicateKey => .duplicate_map_key,
                error.ScratchUnavailable => .scratch_unavailable,
            }),
        }
        values[pc] = value;
        control.activity[pc] = true;
        // Starts the root committed take their turns now, each until it first waits or settles,
        // and the signals it committed are carried out between them, in order.
        while (referenceDraining(&frames.scheduler)) {
            const slot = switch (referenceNextStart(&frames.scheduler, state, pc, &remaining)) {
                .start => |slot| slot,
                .none => break,
                .failed => |code| return failure(node.span, code),
            };
            // RFC-0084, P4.4: a reaction's start is its first evaluation, and its firing.
            if (reactionTask(&frames.scheduler.tasks[slot])) {
                const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
                switch (referenceReactionStart(&run, slot, .start)) {
                    .fired => if (referenceAtRoot(&run, node.span)) |diagnostic| return .{ .failed = diagnostic },
                    .waits => {},
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                }
                continue;
            }
            if (referenceSlice(program, slot, false, pc, values, aggregate_values, &aggregate_count, &pool, &key_work, frames, control, state, &remaining)) |diagnostic| return .{ .failed = diagnostic };
        }
        // RFC-0084, P4.4: a write, an establishing write or a commit to depth 0 of the root
        // delivers what is pending, after the drain it began.
        if (frames.live.on and (node.kind == .cell_write or node.kind == .weak_set or node.kind == .object_set or node.kind == .ref_set or node.kind == .cell_live or node.kind == .object_live or node.kind == .batch or (node.kind == .otherwise and program.nodes[node.kind.otherwise].kind == .attempt_begin))) {
            const run: LiveRun = .{ .p = program, .roots = values, .members = aggregate_values, .member_count = &aggregate_count, .pool = &pool, .key_work = &key_work, .frames = frames, .control = control, .source = state.?, .remaining = &remaining, .root_pc = pc, .span = node.span, .return_to = 0 };
            switch (referenceDeliveryPoint(&run)) {
                .fired => if (referenceAtRoot(&run, node.span)) |diagnostic| return .{ .failed = diagnostic },
                .done => {},
                .failed => |diagnostic| return .{ .failed = diagnostic },
            }
        }
        pc = next;
    }
    std.debug.assert(depth == 0 and aggregate_count <= aggregate_values.len);
    std.debug.assert(control.effects.depth == 0);
    // RFC-0082, P3.5: nothing the root holds now ever moves.
    control.rootEnded(referenceUsage(aggregate_count, &pool, state));
    // The root has finished (S1); the tasks run to quiescence.
    if (referenceSchedule(program, values, aggregate_values, &aggregate_count, &pool, &key_work, frames, control, state, &remaining)) |diagnostic| return .{ .failed = diagnostic };
    std.debug.assert(frames.scheduler.action_count == frames.scheduler.action_head);
    if (state) |storage| storage.commit() catch unreachable;
    complete = true;
    if (control.trace != .full) control.foldCalls(aggregate_values[0..aggregate_count]);
    var extended = program;
    extended.strings = pool.view(program.strings);
    return .{ .ok = .{ .program = extended, .values = values[0..program.nodes.len], .aggregate_values = aggregate_values[0..aggregate_count], .activity = if (types.sparse(program)) control.activity[0..program.nodes.len] else &.{}, .failures = if (types.sparse(program) or types.failureCalls(program)) control.traces[0..control.trace_count] else &.{}, .failure_count = if (types.sparse(program) or types.failureCalls(program)) control.failure_count else 0, .call_steps = control.calls[0..control.call_count], .trace = control.trace, .witness = if (control.trace == .digest) control.witness else .{}, .reclaim_floor = control.reclaim_floor, .reclaims = control.reclaims, .object_cells = if (state) |storage| storage.cells[program.source_cells.len..storage.cell_count] else &.{}, .effects = control.effects.record(), .scheduler = referenceRecord(&frames.scheduler), .cells = if (state != null and (spawns(program) or frames.live.on or types.keyedCells(program))) state.?.cells[0..program.source_cells.len] else &.{}, .live = frames.live.record } };
}

/// A native call by a machine that has a world: an effect native is lent the port of the run's
/// effect log, a pure one nothing. The result is checked as `evaluateNode` checks it. `tick` is
/// the scheduler's clock, at which an input is read (RFC-0086).
fn referenceNative(c: types.NativeCall, result: types.Type, values: []const types.Value, program: types.Program, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, world: *effects.Log, tick: u64, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
    var arguments: [native.max_parameters]types.Value = undefined;
    for (c.args[0..c.count], 0..) |operand, i| arguments[i] = values[operand];
    return switch (native.invokeWith(program.natives[c.native], result, arguments[0..c.count], members[0..@min(members.len, types.limits.aggregate_elements)], member_count, pool, key_work, remaining, world.port(tick))) {
        .ok => |value| .{ .ok = value },
        .fault => |fault| .{ .failed = native.faultCode(fault) },
    };
}

/// RFC-0085, I1: creates a variable cell of type `ref_type` holding `initial`.
fn referenceRef(state: *source_state.ReferenceState, ref_type: types.Type, initial: types.Value) source_state.Error!types.Value {
    const cells = [catalogue.ref_cells]types.Value{ .{ .integer = @backingInt(ref_type) }, initial };
    return .{ .object = .{ .value_type = ref_type, .id = try state.allocate(&cells) } };
}

/// Creates an instance from the operand registers named by `arguments`.
fn referenceObject(state: *source_state.ReferenceState, class: types.Type, arguments: []const u32, registers: []const types.Value) source_state.Error!types.Value {
    std.debug.assert(arguments.len <= types.limits.record_fields);
    var cells: [types.limits.record_fields + 1]types.Value = undefined;
    cells[0] = .{ .integer = @backingInt(class) };
    for (arguments, cells[1..][0..arguments.len]) |operand, *out| out.* = registers[operand];
    return .{ .object = .{ .value_type = class, .id = try state.allocate(cells[0 .. arguments.len + 1]) } };
}

/// RFC-0085, admission rule 8: an entry flagged `nested` is anonymous, not public, exits no
/// arm, holds no block clauses, and its name is an identifier the source follows with `(`, as a
/// nested function's header does.
fn nestedEntry(p: types.Program, f: types.RuntimeFunction) bool {
    if (!f.anonymous or f.is_public or f.exits != null or f.clauses_of != null) return false;
    return f.name.end < p.source.len and p.source[f.name.end] == '(';
}

fn sourceName(name: []const u8) bool {
    if (name.len == 0 or name.len > types.limits.identifier_bytes or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}
fn cellVisible(program: types.Program, cell: u32, span: types.Span) bool {
    return runtimeVisible(program, program.source_cells[cell].name, program.source_cells[cell].is_public, span);
}

/// The privacy of a program whose files declare modules (RFC-0074), or null for one without.
fn nestedPrivacy(program: types.Program) error{OutOfMemory}!?catalogue.Privacy {
    if (program.nested.len == 0) return null;
    return catalogue.Privacy.create(program.definitions, program.tuple_elements, program.modules, program.nested) orelse error.OutOfMemory;
}

/// Whether the declaration at `name` may have `value_type` in its signature: a public one
/// exposes only types that are nameable wherever it is.
fn signatureAdmitted(privacy: ?catalogue.Privacy, exposed: []const bool, value_type: types.Type, name: types.Span, is_public: bool) bool {
    if (privacy) |held| return held.admits(value_type, name, is_public);
    return !is_public or catalogue.exportable(value_type, exposed);
}
fn validSourceCells(program: types.Program, privacy: ?catalogue.Privacy) bool {
    if (program.source_cells.len > types.limits.source_cells) return false;
    // Every cell opcode is still checked by the whole-program typed pass.
    // Empty metadata cannot hide an operation or a forged operation count.
    if (program.source_cells.len == 0) return true;
    var exported: [types.limits.user_types]bool = undefined;
    if (program.modules.len != 0) catalogue.exportableTypes(program.definitions, program.fields, program.tuple_elements, &exported);
    var last_write: ?usize = null;
    for (program.nodes, 0..) |node, index| if (node.kind == .cell_init or node.kind == .cell_write or node.kind == .cell_live) {
        last_write = index;
    };
    // Cells are found by module and name: comparing every cell with every other cell and with
    // every binding costs their product on each run.
    var cells = name_index.Index.create(program.source_cells.len) orelse return false;
    defer cells.destroy();
    const root: u32 = if (program.modules.len == 0) 0 else @intCast(program.modules.len - 1);
    var root_cells = false;
    for (program.source_cells, 0..) |cell, id| {
        if (!validSpan(cell.name, program.source.len) or !sourceName(cell.name.text(program.source)) or !catalogue.validType(cell.value_type, program.definitions) or cell.initial >= program.nodes.len) return false;
        // RFC-0087, P5.4 (admission rule 4): what a cell is follows from its type.
        if (cell.keyed != catalogue.keyedKind(cell.value_type, program.definitions)) return false;
        const owner = if (program.modules.len == 0) null else modules.home(cell.name, program.modules, program.nested) orelse return false;
        if (program.modules.len != 0 and !signatureAdmitted(privacy, exported[0..program.definitions.len], cell.value_type, cell.name, cell.is_public)) return false;
        const initial = program.nodes[cell.initial];
        // A cell is declared by its `cell_init`, or by a `cell_live` that initialises it, which
        // a live-only cell must be (RFC-0084).
        const declared = switch (initial.kind) {
            .cell_init => |c| c.cell == id and !cell.live_only,
            .cell_live => |c| c.cell == id and c.initialize,
            // RFC-0087, P5.4: and a keyed cell by its `weak_init`.
            .weak_init => |c| c == id and cell.keyed != .none and !cell.live_only,
            else => false,
        };
        if (!declared or initial.value_type != cell.value_type or !std.meta.eql(initial.span, cell.name)) return false;
        var probe = cells.probe(name_index.hashName(owner orelse 0, cell.name.text(program.source)));
        while (probe.next()) |earlier_id| {
            const earlier = program.source_cells[earlier_id];
            const same_owner = program.modules.len == 0 or modules.home(earlier.name, program.modules, program.nested) == owner;
            if (same_owner and std.mem.eql(u8, earlier.name.text(program.source), cell.name.text(program.source))) return false;
        }
        probe.claim(@intCast(id));
        if (program.modules.len == 0 or owner.? == root) root_cells = true;
    }
    if (!keyedNamesValid(program)) return false;
    // RFC-0087, P5.5 (admission rule 4): a persistent cell saves its entries, so its value type is persistable.
    if (!(persistable.persistentCellsValid(program.definitions, program.tuple_elements, program.source_cells) catch false)) return false;
    // Only the root module has bindings. Without a cell there, no binding can stand for one.
    if (!root_cells) return true;
    for (program.bindings) |binding| {
        if (!validSpan(binding.name, program.source.len)) return false;
        var probe = cells.probe(name_index.hashName(root, binding.name.text(program.source)));
        while (probe.next()) |id| {
            const cell = program.source_cells[id];
            if (program.modules.len != 0 and modules.home(cell.name, program.modules, program.nested).? != root) continue;
            if (!std.mem.eql(u8, binding.name.text(program.source), cell.name.text(program.source))) continue;
            // RFC-0087, P5.4 (W8): a keyed cell is never read whole; its binding is its
            // declaration, and a report shows its final value.
            if (cell.keyed != .none) {
                if (!std.meta.eql(binding.name, cell.name) or binding.is_public != cell.is_public or binding.value_type != cell.value_type or binding.node != cell.initial) return false;
                continue;
            }
            if (!std.meta.eql(binding.name, cell.name) or binding.is_public != cell.is_public or binding.value_type != cell.value_type or binding.node >= program.nodes.len or binding.node <= last_write.?) return false;
            const read = program.nodes[binding.node];
            if (read.kind != .cell_read or read.kind.cell_read != id) return false;
        }
    }
    return true;
}

/// Whether the code at `at` may use the declaration at `name`. A declaration is in reach of its
/// own module and of the modules nested in it. A public one is also in reach wherever its
/// module can be named: inside the scope that declares that module, further out while each
/// module on the way is public itself, and from another file that imports the file (RFC-0074).
fn runtimeVisible(p: types.Program, name: types.Span, public: bool, at: types.Span) bool {
    if (p.modules.len == 0) return true;
    const owner = modules.home(name, p.modules, p.nested) orelse return false;
    const caller = modules.home(at, p.modules, p.nested) orelse return false;
    if (modules.inside(caller, owner, p.modules, p.nested)) return true;
    if (!public) return false;
    var module = owner;
    for (0..types.limits.module_depth + 2) |_| {
        const around = modules.enclosing(module, p.modules, p.nested) orelse {
            // A file is named through an import of the file the code is in.
            const imports = p.modules[modules.owner(at, p.modules).?].imports;
            for (p.imports[imports.start..imports.end]) |edge| if (edge.target == module) return true;
            return false;
        };
        if (modules.inside(caller, around, p.modules, p.nested)) return true;
        if (!p.nested[module - p.modules.len].is_public) return false;
        module = around;
    }
    return false;
}
/// Functions of one name are overloads when their parameter types differ.
fn runtimeSameParameters(a: types.RuntimeFunction, b: types.RuntimeFunction) bool {
    return a.parameter_count == b.parameter_count and std.mem.eql(types.Type, a.parameters[0..a.parameter_count], b.parameters[0..b.parameter_count]);
}

fn runtimeSameName(p: types.Program, a: types.Span, b: types.Span) bool {
    return (p.modules.len == 0 or modules.home(a, p.modules, p.nested) == modules.home(b, p.modules, p.nested)) and std.mem.eql(u8, a.text(p.source), b.text(p.source));
}

/// Equal for every two names that `runtimeSameName` holds equal, including names outside
/// every module, which that predicate does not tell apart.
fn runtimeNameHash(p: types.Program, name: types.Span) u64 {
    const owner: u32 = if (p.modules.len == 0) 0 else modules.home(name, p.modules, p.nested) orelse name_index.none;
    return name_index.hashName(owner, name.text(p.source));
}

/// The variable index numbers the cells first and the captured bindings after them.
fn runtimeVariableName(p: types.Program, item: u32) types.Span {
    return if (item < p.source_cells.len) p.source_cells[item].name else p.globals[item - p.source_cells.len].name;
}

/// One per function. The first function of a name leads it: its `plain` and `method` head the
/// lists of the functions of that name, linked through `next`. Functions named by the dispatch
/// table are listed apart because they are never compared with each other, and a method name
/// is shared by every class that implements it.
const RuntimeNamesake = struct { next: u32, plain: u32, method: u32 };

/// Whether two functions can collide at all: anonymous functions are the same one when they
/// are written at the same place, named functions when a module declares the name twice.
fn runtimeNamesakes(p: types.Program, a: *const types.RuntimeFunction, b: *const types.RuntimeFunction) bool {
    if (a.anonymous != b.anonymous) return false;
    return if (a.anonymous) std.meta.eql(a.name, b.name) else runtimeSameName(p, a.name, b.name);
}

/// Two functions that may not both be declared. Overloads differ in their parameter types, and
/// the specializations of one generic source differ in their type argument.
fn runtimeConflict(p: types.Program, f: *const types.RuntimeFunction, old: *const types.RuntimeFunction) bool {
    if (f.anonymous and old.anonymous) {
        if (std.meta.eql(f.name, old.name) and (f.specialization == null or old.specialization == null or f.specialization == old.specialization or !std.meta.eql(f.generic_source, old.generic_source))) return true;
    } else if (!f.anonymous and !old.anonymous and runtimeSameName(p, f.name, old.name) and (runtimeSameParameters(f.*, old.*) or f.specialization != null or old.specialization != null)) {
        // A generic method's specialization is a member of its class (RFC-0081), reached only
        // through a value of it: a function of the module, generic or not, may share its name.
        if (runtimeMemberSpecialization(p, f.*) != runtimeMemberSpecialization(p, old.*)) return false;
        // Generic methods of one name declared by different classes (RFC-0081) are as distinct
        // as their classes' methods: their specializations name different receivers.
        if (f.specialization != null and old.specialization != null and f.specialization != old.specialization) {
            const mine = specializedReceiver(p, f.*);
            const theirs = specializedReceiver(p, old.*);
            if (mine != null and theirs != null and mine.? != theirs.?) return false;
        }
        if (f.specialization == null or old.specialization == null or f.specialization == old.specialization or !std.meta.eql(f.generic_source, old.generic_source)) return true;
    }
    return false;
}

/// Whether `inner` is the span of a function of the template that `outer` identifies. The span
/// of an anonymous function whose name lies in a module's library block, such as the body of a
/// `For`, is widened to reach it; one the author wrote inside that body keeps the template's own
/// span. Templates start apart, so the start tells the template, and the inner span lies within
/// the outer one (`pf2`).
fn runtimeSameTemplate(outer: types.Span, inner: types.Span) bool {
    return outer.start == inner.start and inner.end <= outer.end;
}

/// A method, which the dispatch table names, and a function called by name conflict as two
/// functions called by name do, unless one of them is a specialization: that is reached by its
/// template and type arguments and the method only through its class, so a method may share a
/// generic function's name, or a generic method's of another class (`pf2`).
fn runtimeMethodConflict(p: types.Program, f: *const types.RuntimeFunction, old: *const types.RuntimeFunction) bool {
    if (f.specialization != null or old.specialization != null) return false;
    return runtimeConflict(p, f, old);
}

/// Whether the named specialization `f` is a generic method's (RFC-0081): its arguments list
/// the receiver's class after one argument for each parameter its template's header declares.
/// `validGenericFunction` admitted the header, so the parameters are counted by its commas
/// outside the brackets and parentheses of bounds, and outside comments.
fn runtimeMemberSpecialization(p: types.Program, f: types.RuntimeFunction) bool {
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

/// The receiver a named specialization lists last when it is a generic method's (RFC-0081):
/// a class that is its first parameter. The header admits the list (`validGenericFunction`).
fn specializedReceiver(p: types.Program, f: types.RuntimeFunction) ?types.Type {
    const shape = catalogue.definition(f.specialization orelse return null, p.definitions) orelse return null;
    if (shape != .tuple or shape.tuple.start >= shape.tuple.end or shape.tuple.end > p.tuple_elements.len or f.parameter_count == 0) return null;
    const last = p.tuple_elements[shape.tuple.end - 1];
    return if (last == f.parameters[0] and isClass(p, last)) last else null;
}

/// Compares function `id` with the earlier functions it could collide with, then lists it.
/// Only functions of one name are visited, and two methods never are, so the cost follows the
/// overloads and specializations a program declares, not the square of its function count.
fn runtimeDistinct(p: types.Program, id: u32, method: bool, names: *name_index.Index, namesakes: []RuntimeNamesake) bool {
    const none = name_index.none;
    const f = &p.functions[id];
    var probe = names.probe(if (f.anonymous) name_index.hashSpan(f.name.start, f.name.end) else runtimeNameHash(p, f.name));
    const leader = while (probe.next()) |other| {
        if (runtimeNamesakes(p, f, &p.functions[other])) break other;
    } else {
        probe.claim(id);
        namesakes[id] = .{ .next = none, .plain = if (method) none else id, .method = if (method) id else none };
        return true;
    };
    var old = namesakes[leader].plain;
    while (old != none) : (old = namesakes[old].next) if (if (method) runtimeMethodConflict(p, f, &p.functions[old]) else runtimeConflict(p, f, &p.functions[old])) return false;
    old = if (method) none else namesakes[leader].method;
    while (old != none) : (old = namesakes[old].next) if (runtimeMethodConflict(p, f, &p.functions[old])) return false;
    const head = if (method) &namesakes[leader].method else &namesakes[leader].plain;
    namesakes[id] = .{ .next = head.*, .plain = none, .method = none };
    head.* = id;
    return true;
}
fn validFunctions(p: types.Program, comparable: []const bool, privacy: ?catalogue.Privacy, json: persistable.JsonFacts) bool {
    if (p.functions.len > types.limits.functions or p.function_nodes.len > types.limits.template_nodes or p.function_members.len > types.limits.aggregate_elements or p.function_arguments.len > types.limits.call_arguments or p.call_arguments.len > types.limits.call_arguments or p.globals.len > types.limits.bindings) return false;
    var exported: [types.limits.user_types]bool = undefined;
    if (p.modules.len != 0) catalogue.exportableTypes(p.definitions, p.fields, p.tuple_elements, &exported);
    // Cells and captured bindings share one index by module and name, so a name is looked up
    // instead of being compared with every cell, binding and function of the program.
    var variables = name_index.Index.create(p.source_cells.len + p.globals.len) orelse return false;
    defer variables.destroy();
    for (p.source_cells, 0..) |cell, id| {
        // Cells were admitted before this, so nothing is compared here.
        var probe = variables.probe(runtimeNameHash(p, cell.name));
        while (probe.next()) |_| {}
        probe.claim(@intCast(id));
    }
    for (p.globals, 0..) |g, id| {
        if (!validSpan(g.name, p.source.len) or !sourceName(g.name.text(p.source)) or g.node >= p.nodes.len or p.nodes[g.node].value_type != g.value_type) return false;
        if (p.modules.len != 0 and (modules.owner(g.name, p.modules) == null or !signatureAdmitted(privacy, exported[0..p.definitions.len], g.value_type, g.name, g.is_public))) return false;
        var probe = variables.probe(runtimeNameHash(p, g.name));
        while (probe.next()) |old| if (runtimeSameName(p, g.name, runtimeVariableName(p, old))) return false;
        probe.claim(@intCast(p.source_cells.len + id));
    }
    var body_count: u32 = 0;
    var member_count: u32 = 0;
    var argument_count: u32 = 0;
    var availability: u32 = 0;
    var longest_body: usize = 0;
    for (p.functions) |f| {
        if (f.body.end >= f.body.start and f.body.end <= p.function_nodes.len) longest_body = @max(longest_body, f.body.end - f.body.start);
    }
    const nodes = scratch.alloc(types.Node, longest_body) orelse return false;
    defer scratch.free(nodes);
    const methods = catalogue.methodFunctions(p.dispatch);
    var names = name_index.Index.create(p.functions.len) orelse return false;
    defer names.destroy();
    const namesakes = scratch.alloc(RuntimeNamesake, p.functions.len) orelse return false;
    defer scratch.free(namesakes);
    for (p.functions, 0..) |f, id| {
        if (!validSpan(f.name, p.source.len) or !sourceName(f.name.text(p.source)) or !validSpan(f.body, p.function_nodes.len) or f.body.start != body_count or f.body.start == f.body.end or f.root >= f.body.end - f.body.start or f.parameter_count > types.limits.parameters or !catalogue.validType(f.value_type, p.definitions) or f.available_at < availability or f.available_at > p.nodes.len) return false;
        const anonymous_name = std.mem.eql(u8, f.name.text(p.source), "Fn");
        // The body of a `Spawn{...}` is anonymous too, named by its keyword (RFC-0082); a function
        // a program names `Spawn` is not.
        const spawn_body = f.anonymous and std.mem.eql(u8, f.name.text(p.source), "Spawn");
        // So is that of a `Branch{...}` (P3.4).
        const branch_body = f.anonymous and std.mem.eql(u8, f.name.text(p.source), "Branch");
        // A live guard is named by the word `live` it was written with (RFC-0084).
        const live_guard = f.anonymous and std.mem.eql(u8, f.name.text(p.source), "live");
        // RFC-0085, I3 (admission rule 8): a nested function is anonymous and named by the name
        // it was declared with; the flag admits that name and nothing else.
        const nested_entry = f.nested and nestedEntry(p, f);
        if (f.nested and !nested_entry) return false;
        if (!nested_entry and ((f.anonymous != anonymous_name and !spawn_body and !branch_body and !live_guard) or (f.anonymous and f.is_public))) return false;
        if (!validGenericFunction(p, f, comparable) or !clausesShaped(p, f)) return false;
        // RFC-0082, P3.6: an arm that may exit is anonymous and suspends, and its pending exits
        // have a type.
        if (f.exits) |exits| if (!f.anonymous or !f.detail.suspends or f.decides or f.clauses_of != null or !catalogue.validType(exits, p.definitions)) return false;
        if (p.modules.len != 0 and modules.owner(f.name, p.modules) == null) return false;
        if (p.modules.len != 0 and !signatureAdmitted(privacy, exported[0..p.definitions.len], f.value_type, f.name, f.is_public)) return false;
        for (f.parameters[0..f.parameter_count]) |t| if (!catalogue.validType(t, p.definitions) or (p.modules.len != 0 and !signatureAdmitted(privacy, exported[0..p.definitions.len], t, f.name, f.is_public))) return false;
        if (!runtimeDistinct(p, @intCast(id), methods.isSet(id), &names, namesakes)) return false;
        if (!f.anonymous) {
            var probe = variables.probe(runtimeNameHash(p, f.name));
            while (probe.next()) |old| if (runtimeSameName(p, f.name, runtimeVariableName(p, old))) return false;
        }
        var body_p = p;
        body_p.members = p.function_members;
        body_p.call_arguments = p.function_arguments;
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
        var last_new: u32 = no_construction;
        for (p.function_nodes[f.body.start..f.body.end], 0..) |entry, index| {
            const node = entry.node;
            if (!validSpan(node.span, p.source.len) or (p.modules.len != 0 and modules.owner(node.span, p.modules) == null)) return false;
            switch (entry.input) {
                .parameter => |n| if (n >= f.parameter_count or node.value_type != f.parameters[n] or node.kind != .integer or node.kind.integer != 0) {
                    return false;
                },
                .global => |n| {
                    if (n >= p.globals.len or node.kind != .integer or node.kind.integer != 0) return false;
                    const global = p.globals[n];
                    if (global.node >= f.available_at or global.value_type != node.value_type or !runtimeVisible(p, global.name, global.is_public, node.span)) return false;
                },
                .operation => {
                    if (node.kind == .local_set) {
                        if (!allowed.writes or (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules))) return false;
                        has_local = true;
                    }
                    if (types.sourceOp(node)) {
                        if (!stateAllowed(node, allowed) or (!objectOp(node) and !validFunctionCell(p, f, node, nodes[0..index]))) return false;
                        source_ops += 1;
                        has_source = true;
                    }
                    // RFC-0087, P5.3 (admission rule 6): what reaches a class is read or built.
                    if (!jsonAllowed(node, nodes[0..index], p, json, allowed)) return false;
                    // RFC-0086, P2.3 (admission rule 2): opening a grant reads the run's list, so its
                    // function reads; the clock is read too (RFC-0082 rule 5, C96). Neither is a
                    // source operation, so every effect `stateAllowed` names is checked here too.
                    if (!types.sourceOp(node) and !stateAllowed(node, allowed)) return false;
                    if (!clausesHeld(node, nodes[0..index], p, p.function_arguments, last_new)) return false;
                    if (node.kind == .object_new) last_new = @intCast(index);
                    // Nor do the clauses call themselves, with an instance of their choosing.
                    if (f.clauses_of != null and (node.kind == .recur or node.kind == .self_value)) return false;
                    // P3.6: nor does an arm that may exit, which only its expression starts, and
                    // no call or iteration names one.
                    if (f.exits != null and (node.kind == .recur or node.kind == .self_value)) return false;
                    if (node.kind != .function_value and exitingArmNamed(p, node)) return false;
                    if (node.kind == .object_live) {
                        // RFC-0084, P4.2 (admission rule 2): a live-only field is attached only by
                        // the clauses of the class that declares it, on their own `Self`.
                        const c = node.kind.object_live;
                        if (c.object >= index) return false;
                        const field = liveField(p, nodes[c.object].value_type, c.field) orelse return false;
                        if (field.live_only) {
                            const class = f.clauses_of orelse return false;
                            const self_entry = p.function_nodes[f.body.start + c.object];
                            if (self_entry.input != .parameter or self_entry.input.parameter != 0 or nodes[c.object].value_type != class) return false;
                            if (c.field < catalogue.definition(class, p.definitions).?.class.inherited) return false;
                        }
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .object_new) {
                        const c = node.kind.object_new;
                        if (c.arguments.start != argument_count or !catalogue.dispatchReady(p.dispatch, p.functions, node.value_type, f.available_at)) return false;
                        argument_count = c.arguments.end;
                    }
                    if (node.kind == .demand or node.kind == .fail) failures = true;
                    // An effect is not a computation: its caller says so (RFC-0079).
                    if (node.kind == .native_call and node.kind.native_call.native < p.natives.len and p.natives[node.kind.native_call.native].effect != .none and !(allowed.reads and allowed.writes and allowed.allocates)) return false;
                    // RFC-0085, admission rule 9: a function that predicts runs nothing that
                    // dictates: no dictating native, no live form, no notification of callbacks.
                    if (!allowed.dictates and predictionRefused(p, node)) return false;
                    if (node.kind == .exit) {
                        // The value leaves through the frame's result register, so it has that type;
                        // the node's own type is whatever its position expects, as for `fail`.
                        const operand = node.kind.exit;
                        if (operand >= index or nodes[operand].value_type != f.value_type or !catalogue.validType(node.value_type, p.definitions)) return false;
                    }
                    if (node.kind == .arm_exit) {
                        // P3.6: the pending exit has the type the arm's exits have, and the node
                        // fits where it stands, as an exit does.
                        const operand = node.kind.arm_exit;
                        const exits = f.exits orelse return false;
                        if (operand >= index or nodes[operand].value_type != exits or !catalogue.validType(node.value_type, p.definitions)) return false;
                    }
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
                        if (child.anonymous and f.specialization != null and modules.contains(f.generic_source, child.name) and (child.specialization != f.specialization or !runtimeSameTemplate(f.generic_source, child.generic_source))) return false;
                    }
                    if (node.kind == .self_value) {
                        if (!signatureMatches(p, node.value_type, f) or (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules))) return false;
                    }
                    if (node.kind == .loop) {
                        const l = node.kind.loop;
                        if (l.callable >= index) return false;
                        const definition = catalogue.definition(nodes[l.callable].value_type, p.definitions) orelse return false;
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
                        const definition = catalogue.definition(nodes[i.callable].value_type, p.definitions) orelse return false;
                        if (definition != .callable or !callAllowed(definition.callable.effects(), allowed)) return false;
                        has_source = has_source or definition.callable.transacts;
                        has_local = has_local or definition.callable.transacts;
                        failures = true;
                        failable_calls = failable_calls or definition.callable.decides;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .bind) {
                        const b = node.kind.bind;
                        if (b.arguments.start != argument_count) return false;
                        argument_count = b.arguments.end;
                        work = @min(types.limits.aggregate_elements + 1, work + types.limits.parameters);
                    }
                    if (node.kind == .event_notify) {
                        // P3.9: it calls `<transacts>` callbacks (`stateAllowed`), as an `invoke`
                        // calls its callable: what they write is journalled, what they build is
                        // not known here.
                        const n = node.kind.event_notify;
                        if (n.callable >= index or n.arguments.start != argument_count) return false;
                        has_local = true;
                        failures = true;
                        work = types.limits.aggregate_elements + 1;
                        argument_count = n.arguments.end;
                    }
                    if (node.kind == .invoke) {
                        const i = node.kind.invoke;
                        if (i.callable >= index or i.arguments.start != argument_count) return false;
                        const shape = catalogue.definition(nodes[i.callable].value_type, p.definitions) orelse return false;
                        if (shape != .callable or !callAllowed(shape.callable.effects(), allowed)) return false;
                        has_source = has_source or shape.callable.transacts;
                        has_local = has_local or shape.callable.transacts;
                        failures = true;
                        failable_calls = failable_calls or shape.callable.decides;
                        work = types.limits.aggregate_elements + 1;
                        argument_count = i.arguments.end;
                    }
                    if (node.kind == .recur) {
                        recursive = true;
                        const r = node.kind.recur;
                        if (!validSpan(r, p.function_arguments.len) or r.start != argument_count or r.end - r.start != f.parameter_count or node.value_type != f.value_type) return false;
                        if (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules)) return false;
                        for (p.function_arguments[r.start..r.end], f.parameters[0..f.parameter_count]) |operand, t| if (operand >= index or nodes[operand].value_type != t) return false;
                        argument_count = r.end;
                    }
                    if (node.kind == .spawn) {
                        // The body does what its spawner may (admission rule 4), and a task builds
                        // what it builds, as a call that its caller cannot see into does.
                        const operand = node.kind.spawn;
                        if (operand >= index) return false;
                        const shape = catalogue.definition(nodes[operand].value_type, p.definitions) orelse return false;
                        if (shape != .callable or !shape.callable.effects().heap().within(allowed) or !predictionAllowed(shape.callable.effects(), allowed)) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if ((node.kind == .sleep or node.kind == .task_await or node.kind == .event_await or node.kind == .task_cancel or node.kind == .await_guard) and !allowed.suspends) return false;
                    // A guard builds what it builds, and so does a propagation (RFC-0084).
                    if (node.kind == .cell_live) work = types.limits.aggregate_elements + 1;
                    // So does the guard of an `Await` (P4.6).
                    if (node.kind == .await_guard) work = types.limits.aggregate_elements + 1;
                    // Guards and reaction bodies may fail inside regions of their own (I14-D11).
                    if (node.kind == .cell_live or node.kind == .object_live or node.kind == .reaction or node.kind == .await_guard) failures = true;
                    if (node.kind == .reaction) {
                        // P4.4 (admission rule 4): the body does what the function may, and a
                        // reaction builds its handle and what its guard and body build.
                        const r = node.kind.reaction;
                        if (r.body >= index) return false;
                        const shape = catalogue.definition(nodes[r.body].value_type, p.definitions) orelse return false;
                        if (shape != .callable or !shape.callable.effects().heap().within(allowed)) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .batch) {
                        // P4.5 (admission rule 4): the body does what the function may; it is
                        // called as an `invoke` is, so its regions journal what it writes.
                        const operand = node.kind.batch;
                        if (operand >= index) return false;
                        const shape = catalogue.definition(nodes[operand].value_type, p.definitions) orelse return false;
                        if (shape != .callable or !shape.callable.effects().heap().within(allowed)) return false;
                        has_source = has_source or shape.callable.transacts;
                        has_local = has_local or shape.callable.transacts;
                        failures = true;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .structured) {
                        // P3.3: arms do what the function may (admission rule 4), lie in the
                        // argument pool in order, and build what their bodies build.
                        const arms = node.kind.structured.arms;
                        if (!allowed.suspends or arms.start != argument_count or !validSpan(arms, p.function_arguments.len)) return false;
                        for (p.function_arguments[arms.start..arms.end]) |operand| {
                            if (operand >= index) return false;
                            const shape = catalogue.definition(nodes[operand].value_type, p.definitions) orelse return false;
                            if (shape != .callable or !shape.callable.effects().heap().within(allowed) or !predictionAllowed(shape.callable.effects(), allowed)) return false;
                        }
                        argument_count = arms.end;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .branch) {
                        // P3.4: the body does what the function may (rule 4) and builds what it builds.
                        const operand = node.kind.branch;
                        if (!allowed.suspends or operand >= index) return false;
                        const shape = catalogue.definition(nodes[operand].value_type, p.definitions) orelse return false;
                        if (shape != .callable or !shape.callable.effects().heap().within(allowed) or !predictionAllowed(shape.callable.effects(), allowed)) return false;
                        work = types.limits.aggregate_elements + 1;
                    }
                    if (node.kind == .call) {
                        const c = node.kind.call;
                        if (c.function == id or c.function >= p.functions.len or c.arguments.start != argument_count) return false;
                        if (!callAllowed(p.functions[c.function].effects(), allowed)) return false;
                        argument_count = c.arguments.end;
                        failable_calls = failable_calls or p.functions[c.function].decides;
                        if (c.function > id) {
                            // RFC-0091 (admission rule F1): a call of a later function, whose body
                            // is admitted after this one. It is a named function available
                            // exactly where this one is, and what it does is known only from its
                            // signature, so the call counts as an `invoke` of that signature.
                            const later = p.functions[c.function];
                            if (later.available_at != f.available_at or later.anonymous or later.nested or later.clauses_of != null or later.exits != null) return false;
                            has_source = has_source or later.transacts;
                            has_local = has_local or later.transacts;
                            work = types.limits.aggregate_elements + 1;
                            controlled = true;
                            failures = true;
                        } else {
                            has_source = has_source or p.functions[c.function].has_source;
                            has_local = has_local or p.functions[c.function].has_local;
                            work = @min(types.limits.aggregate_elements + 1, work + p.functions[c.function].member_work);
                            controlled = controlled or p.functions[c.function].has_control;
                            failures = failures or p.functions[c.function].has_failure;
                        }
                    }
                    if ((!types.sourceOp(node) or objectOp(node)) and node.kind != .recur and node.kind != .self_value and node.kind != .exit and node.kind != .arm_exit and !validNode(node, nodes[0..index], body_p, comparable, &member_count)) return false;
                    if (!validJson(node, nodes[0..index], body_p, json)) return false;
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
            nodes[index] = node;
        }
        if (recursive and work != 0) work = types.limits.aggregate_elements + 1;
        if (nodes[f.root].value_type != f.value_type or work != f.member_work or controls != f.control_ops or controlled != f.has_control or failures != f.has_failure or source_ops != f.source_ops or has_source != f.has_source or has_local != f.has_local) return false;
        body_p.nodes = nodes[0 .. f.body.end - f.body.start];
        body_p.bindings = &.{};
        body_p.globals = &.{};
        // Without local branches, typed earlier operands already prove that
        // every local/root is visited. Transitive callee branches do not skip
        // this caller's registers; their bodies are admitted separately.
        if ((controls != 0 or failable_calls) and !validateControlRoot(body_p, f.root, f.decides)) return false;
        if (!validSites(body_p, f, body_p.nodes)) return false;
        body_count = f.body.end;
        availability = f.available_at;
    }
    return body_count == p.function_nodes.len and member_count == p.function_members.len and argument_count == p.function_arguments.len;
}

/// The heap effect each state operation is (RFC-0078): an instance or a cell is read, written
/// or, for a new instance, allocated. A function declares the effect of every one in its body.
fn stateAllowed(node: types.Node, allowed: types.EffectSet) bool {
    return switch (node.kind) {
        .cell_read, .object_get => allowed.reads,
        .cell_init, .cell_write, .object_set => allowed.writes,
        .object_new, .spawn => allowed.allocates,
        // P3.2 (admission rule 5): awaiting reads, signalling writes, an event is allocated.
        .task_await, .event_await => allowed.reads,
        .event_signal => allowed.writes,
        .event_new => allowed.allocates,
        // P3.7: a cancellation request writes, as a `Signal` does; the clock is read.
        .task_cancel => allowed.writes,
        .elapsed_time => allowed.reads,
        // RFC-0086, P2.3 (admission rule 2): a grant is looked up in the run's list, read.
        .grant => allowed.reads,
        // RFC-0087, P5.4 (admission rule 5): a keyed cell is read and written as a cell is.
        .weak_get => allowed.reads,
        .weak_init, .weak_set => allowed.writes,
        // RFC-0084, admission rule 6: a guard is evaluated, a cell written and a record built.
        .cell_live, .object_live => allowed.reads and allowed.writes and allowed.allocates,
        // P4.4: a guard is evaluated and a handle built.
        .reaction => allowed.reads and allowed.allocates,
        // P4.6: the guard of an `Await` is evaluated.
        .await_guard => allowed.reads,
        // P3.9: a subscription writes its event and builds its `cancelable`; a cancellation
        // writes; the callbacks of a `Signal` may read, write and allocate (C113).
        .event_subscribe => allowed.writes and allowed.allocates,
        .subscription_cancel => allowed.writes,
        .event_notify => allowed.reads and allowed.writes and allowed.allocates,
        // RFC-0085, I1 (rules 2 to 4): a variable cell is made by a declaration, which writes
        // (its identity is not observable, so nothing is allocated, V4), read, and written.
        .ref_new, .ref_set => allowed.writes,
        .ref_get => allowed.reads,
        else => true,
    };
}
/// A call is admitted where the caller declares the heap effects of what it calls, and suspends
/// if that does. Failure is the control checks' matter; convergence asks nothing of a caller.
fn callAllowed(callee: types.EffectSet, caller: types.EffectSet) bool {
    return callee.heap().within(caller) and (!callee.suspends or caller.suspends) and predictionAllowed(callee, caller);
}
/// RFC-0085, admission rule 9: a function that predicts calls only what predicts. Rule 3
/// compares heap sets only, so the prediction bit has this conjunct of its own.
fn predictionAllowed(callee: types.EffectSet, caller: types.EffectSet) bool {
    return !callee.dictates or caller.dictates;
}
/// The nodes a predicting function may not hold whatever their operands (rule 9): a native
/// that dictates, the live forms, whose guard and body types dictate, and the notification of
/// a subscribable event's callbacks, whose fixed type dictates.
fn predictionRefused(p: types.Program, node: types.Node) bool {
    return switch (node.kind) {
        .native_call => |c| c.native >= p.natives.len or native.dictates(p.natives[c.native]),
        .cell_live, .object_live, .reaction, .batch, .await_guard, .event_notify => true,
        else => false,
    };
}
/// A module's own nodes are not a `<suspends>` context (RFC-0078). Asked of an admitted node.
fn rootSuspends(node: types.Node, prior: []const types.Node, program: types.Program) bool {
    const callable: u32 = switch (node.kind) {
        .call => |c| return program.functions[c.function].detail.suspends,
        .iterate => |i| return program.functions[i.function].detail.suspends,
        .invoke => |i| i.callable,
        .loop => |l| l.callable,
        .iterate_value => |i| i.callable,
        // Nor does it sleep, await, wait for arms or check for cancellation (RFC-0082, rule 1).
        .sleep, .canceling, .cancel_exit, .task_await, .event_await, .structured => return true,
        .branch => return true,
        // Nor check for an arm's exit (P3.6).
        .arm_exit, .arm_exited, .arm_exit_value => return true,
        // Nor ask a task to cancel (P3.7), nor await a guard (RFC-0084, P4.6).
        .task_cancel => return true,
        .await_guard => return true,
        else => return false,
    };
    return catalogue.definition(prior[callable].value_type, program.definitions).?.callable.detail.suspends;
}
/// An upcast of a function is the same function at a type that allows more effects
/// (RFC-0078); a function value carries the type it is used at.
fn retyped(value: types.Value, value_type: types.Type) types.Value {
    // A function held as `any` keeps its own type, which a type test asks for (RFC-0080).
    if (value_type == types.Type.any) return value;
    return switch (value) {
        .callable => |c| .{ .callable = .{ .value_type = value_type, .function = c.function, .captures = c.captures } },
        // RFC-0087, W3: a map made a `weak_map` is one, so no type test finds the map again.
        .aggregate => |a| .{ .aggregate = .{ .value_type = value_type, .elements = a.elements } },
        else => value,
    };
}

/// The source operations on instances, which name no cell of the program: `spawn` builds one,
/// its handle (RFC-0082), and the operations of P3.2 build, read or write handles and events.
fn objectOp(node: types.Node) bool {
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

// Global cell availability is a root declaration boundary, not a body PC.
fn validFunctionCell(p: types.Program, f: types.RuntimeFunction, node: types.Node, prior: []const types.Node) bool {
    // RFC-0087, P5.4: a keyed cell's lookup and update, of a cell declared before the function
    // is, in its module.
    if (node.kind == .weak_get or node.kind == .weak_set) {
        if (!keyedTyped(p, node, prior)) return false;
        const cell = keyedCellOf(node);
        if (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules)) return false;
        return p.source_cells[cell].initial < f.available_at and cellVisible(p, cell, node.span);
    }
    const index = switch (node.kind) {
        .cell_read => |c| c,
        .cell_write => |c| c.cell,
        .cell_live => |c| c.cell,
        else => return false,
    };
    if (index >= p.source_cells.len) return false;
    const cell = p.source_cells[index];
    if (p.modules.len != 0 and modules.owner(node.span, p.modules) != modules.owner(f.name, p.modules)) return false;
    if (cell.initial >= f.available_at or node.value_type != cell.value_type or !cellVisible(p, index, node.span)) return false;
    if (node.kind == .cell_write) {
        const value = node.kind.cell_write.value;
        if (value >= prior.len or prior[value].value_type != cell.value_type or cell.live_only) return false;
    }
    // RFC-0084: a function attaches a guard to a declared cell that is not live-only.
    if (node.kind == .cell_live) {
        const c = node.kind.cell_live;
        if (c.initialize or cell.live_only or c.guard >= prior.len or !guardTyped(p, prior[c.guard].value_type, cell.value_type) or liveRecordType(p, cell.value_type) == null) return false;
    }
    return true;
}
fn referencePush(p: types.Program, call: types.ResolvedCall, arguments: []const u32, caller: []const types.Value, members: []const types.Value, return_to: u32, frames: *call_frames.ReferenceStorage) ?types.Diagnostic.Code {
    const f = p.functions[call.function];
    const length = f.body.end - f.body.start;
    if (frames.depth >= types.limits.call_depth) return .call_depth_limit;
    if (frames.count + length > types.limits.call_registers) return .call_register_limit;
    // Written in place, field by field: a frame is mostly catcher and parameter room that a
    // call does not use, and building it elsewhere to copy it here cost more than the call.
    const frame = &frames.frames[frames.depth];
    frame.function = call.function;
    frame.base = frames.count;
    frame.cursor = 0;
    frame.return_to = return_to;
    frame.remaining_visits = 0;
    frame.catch_depth = 0;
    frame.state_loop = false;
    const captures = call.captures;
    const count = captures.end - captures.start;
    std.debug.assert(captures.end <= members.len and count <= f.parameter_count and call.arguments.end - call.arguments.start == f.parameter_count - count);
    @memcpy(frame.parameters[0..count], members[captures.start..captures.end]);
    for (arguments[call.arguments.start..call.arguments.end], frame.parameters[count..f.parameter_count]) |index, *destination| destination.* = caller[index];
    frames.marks[frames.depth] = @intCast(members.len);
    frames.captures[frames.depth] = captures;
    frames.depth += 1;
    frames.count += length;
    return null;
}
fn referenceStart(p: types.Program, invocation: types.Invocation, arguments: []const u32, caller: []const types.Value, members: []const types.Value, return_to: u32, frames: *call_frames.ReferenceStorage, remaining: *u64) call_frames.Start {
    switch (invocation) {
        .call => |call| if (referencePush(p, call, arguments, caller, members, return_to, frames)) |code| {
            return .{ .failed = code };
        },
        .loop => |transition| {
            const initial = caller[transition.initial];
            if (remaining.* < 1) return .{ .failed = .work_limit };
            remaining.* -= 1;
            const f = p.functions[transition.function];
            const length = f.body.end - f.body.start;
            if (frames.depth >= types.limits.call_depth) return .{ .failed = .call_depth_limit };
            if (length > types.limits.call_registers - frames.count) return .{ .failed = .call_register_limit };
            var frame: call_frames.ReferenceFrame = .{ .function = transition.function, .base = frames.count, .cursor = 0, .return_to = return_to, .state_loop = true };
            const captures = invocation.captures();
            const count_captured = captures.end - captures.start;
            std.debug.assert(captures.end <= members.len and f.parameter_count == count_captured + 1);
            @memcpy(frame.parameters[0..count_captured], members[captures.start..captures.end]);
            frame.parameters[count_captured] = initial;
            frames.frames[frames.depth] = frame;
            frames.marks[frames.depth] = @intCast(members.len);
            frames.captures[frames.depth] = captures;
            frames.count += length;
            frames.depth += 1;
        },
        .iterate => |iteration| {
            const count = caller[iteration.count].integer;
            const initial = caller[iteration.initial];
            if (count < 0) return .{ .failed = .negative_iteration_count };
            if (count == 0) return .{ .immediate = initial };
            if (remaining.* < 1) return .{ .failed = .work_limit };
            remaining.* -= 1;
            const f = p.functions[iteration.function];
            const length = f.body.end - f.body.start;
            if (frames.depth >= types.limits.call_depth) return .{ .failed = .call_depth_limit };
            if (length > types.limits.call_registers - frames.count) return .{ .failed = .call_register_limit };
            var frame: call_frames.ReferenceFrame = .{ .function = iteration.function, .base = frames.count, .cursor = 0, .return_to = return_to, .remaining_visits = @intCast(count) };
            const captures = invocation.captures();
            const count_captured = captures.end - captures.start;
            std.debug.assert(captures.end <= members.len and f.parameter_count == count_captured + 1);
            @memcpy(frame.parameters[0..count_captured], members[captures.start..captures.end]);
            frame.parameters[count_captured] = initial;
            frames.frames[frames.depth] = frame;
            frames.marks[frames.depth] = @intCast(members.len);
            frames.captures[frames.depth] = captures;
            frames.count += length;
            frames.depth += 1;
        },
    }
    return .pushed;
}
fn referenceUnwind(p: types.Program, root_target: u32, root_pc: u32, members: []const types.Value, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: ?*source_state.ReferenceState, cause: types.CallFailure) ?call_frames.Result {
    while (frames.depth > 0) {
        const leaving = frames.frames[frames.depth - 1];
        std.debug.assert(leaving.catch_depth == 0 and p.functions[leaving.function].decides);
        frames.count -= p.functions[leaving.function].body.end - p.functions[leaving.function].body.start;
        frames.depth -= 1;
        if (frames.depth == 0) {
            if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .{ .failed = .{ .span = p.nodes[root_pc].span, .code = .call_trace_limit } };
            control.calls[control.call_count] = .{ .function = root_target, .pc = root_pc, .value = cause.value, .kind = .root_failure };
            control.call_count += 1;
            return .{ .language = cause };
        }
        const parent = &frames.frames[frames.depth - 1];
        const parent_pc = leaving.return_to - parent.base;
        const f = p.functions[parent.function];
        const node = p.function_nodes[f.body.start + parent_pc].node;
        std.debug.assert(node.isInvocation() and parent.cursor == parent_pc + 1);
        if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } };
        control.calls[control.call_count] = .{ .function = parent.function, .pc = parent_pc, .value = cause.value, .kind = .propagate };
        control.call_count += 1;
        if (parent.catch_depth > 0) {
            if (f.has_source) source.?.abort() catch unreachable;
            referenceRegionAbort(control, &frames.scheduler);
            parent.catch_depth -= 1;
            const begin = parent.catchers[parent.catch_depth];
            frames.values[parent.base + begin] = .{ .boolean = false };
            parent.cursor = p.function_nodes[f.body.start + begin].node.kind.attempt_begin.alternative + 1;
            return null;
        }
    }
    unreachable;
}
// The reference machine snapshots parameters and advances the parent before
// entering a child. It restores a separate return register continuation.
fn referenceCall(p: types.Program, invocation: types.Invocation, force_trace: bool, root_pc: u32, roots: []const types.Value, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: ?*source_state.ReferenceState, remaining: *u64) call_frames.Result {
    std.debug.assert(frames.depth == 0 and frames.count == 0);
    defer {
        frames.depth = 0;
        frames.count = 0;
    }
    const span = p.nodes[root_pc].span;
    const target = p.functions[invocation.target()];
    const tracing = force_trace or invocation != .call or target.has_control or target.has_source or target.has_local;
    if (invocation == .call) {
        if (referencePush(p, invocation.call, p.call_arguments, roots, members[0..member_count.*], 0, frames)) |code| return .{ .failed = .{ .span = span, .code = code } };
    } else switch (referenceStart(p, invocation, p.call_arguments, roots, members[0..member_count.*], 0, frames, remaining)) {
        .pushed => {},
        .immediate => |initial| return .{ .ok = initial },
        .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
    }
    referenceMarked(frames, pool, source);
    // A replay follows the string pool from the steps of a call, and what was built outside
    // traced calls left none, so it is told where the pool stands as the call begins. Twice:
    // the first window may carry the last steps of the call before, and the replay begins a
    // call with the window after the one in which it reached it.
    if (tracing and control.trace_sink != null) for (0..2) |_| control.foldCalls(members[0..member_count.*]);
    return referenceLoop(p, invocation.target(), tracing, span, root_pc, roots, members, member_count, pool, key_work, frames, control, source, remaining);
}
/// The frame loop, until the active stack is empty: a call from the root has returned, or a task
/// that ran on an empty stack waits or has settled (RFC-0082). Tasks handed off to run on top of
/// the frames that started them, and leave by waiting or settling, as a callee returns.
fn referenceLoop(p: types.Program, root_target: u32, tracing: bool, span: types.Span, root_pc: u32, roots: []const types.Value, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: ?*source_state.ReferenceState, remaining: *u64) call_frames.Result {
    const s = &frames.scheduler;
    // A guard's frame loop (RFC-0084) runs on top of the frames below it and ends with its frame.
    while (frames.depth > frames.guard_floor) {
        // RFC-0084, P4.4: the next turn of the drain of the frame on top, which the turn before
        // left to be taken here, where everything a reaction's start needs is at hand.
        if (frames.live.drain_turn) {
            frames.live.drain_turn = false;
            const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = frames.drain_spans[frames.depth - 1], .return_to = 0 };
            switch (referenceDrainTurn(&run)) {
                .pushed, .done => continue,
                .failed => |diagnostic| return .{ .failed = diagnostic },
            }
        }
        const frame = &frames.frames[frames.depth - 1];
        const f = p.functions[frame.function];
        if (frame.cursor == f.body.end - f.body.start) {
            std.debug.assert(frame.catch_depth == 0);
            // P3.4: a frame that ended by `cancel_exit` while it owned tasks has waited for them;
            // it ends cancelled now.
            if (frames.canceled_ends[frames.depth - 1]) {
                std.debug.assert(frames.owned_firsts[frames.depth - 1] == no_task);
                switch (referenceCanceledEnd(p, s, frames, control, members, member_count, pool, source, p.function_nodes[f.body.start + f.root].node.span, root_pc, remaining)) {
                    .empty => return .{ .ok = .{ .boolean = false } },
                    .below => continue,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                }
            }
            // P3.4: at the end of a frame, or of a visit of a loop's function (a call of it), the
            // tasks it owns are asked to cancel first, and its task waits here until they are
            // settled; it comes back here when they are, and the end goes on.
            if (frames.owned_firsts[frames.depth - 1] != no_task) switch (referenceOwnedEnd(p, s, frames, control, members, member_count, pool, source, root_pc, remaining)) {
                .empty => return .{ .ok = .{ .boolean = false } },
                .below => continue,
                .failed => |diagnostic| return .{ .failed = diagnostic },
            };
            var result = frames.values[frame.base + f.root];
            if (frame.state_loop) {
                std.debug.assert(result == .aggregate);
                const option = result.aggregate.elements;
                std.debug.assert(option.end - option.start <= 1 and option.end <= member_count.*);
                if (option.start == option.end) {
                    result = frame.parameters[f.parameter_count - 1];
                } else {
                    const dispatch_span = if (frames.depth == 1) span else dispatch: {
                        const parent = frames.frames[frames.depth - 2];
                        const pc = frame.return_to - parent.base;
                        break :dispatch p.function_nodes[p.functions[parent.function].body.start + pc].node.span;
                    };
                    if (remaining.* < 1) return .{ .failed = .{ .span = dispatch_span, .code = .work_limit } };
                    remaining.* -= 1;
                    frame.parameters[f.parameter_count - 1] = members[option.start];
                    // The visit is over: of what it built, only the next state is still in use.
                    if (tracing and !frames.live.tracking and control.reclaimNow(referenceUsage(member_count.*, pool, source), referenceReclaimMarks(frames, control), frames.depth, false, referenceAcross(frames))) referenceReclaim(p, members, member_count, pool, source, frames, control, &frame.parameters[f.parameter_count - 1]);
                    frame.cursor = 0;
                    continue;
                }
            } else if (frame.remaining_visits > 1) {
                const dispatch_span = if (frames.depth == 1) span else dispatch: {
                    const parent = frames.frames[frames.depth - 2];
                    const pc = frame.return_to - parent.base;
                    break :dispatch p.function_nodes[p.functions[parent.function].body.start + pc].node.span;
                };
                if (remaining.* < 1) return .{ .failed = .{ .span = dispatch_span, .code = .work_limit } };
                remaining.* -= 1;
                frame.parameters[f.parameter_count - 1] = result;
                if (tracing and !frames.live.tracking and control.reclaimNow(referenceUsage(member_count.*, pool, source), referenceReclaimMarks(frames, control), frames.depth, false, referenceAcross(frames))) referenceReclaim(p, members, member_count, pool, source, frames, control, &frame.parameters[f.parameter_count - 1]);
                frame.remaining_visits -= 1;
                frame.cursor = 0;
                continue;
            }
            // The frame is over: of what it built, only its result is still in use. The caller's
            // step for the call records the result where it lies afterwards. A frame that saw
            // another task run since it was pushed roots what the suspended tasks hold as well
            // (RFC-0082, the P3.5 rule). Not while a guard runs (RFC-0084): its reads and the
            // dirty set name cells by place. A frame that saw a switch waits for the last
            // reclamation to be paid for (RFC-0085, I6-D3): other tasks built above its marks too.
            if (tracing and !frames.live.tracking and control.reclaimReturn(referenceUsage(member_count.*, pool, source), referenceReclaimMarks(frames, control), frames.depth, true, frames.switch_marks[frames.depth - 1], frames.scheduler.switches, (if (source) |state| state.undo_count + live_reference.measure(&frames.live, state) else 0) + referenceAcross(frames))) referenceReclaim(p, members, member_count, pool, source, frames, control, &result);
            const destination = frame.return_to;
            const settling = frames.task_marks[frames.depth - 1];
            const handoff = frames.handoffs[frames.depth - 1];
            const entry_function = frame.function;
            frames.count -= f.body.end - f.body.start;
            frames.depth -= 1;
            if (settling != no_task) {
                // A task's entry frame ended: the task completed (RFC-0082).
                const blame = p.function_nodes[f.body.start + f.root].node.span;
                // Or a reaction's body returned (RFC-0084, P4.4).
                if (reactionTask(&s.tasks[settling])) {
                    const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = s.tasks[settling].fire_span, .return_to = 0 };
                    switch (referenceFired(&run, settling, entry_function, result, handoff, destination, blame)) {
                        .going => continue,
                        .empty => return .{ .ok = result },
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                }
                // A branch's handle is the unit value its creator's register gets (P3.4).
                const handle: types.Value = if (s.tasks[settling].kind != .arm) s.tasks[settling].handle else .{ .boolean = false };
                // An arm tells its expression, whose start phase goes on if it is under way (P3.3).
                const arm_parent = if (s.tasks[settling].kind == .arm) s.tasks[settling].parent else no_task;
                if (arm_parent != no_task) {
                    if (referenceArmSettled(p, s, frames, control, source.?, members[0..member_count.*], settling, entry_function, result, false, remaining)) |code| return .{ .failed = .{ .span = blame, .code = code } };
                } else if (s.tasks[settling].holder != no_task) {
                    // A branch, or a loser of a `Rush`, leaves the frame that owns it (P3.4).
                    if (referenceOwnedSettled(p, s, frames, control, members[0..member_count.*], settling, entry_function, result, false)) |code| return .{ .failed = .{ .span = blame, .code = code } };
                } else if (referenceSettle(p, s, control, source.?, members, member_count, settling, entry_function, result)) |code| return .{ .failed = .{ .span = blame, .code = code } };
                if (frames.depth == 0) return .{ .ok = result };
                switch (referenceLeft(p, s, frames, control, members, member_count, pool, source, .{ .handoff = handoff, .return_to = destination, .handle = handle, .arm_parent = arm_parent }, blame, root_pc, remaining)) {
                    .going => continue,
                    .empty => return .{ .ok = result },
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                }
            }
            if (frames.depth == frames.guard_floor) return .{ .ok = result };
            const parent = &frames.frames[frames.depth - 1];
            const parent_pc = destination - parent.base;
            // P3.9: a callback of a `Signal` returned: the next subscription's runs, and the node
            // yields only after the last (C109, C115).
            const notified = p.function_nodes[p.functions[parent.function].body.start + parent_pc];
            if (notified.input == .operation and notified.node.kind == .event_notify) {
                const from = source.?.read(frames.notify_cursors[frames.depth - 1].id + catalogue.cancelable_after) catch unreachable;
                switch (referenceNotifyFrom(p, frames, members[0..member_count.*], source.?, notified.node.kind.event_notify, from, destination, remaining)) {
                    .pushed => {
                        referenceMarked(frames, pool, source);
                        continue;
                    },
                    .done => result = referenceUnit(p, notified.node),
                    .failed => |code| return .{ .failed = .{ .span = notified.node.span, .code = code } },
                }
            }
            if (tracing) {
                if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = p.function_nodes[p.functions[parent.function].body.start + parent_pc].node.span, .code = .call_trace_limit } };
                control.calls[control.call_count] = .{ .function = parent.function, .pc = parent_pc, .value = result };
                control.call_count += 1;
            }
            frames.values[destination] = result;
            // RFC-0084, P4.5: the body of a batch returned to its node: the count goes down, and
            // the return is a delivery point.
            const caller = p.function_nodes[p.functions[parent.function].body.start + parent_pc];
            if (caller.input == .operation and caller.node.kind == .batch) {
                std.debug.assert(frames.live.batch != 0);
                frames.live.batch -= 1;
                if (frames.live.on) {
                    const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = caller.node.span, .return_to = 0 };
                    switch (referenceDeliveryPoint(&run)) {
                        .fired, .done => {},
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                }
            }
            continue;
        }
        const cursor = frame.cursor;
        const entry = p.function_nodes[f.body.start + cursor];
        const node = entry.node;
        const cost: u32 = 1 + if (entry.input == .operation and node.kind == .aggregate) node.kind.aggregate.end - node.kind.aggregate.start else if (entry.input == .operation and node.kind == .object_new) node.kind.object_new.arguments.end - node.kind.object_new.arguments.start else if (entry.input == .operation and node.kind == .ref_new) @as(u32, 1) else if (entry.input == .operation and node.kind == .bind) bind: {
            const b = node.kind.bind;
            const original = frames.values[frame.base + b.callable].callable;
            break :bind original.captures.end - original.captures.start + b.arguments.end - b.arguments.start;
        } else @as(u32, 0);
        if (remaining.* < cost) return .{ .failed = .{ .span = node.span, .code = .work_limit } };
        if (tracing and control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } };
        remaining.* -= cost;
        frame.cursor += 1;
        const destination = frame.base + cursor;
        const locals = frames.values[frame.base..destination];
        var value: types.Value = undefined;
        // Set when this node commits a region to depth 0 and so begins a drain (RFC-0082).
        var drain = false;
        // Set when this node is a delivery point (RFC-0084, P4.4): a write, an establishing
        // write, or a commit; whether it may deliver is asked after it.
        var point = false;
        switch (entry.input) {
            .parameter => |n| value = frame.parameters[n],
            .global => |n| value = roots[p.globals[n].node],
            .operation => switch (node.kind) {
                .if_begin => |b| {
                    value = locals[b.condition];
                    if (!value.boolean) frame.cursor = b.alternative + 1;
                },
                .attempt_begin => {
                    if (f.has_source) source.?.begin() catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    control.effects.begin();
                    frame.catchers[frame.catch_depth] = cursor;
                    frame.catch_depth += 1;
                    value = .{ .boolean = true };
                },
                .otherwise => |begin| {
                    value = .{ .boolean = true };
                    const marker = p.function_nodes[f.body.start + begin].node.kind;
                    if (marker == .attempt_begin) {
                        std.debug.assert(frame.catch_depth > 0 and frame.catchers[frame.catch_depth - 1] == begin);
                        if (f.has_source) source.?.commit() catch unreachable;
                        drain = referenceRegionCommit(control, s) catch return .{ .failed = .{ .span = node.span, .code = .effect_commit_failed } };
                        frame.catch_depth -= 1;
                        point = true;
                    }
                    frame.cursor = (if (marker == .if_begin) marker.if_begin else marker.attempt_begin).end;
                },
                .demand, .fail => |operand| {
                    const reason = locals[operand];
                    if (node.kind == .fail or !reason.boolean) {
                        std.debug.assert(tracing);
                        control.calls[control.call_count] = .{ .function = frame.function, .pc = cursor, .value = reason, .kind = .failure };
                        control.call_count += 1;
                        control.record(.{ .instruction = root_pc, .function = frame.function, .pc = cursor, .span = node.span, .code = if (node.kind == .fail) .language_failure else .requirement_failed, .reason = if (node.kind == .fail) reason.string else null });
                        if (frame.catch_depth == 0) {
                            const cause: types.CallFailure = .{ .function = frame.function, .pc = cursor, .value = reason };
                            if (referenceUnwind(p, root_target, root_pc, members[0..member_count.*], frames, control, source, cause)) |outcome| return outcome;
                            continue;
                        }
                        if (f.has_source) source.?.abort() catch unreachable;
                        referenceRegionAbort(control, s);
                        frame.catch_depth -= 1;
                        const begin = frame.catchers[frame.catch_depth];
                        frames.values[frame.base + begin] = .{ .boolean = false };
                        frame.cursor = p.function_nodes[f.body.start + begin].node.kind.attempt_begin.alternative + 1;
                        continue;
                    }
                    value = .{ .boolean = true };
                },
                .exit => |operand| {
                    // Leaving is not failing: every region this frame opened is committed, so the
                    // writes made so far stay, and an enclosing region can still undo them.
                    std.debug.assert(tracing);
                    const committed = frame.catch_depth > 0;
                    while (frame.catch_depth > 0) {
                        if (f.has_source) source.?.commit() catch unreachable;
                        if (referenceRegionCommit(control, s) catch return .{ .failed = .{ .span = node.span, .code = .effect_commit_failed } }) drain = true;
                        frame.catch_depth -= 1;
                    }
                    const result = locals[operand];
                    control.calls[control.call_count] = .{ .function = frame.function, .pc = cursor, .value = result, .kind = .exit };
                    control.call_count += 1;
                    frames.values[frame.base + f.root] = result;
                    frame.cursor = f.body.end - f.body.start;
                    // Starts it committed take their turns before the frame goes on to its end.
                    if (drain) frames.drain_spans[frames.depth - 1] = node.span;
                    if (drain) if (referenceDrainFrom(p, s, frames, control, members[0..member_count.*], pool, source, root_pc, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    // RFC-0084, P4.4: a commit to depth 0 delivers, after its drain.
                    if (committed and !drain and frames.live.on) {
                        const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = 0 };
                        switch (referenceDeliveryPoint(&run)) {
                            .fired, .done => {},
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    }
                    continue;
                },
                .spawn => |operand| {
                    const slot = switch (referenceSpawn(p, node.value_type, locals[operand], root_pc, s, source.?, remaining)) {
                        .ok => |slot| slot,
                        .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                    };
                    value = s.tasks[slot].handle;
                    if (control.effects.depth != 0) {
                        // Held by the region; the handle is the node's value at once.
                        if (!referenceHold(s, slot, control.effects.depth)) return .{ .failed = .{ .span = node.span, .code = .scheduler_action_limit } };
                    } else {
                        // Hand-off (S2): the task runs on top of this frame, which gets the handle
                        // when the task first leaves the stack.
                        if (referenceTaskStart(p, s, frames, control, members[0..member_count.*], pool, source, slot, true, destination)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        continue;
                    }
                },
                .sleep => |operand| {
                    if (referenceCanceledAt(s, control, frame.function, cursor)) continue;
                    const seconds = locals[operand].floating;
                    if (types.isNan(seconds)) return .{ .failed = .{ .span = node.span, .code = .invalid_sleep_duration } };
                    if (referenceWake(seconds, s.now, s.tick_rate)) |deadline| {
                        switch (referenceWaitAt(p, s, frames, control, members, member_count, pool, source.?, cursor, .{ .sleep = deadline }, node.span, root_pc, remaining)) {
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .below => continue,
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    }
                    // A negative duration completes at once (RFC-0082, "Time").
                    value = referenceUnit(p, node);
                },
                // P3.2. An await of a task that completed yields its result at once; of one
                // that has not, the task joins its awaiters and waits. An event's next `Signal`
                // is always waited for.
                .task_await => |operand| awaited: {
                    if (referenceCanceledAt(s, control, frame.function, cursor)) continue;
                    const handle = locals[operand].object;
                    // P3.9: a sticky event that was signalled gives its value at once (C105).
                    if (referenceSticky(p, source.?, handle)) |held| {
                        value = held;
                        break :awaited;
                    }
                    // P3.7: an `awaitable(T)` that holds an event waits for its next `Signal`.
                    if (catalogue.isEvent(handle.value_type, p.definitions)) switch (referenceWaitAt(p, s, frames, control, members, member_count, pool, source.?, cursor, .{ .event = handle }, node.span, root_pc, remaining)) {
                        .empty => return .{ .ok = .{ .boolean = false } },
                        .below => continue,
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    };
                    const phase = (source.?.read(handle.id + catalogue.task_state) catch unreachable).integer;
                    if (phase == catalogue.task_completed) {
                        const result = (source.?.read(handle.id + catalogue.task_result) catch unreachable).aggregate.elements;
                        std.debug.assert(result.end == result.start + 1);
                        value = members[result.start];
                    } else if (phase == catalogue.task_canceled) {
                        // P3.7 (Q3): awaiting a cancelled task asks the awaiter's own task to
                        // cancel, and the site yields cancelled at once.
                        if (referenceAwaitCanceled(s, control, frame.function, cursor, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                        continue;
                    } else {
                        // An unsettled handle names a live task.
                        std.debug.assert(phase == catalogue.task_active);
                        const sequence: u64 = @intCast((source.?.read(handle.id + catalogue.task_sequence) catch unreachable).integer);
                        const awaited = referenceIndexFind(s, sequence).?;
                        switch (referenceWaitAt(p, s, frames, control, members, member_count, pool, source.?, cursor, .{ .task = .{ .handle = handle, .slot = awaited } }, node.span, root_pc, remaining)) {
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .below => continue,
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    }
                },
                .event_await => |operand| if (referenceCanceledAt(s, control, frame.function, cursor)) continue else if (referenceSticky(p, source.?, locals[operand].object)) |held| {
                    // P3.9: a sticky event that was signalled gives its value at once (C105).
                    value = held;
                } else switch (referenceWaitAt(p, s, frames, control, members, member_count, pool, source.?, cursor, .{ .event = locals[operand].object }, node.span, root_pc, remaining)) {
                    .empty => return .{ .ok = .{ .boolean = false } },
                    .below => continue,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                },
                // P3.3: a structured expression. Its record goes in the slot of the task running
                // it, and its first arm starts by hand-off (S2); each arm that leaves the stack
                // hands the start phase on (`referenceLeft`).
                .structured => |structured| {
                    if (referenceCanceledAt(s, control, frame.function, cursor)) continue;
                    const parent = frames.task_marks[referenceRunning(frames)];
                    // In P3.3 no task on the active stack is flagged (`referenceRequests`).
                    std.debug.assert(!s.tasks[parent].flagged);
                    s.tasks[parent].record = .{ .kind = structured.kind, .function = frame.function, .pc = cursor, .arms = structured.arms.end - structured.arms.start, .starting = true };
                    if (referenceArmStart(p, s, frames, control, members[0..member_count.*], pool, source, parent, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    continue;
                },
                // P3.4: a task owned by this frame, handed off to at once (S2); this frame's register
                // gets the unit value when the task first leaves the stack.
                .branch => |operand| {
                    if (referenceCanceledAt(s, control, frame.function, cursor)) continue;
                    if (referenceBranch(p, s, frames, control, members[0..member_count.*], pool, source, locals[operand], node.value_type, root_pc, destination, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    continue;
                },
                // P3.7: `T.Cancel()`, a request to the task of the handle; and the clock.
                .task_cancel => |operand| {
                    if (referenceCanceledAt(s, control, frame.function, cursor)) continue;
                    if (referenceCancel(s, source.?, locals[operand].object, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    value = referenceUnit(p, node);
                },
                .elapsed_time => value = .{ .floating = referenceElapsed(s) },
                // RFC-0086, P2.3: a handle of the run's grants, or `option{}`.
                .grant => |g| value = if (g.kind == .session) referenceSession(node.value_type) else switch (referenceGrant(control.effects.inputs.grants, g, locals[g.name].string, node.value_type, p, members, member_count, @min(members.len, types.limits.aggregate_elements) - member_count.*, remaining)) {
                    .ok => |made| made,
                    .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                },
                // RFC-0087, P5.3: `ToJson` and `FromJson`.
                .json_encode, .json_decode => |operand| value = switch (referenceJson(p, node, p.function_nodes[f.body.start + operand].node.value_type, locals[operand], members, member_count, pool, key_work, frames, source, remaining)) {
                    .ok => |made| made,
                    .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                },
                // RFC-0084, P4.6: `Await(G)`. The guard is evaluated with tracking; when it holds
                // the site yields its value, otherwise the task waits on it here (N7).
                .await_guard => |operand| {
                    if (referenceCanceledAt(s, control, frame.function, cursor)) continue;
                    const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                    switch (referenceAwait(&run, locals[operand].callable)) {
                        .holds => |held| {
                            value = held;
                            // Its guard left steps: the site's own needs room again.
                            if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } };
                        },
                        .waits => switch (referenceWaitAt(p, s, frames, control, members, member_count, pool, source.?, cursor, .guard, node.span, root_pc, remaining)) {
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .below => continue,
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        },
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                },
                .event_new => value = referenceEvent(p, source.?, node.value_type) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } },
                .event_signal => |signal| {
                    value = referenceUnit(p, node);
                    if (control.effects.depth != 0) {
                        if (!referenceHoldSignal(s, locals[signal.event], locals[signal.value], control.effects.depth)) return .{ .failed = .{ .span = node.span, .code = .scheduler_action_limit } };
                    } else if (referenceSignal(s, source.?, locals[signal.event].object, locals[signal.value], remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                },
                // P3.9: subscriptions, journalled as a field's writes are.
                .event_subscribe => |c| value = referenceSubscribe(source.?, locals[c.event].object, locals[c.callback], node.value_type) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } },
                .subscription_cancel => |operand| {
                    referenceUnsubscribe(source.?, locals[operand].object) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    value = referenceUnit(p, node);
                },
                // P3.9: the first callback of the `Signal` runs on top, returning here; the frame
                // goes on when the last has returned (the frame's end above).
                .event_notify => |n| {
                    const event = locals[n.callable].object;
                    frames.notify_limits[frames.depth - 1] = (source.?.read(event.id + catalogue.subscription_count) catch unreachable).integer;
                    const from = source.?.read(event.id + catalogue.subscription_first) catch unreachable;
                    switch (referenceNotifyFrom(p, frames, members[0..member_count.*], source.?, n, from, destination, remaining)) {
                        .pushed => {
                            referenceMarked(frames, pool, source);
                            continue;
                        },
                        .done => value = referenceUnit(p, node),
                        .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                    }
                },
                // P3.3: whether the site just before yielded cancelled, which only it can have.
                .canceling => {
                    value = .{ .boolean = s.canceled_now };
                    s.canceled_now = false;
                },
                // P3.6: whether the site before this check yielded an arm's pending exit, which
                // only it can; and the value of that exit, which the code after it carries on.
                .arm_exited => {
                    value = .{ .boolean = s.exited_now };
                    s.exited_now = false;
                },
                .arm_exit_value => value = s.exited_value,
                .arm_exit => |operand| {
                    // P3.6: an exit of an arm's entry frame (only an arm runs its function), which
                    // its expression learns of when the frame has ended and settles the arm.
                    const arm = frames.task_marks[frames.depth - 1];
                    std.debug.assert(tracing and arm != no_task and s.tasks[arm].kind == .arm);
                    const committed = frame.catch_depth > 0;
                    while (frame.catch_depth > 0) {
                        if (f.has_source) source.?.commit() catch unreachable;
                        if (referenceRegionCommit(control, s) catch return .{ .failed = .{ .span = node.span, .code = .effect_commit_failed } }) drain = true;
                        frame.catch_depth -= 1;
                    }
                    const pending = locals[operand];
                    control.calls[control.call_count] = .{ .function = frame.function, .pc = cursor, .value = pending, .kind = .arm_exit };
                    control.call_count += 1;
                    s.tasks[arm].exited = true;
                    frames.values[frame.base + f.root] = pending;
                    frame.cursor = f.body.end - f.body.start;
                    if (drain) frames.drain_spans[frames.depth - 1] = node.span;
                    if (drain) if (referenceDrainFrom(p, s, frames, control, members[0..member_count.*], pool, source, root_pc, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    // RFC-0084, P4.4: a commit to depth 0 delivers, after its drain, as `exit`.
                    if (committed and !drain and frames.live.on) {
                        const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = 0 };
                        switch (referenceDeliveryPoint(&run)) {
                            .fired, .done => {},
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    }
                    continue;
                },
                .cancel_exit => {
                    // The landing has run: the frame ends as cancelled, its result unwritten, and
                    // reclaims nothing.
                    std.debug.assert(tracing and frame.catch_depth == 0);
                    control.calls[control.call_count] = .{ .function = frame.function, .pc = cursor, .value = .{ .boolean = false }, .kind = .cancel_exit };
                    control.call_count += 1;
                    if (frames.owned_firsts[frames.depth - 1] != no_task) {
                        // P3.4: it owns tasks, which it asks to cancel and waits for at its end,
                        // before it ends cancelled.
                        frames.canceled_ends[frames.depth - 1] = true;
                        frame.cursor = f.body.end - f.body.start;
                        switch (referenceOwnedEnd(p, s, frames, control, members, member_count, pool, source, root_pc, remaining)) {
                            .empty => return .{ .ok = .{ .boolean = false } },
                            .below => continue,
                            .failed => |diagnostic| return .{ .failed = diagnostic },
                        }
                    }
                    switch (referenceCanceledEnd(p, s, frames, control, members, member_count, pool, source, node.span, root_pc, remaining)) {
                        .empty => return .{ .ok = .{ .boolean = false } },
                        .below => continue,
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                },
                .err => return .{ .failed = .{ .span = node.span, .code = .runtime_error } },
                .cell_read => |cell| {
                    value = source.?.read(cell) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    // RFC-0084, L3: a guard that runs records the cells it reads.
                    if (frames.live.tracking) live_reference.track(&frames.live, source.?, cell);
                },
                .cell_write => |cell| {
                    value = locals[cell.value];
                    if (frames.live.on) live_reference.detach(&frames.live, source.?, cell.cell, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveCode(err) } };
                    source.?.write(cell.cell, value, false) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    if (frames.live.on) {
                        const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                        if (referencePropagate(&run, cell.cell)) |diagnostic| return .{ .failed = diagnostic };
                        point = true;
                    }
                },
                .cell_init => unreachable,
                // RFC-0087, P5.4: a keyed cell's lookup, a read of the whole cell for a guard
                // (L3), and its update, a program write (W6).
                .weak_get => |g| {
                    const map = source.?.read(g.cell) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    if (frames.live.tracking) live_reference.track(&frames.live, source.?, g.cell);
                    value = referenceWeakGet(map, locals[g.key], node.value_type, members, key_work, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = keyedCode(err) } };
                },
                .weak_set => |c| {
                    const map = source.?.read(c.cell) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    const written = referenceWeakSet(map, locals[c.key], locals[c.value], members, member_count, key_work, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = keyedCode(err) } };
                    value = locals[c.value];
                    if (frames.live.on) live_reference.detach(&frames.live, source.?, c.cell, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveCode(err) } };
                    source.?.write(c.cell, written, false) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    // RFC-0087, P5.5 (S5): and, for a persistent cell, its action on the store channel.
                    if (referenceStoreAction(p, c, locals[c.key], locals[c.value], members, member_count.*, pool, frames, &control.effects, source, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    if (frames.live.on) {
                        const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                        if (referencePropagate(&run, c.cell)) |diagnostic| return .{ .failed = diagnostic };
                        point = true;
                    }
                },
                .weak_init => unreachable,
                .object_new => |c| value = referenceObject(source.?, node.value_type, p.function_arguments[c.arguments.start..c.arguments.end], locals) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } },
                // RFC-0085, I1: a variable cell, built, read and written as a `var` field is. Its
                // value can change, so a guard that reads it depends on it (S9, L3).
                .ref_new => |operand| value = referenceRef(source.?, node.value_type, locals[operand]) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } },
                .ref_get => |operand| {
                    value = source.?.read(locals[operand].object.id + catalogue.ref_value) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    if (frames.live.tracking) live_reference.track(&frames.live, source.?, locals[operand].object.id + catalogue.ref_value);
                },
                .ref_set => |r| {
                    value = locals[r.value];
                    const cell = locals[r.ref].object.id + catalogue.ref_value;
                    // RFC-0084, L2: a program write of the cell detaches its record.
                    if (frames.live.on) live_reference.detach(&frames.live, source.?, cell, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveCode(err) } };
                    source.?.write(cell, value, false) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    if (frames.live.on) {
                        const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                        if (referencePropagate(&run, cell)) |diagnostic| return .{ .failed = diagnostic };
                        point = true;
                    }
                },
                .object_get => |a| {
                    value = source.?.read(locals[a.value].object.id + 1 + a.index) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    // Only a `var` or live-only field can change, so only its reads are
                    // dependencies (L3).
                    if (frames.live.tracking and changes(catalogue.classFieldAt(locals[a.value].object.value_type, a.index, p.definitions, p.fields).?)) live_reference.track(&frames.live, source.?, locals[a.value].object.id + 1 + a.index);
                },
                .object_set => |c| {
                    value = locals[c.value];
                    // RFC-0084, L2: a program write of a field detaches its record (P4.2).
                    if (frames.live.on) live_reference.detach(&frames.live, source.?, locals[c.object].object.id + 1 + c.index, remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = liveCode(err) } };
                    source.?.write(locals[c.object].object.id + 1 + c.index, value, false) catch |err| return .{ .failed = .{ .span = node.span, .code = source_state.diagnostic(err) } };
                    if (frames.live.on) {
                        const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                        if (referencePropagate(&run, locals[c.object].object.id + 1 + c.index)) |diagnostic| return .{ .failed = diagnostic };
                        point = true;
                    }
                },
                // RFC-0084: `set live` in a function, which has all three heap effects.
                .cell_live => |c| {
                    const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                    value = switch (referenceEstablish(&run, moduleTarget(p, c), locals[c.guard].callable, (@as(i64, frame.function) + 1) << 32 | cursor)) {
                        .ok => |established| established,
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    };
                    point = true;
                },
                // RFC-0084, P4.2: `set live E.F = G`, and the attachment of a live field.
                .object_live => |c| {
                    const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                    value = switch (referenceEstablish(&run, fieldTarget(locals[c.object].object, c, node.value_type), locals[c.guard].callable, (@as(i64, frame.function) + 1) << 32 | cursor)) {
                        .ok => |established| established,
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    };
                    point = true;
                },
                // RFC-0084, P4.4: `Upon` or `When`. Outside every region it starts at once and,
                // if its guard holds, its body runs on top; this frame gets the handle when the
                // body returns. Inside one its start is held, as a `Spawn`'s.
                .reaction => |r| {
                    const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = destination };
                    const slot = switch (referenceReaction(&run, node.value_type, r, locals[r.guard], locals[r.body], root_pc)) {
                        .ok => |slot| slot,
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    };
                    value = s.tasks[slot].handle;
                    if (control.effects.depth != 0) {
                        if (!referenceHold(s, slot, control.effects.depth)) return .{ .failed = .{ .span = node.span, .code = .scheduler_action_limit } };
                    } else switch (referenceReactionStart(&run, slot, .node)) {
                        .fired => continue,
                        // Its guard left steps: the node's own needs room again.
                        .waits => if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = node.span, .code = .call_trace_limit } },
                        .failed => |diagnostic| return .{ .failed = diagnostic },
                    }
                },
                // RFC-0084, P4.5: `Batch{...}`: its body's frame on top, with the batch count
                // raised; this frame gets its result when it returns, which delivers then.
                .batch => |operand| {
                    const body = locals[operand].callable;
                    if (referencePush(p, .{ .function = body.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures }, p.function_arguments, locals, members[0..member_count.*], destination, frames)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
                    referenceMarked(frames, pool, source);
                    frames.live.batch += 1;
                    continue;
                },
                .merge => |m| value = retyped(locals[if (locals[m.begin].boolean) m.left else m.right], node.value_type),
                .native_call => |c| value = switch (referenceNative(c, node.value_type, locals, p, members, member_count, pool, key_work, &control.effects, frames.scheduler.now, remaining)) {
                    .ok => |result| result,
                    .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                },
                .self_value => value = .{ .callable = .{ .value_type = node.value_type, .function = frame.function } },
                .invoke => {
                    const child = node.invocationWith(frame.function, locals).?.call;
                    if (referencePush(p, child, p.function_arguments, locals, members[0..member_count.*], destination, frames)) |code| return .{ .failed = .{ .span = node.span, .code = code } };

                    referenceMarked(frames, pool, source);
                    continue;
                },
                .recur => |arguments| {
                    const child: types.ResolvedCall = .{ .function = frame.function, .arguments = arguments };
                    if (referencePush(p, child, p.function_arguments, locals, members[0..member_count.*], destination, frames)) |code| return .{ .failed = .{ .span = node.span, .code = code } };

                    referenceMarked(frames, pool, source);
                    continue;
                },
                .call => |child| {
                    if (referencePush(p, .{ .function = child.function, .arguments = child.arguments }, p.function_arguments, locals, members[0..member_count.*], destination, frames)) |code| return .{ .failed = .{ .span = node.span, .code = code } };

                    referenceMarked(frames, pool, source);
                    continue;
                },
                .iterate, .iterate_value, .loop => switch (referenceStart(p, node.invocationWith(frame.function, locals).?, p.function_arguments, locals, members[0..member_count.*], destination, frames, remaining)) {
                    .pushed => {
                        referenceMarked(frames, pool, source);
                        continue;
                    },
                    .immediate => |initial| value = initial,
                    .failed => |code| return .{ .failed = .{ .span = node.span, .code = code } },
                },
                .bind => |b| {
                    const original = locals[b.callable].callable;
                    const old = original.captures.end - original.captures.start;
                    const count = old + b.arguments.end - b.arguments.start;
                    if (count > @min(members.len, types.limits.aggregate_elements) - member_count.*) return .{ .failed = .{ .span = node.span, .code = .aggregate_limit } };
                    const capture_range: types.Span = .{ .start = @intCast(member_count.*), .end = @intCast(member_count.* + count) };
                    std.debug.assert(original.captures.end <= member_count.* and count <= types.limits.parameters);
                    @memcpy(members[capture_range.start .. capture_range.start + old], members[original.captures.start..original.captures.end]);
                    for (p.function_arguments[b.arguments.start..b.arguments.end], members[capture_range.start + old .. capture_range.end]) |operand, *out| out.* = locals[operand];
                    member_count.* = capture_range.end;
                    value = .{ .callable = .{ .value_type = node.value_type, .function = original.function, .captures = capture_range } };
                },
                .aggregate => |range| {
                    const count = range.end - range.start;
                    if (count > @min(members.len, types.limits.aggregate_elements) - member_count.*) return .{ .failed = .{ .span = node.span, .code = .aggregate_limit } };
                    const physical: types.Span = .{ .start = @intCast(member_count.*), .end = @intCast(member_count.* + count) };
                    for (p.function_members[range.start..range.end], members[physical.start..physical.end]) |operand, *output| output.* = locals[operand];
                    if (catalogue.entryShape(node.value_type, p.definitions) != null) keys.unique(key_work, members, members[physical.start..physical.end], remaining) catch |err| return .{ .failed = .{ .span = node.span, .code = keyCode(err) } };
                    member_count.* = physical.end;
                    value = .{ .aggregate = .{ .value_type = node.value_type, .elements = physical } };
                },
                else => value = evaluateNode(node, cursor, locals, p, members, member_count, pool, key_work, remaining, array_concat.contextOf(frames.marks[frames.depth - 1], control.root_ended, control.root_end.members, frames.switch_marks[frames.depth - 1] != frames.scheduler.switches, frames.scheduler.frames_live != 0)) catch |err| return .{ .failed = .{ .span = node.span, .code = switch (err) {
                    error.InvalidIr => .invalid_ir,
                    error.Overflow => .arithmetic_overflow,
                    error.DivisionByZero => .division_by_zero,
                    error.IndexRange => .index_out_of_range,
                    error.AggregateLimit => .aggregate_limit,
                    error.NativeFailed => .native_failed,
                    error.StringLimit => .string_limit,
                    error.InvalidNative => .invalid_native,
                    error.WorkLimit => .work_limit,
                    error.DuplicateKey => .duplicate_map_key,
                    error.ScratchUnavailable => .scratch_unavailable,
                } } },
            },
        }
        if (tracing) {
            control.calls[control.call_count] = .{ .function = frame.function, .pc = cursor, .value = value };
            control.call_count += 1;
            // A native may build strings its result does not name; a replay is told where the
            // pool ends after each one.
            if (control.trace_sink != null and entry.input == .operation and (node.kind == .native_call or node.kind == .json_decode)) control.foldCalls(members[0..member_count.*]);
        }
        frames.values[destination] = value;
        // A region that committed to depth 0 here hands its starts their turns (RFC-0082).
        if (drain) frames.drain_spans[frames.depth - 1] = node.span;
        if (drain) if (referenceDrainFrom(p, s, frames, control, members[0..member_count.*], pool, source, root_pc, remaining)) |code| return .{ .failed = .{ .span = node.span, .code = code } };
        // RFC-0084, P4.4: what this node notified is delivered now, unless held back; after a
        // drain it begins, it is delivered when the drain ends.
        if (point and !drain and frames.live.on) {
            const run: LiveRun = .{ .p = p, .roots = roots, .members = members, .member_count = member_count, .pool = pool, .key_work = key_work, .frames = frames, .control = control, .source = source.?, .remaining = remaining, .root_pc = root_pc, .span = node.span, .return_to = 0 };
            switch (referenceDeliveryPoint(&run)) {
                .fired, .done => {},
                .failed => |diagnostic| return .{ .failed = diagnostic },
            }
        }
    }
    unreachable;
}

/// What a frame or loop visit of a traced call leaves behind is reclaimed where it ends: the
/// members, the run strings and the class instances the frame built that nothing can reach any
/// more (`ControlStorage.reclaim_floor`). The frame built everything above the three marks
/// taken when it was pushed, and its registers are dead. What is still in use above the marks
/// is what can be reached from the value the frame hands on (the next loop state, or the
/// result), from the cells that existed before the frame (the program's own and those of older
/// instances, which the frames below may still name), from an instance an open region holds a
/// record for, and, for strings, from the failure traces.
///
/// Nothing else names anything above the marks. Callers' registers, captures and the states of
/// enclosing loops were made before the marks were taken. So was everything a rollback
/// restores: every region still open was opened before the frame was pushed, a record or an
/// image holds what its cell held when its region began, and a rollback forgets every cell
/// created since, which includes all the cells above the frame's mark. (A record for a cell
/// created inside its own region can hold a newer value; the rollback that would use it
/// forgets the cell.)
///
/// Members name only members below them, but an instance names whatever was last written to
/// it, so reachability is a walk and not one pass: members wait on a stack, instances on a
/// list threaded through their own entries, and `skip` leads from any member to the next one
/// not yet reached, so that a span costs what it adds however often and however overlapped
/// it is named.
///
/// What is reachable slides down to its mark in order, in all three stores, and every value
/// that names it is rewritten: spans, instance ids and string addresses. Order is what makes
/// the layout a function of the reachable set alone; the VM and the report replay reach the
/// same one in their own code.
const ReferenceReclaim = struct {
    p: types.Program,
    members: []types.Value,
    mark: u32,
    cells: []source_state.Cell,
    cell_mark: u32,
    /// The string pool: its address, the frame's mark and the bytes in use.
    origin: usize,
    text_mark: u32,
    text_top: u32,
    /// Per member above the mark, while reachability is worked out: itself when it has not
    /// been reached, and otherwise a later member, towards the next that has not. Afterwards:
    /// how many reachable members lie below it.
    skip: []u32,
    /// Per cell above the mark. While reachability is worked out, the entry of an instance's
    /// first cell says whether it was reached and that of its second links the instances whose
    /// fields are still to be read. Afterwards: 0 for a cell that goes, and otherwise one more
    /// than its place above the mark.
    slots: []u32,
    list: []u32,
    starts: []u64,
    ranks: []u32,
    pending: usize = 0,
    waiting: u32 = nobody,
    /// The scheduler, whose values are roots.
    tasks: *call_frames.ReferenceScheduler,
    /// RFC-0082, P3.5: whether the frame that ends saw another task run, so that the suspended
    /// frames' values are roots too, and the links that say which registers they are.
    links: []const u32 = &.{},
    across: bool = false,
    /// The live store of a live run (RFC-0084): a record that reads a cell that stays, stays.
    live: ?*const call_frames.ReferenceLive = null,

    const nobody = std.math.maxInt(u32);

    fn instanceCells(self: *const ReferenceReclaim, offset: u32) u32 {
        const header = self.cells[self.cell_mark + offset];
        std.debug.assert(header.initialized and header.value == .integer);
        return catalogue.classCells(@fromBackingInt(@intCast(header.value.integer)), self.p.definitions).?;
    }
    /// The first member at or after `from` that has not been reached, or the end.
    fn next(self: *ReferenceReclaim, from: u32) u32 {
        var end = from;
        while (self.skip[end] != end) end = self.skip[end];
        // Everything passed on the way now leads there directly.
        var at = from;
        while (self.skip[at] != end and at != end) {
            const after = self.skip[at];
            self.skip[at] = end;
            at = after;
        }
        return end;
    }
    fn follow(self: *ReferenceReclaim, value: types.Value) void {
        switch (value) {
            .aggregate => |aggregate| self.followSpan(aggregate.elements),
            .callable => |callable| self.followSpan(callable.captures),
            .object => |object| self.followInstance(object.id),
            else => {},
        }
    }
    fn followSpan(self: *ReferenceReclaim, span: types.Span) void {
        if (span.start == span.end or span.end <= self.mark) return;
        std.debug.assert(span.start < span.end and span.end <= self.members.len);
        // A span that began below the mark and grew in place is reachable from the mark upwards.
        const end = span.end - self.mark;
        var at = self.next(span.start -| self.mark);
        while (at < end) : (at = self.next(at + 1)) {
            self.skip[at] = at + 1;
            switch (self.members[self.mark + at]) {
                .aggregate, .callable, .object => {
                    self.list[self.pending] = at;
                    self.pending += 1;
                },
                else => {},
            }
        }
        // The room that begins where an array in use ends stays behind it (`array_concat`): the
        // array grows into it as it would have without this reclamation, for the same fuel.
        if (span.end < self.members.len) if (array_concat.placeholderLimit(self.members[span.end])) |limit| {
            std.debug.assert(limit < self.members.len);
            at = self.next(end);
            while (at <= limit - self.mark) : (at = self.next(at + 1)) self.skip[at] = at + 1;
        };
    }
    fn followInstance(self: *ReferenceReclaim, id: u32) void {
        if (id < self.cell_mark) return;
        std.debug.assert(id < self.cells.len);
        const offset = id - self.cell_mark;
        if (self.slots[offset] != 0) return;
        self.slots[offset] = 1;
        // An instance without fields names nothing.
        if (self.instanceCells(offset) == 1) return;
        self.slots[offset + 1] = self.waiting;
        self.waiting = offset;
    }
    /// An instance one of whose cells an open region holds a record for stays, so that the
    /// record keeps its cell. Such an instance was created inside that region; a rollback
    /// forgets it, and until then it is counted as in use.
    fn followHeld(self: *ReferenceReclaim, state: *const source_state.ReferenceState) void {
        var offset: u32 = 0;
        while (offset < self.slots.len) {
            const count = self.instanceCells(offset);
            for (self.cell_mark + offset..self.cell_mark + offset + count) |cell| if (state.holds(cell)) {
                self.followInstance(self.cell_mark + offset);
                break;
            };
            offset += count;
        }
    }
    fn drain(self: *ReferenceReclaim) void {
        while (true) {
            if (self.pending != 0) {
                self.pending -= 1;
                self.follow(self.members[self.mark + self.list[self.pending]]);
            } else if (self.waiting != nobody) {
                const offset = self.waiting;
                self.waiting = self.slots[offset + 1];
                const count = self.instanceCells(offset);
                for (self.cells[self.cell_mark + offset + 1 ..][0 .. count - 1], self.cell_mark + offset + 1..) |cell, id| {
                    self.follow(cell.value);
                    // A field's link reaches its record (RFC-0084), and so does a record that
                    // reads the field, which a write of it would evaluate (C24).
                    if (cell.link != source_state.no_link) self.followInstance(cell.link);
                    if (self.live) |store| {
                        var readers = live_reference.Readers.of(store, @intCast(id));
                        while (readers.next()) |record| self.followInstance(record);
                    }
                }
            } else break;
        }
    }
    /// Turns `skip` into the number of reachable members below each position; returns how many
    /// there are.
    fn forwardMembers(self: *ReferenceReclaim) u32 {
        var kept: u32 = 0;
        for (self.skip[0 .. self.skip.len - 1], 0..) |*slot, index| {
            const reached = slot.* != index;
            slot.* = kept;
            kept += @intFromBool(reached);
        }
        self.skip[self.skip.len - 1] = kept;
        return kept;
    }
    /// Turns `slots` into the place of each cell that stays; returns how many there are.
    fn forwardCells(self: *ReferenceReclaim) u32 {
        var kept: u32 = 0;
        var offset: u32 = 0;
        while (offset < self.slots.len) {
            const count = self.instanceCells(offset);
            const reached = self.slots[offset] != 0;
            for (self.slots[offset..][0..count], 0..) |*slot, index| slot.* = if (reached) kept + @as(u32, @intCast(index)) + 1 else 0;
            if (reached) kept += count;
            offset += count;
        }
        return kept;
    }
    /// Calls `visit` for every value that is still in use and can name something above a mark:
    /// the handed-on value, the reasons of the failure traces, the older cells, the cells of the
    /// instances that stay and the members that stay. Only valid once the forwards are known.
    fn each(self: *ReferenceReclaim, root: *types.Value, traces: []types.FailureTrace, comptime visit: fn (*ReferenceReclaim, *types.Value) void) void {
        visit(self, root);
        self.eachTask(visit);
        if (self.across) self.eachSaved(visit);
        for (traces) |*trace| if (trace.reason) |reason| {
            var value: types.Value = .{ .string = reason };
            visit(self, &value);
            trace.reason = value.string;
        };
        for (self.cells[0..self.cell_mark]) |*cell| visit(self, &cell.value);
        var offset: u32 = 0;
        while (offset < self.slots.len) {
            const count = self.instanceCells(offset);
            if (self.slots[offset] != 0) for (self.cells[self.cell_mark + offset ..][0..count]) |*cell| visit(self, &cell.value);
            offset += count;
        }
        for (0..self.skip.len - 1) |index| {
            if (self.skip[index + 1] != self.skip[index]) visit(self, &self.members[self.mark + index]);
        }
    }
    /// The values the scheduler holds (RFC-0082): the handle of every live task, and the closure
    /// of every task that has not started. From P3.2 also the value a ready task resumes with,
    /// the event or handle a waiting task names, and the event and value of every signal that
    /// is held or committed and not yet carried out.
    fn eachTask(self: *ReferenceReclaim, comptime visit: fn (*ReferenceReclaim, *types.Value) void) void {
        for (self.tasks.tasks[0..self.tasks.used]) |*task| {
            if (task.state == .free) continue;
            // An arm has no handle; a completed one holds its result for its expression (P3.3).
            if (task.kind == .spawn or reactionTask(task)) visit(self, &task.handle);
            if (task.state == .settled and task.completed) visit(self, &task.result);
            if (task.state == .pending or task.state == .queued) visit(self, &task.closure);
            // A reaction holds its guard and its body while it lives (RFC-0084, P4.4).
            if (reactionTask(task) and task.state != .pending and task.state != .queued) visit(self, &task.closure);
            if (reactionTask(task)) visit(self, &task.body);
            if (task.state == .ready) visit(self, &task.resume_value);
            if (task.state == .waiting and (task.wait == .event or task.wait == .task)) visit(self, &task.target);
        }
        var at = self.tasks.action_head;
        while (at < self.tasks.action_count) : (at += 1) {
            const place = at % types.limits.scheduler_actions;
            if (self.tasks.actions[place] != no_task) continue;
            visit(self, &self.tasks.signals[place].event);
            visit(self, &self.tasks.signals[place].value);
        }
    }
    fn followValue(self: *ReferenceReclaim, value: *types.Value) void {
        self.follow(value.*);
    }
    /// RFC-0082, P3.5: every value a suspended frame holds, for `visit`: its parameters (an
    /// iteration's seed is its last), and its registers available where it stands, the node of
    /// its site or call. A frame waiting at its end holds only its result, or nothing when it
    /// ends cancelled.
    fn eachSaved(self: *ReferenceReclaim, comptime visit: fn (*ReferenceReclaim, *types.Value) void) void {
        const s = self.tasks;
        var slot = s.oldest;
        while (slot != no_task) : (slot = s.tasks[slot].newer) {
            const task = &s.tasks[slot];
            const registers = s.saved_values[task.value_start..][0..task.value_count];
            var parameter_at = task.value_start + task.value_count;
            for (s.saved[task.frame_start..][0..task.frame_count], 0..) |saved, index| {
                const f = self.p.functions[saved.function];
                for (s.saved_values[parameter_at..][0..f.parameter_count]) |*parameter| visit(self, parameter);
                parameter_at += f.parameter_count;
                const length = f.body.end - f.body.start;
                if (index + 1 == task.frame_count and task.wait == .frame_end) {
                    if (!saved.canceled_end) visit(self, &registers[saved.base + f.root]);
                    continue;
                }
                std.debug.assert(saved.cursor >= 1 and saved.cursor <= length);
                var register = self.links[f.body.start + saved.cursor - 1];
                while (register != reference_no_link) : (register = self.links[f.body.start + register]) visit(self, &registers[saved.base + register]);
            }
        }
    }
    /// The string mark of every suspended frame, as the empty string at its place, for `visit`,
    /// which may move it.
    fn eachSavedMark(self: *ReferenceReclaim, comptime visit: fn (*ReferenceReclaim, *types.Value) void) void {
        const s = self.tasks;
        var slot = s.oldest;
        while (slot != no_task) : (slot = s.tasks[slot].newer) {
            const task = &s.tasks[slot];
            for (s.saved[task.frame_start..][0..task.frame_count]) |*saved| {
                var value: types.Value = .{ .string = @as([*]const u8, @ptrFromInt(self.origin + saved.string_mark))[0..0] };
                visit(self, &value);
                saved.string_mark = @intCast(@intFromPtr(value.string.ptr) - self.origin);
            }
        }
    }
    /// After `settle`: the suspended frames' member and cell marks above the reclaiming ones
    /// become what stays below them, and their string marks move as empty strings do. Before
    /// the cells move: their headers are still where they were.
    fn settleSaved(self: *ReferenceReclaim) void {
        if (self.text_top != self.text_mark) self.eachSavedMark(settle);
        const s = self.tasks;
        // The cells that stay below each instance above the mark, and below the top, in `list`,
        // which the strings no longer need.
        const span: u32 = @intCast(self.slots.len);
        var kept: u32 = 0;
        var offset: u32 = 0;
        while (offset < span) {
            const count = self.instanceCells(offset);
            self.list[offset] = kept;
            if (self.slots[offset] != 0) kept += count;
            offset += count;
        }
        self.list[span] = kept;
        var slot = s.oldest;
        while (slot != no_task) : (slot = s.tasks[slot].newer) {
            const task = &s.tasks[slot];
            for (s.saved[task.frame_start..][0..task.frame_count]) |*saved| {
                self.settleSpan(&saved.captures);
                if (saved.mark > self.mark) saved.mark = self.mark + self.skip[saved.mark - self.mark];
                if (saved.cell_mark > self.cell_mark) saved.cell_mark = self.cell_mark + self.list[saved.cell_mark - self.cell_mark];
            }
        }
    }
    /// The members a suspended frame's closure captured, which it reads again at each visit.
    fn followSavedCaptures(self: *ReferenceReclaim) void {
        const s = self.tasks;
        var slot = s.oldest;
        while (slot != no_task) : (slot = s.tasks[slot].newer) {
            const task = &s.tasks[slot];
            for (s.saved[task.frame_start..][0..task.frame_count]) |saved| self.followSpan(saved.captures);
        }
    }
    fn followTasks(self: *ReferenceReclaim) void {
        for (self.tasks.tasks[0..self.tasks.used]) |*task| {
            if (task.state == .free) continue;
            if (task.kind == .spawn or reactionTask(task)) self.follow(task.handle);
            if (task.state == .settled and task.completed) self.follow(task.result);
            if (task.state == .pending or task.state == .queued or reactionTask(task)) self.follow(task.closure);
            if (reactionTask(task)) self.follow(task.body);
            if (task.state == .ready) self.follow(task.resume_value);
            if (task.state == .waiting and (task.wait == .event or task.wait == .task)) self.follow(task.target);
        }
        var at = self.tasks.action_head;
        while (at < self.tasks.action_count) : (at += 1) {
            const place = at % types.limits.scheduler_actions;
            if (self.tasks.actions[place] != no_task) continue;
            self.follow(self.tasks.signals[place].event);
            self.follow(self.tasks.signals[place].value);
        }
    }
    /// Where in the pool a string lies when it names a byte above the mark or is an empty
    /// string placed above it: its offset and its end. An empty string moves with the place it
    /// stands at, so that it stays inside the pool.
    fn text(self: *const ReferenceReclaim, value: []const u8) ?[2]u32 {
        const offset = @intFromPtr(value.ptr) -% self.origin;
        if (offset > self.text_top or offset + value.len <= self.text_mark) return null;
        std.debug.assert(offset + value.len <= self.text_top);
        return .{ @intCast(offset), @intCast(offset + value.len) };
    }
    /// The bit for the place a string starts at, or for the mark when it starts below it: the
    /// bytes below the mark stay where they are.
    fn startBit(self: *const ReferenceReclaim, offset: u32) u32 {
        return @max(offset, self.text_mark) - self.text_mark;
    }
    fn rank(self: *const ReferenceReclaim, bit: u32) u32 {
        const below = (@as(u64, 1) << @intCast(bit % 64)) - 1;
        return self.ranks[bit / 64] + @popCount(self.starts[bit / 64] & below);
    }
    fn noteStart(self: *ReferenceReclaim, value: *types.Value) void {
        if (value.* != .string) return;
        const place = self.text(value.string) orelse return;
        const bit = self.startBit(place[0]);
        self.starts[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
    }
    /// The furthest end among the strings that start at one place.
    fn noteEnd(self: *ReferenceReclaim, value: *types.Value) void {
        if (value.* != .string) return;
        const place = self.text(value.string) orelse return;
        const index = self.rank(self.startBit(place[0]));
        self.list[index] = @max(self.list[index], place[1]);
    }
    /// Numbers the places strings start at, in order; returns how many there are.
    fn rankStarts(self: *ReferenceReclaim) u32 {
        const words = (self.text_top - self.text_mark) / 64 + 1;
        var count: u32 = 0;
        for (self.starts[0..words], self.ranks[0..words]) |word, *before| {
            before.* = count;
            count += @popCount(word);
        }
        return count;
    }
    fn settle(self: *ReferenceReclaim, value: *types.Value) void {
        switch (value.*) {
            .aggregate => |*aggregate| self.settleSpan(&aggregate.elements),
            .callable => |*callable| self.settleSpan(&callable.captures),
            .object => |*object| if (object.id >= self.cell_mark) {
                std.debug.assert(self.slots[object.id - self.cell_mark] != 0);
                object.id = self.cell_mark + self.slots[object.id - self.cell_mark] - 1;
            },
            .string => |*string| if (self.text_top != self.text_mark) {
                const place = self.text(string.*) orelse return;
                if (place[0] > self.text_mark) string.ptr = @ptrFromInt(self.origin + self.list[self.rank(place[0] - self.text_mark)]);
            },
            else => {},
        }
    }
    /// The ends of an empty span move the same way, so that it stays inside the pool.
    fn settleSpan(self: *const ReferenceReclaim, span: *types.Span) void {
        if (span.start > self.mark and span.start <= self.members.len) span.start = self.mark + self.skip[span.start - self.mark];
        if (span.end > self.mark and span.end <= self.members.len) span.end = self.mark + self.skip[span.end - self.mark];
    }
};
noinline fn referenceReclaim(p: types.Program, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, source: ?*source_state.ReferenceState, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, root: *types.Value) void {
    // Rare by construction, and kept out of the frame loop it is called from.
    @branchHint(.cold);
    const top: u32 = @intCast(member_count.*);
    const cells: []source_state.Cell = if (source) |state| state.cells[0..state.cell_count] else &.{};
    const now = referenceUsage(top, pool, source);
    // RFC-0082, P3.5: after a switch, above the marks `referenceReclaimMarks` gives, with the
    // suspended frames' values as roots.
    const across = frames.switch_marks[frames.depth - 1] != frames.scheduler.switches;
    const before = referenceReclaimMarks(frames, control);
    const mark: u32 = @intCast(before.members);
    const cell_mark: u32 = @intCast(before.cells);
    const text_mark: u32 = @intCast(before.strings);
    std.debug.assert(mark <= top and top <= members.len and top <= types.limits.aggregate_elements and cell_mark <= cells.len and text_mark <= pool.used and text_mark >= pool.base);
    // Switches are made outside every region: none is open at the end of such a frame.
    std.debug.assert(!across or (control.effects.depth == 0 and (source == null or source.?.undo_count == 0)));
    if (across and !frames.links_ready) referenceLinks(p, frames);
    // A sink checks the steps it has not seen against the pools they were recorded with.
    control.foldCalls(members[0..top]);
    if (builtin.mode == .debug) if (source) |state| state.assertRestoresBelow(mark, cell_mark, pool.origin + text_mark);
    const work = &frames.reclaim_work;
    const size = top - mark;
    var pass: ReferenceReclaim = .{
        .p = p,
        .members = members[0..top],
        .mark = mark,
        .cells = cells,
        .cell_mark = cell_mark,
        .origin = @intFromPtr(pool.origin),
        .text_mark = text_mark,
        .text_top = @intCast(pool.used),
        .skip = frames.reclaim[0 .. size + 1],
        .slots = work.cells[0 .. cells.len - cell_mark],
        .list = &work.list,
        .starts = &work.starts,
        .ranks = &work.ranks,
        .tasks = &frames.scheduler,
        .links = if (across) frames.links[0..p.function_nodes.len] else &.{},
        .across = across,
    };
    for (pass.skip, 0..) |*slot, index| slot.* = @intCast(index);
    @memset(pass.slots, 0);
    pass.follow(root.*);
    pass.followTasks();
    if (across) {
        pass.eachSaved(ReferenceReclaim.followValue);
        pass.followSavedCaptures();
    }
    for (cells[0..cell_mark]) |cell| pass.follow(cell.value);
    // RFC-0084: a cell's link reaches its record, which reaches its guard. A record that reads a
    // cell below the mark stays: a write of the cell would evaluate it (C24). What failed
    // regions left is undone first, so that the lists hold the valid entries.
    if (frames.live.on) {
        live_reference.beforeReclaim(&frames.live, source.?);
        for (cells[0..cell_mark]) |cell| if (cell.link != source_state.no_link) pass.followInstance(cell.link);
        for (frames.live.entries[0..frames.live.entry_count]) |entry| if (entry.listed and entry.cell < cell_mark and entry.record & call_frames.observer_entry == 0) pass.followInstance(entry.record);
        pass.live = &frames.live;
    }
    if (source) |state| pass.followHeld(state);
    pass.drain();
    const kept = pass.forwardMembers();
    const kept_cells = pass.forwardCells();
    // The entries name cells and records where they are now: they move, or go, first.
    if (frames.live.on) live_reference.relocate(&frames.live, source.?, cell_mark, pass.slots);
    const measured = if (source) |state| live_reference.measure(&frames.live, state) else 0;
    // The strings: where they start, how far they reach from there, and where each start goes.
    const traces = control.traces[0..control.trace_count];
    var text_kept = pass.text_top;
    var text_newest = true;
    if (pass.text_top != text_mark) {
        @memset(pass.starts[0 .. (pass.text_top - text_mark) / 64 + 1], 0);
        pass.each(root, traces, ReferenceReclaim.noteStart);
        if (across) pass.eachSavedMark(ReferenceReclaim.noteStart);
        const places = pass.rankStarts();
        @memset(pass.list[0..places], 0);
        pass.each(root, traces, ReferenceReclaim.noteEnd);
        if (across) pass.eachSavedMark(ReferenceReclaim.noteEnd);
        const slid = referenceSlide(&pass, @constCast(pool.origin));
        text_kept = slid.kept;
        text_newest = slid.newest;
    }
    // Every value still in use reads as it will once everything has moved; then it moves.
    pass.each(root, traces, ReferenceReclaim.settle);
    // P3.5: and so do the suspended frames' marks above these, each to the number of what stays
    // below its old place.
    if (across) pass.settleSaved();
    for (0..size) |offset| {
        if (pass.skip[offset + 1] == pass.skip[offset]) continue;
        members[mark + pass.skip[offset]] = members[mark + offset];
    }
    if (source) |state| state.relocate(cell_mark, pass.slots);
    if (frames.live.on) {
        // Links name records by their first cell, which may have moved.
        for (source.?.cells[0..source.?.cell_count]) |*cell| if (cell.link != source_state.no_link and cell.link >= cell_mark) {
            cell.link = cell_mark + pass.slots[cell.link - cell_mark] - 1;
        };
        live_reference.relink(&frames.live);
    }
    member_count.* = mark + kept;
    pool.stale = run_strings.staleAfter(pool.stale, pool.used, text_kept, text_newest);
    pool.used = text_kept;
    std.debug.assert(reach(root.*) <= member_count.*);
    control.reclaimed(now, .{ .members = mark + kept, .strings = text_kept, .cells = cell_mark + kept_cells }, types.ControlStorage.reclaimExamined(now, before, (if (source) |state| state.undo_count + measured else 0) + referenceAcross(frames)), frames.depth, frames.scheduler.switches);
}
/// RFC-0082, P3.5: the marks the newest frame's end reclaims above. Its own, when no other task
/// ran since its push (the P3.1 rule); otherwise its own or the stores' sizes when the root
/// ended, whichever is more.
inline fn referenceReclaimMarks(frames: *const call_frames.ReferenceStorage, control: *const types.ControlStorage) types.ControlStorage.Usage {
    const marks = referenceMarks(frames);
    return if (frames.switch_marks[frames.depth - 1] == frames.scheduler.switches) marks else control.acrossMarks(marks);
}
/// What rooting the suspended frames adds to the measure of a reclamation by the newest frame:
/// nothing without a switch, and otherwise the saved frames, registers and parameters.
inline fn referenceAcross(frames: *const call_frames.ReferenceStorage) u64 {
    const s = &frames.scheduler;
    if (frames.switch_marks[frames.depth - 1] == s.switches) return 0;
    return @as(u64, s.frames_live) + s.values_live;
}
/// For each body node, the newest register before it that is available there, read off the
/// structure of the nodes: the node before it, unless that one opens an arm (then what was
/// available at it), or is the `otherwise` that closes the first arm (what was available at the
/// arm's `if_begin`); and for a merge, what was available at its `if_begin`. `no_link` for none.
fn referenceLinks(p: types.Program, frames: *call_frames.ReferenceStorage) void {
    const links = frames.links[0..p.function_nodes.len];
    for (p.functions) |f| {
        const body = p.function_nodes[f.body.start..f.body.end];
        const own = links[f.body.start..f.body.end];
        for (body, own, 0..) |entry, *link, index| {
            if (entry.node.kind == .merge) {
                link.* = own[entry.node.kind.merge.begin];
            } else if (index == 0) {
                link.* = reference_no_link;
            } else switch (body[index - 1].node.kind) {
                .if_begin, .attempt_begin => link.* = own[index - 1],
                .otherwise => |begin| link.* = own[begin],
                else => link.* = @intCast(index - 1),
            }
        }
    }
    frames.links_ready = true;
}
const reference_no_link = std.math.maxInt(u32);
/// Slides the bytes that strings still name down to the mark. Going up through the places
/// strings start at, a run of bytes in use lasts as long as the next start lies inside the
/// furthest end seen so far. Each start is left with the place it went to. `bytes` is the
/// pool's writable address. Returns the bytes in use afterwards, and whether a string still in
/// use names the last byte before the reclamation, so that the newest string still ends the
/// pool (c7-1).
fn referenceSlide(pass: *ReferenceReclaim, bytes: [*]u8) struct { kept: u32, newest: bool } {
    var newest = false;
    const words = (pass.text_top - pass.text_mark) / 64 + 1;
    var shift: u32 = 0;
    var run_start = pass.text_mark;
    var run_end = pass.text_mark;
    var index: usize = 0;
    for (pass.starts[0..words], 0..) |word, position| {
        var bits = word;
        while (bits != 0) : (bits &= bits - 1) {
            const start = pass.text_mark + @as(u32, @intCast(position * 64 + @ctz(bits)));
            const end = pass.list[index];
            std.debug.assert(end >= start and end <= pass.text_top);
            if (end == pass.text_top and end > start) newest = true;
            if (start >= run_end) {
                // The run before this one is complete, and this one begins where that one ends
                // once it has moved.
                if (shift != 0) std.mem.copyForwards(u8, bytes[run_start - shift .. run_end - shift], bytes[run_start..run_end]);
                shift = start - (run_end - shift);
                run_start = start;
                run_end = end;
            } else run_end = @max(run_end, end);
            pass.list[index] = start - shift;
            index += 1;
        }
    }
    if (shift != 0) std.mem.copyForwards(u8, bytes[run_start - shift .. run_end - shift], bytes[run_start..run_end]);
    return .{ .kept = run_end - shift, .newest = newest };
}
/// What the run holds of the three stores a reclamation compacts.
inline fn referenceUsage(member_count: usize, pool: *const run_strings.Pool, source: ?*const source_state.ReferenceState) types.ControlStorage.Usage {
    return .{ .members = member_count, .strings = pool.used, .cells = if (source) |state| state.cell_count else 0 };
}
/// What it held when the newest frame was pushed.
inline fn referenceMarks(frames: *const call_frames.ReferenceStorage) types.ControlStorage.Usage {
    return .{ .members = frames.marks[frames.depth - 1], .strings = frames.string_marks[frames.depth - 1], .cells = frames.cell_marks[frames.depth - 1] };
}
/// Completes the marks of the frame just pushed, whose member mark `referencePush` took.
inline fn referenceMarked(frames: *call_frames.ReferenceStorage, pool: *const run_strings.Pool, source: ?*const source_state.ReferenceState) void {
    frames.string_marks[frames.depth - 1] = @intCast(pool.used);
    frames.cell_marks[frames.depth - 1] = if (source) |state| @intCast(state.cell_count) else 0;
    // RFC-0082: the switch count it was pushed at, and no task of its own until one starts.
    frames.switch_marks[frames.depth - 1] = frames.scheduler.switches;
    frames.task_marks[frames.depth - 1] = no_task;
    frames.handoffs[frames.depth - 1] = false;
    frames.drains[frames.depth - 1] = false;
    // P3.4: and owns no task.
    frames.owned_firsts[frames.depth - 1] = no_task;
    frames.owned_lasts[frames.depth - 1] = no_task;
    frames.canceled_ends[frames.depth - 1] = false;
}
/// One past the highest member a value names, or 0 for a value that names none.
fn reach(value: types.Value) u32 {
    const span = switch (value) {
        .aggregate => |aggregate| aggregate.elements,
        .callable => |callable| callable.captures,
        else => return 0,
    };
    return if (span.start == span.end) 0 else span.end;
}

// IR admission compares all signature components independently of lowering.
fn signatureMatches(p: types.Program, value_type: types.Type, f: types.RuntimeFunction) bool {
    const shape = catalogue.definition(value_type, p.definitions) orelse return false;
    if (shape != .callable or shape.callable.result != f.value_type or shape.callable.transacts != f.transacts or shape.callable.decides != f.decides or @as(u8, @bitCast(shape.callable.detail)) != @as(u8, @bitCast(f.detail))) return false;
    const parameters = catalogue.definition(shape.callable.parameters, p.definitions) orelse return false;
    if (parameters != .tuple or !validSpan(parameters.tuple, p.tuple_elements.len) or parameters.tuple.end - parameters.tuple.start != f.parameter_count or f.parameter_count > types.limits.parameters) return false;
    return std.mem.eql(types.Type, p.tuple_elements[parameters.tuple.start..parameters.tuple.end], f.parameters[0..f.parameter_count]);
}
fn needsSource(p: types.Program) bool {
    if (p.source_ops != 0) return true;
    for (p.nodes) |node| {
        if (node.kind == .invoke or node.kind == .iterate_value or node.kind == .loop) {
            const operand = if (node.kind == .invoke) node.kind.invoke.callable else if (node.kind == .iterate_value) node.kind.iterate_value.callable else node.kind.loop.callable;
            if (catalogue.definition(p.nodes[operand].value_type, p.definitions).?.callable.transacts) return true;
        }
        // RFC-0084, P4.5: so does the body of a batch.
        if (node.kind == .batch and catalogue.definition(p.nodes[node.kind.batch].value_type, p.definitions).?.callable.transacts) return true;
        if (node.invocation()) |i| if (p.functions[i.target()].has_source) return true;
    }
    return false;
}

fn validGenericFunction(p: types.Program, f: types.RuntimeFunction, comparable: []const bool) bool {
    const key = f.specialization orelse {
        if (f.template_public or f.generic_source.start != 0 or f.generic_source.end != 0) return false;
        if (!f.anonymous) {
            const suffix = p.source[f.name.end..];
            var at: usize = 0;
            skipGenericFunctionSpace(suffix, &at);
            if (at < suffix.len and suffix[at] == '<') {
                at += 1;
                skipGenericFunctionSpace(suffix, &at);
                // `<public>` or `<internal>` (RFC-0074) stands between the name and a generic header.
                const word: usize = if (std.mem.startsWith(u8, suffix[at..], "public")) 6 else if (std.mem.startsWith(u8, suffix[at..], "internal")) 8 else 0;
                if (word != 0) {
                    at += word;
                    skipGenericFunctionSpace(suffix, &at);
                    if (at < suffix.len and suffix[at] == '>') at += 1;
                    skipGenericFunctionSpace(suffix, &at);
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
    skipGenericFunctionSpace(source, &at);
    // A generic method (RFC-0081) may also say `<private>`, `<protected>` and `<final>`.
    var specifiers: usize = 0;
    while (at < source.len and source[at] == '<') : (specifiers += 1) {
        if (specifiers == 2) return false;
        at += 1;
        skipGenericFunctionSpace(source, &at);
        // `<internal>` says what no specifier means (RFC-0074): the template is not public.
        const word = genericSpecifier(source[at..]) orelse return false;
        if (std.mem.eql(u8, word, "public")) {
            if (source_public) return false;
            source_public = true;
        }
        at += word.len;
        skipGenericFunctionSpace(source, &at);
        if (at == source.len or source[at] != '>') return false;
        at += 1;
        skipGenericFunctionSpace(source, &at);
    }
    if (f.template_public != (!f.anonymous and source_public)) return false;
    if (at == source.len or source[at] != '[') return false;
    at += 1;
    var names: [types.limits.parameters][]const u8 = undefined;
    var count: usize = 0;
    while (at < source.len and count < names.len) {
        skipGenericFunctionSpace(source, &at);
        const begin = at;
        if (at == source.len or (!std.ascii.isAlphabetic(source[at]) and source[at] != '_')) return false;
        while (at < source.len and (std.ascii.isAlphanumeric(source[at]) or source[at] == '_')) at += 1;
        const text = source[begin..at];
        if (text.len > types.limits.identifier_bytes) return false;
        for (names[0..count]) |old| if (std.mem.eql(u8, old, text)) return false;
        names[count] = text;
        count += 1;
        if (count > n) return false;
        skipGenericFunctionSpace(source, &at);
        if (at == source.len or source[at] != ':') return false;
        at += 1;
        skipGenericFunctionSpace(source, &at);
        if (std.mem.startsWith(u8, source[at..], "effect")) {
            if (!catalogue.effectWitness(p.tuple_elements[shape.tuple.start + count - 1], p.definitions, p.tuple_elements)) return false;
            at += 6;
        } else if (std.mem.startsWith(u8, source[at..], "type")) {
            at += 4;
        } else if (std.mem.startsWith(u8, source[at..], "comparable")) {
            // The constraint holds for the argument this specialization was made for.
            if (!catalogue.comparableIn(p.tuple_elements[shape.tuple.start + count - 1], comparable)) return false;
            at += 10;
        } else if (boundWord(source[at..])) |length| {
            // A bound `T:subtype(Base)` (RFC-0073), `castable_subtype(Base)` or
            // `concrete_subtype(Base)` (RFC-0081) was checked by the compiler where the template
            // was named. The code made for the argument is typed by the argument itself, so the
            // bound is skipped here, up to the parenthesis that closes it.
            at += length;
            skipGenericFunctionSpace(source, &at);
            if (at == source.len or source[at] != '(') return false;
            var nesting: usize = 1;
            at += 1;
            while (at < source.len and nesting != 0) : (at += 1) switch (source[at]) {
                '(', '[' => nesting += 1,
                ')', ']' => nesting -= 1,
                // A comment runs to the end of its line; brackets in it are text.
                '#', '<' => if (lexer.commentOpens(source, at)) {
                    at = lexer.commentEnd(source, at) - 1;
                },
                else => {},
            };
            if (nesting != 0) return false;
        } else return false;
        skipGenericFunctionSpace(source, &at);
        if (at == source.len) return false;
        if (source[at] == ']') return count == n or (count + 1 == n and methodReceiver(p, f, p.tuple_elements[shape.tuple.end - 1]));
        if (source[at] != ',') return false;
        at += 1;
    }
    return false;
}

/// A specialization of a generic method (RFC-0081) lists, after the method's own type arguments,
/// the class whose method it is: the type of its receiver, which is its first parameter (an
/// anonymous function made inside the method inherits the list and has parameters of its own).
fn methodReceiver(p: types.Program, f: types.RuntimeFunction, receiver: types.Type) bool {
    if (!isClass(p, receiver)) return false;
    return f.anonymous or (f.parameter_count != 0 and f.parameters[0] == receiver);
}

/// The specifier that may stand between the name of a generic template and its parameters.
fn genericSpecifier(text: []const u8) ?[]const u8 {
    for ([_][]const u8{ "public", "internal", "private", "protected", "final" }) |word| {
        if (std.mem.startsWith(u8, text, word) and (text.len == word.len or !(std.ascii.isAlphanumeric(text[word.len]) or text[word.len] == '_'))) return word;
    }
    return null;
}

/// The length of the bound word a template parameter's kind starts with, if it has one.
fn boundWord(text: []const u8) ?usize {
    for ([_][]const u8{ "subtype", "castable_subtype", "concrete_subtype", "castable_concrete_subtype" }) |word| {
        if (std.mem.startsWith(u8, text, word)) return word.len;
    }
    return null;
}

fn skipGenericFunctionSpace(source: []const u8, at: *usize) void {
    while (at.* < source.len) {
        if (std.ascii.isWhitespace(source[at.*])) {
            at.* += 1;
        } else if (lexer.commentOpens(source, at.*)) {
            at.* = lexer.commentEnd(source, at.*);
        } else break;
    }
}

// Structured concurrency (RFC-0082): the reference's admission of sites, and its scheduler.
//
// The scheduler is the RFC's rules S1 to S6 written as data and plain loops: a slot table, a
// ring for the ready queue, a binary heap for the timers, a ring for the starts held by
// rollback regions, and three stores for the frames, registers and parameters of suspended
// tasks. The VM and the report replay keep the same rules in their own forms.

const ReferenceScheduler = call_frames.ReferenceScheduler;
const no_task = call_frames.no_task;
const never = call_frames.never;

/// `spawn` takes a callable of no parameters that suspends and cannot fail, and yields the
/// handle type of its result (admission rule 4).
fn spawnTyped(program: types.Program, callable: types.Type, handle: types.Type) bool {
    const shape = catalogue.definition(callable, program.definitions) orelse return false;
    if (shape != .callable) return false;
    const parameters = catalogue.definition(shape.callable.parameters, program.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.start != parameters.tuple.end) return false;
    if (shape.callable.decides or !shape.callable.detail.suspends) return false;
    const target = catalogue.definition(handle, program.definitions) orelse return false;
    return target == .task and target.task.result == shape.callable.result;
}

/// Whether `value_type` is the unit type `tuple()`, which `sleep` yields.
fn unitTyped(program: types.Program, value_type: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    return shape == .tuple and shape.tuple.start == shape.tuple.end;
}

/// Whether a callable of this type suspends.
fn callableSuspends(program: types.Program, value_type: types.Type) bool {
    const shape = catalogue.definition(value_type, program.definitions) orelse return false;
    return shape == .callable and shape.callable.detail.suspends;
}

/// Whether node `index` of the body of `f` is a site: a `sleep`, or a call of something that
/// suspends. Asked of a body whose operands were admitted.
fn referenceSite(p: types.Program, f: types.RuntimeFunction, nodes: []const types.Node, index: usize) bool {
    return switch (nodes[index].kind) {
        .sleep, .task_await, .event_await, .structured => true,
        .branch => true,
        .task_cancel => true,
        .await_guard => true,
        .call => |c| p.functions[c.function].detail.suspends,
        .iterate => |i| p.functions[i.function].detail.suspends,
        .recur => f.detail.suspends,
        .invoke => |i| callableSuspends(p, nodes[i.callable].value_type),
        .iterate_value => |i| callableSuspends(p, nodes[i.callable].value_type),
        .loop => |l| callableSuspends(p, nodes[l.callable].value_type),
        else => false,
    };
}

/// Admission rules 1 to 3 for one body: every site stands outside the first arm of every
/// `attempt_begin` and is followed by exactly its check, a landing holds no site, exit,
/// `canceling` or `cancel_exit`, those two stand only in a check, and a site's register is
/// read by its check's `merge` and by nothing else.
/// One bit per node of a body, on the stack: admission needs no scratch memory, so it admits
/// the programs the VM admits whatever the arena holds.
const NodeMarks = struct {
    words: [types.limits.nodes / 64 + 1]u64 = undefined,
    count: usize = 0,

    fn clear(self: *NodeMarks, count: usize) void {
        std.debug.assert(count <= types.limits.nodes);
        @memset(self.words[0 .. count / 64 + 1], 0);
        self.count = count;
    }
    fn get(self: *const NodeMarks, index: usize) bool {
        return index < self.count and self.words[index / 64] >> @intCast(index % 64) & 1 != 0;
    }
    fn mark(self: *NodeMarks, index: usize) void {
        std.debug.assert(index < self.count);
        self.words[index / 64] |= @as(u64, 1) << @intCast(index % 64);
    }
};

fn validSites(p: types.Program, f: types.RuntimeFunction, nodes: []const types.Node) bool {
    if (nodes.len > types.limits.nodes) return false;
    // The sites, and the nodes of their checks: `canceling`, `cancel_exit` and `merge`.
    var sites: NodeMarks = .{};
    var checks: NodeMarks = .{};
    sites.clear(nodes.len);
    checks.clear(nodes.len);
    var attempts: [types.limits.control_depth]u32 = undefined;
    var open: usize = 0;
    for (nodes, 0..) |node, index| {
        switch (node.kind) {
            .attempt_begin => {
                if (open == attempts.len) return false;
                attempts[open] = @intCast(index);
                open += 1;
            },
            .otherwise => |begin| if (begin < nodes.len and nodes[begin].kind == .attempt_begin) {
                if (open == 0 or attempts[open - 1] != begin) return false;
                open -= 1;
            },
            else => {},
        }
        if (!referenceSite(p, f, nodes, index)) continue;
        // A site stands in a function that may suspend, outside every rollback region.
        if (!f.detail.suspends or open != 0) return false;
        if (checks.get(index)) return false;
        const site: u32 = @intCast(index);
        if (index + 2 >= nodes.len or nodes[index + 1].kind != .canceling or nodes[index + 2].kind != .if_begin) return false;
        const check = nodes[index + 2].kind.if_begin;
        // P3.6: after its empty `otherwise`, the check of a `structured` site whose arms may exit
        // tests whether one did.
        const exiting = node.kind == .structured and check.alternative + 1 < nodes.len and nodes[check.alternative + 1].kind == .arm_exited;
        if (check.condition != site + 1 or check.alternative < site + 4 or check.end >= nodes.len) return false;
        if (!exiting and check.end != check.alternative + 1) return false;
        const exit_node = nodes[check.alternative - 1];
        const otherwise = nodes[check.alternative];
        const merge = nodes[check.end];
        if (exit_node.kind != .cancel_exit or exit_node.value_type != node.value_type) return false;
        if (otherwise.kind != .otherwise or otherwise.kind.otherwise != site + 2) return false;
        if (merge.kind != .merge or merge.kind.merge.begin != site + 2 or merge.kind.merge.left != check.alternative - 1) return false;
        if (exiting) {
            if (!referenceExitTest(p, f, nodes, site, check.alternative, check.end, &checks)) return false;
        } else if (merge.kind.merge.right != site) return false;
        // The landing: the copies of the open `Defer`s, which may not wait or leave.
        for (nodes[site + 3 .. check.alternative - 1], site + 3..) |landed, at| {
            if (landed.kind == .exit or landed.kind == .canceling or landed.kind == .cancel_exit or referenceSite(p, f, nodes, at)) return false;
            if (landed.kind == .arm_exit or landed.kind == .arm_exited or landed.kind == .arm_exit_value) return false;
        }
        sites.mark(site);
        for ([_]u32{ site + 1, check.alternative - 1, check.end }) |position| {
            if (checks.get(position) or sites.get(position)) return false;
            checks.mark(position);
        }
    }
    // A site's value is read by its check's merge and nothing else: not even as the result.
    if (sites.get(f.root)) return false;
    // P3.6: nor is the closure of an arm that may exit: only its expression starts it.
    if (referenceExitingArm(p, nodes, f.root) != null) return false;
    for (nodes, 0..) |node, index| {
        switch (node.kind) {
            // Each is a node of the check of the site it was marked for (the first pass
            // proved where), so one that is not marked stands outside every check.
            .canceling => if (!checks.get(index) or !sites.get(index - 1)) return false,
            .cancel_exit => if (!checks.get(index)) return false,
            .arm_exited, .arm_exit_value => if (!checks.get(index)) return false,
            .merge => |m| {
                if (sites.get(m.left)) return false;
                if (sites.get(m.right) and !checks.get(index)) return false;
                // Of a check's merges, only the last of a site without exits and the second
                // test's of one with them, whose condition is `arm_exited`, read it.
                if (sites.get(m.right) and m.begin != m.right + 2 and nodes[nodes[m.begin].kind.if_begin.condition].kind != .arm_exited) return false;
                // P3.6: no merge hands on the closure of an arm that may exit, which operand
                // enumeration does not list for a merge.
                if (referenceExitingArm(p, nodes, m.left) != null or referenceExitingArm(p, nodes, m.right) != null) return false;
            },
            else => {},
        }
        for (0..types.operandCount(node, p.function_members)) |ordinal| {
            const operand = types.operandAt(node, ordinal, p.function_members, p.function_arguments);
            if (sites.get(operand)) return false;
            if (referenceExitingArm(p, nodes, operand)) |exits| if (!referenceStartsArm(nodes, index, node, ordinal, operand, exits)) return false;
        }
    }
    return true;
}

/// RFC-0082, P3.6: the second test of the check of the `structured` site `site`, whose first
/// test's `otherwise` is at `alternative` and whose check ends at `end`: `arm_exited`, an
/// `if_begin` on it, `arm_exit_value` first in its first arm, which carries the exit on and
/// holds no site and no node of a check, an empty `otherwise`, and a `merge` of that arm and
/// the site right before the check's own `merge`, which joins the landing and that.
fn referenceExitTest(p: types.Program, f: types.RuntimeFunction, nodes: []const types.Node, site: u32, alternative: u32, end: u32, checks: *NodeMarks) bool {
    if (alternative + 4 >= nodes.len) return false;
    const test_at = alternative + 1;
    const begin = alternative + 2;
    if (nodes[begin].kind != .if_begin) return false;
    const inner = nodes[begin].kind.if_begin;
    if (inner.condition != test_at or inner.alternative <= alternative + 4 or inner.end != inner.alternative + 1 or inner.end + 1 != end) return false;
    if (nodes[alternative + 3].kind != .arm_exit_value) return false;
    const empty = nodes[inner.alternative];
    const joined = nodes[inner.end];
    if (empty.kind != .otherwise or empty.kind.otherwise != begin) return false;
    if (joined.kind != .merge or joined.value_type != nodes[site].value_type) return false;
    const m = joined.kind.merge;
    if (m.begin != begin or m.left <= begin or m.left >= inner.alternative or m.right != site or nodes[end].kind.merge.right != inner.end) return false;
    for (nodes[alternative + 4 .. inner.alternative], alternative + 4..) |carried, at| {
        switch (carried.kind) {
            .canceling, .cancel_exit, .arm_exited, .arm_exit_value => return false,
            else => if (referenceSite(p, f, nodes, at)) return false,
        }
    }
    for ([_]u32{ test_at, alternative + 3, inner.end }) |position| {
        if (checks.get(position)) return false;
        checks.mark(position);
    }
    return true;
}

/// P3.6: the type of the pending exits of an arm whose closure is register `index`: a
/// `function_value` of an arm that may exit, or a `bind` of one; null for any other register.
fn referenceExitingArm(p: types.Program, nodes: []const types.Node, index: u32) ?types.Type {
    if (index >= nodes.len) return null;
    const function: u32 = switch (nodes[index].kind) {
        .function_value => |id| id,
        .bind => |b| if (b.callable < nodes.len and nodes[b.callable].kind == .function_value) nodes[b.callable].kind.function_value else return null,
        else => return null,
    };
    return if (function < p.functions.len) p.functions[function].exits else null;
}

/// Whether node `index` may read such a closure as its operand `ordinal`: a `bind` of the
/// `function_value`, or an arm of a `structured` site whose check reads exits of its type.
fn referenceStartsArm(nodes: []const types.Node, index: usize, node: types.Node, ordinal: usize, operand: u32, exits: types.Type) bool {
    return switch (node.kind) {
        .bind => ordinal == 0 and nodes[operand].kind == .function_value,
        .structured => found: {
            // A site, whose check the first pass has seen.
            const alternative = nodes[index + 2].kind.if_begin.alternative;
            break :found alternative + 3 < nodes.len and nodes[alternative + 1].kind == .arm_exited and nodes[alternative + 3].value_type == exits;
        },
        else => false,
    };
}

/// P3.6: whether a node names an arm that may exit as a value, a call or an iteration.
fn exitingArmNamed(p: types.Program, node: types.Node) bool {
    const function: u32 = switch (node.kind) {
        .function_value => |id| id,
        .call => |c| c.function,
        .iterate => |i| i.function,
        else => return false,
    };
    return function < p.functions.len and p.functions[function].exits != null;
}

fn referenceSchedulerReset(s: *ReferenceScheduler, tick_rate: u64) void {
    std.debug.assert(types.Scheduler.validRate(tick_rate));
    s.used = 0;
    s.free = no_task;
    s.live = 0;
    s.ready_head = 0;
    s.ready_tail = 0;
    s.timer_count = 0;
    s.action_head = 0;
    s.action_kept = 0;
    s.action_count = 0;
    s.action_mark_count = 0;
    s.indexed = 0;
    s.frame_top = 0;
    s.value_top = 0;
    s.frames_live = 0;
    s.values_live = 0;
    s.oldest = no_task;
    s.newest = no_task;
    s.now = 0;
    s.tick_rate = tick_rate;
    s.sequence = 0;
    s.registration = 0;
    s.switches = 0;
    s.created = 0;
    s.completed = 0;
    s.waiting_count = 0;
    s.canceled = 0;
    s.requests = no_task;
    s.canceled_now = false;
    s.current = no_task;
    s.exited_now = false;
}

/// The run's record, once the scheduler is quiescent.
fn referenceRecord(s: *const ReferenceScheduler) types.Scheduler {
    return .{ .tick_rate = s.tick_rate, .tick = s.now, .created = s.created, .completed = s.completed, .canceled = s.canceled, .switches = s.switches, .waiting = s.waiting[0..s.waiting_count] };
}

fn referenceTaskTake(s: *ReferenceScheduler) ?u32 {
    if (s.live == types.limits.tasks) return null;
    var slot: u32 = undefined;
    if (s.free != no_task) {
        slot = s.free;
        s.free = s.tasks[slot].next_free;
    } else {
        std.debug.assert(s.used < types.limits.tasks);
        slot = s.used;
        s.used += 1;
    }
    s.tasks[slot] = .{};
    s.live += 1;
    return slot;
}

fn referenceTaskRelease(s: *ReferenceScheduler, slot: u32) void {
    std.debug.assert(s.tasks[slot].state != .free and s.live != 0);
    referenceIndexDrop(s, s.tasks[slot].sequence);
    s.tasks[slot].state = .free;
    s.tasks[slot].next_free = s.free;
    s.free = slot;
    s.live -= 1;
}

/// `spawn`: one unit of fuel for the creation, a slot, and the handle, an instance with the next
/// sequence, active and without a result. The task does not run yet.
fn referenceSpawn(p: types.Program, handle_type: types.Type, closure: types.Value, origin: u32, s: *ReferenceScheduler, source: *source_state.ReferenceState, remaining: *u64) union(enum) { ok: u32, failed: types.Diagnostic.Code } {
    if (remaining.* < 1) return .{ .failed = .work_limit };
    remaining.* -= 1;
    const shape = catalogue.definition(handle_type, p.definitions).?.task;
    const slot = referenceTaskTake(s) orelse return .{ .failed = .task_limit };
    s.sequence += 1;
    const cells = [_]types.Value{
        .{ .integer = @backingInt(handle_type) },
        .{ .integer = @intCast(s.sequence) },
        .{ .integer = catalogue.task_active },
        .{ .aggregate = .{ .value_type = shape.option, .elements = .{ .start = 0, .end = 0 } } },
    };
    const id = source.allocate(&cells) catch |err| return .{ .failed = source_state.diagnostic(err) };
    s.tasks[slot] = .{ .state = .running, .sequence = s.sequence, .handle = .{ .object = .{ .value_type = handle_type, .id = id } }, .closure = closure, .origin = origin };
    referenceIndexAdd(s, s.sequence, slot);
    return .{ .ok = slot };
}

/// A start inside a rollback region is held there, as an action is (Q5): `depth` is the run's
/// region depth. False when the held starts are at their capacity.
fn referenceHold(s: *ReferenceScheduler, slot: u32, depth: u32) bool {
    const place = referenceHoldPlace(s, depth) orelse return false;
    s.actions[place] = slot;
    s.tasks[slot].state = .pending;
    return true;
}

/// A `Signal` inside a rollback region is held there with the starts, in program order (Q5).
fn referenceHoldSignal(s: *ReferenceScheduler, event: types.Value, value: types.Value, depth: u32) bool {
    std.debug.assert(event == .object);
    const place = referenceHoldPlace(s, depth) orelse return false;
    s.actions[place] = no_task;
    s.signals[place] = .{ .event = event, .value = value };
    return true;
}

/// The place in the ring of the next held action of the region `depth` deep; null when the
/// actions held and committed are at their capacity.
fn referenceHoldPlace(s: *ReferenceScheduler, depth: u32) ?u64 {
    std.debug.assert(depth != 0);
    if (s.action_count - s.action_head == types.limits.scheduler_actions) return null;
    if (s.action_mark_count == 0 or s.action_marks[s.action_mark_count - 1].depth != depth) {
        // A mark owns at least one held action, so the marks fit beside them.
        s.action_marks[s.action_mark_count] = .{ .depth = depth, .count = s.action_count };
        s.action_mark_count += 1;
    }
    const place = s.action_count % types.limits.scheduler_actions;
    s.action_count += 1;
    return place;
}

/// The region `closing` deep committed: its starts now belong to the region around it, and
/// when that is none, they are committed and wait their turn. True when they begin a drain: no
/// committed start was waiting before. Otherwise a drain is under way, by the task that
/// committed first, and these join the back of its queue (RFC-0082, "Scheduler actions").
fn referenceHeldCommit(s: *ReferenceScheduler, closing: u32) bool {
    std.debug.assert(closing != 0);
    if (s.action_mark_count != 0 and s.action_marks[s.action_mark_count - 1].depth == closing) {
        if (closing == 1 or (s.action_mark_count > 1 and s.action_marks[s.action_mark_count - 2].depth == closing - 1)) {
            s.action_mark_count -= 1;
        } else s.action_marks[s.action_mark_count - 1].depth = closing - 1;
    }
    if (closing != 1) return false;
    std.debug.assert(s.action_mark_count == 0);
    const idle = s.action_head == s.action_kept;
    var at = s.action_kept;
    while (at < s.action_count) : (at += 1) {
        const slot = s.actions[at % types.limits.scheduler_actions];
        if (slot == no_task) continue; // A signal (P3.2), carried out in its turn.
        std.debug.assert(s.tasks[slot].state == .pending);
        s.tasks[slot].state = .queued;
    }
    s.action_kept = s.action_count;
    return idle and s.action_head != s.action_kept;
}

/// The region `closing` deep failed: its starts never happen. Their handles were created in it
/// and the rollback forgets them; their slots are free again and their sequence numbers too.
fn referenceHeldAbort(s: *ReferenceScheduler, closing: u32) void {
    std.debug.assert(closing != 0);
    if (s.action_mark_count == 0 or s.action_marks[s.action_mark_count - 1].depth != closing) return;
    const mark = s.action_marks[s.action_mark_count - 1];
    s.action_mark_count -= 1;
    std.debug.assert(mark.count >= s.action_kept and mark.count < s.action_count);
    while (s.action_count > mark.count) {
        s.action_count -= 1;
        const slot = s.actions[s.action_count % types.limits.scheduler_actions];
        // A signal the region held is dropped with it (P3.2).
        if (slot == no_task) continue;
        // No task starts inside a region, so the starts it drops are the last ones numbered.
        std.debug.assert(s.tasks[slot].state == .pending and s.tasks[slot].sequence == s.sequence);
        s.sequence -= 1;
        referenceTaskRelease(s, slot);
    }
}

/// A rollback region commits: its actions and its starts go to the region around it. True when
/// the committing frame now drains the starts (`referenceHeldCommit`).
fn referenceRegionCommit(control: *types.ControlStorage, s: *ReferenceScheduler) effects.Error!bool {
    const closing = control.effects.depth;
    try control.effects.commit();
    // RFC-0084, P4.4: and what it notified, to the region around it.
    const frames: *call_frames.ReferenceStorage = @fieldParentPtr("scheduler", s);
    if (frames.live.on) live_reference.pendingCommit(&frames.live, closing);
    return referenceHeldCommit(s, closing);
}

/// A rollback region fails: its actions and its starts are dropped.
fn referenceRegionAbort(control: *types.ControlStorage, s: *ReferenceScheduler) void {
    const closing = control.effects.depth;
    control.effects.abort();
    // RFC-0084, P4.4 (R2): what it notified is not notified.
    const frames: *call_frames.ReferenceStorage = @fieldParentPtr("scheduler", s);
    if (frames.live.on) live_reference.pendingAbort(&frames.live, closing);
    referenceHeldAbort(s, closing);
}

/// Whether committed starts wait for their turn.
fn referenceDraining(s: *const ReferenceScheduler) bool {
    return s.action_head != s.action_kept;
}

/// The next committed start, which takes its turn now; the committed signals before it are
/// carried out first, in order (P3.2), each charged as at its node. The start is counted under
/// `origin`, the root instruction of the drain, in failure traces from then on.
fn referenceNextStart(s: *ReferenceScheduler, source: ?*source_state.ReferenceState, origin: u32, remaining: *u64) union(enum) { start: u32, none, failed: types.Diagnostic.Code } {
    while (referenceDraining(s)) {
        const place = s.action_head % types.limits.scheduler_actions;
        const slot = s.actions[place];
        s.action_head += 1;
        if (slot == no_task) {
            const signal = s.signals[place];
            if (referenceSignal(s, source.?, signal.event.object, signal.value, remaining)) |code| return .{ .failed = code };
            continue;
        }
        // RFC-0084, P4.7: a reaction cancelled before its turn starts never (N6); its slot goes.
        if (s.tasks[slot].state == .settled) {
            std.debug.assert(reactionTask(&s.tasks[slot]));
            referenceTaskRelease(s, slot);
            continue;
        }
        std.debug.assert(s.tasks[slot].state == .queued);
        s.tasks[slot].origin = origin;
        return .{ .start = slot };
    }
    return .none;
}

/// The frame on top committed a region to depth 0 and begins a drain: the first start takes
/// its turn on top of it, and the frame goes on when it has none left (`referenceLeft`).
fn referenceDrainFrom(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []const types.Value, pool: *const run_strings.Pool, source: ?*source_state.ReferenceState, root_pc: u32, remaining: *u64) ?types.Diagnostic.Code {
    // RFC-0084, P4.4: in a program with reactions a turn may be a reaction's start, which the
    // frame loop takes, where the guard's frame and the body's can run; it delivers when the
    // drain ends.
    if (frames.live.reacts) {
        frames.drains[frames.depth - 1] = true;
        frames.live.drain_turn = true;
        return null;
    }
    switch (referenceNextStart(s, source, root_pc, remaining)) {
        .start => |slot| {
            frames.drains[frames.depth - 1] = true;
            return referenceTaskStart(p, s, frames, control, members, pool, source, slot, false, 0);
        },
        .none => return null,
        .failed => |code| return code,
    }
}

/// Starts the task in `slot`: its entry frame goes on top of the active stack, to run from the
/// next pass of the frame loop. A start is a switch, counted before the frame is pushed, so
/// that the entry frame's mark includes it. `return_to` is the creator's register when a
/// `spawn` hands off (`handoff`).
fn referenceTaskStart(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []const types.Value, pool: *const run_strings.Pool, source: ?*const source_state.ReferenceState, slot: u32, handoff: bool, return_to: u32) ?types.Diagnostic.Code {
    std.debug.assert(control.effects.depth == 0);
    const task = &s.tasks[slot];
    std.debug.assert(task.closure == .callable);
    const closure = task.closure.callable;
    if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .call_trace_limit;
    s.switches += 1;
    const entry_at = frames.depth;
    if (referencePush(p, .{ .function = closure.function, .arguments = .{ .start = 0, .end = 0 }, .captures = closure.captures }, &.{}, &.{}, members, return_to, frames)) |code| return code;
    referenceMarked(frames, pool, source);
    frames.task_marks[frames.depth - 1] = slot;
    frames.handoffs[frames.depth - 1] = handoff;
    task.state = .running;
    // P3.4: it runs above the task that started it, which runs again when this one leaves.
    task.below = s.current;
    task.entry_at = entry_at;
    s.current = slot;
    s.created += 1;
    control.calls[control.call_count] = .{ .function = closure.function, .pc = 0, .value = .{ .integer = @intCast(task.sequence) }, .kind = .start };
    control.call_count += 1;
    return null;
}

/// The task whose frames are on top of the active stack: the one whose entry frame is highest.
fn referenceRunning(frames: *const call_frames.ReferenceStorage) u32 {
    var depth = frames.depth;
    while (depth != 0) {
        depth -= 1;
        if (frames.task_marks[depth] != no_task) return depth;
    }
    unreachable; // Only a task reaches a site: root code calls nothing that suspends.
}

/// Makes room at the end of the stores for `frame_count` frames and `value_count` values
/// (registers and parameters), closing up the runs of the suspended tasks in their order.
/// The live sums fit by the caller's check.
fn referenceStoreRoom(s: *ReferenceScheduler, frame_count: u32, value_count: u32) void {
    if (frame_count <= s.saved.len - s.frame_top and value_count <= s.saved_values.len - s.value_top) return;
    var frame_at: u32 = 0;
    var value_at: u32 = 0;
    var slot = s.oldest;
    while (slot != no_task) : (slot = s.tasks[slot].newer) {
        const task = &s.tasks[slot];
        const stored = task.value_count + task.parameter_count;
        std.mem.copyForwards(call_frames.ReferenceSavedFrame, s.saved[frame_at..][0..task.frame_count], s.saved[task.frame_start..][0..task.frame_count]);
        std.mem.copyForwards(types.Value, s.saved_values[value_at..][0..stored], s.saved_values[task.value_start..][0..stored]);
        task.frame_start = frame_at;
        task.value_start = value_at;
        frame_at += task.frame_count;
        value_at += stored;
    }
    std.debug.assert(frame_at == s.frames_live and value_at == s.values_live);
    s.frame_top = frame_at;
    s.value_top = value_at;
    std.debug.assert(frame_count <= s.saved.len - s.frame_top and value_count <= s.saved_values.len - s.value_top);
}

/// What a task waits for at a site (P3.2): a deadline (`never` for none), the next `Signal`
/// of an event, or the end of the task in `slot`, whose handle it awaits.
const ReferenceWait = union(enum) { sleep: u64, event: types.ObjectRef, task: struct { handle: types.ObjectRef, slot: u32 }, record: u32, frame_end: u32, guard };

/// The current task waits at the site `site_pc` of its top frame for `wait`: its frames go to
/// the stores, and the active stack is left as it was below its entry frame. Charges one unit
/// per frame and one per eight registers. Returns the depth of the entry frame.
fn referenceSuspend(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: *source_state.ReferenceState, members: []const types.Value, site_pc: u32, wait: ReferenceWait, remaining: *u64) union(enum) { ok: u32, failed: types.Diagnostic.Code } {
    std.debug.assert(control.effects.depth == 0);
    const entry = referenceRunning(frames);
    const slot = frames.task_marks[entry];
    const first = frames.frames[entry].base;
    const frame_count = frames.depth - entry;
    const value_count = frames.count - first;
    var parameter_count: u32 = 0;
    for (frames.frames[entry..frames.depth]) |frame| {
        std.debug.assert(frame.catch_depth == 0);
        parameter_count += p.functions[frame.function].parameter_count;
    }
    const cost: u64 = frame_count + (@as(u64, value_count) + 7) / 8;
    if (remaining.* < cost) return .{ .failed = .work_limit };
    remaining.* -= cost;
    // The registers and the parameters of the frames count against one limit.
    if (frame_count > types.limits.saved_frames - s.frames_live or value_count + parameter_count > types.limits.saved_registers - s.values_live) return .{ .failed = .suspended_frame_limit };
    if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .{ .failed = .call_trace_limit };
    const top = frames.frames[frames.depth - 1];
    // The step says what it waits for: the wake tick, `false` for never, or the instance.
    const told: types.Value = switch (wait) {
        .sleep => |deadline| if (deadline == never) .{ .boolean = false } else .{ .integer = @intCast(deadline) },
        .event => |event| .{ .object = event },
        .task => |awaited| .{ .object = awaited.handle },
        // P3.3: the number of its arms.
        .record => |arms| .{ .integer = arms },
        // P3.4: how many tasks its frame owns.
        .frame_end => |owned| .{ .integer = owned },
        // RFC-0084, P4.6: a guard, which no clock ends.
        .guard => .{ .boolean = false },
    };
    control.calls[control.call_count] = .{ .function = top.function, .pc = site_pc, .value = told, .kind = .@"suspend" };
    control.call_count += 1;
    s.switches += 1;
    referenceStoreRoom(s, frame_count, value_count + parameter_count);
    const task = &s.tasks[slot];
    task.frame_start = s.frame_top;
    task.value_start = s.value_top;
    task.frame_count = frame_count;
    task.value_count = value_count;
    task.parameter_count = parameter_count;
    @memcpy(s.saved_values[s.value_top..][0..value_count], frames.values[first..frames.count]);
    s.value_top += value_count;
    for (frames.frames[entry..frames.depth], entry..) |frame, depth| {
        const count = p.functions[frame.function].parameter_count;
        @memcpy(s.saved_values[s.value_top..][0..count], frame.parameters[0..count]);
        s.value_top += count;
        s.saved[s.frame_top] = .{
            .function = frame.function,
            .base = frame.base - first,
            .cursor = frame.cursor,
            // The entry frame has given its creator what it gets by now.
            .return_to = if (depth == entry) 0 else frame.return_to - first,
            .remaining_visits = frame.remaining_visits,
            .state_loop = frame.state_loop,
            .mark = frames.marks[depth],
            .string_mark = frames.string_marks[depth],
            .cell_mark = frames.cell_marks[depth],
            .switches = frames.switch_marks[depth],
            .task = frames.task_marks[depth],
            .owned_first = frames.owned_firsts[depth],
            .owned_last = frames.owned_lasts[depth],
            .canceled_end = frames.canceled_ends[depth],
            .captures = frames.captures[depth],
        };
        s.frame_top += 1;
    }
    s.frames_live += frame_count;
    s.values_live += value_count + parameter_count;
    task.older = s.newest;
    task.newer = no_task;
    if (s.newest != no_task) s.tasks[s.newest].newer = slot else s.oldest = slot;
    s.newest = slot;
    task.site_function = top.function;
    task.site_pc = site_pc;
    task.state = .waiting;
    task.deadline = never;
    task.next_waiter = no_task;
    switch (wait) {
        .sleep => |deadline| {
            task.wait = .sleep;
            task.deadline = deadline;
            if (deadline != never) {
                s.registration += 1;
                task.registration = s.registration;
                referenceTimerPush(s, .{ .deadline = deadline, .registration = s.registration, .task = slot });
            }
        },
        .event => |event| {
            task.wait = .event;
            task.target = .{ .object = event };
            referenceJoinEvent(s, source, event, slot);
        },
        .task => |awaited| {
            // Awaiting is not owning: the awaited task only learns whom to wake (api:3269).
            task.wait = .task;
            task.target = .{ .object = awaited.handle };
            task.awaited = awaited.slot;
            const target = &s.tasks[awaited.slot];
            task.prior_waiter = target.awaiter_last;
            if (target.awaiter_last == no_task) target.awaiter_first = slot else s.tasks[target.awaiter_last].next_waiter = slot;
            target.awaiter_last = slot;
        },
        // P3.3: it waits until its arms are settled; the record is its own.
        .record => task.wait = .record,
        // P3.4: until the tasks of its top frame are settled.
        .frame_end => task.wait = .frame_end,
        // RFC-0084, P4.6: until a write of what its guard read notifies it; the live store keeps
        // those dependencies.
        .guard => task.wait = .guard,
    }
    // P3.4: the task below it on the stack runs again.
    std.debug.assert(s.current == slot);
    s.current = task.below;
    task.below = no_task;
    frames.depth = entry;
    frames.count = first;
    return .{ .ok = entry };
}

/// A waiting task back on the empty active stack, its site yielding `task.resume_value`.
/// Charges one unit per frame and one per eight registers at the site.
fn referenceRestore(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, slot: u32, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(frames.depth == 0 and frames.count == 0 and control.effects.depth == 0);
    const task = &s.tasks[slot];
    std.debug.assert(task.state == .ready);
    const cost: u64 = task.frame_count + (@as(u64, task.value_count) + 7) / 8;
    if (remaining.* < cost) return .work_limit;
    remaining.* -= cost;
    if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .call_trace_limit;
    s.switches += 1;
    var parameter_at = task.value_start + task.value_count;
    for (s.saved[task.frame_start..][0..task.frame_count], 0..) |saved, depth| {
        const count = p.functions[saved.function].parameter_count;
        const frame = &frames.frames[depth];
        frame.function = saved.function;
        frame.base = saved.base;
        frame.cursor = saved.cursor;
        frame.return_to = saved.return_to;
        frame.remaining_visits = saved.remaining_visits;
        frame.catch_depth = 0;
        frame.state_loop = saved.state_loop;
        @memcpy(frame.parameters[0..count], s.saved_values[parameter_at..][0..count]);
        parameter_at += count;
        frames.marks[depth] = saved.mark;
        frames.string_marks[depth] = saved.string_mark;
        frames.cell_marks[depth] = saved.cell_mark;
        frames.switch_marks[depth] = saved.switches;
        frames.task_marks[depth] = saved.task;
        frames.handoffs[depth] = false;
        frames.drains[depth] = false;
        frames.owned_firsts[depth] = saved.owned_first;
        frames.owned_lasts[depth] = saved.owned_last;
        frames.canceled_ends[depth] = saved.canceled_end;
        frames.captures[depth] = saved.captures;
    }
    std.debug.assert(parameter_at == task.value_start + task.value_count + task.parameter_count);
    @memcpy(frames.values[0..task.value_count], s.saved_values[task.value_start..][0..task.value_count]);
    frames.depth = task.frame_count;
    frames.count = task.value_count;
    s.frames_live -= task.frame_count;
    s.values_live -= task.value_count + task.parameter_count;
    if (task.older != no_task) s.tasks[task.older].newer = task.newer else s.oldest = task.newer;
    if (task.newer != no_task) s.tasks[task.newer].older = task.older else s.newest = task.older;
    task.older = no_task;
    task.newer = no_task;
    // The top frame's cursor is already past its site; the site's register gets the value. A
    // frame waiting at its end (P3.4) stands at its end, and goes on ending whether or not its
    // task was asked to cancel meanwhile: the end is already happening.
    std.debug.assert(s.current == no_task);
    s.current = slot;
    task.below = no_task;
    task.entry_at = 0;
    // P3.5: depths compare within the run of the task on the stack, which begins here.
    control.reclaim_depth = 0;
    const top = &frames.frames[frames.depth - 1];
    std.debug.assert(top.function == task.site_function and top.cursor == task.site_pc + @intFromBool(task.wait != .frame_end));
    if (task.wait == .guard and !task.flagged) {
        // RFC-0084, P4.6: a task woken at an `Await` stands at the site again and evaluates its
        // guard there: the site's register is not written.
        control.calls[control.call_count] = .{ .function = task.site_function, .pc = task.site_pc, .value = task.resume_value, .kind = .@"resume" };
        control.call_count += 1;
        top.cursor = task.site_pc;
    } else if (task.wait == .frame_end) {
        control.calls[control.call_count] = .{ .function = task.site_function, .pc = task.site_pc, .value = task.resume_value, .kind = .@"resume" };
        control.call_count += 1;
    } else if (task.flagged) {
        // P3.3: a task asked to cancel resumes only to yield cancelled; its check comes next.
        control.calls[control.call_count] = .{ .function = task.site_function, .pc = task.site_pc, .value = .{ .integer = @intCast(task.sequence) }, .kind = .resume_canceled };
        control.call_count += 1;
        s.canceled_now = true;
    } else if (task.wait == .record and task.record.exited) {
        // P3.6: an expression an arm's exit abandoned yields that pending exit to its check, and
        // not to the site's register.
        const pending = s.tasks[task.record.winner].result;
        control.calls[control.call_count] = .{ .function = task.site_function, .pc = task.site_pc, .value = pending, .kind = .resume_exited };
        control.call_count += 1;
        s.exited_now = true;
        s.exited_value = pending;
    } else {
        // An expression that completed yields the winner's result, or the tuple of the results,
        // built now in the site's frame (P3.3).
        var value = task.resume_value;
        if (task.wait == .record) value = switch (task.record.kind) {
            .race, .rush => s.tasks[task.record.winner].result,
            .sync => switch (referenceSyncTuple(p, s, &task.record, members, member_count, remaining)) {
                .ok => |tuple| tuple,
                .failed => |code| return code,
            },
        };
        frames.values[top.base + task.site_pc] = value;
        control.calls[control.call_count] = .{ .function = task.site_function, .pc = task.site_pc, .value = value, .kind = .@"resume" };
        control.call_count += 1;
    }
    // Its arms go with the expression.
    if (task.wait == .record) referenceArmsRelease(s, &task.record);
    task.state = .running;
    return null;
}

/// The current task's entry frame ended with `result`: the task completed. Its handle says so
/// and holds `option{result}`, one member; its slot is free.
fn referenceSettle(p: types.Program, s: *ReferenceScheduler, control: *types.ControlStorage, source: *source_state.ReferenceState, members: []types.Value, member_count: *usize, slot: u32, function: u32, result: types.Value) ?types.Diagnostic.Code {
    std.debug.assert(control.effects.depth == 0 and source.depth == 1);
    const task = &s.tasks[slot];
    std.debug.assert(task.state == .running);
    if (member_count.* >= @min(members.len, types.limits.aggregate_elements)) return .aggregate_limit;
    if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .call_trace_limit;
    // P3.4: the task below it on the stack runs again.
    std.debug.assert(s.current == slot);
    s.current = task.below;
    const handle = task.handle.object;
    const shape = catalogue.definition(handle.value_type, p.definitions).?.task;
    members[member_count.*] = result;
    const option: types.Value = .{ .aggregate = .{ .value_type = shape.option, .elements = .{ .start = @intCast(member_count.*), .end = @intCast(member_count.* + 1) } } };
    member_count.* += 1;
    // At region depth 0 the root region keeps no record: the scheduler's writes are never undone.
    source.write(handle.id + catalogue.task_state, .{ .integer = catalogue.task_completed }, false) catch unreachable;
    source.write(handle.id + catalogue.task_result, option, false) catch unreachable;
    const f = p.functions[function];
    control.calls[control.call_count] = .{ .function = function, .pc = f.body.end - f.body.start, .value = result, .kind = .settle };
    control.call_count += 1;
    s.completed += 1;
    // Its awaiters resume with the result, in the order they began to wait (S4, S6). Each paid
    // for its wait, so waking them is not charged again.
    var awaiter = task.awaiter_first;
    while (awaiter != no_task) {
        const next = s.tasks[awaiter].next_waiter;
        std.debug.assert(s.tasks[awaiter].state == .waiting and s.tasks[awaiter].wait == .task);
        referenceReadyPush(s, awaiter, result);
        awaiter = next;
    }
    referenceTaskRelease(s, slot);
    return null;
}

/// The wake ticks of `Sleep(seconds)` at tick `now` (RFC-0082, "Time"): null for a sleep that
/// completes at once, `never` for one the clock cannot end. NaN is refused by the caller.
fn referenceWake(seconds: f64, now: u64, rate: u64) ?u64 {
    @setFloatMode(.strict);
    std.debug.assert(!types.isNan(seconds) and now < types.Scheduler.clock_limit);
    if (seconds < 0.0) return null;
    // Zero, of either sign, is the next tick, unless that is the clock's limit.
    if (seconds == 0.0) return if (now + 1 >= types.Scheduler.clock_limit) never else now + 1;
    if (std.math.isInf(seconds)) return never;
    const ticks = @ceil(seconds * @as(f64, @floatFromInt(rate)));
    // `ceil(S * R)` in binary64; a deadline at or above 2^62 is never reached.
    if (!(ticks < @as(f64, @floatFromInt(types.Scheduler.clock_limit)))) return never;
    const whole: u64 = @intFromFloat(ticks);
    if (whole >= types.Scheduler.clock_limit - now) return never;
    return now + @max(1, whole);
}

fn referenceTimerBefore(a: call_frames.ReferenceTimer, b: call_frames.ReferenceTimer) bool {
    return a.deadline < b.deadline or (a.deadline == b.deadline and a.registration < b.registration);
}

/// A timer at its place in the heap, which its task remembers so that a cancellation can take
/// it out (P3.3).
fn referenceTimerPlace(s: *ReferenceScheduler, at: u32, timer: call_frames.ReferenceTimer) void {
    s.timers[at] = timer;
    s.tasks[timer.task].timer_at = at;
}

/// Moves `timer` up from the hole at `at` to where it belongs, and places it.
fn referenceTimerUp(s: *ReferenceScheduler, start: u32, timer: call_frames.ReferenceTimer) void {
    var at = start;
    while (at != 0) {
        const parent = (at - 1) / 2;
        if (!referenceTimerBefore(timer, s.timers[parent])) break;
        referenceTimerPlace(s, at, s.timers[parent]);
        at = parent;
    }
    referenceTimerPlace(s, at, timer);
}

/// Moves `timer` down from the hole at `at` to where it belongs, and places it.
fn referenceTimerDown(s: *ReferenceScheduler, start: u32, timer: call_frames.ReferenceTimer) void {
    var at = start;
    while (true) {
        const left = 2 * at + 1;
        if (left >= s.timer_count) break;
        const right = left + 1;
        const child = if (right < s.timer_count and referenceTimerBefore(s.timers[right], s.timers[left])) right else left;
        if (!referenceTimerBefore(s.timers[child], timer)) break;
        referenceTimerPlace(s, at, s.timers[child]);
        at = child;
    }
    referenceTimerPlace(s, at, timer);
}

fn referenceTimerPush(s: *ReferenceScheduler, timer: call_frames.ReferenceTimer) void {
    std.debug.assert(s.timer_count < s.timers.len);
    const at = s.timer_count;
    s.timer_count += 1;
    referenceTimerUp(s, at, timer);
}

fn referenceTimerPop(s: *ReferenceScheduler) call_frames.ReferenceTimer {
    std.debug.assert(s.timer_count != 0);
    const first = s.timers[0];
    s.timer_count -= 1;
    if (s.timer_count != 0) referenceTimerDown(s, 0, s.timers[s.timer_count]);
    s.tasks[first.task].timer_at = no_task;
    return first;
}

/// Takes the timer of the task in `slot` out of the heap: it was asked to cancel (P3.3).
fn referenceTimerRemove(s: *ReferenceScheduler, slot: u32) void {
    const at = s.tasks[slot].timer_at;
    std.debug.assert(at < s.timer_count and s.timers[at].task == slot);
    s.timer_count -= 1;
    s.tasks[slot].timer_at = no_task;
    if (at == s.timer_count) return;
    const moved = s.timers[s.timer_count];
    if (at != 0 and referenceTimerBefore(moved, s.timers[(at - 1) / 2])) referenceTimerUp(s, at, moved) else referenceTimerDown(s, at, moved);
}

fn referenceReadyPush(s: *ReferenceScheduler, slot: u32, value: types.Value) void {
    std.debug.assert(s.ready_tail - s.ready_head < types.limits.tasks);
    s.tasks[slot].state = .ready;
    s.tasks[slot].resume_value = value;
    s.tasks[slot].next_waiter = no_task;
    s.tasks[slot].prior_waiter = no_task;
    s.ready[s.ready_tail % types.limits.tasks] = slot;
    s.ready_tail += 1;
}

/// The unit value a `sleep` yields.
fn referenceUnit(p: types.Program, site: types.Node) types.Value {
    std.debug.assert(unitTyped(p, site.value_type));
    return .{ .aggregate = .{ .value_type = site.value_type, .elements = .{ .start = 0, .end = 0 } } };
}

fn referenceSiteSpan(p: types.Program, function: u32, pc: u32) types.Span {
    const f = p.functions[function];
    // A wait at a frame's end (P3.4) is placed at the frame's result.
    const at = if (pc == f.body.end - f.body.start) f.root else pc;
    return p.function_nodes[f.body.start + at].node.span;
}

/// What a task that left the active stack hands the frame below it (RFC-0082): the handle, when
/// a `spawn` there handed off to it; or, for an arm (P3.3), the turn of its expression's start
/// phase, which the task waiting on the expression (`arm_parent`) runs.
const ReferenceLeave = struct { handoff: bool, return_to: u32, handle: types.Value, arm_parent: u32 };
/// Where the frame loop goes after a task left the active stack.
const ReferenceLeft = union(enum) { going, empty, failed: types.Diagnostic };

/// Hands the creator, the frame below a task that left the active stack, what it waits for:
/// the handle, in its register and its step, when a `spawn` there handed off to the task; the
/// next arm, or the value, of the expression whose arm it was. Then a committed start takes its
/// turn if this frame is draining the queue. A task whose start phase ends without a value
/// waits in turn, and the frame below it is handed what it waits for (`empty` when there is
/// none). `span` names the place of a failure that is not the start phase's.
fn referenceLeft(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, pool: *const run_strings.Pool, source: ?*source_state.ReferenceState, first: ReferenceLeave, span: types.Span, root_pc: u32, remaining: *u64) ReferenceLeft {
    var leave = first;
    while (true) {
        std.debug.assert(frames.depth != 0);
        const parent = &frames.frames[frames.depth - 1];
        if (leave.handoff) {
            const parent_pc = leave.return_to - parent.base;
            std.debug.assert(parent.cursor == parent_pc + 1);
            if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
            control.calls[control.call_count] = .{ .function = parent.function, .pc = parent_pc, .value = leave.handle };
            control.call_count += 1;
            frames.values[leave.return_to] = leave.handle;
        }
        if (leave.arm_parent != no_task) {
            switch (referenceStartPhase(p, s, frames, control, members, member_count, pool, source, leave.arm_parent, remaining)) {
                .started, .completed => return .going,
                .waits => |next| {
                    if (frames.depth == 0) return .empty;
                    leave = next;
                    continue;
                },
                .failed => |diagnostic| return .{ .failed = diagnostic },
            }
        }
        if (!frames.drains[frames.depth - 1]) return .going;
        // RFC-0084, P4.4: with reactions the frame loop takes the next turn (`referenceDrainTurn`).
        if (frames.live.reacts) {
            frames.live.drain_turn = true;
            return .going;
        }
        switch (referenceNextStart(s, source, root_pc, remaining)) {
            .start => |slot| if (referenceTaskStart(p, s, frames, control, members[0..member_count.*], pool, source, slot, false, 0)) |code| return .{ .failed = .{ .span = span, .code = code } },
            .none => frames.drains[frames.depth - 1] = false,
            .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
        }
        return .going;
    }
}

/// The task on top waits at the site `cursor` of its top frame for `wait`; the frame below its
/// entry frame, if any, goes on (`below`), or the stack is empty (`empty`). `span` is the site's.
fn referenceWaitAt(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, pool: *const run_strings.Pool, source: *source_state.ReferenceState, cursor: u32, wait: ReferenceWait, span: types.Span, root_pc: u32, remaining: *u64) union(enum) { empty, below, failed: types.Diagnostic } {
    const leave = referenceLeaving(s, frames);
    switch (referenceSuspend(p, s, frames, control, source, members[0..member_count.*], cursor, wait, remaining)) {
        .ok => {},
        .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
    }
    if (frames.depth == 0) return .empty;
    return switch (referenceLeft(p, s, frames, control, members, member_count, pool, source, leave, span, root_pc, remaining)) {
        .going => .below,
        .empty => .empty,
        .failed => |diagnostic| .{ .failed = diagnostic },
    };
}

/// What the task on top hands the frame below its entry frame when it leaves the stack. An arm
/// that has a frame below it was handed off to by its expression's start phase (P3.3): a
/// restored arm runs on the empty stack.
fn referenceLeaving(s: *const ReferenceScheduler, frames: *const call_frames.ReferenceStorage) ReferenceLeave {
    const entry = referenceRunning(frames);
    const slot = frames.task_marks[entry];
    const task = &s.tasks[slot];
    return .{ .handoff = frames.handoffs[entry], .return_to = frames.frames[entry].return_to, .handle = if (task.kind != .arm) task.handle else .{ .boolean = false }, .arm_parent = if (task.kind == .arm and entry != 0) task.parent else no_task };
}

/// `event(T){}` (P3.2): an instance with no waiter.
fn referenceEvent(p: types.Program, source: *source_state.ReferenceState, event_type: types.Type) source_state.Error!types.Value {
    // P3.9: a sticky event, its latch clear and a value of 0; a subscribable one, no
    // subscription and the number 0 next.
    const kind = catalogue.definition(event_type, p.definitions).?.event.kind;
    const cells = [catalogue.subscribable_cells]types.Value{ .{ .integer = @backingInt(event_type) }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 0 }, if (kind == .sticky) .{ .integer = 0 } else .{ .boolean = false }, if (kind == .sticky) .{ .integer = 0 } else .{ .boolean = false }, .{ .integer = 0 } };
    const id = try source.allocate(cells[0..catalogue.eventCells(kind)]);
    return .{ .object = .{ .value_type = event_type, .id = id } };
}

/// P3.9 (C105): the value a sticky event holds once signalled; null otherwise, and for any other
/// instance.
fn referenceSticky(p: types.Program, source: *const source_state.ReferenceState, instance: types.ObjectRef) ?types.Value {
    const shape = catalogue.definition(instance.value_type, p.definitions) orelse return null;
    if (shape != .event or shape.event.kind != .sticky or referenceEventCell(source, instance, catalogue.sticky_latch) != 1) return null;
    return source.read(instance.id + catalogue.sticky_value) catch unreachable;
}

/// P3.9 (C107): a new `cancelable`, last on its event's list.
fn referenceSubscribe(source: *source_state.ReferenceState, event: types.ObjectRef, callback: types.Value, cancelable_type: types.Type) source_state.Error!types.Value {
    const number = try source.read(event.id + catalogue.subscription_count);
    const last = try source.read(event.id + catalogue.subscription_last);
    const cells = [catalogue.cancelable_cells]types.Value{ .{ .integer = @backingInt(cancelable_type) }, .{ .integer = catalogue.cancelable_active }, callback, .{ .object = event }, last, .{ .boolean = false }, number };
    const made: types.Value = .{ .object = .{ .value_type = cancelable_type, .id = try source.allocate(&cells) } };
    switch (last) {
        .object => |previous| try source.write(previous.id + catalogue.cancelable_after, made, false),
        else => try source.write(event.id + catalogue.subscription_first, made, false),
    }
    try source.write(event.id + catalogue.subscription_last, made, false);
    try source.write(event.id + catalogue.subscription_count, .{ .integer = number.integer + 1 }, false);
    return made;
}

/// P3.9 (C111, C112): an active subscription leaves its event's list, keeping the link to the
/// one after it; an ended one stays as it is.
fn referenceUnsubscribe(source: *source_state.ReferenceState, subscription: types.ObjectRef) source_state.Error!void {
    if ((try source.read(subscription.id + catalogue.cancelable_state)).integer == catalogue.cancelable_canceled) return;
    const event = (try source.read(subscription.id + catalogue.cancelable_event)).object;
    const before = try source.read(subscription.id + catalogue.cancelable_before);
    const after = try source.read(subscription.id + catalogue.cancelable_after);
    switch (before) {
        .object => |previous| try source.write(previous.id + catalogue.cancelable_after, after, false),
        else => try source.write(event.id + catalogue.subscription_first, after, false),
    }
    switch (after) {
        .object => |following| try source.write(following.id + catalogue.cancelable_before, before, false),
        else => try source.write(event.id + catalogue.subscription_last, before, false),
    }
    try source.write(subscription.id + catalogue.cancelable_state, .{ .integer = catalogue.cancelable_canceled }, false);
}

/// P3.9 (C109, C112, C114): from `from` on along the list, the first subscription that is active
/// and numbered below `limit`; one unit of fuel for each one reached.
fn referenceNextSubscription(source: *const source_state.ReferenceState, from: types.Value, limit: i64, remaining: *u64) union(enum) { found: types.ObjectRef, none, failed: types.Diagnostic.Code } {
    var at = from;
    while (true) {
        const subscription = switch (at) {
            .object => |object| object,
            else => return .none,
        };
        if ((source.read(subscription.id + catalogue.cancelable_number) catch unreachable).integer >= limit) return .none;
        if (remaining.* < 1) return .{ .failed = .work_limit };
        remaining.* -= 1;
        if ((source.read(subscription.id + catalogue.cancelable_state) catch unreachable).integer == catalogue.cancelable_active) return .{ .found = subscription };
        at = source.read(subscription.id + catalogue.cancelable_after) catch unreachable;
    }
}

/// P3.9: pushes the callback of the next subscription of the `event_notify` the frame on top
/// stands at, returning to `return_to`, with the node's one argument; `done` when none is left.
fn referenceNotifyFrom(p: types.Program, frames: *call_frames.ReferenceStorage, members: []const types.Value, source: *const source_state.ReferenceState, n: types.Invoke, from: types.Value, return_to: u32, remaining: *u64) union(enum) { pushed, done, failed: types.Diagnostic.Code } {
    const at = frames.depth - 1;
    const subscription = switch (referenceNextSubscription(source, from, frames.notify_limits[at], remaining)) {
        .found => |found| found,
        .none => return .done,
        .failed => |code| return .{ .failed = code },
    };
    frames.notify_cursors[at] = subscription;
    const callback = (source.read(subscription.id + catalogue.cancelable_callback) catch unreachable).callable;
    const caller = frames.values[frames.frames[at].base..return_to];
    if (referencePush(p, .{ .function = callback.function, .arguments = n.arguments, .captures = callback.captures }, p.function_arguments, caller, members, return_to, frames)) |code| return .{ .failed = code };
    return .pushed;
}

/// A hidden cell of an event: written only by the scheduler, at region depth 0, where the root
/// region keeps no record.
fn referenceEventCell(source: *const source_state.ReferenceState, event: types.ObjectRef, at: u32) i64 {
    return (source.read(event.id + at) catch unreachable).integer;
}
fn referenceSetEventCell(source: *source_state.ReferenceState, event: types.ObjectRef, at: u32, value: i64) void {
    std.debug.assert(source.depth == 1);
    source.write(event.id + at, .{ .integer = value }, false) catch unreachable;
}

/// The task in `slot` joins the end of the event's waiters, which its cells count and name by
/// their first and last sequences.
fn referenceJoinEvent(s: *ReferenceScheduler, source: *source_state.ReferenceState, event: types.ObjectRef, slot: u32) void {
    const waiting = referenceEventCell(source, event, catalogue.event_waiting);
    if (waiting == 0) {
        referenceSetEventCell(source, event, catalogue.event_first, @intCast(s.tasks[slot].sequence));
    } else {
        const last = referenceIndexFind(s, @intCast(referenceEventCell(source, event, catalogue.event_last))).?;
        s.tasks[last].next_waiter = slot;
        s.tasks[slot].prior_waiter = last;
    }
    referenceSetEventCell(source, event, catalogue.event_last, @intCast(s.tasks[slot].sequence));
    referenceSetEventCell(source, event, catalogue.event_waiting, waiting + 1);
}

/// `Signal` at region depth 0 (RFC-0082, Q1): every task waiting on the event now is appended
/// to the ready queue in the order it began to wait, each to resume with `value`; one unit of
/// fuel per task woken. With none waiting the value is dropped: a rendezvous, not a mailbox.
fn referenceSignal(s: *ReferenceScheduler, source: *source_state.ReferenceState, event: types.ObjectRef, value: types.Value, remaining: *u64) ?types.Diagnostic.Code {
    const waiting = referenceEventCell(source, event, catalogue.event_waiting);
    std.debug.assert(waiting >= 0);
    if (remaining.* < @as(u64, @intCast(waiting))) return .work_limit;
    remaining.* -= @intCast(waiting);
    // P3.9 (C104): a sticky event latches the value, which every later `Await` gets at once.
    if (catalogue.definition(event.value_type, s.event_definitions).?.event.kind == .sticky) {
        referenceSetEventCell(source, event, catalogue.sticky_latch, 1);
        source.write(event.id + catalogue.sticky_value, value, false) catch unreachable;
    }
    if (waiting == 0) return null;
    var slot = referenceIndexFind(s, @intCast(referenceEventCell(source, event, catalogue.event_first))).?;
    var woken: i64 = 0;
    while (true) {
        const next = s.tasks[slot].next_waiter;
        std.debug.assert(s.tasks[slot].state == .waiting and s.tasks[slot].wait == .event);
        referenceReadyPush(s, slot, value);
        woken += 1;
        if (next == no_task) break;
        slot = next;
    }
    std.debug.assert(woken == waiting);
    referenceSetEventCell(source, event, catalogue.event_waiting, 0);
    referenceSetEventCell(source, event, catalogue.event_first, 0);
    referenceSetEventCell(source, event, catalogue.event_last, 0);
    return null;
}

/// The index from sequence to slot (P3.2): appended at each spawn, in ascending order, and
/// compacted when full; a task that ends leaves a gap, and gaps at the end are dropped.
fn referenceIndexAdd(s: *ReferenceScheduler, sequence: u64, slot: u32) void {
    if (s.indexed == s.by_sequence.len) {
        var kept: u32 = 0;
        for (s.by_sequence[0..s.indexed]) |entry| if (entry.slot != no_task) {
            s.by_sequence[kept] = entry;
            kept += 1;
        };
        // At most every live task but this one is listed: half the room or less.
        std.debug.assert(kept < types.limits.tasks);
        s.indexed = kept;
    }
    std.debug.assert(s.indexed == 0 or s.by_sequence[s.indexed - 1].sequence < sequence);
    s.by_sequence[s.indexed] = .{ .sequence = sequence, .slot = slot };
    s.indexed += 1;
}
fn referenceIndexAt(s: *const ReferenceScheduler, sequence: u64) ?u32 {
    var low: u32 = 0;
    var high: u32 = s.indexed;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (s.by_sequence[middle].sequence < sequence) low = middle + 1 else high = middle;
    }
    if (low == s.indexed or s.by_sequence[low].sequence != sequence) return null;
    return low;
}
fn referenceIndexFind(s: *const ReferenceScheduler, sequence: u64) ?u32 {
    const at = referenceIndexAt(s, sequence) orelse return null;
    const slot = s.by_sequence[at].slot;
    return if (slot == no_task) null else slot;
}
fn referenceIndexDrop(s: *ReferenceScheduler, sequence: u64) void {
    const at = referenceIndexAt(s, sequence).?;
    std.debug.assert(s.by_sequence[at].slot != no_task);
    s.by_sequence[at].slot = no_task;
    while (s.indexed != 0 and s.by_sequence[s.indexed - 1].slot == no_task) s.indexed -= 1;
}

// P3.3: `Sync` and `Race`, cancellation requests and unwinding.

/// Starts the next arm of the expression of the task in `parent`, whose frame is on top at the
/// expression's site: one unit of fuel for the creation, a slot, the next sequence, and its
/// entry frame on top, handed off to (S2). The arm's closure is the expression's operand.
fn referenceArmStart(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []const types.Value, pool: *const run_strings.Pool, source: ?*const source_state.ReferenceState, parent: u32, remaining: *u64) ?types.Diagnostic.Code {
    const record = &s.tasks[parent].record;
    std.debug.assert(record.starting and record.started < record.arms and record.winner == no_task);
    const top = frames.frames[frames.depth - 1];
    std.debug.assert(top.function == record.function and top.cursor == record.pc + 1);
    const arms = p.function_nodes[p.functions[record.function].body.start + record.pc].node.kind.structured.arms;
    const closure = frames.values[top.base + p.function_arguments[arms.start + record.started]];
    if (remaining.* < 1) return .work_limit;
    remaining.* -= 1;
    const slot = referenceTaskTake(s) orelse return .task_limit;
    s.sequence += 1;
    s.tasks[slot] = .{ .state = .running, .sequence = s.sequence, .closure = closure, .origin = s.tasks[parent].origin, .kind = .arm, .parent = parent };
    referenceIndexAdd(s, s.sequence, slot);
    if (record.last_arm == no_task) record.first_arm = slot else s.tasks[record.last_arm].next_arm = slot;
    record.last_arm = slot;
    record.started += 1;
    return referenceTaskStart(p, s, frames, control, members, pool, source, slot, false, 0);
}

/// Whether the expression `record` can complete: every arm of a `Sync` completed, or a `Race`
/// was won and every arm it started is settled. One asked to cancel yields cancelled instead.
fn referenceRecordDone(record: *const call_frames.ReferenceRecord) bool {
    if (record.canceling) return false;
    // P3.6: an arm's exit abandoned it; it is over when the arms it started are settled.
    if (record.exited) return record.settled == record.started;
    return switch (record.kind) {
        .sync => record.settled == record.arms,
        // A resolved `Rush` keeps only its settled arms (P3.4): the others went to the frame.
        .race, .rush => record.winner != no_task and record.settled == record.started,
    };
}

/// The tuple of a `Sync`'s results, in arm order: an aggregate of one member per arm, charged
/// as one, built where the expression yields.
fn referenceSyncTuple(p: types.Program, s: *const ReferenceScheduler, record: *const call_frames.ReferenceRecord, members: []types.Value, member_count: *usize, remaining: *u64) union(enum) { ok: types.Value, failed: types.Diagnostic.Code } {
    std.debug.assert(record.kind == .sync and record.settled == record.arms);
    if (remaining.* < record.arms) return .{ .failed = .work_limit };
    remaining.* -= record.arms;
    if (record.arms > @min(members.len, types.limits.aggregate_elements) - member_count.*) return .{ .failed = .aggregate_limit };
    const start = member_count.*;
    var arm = record.first_arm;
    while (arm != no_task) : (arm = s.tasks[arm].next_arm) {
        std.debug.assert(s.tasks[arm].state == .settled and s.tasks[arm].completed);
        members[member_count.*] = s.tasks[arm].result;
        member_count.* += 1;
    }
    std.debug.assert(member_count.* - start == record.arms);
    const node = p.function_nodes[p.functions[record.function].body.start + record.pc].node;
    return .{ .ok = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = @intCast(start), .end = @intCast(member_count.*) } } } };
}

/// The arms of an expression that is over leave with it, in order: their slots are free.
fn referenceArmsRelease(s: *ReferenceScheduler, record: *call_frames.ReferenceRecord) void {
    var arm = record.first_arm;
    while (arm != no_task) {
        const next = s.tasks[arm].next_arm;
        std.debug.assert(s.tasks[arm].state == .settled);
        referenceTaskRelease(s, arm);
        arm = next;
    }
    record.first_arm = no_task;
    record.last_arm = no_task;
}

/// The start phase of the expression of the task in `parent` goes on, with its frame on top:
/// the next arm starts, unless the expression is resolved or every arm has started. Then the
/// expression completes at once, its value the site's, or the task waits for its arms.
fn referenceStartPhase(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, pool: *const run_strings.Pool, source: ?*source_state.ReferenceState, parent: u32, remaining: *u64) ReferencePhase {
    const record = &s.tasks[parent].record;
    const span = referenceSiteSpan(p, record.function, record.pc);
    std.debug.assert(record.starting);
    // P3.7: an arm asked the task running the expression to cancel while it ran (it awaited a
    // cancelled task, or it holds that task's handle): no arm starts after it.
    if (s.tasks[parent].flagged) return referenceStartCanceled(p, s, frames, control, members, member_count, source, parent, span, remaining);
    if (record.started < record.arms and record.winner == no_task) {
        if (referenceArmStart(p, s, frames, control, members[0..member_count.*], pool, source, parent, remaining)) |code| return .{ .failed = .{ .span = span, .code = code } };
        return .started;
    }
    record.starting = false;
    if (referenceRecordDone(record) and record.exited) {
        // P3.6: the site yields the pending exit to its check at once.
        const pending = s.tasks[record.winner].result;
        referenceArmsRelease(s, record);
        const top = &frames.frames[frames.depth - 1];
        std.debug.assert(top.function == record.function and top.cursor == record.pc + 1);
        if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
        control.calls[control.call_count] = .{ .function = top.function, .pc = record.pc, .value = pending, .kind = .resume_exited };
        control.call_count += 1;
        s.exited_now = true;
        s.exited_value = pending;
        return .completed;
    }
    if (referenceRecordDone(record)) {
        const value = switch (record.kind) {
            .race, .rush => s.tasks[record.winner].result,
            .sync => switch (referenceSyncTuple(p, s, record, members, member_count, remaining)) {
                .ok => |tuple| tuple,
                .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
            },
        };
        referenceArmsRelease(s, record);
        const top = &frames.frames[frames.depth - 1];
        std.debug.assert(top.function == record.function and top.cursor == record.pc + 1);
        if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
        control.calls[control.call_count] = .{ .function = top.function, .pc = record.pc, .value = value };
        control.call_count += 1;
        frames.values[top.base + record.pc] = value;
        return .completed;
    }
    // Some arm is still running: the task waits on its expression.
    const leave = referenceLeaving(s, frames);
    switch (referenceSuspend(p, s, frames, control, source.?, members[0..member_count.*], record.pc, .{ .record = record.arms }, remaining)) {
        .ok => {},
        .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
    }
    return .{ .waits = leave };
}

const ReferencePhase = union(enum) { started, completed, waits: ReferenceLeave, failed: types.Diagnostic };

/// The start phase of the expression of `parent`, which was asked to cancel while an arm ran,
/// ends (P3.7): the expression is cancelled, as when a request reaches a task waiting on it (its
/// started arms not settled are asked, in arm order), and the site yields cancelled at once if
/// every started arm is settled; otherwise the task waits on the expression, and is restored to
/// yield cancelled. A resolved `Rush` has handed its losers to the frame already (the RFC's
/// "Rush exception").
fn referenceStartCanceled(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, source: ?*source_state.ReferenceState, parent: u32, span: types.Span, remaining: *u64) ReferencePhase {
    const record = &s.tasks[parent].record;
    record.starting = false;
    std.debug.assert(!record.canceling and s.requests == no_task);
    record.canceling = true;
    referencePushArms(s, record);
    if (referenceRequests(s, source.?, remaining)) |code| return .{ .failed = .{ .span = span, .code = code } };
    if (record.settled == record.started) {
        referenceArmsRelease(s, record);
        const top = &frames.frames[frames.depth - 1];
        std.debug.assert(top.function == record.function and top.cursor == record.pc + 1);
        if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = span, .code = .call_trace_limit } };
        const yielded = referenceCanceledAt(s, control, record.function, record.pc);
        std.debug.assert(yielded);
        return .completed;
    }
    const leave = referenceLeaving(s, frames);
    switch (referenceSuspend(p, s, frames, control, source.?, members[0..member_count.*], record.pc, .{ .record = record.arms }, remaining)) {
        .ok => {},
        .failed => |code| return .{ .failed = .{ .span = span, .code = code } },
    }
    return .{ .waits = leave };
}

/// The arm in `slot`, whose entry frame `function` ended, settled: completed with `result`, or
/// cancelled. Its expression learns it; the first completion resolves a `Race`, whose other
/// started arms are asked to cancel, in arm order; and a task waiting on an expression that is
/// over is ready.
fn referenceArmSettled(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: *source_state.ReferenceState, members: []const types.Value, slot: u32, function: u32, result: types.Value, canceled: bool, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(control.effects.depth == 0);
    const task = &s.tasks[slot];
    std.debug.assert(task.kind == .arm and task.state == .running);
    if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .call_trace_limit;
    // P3.4: the task below it on the stack runs again.
    std.debug.assert(s.current == slot);
    s.current = task.below;
    const f = p.functions[function];
    control.calls[control.call_count] = .{ .function = function, .pc = f.body.end - f.body.start, .value = if (canceled) .{ .boolean = false } else result, .kind = .settle };
    control.call_count += 1;
    task.state = .settled;
    task.completed = !canceled;
    task.result = result;
    if (canceled) s.canceled += 1 else s.completed += 1;
    const parent = task.parent;
    const record = &s.tasks[parent].record;
    record.settled += 1;
    // P3.6: an arm that ended with a pending exit abandons an expression nothing resolved: its
    // other started arms are asked to cancel, in arm order, and no arm starts after it.
    const exited = !canceled and task.exited;
    if (exited and record.winner == no_task and !record.canceling) {
        record.winner = slot;
        record.exited = true;
        referencePushArms(s, record);
        if (referenceRequests(s, source, remaining)) |code| return code;
    }
    if (!canceled and !exited and record.kind == .race and record.winner == no_task and !record.canceling) {
        record.winner = slot;
        referencePushArms(s, record);
        if (referenceRequests(s, source, remaining)) |code| return code;
    }
    // P3.4: the first completion resolves a `Rush`, whose other started arms go on, owned by
    // the frame that runs it.
    if (!canceled and !exited and record.kind == .rush and record.winner == no_task and !record.canceling) {
        record.winner = slot;
        referenceAdopt(p, s, frames, parent);
    }
    // P3.7: an arm cancelled from outside its expression (it awaited a cancelled task) asks the
    // task running the expression to cancel, unless the expression is already cancelling or
    // resolved, which take such an arm for a loser.
    if (canceled and record.winner == no_task and !record.canceling) {
        std.debug.assert(s.requests == no_task);
        s.requests = parent;
        s.tasks[parent].request_next = no_task;
        if (referenceRequests(s, source, remaining)) |code| return code;
    }
    const waiting = s.tasks[parent].state == .waiting and s.tasks[parent].wait == .record;
    if (waiting and record.settled == record.started and (record.canceling or referenceRecordDone(record))) referenceReadyPush(s, parent, .{ .boolean = false });
    return null;
}

/// Puts the started arms of `record` that are not settled on top of the stack of requests,
/// in arm order: the first is asked first, and what it waits on before the next (RFC-0082,
/// "Order": children before their siblings, as the prototype's recursion asks them).
fn referencePushArms(s: *ReferenceScheduler, record: *const call_frames.ReferenceRecord) void {
    var first: u32 = no_task;
    var last: u32 = no_task;
    var arm = record.first_arm;
    while (arm != no_task) : (arm = s.tasks[arm].next_arm) {
        if (s.tasks[arm].state == .settled) continue;
        if (last == no_task) first = arm else s.tasks[last].request_next = arm;
        last = arm;
    }
    if (last == no_task) return;
    s.tasks[last].request_next = s.requests;
    s.requests = first;
}

/// Makes the cancellation requests on the stack, one unit of fuel each (RFC-0082, "Fuel"). A
/// request to a settled or already flagged task does nothing more. Otherwise it flags the task
/// and acts on its wait: a sleeper's timer goes, an awaiter leaves its list, and either is
/// ready to yield cancelled; a task waiting on an expression marks it canceling and its arms
/// are asked in turn, before any task asked after it. The stack makes this a loop, so a tree
/// of any depth is cancelled in bounded native stack.
///
/// In P3.3 a request only reaches a task that waits or is ready. Requests come from the
/// resolution of a `Race`, to arms that started before the winner and left the stack, and
/// from a request to a task waiting on an expression, to its arms; a task on the active
/// stack is never an arm of either: the arms of an expression run one at a time and a task
/// handed off to runs above its creator.
fn referenceRequests(s: *ReferenceScheduler, source: *source_state.ReferenceState, remaining: *u64) ?types.Diagnostic.Code {
    while (s.requests != no_task) {
        const slot = s.requests;
        const task = &s.tasks[slot];
        s.requests = task.request_next;
        task.request_next = no_task;
        if (remaining.* < 1) {
            s.requests = no_task;
            return .work_limit;
        }
        remaining.* -= 1;
        if (task.state == .settled or task.flagged) continue;
        task.flagged = true;
        switch (task.state) {
            // Restored, it yields cancelled.
            .ready => {},
            .waiting => switch (task.wait) {
                .sleep => {
                    if (task.deadline != never) referenceTimerRemove(s, slot);
                    referenceReadyPush(s, slot, .{ .boolean = false });
                },
                .event => {
                    referenceLeaveEvent(s, source, task.target.object, slot);
                    referenceReadyPush(s, slot, .{ .boolean = false });
                },
                .task => {
                    referenceLeaveAwaiters(s, slot);
                    referenceReadyPush(s, slot, .{ .boolean = false });
                },
                .record => {
                    task.record.canceling = true;
                    referencePushArms(s, &task.record);
                },
                // P3.4: its frame is already ending, and asked its own tasks; the flag waits for
                // its next site.
                .frame_end => {},
                // RFC-0084, P4.7: only a `Cancel` of a reaction's handle asks a reaction, and
                // `referenceCancel` does that itself. P4.6: a task at an `Await`
                // stops waiting, its entries let go, a unit each, to yield cancelled.
                .guard => {
                    std.debug.assert(!reactionTask(task));
                    const store = &@as(*call_frames.ReferenceStorage, @fieldParentPtr("scheduler", s)).live;
                    live_reference.settle(store, source);
                    live_reference.observerRelease(store, source, slot, remaining) catch {
                        s.requests = no_task;
                        return .work_limit;
                    };
                    referenceReadyPush(s, slot, .{ .boolean = false });
                },
            },
            // P3.7: a task on the active stack (running on top, or below a task it handed off
            // to), or a committed start still waiting for its turn, notices the flag at its next
            // site. No start is held by an open region when a request is made: requests are
            // made at depth 0.
            .running, .queued => {},
            .free, .pending, .settled => unreachable,
        }
    }
    return null;
}
/// `T.Cancel()` (P3.7): a request to the task of the handle, one unit of fuel, also when that
/// task has settled and its slot is gone.
fn referenceCancel(s: *ReferenceScheduler, source: *source_state.ReferenceState, handle: types.ObjectRef, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(s.requests == no_task and source.depth == 1);
    const phase = (source.read(handle.id + catalogue.task_state) catch unreachable).integer;
    if (phase != catalogue.task_active) {
        if (remaining.* < 1) return .work_limit;
        remaining.* -= 1;
        return null;
    }
    const sequence: u64 = @intCast((source.read(handle.id + catalogue.task_sequence) catch unreachable).integer);
    const slot = referenceIndexFind(s, sequence).?;
    // RFC-0084, P4.7: a request to a reaction does what N6 says.
    if (reactionTask(&s.tasks[slot])) return referenceCancelReaction(s, source, slot, remaining);
    s.requests = slot;
    s.tasks[s.requests].request_next = no_task;
    return referenceRequests(s, source, remaining);
}

/// `Await` of a cancelled task (P3.7, Q3): a request to the awaiter's own task, one unit of fuel,
/// which flags it, and the site at `pc` of `function` yields cancelled at once, as at its entry.
fn referenceAwaitCanceled(s: *ReferenceScheduler, control: *types.ControlStorage, function: u32, pc: u32, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(s.current != no_task and !s.tasks[s.current].flagged);
    if (remaining.* < 1) return .work_limit;
    remaining.* -= 1;
    s.tasks[s.current].flagged = true;
    const yielded = referenceCanceledAt(s, control, function, pc);
    std.debug.assert(yielded);
    return null;
}

/// RFC-0084, P4.7 (N6): a request to the reaction in `slot`, one unit. Waiting on its guard, it
/// settles cancelled at once, its entries let go, a unit each. Held for its turn in a drain, it
/// settles cancelled at once and its start will do nothing. Firing (only a task its body handed
/// off to can ask it), it is flagged, and the end of its body decides. Only `T.Cancel()` asks a
/// reaction: no other source of requests reaches one.
fn referenceCancelReaction(s: *ReferenceScheduler, source: *source_state.ReferenceState, slot: u32, remaining: *u64) ?types.Diagnostic.Code {
    if (remaining.* < 1) return .work_limit;
    remaining.* -= 1;
    const task = &s.tasks[slot];
    if (task.flagged) return null;
    switch (task.state) {
        .running => {
            task.flagged = true;
            return null;
        },
        .waiting => {
            std.debug.assert(task.wait == .guard);
            const store = &@as(*call_frames.ReferenceStorage, @fieldParentPtr("scheduler", s)).live;
            live_reference.settle(store, source);
            live_reference.observerRelease(store, source, slot, remaining) catch return .work_limit;
        },
        // It never starts, but it was made and is cancelled: it counts as created (C73).
        .queued => s.created += 1,
        .free, .pending, .ready, .settled => unreachable,
    }
    return referenceReactionCanceled(s, source, slot, remaining);
}

/// The reaction in `slot` settles cancelled (N6): its handle says so and keeps no result, it
/// counts in `canceled`, and each task awaiting it is asked to cancel, first come first, a unit
/// each (Q3). Its slot is free, unless a notification for it is still pending or its start is
/// still queued: then it stays settled until the delivery loop or the drain reaches it, which
/// does nothing more, so that no other task takes the slot that entry names (C74).
fn referenceReactionCanceled(s: *ReferenceScheduler, source: *source_state.ReferenceState, slot: u32, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(source.depth == 1 and s.requests == no_task);
    const task = &s.tasks[slot];
    // At region depth 0 the root region keeps no record: the scheduler's writes are never undone.
    source.write(task.handle.object.id + catalogue.task_state, .{ .integer = catalogue.task_canceled }, false) catch unreachable;
    s.canceled += 1;
    var awaiter = task.awaiter_first;
    while (awaiter != no_task) : (awaiter = s.tasks[awaiter].next_waiter) {
        std.debug.assert(s.tasks[awaiter].state == .waiting and s.tasks[awaiter].wait == .task);
        s.tasks[awaiter].request_next = s.tasks[awaiter].next_waiter;
    }
    s.requests = task.awaiter_first;
    if (referenceRequests(s, source, remaining)) |code| return code;
    std.debug.assert(task.awaiter_first == no_task);
    const store = &@as(*call_frames.ReferenceStorage, @fieldParentPtr("scheduler", s)).live;
    if (task.state == .queued or (task.state == .waiting and store.observers[slot].pending)) {
        task.state = .settled;
    } else referenceTaskRelease(s, slot);
    return null;
}

/// The clock in seconds (P3.7): `now / R` in binary64, the same division in every implementation.
fn referenceElapsed(s: *const ReferenceScheduler) f64 {
    @setFloatMode(.strict);
    return @as(f64, @floatFromInt(s.now)) / @as(f64, @floatFromInt(s.tick_rate));
}

/// The spawned task in `slot`, whose entry frame `function` ended by `cancel_exit`, settled
/// cancelled (P3.7): its handle says so and keeps no result, and each task awaiting it is asked
/// to cancel, in the order they began to wait (Q3), a unit each; its slot is free.
fn referenceSettleCanceled(p: types.Program, s: *ReferenceScheduler, control: *types.ControlStorage, source: *source_state.ReferenceState, members: []const types.Value, slot: u32, function: u32, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(control.effects.depth == 0 and source.depth == 1 and s.requests == no_task);
    const task = &s.tasks[slot];
    std.debug.assert(task.state == .running and task.kind == .spawn and task.holder == no_task);
    if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .call_trace_limit;
    std.debug.assert(s.current == slot);
    s.current = task.below;
    // At region depth 0 the root region keeps no record: the scheduler's writes are never undone.
    source.write(task.handle.object.id + catalogue.task_state, .{ .integer = catalogue.task_canceled }, false) catch unreachable;
    const f = p.functions[function];
    control.calls[control.call_count] = .{ .function = function, .pc = f.body.end - f.body.start, .value = .{ .boolean = false }, .kind = .settle };
    control.call_count += 1;
    s.canceled += 1;
    var awaiter = task.awaiter_first;
    while (awaiter != no_task) : (awaiter = s.tasks[awaiter].next_waiter) {
        std.debug.assert(s.tasks[awaiter].state == .waiting and s.tasks[awaiter].wait == .task);
        s.tasks[awaiter].request_next = s.tasks[awaiter].next_waiter;
    }
    s.requests = task.awaiter_first;
    if (referenceRequests(s, source, remaining)) |code| return code;
    std.debug.assert(task.awaiter_first == no_task);
    referenceTaskRelease(s, slot);
    return null;
}

/// The task in `slot` leaves the waiters of `event`, whose cells name the first and the last.
fn referenceLeaveEvent(s: *ReferenceScheduler, source: *source_state.ReferenceState, event: types.ObjectRef, slot: u32) void {
    const task = &s.tasks[slot];
    const waiting = referenceEventCell(source, event, catalogue.event_waiting);
    std.debug.assert(waiting > 0);
    if (task.prior_waiter != no_task) s.tasks[task.prior_waiter].next_waiter = task.next_waiter else referenceSetEventCell(source, event, catalogue.event_first, if (task.next_waiter == no_task) 0 else @intCast(s.tasks[task.next_waiter].sequence));
    if (task.next_waiter != no_task) s.tasks[task.next_waiter].prior_waiter = task.prior_waiter else referenceSetEventCell(source, event, catalogue.event_last, if (task.prior_waiter == no_task) 0 else @intCast(s.tasks[task.prior_waiter].sequence));
    referenceSetEventCell(source, event, catalogue.event_waiting, waiting - 1);
    task.next_waiter = no_task;
    task.prior_waiter = no_task;
}

/// The task in `slot` leaves the awaiters of the task it awaits.
fn referenceLeaveAwaiters(s: *ReferenceScheduler, slot: u32) void {
    const task = &s.tasks[slot];
    const awaited = &s.tasks[task.awaited];
    if (task.prior_waiter != no_task) s.tasks[task.prior_waiter].next_waiter = task.next_waiter else awaited.awaiter_first = task.next_waiter;
    if (task.next_waiter != no_task) s.tasks[task.next_waiter].prior_waiter = task.prior_waiter else awaited.awaiter_last = task.prior_waiter;
    task.next_waiter = no_task;
    task.prior_waiter = no_task;
}

// P3.4: `Rush` and `Branch`, the tasks a frame owns, and the wait at a frame's end.

/// Whether the task running was asked to cancel (P3.4: while it waited at a frame's end, which
/// went on), so that the site `pc` of `function` yields cancelled at once: a `resume_canceled`
/// step with its sequence and no `suspend` before it, its register unwritten, its check next.
fn referenceCanceledAt(s: *ReferenceScheduler, control: *types.ControlStorage, function: u32, pc: u32) bool {
    if (s.current == no_task or !s.tasks[s.current].flagged) return false;
    // Every frame of a task is traced, and the site's own step was made room for.
    control.calls[control.call_count] = .{ .function = function, .pc = pc, .value = .{ .integer = @intCast(s.tasks[s.current].sequence) }, .kind = .resume_canceled };
    control.call_count += 1;
    s.canceled_now = true;
    return true;
}

/// `branch` of `closure` in the frame on top, whose node's register is `destination`: one unit
/// of fuel for the creation, a slot, the next sequence, a place at the end of the frame's list
/// of the tasks it owns, and its entry frame on top, handed off to (S2). Its handle is the unit
/// value `unit`, which the frame gets when the task first leaves the stack.
fn referenceBranch(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []const types.Value, pool: *const run_strings.Pool, source: ?*const source_state.ReferenceState, closure: types.Value, unit: types.Type, origin: u32, destination: u32, remaining: *u64) ?types.Diagnostic.Code {
    std.debug.assert(control.effects.depth == 0 and s.current != no_task);
    if (remaining.* < 1) return .work_limit;
    remaining.* -= 1;
    const slot = referenceTaskTake(s) orelse return .task_limit;
    s.sequence += 1;
    const owner = frames.depth - 1;
    const holder = s.current;
    s.tasks[slot] = .{ .state = .running, .sequence = s.sequence, .handle = .{ .aggregate = .{ .value_type = unit, .elements = .{ .start = 0, .end = 0 } } }, .closure = closure, .origin = origin, .kind = .branch, .holder = holder, .holder_frame = owner - s.tasks[holder].entry_at, .prior_owned = frames.owned_lasts[owner] };
    referenceIndexAdd(s, s.sequence, slot);
    if (frames.owned_lasts[owner] == no_task) frames.owned_firsts[owner] = slot else s.tasks[frames.owned_lasts[owner]].next_owned = slot;
    frames.owned_lasts[owner] = slot;
    return referenceTaskStart(p, s, frames, control, members, pool, source, slot, true, destination);
}

/// The ends of the list of tasks the frame at `index` (from the entry frame) of `holder` owns:
/// on the active stack while `holder` runs there, in the saved store while it is suspended.
const ReferenceOwned = struct { first: *u32, last: *u32 };
fn referenceOwnedList(s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, holder: u32, index: u32) ReferenceOwned {
    const task = &s.tasks[holder];
    if (task.state == .running) {
        const depth = task.entry_at + index;
        std.debug.assert(depth < frames.depth);
        return .{ .first = &frames.owned_firsts[depth], .last = &frames.owned_lasts[depth] };
    }
    std.debug.assert(index < task.frame_count);
    const saved = &s.saved[task.frame_start + index];
    return .{ .first = &saved.owned_first, .last = &saved.owned_last };
}

/// A task a frame owns (a branch, or a `Rush`'s loser) settled: completed with `result`, or
/// cancelled. It leaves the frame's list and its slot is free; a task waiting at that frame's
/// end, whose list is now empty, is ready to end it.
fn referenceOwnedSettled(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []const types.Value, slot: u32, function: u32, result: types.Value, canceled: bool) ?types.Diagnostic.Code {
    std.debug.assert(control.effects.depth == 0);
    const task = &s.tasks[slot];
    std.debug.assert(task.holder != no_task and task.state == .running and s.current == slot);
    if (control.call_count >= control.call_limit and !control.makeRoom(members)) return .call_trace_limit;
    const f = p.functions[function];
    control.calls[control.call_count] = .{ .function = function, .pc = f.body.end - f.body.start, .value = if (canceled) .{ .boolean = false } else result, .kind = .settle };
    control.call_count += 1;
    if (canceled) s.canceled += 1 else s.completed += 1;
    s.current = task.below;
    const list = referenceOwnedList(s, frames, task.holder, task.holder_frame);
    if (task.prior_owned == no_task) list.first.* = task.next_owned else s.tasks[task.prior_owned].next_owned = task.next_owned;
    if (task.next_owned == no_task) list.last.* = task.prior_owned else s.tasks[task.next_owned].prior_owned = task.prior_owned;
    const holder = &s.tasks[task.holder];
    if (list.first.* == no_task and holder.state == .waiting and holder.wait == .frame_end and task.holder_frame + 1 == holder.frame_count) referenceReadyPush(s, task.holder, .{ .boolean = true });
    referenceTaskRelease(s, slot);
    return null;
}

/// The frame on top is at its end and owns tasks: each is asked to cancel, in the order it came
/// to the frame (one unit of fuel each, cascading as any request does), and the task waits at
/// the frame's end until they are settled; none is settled by being asked. `empty` and `below`
/// say where the frame loop goes on, as for any wait.
fn referenceOwnedEnd(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, pool: *const run_strings.Pool, source: ?*source_state.ReferenceState, root_pc: u32, remaining: *u64) union(enum) { empty, below, failed: types.Diagnostic } {
    const depth = frames.depth - 1;
    const frame = frames.frames[depth];
    const f = p.functions[frame.function];
    const length = f.body.end - f.body.start;
    const span = p.function_nodes[f.body.start + f.root].node.span;
    std.debug.assert(frame.cursor == length and s.requests == no_task and frames.owned_firsts[depth] != no_task);
    var count: u32 = 0;
    var slot = frames.owned_firsts[depth];
    while (slot != no_task) : (slot = s.tasks[slot].next_owned) {
        count += 1;
        s.tasks[slot].request_next = s.tasks[slot].next_owned;
    }
    s.requests = frames.owned_firsts[depth];
    if (referenceRequests(s, source.?, remaining)) |code| return .{ .failed = .{ .span = span, .code = code } };
    std.debug.assert(frames.owned_firsts[depth] != no_task);
    return switch (referenceWaitAt(p, s, frames, control, members, member_count, pool, source.?, length, .{ .frame_end = count }, span, root_pc, remaining)) {
        .empty => .empty,
        .below => .below,
        .failed => |diagnostic| .{ .failed = diagnostic },
    };
}

/// The frame on top ended by `cancel_exit` and owns no task that is not settled: it ends as
/// cancelled, its result unwritten, and reclaims nothing. The entry frame of a task settles it
/// cancelled (it runs on the empty stack: it was restored to unwind); any other frame's caller
/// yields cancelled at its call, whose check is next. `span` places a failure of the settling.
fn referenceCanceledEnd(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, members: []types.Value, member_count: *usize, pool: *const run_strings.Pool, source: ?*source_state.ReferenceState, span: types.Span, root_pc: u32, remaining: *u64) union(enum) { empty, below, failed: types.Diagnostic } {
    const frame = frames.frames[frames.depth - 1];
    const f = p.functions[frame.function];
    std.debug.assert(frames.owned_firsts[frames.depth - 1] == no_task);
    const ending = frames.task_marks[frames.depth - 1];
    const handoff = frames.handoffs[frames.depth - 1];
    frames.count -= f.body.end - f.body.start;
    frames.depth -= 1;
    if (ending != no_task) {
        // A task's entry frame: the task is cancelled. An arm tells its expression; a branch or
        // a `Rush`'s loser leaves the frame that owns it (P3.4); a spawned task (P3.7) says so
        // in its handle.
        const task = s.tasks[ending];
        const arm_parent = if (task.kind == .arm) task.parent else no_task;
        const handle: types.Value = if (task.kind != .arm) task.handle else .{ .boolean = false };
        if (arm_parent != no_task) {
            if (referenceArmSettled(p, s, frames, control, source.?, members[0..member_count.*], ending, frame.function, .{ .boolean = false }, true, remaining)) |code| return .{ .failed = .{ .span = span, .code = code } };
        } else if (task.holder != no_task) {
            if (referenceOwnedSettled(p, s, frames, control, members[0..member_count.*], ending, frame.function, .{ .boolean = false }, true)) |code| return .{ .failed = .{ .span = span, .code = code } };
        } else if (referenceSettleCanceled(p, s, control, source.?, members[0..member_count.*], ending, frame.function, remaining)) |code| return .{ .failed = .{ .span = span, .code = code } };
        // P3.7: a task can be cancelled in its first run, before it first leaves the stack (it
        // awaited a cancelled task, or asked itself to cancel): its creator is handed what it
        // waits for, as for a task that completes there.
        if (frames.depth == 0) return .empty;
        return switch (referenceLeft(p, s, frames, control, members, member_count, pool, source, .{ .handoff = handoff, .return_to = frame.return_to, .handle = handle, .arm_parent = arm_parent }, span, root_pc, remaining)) {
            .going => .below,
            .empty => .empty,
            .failed => |diagnostic| .{ .failed = diagnostic },
        };
    }
    // The caller's call yields cancelled: its check comes next.
    const caller = frames.frames[frames.depth - 1];
    const caller_pc = frame.return_to - caller.base;
    if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .failed = .{ .span = p.function_nodes[p.functions[caller.function].body.start + caller_pc].node.span, .code = .call_trace_limit } };
    control.calls[control.call_count] = .{ .function = caller.function, .pc = caller_pc, .value = .{ .boolean = false }, .kind = .call_canceled };
    control.call_count += 1;
    s.canceled_now = true;
    return .below;
}

/// A `Rush` of the task in `parent` resolved: its started arms that are not settled leave its
/// record, in arm order, for the end of the list of the frame that runs it, where they go on as
/// its own tasks (RFC-0082, "Sync, Race, Rush"). That frame is on top of the stack when the
/// resolution falls in the start phase, and is the top saved frame of a task waiting on it.
fn referenceAdopt(p: types.Program, s: *ReferenceScheduler, frames: *call_frames.ReferenceStorage, parent: u32) void {
    const owner = &s.tasks[parent];
    const record = &owner.record;
    std.debug.assert(record.kind == .rush and record.winner != no_task);
    const index = if (owner.state == .running) frames.depth - 1 - owner.entry_at else owner.frame_count - 1;
    if (owner.state == .running) {
        const top = frames.frames[frames.depth - 1];
        std.debug.assert(top.function == record.function and top.cursor == record.pc + 1 and p.functions[top.function].detail.suspends);
    }
    const list = referenceOwnedList(s, frames, parent, index);
    var kept_first: u32 = no_task;
    var kept_last: u32 = no_task;
    var adopted: u32 = 0;
    var arm = record.first_arm;
    while (arm != no_task) {
        const task = &s.tasks[arm];
        const next = task.next_arm;
        task.next_arm = no_task;
        if (task.state == .settled) {
            if (kept_last == no_task) kept_first = arm else s.tasks[kept_last].next_arm = arm;
            kept_last = arm;
        } else {
            task.parent = no_task;
            task.holder = parent;
            task.holder_frame = index;
            task.prior_owned = list.last.*;
            task.next_owned = no_task;
            if (list.last.* == no_task) list.first.* = arm else s.tasks[list.last.*].next_owned = arm;
            list.last.* = arm;
            adopted += 1;
        }
        arm = next;
    }
    record.first_arm = kept_first;
    record.last_arm = kept_last;
    record.started -= adopted;
}

/// The result type of a handle type, or the value type of an event type (P3.2).
fn awaitedResult(program: types.Program, value_type: types.Type) ?types.Type {
    const shape = catalogue.definition(value_type, program.definitions) orelse return null;
    // P3.7: an `awaitable(T)` yields a `T` too, whether it holds a handle or an event.
    if (shape == .scheduled_interface and shape.scheduled_interface.kind == .awaitable) return shape.scheduled_interface.value;
    return if (shape == .task) shape.task.result else null;
}
/// The value type of an event; for `event_signal`, a `signalable(T)` too (P3.7), which only an
/// event can be.
fn eventValue(program: types.Program, value_type: types.Type) ?types.Type {
    const shape = catalogue.definition(value_type, program.definitions) orelse return null;
    return if (shape == .event) shape.event.value else null;
}
fn signalValue(program: types.Program, value_type: types.Type) ?types.Type {
    const shape = catalogue.definition(value_type, program.definitions) orelse return null;
    if (shape == .scheduled_interface and shape.scheduled_interface.kind == .signalable) return shape.scheduled_interface.value;
    return if (shape == .event) shape.event.value else null;
}
fn sameType(found: ?types.Type, wanted: types.Type) bool {
    return if (found) |value_type| value_type == wanted else false;
}

/// Runs a task on the empty active stack until it first waits or settles: a `spawn` at the root
/// handing off, a start the root committed, or (`restored`) a slice of the scheduler.
fn referenceSlice(p: types.Program, slot: u32, restored: bool, root_pc: u32, roots: []const types.Value, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: ?*source_state.ReferenceState, remaining: *u64) ?types.Diagnostic {
    std.debug.assert(frames.depth == 0 and frames.count == 0);
    defer {
        frames.depth = 0;
        frames.count = 0;
    }
    const s = &frames.scheduler;
    const span = if (restored) referenceSiteSpan(p, s.tasks[slot].site_function, s.tasks[slot].site_pc) else p.nodes[root_pc].span;
    // A replay follows the string pool from the steps, and is told where it stands as a slice
    // begins, as it is when a traced call does.
    if (control.trace_sink != null) for (0..2) |_| control.foldCalls(members[0..member_count.*]);
    const target = if (restored) s.tasks[slot].site_function else s.tasks[slot].closure.callable.function;
    if (restored) {
        if (referenceRestore(p, s, frames, control, members, member_count, slot, remaining)) |code| return .{ .span = span, .code = code };
    } else if (referenceTaskStart(p, s, frames, control, members[0..member_count.*], pool, source, slot, false, 0)) |code| return .{ .span = span, .code = code };
    return switch (referenceLoop(p, target, true, span, root_pc, roots, members, member_count, pool, key_work, frames, control, source, remaining)) {
        .ok => null,
        .failed => |diagnostic| diagnostic,
        // A task's entry function cannot fail, so no failure leaves it.
        .language => unreachable,
    };
}

/// The scheduler after the root (S3): ready tasks run in turn, the clock jumps to the next
/// deadline when none is, and the run is quiescent when neither is left.
fn referenceSchedule(p: types.Program, roots: []const types.Value, members: []types.Value, member_count: *usize, pool: *run_strings.Pool, key_work: *keys.Work, frames: *call_frames.ReferenceStorage, control: *types.ControlStorage, source: ?*source_state.ReferenceState, remaining: *u64) ?types.Diagnostic {
    const s = &frames.scheduler;
    std.debug.assert(frames.depth == 0 and control.effects.depth == 0 and !referenceDraining(s));
    while (true) {
        if (s.ready_head != s.ready_tail) {
            const slot = s.ready[s.ready_head % types.limits.tasks];
            s.ready_head += 1;
            if (referenceSlice(p, slot, true, s.tasks[slot].origin, roots, members, member_count, pool, key_work, frames, control, source, remaining)) |diagnostic| return diagnostic;
            continue;
        }
        if (s.timer_count == 0) break;
        // The clock jumps to the earliest deadline; every timer due then wakes, in order.
        const first = s.timers[0];
        std.debug.assert(first.deadline > s.now and first.deadline < types.Scheduler.clock_limit);
        const span = referenceSiteSpan(p, s.tasks[first.task].site_function, s.tasks[first.task].site_pc);
        if (remaining.* < 1) return .{ .span = span, .code = .work_limit };
        remaining.* -= 1;
        if (control.call_count >= control.call_limit and !control.makeRoom(members[0..member_count.*])) return .{ .span = span, .code = .call_trace_limit };
        s.now = first.deadline;
        control.calls[control.call_count] = .{ .function = 0, .pc = 0, .value = .{ .integer = @intCast(s.now) }, .kind = .tick };
        control.call_count += 1;
        while (s.timer_count != 0 and s.timers[0].deadline == s.now) {
            const timer = referenceTimerPop(s);
            const task = &s.tasks[timer.task];
            std.debug.assert(task.state == .waiting and task.deadline == s.now);
            referenceReadyPush(s, timer.task, referenceUnit(p, p.function_nodes[p.functions[task.site_function].body.start + task.site_pc].node));
        }
    }
    // Quiescent: what still waits is abandoned, and listed by sequence.
    for (s.tasks[0..s.used]) |task| {
        // A settled arm waits for nothing; its expression keeps its slot (P3.3).
        if (task.state == .free or task.state == .settled) continue;
        std.debug.assert(task.state == .waiting and task.deadline == never);
        // A reaction waits on its guard where its node made it (RFC-0084, P4.4).
        const span = if (task.kind == .upon or task.kind == .when) task.site_span else referenceSiteSpan(p, task.site_function, task.site_pc);
        s.waiting[s.waiting_count] = .{ .task = task.sequence, .kind = task.kind, .wait = task.wait, .span = span };
        s.waiting_count += 1;
    }
    std.mem.sort(types.Scheduler.Waiting, s.waiting[0..s.waiting_count], {}, struct {
        fn before(_: void, a: types.Scheduler.Waiting, b: types.Scheduler.Waiting) bool {
            return a.task < b.task;
        }
    }.before);
    return null;
}

/// Whether the program spawns tasks anywhere (RFC-0082).
pub fn spawns(program: types.Program) bool {
    for (program.nodes) |node| if (node.kind == .spawn) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .spawn) return true;
    return false;
}

// Live variables (RFC-0084, P4.1): the reference runs guards and propagations here, with the
// store of `live_reference.zig`. A guard is a frame loop of its own on top of the active stack
// (`ReferenceStorage.guard_floor`), which ends with the guard's frame. A guard cannot write, so
// no propagation starts inside one and guards never nest: the loop is at most one level deep.

/// Whether the program holds a `cell_live` anywhere, or from P4.4 a `reaction`. An IR fact,
/// worked out from the nodes.
pub fn live(program: types.Program) bool {
    for (program.nodes) |node| if (node.kind == .cell_live or node.kind == .object_live or node.kind == .reaction or node.kind == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .cell_live or entry.node.kind == .object_live or entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}

/// Whether the program holds a `reaction` (P4.4): only then does a drain take its turns one at a
/// time in the frame loop, where a reaction's start can run its guard and its body. From P4.6
/// also an `await_guard`, whose notifications a drain delivers when it ends.
pub fn reacts(program: types.Program) bool {
    for (program.nodes) |node| if (node.kind == .reaction or node.kind == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}

/// What a propagation or an establishing write needs of the frame loop it runs in. `span` is
/// the node that wrote, where its bounds fall, and `return_to` the register of that node.
const LiveRun = struct {
    p: types.Program,
    roots: []const types.Value,
    members: []types.Value,
    member_count: *usize,
    pool: *run_strings.Pool,
    key_work: *keys.Work,
    frames: *call_frames.ReferenceStorage,
    control: *types.ControlStorage,
    source: *source_state.ReferenceState,
    remaining: *u64,
    root_pc: u32,
    span: types.Span,
    return_to: u32,
};
const LiveOutcome = union(enum) { ok: types.Value, failed: types.Diagnostic };

fn liveCode(err: live_reference.Error) types.Diagnostic.Code {
    return switch (err) {
        error.LiveEdgeLimit => .live_edge_limit,
        error.WorkLimit => .work_limit,
        else => |other| source_state.diagnostic(other),
    };
}

/// Where the node that made a record is (its `origin` cell): a root node, or a node of a
/// function body, counted from one in the upper half.
fn referenceOrigin(p: types.Program, state: *const source_state.ReferenceState, record: u32) types.Span {
    const origin: u64 = @bitCast(state.cells[record + catalogue.live_origin].value.integer);
    const function = origin >> 32;
    const pc: u32 = @truncate(origin);
    if (function == 0) return p.nodes[pc].span;
    return p.function_nodes[p.functions[function - 1].body.start + pc].node.span;
}

/// Appends a step of the machine's own (RFC-0084, "Steps"), finding room for it first.
fn referenceLiveStep(run: *const LiveRun, step: types.CallStep) ?types.Diagnostic {
    const control = run.control;
    if (control.call_count >= control.call_limit and !control.makeRoom(run.members[0..run.member_count.*])) return .{ .span = run.span, .code = .call_trace_limit };
    control.calls[control.call_count] = step;
    control.call_count += 1;
    return null;
}

/// Evaluates a guard with tracking (L3): one unit of fuel, its step (`live_eval` with the record,
/// or from P4.4 `observe` with a reaction's sequence), then its frame, on top of the active
/// stack. The reads are left in the store for the caller to record.
fn referenceGuard(run: *const LiveRun, closure: types.CallableValue, kind: @FieldType(types.CallStep, "kind"), told: types.Value) LiveOutcome {
    const frames = run.frames;
    const control = run.control;
    if (run.remaining.* < 1) return .{ .failed = .{ .span = run.span, .code = .work_limit } };
    run.remaining.* -= 1;
    live_reference.settle(&frames.live, run.source);
    _ = live_reference.begin(&frames.live, run.source);
    frames.live.record.evaluations += 1;
    if (referenceLiveStep(run, .{ .function = closure.function, .pc = 0, .value = told, .kind = kind })) |diagnostic| return .{ .failed = diagnostic };
    const below = frames.depth;
    const floor = frames.guard_floor;
    defer frames.guard_floor = floor;
    // At the root the stack is empty again however the guard ends, as after a call.
    defer if (below == 0) {
        frames.depth = 0;
        frames.count = 0;
    };
    const call: types.ResolvedCall = .{ .function = closure.function, .arguments = .{ .start = 0, .end = 0 }, .captures = closure.captures };
    if (referencePush(run.p, call, run.p.function_arguments, &.{}, run.members[0..run.member_count.*], run.return_to, frames)) |code| return .{ .failed = .{ .span = run.span, .code = code } };
    referenceMarked(frames, run.pool, run.source);
    // A replay is told where the string pool stands as a guard begins at the root, as for a call.
    if (below == 0 and control.trace_sink != null) for (0..2) |_| control.foldCalls(run.members[0..run.member_count.*]);
    frames.guard_floor = below;
    const result = referenceLoop(run.p, closure.function, true, run.span, run.root_pc, run.roots, run.members, run.member_count, run.pool, run.key_work, frames, control, run.source, run.remaining);
    live_reference.end(&frames.live);
    return switch (result) {
        .ok => |value| .{ .ok = value },
        .failed => |diagnostic| .{ .failed = diagnostic },
        // A guard cannot fail: its function does not decide (admission rule 1).
        .language => unreachable,
    };
}

/// The `live_settle` step after a guard's frame: whether the target was written.
fn referenceSettled(run: *const LiveRun, function: u32, written: bool) ?types.Diagnostic {
    const f = run.p.functions[function];
    return referenceLiveStep(run, .{ .function = function, .pc = f.body.end - f.body.start, .value = .{ .boolean = written }, .kind = .live_settle });
}

/// What an establishing write attaches a record to (RFC-0084, L1): a module cell, which the
/// record owns itself, or field `place` of the instance `owner` (P4.2), at the cell `cell`.
const LiveTarget = struct { cell: u32, owner: ?types.ObjectRef, place: u32, value_type: types.Type, initialize: bool };
fn moduleTarget(p: types.Program, c: types.CellLive) LiveTarget {
    return .{ .cell = c.cell, .owner = null, .place = c.cell, .value_type = p.source_cells[c.cell].value_type, .initialize = c.initialize };
}
/// What an `object_live` attaches its guard to, by its object's type: a `var` or live-only field
/// of a class instance (RFC-0084, admission rule 2), or the value of a variable cell `ref(T)`,
/// at field 0 (RFC-0085, admission rule 6, I14), which is never live-only. Null otherwise.
const LiveField = struct { value_type: types.Type, live_only: bool };
fn liveField(p: types.Program, object_type: types.Type, field: u32) ?LiveField {
    if (catalogue.refValue(object_type, p.definitions)) |held| return if (field == 0) .{ .value_type = held, .live_only = false } else null;
    const shape = catalogue.definition(object_type, p.definitions) orelse return null;
    if (shape != .class) return null;
    const declared = catalogue.classFieldAt(object_type, field, p.definitions, p.fields) orelse return null;
    if (!declared.is_var and !declared.live_only) return null;
    return .{ .value_type = declared.value_type, .live_only = declared.live_only };
}
fn fieldTarget(object: types.ObjectRef, c: types.ObjectLive, value_type: types.Type) LiveTarget {
    return .{ .cell = object.id + 1 + c.field, .owner = object, .place = c.field, .value_type = value_type, .initialize = false };
}
/// Whether a field's value can change after its instance is built: a `var` field, or a
/// live-only one, which its guard writes (RFC-0084, L3).
fn changes(field: types.Field) bool {
    return field.is_var or field.live_only;
}

/// L2, establishing: the guard, the record, the link, the entries and the height, the value,
/// then the propagation from the cell. Yields the value the guard gave.
fn referenceEstablish(run: *const LiveRun, c: LiveTarget, closure: types.CallableValue, origin: i64) LiveOutcome {
    const store = &run.frames.live;
    const state = run.source;
    const live_type = liveRecordType(run.p, c.value_type).?;
    live_reference.settle(store, state);
    // Guards build no instance, so the record is the next one.
    const id: u32 = @intCast(state.cell_count);
    const value = switch (referenceGuard(run, closure, .live_eval, .{ .object = .{ .value_type = live_type, .id = id } })) {
        .ok => |result| result,
        .failed => |diagnostic| return .{ .failed = diagnostic },
    };
    if (referenceSettled(run, closure.function, true)) |diagnostic| return .{ .failed = diagnostic };
    live_reference.settle(store, state);
    // The record: one unit and its seven cells, as an instance of that size.
    if (run.remaining.* < 1 + catalogue.live_cells) return .{ .failed = .{ .span = run.span, .code = .work_limit } };
    run.remaining.* -= 1 + catalogue.live_cells;
    const stamp = state.live.stamp;
    const height = live_reference.heightFor(store, state, id, c.cell);
    const owner: types.ObjectRef = c.owner orelse .{ .value_type = live_type, .id = id };
    const cells = [catalogue.live_cells]types.Value{ .{ .integer = @backingInt(live_type) }, .{ .callable = closure }, .{ .integer = @intCast(stamp) }, .{ .integer = @intCast(height) }, .{ .object = owner }, .{ .integer = c.place }, .{ .integer = origin } };
    const built = state.allocate(&cells) catch |err| return .{ .failed = .{ .span = run.span, .code = source_state.diagnostic(err) } };
    std.debug.assert(built == id);
    store.record.records += 1;
    if (c.initialize) state.write(c.cell, value, true) catch |err| return .{ .failed = .{ .span = run.span, .code = source_state.diagnostic(err) } };
    live_reference.attach(store, state, c.cell, id, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
    live_reference.check(store, state, 0, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
    live_reference.append(store, state, id, stamp, 0, 0);
    live_reference.raise(store, state, id, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
    // Written whether or not it equals what the cell held.
    if (!c.initialize) state.write(c.cell, value, false) catch |err| return .{ .failed = .{ .span = run.span, .code = source_state.diagnostic(err) } };
    if (referencePropagate(run, c.cell)) |diagnostic| return .{ .failed = diagnostic };
    return .{ .ok = value };
}

/// L5: the propagation after a write of `cell`. Dirty records are taken by (height, id), each
/// counted against both bounds (the per-record one first), evaluated, its entries, stamp and
/// height recorded and the records above it raised; a comparable result equal to what the
/// target holds is not written (L6), and a written one dirties the records that read it.
fn referencePropagate(run: *const LiveRun, cell: u32) ?types.Diagnostic {
    const store = &run.frames.live;
    const state = run.source;
    live_reference.settle(store, state);
    live_reference.startPropagation(store);
    live_reference.dirty(store, state, cell, run.control.effects.depth, run.remaining) catch |err| return .{ .span = run.span, .code = liveCode(err) };
    var total: u64 = 0;
    while (live_reference.take(store, state)) |record| {
        if (live_reference.counted(store, record) > types.limits.live_record_evaluations) return .{ .span = referenceOrigin(run.p, state, record), .code = .live_unstable };
        total += 1;
        if (total > types.limits.live_evaluations) return .{ .span = run.span, .code = .live_propagation_limit };
        const guard = state.cells[record + catalogue.live_guard].value.callable;
        const record_type: types.Type = @fromBackingInt(@intCast(state.cells[record].value.integer));
        const value = switch (referenceGuard(run, guard, .live_eval, .{ .object = .{ .value_type = record_type, .id = record } })) {
            .ok => |result| result,
            .failed => |diagnostic| return diagnostic,
        };
        live_reference.settle(store, state);
        const old = live_reference.count(store, state, record);
        live_reference.check(store, state, old, run.remaining) catch |err| return .{ .span = run.span, .code = liveCode(err) };
        const stamp = state.live.stamp;
        const old_stamp = live_reference.stampOf(state, record);
        state.write(record + catalogue.live_stamp, .{ .integer = @intCast(stamp) }, false) catch |err| return .{ .span = run.span, .code = source_state.diagnostic(err) };
        live_reference.append(store, state, record, stamp, old_stamp, old);
        const target = live_reference.targetOf(state, record);
        const height = live_reference.heightFor(store, state, record, target);
        state.write(record + catalogue.live_height, .{ .integer = @intCast(height) }, false) catch |err| return .{ .span = run.span, .code = source_state.diagnostic(err) };
        live_reference.raise(store, state, record, run.remaining) catch |err| return .{ .span = run.span, .code = liveCode(err) };
        // L6: an equal value of a comparable type is not written, which charges as `==` does.
        const target_type = catalogue.definition(record_type, run.p.definitions).?.live;
        var same = false;
        if (live_reference.comparableTarget(store, target_type)) {
            if (run.remaining.* < 1) return .{ .span = run.span, .code = .work_limit };
            run.remaining.* -= 1;
            const current = state.read(target) catch unreachable;
            same = referenceCompare(.equal, value, current, run.members[0..run.member_count.*], run.key_work, run.remaining) catch |err| return .{ .span = run.span, .code = switch (err) {
                error.WorkLimit => .work_limit,
                error.ScratchUnavailable => .scratch_unavailable,
                else => .invalid_ir,
            } };
        }
        if (referenceSettled(run, guard.function, !same)) |diagnostic| return diagnostic;
        if (same) continue;
        // A propagation write: one unit, as a `cell_write`, and its readers become dirty.
        if (run.remaining.* < 1) return .{ .span = run.span, .code = .work_limit };
        run.remaining.* -= 1;
        state.write(target, value, false) catch |err| return .{ .span = run.span, .code = source_state.diagnostic(err) };
        live_reference.dirty(store, state, target, run.control.effects.depth, run.remaining) catch |err| return .{ .span = run.span, .code = liveCode(err) };
    }
    // The node that wrote records its own step next, with room found for it as for any step.
    const control = run.control;
    if (control.call_count >= control.call_limit and !control.makeRoom(run.members[0..run.member_count.*])) return .{ .span = run.span, .code = .call_trace_limit };
    return null;
}

// Reactions (RFC-0084, P4.4): `Upon` and `When` in the reference. A reaction is a task without
// frames: a slot, a handle, its guard and body closures, and, while it waits on its guard, the
// dependencies of the guard's latest evaluation (`live_reference.zig`). A write notifies it; a
// delivery point delivers what is pending; a delivery evaluates its guard again and fires its
// body when it succeeds. A body runs on top of the active stack, as the entry frame of the
// reaction's task, inside an implicit batch, and never suspends, so it returns before the
// delivery loop goes on; the loop is a small state in the store that the frame loop drives, so
// a body's own reactions nest no native frames.

/// Whether a task slot holds a reaction.
fn reactionTask(task: *const call_frames.ReferenceTask) bool {
    return task.kind == .upon or task.kind == .when;
}

/// `reaction` (N5): one unit of fuel for the creation, as a `Spawn`'s, a slot and the handle, an
/// instance with the next sequence, active and without a result; its guard and body wait in the
/// slot. It is started or held by the caller.
fn referenceReaction(run: *const LiveRun, handle_type: types.Type, r: types.Reaction, guard: types.Value, body: types.Value, origin: u32) union(enum) { ok: u32, failed: types.Diagnostic } {
    const s = &run.frames.scheduler;
    const slot = switch (referenceSpawn(run.p, handle_type, guard, origin, s, run.source, run.remaining)) {
        .ok => |slot| slot,
        .failed => |code| return .{ .failed = .{ .span = run.span, .code = code } },
    };
    const task = &s.tasks[slot];
    task.kind = if (r.kind == .upon) .upon else .when;
    task.body = body;
    task.site_span = run.span;
    live_reference.observerReset(&run.frames.live, slot);
    return .{ .ok = slot };
}

/// Starts the reaction in `slot` (N5): it is created, waits on its guard, whose first evaluation
/// is made now, and fires if that succeeded, the body's frame on top of the stack.
fn referenceReactionStart(run: *const LiveRun, slot: u32, by: call_frames.Firing) union(enum) { fired, waits, failed: types.Diagnostic } {
    const s = &run.frames.scheduler;
    const task = &s.tasks[slot];
    s.created += 1;
    task.state = .waiting;
    task.wait = .guard;
    task.deadline = never;
    switch (referenceObserve(run, slot)) {
        .ok => |succeeded| if (!succeeded) return .waits,
        .failed => |diagnostic| return .{ .failed = diagnostic },
    }
    if (referenceFire(run, slot, by)) |diagnostic| return .{ .failed = diagnostic };
    return .fired;
}

/// Evaluates the guard of the reaction in `slot` with tracking, as an `observe`, and records
/// what it read: the reaction waits on its guard with those dependencies (L4). Whether the
/// guard succeeded, that is, whether its option is present.
fn referenceObserve(run: *const LiveRun, slot: u32) union(enum) { ok: bool, failed: types.Diagnostic } {
    const store = &run.frames.live;
    const state = run.source;
    const task = &run.frames.scheduler.tasks[slot];
    const value = switch (referenceGuard(run, task.closure.callable, .observe, .{ .integer = @intCast(task.sequence) })) {
        .ok => |result| result,
        .failed => |diagnostic| return .{ .failed = diagnostic },
    };
    live_reference.settle(store, state);
    live_reference.observerCheck(store, state, slot, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
    live_reference.observerAppend(store, state, slot, state.live.stamp);
    // Admission typed the guard's result as an option.
    return .{ .ok = value.aggregate.elements.start != value.aggregate.elements.end };
}

/// RFC-0084, P4.6: the guard of the `Await` the task running stands at, evaluated with tracking
/// as an `observe` with the task's sequence, its reads recorded as the task's dependencies
/// (N7). When it holds they leave their lists at once, a unit each, as at a firing, and the
/// site yields the option's value; otherwise the task is to wait on them.
fn referenceAwait(run: *const LiveRun, guard: types.CallableValue) union(enum) { holds: types.Value, waits, failed: types.Diagnostic } {
    const store = &run.frames.live;
    const state = run.source;
    const s = &run.frames.scheduler;
    const slot = s.current;
    std.debug.assert(slot != no_task and !reactionTask(&s.tasks[slot]));
    // A task that is not waiting on a guard holds no entries and is not notified: a wait ends
    // by a delivery, which takes it off the list, or by a request, after which it never reaches
    // a site again. Its slot's entry is made so before the guard runs.
    live_reference.observerReset(store, slot);
    const value = switch (referenceGuard(run, guard, .observe, .{ .integer = @intCast(s.tasks[slot].sequence) })) {
        .ok => |result| result,
        .failed => |diagnostic| return .{ .failed = diagnostic },
    };
    live_reference.settle(store, state);
    live_reference.observerCheck(store, state, slot, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
    live_reference.observerAppend(store, state, slot, state.live.stamp);
    // Admission typed the guard's result as an option.
    const option = value.aggregate.elements;
    if (option.start == option.end) return .waits;
    live_reference.observerRelease(store, state, slot, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
    return .{ .holds = run.members[option.start] };
}

/// Fires the reaction in `slot` (N4): one unit, and one for each entry that leaves its list; it
/// stops waiting, and the `fire` step and its body's frame follow, the entry frame of its task,
/// inside a batch. At the root the body runs on the empty stack: its window is sent as a slice's.
fn referenceFire(run: *const LiveRun, slot: u32, by: call_frames.Firing) ?types.Diagnostic {
    const frames = run.frames;
    const control = run.control;
    const s = &frames.scheduler;
    const store = &frames.live;
    const task = &s.tasks[slot];
    if (run.remaining.* < 1) return .{ .span = run.span, .code = .work_limit };
    run.remaining.* -= 1;
    live_reference.observerRelease(store, run.source, slot, run.remaining) catch |err| return .{ .span = run.span, .code = liveCode(err) };
    store.record.firings += 1;
    task.state = .running;
    task.fired_by = by;
    task.fire_span = run.span;
    const body = task.body.callable;
    if (referenceLiveStep(run, .{ .function = body.function, .pc = 0, .value = .{ .integer = @intCast(task.sequence) }, .kind = .fire })) |diagnostic| return diagnostic;
    store.batch += 1;
    const below = frames.depth;
    if (referencePush(run.p, .{ .function = body.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures }, &.{}, &.{}, run.members[0..run.member_count.*], run.return_to, frames)) |code| return .{ .span = run.span, .code = code };
    referenceMarked(frames, run.pool, run.source);
    frames.task_marks[frames.depth - 1] = slot;
    // The node that made the reaction gets its handle when the body ends (S2).
    frames.handoffs[frames.depth - 1] = by == .node and below != 0;
    task.below = s.current;
    task.entry_at = below;
    s.current = slot;
    if (below == 0 and control.trace_sink != null) for (0..2) |_| control.foldCalls(run.members[0..run.member_count.*]);
    return null;
}

/// The body of the reaction in `slot`, whose entry frame `function` ended with `result`, has
/// returned (N4 step 3): an `Upon` settles with it, a `When` waits on its guard again with what
/// its guard reads now. Then what fired it goes on: a node gets the handle; the delivery loop
/// takes its next reaction; a drain delivers and takes its next turn. `run.span` is where the
/// firing's bounds fall; `destination` the register of the node, when one handed off.
fn referenceFired(run: *const LiveRun, slot: u32, function: u32, result: types.Value, handoff: bool, destination: u32, blame: types.Span) ReferenceLeft {
    const frames = run.frames;
    const control = run.control;
    const s = &frames.scheduler;
    const store = &frames.live;
    const task = &s.tasks[slot];
    std.debug.assert(store.batch != 0 and task.state == .running and s.current == slot);
    store.batch -= 1;
    const by = task.fired_by;
    const handle = task.handle;
    const site = task.site_span;
    if (task.kind == .upon) {
        // P4.7: asked while it fired, its body has finished all the same: it completes (N6).
        if (referenceSettle(run.p, s, control, run.source, run.members, run.member_count, slot, function, result)) |code| return .{ .failed = .{ .span = blame, .code = code } };
    } else if (task.flagged) {
        // P4.7 (N6): a `When` asked while it fired settles cancelled now, with the `settle`
        // step of a cancelled task, and registers no more.
        if (control.call_count >= control.call_limit and !control.makeRoom(run.members[0..run.member_count.*])) return .{ .failed = .{ .span = blame, .code = .call_trace_limit } };
        s.current = task.below;
        task.below = no_task;
        const f = run.p.functions[function];
        control.calls[control.call_count] = .{ .function = function, .pc = f.body.end - f.body.start, .value = .{ .boolean = false }, .kind = .settle };
        control.call_count += 1;
        if (referenceReactionCanceled(s, run.source, slot, run.remaining)) |code| return .{ .failed = .{ .span = blame, .code = code } };
    } else {
        // A `When` registers again after each run of its body (15:524).
        s.current = task.below;
        task.below = no_task;
        task.state = .waiting;
        task.wait = .guard;
        switch (referenceObserve(run, slot)) {
            .ok => {},
            .failed => |diagnostic| return .{ .failed = diagnostic },
        }
    }
    var next = run.*;
    switch (by) {
        .loop => {
            next.span = store.delivery_span;
            return switch (referenceDeliver(&next)) {
                .fired => .going,
                .done => referenceContinue(&next),
                .failed => |diagnostic| .{ .failed = diagnostic },
            };
        },
        .node => {
            if (handoff) {
                const parent = &frames.frames[frames.depth - 1];
                const parent_pc = destination - parent.base;
                std.debug.assert(parent.cursor == parent_pc + 1);
                if (control.call_count >= control.call_limit and !control.makeRoom(run.members[0..run.member_count.*])) return .{ .failed = .{ .span = site, .code = .call_trace_limit } };
                control.calls[control.call_count] = .{ .function = parent.function, .pc = parent_pc, .value = handle };
                control.call_count += 1;
                frames.values[destination] = handle;
            }
            next.span = site;
        },
        .start => {},
    }
    return switch (referenceDeliveryPoint(&next)) {
        .fired => .going,
        .done => referenceContinue(&next),
        .failed => |diagnostic| .{ .failed = diagnostic },
    };
}

/// What a delivery point or the delivery loop leaves: a body on top of the stack, or nothing.
const Delivered = union(enum) { fired, done, failed: types.Diagnostic };
/// A delivery point (N3): when nothing holds notifications back and something is pending, the
/// delivery loop begins here, its bounds falling at `run.span`.
fn referenceDeliveryPoint(run: *const LiveRun) Delivered {
    const store = &run.frames.live;
    if (!live_reference.deliverable(store, run.control.effects.depth)) return .done;
    store.delivering = true;
    store.delivery_span = run.span;
    store.delivery_count = 0;
    return referenceDeliver(run);
}

/// The delivery loop (N4) goes on: each pending reaction in order is counted against
/// `deliveries`, charged one unit and delivered: one that waits on its guard evaluates it again,
/// and fires if it succeeded, which leaves its body on top of the stack. Done when none is left.
fn referenceDeliver(run_in: *const LiveRun) Delivered {
    const store = &run_in.frames.live;
    const s = &run_in.frames.scheduler;
    std.debug.assert(store.delivering and store.batch == 0);
    var run = run_in.*;
    run.span = store.delivery_span;
    run.return_to = 0;
    while (live_reference.takePending(store)) |slot| {
        store.delivery_count += 1;
        if (store.delivery_count > types.limits.deliveries) return .{ .failed = .{ .span = run.span, .code = .reaction_limit } };
        if (run.remaining.* < 1) return .{ .failed = .{ .span = run.span, .code = .work_limit } };
        run.remaining.* -= 1;
        store.record.deliveries += 1;
        const task = &s.tasks[slot];
        if (referenceLiveStep(&run, .{ .function = 0, .pc = 0, .value = .{ .integer = @intCast(task.sequence) }, .kind = .deliver })) |diagnostic| return .{ .failed = diagnostic };
        // RFC-0084, P4.7: a reaction cancelled while this was pending is delivered nothing, and
        // its slot goes now (C74).
        if (task.state == .settled and reactionTask(task)) {
            referenceTaskRelease(s, slot);
            continue;
        }
        if (task.state != .waiting or task.wait != .guard) continue;
        if (!reactionTask(task)) {
            // P4.6: a task at an `Await` stops waiting, its entries let go, a unit each, and joins
            // the ready queue (S4); it evaluates its guard again when it runs (N7).
            live_reference.settle(store, run.source);
            live_reference.observerRelease(store, run.source, slot, run.remaining) catch |err| return .{ .failed = .{ .span = run.span, .code = liveCode(err) } };
            referenceReadyPush(s, slot, .{ .boolean = true });
            continue;
        }
        switch (referenceObserve(&run, slot)) {
            .ok => |succeeded| if (!succeeded) continue,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        }
        if (referenceFire(&run, slot, .loop)) |diagnostic| return .{ .failed = diagnostic };
        return .fired;
    }
    store.delivering = false;
    return .done;
}

/// What a frame that drains the commit queue does once the turn before is over: the next turn,
/// or, when none is left, the drain ends and delivers (N3). `.going` with the stack as the turn
/// left it, `.empty` when it is empty.
fn referenceContinue(run: *const LiveRun) ReferenceLeft {
    const frames = run.frames;
    if (frames.depth == 0) return .empty;
    if (!frames.drains[frames.depth - 1]) return .going;
    var next = run.*;
    next.span = frames.drain_spans[frames.depth - 1];
    return switch (referenceDrainTurn(&next)) {
        .pushed, .done => .going,
        .failed => |diagnostic| .{ .failed = diagnostic },
    };
}

/// The next turn of the drain of the frame on top (RFC-0082 C10, P4.4): the committed signals
/// before the next start are carried out, and the start takes its turn: a task by hand-off, a
/// reaction by its first evaluation, which may fire it. A reaction that does not fire leaves the
/// turn to the next start at once. When no start is left, the drain ends and delivers.
fn referenceDrainTurn(run: *const LiveRun) union(enum) { pushed, done, failed: types.Diagnostic } {
    const frames = run.frames;
    const s = &frames.scheduler;
    while (true) {
        switch (referenceNextStart(s, run.source, run.root_pc, run.remaining)) {
            .start => |slot| {
                if (reactionTask(&s.tasks[slot])) switch (referenceReactionStart(run, slot, .start)) {
                    .fired => return .pushed,
                    .waits => continue,
                    .failed => |diagnostic| return .{ .failed = diagnostic },
                };
                if (referenceTaskStart(run.p, s, frames, run.control, run.members[0..run.member_count.*], run.pool, run.source, slot, false, 0)) |code| return .{ .failed = .{ .span = run.span, .code = code } };
                return .pushed;
            },
            .none => {
                frames.drains[frames.depth - 1] = false;
                return switch (referenceDeliveryPoint(run)) {
                    .fired => .pushed,
                    .done => .done,
                    .failed => |diagnostic| .{ .failed = diagnostic },
                };
            },
            .failed => |code| return .{ .failed = .{ .span = run.span, .code = code } },
        }
    }
}

/// A firing at the root: its body's frame, pushed on the empty stack, runs until the stack is
/// empty again, the deliveries and drains it leads to with it.
fn referenceAtRoot(run: *const LiveRun, span: types.Span) ?types.Diagnostic {
    const frames = run.frames;
    std.debug.assert(frames.depth == 1);
    defer {
        frames.depth = 0;
        frames.count = 0;
    }
    return switch (referenceLoop(run.p, frames.frames[0].function, true, span, run.root_pc, run.roots, run.members, run.member_count, run.pool, run.key_work, frames, run.control, run.source, run.remaining)) {
        .ok => null,
        .failed => |diagnostic| diagnostic,
        // A body cannot fail: admission keeps `decides` out of its type.
        .language => unreachable,
    };
}
