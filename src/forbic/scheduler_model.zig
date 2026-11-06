//! Test-only oracle for RFC-0082, P3.1 to P3.4: the scheduler's rules S1 to S6 over abstract
//! task scripts of `Spawn`, `Sleep`, `Print`, rollback regions, from P3.2 `Signal`, the
//! `Await` of an event and the `Await` of a handle, from P3.3 `Sync`, `Race` and `Defer`,
//! with cancellation, from P3.4 `Rush` and `Branch`, with the tasks a frame owns and the
//! wait at its end, from P3.6 an arm that returns from the function its expression stands
//! in, from P3.7 `T.Cancel()` and the `Await` of a cancelled task, with its propagation, and
//! from P3.8 `For` loops whose bodies suspend, with the `Defer`s of their iterations,
//! written apart from both machines and the replay (a port of
//! `.local/agents/p3d/model/scheduler_model.py`, narrowed to what P3.1 to P3.4 deliver). A
//! generator writes random scripts, prints each as a Forbic program, and the test requires
//! both machines' committed output and scheduler record to be the model's.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");
const concurrency = @import("concurrency_tests.zig");

/// Seconds a script may sleep, and the ticks each is at 60 ticks a second: null for none at
/// all, `never` for one only the end of the run ends.
const durations = [_][]const u8{ "-1.0", "0.0", "0.02", "0.05", "1.0", "Inf" };
const never = std.math.maxInt(u64);
const delays = [_]?u64{ null, 1, 2, 3, 60, never };
/// The events a script signals and waits on (P3.2), module bindings `E0` to `E2`.
const event_count = 3;
/// How far into the list of handles an `Await` of a handle looks.
const handle_reach = 3;

const Op = union(enum) {
    print: u32,
    sleep: u8,
    spawn: u32,
    /// An `Attempt` whose body is the next `count` operations, failing at its end or not.
    region: struct { count: u32, fail: bool },
    /// P3.2: `E.Signal(value)`; `Print("w{label} {E.Await()}")`; and the `Await` of the handle
    /// at `handle` in the list of handles, if there is one, printing `h{label}`, or `n{label}`.
    signal: struct { event: u8, value: u32 },
    await_event: struct { event: u8, label: u32 },
    await_handle: struct { handle: u32, label: u32 },
    /// P3.3: `Defer{ Print("d{label}") }`; and `S{label} := Sync(B{a}(), ...)` printing
    /// `s{label}`, or `R{label} := Race(Block{ B{a}(); 0 }, ...)` printing `r{label} {R}`.
    defer_: u32,
    structured: struct { race: bool, arms: [3]u32, count: u32, label: u32, rush: bool = false, exit: ?u32 = null },
    /// P3.4: `Branch{ B{body}() }`; a `Rush` is a `structured` with `rush` set, printed as
    /// `U{label} := Rush(Block{ B{a}(); 0 }, ...)` and `u{label} {U}`.
    branch: u32,
    /// P3.7: `T.Cancel()` of the handle at `handle` in the list of handles, if there is one,
    /// printing `c{label}` after it, or `m{label}`.
    cancel: struct { handle: u32, label: u32 },
    /// P3.8: a `For` whose body, the next `count` operations, may suspend: `iterations` of
    /// them in order, but the `skip`-th, which a filter leaves out. `form` says how it is
    /// written (`writeLoop`): every form runs its body for the same iterations. `regions`: the
    /// body holds no site and the form is a general one, so each iteration is a region, as it
    /// was before P3.8, which holds the starts and signals of the iteration until it ends.
    loop: struct { count: u32, iterations: u32, skip: ?u32 = null, label: u32, form: u8, regions: bool = false },
};
const max_ops = 256;
const max_bodies = 6;

const Script = struct {
    ops: [max_ops]Op = undefined,
    op_count: u32 = 0,
    /// Each body is a range of `ops`; the root is the last range.
    bodies: [max_bodies + 1]struct { first: u32, count: u32 } = undefined,
    body_count: u32 = 0,
    labels: u32 = 0,
    /// Whether to write the P3.2 operations: P3.1's scripts are generated as they were.
    events: bool = false,
    /// And the P3.3 operations, after them.
    structured: bool = false,
    /// And the P3.4 operations, after those.
    owned: bool = false,
    /// P3.6: an arm of some expressions returns from the body, after its own body: printed
    /// `Block{ B{a}(); Return(tuple{}) }`.
    exits: bool = false,
    /// P3.7: and `Cancel`s of handles.
    cancels: bool = false,
    /// P3.8: and `For` loops whose bodies may suspend, in the bodies of tasks; `looping` while
    /// the body of one is written, which holds no `Branch`, `Rush`, exit or loop (a branch
    /// would belong to the frame of an iteration), and `in_root` while the root is.
    loops: bool = false,
    looping: bool = false,
    in_root: bool = false,

    fn add(self: *Script, op: Op) void {
        self.ops[self.op_count] = op;
        self.op_count += 1;
    }
    fn label(self: *Script) u32 {
        self.labels += 1;
        return self.labels;
    }
    /// The number of operations an operation spans with what it holds.
    fn span(self: *const Script, at: u32) u32 {
        return switch (self.ops[at]) {
            .region => |r| region: {
                var total: u32 = 1;
                for (0..r.count) |_| total += self.span(at + total);
                break :region total;
            },
            .loop => |l| loop: {
                var total: u32 = 1;
                for (0..l.count) |_| total += self.span(at + total);
                break :loop total;
            },
            else => 1,
        };
    }
};

