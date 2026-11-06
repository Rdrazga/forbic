//! The full randomised oracle of RFC-0085 Part 1 (I6): one generator composes every form of I1
//! to I5 in one program. `Fn` closures, nested functions (plain, with a default, overloaded),
//! task bodies, `Sync` and `Race` arms, `When` and `Upon` bodies, `Batch{}` bodies and the
//! landing of a `Defer` in a losing arm all share locals and cells of one function, call each
//! other, and are run against a plain model of the locals (S1, S2, S4, S7, S8) and of RFC-0082's
//! scheduler (S5), on both machines, in all three trace modes, with the replay admitting every
//! digest report as the full report.
const std = @import("std");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");
const replay = @import("trace_replay.zig");
const profile = @import("profile.zig");

const allocator = std.testing.allocator;

// ---- The program shape.
//
// `Run` is a suspending function spawned by the root, with `var` locals `V0..`, `Acc` and the
// module `var`s `Out` (its result) and `G` (what reactions watch). Its statements build closures
// `F0..` in order, assign locals, call closures (directly, in an `Attempt` that fails past a
// bound, in a `For` whose visits may fail), `Spawn` bodies, `Sleep`, `Await`, run one `Sync` and
// one `Race` whose first arm has a `Defer`, run `Batch{}` bodies, make `When` and `Upon`
// reactions and write `G`. Every closure form may assign locals (sharing them, S1d) and call an
// earlier closure (carrying its captures, S7); a nested function shares every local it names
// (S1a); since I13 (Q1, S1e) so does every other closure form, so a local any of them names is
// shared and read as the variable. The model of the rules before Q1 is kept (`names_share`
// false, with `Workspace.share_names` off): an `Fn`, a body or an arm reads a local nothing
// shares as it was when it was built (S8). The model below is a plain interpreter of exactly that.

const max_vars = 6;
const max_closures = 5;
const max_bodies = 10;
const max_reactions = 4;
const max_statements = 14;
const no_call: u8 = std.math.maxInt(u8);

const Assign = struct { v: u8, c: i64 };
/// How a closure is called: `F()` (a default), `F(a)`, `F(K := a)`, `F(a, b)` (an overload).
const Form = enum { none, one, named, two };
const Args = struct {
    form: Form = .one,
    a: i64 = 0,
    b: i64 = 0,
    /// In a `For` body the first argument is the visit `I`.
    visit: bool = false,
};
/// `recursive` calls itself with `K - 1` until `K <= 0` (S7, `recur`).
const Kind = enum { closure, nested, defaulted, overloaded, recursive };
const Closure = struct {
    kind: Kind = .closure,
    /// Assignments of the body; the first one also adds the parameter `K`.
    assigns: [3]Assign = undefined,
    count: u8 = 0,
    read: u8 = 0,
    plus: i64 = 0,
    /// An earlier closure the body calls before its read, `no_call` for none.
    calls: u8 = no_call,
    args: Args = .{},
    default_value: i64 = 0,
};
/// A task body or an arm: assignments, one `Sleep`, assignments, a call, a read. The first arm
/// of the `Race` has only a `Defer` (`pre[0]`, and `calls`) and its sleep, and yields 1.
const Body = struct {
    pre: [2]Assign = undefined,
    pre_count: u8 = 0,
    sleep: u8 = 1,
    post: [2]Assign = undefined,
    post_count: u8 = 0,
    calls: u8 = no_call,
    args: Args = .{},
    read: u8 = 0,
    plus: i64 = 0,
    defer_arm: bool = false,
};
/// A reaction's body: `set V = V * 3 + Vsrc + G + c + C`, `C` what it calls, so that the order
/// of deliveries and what the body read of a local nothing shares (S8) reach the result.
const Reaction = struct { upon: bool, threshold: i64 = 0, v: u8, c: i64, src: u8 = 0, calls: u8 = no_call, args: Args = .{} };
const Call = struct { f: u8, args: Args };
const Statement = union(enum) {
    build: u8,
    set: Assign,
    call: Call,
    attempt: struct { f: u8, args: Args, limit: i64 },
    loop: struct { v: u8, f: u8, args: Args, visits: u8, limit: ?i64 },
    spawn: u8,
    sleep: u8,
    await_task: u8,
    sync: [2]u8,
    race: [2]u8,
    batch: struct { v: u8, c: i64, calls: u8, args: Args },
    react: u8,
    set_g: i64,
    /// A closure as a value (S7): held in a module `var`, called from it, and picked from a tuple.
    keep: u8,
    call_kept: Args,
    pair: struct { a: u8, b: u8, second: bool, args: Args },
    /// A `Branch{}` body: a task owned by `Run`'s frame, never awaited.
    branch: u8,
    /// A `Loop{}` of `Run` that sleeps in each visit and then assigns a local, which it carries
    /// unless the local is shared (S2).
    sleep_loop: struct { v: u8, c: i64, visits: u8 },
};

