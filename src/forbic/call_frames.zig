//! Persistent, bounded scratch for the two independent call machines.
const std = @import("std");
const types = @import("types.zig");
const persist_json = @import("persist_json.zig");
pub const Result = union(enum) { ok: types.Value, language: types.CallFailure, failed: types.Diagnostic };
pub const Start = union(enum) { pushed, immediate: types.Value, failed: types.Diagnostic.Code };
pub const VmFrame = struct {
    function: u32,
    base: u32,
    pc: u32,
    arguments: types.Span,
    caller_base: ?u32,
    remaining_visits: u64 = 0,
    iteration_seed: types.Value = undefined,
    catchers: [types.limits.control_depth]u32 = undefined,
    catch_depth: u32 = 0,
    state_loop: bool = false,
    captures: types.Span = .{ .start = 0, .end = 0 },
    /// Members in use when the frame was pushed: everything it builds lies at or above this.
    mark: u32 = 0,
    /// The same for the bytes of the string pool and for the cells.
    string_mark: u32 = 0,
    cell_mark: u32 = 0,
    /// The run's switch count when the frame was pushed (RFC-0082): a frame end reclaims only
    /// if no other task ran since.
    switches: u64 = 0,
    /// The task whose entry frame this is, or `no_task`; and whether a `spawn` handed off to it
    /// from the frame below, whose register gets the handle when the task first leaves the stack.
    task: u32 = no_task,
    handoff: bool = false,
    /// Whether it committed starts that still take their turns, one after another.
    drains: bool = false,
    /// RFC-0084, P4.4: the node whose commit began that drain, where it delivers when it ends.
    drain_span: types.Span = .{ .start = 0, .end = 0 },
    /// RFC-0082, P3.4: the tasks it owns (its `Branch` tasks and the losers of its `Rush`es), the
    /// first and the last of a list threaded through the task table; and whether it ended by
    /// `cancel_exit` and waits for them before it ends cancelled.
    owned_first: u32 = no_task,
    owned_last: u32 = no_task,
    canceled_end: bool = false,
    /// RFC-0082, P3.9: while the frame stands at an `event_notify`, the subscription whose
    /// callback runs on top of it and the number below which its `Signal` calls subscriptions.
    /// A frame there is never saved: no callback suspends.
    notify_cursor: types.ObjectRef = undefined,
    notify_limit: i64 = 0,
};
/// Working memory of a reclamation beyond one entry per member, which each machine keeps in
/// its own form. It is storage only: each machine fills and reads it by its own rules, and
/// touches no more of it than the frame that ends has built.
pub const ReclaimWork = struct {
    /// The cells of a run: the program's own and at most `object_cells` of its instances.
    pub const cell_capacity = types.limits.source_cells + types.limits.object_cells;
    /// One entry per cell above the frame's mark, and one more.
    cells: [cell_capacity + 1]u32 = undefined,
    /// Members waiting to be examined; afterwards one entry per place a reachable string starts.
    /// Either is at most one per value that can name something: a member, a cell, a failure
    /// trace or the value the frame hands on, and (RFC-0082, P3.5) a suspended frame's register,
    /// seed or string mark.
    list: [types.limits.aggregate_elements + cell_capacity + types.limits.failure_traces + 2 + types.limits.saved_registers + 2 * types.limits.saved_frames]u32 = undefined,
    /// One bit per byte of the string pool above the frame's mark, and one for its end.
    starts: [types.limits.string_bytes / 64 + 2]u64 = undefined,
    /// Per word of `starts`, the bits set in the words before it.
    ranks: [types.limits.string_bytes / 64 + 2]u32 = undefined,
};
pub const VmStorage = struct {
    frames: [types.limits.call_depth]VmFrame = undefined,
    values: [types.limits.call_registers]types.Value = undefined,
    depth: u32 = 0,
    count: u32 = 0,
};
pub const ReferenceFrame = struct {
    function: u32,
    base: u32,
    cursor: u32,
    return_to: u32,
    remaining_visits: u64 = 0,
    parameters: [types.limits.parameters]types.Value = undefined,
    catchers: [types.limits.control_depth]u32 = undefined,
    catch_depth: u32 = 0,
    state_loop: bool = false,
};
pub const ReferenceStorage = struct {
    frames: [types.limits.call_depth]ReferenceFrame = undefined,
    values: [types.limits.call_registers]types.Value = undefined,
    depth: u32 = 0,
    count: u32 = 0,
    /// Per frame, the members in use when it was pushed: everything it builds lies at or above
    /// this. Beside the frames, which are copied whole when they are pushed.
    marks: [types.limits.call_depth]u32 = undefined,
    /// The same for the bytes of the string pool and for the cells.
    string_marks: [types.limits.call_depth]u32 = undefined,
    cell_marks: [types.limits.call_depth]u32 = undefined,
    /// Working memory of a reclamation: one entry per member above the mark, and one more.
    reclaim: [types.limits.aggregate_elements + 1]u32 = undefined,
    reclaim_work: ReclaimWork = .{},
    /// Per frame (RFC-0082): the run's switch count when it was pushed, the task whose entry
    /// frame it is (`no_task` for any other), and whether that task was handed off to by a
    /// `spawn` of the frame below, whose register it returns to.
    switch_marks: [types.limits.call_depth]u64 = undefined,
    task_marks: [types.limits.call_depth]u32 = undefined,
    handoffs: [types.limits.call_depth]bool = undefined,
    /// Per frame: whether it committed starts that still take their turns, one after another,
    /// each when the one before first leaves the stack.
    drains: [types.limits.call_depth]bool = undefined,
    /// Per frame (P4.4): the node whose commit began its drain, where the drain delivers.
    drain_spans: [types.limits.call_depth]types.Span = undefined,
    /// Per frame (P3.4): the first and the last task it owns, and whether it ended by
    /// `cancel_exit` and waits for them at its end.
    owned_firsts: [types.limits.call_depth]u32 = undefined,
    owned_lasts: [types.limits.call_depth]u32 = undefined,
    canceled_ends: [types.limits.call_depth]bool = undefined,
    /// Per frame (P3.9): while it stands at an `event_notify`, the subscription whose callback
    /// runs above it and the number below which its `Signal` calls subscriptions.
    notify_cursors: [types.limits.call_depth]types.ObjectRef = undefined,
    notify_limits: [types.limits.call_depth]i64 = undefined,
    /// The reference's scheduler.
    scheduler: ReferenceScheduler = .{},
    /// The reference's live records (RFC-0084), and the depth below which the frame loop of
    /// the guard that runs leaves the frames alone.
    live: ReferenceLive = .{},
    guard_floor: u32 = 0,
    /// RFC-0082, P3.5: per body node, the newest register before it that is available there,
    /// worked out at a run's first reclamation that roots suspended frames.
    links: [types.limits.template_nodes]u32 = undefined,
    links_ready: bool = false,
    /// Per frame (P3.5): the members its closure captured. The frame copied them into its
    /// parameters, but the VM's frames read them in place, so a suspended frame's are roots in
    /// both machines.
    captures: [types.limits.call_depth]types.Span = undefined,
    /// RFC-0087, P5.3 (E6): the JSON codec's stack, made at the run's first encode or decode.
    json: ?*persist_json.Stack = null,
};