fn generateOps(script: *Script, random: std.Random, body: u32, count: u32, in_region: bool, depth: u32) void {
    for (0..count) |_| {
        // P3.8: a loop, drawn only when loops are asked for, so that other scripts stay as they were.
        if (script.loops and !in_region and !script.looping and !script.in_root and depth == 0 and script.op_count + 24 < max_ops and random.uintLessThan(u8, 5) == 0) {
            generateLoop(script, random, body, depth);
            continue;
        }
        const choice = random.uintLessThan(u8, if (script.cancels) 64 else if (script.owned) 48 else if (script.structured) 40 else if (script.events) 24 else 10);
        if (choice < 3) {
            script.add(.{ .print = script.label() });
        } else if (choice < 6 and !in_region) {
            script.add(.{ .sleep = random.uintLessThan(u8, durations.len) });
        } else if (choice < 8 and body != 0) {
            script.add(.{ .spawn = random.uintLessThan(u32, body) });
        } else if (choice >= 10 and choice < 14) {
            script.add(.{ .signal = .{ .event = random.uintLessThan(u8, event_count), .value = script.label() } });
        } else if (choice >= 14 and choice < 19 and !in_region) {
            script.add(.{ .await_event = .{ .event = random.uintLessThan(u8, event_count), .label = script.label() } });
        } else if (choice >= 19 and choice < 24 and !in_region) {
            script.add(.{ .await_handle = .{ .handle = random.uintLessThan(u32, handle_reach), .label = script.label() } });
        } else if (choice >= 24 and choice < 35 and !in_region and body != 0) {
            // Arms call earlier bodies, so no script calls itself.
            const arm_count = 2 + random.uintLessThan(u32, 2);
            var arms: [3]u32 = @splat(0);
            for (arms[0..arm_count]) |*arm| arm.* = random.uintLessThan(u32, body);
            script.add(.{ .structured = .{ .race = random.boolean(), .arms = arms, .count = arm_count, .label = script.label() } });
            // P3.6: one of the arms returns from the body after its own.
            if (script.exits and !script.looping and random.boolean()) script.ops[script.op_count - 1].structured.exit = random.uintLessThan(u32, arm_count);
        } else if (choice >= 40 and choice < 44 and !in_region and body != 0 and !script.looping) {
            // P3.4: a branch runs an earlier body, as an arm does.
            script.add(.{ .branch = random.uintLessThan(u32, body) });
        } else if (choice >= 48 and !in_region) {
            // P3.7: a cancellation of a handle a task kept, perhaps its own or its creator's.
            script.add(.{ .cancel = .{ .handle = random.uintLessThan(u32, handle_reach), .label = script.label() } });
        } else if (choice >= 44 and !in_region and body != 0 and !script.looping) {
            const arm_count = 2 + random.uintLessThan(u32, 2);
            var arms: [3]u32 = @splat(0);
            for (arms[0..arm_count]) |*arm| arm.* = random.uintLessThan(u32, body);
            script.add(.{ .structured = .{ .race = true, .rush = true, .arms = arms, .count = arm_count, .label = script.label() } });
            if (script.exits and random.boolean()) script.ops[script.op_count - 1].structured.exit = random.uintLessThan(u32, arm_count);
        } else if (choice >= 35 and choice < 40 and !in_region) {
            script.add(.{ .defer_ = script.label() });
        } else if (choice >= 40 and !in_region) {
            script.add(.{ .defer_ = script.label() });
        } else if (choice < 10 and depth < 2 and script.op_count + 8 < max_ops) {
            const inner = 1 + random.uintLessThan(u32, 3);
            script.add(.{ .region = .{ .count = inner, .fail = random.uintLessThan(u8, 3) == 0 } });
            generateOps(script, random, body, inner, true, depth + 1);
        } else {
            script.add(.{ .print = script.label() });
        }
    }
    // A `Defer` has statements after it in its scope.
    if (!in_region and script.op_count != 0 and script.ops[script.op_count - 1] == .defer_) script.add(.{ .print = script.label() });
}

/// P3.8: a loop of one to three iterations whose body is one to three operations.
fn generateLoop(script: *Script, random: std.Random, body: u32, depth: u32) void {
    const form = random.uintLessThan(u8, 6);
    const iterations = 1 + random.uintLessThan(u32, 3);
    // The filtered forms run over one value more and leave one out.
    const filtered = form == 1 or form == 5;
    const total = if (filtered) iterations + 1 else if (form == 2) 2 * iterations else iterations;
    const at = script.op_count;
    script.add(.{ .loop = .{ .count = 0, .iterations = total, .skip = if (filtered) random.uintLessThan(u32, total) else null, .label = script.label(), .form = form } });
    script.looping = true;
    generateOps(script, random, body, 1 + random.uintLessThan(u32, 3), false, depth + 1);
    script.looping = false;
    script.ops[at].loop.count = topLevel(script, at + 1, script.op_count - at - 1);
    // A site is never inside a region, so the body's own operations say whether it has one.
    var site = false;
    var cursor = at + 1;
    while (cursor < script.op_count) : (cursor += script.span(cursor)) switch (script.ops[cursor]) {
        .sleep, .await_event, .await_handle, .structured, .cancel => site = true,
        else => {},
    };
    script.ops[at].loop.regions = !site and form < 4;
}

fn generate(random: std.Random, events: bool, structured: bool, owned: bool, exits: bool, cancels: bool) Script {
    return generateLoops(random, events, structured, owned, exits, cancels, false);
}

fn generateLoops(random: std.Random, events: bool, structured: bool, owned: bool, exits: bool, cancels: bool, loops: bool) Script {
    var script: Script = .{ .events = events, .structured = structured, .owned = owned, .exits = exits, .cancels = cancels, .loops = loops };
    const bodies = 1 + random.uintLessThan(u32, max_bodies);
    for (0..bodies + 1) |index| {
        const first = script.op_count;
        const before = script.op_count;
        const body: u32 = @intCast(index);
        // The root (the last range) spawns bodies, and starts held by its regions.
        script.in_root = index == bodies;
        generateOps(&script, random, if (index == bodies) bodies else body, if (events) 2 + random.uintLessThan(u32, 5) else 1 + random.uintLessThan(u32, 4), false, 0);
        if (index == bodies) {
            // Root code cannot sleep or wait: what the generator put there is dropped.
            var at = before;
            while (at < script.op_count) : (at += 1) switch (script.ops[at]) {
                .sleep, .await_event, .await_handle, .structured, .defer_, .branch, .cancel => script.ops[at] = .{ .print = script.label() },
                else => {},
            };
        }
        script.bodies[index] = .{ .first = first, .count = script.op_count - first };
        script.body_count += 1;
        if (events and index + 1 == bodies) {
            // The last body is a pump, spawned by the root last: after the others have had
            // their turns it signals every event, three times a second apart, so that the
            // waiters the scripts leave are woken often.
            script.op_count = first;
            for (0..3) |_| {
                script.add(.{ .sleep = 4 });
                for (0..event_count) |event| script.add(.{ .signal = .{ .event = @intCast(event), .value = script.label() } });
            }
            script.bodies[index] = .{ .first = first, .count = script.op_count - first };
        }
    }
    if (events) {
        script.add(.{ .spawn = bodies - 1 });
        script.bodies[bodies].count += 1;
    }
    return script;
}