pub const Model = struct {
    vars: u8,
    /// Closure forms assign only the locals below this; the others only `Run` assigns, so they
    /// stay unshared unless a nested function names one, and closures read their snapshots (S8).
    shareable: u8,
    initial: [max_vars]i64,
    closures: [max_closures]Closure,
    closure_count: u8,
    bodies: [max_bodies]Body,
    body_count: u8,
    reactions: [max_reactions]Reaction,
    reaction_count: u8,
    statements: [4 * max_statements + max_closures]Statement,
    statement_count: u8,
    /// Q1 (I13, S1e): a local any closure form names is shared, not only one it assigns.
    names_share: bool,

    /// S1: a local is shared when a closure form assigns it (S1d) or a nested function names it
    /// (S1a), and, under Q1 (S1e), when any closure form names it. The `For` of a statement is
    /// not a closure form.
    fn shared(self: *const Model, v: u8) bool {
        for (self.closures[0..self.closure_count]) |c| {
            for (c.assigns[0..c.count]) |a| if (a.v == v) return true;
            if ((c.kind != .closure or self.names_share) and c.read == v) return true;
        }
        for (self.bodies[0..self.body_count]) |b| {
            for (b.pre[0..b.pre_count]) |a| if (a.v == v) return true;
            for (b.post[0..b.post_count]) |a| if (a.v == v) return true;
            // A `Defer` arm reads nothing: its `read` is not written.
            if (self.names_share and !b.defer_arm and b.read == v) return true;
        }
        for (self.reactions[0..self.reaction_count]) |r| if (r.v == v or (self.names_share and r.src == v)) return true;
        for (self.statements[0..self.statement_count]) |s| if (s == .batch and s.batch.v == v) return true;
        return false;
    }
    fn anyShared(self: *const Model) bool {
        for (0..self.vars) |v| if (self.shared(@intCast(v))) return true;
        return false;
    }

    fn argsFor(random: std.Random, kind: Kind) Args {
        const a = random.intRangeAtMost(i64, 0, 9);
        const b = random.intRangeAtMost(i64, 0, 4);
        return switch (kind) {
            .closure, .nested => .{ .form = .one, .a = a },
            .defaulted => .{ .form = switch (random.uintLessThan(u8, 3)) {
                0 => .none,
                1 => .one,
                else => .named,
            }, .a = a },
            .overloaded => .{ .form = if (random.boolean()) .one else .two, .a = a, .b = b },
            .recursive => .{ .form = .one, .a = random.intRangeAtMost(i64, 0, 3) },
        };
    }
    fn assign(random: std.Random, vars: u8) Assign {
        return .{ .v = random.uintLessThan(u8, vars), .c = random.intRangeAtMost(i64, -3, 7) };
    }
    /// A call of one of the `built` closures, or none.
    fn callOf(self: *const Model, random: std.Random, built: u8) Call {
        if (built == 0 or random.uintLessThan(u8, 3) == 0) return .{ .f = no_call, .args = .{} };
        const f = random.uintLessThan(u8, built);
        return .{ .f = f, .args = argsFor(random, self.closures[f].kind) };
    }
    /// A local, one that closure forms do not assign half of the time when there is one.
    fn unshared(self: *const Model, random: std.Random) u8 {
        if (self.shareable < self.vars and random.boolean()) return self.shareable + random.uintLessThan(u8, self.vars - self.shareable);
        return random.uintLessThan(u8, self.vars);
    }
    /// One of the `built` closures that is not overloaded, or null when there is none.
    fn valueOf(self: *const Model, random: std.Random, built: u8) ?u8 {
        var candidates: [max_closures]u8 = undefined;
        var count: u8 = 0;
        for (self.closures[0..built], 0..) |c, f| if (c.kind != .overloaded) {
            candidates[count] = @intCast(f);
            count += 1;
        };
        if (count == 0) return null;
        return candidates[random.uintLessThan(u8, count)];
    }
    fn newBody(self: *Model, random: std.Random, built: u8) u8 {
        const body = &self.bodies[self.body_count];
        body.* = .{};
        body.pre_count = random.uintLessThan(u8, 2);
        for (body.pre[0..body.pre_count]) |*a| a.* = assign(random, self.shareable);
        body.sleep = 1 + random.uintLessThan(u8, 3);
        body.post_count = random.uintLessThan(u8, 3);
        for (body.post[0..body.post_count]) |*a| a.* = assign(random, self.shareable);
        const call = self.callOf(random, built);
        body.calls = call.f;
        body.args = call.args;
        body.read = self.unshared(random);
        body.plus = random.intRangeAtMost(i64, 0, 5);
        self.body_count += 1;
        return self.body_count - 1;
    }

    pub fn generate(random: std.Random, names_share: bool) Model {
        var m: Model = undefined;
        m.names_share = names_share;
        m.vars = 1 + random.uintLessThan(u8, max_vars);
        for (m.initial[0..m.vars]) |*value| value.* = random.intRangeAtMost(i64, -5, 9);
        m.shareable = if (random.boolean()) m.vars else (m.vars + 1) / 2;
        m.closure_count = 1 + random.uintLessThan(u8, max_closures);
        for (m.closures[0..m.closure_count], 0..) |*c, f| {
            c.* = .{};
            c.kind = random.enumValue(Kind);
            c.count = random.uintLessThan(u8, 3);
            for (c.assigns[0..c.count]) |*a| a.* = assign(random, m.shareable);
            // A nested function shares what it names (S1a): it reads a shareable local.
            c.read = if (c.kind == .closure) m.unshared(random) else random.uintLessThan(u8, m.shareable);
            c.plus = random.intRangeAtMost(i64, 0, 5);
            c.default_value = random.intRangeAtMost(i64, -2, 6);
            if (f != 0 and random.uintLessThan(u8, 3) == 0) {
                c.calls = random.uintLessThan(u8, @intCast(f));
                c.args = argsFor(random, m.closures[c.calls].kind);
            }
        }
        m.body_count = 0;
        m.reaction_count = 0;
        m.statement_count = 0;
        var built: u8 = 0;
        var spawned: [max_bodies]u8 = undefined;
        var spawn_count: u8 = 0;
        var synced = false;
        var raced = false;
        var loops: u8 = 0;
        var batches: u8 = 0;
        var sleep_loops: u8 = 0;
        const total = 4 + random.uintLessThan(u8, max_statements - 3);
        for (0..total) |_| {
            // Closures are built in order, so a statement can call only those built before it.
            if (built < m.closure_count and (built == 0 or random.uintLessThan(u8, 3) == 0)) {
                m.statements[m.statement_count] = .{ .build = built };
                m.statement_count += 1;
                built += 1;
            }
            const v = m.unshared(random);
            // What a closure form assigns.
            const w = random.uintLessThan(u8, m.shareable);
            const call = m.callOf(random, built);
            const f = random.uintLessThan(u8, built);
            const args = argsFor(random, m.closures[f].kind);
            // A closure that is a value: any but an overloaded one, which no context selects here.
            const value = m.valueOf(random, built);
            const one: Args = .{ .form = .one, .a = random.intRangeAtMost(i64, 0, 3) };
            m.statements[m.statement_count] = switch (random.uintLessThan(u8, 17)) {
                0 => .{ .set = assign(random, m.vars) },
                1 => .{ .call = .{ .f = f, .args = args } },
                2 => .{ .attempt = .{ .f = f, .args = args, .limit = random.intRangeAtMost(i64, -2, 20) } },
                3 => if (loops < 3) loop: {
                    loops += 1;
                    var visit_args = args;
                    visit_args.visit = true;
                    if (visit_args.form == .none) visit_args.form = .one;
                    break :loop .{ .loop = .{ .v = v, .f = f, .args = visit_args, .visits = 1 + random.uintLessThan(u8, 3), .limit = if (random.boolean()) random.intRangeAtMost(i64, 0, 25) else null } };
                } else .{ .set = .{ .v = v, .c = 1 } },
                4 => if (m.body_count < max_bodies - 4) spawn: {
                    spawned[spawn_count] = m.body_count;
                    spawn_count += 1;
                    break :spawn .{ .spawn = m.newBody(random, built) };
                } else .{ .set = .{ .v = v, .c = 2 } },
                5 => .{ .sleep = 1 + random.uintLessThan(u8, 3) },
                6 => if (spawn_count != 0) .{ .await_task = spawned[random.uintLessThan(u8, spawn_count)] } else .{ .sleep = 1 },
                7 => if (!synced) sync: {
                    synced = true;
                    const a = m.newBody(random, built);
                    break :sync .{ .sync = .{ a, m.newBody(random, built) } };
                } else .{ .set = .{ .v = v, .c = 3 } },
                8 => if (!raced) race: {
                    raced = true;
                    const other = m.newBody(random, built);
                    const first = m.newBody(random, built);
                    const arm = &m.bodies[first];
                    arm.* = .{ .defer_arm = true };
                    arm.pre_count = 1;
                    arm.pre[0] = assign(random, m.shareable);
                    arm.calls = call.f;
                    arm.args = call.args;
                    // Different sleeps: the arm that wakes first wins, and the loser is still
                    // asleep when it is asked to cancel.
                    arm.sleep = 1 + random.uintLessThan(u8, 4);
                    while (m.bodies[other].sleep == arm.sleep) m.bodies[other].sleep = 1 + random.uintLessThan(u8, 4);
                    break :race .{ .race = .{ first, other } };
                } else .{ .set = .{ .v = v, .c = 4 } },
                9 => if (batches < 2) batch: {
                    batches += 1;
                    break :batch .{ .batch = .{ .v = w, .c = random.intRangeAtMost(i64, -3, 6), .calls = call.f, .args = call.args } };
                } else .{ .set = .{ .v = v, .c = 5 } },
                10 => if (m.reaction_count < max_reactions) react: {
                    m.reactions[m.reaction_count] = .{ .upon = random.boolean(), .threshold = random.intRangeAtMost(i64, 0, 8), .v = w, .c = random.intRangeAtMost(i64, -2, 4), .src = m.unshared(random), .calls = call.f, .args = call.args };
                    m.reaction_count += 1;
                    break :react .{ .react = m.reaction_count - 1 };
                } else .{ .set_g = 1 + random.intRangeAtMost(i64, 0, 4) },
                11 => .{ .set_g = 1 + random.intRangeAtMost(i64, 0, 4) },
                12 => if (value) |k| .{ .keep = k } else .{ .set = assign(random, m.vars) },
                13 => .{ .call_kept = one },
                14 => if (value) |a| .{ .pair = .{ .a = a, .b = m.valueOf(random, built).?, .second = random.boolean(), .args = one } } else .{ .set_g = 1 },
                15 => if (m.body_count < max_bodies - 4) .{ .branch = m.newBody(random, built) } else .{ .set = .{ .v = v, .c = 6 } },
                else => if (sleep_loops < 2) sleep_loop: {
                    sleep_loops += 1;
                    break :sleep_loop .{ .sleep_loop = .{ .v = v, .c = random.intRangeAtMost(i64, -3, 6), .visits = 1 + random.uintLessThan(u8, 3) } };
                } else .{ .sleep = 1 },
            };
            m.statement_count += 1;
            // A second reaction beside the one just made, on the same local or reading it, and a
            // write of `G` that delivers to both: the order of deliveries reaches the result.
            if (m.statements[m.statement_count - 1] == .react and m.reaction_count < max_reactions and random.boolean()) {
                const first_reaction = m.reactions[m.reaction_count - 1];
                const same = random.boolean();
                m.reactions[m.reaction_count] = .{ .upon = random.boolean(), .threshold = random.intRangeAtMost(i64, 0, 4), .v = if (same) first_reaction.v else random.uintLessThan(u8, m.shareable), .c = random.intRangeAtMost(i64, -2, 4), .src = if (same) m.unshared(random) else first_reaction.v };
                m.reaction_count += 1;
                m.statements[m.statement_count] = .{ .react = m.reaction_count - 1 };
                m.statements[m.statement_count + 1] = .{ .set_g = 1 + random.intRangeAtMost(i64, 0, 4) };
                m.statement_count += 2;
            }
            // `Run` changes a local after closures took their snapshots of it.
            if (random.boolean()) {
                m.statements[m.statement_count] = .{ .set = .{ .v = m.unshared(random), .c = random.intRangeAtMost(i64, 1, 9) } };
                m.statement_count += 1;
            }
        }
        // Closures never built assign nothing anyone sees, and share nothing.
        m.closure_count = built;
        return m;
    }

    // ---- The program text.

    fn writeCall(out: *std.Io.Writer, f: u8, args: Args) !void {
        try out.print("F{d}", .{f});
        const a: []const u8 = if (args.visit) "I" else "";
        switch (args.form) {
            .none => try out.writeAll("()"),
            .one => if (args.visit) try out.print("({s})", .{a}) else try out.print("({d})", .{args.a}),
            .named => if (args.visit) try out.print("(K:={s})", .{a}) else try out.print("(K:={d})", .{args.a}),
            .two => if (args.visit) try out.print("({s},{d})", .{ a, args.b }) else try out.print("({d},{d})", .{ args.a, args.b }),
        }
    }
    fn writeClosureBody(self: *const Model, out: *std.Io.Writer, f: u8, k: []const u8) !void {
        const c = self.closures[f];
        for (c.assigns[0..c.count], 0..) |a, index| {
            try out.print("set V{d}=V{d}+{d}", .{ a.v, a.v, a.c });
            if (index == 0) try out.print("+{s}", .{k});
            try out.writeAll(";");
        }
        if (c.calls != no_call) {
            try out.writeAll("C:=");
            try writeCall(out, c.calls, c.args);
            try out.writeAll(";");
        }
        if (c.kind == .recursive) try out.writeAll("If(K<=0,");
        try out.print("V{d}+{d}+{s}", .{ c.read, c.plus, k });
        if (c.calls != no_call) try out.writeAll("+C");
        if (c.kind == .recursive) try out.print(",F{d}(K-1))", .{f});
    }
    fn writeClosure(self: *const Model, out: *std.Io.Writer, f: u8) !void {
        const c = self.closures[f];
        switch (c.kind) {
            .closure => {
                try out.print("F{d}:=Fn(K:i64)<transacts>:i64{{Block{{", .{f});
                try self.writeClosureBody(out, f, "K");
                try out.writeAll("}}\n");
            },
            .nested, .recursive => {
                try out.print("F{d}(K:i64)<transacts>:i64=Block{{", .{f});
                try self.writeClosureBody(out, f, "K");
                try out.writeAll("}\n");
            },
            .defaulted => {
                try out.print("F{d}(K:i64={d})<transacts>:i64=Block{{", .{ f, c.default_value });
                try self.writeClosureBody(out, f, "K");
                try out.writeAll("}\n");
            },
            .overloaded => {
                try out.print("F{d}(K:i64)<transacts>:i64=Block{{", .{f});
                try self.writeClosureBody(out, f, "K");
                try out.print("}}\nF{d}(K:i64,J:i64)<transacts>:i64=Block{{", .{f});
                try self.writeClosureBody(out, f, "(K+J)");
                try out.writeAll("}\n");
            },
        }
    }
    fn writeBody(self: *const Model, out: *std.Io.Writer, b: u8) !void {
        const body = self.bodies[b];
        if (body.defer_arm) {
            try out.print("Defer{{set V{d}=V{d}+{d}", .{ body.pre[0].v, body.pre[0].v, body.pre[0].c });
            if (body.calls != no_call) {
                try out.writeAll(";");
                try writeCall(out, body.calls, body.args);
            }
            try out.print("}};Sleep({d}.0);1", .{body.sleep});
            return;
        }
        for (body.pre[0..body.pre_count]) |a| try out.print("set V{d}=V{d}+{d};", .{ a.v, a.v, a.c });
        try out.print("Sleep({d}.0);", .{body.sleep});
        for (body.post[0..body.post_count]) |a| try out.print("set V{d}=V{d}+{d};", .{ a.v, a.v, a.c });
        if (body.calls != no_call) {
            try out.writeAll("C:=");
            try writeCall(out, body.calls, body.args);
            try out.writeAll(";");
        }
        try out.print("V{d}+{d}", .{ body.read, body.plus });
        if (body.calls != no_call) try out.writeAll("+C");
    }
    pub fn write(self: *const Model, out: *std.Io.Writer) !void {
        try out.writeAll("var Out:[]i64=array{}\nvar G:i64=0\nvar Keep:option(function<transacts>(tuple(i64),i64))=option{}\nRun()<transacts><suspends>:i64=Block{\n");
        for (self.initial[0..self.vars], 0..) |value, v| try out.print("var V{d}:i64={d}\n", .{ v, value });
        try out.writeAll("var Acc:i64=0\n");
        for (self.statements[0..self.statement_count], 0..) |s, index| switch (s) {
            .build => |f| try self.writeClosure(out, f),
            .set => |a| try out.print("set V{d}=V{d}+{d}\n", .{ a.v, a.v, a.c }),
            .call => |call| {
                try out.writeAll("set Acc=Acc+");
                try writeCall(out, call.f, call.args);
                try out.writeAll("\n");
            },
            .attempt => |a| {
                try out.writeAll("set Acc=Acc+Attempt(Block{A:=");
                try writeCall(out, a.f, a.args);
                try out.print(";Require[A<{d}];A}},-1)\n", .{a.limit});
            },
            .loop => |l| {
                try out.print("For(I:1..{d},Block{{set V{d}=V{d}+I;R:=", .{ l.visits, l.v, l.v });
                try writeCall(out, l.f, l.args);
                if (l.limit) |limit| try out.print(";Require[R<{d}];R}})\n", .{limit}) else try out.writeAll(";R})\n");
            },
            .spawn => |b| {
                try out.print("T{d}:=Spawn{{", .{b});
                try self.writeBody(out, b);
                try out.writeAll("}\n");
            },
            .sleep => |d| try out.print("Sleep({d}.0)\n", .{d}),
            .await_task => |b| try out.print("set Acc=Acc*3+T{d}.Await()\n", .{b}),
            .sync => |arms| {
                try out.print("S{d}:=Sync(Block{{", .{index});
                try self.writeBody(out, arms[0]);
                try out.writeAll("},Block{");
                try self.writeBody(out, arms[1]);
                try out.print("}})\nset Acc=Acc*5+S{d}(0)*2+S{d}(1)\n", .{ index, index });
            },
            .race => |arms| {
                try out.print("W{d}:=Race(Block{{", .{index});
                try self.writeBody(out, arms[0]);
                try out.writeAll("},Block{");
                try self.writeBody(out, arms[1]);
                try out.print("}})\nset Acc=Acc*7+W{d}\n", .{index});
            },
            .batch => |b| {
                try out.print("B{d}:i64=Batch{{set V{d}=V{d}+{d};", .{ index, b.v, b.v, b.c });
                if (b.calls != no_call) {
                    try out.writeAll("C:=");
                    try writeCall(out, b.calls, b.args);
                    try out.print(";V{d}+C}}\n", .{b.v});
                } else try out.print("V{d}}}\n", .{b.v});
                try out.print("set Acc=Acc+B{d}\n", .{index});
            },
            .react => |r| {
                const reaction = self.reactions[r];
                if (reaction.upon) try out.print("Q{d}:=Upon(G>={d},Block{{", .{ index, reaction.threshold }) else try out.print("Q{d}:=When(G,Block{{", .{index});
                if (reaction.calls != no_call) {
                    try out.writeAll("C:=");
                    try writeCall(out, reaction.calls, reaction.args);
                    try out.writeAll(";");
                }
                try out.print("set V{d}=V{d}*3+V{d}+G+{d}", .{ reaction.v, reaction.v, reaction.src, reaction.c });
                if (reaction.calls != no_call) try out.writeAll("+C");
                try out.writeAll(";0})\n");
            },
            .set_g => |k| try out.print("set G=G+{d}\n", .{k}),
            .keep => |k| try out.print("set Keep=option{{F{d}}}\n", .{k}),
            .call_kept => |args| try out.print("set Acc=Acc+Attempt(Keep?({d}),-1)\n", .{args.a}),
            .pair => |pair| try out.print("set Acc=Acc+tuple{{F{d},F{d}}}({d})({d})\n", .{ pair.a, pair.b, @intFromBool(pair.second), pair.args.a }),
            .branch => |b| {
                try out.writeAll("Branch{");
                try self.writeBody(out, b);
                try out.writeAll("}\n");
            },
            .sleep_loop => |l| try out.print("var L{d}:i64=0\nLoop{{If(L{d}>={d},Break(),false);Sleep(1.0);set V{d}=V{d}+{d};set L{d}=L{d}+1}}\n", .{ index, index, l.visits, l.v, l.v, l.c, index, index }),
        };
        try out.writeAll("set Out=array{Acc,G");
        for (0..self.vars) |v| try out.print(",V{d}", .{v});
        try out.writeAll("}\n0}\nP:task(i64)=Spawn{Run()}");
    }

    // ---- The model.

    /// The run under the scheduler: task 0 is `Run`, task `1 + b` runs body `b`.
    const Wait = enum { none, timer, task, record, done };
    const Task = struct { phase: u8 = 0, wait: Wait = .none, deadline: u64 = 0, registration: u64 = 0, target: u8 = 0, result: i64 = 0, cancel: bool = false, snapshot: [max_vars]i64 = undefined };
    const Record = struct { race: bool = false, arms: [2]u8 = undefined, settled: u8 = 0, winner: ?u8 = null };
    pub const out_length = 2 + max_vars;
    const Run = struct {
        model: *const Model,
        vars: [max_vars]i64,
        acc: i64 = 0,
        g: i64 = 0,
        pc: u8 = 0,
        /// What an `Fn` built here read of the locals nothing shares (S8).
        closure_snapshots: [max_closures][max_vars]i64 = undefined,
        tasks: [1 + max_bodies]Task = @splat(.{}),
        record: Record = .{},
        created: [max_reactions]bool = @splat(false),
        fired: [max_reactions]bool = @splat(false),
        ready: [128]u8 = undefined,
        ready_head: usize = 0,
        ready_tail: usize = 0,
        now: u64 = 0,
        registrations: u64 = 0,
        out: ?[out_length]i64 = null,
        /// The closure `Keep` holds.
        kept: ?u8 = null,
        /// The visits left of the `Loop{}` `Run` sleeps in, and what each visit assigns.
        loop_left: u8 = 0,
        loop_assign: Assign = undefined,
        /// What each reaction read of the locals when it was made.
        reaction_snapshots: [max_reactions][max_vars]i64 = undefined,
        /// Reads of a local nothing shares whose snapshot differed from its value then (S8).
        stale: usize = 0,
        mutation: Mutation = .none,

        /// What a closure built with `snapshot` reads of local `v`: the cell if `v` is shared,
        /// else the snapshot (S8).
        fn seen(self: *Run, snapshot: *const [max_vars]i64, v: u8) i64 {
            if (self.mutation == .snapshot) {
                // Wrong on purpose: the rules before Q1, under which a local nothing assigns
                // is read as a snapshot.
                var before = self.model.*;
                before.names_share = false;
                if (!before.shared(v)) return snapshot[v];
            }
            if (self.model.shared(v)) return self.vars[v];
            if (snapshot[v] != self.vars[v]) self.stale += 1;
            return if (self.mutation == .current) self.vars[v] else snapshot[v];
        }

        fn push(self: *Run, task: u8) void {
            self.ready[self.ready_tail] = task;
            self.ready_tail += 1;
        }
        fn sleep(self: *Run, task: u8, seconds: u8) void {
            self.registrations += 1;
            self.tasks[task].wait = .timer;
            self.tasks[task].deadline = self.now + seconds;
            self.tasks[task].registration = self.registrations;
        }
        /// The value `K` a call passes: a default, an argument, or the sum an overload adds.
        fn argument(self: *const Run, f: u8, args: Args, visit: i64) i64 {
            const a = if (args.visit) visit else args.a;
            return switch (args.form) {
                .none => self.model.closures[f].default_value,
                .one, .named => a,
                .two => a + args.b,
            };
        }
        fn call(self: *Run, f: u8, k: i64) i64 {
            const c = self.model.closures[f];
            for (c.assigns[0..c.count], 0..) |a, index| self.vars[a.v] += a.c + @as(i64, if (index == 0) k else 0);
            const called = if (c.calls != no_call) self.call(c.calls, self.argument(c.calls, c.args, 0)) else 0;
            if (c.kind == .recursive and k > 0) return self.call(f, k - 1);
            // A nested function names the local and shares it (S1a); an `Fn` that does not assign
            // it read it when it was built (S8).
            const value = if (c.kind == .closure) self.seen(&self.closure_snapshots[f], c.read) else self.vars[c.read];
            return value + c.plus + k + called;
        }
        fn callIf(self: *Run, f: u8, args: Args) i64 {
            if (f == no_call) return 0;
            return self.call(f, self.argument(f, args, 0));
        }
        fn react(self: *Run, r: u8) void {
            const reaction = self.model.reactions[r];
            const called = self.callIf(reaction.calls, reaction.args);
            const source = self.seen(&self.reaction_snapshots[r], reaction.src);
            self.vars[reaction.v] = self.vars[reaction.v] * 3 + source + self.g + reaction.c + called;
        }
        /// Deliveries after a write of `G` outside every region, in the order of first trigger.
        fn deliver(self: *Run) void {
            for (0..self.model.reaction_count) |index| {
                const r = if (self.mutation == .reversed) self.model.reaction_count - 1 - index else index;
                const reaction = self.model.reactions[r];
                if (!self.created[r]) continue;
                if (reaction.upon) {
                    if (!self.fired[r] and self.g >= reaction.threshold) {
                        self.fired[r] = true;
                        self.react(@intCast(r));
                    }
                } else self.react(@intCast(r));
            }
        }
        fn read(self: *Run, b: u8, v: u8) i64 {
            return self.seen(&self.tasks[1 + b].snapshot, v);
        }
        fn isArm(self: *const Run, b: u8) bool {
            return self.tasks[0].wait == .record and (self.record.arms[0] == b or self.record.arms[1] == b);
        }
        /// An arm settled: a `Sync` waits for both; a `Race`'s first completion wins and asks
        /// the other arm to cancel, which wakes it to yield cancelled when it runs.
        fn armSettled(self: *Run, b: u8, canceled: bool) void {
            const r = &self.record;
            r.settled += 1;
            if (r.race and !canceled and r.winner == null) {
                r.winner = b;
                const other = if (r.arms[0] == b) r.arms[1] else r.arms[0];
                const loser = &self.tasks[1 + other];
                if (loser.wait != .done) {
                    loser.cancel = true;
                    // The generator keeps the loser asleep at this point.
                    std.debug.assert(loser.wait == .timer);
                    loser.wait = .none;
                    self.push(1 + other);
                }
            }
            if (r.settled == 2) self.push(0);
        }
        /// Runs body `b` from where it stands until its `Sleep` or its end.
        fn body(self: *Run, b: u8) void {
            const task = 1 + b;
            const shape = self.model.bodies[b];
            if (self.tasks[task].phase == 0) {
                if (!shape.defer_arm) for (shape.pre[0..shape.pre_count]) |a| {
                    self.vars[a.v] += a.c;
                };
                self.tasks[task].phase = 1;
                self.sleep(task, shape.sleep);
                return;
            }
            if (self.tasks[task].cancel) {
                // The landing: the `Defer`'s body, with the cell it shares (S1d, I5).
                if (shape.defer_arm) {
                    self.vars[shape.pre[0].v] += shape.pre[0].c;
                    _ = self.callIf(shape.calls, shape.args);
                }
                self.tasks[task].wait = .done;
                self.armSettled(b, true);
                return;
            }
            if (shape.defer_arm) {
                self.tasks[task].result = 1;
                // The copy of the `Defer` at the arm's exit.
                self.vars[shape.pre[0].v] += shape.pre[0].c;
                _ = self.callIf(shape.calls, shape.args);
            } else {
                for (shape.post[0..shape.post_count]) |a| self.vars[a.v] += a.c;
                const called = self.callIf(shape.calls, shape.args);
                self.tasks[task].result = self.read(b, shape.read) + shape.plus + called;
            }
            self.tasks[task].wait = .done;
            // Its awaiter, or the record it is an arm of.
            if (self.tasks[0].wait == .task and self.tasks[0].target == b) self.push(0);
            if (self.isArm(b)) self.armSettled(b, false);
        }
        fn start(self: *Run, b: u8) void {
            self.tasks[1 + b].snapshot = self.vars;
            self.body(b);
        }
        /// Runs `Run` from where it stands until it waits or ends.
        fn creator(self: *Run) void {
            const m = self.model;
            // Resumed from a wait: what it waited for.
            switch (self.tasks[0].wait) {
                .task => self.acc = self.acc * 3 + self.tasks[1 + self.tasks[0].target].result,
                .record => if (self.record.race) {
                    self.acc = self.acc * 7 + self.tasks[1 + self.record.winner.?].result;
                } else {
                    self.acc = self.acc * 5 + self.tasks[1 + self.record.arms[0]].result * 2 + self.tasks[1 + self.record.arms[1]].result;
                },
                // Woken from a timer: the visit of a `Loop{}` goes on after its `Sleep`.
                else => if (self.loop_left != 0) {
                    self.vars[self.loop_assign.v] += self.loop_assign.c;
                    self.loop_left -= 1;
                    if (self.loop_left != 0) {
                        self.sleep(0, 1);
                        return;
                    }
                },
            }
            self.tasks[0].wait = .none;
            while (self.pc < m.statement_count) {
                const s = m.statements[self.pc];
                self.pc += 1;
                switch (s) {
                    .build => |f| self.closure_snapshots[f] = self.vars,
                    .set => |a| self.vars[a.v] += a.c,
                    .call => |c| self.acc += self.call(c.f, self.argument(c.f, c.args, 0)),
                    .attempt => |a| {
                        const saved = self.vars;
                        const r = self.call(a.f, self.argument(a.f, a.args, 0));
                        if (r < a.limit) self.acc += r else {
                            self.vars = saved;
                            self.acc -= 1;
                        }
                    },
                    .loop => |l| for (1..@as(usize, l.visits) + 1) |visit| {
                        const saved = self.vars;
                        self.vars[l.v] += @intCast(visit);
                        const r = self.call(l.f, self.argument(l.f, l.args, @intCast(visit)));
                        if (l.limit) |limit| if (r >= limit) {
                            self.vars = saved;
                        };
                    },
                    .spawn => |b| self.start(b),
                    .sleep => |d| {
                        self.sleep(0, d);
                        return;
                    },
                    .await_task => |b| {
                        if (self.tasks[1 + b].wait == .done) {
                            self.acc = self.acc * 3 + self.tasks[1 + b].result;
                        } else {
                            self.tasks[0].wait = .task;
                            self.tasks[0].target = b;
                            return;
                        }
                    },
                    .sync, .race => |arms| {
                        // Both are built where the expression stands; each runs to its `Sleep`.
                        self.tasks[1 + arms[0]].snapshot = self.vars;
                        self.tasks[1 + arms[1]].snapshot = self.vars;
                        self.record = .{ .race = s == .race, .arms = arms };
                        self.tasks[0].wait = .record;
                        self.body(arms[0]);
                        self.body(arms[1]);
                        return;
                    },
                    .batch => |b| {
                        self.vars[b.v] += b.c;
                        const called = self.callIf(b.calls, b.args);
                        self.acc += self.vars[b.v] + called;
                    },
                    .react => |r| {
                        self.created[r] = true;
                        self.reaction_snapshots[r] = self.vars;
                        // A `When` runs its body at once; an `Upon` when its guard first holds.
                        if (m.reactions[r].upon) {
                            if (self.g >= m.reactions[r].threshold) {
                                self.fired[r] = true;
                                self.react(r);
                            }
                        } else self.react(r);
                    },
                    .set_g => |k| {
                        self.g += k;
                        self.deliver();
                    },
                    .keep => |k| self.kept = k,
                    .call_kept => |args| self.acc += if (self.kept) |k| self.call(k, args.a) else -1,
                    .pair => |pair| self.acc += self.call(if (pair.second) pair.b else pair.a, pair.args.a),
                    .branch => |b| self.start(b),
                    .sleep_loop => |l| {
                        self.loop_left = l.visits;
                        self.loop_assign = .{ .v = l.v, .c = l.c };
                        self.sleep(0, 1);
                        return;
                    },
                }
            }
            var out: [out_length]i64 = undefined;
            out[0] = self.acc;
            out[1] = self.g;
            @memcpy(out[2 .. 2 + m.vars], self.vars[0..m.vars]);
            self.out = out;
            self.tasks[0].wait = .done;
        }
        fn wake(self: *Run, task: u8) void {
            if (task == 0) self.creator() else {
                self.tasks[task].wait = .none;
                self.body(task - 1);
            }
        }
    };
    /// A model made wrong on purpose, to show the oracle tells it apart: deliveries in the
    /// reverse order, or closures that read the current value of a local nothing shares.
    pub const Mutation = enum { none, reversed, current, snapshot };
    /// What `Out` holds at the end: `Acc`, `G` and the locals; returns how many reads of a local
    /// nothing shares saw a snapshot that differed from its value then.
    pub fn run(self: *const Model, into: []i64) usize {
        return self.runWith(into, .none);
    }
    pub fn runWith(self: *const Model, into: []i64, mutation: Mutation) usize {
        var r: Run = .{ .model = self, .vars = undefined, .mutation = mutation };
        @memcpy(r.vars[0..self.vars], self.initial[0..self.vars]);
        // The root spawns `Run`, which runs at once to its first wait.
        r.creator();
        while (true) {
            if (r.ready_head < r.ready_tail) {
                const task = r.ready[r.ready_head];
                r.ready_head += 1;
                r.wake(task);
                continue;
            }
            // The earliest deadline, then every timer due then, in registration order.
            var earliest: ?u64 = null;
            for (r.tasks[0 .. 1 + self.body_count]) |t| if (t.wait == .timer) {
                earliest = if (earliest) |e| @min(e, t.deadline) else t.deadline;
            };
            const due = earliest orelse break;
            r.now = due;
            while (true) {
                var next: ?u8 = null;
                for (r.tasks[0 .. 1 + self.body_count], 0..) |t, index| if (t.wait == .timer and t.deadline == due) {
                    if (next == null or t.registration < r.tasks[next.?].registration) next = @intCast(index);
                };
                const task = next orelse break;
                r.tasks[task].wait = .none;
                r.push(task);
            }
        }
        @memcpy(into[0 .. 2 + self.vars], r.out.?[0 .. 2 + self.vars]);
        return r.stale;
    }
};