// Structured concurrency (RFC-0082). Each machine keeps its scheduler in its own form; these
// are storage only, and each machine fills and reads them by its own rules.

pub const no_task: u32 = std.math.maxInt(u32);
/// A wait with no deadline: `Sleep` of infinity, or of more ticks than the clock has.
pub const never: u64 = std.math.maxInt(u64);
/// The stores of suspended frames hold a capacity and a half, so that compacting them, which
/// costs what they hold, follows at least half a capacity of saves.
pub const saved_frame_room = types.limits.saved_frames + types.limits.saved_frames / 2;
/// `saved_registers` bounds the registers of suspended frames and their parameters together.
pub const saved_register_room = types.limits.saved_registers + types.limits.saved_registers / 2;

/// A frame of a suspended task in the reference: a `ReferenceFrame` without its catchers, which
/// are empty at every site, with `base` and `return_to` counted from the task's first register
/// and its parameters in the parameter store.
pub const ReferenceSavedFrame = struct {
    function: u32,
    base: u32,
    cursor: u32,
    return_to: u32,
    remaining_visits: u64,
    state_loop: bool,
    mark: u32,
    string_mark: u32,
    cell_mark: u32,
    switches: u64,
    task: u32,
    /// P3.4: what it owns, and whether it ends cancelled.
    owned_first: u32 = no_task,
    owned_last: u32 = no_task,
    canceled_end: bool = false,
    /// P3.5: the members its closure captured.
    captures: types.Span = .{ .start = 0, .end = 0 },
};
/// `settled`: an arm (RFC-0082, P3.3) that has completed or been cancelled, whose slot its
/// expression keeps until the task waiting on it goes on.
pub const ReferenceTaskState = enum { free, pending, queued, running, ready, waiting, settled };
/// A structured expression (P3.3), kept in the slot of the task that runs it: its kind, the node
/// of its site, how many arms it has, has started and has settled, its arms in order, the
/// winner of a `Race`, and whether it was asked to cancel or is still starting its arms.
pub const ReferenceRecord = struct {
    kind: types.StructuredKind = .sync,
    function: u32 = 0,
    pc: u32 = 0,
    arms: u32 = 0,
    started: u32 = 0,
    settled: u32 = 0,
    first_arm: u32 = no_task,
    last_arm: u32 = no_task,
    winner: u32 = no_task,
    canceling: bool = false,
    starting: bool = false,
    /// P3.6: the winner ended with a pending exit, which abandoned the expression.
    exited: bool = false,
};
pub const ReferenceTask = struct {
    state: ReferenceTaskState = .free,
    sequence: u64 = 0,
    /// Its handle (an instance of `task(T)`) and, until it starts, the closure it runs.
    handle: types.Value = undefined,
    closure: types.Value = undefined,
    /// The root instruction it is counted under in failure traces.
    origin: u32 = 0,
    /// Where it waits: the deadline, the registration that orders equal deadlines, and the
    /// function and node of its top frame's site.
    deadline: u64 = never,
    registration: u64 = 0,
    site_function: u32 = 0,
    site_pc: u32 = 0,
    /// What its site yields when it is restored.
    resume_value: types.Value = undefined,
    /// Its saved frames, and its registers followed by its frames' parameters (one run of the
    /// value store), while it is suspended.
    frame_start: u32 = 0,
    frame_count: u32 = 0,
    value_start: u32 = 0,
    value_count: u32 = 0,
    parameter_count: u32 = 0,
    /// The suspended tasks in the order their runs lie in the stores.
    older: u32 = no_task,
    newer: u32 = no_task,
    next_free: u32 = no_task,
    /// P3.2: what it waits for (a timer, an event or a task) and, for the last two, the
    /// instance; the next task in the list it waits in; and the tasks awaiting it, in the
    /// order they began to.
    wait: types.Scheduler.WaitKind = .sleep,
    target: types.Value = undefined,
    next_waiter: u32 = no_task,
    awaiter_first: u32 = no_task,
    awaiter_last: u32 = no_task,
    /// P3.3: a spawned task or an arm; its cancel flag; the task before it in the list it waits
    /// in, the task it awaits, and its place in the timer heap; the next task in the stack of
    /// cancellation requests; for an arm, the task whose expression it belongs to, the next arm
    /// of that expression, and its result once completed; and the expression it runs.
    kind: types.Scheduler.TaskKind = .spawn,
    flagged: bool = false,
    prior_waiter: u32 = no_task,
    awaited: u32 = no_task,
    timer_at: u32 = no_task,
    request_next: u32 = no_task,
    parent: u32 = no_task,
    next_arm: u32 = no_task,
    completed: bool = false,
    result: types.Value = undefined,
    record: ReferenceRecord = .{},
    /// P3.4: for a `Branch` task or a `Rush`'s loser, the task whose frame owns it, that frame's
    /// place among the task's frames (from its entry frame), and its neighbours in the frame's
    /// list; the task running below it on the active stack when it started (it runs again when
    /// this one leaves the stack); and the depth of its entry frame while it is on the stack.
    holder: u32 = no_task,
    holder_frame: u32 = 0,
    next_owned: u32 = no_task,
    prior_owned: u32 = no_task,
    below: u32 = no_task,
    entry_at: u32 = 0,
    /// P3.6: an arm whose entry frame ended by `arm_exit`; its result is the pending exit.
    exited: bool = false,
    /// RFC-0084, P4.4: a reaction (`kind` `upon` or `when`) keeps its guard in `closure` and its
    /// body here; the node that made it, where it is listed at quiescence; what started its
    /// firing, which says what follows the body's end; and where a bound of what follows falls.
    body: types.Value = undefined,
    site_span: types.Span = .{ .start = 0, .end = 0 },
    fired_by: Firing = .loop,
    fire_span: types.Span = .{ .start = 0, .end = 0 },
};
/// What fired a reaction (RFC-0084, P4.4): its node, at creation, on the active stack; the
/// delivery loop; or the drain of the commit queue that started it.
pub const Firing = enum { node, loop, start };
pub const ReferenceTimer = struct { deadline: u64, registration: u64, task: u32 };
/// A live task by its sequence (P3.2); `slot` is `no_task` for one that has ended.
pub const ReferenceIndexEntry = struct { sequence: u64, slot: u32 };
/// A `Signal` held with the starts (P3.2): its event and its value.
pub const ReferenceSignal = struct { event: types.Value, value: types.Value };
pub const ReferenceActionMark = struct { depth: u32, count: u64 };
pub const ReferenceScheduler = struct {
    tasks: [types.limits.tasks]ReferenceTask = undefined,
    /// Slots taken so far; below it, freed slots are linked from `free`.
    used: u32 = 0,
    free: u32 = no_task,
    live: u32 = 0,
    /// The ready queue, a ring of slots: `ready_head` and `ready_tail` count pops and pushes.
    ready: [types.limits.tasks]u32 = undefined,
    ready_head: u64 = 0,
    ready_tail: u64 = 0,
    /// Pending timers, a binary heap on (deadline, registration).
    timers: [types.limits.tasks]ReferenceTimer = undefined,
    timer_count: u32 = 0,
    /// Starts held by rollback regions, after the committed ones waiting for their turn, in
    /// program order: a ring of slots counted like the ready queue. Entries from `action_head`
    /// to `action_kept` are committed; the rest belong to open regions.
    actions: [types.limits.scheduler_actions]u32 = undefined,
    action_head: u64 = 0,
    action_kept: u64 = 0,
    action_count: u64 = 0,
    /// One per open region that holds a start of its own, outermost first.
    action_marks: [types.limits.scheduler_actions]ReferenceActionMark = undefined,
    action_mark_count: u32 = 0,
    /// P3.2: an action whose slot is `no_task` is a `Signal`, kept here at the same place.
    signals: [types.limits.scheduler_actions]ReferenceSignal = undefined,
    /// P3.2: every task that has not ended, by sequence, ascending: handles and events name
    /// tasks by their sequences. An ended task leaves a gap until the next compaction.
    by_sequence: [2 * types.limits.tasks]ReferenceIndexEntry = undefined,
    indexed: u32 = 0,
    /// The stores of suspended frames.
    saved: [saved_frame_room]ReferenceSavedFrame = undefined,
    saved_values: [saved_register_room]types.Value = undefined,
    frame_top: u32 = 0,
    value_top: u32 = 0,
    frames_live: u32 = 0,
    values_live: u32 = 0,
    oldest: u32 = no_task,
    newest: u32 = no_task,
    /// The clock, the run's counters, and the tick rate the run was given.
    now: u64 = 0,
    tick_rate: u64 = types.Scheduler.default_tick_rate,
    sequence: u64 = 0,
    registration: u64 = 0,
    switches: u64 = 0,
    created: u64 = 0,
    completed: u64 = 0,
    /// The tasks waiting at quiescence, for the record.
    waiting: [types.limits.tasks]types.Scheduler.Waiting = undefined,
    waiting_count: u32 = 0,
    /// P3.3: tasks cancelled; the stack of cancellation requests still to make, threaded
    /// through the tasks; and whether the site just left yielded cancelled, which the
    /// `canceling` after it reads.
    canceled: u64 = 0,
    requests: u32 = no_task,
    canceled_now: bool = false,
    /// P3.4: the task whose frames are on top of the active stack, `no_task` in root code.
    current: u32 = no_task,
    /// P3.6: whether the site just left yielded the pending exit of an arm, which the
    /// `arm_exited` after it reads, and the value of that exit.
    exited_now: bool = false,
    exited_value: types.Value = undefined,
    /// P3.9: the run's catalogue, by which a `Signal` carried out of the commit queue tells a
    /// sticky event from another.
    event_definitions: []const types.Definition = &.{},
};