/// Prints `count` operations from `at` as statements separated by `;`; returns the next one.
fn writeOps(script: *const Script, out: *std.Io.Writer, at: u32, count: u32) !u32 {
    var cursor = at;
    for (0..count) |index| {
        if (index != 0) try out.writeAll("; ");
        switch (script.ops[cursor]) {
            .print => |label| {
                try out.print("Print(\"p{d}\")", .{label});
                cursor += 1;
            },
            .sleep => |which| {
                try out.print("Sleep({s})", .{durations[which]});
                cursor += 1;
            },
            .spawn => |body| {
                // With events, every handle is kept, so that a task can await it.
                if (script.events) try out.print("Keep(Spawn{{ B{d}() }})", .{body}) else try out.print("Spawn{{ B{d}() }}", .{body});
                cursor += 1;
            },
            .region => |r| {
                try out.writeAll("Attempt(Block{ ");
                cursor = try writeOps(script, out, cursor + 1, r.count);
                try out.print("; Require[{s}]; 0 }}, 1)", .{if (r.fail) "false" else "true"});
            },
            .signal => |s| {
                try out.print("E{d}.Signal({d})", .{ s.event, s.value });
                cursor += 1;
            },
            .await_event => |a| {
                try out.print("Print(\"w{d} {{E{d}.Await()}}\")", .{ a.label, a.event });
                cursor += 1;
            },
            .await_handle => |a| {
                try out.print("If(H{d} := Hs[{d}], Block{{ H{d}.Await(); Print(\"h{d}\") }}, Print(\"n{d}\"))", .{ a.label, a.handle, a.label, a.label, a.label });
                cursor += 1;
            },
            .defer_ => |label| {
                try out.print("Defer{{ Print(\"d{d}\") }}", .{label});
                cursor += 1;
            },
            .structured => |s| {
                // P3.6: an arm that returns from the body; a `Race` or `Rush` with one states its
                // type, which an exit has no value to give.
                if (s.rush) {
                    if (s.exit == null) try out.print("U{d} := Rush(", .{s.label}) else try out.print("U{d}:i64 = Rush(", .{s.label});
                    for (s.arms[0..s.count], 0..) |arm, k| {
                        if (s.exit != null and s.exit.? == k) try out.print("{s}Block{{ B{d}(); Return(tuple{{}}) }}", .{ if (k != 0) ", " else "", arm }) else try out.print("{s}Block{{ B{d}(); {d} }}", .{ if (k != 0) ", " else "", arm, k });
                    }
                    try out.print("); Print(\"u{d} {{U{d}}}\")", .{ s.label, s.label });
                    cursor += 1;
                    continue;
                }
                if (s.race and s.exit != null) try out.print("R{d}:i64 = Race(", .{s.label}) else try out.print("{s}{d} := {s}(", .{ if (s.race) "R" else "S", s.label, if (s.race) "Race" else "Sync" });
                for (s.arms[0..s.count], 0..) |arm, k| {
                    if (k != 0) try out.writeAll(", ");
                    if (s.exit != null and s.exit.? == k) try out.print("Block{{ B{d}(); Return(tuple{{}}) }}", .{arm}) else if (s.race) try out.print("Block{{ B{d}(); {d} }}", .{ arm, k }) else try out.print("B{d}()", .{arm});
                }
                if (s.race) try out.print("); Print(\"r{d} {{R{d}}}\")", .{ s.label, s.label }) else try out.print("); Print(\"s{d}\")", .{s.label});
                cursor += 1;
            },
            .branch => |body| {
                try out.print("Branch{{ B{d}() }}", .{body});
                cursor += 1;
            },
            .cancel => |c| {
                try out.print("If(C{d} := Hs[{d}], Block{{ C{d}.Cancel(); Print(\"c{d}\") }}, Print(\"m{d}\"))", .{ c.label, c.handle, c.label, c.label, c.label });
                cursor += 1;
            },
            .loop => |l| {
                try writeLoop(out, l.form, l.label, l.iterations, l.skip);
                cursor = try writeOps(script, out, cursor + 1, l.count);
                try out.writeAll(" })");
            },
        }
    }
    return cursor;
}

/// P3.8: the head of a loop of `total` iterations, up to the `Block{ ` of its body: a range,
/// a range with a filter, two generators, a binding, and the two forms of RFC-0056 (an
/// array, and an array with a filter). A filter leaves the `skip`-th value out.
fn writeLoop(out: *std.Io.Writer, form: u8, label: u32, total: u32, skip: ?u32) !void {
    switch (form) {
        0 => try out.print("For(I{d}:0..{d}, Block{{ ", .{ label, total - 1 }),
        1 => try out.print("For(I{d}:0..{d}, I{d} != {d}, Block{{ ", .{ label, total - 1, label, skip.? }),
        2 => try out.print("For(I{d}:0..1, J{d}:1..{d}, Block{{ ", .{ label, label, total / 2 }),
        3 => try out.print("For(I{d}:0..{d}, J{d} := I{d} * 2, Block{{ ", .{ label, total - 1, label, label }),
        4, 5 => {
            try out.print("For(X{d}:array{{", .{label});
            for (0..total) |k| try out.print("{s}{d}", .{ if (k != 0) ", " else "", k });
            if (form == 4) try out.writeAll("}, Block{ ") else try out.print("}}, X{d} != {d}, Block{{ ", .{ label, skip.? });
        },
        else => unreachable,
    }
}

fn writeProgram(script: *const Script, out: *std.Io.Writer) !void {
    if (script.events) {
        for (0..event_count) |event| try out.print("E{d}:event(i64) = event(i64){{}}\n", .{event});
        try out.writeAll("var Hs:[]task(void) = array{}\n");
        // The handle is kept once the spawn has yielded it: after the task's first turn.
        try out.writeAll("Keep(T:task(void))<transacts>:void = Set(Hs, Hs + array{T})\n");
    }
    const root = script.body_count - 1;
    for (script.bodies[0..root], 0..) |body, index| {
        try out.print("B{d}()<transacts><suspends>:void = Block{{ ", .{index});
        _ = try writeOps(script, out, body.first, topLevel(script, body.first, body.count));
        try out.writeAll(" }\n");
    }
    // Each top-level root operation is a binding of its own.
    const body = script.bodies[root];
    var cursor = body.first;
    var index: u32 = 0;
    while (cursor < body.first + body.count) : (index += 1) {
        try out.print("R{d}:i64 = Block{{ ", .{index});
        const next = try writeOps(script, out, cursor, 1);
        try out.writeAll("; 0 }\n");
        cursor = next;
    }
}

/// How many operations of a range are its own and not inside its regions.
fn topLevel(script: *const Script, first: u32, count: u32) u32 {
    var cursor = first;
    var own: u32 = 0;
    while (cursor < first + count) : (own += 1) cursor += script.span(cursor);
    return own;
}

/// A start or a signal, held by a region or committed and waiting for its turn (P3.2).
const Action = union(enum) { start: u32, signal: struct { event: u8, value: u32 } };
/// An open region: its output, its held actions, and the length of the list of handles when it
/// began, which a failure goes back to.
const Region = struct { lines: std.ArrayList(u8) = .empty, held: std.ArrayList(Action) = .empty, handles: usize = 0 };