// ---- Running a program on both machines in every trace mode.

fn configure(f: replay.Fixture, trace: types.TraceMode, window: u32, floor: u32) void {
    f.mode(trace, window);
    f.h.control.reclaim_floor = floor;
    f.h.runtime.machine.control.reclaim_floor = floor;
    f.again.control.trace_window = window;
    f.again.control.reclaim_floor = floor;
}
const Pair = struct { reference: evaluator.Execution, actual: evaluator.Execution };
/// Both machines agree member for member, window by window (as `reclaim_tests.zig` does).
fn both(f: replay.Fixture, p: types.Program) !Pair {
    const h = f.h;
    const expected = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, replay.fuel);
    const actual = h.runtime.evaluate(p, replay.fuel);
    if (expected != .ok) std.debug.print("reference: {s}\n", .{expected.failed.message()});
    if (actual != .ok) std.debug.print("vm: {s}\n", .{actual.failed.message()});
    try std.testing.expect(expected == .ok and actual == .ok);
    const a = expected.ok;
    const b = actual.ok;
    try std.testing.expectEqualSlices(bool, a.activity, b.activity);
    for (a.values, b.values, 0..) |x, y, index| if (b.active(index)) try replay.same(x, y);
    try std.testing.expectEqual(a.aggregate_values.len, b.aggregate_values.len);
    for (a.aggregate_values, b.aggregate_values) |x, y| try replay.same(x, y);
    try std.testing.expectEqual(a.object_cells.len, b.object_cells.len);
    for (a.object_cells, b.object_cells) |x, y| try replay.same(x.value, y.value);
    try std.testing.expectEqual(a.cells.len, b.cells.len);
    for (a.cells, b.cells) |x, y| {
        try std.testing.expectEqual(x.initialized, y.initialized);
        if (x.initialized) try replay.same(x.value, y.value);
    }
    try std.testing.expectEqual(a.trace, b.trace);
    try std.testing.expectEqualDeep(a.witness, b.witness);
    try std.testing.expectEqualDeep(a.scheduler, b.scheduler);
    try std.testing.expectEqualDeep(a.live, b.live);
    try std.testing.expectEqual(a.reclaims, b.reclaims);
    try std.testing.expectEqual(h.control.reclaimed_cells, h.runtime.machine.control.reclaimed_cells);
    return .{ .reference = a, .actual = b };
}
fn report(x: evaluator.Execution, into: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(into);
    _ = try reporting.write(&out, x, false, .{ .work = 1 << 24 });
    try trace_report.write(&out, x, "test.forb", .{});
    return out.buffered();
}
fn replayed(f: replay.Fixture, x: evaluator.Execution, p: types.Program, into: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(into);
    _ = try reporting.writeReplayed(&out, x, f.again.producer(p, replay.fuel), false, .{ .work = 1 << 24 });
    try trace_report.writeReplayed(&out, x, f.again.producer(p, replay.fuel), "test.forb", .{});
    return out.buffered();
}