/// The VM's suspended frame: a `VmFrame` without its catchers, `base` and `caller_base` counted
/// from the task's first register.
pub const VmSavedFrame = struct {
    function: u32,
    base: u32,
    pc: u32,
    arguments: types.Span,
    caller_base: ?u32,
    remaining_visits: u64,
    iteration_seed: types.Value,
    state_loop: bool,
    captures: types.Span,
    mark: u32,
    string_mark: u32,
    cell_mark: u32,
    switches: u64,
    task: u32,
    /// P3.4: as in `VmFrame`.
    owned_first: u32 = no_task,
    owned_last: u32 = no_task,
    canceled_end: bool = false,
};
pub const VmTaskPhase = enum { free, held, queued, running, ready, waiting, settled };
/// A structured expression of the VM (P3.3), in the slot of the task that runs it.
pub const VmRecord = struct {
    kind: types.StructuredKind = .sync,
    pc: u32 = 0,
    arms: u32 = 0,
    started: u32 = 0,
    settled: u32 = 0,
    first: u32 = no_task,
    last: u32 = no_task,
    winner: u32 = no_task,
    canceling: bool = false,
    starting: bool = false,
    /// P3.6: `winner` ended with a pending exit, which abandoned the expression.
    exited: bool = false,
};
pub const VmTask = struct {
    sequence: u64 = 0,
    phase: VmTaskPhase = .free,
    handle: types.Value = undefined,
    closure: types.Value = undefined,
    origin: u32 = 0,
    wake: u64 = never,
    order: u64 = 0,
    resume_value: types.Value = undefined,
    /// Its runs of the saved stores.
    first_frame: u32 = 0,
    frames: u32 = 0,
    first_value: u32 = 0,
    values: u32 = 0,
    /// The parameters of its frames, which count against `saved_registers` with the registers
    /// though they stay where the frames read them.
    parameters: u32 = 0,
    /// Neighbours in the order of the runs in the stores.
    previous: u32 = no_task,
    next: u32 = no_task,
    /// P3.2: the kind of its wait and the event or handle it names; the task after it in the
    /// list of the event's waiters or of a task's awaiters; and the list of its own awaiters.
    waits: types.Scheduler.WaitKind = .sleep,
    on: types.Value = undefined,
    after: u32 = no_task,
    awaiters: u32 = no_task,
    awaiters_end: u32 = no_task,
    /// P3.3: as in the reference, in the VM's own form.
    kind: types.Scheduler.TaskKind = .spawn,
    cancel: bool = false,
    before: u32 = no_task,
    awaiting: u32 = no_task,
    heap_at: u32 = no_task,
    request: u32 = no_task,
    owner: u32 = no_task,
    sibling: u32 = no_task,
    done: bool = false,
    result: types.Value = undefined,
    record: VmRecord = .{},
    /// P3.4: as in the reference, in the VM's own form: the task whose frame keeps it and that
    /// frame's place from the keeper's entry frame, its neighbours in the frame's list, the task
    /// below it on the stack, and its entry frame's depth while it runs.
    keeper: u32 = no_task,
    keeper_frame: u32 = 0,
    owned_next: u32 = no_task,
    owned_prior: u32 = no_task,
    below: u32 = no_task,
    entry_at: u32 = 0,
    /// P3.6: an arm whose entry frame ended by `arm_exit`, its result the pending exit.
    exited: bool = false,
    /// RFC-0084, P4.4: as in the reference.
    body: types.Value = undefined,
    site_span: types.Span = .{ .start = 0, .end = 0 },
    fired_by: Firing = .loop,
    fire_span: types.Span = .{ .start = 0, .end = 0 },
};
pub const VmHeldMark = struct { depth: u32, count: u32 };
/// The VM's table from sequence to slot (P3.2): sorted by sequence, `no_task` for a gap.
pub const VmSequenceSlot = struct { sequence: u64, slot: u32 };
/// What a held `Signal` carries (P3.2).
pub const VmHeldSignal = struct { event: types.Value, value: types.Value };
pub const VmScheduler = struct {
    tasks: [types.limits.tasks]VmTask = undefined,
    /// Free slots form a stack.
    spare: [types.limits.tasks]u32 = undefined,
    spare_count: u32 = 0,
    high: u32 = 0,
    live: u32 = 0,
    ready: [types.limits.tasks]u32 = undefined,
    ready_first: u32 = 0,
    ready_count: u32 = 0,
    /// A binary heap of slots ordered by their task's (wake, order).
    heap: [types.limits.tasks]u32 = undefined,
    heap_count: u32 = 0,
    /// Starts in program order, from `held_first`: the first `held_committed` of them are
    /// committed and wait for their turn, the rest belong to open regions. A ring.
    held: [types.limits.scheduler_actions]u32 = undefined,
    held_first: u32 = 0,
    held_committed: u32 = 0,
    held_count: u32 = 0,
    held_marks: [types.limits.scheduler_actions]VmHeldMark = undefined,
    held_mark_count: u32 = 0,
    /// P3.2: a held entry whose slot is `no_task` is a `Signal`, whose event and value lie here
    /// at the same index of the ring.
    held_signals: [types.limits.scheduler_actions]VmHeldSignal = undefined,
    /// P3.2: live tasks by sequence, ascending, with gaps; compacted when full.
    sequences: [2 * types.limits.tasks]VmSequenceSlot = undefined,
    sequence_count: u32 = 0,
    saved: [saved_frame_room]VmSavedFrame = undefined,
    saved_values: [saved_register_room]types.Value = undefined,
    frame_end: u32 = 0,
    value_end: u32 = 0,
    frames_used: u32 = 0,
    values_used: u32 = 0,
    parameters_used: u32 = 0,
    first_saved: u32 = no_task,
    last_saved: u32 = no_task,
    now: u64 = 0,
    rate: u64 = types.Scheduler.default_tick_rate,
    sequence: u64 = 0,
    order: u64 = 0,
    switches: u64 = 0,
    created: u64 = 0,
    completed: u64 = 0,
    waiting: [types.limits.tasks]types.Scheduler.Waiting = undefined,
    waiting_count: u32 = 0,
    /// P3.3.
    canceled: u64 = 0,
    requests: u32 = no_task,
    just_canceled: bool = false,
    /// P3.4: the task running on top of the stack, `no_task` in root code.
    current: u32 = no_task,
    /// P3.6: whether the site just left yielded the pending exit of an arm, which the
    /// `arm_exited` of its check reads, and that exit's value, which its `arm_exit_value` reads.
    just_exited: bool = false,
    exit_value: types.Value = undefined,
};