/// The model's run.
const Model = struct {
    script: *const Script,
    out: std.ArrayList(u8) = .empty,
    now: u64 = 0,
    switches: u64 = 0,
    created: u64 = 0,
    completed: u64 = 0,
    registration: u64 = 0,
    tasks: [512]Task = undefined,
    task_count: u32 = 0,
    ready: std.ArrayList(u32) = .empty,
    timers: std.ArrayList(struct { deadline: u64, registration: u64, task: u32 }) = .empty,
    /// Committed starts and signals waiting for their turn.
    queue: std.ArrayList(Action) = .empty,
    /// One per open region: its output, its held actions, and the length of the list of
    /// handles when it began, which a failure goes back to.
    regions: [8]Region = @splat(.{}),
    region_depth: u32 = 0,
    /// P3.2: the waiters of each event, and the handles in the order the program kept them.
    waiters: [event_count]std.ArrayList(u32) = @splat(.empty),
    handles: std.ArrayList(u32) = .empty,
    too_big: bool = false,
    /// P3.3: tasks cancelled, and the requests still to make, the next on top.
    canceled: u64 = 0,
    requests: std.ArrayList(u32) = .empty,
    /// P3.8: how often a task waited inside a loop.
    loop_waits: usize = 0,

    const Task = struct {
        body: u32,
        pc: u32,
        end: u32,
        waiting: bool = false,
        done: bool = false,
        /// What a task prints when it resumes from an await, and the value a signal gave it.
        resumes: enum { nothing, event, handle, structured } = .nothing,
        label: u32 = 0,
        value: u32 = 0,
        awaiters: std.ArrayList(u32) = .empty,
        /// P3.3: an arm, of the expression of `parent`, the `index`-th; whether it was asked
        /// to cancel, and was; what it waits on; the `Defer`s registered so far; and the
        /// expression it runs.
        arm: bool = false,
        parent: u32 = 0,
        index: u32 = 0,
        cancel: bool = false,
        canceled: bool = false,
        waits: enum { none, sleep, event, handle, record, frame_end } = .none,
        target: u32 = 0,
        defers: std.ArrayList(u32) = .empty,
        record: struct { race: bool = false, label: u32 = 0, arms: [3]u32 = @splat(0), count: u32 = 0, started: u32 = 0, settled: u32 = 0, winner: ?u32 = null, canceling: bool = false, rush: bool = false, adopted: u32 = 0, exited: bool = false } = .{},
        /// P3.4: the tasks its body's frame owns (its branches and its `Rush`es' losers) that
        /// are not settled, in the order they came; the task whose frame owns it; and, while it
        /// waits at its frame's end, whether its body ended by cancellation.
        owned: std.ArrayList(u32) = .empty,
        holder: ?u32 = null,
        end_canceled: bool = false,
        /// P3.6: an arm that returns from the body its expression stands in, after its own.
        exits: bool = false,
        /// P3.7: whether it has had its first turn: a task asked to cancel before it starts
        /// runs to its first site.
        started: bool = false,
        /// P3.8: the loop it waits in: the loop's operation, the iteration, and how many
        /// `Defer`s the task had when that iteration began.
        loop: ?struct { at: u32, iteration: u32, mark: usize } = null,
    };

    fn deinit(self: *Model) void {
        const a = std.testing.allocator;
        self.out.deinit(a);
        self.ready.deinit(a);
        self.timers.deinit(a);
        self.queue.deinit(a);
        for (&self.regions) |*region| {
            region.lines.deinit(a);
            region.held.deinit(a);
        }
        for (&self.waiters) |*list| list.deinit(a);
        self.handles.deinit(a);
        self.requests.deinit(a);
        for (self.tasks[0..self.task_count]) |*task| {
            task.awaiters.deinit(a);
            task.defers.deinit(a);
            task.owned.deinit(a);
        }
    }

    /// The task is ready: woken, or (P3.3) asked to cancel.
    fn wake(self: *Model, id: u32) error{OutOfMemory}!void {
        self.tasks[id].waiting = false;
        try self.ready.append(std.testing.allocator, id);
    }

    fn settled(self: *const Model, id: u32) bool {
        return self.tasks[id].done or self.tasks[id].canceled;
    }

    /// Whether an expression is over: every arm of a `Sync` completed; a `Race` won and every
    /// arm it started settled. One asked to cancel is over only for cancelling.
    fn over(self: *const Model, id: u32) bool {
        const r = self.tasks[id].record;
        if (r.canceling) return false;
        // P3.6: one an arm's exit abandoned is over when its started arms are settled.
        if (r.exited) return r.settled == r.started;
        // A resolved `Rush` gave its unsettled arms to the frame (P3.4).
        return if (r.race) r.winner != null and r.settled + r.adopted == r.started else r.settled == r.count;
    }

    /// The started arms of `id`'s expression not yet settled are asked, the first first.
    fn pushArms(self: *Model, id: u32) error{OutOfMemory}!void {
        const r = self.tasks[id].record;
        var k = r.started;
        while (k > 0) {
            k -= 1;
            if (!self.settled(r.arms[k]) and self.tasks[r.arms[k]].arm) try self.requests.append(std.testing.allocator, r.arms[k]);
        }
    }

    /// Cancellation requests, depth first in arm order (RFC-0082, "Cancellation").
    fn makeRequests(self: *Model) error{OutOfMemory}!void {
        while (self.requests.pop()) |id| {
            const task = &self.tasks[id];
            if (self.settled(id) or task.cancel) continue;
            task.cancel = true;
            if (!task.waiting) continue; // Ready: it yields cancelled when it runs.
            switch (task.waits) {
                .sleep => {
                    for (self.timers.items, 0..) |timer, at| if (timer.task == id) {
                        _ = self.timers.orderedRemove(at);
                        break;
                    };
                    try self.wake(id);
                },
                .event => {
                    for (self.waiters[task.target].items, 0..) |other, at| if (other == id) {
                        _ = self.waiters[task.target].orderedRemove(at);
                        break;
                    };
                    try self.wake(id);
                },
                .handle => {
                    const list = &self.tasks[task.target].awaiters;
                    for (list.items, 0..) |other, at| if (other == id) {
                        _ = list.orderedRemove(at);
                        break;
                    };
                    try self.wake(id);
                },
                .record => {
                    task.record.canceling = true;
                    try self.pushArms(id);
                },
                // P3.4: its frame is already ending; the flag waits for its next site.
                .frame_end => {},
                .none => unreachable,
            }
        }
    }

    /// An arm settled: its expression counts it, a `Race`'s first completion wins and cancels
    /// the others, and a task waiting on an expression that is over is ready.
    fn armSettled(self: *Model, id: u32, canceled: bool) error{OutOfMemory}!void {
        const parent = self.tasks[id].parent;
        const r = &self.tasks[parent].record;
        r.settled += 1;
        // P3.6: an arm that returns abandons an expression nothing resolved: the other started
        // arms are asked to cancel, of every kind, and no arm starts after it.
        const exits = !canceled and self.tasks[id].exits;
        if (exits and r.winner == null and !r.canceling) {
            r.winner = self.tasks[id].index;
            r.exited = true;
            try self.pushArms(parent);
            try self.makeRequests();
        }
        if (!canceled and !exits and r.race and r.winner == null and !r.canceling) {
            r.winner = self.tasks[id].index;
            if (r.rush) {
                // P3.4: the started arms not settled go on, owned by the frame that runs it.
                for (r.arms[0..r.started]) |arm| if (!self.settled(arm)) {
                    self.tasks[arm].arm = false;
                    self.tasks[arm].holder = parent;
                    try self.tasks[parent].owned.append(std.testing.allocator, arm);
                    r.adopted += 1;
                };
            } else {
                try self.pushArms(parent);
                try self.makeRequests();
            }
        }
        // P3.7: an arm cancelled from outside its expression (it awaited a cancelled task) asks
        // the task running the expression to cancel, unless the expression is cancelling or
        // resolved.
        if (canceled and r.winner == null and !r.canceling) {
            try self.requests.append(std.testing.allocator, parent);
            try self.makeRequests();
        }
        const p = &self.tasks[parent];
        if (p.waiting and p.waits == .record and r.settled + r.adopted == r.started and (r.canceling or self.over(parent))) try self.wake(parent);
    }

    fn newTask(self: *Model, body: u32) u32 {
        if (self.task_count == self.tasks.len or self.task_count >= 48) {
            self.too_big = true;
            return 0;
        }
        const range = self.script.bodies[body];
        self.tasks[self.task_count] = .{ .body = body, .pc = range.first, .end = range.first + range.count };
        self.task_count += 1;
        return self.task_count - 1;
    }

    /// A task's first turn, by hand-off or from the queue.
    fn start(self: *Model, task: u32) error{OutOfMemory}!void {
        self.switches += 1;
        self.created += 1;
        self.tasks[task].started = true;
        try self.runFrom(task, true);
    }

    /// P3.7: whether the task `id` was asked to cancel, as a site at its entry asks; if so it
    /// unwinds there: its `Defer`s run, then its frame's end, and it settles cancelled.
    fn canceledAt(self: *Model, id: u32) error{OutOfMemory}!bool {
        if (!self.tasks[id].cancel) return false;
        try self.runDefers(id);
        try self.frameEnd(id, true);
        return true;
    }

    /// `Signal` at depth 0: every task waiting on the event, in order, is ready with the value.
    fn signal(self: *Model, event: u8, value: u32) error{OutOfMemory}!void {
        const a = std.testing.allocator;
        _ = a;
        for (self.waiters[event].items) |id| {
            self.tasks[id].value = value;
            try self.wake(id);
        }
        self.waiters[event].clearRetainingCapacity();
    }

    /// Runs `count` operations from `at` inside the current task or the root; returns the next
    /// one, or null when the task waits there (`at` is then where it resumes).
    fn ops(self: *Model, task: ?u32, at: u32, count: u32) error{OutOfMemory}!?u32 {
        const a = std.testing.allocator;
        var cursor = at;
        for (0..count) |_| {
            if (self.too_big) return null;
            switch (self.script.ops[cursor]) {
                .print => |label| {
                    const target = if (self.region_depth == 0) &self.out else &self.regions[self.region_depth - 1].lines;
                    try target.print(a, "p{d}\n", .{label});
                    cursor += 1;
                },
                .sleep => |which| {
                    cursor += 1;
                    if (try self.canceledAt(task.?)) return null;
                    const delay = delays[which] orelse continue;
                    // Saves the task; it is restored when its timer is due.
                    const id = task.?;
                    self.tasks[id].pc = cursor;
                    self.tasks[id].waiting = true;
                    self.tasks[id].waits = .sleep;
                    self.switches += 1;
                    if (delay != never) {
                        self.registration += 1;
                        try self.timers.append(a, .{ .deadline = self.now + delay, .registration = self.registration, .task = id });
                    }
                    return null;
                },
                .spawn => |body| {
                    cursor += 1;
                    const child = self.newTask(body);
                    if (self.too_big) return null;
                    // A handle is kept when the spawn yields it: at once in a region, and after
                    // the task's first turn outside one.
                    if (self.region_depth != 0) {
                        if (self.script.events) try self.handles.append(a, child);
                        try self.regions[self.region_depth - 1].held.append(a, .{ .start = child });
                    } else {
                        try self.start(child);
                        if (self.too_big) return null;
                        if (self.script.events) try self.handles.append(a, child);
                    }
                },
                .signal => |s| {
                    cursor += 1;
                    if (self.region_depth != 0) {
                        try self.regions[self.region_depth - 1].held.append(a, .{ .signal = .{ .event = s.event, .value = s.value } });
                    } else try self.signal(s.event, s.value);
                },
                .await_event => |w| {
                    cursor += 1;
                    if (try self.canceledAt(task.?)) return null;
                    const id = task.?;
                    self.tasks[id].pc = cursor;
                    self.tasks[id].waiting = true;
                    self.tasks[id].resumes = .event;
                    self.tasks[id].label = w.label;
                    self.tasks[id].waits = .event;
                    self.tasks[id].target = w.event;
                    self.switches += 1;
                    try self.waiters[w.event].append(a, id);
                    return null;
                },
                .await_handle => |w| {
                    cursor += 1;
                    if (w.handle >= self.handles.items.len) {
                        try self.out.print(a, "n{d}\n", .{w.label});
                        continue;
                    }
                    const target = self.handles.items[w.handle];
                    if (try self.canceledAt(task.?)) return null;
                    // A completed task's result is there at once (sticky).
                    if (self.tasks[target].done) {
                        try self.out.print(a, "h{d}\n", .{w.label});
                        continue;
                    }
                    // P3.7 (Q3): awaiting a cancelled task cancels the awaiter, at once.
                    if (self.tasks[target].canceled) {
                        self.tasks[task.?].cancel = true;
                        _ = try self.canceledAt(task.?);
                        return null;
                    }
                    const id = task.?;
                    self.tasks[id].pc = cursor;
                    self.tasks[id].waiting = true;
                    self.tasks[id].resumes = .handle;
                    self.tasks[id].label = w.label;
                    self.tasks[id].waits = .handle;
                    self.tasks[id].target = target;
                    self.switches += 1;
                    try self.tasks[target].awaiters.append(a, id);
                    return null;
                },
                .defer_ => |label| {
                    cursor += 1;
                    try self.tasks[task.?].defers.append(a, label);
                },
                .branch => |body| {
                    cursor += 1;
                    if (try self.canceledAt(task.?)) return null;
                    // P3.4: a task the body's frame owns, handed off to at once.
                    const id = task.?;
                    const child = self.newTask(body);
                    if (self.too_big) return null;
                    self.tasks[child].holder = id;
                    try self.tasks[id].owned.append(a, child);
                    try self.start(child);
                    if (self.too_big) return null;
                },
                .structured => |s| {
                    cursor += 1;
                    if (try self.canceledAt(task.?)) return null;
                    const id = task.?;
                    self.tasks[id].record = .{ .race = s.race, .label = s.label, .count = s.count, .rush = s.rush };
                    // The start phase: each arm in turn, until one wins, or (P3.7) until an arm
                    // asks the task to cancel.
                    for (s.arms[0..s.count], 0..) |body, k| {
                        if (self.tasks[id].record.winner != null or self.tasks[id].cancel) break;
                        const child = self.newTask(body);
                        if (self.too_big) return null;
                        self.tasks[child].arm = true;
                        self.tasks[child].parent = id;
                        self.tasks[child].index = @intCast(k);
                        self.tasks[child].exits = s.exit != null and s.exit.? == k;
                        self.tasks[id].record.arms[k] = child;
                        self.tasks[id].record.started += 1;
                        try self.start(child);
                        if (self.too_big) return null;
                    }
                    if (self.tasks[id].cancel) {
                        // P3.7: the expression is cancelled, and the site yields cancelled once
                        // its started arms are settled: at once, or when the task is woken.
                        const r = &self.tasks[id].record;
                        r.canceling = true;
                        try self.pushArms(id);
                        try self.makeRequests();
                        if (r.settled + r.adopted == r.started) {
                            _ = try self.canceledAt(id);
                            return null;
                        }
                        self.tasks[id].pc = cursor;
                        self.tasks[id].waiting = true;
                        self.tasks[id].waits = .record;
                        self.tasks[id].resumes = .structured;
                        self.switches += 1;
                        return null;
                    }
                    if (self.over(id)) {
                        // P3.6: the body returns, before its next operation.
                        if (self.tasks[id].record.exited) return cursor;
                        try self.printStructured(id);
                        continue;
                    }
                    self.tasks[id].pc = cursor;
                    self.tasks[id].waiting = true;
                    self.tasks[id].waits = .record;
                    self.tasks[id].resumes = .structured;
                    self.switches += 1;
                    return null;
                },
                .loop => cursor = (try self.loopFrom(task.?, cursor, 0, null, 0)) orelse return null,
                .cancel => |c| {
                    cursor += 1;
                    if (c.handle >= self.handles.items.len) {
                        try self.out.print(a, "m{d}\n", .{c.label});
                        continue;
                    }
                    if (try self.canceledAt(task.?)) return null;
                    // P3.7: a request to the task, of whatever it is doing.
                    try self.requests.append(a, self.handles.items[c.handle]);
                    try self.makeRequests();
                    try self.out.print(a, "c{d}\n", .{c.label});
                },
                .region => |r| {
                    self.region_depth += 1;
                    const region = &self.regions[self.region_depth - 1];
                    region.lines.clearRetainingCapacity();
                    region.held.clearRetainingCapacity();
                    region.handles = self.handles.items.len;
                    const after = (try self.ops(task, cursor + 1, r.count)) orelse unreachable;
                    self.region_depth -= 1;
                    cursor = after;
                    if (r.fail) {
                        // Its starts never happen and their sequence numbers come back; the
                        // handles it kept are rolled back with the cell.
                        for (region.held.items) |action| if (action == .start) {
                            self.task_count -= 1;
                        };
                        self.handles.shrinkRetainingCapacity(region.handles);
                        continue;
                    }
                    try self.commit(region);
                },
            }
        }
        return cursor;
    }

    /// P3.8: the iterations of the loop at `at` from `first` on, the first of them resumed at
    /// `resume_at` if the task waited in it; the cursor after the loop, or null when the task
    /// waits in it (it then records where). As an iteration's body ends, the `Defer`s it
    /// registered run, the newest first; a task cancelled in one runs them with its others.
    fn loopFrom(self: *Model, id: u32, at: u32, first: u32, resume_at: ?u32, resume_mark: usize) error{OutOfMemory}!?u32 {
        const l = self.script.ops[at].loop;
        const end = at + self.script.span(at);
        var iteration = first;
        var from = resume_at;
        var mark = resume_mark;
        while (iteration < l.iterations) : (iteration += 1) {
            if (from == null) {
                if (l.skip != null and l.skip.? == iteration) continue;
                mark = self.tasks[id].defers.items.len;
            }
            const begin = from orelse at + 1;
            from = null;
            // Two generators are two levels, each iteration of each in its region: the inner
            // ones commit into the outer one, which commits when its last inner one has.
            const half = l.iterations / 2;
            if (l.regions and l.form == 2 and iteration % half == 0) self.openRegion();
            // An iteration without a site, in its region: its output and its starts and signals
            // are held until it ends, and then committed as a region's are.
            if (l.regions) self.openRegion();
            if ((try self.ops(id, begin, topLevel(self.script, begin, end - begin))) == null) {
                self.tasks[id].loop = .{ .at = at, .iteration = iteration, .mark = mark };
                self.loop_waits += 1;
                return null;
            }
            const defers = &self.tasks[id].defers;
            const target = if (self.region_depth == 0) &self.out else &self.regions[self.region_depth - 1].lines;
            while (defers.items.len > mark) try target.print(std.testing.allocator, "d{d}\n", .{defers.pop().?});
            if (l.regions) {
                self.region_depth -= 1;
                try self.commit(&self.regions[self.region_depth]);
            }
            if (l.regions and l.form == 2 and iteration % half == half - 1) {
                self.region_depth -= 1;
                try self.commit(&self.regions[self.region_depth]);
            }
        }
        return end;
    }

    fn openRegion(self: *Model) void {
        self.region_depth += 1;
        const region = &self.regions[self.region_depth - 1];
        region.lines.clearRetainingCapacity();
        region.held.clearRetainingCapacity();
        region.handles = self.handles.items.len;
    }

    /// A region that succeeded hands what it holds to the region around it, or at depth 0
    /// commits it: its output, then its starts and signals, at the back of the queue.
    fn commit(self: *Model, region: *Region) error{OutOfMemory}!void {
        const a = std.testing.allocator;
        if (self.region_depth != 0) {
            const outer = &self.regions[self.region_depth - 1];
            try outer.lines.appendSlice(a, region.lines.items);
            try outer.held.appendSlice(a, region.held.items);
            return;
        }
        try self.out.appendSlice(a, region.lines.items);
        const begins = self.queue.items.len == 0;
        try self.queue.appendSlice(a, region.held.items);
        // The task that committed first drains the queue: signals at once, starts
        // one at a time.
        if (begins) while (self.queue.items.len != 0) {
            switch (self.queue.orderedRemove(0)) {
                .start => |next| try self.start(next),
                .signal => |s| try self.signal(s.event, s.value),
            }
        };
    }

    /// The rest of a task's body from where it waited, inside a loop if it waited in one.
    fn resumeBody(self: *Model, id: u32) error{OutOfMemory}!?u32 {
        var pc = self.tasks[id].pc;
        if (self.tasks[id].loop) |l| {
            self.tasks[id].loop = null;
            pc = (try self.loopFrom(id, l.at, l.iteration, pc, l.mark)) orelse return null;
        }
        return self.ops(id, pc, topLevel(self.script, pc, self.tasks[id].end - pc));
    }

    fn printStructured(self: *Model, id: u32) error{OutOfMemory}!void {
        const r = self.tasks[id].record;
        if (r.rush) return self.out.print(std.testing.allocator, "u{d} {d}\n", .{ r.label, r.winner.? });
        if (r.race) try self.out.print(std.testing.allocator, "r{d} {d}\n", .{ r.label, r.winner.? }) else try self.out.print(std.testing.allocator, "s{d}\n", .{r.label});
    }

    /// The `Defer`s a task registered run, the newest first: when its body ends, or (P3.3) when
    /// it is cancelled at a site.
    fn runDefers(self: *Model, id: u32) error{OutOfMemory}!void {
        const defers = self.tasks[id].defers.items;
        var k = defers.len;
        while (k > 0) {
            k -= 1;
            try self.out.print(std.testing.allocator, "d{d}\n", .{defers[k]});
        }
    }

    /// P3.4: the body's frame ends, normally or by cancellation, its `Defer`s run: the tasks it
    /// owns are asked to cancel, in order, and the task waits at the frame's end until they are
    /// settled; then it settles.
    fn frameEnd(self: *Model, id: u32, canceled: bool) error{OutOfMemory}!void {
        if (self.tasks[id].owned.items.len != 0) {
            var k = self.tasks[id].owned.items.len;
            while (k > 0) {
                k -= 1;
                try self.requests.append(std.testing.allocator, self.tasks[id].owned.items[k]);
            }
            try self.makeRequests();
            std.debug.assert(self.tasks[id].owned.items.len != 0);
            self.tasks[id].waiting = true;
            self.tasks[id].waits = .frame_end;
            self.tasks[id].end_canceled = canceled;
            self.switches += 1;
            return;
        }
        try self.finish(id, canceled);
    }

    /// The task settles: an arm tells its expression, an owned task its frame, and a spawned
    /// task that completed wakes its awaiters.
    fn finish(self: *Model, id: u32, canceled: bool) error{OutOfMemory}!void {
        if (canceled) {
            self.tasks[id].canceled = true;
            self.canceled += 1;
        } else {
            self.tasks[id].done = true;
            self.completed += 1;
        }
        if (self.tasks[id].arm) return self.armSettled(id, canceled);
        if (self.tasks[id].holder) |holder| {
            const list = &self.tasks[holder].owned;
            for (list.items, 0..) |other, at| if (other == id) {
                _ = list.orderedRemove(at);
                break;
            };
            if (list.items.len == 0 and self.tasks[holder].waiting and self.tasks[holder].waits == .frame_end) try self.wake(holder);
            return;
        }
        if (canceled) {
            // P3.7 (Q3): each task awaiting it is asked to cancel, first come first.
            const awaiters = self.tasks[id].awaiters.items;
            var k = awaiters.len;
            while (k > 0) {
                k -= 1;
                try self.requests.append(std.testing.allocator, awaiters[k]);
            }
            try self.makeRequests();
            std.debug.assert(self.tasks[id].awaiters.items.len == 0);
            return;
        }
        for (self.tasks[id].awaiters.items) |other| try self.wake(other);
        self.tasks[id].awaiters.clearRetainingCapacity();
    }

    fn run(self: *Model, id: u32) error{OutOfMemory}!void {
        return self.runFrom(id, false);
    }

    /// A task's turn: its first (`fresh`), which runs until it first waits or settles whatever
    /// it was asked, or a later one, which resumes at its site.
    fn runFrom(self: *Model, id: u32, fresh: bool) error{OutOfMemory}!void {
        const a = std.testing.allocator;
        const task = &self.tasks[id];
        task.waiting = false;
        if (task.waits == .frame_end) {
            // P3.4: its frame's tasks are settled: it ends as it was ending, asked to cancel or not.
            task.waits = .none;
            return self.finish(id, task.end_canceled);
        }
        if (task.cancel and !fresh) {
            // P3.3: a task asked to cancel unwinds at its site: its `Defer`s, then its frame's
            // end (P3.4), then it settles.
            try self.runDefers(id);
            return self.frameEnd(id, true);
        }
        switch (task.resumes) {
            .nothing => {},
            .event => try self.out.print(a, "w{d} {d}\n", .{ task.label, task.value }),
            .handle => try self.out.print(a, "h{d}\n", .{task.label}),
            .structured => if (task.record.exited) {
                // P3.6: an arm's exit: the body returns, its `Defer`s run and its frame ends.
                task.resumes = .nothing;
                try self.runDefers(id);
                return self.frameEnd(id, false);
            } else try self.printStructured(id),
        }
        task.resumes = .nothing;
        if (try self.resumeBody(id)) |_| {
            try self.runDefers(id);
            try self.frameEnd(id, false);
        }
    }

    fn all(self: *Model) !void {
        const root = self.script.bodies[self.script.body_count - 1];
        _ = (try self.ops(null, root.first, topLevel(self.script, root.first, root.count))) orelse return;
        while (!self.too_big) {
            if (self.ready.items.len != 0) {
                const id = self.ready.orderedRemove(0);
                self.switches += 1;
                try self.run(id);
                continue;
            }
            if (self.timers.items.len == 0) break;
            var earliest: u64 = never;
            for (self.timers.items) |timer| earliest = @min(earliest, timer.deadline);
            self.now = earliest;
            while (true) {
                var best: ?usize = null;
                for (self.timers.items, 0..) |timer, index| if (timer.deadline == earliest and (best == null or timer.registration < self.timers.items[best.?].registration)) {
                    best = index;
                };
                const index = best orelse break;
                try self.wake(self.timers.orderedRemove(index).task);
            }
        }
    }

    /// The tasks that never ended, which the run abandons at quiescence.
    fn unfinished(self: *const Model) usize {
        var count: usize = 0;
        for (self.tasks[0..self.task_count]) |task| count += @intFromBool(!task.done and !task.canceled);
        return count;
    }
};