/// The model's `Out` against the run's: `Out` is the program's first cell.
fn check(x: evaluator.Execution, m: *const Model, expected: []const i64, seed: usize, mode: types.TraceMode, source: []const u8) !void {
    try std.testing.expect(x.cells.len >= 1 and x.cells[0].initialized);
    const values = x.elements(x.cells[0].value).?;
    try std.testing.expectEqual(@as(usize, 2 + m.vars), values.len);
    for (values, expected) |actual, wanted| if (actual.integer != wanted) {
        std.debug.print("seed {d}, mode {s}: got", .{ seed, @tagName(mode) });
        for (values) |value| std.debug.print(" {d}", .{value.integer});
        std.debug.print(", model", .{});
        for (expected) |value| std.debug.print(" {d}", .{value});
        std.debug.print("\n{s}\n", .{source});
        return error.ModelDisagrees;
    };
}

/// What the generator reached, so that a run of the oracle can assert its coverage.
pub const Reach = struct {
    shares: usize = 0,
    snapshots: usize = 0,
    /// Locals shared only because a closure names them (Q1), none assigns them.
    named_only: usize = 0,
    closures: [std.enums.values(Kind).len]usize = @splat(0),
    chained: usize = 0,
    spawns: usize = 0,
    syncs: usize = 0,
    races: usize = 0,
    landings: usize = 0,
    batches: usize = 0,
    whens: usize = 0,
    upons: usize = 0,
    loops: usize = 0,
    attempts: usize = 0,
    reclaimed: usize = 0,
    /// Reads of a local nothing shares whose snapshot differed from its value at the read.
    stale: usize = 0,
    values: usize = 0,
    branches: usize = 0,
    sleep_loops: usize = 0,
};