// Live variables (RFC-0084). Each machine keeps its dependency entries, its dirty set and its
// tracking in its own form; these are storage only, reserved at their capacities and touched
// as a live program uses them.

pub const no_entry: u32 = std.math.maxInt(u32);
/// Entries kept at once: `live_edges` must be kept, and the store holds half as many again so
/// that compacting it, which costs what it holds, follows at least that many invalidations.
pub const live_entry_room = types.limits.live_edges + types.limits.live_edges / 2 + 64;
/// One per cell of a run: the program's own and at most `object_cells` of its instances.
pub const live_cell_room = types.limits.source_cells + types.limits.object_cells;
/// Records are instances of seven cells, so at most this many exist at once.
pub const live_record_room = types.limits.object_cells / 7 + 1;
/// RFC-0084, P4.4: an entry whose dependent is a reaction names its task slot with this bit;
/// every other dependent is a record, a cell of the run, which lies below it.
pub const observer_entry: u32 = 1 << 31;
comptime {
    std.debug.assert(live_cell_room < observer_entry and types.limits.tasks < observer_entry);
}
/// What a live store keeps of each task slot that holds a reaction (P4.4): the stamp of its
/// latest evaluation while it waits on its guard (0 otherwise), the entries that evaluation
/// recorded, which a later one is charged for, and whether it is on the pending list.
pub const Observer = struct { stamp: u64 = 0, entries: u64 = 0, pending: bool = false };
/// A mark of the pending list per open region that notified (P4.4): the region's depth and the
/// list's length when it first did.
pub const PendingMark = struct { depth: u32, count: u64 };