const Reached = struct { checked: usize = 0, waited: usize = 0, held: usize = 0, signals: usize = 0, events: usize = 0, handles: usize = 0, canceled: u64 = 0, races: usize = 0, syncs: usize = 0, defers: usize = 0, rushes: usize = 0, branches: usize = 0, exits: usize = 0, abandoned: usize = 0, cancels: usize = 0, spawned_canceled: usize = 0, propagated: usize = 0, loops: usize = 0, loop_waits: usize = 0, loop_cancels: usize = 0 };

fn check(h: *harness.Harness, seed: u64, runs: usize, events: bool, structured: bool) !Reached {
    return checkWith(h, seed, runs, events, structured, false);
}

fn checkWith(h: *harness.Harness, seed: u64, runs: usize, events: bool, structured: bool, owned: bool) !Reached {
    return checkAll(h, seed, runs, events, structured, owned, false);
}

fn checkAll(h: *harness.Harness, seed: u64, runs: usize, events: bool, structured: bool, owned: bool, exits: bool) !Reached {
    return checkCancels(h, seed, runs, events, structured, owned, exits, false);
}

fn checkCancels(h: *harness.Harness, seed: u64, runs: usize, events: bool, structured: bool, owned: bool, exits: bool, cancels: bool) !Reached {
    return checkLoops(h, seed, runs, events, structured, owned, exits, cancels, false);
}