/// `seeds` random programs from `first_seed` on: each is compiled once, run on both machines in
/// `full` mode (its report is the stored one), then in `digest` and `off` modes with reclamation,
/// where both machines agree member for member and the replay of each digest run yields the
/// stored report byte for byte; every run's `Out` is the model's.
pub fn oracle(f: replay.Fixture, first_seed: u64, seeds: usize, reach: *Reach, names_share: bool) !void {
    f.h.front.share_names = names_share;
    var prng = std.Random.DefaultPrng.init(first_seed);
    const text = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(text);
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    for (0..seeds) |seed| {
        const m = Model.generate(prng.random(), names_share);
        var out = std.Io.Writer.fixed(text);
        try m.write(&out);
        const source = out.buffered();
        var expected: [Model.out_length]i64 = undefined;
        reach.stale += m.run(&expected);
        const wanted = expected[0 .. 2 + m.vars];
        var before = m;
        before.names_share = false;
        for (0..m.vars) |v| {
            if (m.shared(@intCast(v))) reach.shares += 1 else reach.snapshots += 1;
            if (m.shared(@intCast(v)) and !before.shared(@intCast(v))) reach.named_only += 1;
        }
        for (m.closures[0..m.closure_count]) |c| {
            reach.closures[@backingInt(c.kind)] += 1;
            if (c.calls != no_call) reach.chained += 1;
        }
        for (m.statements[0..m.statement_count]) |s| switch (s) {
            .spawn => reach.spawns += 1,
            .sync => reach.syncs += 1,
            .race => |arms| {
                reach.races += 1;
                // The first arm loses when it sleeps longer: its `Defer` runs as a landing.
                if (m.bodies[arms[0]].sleep > m.bodies[arms[1]].sleep) reach.landings += 1;
            },
            .batch => reach.batches += 1,
            .react => |r| if (m.reactions[r].upon) {
                reach.upons += 1;
            } else {
                reach.whens += 1;
            },
            .loop => reach.loops += 1,
            .attempt => reach.attempts += 1,
            .keep, .pair => reach.values += 1,
            .branch => reach.branches += 1,
            .sleep_loop => reach.sleep_loops += 1,
            else => {},
        };
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const p = f.h.compile(source) catch |problem| {
            std.debug.print("seed {d}:\n{s}\n", .{ seed, source });
            return problem;
        };
        try std.testing.expectEqual(m.anyShared(), census(p));
        const full = both(f, p) catch |problem| {
            std.debug.print("seed {d}, full:\n{s}\n", .{ seed, source });
            return problem;
        };
        try check(full.actual, &m, wanted, seed, .full, source);
        const stored = try report(full.actual, stored_text);
        // Digest runs reclaim at a small window and floor; the replay of each must yield the
        // stored report.
        configure(f, .digest, 2, 0);
        const digest = both(f, p) catch |problem| {
            std.debug.print("seed {d}, digest:\n{s}\n", .{ seed, source });
            return problem;
        };
        try check(digest.actual, &m, wanted, seed, .digest, source);
        if (digest.actual.reclaims != 0) reach.reclaimed += 1;
        std.testing.expectEqualStrings(stored, try replayed(f, digest.actual, p, other)) catch |problem| {
            std.debug.print("seed {d}, the vm's digest run replayed:\n{s}\n", .{ seed, source });
            return problem;
        };
        std.testing.expectEqualStrings(stored, try replayed(f, digest.reference, p, other)) catch |problem| {
            std.debug.print("seed {d}, the reference digest run replayed:\n{s}\n", .{ seed, source });
            return problem;
        };
        configure(f, .off, 2, 0);
        const off = both(f, p) catch |problem| {
            std.debug.print("seed {d}, off:\n{s}\n", .{ seed, source });
            return problem;
        };
        try check(off.actual, &m, wanted, seed, .off, source);
    }
}