/// A dependency entry of the reference: `cell` was read by the evaluation of `record` that took
/// `stamp`. `before` and `after` link the valid entries of one cell in the order they were made;
/// `listed` is whether the entry is on that list. An entry taken off keeps its `before`, which
/// puts it back where it was if a rollback revives it.
pub const ReferenceLiveEntry = struct { cell: u32, record: u32, stamp: u64, before: u32, after: u32, listed: bool };
/// What the reference keeps beside each cell: the first and last entry of its list, the stamp
/// of the evaluation that last read it, and, for a record, its place in the dirty heap and its
/// evaluations in the current propagation (the propagation's number above, the count below).
pub const ReferenceLiveCell = struct { first: u32, last: u32, heap: u32, queued: bool, seen: u64, evaluated: u64 };
pub const ReferenceLive = struct {
    /// The running program holds a `cell_live`.
    on: bool = false,
    /// Entries in stamp order, and how many there are.
    entries: [live_entry_room]ReferenceLiveEntry = undefined,
    entry_count: u32 = 0,
    /// The entries taken off their lists in open regions that a rollback can revive, in the
    /// order they were taken off (`source_state.Live.log`).
    log: [live_entry_room]u32 = undefined,
    log_count: u32 = 0,
    /// Per cell below `listed`.
    cells: [live_cell_room]ReferenceLiveCell = undefined,
    listed: u32 = 0,
    /// The dirty set, a binary heap of records on (height, id).
    heap: [live_record_room]u32 = undefined,
    heap_count: u32 = 0,
    /// The records whose height was raised and whose readers are still to be raised.
    raise: [live_record_room]u32 = undefined,
    raise_head: u32 = 0,
    raise_count: u32 = 0,
    /// A guard is running, and the cells it has read so far, in order.
    tracking: bool = false,
    reads: [live_cell_room]u32 = undefined,
    read_count: u32 = 0,
    /// Propagations so far, which number them.
    propagation: u64 = 0,
    /// The run's record.
    record: types.Live = .{},
    /// Which definitions have an equality (L6), worked out when a live run begins.
    comparable: [types.limits.user_types]bool = undefined,
    comparable_count: u32 = 0,
    /// RFC-0084, P4.4: per task slot, what the store keeps of a reaction; the pending list, a
    /// ring of slots counted by `pending_head` and `pending_tail`, with a mark per open region
    /// that notified; the open batches (the firings on the active stack, and from P4.5 the
    /// bodies of `Batch{...}`); and the delivery loop under way, where its bounds fall, and its
    /// deliveries so far.
    observers: [types.limits.tasks]Observer = undefined,
    pending: [types.limits.tasks]u32 = undefined,
    pending_head: u64 = 0,
    pending_tail: u64 = 0,
    pending_marks: [types.limits.tasks]PendingMark = undefined,
    pending_mark_count: u32 = 0,
    batch: u32 = 0,
    delivering: bool = false,
    delivery_span: types.Span = .{ .start = 0, .end = 0 },
    delivery_count: u64 = 0,
    /// A drain of the commit queue under way in a program that holds a `reaction`: whether its
    /// next turn is due at the top of the frame loop. (Where it began is the draining frame's.)
    drain_turn: bool = false,
    /// Whether the program holds a `reaction`: only then are a drain's turns taken one at a
    /// time by the frame loop, so the drains of P4.1 to P4.3 programs are as before.
    reacts: bool = false,
};