fn checkLoops(h: *harness.Harness, seed: u64, runs: usize, events: bool, structured: bool, owned: bool, exits: bool, cancels: bool, loops: bool) !Reached {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var source: [16 * 1024]u8 = undefined;
    var output: [16 * 1024]u8 = undefined;
    var reached: Reached = .{};
    for (0..runs) |_| {
        const script = generateLoops(random, events, structured, owned, exits, cancels, loops);
        var model: Model = .{ .script = &script };
        defer model.deinit();
        try model.all();
        if (model.too_big) continue;
        var out: std.Io.Writer = .fixed(&source);
        try writeProgram(&script, &out);
        const text = out.buffered();
        const x = concurrency.expectRun(h, text) catch |err| {
            std.debug.print("{s}\n", .{text});
            return err;
        };
        const printed = concurrency.printed(x, &output);
        if (!std.mem.eql(u8, model.out.items, printed) or model.now != x.scheduler.tick or model.created != x.scheduler.created or model.completed != x.scheduler.completed or model.canceled != x.scheduler.canceled or model.switches != x.scheduler.switches or model.unfinished() != x.scheduler.waiting.len) {
            std.debug.print("model: tick {d} created {d} completed {d} canceled {d} switches {d} unfinished {d}\n{s}\nmachines: {any}\n{s}\nprogram:\n{s}\n", .{ model.now, model.created, model.completed, model.canceled, model.switches, model.unfinished(), model.out.items, x.scheduler, printed, text });
            return error.TestUnexpectedResult;
        }
        reached.checked += 1;
        reached.waited += x.scheduler.waiting.len;
        reached.held += @intFromBool(std.mem.indexOf(u8, text, "Attempt(Block{ Spawn") != null or std.mem.indexOf(u8, text, "Attempt(Block{ Keep(") != null);
        reached.signals += @intFromBool(std.mem.indexOf(u8, text, "Attempt(Block{ E") != null);
        reached.events += std.mem.count(u8, model.out.items, " ");
        reached.handles += std.mem.count(u8, model.out.items, "h");
        reached.canceled += model.canceled;
        reached.races += std.mem.count(u8, model.out.items, "\nr");
        reached.syncs += std.mem.count(u8, model.out.items, "\ns");
        reached.defers += std.mem.count(u8, model.out.items, "\nd");
        reached.rushes += std.mem.count(u8, model.out.items, "\nu");
        reached.branches += std.mem.count(u8, text, "Branch{");
        reached.exits += std.mem.count(u8, text, "Return(");
        for (model.tasks[0..model.task_count]) |task| reached.abandoned += @intFromBool(task.record.exited);
        reached.cancels += std.mem.count(u8, model.out.items, "\nc");
        // Spawned tasks cancelled, and awaiters cancelled by what they awaited (P3.7).
        for (model.tasks[0..model.task_count]) |task| reached.spawned_canceled += @intFromBool(task.canceled and !task.arm and task.holder == null);
        for (model.tasks[0..model.task_count]) |task| reached.propagated += @intFromBool(task.canceled and task.waits == .handle);
        reached.loops += std.mem.count(u8, text, "For(");
        reached.loop_waits += model.loop_waits;
        // Tasks cancelled while they waited in a loop.
        for (model.tasks[0..model.task_count]) |task| reached.loop_cancels += @intFromBool(task.canceled and task.loop != null);
    }
    return reached;
}