/// Whether the program has a variable cell type.
fn census(p: types.Program) bool {
    for (p.definitions) |d| if (d == .ref) return true;
    return false;
}

test "randomised oracle: every closure form of I1 to I5 composed in one program agrees with the model, both machines, every trace mode, the replay" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    var reach: Reach = .{};
    // Several thousand programs a run of the suite; the program profile runs three times more.
    const seeds: usize = if (std.mem.eql(u8, profile.active.name, "program")) 6000 else 2000;
    try oracle(f, 0x0085_0006, seeds, &reach, true);
    // The generator reaches every form, both kinds of local, and reclamation: the bounds are
    // about a third of what a run of 300 programs reaches. Under Q1 (I13) a local is shared
    // when any closure names it: some are shared by a name alone, some stay plain locals that
    // only `Run` touches, and no closure reads a snapshot.
    const per = seeds / 300;
    try std.testing.expect(reach.shares > 300 * per and reach.snapshots > 20 * per and reach.named_only > 100 * per);
    try std.testing.expectEqual(@as(usize, 0), reach.stale);
    for (reach.closures) |count| try std.testing.expect(count > 50 * per);
    try std.testing.expect(reach.chained > 50 * per);
    try std.testing.expect(reach.spawns > 50 * per and reach.syncs > 40 * per and reach.races > 40 * per and reach.landings > 25 * per);
    try std.testing.expect(reach.batches > 50 * per and reach.whens > 25 * per and reach.upons > 25 * per);
    try std.testing.expect(reach.loops > 50 * per and reach.attempts > 50 * per);
    try std.testing.expect(reach.values > 100 * per and reach.branches > 50 * per and reach.sleep_loops > 50 * per);
    try std.testing.expect(reach.reclaimed > 250 * per);
}