/// A dependency entry of the VM: `older` and `newer` chain the valid entries of one cell, and
/// `chained` says whether the entry is in that chain. One taken out keeps `older`, beside which a
/// rollback that revives it puts it back.
pub const VmLiveEntry = struct { cell: u32, record: u32, stamp: u64, older: u32, newer: u32, chained: bool };
pub const VmLive = struct {
    on: bool = false,
    entries: [live_entry_room]VmLiveEntry = undefined,
    count: u32 = 0,
    /// Entries taken out of their chains in open regions, which a rollback puts back newest first.
    taken: [live_entry_room]u32 = undefined,
    taken_len: u32 = 0,
    /// Per cell below `known`: its newest and oldest entries, the stamp of the guard that last read it, and,
    /// for a record, one more than its place in the dirty heap (0 when it is not there), its
    /// evaluations in the propagation (the propagation's number above, the count below), and
    /// whether it waits to raise its readers.
    newest: [live_cell_room]u32 = undefined,
    oldest: [live_cell_room]u32 = undefined,
    seen: [live_cell_room]u64 = undefined,
    slot: [live_cell_room]u32 = undefined,
    tally: [live_cell_room]u64 = undefined,
    waiting: [live_cell_room]bool = undefined,
    known: u32 = 0,
    heap: [live_record_room]u32 = undefined,
    heap_len: u32 = 0,
    pending: [live_record_room]u32 = undefined,
    pending_first: u32 = 0,
    pending_len: u32 = 0,
    tracking: bool = false,
    reads: [live_cell_room]u32 = undefined,
    read_len: u32 = 0,
    propagation: u64 = 0,
    record: types.Live = .{},
    comparable: [types.limits.user_types]bool = undefined,
    comparable_len: u32 = 0,
    /// RFC-0084, P4.4: the machine's own view of reactions, as the reference keeps it: per slot
    /// the stamp of the latest evaluation of a waiting reaction, the entries it recorded and
    /// whether it is notified; the notified ones in order, with the marks of the regions that
    /// notified; the firings on the stack; and the delivery loop.
    watch_stamp: [types.limits.tasks]u64 = undefined,
    watch_entries: [types.limits.tasks]u64 = undefined,
    watch_pending: [types.limits.tasks]bool = undefined,
    notified: [types.limits.tasks]u32 = undefined,
    notified_first: u64 = 0,
    notified_end: u64 = 0,
    notified_marks: [types.limits.tasks]PendingMark = undefined,
    notified_mark_len: u32 = 0,
    firing_depth: u32 = 0,
    /// RFC-0084, P4.5: the `Batch{...}` bodies open on the active stack.
    batches: u32 = 0,
    delivering: bool = false,
    delivery_span: types.Span = .{ .start = 0, .end = 0 },
    delivered: u64 = 0,
    drain_due: bool = false,
    reacts: bool = false,
};