test "a thousand random scripts of spawns, sleeps, prints and regions run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try check(h, 0x0082_5ced, 1000, false, false);
    // The generator reaches what it is for.
    try std.testing.expect(reached.checked > 600 and reached.waited > 50 and reached.held > 50);
}

test "a thousand random scripts with signals, awaits of events and awaits of handles run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try check(h, 0x0082_e7e5, 1000, true, false);
    // Signals held by regions, values woken by signals, and handles awaited, all reached.
    try std.testing.expect(reached.checked > 600 and reached.waited > 30 and reached.held > 50 and reached.signals > 50 and reached.events > 150 and reached.handles > 40);
}

test "two thousand random scripts with Sync, Race, Defer and cancellation run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try check(h, 0x0082_5733, 2000, true, true);
    // Expressions of both kinds, losers cancelled, and Defers run at ends and in landings.
    try std.testing.expect(reached.checked > 1000 and reached.races > 60 and reached.syncs > 60 and reached.canceled > 70 and reached.defers > 150);
}

test "two thousand random scripts with Rush, Branch, frames that wait for what they own and cancellation run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try checkWith(h, 0x0082_b4a0, 2000, true, true, true);
    // Rushes resolved, branches started, and cancellations at frames' ends, all reached.
    try std.testing.expect(reached.checked > 1000 and reached.rushes > 60 and reached.branches > 300 and reached.canceled > 100 and reached.races > 40);
}