// The rules before Q1 (`Workspace.share_names` off): a closure shares only what it assigns or a
// nested function names, and reads any other local as it was when it was built (S8).
test "randomised oracle: the rules before Q1, with the switch off, agree with their model" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    var reach: Reach = .{};
    const seeds: usize = if (std.mem.eql(u8, profile.active.name, "program")) 3000 else 900;
    try oracle(f, 0x0085_0006, seeds, &reach, false);
    const per = seeds / 300;
    try std.testing.expect(reach.shares > 300 * per and reach.snapshots > 50 * per);
    try std.testing.expectEqual(@as(usize, 0), reach.named_only);
    // Snapshots that a cell would not have given: the model's S8 is exercised, not vacuous.
    try std.testing.expect(reach.stale > 100 * per);
}

// The oracle tells apart a model made wrong on purpose (review of I6): one that delivers to
// reactions in the reverse order, and one in which closures read the current value of a local
// nothing shares (before Q1) or a snapshot of a local only a closure's name shares (since Q1).
// On the suite's seed stream and on another, enough programs have a result the
// mutation changes, and for each of them the machines give the right model's result.
test "the composed oracle catches a model that reverses deliveries or reads current values" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const text = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(text);
    for ([_]bool{ false, true }) |names_share| {
        for ([_]u64{ 0x0085_0006, 0x0085_0066 }) |stream| {
            f.h.front.share_names = names_share;
            var prng = std.Random.DefaultPrng.init(stream);
            var caught: [2]usize = @splat(0);
            for (0..400) |seed| {
                const m = Model.generate(prng.random(), names_share);
                var expected: [Model.out_length]i64 = undefined;
                _ = m.run(&expected);
                const wanted = expected[0 .. 2 + m.vars];
                var differs: [2]bool = undefined;
                for ([_]Model.Mutation{ .reversed, if (names_share) .snapshot else .current }, &differs) |mutation, *changed| {
                    var mutated: [Model.out_length]i64 = undefined;
                    _ = m.runWith(&mutated, mutation);
                    changed.* = !std.mem.eql(i64, wanted, mutated[0 .. 2 + m.vars]);
                }
                if (!differs[0] and !differs[1]) continue;
                var out = std.Io.Writer.fixed(text);
                try m.write(&out);
                const source = out.buffered();
                configure(f, .full, types.ControlStorage.default_trace_window, 0);
                const runs = try both(f, try f.h.compile(source));
                try check(runs.actual, &m, wanted, seed, .full, source);
                for (differs, &caught) |changed, *count| count.* += @intFromBool(changed);
            }
            // Measured: 71 and 48 of the suite's first 400 programs, 40 and 40 of the other stream.
            try std.testing.expect(caught[0] > 25 and caught[1] > 25);
        }
    }
}

// RFC-0085, I6-D3: a task's frame that ends at depth 1 after a switch reclaims as a call from
// the root does only once the last reclamation is paid for (`ControlStorage.reclaimReturn`); the
// program profile's fan-out of 60,000 tasks reclaimed 7,826 times before. Both machines and the replay
// decide alike at every floor and window, and the replayed report is the stored one.
test "tasks that complete after a switch reclaim alike in both machines and the replay" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    const sources = [_][]const u8{
        // A fan-out over one cell: every task completes in one tick.
        "var Out:i64=0\nRun()<transacts><suspends>:i64=Block{var C:i64=0;var I:i64=0;Loop{If(I>=40,Break(),false);set I=I+1;K:=I;Spawn{Sleep(1.0);Set(C,C+K)};0};Sleep(2.0);set Out=C;C}\nP:task(i64)=Spawn{Run()}",
        // Tasks that build what they hand on, completing one after another.
        "var Out:[]i64=array{}\nRun()<transacts><suspends>:i64=Block{var I:i64=0;Loop{If(I>=30,Break(),false);set I=I+1;K:=I;Spawn{Sleep(ToFloat(K));set Out=Out+array{K};0};0};Sleep(40.0);Out.Length}\nP:task(i64)=Spawn{Run()}",
    };
    for (sources) |source| {
        const p = try f.h.compile(source);
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const stored = try report((try both(f, p)).actual, stored_text);
        var reclaiming = false;
        for ([_]u32{ 0, 1, 8, 64 }) |floor| for ([_]u32{ 1, 64 }) |window| {
            configure(f, .digest, window, floor);
            const runs = try both(f, p);
            if (runs.actual.reclaims != 0) reclaiming = true;
            try std.testing.expectEqualStrings(stored, try replayed(f, runs.actual, p, other));
            try std.testing.expectEqualStrings(stored, try replayed(f, runs.reference, p, other));
        };
        try std.testing.expect(reclaiming);
        configure(f, .off, 1, 0);
        _ = try both(f, p);
    }
}

