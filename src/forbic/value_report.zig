//! Bounded, allocation-free value JSON. The whole execution and expanded output
//! are admitted before the external writer receives a byte. Aggregate traversal
//! uses an explicit stack; aliases expand only within the report profile.
const std = @import("std");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const run_strings = @import("run_strings.zig");
const catalogue = @import("aggregate_types.zig");
const keys = @import("map_keys.zig");
const array_concat = @import("array_concat.zig");
const modules = @import("modules.zig");
const scratch = @import("scratch.zig");
const native = @import("native.zig");
const effects = @import("effects.zig");
const name_index = @import("name_index.zig");
const persist_json = @import("persist_json.zig");
const persistable = @import("persistable.zig");
pub const Error = error{ InvalidExecution, ReportLimit };
pub const Limits = struct { work: u64 = types.limits.report_work, output_bytes: u64 = types.limits.report_bytes };
/// `live_bytes`: the most memory the replay of live variables held at once (RFC-0084 C17); 0
/// for a program without them.
pub const Stats = struct { work: u64, output_bytes: u64, live_bytes: u64 = 0 };
const max_depth = types.limits.user_types + 1;

/// Work charges checked value/binding descriptors, checked immediate aggregate
/// members, raw call events, root/callee schedule and constructor-copy visits,
/// source checkpoint/restoration cell copies and expanded value visits.
/// Untraced hidden constructors admit their members.
/// IR/catalogue/UTF-8 checks have the separate
/// fixed bootstrap bounds. Output bytes are exact compact JSON, including LF.
/// Input and all referenced storage must remain immutable through consumption.
pub fn validate(execution: evaluator.Execution, public_only: bool, limits: Limits) Error!Stats {
    // The replay below reads the stored witness. A `digest` run stored none and is admitted
    // by `validateReplayed`; an `off` run has no witness and cannot be reported at all.
    if (execution.trace != .full) return error.InvalidExecution;
    return admit(execution, null, public_only, limits);
}

/// `validate` for a run that kept only the count and digest of its witness. `again` runs the
/// program a second time on separate storage and streams its steps here window by window, so
/// the same replay checks them against this execution without ever holding the whole witness.
/// The stream's count and digest must equal the ones this execution claims, which also means
/// the two runs agreed on every step. Work is charged as for `validate`: per step replayed, and
/// when `limits.work` runs out the second run is stopped within a step or two, so the budget
/// bounds the whole call; the stopped run leaves the execution's string pool partly rewritten,
/// so that execution is not replayed again after `ReportLimit`.
pub fn validateReplayed(execution: evaluator.Execution, again: types.TraceProducer, public_only: bool, limits: Limits) Error!Stats {
    return switch (execution.trace) {
        .full => admit(execution, null, public_only, limits),
        .digest => if (execution.call_steps.len != 0) error.InvalidExecution else admit(execution, again, public_only, limits),
        .off => error.InvalidExecution,
    };
}

fn admit(execution: evaluator.Execution, producer: ?types.TraceProducer, public_only: bool, limits: Limits) Error!Stats {
    const program = execution.program;
    memo = .{};
    defer memo = .{};
    live_peak = 0;
    // One set of walk levels and one key table for the whole replay, not one per map checked.
    key_work = .{};
    defer key_work.release();
    // Remember how much of each aggregate has been checked (see `Memo`); without scratch
    // memory every aggregate is simply checked in full. The pool of a second run can be
    // larger while it runs than the final one, so a streamed replay reserves the capacity
    // and clears what it comes to use.
    const span = if (producer == null) execution.aggregate_values.len else types.limits.aggregate_elements;
    const cells = if (execution.aggregate_values.len <= types.limits.aggregate_elements) scratch.alloc(u32, 2 * span) else null;
    defer if (cells) |slots| scratch.free(slots);
    if (cells) |slots| {
        memo = .{ .types = slots[0..span], .lengths = slots[span..], .cleared = execution.aggregate_values.len };
        @memset(memo.types[0..memo.cleared], 0);
    }
    // Without them a join that leaves a room cannot be followed, and the replay refuses it.
    const room_slots = scratch.alloc(u32, 2 * array_concat.Rooms.capacity);
    defer if (room_slots) |slots| scratch.free(slots);
    rooms = if (room_slots) |slots| .{ .fills = slots[0..array_concat.Rooms.capacity], .limits = slots[array_concat.Rooms.capacity..] } else .{};
    defer rooms = .{};
    if (execution.values.len != program.nodes.len or execution.aggregate_values.len > types.limits.aggregate_elements or execution.call_steps.len > types.limits.call_steps) return error.InvalidExecution;
    if (evaluator.validate(program, execution.values.len) != null) return error.InvalidExecution;
    if (types.sparse(program)) {
        if (execution.activity.len != execution.values.len) return error.InvalidExecution;
    } else if (execution.activity.len != 0) return error.InvalidExecution;
    var work: u64 = 0;
    // Admit every readable borrow before any key comparator/hash. Failed events
    // carry a condition/reason rather than the defining operation's result type.
    for (program.nodes, 0..) |node, index| if (execution.active(index)) {
        const value = execution.values[index];
        try charge(&work, limits.work);
        if (!conforms(execution, value, node.value_type)) return error.InvalidExecution;
        if (node.kind == .function_value and (value != .callable or value.callable.function != node.kind.function_value or value.callable.captures.start != 0 or value.callable.captures.end != 0)) return error.InvalidExecution;
        if (node.kind == .enumeration and (value != .enumeration or value.enumeration.index != node.kind.enumeration)) return error.InvalidExecution;
        if (node.kind == .character and (value != .enumeration or value.enumeration.index != node.kind.character)) return error.InvalidExecution;
        try validateValue(execution, value, &work, limits.work);
    };
    for (execution.call_steps) |event| {
        try charge(&work, limits.work);
        try validateValue(execution, event.value, &work, limits.work);
    }
    for (execution.aggregate_values) |value| {
        try charge(&work, limits.work);
        // The unfilled part of a room (`array_concat`): no value names it.
        if (array_concat.placeholderLimit(value) != null) continue;
        try validateValue(execution, value, &work, limits.work);
    }
    try validateObjects(execution, &work, limits.work);
    for (0..execution.values.len) |index| if (execution.active(index)) try validateMap(execution, execution.values[index], &work, limits.work);
    for (execution.call_steps) |event| try validateMap(execution, event.value, &work, limits.work);
    for (execution.aggregate_values) |value| if (array_concat.placeholderLimit(value) == null) try validateMap(execution, value, &work, limits.work);
    // The root schedule visits failed calls as well as successful registers.
    // Its own control stack decides which invocation consumes the next events.
    try validateSchedule(execution, producer, &work, limits.work);
    // Each printed name once: found through an index, so a report of many bindings costs what
    // it prints and not the square of it.
    var names = name_index.Index.create(program.bindings.len) orelse return error.InvalidExecution;
    defer names.destroy();
    for (program.bindings, 0..) |binding, index| {
        try charge(&work, limits.work);
        const name = binding.name.text(program.source);
        if (!validName(name)) return error.InvalidExecution;
        var probe = names.probe(name_index.hashName(0, name));
        while (probe.next()) |prior| if (std.mem.eql(u8, name, program.bindings[prior].name.text(program.source))) return error.InvalidExecution;
        probe.claim(@intCast(index));
        if (!execution.active(binding.node) or !conforms(execution, bindingValue(execution, binding), binding.value_type)) return error.InvalidExecution;
    }
    var buffer: [256]u8 = undefined;
    var counter = CountingWriter.init(&buffer, limits.output_bytes);
    writeObject(&counter.writer, execution, public_only, &work, limits.work) catch |err| switch (err) {
        error.WriteFailed => return error.ReportLimit,
        error.ReportLimit => return error.ReportLimit,
        error.InvalidExecution => return error.InvalidExecution,
        error.ScratchUnavailable => return error.InvalidExecution, // As for the replay's other scratch.
    };
    counter.writer.writeByte('\n') catch return error.ReportLimit;
    counter.writer.flush() catch return error.ReportLimit;
    std.debug.assert(work <= limits.work and counter.count <= limits.output_bytes);
    return .{ .work = work, .output_bytes = counter.count, .live_bytes = live_peak };
}

/// The final state of every instance, in creation order: each starts with its class and holds one
/// well-typed value per field.
fn validateObjects(execution: evaluator.Execution, work: *u64, budget: u64) Error!void {
    const program = execution.program;
    var at: usize = 0;
    while (at < execution.object_cells.len) {
        try charge(work, budget);
        const header = execution.object_cells[at];
        if (!header.initialized or header.value != .integer or header.value.integer < 0 or header.value.integer > std.math.maxInt(u16)) return error.InvalidExecution;
        const class: types.Type = @fromBackingInt(@intCast(header.value.integer));
        const count = catalogue.classCells(class, program.definitions) orelse return error.InvalidExecution;
        if (count > execution.object_cells.len - at) return error.InvalidExecution;
        if (catalogue.definition(class, program.definitions).? == .task) {
            // A task handle (RFC-0082): its sequence, its state and the option of its result.
            const shape = catalogue.definition(class, program.definitions).?.task;
            for (execution.object_cells[at + 1 ..][0 .. count - 1], [_]types.Type{ .i64, .i64, shape.option }) |cell, value_type| {
                try charge(work, budget);
                if (!cell.initialized or !conforms(execution, cell.value, value_type)) return error.InvalidExecution;
                try validateValue(execution, cell.value, work, budget);
            }
            const state = execution.object_cells[at + catalogue.task_state].value.integer;
            const result = execution.object_cells[at + catalogue.task_result].value.aggregate.elements;
            // A cancelled task (P3.7) keeps no result.
            if (state != catalogue.task_active and state != catalogue.task_completed and state != catalogue.task_canceled) return error.InvalidExecution;
            if ((state == catalogue.task_completed) != (result.end != result.start)) return error.InvalidExecution;
            at += count;
            continue;
        }
        if (catalogue.definition(class, program.definitions).? == .live) {
            // A live record (RFC-0084): its guard, stamp, height, owner, place and origin.
            const target = catalogue.definition(class, program.definitions).?.live;
            const cells = execution.object_cells[at..][0..count];
            for (cells[1..]) |cell| {
                try charge(work, budget);
                if (!cell.initialized) return error.InvalidExecution;
            }
            const guard = cells[catalogue.live_guard].value;
            if (guard != .callable or guard.callable.function >= program.functions.len or program.functions[guard.callable.function].value_type != target) return error.InvalidExecution;
            try validateValue(execution, guard, work, budget);
            for ([_]u32{ catalogue.live_stamp, catalogue.live_height, catalogue.live_place, catalogue.live_origin }) |index| if (cells[index].value != .integer or cells[index].value.integer < 0) return error.InvalidExecution;
            // Its owner is the record itself, for a module cell, or the class instance whose
            // field `place` it follows (P4.2).
            const owner = cells[catalogue.live_owner].value;
            const place = cells[catalogue.live_place].value.integer;
            if (owner != .object) return error.InvalidExecution;
            if (owner.object.id == program.source_cells.len + at) {
                if (owner.object.value_type != class or place >= program.source_cells.len) return error.InvalidExecution;
            } else {
                // Or, from RFC-0085 I14, the variable cell `ref(T)` of a live local, at place 0.
                const shape = catalogue.definition(owner.object.value_type, program.definitions) orelse return error.InvalidExecution;
                if ((shape != .class and shape != .ref) or owner.object.id < program.source_cells.len or owner.object.id - program.source_cells.len >= execution.object_cells.len) return error.InvalidExecution;
                const owner_header = execution.object_cells[owner.object.id - program.source_cells.len].value;
                if (owner_header != .integer or owner_header.integer != @backingInt(owner.object.value_type) or place >= catalogue.classCells(owner.object.value_type, program.definitions).? - 1) return error.InvalidExecution;
                const followed = if (shape == .ref) shape.ref else catalogue.classFieldAt(owner.object.value_type, @intCast(place), program.definitions, program.fields).?.value_type;
                if (followed != target) return error.InvalidExecution;
            }
            at += count;
            continue;
        }
        if (catalogue.definition(class, program.definitions).? == .event) {
            // An event (P3.2): how many wait, and the sequences of the first and the last, all
            // zero together when none does.
            const shape = catalogue.definition(class, program.definitions).?.event;
            for (execution.object_cells[at + 1 ..][0 .. catalogue.event_cells - 1]) |cell| {
                try charge(work, budget);
                if (!cell.initialized or cell.value != .integer or cell.value.integer < 0) return error.InvalidExecution;
            }
            const waiting = execution.object_cells[at + catalogue.event_waiting].value.integer;
            const first = execution.object_cells[at + catalogue.event_first].value.integer;
            const last = execution.object_cells[at + catalogue.event_last].value.integer;
            if ((waiting == 0) != (first == 0) or (waiting == 0) != (last == 0) or (waiting == 1 and first != last)) return error.InvalidExecution;
            const cells = execution.object_cells[at..][0..count];
            for (cells[catalogue.event_cells..]) |cell| {
                try charge(work, budget);
                if (!cell.initialized) return error.InvalidExecution;
            }
            switch (shape.kind) {
                .plain => {},
                // P3.9: a sticky event's latch, and the value it holds once set.
                .sticky => {
                    const latch = cells[catalogue.sticky_latch].value;
                    const held = cells[catalogue.sticky_value].value;
                    if (latch != .integer or (latch.integer != 0 and latch.integer != 1)) return error.InvalidExecution;
                    if (latch.integer == 0 and (held != .integer or held.integer != 0)) return error.InvalidExecution;
                    if (latch.integer == 1) {
                        if (!conforms(execution, held, shape.value)) return error.InvalidExecution;
                        try validateValue(execution, held, work, budget);
                    }
                },
                // P3.9: a subscribable event's list ends, both or neither, and its next number.
                .subscribable => {
                    const head = cells[catalogue.subscription_first].value;
                    const tail = cells[catalogue.subscription_last].value;
                    const number = cells[catalogue.subscription_count].value;
                    if (!subscriptionLink(execution, head) or !subscriptionLink(execution, tail) or (head == .object) != (tail == .object)) return error.InvalidExecution;
                    if (number != .integer or number.integer < 0) return error.InvalidExecution;
                },
            }
            at += count;
            continue;
        }
        if (catalogue.refValue(class, program.definitions)) |held| {
            // RFC-0085, I1: a variable cell holds one value of its type.
            const cell = execution.object_cells[at + catalogue.ref_value];
            try charge(work, budget);
            if (!cell.initialized or !conforms(execution, cell.value, held)) return error.InvalidExecution;
            try validateValue(execution, cell.value, work, budget);
            at += count;
            continue;
        }
        if (catalogue.definition(class, program.definitions).? == .cancelable) {
            // P3.9: a subscription's state, callback, event, neighbours and number.
            const cells = execution.object_cells[at..][0..count];
            for (cells[1..]) |cell| {
                try charge(work, budget);
                if (!cell.initialized) return error.InvalidExecution;
            }
            const state = cells[catalogue.cancelable_state].value;
            if (state != .integer or (state.integer != catalogue.cancelable_active and state.integer != catalogue.cancelable_canceled)) return error.InvalidExecution;
            const event = cells[catalogue.cancelable_event].value;
            if (event != .object) return error.InvalidExecution;
            const shape = catalogue.eventShape(event.object.value_type, program.definitions) orelse return error.InvalidExecution;
            if (shape.kind != .subscribable) return error.InvalidExecution;
            try validateValue(execution, event, work, budget);
            const callback = cells[catalogue.cancelable_callback].value;
            if (callback != .callable or !callbackOf(execution, callback.callable.value_type, shape.value)) return error.InvalidExecution;
            try validateValue(execution, callback, work, budget);
            if (!subscriptionLink(execution, cells[catalogue.cancelable_before].value) or !subscriptionLink(execution, cells[catalogue.cancelable_after].value)) return error.InvalidExecution;
            const number = cells[catalogue.cancelable_number].value;
            if (number != .integer or number.integer < 0) return error.InvalidExecution;
            at += count;
            continue;
        }
        if (!validSpanOf(program.definitions, class, program.fields.len)) return error.InvalidExecution;
        const shape = catalogue.definition(class, program.definitions).?.class;
        for (execution.object_cells[at + 1 ..][0 .. count - 1], program.fields[shape.fields.start..shape.fields.end]) |cell, field| {
            try charge(work, budget);
            if (!cell.initialized or !conforms(execution, cell.value, field.value_type)) return error.InvalidExecution;
            try validateValue(execution, cell.value, work, budget);
        }
        at += count;
    }
}
/// P3.9: a link of a subscription list: `false`, or a `cancelable`.
fn subscriptionLink(execution: evaluator.Execution, value: types.Value) bool {
    return switch (value) {
        .boolean => |b| !b,
        .object => |object| catalogue.isCancelable(object.value_type, execution.program.definitions) and object.id >= execution.program.source_cells.len,
        else => false,
    };
}
/// P3.9 (C108): whether `callback` is the callback type of a `subscribable_event(value)`.
fn callbackOf(execution: evaluator.Execution, callback: types.Type, value: types.Type) bool {
    const p = execution.program;
    const shape = catalogue.definition(callback, p.definitions) orelse return false;
    if (shape != .callable or !shape.callable.transacts or shape.callable.decides or @as(u8, @bitCast(shape.callable.detail)) != 0) return false;
    const parameters = catalogue.definition(shape.callable.parameters, p.definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start != 1 or parameters.tuple.end > p.tuple_elements.len or p.tuple_elements[parameters.tuple.start] != value) return false;
    const result = catalogue.definition(shape.callable.result, p.definitions) orelse return false;
    return result == .tuple and result.tuple.start == result.tuple.end;
}
fn validSpanOf(definitions: []const types.Definition, class: types.Type, field_count: usize) bool {
    const shape = catalogue.definition(class, definitions) orelse return false;
    return shape == .class and shape.class.fields.start <= shape.class.fields.end and shape.class.fields.end <= field_count;
}

// Independent replay of controlled invocations and language outcomes. The program owns
// schedules; the trace supplies typed values, and the replay works out again every value the
// program and the values before it decide (RFC-0024, "Amendment: the replay works out every value").
const TraceOutcome = union(enum) { ok: types.Value, language: types.CallFailure };
// Reconstruct observable cell state from admitted immutable Values. This neither
// consumes a runtime journal nor trusts the reference engine's source images.
// The machines keep at most one record per region and cell, and none in the root region; the
// replay counts the same records by its own bookkeeping, so that it admits exactly the runs
// `source_undos` allows. `cell` numbers the program's cells first and instance cells after them.
// `outer` is the nearest enclosing region holding a record for the same cell, or 0.
const RegionDepth = std.math.IntFittingRange(0, types.limits.source_frames);
/// `link` (RFC-0084, P4.2): the live record an instance cell was attached to when the region
/// first touched it, which a rollback restores with the value.
const Held = struct { cell: u32, previous: ?types.Value, outer: RegionDepth, link: u32 = replay_none };
const SourceReplay = struct {
    cells: [types.limits.source_cells]?types.Value = @splat(null),
    /// One image of the program's cells per open region, `count` cells each; sized by the program.
    images: []?types.Value = &.{},
    /// Replay storage for calls, borrowed on the first call of a report.
    trace_frames: []CallVisit = &.{},
    trace_locals: []types.Value = &.{},
    count: usize = 0,
    depth: usize = 0,
    /// Instance cells, appended after the program's own and rolled back by undo records rather
    /// than images: a region costs what it writes, not what the run has built.
    objects: []?types.Value = &.{},
    object_count: u32 = 0,
    /// Per program cell, then per instance cell: the innermost open region holding a record for
    /// it, or 0. Never 1, which is the root region.
    holder: []RegionDepth = &.{},
    /// Borrowed at the first record: a run that writes only in the root region needs none.
    undo: []Held = &.{},
    undo_count: u32 = 0,
    marks: [types.limits.source_frames]struct { undo: u32, objects: u32 } = undefined,
    /// Whether the run kept cells at all; a run without them reclaims with no cell to examine.
    tracked: bool = false,
    /// The pool size at which the replayed run next reclaimed; never, for a stored witness.
    reclaim_at: u64 = std.math.maxInt(u64),
    reclaim_floor: u32 = types.ControlStorage.reclaim_never,
    /// Reclamations so far, and how many the run says it made.
    reclaims: u64 = 0,
    reclaims_claimed: u64 = 0,
    /// Where each member above the mark goes in a reclamation, borrowed at the first one.
    forward: []u32 = &.{},
    /// The same for the instance cells, the values still to be examined, and the strings in use.
    places: []u32 = &.{},
    pending: []u32 = &.{},
    texts: []u64 = &.{},
    /// Whether the steps arrive from a second run, which says where its string pool ends.
    streaming: bool = false,
    /// Bytes of the string pool the replayed run had in use at this point of a traced call.
    /// Every string a call builds is the value of a step, so its end is where the pool ends;
    /// what was built before the call, and by a native, the run tells.
    string_used: u64 = 0,
    /// The sizes of the string pool and of the cells at which the replayed run next reclaimed.
    string_reclaim_at: u64 = std.math.maxInt(u64),
    object_reclaim_at: u64 = std.math.maxInt(u64),
    /// How many frames there were at the last reclamation, and the sizes at which its work is
    /// paid for: a frame nearer the root reclaims from then on.
    reclaim_depth: usize = 0,
    paid_members: u64 = 0,
    paid_strings: u64 = 0,
    paid_cells: u64 = 0,
    /// What a task's frame at depth 1 after a switch waits for: the above, or half the room left
    /// in the store when that comes first (`ControlStorage.reclaim_across`).
    across_members: u64 = 0,
    across_strings: u64 = 0,
    across_cells: u64 = 0,
    /// The scheduler's switch count at the last reclamation (`ControlStorage.reclaim_switches`).
    reclaim_switches: u64 = 0,
    /// The reason of each failure a trace is kept of, as the run holds it: a reclamation moves
    /// the string, so it is compared with the run's trace when the replay ends.
    reasons: [types.limits.failure_traces]?[]const u8 = undefined,
    reason_count: u32 = 0,
    /// What the run did to the world, worked out again from its steps.
    effects: EffectReplay = .{},
    /// What the world gave the run (RFC-0086): the run's record, read as the run read it.
    inputs: InputReplay = .{},
    /// What its scheduler did (RFC-0082).
    tasks: SchedulerReplay = .{},
    /// What its live variables did (RFC-0084).
    live: LiveReplay = .{},
    /// RFC-0082, P3.5: what the stores held when the root had run to its end: the members and
    /// cells then, and the string pool as the first slice after it began, which a run tells.
    root_ended: bool = false,
    root_members: u32 = 0,
    root_cells: u32 = 0,
    root_strings: ?u32 = null,
    /// Per body node, the newest register before it that is available there; borrowed at the
    /// first reclamation that roots suspended frames.
    links: []u32 = &.{},
    /// RFC-0082, P3.9: the run's catalogue, by which a carried-out `Signal` tells the kinds of
    /// event apart.
    definitions: []const types.Definition = &.{},
    /// What the replay runs pure natives (`replayNative`) and untraced root calls
    /// (`replayCompute`) on, borrowed at the first.
    native_members: []types.Value = &.{},
    native_strings: []u8 = &.{},
    /// RFC-0087, P5.3: what the replay runs the JSON codec on, borrowed at the first JSON node:
    /// a member pool indexed as the run's, and the codec's stack.
    json_members: []types.Value = &.{},
    json_stack: ?*persist_json.Stack = null,
    /// Per instance cell a decode built, at its header: where the run laid its fields out.
    json_blocks: []u32 = &.{},
    compute_frames: []ComputeVisit = &.{},
    compute_locals: []types.Value = &.{},

    /// A region of the run commits: its actions and its starts go to the region around it. True
    /// when the starts begin a drain (RFC-0082).
    fn regionCommit(self: *SourceReplay) Error!bool {
        const closing = self.effects.depth;
        try self.effects.commit();
        // RFC-0084, P4.4: what it notified goes to the region around it.
        if (self.live.on) self.live.notifiedCommit(closing);
        return if (self.tasks.on) self.tasks.commitHeld(closing) else false;
    }
    fn regionAbort(self: *SourceReplay) Error!void {
        const closing = self.effects.depth;
        try self.effects.abort();
        // RFC-0084, P4.4 (R2): what it notified is not notified.
        if (self.live.on) try self.live.notifiedAbort(closing);
        if (self.tasks.on) self.tasks.abortHeld(closing);
    }

    fn begin(self: *SourceReplay, work: *u64, budget: u64) Error!void {
        if (self.depth == 0 or self.depth == types.limits.source_frames) return error.InvalidExecution;
        for (self.cells[0..self.count], self.images[self.depth * self.count ..][0..self.count]) |cell, *copy| {
            try charge(work, budget);
            copy.* = cell;
        }
        self.marks[self.depth] = .{ .undo = self.undo_count, .objects = self.object_count };
        if (self.live.on) try self.live.regionBegin(self.depth, work, budget);
        self.depth += 1;
    }
    /// The parent inherits a record unless it holds an older one for the cell or is the root.
    fn commit(self: *SourceReplay, work: *u64, budget: u64) Error!void {
        if (self.depth <= 1) return error.InvalidExecution;
        self.depth -= 1;
        var kept = self.marks[self.depth].undo;
        for (self.undo[kept..self.undo_count]) |record| {
            // A record can pass through every enclosing commit, so the write that made it does
            // not pay for this.
            try charge(work, budget);
            std.debug.assert(self.holder[record.cell] == self.depth + 1 and record.outer <= self.depth);
            if (self.depth > 1 and record.outer != self.depth) {
                self.holder[record.cell] = @intCast(self.depth);
                self.undo[kept] = record;
                kept += 1;
            } else self.holder[record.cell] = record.outer;
        }
        self.undo_count = kept;
    }
    /// Takes the record a write needs: the first one to this cell in a region other than the root.
    fn hold(self: *SourceReplay, cell: usize, previous: ?types.Value) Error!void {
        std.debug.assert(self.holder[cell] <= self.depth and self.holder[cell] != 1);
        if (self.depth == 1 or self.holder[cell] == self.depth) return;
        if (self.undo_count == types.limits.source_undos) return error.InvalidExecution;
        if (self.undo.len == 0) self.undo = scratch.alloc(Held, types.limits.source_undos) orelse return error.InvalidExecution;
        self.undo[self.undo_count] = .{ .cell = @intCast(cell), .previous = previous, .outer = self.holder[cell], .link = if (cell >= self.count) self.live.objectLink(@intCast(cell - self.count)) else replay_none };
        self.undo_count += 1;
        self.holder[cell] = @intCast(self.depth);
    }
    fn abort(self: *SourceReplay, work: *u64, budget: u64) Error!void {
        if (self.depth <= 1) return error.InvalidExecution;
        self.depth -= 1;
        for (self.cells[0..self.count], self.images[self.depth * self.count ..][0..self.count]) |*cell, copy| {
            try charge(work, budget);
            cell.* = copy;
        }
        while (self.undo_count > self.marks[self.depth].undo) {
            self.undo_count -= 1;
            const record = self.undo[self.undo_count];
            // The images restored the program's cells; their records only count.
            if (record.cell >= self.count) {
                self.objects[record.cell - self.count] = record.previous;
                // And the link of an instance cell (RFC-0084, P4.2).
                self.live.restoreObjectLink(@intCast(record.cell - self.count), record.link);
            }
            self.holder[record.cell] = record.outer;
        }
        self.object_count = self.marks[self.depth].objects;
        if (self.live.on) try self.live.regionAbort(self.depth, work, budget);
    }
    /// Appends an instance and returns the reference the run must have reported for it.
    fn allocate(self: *SourceReplay, class: types.Type, fields: []const types.Value) Error!types.ObjectRef {
        if (self.depth == 0 or fields.len + 1 > self.objects.len - self.object_count) return error.InvalidExecution;
        const first = self.object_count;
        self.objects[first] = .{ .integer = @backingInt(class) };
        for (fields, self.objects[first + 1 ..][0..fields.len]) |field, *cell| cell.* = field;
        @memset(self.holder[self.count + first ..][0 .. fields.len + 1], 0);
        // A new instance's cells have no live record (RFC-0084, P4.2).
        self.live.clearObjectLinks(first, @intCast(fields.len + 1));
        self.object_count += @intCast(fields.len + 1);
        return .{ .value_type = class, .id = @intCast(self.count + first) };
    }
    fn objectCell(self: *const SourceReplay, object: types.ObjectRef, index: u32) Error!usize {
        if (object.id < self.count or object.id - self.count >= self.object_count) return error.InvalidExecution;
        const first = object.id - self.count;
        const header = self.objects[first] orelse return error.InvalidExecution;
        if (header != .integer or header.integer != @backingInt(object.value_type) or first + 1 + index >= self.object_count) return error.InvalidExecution;
        return first + 1 + index;
    }
    fn objectRead(self: *const SourceReplay, object: types.ObjectRef, index: u32) Error!types.Value {
        return self.objects[try self.objectCell(object, index)] orelse error.InvalidExecution;
    }
    fn objectWrite(self: *SourceReplay, object: types.ObjectRef, index: u32, value: types.Value) Error!void {
        const cell = try self.objectCell(object, index);
        if (self.depth == 0) return error.InvalidExecution;
        try self.hold(self.count + cell, self.objects[cell]);
        self.objects[cell] = value;
    }
    fn read(self: *const SourceReplay, index: u32) Error!types.Value {
        if (index >= self.count) return error.InvalidExecution;
        return self.cells[index] orelse error.InvalidExecution;
    }
    fn write(self: *SourceReplay, index: u32, value: types.Value, initialize: bool) Error!void {
        if (self.depth == 0 or index >= self.count) return error.InvalidExecution;
        if ((self.cells[index] != null) == initialize) return error.InvalidExecution;
        try self.hold(index, null);
        self.cells[index] = value;
    }
};
/// The effects of a run in the replay's own words (RFC-0079). The replay has no device and
/// keeps no action: it folds each one into a tally as it is prepared, and remembers per region
/// that prepared any what the tally was before, so that a region that fails takes its actions
/// out again. At the end the tally holds exactly the actions the run committed, in order, and
/// the stream stands where the run's stood. Regions are counted as the run counts them: every
/// `attempt_begin` opens one, whether or not the function has cells.
///
/// A `full` run also lists its committed actions (`listed`), and those are compared byte for
/// byte as the replay goes: each action that is prepared is held against the listed action at
/// `cursor`. The actions that are still standing, in the order they were prepared, are the
/// ones the run will have committed, and a region that fails drops the newest of them, so a
/// mark restores `cursor` and `diverged` as it restores the tally. The comparison reads each
/// prepared byte once, as the tally does: no action is kept and nothing is hashed for it.
const EffectReplay = struct {
    const Mark = struct { depth: u32, pending: u64, tally: effects.Tally, cursor: u64, diverged: bool };
    /// One per open region that prepared an action of its own. Borrowed at the first.
    marks: []Mark = &.{},
    mark_count: u32 = 0,
    depth: u32 = 0,
    /// Actions prepared in regions that are still open; the run held as many in its log.
    pending: u64 = 0,
    tally: effects.Tally = .{},
    discarded: u64 = 0,
    stream: effects.Stream = .{},
    /// The actions a `full` run lists, or null for a run that lists none.
    listed: ?effects.Record = null,
    /// How many listed actions the standing actions match, from the first.
    cursor: u64 = 0,
    /// A standing action differs from the listed one in its place, or there was none.
    diverged: bool = false,
    /// RFC-0086, P2.3: the run's grants, which a writer handle a native is given names.
    grants: []const effects.Grant = &.{},

    fn begin(self: *EffectReplay) void {
        self.depth += 1;
    }
    fn commit(self: *EffectReplay) Error!void {
        if (self.depth == 0) return error.InvalidExecution;
        const closing = self.depth;
        self.depth -= 1;
        if (self.mark_count != 0 and self.marks[self.mark_count - 1].depth == closing) {
            // The actions now belong to the parent, which keeps its own, older mark if it has one.
            if (self.depth == 0 or (self.mark_count > 1 and self.marks[self.mark_count - 2].depth == self.depth)) {
                self.mark_count -= 1;
            } else self.marks[self.mark_count - 1].depth = self.depth;
        }
        if (self.depth == 0) self.pending = 0;
    }
    fn abort(self: *EffectReplay) Error!void {
        if (self.depth == 0) return error.InvalidExecution;
        const closing = self.depth;
        self.depth -= 1;
        if (self.mark_count == 0 or self.marks[self.mark_count - 1].depth != closing) return;
        const mark = self.marks[self.mark_count - 1];
        self.mark_count -= 1;
        self.discarded += self.pending - mark.pending;
        self.pending = mark.pending;
        self.tally = mark.tally;
        self.cursor = mark.cursor;
        self.diverged = mark.diverged;
    }
    /// An effect native, run again, describes its action here, on its channel (RFC-0086 H5).
    fn act(context: *anyopaque, channel: u32, text: []const u8) effects.Error!void {
        const self: *EffectReplay = @ptrCast(@alignCast(context));
        if (self.depth != 0) {
            // A run that held more than its log has room for stopped there and has no report.
            if (self.pending >= effects.entry_capacity) return error.EffectLimit;
            if (self.mark_count == 0 or self.marks[self.mark_count - 1].depth != self.depth) {
                if (self.marks.len == 0) self.marks = scratch.alloc(Mark, effects.entry_capacity) orelse return error.EffectLimit;
                // A mark owns at least one pending action, so there is room.
                self.marks[self.mark_count] = .{ .depth = self.depth, .pending = self.pending, .tally = self.tally, .cursor = self.cursor, .diverged = self.diverged };
                self.mark_count += 1;
            }
            self.pending += 1;
        }
        self.tally.addOn(channel, text);
        if (self.listed) |record| if (!self.diverged) {
            // Once one differs, every later one is out of place too: none is read again.
            self.diverged = self.cursor >= record.entries.len or !listedEql(record, self.cursor, channel, text);
            if (!self.diverged) self.cursor += 1;
        };
    }
    /// Whether the listed action at `index` is `text`. Where the entry lies is checked here, as
    /// it is read; `admitEffects` checks that the entries lie end to end.
    fn listedEql(record: effects.Record, index: u64, channel: u32, text: []const u8) bool {
        const entry = record.entries[@intCast(index)];
        if (entry.start > entry.end or entry.end > record.bytes.len or entry.channel != channel) return false;
        return std.mem.eql(u8, record.bytes[entry.start..entry.end], text);
    }
    fn port(self: *EffectReplay) effects.Port {
        return .{ .context = self, .act = act, .stream = &self.stream, .grants = self.grants };
    }
};

/// A native call of the run that is an effect (RFC-0079): the native is run again against the
/// replay's port, so the replay learns the action or the draw from the native itself and not
/// from the run. `operands` are the values the call's operands had and `actual` is what the
/// run recorded as its result: a draw must be the value the replay's own stream gives at its
/// own position, and an action yields the empty `tuple()`.
fn replayEffect(program: types.Program, call: types.NativeCall, operands: []const types.Value, actual: types.Value, members: []const types.Value, source: *SourceReplay, work: *u64, budget: u64) Error!void {
    const entry = program.natives[call.native];
    if (entry.effect == .none) return;
    if (entry.effect == .input) return replayInput(entry, call, operands, actual, members, &source.inputs, source.tasks.now, work, budget);
    const replay = &source.effects;
    var arguments: [native.max_parameters]types.Value = undefined;
    var bytes: u64 = 0;
    for (call.args[0..call.count], 0..) |operand, index| {
        arguments[index] = operands[operand];
        if (arguments[index] == .string) bytes += arguments[index].string.len;
    }
    // What the native can charge at most, so that a report out of budget is told apart from
    // a native that does not do what the run says it did.
    const needed = native.callCost(entry, arguments[0..call.count]) +| (bytes / 8 + effects.max_rejections + 2);
    if (needed > budget - work.*) return error.ReportLimit;
    var remaining: u64 = budget - work.*;
    const value = native.replay(entry, arguments[0..call.count], replay.port(), &remaining) catch return error.InvalidExecution;
    work.* = budget - remaining;
    if (value) |drawn| {
        if (!sameValue(drawn, actual)) return error.InvalidExecution;
    } else if (actual != .aggregate or actual.aggregate.elements.start != actual.aggregate.elements.end) return error.InvalidExecution;
}

/// The third reader of a run's input record (RFC-0086, "Replay"), beside `EffectReplay`: a cursor
/// into the record and the latest clock reading. At each input call it works out from its own
/// state whether the call took an entry, which must then be the one at the cursor, asked for at
/// the call's tick, and what value the call had to yield. It never asks the world: a report of a
/// run carries what the world gave it, and that is the one value the replay takes from a report.
const InputReplay = struct {
    record: effects.InputRecord = .{},
    cursor: usize = 0,
    /// Where the bytes of the entries read so far end: they lie end to end.
    bytes: u64 = 0,
    reading: ?u64 = null,
    reading_tick: u64 = 0,
    /// RFC-0086, P2.3: the run's grants, from its record.
    grants: []const effects.Grant = &.{},

    /// The entry at the cursor, which must be the request of this call.
    fn next(self: *InputReplay, kind: effects.InputKind, request: u32, tick: u64) Error!effects.InputEntry {
        if (self.cursor >= self.record.entries.len) return error.InvalidExecution;
        const entry = self.record.entries[self.cursor];
        if (entry.kind != kind or entry.request != request or entry.tick != tick) return error.InvalidExecution;
        if (entry.start != self.bytes or entry.end < entry.start or entry.end > self.record.bytes.len) return error.InvalidExecution;
        self.cursor += 1;
        self.bytes = entry.end;
        return entry;
    }

    /// The bits of the value `GetSecondsSinceEpoch()` yields at `tick` (I5), written again here.
    fn clock(self: *InputReplay, tick: u64) Error!u64 {
        if (self.reading) |bits| {
            if (self.reading_tick == tick) return bits;
            if (tick < self.reading_tick) return error.InvalidExecution;
        }
        const entry = try self.next(.clock, 0, tick);
        // A reading that is no number ended the run where it was taken: no report has one.
        if (entry.status != .value or entry.start != entry.end or entry.bits & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000) return error.InvalidExecution;
        const raw: f64 = @bitCast(entry.bits);
        const value = if (self.reading) |bits| (if (@as(f64, @bitCast(bits)) < raw) entry.bits else bits) else entry.bits;
        self.reading = value;
        self.reading_tick = tick;
        return value;
    }
};

/// An input native call of the run (RFC-0086). It is not run again: the replay has no world to
/// give it, and what the world gave is in the record. The replay knows what the standard input
/// natives ask for; a call of an input native it does not know cannot be checked, and its report
/// is refused. It charges what the run charged for the call.
fn replayInput(entry: native.Entry, call: types.NativeCall, operands: []const types.Value, actual: types.Value, members: []const types.Value, replay: *InputReplay, tick: u64, work: *u64, budget: u64) Error!void {
    if (std.mem.eql(u8, entry.id, "std.read_line")) return replayLine(entry, call, operands, actual, members, replay, tick, work, budget);
    if (!std.mem.eql(u8, entry.id, "std.clock_seconds") or call.count != 0 or entry.params.len != 0 or entry.result.kind != .scalar or entry.result.element != .float) return error.InvalidExecution;
    const charge_due = native.callCost(entry, &.{});
    if (charge_due > budget - work.*) return error.ReportLimit;
    work.* += charge_due;
    const bits = try replay.clock(tick);
    if (actual != .floating or @as(u64, @bitCast(actual.floating)) != bits) return error.InvalidExecution;
}

/// `R.ReadLine[]` (RFC-0086 I6, I7): `std.read_line`, `(reader) -> option(string)`. The call takes
/// the entry at the cursor, which must ask for a line of the reader's grant at the call's tick; its
/// value is `option{}` at the end of the stream, and otherwise an option whose one member is a
/// string of exactly the line's bytes. The replay charges what the call charged.
fn replayLine(entry: native.Entry, call: types.NativeCall, operands: []const types.Value, actual: types.Value, members: []const types.Value, replay: *InputReplay, tick: u64, work: *u64, budget: u64) Error!void {
    if (call.count != 1 or entry.params.len != 1 or entry.params[0].kind != .scalar or entry.params[0].element != .reader or entry.result.kind != .option or entry.result.element != .string) return error.InvalidExecution;
    if (call.args[0] >= operands.len) return error.InvalidExecution;
    const handle = operands[call.args[0]];
    if (handle != .enumeration) return error.InvalidExecution;
    const grant = handle.enumeration.index;
    if (grant >= replay.grants.len or replay.grants[grant].kind != .reader) return error.InvalidExecution;
    const charge_due = native.callCost(entry, &.{handle});
    if (charge_due > budget - work.*) return error.ReportLimit;
    work.* += charge_due;
    const taken = try replay.next(.line, grant, tick);
    if (actual != .aggregate or taken.bits != 0) return error.InvalidExecution;
    const span = actual.aggregate.elements;
    if (span.start > span.end or span.end > members.len) return error.InvalidExecution;
    const line = replay.record.bytes[taken.start..taken.end];
    switch (taken.status) {
        .end => if (span.end != span.start or line.len != 0) return error.InvalidExecution,
        .value => {
            if (span.end - span.start != 1) return error.InvalidExecution;
            const read = members[span.start];
            // The line, without its newline: the run copied exactly these bytes (I6).
            if (read != .string or read.string.len != line.len or std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidExecution;
            try replayCharge(work, budget, run_strings.work(line.len));
            if (!std.mem.eql(u8, read.string, line)) return error.InvalidExecution;
        },
    }
}

/// RFC-0086, P2.3 (H3): the value a `grant` node had to yield, worked out from the run's grants:
/// an option of the handle of the first grant of the kind named by `name`, its one member the
/// next unused one (`prefix`), or `option{}`. The replay charges a unit per grant compared.
fn replayGrant(grants: []const effects.Grant, g: types.Grant, name: types.Value, actual: types.Value, members: []const types.Value, prefix: *u32, program: types.Program, work: *u64, budget: u64) Error!void {
    if (name != .string or actual != .aggregate) return error.InvalidExecution;
    const shape = catalogue.definition(actual.aggregate.value_type, program.definitions) orelse return error.InvalidExecution;
    if (shape != .option) return error.InvalidExecution;
    var found: ?u32 = null;
    for (grants, 0..) |grant, index| {
        if (grant.kind != g.kind) continue;
        try charge(work, budget);
        if (std.mem.eql(u8, grant.name, name.string)) {
            found = @intCast(index);
            break;
        }
    }
    const span = actual.aggregate.elements;
    const count: u32 = if (found == null) 0 else 1;
    if (prefix.* > members.len or count > members.len - prefix.* or span.start != prefix.* or span.end != prefix.* + count) return error.InvalidExecution;
    if (found) |index| {
        const handle = members[span.start];
        if (handle != .enumeration or handle.enumeration.value_type != shape.option or handle.enumeration.index != index) return error.InvalidExecution;
    }
    prefix.* = span.end;
}

/// RFC-0087, P5.4 (K1): the run's one session.
fn replaySession(session_type: types.Type) types.Value {
    return .{ .enumeration = .{ .value_type = session_type, .index = 0 } };
}

/// RFC-0087, P5.4: the option a keyed cell's lookup gives, worked out from the replay's own
/// value of the cell: the value of the entry of `key`, viewed where the map holds it, or none.
fn replayKeyedGet(execution: evaluator.Execution, map: types.Value, key: types.Value, option_type: types.Type, work: *u64, budget: u64) Error!types.Value {
    if (map != .aggregate) return error.InvalidExecution;
    const original = map.aggregate.elements;
    const pool = execution.aggregate_values;
    if (original.start > original.end or original.end > pool.len or (original.end - original.start) % 2 != 0) return error.InvalidExecution;
    const offset = try replayLookup(pool, original, key, work, budget);
    const start: u32 = if (offset) |position| original.start + @as(u32, @intCast(position)) else original.end;
    return .{ .aggregate = .{ .value_type = option_type, .elements = .{ .start = start, .end = start + @intFromBool(offset != null) } } };
}

/// RFC-0087, P5.4: the map a keyed cell's update writes, worked out from the replay's own value
/// of the cell: the entry of `key` replaced or appended, as `map_set` builds it, in the next
/// unused members, which must hold exactly that.
fn replayKeyedSet(execution: evaluator.Execution, map: types.Value, key: types.Value, value: types.Value, prefix: *u32, work: *u64, budget: u64) Error!types.Value {
    if (map != .aggregate) return error.InvalidExecution;
    const original = map.aggregate.elements;
    const pool = execution.aggregate_values;
    if (original.start > original.end or original.end > pool.len or (original.end - original.start) % 2 != 0) return error.InvalidExecution;
    const found = try replayLookup(pool, original, key, work, budget);
    const total: u32 = original.end - original.start + @as(u32, if (found == null) 2 else 0);
    if (prefix.* > pool.len or total > pool.len - prefix.*) return error.InvalidExecution;
    const span: types.Span = .{ .start = prefix.*, .end = prefix.* + total };
    try replayMapSet(execution, original, key, value, span, prefix, work, budget);
    return .{ .aggregate = .{ .value_type = map.aggregate.value_type, .elements = span } };
}

/// RFC-0087, P5.4: whether the pool the replay sees already holds the members the update `c`
/// builds from `prefix` on.
fn replayKeyedHeld(execution: evaluator.Execution, source: *SourceReplay, c: types.WeakSet, registers: []const types.Value, prefix: u32, work: *u64, budget: u64) Error!bool {
    const map = try source.read(c.cell);
    if (map != .aggregate or c.key >= registers.len) return error.InvalidExecution;
    const original = map.aggregate.elements;
    const pool = execution.aggregate_values;
    if (original.start > original.end or original.end > pool.len or (original.end - original.start) % 2 != 0) return error.InvalidExecution;
    const found = try replayLookup(pool, original, registers[c.key], work, budget);
    const total: u32 = original.end - original.start + @as(u32, if (found == null) 2 else 0);
    return prefix <= pool.len and total <= pool.len - prefix;
}

/// The run's record lists exactly the entries its calls took, end to end.
fn admitInputs(execution: evaluator.Execution, replay: *const InputReplay) Error!void {
    const record = execution.effects;
    // RFC-0086, P2.3: the grants are a list a host may give (H1).
    if (!effects.validGrants(record.grants)) return error.InvalidExecution;
    if (record.inputs.len > effects.input_entry_capacity or record.input_bytes.len > effects.input_byte_capacity) return error.InvalidExecution;
    if (replay.cursor != record.inputs.len or replay.bytes != record.input_bytes.len) return error.InvalidExecution;
}

/// The record a run gives of its effects is the one its steps lead to: the seed its draws came
/// from, how many words it drew, the actions it committed in order and how many it discarded.
/// A `full` run also lists the committed actions, which a report shows: they are those actions.
fn admitEffects(execution: evaluator.Execution, replay: *const EffectReplay, work: *u64, budget: u64) Error!void {
    const record = execution.effects;
    if (replay.depth != 0 or replay.mark_count != 0 or replay.pending != 0) return error.InvalidExecution;
    if (replay.stream.seed != record.seed or replay.stream.position != record.draws) return error.InvalidExecution;
    if (!replay.tally.eql(record.output) or replay.discarded != record.discarded) return error.InvalidExecution;
    if (execution.trace != .full) {
        if (record.entries.len != 0 or record.bytes.len != 0) return error.InvalidExecution;
        return;
    }
    if (record.entries.len != record.output.count or record.bytes.len != record.output.bytes) return error.InvalidExecution;
    // Every committed action was compared with its listed one, byte for byte, as it was
    // prepared (`EffectReplay.listed`): the list is exactly those actions, not merely a list
    // that hashes to the same tally.
    std.debug.assert(replay.listed != null);
    if (replay.diverged or replay.cursor != record.entries.len) return error.InvalidExecution;
    var end: u32 = 0;
    for (record.entries) |entry| {
        // The actions lie end to end in the order they were committed.
        if (entry.start != end or entry.end < entry.start or entry.end > record.bytes.len) return error.InvalidExecution;
        // What reading the action costs, as when the list was hashed again here.
        if ((entry.end - entry.start) / 8 + 1 > budget - work.*) return error.ReportLimit;
        work.* += (entry.end - entry.start) / 8 + 1;
        end = entry.end;
    }
    if (end != record.bytes.len) return error.InvalidExecution;
}

/// ABI size of this cold replay state; not persistent backing or resident pages.
pub const source_replay_bytes = @sizeOf(SourceReplay);
const CallVisit = struct {
    function: u32,
    base: u32,
    pc: u32 = 0,
    caller: ?u32,
    arguments: types.Span,
    remaining_visits: u64 = 0,
    seed: types.Value = undefined,
    pending: bool = false,
    returned: ?TraceOutcome = null,
    catchers: [types.limits.control_depth]u32 = undefined,
    catch_depth: u32 = 0,
    state_loop: bool = false,
    captures: types.Span = .{ .start = 0, .end = 0 },
    /// Members in use when the frame was pushed.
    mark: u32 = 0,
    /// Bytes of the string pool and cells in use then.
    string_mark: u32 = 0,
    cell_mark: u32 = 0,
    /// RFC-0082: the switch count at the push; the task whose entry visit this is; whether a
    /// `spawn` below handed off to it; whether it drains committed starts; and the scheduler
    /// step it replays next: its task's `start`, its site's `resume`, or (`ending`, after its
    /// end was reclaimed) its task's `settle`.
    switches: u64 = 0,
    task: u32 = replay_none,
    handoff: bool = false,
    drains: bool = false,
    /// P3.3 adds: its site's `resume_canceled`; the `suspend` of a task whose start phase ended
    /// with arms running (`waits`); the `settle` of a cancelled task's entry visit
    /// (`canceled_end`); and the `call_canceled` of a call whose callee was cancelled. P3.4 adds
    /// the `suspend` of a visit that waits at its end for the tasks it owns (`owned_end`).
    /// P3.7 adds the `resume_canceled` of a structured site whose task an arm asked to cancel,
    /// when every started arm settled in its start phase (`start_canceled`). RFC-0084 P4.6 adds
    /// the `suspend` of a task whose `Await` found its guard failing (`guard_wait`).
    expect: enum { none, start, @"resume", ending, resume_canceled, waits, canceled_end, call_canceled, owned_end, start_canceled, guard_wait } = .none,
    /// P3.4: the tasks it owns, first and last, and whether it ended by `cancel_exit` and waits
    /// for them before it ends cancelled.
    owned_first: u32 = replay_none,
    owned_last: u32 = replay_none,
    canceled_end: bool = false,
    /// The frame of a live guard (RFC-0084), which returns to the propagation that runs it.
    guard: bool = false,
    /// RFC-0082, P3.9: at an `event_notify`: whether its callbacks are being called or have all
    /// returned, the subscription whose callback runs above, and the number below which the
    /// `Signal` calls subscriptions.
    notify: enum { idle, calling, done } = .idle,
    notify_cursor: types.ObjectRef = undefined,
    notify_limit: i64 = 0,
};
/// Combined cold frame/value array reservations, not native stack extent or RSS.
pub const call_replay_bytes = @sizeOf([types.limits.call_depth]CallVisit) + @sizeOf([types.limits.call_registers]types.Value);
/// Where the replay of one root call stands when a window of steps ends inside it. The frames
/// and their locals already live in the replay's own storage.
const CallProgress = struct {
    started: bool = false,
    /// A streamed call begins with the window after the one that reached it: see `functionTrace`.
    waiting: bool = false,
    depth: usize = 0,
    used: u32 = 0,
    /// The failure that left the root frame; the next step must name the root call.
    terminal: ?types.CallFailure = null,
    /// RFC-0082: a run of this task on an empty stack, which it is started on or (`restore`)
    /// restored to.
    task: u32 = replay_none,
    restore: bool = false,
    /// RFC-0084: a propagation or an establishing write the root started, whose guards run
    /// on the empty stack (`LiveRunState`).
    live: bool = false,
    /// P4.4: the root delivers once that propagation is over; and this is a turn of the root's
    /// drain (a reaction's start, or the delivery after the drain), not a node's own call.
    deliver: bool = false,
    turn: bool = false,
    /// What the establishing write before that delivery wrote, which its node yields.
    established: types.Value = .{ .integer = 0 },
};
/// Replays one root call against `steps`, from `step`. Null means the window ended first:
/// call again with the next window and the same `call`.
fn functionTrace(execution: evaluator.Execution, root_pc: u32, root_invocation: types.Invocation, prefix: *u32, steps: []const types.CallStep, step: *usize, failure_count: *u32, source: *SourceReplay, call: *CallProgress, work: *u64, budget: u64) Error!?TraceOutcome {
    const program = execution.program;
    // A frame carries its catchers, so the frame stack is far too large for the native one. It is
    // borrowed once per report and reused by every root call, not once per call.
    if (source.trace_frames.len == 0) source.trace_frames = scratch.alloc(CallVisit, types.limits.call_depth) orelse return error.InvalidExecution;
    if (source.trace_locals.len == 0) source.trace_locals = scratch.alloc(types.Value, types.limits.call_registers) orelse return error.InvalidExecution;
    const frames = source.trace_frames;
    const locals = source.trace_locals;
    if (!call.started and call.task != replay_none) {
        // A task runs on the empty stack (RFC-0082). The run says where the string pool stands
        // as it begins, as it does for a traced call.
        if (source.streaming and !call.waiting) {
            call.waiting = true;
            return null;
        }
        source.string_used = execution.program.strings.len;
        if (source.root_ended and source.root_strings == null) source.root_strings = std.math.cast(u32, source.string_used) orelse return error.InvalidExecution;
        var depth: usize = 0;
        var used: u32 = 0;
        if (call.restore) try replayRestore(source, frames, &depth, &used, call.task) else try replayStart(execution, source, frames, &depth, &used, prefix.*, call.task, false);
        call.* = .{ .started = true, .waiting = call.waiting, .depth = depth, .used = used, .task = call.task, .restore = call.restore };
    }
    if (!call.started and call.live) call.* = .{ .started = true, .live = true, .deliver = call.deliver, .turn = call.turn, .established = call.established };
    if (!call.started) {
        if (root_invocation == .iterate and execution.values[root_invocation.iterate.count].integer == 0) return .{ .ok = execution.values[root_invocation.iterate.initial] };
        // A second run sends what it holds when a traced call begins, and then an empty window
        // from the same moment. So the window after the one in which the replay reached the
        // call shows the string pool as the call found it, whichever of the two that is.
        if (source.streaming and !call.waiting) {
            call.waiting = true;
            return null;
        }
        source.string_used = execution.program.strings.len;
        frames[0] = .{ .function = root_invocation.target(), .base = 0, .caller = null, .arguments = .{ .start = 0, .end = 0 }, .captures = root_invocation.captures(), .mark = prefix.*, .string_mark = std.math.cast(u32, source.string_used) orelse return error.InvalidExecution, .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = source.tasks.switches };
        if (frames[0].captures.end > prefix.*) return error.InvalidExecution;
        switch (root_invocation) {
            .call => |direct| frames[0].arguments = direct.arguments,
            .loop => |loop| {
                try charge(work, budget);
                frames[0].state_loop = true;
                frames[0].seed = execution.values[loop.initial];
            },
            .iterate => |iteration| {
                const count = execution.values[iteration.count].integer;
                if (count < 0) return error.InvalidExecution;
                const initial = execution.values[iteration.initial];
                if (count == 0) return .{ .ok = initial };
                try charge(work, budget);
                frames[0].remaining_visits = @intCast(count);
                frames[0].seed = initial;
            },
        }
        call.* = .{ .started = true, .waiting = call.waiting, .depth = 1, .used = program.functions[root_invocation.target()].body.end - program.functions[root_invocation.target()].body.start };
    }
    var depth = call.depth;
    var used = call.used;
    defer {
        call.depth = depth;
        call.used = used;
    }
    while (depth != 0 or (source.live.run.active and source.live.run.base == 0) or (source.live.react.phase != .idle and source.live.react.base == 0)) {
        // RFC-0084: the propagation or establishing write the frame below started, between its
        // guards' frames.
        if (source.live.run.active and source.live.run.base == depth) {
            switch (try liveDrive(execution, source, frames, &depth, &used, prefix.*, steps, step, work, budget)) {
                .more => continue,
                .window => return null,
                .done => if (depth == 0) {
                    // P4.4: a write or an establishing write of the root delivers next.
                    if (!call.deliver) return .{ .ok = source.live.run.established };
                    call.deliver = false;
                    call.established = source.live.run.established;
                    try replayPoint(source, 0);
                    if (source.live.react.phase == .idle) return .{ .ok = call.established };
                    continue;
                } else continue,
            }
        }
        // P4.4: reactions, between the frames of their guards and bodies.
        if (source.live.react.phase != .idle and source.live.react.base == depth) {
            switch (try reactDrive(execution, source, frames, &depth, &used, prefix.*, root_pc, steps, step, work, budget)) {
                .more => continue,
                .window => return null,
                .done => if (depth == 0) return .{ .ok = call.established } else continue,
            }
        }
        const frame = &frames[depth - 1];
        const f = program.functions[frame.function];
        if (frame.expect == .start or frame.expect == .@"resume" or frame.expect == .resume_canceled) {
            // The task's own first step: its start, or its site completing (RFC-0082), or from
            // P3.3 yielding cancelled.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            const task = &source.tasks.tasks[if (frame.expect == .start) frame.task else replayTaskAt(frames, depth)];
            if (frame.expect == .start) {
                if (event.kind != .start or event.function != frame.function or event.pc != 0 or event.value != .integer or event.value.integer != @as(i64, @intCast(task.sequence))) return error.InvalidExecution;
            } else {
                if (event.function != frame.function or event.pc != frame.pc or task.site_function != frame.function or task.site_pc != frame.pc) return error.InvalidExecution;
                if (task.waits == .guard and frame.expect == .@"resume") {
                    // RFC-0084, P4.6: a task woken at an `Await` stands at the site again and
                    // evaluates its guard there; the site's register is not written.
                    if (event.kind != .@"resume" or !sameValue(event.value, .{ .boolean = true }) or !sameValue(task.resume_value, .{ .boolean = true }) or frame.pending) return error.InvalidExecution;
                    frame.expect = .none;
                    step.* += 1;
                    continue;
                }
                if (task.waits == .frame_end) {
                    // P3.4: a visit that waited at its end for its tasks goes on ending, whether or
                    // not its task was asked to cancel meanwhile.
                    if (frame.expect != .@"resume" or event.kind != .@"resume" or !sameValue(event.value, task.resume_value) or frame.pc != f.body.end - f.body.start) return error.InvalidExecution;
                    frame.expect = .none;
                    step.* += 1;
                    continue;
                }
                if (frame.expect == .resume_canceled) {
                    if (event.kind != .resume_canceled or event.value != .integer or event.value.integer != @as(i64, @intCast(task.sequence))) return error.InvalidExecution;
                    source.tasks.canceled_now = true;
                } else if (task.waits == .record and task.record.exited) {
                    // P3.6: an expression an arm's exit abandoned yields that pending exit to its
                    // check, and not to the site's register.
                    if (event.kind != .resume_exited or !replayRecordDone(&task.record) or !sameValue(event.value, source.tasks.tasks[task.record.winner].result)) return error.InvalidExecution;
                    source.tasks.exited_now = true;
                    source.tasks.exited_value = event.value;
                } else {
                    // An expression that is over yields its winner's result or the tuple of its
                    // results (P3.3); any other site what woke it.
                    const expected = if (task.waits == .record) try replayRecordValue(execution, source, &task.record, event.value, prefix, work, budget) else task.resume_value;
                    if (event.kind != .@"resume" or !sameValue(event.value, expected)) return error.InvalidExecution;
                    locals[frame.base + frame.pc] = event.value;
                }
                frame.pc += 1;
                if (task.waits == .record) {
                    // The expression's arms end with it.
                    try replayArmsRelease(&source.tasks, &task.record);
                    frame.pending = false;
                    frame.returned = null;
                }
            }
            frame.expect = .none;
            step.* += 1;
            continue;
        }
        if (frame.expect == .waits) {
            // P3.3: the start phase ended with arms running, so the task waits on its expression.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            const record = &source.tasks.tasks[replayTaskAt(frames, depth)].record;
            if (event.kind != .@"suspend" or event.function != frame.function or event.pc != frame.pc or event.value != .integer or event.value.integer != record.arms) return error.InvalidExecution;
            step.* += 1;
            frame.expect = .none;
            const entry_depth = try replaySuspendFor(execution.program, source, frames, &depth, &used, .{ .record = record.arms });
            if (depth == 0) return .{ .ok = .{ .boolean = false } };
            try replayLeft(execution, source, frames, &depth, &used, prefix.*, replayLeaveOf(source, frames, entry_depth, depth), root_pc);
            continue;
        }
        if (frame.expect == .guard_wait) {
            // RFC-0084, P4.6: the guard of the `Await` this visit stands at failed, so its task
            // waits on it, with the step that says it waits for no tick.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            if (event.kind != .@"suspend" or event.function != frame.function or event.pc != frame.pc or !sameValue(event.value, .{ .boolean = false })) return error.InvalidExecution;
            step.* += 1;
            frame.expect = .none;
            // Restored, the site evaluates its guard again (N7).
            frame.pending = false;
            const entry_depth = try replaySuspendFor(execution.program, source, frames, &depth, &used, .guard);
            if (depth == 0) return .{ .ok = .{ .boolean = false } };
            try replayLeft(execution, source, frames, &depth, &used, prefix.*, replayLeaveOf(source, frames, entry_depth, depth), root_pc);
            continue;
        }
        if (frame.expect == .start_canceled) {
            // P3.7: an arm asked the task running the expression to cancel, and every started arm
            // settled in the start phase: the site yields cancelled at once.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            const s = &source.tasks;
            if (s.current == replay_none or !s.tasks[s.current].flagged or event.kind != .resume_canceled or event.function != frame.function or event.pc != frame.pc or event.value != .integer or event.value.integer != @as(i64, @intCast(s.tasks[s.current].sequence))) return error.InvalidExecution;
            step.* += 1;
            frame.expect = .none;
            frame.pending = false;
            frame.returned = null;
            frame.pc += 1;
            s.canceled_now = true;
            continue;
        }
        if (frame.expect == .owned_end) {
            // P3.4: the visit is at its end and owns tasks, which it asked to cancel: its task
            // waits there for them, with the step that says how many.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            var count: i64 = 0;
            var owned = frame.owned_first;
            while (owned != replay_none) : (owned = source.tasks.tasks[owned].next_owned) count += 1;
            if (count == 0 or event.kind != .@"suspend" or event.function != frame.function or event.pc != f.body.end - f.body.start or event.value != .integer or event.value.integer != count) return error.InvalidExecution;
            step.* += 1;
            frame.expect = .none;
            const entry_depth = try replaySuspendFor(execution.program, source, frames, &depth, &used, .{ .frame_end = @intCast(count) });
            if (depth == 0) return .{ .ok = .{ .boolean = false } };
            try replayLeft(execution, source, frames, &depth, &used, prefix.*, replayLeaveOf(source, frames, entry_depth, depth), root_pc);
            continue;
        }
        if (frame.task != replay_none and frame.pc == f.body.end - f.body.start and frame.owned_first != replay_none and frame.expect == .none) {
            // P3.4: a task's entry visit that owns tasks asks them to cancel and waits for them.
            if (frame.catch_depth != 0) return error.InvalidExecution;
            try replayOwnedRequests(source, frame);
            frame.expect = .owned_end;
            continue;
        }
        if (frame.canceled_end and frame.expect == .none) {
            // P3.4: a visit that ended by `cancel_exit` waited for its tasks; it ends cancelled now.
            if (frame.owned_first != replay_none) return error.InvalidExecution;
            if (frame.task != replay_none) {
                frame.expect = .canceled_end;
                continue;
            }
            used = frame.base;
            depth -= 1;
            if (depth == 0) return error.InvalidExecution;
            frames[depth - 1].expect = .call_canceled;
            continue;
        }
        if (frame.expect == .canceled_end) {
            // P3.3: the entry visit of a cancelled task ended; its `settle` has no result. A
            // cancelled task runs on the empty stack.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            if (event.kind != .settle or event.function != frame.function or event.pc != f.body.end - f.body.start or event.value != .boolean or event.value.boolean) return error.InvalidExecution;
            step.* += 1;
            const ended = source.tasks.tasks[frame.task];
            var leave: ReplayLeave = .{ .handoff = frame.handoff, .handle = .{ .boolean = false }, .arm_parent = replay_none };
            if (ended.holder != replay_none) {
                // A branch, or a `Rush`'s loser, leaves the visit that owns it (P3.4).
                if (ended.kind == .branch) leave.handle = ended.handle;
                try replayOwnedSettled(source, frames, frame.task, .{ .boolean = false }, true);
            } else if (ended.kind == .arm) {
                leave.arm_parent = ended.parent;
                try replayArmSettled(source, frames, depth - 1, frame.task, .{ .boolean = false }, true);
            } else {
                // P3.7: a spawned task says so in its handle, and its awaiters are asked.
                leave.handle = ended.handle;
                try replaySettleCanceled(source, frame.task);
            }
            used = frame.base;
            depth -= 1;
            if (depth == 0) return .{ .ok = .{ .boolean = false } };
            // P3.7: a task cancelled in its first run leaves its creator what one that completes
            // there does.
            try replayLeft(execution, source, frames, &depth, &used, prefix.*, leave, root_pc);
            continue;
        }
        if (frame.expect == .call_canceled) {
            // P3.3: its callee ended cancelled, so its call yields cancelled, and its check is next.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            if (event.kind != .call_canceled or event.function != frame.function or event.pc != frame.pc or event.value != .boolean or event.value.boolean or !frame.pending) return error.InvalidExecution;
            step.* += 1;
            frame.expect = .none;
            frame.pending = false;
            frame.returned = null;
            frame.pc += 1;
            source.tasks.canceled_now = true;
            continue;
        }
        if (frame.task != replay_none and frame.pc == f.body.end - f.body.start) {
            // A task's entry visit ends: the task completed. Its end reclaims first, as any
            // frame's does; then its `settle` step, which may wait for the next window.
            if (frame.catch_depth != 0) return error.InvalidExecution;
            if (frame.expect != .ending) {
                var ended = locals[frame.base + f.root];
                if (try replayReclaims(source, prefix.*, frame, depth, true)) try replayReclaim(execution, source, prefix, frame, depth, &ended);
                locals[frame.base + f.root] = ended;
                frame.expect = .ending;
            }
            // RFC-0084, P4.4: a reaction's body returned. An `Upon` settles as a task does; a
            // `When` evaluates its guard again; then what fired it goes on (`reactDrive`).
            if (replayReactive(&source.tasks.tasks[frame.task])) {
                const s = &source.tasks;
                const slot = frame.task;
                const task = &s.tasks[slot];
                if (source.effects.depth != 0 or task.state != .running or s.current != slot or source.live.firing == 0 or source.live.react.phase != .idle) return error.InvalidExecution;
                if (task.kind == .upon) {
                    if (step.* == steps.len) return null;
                    const event = steps[step.*];
                    try charge(work, budget);
                    const result = locals[frame.base + f.root];
                    if (event.kind != .settle or event.function != frame.function or event.pc != f.body.end - f.body.start or !sameValue(event.value, result)) return error.InvalidExecution;
                    step.* += 1;
                    if (prefix.* >= execution.aggregate_values.len or !sameValue(execution.aggregate_values[prefix.*], result)) return error.InvalidExecution;
                    const shape = catalogue.definition(task.handle.object.value_type, program.definitions).?.task;
                    try source.objectWrite(task.handle.object, catalogue.task_state - 1, .{ .integer = catalogue.task_completed });
                    try source.objectWrite(task.handle.object, catalogue.task_result - 1, .{ .aggregate = .{ .value_type = shape.option, .elements = .{ .start = prefix.*, .end = prefix.* + 1 } } });
                    prefix.* += 1;
                    s.completed += 1;
                    var awaiter = task.awaiters_first;
                    while (awaiter != replay_none) {
                        const after = s.tasks[awaiter].next_waiter;
                        if (s.tasks[awaiter].state != .waiting or s.tasks[awaiter].waits != .task) return error.InvalidExecution;
                        s.makeReady(awaiter, result);
                        awaiter = after;
                    }
                } else if (task.flagged) {
                    // P4.7 (N6): a `When` asked while it fired settles cancelled, with the
                    // `settle` step of a cancelled task, and registers no more.
                    if (step.* == steps.len) return null;
                    const event = steps[step.*];
                    try charge(work, budget);
                    if (event.kind != .settle or event.function != frame.function or event.pc != f.body.end - f.body.start or event.value != .boolean or event.value.boolean) return error.InvalidExecution;
                    step.* += 1;
                }
                source.live.firing -= 1;
                s.current = task.below;
                task.below = replay_none;
                used = frame.base;
                depth -= 1;
                if (task.kind == .upon) {
                    source.live.react = .{ .phase = .after_body, .base = depth, .slot = slot, .by = task.fired_by, .handle = task.handle };
                    s.release(slot);
                } else if (task.flagged) {
                    source.live.react = .{ .phase = .after_body, .base = depth, .slot = slot, .by = task.fired_by, .handle = task.handle };
                    try replayReactionCanceled(source, slot);
                } else {
                    task.state = .waiting;
                    task.waits = .guard;
                    source.live.react = .{ .phase = .observe, .base = depth, .slot = slot, .why = .when };
                }
                continue;
            }
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            const result = locals[frame.base + f.root];
            if (event.kind != .settle or event.function != frame.function or event.pc != f.body.end - f.body.start or !sameValue(event.value, result)) return error.InvalidExecution;
            step.* += 1;
            const s = &source.tasks;
            const task = &s.tasks[frame.task];
            if (source.effects.depth != 0 or task.state != .running) return error.InvalidExecution;
            if (task.holder != replay_none) {
                // P3.4: a branch, or a `Rush`'s loser, completed: it leaves the visit that owns it,
                // and a branch's creator gets the unit value if it handed off to it.
                const handle: types.Value = if (task.kind == .branch) task.handle else .{ .boolean = false };
                const handoff = frame.handoff;
                try replayOwnedSettled(source, frames, frame.task, result, false);
                used = frame.base;
                depth -= 1;
                if (depth == 0) return .{ .ok = result };
                try replayLeft(execution, source, frames, &depth, &used, prefix.*, .{ .handoff = handoff, .handle = handle, .arm_parent = replay_none }, root_pc);
                continue;
            }
            if (task.kind == .arm) {
                // An arm completed (P3.3): its expression learns it, and goes on starting arms
                // if it was doing so below.
                const parent = task.parent;
                try replayArmSettled(source, frames, depth - 1, frame.task, result, false);
                used = frame.base;
                depth -= 1;
                if (depth == 0) return .{ .ok = result };
                try replayLeft(execution, source, frames, &depth, &used, prefix.*, .{ .handoff = false, .handle = .{ .boolean = false }, .arm_parent = parent }, root_pc);
                continue;
            }
            // The handle holds `option{result}`, the next member.
            if (prefix.* >= execution.aggregate_values.len or !sameValue(execution.aggregate_values[prefix.*], result)) return error.InvalidExecution;
            const shape = catalogue.definition(task.handle.object.value_type, program.definitions).?.task;
            try source.objectWrite(task.handle.object, catalogue.task_state - 1, .{ .integer = catalogue.task_completed });
            try source.objectWrite(task.handle.object, catalogue.task_result - 1, .{ .aggregate = .{ .value_type = shape.option, .elements = .{ .start = prefix.*, .end = prefix.* + 1 } } });
            prefix.* += 1;
            s.completed += 1;
            // Its awaiters resume with the result, in the order they began to wait (P3.2).
            var awaiter = task.awaiters_first;
            while (awaiter != replay_none) {
                const after = s.tasks[awaiter].next_waiter;
                if (s.tasks[awaiter].state != .waiting or s.tasks[awaiter].waits != .task) return error.InvalidExecution;
                s.makeReady(awaiter, result);
                awaiter = after;
            }
            const handle = task.handle;
            const handoff = frame.handoff;
            // P3.4: the task below it on the visit stack runs again.
            if (s.current != frame.task) return error.InvalidExecution;
            s.current = task.below;
            s.release(frame.task);
            used = frame.base;
            depth -= 1;
            if (depth == 0) return .{ .ok = result };
            try replayLeft(execution, source, frames, &depth, &used, prefix.*, .{ .handoff = handoff, .handle = handle, .arm_parent = replay_none }, root_pc);
            continue;
        }
        if (frame.pc == f.body.end - f.body.start) {
            if (frame.catch_depth != 0) return error.InvalidExecution;
            if (frame.owned_first != replay_none) {
                // P3.4: at the end of a visit, or of a loop's visit, it asks the tasks it owns to
                // cancel, and its task waits for them here; the end goes on when they are settled.
                try replayOwnedRequests(source, frame);
                frame.expect = .owned_end;
                continue;
            }
            var returned = locals[frame.base + f.root];
            if (frame.state_loop) {
                if (returned != .aggregate) return error.InvalidExecution;
                const option = returned.aggregate.elements;
                if (option.start > option.end or option.end > prefix.* or option.end - option.start > 1) return error.InvalidExecution;
                if (option.start != option.end) {
                    try charge(work, budget);
                    frame.seed = execution.aggregate_values[option.start];
                    if (!source.live.tracking and try replayReclaims(source, prefix.*, frame, depth, false)) try replayReclaim(execution, source, prefix, frame, depth, &frame.seed);
                    frame.pc = 0;
                    continue;
                }
                returned = frame.seed;
            } else if (frame.remaining_visits > 1) {
                try charge(work, budget);
                frame.remaining_visits -= 1;
                frame.seed = returned;
                if (!source.live.tracking and try replayReclaims(source, prefix.*, frame, depth, false)) try replayReclaim(execution, source, prefix, frame, depth, &frame.seed);
                frame.pc = 0;
                continue;
            }
            // A guard's frame returns its value to the propagation that runs it (RFC-0084), or to
            // the drive of reactions, which asks whether its option is present (P4.4).
            if (frame.guard) {
                if (source.live.react.phase == .guard) {
                    if (returned != .aggregate) return error.InvalidExecution;
                    source.live.react.succeeded = returned.aggregate.elements.start != returned.aggregate.elements.end;
                    // P4.6: what the guard of an `Await` gives is the site's value when it holds.
                    if (source.live.react.why == .site and source.live.react.succeeded) {
                        const option = returned.aggregate.elements;
                        if (option.end != option.start + 1 or option.end > prefix.* or option.start >= execution.aggregate_values.len) return error.InvalidExecution;
                        source.live.react.value = execution.aggregate_values[option.start];
                    }
                    source.live.react.phase = .observed;
                } else {
                    source.live.run.result = returned;
                    source.live.run.phase = .settle;
                }
                used = frame.base;
                depth -= 1;
                continue;
            }
            // A run reclaims where a frame or a visit ends, and its later steps name members
            // where they lie afterwards; the replay moves its own values by the same rule.
            if (!source.live.tracking and try replayReclaims(source, prefix.*, frame, depth, true)) try replayReclaim(execution, source, prefix, frame, depth, &returned);
            used = frame.base;
            depth -= 1;
            if (depth == 0) {
                return .{ .ok = returned };
            }
            frames[depth - 1].returned = .{ .ok = returned };
            continue;
        }
        const entry = program.function_nodes[f.body.start + frame.pc];
        const node = entry.node;
        if (entry.input == .operation and replayPrimitiveSite(node) and !frame.pending and source.tasks.current != replay_none and source.tasks.tasks[source.tasks.current].flagged) {
            // P3.4: the task running was asked to cancel while it waited at a frame's end, which
            // went on: its site yields cancelled at once, with no `suspend` before it.
            if (step.* == steps.len) return null;
            const event = steps[step.*];
            try charge(work, budget);
            if (event.kind != .resume_canceled or event.function != frame.function or event.pc != frame.pc or event.value != .integer or event.value.integer != @as(i64, @intCast(source.tasks.tasks[source.tasks.current].sequence))) return error.InvalidExecution;
            step.* += 1;
            source.tasks.canceled_now = true;
            frame.pc += 1;
            continue;
        }
        if (entry.input == .operation and node.kind == .branch and !frame.pending) {
            // P3.4: a task this visit owns, handed off to: its `start` comes first.
            try charge(work, budget);
            const slot = try replayBranch(source, frames, depth, locals[frame.base + node.kind.branch], node.value_type, root_pc);
            frame.pending = true;
            try replayStart(execution, source, frames, &depth, &used, prefix.*, slot, true);
            continue;
        }
        // RFC-0084, L2: in a live program a write detaches, writes and propagates before its
        // node's step, and `set live` establishes; the step follows the propagation.
        if (entry.input == .operation and source.live.on and !frame.pending and (node.kind == .cell_write or node.kind == .weak_set or node.kind == .object_set or node.kind == .ref_set or node.kind == .cell_live or node.kind == .object_live)) {
            // RFC-0087, P5.4: a streamed window may end before the members of the map a keyed
            // cell's update built: the replay waits for the window that holds them.
            if (node.kind == .weak_set and !try replayKeyedHeld(execution, source, node.kind.weak_set, locals[frame.base .. frame.base + frame.pc], prefix.*, work, budget)) return null;
            try charge(work, budget);
            const registers = locals[frame.base .. frame.base + frame.pc];
            frame.pending = true;
            switch (node.kind) {
                .cell_write => |cell| try liveProgramWrite(source, cell.cell, registers[cell.value], depth, work, budget),
                // RFC-0087, P5.4: the map a keyed cell's update builds is the replay's own, in
                // the next unused members, before the propagation it starts builds anything.
                .weak_set => |c| {
                    try liveProgramWrite(source, c.cell, try replayKeyedSet(execution, try source.read(c.cell), registers[c.key], registers[c.value], prefix, work, budget), depth, work, budget);
                    // RFC-0087, P5.5 (S5): and, for a persistent cell, the action it prepares.
                    try replayStoreAction(execution, source, c.cell, registers[c.key], registers[c.value], work, budget);
                },
                .object_set => |c| {
                    if (registers[c.object] != .object) return error.InvalidExecution;
                    try liveFieldWrite(source, registers[c.object].object, c.index, registers[c.value], depth, work, budget);
                },
                // RFC-0085, I1: a variable cell's value is written as a field is (S9, L2).
                .ref_set => |r| {
                    if (registers[r.ref] != .object) return error.InvalidExecution;
                    try liveFieldWrite(source, registers[r.ref].object, catalogue.ref_value - 1, registers[r.value], depth, work, budget);
                },
                .cell_live => |c| try liveStartEstablish(execution, source, c, registers[c.guard], (@as(i64, frame.function) + 1) << 32 | frame.pc, depth),
                .object_live => |c| {
                    if (registers[c.object] != .object) return error.InvalidExecution;
                    try liveStartField(execution, source, registers[c.object].object, c, node.value_type, registers[c.guard], (@as(i64, frame.function) + 1) << 32 | frame.pc, depth);
                },
                else => unreachable,
            }
            continue;
        }
        if (entry.input == .operation and node.kind == .reaction and !frame.pending and source.effects.depth == 0) {
            // RFC-0084, P4.4: a reaction outside every region starts now; its node's step comes
            // when its first evaluation is over, or after its body when it fires.
            try charge(work, budget);
            const r = node.kind.reaction;
            const slot = try replayReaction(program, source, node.value_type, r, locals[frame.base + r.guard], locals[frame.base + r.body], root_pc, node.span);
            frame.pending = true;
            try replayReactionStart(source, slot, depth, .node);
            continue;
        }
        if (entry.input == .operation and node.kind == .await_guard and !frame.pending) {
            // RFC-0084, P4.6: an `Await` evaluates its guard with tracking first, as an
            // `observe` of the task running; its step, or its task's wait, follows (N7).
            try charge(work, budget);
            const s = &source.tasks;
            const guard = locals[frame.base + node.kind.await_guard];
            if (source.effects.depth != 0 or s.current == replay_none or replayReactive(&s.tasks[s.current]) or guard != .callable or guard.callable.function >= program.functions.len) return error.InvalidExecution;
            if (source.live.react.phase != .idle or source.live.run.active or source.live.tracking) return error.InvalidExecution;
            try source.live.watchFresh(s.current);
            frame.pending = true;
            source.live.react = .{ .phase = .observe, .base = depth, .slot = s.current, .why = .site, .guard = guard.callable };
            continue;
        }
        if (entry.input == .operation and node.kind == .spawn and !frame.pending and source.effects.depth == 0) {
            // Hand-off (RFC-0082, S2): the task's `start` comes before this frame's step.
            try charge(work, budget);
            const slot = try replaySpawn(program, source, node.value_type, locals[frame.base + node.kind.spawn], root_pc);
            frame.pending = true;
            try replayStart(execution, source, frames, &depth, &used, prefix.*, slot, true);
            continue;
        }
        if (entry.input == .operation and node.kind == .structured and !frame.pending) {
            // P3.3: the expression's record is the running task's, and its first arm starts on
            // top. A task on the stack is never asked to cancel in P3.3: a run that says so is
            // not one the replay follows.
            try charge(work, budget);
            if (source.effects.depth != 0) return error.InvalidExecution;
            const owner = replayTaskAt(frames, depth);
            const task = &source.tasks.tasks[owner];
            if (task.flagged) return error.InvalidExecution;
            const arms = node.kind.structured.arms;
            task.record = .{ .kind = node.kind.structured.kind, .function = frame.function, .pc = frame.pc, .arms = arms.end - arms.start, .starting = true };
            frame.pending = true;
            try replayArmStart(execution, source, frames, &depth, &used, prefix.*, owner);
            continue;
        }
        if (entry.input == .operation and node.kind == .batch and !frame.pending) {
            // RFC-0084, P4.5: a batch calls its body with one more batch open; its node's step
            // comes when the body returns, and delivers after it.
            try charge(work, budget);
            const body = locals[frame.base + node.kind.batch];
            if (body != .callable or body.callable.function >= program.functions.len or body.callable.captures.end > prefix.*) return error.InvalidExecution;
            const child = program.functions[body.callable.function];
            const size = child.body.end - child.body.start;
            if (depth == frames.len or size > locals.len - used) return error.InvalidExecution;
            frame.pending = true;
            frames[depth] = .{ .function = body.callable.function, .base = used, .caller = frame.base, .arguments = .{ .start = 0, .end = 0 }, .captures = body.callable.captures, .mark = prefix.*, .string_mark = @intCast(source.string_used), .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = source.tasks.switches };
            used += size;
            depth += 1;
            source.live.batches += 1;
            continue;
        }
        if (entry.input == .operation and node.kind == .event_notify and frame.notify != .done and (!frame.pending or frame.returned != null)) {
            // P3.9: the callbacks of a subscribable event's `Signal`, each a call of this visit
            // that the replay chooses from its own cells (C109, C112, C115); their returns leave
            // no step, and the node's step comes after the last.
            const n = node.kind.event_notify;
            var from: types.Value = undefined;
            if (frame.notify == .idle) {
                try charge(work, budget);
                const target = locals[frame.base + n.callable];
                if (target != .object or frame.pending) return error.InvalidExecution;
                const limit = try source.objectRead(target.object, catalogue.subscription_count - 1);
                if (limit != .integer) return error.InvalidExecution;
                frame.notify_limit = limit.integer;
                frame.notify = .calling;
                from = try source.objectRead(target.object, catalogue.subscription_first - 1);
            } else {
                if (frame.returned.? != .ok) return error.InvalidExecution;
                frame.returned = null;
                frame.pending = false;
                from = try source.objectRead(frame.notify_cursor, catalogue.cancelable_after - 1);
            }
            if (try replayNextSubscription(source, from, frame.notify_limit, work, budget)) |subscription| {
                const callback = try source.objectRead(subscription, catalogue.cancelable_callback - 1);
                if (callback != .callable or callback.callable.function >= program.functions.len or callback.callable.captures.end > prefix.*) return error.InvalidExecution;
                const child = program.functions[callback.callable.function];
                const size = child.body.end - child.body.start;
                if (depth == frames.len or size > locals.len - used) return error.InvalidExecution;
                frame.notify_cursor = subscription;
                frame.pending = true;
                frames[depth] = .{ .function = callback.callable.function, .base = used, .caller = frame.base, .arguments = n.arguments, .captures = callback.callable.captures, .mark = prefix.*, .string_mark = @intCast(source.string_used), .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = source.tasks.switches };
                used += size;
                depth += 1;
                continue;
            }
            frame.notify = .done;
        }
        if (entry.input == .operation and node.isInvocation() and !frame.pending) {
            try charge(work, budget);
            const invocation = node.invocationWith(frame.function, locals[frame.base .. frame.base + frame.pc]).?;
            const child = program.functions[invocation.target()];
            var visit: CallVisit = .{ .function = invocation.target(), .base = used, .caller = frame.base, .arguments = .{ .start = 0, .end = 0 }, .captures = invocation.captures(), .mark = prefix.*, .string_mark = @intCast(source.string_used), .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = source.tasks.switches };
            if (visit.captures.end > prefix.*) return error.InvalidExecution;
            frame.pending = true;
            switch (invocation) {
                .call => |direct| visit.arguments = direct.arguments,
                .loop => |loop| {
                    visit.state_loop = true;
                    visit.seed = locals[frame.base + loop.initial];
                },
                .iterate => |iteration| {
                    const count = locals[frame.base + iteration.count].integer;
                    if (count < 0) return error.InvalidExecution;
                    const initial = locals[frame.base + iteration.initial];
                    if (count == 0) {
                        frame.returned = .{ .ok = initial };
                        continue;
                    }
                    visit.remaining_visits = @intCast(count);
                    visit.seed = initial;
                },
            }
            const size = child.body.end - child.body.start;
            if (depth == frames.len or size > locals.len - used) return error.InvalidExecution;
            frames[depth] = visit;
            used += size;
            depth += 1;
            continue;
        }
        if (step.* == steps.len) return null;
        const event = steps[step.*];
        if (event.function != frame.function or event.pc != frame.pc) return error.InvalidExecution;
        try charge(work, budget);
        if (entry.input == .operation and node.kind == .sleep) {
            // A site (RFC-0082): it completes at once, or the task waits until the tick the
            // replay works out for itself.
            const seconds = locals[frame.base + node.kind.sleep];
            if (seconds != .floating or types.isNan(seconds.floating)) return error.InvalidExecution;
            const unit: types.Value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = 0, .end = 0 } } };
            if (replayWake(seconds.floating, source.tasks.now, source.tasks.rate)) |wake| {
                const told: types.Value = if (wake == replay_never) .{ .boolean = false } else .{ .integer = @intCast(wake) };
                if (event.kind != .@"suspend" or !sameValue(event.value, told)) return error.InvalidExecution;
                step.* += 1;
                const entry_depth = try replaySuspendFor(execution.program, source, frames, &depth, &used, .{ .sleep = wake });
                const waiting = &source.tasks.tasks[frames[entry_depth].task];
                waiting.resume_value = unit;
                if (depth == 0) return .{ .ok = unit };
                try replayLeft(execution, source, frames, &depth, &used, prefix.*, replayLeaveOf(source, frames, entry_depth, depth), root_pc);
                continue;
            }
            if (event.kind != .value or !sameValue(event.value, unit)) return error.InvalidExecution;
            locals[frame.base + frame.pc] = event.value;
            frame.pc += 1;
            step.* += 1;
            continue;
        }
        if (entry.input == .operation and (node.kind == .task_await or node.kind == .event_await)) {
            // A site of P3.2: an await of a completed task gives its result at once; any other
            // await waits, and the replay predicts who wakes it and with what.
            const operand = locals[frame.base + (if (node.kind == .task_await) node.kind.task_await else node.kind.event_await)];
            if (operand != .object) return error.InvalidExecution;
            const instance = operand.object;
            var wait: ReplayWait = .{ .event = instance };
            // P3.9: a sticky event that was signalled gives its value at once (C105).
            if (try replaySticky(source, instance)) |held| {
                if (event.kind != .value or !sameValue(event.value, held)) return error.InvalidExecution;
                locals[frame.base + frame.pc] = event.value;
                frame.pc += 1;
                step.* += 1;
                continue;
            }
            // P3.7: an `awaitable(T)` may hold an event, which is awaited as such.
            if (node.kind == .task_await and !catalogue.isEvent(instance.value_type, program.definitions)) {
                const state = try source.objectRead(instance, catalogue.task_state - 1);
                if (state != .integer) return error.InvalidExecution;
                if (state.integer == catalogue.task_canceled) {
                    // P3.7 (Q3): the awaiter's own task is asked to cancel, and the site yields
                    // cancelled at once.
                    const s = &source.tasks;
                    if (s.current == replay_none or s.tasks[s.current].flagged or event.kind != .resume_canceled or event.value != .integer or event.value.integer != @as(i64, @intCast(s.tasks[s.current].sequence))) return error.InvalidExecution;
                    s.tasks[s.current].flagged = true;
                    s.canceled_now = true;
                    frame.pc += 1;
                    step.* += 1;
                    continue;
                }
                if (state.integer == catalogue.task_completed) {
                    const held = try source.objectRead(instance, catalogue.task_result - 1);
                    if (held != .aggregate or held.aggregate.elements.end != held.aggregate.elements.start + 1 or held.aggregate.elements.start >= execution.aggregate_values.len) return error.InvalidExecution;
                    if (event.kind != .value or !sameValue(event.value, execution.aggregate_values[held.aggregate.elements.start])) return error.InvalidExecution;
                    locals[frame.base + frame.pc] = event.value;
                    frame.pc += 1;
                    step.* += 1;
                    continue;
                }
                if (state.integer != catalogue.task_active) return error.InvalidExecution;
                const sequence = try source.objectRead(instance, catalogue.task_sequence - 1);
                if (sequence != .integer or sequence.integer < 1) return error.InvalidExecution;
                wait = .{ .task = .{ .handle = instance, .slot = source.tasks.slotOf(@intCast(sequence.integer)) orelse return error.InvalidExecution } };
            }
            if (event.kind != .@"suspend" or !sameValue(event.value, operand)) return error.InvalidExecution;
            step.* += 1;
            const entry_depth = try replaySuspendFor(execution.program, source, frames, &depth, &used, wait);
            if (depth == 0) return .{ .ok = .{ .boolean = false } };
            try replayLeft(execution, source, frames, &depth, &used, prefix.*, replayLeaveOf(source, frames, entry_depth, depth), root_pc);
            continue;
        }
        if (event.kind == .arm_exit) {
            // P3.6: an exit of an arm's entry visit, which commits its open regions as an exit
            // does, and hands its expression the pending exit when the visit has ended.
            if (entry.input != .operation or node.kind != .arm_exit or frame.task == replay_none) return error.InvalidExecution;
            const arm = &source.tasks.tasks[frame.task];
            const exits = f.exits orelse return error.InvalidExecution;
            if (arm.kind != .arm or !conforms(execution, event.value, exits) or !sameValue(event.value, locals[frame.base + node.kind.arm_exit])) return error.InvalidExecution;
            step.* += 1;
            var drain = false;
            const committed = frame.catch_depth != 0;
            while (frame.catch_depth != 0) {
                if (f.has_source) try source.commit(work, budget);
                if (try source.regionCommit()) drain = true;
                frame.catch_depth -= 1;
            }
            arm.exited = true;
            locals[frame.base + f.root] = event.value;
            frame.pc = f.body.end - f.body.start;
            if (drain) try replayDrainFrom(execution, source, frames, &depth, &used, prefix.*, root_pc);
            // RFC-0084, P4.4: a commit to depth 0 delivers, after its drain, as an exit does.
            if (committed and !drain and source.live.on) try replayPoint(source, depth);
            continue;
        }
        if (event.kind == .resume_exited) {
            // P3.6: an expression an arm's exit abandoned, all of whose started arms settled in
            // its start phase, yields the pending exit to its check at once.
            if (entry.input != .operation or node.kind != .structured or !frame.pending or frame.returned != null) return error.InvalidExecution;
            const s = &source.tasks;
            const record = &s.tasks[replayTaskAt(frames, depth)].record;
            if (!record.done or !record.exited or !sameValue(event.value, s.tasks[record.winner].result)) return error.InvalidExecution;
            try replayArmsRelease(s, record);
            frame.pending = false;
            s.exited_now = true;
            s.exited_value = event.value;
            frame.pc += 1;
            step.* += 1;
            continue;
        }
        if (event.kind == .exit) {
            // The frame ends here with the operand as its result. Its open regions are
            // committed, as the run committed them, so the source replay keeps their writes.
            if (entry.input != .operation or node.kind != .exit) return error.InvalidExecution;
            if (!conforms(execution, event.value, f.value_type) or !sameValue(event.value, locals[frame.base + node.kind.exit])) return error.InvalidExecution;
            step.* += 1;
            var drain = false;
            const committed = frame.catch_depth != 0;
            while (frame.catch_depth != 0) {
                if (f.has_source) try source.commit(work, budget);
                if (try source.regionCommit()) drain = true;
                frame.catch_depth -= 1;
            }
            locals[frame.base + f.root] = event.value;
            frame.pc = f.body.end - f.body.start;
            if (drain) try replayDrainFrom(execution, source, frames, &depth, &used, prefix.*, root_pc);
            // RFC-0084, P4.4: a commit to depth 0 delivers, after its drain.
            if (committed and !drain and source.live.on) try replayPoint(source, depth);
            continue;
        }
        if (event.kind == .cancel_exit) {
            // P3.3: the landing ran; the frame ends cancelled, and writes and reclaims nothing.
            if (entry.input != .operation or node.kind != .cancel_exit or event.value != .boolean or event.value.boolean or frame.catch_depth != 0) return error.InvalidExecution;
            step.* += 1;
            if (frame.owned_first != replay_none) {
                // P3.4: it waits for the tasks it owns first, at its end.
                frame.canceled_end = true;
                frame.pc = f.body.end - f.body.start;
                try replayOwnedRequests(source, frame);
                frame.expect = .owned_end;
                continue;
            }
            if (frame.task != replay_none) {
                frame.expect = .canceled_end;
                continue;
            }
            used = frame.base;
            depth -= 1;
            if (depth == 0) return error.InvalidExecution;
            frames[depth - 1].expect = .call_canceled;
            continue;
        }
        if (event.kind == .failure or event.kind == .propagate) {
            if (entry.input != .operation) return error.InvalidExecution;
            var cause: types.CallFailure = undefined;
            if (event.kind == .failure) {
                const operand = switch (node.kind) {
                    .demand => |n| blk: {
                        if (event.value != .boolean or event.value.boolean) return error.InvalidExecution;
                        break :blk n;
                    },
                    .fail => |n| blk: {
                        if (event.value != .string) return error.InvalidExecution;
                        break :blk n;
                    },
                    else => return error.InvalidExecution,
                };
                if (!sameValue(event.value, locals[frame.base + operand])) return error.InvalidExecution;
                cause = .{ .function = frame.function, .pc = frame.pc, .value = event.value };
                try admitFailure(execution, source, failure_count, .{ .instruction = root_pc, .function = cause.function, .pc = cause.pc, .span = node.span, .code = if (node.kind == .fail) .language_failure else .requirement_failed, .reason = if (node.kind == .fail) event.value.string else null });
            } else {
                if (!node.isInvocation() or !frame.pending or frame.returned == null or frame.returned.? != .language) return error.InvalidExecution;
                cause = frame.returned.?.language;
                if (!sameValue(event.value, cause.value)) return error.InvalidExecution;
                frame.pending = false;
                frame.returned = null;
            }
            step.* += 1;
            if (frame.catch_depth != 0) {
                if (f.has_source) try source.abort(work, budget);
                try source.regionAbort();
                frame.catch_depth -= 1;
                const begin = frame.catchers[frame.catch_depth];
                locals[frame.base + begin] = .{ .boolean = false };
                frame.pc = program.function_nodes[f.body.start + begin].node.kind.attempt_begin.alternative + 1;
                continue;
            }
            if (!f.decides) return error.InvalidExecution;
            used = frame.base;
            depth -= 1;
            if (depth != 0) {
                frames[depth - 1].returned = .{ .language = cause };
                continue;
            }
            call.terminal = cause;
            continue;
        }
        if (event.kind != .value) return error.InvalidExecution;
        if (!conforms(execution, event.value, node.value_type)) return error.InvalidExecution;
        var drain = false;
        // RFC-0084, P4.4: a write, an establishing write or a commit delivers after its step.
        var point = false;
        // An effect native is run again, against the replay's own port (RFC-0079).
        if (entry.input == .operation and node.kind == .native_call) try replayEffect(program, node.kind.native_call, locals[frame.base .. frame.base + frame.pc], event.value, execution.aggregate_values, source, work, budget);
        var next = frame.pc + 1;
        switch (entry.input) {
            .parameter => |n| {
                const captured = frame.captures.end - frame.captures.start;
                const expected = if (n < captured) execution.aggregate_values[frame.captures.start + n] else if (frame.state_loop or frame.remaining_visits != 0) seed: {
                    if (n != captured) return error.InvalidExecution;
                    break :seed frame.seed;
                } else argument: {
                    const arguments = if (frame.caller == null) program.call_arguments else program.function_arguments;
                    const operand = arguments[frame.arguments.start + n - captured];
                    break :argument if (frame.caller) |base| locals[base + operand] else execution.values[operand];
                };
                if (!sameValue(event.value, expected)) return error.InvalidExecution;
            },
            .global => |n| if (!sameValue(event.value, execution.values[program.globals[n].node])) return error.InvalidExecution,
            .operation => switch (node.kind) {
                .if_begin => |b| {
                    if (!sameValue(event.value, locals[frame.base + b.condition])) return error.InvalidExecution;
                    if (!event.value.boolean) next = b.alternative + 1;
                },
                .attempt_begin => {
                    if (!event.value.boolean or frame.catch_depth == frame.catchers.len) return error.InvalidExecution;
                    if (f.has_source) try source.begin(work, budget);
                    source.effects.begin();
                    frame.catchers[frame.catch_depth] = frame.pc;
                    frame.catch_depth += 1;
                },
                .otherwise => |begin| {
                    if (!event.value.boolean or !locals[frame.base + begin].boolean) return error.InvalidExecution;
                    const marker = program.function_nodes[f.body.start + begin].node;
                    if (marker.kind == .attempt_begin) {
                        if (frame.catch_depth == 0 or frame.catchers[frame.catch_depth - 1] != begin) return error.InvalidExecution;
                        if (f.has_source) try source.commit(work, budget);
                        drain = try source.regionCommit();
                        frame.catch_depth -= 1;
                        point = source.live.on;
                    }
                    next = nodeBranch(marker).end;
                },
                .local_set => |n| if (!sameValue(event.value, locals[frame.base + n])) return error.InvalidExecution,
                .upcast => |n| if (!sameValue(event.value, widened(locals[frame.base + n], node.value_type))) return error.InvalidExecution,
                .downcast => |n| if (!sameValue(event.value, widened(locals[frame.base + n], node.value_type))) return error.InvalidExecution,
                // RFC-0083: the operand's value, unchanged; the step's value conforms to the
                // node's type, so a refinement's bounds hold (`conforms`).
                .refine => |n| if (!sameValue(event.value, locals[frame.base + n])) return error.InvalidExecution,
                .instance_of => |c| if (event.value != .boolean or event.value.boolean != castsTo(execution, locals[frame.base + c.value], c.class)) return error.InvalidExecution,
                .method_value => |m| {
                    const function = catalogue.dispatchLookup(program.dispatch, locals[frame.base + m.receiver].object.value_type, m.slot) orelse return error.InvalidExecution;
                    if (event.value != .callable or event.value.callable.function != function or event.value.callable.captures.start != 0 or event.value.callable.captures.end != 0) return error.InvalidExecution;
                },
                .field, .tuple_element => |access| {
                    const original = locals[frame.base + access.value].aggregate.elements;
                    if (access.index >= original.end - original.start or !sameValue(event.value, execution.aggregate_values[original.start + access.index])) return error.InvalidExecution;
                },
                .array_get => |access| {
                    const original = locals[frame.base + access.array].aggregate.elements;
                    const position = locals[frame.base + access.index].integer;
                    if (position < 0 or position >= original.end - original.start or !sameValue(event.value, execution.aggregate_values[original.start + @as(u32, @intCast(position))])) return error.InvalidExecution;
                },
                .map_key, .map_value => |access| {
                    const original = locals[frame.base + access.array].aggregate.elements;
                    const position = locals[frame.base + access.index].integer;
                    if (position < 0 or position >= (original.end - original.start) / 2) return error.InvalidExecution;
                    const member = original.start + 2 * @as(u32, @intCast(position)) + @intFromBool(node.kind == .map_value);
                    if (!sameValue(event.value, execution.aggregate_values[member])) return error.InvalidExecution;
                },
                .cell_read => |cell| {
                    if (!sameValue(event.value, try source.read(cell))) return error.InvalidExecution;
                    // A guard that runs depends on what it reads (RFC-0084, L3).
                    if (source.live.tracking) try source.live.track(cell);
                },
                .cell_write => |cell| {
                    if (!sameValue(event.value, locals[frame.base + cell.value])) return error.InvalidExecution;
                    // In a live program the write was made before the propagation it started.
                    if (!frame.pending) try source.write(cell.cell, event.value, false);
                    point = frame.pending;
                    frame.pending = false;
                },
                .cell_live, .object_live => {
                    if (!frame.pending or !sameValue(event.value, source.live.run.established)) return error.InvalidExecution;
                    frame.pending = false;
                    point = true;
                },
                .cell_init => return error.InvalidExecution,
                // RFC-0087, P5.4: a keyed cell's lookup in the replay's own cell, a dependency of
                // a guard that runs (L3); its update, a write of the map the replay builds (W6).
                .weak_get => |g| {
                    if (!sameValue(event.value, try replayKeyedGet(execution, try source.read(g.cell), locals[frame.base + g.key], node.value_type, work, budget))) return error.InvalidExecution;
                    if (source.live.tracking) try source.live.track(g.cell);
                },
                .weak_set => |c| {
                    if (!sameValue(event.value, locals[frame.base + c.value])) return error.InvalidExecution;
                    if (!frame.pending) {
                        try source.write(c.cell, try replayKeyedSet(execution, try source.read(c.cell), locals[frame.base + c.key], locals[frame.base + c.value], prefix, work, budget), false);
                        // RFC-0087, P5.5 (S5): a persistent cell's write is also an action.
                        try replayStoreAction(execution, source, c.cell, locals[frame.base + c.key], locals[frame.base + c.value], work, budget);
                    }
                    point = frame.pending;
                    frame.pending = false;
                },
                .weak_init => return error.InvalidExecution,
                .object_new => |c| {
                    var fields: [types.limits.record_fields]types.Value = undefined;
                    const arguments = program.function_arguments[c.arguments.start..c.arguments.end];
                    for (arguments, fields[0..arguments.len]) |operand, *out| out.* = locals[frame.base + operand];
                    try charge(work, budget);
                    if (!sameValue(event.value, .{ .object = try source.allocate(node.value_type, fields[0..arguments.len]) })) return error.InvalidExecution;
                },
                .object_get => |a| {
                    const instance = locals[frame.base + a.value].object;
                    if (!sameValue(event.value, try source.objectRead(instance, a.index))) return error.InvalidExecution;
                    // Only a `var` field is a dependency, and a live-only one (L3, P4.2).
                    if (source.live.tracking) {
                        const field = catalogue.classFieldAt(instance.value_type, a.index, program.definitions, program.fields) orelse return error.InvalidExecution;
                        if (field.is_var or field.live_only) try source.live.track(try liveFieldCell(source, instance, a.index));
                    }
                },
                .object_set => |c| {
                    if (!sameValue(event.value, locals[frame.base + c.value])) return error.InvalidExecution;
                    if (!frame.pending) try source.objectWrite(locals[frame.base + c.object].object, c.index, event.value);
                    point = frame.pending;
                    frame.pending = false;
                },
                // RFC-0085, I1: a variable cell is made with its operand, its value is what the
                // replay's own cells hold (worked out, not taken from the step), and a write is
                // made as a field's is.
                .ref_new => |operand| {
                    try charge(work, budget);
                    if (!sameValue(event.value, .{ .object = try source.allocate(node.value_type, &.{locals[frame.base + operand]}) })) return error.InvalidExecution;
                },
                .ref_get => |operand| {
                    const cell = locals[frame.base + operand];
                    if (cell != .object) return error.InvalidExecution;
                    if (!sameValue(event.value, try source.objectRead(cell.object, catalogue.ref_value - 1))) return error.InvalidExecution;
                    // Its value can change, so a guard that reads it depends on it (S9, L3).
                    if (source.live.tracking) try source.live.track(try liveFieldCell(source, cell.object, catalogue.ref_value - 1));
                },
                .ref_set => |r| {
                    if (!sameValue(event.value, locals[frame.base + r.value]) or locals[frame.base + r.ref] != .object) return error.InvalidExecution;
                    if (!frame.pending) try source.objectWrite(locals[frame.base + r.ref].object, catalogue.ref_value - 1, event.value);
                    point = frame.pending;
                    frame.pending = false;
                },
                .demand => |operand| {
                    if (!event.value.boolean or !sameValue(event.value, locals[frame.base + operand])) return error.InvalidExecution;
                },
                // None of these three yields a value: a failure and an exit have their own step
                // kinds, and a run that reached `err` has no report.
                .fail, .exit, .err => return error.InvalidExecution,
                .arm_exit => return error.InvalidExecution,
                // P3.6: true just after a site that yielded an arm's pending exit, and only there;
                // then that exit's value.
                .arm_exited => {
                    if (event.value.boolean != source.tasks.exited_now) return error.InvalidExecution;
                    source.tasks.exited_now = false;
                },
                .arm_exit_value => if (!sameValue(event.value, source.tasks.exited_value)) return error.InvalidExecution,
                .merge => |m| {
                    const selected = if (locals[frame.base + m.begin].boolean) m.left else m.right;
                    if (!sameValue(event.value, widened(locals[frame.base + selected], node.value_type))) return error.InvalidExecution;
                },
                .call, .iterate, .recur, .invoke, .iterate_value, .loop => {
                    if (!frame.pending or frame.returned == null or frame.returned.? != .ok or !sameValue(event.value, frame.returned.?.ok)) return error.InvalidExecution;
                    frame.pending = false;
                    frame.returned = null;
                },
                // RFC-0084, P4.5: what the body of the batch returned; one batch fewer is open, and
                // the node delivers.
                .batch => {
                    if (!frame.pending or frame.returned == null or frame.returned.? != .ok or !sameValue(event.value, frame.returned.?.ok) or source.live.batches == 0) return error.InvalidExecution;
                    frame.pending = false;
                    frame.returned = null;
                    source.live.batches -= 1;
                    point = source.live.on;
                },
                // RFC-0084, P4.6: what the guard of an `Await` gave, once it held.
                .await_guard => {
                    if (!frame.pending or frame.returned == null or frame.returned.? != .ok or !sameValue(event.value, frame.returned.?.ok)) return error.InvalidExecution;
                    frame.pending = false;
                    frame.returned = null;
                },
                // P3.4: the unit value, once the branch this visit handed off to first left the stack.
                .branch => {
                    if (!frame.pending or frame.returned == null or frame.returned.? != .ok or !sameValue(event.value, frame.returned.?.ok)) return error.InvalidExecution;
                    frame.pending = false;
                    frame.returned = null;
                },
                // RFC-0084, P4.4: the handle, once the reaction's first evaluation is over without
                // firing it; inside a region, at once, its start held.
                .reaction => |r| if (frame.pending) {
                    if (frame.returned == null or frame.returned.? != .ok or !sameValue(event.value, frame.returned.?.ok)) return error.InvalidExecution;
                    frame.pending = false;
                    frame.returned = null;
                } else {
                    if (source.effects.depth == 0) return error.InvalidExecution;
                    const slot = try replayReaction(program, source, node.value_type, r, locals[frame.base + r.guard], locals[frame.base + r.body], root_pc, node.span);
                    try replayHold(source, slot);
                    if (!sameValue(event.value, source.tasks.tasks[slot].handle)) return error.InvalidExecution;
                },
                .spawn => |operand| if (frame.pending) {
                    // The handle, once the task this frame handed off to first left the stack.
                    if (frame.returned == null or frame.returned.? != .ok or !sameValue(event.value, frame.returned.?.ok)) return error.InvalidExecution;
                    frame.pending = false;
                    frame.returned = null;
                } else {
                    // Inside a region the start is held, and the handle is the value now.
                    if (source.effects.depth == 0) return error.InvalidExecution;
                    const slot = try replaySpawn(program, source, node.value_type, locals[frame.base + operand], root_pc);
                    try replayHold(source, slot);
                    if (!sameValue(event.value, source.tasks.tasks[slot].handle)) return error.InvalidExecution;
                },
                // P3.3: true just after a site that yielded cancelled, and only there.
                .canceling => {
                    if (event.value.boolean != source.tasks.canceled_now) return error.InvalidExecution;
                    source.tasks.canceled_now = false;
                },
                .cancel_exit, .sleep, .task_await, .event_await => return error.InvalidExecution,
                // P3.7: a cancellation request, made again by the replay; and the clock.
                .task_cancel => |operand| {
                    if (event.value != .aggregate or event.value.aggregate.elements.start != event.value.aggregate.elements.end) return error.InvalidExecution;
                    try replayCancel(source, locals[frame.base + operand]);
                },
                .elapsed_time => if (!sameValue(event.value, .{ .floating = replayElapsed(&source.tasks) })) return error.InvalidExecution,
                // RFC-0086, P2.3: a handle of the run's grants, or `option{}`.
                .grant => |g| if (g.kind == .session) {
                    // RFC-0087, P5.4: the session, which builds nothing.
                    if (!sameValue(event.value, replaySession(node.value_type))) return error.InvalidExecution;
                } else try replayGrant(source.inputs.grants, g, locals[frame.base + g.name], event.value, execution.aggregate_values, prefix, program, work, budget),
                // RFC-0087, P5.3: encoded or decoded again with the codec, and compared.
                .json_encode => |operand| try replayJsonEncode(execution, source, program.function_nodes[f.body.start + operand].node.value_type, locals[frame.base + operand], event.value, work, budget),
                .json_decode => |operand| try replayJsonDecode(execution, source, node.value_type, locals[frame.base + operand], event.value, prefix, work, budget),
                // The value of an expression that could yield as its start phase ended (P3.3).
                .structured => {
                    const record = &source.tasks.tasks[replayTaskAt(frames, depth)].record;
                    if (!frame.pending or frame.returned != null or !record.done) return error.InvalidExecution;
                    if (!sameValue(event.value, try replayRecordValue(execution, source, record, event.value, prefix, work, budget))) return error.InvalidExecution;
                    try replayArmsRelease(&source.tasks, record);
                    frame.pending = false;
                },
                // P3.2: the event the run built is the replay's next instance; a signal is the
                // unit value, carried out now or held by the innermost region.
                .event_new => {
                    const built = try replayEvent(source, node.value_type);
                    if (!sameValue(event.value, .{ .object = built })) return error.InvalidExecution;
                },
                .event_signal => |signal| {
                    if (event.value != .aggregate or event.value.aggregate.elements.start != event.value.aggregate.elements.end) return error.InvalidExecution;
                    try replaySignalNode(source, locals[frame.base + signal.event], locals[frame.base + signal.value]);
                },
                // P3.9: a subscription the run made is the replay's next instance; one ended, the
                // unit value; the calls of a `Signal` were replayed before its step.
                .event_subscribe => |c| {
                    const built = try replaySubscribe(source, locals[frame.base + c.event], locals[frame.base + c.callback], node.value_type, work, budget);
                    if (!sameValue(event.value, .{ .object = built })) return error.InvalidExecution;
                },
                .subscription_cancel => |operand| {
                    if (event.value != .aggregate or event.value.aggregate.elements.start != event.value.aggregate.elements.end) return error.InvalidExecution;
                    try replayUnsubscribe(source, locals[frame.base + operand]);
                },
                .event_notify => {
                    if (frame.notify != .done or frame.pending or event.value != .aggregate or event.value.aggregate.elements.start != event.value.aggregate.elements.end) return error.InvalidExecution;
                    frame.notify = .idle;
                },
                .bind => try replayBind(execution, node, event.value, locals[frame.base .. frame.base + frame.pc], program.function_arguments, prefix, work, budget),
                .option_value => |operand| {
                    const original = locals[frame.base + operand].aggregate.elements;
                    if (original.start == original.end or !sameValue(event.value, execution.aggregate_values[original.start])) return error.InvalidExecution;
                },
                .map_set => |set| {
                    const original = locals[frame.base + set.map].aggregate.elements;
                    if (event.value != .aggregate) return error.InvalidExecution;
                    try replayMapSet(execution, original, locals[frame.base + set.key], locals[frame.base + set.value], event.value.aggregate.elements, prefix, work, budget);
                },
                .map_remove => |removal| {
                    const original = locals[frame.base + removal.map].aggregate.elements;
                    if (event.value != .aggregate) return error.InvalidExecution;
                    try replayMapRemove(execution, original, locals[frame.base + removal.key], event.value.aggregate.elements, prefix, work, budget);
                },
                .array_set => |set| {
                    const original = locals[frame.base + set.array].aggregate.elements;
                    const position = locals[frame.base + set.index].integer;
                    const span = event.value.aggregate.elements;
                    if (position < 0 or position >= original.end - original.start or span.start != prefix.* or span.end - span.start != original.end - original.start or span.end > execution.aggregate_values.len) return error.InvalidExecution;
                    for (execution.aggregate_values[span.start..span.end], 0..) |actual, offset| {
                        const expected = if (offset == @as(usize, @intCast(position))) locals[frame.base + set.value] else execution.aggregate_values[original.start + offset];
                        try charge(work, budget);
                        if (!sameValue(actual, expected)) return error.InvalidExecution;
                    }
                    prefix.* = span.end;
                },
                .array_concat => |c| {
                    const left = locals[frame.base + c.lhs].aggregate.elements;
                    const right = locals[frame.base + c.rhs].aggregate.elements;
                    if (event.value != .aggregate) return error.InvalidExecution;
                    try replayConcat(execution, left, right, event.value.aggregate.elements, prefix, array_concat.contextOf(frame.mark, source.root_ended, source.root_members, frame.switches != source.tasks.switches, source.tasks.saved_live != 0), work, budget);
                },
                .native_call => |c| if (event.value == .aggregate) {
                    // A native that computes is run again; its fresh results occupy exactly
                    // the next unused members.
                    try replayNative(execution, source, c, locals[frame.base .. frame.base + frame.pc], event.value, prefix.*, work, budget);
                    const span = event.value.aggregate.elements;
                    if (span.start != prefix.* or span.end < span.start or span.end > execution.aggregate_values.len) return error.InvalidExecution;
                    for (execution.aggregate_values[span.start..span.end]) |_| try charge(work, budget);
                    prefix.* = span.end;
                } else try replayNative(execution, source, c, locals[frame.base .. frame.base + frame.pc], event.value, prefix.*, work, budget),
                .aggregate => |r| {
                    const count = r.end - r.start;
                    if (prefix.* > execution.aggregate_values.len or count > execution.aggregate_values.len - prefix.* or event.value != .aggregate) return error.InvalidExecution;
                    const expected: types.Span = .{ .start = prefix.*, .end = prefix.* + count };
                    if (!std.meta.eql(event.value.aggregate.elements, expected)) return error.InvalidExecution;
                    for (program.function_members[r.start..r.end], execution.aggregate_values[expected.start..expected.end]) |operand, actual| {
                        try charge(work, budget);
                        if (!sameValue(actual, locals[frame.base + operand])) return error.InvalidExecution;
                    }
                    prefix.* = expected.end;
                },
                .function_value => |id| if (event.value != .callable or event.value.callable.function != id or event.value.callable.captures.start != 0 or event.value.callable.captures.end != 0) return error.InvalidExecution,
                .self_value => if (event.value != .callable or event.value.callable.function != frame.function or event.value.callable.captures.start != 0 or event.value.callable.captures.end != 0) return error.InvalidExecution,
                .enumeration => |index| if (event.value.enumeration.index != index) return error.InvalidExecution,
                .character => |code| if (event.value.enumeration.index != code) return error.InvalidExecution,
                .text => |t| try replayText(t, node.value_type, .{ locals[frame.base + t.a], if (t.op.arity() > 1) locals[frame.base + t.b] else event.value, if (t.op.arity() > 2) locals[frame.base + t.c] else event.value }, execution.aggregate_values, event.value, work, budget),
                // Every other node computes its value from its operands, which the replay does
                // too; a kind it does not know is one no run records a value for.
                else => if (!try replayPure(execution, node, locals[frame.base .. frame.base + frame.pc], event.value, work, budget)) return error.InvalidExecution,
            },
        }
        locals[frame.base + frame.pc] = event.value;
        frame.pc = next;
        step.* += 1;
        // What this region committed starts now, one task at a time (RFC-0082).
        if (drain) try replayDrainFrom(execution, source, frames, &depth, &used, prefix.*, root_pc);
        // RFC-0084, P4.4: and what it notified is delivered, after the drain it began.
        if (point and !drain) try replayPoint(source, depth);
        // The string pool ends where the newest string does. A native may have built more than
        // it returned, so a second run sends its window, which says where, after each one.
        if (event.value == .string and event.value.string.len != 0) source.string_used = @max(source.string_used, @intFromPtr(event.value.string.ptr) - @intFromPtr(program.strings.ptr) + event.value.string.len);
        // RFC-0087, P5.3: so does a decode, whose strings its result names only through members.
        if (source.streaming and entry.input == .operation and (node.kind == .native_call or node.kind == .json_decode)) {
            if (step.* != steps.len) return error.InvalidExecution;
            source.string_used = program.strings.len;
            // The run sent this window before it went on, so nothing that follows the step
            // has happened in it yet: a frame that ends here is replayed with the next window,
            // which is the one the run sends if it reclaims there.
            return null;
        }
    }
    // A live run at the root has no frame that fails.
    if (call.live) return error.InvalidExecution;
    // Only a failure that left the root frame ends the loop without returning.
    const cause = call.terminal.?;
    if (step.* == steps.len) return null;
    const terminal = steps[step.*];
    try charge(work, budget);
    if (terminal.kind != .root_failure or terminal.function != root_invocation.target() or terminal.pc != root_pc or !sameValue(terminal.value, cause.value)) return error.InvalidExecution;
    step.* += 1;
    return .{ .language = cause };
}

/// A text operation (RFC-0069) worked out again from its operands, in the replay's own words:
/// the result a machine recorded must be this one. `operands` holds the values the operation
/// takes, in order. The units an operation walks are charged to the report.
fn replayText(t: types.Text, result: types.Type, operands: [3]types.Value, members: []const types.Value, actual: types.Value, work: *u64, budget: u64) Error!void {
    switch (t.op) {
        .unit, .boundary, .slice, .scalar, .code, .from_code => if (!sameValue(actual, try replayTextValue(t, result, operands))) return error.InvalidExecution,
        .valid, .join => {
            const range = operands[0].aggregate.elements;
            if (range.start > range.end or range.end > members.len) return error.InvalidExecution;
            const units = members[range.start..range.end];
            if (t.op == .join and (actual != .string or actual.string.len != units.len)) return error.InvalidExecution;
            var scan: UnitScan = .{};
            var valid = true;
            for (units, 0..) |unit, index| {
                try charge(work, budget);
                if (unit != .enumeration or unit.enumeration.value_type != types.Type.char or unit.enumeration.index > 0xFF) return error.InvalidExecution;
                const byte: u8 = @intCast(unit.enumeration.index);
                if (t.op == .join and actual.string[index] != byte) return error.InvalidExecution;
                valid = valid and scan.feed(byte);
            }
            valid = valid and scan.need == 0;
            // A machine joins only valid units, and says so truthfully when asked.
            if (t.op == .join) {
                if (!valid) return error.InvalidExecution;
            } else if (actual != .boolean or actual.boolean != valid) return error.InvalidExecution;
        },
    }
}
/// The value of a text operation that reads a bounded number of units, worked out from its
/// operands. A slice is a view of its operand's bytes, not a copy of them.
fn replayTextValue(t: types.Text, result: types.Type, operands: [3]types.Value) Error!types.Value {
    switch (t.op) {
        .unit => {
            const text = operands[0].string;
            const position = operands[1].integer;
            if (position < 0 or position >= text.len) return error.InvalidExecution;
            return .{ .enumeration = .{ .value_type = types.Type.char, .index = text[@intCast(position)] } };
        },
        .boundary => return .{ .boolean = replayBoundary(operands[0].string, operands[1].integer) },
        .slice => {
            const text = operands[0].string;
            const start = operands[1].integer;
            const end = operands[2].integer;
            if (start < 0 or start > end or end > text.len) return error.InvalidExecution;
            if (start != end and (!replayBoundary(text, start) or !replayBoundary(text, end))) return error.InvalidExecution;
            // An empty slice is the empty view at the operand's start.
            const from: usize = if (start == end) 0 else @intCast(start);
            return .{ .string = text[from .. from + @as(usize, @intCast(end - start))] };
        },
        .scalar => {
            const text = operands[0].string;
            const position = operands[1].integer;
            if (position < 0 or position >= text.len or !replayBoundary(text, position)) return error.InvalidExecution;
            var scan: UnitScan = .{};
            for (text[@intCast(position)..]) |byte| {
                if (!scan.feed(byte)) return error.InvalidExecution;
                if (scan.need == 0) break;
            }
            if (scan.need != 0) return error.InvalidExecution;
            return .{ .enumeration = .{ .value_type = types.Type.char32, .index = scan.code } };
        },
        .code => return .{ .integer = operands[0].enumeration.index },
        .from_code => {
            const code = operands[0].integer;
            if (code < 0 or !types.validCharacter(result, @intCast(code))) return error.InvalidExecution;
            return .{ .enumeration = .{ .value_type = result, .index = @intCast(code) } };
        },
        .valid, .join => return error.InvalidExecution,
    }
}

/// The value a pure node has, worked out again from its operands with the reference
/// evaluator's own arithmetic (`evaluator.calculate` and its neighbours): no machine's record of
/// it is read. `registers` is what the node's operand indexes name: a frame's registers, or the
/// root's values. Null for a kind whose value this does not decide; its caller checks it in its
/// own way (RFC-0024, "Amendment: the replay works out every value"). An operation the machines
/// stop at (an overflow, a division by zero, an index out of range) has no report, so a step
/// that claims a value for it is invalid.
fn replayValue(execution: evaluator.Execution, node: types.Node, registers: []const types.Value, work: *u64, budget: u64) Error!?types.Value {
    @setFloatMode(.strict);
    const program = execution.program;
    const members = execution.aggregate_values;
    return switch (node.kind) {
        .integer => |value| .{ .integer = value },
        .boolean => |value| .{ .boolean = value },
        .floating => |value| .{ .floating = types.canonicalFloat(value) },
        .string => |span| if (span.start > span.end or span.end > program.strings.len) error.InvalidExecution else .{ .string = program.strings[span.start..span.end] },
        .negate => |operand| .{ .integer = try replayArithmetic(evaluator.calculate(.subtract, 0, try replayInteger(registers, operand))) },
        .binary => |b| .{ .integer = try replayArithmetic(evaluator.calculate(b.op, try replayInteger(registers, b.lhs), try replayInteger(registers, b.rhs))) },
        .float_negate => |operand| .{ .floating = types.canonicalFloat(-try replayFloat(registers, operand)) },
        .int_to_float => |operand| .{ .floating = @floatFromInt(try replayInteger(registers, operand)) },
        .float_to_int => |c| .{ .integer = try replayArithmetic(evaluator.referenceFloatToInt(c.mode, try replayFloat(registers, c.operand))) },
        .float_binary => |b| .{ .floating = evaluator.calculateFloat(b.op, try replayFloat(registers, b.lhs), try replayFloat(registers, b.rhs)) },
        .rational => |r| try replayArithmetic(evaluator.referenceRational(r, registers)),
        .logic_not => |operand| .{ .boolean = !try replayBoolean(registers, operand) },
        .logic_binary => |b| .{ .boolean = switch (b.op) {
            .both => try replayBoolean(registers, b.lhs) and try replayBoolean(registers, b.rhs),
            .either => try replayBoolean(registers, b.lhs) or try replayBoolean(registers, b.rhs),
        } },
        .compare => |c| compare: {
            const left = try replayOperand(registers, c.lhs);
            const right = try replayOperand(registers, c.rhs);
            if (std.meta.activeTag(left) != std.meta.activeTag(right) or left == .callable) return error.InvalidExecution;
            std.debug.assert(work.* <= budget);
            var remaining = budget - work.*;
            const holds = evaluator.referenceCompare(c.op, left, right, members, &key_work, &remaining) catch |err| return if (err == error.WorkLimit) error.ReportLimit else error.InvalidExecution;
            work.* = budget - remaining;
            break :compare .{ .boolean = holds };
        },
        .array_length => |operand| length: {
            const value = try replayAggregate(registers, operand, members.len);
            const shape = catalogue.definition(value.value_type, program.definitions) orelse return error.InvalidExecution;
            break :length .{ .integer = (value.elements.end - value.elements.start) / @as(u32, if (shape == .map) 2 else 1) };
        },
        .string_length => |operand| .{ .integer = @intCast((try replayString(registers, operand)).len) },
        .option_present => |operand| .{ .boolean = (try replayAggregate(registers, operand, members.len)).elements.start != (try replayAggregate(registers, operand, members.len)).elements.end },
        .option_or => |choice| choice: {
            const option = (try replayAggregate(registers, choice.option, members.len)).elements;
            break :choice if (option.start == option.end) try replayOperand(registers, choice.fallback) else members[option.start];
        },
        .option_value => |operand| option: {
            const option = (try replayAggregate(registers, operand, members.len)).elements;
            if (option.start == option.end) return error.InvalidExecution;
            break :option members[option.start];
        },
        .field, .tuple_element => |access| element: {
            const original = (try replayAggregate(registers, access.value, members.len)).elements;
            if (access.index >= original.end - original.start) return error.InvalidExecution;
            break :element members[original.start + access.index];
        },
        .array_get => |access| element: {
            const original = (try replayAggregate(registers, access.array, members.len)).elements;
            const position = try replayInteger(registers, access.index);
            if (position < 0 or position >= original.end - original.start) return error.InvalidExecution;
            break :element members[original.start + @as(u32, @intCast(position))];
        },
        .map_key, .map_value => |access| entry: {
            const original = (try replayAggregate(registers, access.array, members.len)).elements;
            const position = try replayInteger(registers, access.index);
            if (position < 0 or position >= (original.end - original.start) / 2) return error.InvalidExecution;
            break :entry members[original.start + 2 * @as(u32, @intCast(position)) + @intFromBool(node.kind == .map_value)];
        },
        .map_lookup => |lookup| found: {
            const original = (try replayAggregate(registers, lookup.map, members.len)).elements;
            if ((original.end - original.start) % 2 != 0) return error.InvalidExecution;
            const offset = try replayLookup(members, original, try replayOperand(registers, lookup.key), work, budget);
            const start: u32 = if (offset) |position| original.start + @as(u32, @intCast(position)) else original.end;
            break :found .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = start, .end = start + @intFromBool(offset != null) } } };
        },
        .text => |t| if (t.op.walks()) null else try replayTextValue(t, node.value_type, .{ try replayOperand(registers, t.a), try replayOperand(registers, if (t.op.arity() > 1) t.b else t.a), try replayOperand(registers, if (t.op.arity() > 2) t.c else t.a) }),
        else => null,
    };
}
fn replayArithmetic(result: anytype) Error!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch error.InvalidExecution;
}
fn replayOperand(registers: []const types.Value, index: u32) Error!types.Value {
    if (index >= registers.len) return error.InvalidExecution;
    return registers[index];
}
fn replayInteger(registers: []const types.Value, index: u32) Error!i64 {
    const value = try replayOperand(registers, index);
    return if (value == .integer) value.integer else error.InvalidExecution;
}
fn replayFloat(registers: []const types.Value, index: u32) Error!f64 {
    const value = try replayOperand(registers, index);
    return if (value == .floating and types.isCanonicalFloat(value.floating)) value.floating else error.InvalidExecution;
}
fn replayBoolean(registers: []const types.Value, index: u32) Error!bool {
    const value = try replayOperand(registers, index);
    return if (value == .boolean) value.boolean else error.InvalidExecution;
}
fn replayString(registers: []const types.Value, index: u32) Error![]const u8 {
    const value = try replayOperand(registers, index);
    return if (value == .string) value.string else error.InvalidExecution;
}
/// An aggregate operand whose members lie in a pool of `count`.
fn replayAggregate(registers: []const types.Value, index: u32, count: usize) Error!types.Aggregate {
    const value = try replayOperand(registers, index);
    if (value != .aggregate or value.aggregate.elements.start > value.aggregate.elements.end or value.aggregate.elements.end > count) return error.InvalidExecution;
    return value.aggregate;
}

/// Whether a pure node's recorded value `actual` is the one the replay works out: through
/// `replayValue`, or, for an operation that builds a string, by its bytes, which are compared
/// one charged unit per eight as the machines charge them. Where the bytes lie is the run's
/// layout of its pool, which the string pool's own checks follow. False for a kind that is no
/// pure node.
fn replayPure(execution: evaluator.Execution, node: types.Node, registers: []const types.Value, actual: types.Value, work: *u64, budget: u64) Error!bool {
    switch (node.kind) {
        .string_concat => |c| {
            const left = try replayString(registers, c.lhs);
            const right = try replayString(registers, c.rhs);
            if (actual != .string or actual.string.len != left.len + right.len) return error.InvalidExecution;
            try replayCharge(work, budget, run_strings.work(actual.string.len));
            if (!std.mem.eql(u8, actual.string[0..left.len], left) or !std.mem.eql(u8, actual.string[left.len..], right)) return error.InvalidExecution;
            return true;
        },
        .to_string => |operand| {
            const value = try replayOperand(registers, operand);
            switch (value) {
                .integer, .boolean, .floating => {},
                .enumeration => |character| if (!types.validCharacter(character.value_type, character.index)) return error.InvalidExecution,
                else => return error.InvalidExecution,
            }
            // What `run_strings.convert` writes, in a pool of the replay's own.
            var buffer: [400]u8 = undefined;
            var pool = run_strings.Pool.init(buffer[0..0], &buffer);
            var remaining: u64 = std.math.maxInt(u64);
            const text = run_strings.convert(&pool, value, &remaining) catch return error.InvalidExecution;
            if (actual != .string or !std.mem.eql(u8, actual.string, text)) return error.InvalidExecution;
            try replayCharge(work, budget, run_strings.work(text.len));
            return true;
        },
        else => {
            const expected = (try replayValue(execution, node, registers, work, budget)) orelse return false;
            if (!sameValue(actual, expected)) return error.InvalidExecution;
            return true;
        },
    }
}
fn replayCharge(work: *u64, budget: u64, amount: u64) error{ReportLimit}!void {
    if (amount > budget - work.*) return error.ReportLimit;
    work.* += amount;
}

/// A native that only computes (RFC-0042), run again by the replay, which learns its result
/// from the native itself as it does an effect's (`replayEffect`). It reads its arguments where
/// the run's pool holds them, which `Context.members` lends it, so the pool is only read and an
/// argument costs the replay what it costs the run: what the native's declared cost and its own
/// work count. Its result goes to the replay's scratch, with exactly the room the recorded
/// result takes, and its strings to a string pool of the replay's own. The result must be the
/// recorded one: a scalar equal to it, a string with its bytes, members equal to the recorded
/// ones in order. A string is compared by where it lies first, so a string a native moved is
/// never read.
fn replayNative(execution: evaluator.Execution, source: *SourceReplay, call: types.NativeCall, operands: []const types.Value, actual: types.Value, prefix: u32, work: *u64, budget: u64) Error!void {
    const entry = execution.program.natives[call.native];
    if (entry.effect != .none) return;
    const pool = execution.aggregate_values;
    if (call.count != entry.params.len) return error.InvalidExecution;
    var arguments: [native.max_parameters]types.Value = undefined;
    for (call.args[0..call.count], arguments[0..call.count]) |operand, *argument| argument.* = try replayOperand(operands, operand);
    const room: usize = if (actual == .aggregate) actual.aggregate.elements.end -| actual.aggregate.elements.start else 0;
    // The recorded result lies in the pool (`admit`), so the room is never more than it.
    if (room > pool.len) return error.InvalidExecution;
    if (room > source.native_members.len) {
        // Grown by halves at least, so a report borrows this a logarithmic number of times.
        const size = @max(room, source.native_members.len + source.native_members.len / 2, 1024);
        if (source.native_members.len != 0) scratch.free(source.native_members);
        source.native_members = scratch.alloc(types.Value, size) orelse {
            source.native_members = &.{};
            return error.InvalidExecution;
        };
    }
    if (source.native_strings.len == 0) source.native_strings = scratch.alloc(u8, types.limits.string_bytes) orelse return error.InvalidExecution;
    const out = source.native_members[0..room];
    var strings = run_strings.Pool.init(source.native_strings[0..0], source.native_strings);
    const cost = native.callCost(entry, arguments[0..call.count]);
    if (cost > budget - work.*) return error.ReportLimit;
    var context: native.Context = .{ .pool = out, .used = 0, .remaining = budget - work.* - cost, .strings = &strings, .work = &key_work, .members = pool, .host = entry.host };
    const outcome = entry.call(&context, arguments[0..call.count]);
    work.* = budget - context.remaining;
    switch (outcome) {
        // A native the machines ran to its end did not run out of the budget they gave it;
        // this one may run out of the report's.
        .fault => |fault| return if (fault == .work_limit) error.ReportLimit else error.InvalidExecution,
        .scalar => |value| {
            if (!native.outcomeMatches(entry.result, outcome) or !try replaySameContent(value, actual, work, budget)) return error.InvalidExecution;
        },
        .members => |span| {
            if (!native.outcomeMatches(entry.result, outcome) or actual != .aggregate or span.start != 0 or span.end != context.used) return error.InvalidExecution;
            const recorded = actual.aggregate.elements;
            if (recorded.start != prefix or recorded.end < recorded.start or recorded.end > pool.len or recorded.end - recorded.start != span.end) return error.InvalidExecution;
            for (out[0..span.end], pool[recorded.start..recorded.end]) |mine, theirs| {
                try charge(work, budget);
                if (!try replaySameContent(mine, theirs, work, budget)) return error.InvalidExecution;
            }
        },
    }
}
/// RFC-0087, P5.3: the replay's host of the JSON codec. Its instances are the replay's own. One
/// that a decode builds first holds the replay's own fields, and where the run laid its fields
/// out as members (`block`, `persist_json.decode`); once the decode has succeeded, the run's
/// fields must have the replay's content and are the ones kept (`replayJsonKeep`), so that what
/// later steps read of the instance is the run's. A decode that fails keeps no member of the
/// run's to compare with, and no instance.
const ReplayJson = struct {
    source: *SourceReplay,
    members: []const types.Value,
    work: *u64,
    budget: u64,
    problem: ?Error = null,

    pub fn field(self: *ReplayJson, object: types.ObjectRef, index: u32) error{Host}!types.Value {
        return self.source.objectRead(object, index) catch |err| {
            self.problem = err;
            return error.Host;
        };
    }
    pub fn instance(self: *ReplayJson, class: types.Type, cells: []const types.Value, block: u32) error{Host}!u32 {
        const source = self.source;
        if (source.json_blocks.len == 0) source.json_blocks = scratch.alloc(u32, types.limits.object_cells) orelse {
            self.problem = error.InvalidExecution;
            return error.Host;
        };
        const made = source.allocate(class, cells[1..]) catch |err| {
            self.problem = err;
            return error.Host;
        };
        source.json_blocks[made.id - source.count] = block;
        return made.id;
    }
    pub fn instanceMark(self: *ReplayJson) usize {
        return self.source.object_count;
    }
    pub fn instanceDrop(self: *ReplayJson, mark: usize) void {
        self.source.object_count = @intCast(mark);
    }
};

/// What the codec needs of the replay: its stack and string scratch, and, for a decode, room
/// for members numbered as the run's.
fn replayJsonRoom(source: *SourceReplay, decoding: bool) Error!*persist_json.Stack {
    if (source.json_stack == null) source.json_stack = scratch.storage(persist_json.Stack) catch return error.InvalidExecution;
    if (source.native_strings.len == 0) source.native_strings = scratch.alloc(u8, types.limits.string_bytes) orelse return error.InvalidExecution;
    if (decoding and source.json_members.len == 0) source.json_members = scratch.alloc(types.Value, types.limits.aggregate_elements) orelse return error.InvalidExecution;
    return source.json_stack.?;
}
fn replayJsonFault(err: persist_json.Error, host: *const ReplayJson) Error {
    return switch (err) {
        // The run's codec did not run out of the budget it had; the replay's may.
        error.WorkLimit => error.ReportLimit,
        error.Host => host.problem orelse error.InvalidExecution,
        else => error.InvalidExecution,
    };
}

/// RFC-0087, P5.3: a `json_encode` that yielded `actual`: the replay encodes `value`, of
/// `value_type`, again, reading instances from its own cells, and the text must be the run's.
fn replayJsonEncode(execution: evaluator.Execution, source: *SourceReplay, value_type: types.Type, value: types.Value, actual: types.Value, work: *u64, budget: u64) Error!void {
    if (actual != .string) return error.InvalidExecution;
    const stack = try replayJsonRoom(source, false);
    var strings = run_strings.Pool.init(source.native_strings[0..0], source.native_strings);
    var host: ReplayJson = .{ .source = source, .members = execution.aggregate_values, .work = work, .budget = budget };
    var remaining = budget - work.*;
    const text = persist_json.encode(persist_json.Catalogue.of(execution.program), &host, execution.aggregate_values, value_type, value, &strings, stack, &remaining) catch |err| {
        work.* = budget - remaining;
        return replayJsonFault(err, &host);
    };
    work.* = budget - remaining;
    if (text.len != actual.string.len) return error.InvalidExecution;
    try replayCharge(work, budget, run_strings.work(text.len));
    if (!std.mem.eql(u8, text, actual.string)) return error.InvalidExecution;
}

/// RFC-0087, P5.3: a `json_decode` that yielded `actual`, an option of `option_type`: the replay
/// decodes `text` again into members numbered as the run's, from `prefix`, and the run must
/// have built exactly those (strings by their bytes) and the instances the replay builds, the
/// next ones of its own, which take the run's fields. `prefix` moves past the members.
fn replayJsonDecode(execution: evaluator.Execution, source: *SourceReplay, option_type: types.Type, text: types.Value, actual: types.Value, prefix: *u32, work: *u64, budget: u64) Error!void {
    const members = execution.aggregate_values;
    if (text != .string or actual != .aggregate or actual.aggregate.value_type != option_type or prefix.* > members.len) return error.InvalidExecution;
    const stack = try replayJsonRoom(source, true);
    var strings = run_strings.Pool.init(source.native_strings[0..0], source.native_strings);
    var host: ReplayJson = .{ .source = source, .members = members, .work = work, .budget = budget };
    var count: usize = prefix.*;
    const made_from = source.object_count;
    var remaining = budget - work.*;
    const made = persist_json.decode(persist_json.Catalogue.of(execution.program), &host, .{ .slots = source.json_members, .count = &count }, option_type, text.string, &strings, stack, &key_work, &remaining) catch |err| {
        work.* = budget - remaining;
        return replayJsonFault(err, &host);
    };
    work.* = budget - remaining;
    if (host.problem) |problem| return problem;
    if (!std.meta.eql(made.aggregate.elements, actual.aggregate.elements) or count > members.len) return error.InvalidExecution;
    for (source.json_members[prefix.*..count], members[prefix.*..count]) |mine, theirs| {
        try charge(work, budget);
        if (!try replaySameContent(mine, theirs, work, budget)) return error.InvalidExecution;
    }
    if (made.aggregate.elements.start != made.aggregate.elements.end) try replayJsonKeep(execution, source, made_from, work, budget);
    prefix.* = @intCast(count);
}

/// The instances a decode that succeeded built, from cell `from` of the replay's own on: each
/// holds the replay's fields, which the run's, laid out as members from its block, must equal
/// in content, and which they then replace.
fn replayJsonKeep(execution: evaluator.Execution, source: *SourceReplay, from: u32, work: *u64, budget: u64) Error!void {
    const members = execution.aggregate_values;
    var at = from;
    while (at < source.object_count) {
        const header = source.objects[at] orelse return error.InvalidExecution;
        if (header != .integer or header.integer < 0 or header.integer > std.math.maxInt(u16)) return error.InvalidExecution;
        const class = catalogue.definition(@fromBackingInt(@as(u16, @intCast(header.integer))), execution.program.definitions) orelse return error.InvalidExecution;
        if (class != .class) return error.InvalidExecution;
        const count = class.class.fields.end - class.class.fields.start;
        const block = source.json_blocks[at];
        if (block > members.len or count > members.len - block or count > source.object_count - at - 1) return error.InvalidExecution;
        for (source.objects[at + 1 ..][0..count], members[block..][0..count]) |*cell, theirs| {
            try charge(work, budget);
            const mine = cell.* orelse return error.InvalidExecution;
            if (!try replaySameContent(mine, theirs, work, budget)) return error.InvalidExecution;
            cell.* = theirs;
        }
        at += count + 1;
    }
}

/// RFC-0087, P5.5 (S4): the loads of the persistent cell `cell`, declared by a `weak_init` that
/// yielded `actual`. For each key grant in order the replay takes the entry at the cursor, which
/// must ask for that `(cell, grant)` at tick 0; the present ones are decoded again, into members
/// numbered as the run's, each value waiting in the top of the pool as the run kept it, and the
/// run must have built exactly those and laid the entries' pairs out after them. Instances take
/// the run's fields as for `FromJson`. `prefix` moves past the members. The replay charges what
/// the run charged.
fn replayLoads(execution: evaluator.Execution, source: *SourceReplay, cell: u32, map_type: types.Type, actual: types.Value, prefix: *u32, work: *u64, budget: u64) Error!void {
    const program = execution.program;
    const members = execution.aggregate_values;
    const shape = catalogue.definition(map_type, program.definitions) orelse return error.InvalidExecution;
    if (shape != .weak_map or actual != .aggregate or actual.aggregate.value_type != map_type or prefix.* > members.len) return error.InvalidExecution;
    const record = source.inputs.record;
    const first = source.inputs.cursor;
    var asked: usize = 0;
    for (source.inputs.grants, 0..) |grant, index| {
        if (grant.kind != .key) continue;
        try charge(work, budget);
        _ = try source.inputs.next(.load, effects.loadRequest(cell, @intCast(index)), 0);
        asked += 1;
    }
    var present: u32 = 0;
    for (record.entries[first .. first + asked]) |entry| {
        // A load is the entry's text, or the end: never a reading.
        if (entry.bits != 0 or (entry.status == .end and entry.start != entry.end)) return error.InvalidExecution;
        present += @intFromBool(entry.status == .value);
    }
    const base = prefix.*;
    // The room the run had: its pool, which is `aggregate_elements` members; the report holds the
    // members it used.
    const capacity: usize = types.limits.aggregate_elements;
    if (base > members.len or members.len > capacity or present > capacity - base) return error.InvalidExecution;
    var count: usize = base;
    var pool_room: []types.Value = &.{};
    if (present != 0) {
        const stack = try replayJsonRoom(source, true);
        if (source.json_members.len < capacity) return error.InvalidExecution;
        pool_room = source.json_members[0..capacity];
        const room = pool_room[0 .. capacity - present];
        var strings = run_strings.Pool.init(source.native_strings[0..0], source.native_strings);
        var host: ReplayJson = .{ .source = source, .members = members, .work = work, .budget = budget };
        var waiting: u32 = 0;
        var ordinal: usize = 0;
        for (source.inputs.grants) |grant| {
            if (grant.kind != .key) continue;
            const entry = record.entries[first + ordinal];
            ordinal += 1;
            if (entry.status != .value) continue;
            const from = count;
            const made_from = source.object_count;
            var remaining = budget - work.*;
            const made = persist_json.decodeEntry(persist_json.Catalogue.of(program), &host, .{ .slots = room, .count = &count }, shape.weak_map.value, record.bytes[entry.start..entry.end], &strings, stack, &key_work, &remaining) catch |err| {
                work.* = budget - remaining;
                return replayJsonFault(err, &host);
            };
            work.* = budget - remaining;
            if (host.problem) |problem| return problem;
            // A text that did not decode ended the run: a report that holds this load is forged.
            const value = made orelse return error.InvalidExecution;
            if (count > members.len) return error.InvalidExecution;
            for (room[from..count], members[from..count]) |mine, theirs| {
                try charge(work, budget);
                if (!try replaySameContent(mine, theirs, work, budget)) return error.InvalidExecution;
            }
            try replayJsonKeep(execution, source, made_from, work, budget);
            pool_room[pool_room.len - 1 - waiting] = value;
            waiting += 1;
        }
    }
    if (2 * present > capacity - present - count or count + 2 * present > members.len) return error.InvalidExecution;
    const span: types.Span = .{ .start = @intCast(count), .end = @intCast(count + 2 * present) };
    if (!std.meta.eql(actual.aggregate.elements, span)) return error.InvalidExecution;
    try replayCharge(work, budget, 2 * present);
    var pair: u32 = 0;
    var ordinal: usize = 0;
    for (source.inputs.grants, 0..) |grant, index| {
        if (grant.kind != .key) continue;
        const entry = record.entries[first + ordinal];
        ordinal += 1;
        if (entry.status != .value) continue;
        const key = members[count + 2 * pair];
        if (key != .enumeration or key.enumeration.value_type != shape.weak_map.key or key.enumeration.index != index) return error.InvalidExecution;
        if (!try replaySameContent(pool_room[pool_room.len - 1 - pair], members[count + 2 * pair + 1], work, budget)) return error.InvalidExecution;
        pair += 1;
    }
    prefix.* = @intCast(count + 2 * present);
}

/// RFC-0087, P5.5 (S5): the store action a `weak_set` of the persistent cell `cell_id` prepared,
/// worked out from the replay's own value of the entry and the key's name, and folded into the
/// replay's effects on the store channel; a `full` run's listed action must be those bytes.
fn replayStoreAction(execution: evaluator.Execution, source: *SourceReplay, cell_id: u32, key: types.Value, value: types.Value, work: *u64, budget: u64) Error!void {
    const program = execution.program;
    if (cell_id >= program.source_cells.len) return error.InvalidExecution;
    const cell = program.source_cells[cell_id];
    if (cell.keyed != .persistent) return;
    const grants = source.inputs.grants;
    if (key != .enumeration or key.enumeration.index >= grants.len or grants[key.enumeration.index].kind != .key) return error.InvalidExecution;
    const entry = persistable.persistentValue(cell.value_type, program.definitions) orelse return error.InvalidExecution;
    const stack = try replayJsonRoom(source, false);
    var strings = run_strings.Pool.init(source.native_strings[0..0], source.native_strings);
    var host: ReplayJson = .{ .source = source, .members = execution.aggregate_values, .work = work, .budget = budget };
    var remaining = budget - work.*;
    const text = persist_json.encodeStoreAction(persist_json.Catalogue.of(program), &host, execution.aggregate_values, entry, value, cell.name, grants[key.enumeration.index].name, &strings, stack, &remaining) catch |err| {
        work.* = budget - remaining;
        return replayJsonFault(err, &host);
    };
    work.* = budget - remaining;
    EffectReplay.act(&source.effects, effects.store_channel, text) catch return error.InvalidExecution;
}

/// `sameValue`, except that two strings that lie apart are equal when their bytes are.
fn replaySameContent(a: types.Value, b: types.Value, work: *u64, budget: u64) Error!bool {
    if (a != .string or b != .string or sameValue(a, b)) return sameValue(a, b);
    if (a.string.len != b.string.len) return false;
    try replayCharge(work, budget, run_strings.work(a.string.len));
    return std.mem.eql(u8, a.string, b.string);
}

/// A frame of a root call that the run did not trace.
const ComputeVisit = struct { function: u32, base: u32, pc: u32 = 0, caller: ?u32, arguments: types.Span };
/// A root call of a function with no control, cell or local operation, itself or in what it
/// calls, leaves no step (RFC-0024): its body is straight-line pure code and calls of such
/// functions, so the replay runs it itself, node by node, one unit each, and yields what it
/// returns, which must be the call's recorded value. A constructor's members are the next
/// unused members of the pool and must hold its operands; a map's keys must be distinct, as
/// the machines require. The frames and registers are the replay's own scratch, which no traced
/// call holds between root nodes.
fn replayCompute(execution: evaluator.Execution, source: *SourceReplay, call: types.Call, prefix: *u32, work: *u64, budget: u64) Error!types.Value {
    const program = execution.program;
    const members = execution.aggregate_values;
    if (source.compute_frames.len == 0) source.compute_frames = scratch.alloc(ComputeVisit, types.limits.call_depth) orelse return error.InvalidExecution;
    if (source.compute_locals.len == 0) source.compute_locals = scratch.alloc(types.Value, types.limits.call_registers) orelse return error.InvalidExecution;
    const frames = source.compute_frames;
    const locals = source.compute_locals;
    const first = program.functions[call.function];
    if (first.body.end - first.body.start > locals.len) return error.InvalidExecution;
    frames[0] = .{ .function = call.function, .base = 0, .caller = null, .arguments = call.arguments };
    var depth: usize = 1;
    var used: u32 = first.body.end - first.body.start;
    while (true) {
        const frame = &frames[depth - 1];
        const f = program.functions[frame.function];
        if (frame.pc == f.body.end - f.body.start) {
            const result = locals[frame.base + f.root];
            used = frame.base;
            depth -= 1;
            if (depth == 0) return result;
            const caller = &frames[depth - 1];
            locals[caller.base + caller.pc] = result;
            caller.pc += 1;
            continue;
        }
        const entry = program.function_nodes[f.body.start + frame.pc];
        const node = entry.node;
        try charge(work, budget);
        const registers = locals[frame.base .. frame.base + frame.pc];
        const value: types.Value = switch (entry.input) {
            .parameter => |n| argument: {
                if (n >= frame.arguments.end - frame.arguments.start) return error.InvalidExecution;
                if (frame.caller) |base| break :argument locals[base + program.function_arguments[frame.arguments.start + n]];
                break :argument execution.values[program.call_arguments[frame.arguments.start + n]];
            },
            .global => |n| execution.values[program.globals[n].node],
            .operation => switch (node.kind) {
                .call => |c| {
                    const callee = program.functions[c.function];
                    const size = callee.body.end - callee.body.start;
                    if (depth == frames.len or size > locals.len - used) return error.InvalidExecution;
                    frames[depth] = .{ .function = c.function, .base = used, .caller = frame.base, .arguments = c.arguments };
                    used += size;
                    depth += 1;
                    continue;
                },
                .aggregate => |r| built: {
                    const count = r.end - r.start;
                    if (prefix.* > members.len or count > members.len - prefix.*) return error.InvalidExecution;
                    const span: types.Span = .{ .start = prefix.*, .end = prefix.* + count };
                    for (program.function_members[r.start..r.end], members[span.start..span.end]) |operand, actual| {
                        try charge(work, budget);
                        if (!sameValue(actual, try replayOperand(registers, operand))) return error.InvalidExecution;
                    }
                    prefix.* = span.end;
                    const built: types.Value = .{ .aggregate = .{ .value_type = node.value_type, .elements = span } };
                    try validateValue(execution, built, work, budget);
                    try validateMap(execution, built, work, budget);
                    break :built built;
                },
                .function_value => |id| .{ .callable = .{ .value_type = node.value_type, .function = id } },
                .self_value => .{ .callable = .{ .value_type = node.value_type, .function = frame.function } },
                .enumeration => |index| .{ .enumeration = .{ .value_type = node.value_type, .index = index } },
                .character => |code| if (types.validCharacter(node.value_type, code)) types.characterValue(node.value_type, code) else return error.InvalidExecution,
                .upcast => |n| widened(try replayOperand(registers, n), node.value_type),
                .downcast => |n| cast: {
                    const operand = try replayOperand(registers, n);
                    if (!castsTo(execution, operand, node.value_type)) return error.InvalidExecution;
                    break :cast widened(operand, node.value_type);
                },
                .instance_of => |c| .{ .boolean = castsTo(execution, try replayOperand(registers, c.value), c.class) },
                .refine => |n| refined: {
                    const operand = try replayOperand(registers, n);
                    if (catalogue.refinementOf(node.value_type, program.definitions)) |refinement| if (!boundsHold(refinement, operand)) return error.InvalidExecution;
                    break :refined operand;
                },
                .method_value => |m| method: {
                    const receiver = try replayOperand(registers, m.receiver);
                    if (receiver != .object) return error.InvalidExecution;
                    const function = catalogue.dispatchLookup(program.dispatch, receiver.object.value_type, m.slot) orelse return error.InvalidExecution;
                    break :method .{ .callable = .{ .value_type = node.value_type, .function = function } };
                },
                else => (try replayValue(execution, node, registers, work, budget)) orelse return error.InvalidExecution,
            },
        };
        locals[frame.base + frame.pc] = value;
        frame.pc += 1;
    }
}
fn replayBoundary(text: []const u8, position: i64) bool {
    if (position < 0 or position > text.len) return false;
    return position == text.len or boundary(@intCast(position), text);
}
/// UTF-8 read one byte at a time: the code point is accumulated and then checked against the
/// least value its length may encode, the surrogates and U+10FFFF, which is a third way of
/// saying what the machines say with a decoder and with second-byte ranges.
pub const UnitScan = struct {
    need: u8 = 0,
    code: u32 = 0,
    least: u32 = 0,

    pub fn feed(self: *UnitScan, byte: u8) bool {
        if (self.need == 0) {
            if (byte < 0x80) {
                self.code = byte;
                return true;
            }
            if (byte & 0xE0 == 0xC0) {
                self.* = .{ .need = 1, .code = byte & 0x1F, .least = 0x80 };
            } else if (byte & 0xF0 == 0xE0) {
                self.* = .{ .need = 2, .code = byte & 0x0F, .least = 0x800 };
            } else if (byte & 0xF8 == 0xF0) {
                self.* = .{ .need = 3, .code = byte & 0x07, .least = 0x10000 };
            } else return false;
            return true;
        }
        if (byte & 0xC0 != 0x80) return false;
        self.code = self.code << 6 | (byte & 0x3F);
        self.need -= 1;
        return self.need != 0 or (self.code >= self.least and types.validCharacter(types.Type.char32, self.code));
    }
};

/// What a `digest` run did when it reclaimed at the end of a frame or visit, worked out again
/// from the rule (`ControlStorage.reclaim_floor`) and not taken from the run: which members,
/// instances and string bytes above the frame's marks are still reachable from the handed-on
/// value `root`, from the cells that existed before the frame, from an instance a region holds
/// a record for and from the reasons of the failures seen, and where each goes when those slide
/// down to the marks. The pool of the second run, which that run is about to compact itself,
/// is only read. The replay's own values that can name something that moved are rewritten:
/// `root`, the cells, the instances it keeps and the reasons. Its instances and their records
/// move as the run's do. A pool or a value that breaks the rules values obey is invalid.
fn replayReclaim(execution: evaluator.Execution, source: *SourceReplay, prefix: *u32, visit: *const CallVisit, depth: usize, root: *types.Value) Error!void {
    const pool = execution.aggregate_values;
    const top = prefix.*;
    // RFC-0082, P3.5: a visit that saw another task run reclaims above the marks `replayMarks`
    // gives, and what every suspended visit holds is a root too. Only the marks are read from
    // the visit: `frame` holds them.
    const across = visit.switches != source.tasks.switches;
    const marked = try replayMarks(source, visit);
    const frame = &marked;
    const mark = frame.mark;
    const told: u64 = execution.program.strings.len;
    const cell_top: u32 = if (source.tracked) @intCast(source.count + source.object_count) else 0;
    if (mark > top or top > pool.len or top > types.limits.aggregate_elements or frame.cell_mark > cell_top or (source.tracked and frame.cell_mark < source.count)) return error.InvalidExecution;
    // The run sent its steps as it began to reclaim, so the pool it showed ends where the
    // strings of those steps end.
    if (frame.string_mark > source.string_used or source.string_used != told or told > types.limits.string_bytes) return error.InvalidExecution;
    // Every switch is made outside every region: none is open at the end of such a visit.
    if (across and (source.effects.depth != 0 or source.depth != 1 or source.undo_count != 0)) return error.InvalidExecution;
    if (across and source.links.len == 0) source.links = try replayLinks(execution.program);
    // A run that says it never reclaimed was checked on that understanding: see `validateSchedule`.
    if (source.reclaims == source.reclaims_claimed) return error.InvalidExecution;
    source.reclaims += 1;
    if (source.forward.len == 0) source.forward = scratch.alloc(u32, types.limits.aggregate_elements + 1) orelse return error.InvalidExecution;
    if (source.places.len == 0) source.places = scratch.alloc(u32, types.limits.object_cells + 1) orelse return error.InvalidExecution;
    if (source.pending.len == 0) source.pending = scratch.alloc(u32, types.limits.aggregate_elements + types.limits.object_cells + 2) orelse return error.InvalidExecution;
    const size = top - mark;
    const first_object: u32 = if (source.tracked) frame.cell_mark - @as(u32, @intCast(source.count)) else 0;
    var walk: ReplayWalk = .{
        .definitions = execution.program.definitions,
        .pool = pool,
        .mark = mark,
        .objects = if (source.tracked) source.objects[0..source.object_count] else &.{},
        .first = first_object,
        .base = @intCast(source.count),
        .slots = source.forward[0 .. size + 1],
        .places = source.places[0 .. source.object_count - first_object],
        .pending = source.pending,
    };
    // `slots[i]` is `i` until member `mark + i` is reached; `places` holds 1 at the first cell
    // of each instance above the mark until it is reached, then 2, and 0 elsewhere.
    for (walk.slots, 0..) |*slot, index| slot.* = @intCast(index);
    @memset(walk.places, 0);
    var at: u32 = first_object;
    while (at < source.object_count) {
        walk.places[at - first_object] = 1;
        at += try walk.instanceCells(at);
    }
    if (at != source.object_count) return error.InvalidExecution;
    try walk.reach(root.*);
    // The scheduler's values (RFC-0082): every live task's handle, every unstarted one's closure,
    // and from P3.2 a ready task's resume value, a waiting task's event or awaited handle, and
    // every signal held or committed.
    // From P3.3 an arm has no handle, and one that completed holds its result.
    if (source.tasks.on) for (source.tasks.tasks[0..source.tasks.taken]) |task| switch (task.state) {
        .unused => {},
        .held, .queued => {
            try walk.reach(task.handle);
            try walk.reach(task.closure);
        },
        .running => if (task.kind == .spawn) try walk.reach(task.handle),
        .ready => {
            if (task.kind == .spawn) try walk.reach(task.handle);
            try walk.reach(task.resume_value);
        },
        .waiting => {
            if (task.kind == .spawn) try walk.reach(task.handle);
            if (task.waits == .event or task.waits == .task) try walk.reach(task.target);
        },
        .settled => if (task.completed) try walk.reach(task.result),
    };
    // RFC-0084, P4.4: a reaction holds its handle, guard and body while it lives.
    if (source.tasks.on) for (source.tasks.tasks[0..source.tasks.taken]) |*task| if (task.state != .unused and replayReactive(task)) {
        try walk.reach(task.handle);
        try walk.reach(task.closure);
        try walk.reach(task.body);
    };
    if (source.tasks.on) {
        var held_at = source.tasks.held_from;
        while (held_at < source.tasks.held_to) : (held_at += 1) {
            const place = held_at % source.tasks.held.len;
            if (source.tasks.held[place] != replay_none) continue;
            try walk.reach(source.tasks.signals[place].event);
            try walk.reach(source.tasks.signals[place].value);
        }
    }
    // P3.5: the suspended visits' available registers, seeds and captures.
    if (across) {
        var held: ReplaySavedRoots = .{ .program = execution.program, .tasks = &source.tasks, .links = source.links };
        while (try held.next()) |value| try walk.reach(value.*);
        var visits: ReplaySavedVisits = .{ .tasks = &source.tasks };
        while (visits.next()) |saved| try walk.reachSpan(saved.visit.captures);
    }
    if (source.tracked) {
        for (source.cells[0..source.count]) |cell| if (cell) |value| try walk.reach(value);
        // RFC-0084: a cell's link reaches its record, and the record its guard.
        if (source.live.on) for (source.live.links[0..source.count]) |link| if (link != replay_none) try walk.reachInstance(link);
        for (source.objects[0..first_object]) |cell| if (cell) |value| try walk.reach(value);
        // So does the link of an instance cell below the mark (P4.2), and a record that reads a
        // cell below the mark stays, since a write of the cell would evaluate it (C24).
        if (source.live.on) {
            for (source.live.object_links[0..@min(first_object, source.live.object_links.len)]) |link| if (link != replay_none) try walk.reachInstance(link);
            for (source.live.entries[0..source.live.entry_count]) |entry| if (entry.on_list and entry.cell < frame.cell_mark and entry.record & watched == 0) try walk.reachInstance(entry.record);
        }
        // An instance a region holds a record for stays, with the record.
        var owner: u32 = first_object;
        for (source.holder[source.count + first_object ..][0..walk.places.len], first_object..) |holder, cell| {
            if (walk.places[cell - first_object] != 0) owner = @intCast(cell);
            if (holder != 0) try walk.reachInstance(walk.base + owner);
        }
    }
    while (walk.waiting != 0) {
        walk.waiting -= 1;
        const entry = walk.pending[walk.waiting];
        if (entry & ReplayWalk.instance == 0) {
            try walk.reach(pool[mark + entry]);
            continue;
        }
        const first = entry & ~ReplayWalk.instance;
        const count = try walk.instanceCells(first);
        for (walk.objects[first + 1 ..][0 .. count - 1]) |cell| try walk.reach(cell orelse return error.InvalidExecution);
        // A field's link reaches its record (RFC-0084, P4.2), and so does a record that reads
        // the field (C24).
        if (source.live.on) for (first + 1..first + count) |cell| {
            const link = source.live.objectLink(@intCast(cell));
            if (link != replay_none) try walk.reachInstance(link);
            const id = walk.base + cell;
            if (id >= source.live.known) continue;
            var reader_at = source.live.first[id];
            while (reader_at != replay_none) : (reader_at = source.live.entries[reader_at].later) {
                // A reaction is the scheduler's, which keeps it (P4.4).
                const reader = source.live.entries[reader_at].record;
                if (reader & watched == 0) try walk.reachInstance(reader);
            }
        };
    }
    // `slots` becomes the number of reachable members below each position; `places`, for each
    // cell of an instance that stays, one more than the number of cells that stay below it.
    var kept: u32 = 0;
    for (walk.slots[0..size], 0..) |*slot, index| {
        const reached = slot.* != index;
        slot.* = kept;
        kept += @intFromBool(reached);
    }
    walk.slots[size] = kept;
    // The rooms above the mark move with the arrays that keep them, or go with them.
    rooms.moved(mark, walk.slots);
    var kept_cells: u32 = 0;
    at = first_object;
    while (at < source.object_count) {
        const count = try walk.instanceCells(at);
        const reached = walk.places[at - first_object] == 2;
        for (walk.places[at - first_object ..][0..count]) |*place| {
            place.* = if (reached) kept_cells + 1 else 0;
            kept_cells += @intFromBool(reached);
        }
        at += count;
    }
    // The strings still named, as pairs of start and end, in order of their starts: a run of
    // bytes in use lasts while the next start lies inside the furthest end seen.
    const reasons = source.reasons[0..@min(source.reason_count, source.reasons.len)];
    var texts: ReplayTexts = .{ .origin = @intFromPtr(execution.program.strings.ptr), .mark = frame.string_mark, .top = @intCast(told) };
    if (texts.top != texts.mark) {
        // P3.5: with the suspended frames' registers, seeds and string marks, and the values
        // the scheduler holds: per task a resume value or a result, and per held signal a value.
        if (source.texts.len == 0) source.texts = scratch.alloc(u64, types.limits.aggregate_elements + types.limits.source_cells + types.limits.object_cells + types.limits.failure_traces + 2 + types.limits.saved_registers + 2 * types.limits.saved_frames + 2 * types.limits.tasks + types.limits.scheduler_actions) orelse return error.InvalidExecution;
        texts.spans = source.texts;
        try texts.note(root.*);
        if (source.tasks.on) for (source.tasks.tasks[0..source.tasks.taken]) |task| {
            if (task.state == .held or task.state == .queued) try texts.note(task.closure);
            if (task.state == .ready) try texts.note(task.resume_value);
            if (task.state == .settled and task.completed) try texts.note(task.result);
        };
        if (source.tasks.on) {
            var held_at = source.tasks.held_from;
            while (held_at < source.tasks.held_to) : (held_at += 1) {
                const place = held_at % source.tasks.held.len;
                if (source.tasks.held[place] == replay_none) try texts.note(source.tasks.signals[place].value);
            }
        }
        for (reasons) |reason| if (reason) |text| try texts.note(.{ .string = text });
        // P3.5: the suspended visits' values, and their string marks as empty strings.
        if (across) {
            var held: ReplaySavedRoots = .{ .program = execution.program, .tasks = &source.tasks, .links = source.links };
            while (try held.next()) |value| try texts.note(value.*);
            var visits: ReplaySavedVisits = .{ .tasks = &source.tasks };
            while (visits.next()) |saved| try texts.note(.{ .string = texts.at(saved.visit.string_mark) });
        }
        if (source.tracked) {
            for (source.cells[0..source.count]) |cell| if (cell) |value| try texts.note(value);
            for (source.objects[0..source.object_count], 0..) |cell, index| {
                if (index >= first_object and walk.places[index - first_object] == 0) continue;
                try texts.note(cell orelse return error.InvalidExecution);
            }
        }
        for (pool[mark..top], 0..) |member, index| {
            if (walk.slots[index + 1] != walk.slots[index]) try texts.note(member);
        }
        texts.settle();
    }
    // P3.5: the suspended visits' marks above these become what stays below their old places,
    // and their captures and values read as they will. Before the instances move: their headers
    // are read where they are.
    if (across) try replayRemapSaved(execution.program, source, &walk, &texts, frame, first_object);
    // The entries move or go first: which are valid is read from the cells where they are.
    if (source.live.on) try source.live.relocate(source, frame.cell_mark, walk.places);
    const live_measure = source.live.measure(source.depth);
    // Every value of the replay's own that is still in use reads as it will afterwards.
    const moves: ReplayMoves = .{ .slots = walk.slots, .mark = mark, .places = walk.places, .cell_mark = frame.cell_mark, .texts = &texts };
    root.* = moves.moved(root.*);
    if (source.tasks.on) for (source.tasks.tasks[0..source.tasks.taken]) |*task| if (task.state != .unused) {
        if (task.kind == .spawn or replayReactive(task)) task.handle = moves.moved(task.handle);
        if (task.state == .held or task.state == .queued or replayReactive(task)) task.closure = moves.moved(task.closure);
        if (replayReactive(task)) task.body = moves.moved(task.body);
        if (task.state == .ready) task.resume_value = moves.moved(task.resume_value);
        if (task.state == .waiting and (task.waits == .event or task.waits == .task)) task.target = moves.moved(task.target);
        if (task.state == .settled and task.completed) task.result = moves.moved(task.result);
    };
    if (source.tasks.on) {
        var held_at = source.tasks.held_from;
        while (held_at < source.tasks.held_to) : (held_at += 1) {
            const place = held_at % source.tasks.held.len;
            if (source.tasks.held[place] != replay_none) continue;
            source.tasks.signals[place].event = moves.moved(source.tasks.signals[place].event);
            source.tasks.signals[place].value = moves.moved(source.tasks.signals[place].value);
        }
    }
    for (reasons) |*reason| if (reason.*) |text| {
        reason.* = texts.moved(text);
    };
    if (source.tracked) {
        for (source.cells[0..source.count]) |*cell| if (cell.*) |value| {
            cell.* = moves.moved(value);
        };
        for (source.objects[0..first_object]) |*cell| if (cell.*) |value| {
            cell.* = moves.moved(value);
        };
        // RFC-0084, P4.2: the links of instance cells name records by their first cell.
        if (source.live.on) try source.live.moveObjectLinks(first_object, frame.cell_mark, walk.places);
        // The instances that stay close up, with the region that holds each cell.
        for (walk.places, first_object..) |place, cell| {
            if (place == 0) continue;
            const to = first_object + place - 1;
            source.objects[to] = moves.moved(source.objects[cell] orelse return error.InvalidExecution);
            source.holder[source.count + to] = source.holder[source.count + cell];
        }
        for (source.undo[0..source.undo_count]) |*record| {
            // A link an open region would restore names a record that stays: the region began
            // before the frame did, so did the record (P4.2).
            if (record.link != replay_none and record.link >= frame.cell_mark) return error.InvalidExecution;
            if (record.cell < frame.cell_mark) continue;
            const place = walk.places[record.cell - frame.cell_mark];
            if (place == 0) return error.InvalidExecution;
            record.cell = frame.cell_mark + place - 1;
        }
        // No region still open began after the frame did.
        for (source.marks[1..source.depth]) |began| if (began.objects > first_object) return error.InvalidExecution;
        source.object_count = first_object + kept_cells;
        if (source.live.on) for (source.live.links[0..source.count]) |*link| {
            if (link.* == replay_none or link.* < frame.cell_mark) continue;
            const place = walk.places[link.* - frame.cell_mark];
            if (place == 0) return error.InvalidExecution;
            link.* = frame.cell_mark + place - 1;
        };
    }
    // These positions hold other members from now on.
    if (mark < memo.cleared) @memset(memo.types[mark..@min(top, memo.cleared)], 0);
    const examined = (top - mark) + @as(u64, cell_top) + (told - frame.string_mark) / 8 + source.undo_count + live_measure + replayAcross(source, visit);
    prefix.* = mark + kept;
    source.string_used = texts.kept();
    source.reclaim_at = reclaimDue(source.reclaim_floor, prefix.*, examined);
    source.string_reclaim_at = replayDue(source.reclaim_floor, types.limits.string_bytes, types.limits.string_bytes, source.string_used, examined);
    const cells_kept: u64 = if (source.tracked) source.count + source.object_count else 0;
    source.object_reclaim_at = replayDue(source.reclaim_floor, types.limits.object_cells, (if (source.tracked) source.count else 0) + types.limits.object_cells, cells_kept, examined / 8);
    // A frame nearer the root does not wait for the floor, only for this work to be paid for.
    source.reclaim_depth = depth;
    source.reclaim_switches = source.tasks.switches;
    source.paid_members = prefix.* + examined / 8;
    source.paid_strings = source.string_used + examined;
    source.paid_cells = cells_kept + examined / 8;
    const own: u64 = if (source.tracked) @min(source.count, cells_kept) else 0;
    source.across_members = @min(source.paid_members, prefix.* + (types.limits.aggregate_elements -| prefix.*) / 2);
    source.across_strings = @min(source.paid_strings, source.string_used + (types.limits.string_bytes -| source.string_used) / 2);
    source.across_cells = @min(source.paid_cells, cells_kept + (types.limits.object_cells -| (cells_kept - own)) / 2);
}
/// The replay's own statement of when a run reclaims next: once the pool has grown by the
/// floor (or by half the room left, when that is less) beyond what survived, and by an eighth
/// of what the last reclamation examined.
fn reclaimDue(floor: u32, kept: u64, examined: u64) u64 {
    return replayDue(floor, types.limits.aggregate_elements, types.limits.aggregate_elements, kept, examined / 8);
}
/// The same for any of the three stores. The floor is stated in members and a store of another
/// size gets the same share of `scale`; `capacity` is what the store holds at most, `kept` what
/// it holds now and `wait` the least it must grow by.
fn replayDue(floor: u32, scale: u64, capacity: u64, kept: u64, wait: u64) u64 {
    if (floor == types.ControlStorage.reclaim_never) return std.math.maxInt(u64);
    const share = @as(u64, floor) * scale / types.limits.aggregate_elements;
    return kept + @max(@min(share, (capacity -| kept) / 2), wait);
}
/// Whether the frame that ends at this point of the replay reclaims: one of the three stores
/// has reached the size the run reclaims at next and holds something the frame built. A run
/// that has reclaimed before also does so in a frame nearer the root than the one that
/// reclaimed last, once a store has grown by the wait for that reclamation's work, and in the
/// frame of a call from the root as it returns, if that frame built anything at all. `depth`
/// counts the frames, the ending one included. A returning frame at depth 1 that saw a switch
/// since its push also waits for the last reclamation to be paid for, as in both machines
/// (`ControlStorage.reclaimReturn`, RFC-0085 I6-D3).
fn replayReclaims(source: *const SourceReplay, prefix: u32, visit: *const CallVisit, depth: usize, returning: bool) Error!bool {
    // RFC-0082, P3.5: after a switch, above the marks `replayMarks` gives.
    const marked = try replayMarks(source, visit);
    const frame = &marked;
    const cells: u64 = if (source.tracked) source.count + source.object_count else 0;
    const built_members = prefix > frame.mark;
    const built_strings = source.string_used > frame.string_mark;
    const built_cells = cells > frame.cell_mark;
    if (built_members and prefix >= source.reclaim_at) return true;
    if (built_strings and source.string_used >= source.string_reclaim_at) return true;
    if (built_cells and cells >= source.object_reclaim_at) return true;
    if (source.reclaims == 0) return false;
    const paid = (built_members and prefix >= source.paid_members) or (built_strings and source.string_used >= source.paid_strings) or (built_cells and cells >= source.paid_cells);
    if (returning and depth == 1 and (built_members or built_strings or built_cells)) {
        // Only when what the call left above its marks is an eighth of what would be examined.
        const built = (prefix - frame.mark) + (cells - frame.cell_mark) + (source.string_used - frame.string_mark) / 8;
        const examined = (prefix - frame.mark) + cells + (source.string_used - frame.string_mark) / 8 + source.undo_count + source.live.measure(source.depth) + replayAcross(source, visit);
        const across = visit.switches != source.tasks.switches and source.tasks.switches != source.reclaim_switches;
        const roomy = (built_members and prefix >= source.across_members) or (built_strings and source.string_used >= source.across_strings) or (built_cells and cells >= source.across_cells);
        if (built * 8 >= examined and (!across or roomy)) return true;
    }
    if (depth >= source.reclaim_depth) return false;
    return paid;
}
/// The three marks a visit's end reclaims above.
const ReplayMarks = struct { mark: u32, string_mark: u32, cell_mark: u32 };
/// RFC-0082, P3.5: the marks the end of `frame` reclaims above. A visit that saw no other task
/// run since its push keeps its own (the P3.1 rule). One that did reclaims above its own or the
/// stores' sizes when the root ended, whichever is more: nothing the root holds moves. The
/// string pool's size then is what the first slice after the root was told.
fn replayMarks(source: *const SourceReplay, frame: *const CallVisit) Error!ReplayMarks {
    const own: ReplayMarks = .{ .mark = frame.mark, .string_mark = frame.string_mark, .cell_mark = frame.cell_mark };
    if (frame.switches == source.tasks.switches or !source.root_ended) return own;
    const strings = source.root_strings orelse return error.InvalidExecution;
    return .{ .mark = @max(own.mark, source.root_members), .string_mark = @max(own.string_mark, strings), .cell_mark = @max(own.cell_mark, source.root_cells) };
}
/// What rooting the suspended visits adds to the measure of a reclamation by `frame`: nothing
/// without a switch, otherwise the saved visits and the registers and parameters they count.
fn replayAcross(source: *const SourceReplay, frame: *const CallVisit) u64 {
    const s = &source.tasks;
    if (frame.switches == s.switches) return 0;
    return @as(u64, s.saved_live) + s.values_live + s.parameters_live;
}
/// For each body node, the newest register before it that is available there: per level of
/// arms open, the newest register of that level. Opening an arm starts a level with the newest
/// of the level around it; the second arm starts again from there; a merge closes the level and
/// is the newest of the one around it. `replay_none` for none.
fn replayLinks(program: types.Program) Error![]u32 {
    const links = scratch.alloc(u32, @max(program.function_nodes.len, 1)) orelse return error.InvalidExecution;
    var newest: [types.limits.control_depth + 1]u32 = undefined;
    for (program.functions) |f| {
        var level: usize = 0;
        newest[0] = replay_none;
        for (program.function_nodes[f.body.start..f.body.end], f.body.start.., 0..) |entry, at, index| {
            switch (entry.node.kind) {
                .if_begin, .attempt_begin => {
                    links[at] = newest[level];
                    if (level == types.limits.control_depth) return error.InvalidExecution;
                    newest[level + 1] = newest[level];
                    level += 1;
                },
                .otherwise => {
                    if (level == 0) return error.InvalidExecution;
                    newest[level] = newest[level - 1];
                    links[at] = newest[level];
                },
                .merge => {
                    if (level == 0) return error.InvalidExecution;
                    level -= 1;
                    links[at] = newest[level];
                    newest[level] = @intCast(index);
                },
                else => {
                    links[at] = newest[level];
                    newest[level] = @intCast(index);
                },
            }
        }
        if (level != 0) return error.InvalidExecution;
    }
    return links;
}
/// Every visit of every suspended task, in the order their runs lie, with its task's registers.
const ReplaySavedVisits = struct {
    tasks: *SchedulerReplay,
    slot: ?u32 = null,
    at: u32 = 0,

    const Saved = struct { visit: *ReplaySaved, values: []types.Value };

    fn next(self: *ReplaySavedVisits) ?Saved {
        var slot = self.slot orelse self.tasks.oldest;
        while (slot != replay_none) {
            const task = &self.tasks.tasks[slot];
            if (self.at < task.visits) {
                self.slot = slot;
                self.at += 1;
                return .{ .visit = &self.tasks.saved[task.visit_at + self.at - 1], .values = self.tasks.values[task.local_at..][0..task.locals] };
            }
            slot = task.later;
            self.at = 0;
        }
        self.slot = replay_none;
        return null;
    }
};
/// The values the suspended visits hold, one after another: per visit, the seed of a loop's
/// visit, and its registers available at its node, the site or call it stands at. A visit
/// waiting at its end holds only its result, and one that ends cancelled nothing.
const ReplaySavedRoots = struct {
    program: types.Program,
    tasks: *SchedulerReplay,
    links: []const u32,
    visits: ReplaySavedVisits = undefined,
    started: bool = false,
    current: ?ReplaySavedVisits.Saved = null,
    seed: bool = false,
    register: u32 = replay_none,

    fn next(self: *ReplaySavedRoots) Error!?*types.Value {
        if (!self.started) {
            self.visits = .{ .tasks = self.tasks };
            self.started = true;
        }
        while (true) {
            if (self.current) |saved| {
                if (self.seed) {
                    self.seed = false;
                    return &saved.visit.seed;
                }
                if (self.register != replay_none) {
                    const register = self.register;
                    const f = self.program.functions[saved.visit.function];
                    if (saved.visit.base + register >= saved.values.len) return error.InvalidExecution;
                    self.register = if (saved.visit.pc == f.body.end - f.body.start) replay_none else self.links[f.body.start + register];
                    return &saved.values[saved.visit.base + register];
                }
            }
            const saved = self.visits.next() orelse return null;
            self.current = saved;
            self.seed = saved.visit.state_loop or saved.visit.remaining_visits != 0;
            const f = self.program.functions[saved.visit.function];
            const length = f.body.end - f.body.start;
            if (saved.visit.pc > length) return error.InvalidExecution;
            self.register = if (saved.visit.pc != length) self.links[f.body.start + saved.visit.pc] else if (saved.visit.canceled_end) replay_none else f.root;
        }
    }
};
/// After a reclamation that rooted the suspended visits: their marks above the reclaiming ones
/// become the number of what stays below each old place, in each store, and their captures and
/// values read as they will once everything has moved.
fn replayRemapSaved(program: types.Program, source: *SourceReplay, walk: *const ReplayWalk, texts: *const ReplayTexts, frame: *const ReplayMarks, first_object: u32) Error!void {
    const moves: ReplayMoves = .{ .slots = walk.slots, .mark = frame.mark, .places = walk.places, .cell_mark = frame.cell_mark, .texts = texts };
    var held: ReplaySavedRoots = .{ .program = program, .tasks = &source.tasks, .links = source.links };
    while (try held.next()) |value| value.* = moves.moved(value.*);
    // The cells that stay below each instance's first cell above the mark, and below the top,
    // in `pending`, which the walk no longer needs.
    const span: u32 = @intCast(walk.places.len);
    const below = source.pending[0 .. span + 1];
    var kept: u32 = 0;
    var at: u32 = 0;
    while (at < span) {
        const count = try walk.instanceCells(first_object + at);
        below[at] = kept;
        if (walk.places[at] != 0) kept += count;
        at += count;
    }
    below[span] = kept;
    var visits: ReplaySavedVisits = .{ .tasks = &source.tasks };
    while (visits.next()) |saved| {
        const visit = saved.visit;
        visit.captures = moves.span(visit.captures);
        if (visit.mark > frame.mark) {
            if (visit.mark - frame.mark >= walk.slots.len) return error.InvalidExecution;
            visit.mark = frame.mark + walk.slots[visit.mark - frame.mark];
        }
        if (visit.string_mark > frame.string_mark) visit.string_mark = @intCast(@intFromPtr(texts.moved(texts.at(visit.string_mark)).ptr) - texts.origin);
        if (visit.cell_mark > frame.cell_mark) {
            if (visit.cell_mark - frame.cell_mark > span) return error.InvalidExecution;
            visit.cell_mark = frame.cell_mark + below[visit.cell_mark - frame.cell_mark];
        }
    }
}
/// The walk that finds what a reclamation keeps. Members and instances still to be examined
/// wait on one stack; an instance is marked by the top bit.
const ReplayWalk = struct {
    definitions: []const types.Definition,
    pool: []const types.Value,
    mark: u32,
    objects: []const ?types.Value,
    /// The first instance cell above the frame's mark, and the number of the program's cells,
    /// which an instance's id counts as well.
    first: u32,
    base: u32,
    slots: []u32,
    places: []u32,
    pending: []u32,
    waiting: usize = 0,

    const instance: u32 = 1 << 31;

    fn instanceCells(self: *const ReplayWalk, first: u32) Error!u32 {
        if (first >= self.objects.len) return error.InvalidExecution;
        const header = self.objects[first] orelse return error.InvalidExecution;
        if (header != .integer or header.integer < 0 or header.integer > std.math.maxInt(u16)) return error.InvalidExecution;
        const count = catalogue.classCells(@fromBackingInt(@intCast(header.integer)), self.definitions) orelse return error.InvalidExecution;
        if (count > self.objects.len - first) return error.InvalidExecution;
        return count;
    }
    /// The first member at or above `from` not reached yet; the way there is shortened.
    fn unreached(self: *ReplayWalk, from: u32) u32 {
        var end = from;
        while (self.slots[end] != end) end = self.slots[end];
        var at = from;
        while (at != end) {
            const after = self.slots[at];
            self.slots[at] = end;
            at = after;
        }
        return end;
    }
    fn reach(self: *ReplayWalk, value: types.Value) Error!void {
        const named = switch (value) {
            .aggregate => |aggregate| aggregate.elements,
            .callable => |callable| callable.captures,
            .object => |object| return self.reachInstance(object.id),
            else => return,
        };
        return self.reachSpan(named);
    }
    fn reachSpan(self: *ReplayWalk, named: types.Span) Error!void {
        if (named.start == named.end or named.end <= self.mark) return;
        const limit: u32 = @intCast(self.slots.len - 1);
        if (named.start > named.end or named.end - self.mark > limit) return error.InvalidExecution;
        var at = self.unreached(named.start -| self.mark);
        while (at < named.end - self.mark) : (at = self.unreached(at + 1)) {
            self.slots[at] = at + 1;
            switch (self.pool[self.mark + at]) {
                .aggregate, .callable, .object => {
                    self.pending[self.waiting] = at;
                    self.waiting += 1;
                },
                else => {},
            }
        }
        // An array in use keeps the room that begins where it ends, as the machines keep it;
        // where the rooms are is the replay's own knowledge, not the pool's.
        if (rooms.after(named.end)) |room_limit| {
            if (room_limit - self.mark >= limit) return error.InvalidExecution;
            at = self.unreached(named.end - self.mark);
            while (at <= room_limit - self.mark) : (at = self.unreached(at + 1)) self.slots[at] = at + 1;
        }
    }
    fn reachInstance(self: *ReplayWalk, id: u32) Error!void {
        if (id < self.base + self.first) return;
        const offset = id - self.base - self.first;
        // A value in use names an instance by its first cell, and one that exists.
        if (offset >= self.places.len or self.places[offset] == 0) return error.InvalidExecution;
        if (self.places[offset] == 2) return;
        self.places[offset] = 2;
        self.pending[self.waiting] = (self.first + offset) | instance;
        self.waiting += 1;
    }
};
/// The strings a reclamation keeps, and where their bytes go.
const ReplayTexts = struct {
    origin: usize,
    mark: u32,
    top: u32,
    /// While strings are noted: start and end of each, the start in the upper half. After
    /// `settle`: per run of bytes in use, its start and how far down it moves.
    spans: []u64 = &.{},
    count: usize = 0,
    used: u32 = 0,

    /// A string that names a byte above the mark, or an empty one that stands above it: its
    /// offset in the pool.
    fn offsetOf(self: *const ReplayTexts, text: []const u8) Error!?u32 {
        const offset = @intFromPtr(text.ptr) -% self.origin;
        if (offset > self.top) return if (text.len == 0) null else error.InvalidExecution;
        if (text.len > self.top - offset) return error.InvalidExecution;
        if (offset + text.len <= self.mark) return null;
        return @intCast(offset);
    }
    fn note(self: *ReplayTexts, value: types.Value) Error!void {
        if (value != .string) return;
        const offset = (try self.offsetOf(value.string)) orelse return;
        if (self.count == self.spans.len) return error.InvalidExecution;
        // The bytes below the mark stay, so a string that began there counts from the mark.
        self.spans[self.count] = @as(u64, @max(offset, self.mark)) << 32 | (offset + value.string.len);
        self.count += 1;
    }
    fn settle(self: *ReplayTexts) void {
        std.mem.sort(u64, self.spans[0..self.count], {}, std.sort.asc(u64));
        var runs: usize = 0;
        var end: u32 = self.mark;
        var down: u32 = 0;
        for (self.spans[0..self.count]) |span| {
            const start: u32 = @intCast(span >> 32);
            const reaches: u32 = @truncate(span);
            if (runs == 0 or start > end) {
                // The bytes between the last run and this one go.
                down += start - end;
                self.spans[runs] = @as(u64, start) << 32 | down;
                runs += 1;
                end = start;
            }
            end = @max(end, reaches);
        }
        self.count = runs;
        self.used = end - down;
    }
    /// The bytes in use once the kept strings have closed up.
    fn kept(self: *const ReplayTexts) u32 {
        return if (self.top == self.mark) self.top else if (self.count == 0) self.mark else self.used;
    }
    /// The empty string at `offset` of the pool, which moves with its place.
    fn at(self: *const ReplayTexts, offset: u32) []const u8 {
        return @as([*]const u8, @ptrFromInt(self.origin + offset))[0..0];
    }
    fn moved(self: *const ReplayTexts, text: []const u8) []const u8 {
        if (self.top == self.mark or self.count == 0) return text;
        // Every string that comes here was noted, and so found to lie in the pool.
        const offset = (self.offsetOf(text) catch return text) orelse return text;
        if (offset <= self.mark) return text;
        // The last run that starts at or below the string.
        var low: usize = 0;
        var high: usize = self.count;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (@as(u32, @intCast(self.spans[middle] >> 32)) <= offset) low = middle else high = middle;
        }
        const down: u32 = @truncate(self.spans[low]);
        return @as([*]const u8, @ptrFromInt(self.origin + offset - down))[0..text.len];
    }
};
/// Rewrites one value by what a reclamation worked out.
const ReplayMoves = struct {
    slots: []const u32,
    mark: u32,
    places: []const u32,
    cell_mark: u32,
    texts: *const ReplayTexts,

    fn moved(self: ReplayMoves, value: types.Value) types.Value {
        return switch (value) {
            .aggregate => |aggregate| .{ .aggregate = .{ .value_type = aggregate.value_type, .elements = self.span(aggregate.elements) } },
            .callable => |callable| .{ .callable = .{ .value_type = callable.value_type, .function = callable.function, .captures = self.span(callable.captures) } },
            // A reference still in use names an instance that stays: the walk reached it.
            .object => |object| if (object.id < self.cell_mark or object.id - self.cell_mark >= self.places.len or self.places[object.id - self.cell_mark] == 0) value else .{ .object = .{ .value_type = object.value_type, .id = self.cell_mark + self.places[object.id - self.cell_mark] - 1 } },
            .string => |text| .{ .string = self.texts.moved(text) },
            else => value,
        };
    }
    fn span(self: ReplayMoves, named: types.Span) types.Span {
        // An end beyond the pool belongs to no value a run can hold; it is left to fail its checks.
        const limit = self.mark + @as(u32, @intCast(self.slots.len - 1));
        return .{
            .start = if (named.start <= self.mark or named.start > limit) named.start else self.mark + self.slots[named.start - self.mark],
            .end = if (named.end <= self.mark or named.end > limit) named.end else self.mark + self.slots[named.end - self.mark],
        };
    }
};

pub fn write(out: *std.Io.Writer, execution: evaluator.Execution, public_only: bool, limits: Limits) (Error || std.Io.Writer.Error)!Stats {
    const admitted = try validate(execution, public_only, limits);
    try writeObjectValidated(out, execution, public_only);
    try out.writeByte('\n');
    return admitted;
}

/// `write` for a run that kept only the digest of its witness; see `validateReplayed`.
pub fn writeReplayed(out: *std.Io.Writer, execution: evaluator.Execution, again: types.TraceProducer, public_only: bool, limits: Limits) (Error || std.Io.Writer.Error)!Stats {
    const admitted = try validateReplayed(execution, again, public_only, limits);
    try writeObjectValidated(out, execution, public_only);
    try out.writeByte('\n');
    return admitted;
}

/// Embed a values object after successful validate on these exact immutable
/// inputs. This is a consumption operation, not a reusable validation token.
/// Manual raw JSON avoids std.json's 256-level nesting assertion for a valid
/// 256-type schema plus enclosing protocol objects. Scalars retain FloatReport.
pub fn writeValidated(json: *std.json.Stringify, execution: evaluator.Execution, public_only: bool) std.Io.Writer.Error!void {
    try json.beginWriteRaw();
    try writeObjectValidated(json.writer, execution, public_only);
    json.endWriteRaw();
}

fn writeObjectValidated(out: *std.Io.Writer, execution: evaluator.Execution, public_only: bool) std.Io.Writer.Error!void {
    var work: u64 = 0;
    writeObject(out, execution, public_only, &work, std.math.maxInt(u64)) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        // The host has no memory for the instance ids: nothing can be written.
        error.ScratchUnavailable => return error.WriteFailed,
        error.ReportLimit, error.InvalidExecution => unreachable, // matching immutable validated traversal
    };
}

/// A value has the type it was computed as, except that an instance also has every superclass of its class.
fn conforms(execution: evaluator.Execution, value: types.Value, expected: types.Type) bool {
    // A rational does not carry its type: the catalogue has one such type or none.
    // RFC-0080: a place of type `any` holds a value of some other type as it is. `instance_of`
    // never asks for `any` (admission), so this only ever answers for a place.
    if (expected == types.Type.any) return true;
    if (value == .rational) return catalogue.isRational(expected, execution.program.definitions);
    // RFC-0083: a value of a refinement is a value of its base that lies within the bounds.
    if (catalogue.refinementOf(expected, execution.program.definitions)) |refinement| return boundsHold(refinement, value);
    const actual = valueType(value);
    // P3.7: a place of an interface holds the handle or the event itself.
    return actual == expected or (value == .object and (catalogue.subtype(actual, expected, execution.program.definitions) or catalogue.implements(actual, expected, execution.program.definitions)));
}
/// What `instance_of` answers: `conforms`, and a function is also of every function type that
/// allows more effects than its own (RFC-0081), which a place never needs because a function
/// value always carries the type of the node that produced it.
fn castsTo(execution: evaluator.Execution, value: types.Value, wanted: types.Type) bool {
    if (value == .callable and catalogue.widens(value.callable.value_type, wanted, execution.program.definitions, execution.program.tuple_elements)) return true;
    return conforms(execution, value, wanted);
}
/// Whether `value` is of a refinement's base and lies within its bounds. A NaN lies within none.
fn boundsHold(refinement: types.Refinement, value: types.Value) bool {
    switch (value) {
        .integer => |x| return refinement.base == .i64 and @as(i64, @bitCast(refinement.low)) <= x and x <= @as(i64, @bitCast(refinement.high)),
        .floating => |x| {
            if (refinement.base != .float) return false;
            const low: f64 = @bitCast(refinement.low);
            const high: f64 = @bitCast(refinement.high);
            return (if (refinement.low_open) low < x else low <= x) and (if (refinement.high_open) x < high else x <= high);
        },
        else => return false,
    }
}
fn valueType(value: types.Value) types.Type {
    return switch (value) {
        .integer => .i64,
        .floating => .float,
        .boolean => .logic,
        .string => .string,
        .aggregate => |aggregate| aggregate.value_type,
        .enumeration => |enumeration| enumeration.value_type,
        .callable => |value_ref| value_ref.value_type,
        .object => |object| object.value_type,
        .rational => unreachable, // `conforms` answers for a rational before asking.
    };
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > types.limits.identifier_bytes) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}
fn validString(value: []const u8, pool: []const u8) bool {
    // Difference arithmetic admits only references into the already validated
    // UTF-8 pool, without forming overflowing end pointers or rescanning aliases.
    const start = @intFromPtr(value.ptr);
    const base = @intFromPtr(pool.ptr);
    if (start < base or start - base > pool.len) return false;
    const offset = start - base;
    if (value.len > pool.len - offset) return false;
    return boundary(offset, pool) and boundary(offset + value.len, pool);
}
fn boundary(index: usize, pool: []const u8) bool {
    std.debug.assert(index <= pool.len);
    return index == pool.len or (pool[index] & 0xC0) != 0x80;
}
/// Aggregates are immutable and arrays grow by sharing a prefix, so the same start is
/// validated again and again as a longer array. `lengths[start]` elements of the aggregate
/// of type `types[start] - 1` that begins at `start` are already known to be well formed,
/// which keeps the checks linear in the pool instead of quadratic in loop iterations.
///
/// Only `types[0..cleared]` is in use. A replay that reads the pool of a second run forgets a
/// position whenever that run can have put another value there.
const Memo = struct { types: []u32 = &.{}, lengths: []u32 = &.{}, cleared: usize = 0 };
threadlocal var memo: Memo = .{};
/// The rooms the run being replayed has open (`array_concat.Rooms`); `admit` owns them.
threadlocal var rooms: array_concat.Rooms = .{};
/// What key walks of the replay in progress use beyond the native stack; `admit` owns it.
threadlocal var key_work: keys.Work = .{};
/// What `Stats.live_bytes` reports of the replay in progress.
threadlocal var live_peak: usize = 0;

fn validateValue(execution: evaluator.Execution, value: types.Value, work: *u64, budget: u64) Error!void {
    switch (value) {
        .callable => |value_ref| {
            const p = execution.program;
            const shape = catalogue.definition(value_ref.value_type, p.definitions) orelse return error.InvalidExecution;
            if (shape != .callable or value_ref.function >= p.functions.len) return error.InvalidExecution;
            const f = p.functions[value_ref.function];
            const parameters = catalogue.definition(shape.callable.parameters, p.definitions).?.tuple;
            const captured = value_ref.captures;
            if (captured.start > captured.end or captured.end > execution.aggregate_values.len) return error.InvalidExecution;
            const count = captured.end - captured.start;
            if (count > f.parameter_count or !catalogue.classBelow(f.value_type, shape.callable.result, p.definitions) or !f.effects().within(shape.callable.effects()) or parameters.end - parameters.start != f.parameter_count - count) return error.InvalidExecution;
            // The value's type may take a class below each parameter the function takes and
            // promise a class above what it returns (`catalogue.widens`).
            for (p.tuple_elements[parameters.start..parameters.end], f.parameters[count..f.parameter_count]) |required, actual| if (!catalogue.classBelow(required, actual, p.definitions)) return error.InvalidExecution;
            for (execution.aggregate_values[captured.start..captured.end], f.parameters[0..count]) |capture, required| {
                try charge(work, budget);
                if (!conforms(execution, capture, required)) return error.InvalidExecution;
                if (capture == .aggregate and capture.aggregate.elements.end > captured.start) return error.InvalidExecution;
                if (capture == .callable and capture.callable.captures.end > captured.start) return error.InvalidExecution;
            }
        },
        .integer, .boolean => {},
        // Lowest terms over a positive denominator is the only form a machine stores.
        .rational => |rational| if (!rational.normalised()) return error.InvalidExecution,
        .object => |object| {
            // A rolled-back region leaves references to the instances it built in the append-only
            // pool and in the call trace, so whether a reference is live is decided where it is
            // printed, and the replay decides whether it was ever correct.
            const shape = catalogue.definition(object.value_type, execution.program.definitions) orelse return error.InvalidExecution;
            // A live record (RFC-0084) is named by the `live_eval` steps and its own owner cell.
            if ((shape != .class and shape != .task and shape != .event and shape != .live and shape != .cancelable and shape != .ref) or object.id < execution.program.source_cells.len) return error.InvalidExecution;
        },
        .floating => |floating| if (!types.isCanonicalFloat(floating)) return error.InvalidExecution,
        .string => |string| if (!validString(string, execution.program.strings)) return error.InvalidExecution,
        // A character is a code of its type; anything else under this tag is a case of an enum.
        .enumeration => |enumeration| if (catalogue.grantKind(enumeration.value_type, execution.program.definitions)) |kind| {
            // RFC-0086, P2.3 (admission rule 3): a handle names a grant of its kind. RFC-0087,
            // P5.4: the session is no grant, and has index 0 whatever the grants are.
            const grants = execution.effects.grants;
            if (kind == .session) {
                if (enumeration.index != 0) return error.InvalidExecution;
            } else if (enumeration.index >= grants.len or grants[enumeration.index].kind != kind) return error.InvalidExecution;
        } else if (!types.validCharacter(enumeration.value_type, enumeration.index) and catalogue.caseAt(enumeration.value_type, enumeration.index, execution.program.definitions, execution.program.cases) == null) return error.InvalidExecution,
        .aggregate => |aggregate| {
            const elements = execution.elements(value) orelse return error.InvalidExecution;
            const definition = catalogue.definition(aggregate.value_type, execution.program.definitions) orelse return error.InvalidExecution;
            const key = aggregate.elements.start;
            const tag: u32 = @backingInt(aggregate.value_type) + 1;
            const remembered = key < memo.cleared and memo.types[key] == tag;
            const known: usize = if (remembered) @min(memo.lengths[key], elements.len) else 0;
            for (elements[known..], known..) |element, index| {
                try charge(work, budget);
                const expected = switch (definition) {
                    .array => |element_type| element_type,
                    .option => |element_type| element_type,
                    // RFC-0087, W1: a `weak_map`'s values are those of a map.
                    .map, .weak_map => |shape| if (index % 2 == 0) shape.key else shape.value,
                    .record => |record| execution.program.fields[record.fields.start + index].value_type,
                    .tuple => |span| execution.program.tuple_elements[span.start + index],
                    .enumeration, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant => return error.InvalidExecution,
                };
                if (!conforms(execution, element, expected)) return error.InvalidExecution;
                // An empty span owns no members, so its position is meaningless (and may follow a joined view).
                if (element == .aggregate and element.aggregate.elements.end != element.aggregate.elements.start and element.aggregate.elements.end > aggregate.elements.start) return error.InvalidExecution;
                if (element == .callable and element.callable.captures.end != element.callable.captures.start and element.callable.captures.end > aggregate.elements.start) return error.InvalidExecution;
            }
            if (key < memo.cleared and (!remembered or memo.lengths[key] < elements.len)) {
                memo.types[key] = tag;
                memo.lengths[key] = @intCast(elements.len);
            }
        },
    }
}
/// A map update copies the entries, replacing the value of an existing key or appending a new
/// pair, into the next unused members.
fn replayMapSet(execution: evaluator.Execution, original: types.Span, key: types.Value, value: types.Value, span: types.Span, prefix: *u32, work: *u64, budget: u64) Error!void {
    const pool = execution.aggregate_values;
    if (original.start > original.end or original.end > pool.len or (original.end - original.start) % 2 != 0) return error.InvalidExecution;
    const found = try replayLookup(pool, original, key, work, budget);
    const length = original.end - original.start;
    const total = length + if (found == null) @as(u32, 2) else 0;
    if (span.start != prefix.* or span.end - span.start != total or span.end > pool.len) return error.InvalidExecution;
    for (pool[span.start..span.end], 0..) |actual, offset| {
        try charge(work, budget);
        const expected = if (offset < length)
            (if (found != null and offset == found.?) value else pool[original.start + offset])
        else if (offset == length) key else value;
        if (!sameValue(actual, expected)) return error.InvalidExecution;
    }
    prefix.* = span.end;
}

/// A removal copies every entry but the one its operand views, in order, into the next unused
/// members. The operand is the present option of a lookup in that map; the machines reject any
/// other. Which entry a key names is the lookup's result, which the replay worked out again
/// where the lookup was made (`replayValue`).
fn replayMapRemove(execution: evaluator.Execution, original: types.Span, entry: types.Value, span: types.Span, prefix: *u32, work: *u64, budget: u64) Error!void {
    const pool = execution.aggregate_values;
    if (original.start > original.end or original.end > pool.len or (original.end - original.start) % 2 != 0) return error.InvalidExecution;
    if (entry != .aggregate) return error.InvalidExecution;
    const view = entry.aggregate.elements;
    if (view.start >= view.end or view.end - view.start != 1 or view.start < original.start or view.start >= original.end or (view.start - original.start) % 2 != 1) return error.InvalidExecution;
    const found = view.start - original.start;
    if (original.end - original.start < 2) return error.InvalidExecution;
    const kept = original.end - original.start - 2;
    if (span.start != prefix.* or span.end < span.start or span.end - span.start != kept or span.end > pool.len) return error.InvalidExecution;
    const removed = found - 1;
    for (pool[span.start..span.end], 0..) |actual, offset| {
        try charge(work, budget);
        const expected = pool[original.start + offset + @as(usize, if (offset < removed) 0 else 2)];
        if (!sameValue(actual, expected)) return error.InvalidExecution;
    }
    prefix.* = span.end;
}

/// Where the replay finds `key` in a map. The comparisons are charged to the report: a
/// structural key costs what it holds, not one unit.
fn replayLookup(pool: []const types.Value, original: types.Span, key: types.Value, work: *u64, budget: u64) Error!?usize {
    std.debug.assert(work.* <= budget);
    var remaining = budget - work.*;
    const found = keys.lookup(&key_work, pool, pool[original.start..original.end], key, &remaining) catch |err| return switch (err) {
        error.WorkLimit => error.ReportLimit,
        error.ScratchUnavailable => error.InvalidExecution, // As for the replay's other scratch.
    };
    work.* = budget - remaining;
    return found;
}

/// A join yields the span `array_concat.plan` chooses and every element equals the matching
/// operand element in order; only appended members move the unused prefix.
/// `context` is as for `array_concat.roomIn` (`array_concat.contextOf`).
fn replayConcat(execution: evaluator.Execution, left: types.Span, right: types.Span, span: types.Span, prefix: *u32, context: array_concat.Context, work: *u64, budget: u64) Error!void {
    const pool = execution.aggregate_values;
    if (left.start > left.end or left.end > pool.len or right.start > right.end or right.end > pool.len) return error.InvalidExecution;
    if (prefix.* > pool.len) return error.InvalidExecution;
    const joined = array_concat.plan(left, right, prefix.*, rooms.at(pool, left, right, prefix.*, context));
    if (!std.meta.eql(joined.span, span) or span.end > pool.len or joined.appended() > pool.len - prefix.*) return error.InvalidExecution;
    // Only copied members hold new values: an unchanged side or a view over neighbours is the
    // operand memory itself, and an array grown in place or into its room keeps its own prefix.
    const first = switch (joined.kind) {
        .left, .right, .adjacent => span.end,
        .extend, .room => left.end,
        .fresh => span.start,
    };
    for (pool[first..span.end], first - span.start..) |actual, offset| {
        try charge(work, budget);
        const expected = if (offset < left.end - left.start) pool[left.start + offset] else pool[right.start + offset - (left.end - left.start)];
        if (!sameValue(actual, expected)) return error.InvalidExecution;
    }
    if (!rooms.record(left, joined)) return error.InvalidExecution; // As for the replay's other scratch.
    prefix.* += joined.appended();
}

fn charge(work: *u64, budget: u64) error{ReportLimit}!void {
    if (work.* == budget) return error.ReportLimit;
    work.* += 1;
}

fn validateMap(execution: evaluator.Execution, value: types.Value, work: *u64, budget: u64) Error!void {
    if (value != .aggregate) return;
    const shape = catalogue.definition(value.aggregate.value_type, execution.program.definitions).?;
    if (shape != .map and shape != .weak_map) return;
    std.debug.assert(work.* <= budget);
    var remaining = budget - work.*;
    keys.unique(&key_work, execution.aggregate_values, execution.elements(value).?, &remaining) catch |err| return switch (err) {
        error.WorkLimit => error.ReportLimit,
        error.DuplicateKey, error.ScratchUnavailable => error.InvalidExecution,
    };
    work.* = budget - remaining;
}

/// `task` marks the result of a task handle printed in place (RFC-0082): its one member, then
/// the two braces that close the handle.
const Frame = struct { value: types.Aggregate, index: usize = 0, callable: bool = false, task: bool = false };
pub const value_traversal_bytes = @sizeOf([max_depth]Frame);

/// What the report knows of an instance cell while it decides which instances it lists. Any
/// smaller number is the id of a listed instance, stored at its first cell.
const reach_inside: u32 = std.math.maxInt(u32);
/// The first cell of an instance that nothing printed reaches.
const reach_unlisted: u32 = std.math.maxInt(u32) - 1;
/// The first cell of an instance that is reached and has no id yet.
const reach_marked: u32 = std.math.maxInt(u32) - 2;

/// What a report shows of a run (RFC-0063 "Reports"). A whole-program report shows every
/// binding and everything it reaches. A `public_only` report shows nothing the public API of
/// the program cannot reach: its public bindings; an instance as the nearest class, its own
/// or one above it, that another module can name, with those of that class's fields that
/// another module can read (`types.Field.hidden`), or as an entry of no class and no fields
/// when there is no such class; and a function value without its captures, which nothing
/// outside the function reads. A single file is public like the files of a bundle.
const View = struct {
    public_only: bool,
    /// For a `public_only` report: whether each type of the catalogue can be named outside the
    /// program (`create`).
    exposed: []bool = &.{},
    /// For a `public_only` report of a run with instances: for each type of the catalogue,
    /// the position of the class an instance of it is shown as, or `unshown`.
    shown_as: []u32 = &.{},

    const unshown = std.math.maxInt(u32);

    /// Which types another module can name is what admission weighs: in a program whose
    /// files declare modules (RFC-0074), a type whose reach is everywhere; otherwise an
    /// exportable one (`catalogue.exportableTypes`). A parent comes before its subclasses, so
    /// one pass in order finds the class every instance is shown as.
    fn create(execution: evaluator.Execution, public_only: bool) error{ScratchUnavailable}!View {
        if (!public_only) return .{ .public_only = false };
        const program = execution.program;
        const definitions = program.definitions;
        const exposed = scratch.alloc(bool, types.limits.user_types) orelse return error.ScratchUnavailable;
        errdefer scratch.free(exposed);
        if (program.nested.len == 0) {
            catalogue.exportableTypes(definitions, program.fields, program.tuple_elements, exposed[0..types.limits.user_types]);
        } else {
            const privacy = catalogue.Privacy.create(definitions, program.tuple_elements, program.modules, program.nested) orelse return error.ScratchUnavailable;
            defer privacy.destroy();
            for (definitions, 0..) |_, index| exposed[index] = privacy.reachesEverywhere(@fromBackingInt(@intCast(index + catalogue.builtin_count)));
        }
        if (execution.object_cells.len == 0) return .{ .public_only = true, .exposed = exposed };
        const shown_as = scratch.alloc(u32, definitions.len) orelse return error.ScratchUnavailable;
        for (definitions, shown_as, 0..) |item, *shown, index| {
            shown.* = unshown;
            if (item != .class) continue;
            if (exposed[index]) {
                shown.* = @intCast(index);
            } else if (item.class.parent) |parent| {
                const above = @backingInt(parent) - catalogue.builtin_count;
                std.debug.assert(above < index);
                shown.* = shown_as[above];
            }
        }
        return .{ .public_only = true, .exposed = exposed, .shown_as = shown_as };
    }
    fn destroy(self: View) void {
        if (self.shown_as.len != 0) scratch.free(self.shown_as);
        if (self.exposed.len != 0) scratch.free(self.exposed);
    }
    /// Whether a value of type `value_type` held in a place of type `place` is hidden. What
    /// a public binding holds, and what lies in its records, arrays, tuples, options and maps,
    /// another module reads through the binding without naming any type. A value held as
    /// `any` it reads back only by naming its type in a cast: when the public API cannot name
    /// it, a public report prints `{"$hidden":true}` and nothing inside it, as it lists an
    /// instance of such a class with no class and no field (`fix2`).
    fn hides(self: View, place: types.Type, value_type: types.Type) bool {
        if (!self.public_only or place != types.Type.any) return false;
        return !catalogue.exportable(value_type, self.exposed);
    }
    /// The class an instance of `class` is shown as; null when none is.
    fn classOf(self: View, class: types.Type) ?types.Type {
        if (!self.public_only) return class;
        const shown = self.shown_as[@backingInt(class) - catalogue.builtin_count];
        return if (shown == unshown) null else @fromBackingInt(@intCast(shown + catalogue.builtin_count));
    }
    fn shows(self: View, field: types.Field) bool {
        return !(self.public_only and field.hidden);
    }
    /// The fields an instance of `class` is shown with: a prefix of its cells, since a class
    /// holds its parent's fields first.
    fn fieldsOf(self: View, class: types.Type, program: types.Program) []const types.Field {
        const shown = self.classOf(class) orelse return &.{};
        const shape = catalogue.definition(shown, program.definitions).?.class;
        return program.fields[shape.fields.start..shape.fields.end];
    }
};

/// The type that the place `index` of an aggregate of type `container` declares.
fn placeType(program: types.Program, container: types.Type, index: usize) types.Type {
    return switch (catalogue.definition(container, program.definitions).?) {
        .array, .option => |element| element,
        .map, .weak_map => |shape| if (index % 2 == 0) shape.key else shape.value,
        .record => |record| program.fields[record.fields.start + index].value_type,
        .tuple => |span| program.tuple_elements[span.start + index],
        // Admitted aggregates are of these kinds only (`validateValue`).
        .enumeration, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant => types.Type.any,
    };
}

/// Decides which instances the report lists and under which ids, into `ids` (one entry per
/// instance cell). An instance is listed exactly when a printed binding reaches it: directly,
/// through aggregates and captures, or through the printed fields of a listed instance. So a
/// `public_only` report says nothing of an instance only private bindings hold, a full report
/// nothing of one the run dropped, and a run that reclaimed dropped instances reports what a
/// run that kept them does. Ids are what `src/tooling/response.zig` admits: the first listed
/// instance has id 0, and each next one the previous id plus one plus its printed fields,
/// in creation order.
///
/// The walk visits what `writeObject` then prints and nothing else, so it is bounded by the
/// same budget without adding to the work reported: `spent` is its own count, and exceeding
/// the budget here means the print would exceed it too.
fn reach(execution: evaluator.Execution, view: View, ids: []u32, queue: []u32, budget: u64) error{ ReportLimit, InvalidExecution }!void {
    const program = execution.program;
    const cells = execution.object_cells;
    std.debug.assert(ids.len == cells.len and queue.len == cells.len);
    if (cells.len == 0) return;
    @memset(ids, reach_inside);
    var at: usize = 0;
    while (at < cells.len) {
        const class: types.Type = @fromBackingInt(@intCast(cells[at].value.integer));
        ids[at] = reach_unlisted;
        at += catalogue.classCells(class, program.definitions).?;
    }
    var spent: u64 = 0;
    var pending: usize = 0;
    for (program.bindings) |binding| {
        if (view.public_only and !binding.is_public) continue;
        try markValue(execution, view, bindingValue(execution, binding), binding.value_type, ids, queue, &pending, &spent, budget);
    }
    // Each instance is queued once, when it is first reached, so the queue cannot overflow.
    while (pending != 0) {
        pending -= 1;
        const start = queue[pending];
        const class: types.Type = @fromBackingInt(@intCast(cells[start].value.integer));
        // RFC-0085, I1: a variable cell shows its one value.
        if (catalogue.refValue(class, program.definitions)) |held| {
            try markValue(execution, view, cells[start + catalogue.ref_value].value, held, ids, queue, &pending, &spent, budget);
            continue;
        }
        const fields = view.fieldsOf(class, program);
        for (cells[start + 1 ..][0..fields.len], fields) |cell, field| {
            if (!view.shows(field)) continue;
            try markValue(execution, view, cell.value, field.value_type, ids, queue, &pending, &spent, budget);
        }
    }
    var next: u32 = 0;
    // RFC-0085, I1: the listed variable cells are numbered 0, 1, 2 in creation order, apart
    // from the instances, so that `$objects` reads as it always did.
    var next_ref: u32 = 0;
    at = 0;
    while (at < cells.len) {
        const class: types.Type = @fromBackingInt(@intCast(cells[at].value.integer));
        const count = catalogue.classCells(class, program.definitions).?;
        if (ids[at] == reach_marked and catalogue.isRef(class, program.definitions)) {
            ids[at] = next_ref;
            next_ref += 1;
        } else if (ids[at] == reach_marked) {
            ids[at] = next;
            next += 1;
            for (view.fieldsOf(class, program)) |field| {
                if (view.shows(field)) next += 1;
            }
        }
        at += count;
    }
    std.debug.assert(next <= cells.len and next < reach_marked and next_ref <= cells.len);
}

/// Marks every instance `root` names, walking aggregates and captures as `writeValue` does.
fn markValue(execution: evaluator.Execution, view: View, root: types.Value, root_type: types.Type, ids: []u32, queue: []u32, pending: *usize, spent: *u64, budget: u64) error{ ReportLimit, InvalidExecution }!void {
    var stack: [max_depth]Frame = undefined;
    var depth: usize = 0;
    var next: ?types.Value = root;
    // The type the place of `next` declares, which a value held as `any` hides (`View.hides`).
    var next_type: types.Type = root_type;
    while (true) {
        if (next) |value| {
            try charge(spent, budget);
            next = null;
            switch (value) {
                .object => |object| {
                    // As where it is printed: a reference names a live instance by its first cell.
                    const cells = execution.objectCells(value) orelse return error.InvalidExecution;
                    if (catalogue.isTask(object.value_type, execution.program.definitions)) {
                        // A task handle is printed in place, with its result (RFC-0082).
                        if (depth == stack.len) return error.ReportLimit;
                        stack[depth] = .{ .value = cells[catalogue.task_result].value.aggregate };
                        depth += 1;
                        continue;
                    }
                    // An event is printed in place and reaches nothing (P3.2), and so is a
                    // subscription (P3.9).
                    if (catalogue.isEvent(object.value_type, execution.program.definitions)) continue;
                    if (catalogue.isCancelable(object.value_type, execution.program.definitions)) continue;
                    const at = object.id - execution.program.source_cells.len;
                    if (ids[at] == reach_inside) return error.InvalidExecution;
                    if (ids[at] == reach_unlisted) {
                        ids[at] = reach_marked;
                        queue[pending.*] = @intCast(at);
                        pending.* += 1;
                    }
                },
                .callable => |value_ref| if (!view.public_only and value_ref.captures.start != value_ref.captures.end) {
                    if (depth == stack.len) return error.ReportLimit;
                    stack[depth] = .{ .value = .{ .value_type = value_ref.value_type, .elements = value_ref.captures } };
                    depth += 1;
                },
                // What a public report prints as `null` reaches nothing (`View.names`).
                .aggregate => |aggregate| if (!view.hides(next_type, aggregate.value_type)) {
                    if (depth == stack.len) return error.ReportLimit;
                    stack[depth] = .{ .value = aggregate };
                    depth += 1;
                },
                .integer, .floating, .boolean, .string, .rational, .enumeration => {},
            }
        }
        if (depth == 0) break;
        const frame = &stack[depth - 1];
        if (frame.index == frame.value.elements.end - frame.value.elements.start) {
            depth -= 1;
            continue;
        }
        next = execution.aggregate_values[frame.value.elements.start + frame.index];
        next_type = if (frame.callable) types.Type.any else placeType(execution.program, frame.value.value_type, frame.index);
        frame.index += 1;
    }
}

fn writeObject(out: *std.Io.Writer, execution: evaluator.Execution, public_only: bool, work: *u64, budget: u64) (std.Io.Writer.Error || error{ ReportLimit, InvalidExecution, ScratchUnavailable })!void {
    // One id per instance cell and one queue slot per instance: sized by what the run made.
    const memory: ?[]u32 = if (execution.object_cells.len == 0) null else scratch.alloc(u32, 2 * execution.object_cells.len) orelse return error.ScratchUnavailable;
    defer if (memory) |slots| scratch.free(slots);
    const ids: []u32 = if (memory) |slots| slots[0..execution.object_cells.len] else &.{};
    const view = try View.create(execution, public_only);
    defer view.destroy();
    try reach(execution, view, ids, if (memory) |slots| slots[execution.object_cells.len..] else &.{}, budget);
    try out.writeByte('{');
    var first = true;
    for (execution.program.bindings) |binding| {
        if (public_only and !binding.is_public) continue;
        if (!first) try out.writeByte(',');
        first = false;
        try std.json.Stringify.value(binding.name.text(execution.program.source), .{}, out);
        try out.writeByte(':');
        try writeValue(out, execution, view, ids, bindingValue(execution, binding), binding.value_type, 0, work, budget);
    }
    // Instances reference each other (and themselves), so a value names one by its id and the
    // instances a printed value reaches are listed once here (`reach`).
    // `$objects` cannot clash with a binding: it is not an identifier.
    var listed = false;
    var at: usize = 0;
    while (at < execution.object_cells.len) {
        const class: types.Type = @fromBackingInt(@intCast(execution.object_cells[at].value.integer));
        const count = catalogue.classCells(class, execution.program.definitions).?;
        const start = at;
        at += count;
        if (ids[start] == reach_unlisted) continue;
        if (catalogue.isRef(class, execution.program.definitions)) continue;
        if (listed) try out.writeByte(',') else {
            if (!first) try out.writeByte(',');
            try out.writeAll("\"$objects\":[");
            listed = true;
        }
        try charge(work, budget);
        try out.print("{{\"id\":{d},\"class\":", .{ids[start]});
        // A public report names no class that the public API cannot name (`View`).
        const shown = view.classOf(class) orelse {
            try out.writeAll("null,\"fields\":{}}");
            continue;
        };
        const shape = catalogue.definition(shown, execution.program.definitions).?.class;
        try std.json.Stringify.value(shape.name.text(execution.program.source), .{}, out);
        if (shape.arguments) |arguments| {
            // An instance of `Box[i64]` is of class `Box` with the arguments `[0]`: type IDs,
            // as a specialized function lists them (RFC-0073).
            const list = catalogue.definition(arguments, execution.program.definitions).?.tuple;
            try out.writeAll(",\"arguments\":[");
            for (execution.program.tuple_elements[list.start..list.end], 0..) |argument, ordinal| {
                try charge(work, budget);
                if (ordinal != 0) try out.writeByte(',');
                try out.print("{d}", .{@backingInt(argument)});
            }
            try out.writeByte(']');
        }
        try out.writeAll(",\"fields\":{");
        var printed: usize = 0;
        const fields = execution.program.fields[shape.fields.start..shape.fields.end];
        std.debug.assert(fields.len <= count - 1);
        for (execution.object_cells[start + 1 ..][0..fields.len], fields) |cell, field| {
            // A hidden field never leaves its module (`types.Field.hidden`).
            if (!view.shows(field)) continue;
            if (printed != 0) try out.writeByte(',');
            printed += 1;
            try std.json.Stringify.value(field.name.text(execution.program.source), .{}, out);
            try out.writeByte(':');
            try writeValue(out, execution, view, ids, cell.value, field.value_type, 3, work, budget);
        }
        try out.writeAll("}}");
    }
    if (listed) try out.writeByte(']');
    // RFC-0085, I1: the variable cells printed values reach, by their ids, right after the
    // instances: `"$refs":[{"id":0,"value":V},...]`. No identifier is spelt so, and a report
    // that reaches no cell has no such member.
    var cells_listed = false;
    at = 0;
    while (at < execution.object_cells.len) {
        const class: types.Type = @fromBackingInt(@intCast(execution.object_cells[at].value.integer));
        const start = at;
        at += catalogue.classCells(class, execution.program.definitions).?;
        const held = catalogue.refValue(class, execution.program.definitions) orelse continue;
        if (ids[start] == reach_unlisted) continue;
        if (cells_listed) try out.writeByte(',') else {
            if (!first or listed) try out.writeByte(',');
            try out.writeAll("\"$refs\":[");
            cells_listed = true;
        }
        try charge(work, budget);
        try out.print("{{\"id\":{d},\"value\":", .{ids[start]});
        try writeValue(out, execution, view, ids, execution.object_cells[start + catalogue.ref_value].value, held, 2, work, budget);
        try out.writeByte('}');
    }
    if (cells_listed) {
        try out.writeByte(']');
        // What follows is separated from it as from the instances.
        listed = true;
    }
    // A program that spawns tasks reports what its scheduler did (RFC-0082). `$scheduler`, like
    // `$objects`, is no binding's name.
    if (replayTasks(execution.program)) {
        if (!first or listed) try out.writeByte(',');
        const record = execution.scheduler;
        try charge(work, budget);
        try out.print("\"$scheduler\":{{\"tick_rate\":{d},\"tick\":{d},\"created\":{d},\"completed\":{d},\"canceled\":{d},\"switches\":{d},\"waiting\":[", .{ record.tick_rate, record.tick, record.created, record.completed, record.canceled, record.switches });
        for (record.waiting, 0..) |entry, index| {
            try charge(work, budget);
            if (index != 0) try out.writeByte(',');
            try out.print("{{\"task\":{d},\"kind\":\"{t}\",\"wait\":\"{t}\",\"span\":[{d},{d}]}}", .{ entry.task, entry.kind, entry.wait, entry.span.start, entry.span.end });
        }
        try out.writeAll("]}");
    }
    // A run that read an input says how much it read (RFC-0086): after `$scheduler`, before
    // `$live`. A run that read none prints what it printed before.
    const inputs = execution.effects.inputs.len != 0;
    if (inputs) {
        if (!first or listed or replayTasks(execution.program)) try out.writeByte(',');
        try charge(work, budget);
        try out.print("\"$inputs\":{{\"count\":{d},\"bytes\":{d}}}", .{ execution.effects.inputs.len, execution.effects.input_bytes.len });
    }
    // A live program reports what its live variables did (RFC-0084), last.
    if (evaluator.live(execution.program)) {
        if (!first or listed or replayTasks(execution.program) or inputs) try out.writeByte(',');
        const record = execution.live;
        try charge(work, budget);
        try out.print("\"$live\":{{\"records\":{d},\"propagations\":{d},\"evaluations\":{d},\"entries\":{d},\"deliveries\":{d},\"firings\":{d}}}", .{ record.records, record.propagations, record.evaluations, record.entries, record.deliveries, record.firings });
    }
    try out.writeByte('}');
}

/// One value, expanded through its aggregates with an explicit stack. `wire_depth` counts the JSON
/// containers already open around it.
fn writeValue(out: *std.Io.Writer, execution: evaluator.Execution, view: View, ids: []const u32, root: types.Value, root_type: types.Type, open_containers: usize, work: *u64, budget: u64) (std.Io.Writer.Error || error{ ReportLimit, InvalidExecution })!void {
    var stack: [max_depth]Frame = undefined;
    var depth: usize = 0;
    // The worker envelope and values object reserve two wire containers.
    // A bound callable adds wrapper, body and capture array containers.
    var wire_depth: usize = open_containers;
    var next: ?types.Value = root;
    // The type the place of `next` declares, which a value held as `any` hides (`View.hides`).
    var next_type: types.Type = root_type;
    while (true) {
        if (next) |value| {
            try charge(work, budget);
            next = null;
            switch (value) {
                .integer => |integer| try std.json.Stringify.value(integer, .{}, out),
                .floating => |floating| try std.json.Stringify.value(types.FloatReport{ .value = floating }, .{}, out),
                .boolean => |boolean| try std.json.Stringify.value(boolean, .{}, out),
                .string => |string| try std.json.Stringify.value(string, .{}, out),
                .rational => |rational| {
                    // Numerator over denominator, exact: no JSON number holds a fraction.
                    if (wire_depth + 2 > types.limits.user_types) return error.ReportLimit;
                    try out.print("{{\"$rational\":[{d},{d}]}}", .{ rational.numerator, rational.denominator });
                },
                .object => |object| {
                    // A printed reference names a live instance of its class: its header cell holds that class.
                    const cells = execution.objectCells(value) orelse return error.InvalidExecution;
                    if (!cells[0].initialized or cells[0].value != .integer or cells[0].value.integer != @backingInt(object.value_type)) return error.InvalidExecution;
                    if (catalogue.isTask(object.value_type, execution.program.definitions)) {
                        // A task handle (RFC-0082): `{"$task":{"sequence":N,"state":S}}`, and the
                        // result of one that completed. It has no identity a program can compare,
                        // so it is printed in place and not listed with the instances.
                        if (wire_depth + 2 > types.limits.user_types) return error.ReportLimit;
                        const state = cells[catalogue.task_state].value.integer;
                        const name: []const u8 = switch (state) {
                            catalogue.task_active => "active",
                            catalogue.task_completed => "completed",
                            catalogue.task_canceled => "canceled",
                            else => return error.InvalidExecution,
                        };
                        try out.print("{{\"$task\":{{\"sequence\":{d},\"state\":\"{s}\"", .{ cells[catalogue.task_sequence].value.integer, name });
                        const result = cells[catalogue.task_result].value.aggregate;
                        if (state != catalogue.task_completed) {
                            try out.writeAll("}}");
                            continue;
                        }
                        if (result.elements.end - result.elements.start != 1) return error.InvalidExecution;
                        if (depth == stack.len) return error.ReportLimit;
                        try out.writeAll(",\"result\":");
                        stack[depth] = .{ .value = result, .task = true };
                        depth += 1;
                        wire_depth += 2;
                        continue;
                    }
                    if (catalogue.isEvent(object.value_type, execution.program.definitions)) {
                        // An event (P3.2), in place like a handle: `{"$event":{"waiting":K}}`.
                        if (wire_depth + 2 > types.limits.user_types) return error.ReportLimit;
                        try out.print("{{\"$event\":{{\"waiting\":{d}}}}}", .{cells[catalogue.event_waiting].value.integer});
                        continue;
                    }
                    if (catalogue.isCancelable(object.value_type, execution.program.definitions)) {
                        // A subscription (P3.9), in place like an event: `{"$cancelable":{"canceled":B}}`.
                        if (wire_depth + 2 > types.limits.user_types) return error.ReportLimit;
                        try out.print("{{\"$cancelable\":{{\"canceled\":{}}}}}", .{cells[catalogue.cancelable_state].value.integer == catalogue.cancelable_canceled});
                        continue;
                    }
                    if (catalogue.isRef(object.value_type, execution.program.definitions)) {
                        // RFC-0085, I1: a variable cell by the id its entry in `$refs` carries.
                        if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                        const id = ids[object.id - execution.program.source_cells.len];
                        if (id >= reach_marked) return error.InvalidExecution;
                        try out.print("{{\"$ref\":{d}}}", .{id});
                        continue;
                    }
                    if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                    // The id is the one its entry in `$objects` carries. Every printed reference was
                    // marked first, so one that names no listed instance points inside another.
                    const id = ids[object.id - execution.program.source_cells.len];
                    if (id >= reach_marked) return error.InvalidExecution;
                    try out.print("{{\"$object\":{d}}}", .{id});
                },
                .callable => |value_ref| if (view.hides(next_type, value_ref.value_type)) {
                    // A value of a type the public API cannot name (`View.names`).
                    if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                    try out.writeAll("{\"$hidden\":true}");
                } else {
                    const specialized = execution.program.functions[value_ref.function].specialization;
                    // A public report does not show what a function captured (`View`).
                    const captured = !view.public_only and value_ref.captures.start != value_ref.captures.end;
                    // The specialization array closes before captures begin;
                    // both arrays are siblings in the descriptor body.
                    const containers: usize = if (captured or specialized != null) 3 else 2;
                    if (containers > types.limits.user_types - wire_depth) return error.ReportLimit;
                    if (specialized) |key| {
                        const tuple = catalogue.definition(key, execution.program.definitions).?.tuple;
                        for (tuple.start..tuple.end) |_| try charge(work, budget);
                    }
                    try writeCallable(out, execution.program, value_ref, captured);
                    if (captured) {
                        if (depth == stack.len) return error.ReportLimit;
                        stack[depth] = .{ .value = .{ .value_type = value_ref.value_type, .elements = value_ref.captures }, .callable = true };
                        depth += 1;
                        wire_depth += containers;
                    }
                },
                .enumeration => |enumeration| if (view.hides(next_type, enumeration.value_type)) {
                    // A value of a type the public API cannot name (`View.names`).
                    if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                    try out.writeAll("{\"$hidden\":true}");
                } else if (enumeration.value_type.isCharacter()) {
                    // The code, under a key that is no field name: a `char` need not be text,
                    // and a number says the same for a code unit and for a code point.
                    if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                    try out.print("{{\"{s}\":{d}}}", .{ if (enumeration.value_type == types.Type.char) "$char" else "$char32", enumeration.index });
                } else if (catalogue.grantKind(enumeration.value_type, execution.program.definitions)) |kind| {
                    // RFC-0086 H7: a handle, `{"$reader":"NAME"}` or `{"$writer":"NAME"}`, under a
                    // key that is no field name. Admission checked that it names a grant.
                    if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                    // RFC-0087, P5.4 (K1): the session, `{"$session":0}`.
                    if (kind == .session) {
                        try out.writeAll("{\"$session\":0}");
                    } else {
                        // RFC-0087, P5.5 (K2): and a persistent key, `{"$key":"NAME"}`.
                        try out.writeAll(switch (kind) {
                            .writer => "{\"$writer\":",
                            .key => "{\"$key\":",
                            else => "{\"$reader\":",
                        });
                        try std.json.Stringify.value(execution.effects.grants[enumeration.index].name, .{}, out);
                        try out.writeByte('}');
                    }
                } else try writeEnum(out, execution.program, enumeration),
                .aggregate => |aggregate| if (view.hides(next_type, aggregate.value_type)) {
                    // A value of a type the public API cannot name (`View.names`).
                    if (wire_depth >= types.limits.user_types) return error.ReportLimit;
                    try out.writeAll("{\"$hidden\":true}");
                } else {
                    if (depth == stack.len or wire_depth == types.limits.user_types) return error.ReportLimit;
                    const definition = catalogue.definition(aggregate.value_type, execution.program.definitions).?;
                    try out.writeByte(if (definition == .record) '{' else '[');
                    stack[depth] = .{ .value = aggregate };
                    depth += 1;
                    wire_depth += 1;
                },
            }
        }
        if (depth == 0) break;
        const frame = &stack[depth - 1];
        const definition = catalogue.definition(frame.value.value_type, execution.program.definitions).?;
        const count = frame.value.elements.end - frame.value.elements.start;
        if (frame.index == count) {
            if (frame.task) try out.writeAll("}}") else if (frame.callable) try out.writeAll("]}}") else try out.writeByte(if (definition == .record) '}' else ']');
            wire_depth -= if (frame.callable) @as(usize, 3) else if (frame.task) @as(usize, 2) else 1;
            depth -= 1;
            continue;
        }
        if (frame.index != 0) try out.writeByte(',');
        if (!frame.callable and definition == .record) {
            const field = execution.program.fields[definition.record.fields.start + frame.index];
            try std.json.Stringify.value(field.name.text(execution.program.source), .{}, out);
            try out.writeByte(':');
        }
        next = execution.aggregate_values[frame.value.elements.start + frame.index];
        next_type = if (frame.callable) types.Type.any else placeType(execution.program, frame.value.value_type, frame.index);
        frame.index += 1;
    }
}

fn writeEnum(out: *std.Io.Writer, program: types.Program, value: types.EnumValue) std.Io.Writer.Error!void {
    // Both names were admitted as bounded ASCII identifiers by the complete
    // catalogue validation. Keep std.json escaping in the exact byte preflight.
    const enumeration = catalogue.definition(value.value_type, program.definitions).?.enumeration;
    const name = enumeration.name.text(program.source);
    const case = catalogue.caseAt(value.value_type, value.index, program.definitions, program.cases).?.text(program.source);
    var qualified: [types.limits.module_path_bytes + 2 + (types.limits.module_depth + 2) * (types.limits.identifier_bytes + 1)]u8 = undefined;
    std.debug.assert(name.len <= types.limits.identifier_bytes and case.len <= types.limits.identifier_bytes);
    var prefix: usize = 0;
    if (program.modules.len != 0) {
        const namespace = modules.owner(enumeration.name, program.modules).?;
        const path = program.modules[namespace].path.text(program.paths);
        @memcpy(qualified[0..path.len], path);
        @memcpy(qualified[path.len..][0..2], "::");
        prefix = path.len + 2;
        // An enum of a module declared inside the file is named through that module's path
        // (`file::Outer.Inner.name.case`), outermost first: admission bounds the nesting.
        var chain: [types.limits.module_depth]u32 = undefined;
        var depth: usize = 0;
        var inner: u32 = modules.innermost(enumeration.name, program.nested) orelse types.no_parent;
        while (inner != types.no_parent and depth < chain.len) : (inner = program.nested[inner].parent) {
            chain[depth] = inner;
            depth += 1;
        }
        while (depth != 0) {
            depth -= 1;
            const module = program.nested[chain[depth]].name.text(program.source);
            @memcpy(qualified[prefix..][0..module.len], module);
            qualified[prefix + module.len] = '.';
            prefix += module.len + 1;
        }
    }
    @memcpy(qualified[prefix..][0..name.len], name);
    qualified[prefix + name.len] = '.';
    @memcpy(qualified[prefix + name.len + 1 ..][0..case.len], case);
    try std.json.Stringify.value(qualified[0 .. prefix + name.len + 1 + case.len], .{}, out);
}

/// Exact bounded sink for report preflight. It retains no output bytes after
/// draining, and reports quota exhaustion through Writer.Error.WriteFailed.
pub const CountingWriter = struct {
    count: u64 = 0,
    limit: u64,
    writer: std.Io.Writer,
    pub fn init(buffer: []u8, limit: u64) CountingWriter {
        return .{ .limit = limit, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CountingWriter = @alignCast(@fieldParentPtr("writer", writer));
        const multiplied = @mulWithOverflow(data[data.len - 1].len, splat);
        if (multiplied[1] != 0) return error.WriteFailed;
        var written = multiplied[0];
        for (data[0 .. data.len - 1]) |bytes| {
            const added = @addWithOverflow(written, bytes.len);
            if (added[1] != 0) return error.WriteFailed;
            written = added[0];
        }
        const total = @addWithOverflow(@as(u64, writer.end), @as(u64, written));
        if (total[1] != 0 or total[0] > self.limit - self.count) return error.WriteFailed;
        self.count += total[0];
        writer.end = 0;
        return written;
    }
};

const sample_source = "Pair Left Right A B";
const sample_strings = "雪\n\"\x01\\";
const sample_definitions = [_]types.Definition{
    .{ .record = .{ .name = .{ .start = 0, .end = 4 }, .fields = .{ .start = 0, .end = 2 }, .is_public = false } },
    .{ .array = @fromBackingInt(@intCast(4)) },
};
const sample_fields = [_]types.Field{
    .{ .name = .{ .start = 5, .end = 9 }, .value_type = .float },
    .{ .name = .{ .start = 10, .end = 15 }, .value_type = .string },
};
const sample_nodes = [_]types.Node{
    .{ .span = .{ .start = 0, .end = 0 }, .value_type = .float, .kind = .{ .floating = std.math.inf(f64) } },
    .{ .span = .{ .start = 0, .end = 0 }, .value_type = .string, .kind = .{ .string = .{ .start = 0, .end = sample_strings.len } } },
    .{ .span = .{ .start = 0, .end = 0 }, .value_type = @fromBackingInt(@intCast(4)), .kind = .{ .aggregate = .{ .start = 0, .end = 2 } } },
    .{ .span = .{ .start = 0, .end = 0 }, .value_type = @fromBackingInt(@intCast(5)), .kind = .{ .aggregate = .{ .start = 2, .end = 4 } } },
};
const sample_bindings = [_]types.Binding{
    .{ .name = .{ .start = 16, .end = 17 }, .node = 3, .value_type = @fromBackingInt(@intCast(5)), .is_public = true },
    .{ .name = .{ .start = 18, .end = 19 }, .node = 3, .value_type = @fromBackingInt(@intCast(5)), .is_public = false },
};
const sample_record: types.Value = .{ .aggregate = .{ .value_type = @fromBackingInt(@intCast(4)), .elements = .{ .start = 0, .end = 2 } } };
const sample_values = [_]types.Value{
    .{ .floating = std.math.inf(f64) },                                                                       .{ .string = sample_strings }, sample_record,
    .{ .aggregate = .{ .value_type = @fromBackingInt(@intCast(5)), .elements = .{ .start = 2, .end = 4 } } },
};
const sample_elements = [_]types.Value{ sample_values[0], sample_values[1], sample_record, sample_record };
fn sampleExecution() evaluator.Execution {
    return .{ .program = .{
        .source = sample_source,
        .strings = sample_strings,
        .definitions = &sample_definitions,
        .fields = &sample_fields,
        .nodes = &sample_nodes,
        .members = &.{ 0, 1, 2, 2 },
        .bindings = &sample_bindings,
    }, .values = &sample_values, .aggregate_values = &sample_elements };
}

test "reports nested record aliases in declaration order and escapes strings" {
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const admitted = try write(&out, sampleExecution(), false, .{});
    try std.testing.expectEqual(out.end, admitted.output_bytes);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "{\"Left\":\"Inf\",\"Right\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "雪\\n\\\"\\u0001\\\\") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const a = parsed.value.object.get("A").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings(sample_strings, a[1].object.get("Right").?.string);
    try std.testing.expectEqualStrings("Inf", a[0].object.get("Left").?.string);
    try std.testing.expect(parsed.value.object.get("B") != null);
    out = std.Io.Writer.fixed(&buffer);
    _ = try write(&out, sampleExecution(), true, .{});
    const public = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer public.deinit();
    try std.testing.expectEqual(@as(usize, 1), public.value.object.count());
}

test "report quotas admit exact work and escaped bytes before any output" {
    const execution = sampleExecution();
    const admitted = try validate(execution, false, .{});
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    _ = try write(&out, execution, false, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    try std.testing.expectEqual(admitted.output_bytes, out.end);
    out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, write(&out, execution, false, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    try std.testing.expectError(error.ReportLimit, write(&out, execution, false, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    var failed: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, write(&failed, execution, false, .{}));
}

test "reports reject malformed private tails references names and types without output" {
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var registers = sample_values;
    var elements = sample_elements;
    var execution = sampleExecution();
    execution.values = &registers;
    execution.aggregate_values = &elements;
    registers[0] = .{ .floating = @bitCast(@as(u64, 0x7ff8000000000001)) };
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    registers = sample_values;
    elements[1] = .{ .string = sample_strings[1..2] };
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    elements = sample_elements;
    elements[3] = .{ .aggregate = .{ .value_type = @fromBackingInt(@intCast(4)), .elements = .{ .start = 2, .end = 4 } } };
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    elements = sample_elements;
    registers[2].aggregate.value_type = @fromBackingInt(@intCast(65535));
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    registers = sample_values;
    // Same element type and safe bounds are insufficient: a constructor must
    // retain its verified canonical member range, including array length.
    registers[3].aggregate.elements.end -= 1;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    registers = sample_values;
    var bindings = sample_bindings;
    bindings[1].name = bindings[0].name;
    execution.program.bindings = &bindings;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    bindings = sample_bindings;
    var nodes = sample_nodes;
    nodes[3].kind = .{ .aggregate = .{ .start = 2, .end = 5 } };
    execution.program.nodes = &nodes;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    // This valid IR tail belongs only to a private binding and is never reached
    // by the public output walk. Its malformed runtime value must still fail.
    const private_nodes = sample_nodes ++ [_]types.Node{.{ .span = .{ .start = 0, .end = 0 }, .value_type = .float, .kind = .{ .floating = 42 } }};
    const private_values = sample_values ++ [_]types.Value{.{ .floating = @bitCast(@as(u64, 0x7ff8000000000001)) }};
    const private_bindings = sample_bindings ++ [_]types.Binding{.{ .name = .{ .start = 20, .end = 21 }, .node = 4, .value_type = .float, .is_public = false }};
    execution = sampleExecution();
    execution.program.source = sample_source ++ " H";
    execution.program.nodes = &private_nodes;
    execution.program.bindings = &private_bindings;
    execution.values = &private_values;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    // Binding names have the same ASCII identifier contract as source names;
    // valid UTF-8/control text remains accepted only for string values.
    var bad_names = sample_bindings;
    bad_names[1].name = .{ .start = 20, .end = 23 };
    execution = sampleExecution();
    execution.program.source = sample_source ++ " 雪";
    execution.program.bindings = &bad_names;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    bad_names[1].name = .{ .start = 20, .end = 21 };
    execution.program.source = sample_source ++ " \r";
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "maximum acyclic schema depth fits iterative raw JSON even in an envelope" {
    try @import("profile.zig").requireBootstrap();
    var definitions: [types.limits.user_types]types.Definition = undefined;
    var nodes: [types.limits.user_types]types.Node = undefined;
    var registers: [types.limits.user_types]types.Value = undefined;
    var members: [types.limits.user_types - 1]u32 = undefined;
    var elements: [types.limits.user_types - 1]types.Value = undefined;
    for (0..types.limits.user_types) |index| {
        const value_type: types.Type = @fromBackingInt(@intCast(index + 4));
        definitions[index] = .{ .array = if (index == 0) .i64 else @fromBackingInt(@intCast(index + 3)) };
        const range: types.Span = .{ .start = @intCast(index -| 1), .end = @intCast(index) };
        nodes[index] = .{ .span = .{ .start = 0, .end = 0 }, .value_type = value_type, .kind = .{ .aggregate = range } };
        registers[index] = .{ .aggregate = .{ .value_type = value_type, .elements = range } };
        if (index != 0) {
            members[index - 1] = @intCast(index - 1);
            elements[index - 1] = registers[index - 1];
        }
    }
    const execution: evaluator.Execution = .{ .program = .{
        .source = "A",
        .strings = "",
        .nodes = &nodes,
        .definitions = &definitions,
        .members = &members,
        .bindings = &.{.{ .name = .{ .start = 0, .end = 1 }, .node = types.limits.user_types - 1, .value_type = @fromBackingInt(@intCast(types.limits.user_types + 3)), .is_public = true }},
    }, .values = &registers, .aggregate_values = &elements };
    _ = try validate(execution, true, .{});
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var json: std.json.Stringify = .{ .writer = &out };
    try json.beginObject();
    try json.objectField("values");
    try writeValidated(&json, execution, true);
    try json.endObject();
    try std.testing.expectEqualStrings("{\"values\":{\"A\":", out.buffered()[0..15]);
    try std.testing.expectEqual(@as(usize, 529), out.end);
}

test "small immutable alias DAG cannot amplify into an unbounded report" {
    const count = 24;
    var definitions: [count]types.Definition = undefined;
    var nodes: [count + 1]types.Node = undefined;
    var registers: [count + 1]types.Value = undefined;
    var members: [count * 2]u32 = undefined;
    var elements: [count * 2]types.Value = undefined;
    nodes[0] = .{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .integer = 7 } };
    registers[0] = .{ .integer = 7 };
    for (0..count) |index| {
        const value_type: types.Type = @fromBackingInt(@intCast(index + 4));
        definitions[index] = .{ .array = if (index == 0) .i64 else @fromBackingInt(@intCast(index + 3)) };
        const range: types.Span = .{ .start = @intCast(index * 2), .end = @intCast(index * 2 + 2) };
        nodes[index + 1] = .{ .span = .{ .start = 0, .end = 0 }, .value_type = value_type, .kind = .{ .aggregate = range } };
        registers[index + 1] = .{ .aggregate = .{ .value_type = value_type, .elements = range } };
        members[index * 2] = @intCast(index);
        members[index * 2 + 1] = @intCast(index);
        elements[index * 2] = registers[index];
        elements[index * 2 + 1] = registers[index];
    }
    const execution: evaluator.Execution = .{ .program = .{
        .source = "A",
        .strings = "",
        .nodes = &nodes,
        .definitions = &definitions,
        .members = &members,
        .bindings = &.{.{ .name = .{ .start = 0, .end = 1 }, .node = count, .value_type = @fromBackingInt(@intCast(count + 3)), .is_public = true }},
    }, .values = &registers, .aggregate_values = &elements };
    var buffer: [16]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    // The budget that stops it is the point, so it is stated rather than taken from the profile.
    try std.testing.expectError(error.ReportLimit, write(&out, execution, true, .{ .work = 65536 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "FloatReport remains unchanged for signed zero nonfinite and extreme finite values" {
    const numbers = [_]f64{ -0.0, -std.math.inf(f64), types.canonicalFloat(std.math.nan(f64)), std.math.floatMax(f64), std.math.floatTrueMin(f64) };
    var nodes: [numbers.len]types.Node = undefined;
    var values: [numbers.len]types.Value = undefined;
    var bindings: [numbers.len]types.Binding = undefined;
    const names = "ABCDE";
    for (numbers, 0..) |number, index| {
        nodes[index] = .{ .span = .{ .start = 0, .end = 0 }, .value_type = .float, .kind = .{ .floating = number } };
        values[index] = .{ .floating = number };
        bindings[index] = .{ .name = .{ .start = @intCast(index), .end = @intCast(index + 1) }, .node = @intCast(index), .value_type = .float, .is_public = true };
    }
    const execution: evaluator.Execution = .{ .program = .{ .source = names, .strings = "", .nodes = &nodes, .bindings = &bindings }, .values = &values };
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const admitted = try write(&out, execution, false, .{});
    var expected_buffer: [2048]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_buffer);
    var json: std.json.Stringify = .{ .writer = &expected };
    try json.beginObject();
    for (numbers, 0..) |number, index| {
        try json.objectField(names[index..][0..1]);
        try json.write(types.FloatReport{ .value = number });
    }
    try json.endObject();
    try expected.writeByte('\n');
    try std.testing.expectEqualStrings(expected.buffered(), out.buffered());
    try std.testing.expectEqual(admitted.output_bytes, out.end);
}

fn enumExecution() evaluator.Execution {
    const mode: types.Type = @fromBackingInt(@as(u16, 4));
    const other: types.Type = @fromBackingInt(@as(u16, 5));
    const modes: types.Type = @fromBackingInt(@as(u16, 6));
    const box: types.Type = @fromBackingInt(@as(u16, 7));
    const dark: types.Value = .{ .enumeration = .{ .value_type = mode, .index = 1 } };
    const light: types.Value = .{ .enumeration = .{ .value_type = mode, .index = 0 } };
    const array: types.Value = .{ .aggregate = .{ .value_type = modes, .elements = .{ .start = 0, .end = 2 } } };
    return .{ .program = .{
        .source = "mode Light Dark other Dark box Mode Allowed Empty A B H",
        .strings = "",
        .definitions = &.{
            .{ .enumeration = .{ .name = .{ .start = 0, .end = 4 }, .cases = .{ .start = 0, .end = 2 }, .is_public = true } },
            .{ .enumeration = .{ .name = .{ .start = 16, .end = 21 }, .cases = .{ .start = 2, .end = 3 }, .is_public = false } },
            .{ .array = mode },
            .{ .record = .{ .name = .{ .start = 27, .end = 30 }, .fields = .{ .start = 0, .end = 2 }, .is_public = true } },
            .{ .enumeration = .{ .name = .{ .start = 44, .end = 49 }, .cases = .{ .start = 3, .end = 3 }, .is_public = false } },
        },
        .cases = &.{ .{ .start = 5, .end = 10 }, .{ .start = 11, .end = 15 }, .{ .start = 22, .end = 26 } },
        .fields = &.{
            .{ .name = .{ .start = 31, .end = 35 }, .value_type = mode },
            .{ .name = .{ .start = 36, .end = 43 }, .value_type = modes },
        },
        .nodes = &.{
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = mode, .kind = .{ .enumeration = 1 } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = other, .kind = .{ .enumeration = 0 } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = mode, .kind = .{ .enumeration = 0 } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = modes, .kind = .{ .aggregate = .{ .start = 0, .end = 2 } } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = box, .kind = .{ .aggregate = .{ .start = 2, .end = 4 } } },
        },
        .members = &.{ 0, 2, 0, 3 },
        .bindings = &.{
            .{ .name = .{ .start = 50, .end = 51 }, .node = 4, .value_type = box, .is_public = true },
            .{ .name = .{ .start = 52, .end = 53 }, .node = 4, .value_type = box, .is_public = true },
            .{ .name = .{ .start = 54, .end = 55 }, .node = 1, .value_type = other, .is_public = false },
        },
    }, .values = &.{ dark, .{ .enumeration = .{ .value_type = other, .index = 0 } }, light, array, .{ .aggregate = .{ .value_type = box, .elements = .{ .start = 2, .end = 4 } } } }, .aggregate_values = &.{ dark, light, dark, array } };
}

test "enum reporting qualifies nominal cases in nested aliases with exact budgets" {
    const execution = enumExecution();
    const expected = "{\"A\":{\"Mode\":\"mode.Dark\",\"Allowed\":[\"mode.Dark\",\"mode.Light\"]},\"B\":{\"Mode\":\"mode.Dark\",\"Allowed\":[\"mode.Dark\",\"mode.Light\"]}}\n";
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const admitted = try write(&out, execution, true, .{});
    try std.testing.expectEqualStrings(expected, out.buffered());
    try std.testing.expectEqual(@as(u64, expected.len), admitted.output_bytes);
    // Prior descriptors/output plus five root schedule and four member copies; an aggregate
    // that two values share is checked once.
    try std.testing.expectEqual(@as(u64, 35), admitted.work);
    out = .fixed(&buffer);
    _ = try write(&out, execution, true, .{ .work = admitted.work, .output_bytes = admitted.output_bytes });
    try std.testing.expectEqualStrings(expected, out.buffered());
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, write(&out, execution, true, .{ .work = admitted.work - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    try std.testing.expectError(error.ReportLimit, write(&out, execution, true, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    _ = try write(&out, execution, false, .{});
    try std.testing.expect(std.mem.endsWith(u8, out.buffered(), ",\"H\":\"other.Dark\"}\n"));
    out = .fixed(buffer[0..8]);
    try std.testing.expectError(error.WriteFailed, write(&out, execution, true, .{}));
}

test "enum reporting rejects invalid concrete descriptors literals and unused catalogue tails before writing" {
    const original = enumExecution();
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    var values: [5]types.Value = undefined;
    @memcpy(&values, original.values);
    var execution = original;
    execution.values = &values;
    // This enum is reachable only through a private binding, yet still admitted.
    for ([_]types.EnumValue{
        .{ .value_type = @fromBackingInt(@as(u16, 5)), .index = 1 },
        .{ .value_type = @fromBackingInt(@as(u16, 4)), .index = 0 },
        .{ .value_type = @fromBackingInt(@as(u16, 7)), .index = 0 },
        .{ .value_type = .i64, .index = 0 },
        .{ .value_type = @fromBackingInt(@as(u16, 65535)), .index = 0 },
    }) |malformed| {
        values[1] = .{ .enumeration = malformed };
        try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    @memcpy(&values, original.values);
    values[0].enumeration.index = 0; // Valid case, inconsistent with the literal.
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    execution = original;
    var elements: [4]types.Value = undefined;
    @memcpy(&elements, original.aggregate_values);
    execution.aggregate_values = &elements;
    elements[0].enumeration.index = 2;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    elements[0] = original.values[1]; // Same case spelling but different nominal type.
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    execution = original;
    execution.program.cases = &.{ original.program.cases[0], original.program.cases[1], original.program.cases[2], original.program.cases[0] };
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    var cases: [3]types.Span = undefined;
    @memcpy(&cases, original.program.cases);
    execution = original;
    execution.program.cases = &cases;
    cases[2].end = 65535;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    cases[2] = .{ .start = 0, .end = 0 };
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    var definitions: [5]types.Definition = undefined;
    @memcpy(&definitions, original.program.definitions);
    execution = original;
    execution.program.definitions = &definitions;
    definitions[4].enumeration.name = .{ .start = 44, .end = 65535 };
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    // Empty enum declarations are valid; no value can inhabit one.
    @memcpy(&definitions, original.program.definitions);
    @memcpy(&values, original.values);
    const extra_node: types.Node = .{ .span = .{ .start = 0, .end = 0 }, .value_type = @fromBackingInt(@as(u16, 8)), .kind = .{ .enumeration = 0 } };
    const nodes = [_]types.Node{ original.program.nodes[0], original.program.nodes[1], original.program.nodes[2], original.program.nodes[3], original.program.nodes[4], extra_node };
    const all_values = [_]types.Value{ values[0], values[1], values[2], values[3], values[4], .{ .enumeration = .{ .value_type = @fromBackingInt(@as(u16, 8)), .index = 0 } } };
    execution.program.nodes = &nodes;
    execution.values = &all_values;
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "enum reporting maximum qualified identifier length fits fixed storage and exact escaping" {
    const length = types.limits.identifier_bytes;
    var source: [2 * length + 3]u8 = @splat('N');
    source[length] = ' ';
    @memset(source[length + 1 ..][0..length], 'C');
    source[2 * length + 1] = ' ';
    source[2 * length + 2] = 'A';
    const enum_type: types.Type = @fromBackingInt(@as(u16, 4));
    const execution: evaluator.Execution = .{ .program = .{
        .source = &source,
        .strings = "",
        .definitions = &.{.{ .enumeration = .{ .name = .{ .start = 0, .end = length }, .cases = .{ .start = 0, .end = 1 }, .is_public = true } }},
        .cases = &.{.{ .start = length + 1, .end = 2 * length + 1 }},
        .nodes = &.{.{ .span = .{ .start = 0, .end = 0 }, .value_type = enum_type, .kind = .{ .enumeration = 0 } }},
        .bindings = &.{.{ .name = .{ .start = 2 * length + 2, .end = source.len }, .node = 0, .value_type = enum_type, .is_public = true }},
    }, .values = &.{.{ .enumeration = .{ .value_type = enum_type, .index = 0 } }} };
    var buffer: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const admitted = try write(&out, execution, true, .{});
    try std.testing.expectEqual(@as(u64, 2 * length + 10), admitted.output_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const qualified = parsed.value.object.get("A").?.string;
    try std.testing.expectEqual(@as(usize, 2 * length + 1), qualified.len);
    try std.testing.expectEqual(@as(u8, '.'), qualified[length]);
    try std.testing.expectEqualSlices(u8, source[0..length], qualified[0..length]);
    try std.testing.expectEqualSlices(u8, source[length + 1 ..][0..length], qualified[length + 1 ..]);
    out = .fixed(&buffer);
    _ = try write(&out, execution, true, .{ .output_bytes = admitted.output_bytes });
    out = .fixed(&buffer);
    try std.testing.expectError(error.ReportLimit, write(&out, execution, true, .{ .output_bytes = admitted.output_bytes - 1 }));
    try std.testing.expectEqual(@as(usize, 0), out.end);
    // Escapes/control characters are supported in strings, never identifiers.
    for ([_]u8{ '"', '\n', '\t', '\\' }) |invalid| {
        source[length + 1] = invalid;
        try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
        try std.testing.expectEqual(@as(usize, 0), out.end);
    }
    source[length + 1] = 0xC3;
    source[length + 2] = 0xA9; // Valid UTF-8 é, outside the ASCII name contract.
    try std.testing.expect(std.unicode.utf8ValidateSlice(&source));
    try std.testing.expectError(error.InvalidExecution, write(&out, execution, true, .{}));
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

fn sameValue(a: types.Value, b: types.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .integer => |x| x == b.integer,
        .boolean => |x| x == b.boolean,
        .floating => |x| @as(u64, @bitCast(x)) == @as(u64, @bitCast(b.floating)),
        .string => |x| x.ptr == b.string.ptr and x.len == b.string.len,
        .aggregate => |x| std.meta.eql(x, b.aggregate),
        .enumeration => |x| std.meta.eql(x, b.enumeration),
        .callable => |x| std.meta.eql(x, b.callable),
        .object => |x| std.meta.eql(x, b.object),
        .rational => |x| std.meta.eql(x, b.rational),
    };
}
/// What an upcast makes of its operand: the same instance, or the same function carrying the
/// type that allows more effects (RFC-0078).
fn widened(value: types.Value, value_type: types.Type) types.Value {
    // A function held as `any` keeps its own type (RFC-0080).
    if (value_type == types.Type.any) return value;
    // RFC-0087, W3: a map made a `weak_map` is an aggregate of the new type.
    if (value == .aggregate) return .{ .aggregate = .{ .value_type = value_type, .elements = value.aggregate.elements } };
    if (value != .callable) return value;
    return .{ .callable = .{ .value_type = value_type, .function = value.callable.function, .captures = value.callable.captures } };
}
fn nodeBranch(node: types.Node) types.Branch {
    return if (node.kind == .if_begin) node.kind.if_begin else node.kind.attempt_begin;
}
// Reconstruct the root/callee schedule with bounded counted repetition from admitted structured IR and concrete
// predicates, rather than trusting a caller-provided mask or a truncated trace.
fn validateSchedule(execution: evaluator.Execution, producer: ?types.TraceProducer, work: *u64, budget: u64) Error!void {
    const program = execution.program;
    const has_source = replaySource(program);
    const expected = scratch.alloc(bool, program.nodes.len) orelse return error.InvalidExecution;
    defer scratch.free(expected);
    @memset(expected, false);
    var catchers: [types.limits.control_depth]u32 = undefined;
    var source: SourceReplay = .{};
    source.count = program.source_cells.len;
    source.depth = 1; // Implicit root source region.
    source.images = scratch.alloc(?types.Value, types.limits.source_frames * source.count) orelse return error.InvalidExecution;
    defer scratch.free(source.images);
    defer {
        if (source.trace_frames.len != 0) scratch.free(source.trace_frames);
        if (source.trace_locals.len != 0) scratch.free(source.trace_locals);
    }
    if (replayObjects(program)) source.objects = scratch.alloc(?types.Value, types.limits.object_cells) orelse return error.InvalidExecution;
    defer if (source.objects.len != 0) scratch.free(source.objects);
    defer if (source.undo.len != 0) scratch.free(source.undo);
    defer if (source.forward.len != 0) scratch.free(source.forward);
    defer if (source.places.len != 0) scratch.free(source.places);
    defer if (source.pending.len != 0) scratch.free(source.pending);
    defer if (source.texts.len != 0) scratch.free(source.texts);
    defer if (source.links.len != 0) scratch.free(source.links);
    defer if (source.effects.marks.len != 0) scratch.free(source.effects.marks);
    defer if (source.native_members.len != 0) scratch.free(source.native_members);
    defer if (source.native_strings.len != 0) scratch.free(source.native_strings);
    defer if (source.json_members.len != 0) scratch.free(source.json_members);
    defer if (source.json_stack) |stack| scratch.release(stack);
    defer if (source.json_blocks.len != 0) scratch.free(source.json_blocks);
    defer if (source.compute_frames.len != 0) scratch.free(source.compute_frames);
    defer if (source.compute_locals.len != 0) scratch.free(source.compute_locals);
    defer source.tasks.close();
    if (replayScheduled(program)) try source.tasks.open(execution.scheduler.tick_rate);
    source.definitions = program.definitions;
    defer source.live.close();
    if (evaluator.live(program)) try source.live.open(program, source.count);
    // The run's draws came from the stream its seed names; the replay reads that stream itself.
    source.effects.stream = .{ .seed = execution.effects.seed };
    // What the world gave the run is read from its record, never from the world (RFC-0086).
    source.inputs.record = execution.effects.inputRecord();
    // RFC-0086, P2.3: and what it was granted, a run parameter its record carries: a list a host
    // may give, checked before anything is replayed against it (H1).
    if (!effects.validGrants(execution.effects.grants)) return error.InvalidExecution;
    source.inputs.grants = execution.effects.grants;
    source.effects.grants = execution.effects.grants;
    // A `full` run's listed actions are compared with the replay's as they are prepared.
    if (execution.trace == .full) source.effects.listed = execution.effects;
    source.tracked = has_source;
    // Only a run that stored no steps reclaims; a replay of stored steps reads the final pool.
    if (producer != null and execution.trace == .digest) {
        source.reclaim_floor = execution.reclaim_floor;
        source.reclaim_at = reclaimDue(source.reclaim_floor, 0, 0);
        source.string_reclaim_at = replayDue(source.reclaim_floor, types.limits.string_bytes, types.limits.string_bytes, 0, 0);
        const own: u64 = if (has_source) source.count else 0;
        source.object_reclaim_at = replayDue(source.reclaim_floor, types.limits.object_cells, own + types.limits.object_cells, own, 0);
        source.reclaims_claimed = execution.reclaims;
        source.streaming = true;
    } else if (execution.reclaims != 0) return error.InvalidExecution;
    source.holder = scratch.alloc(RegionDepth, source.count + source.objects.len) orelse return error.InvalidExecution;
    defer scratch.free(source.holder);
    // Instance cells get theirs when they are created.
    @memset(source.holder[0..source.count], 0);
    var replay: Replay = .{ .execution = execution, .view = execution, .expected = expected, .catchers = &catchers, .source = &source, .has_source = has_source, .work = work, .budget = budget };
    if (producer) |again| {
        // The second run builds its strings where the first did. Equal bytes afterwards mean the
        // strings about to be printed are still the ones admitted before the replay.
        const pool = std.hash.Wyhash.hash(0, program.strings);
        // A run that never reclaims only appends, so its pool is at every moment the start of
        // the final one, and what was just learnt about the final pool holds throughout. A run
        // that reclaims reuses positions: nothing is known about its pool while it is under way.
        if (execution.reclaims != 0) @memset(memo.types[0..memo.cleared], 0);
        // A run that reclaims writes new strings over freed bytes. A window can end before
        // the second run has built the strings of the root nodes the replay reaches next, so
        // the checks that read the bytes of strings at the root wait for the next window, or
        // for the end of the run: by then the second run has built them, and no frame has
        // ended since to free them.
        replay.deferring = execution.reclaims != 0;
        defer if (replay.deferred.len != 0) scratch.free(replay.deferred);
        // The second run is given the first one's record and no world (RFC-0086, I3).
        if (again.inputs) |inputs| {
            inputs.prefix = execution.effects.inputRecord();
            inputs.source = null;
            // RFC-0086, P2.3: and the same grants, a run parameter (H1).
            inputs.grants = execution.effects.grants;
        }
        // The prefix borrows the reported run, which need not outlive this replay.
        defer if (again.inputs) |inputs| {
            inputs.prefix = .{};
            inputs.grants = &.{};
        };
        const completed = again.run(again.context, .{ .context = &replay, .write = Replay.receive, .more = Replay.wantsMore });
        if (replay.failed) |problem| return problem;
        try replayDeferred(&replay);
        replay.deferring = false;
        if (!completed or std.hash.Wyhash.hash(0, program.strings) != pool) return error.InvalidExecution;
        if (!replay.witness.eql(execution.witness) or source.reclaims != execution.reclaims) return error.InvalidExecution;
        // Calls were checked against the second run's pool, which reclaimed as it went. The
        // members about to be printed are the first run's: they must be the same members.
        // This is one comparison per member in use and is not charged, like the hash above.
        if (replay.streamed) {
            // And the string pool ends where the second run's does.
            if (replay.view.program.strings.len != program.strings.len) return error.InvalidExecution;
            const members = replay.view.aggregate_values;
            if (members.len != execution.aggregate_values.len) return error.InvalidExecution;
            for (members, execution.aggregate_values) |theirs, ours| if (!sameValue(theirs, ours)) return error.InvalidExecution;
        }
        // A run without steps sends no window; the roots after the last call need none either.
        try replaySchedule(&replay, &.{});
    } else try replaySchedule(&replay, execution.call_steps);
    // A witness that ends early leaves the schedule waiting for its next step.
    if (replay.pc != program.nodes.len) return error.InvalidExecution;
    try scheduleEnd(&replay);
}

/// The schedule replay between windows of steps. A stored witness is one window; a streamed
/// one arrives in many, and the replay stops wherever a window ends and continues in the next.
const Replay = struct {
    execution: evaluator.Execution,
    /// The execution as calls are checked against it: with the members of the second run, as
    /// they are while a window is being replayed, when there is a second run. Root values and
    /// the members they name are never reclaimed, so the schedule between calls reads them
    /// from `execution` itself, whenever it gets to them.
    view: evaluator.Execution,
    streamed: bool = false,
    expected: []bool,
    catchers: *[types.limits.control_depth]u32,
    source: *SourceReplay,
    has_source: bool,
    work: *u64,
    budget: u64,
    depth: usize = 0,
    failure_count: u32 = 0,
    prefix: u32 = 0,
    pc: u32 = 0,
    call: CallProgress = .{},
    /// RFC-0082, P3.9: an `event_notify` of the root under way: the number below which it calls
    /// subscriptions, and the next one it calls, if any.
    notify_on: bool = false,
    notify_limit: i64 = 0,
    notify_next: ?types.ObjectRef = null,
    /// Steps received and steps the schedule accounted for; a valid witness has no others.
    fed: u64 = 0,
    consumed: u64 = 0,
    /// Count and digest of the streamed steps, to compare with the ones the execution claims.
    witness: types.Witness = .{},
    failed: ?Error = null,
    /// The root checks put off until the second run has caught up (`replayLater`).
    deferring: bool = false,
    deferred: []Deferred = &.{},
    deferred_count: u32 = 0,

    /// Whether the second run is worth continuing: not once the report's work budget is spent. It
    /// stops at its next step (`TraceSink.more`), so the work of the report bounds the run that
    /// feeds it. Any other refusal (an invalid window) lets the run end: the budget is not what
    /// ran out, and a run that ends writes the string pool as the reported run left it, where a
    /// stopped one leaves the strings of its tail partly written. After `ReportLimit` the
    /// execution's string pool is spent for further replays, as `validateReplayed` documents.
    fn wantsMore(context: *anyopaque) bool {
        const self: *Replay = @ptrCast(@alignCast(context));
        const problem = self.failed orelse return true;
        return problem != error.ReportLimit;
    }

    /// A window of a streamed witness. The first error is kept and the rest of the stream is
    /// ignored, until the second run, which `wantsMore` has stopped, ends.
    fn receive(context: *anyopaque, steps: []const types.CallStep, members: []const types.Value, strings: usize) void {
        const self: *Replay = @ptrCast(@alignCast(context));
        if (self.failed != null) return;
        if (strings > types.limits.string_bytes) {
            self.failed = error.InvalidExecution;
            return;
        }
        // Steps name strings of the second run's pool as it stands, which while that run is
        // under way can reach beyond where the reported run's pool ended.
        self.view.program.strings = self.execution.program.strings.ptr[0..strings];
        // Between two windows a run only appends, or reclaims as the replay has worked out for
        // itself; a pool smaller than the replay's own count is a run it did not follow.
        if (members.len > types.limits.aggregate_elements or members.len < self.prefix) {
            self.failed = error.InvalidExecution;
            return;
        }
        self.streamed = true;
        self.view.aggregate_values = members;
        // The pool has grown over positions nothing has been remembered about yet.
        if (members.len > memo.cleared and members.len <= memo.types.len) {
            @memset(memo.types[memo.cleared..members.len], 0);
            memo.cleared = members.len;
        }
        replayWindow(self, steps) catch |problem| {
            self.failed = problem;
        };
    }
};

/// Admits the values of a streamed window as `admit` does for a stored witness, then replays it.
fn replayWindow(replay: *Replay, steps: []const types.CallStep) Error!void {
    for (steps) |event| {
        try charge(replay.work, replay.budget);
        try validateValue(replay.view, event.value, replay.work, replay.budget);
    }
    for (steps) |event| try validateMap(replay.view, event.value, replay.work, replay.budget);
    replay.witness.fold(steps, replay.execution.program.strings.ptr);
    // The second run has built the strings of the root nodes reached before this window.
    try replayDeferred(replay);
    try replaySchedule(replay, steps);
}

/// A root check that waits for the second run (`Replay.deferring`): the node and the members in
/// use when it was reached.
const Deferred = struct { pc: u32, prefix: u32 };
/// Whether the check of root node `pc` waits; if so it is queued. Each root node is reached
/// once, so the queue never holds more than the program's nodes.
fn replayLater(replay: *Replay, pc: u32, prefix: u32) Error!bool {
    if (!replay.deferring) return false;
    if (replay.deferred.len == 0) replay.deferred = scratch.alloc(Deferred, replay.execution.program.nodes.len) orelse return error.InvalidExecution;
    if (replay.deferred_count == replay.deferred.len) return error.InvalidExecution;
    replay.deferred[replay.deferred_count] = .{ .pc = pc, .prefix = prefix };
    replay.deferred_count += 1;
    return true;
}
fn replayDeferred(replay: *Replay) Error!void {
    for (replay.deferred[0..replay.deferred_count]) |later| try replayRoot(replay.execution, replay.source, later.pc, later.prefix, replay.work, replay.budget);
    replay.deferred_count = 0;
}
/// The check of a root node whose value the replay works out from its operands: a pure node, a
/// text operation, a native that computes, or an untraced call, which builds the members from
/// `prefix` on (`replaySchedule` has moved past them already).
fn replayRoot(execution: evaluator.Execution, source: *SourceReplay, pc: u32, prefix: u32, work: *u64, budget: u64) Error!void {
    const node = execution.program.nodes[pc];
    const value = execution.values[pc];
    switch (node.kind) {
        .call => |c| {
            var at = prefix;
            if (!sameValue(value, try replayCompute(execution, source, c, &at, work, budget))) return error.InvalidExecution;
            if (at != prefix + execution.program.functions[c.function].member_work) return error.InvalidExecution;
        },
        .native_call => |c| try replayNative(execution, source, c, execution.values[0..pc], value, prefix, work, budget),
        .map_set => |set| {
            var at = prefix;
            try replayMapSet(execution, execution.values[set.map].aggregate.elements, execution.values[set.key], execution.values[set.value], value.aggregate.elements, &at, work, budget);
        },
        .text => |t| try replayText(t, node.value_type, .{ execution.values[t.a], if (t.op.arity() > 1) execution.values[t.b] else value, if (t.op.arity() > 2) execution.values[t.c] else value }, execution.aggregate_values, value, work, budget),
        else => if (!try replayPure(execution, node, execution.values[0..pc], value, work, budget)) return error.InvalidExecution,
    }
}

fn replaySchedule(replay: *Replay, steps: []const types.CallStep) Error!void {
    const execution = replay.execution;
    const program = execution.program;
    const has_source = replay.has_source;
    const expected = replay.expected;
    const catchers = replay.catchers;
    const source = replay.source;
    const work = replay.work;
    const budget = replay.budget;
    var depth = replay.depth;
    var failure_count = replay.failure_count;
    var call_step: usize = 0;
    var prefix = replay.prefix;
    var pc = replay.pc;
    replay.fed += steps.len;
    defer {
        replay.depth = depth;
        replay.failure_count = failure_count;
        replay.consumed += call_step;
        replay.prefix = prefix;
        replay.pc = pc;
    }
    while (true) {
        // The root's own turns for tasks (RFC-0082): one its `spawn` started, then the starts it
        // committed, each until it first waits or settles.
        if (source.tasks.on) while (true) {
            if (replay.call.task == replay_none and replay.call.started == false and replay.call.waiting == false and !replay.call.live) {
                const s = &source.tasks;
                if (s.root_slice != replay_none) {
                    replay.call = .{ .task = s.root_slice };
                    s.root_slice = replay_none;
                } else if (s.root_drain) {
                    if (try replayNextStart(source, s.drain_origin)) |slot| {
                        if (replayReactive(&s.tasks[slot])) {
                            // RFC-0084, P4.4: a reaction's start is its first evaluation.
                            try replayReactionStart(source, slot, 0, .root_start);
                            replay.call = .{ .live = true, .turn = true };
                        } else replay.call = .{ .task = slot };
                    } else {
                        s.root_drain = false;
                        // P4.4: the commit that began the drain delivers once it is over.
                        if (s.root_point) {
                            s.root_point = false;
                            try replayPoint(source, 0);
                            if (source.live.react.phase != .idle) replay.call = .{ .live = true, .turn = true };
                        }
                    }
                }
            }
            if (replay.call.task == replay_none and !replay.call.turn) break;
            const origin = if (replay.call.task != replay_none) source.tasks.tasks[replay.call.task].origin else source.tasks.drain_origin;
            _ = (try functionTrace(replay.view, origin, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
            replay.call = .{};
        };
        if (pc == program.nodes.len) break;
        const node = program.nodes[pc];
        // A root call that a window interrupted was charged and checked when it began.
        const resumed = replay.call.started or replay.call.waiting or replay.call.live;
        if (!resumed) try charge(work, budget);
        for (0..if (resumed) 0 else types.operandCount(node, program.members)) |ordinal| {
            if (!expected[types.operandAt(node, ordinal, program.members, program.call_arguments)]) return error.InvalidExecution;
        }
        var next = pc + 1;
        var failed = false;
        // An effect native outside every function (RFC-0079): the run left a step for it
        // (`CallStep.kind == .root`), and the native is run again against the replay's own
        // port. A second run sends that step as soon as the native has run, so the text of an
        // action is read while the pool the two runs share still holds it; until the step is
        // here the replay waits, and gives back what it charged for this visit.
        // RFC-0087, P5.3: so does a JSON node there, whose text and strings the replay reads.
        // RFC-0087, P5.5: and so does the declaration of a persistent cell, which decodes its loads.
        if ((node.kind == .native_call and program.natives[node.kind.native_call.native].effect != .none) or node.kind == .json_encode or node.kind == .json_decode or (node.kind == .weak_init and program.source_cells[node.kind.weak_init].keyed == .persistent)) {
            if (!execution.active(pc)) return error.InvalidExecution;
            if (call_step == steps.len) {
                work.* -= 1;
                return;
            }
            const event = steps[call_step];
            if (event.kind != .root or event.function != 0 or event.pc != pc or !sameValue(event.value, execution.values[pc])) return error.InvalidExecution;
            call_step += 1;
            switch (node.kind) {
                .json_encode => |operand| try replayJsonEncode(execution, source, program.nodes[operand].value_type, execution.values[operand], execution.values[pc], work, budget),
                .json_decode => |operand| try replayJsonDecode(execution, source, node.value_type, execution.values[operand], execution.values[pc], &prefix, work, budget),
                .weak_init => |c| try replayLoads(execution, source, c, node.value_type, execution.values[pc], &prefix, work, budget),
                else => try replayEffect(program, node.kind.native_call, execution.values[0..pc], execution.values[pc], execution.aggregate_values, source, work, budget),
            }
        }
        switch (node.kind) {
            .call, .iterate, .invoke, .iterate_value, .loop => {
                const invocation = node.invocationWith(null, execution.values).?;
                const f = program.functions[invocation.target()];
                if (node.kind == .invoke or invocation != .call or f.has_control or f.has_source or f.has_local) {
                    const outcome = (try functionTrace(replay.view, pc, invocation, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                    switch (outcome) {
                        .ok => |value| if (!execution.active(pc) or !sameValue(value, execution.values[pc])) {
                            return error.InvalidExecution;
                        },
                        .language => {
                            failed = true;
                            if (execution.active(pc) or depth == 0) return error.InvalidExecution;
                            depth -= 1;
                            const begin = catchers[depth];
                            if (has_source) try source.abort(work, budget);
                            try source.regionAbort();
                            if (!expected[begin] or execution.values[begin].boolean) return error.InvalidExecution;
                            next = nodeBranch(program.nodes[begin]).alternative + 1;
                        },
                    }
                } else {
                    // An untraced call is run again by the replay itself; the members it builds
                    // are as many as its function's footprint says, which the replay checks
                    // where it runs it.
                    if (!execution.active(pc)) return error.InvalidExecution;
                    const footprint = f.member_work;
                    if (prefix > execution.aggregate_values.len or footprint > execution.aggregate_values.len - prefix) return error.InvalidExecution;
                    if (!try replayLater(replay, pc, prefix)) try replayRoot(execution, source, pc, prefix, work, budget);
                    prefix += footprint;
                }
            },
            .bind => {
                if (!execution.active(pc)) return error.InvalidExecution;
                try replayBind(execution, node, execution.values[pc], execution.values[0..pc], program.call_arguments, &prefix, work, budget);
            },
            .aggregate => |range| {
                if (!execution.active(pc)) return error.InvalidExecution;
                const count = range.end - range.start;
                if (prefix > execution.aggregate_values.len or count > execution.aggregate_values.len - prefix) return error.InvalidExecution;
                const expected_range: types.Span = .{ .start = prefix, .end = prefix + count };
                if (execution.values[pc] != .aggregate or !std.meta.eql(execution.values[pc].aggregate.elements, expected_range)) return error.InvalidExecution;
                for (program.members[range.start..range.end], execution.aggregate_values[expected_range.start..expected_range.end]) |operand, actual| {
                    try charge(work, budget);
                    if (!sameValue(execution.values[operand], actual)) return error.InvalidExecution;
                }
                prefix = expected_range.end;
            },
            .option_value => |operand| {
                const original = execution.values[operand].aggregate.elements;
                if (!execution.active(pc) or original.start == original.end or !sameValue(execution.values[pc], execution.aggregate_values[original.start])) return error.InvalidExecution;
            },
            .map_set => {
                if (!execution.active(pc) or execution.values[pc] != .aggregate) return error.InvalidExecution;
                // Its key may be a string, whose bytes a lookup reads (`replayLater`): its members
                // are the recorded span, which the check where it runs compares.
                const span = execution.values[pc].aggregate.elements;
                if (span.start != prefix or span.end < span.start or span.end > execution.aggregate_values.len) return error.InvalidExecution;
                if (!try replayLater(replay, pc, prefix)) try replayRoot(execution, source, pc, prefix, work, budget);
                prefix = span.end;
            },
            .map_remove => |removal| {
                if (!execution.active(pc) or execution.values[pc] != .aggregate) return error.InvalidExecution;
                try replayMapRemove(execution, execution.values[removal.map].aggregate.elements, execution.values[removal.key], execution.values[pc].aggregate.elements, &prefix, work, budget);
            },
            .array_set => |set| {
                if (!execution.active(pc) or execution.values[pc] != .aggregate) return error.InvalidExecution;
                const original = execution.values[set.array].aggregate.elements;
                const position = execution.values[set.index].integer;
                const span = execution.values[pc].aggregate.elements;
                if (position < 0 or position >= original.end - original.start or span.start != prefix or span.end - span.start != original.end - original.start or span.end > execution.aggregate_values.len) return error.InvalidExecution;
                for (execution.aggregate_values[span.start..span.end], 0..) |actual, offset| {
                    try charge(work, budget);
                    const kept = if (offset == @as(usize, @intCast(position))) execution.values[set.value] else execution.aggregate_values[original.start + offset];
                    if (!sameValue(actual, kept)) return error.InvalidExecution;
                }
                prefix = span.end;
            },
            .array_concat => |c| {
                if (!execution.active(pc) or execution.values[pc] != .aggregate) return error.InvalidExecution;
                try replayConcat(execution, execution.values[c.lhs].aggregate.elements, execution.values[c.rhs].aggregate.elements, execution.values[pc].aggregate.elements, &prefix, array_concat.contextOf(0, false, 0, source.tasks.switches != 0, source.tasks.saved_live != 0), work, budget);
            },
            .native_call => {
                // A native that computes is run again, and a fresh result occupies exactly the
                // next unused members.
                if (!execution.active(pc)) return error.InvalidExecution;
                if (!try replayLater(replay, pc, prefix)) try replayRoot(execution, source, pc, prefix, work, budget);
                if (execution.values[pc] == .aggregate) {
                    const span = execution.values[pc].aggregate.elements;
                    if (span.start != prefix or span.end < span.start or span.end > execution.aggregate_values.len) return error.InvalidExecution;
                    for (execution.aggregate_values[span.start..span.end]) |_| try charge(work, budget);
                    prefix = span.end;
                }
            },
            .if_begin => |b| {
                if (!execution.active(pc) or !sameValue(execution.values[pc], execution.values[b.condition])) return error.InvalidExecution;
                if (!execution.values[b.condition].boolean) next = b.alternative + 1;
            },
            .local_set => |n| if (!sameValue(execution.values[pc], execution.values[n])) return error.InvalidExecution,
            .upcast => |n| if (!sameValue(execution.values[pc], widened(execution.values[n], node.value_type))) return error.InvalidExecution,
            .downcast => |n| if (!sameValue(execution.values[pc], widened(execution.values[n], node.value_type))) return error.InvalidExecution,
            .refine => |n| if (!sameValue(execution.values[pc], execution.values[n])) return error.InvalidExecution,
            .text => {
                if (!execution.active(pc)) return error.InvalidExecution;
                if (!try replayLater(replay, pc, prefix)) try replayRoot(execution, source, pc, prefix, work, budget);
            },
            .instance_of => |c| if (execution.values[pc] != .boolean or execution.values[pc].boolean != castsTo(execution, execution.values[c.value], c.class)) return error.InvalidExecution,
            .method_value => |m| {
                const function = catalogue.dispatchLookup(program.dispatch, execution.values[m.receiver].object.value_type, m.slot) orelse return error.InvalidExecution;
                const value = execution.values[pc];
                if (value != .callable or value.callable.function != function or value.callable.captures.start != 0 or value.callable.captures.end != 0) return error.InvalidExecution;
            },
            .cell_read => |cell| {
                if (!sameValue(execution.values[pc], try source.read(cell))) return error.InvalidExecution;
            },
            .cell_init, .cell_write => |cell| {
                if (!sameValue(execution.values[pc], execution.values[cell.value])) return error.InvalidExecution;
                if (node.kind == .cell_write and source.live.on) {
                    // RFC-0084: the root's write propagates; its guards run on the empty stack.
                    // P4.4: then it delivers.
                    if (!replay.call.live) {
                        if (!resumed) try liveProgramWrite(source, cell.cell, execution.values[pc], 0, work, budget);
                        replay.call = .{ .live = true, .deliver = true };
                    }
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                } else try source.write(cell.cell, execution.values[pc], node.kind == .cell_init);
            },
            .cell_live, .object_live => {
                // RFC-0084: the establishing write, and the propagation after it.
                if (!replay.call.live) {
                    if (!resumed) switch (node.kind) {
                        .cell_live => |c| try liveStartEstablish(execution, source, c, execution.values[c.guard], pc, 0),
                        .object_live => |c| {
                            if (execution.values[c.object] != .object) return error.InvalidExecution;
                            try liveStartField(execution, source, execution.values[c.object].object, c, node.value_type, execution.values[c.guard], pc, 0);
                        },
                        else => unreachable,
                    };
                    replay.call = .{ .live = true, .deliver = true };
                }
                const established = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                replay.call = .{};
                if (!execution.active(pc) or established != .ok or !sameValue(execution.values[pc], established.ok)) return error.InvalidExecution;
            },
            .object_new => |c| {
                var fields: [types.limits.record_fields]types.Value = undefined;
                const arguments = program.call_arguments[c.arguments.start..c.arguments.end];
                for (arguments, fields[0..arguments.len]) |operand, *out| out.* = execution.values[operand];
                try charge(work, budget);
                if (!sameValue(execution.values[pc], .{ .object = try source.allocate(node.value_type, fields[0..arguments.len]) })) return error.InvalidExecution;
            },
            .object_get => |a| if (!sameValue(execution.values[pc], try source.objectRead(execution.values[a.value].object, a.index))) return error.InvalidExecution,
            .object_set => |c| {
                if (!sameValue(execution.values[pc], execution.values[c.value])) return error.InvalidExecution;
                if (source.live.on) {
                    if (!replay.call.live) {
                        if (!resumed) try liveFieldWrite(source, execution.values[c.object].object, c.index, execution.values[pc], 0, work, budget);
                        replay.call = .{ .live = true, .deliver = true };
                    }
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                } else try source.objectWrite(execution.values[c.object].object, c.index, execution.values[pc]);
            },
            // RFC-0085, I1: the root's variable cells, as in a function.
            .ref_new => |operand| {
                try charge(work, budget);
                if (!sameValue(execution.values[pc], .{ .object = try source.allocate(node.value_type, &.{execution.values[operand]}) })) return error.InvalidExecution;
            },
            .ref_get => |operand| {
                if (execution.values[operand] != .object or !sameValue(execution.values[pc], try source.objectRead(execution.values[operand].object, catalogue.ref_value - 1))) return error.InvalidExecution;
            },
            .ref_set => |r| {
                if (!sameValue(execution.values[pc], execution.values[r.value]) or execution.values[r.ref] != .object) return error.InvalidExecution;
                if (source.live.on) {
                    if (!replay.call.live) {
                        if (!resumed) try liveFieldWrite(source, execution.values[r.ref].object, catalogue.ref_value - 1, execution.values[pc], 0, work, budget);
                        replay.call = .{ .live = true, .deliver = true };
                    }
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                } else try source.objectWrite(execution.values[r.ref].object, catalogue.ref_value - 1, execution.values[pc]);
            },
            .attempt_begin => {
                if (!execution.active(pc)) return error.InvalidExecution;
                if (has_source) try source.begin(work, budget);
                source.effects.begin();
                catchers[depth] = pc;
                depth += 1;
            },
            .otherwise => |begin| {
                if (!resumed) {
                    if (!expected[begin] or !execution.values[begin].boolean) return error.InvalidExecution;
                    if (program.nodes[begin].kind == .attempt_begin) {
                        if (depth == 0 or catchers[depth - 1] != begin) return error.InvalidExecution;
                        depth -= 1;
                        if (has_source) try source.commit(work, budget);
                        if (try source.regionCommit()) {
                            source.tasks.root_drain = true;
                            source.tasks.drain_origin = pc;
                            // RFC-0084, P4.4: it delivers once its drain is over.
                            if (source.live.on) source.tasks.root_point = true;
                        } else if (source.live.on) {
                            // P4.4: a commit to depth 0 delivers what is pending at once.
                            try replayPoint(source, 0);
                            if (source.live.react.phase != .idle) replay.call = .{ .live = true };
                        }
                    }
                }
                if (replay.call.live) {
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                }
                if (!execution.active(pc) or !execution.values[pc].boolean) return error.InvalidExecution;
                next = nodeBranch(program.nodes[begin]).end;
            },
            .merge => |m| {
                const selected = if (execution.values[m.begin].boolean) m.left else m.right;
                if (!expected[m.begin] or !expected[selected] or !execution.active(pc) or !sameValue(execution.values[pc], widened(execution.values[selected], node.value_type))) return error.InvalidExecution;
            },
            .demand, .fail => |operand| {
                failed = node.kind == .fail or !execution.values[operand].boolean;
                if (failed) {
                    if (execution.active(pc) or depth == 0) return error.InvalidExecution;
                    depth -= 1;
                    const begin = catchers[depth];
                    if (has_source) try source.abort(work, budget);
                    try source.regionAbort();
                    if (!expected[begin] or execution.values[begin].boolean) return error.InvalidExecution;
                    try admitFailure(execution, source, &failure_count, .{ .instruction = pc, .span = node.span, .code = if (node.kind == .fail) .language_failure else .requirement_failed, .reason = if (node.kind == .fail) execution.values[operand].string else null });
                    next = nodeBranch(program.nodes[begin]).alternative + 1;
                } else if (!execution.active(pc) or !execution.values[pc].boolean) return error.InvalidExecution;
            },
            // A root has no exit, and a run that reached `err` ended without a report.
            .exit, .err => return error.InvalidExecution,
            // RFC-0084, P4.4: a reaction of the root starts now outside every region; its first
            // evaluation, and its body when that fires it, run on the empty stack.
            .reaction => |r| {
                if (!replay.call.live) {
                    if (!execution.active(pc)) return error.InvalidExecution;
                    const slot = try replayReaction(program, source, node.value_type, r, execution.values[r.guard], execution.values[r.body], pc, node.span);
                    if (!sameValue(execution.values[pc], source.tasks.tasks[slot].handle)) return error.InvalidExecution;
                    if (source.effects.depth != 0) try replayHold(source, slot) else {
                        try replayReactionStart(source, slot, 0, .node);
                        replay.call = .{ .live = true };
                    }
                }
                if (replay.call.live) {
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                }
            },
            // RFC-0084, P4.5: a batch of the root calls its body on the empty stack with one more
            // batch open, and delivers once it returns.
            .batch => |operand| {
                if (!replay.call.live) {
                    const body = execution.values[operand];
                    if (body != .callable or body.callable.function >= program.functions.len) return error.InvalidExecution;
                    if (!resumed) source.live.batches += 1;
                    const invocation: types.Invocation = .{ .call = .{ .function = body.callable.function, .arguments = .{ .start = 0, .end = 0 }, .captures = body.callable.captures } };
                    const outcome = (try functionTrace(replay.view, pc, invocation, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                    if (outcome != .ok or !execution.active(pc) or !sameValue(outcome.ok, execution.values[pc]) or source.live.batches == 0) return error.InvalidExecution;
                    source.live.batches -= 1;
                    if (source.live.on) {
                        try replayPoint(source, 0);
                        if (source.live.react.phase != .idle) replay.call = .{ .live = true };
                    }
                }
                if (replay.call.live) {
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                }
            },
            .spawn => |operand| {
                // RFC-0082: outside every region the task runs now, as the root's next turn.
                if (!execution.active(pc)) return error.InvalidExecution;
                const slot = try replaySpawn(program, source, node.value_type, execution.values[operand], pc);
                if (!sameValue(execution.values[pc], source.tasks.tasks[slot].handle)) return error.InvalidExecution;
                if (source.effects.depth != 0) try replayHold(source, slot) else source.tasks.root_slice = slot;
            },
            // Root code holds no site.
            .sleep, .canceling, .cancel_exit, .task_await, .event_await => return error.InvalidExecution,
            .branch => return error.InvalidExecution,
            .task_cancel => return error.InvalidExecution,
            // P3.7: the clock, which stands still while the root runs.
            .elapsed_time => if (!execution.active(pc) or !sameValue(execution.values[pc], .{ .floating = replayElapsed(&source.tasks) })) return error.InvalidExecution,
            // RFC-0086, P2.3: a handle of the run's grants, or `option{}`.
            .grant => |g| {
                if (!execution.active(pc)) return error.InvalidExecution;
                // RFC-0087, P5.4: the session, which builds nothing.
                if (g.kind == .session) {
                    if (!sameValue(execution.values[pc], replaySession(node.value_type))) return error.InvalidExecution;
                } else try replayGrant(source.inputs.grants, g, execution.values[g.name], execution.values[pc], execution.aggregate_values, &prefix, program, work, budget);
            },
            // RFC-0087, P5.4: a keyed cell, declared empty, looked up and updated in the replay's
            // own cells; an update of a live program propagates as a `cell_write` does.
            .weak_init => |c| {
                if (program.source_cells[c].keyed == .persistent) {
                    // The loads were replayed above; the cell is what they built.
                    if (!execution.active(pc)) return error.InvalidExecution;
                    try source.write(c, execution.values[pc], true);
                } else {
                    const empty: types.Value = .{ .aggregate = .{ .value_type = node.value_type, .elements = .{ .start = prefix, .end = prefix } } };
                    if (!execution.active(pc) or !sameValue(execution.values[pc], empty)) return error.InvalidExecution;
                    try source.write(c, empty, true);
                }
            },
            .weak_get => |g| {
                if (!execution.active(pc) or !sameValue(execution.values[pc], try replayKeyedGet(execution, try source.read(g.cell), execution.values[g.key], node.value_type, work, budget))) return error.InvalidExecution;
            },
            .weak_set => |c| {
                if (!execution.active(pc) or !sameValue(execution.values[pc], execution.values[c.value])) return error.InvalidExecution;
                if (!replay.call.live) {
                    const written = try replayKeyedSet(execution, try source.read(c.cell), execution.values[c.key], execution.values[c.value], &prefix, work, budget);
                    if (source.live.on) {
                        try liveProgramWrite(source, c.cell, written, 0, work, budget);
                        replay.call = .{ .live = true, .deliver = true };
                    } else try source.write(c.cell, written, false);
                    // RFC-0087, P5.5 (S5): a persistent cell's write is also an action.
                    try replayStoreAction(execution, source, c.cell, execution.values[c.key], execution.values[c.value], work, budget);
                }
                if (source.live.on) {
                    _ = (try functionTrace(replay.view, pc, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                }
            },
            // P3.2: events, and signals carried out or held, at the root too.
            .event_new => {
                if (!execution.active(pc)) return error.InvalidExecution;
                const built = try replayEvent(source, node.value_type);
                if (!sameValue(execution.values[pc], .{ .object = built })) return error.InvalidExecution;
            },
            // P3.9: subscriptions at the root, and the callbacks of a `Signal` there, each a call
            // of the root that the replay chooses from its own cells.
            .event_subscribe => |c| {
                if (!execution.active(pc)) return error.InvalidExecution;
                const built = try replaySubscribe(source, execution.values[c.event], execution.values[c.callback], node.value_type, work, budget);
                if (!sameValue(execution.values[pc], .{ .object = built })) return error.InvalidExecution;
            },
            .subscription_cancel => |operand| {
                if (!execution.active(pc)) return error.InvalidExecution;
                try replayUnsubscribe(source, execution.values[operand]);
            },
            .event_notify => |n| {
                if (!replay.notify_on) {
                    const target = execution.values[n.callable];
                    if (target != .object) return error.InvalidExecution;
                    const limit = try source.objectRead(target.object, catalogue.subscription_count - 1);
                    if (limit != .integer) return error.InvalidExecution;
                    replay.notify_limit = limit.integer;
                    replay.notify_next = try replayNextSubscription(source, try source.objectRead(target.object, catalogue.subscription_first - 1), limit.integer, work, budget);
                    replay.notify_on = true;
                }
                while (replay.notify_next) |subscription| {
                    const callback = try source.objectRead(subscription, catalogue.cancelable_callback - 1);
                    if (callback != .callable or callback.callable.function >= program.functions.len) return error.InvalidExecution;
                    const invocation: types.Invocation = .{ .call = .{ .function = callback.callable.function, .arguments = n.arguments, .captures = callback.callable.captures } };
                    const outcome = (try functionTrace(replay.view, pc, invocation, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
                    replay.call = .{};
                    if (outcome != .ok) return error.InvalidExecution;
                    replay.notify_next = try replayNextSubscription(source, try source.objectRead(subscription, catalogue.cancelable_after - 1), replay.notify_limit, work, budget);
                }
                replay.notify_on = false;
                const unit = execution.values[pc];
                if (!execution.active(pc) or unit != .aggregate or unit.aggregate.elements.start != unit.aggregate.elements.end) return error.InvalidExecution;
            },
            .event_signal => |signal| {
                if (!execution.active(pc)) return error.InvalidExecution;
                try replaySignalNode(source, execution.values[signal.event], execution.values[signal.value]);
            },
            // The admission compared these three with their nodes (`admit`).
            .function_value, .enumeration, .character => {},
            // RFC-0087, P5.3: checked with their root steps, above.
            .json_encode, .json_decode => {},
            // Every other node computes its value from its operands, which the replay does too.
            else => {
                if (!execution.active(pc)) return error.InvalidExecution;
                if (!try replayLater(replay, pc, prefix)) try replayRoot(execution, source, pc, prefix, work, budget);
            },
        }
        if (!failed) {
            if (!execution.active(pc)) return error.InvalidExecution;
            expected[pc] = true;
        }
        pc = next;
    }
    // P3.5: what the root holds now never moves.
    if (!source.root_ended) {
        source.root_ended = true;
        source.root_members = prefix;
        source.root_cells = if (source.tracked) @intCast(source.count + source.object_count) else 0;
    }
    // The root has finished: the scheduler runs the tasks to quiescence (RFC-0082, S3).
    if (!source.tasks.on or source.tasks.quiescent) return;
    const s = &source.tasks;
    while (true) {
        if (replay.call.task != replay_none or replay.call.started or replay.call.waiting) {
            _ = (try functionTrace(replay.view, s.tasks[replay.call.task].origin, undefined, &prefix, steps, &call_step, &failure_count, source, &replay.call, work, budget)) orelse return;
            replay.call = .{};
            continue;
        }
        if (s.ready_from != s.ready_to) {
            std.debug.assert(s.current == replay_none);
            const slot = s.ready[s.ready_from % s.ready.len];
            s.ready_from += 1;
            replay.call = .{ .task = slot, .restore = true };
            continue;
        }
        if (s.timer_count == 0) break;
        // The clock jumps to the earliest deadline, and every timer due then wakes in order.
        if (call_step == steps.len) return;
        const event = steps[call_step];
        try charge(work, budget);
        const wake = s.timers[1].wake;
        if (event.kind != .tick or event.function != 0 or event.pc != 0 or event.value != .integer or event.value.integer != @as(i64, @intCast(wake)) or wake <= s.now) return error.InvalidExecution;
        call_step += 1;
        s.now = wake;
        while (s.timer_count != 0 and s.timers[1].wake == wake) {
            const timer = s.timerTake();
            const task = &s.tasks[timer.task];
            if (task.state != .waiting) return error.InvalidExecution;
            task.state = .ready;
            const site = program.function_nodes[program.functions[task.site_function].body.start + task.site_pc].node;
            task.resume_value = .{ .aggregate = .{ .value_type = site.value_type, .elements = .{ .start = 0, .end = 0 } } };
            s.ready[s.ready_to % s.ready.len] = timer.task;
            s.ready_to += 1;
        }
    }
    s.quiescent = true;
}

fn scheduleEnd(replay: *const Replay) Error!void {
    const execution = replay.execution;
    const program = execution.program;
    const expected = replay.expected;
    const source = replay.source;
    const work = replay.work;
    const budget = replay.budget;
    if (source.depth != 1) return error.InvalidExecution;
    try admitEffects(execution, &source.effects, work, budget);
    try admitInputs(execution, &source.inputs);
    try admitScheduler(execution, source, work, budget);
    // A program that spawns, or a live one, reports its cells as they ended, which the replay
    // built too.
    // RFC-0087, P5.4: so does a program with a keyed cell, whose final value a report shows (W8).
    if (execution.cells.len != (if (replayTasks(program) or source.live.on or types.keyedCells(program)) source.count else 0)) return error.InvalidExecution;
    // What its live variables did is what the replay did (RFC-0084).
    if (source.live.on) {
        if (source.live.run.active or source.live.tracking or !std.meta.eql(execution.live, source.live.record)) return error.InvalidExecution;
    } else if (!std.meta.eql(execution.live, types.Live{})) return error.InvalidExecution;
    for (execution.cells, source.cells[0..execution.cells.len]) |cell, expected_cell| {
        try charge(work, budget);
        if (cell.initialized != (expected_cell != null) or (expected_cell != null and !sameValue(expected_cell.?, cell.value))) return error.InvalidExecution;
    }
    // The state the run ended with is exactly the state the trace built.
    if (source.object_count != execution.object_cells.len) return error.InvalidExecution;
    for (source.objects[0..source.object_count], execution.object_cells) |expected_cell, cell| {
        try charge(work, budget);
        if (!cell.initialized or expected_cell == null or !sameValue(expected_cell.?, cell.value)) return error.InvalidExecution;
    }
    for (source.reasons[0..source.reason_count], execution.failures[0..source.reason_count]) |expected_reason, trace| {
        const reason = expected_reason orelse continue;
        const actual = trace.reason.?;
        if (!validString(actual, program.strings) or actual.ptr != reason.ptr or actual.len != reason.len) return error.InvalidExecution;
    }
    if (replay.depth != 0 or replay.prefix != execution.aggregate_values.len or replay.consumed != replay.fed or replay.failure_count != execution.failure_count or execution.failures.len != @min(replay.failure_count, types.limits.failure_traces)) return error.InvalidExecution;
    for (expected[0..program.nodes.len], 0..) |visited, index| if (visited != execution.active(index)) return error.InvalidExecution;
}

fn replayBind(execution: evaluator.Execution, node: types.Node, value: types.Value, values: []const types.Value, arguments: []const u32, prefix: *u32, work: *u64, budget: u64) Error!void {
    const b = node.kind.bind;
    const original = values[b.callable].callable;
    if (original.captures.end > prefix.* or value != .callable or value.callable.function != original.function) return error.InvalidExecution;
    const old = original.captures.end - original.captures.start;
    const count = old + b.arguments.end - b.arguments.start;
    if (prefix.* > execution.aggregate_values.len or count > execution.aggregate_values.len - prefix.*) return error.InvalidExecution;
    const expected: types.Span = .{ .start = prefix.*, .end = prefix.* + count };
    if (!std.meta.eql(value.callable.captures, expected)) return error.InvalidExecution;
    for (execution.aggregate_values[original.captures.start..original.captures.end], execution.aggregate_values[expected.start .. expected.start + old]) |prior, actual| {
        try charge(work, budget);
        if (!sameValue(prior, actual)) return error.InvalidExecution;
    }
    for (arguments[b.arguments.start..b.arguments.end], execution.aggregate_values[expected.start + old .. expected.end]) |operand, actual| {
        try charge(work, budget);
        if (!sameValue(values[operand], actual)) return error.InvalidExecution;
    }
    prefix.* = expected.end;
}

fn replayObjects(program: types.Program) bool {
    // A live record is an instance (RFC-0084).
    if (evaluator.live(program)) return true;
    for (program.nodes) |node| if (node.kind == .object_new or node.kind == .event_new or node.kind == .ref_new or node.kind == .json_decode) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .object_new or entry.node.kind == .event_new or entry.node.kind == .ref_new or entry.node.kind == .json_decode)) return true;
    // RFC-0087, P5.6: so do the loads of a persistent cell, whose entries may be instances, in a
    // program that makes none itself (a later version that reads what an earlier one saved). A
    // `weak_init` is only ever a root node.
    for (program.nodes) |node| if (node.kind == .weak_init and node.kind.weak_init < program.source_cells.len and program.source_cells[node.kind.weak_init].keyed == .persistent) return true;
    // A task's handle is an instance too (RFC-0082).
    return replayTasks(program);
}

fn replaySource(program: types.Program) bool {
    if (program.source_ops != 0) return true;
    for (program.nodes) |node| {
        if (node.kind == .invoke or node.kind == .iterate_value or node.kind == .loop) {
            const operand = switch (node.kind) {
                .invoke => |i| i.callable,
                .iterate_value => |i| i.callable,
                .loop => |i| i.callable,
                else => unreachable,
            };
            if (catalogue.definition(program.nodes[operand].value_type, program.definitions).?.callable.transacts) return true;
        }
        // RFC-0084, P4.5: so does the body of a batch.
        if (node.kind == .batch and catalogue.definition(program.nodes[node.kind.batch].value_type, program.definitions).?.callable.transacts) return true;
        if (node.invocation()) |invocation| if (program.functions[invocation.target()].has_source) return true;
    }
    return false;
}

// Global chronology is independent of whether root activity is dense or sparse.
// Full counts remain checked after the bounded prefix has filled.
fn admitFailure(execution: evaluator.Execution, source: *SourceReplay, count: *u32, expected: types.FailureTrace) Error!void {
    if (count.* < types.limits.failure_traces) {
        if (count.* >= execution.failures.len) return error.InvalidExecution;
        const trace = execution.failures[count.*];
        if (trace.instruction != expected.instruction or trace.function != expected.function or trace.pc != expected.pc or !std.meta.eql(trace.span, expected.span) or trace.code != expected.code) return error.InvalidExecution;
        if ((expected.reason == null) != (trace.reason == null)) return error.InvalidExecution;
        // The reason is a string of the run, which a later reclamation may move: it is kept,
        // moved by the replay's own rule, and compared with the trace when the replay ends.
        source.reasons[count.*] = expected.reason;
        source.reason_count = count.* + 1;
    }
    count.* += 1;
}

fn writeCallable(out: *std.Io.Writer, p: types.Program, value_ref: types.CallableValue, captured: bool) std.Io.Writer.Error!void {
    const f = p.functions[value_ref.function];
    try out.writeAll("{\"function\":{\"name\":");
    try std.json.Stringify.value(f.name.text(p.source), .{}, out);
    try out.writeAll(",\"module\":");
    if (p.modules.len == 0) try out.writeAll("null") else {
        const owner = modules.owner(f.name, p.modules).?;
        try std.json.Stringify.value(p.modules[owner].path.text(p.paths), .{}, out);
    }
    if (f.anonymous) {
        const offset = if (p.modules.len == 0) f.name.start else f.name.start - p.modules[modules.owner(f.name, p.modules).?].source.start;
        try out.writeAll(",\"anonymous\":");
        try std.json.Stringify.value(offset, .{}, out);
    }
    if (f.specialization) |key| {
        const tuple = catalogue.definition(key, p.definitions).?.tuple;
        try out.writeAll(",\"specialization\":[");
        for (p.tuple_elements[tuple.start..tuple.end], 0..) |t, index| {
            if (index != 0) try out.writeByte(',');
            try std.json.Stringify.value(@backingInt(t), .{}, out);
        }
        try out.writeByte(']');
    }
    if (!captured) try out.writeAll("}}") else try out.writeAll(",\"captures\":[");
}

// A `full` run's listed actions are compared byte for byte as the replay prepares them
// (`EffectReplay.listed`, `fix2`), without the tally. Random region operations against a model
// that keeps the actions still standing: the list the model commits is accepted, and changing
// one byte of it, dropping or adding an action, or moving where one ends is refused.
test "a full run's listed actions are checked byte for byte against the actions replayed" {
    var prng = std.Random.DefaultPrng.init(0xb17e);
    const random = prng.random();
    for (0..400) |_| {
        // The run, as the model sees it: what every operation does, and what ends committed.
        var operations: [48]u8 = undefined;
        var texts: [48][8]u8 = undefined;
        var lengths: [48]usize = undefined;
        var depth: usize = 0;
        var standing: [64]usize = undefined;
        var standing_count: usize = 0;
        var region_marks: [64]usize = undefined;
        for (&operations, 0..) |*operation, index| {
            operation.* = random.uintLessThan(u8, 4);
            if (depth == 0 and operation.* > 1) operation.* = 0;
            switch (operation.*) {
                0 => {
                    lengths[index] = random.uintLessThan(usize, 9);
                    for (texts[index][0..lengths[index]]) |*byte| byte.* = 'a' + random.uintLessThan(u8, 3);
                    standing[standing_count] = index;
                    standing_count += 1;
                },
                1 => {
                    region_marks[depth] = standing_count;
                    depth += 1;
                },
                2 => depth -= 1,
                else => {
                    depth -= 1;
                    standing_count = region_marks[depth];
                },
            }
        }
        // Regions still open at the end commit, as the run's do.
        // The record of the run: the standing actions, end to end.
        var bytes: [48 * 8]u8 = undefined;
        var entries: [48]effects.Entry = undefined;
        var end: u32 = 0;
        for (standing[0..standing_count], 0..) |action, position| {
            @memcpy(bytes[end..][0..lengths[action]], texts[action][0..lengths[action]]);
            entries[position] = .{ .start = end, .end = end + @as(u32, @intCast(lengths[action])) };
            end += @intCast(lengths[action]);
        }
        const Forgery = enum { none, byte, drop, add, boundary };
        for ([_]Forgery{ .none, .byte, .drop, .add, .boundary }) |forgery| {
            var record: effects.Record = .{ .entries = entries[0..standing_count], .bytes = bytes[0..end] };
            var forged_bytes = bytes;
            var forged_entries = entries;
            switch (forgery) {
                .none => {},
                .byte => {
                    if (end == 0) continue;
                    forged_bytes[random.uintLessThan(usize, end)] ^= 0x20;
                    record.bytes = forged_bytes[0..end];
                },
                .drop => {
                    if (standing_count == 0) continue;
                    record.entries = entries[0 .. standing_count - 1];
                    record.bytes = bytes[0..if (standing_count == 1) 0 else entries[standing_count - 2].end];
                },
                .add => {
                    forged_entries[standing_count] = .{ .start = end, .end = end };
                    record.entries = forged_entries[0 .. standing_count + 1];
                },
                .boundary => {
                    if (standing_count < 2 or entries[0].end == entries[0].start) continue;
                    forged_entries[0].end -= 1;
                    forged_entries[1].start -= 1;
                    record.entries = forged_entries[0..standing_count];
                },
            }
            var replay: EffectReplay = .{ .listed = record };
            defer if (replay.marks.len != 0) scratch.free(replay.marks);
            for (operations, 0..) |operation, index| switch (operation) {
                0 => try EffectReplay.act(&replay, 0, texts[index][0..lengths[index]]),
                1 => replay.begin(),
                2 => try replay.commit(),
                else => try replay.abort(),
            };
            while (replay.depth != 0) try replay.commit();
            const agrees = !replay.diverged and replay.cursor == record.entries.len;
            try std.testing.expectEqual(forgery == .none, agrees);
        }
    }
}

// Structured concurrency (RFC-0082): `SchedulerReplay`, the third statement of the scheduler,
// written from the RFC. It predicts every decision the run's scheduler makes (which task
// starts or resumes, whether a site waits and until when, which timers a tick wakes and in
// which order) and requires the run's steps to be exactly those decisions. Its stores are
// borrowed at the first `spawn` of a report and returned with the report.

const replay_none: u32 = std.math.maxInt(u32);
const replay_never: u64 = std.math.maxInt(u64);
const ReplayTaskState = enum { unused, held, queued, running, ready, waiting, settled };
/// A structured expression (P3.3), in the slot of the task running it; `done` once it can yield
/// at the end of its start phase, until its value is replayed.
const ReplayRecord = struct {
    kind: types.StructuredKind = .sync,
    function: u32 = 0,
    pc: u32 = 0,
    arms: u32 = 0,
    started: u32 = 0,
    settled: u32 = 0,
    first: u32 = replay_none,
    last: u32 = replay_none,
    winner: u32 = replay_none,
    canceling: bool = false,
    starting: bool = false,
    done: bool = false,
    /// P3.6: the winner ended with a pending exit, which abandoned the expression.
    exited: bool = false,
};
const ReplayTask = struct {
    sequence: u64 = 0,
    state: ReplayTaskState = .unused,
    handle: types.Value = undefined,
    closure: types.Value = undefined,
    origin: u32 = 0,
    wake: u64 = replay_never,
    order: u64 = 0,
    site_function: u32 = 0,
    site_pc: u32 = 0,
    resume_value: types.Value = undefined,
    visit_at: u32 = 0,
    visits: u32 = 0,
    local_at: u32 = 0,
    locals: u32 = 0,
    parameters: u32 = 0,
    prior: u32 = replay_none,
    later: u32 = replay_none,
    /// P3.2: what it waits for and on what; the next in its list; its own awaiters.
    waits: types.Scheduler.WaitKind = .sleep,
    target: types.Value = undefined,
    next_waiter: u32 = replay_none,
    awaiters_first: u32 = replay_none,
    awaiters_last: u32 = replay_none,
    /// P3.3: a spawned task or an arm; its cancel flag; the waiter before it, the task it
    /// awaits and its timer's place; the next request; for an arm its expression's task, the
    /// next arm and its result; and the expression it runs.
    kind: types.Scheduler.TaskKind = .spawn,
    flagged: bool = false,
    prior_waiter: u32 = replay_none,
    awaited: u32 = replay_none,
    timer_at: u32 = replay_none,
    request_next: u32 = replay_none,
    parent: u32 = replay_none,
    next_arm: u32 = replay_none,
    completed: bool = false,
    result: types.Value = undefined,
    record: ReplayRecord = .{},
    /// P3.4: for a branch or a `Rush`'s loser, the task whose visit owns it, that visit's place
    /// from the task's entry visit, and its neighbours in the visit's list; the task below it on
    /// the visit stack, and its entry visit's depth while it runs there.
    holder: u32 = replay_none,
    holder_frame: u32 = 0,
    next_owned: u32 = replay_none,
    prior_owned: u32 = replay_none,
    below: u32 = replay_none,
    entry_at: u32 = 0,
    /// P3.6: an arm whose entry visit ended by `arm_exit`; its result is the pending exit.
    exited: bool = false,
    /// RFC-0084, P4.4: a reaction's body (its guard is `closure`), its node, and what fired it.
    body: types.Value = undefined,
    site_span: types.Span = .{ .start = 0, .end = 0 },
    fired_by: ReplayFiring = .loop,
};
const ReplayIndexed = struct { sequence: u64, slot: u32 };
const ReplaySignal = struct { event: types.Value, value: types.Value };
/// What a task waits for (P3.2).
const ReplayWait = union(enum) { sleep: u64, event: types.ObjectRef, task: struct { handle: types.ObjectRef, slot: u32 }, record: u32, frame_end: u32, guard };
/// A `CallVisit` of a suspended task, without the catchers (none is open at a site), its
/// registers counted from the task's first.
const ReplaySaved = struct {
    function: u32,
    base: u32,
    pc: u32,
    caller: ?u32,
    arguments: types.Span,
    remaining_visits: u64,
    seed: types.Value,
    pending: bool,
    state_loop: bool,
    captures: types.Span,
    mark: u32,
    string_mark: u32,
    cell_mark: u32,
    switches: u64,
    task: u32,
    /// P3.4: as in `CallVisit`.
    owned_first: u32 = replay_none,
    owned_last: u32 = replay_none,
    canceled_end: bool = false,
};
const ReplayTimer = struct { wake: u64, order: u64, task: u32 };
const ReplayMark = struct { depth: u32, count: u64 };
const replay_frame_room = types.limits.saved_frames + types.limits.saved_frames / 2;
const replay_value_room = types.limits.saved_registers + types.limits.saved_registers / 2;
const SchedulerReplay = struct {
    on: bool = false,
    tasks: []ReplayTask = &.{},
    free: []u32 = &.{},
    free_count: u32 = 0,
    taken: u32 = 0,
    live: u32 = 0,
    ready: []u32 = &.{},
    ready_from: u64 = 0,
    ready_to: u64 = 0,
    /// A heap counted from 1.
    timers: []ReplayTimer = &.{},
    timer_count: u32 = 0,
    held: []u32 = &.{},
    /// P3.2: a held entry `replay_none` is a signal, kept here at the same place.
    signals: []ReplaySignal = &.{},
    /// P3.2: live tasks by sequence.
    index: []ReplayIndexed = &.{},
    indexed: u32 = 0,
    held_from: u64 = 0,
    held_committed: u64 = 0,
    held_to: u64 = 0,
    marks: []ReplayMark = &.{},
    mark_count: u32 = 0,
    saved: []ReplaySaved = &.{},
    values: []types.Value = &.{},
    saved_top: u32 = 0,
    values_top: u32 = 0,
    saved_live: u32 = 0,
    values_live: u32 = 0,
    parameters_live: u32 = 0,
    oldest: u32 = replay_none,
    newest: u32 = replay_none,
    now: u64 = 0,
    rate: u64 = types.Scheduler.default_tick_rate,
    sequence: u64 = 0,
    order: u64 = 0,
    switches: u64 = 0,
    created: u64 = 0,
    completed: u64 = 0,
    /// P3.3: tasks cancelled, the requests still to make, and whether the site just left
    /// yielded cancelled.
    canceled: u64 = 0,
    requests: u32 = replay_none,
    canceled_now: bool = false,
    /// The root's turns: a task its `spawn` started, and whether it drains committed starts.
    root_slice: u32 = replay_none,
    root_drain: bool = false,
    /// The root instruction that committed what the root drains.
    drain_origin: u32 = 0,
    /// RFC-0084, P4.4: that commit delivers once the drain is over.
    root_point: bool = false,
    quiescent: bool = false,
    /// P3.4: the task whose visits are on top, `replay_none` in root code.
    current: u32 = replay_none,
    /// P3.6: whether the site just left yielded an arm's pending exit, and its value.
    exited_now: bool = false,
    exited_value: types.Value = undefined,

    fn open(self: *SchedulerReplay, rate: u64) Error!void {
        if (!types.Scheduler.validRate(rate)) return error.InvalidExecution;
        self.rate = rate;
        self.on = true;
        self.tasks = scratch.alloc(ReplayTask, types.limits.tasks) orelse return error.InvalidExecution;
        self.free = scratch.alloc(u32, types.limits.tasks) orelse return error.InvalidExecution;
        self.ready = scratch.alloc(u32, types.limits.tasks) orelse return error.InvalidExecution;
        self.timers = scratch.alloc(ReplayTimer, types.limits.tasks + 1) orelse return error.InvalidExecution;
        self.held = scratch.alloc(u32, types.limits.scheduler_actions) orelse return error.InvalidExecution;
        self.signals = scratch.alloc(ReplaySignal, types.limits.scheduler_actions) orelse return error.InvalidExecution;
        self.index = scratch.alloc(ReplayIndexed, 2 * types.limits.tasks) orelse return error.InvalidExecution;
        self.marks = scratch.alloc(ReplayMark, types.limits.scheduler_actions) orelse return error.InvalidExecution;
        self.saved = scratch.alloc(ReplaySaved, replay_frame_room) orelse return error.InvalidExecution;
        self.values = scratch.alloc(types.Value, replay_value_room) orelse return error.InvalidExecution;
    }
    fn close(self: *SchedulerReplay) void {
        if (self.tasks.len != 0) scratch.free(self.tasks);
        if (self.free.len != 0) scratch.free(self.free);
        if (self.ready.len != 0) scratch.free(self.ready);
        if (self.timers.len != 0) scratch.free(self.timers);
        if (self.held.len != 0) scratch.free(self.held);
        if (self.signals.len != 0) scratch.free(self.signals);
        if (self.index.len != 0) scratch.free(self.index);
        if (self.marks.len != 0) scratch.free(self.marks);
        if (self.saved.len != 0) scratch.free(self.saved);
        if (self.values.len != 0) scratch.free(self.values);
        self.* = .{};
    }
    /// Live tasks by sequence, ascending, with gaps for ended ones (P3.2).
    fn noteSequence(self: *SchedulerReplay, sequence: u64, slot: u32) void {
        if (self.indexed == self.index.len) {
            var kept: u32 = 0;
            for (self.index[0..self.indexed]) |entry| if (entry.slot != replay_none) {
                self.index[kept] = entry;
                kept += 1;
            };
            self.indexed = kept;
        }
        std.debug.assert(self.indexed == 0 or self.index[self.indexed - 1].sequence < sequence);
        self.index[self.indexed] = .{ .sequence = sequence, .slot = slot };
        self.indexed += 1;
    }
    fn indexOf(self: *const SchedulerReplay, sequence: u64) ?u32 {
        var low: u32 = 0;
        var high: u32 = self.indexed;
        while (high > low) {
            const half = (low + high) / 2;
            if (self.index[half].sequence >= sequence) high = half else low = half + 1;
        }
        return if (low < self.indexed and self.index[low].sequence == sequence) low else null;
    }
    fn slotOf(self: *const SchedulerReplay, sequence: u64) ?u32 {
        const at = self.indexOf(sequence) orelse return null;
        return if (self.index[at].slot == replay_none) null else self.index[at].slot;
    }
    fn forgetSequence(self: *SchedulerReplay, sequence: u64) void {
        const at = self.indexOf(sequence).?;
        self.index[at].slot = replay_none;
        while (self.indexed != 0 and self.index[self.indexed - 1].slot == replay_none) self.indexed -= 1;
    }
    fn makeReady(self: *SchedulerReplay, slot: u32, value: types.Value) void {
        self.tasks[slot].state = .ready;
        self.tasks[slot].resume_value = value;
        self.tasks[slot].next_waiter = replay_none;
        self.tasks[slot].prior_waiter = replay_none;
        self.ready[self.ready_to % self.ready.len] = slot;
        self.ready_to += 1;
    }
    fn take(self: *SchedulerReplay) Error!u32 {
        // A run with no slot left stopped at `task_limit` and has no report.
        if (self.live == types.limits.tasks) return error.InvalidExecution;
        const slot = if (self.free_count != 0) reuse: {
            self.free_count -= 1;
            break :reuse self.free[self.free_count];
        } else fresh: {
            self.taken += 1;
            break :fresh self.taken - 1;
        };
        self.live += 1;
        self.tasks[slot] = .{};
        return slot;
    }
    fn release(self: *SchedulerReplay, slot: u32) void {
        std.debug.assert(self.tasks[slot].state != .unused);
        self.forgetSequence(self.tasks[slot].sequence);
        self.tasks[slot].state = .unused;
        self.free[self.free_count] = slot;
        self.free_count += 1;
        self.live -= 1;
    }
    fn timerAbove(a: ReplayTimer, b: ReplayTimer) bool {
        return if (a.wake == b.wake) a.order < b.order else a.wake < b.wake;
    }
    /// A timer at `at` of the heap, whose task remembers where (P3.3: a cancellation takes it out).
    fn timerPut(self: *SchedulerReplay, at: u32, timer: ReplayTimer) void {
        self.timers[at] = timer;
        self.tasks[timer.task].timer_at = at;
    }
    fn timerRise(self: *SchedulerReplay, start: u32, timer: ReplayTimer) void {
        var at = start;
        while (at > 1 and timerAbove(timer, self.timers[at / 2])) : (at /= 2) self.timerPut(at, self.timers[at / 2]);
        self.timerPut(at, timer);
    }
    fn timerFall(self: *SchedulerReplay, start: u32, timer: ReplayTimer) void {
        var at = start;
        while (2 * at <= self.timer_count) {
            var child = 2 * at;
            if (child < self.timer_count and timerAbove(self.timers[child + 1], self.timers[child])) child += 1;
            if (timerAbove(timer, self.timers[child])) break;
            self.timerPut(at, self.timers[child]);
            at = child;
        }
        self.timerPut(at, timer);
    }
    fn timerAdd(self: *SchedulerReplay, timer: ReplayTimer) void {
        self.timer_count += 1;
        self.timerRise(self.timer_count, timer);
    }
    fn timerTake(self: *SchedulerReplay) ReplayTimer {
        const top = self.timers[1];
        const last = self.timers[self.timer_count];
        self.timer_count -= 1;
        if (self.timer_count != 0) self.timerFall(1, last);
        self.tasks[top.task].timer_at = replay_none;
        return top;
    }
    /// Takes out the timer of the task in `slot`, which was asked to cancel (P3.3).
    fn timerDrop(self: *SchedulerReplay, slot: u32) Error!void {
        const at = self.tasks[slot].timer_at;
        if (at == replay_none or at == 0 or at > self.timer_count or self.timers[at].task != slot) return error.InvalidExecution;
        const last = self.timers[self.timer_count];
        self.timer_count -= 1;
        self.tasks[slot].timer_at = replay_none;
        if (at == self.timer_count + 1) return;
        if (at > 1 and timerAbove(last, self.timers[at / 2])) self.timerRise(at, last) else self.timerFall(at, last);
    }
    /// Commits the innermost of the run's regions for the starts: they go to the region around
    /// it, or are committed outside every region. True when that begins a drain.
    fn commitHeld(self: *SchedulerReplay, closing: u32) bool {
        if (self.mark_count != 0 and self.marks[self.mark_count - 1].depth == closing) {
            if (closing == 1 or (self.mark_count > 1 and self.marks[self.mark_count - 2].depth == closing - 1)) {
                self.mark_count -= 1;
            } else self.marks[self.mark_count - 1].depth = closing - 1;
        }
        if (closing != 1) return false;
        const begins = self.held_from == self.held_committed;
        while (self.held_committed < self.held_to) : (self.held_committed += 1) {
            const slot = self.held[self.held_committed % self.held.len];
            if (slot != replay_none) self.tasks[slot].state = .queued;
        }
        return begins and self.held_from != self.held_committed;
    }
    fn abortHeld(self: *SchedulerReplay, closing: u32) void {
        if (self.mark_count == 0 or self.marks[self.mark_count - 1].depth != closing) return;
        self.mark_count -= 1;
        const keep = self.marks[self.mark_count].count;
        while (self.held_to > keep) {
            self.held_to -= 1;
            const slot = self.held[self.held_to % self.held.len];
            // A held signal goes with its region (P3.2).
            if (slot == replay_none) continue;
            self.sequence = self.tasks[slot].sequence - 1;
            self.release(slot);
        }
    }
};

/// The next committed start, counted under `origin`, the root instruction of its drain; the
/// committed signals before it are carried out first, in order (P3.2).
fn replayNextStart(source: *SourceReplay, origin: u32) Error!?u32 {
    const s = &source.tasks;
    while (s.held_from != s.held_committed) {
        const place = s.held_from % s.held.len;
        const slot = s.held[place];
        s.held_from += 1;
        if (slot == replay_none) {
            try replaySignal(source, s.signals[place].event, s.signals[place].value);
            continue;
        }
        // RFC-0084, P4.7: a reaction cancelled before its turn never starts (N6).
        if (s.tasks[slot].state == .settled) {
            if (!replayReactive(&s.tasks[slot])) return error.InvalidExecution;
            s.release(slot);
            continue;
        }
        s.tasks[slot].origin = origin;
        return slot;
    }
    return null;
}

/// The visit on top committed to depth 0 and begins a drain.
fn replayDrainFrom(execution: evaluator.Execution, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, prefix: u32, root_pc: u32) Error!void {
    // RFC-0084, P4.4: with reactions each turn is taken by the drive, where a reaction's start
    // can run its guard and its body, and the drain delivers when it ends.
    if (source.live.reacts) {
        if (source.live.react.phase != .idle) return error.InvalidExecution;
        frames[depth.* - 1].drains = true;
        source.live.react = .{ .phase = .drain_turn, .base = depth.* };
        return;
    }
    const slot = (try replayNextStart(source, root_pc)) orelse return;
    frames[depth.* - 1].drains = true;
    try replayStart(execution, source, frames, depth, used, prefix, slot, false);
}

/// A `Signal` node replayed: carried out at depth 0, held by the innermost region otherwise.
fn replaySignalNode(source: *SourceReplay, event: types.Value, value: types.Value) Error!void {
    if (event != .object) return error.InvalidExecution;
    if (source.effects.depth == 0) return replaySignal(source, event, value);
    const s = &source.tasks;
    if (!s.on) return error.InvalidExecution;
    const depth = source.effects.depth;
    if (s.held_to - s.held_from == s.held.len) return error.InvalidExecution;
    if (s.mark_count == 0 or s.marks[s.mark_count - 1].depth != depth) {
        s.marks[s.mark_count] = .{ .depth = depth, .count = s.held_to };
        s.mark_count += 1;
    }
    const place = s.held_to % s.held.len;
    s.held[place] = replay_none;
    s.signals[place] = .{ .event = event, .value = value };
    s.held_to += 1;
}

/// The replay's reading of `Signal` (Q1): every task waiting on the event, from its cells and
/// the replay's own lists, goes to the ready queue in order with `value`; the cells empty.
fn replaySignal(source: *SourceReplay, event: types.Value, value: types.Value) Error!void {
    if (event != .object) return error.InvalidExecution;
    const instance = event.object;
    // P3.9 (C104): a sticky event keeps the value, latched, before its waiters wake.
    const shape = catalogue.eventShape(instance.value_type, source.definitions) orelse return error.InvalidExecution;
    if (shape.kind == .sticky) {
        try source.objectWrite(instance, catalogue.sticky_latch - 1, .{ .integer = 1 });
        try source.objectWrite(instance, catalogue.sticky_value - 1, value);
    }
    const waiting = try source.objectRead(instance, catalogue.event_waiting - 1);
    if (waiting != .integer or waiting.integer < 0) return error.InvalidExecution;
    if (waiting.integer == 0) return;
    const s = &source.tasks;
    if (!s.on) return error.InvalidExecution;
    const first = try source.objectRead(instance, catalogue.event_first - 1);
    if (first != .integer or first.integer < 1) return error.InvalidExecution;
    var slot = s.slotOf(@intCast(first.integer)) orelse return error.InvalidExecution;
    var woken: i64 = 0;
    while (true) : (woken += 1) {
        if (woken == waiting.integer) return error.InvalidExecution;
        const task = &s.tasks[slot];
        if (task.state != .waiting or task.waits != .event or !sameValue(task.target, event)) return error.InvalidExecution;
        const after = task.next_waiter;
        s.makeReady(slot, value);
        if (after == replay_none) break;
        slot = after;
    }
    if (woken + 1 != waiting.integer) return error.InvalidExecution;
    for ([_]u32{ catalogue.event_waiting, catalogue.event_first, catalogue.event_last }) |cell| try source.objectWrite(instance, cell - 1, .{ .integer = 0 });
}

/// P3.9: an event of its kind, as the run built it: the cells of an event, and a sticky one's
/// clear latch or a subscribable one's empty list.
fn replayEvent(source: *SourceReplay, event_type: types.Type) Error!types.ObjectRef {
    const shape = catalogue.eventShape(event_type, source.definitions) orelse return error.InvalidExecution;
    const zero: types.Value = .{ .integer = 0 };
    const none: types.Value = .{ .boolean = false };
    return switch (shape.kind) {
        .plain => source.allocate(event_type, &.{ zero, zero, zero }),
        .sticky => source.allocate(event_type, &.{ zero, zero, zero, zero, zero }),
        .subscribable => source.allocate(event_type, &.{ zero, zero, zero, none, none, zero }),
    };
}

/// P3.9: what a sticky event holds once signalled; null otherwise, and for another instance.
fn replaySticky(source: *const SourceReplay, instance: types.ObjectRef) Error!?types.Value {
    const shape = catalogue.eventShape(instance.value_type, source.definitions) orelse return null;
    if (shape.kind != .sticky) return null;
    const latch = try source.objectRead(instance, catalogue.sticky_latch - 1);
    if (latch != .integer) return error.InvalidExecution;
    return if (latch.integer == 1) try source.objectRead(instance, catalogue.sticky_value - 1) else null;
}

/// P3.9 (C107): the replay's own subscription, last on its event's list.
fn replaySubscribe(source: *SourceReplay, event: types.Value, callback: types.Value, made: types.Type, work: *u64, budget: u64) Error!types.ObjectRef {
    try charge(work, budget);
    if (event != .object or callback != .callable) return error.InvalidExecution;
    const number = try source.objectRead(event.object, catalogue.subscription_count - 1);
    const last = try source.objectRead(event.object, catalogue.subscription_last - 1);
    if (number != .integer or number.integer < 0 or (last != .object and !(last == .boolean and !last.boolean))) return error.InvalidExecution;
    const built = try source.allocate(made, &.{ .{ .integer = catalogue.cancelable_active }, callback, event, last, .{ .boolean = false }, number });
    const created: types.Value = .{ .object = built };
    if (last == .object) try source.objectWrite(last.object, catalogue.cancelable_after - 1, created) else try source.objectWrite(event.object, catalogue.subscription_first - 1, created);
    try source.objectWrite(event.object, catalogue.subscription_last - 1, created);
    try source.objectWrite(event.object, catalogue.subscription_count - 1, .{ .integer = number.integer + 1 });
    return built;
}

/// P3.9 (C111, C112): an active subscription leaves its list and keeps its link after.
fn replayUnsubscribe(source: *SourceReplay, subscription: types.Value) Error!void {
    if (subscription != .object) return error.InvalidExecution;
    const instance = subscription.object;
    const state = try source.objectRead(instance, catalogue.cancelable_state - 1);
    if (state != .integer) return error.InvalidExecution;
    if (state.integer != catalogue.cancelable_active) return;
    const event = try source.objectRead(instance, catalogue.cancelable_event - 1);
    const before = try source.objectRead(instance, catalogue.cancelable_before - 1);
    const after = try source.objectRead(instance, catalogue.cancelable_after - 1);
    if (event != .object) return error.InvalidExecution;
    if (before == .object) try source.objectWrite(before.object, catalogue.cancelable_after - 1, after) else try source.objectWrite(event.object, catalogue.subscription_first - 1, after);
    if (after == .object) try source.objectWrite(after.object, catalogue.cancelable_before - 1, before) else try source.objectWrite(event.object, catalogue.subscription_last - 1, before);
    try source.objectWrite(instance, catalogue.cancelable_state - 1, .{ .integer = catalogue.cancelable_canceled });
}

/// P3.9 (C109, C112): from `from` along the list, the first active subscription numbered below
/// `limit`; each reached is charged to the report.
fn replayNextSubscription(source: *const SourceReplay, from: types.Value, limit: i64, work: *u64, budget: u64) Error!?types.ObjectRef {
    var at = from;
    while (true) {
        const subscription = switch (at) {
            .object => |object| object,
            .boolean => |b| if (b) return error.InvalidExecution else return null,
            else => return error.InvalidExecution,
        };
        const number = try source.objectRead(subscription, catalogue.cancelable_number - 1);
        if (number != .integer) return error.InvalidExecution;
        if (number.integer >= limit) return null;
        try charge(work, budget);
        const state = try source.objectRead(subscription, catalogue.cancelable_state - 1);
        if (state != .integer) return error.InvalidExecution;
        if (state.integer == catalogue.cancelable_active) return subscription;
        at = try source.objectRead(subscription, catalogue.cancelable_after - 1);
    }
}

/// The task on top joins the end of the event's waiters, by the event's cells.
fn replayJoinEvent(source: *SourceReplay, event: types.ObjectRef, slot: u32) Error!void {
    const s = &source.tasks;
    const waiting = try source.objectRead(event, catalogue.event_waiting - 1);
    if (waiting != .integer or waiting.integer < 0) return error.InvalidExecution;
    const sequence: i64 = @intCast(s.tasks[slot].sequence);
    if (waiting.integer == 0) {
        try source.objectWrite(event, catalogue.event_first - 1, .{ .integer = sequence });
    } else {
        const last = try source.objectRead(event, catalogue.event_last - 1);
        if (last != .integer or last.integer < 1) return error.InvalidExecution;
        const tail = s.slotOf(@intCast(last.integer)) orelse return error.InvalidExecution;
        s.tasks[tail].next_waiter = slot;
        s.tasks[slot].prior_waiter = tail;
    }
    try source.objectWrite(event, catalogue.event_last - 1, .{ .integer = sequence });
    try source.objectWrite(event, catalogue.event_waiting - 1, .{ .integer = waiting.integer + 1 });
}

/// A suspension for `wait`: the frames go to the saved stores (`replaySuspend`), and then the
/// task registers where it waits.
fn replaySuspendFor(program: types.Program, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, wait: ReplayWait) Error!usize {
    const entry = try replaySuspend(program, source, frames, depth, used, if (wait == .sleep) wait.sleep else replay_never);
    const slot = frames[entry].task;
    const s = &source.tasks;
    s.tasks[slot].next_waiter = replay_none;
    switch (wait) {
        .sleep => s.tasks[slot].waits = .sleep,
        .event => |event| {
            s.tasks[slot].waits = .event;
            s.tasks[slot].target = .{ .object = event };
            try replayJoinEvent(source, event, slot);
        },
        .task => |awaited| {
            s.tasks[slot].waits = .task;
            s.tasks[slot].target = .{ .object = awaited.handle };
            s.tasks[slot].awaited = awaited.slot;
            const target = &s.tasks[awaited.slot];
            s.tasks[slot].prior_waiter = target.awaiters_last;
            if (target.awaiters_last == replay_none) target.awaiters_first = slot else s.tasks[target.awaiters_last].next_waiter = slot;
            target.awaiters_last = slot;
        },
        .record => s.tasks[slot].waits = .record,
        .frame_end => s.tasks[slot].waits = .frame_end,
        // RFC-0084, P4.6: the live replay keeps what its guard read.
        .guard => s.tasks[slot].waits = .guard,
    }
    return entry;
}

/// The replay's own reading of `Sleep(seconds)` at tick `now`: null when it ends at once.
fn replayWake(seconds: f64, now: u64, rate: u64) ?u64 {
    @setFloatMode(.strict);
    if (seconds < 0.0) return null;
    if (seconds == 0.0) return if (now + 1 >= types.Scheduler.clock_limit) replay_never else now + 1;
    if (seconds == std.math.inf(f64)) return replay_never;
    const ticks = @ceil(seconds * @as(f64, @floatFromInt(rate)));
    if (ticks >= 0x1p62) return replay_never;
    const whole: u64 = @intFromFloat(ticks);
    if (now + whole >= types.Scheduler.clock_limit) return replay_never;
    return now + @max(whole, 1);
}

/// A `spawn` replayed: a slot, the next sequence and the handle the run must have built.
fn replaySpawn(program: types.Program, source: *SourceReplay, handle_type: types.Type, closure: types.Value, origin: u32) Error!u32 {
    const s = &source.tasks;
    const shape = catalogue.definition(handle_type, program.definitions).?.task;
    if (closure != .callable) return error.InvalidExecution;
    const slot = try s.take();
    s.sequence += 1;
    const fields = [_]types.Value{ .{ .integer = @intCast(s.sequence) }, .{ .integer = catalogue.task_active }, .{ .aggregate = .{ .value_type = shape.option, .elements = .{ .start = 0, .end = 0 } } } };
    const handle = try source.allocate(handle_type, &fields);
    s.tasks[slot] = .{ .sequence = s.sequence, .state = .running, .handle = .{ .object = handle }, .closure = closure, .origin = origin };
    s.noteSequence(s.sequence, slot);
    return slot;
}

fn replayHold(source: *SourceReplay, slot: u32) Error!void {
    const s = &source.tasks;
    const depth = source.effects.depth;
    std.debug.assert(depth != 0);
    if (s.held_to - s.held_from == s.held.len) return error.InvalidExecution;
    if (s.mark_count == 0 or s.marks[s.mark_count - 1].depth != depth) {
        s.marks[s.mark_count] = .{ .depth = depth, .count = s.held_to };
        s.mark_count += 1;
    }
    s.held[s.held_to % s.held.len] = slot;
    s.held_to += 1;
    s.tasks[slot].state = .held;
}

/// Pushes the entry visit of the task in `slot` above `depth` visits, to replay its `start`
/// step first. A start is a switch, counted before the push.
fn replayStart(execution: evaluator.Execution, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, prefix: u32, slot: u32, handoff: bool) Error!void {
    const s = &source.tasks;
    if (source.effects.depth != 0) return error.InvalidExecution;
    const task = &s.tasks[slot];
    const closure = task.closure.callable;
    if (closure.captures.end > prefix) return error.InvalidExecution;
    const size = execution.program.functions[closure.function].body.end - execution.program.functions[closure.function].body.start;
    if (depth.* == frames.len or size > source.trace_locals.len - used.*) return error.InvalidExecution;
    s.switches += 1;
    frames[depth.*] = .{ .function = closure.function, .base = used.*, .caller = null, .arguments = .{ .start = 0, .end = 0 }, .captures = closure.captures, .mark = prefix, .string_mark = @intCast(source.string_used), .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = s.switches, .task = slot, .handoff = handoff, .expect = .start };
    // P3.4: it runs above the task that started it, which runs again when this one leaves.
    task.below = s.current;
    task.entry_at = @intCast(depth.*);
    s.current = slot;
    used.* += size;
    depth.* += 1;
    task.state = .running;
    s.created += 1;
}

/// The task whose visits are on top waits: they go to the saved stores, from its entry visit.
fn replaySuspend(program: types.Program, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, wake: u64) Error!usize {
    const s = &source.tasks;
    if (source.effects.depth != 0) return error.InvalidExecution;
    var entry = depth.*;
    while (entry > 0 and frames[entry - 1].task == replay_none) entry -= 1;
    if (entry == 0) return error.InvalidExecution;
    entry -= 1;
    const slot = frames[entry].task;
    const first = frames[entry].base;
    const visits: u32 = @intCast(depth.* - entry);
    const values = used.* - first;
    // The visits' parameters count with their registers against one limit.
    var parameters: u32 = 0;
    for (frames[entry..depth.*]) |visit| parameters += program.functions[visit.function].parameter_count;
    if (visits > types.limits.saved_frames - s.saved_live or @as(u64, values) + parameters > types.limits.saved_registers - s.values_live - s.parameters_live) return error.InvalidExecution;
    if (visits > s.saved.len - s.saved_top or values > s.values.len - s.values_top) {
        // Close up the runs of the suspended tasks, in order.
        var saved_at: u32 = 0;
        var values_at: u32 = 0;
        var at = s.oldest;
        while (at != replay_none) : (at = s.tasks[at].later) {
            const held = &s.tasks[at];
            std.mem.copyForwards(ReplaySaved, s.saved[saved_at..][0..held.visits], s.saved[held.visit_at..][0..held.visits]);
            std.mem.copyForwards(types.Value, s.values[values_at..][0..held.locals], s.values[held.local_at..][0..held.locals]);
            held.visit_at = saved_at;
            held.local_at = values_at;
            saved_at += held.visits;
            values_at += held.locals;
        }
        s.saved_top = saved_at;
        s.values_top = values_at;
    }
    const task = &s.tasks[slot];
    task.visit_at = s.saved_top;
    task.visits = visits;
    task.local_at = s.values_top;
    task.locals = values;
    task.parameters = parameters;
    for (frames[entry..depth.*]) |visit| {
        if (visit.catch_depth != 0 or visit.returned != null) return error.InvalidExecution;
        s.saved[s.saved_top] = .{ .function = visit.function, .base = visit.base - first, .pc = visit.pc, .caller = if (visit.caller) |base| base - first else null, .arguments = visit.arguments, .remaining_visits = visit.remaining_visits, .seed = visit.seed, .pending = visit.pending, .state_loop = visit.state_loop, .captures = visit.captures, .mark = visit.mark, .string_mark = visit.string_mark, .cell_mark = visit.cell_mark, .switches = visit.switches, .task = visit.task, .owned_first = visit.owned_first, .owned_last = visit.owned_last, .canceled_end = visit.canceled_end };
        s.saved_top += 1;
    }
    @memcpy(s.values[s.values_top..][0..values], source.trace_locals[first..used.*]);
    s.values_top += values;
    s.saved_live += visits;
    s.values_live += values;
    s.parameters_live += parameters;
    task.prior = s.newest;
    task.later = replay_none;
    if (s.newest == replay_none) s.oldest = slot else s.tasks[s.newest].later = slot;
    s.newest = slot;
    const top = frames[depth.* - 1];
    task.site_function = top.function;
    task.site_pc = top.pc;
    task.wake = wake;
    task.state = .waiting;
    // P3.4: the task below it on the visit stack runs again.
    if (s.current != slot) return error.InvalidExecution;
    s.current = task.below;
    task.below = replay_none;
    if (wake != replay_never) {
        s.order += 1;
        task.order = s.order;
        s.timerAdd(.{ .wake = wake, .order = s.order, .task = slot });
    }
    s.switches += 1;
    depth.* = entry;
    used.* = first;
    return entry;
}

/// A ready task back on the empty visit stack, its top visit to replay the `resume` step first.
fn replayRestore(source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, slot: u32) Error!void {
    const s = &source.tasks;
    if (source.effects.depth != 0 or depth.* != 0) return error.InvalidExecution;
    const task = &s.tasks[slot];
    std.debug.assert(task.state == .ready);
    s.switches += 1;
    for (s.saved[task.visit_at..][0..task.visits], frames[0..task.visits]) |saved, *visit| {
        visit.* = .{ .function = saved.function, .base = saved.base, .pc = saved.pc, .caller = saved.caller, .arguments = saved.arguments, .remaining_visits = saved.remaining_visits, .seed = saved.seed, .pending = saved.pending, .state_loop = saved.state_loop, .captures = saved.captures, .mark = saved.mark, .string_mark = saved.string_mark, .cell_mark = saved.cell_mark, .switches = saved.switches, .task = saved.task, .owned_first = saved.owned_first, .owned_last = saved.owned_last, .canceled_end = saved.canceled_end };
    }
    @memcpy(source.trace_locals[0..task.locals], s.values[task.local_at..][0..task.locals]);
    // A task asked to cancel resumes only to yield cancelled (P3.3), unless it waited at a
    // frame's end, which goes on (P3.4).
    frames[task.visits - 1].expect = if (task.flagged and task.waits != .frame_end) .resume_canceled else .@"resume";
    if (s.current != replay_none) return error.InvalidExecution;
    s.current = slot;
    task.below = replay_none;
    task.entry_at = 0;
    // P3.5: depths compare within the run of the task on the stack, which begins here.
    source.reclaim_depth = 0;
    depth.* = task.visits;
    used.* = task.locals;
    s.saved_live -= task.visits;
    s.values_live -= task.locals;
    s.parameters_live -= task.parameters;
    if (task.prior == replay_none) s.oldest = task.later else s.tasks[task.prior].later = task.later;
    if (task.later == replay_none) s.newest = task.prior else s.tasks[task.later].prior = task.prior;
    task.state = .running;
}

/// What a task that left the visit stack owes the visit below: the handle when a `spawn` handed
/// off to it, the turn of the start phase of `arm_parent`'s expression when it is an arm (P3.3).
const ReplayLeave = struct { handoff: bool, handle: types.Value, arm_parent: u32 };

/// What the task whose entry visit was at `entry_depth`, and has just left, owes; `depth` is
/// how many visits are left below it.
fn replayLeaveOf(source: *const SourceReplay, frames: []const CallVisit, entry_depth: usize, depth: usize) ReplayLeave {
    const task = &source.tasks.tasks[frames[entry_depth].task];
    return .{ .handoff = frames[entry_depth].handoff, .handle = if (task.kind != .arm) task.handle else .{ .boolean = false }, .arm_parent = if (task.kind == .arm and depth != 0) task.parent else replay_none };
}

/// A task left the visit stack: its creator below gets the handle if a `spawn` handed off to
/// it; an arm's expression starts its next arm, or can yield (its value is replayed at its
/// node), or its task waits on it (the `suspend` is replayed next); and a visit that drains
/// committed starts starts the next.
fn replayLeft(execution: evaluator.Execution, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, prefix: u32, leave: ReplayLeave, root_pc: u32) Error!void {
    const below = &frames[depth.* - 1];
    if (leave.handoff) {
        if (!below.pending or below.returned != null) return error.InvalidExecution;
        below.returned = .{ .ok = leave.handle };
    }
    if (leave.arm_parent != replay_none) {
        const record = &source.tasks.tasks[leave.arm_parent].record;
        if (!record.starting or !below.pending or below.function != record.function or below.pc != record.pc) return error.InvalidExecution;
        if (source.tasks.tasks[leave.arm_parent].flagged) {
            // P3.7: an arm asked the task running the expression to cancel: no arm starts after
            // it, the expression is cancelled, and the site yields cancelled at once when every
            // started arm is settled, or after the task waits for them.
            const s = &source.tasks;
            record.starting = false;
            if (record.canceling or s.requests != replay_none) return error.InvalidExecution;
            record.canceling = true;
            replayPushArms(s, record);
            try replayRequests(source);
            if (record.settled == record.started) {
                try replayArmsRelease(s, record);
                below.expect = .start_canceled;
            } else below.expect = .waits;
            return;
        }
        if (record.started < record.arms and record.winner == replay_none) return replayArmStart(execution, source, frames, depth, used, prefix, leave.arm_parent);
        record.starting = false;
        if (replayRecordDone(record)) record.done = true else below.expect = .waits;
        return;
    }
    if (!below.drains) return;
    // RFC-0084, P4.4: the drive takes the next turn of a program with reactions.
    if (source.live.reacts) {
        if (source.live.react.phase != .idle) return error.InvalidExecution;
        source.live.react = .{ .phase = .drain_turn, .base = depth.* };
        return;
    }
    const slot = (try replayNextStart(source, root_pc)) orelse {
        below.drains = false;
        return;
    };
    try replayStart(execution, source, frames, depth, used, prefix, slot, false);
}

// P3.3: `Sync` and `Race`, cancellation requests and unwinding, in the replay's own words.

/// The next arm of `owner`'s expression starts on top of its visit at the site: a slot, the
/// next sequence, and its entry visit, to replay its `start` first.
fn replayArmStart(execution: evaluator.Execution, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, prefix: u32, owner: u32) Error!void {
    const s = &source.tasks;
    const record = &s.tasks[owner].record;
    const top = frames[depth.* - 1];
    if (top.function != record.function or top.pc != record.pc or record.started >= record.arms) return error.InvalidExecution;
    const program = execution.program;
    const arms = program.function_nodes[program.functions[record.function].body.start + record.pc].node.kind.structured.arms;
    const closure = source.trace_locals[top.base + program.function_arguments[arms.start + record.started]];
    if (closure != .callable) return error.InvalidExecution;
    const slot = try s.take();
    s.sequence += 1;
    s.tasks[slot] = .{ .sequence = s.sequence, .state = .running, .closure = closure, .origin = s.tasks[owner].origin, .kind = .arm, .parent = owner };
    s.noteSequence(s.sequence, slot);
    if (record.last == replay_none) record.first = slot else s.tasks[record.last].next_arm = slot;
    record.last = slot;
    record.started += 1;
    try replayStart(execution, source, frames, depth, used, prefix, slot, false);
}

/// Whether an expression can yield: a `Sync` whose arms all completed, a won `Race` whose
/// started arms are all settled. One asked to cancel yields cancelled.
fn replayRecordDone(record: *const ReplayRecord) bool {
    if (record.canceling) return false;
    // P3.6: abandoned by an arm's exit, when its started arms are settled.
    if (record.exited) return record.settled == record.started;
    return switch (record.kind) {
        .sync => record.settled == record.arms,
        // A resolved `Rush` keeps its settled arms only (P3.4).
        .race, .rush => record.winner != replay_none and record.settled == record.started,
    };
}

/// The value an expression that can yield yields, as the replay works it out: a `Race`'s
/// winner's result; a `Sync`'s tuple, which `value` must be: the next members, its arms'
/// results in order.
fn replayRecordValue(execution: evaluator.Execution, source: *const SourceReplay, record: *const ReplayRecord, value: types.Value, prefix: *u32, work: *u64, budget: u64) Error!types.Value {
    const s = &source.tasks;
    // One that an arm's exit abandoned yields no value (P3.6).
    if (!replayRecordDone(record) or record.exited) return error.InvalidExecution;
    if (record.kind != .sync) return s.tasks[record.winner].result;
    const node = execution.program.function_nodes[execution.program.functions[record.function].body.start + record.pc].node;
    if (value != .aggregate or value.aggregate.value_type != node.value_type) return error.InvalidExecution;
    const expected: types.Span = .{ .start = prefix.*, .end = prefix.* + record.arms };
    if (!std.meta.eql(value.aggregate.elements, expected) or expected.end > execution.aggregate_values.len) return error.InvalidExecution;
    var arm = record.first;
    var at = expected.start;
    while (arm != replay_none) : (arm = s.tasks[arm].next_arm) {
        try charge(work, budget);
        if (s.tasks[arm].state != .settled or !s.tasks[arm].completed or at == expected.end or !sameValue(execution.aggregate_values[at], s.tasks[arm].result)) return error.InvalidExecution;
        at += 1;
    }
    if (at != expected.end) return error.InvalidExecution;
    prefix.* = expected.end;
    return value;
}

/// An expression is over: its arms' slots are free, in order.
fn replayArmsRelease(s: *SchedulerReplay, record: *ReplayRecord) Error!void {
    var arm = record.first;
    while (arm != replay_none) {
        const next = s.tasks[arm].next_arm;
        if (s.tasks[arm].state != .settled) return error.InvalidExecution;
        s.release(arm);
        arm = next;
    }
    record.first = replay_none;
    record.last = replay_none;
    record.done = false;
}

/// The arm in `slot` settled: completed with `result`, or cancelled. Its expression counts it;
/// the first to complete wins a `Race`, whose other started arms are asked to cancel; a task
/// waiting on an expression now over is ready.
fn replayArmSettled(source: *SourceReplay, frames: []CallVisit, below: usize, slot: u32, result: types.Value, canceled: bool) Error!void {
    const s = &source.tasks;
    const task = &s.tasks[slot];
    if (task.kind != .arm or task.state != .running or source.effects.depth != 0 or task.parent == replay_none) return error.InvalidExecution;
    // P3.4: the task below it on the visit stack runs again.
    if (s.current != slot) return error.InvalidExecution;
    s.current = task.below;
    task.state = .settled;
    task.completed = !canceled;
    task.result = result;
    if (canceled) s.canceled += 1 else s.completed += 1;
    const owner = task.parent;
    const record = &s.tasks[owner].record;
    record.settled += 1;
    // P3.6: an arm that ended with a pending exit abandons an expression nothing resolved: the
    // other started arms are asked to cancel, in arm order, and no arm starts after it.
    const exited = !canceled and task.exited;
    if (exited and record.winner == replay_none and !record.canceling) {
        record.winner = slot;
        record.exited = true;
        replayPushArms(s, record);
        try replayRequests(source);
    }
    if (!canceled and !exited and record.kind == .race and record.winner == replay_none and !record.canceling) {
        record.winner = slot;
        replayPushArms(s, record);
        try replayRequests(source);
    }
    // P3.4: a `Rush` resolves too, and its other started arms go on, owned by the visit that runs it.
    if (!canceled and !exited and record.kind == .rush and record.winner == replay_none and !record.canceling) {
        record.winner = slot;
        try replayAdopt(source, frames, below, owner);
    }
    // P3.7: an arm cancelled from outside its expression (it awaited a cancelled task) asks the
    // task running it to cancel, unless the expression is cancelling or resolved.
    if (canceled and record.winner == replay_none and !record.canceling) {
        if (s.requests != replay_none) return error.InvalidExecution;
        s.tasks[owner].request_next = replay_none;
        s.requests = owner;
        try replayRequests(source);
    }
    const parked = &s.tasks[owner];
    if (parked.state == .waiting and parked.waits == .record and record.settled == record.started and (record.canceling or replayRecordDone(record))) s.makeReady(owner, .{ .boolean = false });
}

/// The started arms of `record` not yet settled go on top of the requests, in arm order.
fn replayPushArms(s: *SchedulerReplay, record: *const ReplayRecord) void {
    var head: u32 = replay_none;
    var tail: u32 = replay_none;
    var arm = record.first;
    while (arm != replay_none) : (arm = s.tasks[arm].next_arm) {
        if (s.tasks[arm].state == .settled) continue;
        if (tail == replay_none) head = arm else s.tasks[tail].request_next = arm;
        tail = arm;
    }
    if (tail == replay_none) return;
    s.tasks[tail].request_next = s.requests;
    s.requests = head;
}

/// The requests waiting, the last pushed first: a flagged or settled task takes no more; a
/// sleeper's timer goes and an awaiter leaves its list, each ready to yield cancelled; a task
/// waiting on an expression marks it, and its arms are asked next. The run asks only waiting
/// and ready tasks in P3.3, so anything else is a run the replay does not follow.
fn replayRequests(source: *SourceReplay) Error!void {
    const s = &source.tasks;
    while (s.requests != replay_none) {
        const slot = s.requests;
        const task = &s.tasks[slot];
        s.requests = task.request_next;
        task.request_next = replay_none;
        if (task.state == .settled or task.flagged) continue;
        task.flagged = true;
        switch (task.state) {
            .ready => {},
            .waiting => switch (task.waits) {
                .sleep => {
                    if (task.wake != replay_never) try s.timerDrop(slot);
                    s.makeReady(slot, .{ .boolean = false });
                },
                .event => {
                    try replayLeaveEvent(source, slot);
                    s.makeReady(slot, .{ .boolean = false });
                },
                .task => {
                    const awaited = &s.tasks[task.awaited];
                    if (task.prior_waiter == replay_none) awaited.awaiters_first = task.next_waiter else s.tasks[task.prior_waiter].next_waiter = task.next_waiter;
                    if (task.next_waiter == replay_none) awaited.awaiters_last = task.prior_waiter else s.tasks[task.next_waiter].prior_waiter = task.prior_waiter;
                    s.makeReady(slot, .{ .boolean = false });
                },
                .record => {
                    task.record.canceling = true;
                    replayPushArms(s, &task.record);
                },
                // P3.4: its visit is already ending; the flag waits for its next site.
                .frame_end => {},
                // RFC-0084, P4.7: only `replayCancel` asks a reaction, itself. P4.6: a task at
                // an `Await` stops waiting, its entries let go, to yield cancelled.
                .guard => {
                    if (replayReactive(task)) return error.InvalidExecution;
                    try source.live.tidy(source);
                    try source.live.watchRelease(source, slot);
                    s.makeReady(slot, .{ .boolean = false });
                },
            },
            // P3.7: a task on the visit stack, or a committed start, finds the flag at its next
            // site. No region holds a start when a request is made.
            .running, .queued => {},
            else => return error.InvalidExecution,
        }
    }
}

/// `T.Cancel()` (P3.7): a request to the task of the handle, if it has not settled.
fn replayCancel(source: *SourceReplay, handle: types.Value) Error!void {
    const s = &source.tasks;
    if (handle != .object or s.requests != replay_none or source.effects.depth != 0) return error.InvalidExecution;
    const state = try source.objectRead(handle.object, catalogue.task_state - 1);
    if (state != .integer) return error.InvalidExecution;
    if (state.integer != catalogue.task_active) return;
    const sequence = try source.objectRead(handle.object, catalogue.task_sequence - 1);
    if (sequence != .integer or sequence.integer < 1) return error.InvalidExecution;
    const slot = s.slotOf(@intCast(sequence.integer)) orelse return error.InvalidExecution;
    // RFC-0084, P4.7: a request to a reaction does what N6 says.
    if (replayReactive(&s.tasks[slot])) return replayCancelReaction(source, slot);
    s.tasks[slot].request_next = replay_none;
    s.requests = slot;
    try replayRequests(source);
}

/// RFC-0084, P4.7 (N6): a request to the reaction in `slot`. Waiting on its guard it settles
/// cancelled now, its entries let go; queued for its turn in a drain it settles cancelled now,
/// and its start does nothing; firing, it is flagged, and its body's end decides. Anything else
/// is a run the replay does not follow.
fn replayCancelReaction(source: *SourceReplay, slot: u32) Error!void {
    const s = &source.tasks;
    const task = &s.tasks[slot];
    if (task.flagged) return;
    switch (task.state) {
        .running => {
            if (source.live.firing == 0) return error.InvalidExecution;
            task.flagged = true;
            return;
        },
        .waiting => {
            if (task.waits != .guard) return error.InvalidExecution;
            try source.live.tidy(source);
            try source.live.watchRelease(source, slot);
        },
        // Made and cancelled before its turn, it counts as created (C73).
        .queued => s.created += 1,
        else => return error.InvalidExecution,
    }
    try replayReactionCanceled(source, slot);
}

/// The reaction in `slot` settled cancelled (N6): its handle says so and keeps no result, the
/// tasks awaiting it are asked to cancel in the order they began to wait (Q3). Its slot goes,
/// unless a notification for it is pending or its start is queued: then it stays settled until
/// the delivery loop or the drain reaches it (C74).
fn replayReactionCanceled(source: *SourceReplay, slot: u32) Error!void {
    const s = &source.tasks;
    const task = &s.tasks[slot];
    if (source.effects.depth != 0 or s.requests != replay_none or task.handle != .object) return error.InvalidExecution;
    try source.objectWrite(task.handle.object, catalogue.task_state - 1, .{ .integer = catalogue.task_canceled });
    s.canceled += 1;
    var awaiter = task.awaiters_first;
    while (awaiter != replay_none) : (awaiter = s.tasks[awaiter].next_waiter) {
        if (s.tasks[awaiter].state != .waiting or s.tasks[awaiter].waits != .task) return error.InvalidExecution;
        s.tasks[awaiter].request_next = s.tasks[awaiter].next_waiter;
    }
    s.requests = task.awaiters_first;
    try replayRequests(source);
    if (task.awaiters_first != replay_none) return error.InvalidExecution;
    if (slot >= source.live.watch_pending.len) return error.InvalidExecution;
    if (task.state == .queued or (task.state == .waiting and source.live.watch_pending[slot])) task.state = .settled else s.release(slot);
}

/// The clock in seconds (P3.7), worked out by the replay from its own clock.
fn replayElapsed(s: *const SchedulerReplay) f64 {
    @setFloatMode(.strict);
    return @as(f64, @floatFromInt(s.now)) / @as(f64, @floatFromInt(s.rate));
}

/// A spawned task settled cancelled (P3.7): its handle says so and keeps no result, the tasks
/// awaiting it are asked to cancel in the order they began to wait (Q3), and its slot is free.
fn replaySettleCanceled(source: *SourceReplay, slot: u32) Error!void {
    const s = &source.tasks;
    const task = &s.tasks[slot];
    if (task.kind != .spawn or task.state != .running or source.effects.depth != 0 or s.current != slot or s.requests != replay_none) return error.InvalidExecution;
    try source.objectWrite(task.handle.object, catalogue.task_state - 1, .{ .integer = catalogue.task_canceled });
    s.canceled += 1;
    s.current = task.below;
    var awaiter = task.awaiters_first;
    while (awaiter != replay_none) : (awaiter = s.tasks[awaiter].next_waiter) {
        if (s.tasks[awaiter].state != .waiting or s.tasks[awaiter].waits != .task) return error.InvalidExecution;
        s.tasks[awaiter].request_next = s.tasks[awaiter].next_waiter;
    }
    s.requests = task.awaiters_first;
    try replayRequests(source);
    if (task.awaiters_first != replay_none) return error.InvalidExecution;
    s.release(slot);
}

/// The task in `slot` leaves the waiters of the event it waits on, whose cells name the first
/// and the last and count them.
fn replayLeaveEvent(source: *SourceReplay, slot: u32) Error!void {
    const s = &source.tasks;
    const task = &s.tasks[slot];
    if (task.target != .object) return error.InvalidExecution;
    const event = task.target.object;
    const waiting = try source.objectRead(event, catalogue.event_waiting - 1);
    if (waiting != .integer or waiting.integer < 1) return error.InvalidExecution;
    if (task.prior_waiter == replay_none) {
        try source.objectWrite(event, catalogue.event_first - 1, .{ .integer = if (task.next_waiter == replay_none) 0 else @intCast(s.tasks[task.next_waiter].sequence) });
    } else s.tasks[task.prior_waiter].next_waiter = task.next_waiter;
    if (task.next_waiter == replay_none) {
        try source.objectWrite(event, catalogue.event_last - 1, .{ .integer = if (task.prior_waiter == replay_none) 0 else @intCast(s.tasks[task.prior_waiter].sequence) });
    } else s.tasks[task.next_waiter].prior_waiter = task.prior_waiter;
    try source.objectWrite(event, catalogue.event_waiting - 1, .{ .integer = waiting.integer - 1 });
}

// P3.4: `Rush` and `Branch`, the tasks a visit owns, and the wait at a frame's end.

/// Whether a node is a site that acts only for a task not asked to cancel.
fn replayPrimitiveSite(node: types.Node) bool {
    return switch (node.kind) {
        .sleep, .task_await, .event_await, .structured, .branch => true,
        .task_cancel => true,
        .await_guard => true,
        else => false,
    };
}

/// A `branch` replayed in the visit on top: a slot, the next sequence, the end of the visit's
/// list of the tasks it owns, and the unit value as its handle.
fn replayBranch(source: *SourceReplay, frames: []CallVisit, depth: usize, closure: types.Value, unit: types.Type, origin: u32) Error!u32 {
    const s = &source.tasks;
    if (!s.on or source.effects.depth != 0 or s.current == replay_none or closure != .callable or depth == 0) return error.InvalidExecution;
    const slot = try s.take();
    s.sequence += 1;
    const at: u32 = @intCast(depth - 1);
    const holder = s.current;
    if (at < s.tasks[holder].entry_at) return error.InvalidExecution;
    s.tasks[slot] = .{ .sequence = s.sequence, .state = .running, .handle = .{ .aggregate = .{ .value_type = unit, .elements = .{ .start = 0, .end = 0 } } }, .closure = closure, .origin = origin, .kind = .branch, .holder = holder, .holder_frame = at - s.tasks[holder].entry_at, .prior_owned = frames[at].owned_last };
    s.noteSequence(s.sequence, slot);
    if (frames[at].owned_last == replay_none) frames[at].owned_first = slot else s.tasks[frames[at].owned_last].next_owned = slot;
    frames[at].owned_last = slot;
    return slot;
}

/// The ends of the list of the tasks owned by the visit at `index` (from the entry visit) of
/// `holder`: on the visit stack while it runs, in the saved store while it is suspended.
const ReplayOwned = struct { first: *u32, last: *u32 };
fn replayOwnedList(source: *SourceReplay, frames: []CallVisit, holder: u32, index: u32) ReplayOwned {
    const s = &source.tasks;
    const task = &s.tasks[holder];
    if (task.state == .running) {
        const visit = &frames[task.entry_at + index];
        return .{ .first = &visit.owned_first, .last = &visit.owned_last };
    }
    const saved = &s.saved[task.visit_at + index];
    return .{ .first = &saved.owned_first, .last = &saved.owned_last };
}

/// An owned task settled: it leaves its visit's list and its slot is free; a task waiting at
/// that visit's end, whose list is now empty, is ready to end it.
fn replayOwnedSettled(source: *SourceReplay, frames: []CallVisit, slot: u32, result: types.Value, canceled: bool) Error!void {
    _ = result;
    const s = &source.tasks;
    const task = &s.tasks[slot];
    if (task.holder == replay_none or task.state != .running or source.effects.depth != 0 or s.current != slot) return error.InvalidExecution;
    const holder = &s.tasks[task.holder];
    if ((holder.state == .running and holder.entry_at + task.holder_frame >= frames.len) or (holder.state != .running and task.holder_frame >= holder.visits)) return error.InvalidExecution;
    if (canceled) s.canceled += 1 else s.completed += 1;
    s.current = task.below;
    const list = replayOwnedList(source, frames, task.holder, task.holder_frame);
    if (task.prior_owned == replay_none) list.first.* = task.next_owned else s.tasks[task.prior_owned].next_owned = task.next_owned;
    if (task.next_owned == replay_none) list.last.* = task.prior_owned else s.tasks[task.next_owned].prior_owned = task.prior_owned;
    if (list.first.* == replay_none and holder.state == .waiting and holder.waits == .frame_end and task.holder_frame + 1 == holder.visits) s.makeReady(task.holder, .{ .boolean = true });
    s.release(slot);
}

/// The visit `frame` is at its end and owns tasks: each is asked to cancel, in the order it came
/// to the visit, cascading as any request does.
fn replayOwnedRequests(source: *SourceReplay, frame: *const CallVisit) Error!void {
    const s = &source.tasks;
    if (s.requests != replay_none or frame.owned_first == replay_none) return error.InvalidExecution;
    var slot = frame.owned_first;
    while (slot != replay_none) : (slot = s.tasks[slot].next_owned) s.tasks[slot].request_next = s.tasks[slot].next_owned;
    s.requests = frame.owned_first;
    try replayRequests(source);
}

/// `owner`'s `Rush` resolved: its started arms not settled leave the record, in arm order, for
/// the end of the list of the visit that runs it: the visit below the winner's entry visit
/// (`below` visits are below it) in the start phase, the top saved visit of a task waiting on it.
fn replayAdopt(source: *SourceReplay, frames: []CallVisit, below: usize, owner: u32) Error!void {
    const s = &source.tasks;
    const parent = &s.tasks[owner];
    const record = &parent.record;
    var index: u32 = undefined;
    if (parent.state == .running) {
        if (below == 0 or below - 1 < parent.entry_at or frames[below - 1].function != record.function or frames[below - 1].pc != record.pc) return error.InvalidExecution;
        index = @intCast(below - 1 - parent.entry_at);
    } else {
        if (parent.visits == 0) return error.InvalidExecution;
        index = parent.visits - 1;
    }
    const list = replayOwnedList(source, frames, owner, index);
    var first: u32 = replay_none;
    var last: u32 = replay_none;
    var adopted: u32 = 0;
    var arm = record.first;
    while (arm != replay_none) {
        const task = &s.tasks[arm];
        const next = task.next_arm;
        task.next_arm = replay_none;
        if (task.state == .settled) {
            if (last == replay_none) first = arm else s.tasks[last].next_arm = arm;
            last = arm;
        } else {
            task.parent = replay_none;
            task.holder = owner;
            task.holder_frame = index;
            task.prior_owned = list.last.*;
            task.next_owned = replay_none;
            if (list.last.* == replay_none) list.first.* = arm else s.tasks[list.last.*].next_owned = arm;
            list.last.* = arm;
            adopted += 1;
        }
        arm = next;
    }
    record.first = first;
    record.last = last;
    record.started -= adopted;
}

/// The scheduler's record must be the one the replay worked out, and so must what is left.
fn admitScheduler(execution: evaluator.Execution, source: *const SourceReplay, work: *u64, budget: u64) Error!void {
    const record = execution.scheduler;
    const s = &source.tasks;
    if (!s.on) {
        if (record.created != 0 or record.completed != 0 or record.canceled != 0 or record.switches != 0 or record.tick != 0 or record.waiting.len != 0 or !types.Scheduler.validRate(record.tick_rate)) return error.InvalidExecution;
        return;
    }
    if (!s.quiescent or s.ready_from != s.ready_to or s.timer_count != 0 or s.held_to != s.held_from) return error.InvalidExecution;
    if (record.tick_rate != s.rate or record.tick != s.now or record.created != s.created or record.completed != s.completed or record.canceled != s.canceled or record.switches != s.switches) return error.InvalidExecution;
    // Settled arms keep their slots for their expressions, and wait for nothing (P3.3).
    var settled: u64 = 0;
    for (s.tasks[0..s.taken]) |task| {
        try charge(work, budget);
        if (task.state == .settled) settled += 1;
    }
    if (record.waiting.len != s.live - settled) return error.InvalidExecution;
    var listed: u64 = 0;
    for (record.waiting, 0..) |entry, index| {
        try charge(work, budget);
        if (index != 0 and entry.task <= record.waiting[index - 1].task) return error.InvalidExecution;
        // Each listed task waits for ever at a site, and is one the replay has waiting there,
        // for the same thing.
        const found = s.tasks[s.slotOf(entry.task) orelse return error.InvalidExecution];
        if (found.state != .waiting) return error.InvalidExecution;
        // A wait at a frame's end (P3.4) is placed at the frame's result; a reaction's where its
        // node made it (RFC-0084, P4.4).
        const span = if (replayReactive(&found)) found.site_span else at_site: {
            const waited = execution.program.functions[found.site_function];
            break :at_site execution.program.function_nodes[waited.body.start + if (found.site_pc == waited.body.end - waited.body.start) waited.root else found.site_pc].node.span;
        };
        if (found.wake != replay_never or entry.kind != found.kind or entry.wait != found.waits or !std.meta.eql(entry.span, span)) return error.InvalidExecution;
        listed += 1;
    }
    if (listed != s.live - settled) return error.InvalidExecution;
}

/// Whether the replay keeps a scheduler: the program spawns, or builds or signals events
/// (P3.2), whose signals a region holds like its starts.
fn replayScheduled(program: types.Program) bool {
    for (program.nodes) |node| if (node.kind == .spawn or node.kind == .event_new or node.kind == .event_signal or node.kind == .reaction or node.kind == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .spawn or entry.node.kind == .event_new or entry.node.kind == .event_signal or entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}

/// Whether the program makes tasks: it spawns, or from RFC-0084 P4.4 holds a reaction, or from
/// P4.6 an `Await` of a guard, as the amendment to RFC-0082 C4 says.
fn replayTasks(program: types.Program) bool {
    for (program.nodes) |node| if (node.kind == .spawn or node.kind == .reaction or node.kind == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .spawn or entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}

/// The task whose visits are on top: the one whose entry visit is highest.
fn replayTaskAt(frames: []const CallVisit, depth: usize) u32 {
    var at = depth;
    while (at != 0) {
        at -= 1;
        if (frames[at].task != replay_none) return frames[at].task;
    }
    unreachable;
}

/// What a binding is reported as: its root value, or for a `var` of a program that spawns tasks
/// (RFC-0082), the cell's final value, admitted against the replay's own cells.
/// TASK-0109, W4.4: public for the embedding API, which reads a binding's value as a report does.
pub fn bindingValue(execution: evaluator.Execution, binding: types.Binding) types.Value {
    const node = execution.program.nodes[binding.node];
    // RFC-0087, P5.4 (W8): a keyed cell's binding is its declaration; it is reported as the
    // cell ended, which every program with one records.
    if (node.kind == .weak_init and execution.cells.len != 0 and std.meta.eql(execution.program.source_cells[node.kind.weak_init].name, binding.name)) {
        const cell = execution.cells[node.kind.weak_init];
        return if (cell.initialized) cell.value else execution.values[binding.node];
    }
    if (execution.cells.len == 0 or node.kind != .cell_read) return execution.values[binding.node];
    // The binding of the `var` itself, not another name bound to what the root read of it.
    if (!std.meta.eql(execution.program.source_cells[node.kind.cell_read].name, binding.name)) return execution.values[binding.node];
    const cell = execution.cells[node.kind.cell_read];
    return if (cell.initialized) cell.value else execution.values[binding.node];
}

// Live variables (RFC-0084, P4.1): the report replay's own reading of rules L1 to L7, written
// from the RFC apart from both machines. It keeps its own links (of the program's cells, with
// an image per open region, as the source replay keeps their values), its own entries, stamps,
// count of valid entries, heights in the records it builds, and dirty set; it predicts which
// record each `live_eval` step evaluates, runs the guard's frame as the run did, and requires
// each `live_settle` to say what its own stability test says. A run whose propagation would
// have reached a bound has no report: such a run here is refused.

const LiveReplayEntry = struct { cell: u32, record: u32, stamp: u64, earlier: u32, later: u32, on_list: bool };
const LiveReplayMark = struct { valid: u64, stamp: u64, log: u32 };
const LiveRunState = struct {
    active: bool = false,
    /// How many frames are below the guards it runs: those of the node that wrote.
    base: usize = 0,
    phase: enum { next, eval, frame, settle } = .next,
    /// An establishing write (L2) of `cell`, whose record is built after its guard ran.
    establish: bool = false,
    cell: u32 = 0,
    initialize: bool = false,
    origin: i64 = 0,
    /// The target's type, and its instance (a field's, P4.2) or none (a module cell's), and
    /// its place there.
    target_type: types.Type = .i64,
    owner: ?types.ObjectRef = null,
    place: u32 = 0,
    /// The record being evaluated, its guard, and what the guard gave.
    record: u32 = 0,
    guard: types.CallableValue = undefined,
    result: types.Value = undefined,
    /// What an establishing write wrote: the value of its node.
    established: types.Value = .{ .integer = 0 },
    total: u64 = 0,
    /// A guard at the root begins in the window after the one with its `live_eval`.
    waited: bool = false,
};
/// Its stores grow as the run it replays used them, from nothing: a report of a run that made
/// few records and entries costs memory for those (RFC-0084 C17).
const LiveReplay = struct {
    on: bool = false,
    /// P4.4: whether the program holds a `reaction`, whose drains take one turn at a time.
    reacts: bool = false,
    count: u32 = 0,
    links: []u32 = &.{},
    /// The links as each open region found them, a row per depth; rows are added as needed.
    images: []u32 = &.{},
    entries: []LiveReplayEntry = &.{},
    entry_count: u32 = 0,
    /// Entries taken off their lists in open regions that a rollback revives, in order.
    log: []u32 = &.{},
    log_count: u32 = 0,
    /// Per cell of the run (the program's, then the instances'), below `known`.
    first: []u32 = &.{},
    last: []u32 = &.{},
    seen: []u64 = &.{},
    heap_at: []u32 = &.{},
    tally: []u64 = &.{},
    waiting: []bool = &.{},
    known: u32 = 0,
    heap: []u32 = &.{},
    heap_count: u32 = 0,
    queue: []u32 = &.{},
    queue_head: u32 = 0,
    queue_count: u32 = 0,
    reads: []u32 = &.{},
    read_count: u32 = 0,
    tracking: bool = false,
    valid: u64 = 0,
    stamp: u64 = 0,
    marks: [types.limits.source_frames]LiveReplayMark = undefined,
    fresh: bool = false,
    comparable: []bool = &.{},
    record: types.Live = .{},
    propagation: u64 = 0,
    run: LiveRunState = .{},
    /// The bytes its stores hold.
    bytes: usize = 0,

    /// The links of instance cells (P4.2), by their place among them; grown as fields are
    /// attached to. A region's undo records restore them (`Held.link`).
    object_links: []u32 = &.{},
    /// RFC-0084, P4.4: per task slot of the replay, the stamp of a waiting reaction's latest
    /// evaluation (0 for none), the entries it recorded and whether it is notified; the notified
    /// reactions in order, as a ring of slots with a mark per region that notified; the firings
    /// on the visit stack; and the delivery loop with its deliveries. Grown as reactions come.
    watch_stamp: []u64 = &.{},
    watch_entries: []u64 = &.{},
    watch_pending: []bool = &.{},
    notified: []u32 = &.{},
    notified_from: u64 = 0,
    notified_to: u64 = 0,
    notified_marks: []ReplayMark = &.{},
    notified_mark_count: u32 = 0,
    firing: u32 = 0,
    delivering: bool = false,
    delivered: u64 = 0,
    /// RFC-0084, P4.5: the bodies of `Batch{...}` open on the visit stack.
    batches: u32 = 0,
    /// The replay's own drive of reactions (`reactDrive`).
    react: ReactState = .{},

    const room = types.limits.live_edges + types.limits.live_edges / 2 + 64;
    const ids = types.limits.source_cells + types.limits.object_cells;

    fn objectLink(self: *const LiveReplay, index: u32) u32 {
        return if (index < self.object_links.len) self.object_links[index] else replay_none;
    }
    fn restoreObjectLink(self: *LiveReplay, index: u32, link: u32) void {
        if (index < self.object_links.len) self.object_links[index] = link else std.debug.assert(link == replay_none);
    }
    fn clearObjectLinks(self: *LiveReplay, first: u32, count: u32) void {
        if (first >= self.object_links.len) return;
        @memset(self.object_links[first..@min(self.object_links.len, first + count)], replay_none);
    }
    /// The link of a cell of the run: a program cell's, or an instance cell's.
    fn linkAt(self: *const LiveReplay, cell: u32) u32 {
        return if (cell < self.count) self.links[cell] else self.objectLink(cell - self.count);
    }
    /// Sets a cell's link. An instance cell's goes in the region's undo record for the cell, as
    /// a write's would; a program cell's in the images regions take of the links.
    fn linkTo(self: *LiveReplay, source: *SourceReplay, cell: u32, record: u32) Error!void {
        if (cell < self.count) {
            self.links[cell] = record;
            return;
        }
        const index = cell - self.count;
        if (index >= source.object_count) return error.InvalidExecution;
        try source.hold(cell, source.objects[index]);
        if (index >= self.object_links.len) {
            const known = self.object_links.len;
            self.object_links = try self.grown(u32, self.object_links, known, @as(usize, index) + 1, 256, types.limits.object_cells);
            @memset(self.object_links[known..], replay_none);
        }
        self.object_links[index] = record;
    }
    /// Reclamation: the links of the instance cells that stay close up with them, and every
    /// link names its record where it will be. `first` is the first instance cell above the
    /// frame's mark, `mark` that cell's id.
    fn moveObjectLinks(self: *LiveReplay, first: u32, mark: u32, places: []const u32) Error!void {
        const links = self.object_links;
        for (links[0..@min(first, links.len)]) |*link| {
            if (link.* == replay_none or link.* < mark) continue;
            const place = places[link.* - mark];
            if (place == 0) return error.InvalidExecution;
            link.* = mark + place - 1;
        }
        for (places, first..) |place, cell| {
            if (place == 0) continue;
            const to = first + place - 1;
            if (to >= links.len) continue;
            const link = if (cell < links.len) links[cell] else replay_none;
            links[to] = if (link == replay_none or link < mark) link else moved: {
                const moved_to = places[link - mark];
                if (moved_to == 0) return error.InvalidExecution;
                break :moved mark + moved_to - 1;
            };
        }
    }

    fn open(self: *LiveReplay, program: types.Program, count: usize) Error!void {
        self.on = true;
        self.reacts = holdsReaction(program);
        self.count = @intCast(count);
        self.links = scratch.alloc(u32, count) orelse return error.InvalidExecution;
        self.held(@sizeOf(u32) * count);
        @memset(self.links, replay_none);
        self.comparable = scratch.alloc(bool, program.definitions.len) orelse return error.InvalidExecution;
        self.held(program.definitions.len);
        catalogue.comparableTypes(program.definitions, program.fields, program.tuple_elements, self.comparable);
    }
    fn close(self: *LiveReplay) void {
        if (!self.on) return;
        inline for (.{ "links", "images", "entries", "log", "first", "last", "seen", "heap_at", "tally", "waiting", "heap", "queue", "reads", "comparable", "object_links", "watch_stamp", "watch_entries", "watch_pending", "notified", "notified_marks" }) |name| {
            const memory = @field(self, name);
            if (memory.len != 0) scratch.free(memory);
        }
        self.* = .{};
    }
    /// `memory` with room for `need` elements, its first `used` kept: twice what it had, or
    /// `need`, or `least`, whichever is most, but no more than `most`.
    fn grown(self: *LiveReplay, comptime T: type, memory: []T, used: usize, need: usize, least: usize, most: usize) Error![]T {
        if (need <= memory.len) return memory;
        if (need > most) return error.InvalidExecution;
        const size = @min(most, @max(need, 2 * memory.len, least));
        const larger = scratch.alloc(T, size) orelse return error.InvalidExecution;
        self.held(@sizeOf(T) * size);
        @memcpy(larger[0..used], memory[0..used]);
        if (memory.len != 0) scratch.free(memory);
        self.bytes -= @sizeOf(T) * memory.len;
        return larger;
    }
    /// Counts memory taken, and the most held at once (`Stats.live_bytes`).
    fn held(self: *LiveReplay, bytes: usize) void {
        self.bytes += bytes;
        live_peak = @max(live_peak, self.bytes);
    }
    fn know(self: *LiveReplay, id: u32) Error!void {
        if (id >= ids) return error.InvalidExecution;
        if (id >= self.first.len) {
            // Only between raises: the worklist is empty.
            if (self.queue_count != 0) return error.InvalidExecution;
            const need = @as(usize, id) + 1;
            const known = self.known;
            self.first = try self.grown(u32, self.first, known, need, 256, ids);
            self.last = try self.grown(u32, self.last, known, need, 256, ids);
            self.seen = try self.grown(u64, self.seen, known, need, 256, ids);
            self.heap_at = try self.grown(u32, self.heap_at, known, need, 256, ids);
            self.tally = try self.grown(u64, self.tally, known, need, 256, ids);
            self.waiting = try self.grown(bool, self.waiting, known, need, 256, ids);
            self.reads = try self.grown(u32, self.reads, self.read_count, need, 256, ids);
            // A record is a cell of the run, so these hold every record.
            self.heap = try self.grown(u32, self.heap, self.heap_count, need, 256, ids);
            self.queue = try self.grown(u32, self.queue, 0, need, 256, ids);
        }
        while (self.known <= id) : (self.known += 1) {
            self.first[self.known] = replay_none;
            self.last[self.known] = replay_none;
            self.seen[self.known] = 0;
            self.heap_at[self.known] = replay_none;
            self.tally[self.known] = 0;
            self.waiting[self.known] = false;
        }
    }
    fn regionBegin(self: *LiveReplay, depth: usize, work: *u64, budget: u64) Error!void {
        self.marks[depth] = .{ .valid = self.valid, .stamp = self.stamp, .log = self.log_count };
        self.images = try self.grown(u32, self.images, @min(self.images.len, depth * self.count), (depth + 1) * self.count, 4 * self.count, types.limits.source_frames * self.count);
        for (self.links, self.images[depth * self.count ..][0..self.count]) |link, *copy| {
            try charge(work, budget);
            copy.* = link;
        }
        if (depth == 1) self.fresh = true;
    }
    fn regionAbort(self: *LiveReplay, depth: usize, work: *u64, budget: u64) Error!void {
        self.valid = self.marks[depth].valid;
        for (self.links, self.images[depth * self.count ..][0..self.count]) |*link, copy| {
            try charge(work, budget);
            link.* = copy;
        }
        // Every entry the region recorded carries a stamp issued since it began (R1).
        while (self.entry_count != 0 and self.entries[self.entry_count - 1].stamp > self.marks[depth].stamp) {
            self.entry_count -= 1;
            if (!self.entries[self.entry_count].on_list) continue;
            if (self.last[self.entries[self.entry_count].cell] != self.entry_count) return error.InvalidExecution;
            self.unchain(self.entry_count);
        }
        // What it took off the lists comes back, the last taken first.
        while (self.log_count > self.marks[depth].log) {
            self.log_count -= 1;
            const index = self.log[self.log_count];
            if (index < self.entry_count) try self.rechain(index);
        }
    }
    fn recordCell(source: *const SourceReplay, record: u32, index: u32) Error!types.Value {
        if (record < source.count or record - source.count + index >= source.object_count) return error.InvalidExecution;
        return source.objects[record - source.count + index] orelse error.InvalidExecution;
    }
    fn integerOf(source: *const SourceReplay, record: u32, index: u32) Error!u64 {
        const value = try recordCell(source, record, index);
        if (value != .integer or value.integer < 0) return error.InvalidExecution;
        return @intCast(value.integer);
    }
    /// A record's target: a cell of the program, for a record that owns itself, or field
    /// `place` of the instance that owns it (P4.2), counted as the run counts cells.
    fn target(source: *const SourceReplay, record: u32) Error!u32 {
        const owner = try recordCell(source, record, catalogue.live_owner);
        const place = try integerOf(source, record, catalogue.live_place);
        if (owner != .object) return error.InvalidExecution;
        if (owner.object.id == record) {
            if (place >= source.count) return error.InvalidExecution;
            return @intCast(place);
        }
        if (place > types.limits.record_fields) return error.InvalidExecution;
        return @intCast(source.count + try source.objectCell(owner.object, @intCast(place)));
    }
    fn holds(self: *const LiveReplay, source: *const SourceReplay, entry: LiveReplayEntry) Error!bool {
        // A reaction's entry holds while it waits on its guard with that stamp (P4.4).
        if (entry.record & watched != 0) return (entry.record & ~watched) < self.watch_stamp.len and self.watch_stamp[entry.record & ~watched] == entry.stamp;
        if (try integerOf(source, entry.record, catalogue.live_stamp) != entry.stamp) return false;
        return self.linkAt(try target(source, entry.record)) == entry.record;
    }
    /// The value of a cell of the run, and a write of it, which a region journals.
    fn cellValue(source: *const SourceReplay, cell: u32) Error!types.Value {
        if (cell < source.count) return source.read(cell);
        if (cell - source.count >= source.object_count) return error.InvalidExecution;
        return source.objects[cell - source.count] orelse error.InvalidExecution;
    }
    fn writeCell(source: *SourceReplay, cell: u32, value: types.Value) Error!void {
        if (cell < source.count) return source.write(cell, value, false);
        const index = cell - source.count;
        if (index >= source.object_count or source.depth == 0) return error.InvalidExecution;
        try source.hold(cell, source.objects[index]);
        source.objects[index] = value;
    }
    fn from(self: *const LiveReplay, stamp: u64) u32 {
        var low: u32 = 0;
        var high: u32 = self.entry_count;
        while (low != high) {
            const middle = low + (high - low) / 2;
            if (self.entries[middle].stamp < stamp) low = middle + 1 else high = middle;
        }
        return low;
    }
    fn entriesOf(self: *const LiveReplay, source: *const SourceReplay, record: u32) Error!u64 {
        const stamp = try integerOf(source, record, catalogue.live_stamp);
        if (stamp == 0) return 0;
        return self.from(stamp + 1) - self.from(stamp);
    }
    fn chain(self: *LiveReplay, index: u32) Error!void {
        const cell = self.entries[index].cell;
        try self.know(cell);
        self.entries[index].earlier = self.last[cell];
        self.entries[index].later = replay_none;
        self.entries[index].on_list = true;
        if (self.last[cell] == replay_none) self.first[cell] = index else self.entries[self.last[cell]].later = index;
        self.last[cell] = index;
    }
    fn unchain(self: *LiveReplay, index: u32) void {
        const entry = &self.entries[index];
        if (entry.earlier == replay_none) self.first[entry.cell] = entry.later else self.entries[entry.earlier].later = entry.later;
        if (entry.later == replay_none) self.last[entry.cell] = entry.earlier else self.entries[entry.later].earlier = entry.earlier;
        entry.on_list = false;
    }
    /// Puts a revived entry back after the one it followed, which is on its list again.
    fn rechain(self: *LiveReplay, index: u32) Error!void {
        const entry = &self.entries[index];
        if (entry.on_list or (entry.earlier != replay_none and !self.entries[entry.earlier].on_list)) return error.InvalidExecution;
        const later = if (entry.earlier == replay_none) self.first[entry.cell] else self.entries[entry.earlier].later;
        entry.later = later;
        if (entry.earlier == replay_none) self.first[entry.cell] = index else self.entries[entry.earlier].later = index;
        if (later == replay_none) self.last[entry.cell] = index else self.entries[later].earlier = index;
        entry.on_list = true;
    }
    /// The entries of the evaluation that took `stamp` stop being valid (C16): off their
    /// lists, and logged when a rollback of the innermost open region would revive them.
    fn release(self: *LiveReplay, depth: usize, stamp: u64) Error!void {
        const revives = depth > 1 and stamp <= self.marks[depth - 1].stamp;
        var index = self.from(stamp);
        while (index < self.entry_count and self.entries[index].stamp == stamp) : (index += 1) {
            if (!self.entries[index].on_list) return error.InvalidExecution;
            self.unchain(index);
            if (!revives) continue;
            self.log = try self.grown(u32, self.log, self.log_count, self.log_count + 1, 256, room);
            self.log[self.log_count] = index;
            self.log_count += 1;
        }
    }
    /// The record attached to a cell leaves it (L2): its entries stop counting.
    fn detach(self: *LiveReplay, source: *const SourceReplay, record: u32) Error!void {
        self.valid -= try self.entriesOf(source, record);
        try self.release(source.depth, try integerOf(source, record, catalogue.live_stamp));
    }
    fn sweep(self: *LiveReplay, source: *const SourceReplay) Error!void {
        var kept: u32 = 0;
        for (0..self.entry_count) |index| {
            const entry = self.entries[index];
            if (!entry.on_list) continue;
            if (!try self.holds(source, entry)) return error.InvalidExecution;
            self.entries[kept] = entry;
            kept += 1;
        }
        for (self.entries[0..kept]) |entry| {
            self.first[entry.cell] = replay_none;
            self.last[entry.cell] = replay_none;
        }
        for (0..kept) |index| try self.chain(@intCast(index));
        self.entry_count = kept;
        if (kept != self.valid) return error.InvalidExecution;
    }
    /// Before a live operation: where no entry taken off can come back, the log is forgotten
    /// and the store swept when its unlisted entries outnumber half the valid ones plus 32.
    fn tidy(self: *LiveReplay, source: *const SourceReplay) Error!void {
        const fresh = self.fresh;
        self.fresh = false;
        if (source.depth > 1 and !fresh) return;
        self.forget(source.depth);
        if (2 * (self.entry_count - self.valid) > self.valid + 64) try self.sweep(source);
    }
    fn forget(self: *LiveReplay, depth: usize) void {
        if (self.log_count == 0) return;
        self.log_count = 0;
        for (self.marks[0..depth]) |*mark| mark.log = 0;
    }
    fn required(self: *const LiveReplay, depth: usize, old: u64, n: u64) u64 {
        if (depth <= 1) return self.valid - old + n;
        return self.marks[1].valid + (self.entry_count - self.from(self.marks[1].stamp + 1)) + n;
    }
    fn measure(self: *const LiveReplay, depth: usize) u64 {
        if (!self.on) return 0;
        return self.required(depth, 0, 0);
    }
    fn track(self: *LiveReplay, cell: u32) Error!void {
        try self.know(cell);
        if (self.seen[cell] == self.stamp) return;
        self.seen[cell] = self.stamp;
        self.reads[self.read_count] = cell;
        self.read_count += 1;
    }
    /// The bound, then the entries of the evaluation of `record` that took the latest stamp;
    /// those of its evaluation that took `previous` (0 for none) leave their lists.
    fn record_reads(self: *LiveReplay, source: *const SourceReplay, record: u32, previous: u64, old: u64) Error!void {
        const n = self.read_count;
        if (self.required(source.depth, old, n) > types.limits.live_edges) return error.InvalidExecution;
        if (previous != 0) try self.release(source.depth, previous);
        // Off their lists, the old entries no longer count, also for a sweep here.
        self.valid -= old;
        if (self.entry_count + n > room) {
            if (source.depth > 1) return error.InvalidExecution;
            try self.sweep(source);
        }
        self.entries = try self.grown(LiveReplayEntry, self.entries, self.entry_count, self.entry_count + n, 256, room);
        // A reaction's bookkeeping is its slot's (P4.4).
        if (record & watched == 0) try self.know(record);
        for (self.reads[0..n]) |cell| {
            self.entries[self.entry_count] = .{ .cell = cell, .record = record, .stamp = self.stamp, .earlier = replay_none, .later = replay_none, .on_list = false };
            try self.chain(self.entry_count);
            self.entry_count += 1;
        }
        self.valid += n;
        self.record.entries += n;
    }
    fn heightFor(self: *const LiveReplay, source: *const SourceReplay, record: u32, own: u32) Error!u64 {
        var top: u64 = 0;
        for (self.reads[0..self.read_count]) |cell| {
            if (cell == own) continue;
            const link = self.linkAt(cell);
            if (link == replay_none or link == record) continue;
            top = @max(top, try integerOf(source, link, catalogue.live_height));
        }
        return @min(types.limits.live_height, top + 1);
    }
    fn earlier(source: *const SourceReplay, a: u32, b: u32) Error!bool {
        const ha = try integerOf(source, a, catalogue.live_height);
        const hb = try integerOf(source, b, catalogue.live_height);
        return ha < hb or (ha == hb and a < b);
    }
    fn heapSet(self: *LiveReplay, at: u32, record: u32) void {
        self.heap[at] = record;
        self.heap_at[record] = at;
    }
    fn heapUp(self: *LiveReplay, source: *const SourceReplay, start: u32) Error!void {
        var at = start;
        const record = self.heap[at];
        while (at != 0 and try earlier(source, record, self.heap[(at - 1) / 2])) {
            self.heapSet(at, self.heap[(at - 1) / 2]);
            at = (at - 1) / 2;
        }
        self.heapSet(at, record);
    }
    fn heapDown(self: *LiveReplay, source: *const SourceReplay, start: u32) Error!void {
        var at = start;
        const record = self.heap[at];
        while (2 * at + 1 < self.heap_count) {
            var child = 2 * at + 1;
            if (child + 1 < self.heap_count and try earlier(source, self.heap[child + 1], self.heap[child])) child += 1;
            if (!try earlier(source, self.heap[child], record)) break;
            self.heapSet(at, self.heap[child]);
            at = child;
        }
        self.heapSet(at, record);
    }
    /// The readers of `cell` become dirty, and the reactions among them are notified (N1, P4.4),
    /// in the order of the entries. Every entry on a list is valid.
    fn dirty(self: *LiveReplay, source: *const SourceReplay, cell: u32, work: *u64, budget: u64) Error!void {
        if (cell >= self.known) return;
        var at = self.first[cell];
        while (at != replay_none) {
            const entry = self.entries[at];
            at = entry.later;
            try charge(work, budget);
            if (!try self.holds(source, entry)) return error.InvalidExecution;
            if (entry.record & watched != 0) {
                try self.notify(entry.record & ~watched, source.effects.depth);
                continue;
            }
            if (self.heap_at[entry.record] != replay_none) continue;
            if (self.heap_count == self.heap.len) return error.InvalidExecution;
            self.heapSet(self.heap_count, entry.record);
            self.heap_count += 1;
            try self.heapUp(source, self.heap_count - 1);
        }
    }
    fn take(self: *LiveReplay, source: *const SourceReplay) Error!?u32 {
        if (self.heap_count == 0) return null;
        const record = self.heap[0];
        self.heap_at[record] = replay_none;
        self.heap_count -= 1;
        if (self.heap_count != 0) {
            self.heapSet(0, self.heap[self.heap_count]);
            try self.heapDown(source, 0);
        }
        return record;
    }
    fn raise(self: *LiveReplay, source: *SourceReplay, record: u32, work: *u64, budget: u64) Error!void {
        const ring: u32 = @intCast(self.queue.len);
        self.queue_head = 0;
        self.queue[0] = record;
        self.queue_count = 1;
        self.waiting[record] = true;
        while (self.queue_count != 0) {
            const raised = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % ring;
            self.queue_count -= 1;
            self.waiting[raised] = false;
            const height = try integerOf(source, raised, catalogue.live_height);
            const cell = try target(source, raised);
            if (cell >= self.known) continue;
            var at = self.first[cell];
            while (at != replay_none) {
                const entry = self.entries[at];
                at = entry.later;
                try charge(work, budget);
                if (!try self.holds(source, entry)) return error.InvalidExecution;
                // A reaction has no height (P4.4).
                if (entry.record & watched != 0) continue;
                const reader = entry.record;
                const current = try integerOf(source, reader, catalogue.live_height);
                if (current > height or current >= types.limits.live_height) continue;
                try source.objectWrite(try liveRecordRef(source, reader), catalogue.live_height - 1, .{ .integer = @intCast(@min(types.limits.live_height, height + 1)) });
                if (self.heap_at[reader] != replay_none) try self.heapDown(source, self.heap_at[reader]);
                if (self.waiting[reader]) continue;
                if (self.queue_count == ring) return error.InvalidExecution;
                self.queue[(self.queue_head + self.queue_count) % ring] = reader;
                self.queue_count += 1;
                self.waiting[reader] = true;
            }
        }
    }
    /// Reclamation: entries of cells or records that go are dropped, outside every region the
    /// unlisted ones too, and the rest renumbered by `places`. No listed entry may go, and a
    /// logged one stays where it is.
    fn relocate(self: *LiveReplay, source: *const SourceReplay, mark: u32, places: []const u32) Error!void {
        for (self.entries[0..self.entry_count]) |entry| if (entry.on_list) {
            self.first[entry.cell] = replay_none;
            self.last[entry.cell] = replay_none;
        };
        const outside = source.depth <= 1;
        if (outside or self.fresh) self.forget(source.depth) else {
            // What committed regions logged above the innermost region's mark: its rollback
            // drops those entries, so none is revived, and they may go now (C19).
            var logged: u32 = 0;
            for (self.log[0..self.log_count]) |index| {
                if (index >= self.entry_count) return error.InvalidExecution;
                if (self.entries[index].stamp > self.marks[source.depth - 1].stamp) continue;
                self.log[logged] = index;
                logged += 1;
            }
            self.log_count = logged;
        }
        var kept: u32 = 0;
        for (0..self.entry_count) |index| {
            var entry = self.entries[index];
            const reaction = entry.record & watched != 0;
            const cell_goes = entry.cell >= mark and (entry.cell - mark >= places.len or places[entry.cell - mark] == 0);
            const record_goes = !reaction and entry.record >= mark and (entry.record - mark >= places.len or places[entry.record - mark] == 0);
            if (cell_goes or record_goes or (outside and !entry.on_list)) {
                // A valid entry goes only with its record and its cell: a field's record that
                // nothing reaches (P4.2, C23, C24). It was recorded after every open region began.
                // A reaction's goes with its cell, which nothing reaches any more (C49).
                if (entry.on_list) {
                    if (reaction) {
                        if (!cell_goes) return error.InvalidExecution;
                    } else if (!record_goes or !cell_goes or (!outside and entry.stamp <= self.marks[source.depth - 1].stamp)) return error.InvalidExecution;
                    self.valid -= 1;
                }
                continue;
            }
            if (entry.cell >= mark) entry.cell = mark + places[entry.cell - mark] - 1;
            if (!reaction and entry.record >= mark) entry.record = mark + places[entry.record - mark] - 1;
            self.entries[kept] = entry;
            kept += 1;
        }
        for (self.log[0..self.log_count]) |index| if (index >= kept or self.entries[index].stamp > self.marks[source.depth - 1].stamp) return error.InvalidExecution;
        self.entry_count = kept;
        for (0..kept) |index| if (self.entries[index].on_list) try self.chain(@intCast(index));
    }

    // RFC-0084, P4.4: reactions, in the replay's words.

    /// A slot of the replay's scheduler takes a new reaction: no entries, not notified.
    fn watchFresh(self: *LiveReplay, slot: u32) Error!void {
        if (slot >= self.watch_stamp.len) {
            const known = self.watch_stamp.len;
            const need = @as(usize, slot) + 1;
            self.watch_stamp = try self.grown(u64, self.watch_stamp, known, need, 64, types.limits.tasks);
            self.watch_entries = try self.grown(u64, self.watch_entries, known, need, 64, types.limits.tasks);
            self.watch_pending = try self.grown(bool, self.watch_pending, known, need, 64, types.limits.tasks);
        }
        self.watch_stamp[slot] = 0;
        self.watch_entries[slot] = 0;
        self.watch_pending[slot] = false;
    }
    /// The entries of the latest evaluation of a waiting reaction still in the store.
    fn watchHeld(self: *const LiveReplay, slot: u32) u64 {
        const stamp = self.watch_stamp[slot];
        if (stamp == 0) return 0;
        return self.from(stamp + 1) - self.from(stamp);
    }
    /// The reaction in `slot` waits on its guard with what the evaluation that took the latest
    /// stamp read; a run that would have reached `live_edge_limit` here has no report.
    fn watchRecord(self: *LiveReplay, source: *const SourceReplay, slot: u32) Error!void {
        const n = self.read_count;
        try self.record_reads(source, watched | slot, self.watch_stamp[slot], self.watchHeld(slot));
        self.watch_stamp[slot] = self.stamp;
        self.watch_entries[slot] = n;
    }
    /// The reaction in `slot` stops waiting, to fire.
    fn watchRelease(self: *LiveReplay, source: *const SourceReplay, slot: u32) Error!void {
        const kept = self.watchHeld(slot);
        if (self.watch_stamp[slot] != 0) try self.release(source.depth, self.watch_stamp[slot]);
        self.valid -= kept;
        self.watch_stamp[slot] = 0;
        self.watch_entries[slot] = 0;
    }
    fn notify(self: *LiveReplay, slot: u32, depth: u32) Error!void {
        if (slot >= self.watch_pending.len) return error.InvalidExecution;
        if (self.watch_pending[slot]) return;
        if (self.notified_to - self.notified_from == types.limits.tasks) return error.InvalidExecution;
        if (depth != 0 and (self.notified_mark_count == 0 or self.notified_marks[self.notified_mark_count - 1].depth != depth)) {
            self.notified_marks = try self.grown(ReplayMark, self.notified_marks, self.notified_mark_count, self.notified_mark_count + 1, 64, types.limits.tasks);
            self.notified_marks[self.notified_mark_count] = .{ .depth = depth, .count = self.notified_to };
            self.notified_mark_count += 1;
        }
        // The ring holds what is notified in order; it is laid out again when it grows.
        try self.notifiedRoom();
        self.notified[self.notified_to % self.notified.len] = slot;
        self.notified_to += 1;
        self.watch_pending[slot] = true;
    }
    /// Room in the ring for one more: when it is full it doubles, its entries kept in order.
    fn notifiedRoom(self: *LiveReplay) Error!void {
        const count = self.notified_to - self.notified_from;
        if (count < self.notified.len) return;
        const old = self.notified;
        const size: usize = @min(types.limits.tasks, @max(64, 2 * old.len));
        if (count >= size) return error.InvalidExecution;
        const larger = scratch.alloc(u32, size) orelse return error.InvalidExecution;
        self.held(@sizeOf(u32) * size);
        var at = self.notified_from;
        while (at < self.notified_to) : (at += 1) larger[(at - self.notified_from)] = old[at % old.len];
        if (old.len != 0) scratch.free(old);
        self.bytes -= @sizeOf(u32) * old.len;
        // Renumbered from zero: the marks count from the same place.
        for (self.notified_marks[0..self.notified_mark_count]) |*mark| mark.count -= self.notified_from;
        self.notified_to -= self.notified_from;
        self.notified_from = 0;
        self.notified = larger;
    }
    fn notifiedCommit(self: *LiveReplay, closing: u32) void {
        if (self.notified_mark_count == 0 or self.notified_marks[self.notified_mark_count - 1].depth != closing) return;
        if (closing == 1 or (self.notified_mark_count > 1 and self.notified_marks[self.notified_mark_count - 2].depth == closing - 1)) {
            self.notified_mark_count -= 1;
        } else self.notified_marks[self.notified_mark_count - 1].depth = closing - 1;
    }
    fn notifiedAbort(self: *LiveReplay, closing: u32) Error!void {
        if (self.notified_mark_count == 0 or self.notified_marks[self.notified_mark_count - 1].depth != closing) return;
        self.notified_mark_count -= 1;
        const keep = self.notified_marks[self.notified_mark_count].count;
        if (keep < self.notified_from or keep >= self.notified_to) return error.InvalidExecution;
        while (self.notified_to > keep) {
            self.notified_to -= 1;
            self.watch_pending[self.notified[self.notified_to % self.notified.len]] = false;
        }
    }
    fn takeNotified(self: *LiveReplay) ?u32 {
        if (self.notified_from == self.notified_to) return null;
        const slot = self.notified[self.notified_from % self.notified.len];
        self.notified_from += 1;
        self.watch_pending[slot] = false;
        return slot;
    }
    /// Whether a delivery point delivers now (N3).
    fn deliverable(self: *const LiveReplay, depth: u32) bool {
        return self.on and depth == 0 and self.firing == 0 and self.batches == 0 and !self.tracking and !self.delivering and self.notified_from != self.notified_to and self.notified_mark_count == 0;
    }
};

/// What fired a reaction's body (RFC-0084, P4.4): its node, the delivery loop, or a drain.
const ReplayFiring = enum { node, loop, start };
/// RFC-0084, P4.4: an entry whose dependent is a reaction names the replay's task slot with this
/// bit; a record is a cell of the run, which lies below it.
const watched: u32 = 1 << 31;

/// Where the replay's drive of reactions stands (`reactDrive`), at `base` visits: a step to
/// read, a guard's frame running, what follows an evaluation, the delivery loop, a drain's next
/// turn, a delivery point. `slot` is the reaction it is about, `why` what its evaluation is for.
const ReactState = struct {
    phase: enum { idle, observe, guard, observed, fire, after_body, point, loop, continue_drain, drain_turn } = .idle,
    base: usize = 0,
    slot: u32 = 0,
    /// P4.6 adds `site`: the guard of an `Await` (`guard`), whose value when it holds (`value`)
    /// the site at `base` visits yields.
    why: enum { node, drain, root_start, loop, when, site } = .node,
    guard: types.CallableValue = undefined,
    value: types.Value = .{ .boolean = false },
    succeeded: bool = false,
    /// A step at the root was read in the window before the frame it leads to begins.
    waited: bool = false,
    /// What fired the body that has just returned, and the handle of its reaction.
    by: ReplayFiring = .loop,
    handle: types.Value = .{ .boolean = false },
};

/// A `reaction` replayed: a slot, the next sequence and the handle the run must have built, its
/// guard and body kept in the slot.
fn replayReaction(program: types.Program, source: *SourceReplay, handle_type: types.Type, r: types.Reaction, guard: types.Value, body: types.Value, origin: u32, span: types.Span) Error!u32 {
    if (guard != .callable or body != .callable) return error.InvalidExecution;
    const slot = try replaySpawn(program, source, handle_type, guard, origin);
    const task = &source.tasks.tasks[slot];
    task.kind = if (r.kind == .upon) .upon else .when;
    task.body = body;
    task.site_span = span;
    try source.live.watchFresh(slot);
    return slot;
}
/// A reaction starts (N5): it waits on its guard, which is evaluated next.
fn replayReactionStart(source: *SourceReplay, slot: u32, base: usize, why: @FieldType(ReactState, "why")) Error!void {
    if (source.effects.depth != 0 or source.live.react.phase != .idle) return error.InvalidExecution;
    const task = &source.tasks.tasks[slot];
    source.tasks.created += 1;
    task.state = .waiting;
    task.waits = .guard;
    task.wake = replay_never;
    source.live.react = .{ .phase = .observe, .base = base, .slot = slot, .why = why };
}
fn replayReactive(task: *const ReplayTask) bool {
    return task.kind == .upon or task.kind == .when;
}
/// A delivery point of the replay at `base` visits (N3).
fn replayPoint(source: *SourceReplay, base: usize) Error!void {
    // A commit inside a guard, or with nothing pending, delivers nothing.
    if (!source.live.deliverable(source.effects.depth)) return;
    if (source.live.react.phase != .idle) return error.InvalidExecution;
    source.live.react = .{ .phase = .point, .base = base };
}

/// One move of the replay's drive of reactions (RFC-0084, P4.4), at `react.base` visits: it reads
/// the steps of reactions in the order the RFC gives them and requires each to be the one it
/// predicts: which reaction is delivered to, whether its guard holds, which fires and what
/// follows its body. Guards and bodies run as frames above, which the call replay drives.
fn reactDrive(execution: evaluator.Execution, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, prefix: u32, root_pc: u32, steps: []const types.CallStep, step: *usize, work: *u64, budget: u64) Error!enum { more, window, done } {
    const program = execution.program;
    const live = &source.live;
    const react = &live.react;
    const s = &source.tasks;
    if (!s.on) return error.InvalidExecution;
    switch (react.phase) {
        .idle, .guard => return error.InvalidExecution,
        .observe => {
            const task = &s.tasks[react.slot];
            if (react.why != .site and task.closure != .callable) return error.InvalidExecution;
            const guard = if (react.why == .site) react.guard else task.closure.callable;
            if (!react.waited) {
                if (step.* == steps.len) return .window;
                const event = steps[step.*];
                try charge(work, budget);
                if (event.kind != .observe or event.function != guard.function or event.pc != 0 or event.value != .integer or event.value.integer != @as(i64, @intCast(task.sequence))) return error.InvalidExecution;
                step.* += 1;
                try live.tidy(source);
                live.stamp += 1;
                live.tracking = true;
                live.read_count = 0;
                live.record.evaluations += 1;
                react.waited = true;
                // At the root the run sent its window once the guard's frame was pushed.
                if (react.base == 0 and source.streaming) return .window;
            }
            if (guard.function >= program.functions.len or guard.captures.end > prefix) return error.InvalidExecution;
            const f = program.functions[guard.function];
            if (f.parameter_count != guard.captures.end - guard.captures.start) return error.InvalidExecution;
            const size = f.body.end - f.body.start;
            if (depth.* == frames.len or size > source.trace_locals.len - used.*) return error.InvalidExecution;
            if (react.base == 0) source.string_used = program.strings.len;
            frames[depth.*] = .{ .function = guard.function, .base = used.*, .caller = null, .arguments = .{ .start = 0, .end = 0 }, .captures = guard.captures, .mark = prefix, .string_mark = std.math.cast(u32, source.string_used) orelse return error.InvalidExecution, .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = s.switches, .guard = true };
            used.* += size;
            depth.* += 1;
            react.waited = false;
            react.phase = .guard;
            return .more;
        },
        .observed => {
            live.tracking = false;
            try charge(work, budget);
            try live.tidy(source);
            try live.watchRecord(source, react.slot);
            const task = &s.tasks[react.slot];
            switch (react.why) {
                .node => {
                    if (react.succeeded) {
                        react.phase = .fire;
                        react.by = .node;
                        return .more;
                    }
                    // The node yields the handle, its step read where the frame goes on.
                    if (react.base != 0) frames[react.base - 1].returned = .{ .ok = task.handle };
                    react.phase = .idle;
                    return .done;
                },
                .drain, .root_start => {
                    if (react.succeeded) {
                        react.phase = .fire;
                        react.by = .start;
                        return .more;
                    }
                    if (react.why == .root_start) {
                        react.phase = .idle;
                        return .done;
                    }
                    react.phase = .drain_turn;
                    return .more;
                },
                .loop => {
                    if (react.succeeded) {
                        react.phase = .fire;
                        react.by = .loop;
                        return .more;
                    }
                    react.phase = .loop;
                    return .more;
                },
                // A `When` that ran its body waits on its guard again, whatever it gives (N4).
                .when => {
                    react.phase = .after_body;
                    react.by = task.fired_by;
                    react.handle = task.handle;
                    return .more;
                },
                // P4.6: an `Await` whose guard holds lets its entries go at once and yields its
                // value; one whose guard fails waits on it, its `suspend` read by its visit.
                .site => {
                    if (react.base == 0) return error.InvalidExecution;
                    const site = &frames[react.base - 1];
                    if (react.succeeded) {
                        try live.watchRelease(source, react.slot);
                        site.returned = .{ .ok = react.value };
                    } else site.expect = .guard_wait;
                    react.phase = .idle;
                    return .done;
                },
            }
        },
        .fire => {
            const task = &s.tasks[react.slot];
            if (task.body != .callable) return error.InvalidExecution;
            const body = task.body.callable;
            if (!react.waited) {
                if (step.* == steps.len) return .window;
                const event = steps[step.*];
                try charge(work, budget);
                if (event.kind != .fire or event.function != body.function or event.pc != 0 or event.value != .integer or event.value.integer != @as(i64, @intCast(task.sequence))) return error.InvalidExecution;
                step.* += 1;
                try live.tidy(source);
                try live.watchRelease(source, react.slot);
                live.record.firings += 1;
                task.state = .running;
                task.fired_by = react.by;
                react.waited = true;
                // At the root the body runs on the empty stack, which the run tells as a slice.
                if (react.base == 0 and source.streaming) return .window;
            }
            if (body.function >= program.functions.len or body.captures.end > prefix) return error.InvalidExecution;
            const f = program.functions[body.function];
            if (f.parameter_count != body.captures.end - body.captures.start) return error.InvalidExecution;
            const size = f.body.end - f.body.start;
            if (depth.* == frames.len or size > source.trace_locals.len - used.*) return error.InvalidExecution;
            if (react.base == 0) source.string_used = program.strings.len;
            frames[depth.*] = .{ .function = body.function, .base = used.*, .caller = null, .arguments = .{ .start = 0, .end = 0 }, .captures = body.captures, .mark = prefix, .string_mark = std.math.cast(u32, source.string_used) orelse return error.InvalidExecution, .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = s.switches, .task = react.slot, .handoff = react.by == .node and react.base != 0 };
            task.below = s.current;
            task.entry_at = @intCast(depth.*);
            s.current = react.slot;
            live.firing += 1;
            used.* += size;
            depth.* += 1;
            react.* = .{};
            return .more;
        },
        .after_body => {
            switch (react.by) {
                .loop => react.phase = .loop,
                .node => {
                    if (react.base != 0) {
                        // The node that made the reaction gets its handle, its step before what
                        // the delivery point after it delivers.
                        if (step.* == steps.len) return .window;
                        const event = steps[step.*];
                        const below = &frames[react.base - 1];
                        try charge(work, budget);
                        if (!below.pending or event.kind != .value or event.function != below.function or event.pc != below.pc or !sameValue(event.value, react.handle)) return error.InvalidExecution;
                        step.* += 1;
                        source.trace_locals[below.base + below.pc] = event.value;
                        below.pc += 1;
                        below.pending = false;
                    }
                    react.phase = .point;
                },
                .start => react.phase = .point,
            }
            return .more;
        },
        .point => {
            if (live.deliverable(source.effects.depth)) {
                live.delivering = true;
                live.delivered = 0;
                react.phase = .loop;
            } else react.phase = .continue_drain;
            return .more;
        },
        .loop => {
            if (live.notified_from == live.notified_to) {
                live.delivering = false;
                react.phase = .continue_drain;
                return .more;
            }
            if (step.* == steps.len) return .window;
            const event = steps[step.*];
            try charge(work, budget);
            const slot = live.takeNotified().?;
            const task = &s.tasks[slot];
            live.delivered += 1;
            // A run that reached `reaction_limit` has no report.
            if (live.delivered > types.limits.deliveries) return error.InvalidExecution;
            if (event.kind != .deliver or event.function != 0 or event.pc != 0 or event.value != .integer or event.value.integer != @as(i64, @intCast(task.sequence))) return error.InvalidExecution;
            step.* += 1;
            live.record.deliveries += 1;
            if (task.state == .settled and replayReactive(task)) {
                // P4.7: a reaction cancelled while this was pending gets nothing; its slot goes.
                s.release(slot);
            } else if (task.state == .waiting and task.waits == .guard and !replayReactive(task)) {
                // P4.6: a task at an `Await` stops waiting, its entries let go, and joins the
                // ready queue (S4); it evaluates its guard again when it runs (N7).
                try live.tidy(source);
                try live.watchRelease(source, slot);
                s.makeReady(slot, .{ .boolean = true });
            } else if (task.state == .waiting and task.waits == .guard) {
                react.slot = slot;
                react.why = .loop;
                react.phase = .observe;
            }
            return .more;
        },
        .continue_drain => {
            if (react.base == 0 or !frames[react.base - 1].drains) {
                react.phase = .idle;
                return .done;
            }
            react.phase = .drain_turn;
            return .more;
        },
        .drain_turn => {
            if (react.base == 0 or !frames[react.base - 1].drains or depth.* != react.base) return error.InvalidExecution;
            const slot = (try replayNextStart(source, root_pc)) orelse {
                frames[react.base - 1].drains = false;
                react.phase = .point;
                return .more;
            };
            if (replayReactive(&s.tasks[slot])) {
                const base = react.base;
                react.phase = .idle;
                try replayReactionStart(source, slot, base, .drain);
                return .more;
            }
            react.phase = .idle;
            try replayStart(execution, source, frames, depth, used, prefix, slot, false);
            return .done;
        },
    }
}

/// The type a record's header names: what the replay built it with.
fn liveRecordRef(source: *const SourceReplay, record: u32) Error!types.ObjectRef {
    const header = try LiveReplay.recordCell(source, record, 0);
    if (header != .integer or header.integer < 0 or header.integer > std.math.maxInt(u16)) return error.InvalidExecution;
    return .{ .value_type = @fromBackingInt(@intCast(header.integer)), .id = record };
}
/// The cell of the run a field is, counted as the machines count it.
fn liveFieldCell(source: *const SourceReplay, object: types.ObjectRef, index: u32) Error!u32 {
    return @intCast(source.count + try source.objectCell(object, index));
}
/// L2 for a field (P4.2): the write detaches the field's record, is made, and propagates.
fn liveFieldWrite(source: *SourceReplay, object: types.ObjectRef, index: u32, value: types.Value, depth: usize, work: *u64, budget: u64) Error!void {
    const live = &source.live;
    const cell = try liveFieldCell(source, object, index);
    const link = live.linkAt(cell);
    if (link != replay_none) {
        try live.tidy(source);
        try live.detach(source, link);
        try live.linkTo(source, cell, replay_none);
    }
    try source.objectWrite(object, index, value);
    try liveStartPropagation(source, cell, depth, work, budget);
}
/// L2, establishing, for field `c.field` of `object` (P4.2).
fn liveStartField(execution: evaluator.Execution, source: *SourceReplay, object: types.ObjectRef, c: types.ObjectLive, value_type: types.Type, closure: types.Value, origin: i64, depth: usize) Error!void {
    const live = &source.live;
    if (live.run.active or live.tracking or closure != .callable or closure.callable.function >= execution.program.functions.len) return error.InvalidExecution;
    const cell = try liveFieldCell(source, object, c.field);
    live.run = .{ .active = true, .base = depth, .phase = .eval, .establish = true, .cell = cell, .initialize = false, .origin = origin, .record = @intCast(source.count + source.object_count), .guard = closure.callable, .target_type = value_type, .owner = object, .place = c.field };
}
/// L2: a program write of a cell detaches its record, is made, and starts a propagation.
fn liveProgramWrite(source: *SourceReplay, cell: u32, value: types.Value, depth: usize, work: *u64, budget: u64) Error!void {
    const live = &source.live;
    if (cell >= source.count) return error.InvalidExecution;
    if (live.links[cell] != replay_none) {
        try live.tidy(source);
        try live.detach(source, live.links[cell]);
        live.links[cell] = replay_none;
    }
    try source.write(cell, value, false);
    try liveStartPropagation(source, cell, depth, work, budget);
}
fn liveStartPropagation(source: *SourceReplay, cell: u32, depth: usize, work: *u64, budget: u64) Error!void {
    const live = &source.live;
    if (live.run.active or live.tracking) return error.InvalidExecution;
    try live.tidy(source);
    live.propagation += 1;
    live.record.propagations += 1;
    live.run = .{ .active = true, .base = depth, .phase = .next };
    try live.dirty(source, cell, work, budget);
}
/// L2, establishing: the guard runs first; the record is the next instance.
fn liveStartEstablish(execution: evaluator.Execution, source: *SourceReplay, c: types.CellLive, closure: types.Value, origin: i64, depth: usize) Error!void {
    const live = &source.live;
    if (live.run.active or live.tracking or closure != .callable or c.cell >= source.count) return error.InvalidExecution;
    if (closure.callable.function >= execution.program.functions.len) return error.InvalidExecution;
    live.run = .{ .active = true, .base = depth, .phase = .eval, .establish = true, .cell = c.cell, .initialize = c.initialize, .origin = origin, .record = @intCast(source.count + source.object_count), .guard = closure.callable, .target_type = execution.program.source_cells[c.cell].value_type, .place = c.cell };
}
fn liveTypeOf(program: types.Program, target: types.Type) Error!types.Type {
    for (program.definitions, 0..) |item, index| if (item == .live and item.live == target) return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    return error.InvalidExecution;
}
/// One move of the propagation in progress, between the frames of its guards.
fn liveDrive(execution: evaluator.Execution, source: *SourceReplay, frames: []CallVisit, depth: *usize, used: *u32, prefix: u32, steps: []const types.CallStep, step: *usize, work: *u64, budget: u64) Error!enum { more, window, done } {
    const program = execution.program;
    const live = &source.live;
    const run = &live.run;
    switch (run.phase) {
        .next => {
            const record = (try live.take(source)) orelse {
                run.active = false;
                return .done;
            };
            // L7: a reported run reached neither bound, the per-record one checked first.
            const bits = 20;
            if (live.tally[record] >> bits != live.propagation) live.tally[record] = live.propagation << bits;
            live.tally[record] += 1;
            if (live.tally[record] & ((1 << bits) - 1) > types.limits.live_record_evaluations) return error.InvalidExecution;
            run.total += 1;
            if (run.total > types.limits.live_evaluations) return error.InvalidExecution;
            const guard = try LiveReplay.recordCell(source, record, catalogue.live_guard);
            if (guard != .callable) return error.InvalidExecution;
            run.record = record;
            run.guard = guard.callable;
            run.waited = false;
            run.phase = .eval;
            return .more;
        },
        .eval => {
            if (!run.waited) {
                if (step.* == steps.len) return .window;
                const event = steps[step.*];
                try charge(work, budget);
                const expected: types.ObjectRef = if (run.establish) .{ .value_type = try liveTypeOf(program, run.target_type), .id = run.record } else try liveRecordRef(source, run.record);
                if (event.kind != .live_eval or event.function != run.guard.function or event.pc != 0 or !sameValue(event.value, .{ .object = expected })) return error.InvalidExecution;
                step.* += 1;
                try live.tidy(source);
                live.stamp += 1;
                live.tracking = true;
                live.read_count = 0;
                live.record.evaluations += 1;
                run.waited = true;
                // At the root the run sent its window once the guard's frame was pushed, then
                // an empty one: the frame begins in the window after this one.
                if (run.base == 0 and source.streaming) return .window;
            }
            const f = program.functions[run.guard.function];
            if (run.guard.captures.end > prefix) return error.InvalidExecution;
            if (f.parameter_count != run.guard.captures.end - run.guard.captures.start) return error.InvalidExecution;
            const size = f.body.end - f.body.start;
            if (depth.* == frames.len or size > source.trace_locals.len - used.*) return error.InvalidExecution;
            if (run.base == 0) source.string_used = program.strings.len;
            frames[depth.*] = .{ .function = run.guard.function, .base = used.*, .caller = null, .arguments = .{ .start = 0, .end = 0 }, .captures = run.guard.captures, .mark = prefix, .string_mark = std.math.cast(u32, source.string_used) orelse return error.InvalidExecution, .cell_mark = if (source.tracked) @intCast(source.count + source.object_count) else 0, .switches = source.tasks.switches, .guard = true };
            used.* += size;
            depth.* += 1;
            run.phase = .frame;
            return .more;
        },
        .frame => return error.InvalidExecution,
        .settle => {
            if (step.* == steps.len) return .window;
            const event = steps[step.*];
            live.tracking = false;
            const f = program.functions[run.guard.function];
            if (run.establish) {
                if (event.kind != .live_settle or event.function != run.guard.function or event.pc != f.body.end - f.body.start or !sameValue(event.value, .{ .boolean = true })) return error.InvalidExecution;
                step.* += 1;
                try charge(work, budget);
                try live.tidy(source);
                const record_type = try liveTypeOf(program, run.target_type);
                const height = try live.heightFor(source, run.record, run.cell);
                const owner: types.ObjectRef = run.owner orelse .{ .value_type = record_type, .id = run.record };
                const built = try source.allocate(record_type, &.{ .{ .callable = run.guard }, .{ .integer = @intCast(live.stamp) }, .{ .integer = @intCast(height) }, .{ .object = owner }, .{ .integer = run.place }, .{ .integer = run.origin } });
                if (built.id != run.record) return error.InvalidExecution;
                live.record.records += 1;
                if (run.initialize) try source.write(run.cell, run.result, true);
                const earlier = live.linkAt(run.cell);
                if (earlier != replay_none) try live.detach(source, earlier);
                try live.linkTo(source, run.cell, run.record);
                try live.record_reads(source, run.record, 0, 0);
                try live.raise(source, run.record, work, budget);
                if (!run.initialize) try LiveReplay.writeCell(source, run.cell, run.result);
                const established = run.result;
                const cell = run.cell;
                const base = run.base;
                run.active = false;
                try liveStartPropagation(source, cell, base, work, budget);
                live.run.established = established;
                return .more;
            }
            try charge(work, budget);
            try live.tidy(source);
            const record = run.record;
            const old = try live.entriesOf(source, record);
            const ref = try liveRecordRef(source, record);
            const previous = try LiveReplay.integerOf(source, record, catalogue.live_stamp);
            try source.objectWrite(ref, catalogue.live_stamp - 1, .{ .integer = @intCast(live.stamp) });
            try live.record_reads(source, record, previous, old);
            const cell = try LiveReplay.target(source, record);
            try source.objectWrite(ref, catalogue.live_height - 1, .{ .integer = @intCast(try live.heightFor(source, record, cell)) });
            try live.raise(source, record, work, budget);
            // L6: a comparable value equal to the target's is not written.
            const target_type = catalogue.definition(ref.value_type, program.definitions).?.live;
            var stable = false;
            if (catalogue.comparableIn(target_type, live.comparable)) {
                var remaining = budget - work.*;
                stable = keys.equal(&key_work, execution.aggregate_values, run.result, try LiveReplay.cellValue(source, cell), &remaining) catch |err| return if (err == error.WorkLimit) error.ReportLimit else error.InvalidExecution;
                work.* = budget - remaining;
            }
            if (event.kind != .live_settle or event.function != run.guard.function or event.pc != f.body.end - f.body.start or !sameValue(event.value, .{ .boolean = !stable })) return error.InvalidExecution;
            step.* += 1;
            if (!stable) {
                try LiveReplay.writeCell(source, cell, run.result);
                try live.dirty(source, cell, work, budget);
            }
            run.phase = .next;
            return .more;
        },
    }
}

/// P4.4: whether a program holds a `reaction`, worked out from its nodes by the replay itself;
/// from P4.6 also an `await_guard`, whose notifications a drain delivers when it ends.
fn holdsReaction(program: types.Program) bool {
    for (program.nodes) |node| if (node.kind == .reaction or node.kind == .await_guard) return true;
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .reaction or entry.node.kind == .await_guard)) return true;
    return false;
}