test "two thousand random scripts whose arms return from the function their expression stands in run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try checkAll(h, 0x0082_e1a6, 2000, true, true, true, true);
    // Expressions abandoned by an arm's exit, with the rest still reached.
    try std.testing.expect(reached.checked > 1000 and reached.exits > 300 and reached.abandoned > 40 and reached.canceled > 60 and reached.races > 20 and reached.rushes > 20);
}

test "three thousand random scripts that cancel tasks, await cancelled tasks and propagate cancellation run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try checkCancels(h, 0x0082_ca9c, 3000, true, true, true, false, true);
    errdefer std.debug.print("reached: {any}\n", .{reached});
    // Cancels made, spawned tasks cancelled, and awaiters cancelled by what they awaited.
    try std.testing.expect(reached.checked > 2000 and reached.cancels > 120 and reached.spawned_canceled > 50 and reached.propagated > 20 and reached.races > 40 and reached.rushes > 25);
}

test "three thousand random scripts whose task bodies hold For loops that suspend run on both machines as the model says" {
    const h = try harness.create();
    defer scratch.release(h);
    const reached = try checkLoops(h, 0x0082_f0e5, 3000, true, true, true, false, true, true);
    errdefer std.debug.print("reached: {any}\n", .{reached});
    // Loops of every form, tasks that wait in them, and tasks cancelled while they wait in one,
    // with the rest still reached.
    try std.testing.expect(reached.checked > 1500 and reached.loops > 1000 and reached.loop_waits > 150 and reached.loop_cancels > 25 and reached.defers > 150 and reached.cancels > 60);
}