// RFC-0085, I6-D3, second review: a task resumed by the scheduler that reclaims inside its own
// loop (or a `Rush`, `Branch` or reaction body that builds) still reclaims at its end, since no
// other task ran after that reclamation. Without it the run ended with millions of members
// (here thousands) the rule of base56 would have freed, and at the program profile's scale it
// failed with `aggregate_limit`. Both machines and the replay, every floor and window; the pool
// of a run that ends is a small multiple of the floor.
test "a resumed task that reclaims in its own loop reclaims at its end, in both machines and the replay" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    const sources = [_][]const u8{
        "var Out:i64=0\nArm(K:i64,D:float)<transacts><suspends>:i64=Block{Sleep(D);Xs:=For(I:1..K,array{I});Xs.Length}\nOne()<transacts><suspends>:i64=Rush(Arm(30,1.0),Arm(40,2.0))\nRun(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;Loop{If(J>=N,Break(),false);set J=J+1;R:=One();set Out=Out+R;Sleep(3.0)};Out}\nP:task(i64)=Spawn{Run(5)}",
        "var Out:i64=0\nOne()<transacts><suspends>:void=Block{Branch{Sleep(1.0);Xs:=For(I:1..30,array{I});Set(Out,Out+Xs.Length)};Sleep(2.0)}\nRun(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;Loop{If(J>=N,Break(),false);set J=J+1;One()};Out}\nP:task(i64)=Spawn{Run(5)}",
        "var Out:i64=0\nvar G:i64=0\nRun(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;Q:task(void)=When(G,Block{Xs:=For(I:1..20,array{I});Set(Out,Out+Xs.Length)});Loop{If(J>=N,Break(),false);set J=J+1;Sleep(1.0);Ys:=For(I:1..15,array{I});set G=G+Ys.Length};Out}\nP:task(i64)=Spawn{Run(5)}",
        // Tasks that sleep, build in a loop and write: they resume, reclaim in their own loops.
        "var Out:i64=0\nRun(N:i64)<transacts><suspends>:i64=Block{var J:i64=0;var Kc:i64=20;Loop{If(J>=N,Break(),false);set J=J+1;set Kc=Kc+7;If(Kc>40,Block{set Kc=Kc-20;0},0);L:=Kc;Spawn{Sleep(1.0);Ys:=For(I:1..L,array{I});set Out=Out+Ys.Length;0};Sleep(2.0)};Out}\nP:task(i64)=Spawn{Run(5)}",
    };
    for (sources) |source| {
        const p = try f.h.compile(source);
        configure(f, .full, types.ControlStorage.default_trace_window, 0);
        const stored = try report((try both(f, p)).actual, stored_text);
        var reclaiming = false;
        for ([_]u32{ 0, 1, 8, 64 }) |floor| for ([_]u32{ 1, 64 }) |window| {
            configure(f, .digest, window, floor);
            const runs = try both(f, p);
            if (runs.actual.reclaims != 0) reclaiming = true;
            try std.testing.expectEqualStrings(stored, try replayed(f, runs.actual, p, other));
            try std.testing.expectEqualStrings(stored, try replayed(f, runs.reference, p, other));
            try std.testing.expect(runs.actual.aggregate_values.len <= 4 * floor + 128);
        };
        try std.testing.expect(reclaiming);
        for ([_]u32{ 0, 8 }) |floor| {
            configure(f, .off, 1, floor);
            const quiet = try both(f, p);
            try std.testing.expect(quiet.actual.aggregate_values.len <= 4 * floor + 128);
        }
    }
}

// RFC-0085, I6: the open item of I1, a cell holding a structured value. Locals of an array, a
// map, a tuple, a class and an option are cells that an `Fn` writes (S1d) and that closures held
// in module `var`s keep after their frame; digest runs reclaim them at several floors and
// windows, and every report is the stored one, `$refs` with the structured values included.
test "cells holding arrays, maps, tuples, instances and options report alike in every trace mode" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const stored_text = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stored_text);
    const other = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(other);
    const program =
        \\var KeepA:option(function<reads>(tuple(),[]i64))=option{}
        \\var KeepM:option(function<reads>(tuple(),map(i64,string)))=option{}
        \\var Sum:i64=0
        \\c:=class{var N:i64=0}
        \\Step(S:i64)<transacts>:i64=Block{
        \\var Xs:[]i64=array{S}
        \\var M:map(i64,string)=map{}
        \\var P:tuple(i64,[]i64)=tuple{S,array{}}
        \\var O:c=c{}
        \\var Q:option(i64)=option{}
        \\G:=Fn()<transacts>:void{Block{set Xs=Xs+array{S+1};set M[S]="v{S}";Set(P,tuple{P(0)+1,P(1)+array{S}});Set(O,c{N:=O.N+S});Set(Q,option{S});0}}
        \\G()
        \\G()
        \\set KeepA=option{Fn()<reads>:[]i64{Xs}}
        \\set KeepM=option{Fn()<reads>:map(i64,string){M}}
        \\set Sum=Sum+Xs.Length+P(0)+O.N+Attempt(Q?,0)+Attempt(M[S].Length,0)
        \\S+1
        \\}
        \\Total<public>:i64=Iterate(Step,12,0)
        \\A<public>:[]i64=Attempt(KeepA?(),array{})
        \\M<public>:map(i64,string)=Attempt(KeepM?(),map{})
        \\Checked<public>:i64=Sum
    ;
    const p = try f.h.compile(program);
    try std.testing.expect(census(p));
    configure(f, .full, types.ControlStorage.default_trace_window, 0);
    const full = try both(f, p);
    // Each visit adds 3 + (S + 2) + 2S + S + (1 + the digits of S).
    var sum: i64 = 0;
    for (0..12) |s| sum += 4 * @as(i64, @intCast(s)) + 6 + @as(i64, if (s < 10) 1 else 2);
    try std.testing.expectEqual(@as(i64, 12), full.actual.get("Total").?.integer);
    try std.testing.expectEqual(sum, full.actual.get("Checked").?.integer);
    const stored = try report(full.actual, stored_text);
    // The cells the module `var`s keep are listed with their values.
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"$refs\":[{\"id\":0,\"value\":[11,12,12]},{\"id\":1,\"value\":[11,\"v11\"]}]") != null);
    var reclaiming = false;
    for ([_]u32{ 0, 1, 5 }) |floor| for ([_]u32{ 1, 3, 64 }) |window| {
        configure(f, .digest, window, floor);
        const runs = try both(f, p);
        if (runs.actual.reclaims != 0) reclaiming = true;
        try std.testing.expectEqualStrings(stored, try replayed(f, runs.actual, p, other));
        try std.testing.expectEqualStrings(stored, try replayed(f, runs.reference, p, other));
    };
    try std.testing.expect(reclaiming);
    configure(f, .off, 5, 0);
    try std.testing.expectEqual(sum, (try both(f, p)).actual.get("Checked").?.integer);
}

fn refuses(f: replay.Fixture, source: []const u8, code: types.Diagnostic.Code, at: []const u8) !void {
    switch (f.h.front.compile(source)) {
        .ok => {
            std.debug.print("compiled, expected {s}: {s}\n", .{ @tagName(code), source });
            return error.Compiled;
        },
        .failed => |d| {
            if (d.code != code or !std.mem.eql(u8, source[d.span.start..d.span.end], at)) {
                std.debug.print("got {s} at '{s}', expected {s} at '{s}': {s}\n", .{ @tagName(d.code), source[d.span.start..d.span.end], @tagName(code), at, source });
                return error.WrongDiagnostic;
            }
        },
    }
}

// RFC-0085, I6: the open item of I2's review. `capturedBy` stepped outward onto a frame still
// reading its capture list, taking it for the code around a loop written in that list: a task
// body's assignment of its copy of a parameter there was `not_mutable` instead of the
// `arm_assigns_local` it is without the `Fn` around. A local `var` is shared either way.
test "an assignment in a loop written in a capture list inside a task body is judged by the task body" {
    const f = try replay.Fixture.create();
    defer f.destroy();
    const direct = "F(P:i64)<transacts><suspends>:i64=Block{T:=Spawn{Y:=For(I:1..2,Block{set P=P+I;0});P};T.Await()}\nV:task(i64)=Spawn{F(1)}";
    try refuses(f, direct, .arm_assigns_local, "P");
    const listed = "F(P:i64)<transacts><suspends>:i64=Block{T:=Spawn{G:=Fn[Y:[]i64=For(I:1..2,Block{set P=P+I;0})]()<computes>:i64{0};P};T.Await()}\nV:task(i64)=Spawn{F(1)}";
    try refuses(f, listed, .arm_assigns_local, "P");
    // In an `Fn` around the task body, the loop in the list is the `Fn`'s: a copy, `not_mutable`.
    try refuses(f, "F(P:i64)<transacts>:i64=Block{G:=Fn[Y:[]i64=For(I:1..2,Block{set P=P+I;0})]()<computes>:i64{0};P}\nV:i64=F(1)", .not_mutable, "P");
    // A local `var` assigned there is shared: the task's writes are the creator's.
    const shared = "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{G:=Fn[Y:[]i64=For(I:1..2,Block{set X=X+I;0})]()<computes>:i64{0};X};A:=T.Await();A*10+X}\nV:task(i64)=Spawn{F()}";
    const p = try f.h.compile(shared);
    try std.testing.expect(census(p));
    configure(f, .full, types.ControlStorage.default_trace_window, 0);
    var text: [1024]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try report((try both(f, p)).actual, &text), "\"result\":33") != null);
}
