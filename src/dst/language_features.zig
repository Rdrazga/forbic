//! Generated programs for the language features merged after the first workload was written:
//! classes with inheritance, interfaces and extension methods (RFC-0063, RFC-0071), `For`
//! generators, ranges and binding clauses (RFC-0064), map iteration (RFC-0056 addendum),
//! comparable keys and `Without` (RFC-0065), `Case` patterns and exhaustive `Case` (RFC-0066,
//! RFC-0050), early exit (RFC-0068), characters and string views (RFC-0069), and `First`,
//! `logic{}`, `option{}`, `?.` and the bit operations (RFC-0072), and modules declared inside
//! files with their access rules, split write access and exported aliases (RFC-0074), which
//! are programs of two files (`generateBundle`), and the locals a `For` carries, a single
//! condition that binds and a condition that fails by a lone unwrap (the amendments of
//! RFC-0064, RFC-0059, RFC-0060 and RFC-0049), and parametric classes, structs and interfaces
//! (RFC-0073), and the rules of RFC-0076: `and` / `or` that short-circuit and comparison chains,
//! a dropped comparison and a shadowed name refused, `class<unique>` identity and overloads that
//! must be distinct, `option{}` and an `If` condition as failure contexts of their own, defaults
//! that read earlier parameters, and class members internal to their module (two files again),
//! and the Book's standard functions over numbers, arrays, maps and strings (RFC-0077), and
//! the shadowing of type parameters and of what an uncalled generic body declares, and reports
//! of runs that drop instances (`fix1`), and the effect families (RFC-0078): what reads, writes
//! and allocates, sets that are rolled back, and a function with fewer effects standing where
//! more are expected, and the remaining type features of RFC-0080: `void` results, `any` with
//! its explicit conversion and checked casts, `Case[...]` that fails, and the explicit
//! tuple-to-array conversion, and native effects: output that a failed region takes back and
//! draws that it does not (RFC-0079), and generic methods, `SortBy`, the `subtype` family as
//! values and casts out of `any` to a function type with more effects (RFC-0081), and the
//! `fix2` pass: loops at the root that print and write, function arms that join and function
//! types that vary, and template bodies refused from their tokens, and the first increment of
//! structured concurrency (RFC-0082): `Spawn`, `Sleep` and the schedule, and refinement
//! types with their casts, the `(local:)` qualifier, parametric aliases and open enums (RFC-0083),
//! and the events of structured concurrency (RFC-0082, P3.2): signals, signals held by regions
//! and the `Await` of handles and events, and `Sync` and `Race` (RFC-0082, P3.3): the start
//! phase, a resolution that cancels the losers, and the `Defer`s their landings run, and `Rush`
//! and `Branch` (RFC-0082, P3.4): losers that go on under the frame, and a frame's end that
//! cancels the tasks it owns, in the order they came, and waits for them, and live variables
//! (RFC-0084, P4.1): chains, rings and diamonds of records and their refusals, and reclamation
//! across task stacks (RFC-0082, P3.5): service loops whose visits sleep and wait, holding
//! what they built across every switch, and live fields (RFC-0084, P4.2): fields that follow
//! each other, `set live` on a field in a region, records that a reclamation keeps or forgets,
//! and their refusals, and functions as types (RFC-0084, P4.3): variables and fields that hold
//! what is assigned and follow a function of it, rollback, a cycle, and their refusals, and
//! exits from arms (RFC-0082, P3.6): a `Return` in an arm that abandons its expression, a
//! `Break` from an arm to the `Loop{}` around it, and their refusals, and reactions (RFC-0084,
//! P4.4): `When` and `Upon` and the order they are delivered in, a region that takes back its
//! notifications or holds what it makes, a delivery loop that never ends, and their refusals,
//! and cancellation (RFC-0082, P3.7): `Cancel` of a task that sleeps or has completed, the
//! `Await` of a cancelled task that cancels its awaiter, an arm that does and so cancels its
//! expression's task, `NextTick` and the clock, and their refusals, and batches (RFC-0084,
//! P4.5): writes whose notifications a batch holds until its outermost body ends, a batch in a
//! region that commits or fails, a task handed off inside one, a body that ends the run at a
//! batch's end, and their refusals, and sticky and
//! subscribable events (RFC-0082, P3.9): a latch that a task waiting before it and every
//! later `Await` see, subscriptions made and cancelled in regions that commit or fail and called
//! in order, a callback that ends the run inside a `Signal`, and their refusals, and the rooms
//! of array joins (RFC-0055): `For` results that grow into the room their copies leave, and the
//! forms of RFC-0085 that need nothing else: transparent functions, whose result type is their
//! body's (I7), enumerators qualified by their enum (I10), and `<predicts>` (I12), a checked
//! effect that changes nothing that runs, and their refusals, and fields with accessors
//! (RFC-0085, I8): getters and setters that the field's reads and `set`s call, through a class,
//! a subclass and an interface, in regions that fail and in guards, and their refusals; and
//! shared locals (I2): an `Fn` that assigns a local of the code around it shares one cell with
//! it, also with a task, across loops and closures that outlive the frame, undone in regions
//! that fail; and `weak_map(K, V)` (RFC-0087, P5.1): lookups and updates one key at a time,
//! reassignment from literals and maps, a cell of the type, rollback, a value held as `any`,
//! and what the type does not have; and nested functions (RFC-0085, I3): recursive, as values
//! that outlive the frame with their cells, called from an `Fn`, a loop and a task, undone in
//! regions that fail, and their refusals; and fields with accessors and no default (RFC-0085,
//! I9): archetypes that give them, whose setters run after the block clauses in declaration
//! order, also through a constructor function and an interface, undone in regions that fail,
//! and their refusals; and automatic qualification (RFC-0085, I11): programs whose every
//! identifier the compiler notes with its definition, whose qualified forms must resolve again
//! to those definitions (locals, carried loop locals, captures, nested functions, members,
//! overloads, extension methods, type parameters and the `(local:)` and `(e:)` qualifiers), run
//! as any other; and the seals of the durable journal (RFC-0086, P2.4): one per commit point
//! that commits an action, in regions, loops, exits, tasks and fatal errors; and the overloads,
//! defaults and named parameters of nested functions (RFC-0085, I4): chosen by the argument
//! types, as values by the expected type, defaults that read the parameters before them, in
//! regions that fail, in closures and across sleeps, and their refusals; and `<persistable>`
//! types (RFC-0087, P5.2): structs, classes and enums whose fields have literal defaults, built,
//! compared and matched as any other, a default that ends the run where it is used, and the
//! rules, refused; and recovery from the durable journal (RFC-0086, P2.5): programs of regions
//! with writers and draws, loops, exits, tasks reading the clock, fatal errors and lines read,
//! each crashed at a drawn commit point, its journal torn there, and resumed, which must verify
//! what was sealed and write the journal the uninterrupted run wrote, and their refusals; and
//! `For` loops whose bodies suspend (RFC-0082, P3.8): the Book's 14:1086 cancelled after some
//! ticks, filters, bindings and carried locals across the waits, two loops interleaving, a
//! `Return` from one, a fatal error in one, the `Defer`s of an iteration and of the function on
//! a cancellation, and the clauses that may not fail; and session cells (RFC-0087, P5.4): a
//! per-session counter, entries updated inside, writes undone with their regions and the lines
//! printed with them, read by a live variable and written by a task, and their refusals; and the closure forms
//! of RFC-0085 composed (I6): nested functions with defaults, overloads and recursion, `Fn`s,
//! task bodies, landings, `Batch{}` and `When` bodies and closures kept in module `var`s over
//! the cells of one function, in regions and loops whose visits fail, and their refusals; and JSON (RFC-0087, P5.3): canonical texts of persistable structs read back,
//! texts with members in any order, whitespace and fields left out, which take their defaults,
//! texts that break a rule, instances decoded in a region that fails, a decoded value that ends
//! the run where it is used, the forms' refusals, and the names, which yield; and live locals (RFC-0085, I14): `set live` and `var live` on local `var`s, guards and
//! reactions that follow them, regions that take them back, cells that outlive their frames, the
//! Book's cycles over locals, and their refusals; and the one capture rule (RFC-0085, I13, Q1):
//! closures of every form that read a local `var` the code around them writes later, what stays
//! by value, regions that take a write back, and the reads that now need `<reads>`; and
//! control-flow completion (RFC-0090, B2): `If` without an else, `For` without a generator and
//! with clauses before its first one, in regions that fail, a fatal error in such a clause, and
//! the Book's refusals of the value of an else-less `If`, unreachable `Case` arms and float
//! scrutinees;
//! and classes completion (RFC-0092, B4): override results and access that narrow,
//! `Super{...}`, effects on structs, `<final_super>` families and `GetCastableFinalSuperClass`,
//! and their refusals; and `Profile(Tag, Body)` (RFC-0094, B6): profiled sleeps against the
//! recorded clock of the world, a body that leaves or a region that fails after it, and its
//! refusals; and the Book tightened (TASK-0109, B8): `castable_concrete_subtype` values that
//! cast and build, `<castable>` that a parametric class does not take, and `_` that declares
//! nothing and stays the wildcard of a `Case` pattern.
//!
//! Each case writes a program whose data come from the seed and returns what the program must
//! produce, worked out here in plain Zig from the rule the feature states: never by running
//! the compiler or either machine. Every feature has cases that succeed, a case whose effects
//! must be undone or that ends the run with a diagnostic, and one whose source must be refused.
const std = @import("std");
const kernel = @import("kernel.zig");

/// The cases occupy `first .. first + count` of the workload's case numbers.
pub const first: u64 = 199;
pub const count: u64 = 339;
/// The cases of automatic qualification (RFC-0085, I11), which the workload compiles with the
/// resolution table and checks for the resolution property before it runs them.
pub const first_qualifying: u64 = first + 215;
pub const qualifying_count: u64 = 7;

/// Whether case `kind` is a case of automatic qualification.
pub fn qualifying(kind: u64) bool {
    return kind >= first_qualifying and kind < first_qualifying + qualifying_count;
}
/// The cases of recovery (RFC-0086, P2.5), which the workload also runs journaled, crashes at a
/// commit point and resumes, whatever they end with.
pub const first_recovering: u64 = first + 250;
pub const recovering_count: u64 = 7;

/// Whether case `kind` is a case of recovery.
pub fn recovering(kind: u64) bool {
    // RFC-0087, P5.5: and three of the persistent cells' (295, 296 and 298): their loads are inputs
    // the journal holds, served again to the run that resumes, and their store actions are
    // actions it verifies.
    if (kind == first + 295 or kind == first + 296 or kind == first + 298) return true;
    return kind >= first_recovering and kind < first_recovering + recovering_count;
}
/// The `bundle_count` cases from this number on are bundles of two files, written by
/// `generateBundle`. The cases added after them are programs of one file again, up to the
/// `member_bundle_count` cases from `first_member_bundle` on, which are bundles too.
pub const first_bundle: u64 = first + 36;
pub const bundle_count: u64 = 5;
pub const first_member_bundle: u64 = first + 62;
pub const member_bundle_count: u64 = 2;

/// Whether case `kind` is a bundle of two files.
pub fn bundled(kind: u64) bool {
    if (kind >= first_member_bundle and kind < first_member_bundle + member_bundle_count) return true;
    return kind >= first_bundle and kind < first_bundle + bundle_count;
}

/// What a program with effects must have done: its value, the lines it committed, in order
/// and end to end as the run's record keeps them, how many it discarded and how many words of the stream it read.
pub const Effects = struct {
    value: i64,
    text: [256]u8 = undefined,
    length: usize = 0,
    lines: usize = 0,
    discarded: u64 = 0,
    draws: u64 = 0,
    /// RFC-0086: the entries the run's input record must hold, where the case knows.
    inputs: ?usize = null,
    /// RFC-0086, P2.3: the channel of each committed line, where the case writes to writers.
    channels: [32]u32 = undefined,
    checks_channels: bool = false,
    /// RFC-0086, P2.4: the actions committed after each commit point, where the case knows.
    seal_points: [32]u64 = undefined,
    seal_count: ?usize = null,

    fn line(self: *Effects, comptime format: []const u8, arguments: anytype) void {
        const written = std.fmt.bufPrint(self.text[self.length..], format, arguments) catch unreachable;
        self.length += written.len;
        if (self.lines < self.channels.len) self.channels[self.lines] = 0;
        self.lines += 1;
    }
    /// A committed line on `channel`.
    fn lineOn(self: *Effects, channel: u32, comptime format: []const u8, arguments: anytype) void {
        self.checks_channels = true;
        self.line(format, arguments);
        self.channels[self.lines - 1] = channel;
    }
    /// The end of a commit point, after the lines committed so far (RFC-0086 J3).
    fn seal(self: *Effects) void {
        const at = self.seal_count orelse 0;
        self.seal_points[at] = self.lines;
        self.seal_count = at + 1;
    }
};

/// The workload's grants (RFC-0086, P2.3): both machines are given them. The readers' streams
/// are `worldLine`.
pub const world_grants = [_]@import("forbic").effects.Grant{
    .{ .kind = .reader, .name = "config" },
    .{ .kind = .writer, .name = "log" },
    .{ .kind = .reader, .name = "extra" },
    .{ .kind = .writer, .name = "audit" },
    .{ .kind = .reader, .name = "bad" },
    // RFC-0087, P5.5: the persistent keys, grants 5 and 6.
    .{ .kind = .key, .name = "alice" },
    .{ .kind = .key, .name = "bob" },
};

/// RFC-0087, P5.5 (S4): what the workload's store holds for the persistent cell declared `cell`th
/// in a program (counting the module `var`s) under the key granted at `grant`, or null: the first
/// cell holds the number 7 for `alice`; the second the strings "hi" for `alice` and "yo" for `bob`.
pub fn worldStore(cell: u32, grant: u32) ?[]const u8 {
    return switch (cell) {
        0 => if (grant == 5) "7" else null,
        1 => if (grant == 5) "\"hi\"" else if (grant == 6) "\"yo\"" else null,
        else => null,
    };
}
const config_stream = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5" };
const extra_stream = [_][]const u8{ "x0", "x1" };
/// The second line of `bad` is no text.
const bad_stream = [_][]const u8{ "ok", "\xff", "after" };

/// Line `index` of the stream of the reader granted at `grant`, or null past its end.
pub fn worldLine(grant: u32, index: usize) ?[]const u8 {
    const stream: []const []const u8 = switch (grant) {
        0 => &config_stream,
        2 => &extra_stream,
        4 => &bad_stream,
        else => return null,
    };
    return if (index < stream.len) stream[index] else null;
}

/// The reader `config` as a program sees it, written again from I6 and I7: a cursor that every
/// read moves on, in a region that fails too, until the end.
const SeenLines = struct {
    cursor: usize = 0,
    reads: usize = 0,
    fn take(self: *SeenLines) ?[]const u8 {
        self.reads += 1;
        const line = worldLine(0, self.cursor) orelse return null;
        self.cursor += 1;
        return line;
    }
};

/// The run's stream as RFC-0079 defines it, written out again here: SplitMix64 at a position
/// from the default seed, and a bounded draw that rejects the words that would favour the low
/// values.
const Stream = struct {
    position: u64 = 0,

    fn next(self: *Stream) u64 {
        var z = @as(u64, 0x5645_5253_452f_5400) +% (self.position +% 1) *% 0x9e3779b97f4a7c15;
        self.position += 1;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
    fn integer(self: *Stream, first_bound: i64, second_bound: i64) i64 {
        const low = @min(first_bound, second_bound);
        const span: u64 = @intCast(@max(first_bound, second_bound) - low + 1);
        const rejected = (0 -% span) % span;
        while (true) {
            const word_drawn = self.next();
            if (word_drawn >= rejected) return low + @as(i64, @intCast(word_drawn % span));
        }
    }
};

/// The world's wall clock in the workload (RFC-0086): whole seconds of the virtual clock from
/// 1000, two seconds behind at every third second, and no number at all at second 7. Both
/// machines are given it; the cases work out what the program sees with the rule of I5.
pub fn worldClock(tick: u64) f64 {
    const second = tick / 60;
    if (second == 7) return std.math.inf(f64);
    const behind: u64 = if (second % 3 == 1) 2 else 0;
    return @floatFromInt(1000 + second - behind);
}

/// The clock as a program sees it, written again from I5: one reading per tick, taken at the
/// first read, held when the world's clock goes back.
const SeenClock = struct {
    reading: ?i64 = null,
    tick: u64 = 0,
    entries: usize = 0,

    fn at(self: *SeenClock, tick: u64) i64 {
        if (self.reading != null and self.tick == tick) return self.reading.?;
        self.entries += 1;
        const raw: i64 = @intFromFloat(worldClock(tick));
        const value = if (self.reading) |held| @max(held, raw) else raw;
        self.reading = value;
        self.tick = tick;
        return value;
    }
};

fn draw(c: *kernel.Context, exclusive: u64) i64 {
    const value = c.rng.below(exclusive);
    c.record("language_feature_draw", exclusive, value);
    return @intCast(value);
}

fn choose(c: *kernel.Context, comptime T: type, options: []const T) T {
    return options[@intCast(draw(c, options.len))];
}

/// A short text of ASCII letters and, now and then, a two-unit letter: what the string cases
/// index and slice by code unit.
const Text = struct {
    bytes: [16]u8 = undefined,
    len: usize = 0,

    fn random(c: *kernel.Context) Text {
        var text: Text = .{};
        const letters: usize = @intCast(1 + draw(c, 6));
        for (0..letters) |_| {
            const pick: usize = @intCast(draw(c, 7));
            if (pick == 6) {
                // U+00E9 in UTF-8.
                text.bytes[text.len] = 0xc3;
                text.bytes[text.len + 1] = 0xa9;
                text.len += 2;
            } else {
                text.bytes[text.len] = "abcxyz"[pick];
                text.len += 1;
            }
        }
        return text;
    }
    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
    /// Whether a text may begin or end at this unit: not inside a letter.
    fn boundary(self: *const Text, index: usize) bool {
        return index == self.len or self.bytes[index] & 0xc0 != 0x80;
    }
};

pub fn generate(comptime Expected: type, kind: u64, c: *kernel.Context, out: *std.Io.Writer, a: i64, b: i64, offset: i64) !Expected {
    std.debug.assert(kind >= first and kind < first + count and !bundled(kind));
    switch (kind - first) {
        // ---- Classes: dispatch through a base reference, `Super`, and state on the instance.
        0 => {
            const which = draw(c, 3);
            const grow = draw(c, 6);
            const other = 1 + draw(c, 5);
            try out.writeAll("Shape:=class<abstract>{\nvar Scale:i64=1\nArea<abstract>()<transacts>:i64\nGrow(By:i64)<transacts>:i64=Block{set Self.Scale=Self.Scale+By;Self.Scale}\n}\n" ++
                "Square:=class(Shape){\nSide:i64\nArea<override>()<transacts>:i64=Self.Side*Self.Side*Self.Scale\n}\n" ++
                "Rect:=class<final>(Shape){\nW:i64\nH:i64\nArea<override>()<transacts>:i64=Self.W*Self.H*Self.Scale\n}\n" ++
                "Cube:=class(Square){\nArea<override>()<transacts>:i64=Super.Area()*Self.Side\n}\n");
            switch (which) {
                0 => try out.print("S:Shape=Square{{Side:={d}}}\n", .{b}),
                1 => try out.print("S:Shape=Rect{{W:={d},H:={d}}}\n", .{ b, other }),
                else => try out.print("S:Shape=Cube{{Side:={d}}}\n", .{b}),
            }
            try out.print("G:i64=S.Grow({d})\nValue:i64=S.Area()*10+G", .{grow});
            const scale = 1 + grow;
            const area = switch (which) {
                0 => b * b * scale,
                1 => b * other * scale,
                else => b * b * scale * b,
            };
            return .{ .value = area * 10 + scale };
        },
        // Interface fields and default bodies, an overriding class, named and default arguments
        // and an extension method. A default argument belongs to the method the caller sees:
        // through the interface it is the interface's, through the class the class's.
        1 => {
            const knight = draw(c, 2) == 0;
            const by = draw(c, 5);
            const scale = 1 + draw(c, 4);
            const heal = draw(c, 9);
            try out.writeAll("Entity:=interface{\nId:i64=7\nvar Health:i64=100\nHurt(By:i64,Scale:i64=2)<transacts>:i64=Block{set Self.Health=Self.Health-By*Scale;Self.Health}\n}\n" ++
                "Knight:=class(Entity){\nHurt<override>(By:i64,Scale:i64=3)<transacts>:i64=Block{set Self.Health=Self.Health-By*Scale;Self.Health}\n}\n" ++
                "Monk:=class(Entity){\nId<override>:i64=9\n}\n" ++
                "(E:Entity).Heal(By:i64=1)<transacts>:i64=Block{set E.Health=E.Health+By;E.Health}\n");
            try out.print("X:={s}{{}}\nE:Entity=X\nA:i64=E.Hurt({d})\nD:i64=X.Hurt(1)\nB:i64=E.Hurt(Scale:={d},By:={d})\nC:i64=E.Heal()+E.Heal(By:={d})\nValue:i64=A+D*2+B*3+C*5+E.Id*7+X.Health", .{ if (knight) "Knight" else "Monk", b, scale, by, heal });
            var health: i64 = 100;
            health -= b * 2;
            const first_hurt = health;
            health -= if (knight) 3 else 2;
            const direct = health;
            health -= by * scale;
            const named = health;
            health += 1;
            const healed = health;
            health += heal;
            const id: i64 = if (knight) 7 else 9;
            return .{ .value = first_hurt + direct * 2 + named * 3 + (healed + health) * 5 + id * 7 + health };
        },
        // A failed method call leaves the instance as it was, through either reference to it.
        2 => {
            var amounts: [3]i64 = undefined;
            for (&amounts) |*amount| amount.* = draw(c, 21);
            try out.writeAll("Acc:=class{\nvar Total:i64=0\nAdd(N:i64)<transacts><decides>:i64=Block{set Self.Total=Self.Total+N;Require[Self.Total<=25];Self.Total}\n}\nA:=Acc{}\nB:Acc=A\n");
            try out.print("R1:i64=Attempt(A.Add[{d}],-1)\nR2:i64=Attempt(B.Add[{d}],-1)\nR3:i64=Attempt(A.Add[{d}],-1)\nValue:i64=A.Total*1000+R1+R2+R3", .{ amounts[0], amounts[1], amounts[2] });
            var total: i64 = 0;
            var results: i64 = 0;
            for (amounts) |amount| {
                if (total + amount <= 25) {
                    total += amount;
                    results += total;
                } else results -= 1;
            }
            return .{ .value = total * 1000 + results };
        },
        // An arithmetic error in a method ends the run; `Attempt` does not catch it.
        3 => {
            const parts = draw(c, 3);
            try out.print("Meter:=class{{\nvar Total:i64={d}\nShare(Parts:i64)<transacts>:i64=Self.Total/Parts\n}}\nM:=Meter{{}}\nValue:i64=Attempt(M.Share({d}),1)", .{ a, parts });
            return if (parts == 0) .{ .failed = .division_by_zero } else .{ .value = @divTrunc(a, parts) };
        },
        4 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Shape:=class<abstract>{\nArea<abstract>()<transacts>:i64\n}\nValue:i64=Shape{}.Area()",
                "Shape:=class<abstract>{\nArea<abstract>()<transacts>:i64\n}\nDot:=class(Shape){}\nValue:i64=Dot{}.Area()",
                "Base:=class{\nSize<final>()<transacts>:i64=1\n}\nMore:=class(Base){\nSize<override>()<transacts>:i64=2\n}\nValue:i64=More{}.Size()",
                "Base:=class<final>{\nSize()<transacts>:i64=1\n}\nMore:=class(Base){}\nValue:i64=More{}.Size()",
                "P:=class{\nX:i64\n}\nValue:i64=P{}.X",
                "Base:=class{\nSize()<transacts>:i64=1\n}\nMore:=class(Base){\nSize()<transacts>:i64=2\n}\nValue:i64=More{}.Size()",
                "More:=class{\nSize<override>()<transacts>:i64=2\n}\nValue:i64=More{}.Size()",
                "P:=class{\nX:i64=1\n}\nQ:=P{}\nset Q.X=2\nValue:i64=Q.X",
                "P:=class(P){}\nValue:i64=1",
                "I:=interface{\nSize()<transacts>:i64\n}\nValue:i64=I{}.Size()",
            }));
            return .syntax_failure;
        },

        // ---- `For`: two range generators (inclusive, empty when the bounds cross) and a filter.
        5 => {
            const low = draw(c, 7) - 3;
            const high = low + draw(c, 7) - 1;
            const threshold = draw(c, 5) - 1;
            try out.print("Sum:=native{{\"std.sum\"}}\nXs:[]i64=For(I:{d}..{d},J:I..{d},I*J>{d},I*10+J)\nValue:i64=Sum(Xs)*100+Xs.Length", .{ low, high, high, threshold });
            var sum: i64 = 0;
            var kept: i64 = 0;
            var i = low;
            while (i <= high) : (i += 1) {
                var j = i;
                while (j <= high) : (j += 1) if (i * j > threshold) {
                    sum += i * 10 + j;
                    kept += 1;
                };
            }
            return .{ .value = sum * 100 + kept };
        },
        // A keyed generator, a binding clause that skips when it fails, and a body whose
        // failure skips the element and undoes what the iteration wrote.
        6 => {
            var items: [4]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 10);
            const ahead: usize = @intCast(draw(c, 3));
            const skip = draw(c, 10);
            try out.print("Sum:=native{{\"std.sum\"}}\nItems:[]i64=array{{{d},{d},{d},{d}}}\nvar Log:i64=0\nRun()<transacts>:[]i64=For(I->X:Items,Y:=Items[I+{d}],Block{{set Log=Log+X;Require[X!={d}];X*Y+Log}})\nR:[]i64=Run()\nValue:i64=Sum(R)+Log*7+R.Length*100000", .{ items[0], items[1], items[2], items[3], ahead, skip });
            var log: i64 = 0;
            var sum: i64 = 0;
            var kept: i64 = 0;
            for (items, 0..) |item, index| {
                if (index + ahead >= items.len) continue;
                if (item == skip) continue;
                log += item;
                sum += item * items[index + ahead] + log;
                kept += 1;
            }
            return .{ .value = sum + log * 7 + kept * 100000 };
        },
        // A map is visited in insertion order: an update keeps the key's place and a new key
        // goes last.
        7 => {
            var keys = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
            var index: usize = keys.len;
            while (index > 1) : (index -= 1) std.mem.swap(i64, &keys[index - 1], &keys[@intCast(draw(c, index))]);
            const entries: usize = @intCast(3 + draw(c, 3));
            var values: [6]i64 = undefined;
            for (values[0..entries]) |*value| value.* = draw(c, 10);
            const updated: usize = @intCast(draw(c, entries));
            const replacement = draw(c, 10);
            const threshold = draw(c, 10);
            try out.writeAll("Sum:=native{\"std.sum\"}\nvar M:map(i64,i64)=map{");
            for (keys[0..entries], values[0..entries], 0..) |key, value, position| try out.print("{s}{d}=>{d}", .{ if (position == 0) "" else ",", key, value });
            // `keys[entries]` is a key the map does not hold yet.
            try out.print("}}\nset M[{d}]={d}\nset M[{d}]={d}\nvar Acc:i64=0\nWalk()<transacts>:i64=Block{{For(K->V:M,Block{{set Acc=Acc*10+K;0}});Acc}}\nValue:i64=Sum(For(K->V:M,V>{d},K*V))+Walk()*1000", .{ keys[updated], replacement, keys[entries], threshold, threshold });
            values[updated] = replacement;
            values[entries] = threshold;
            var sum: i64 = 0;
            var order: i64 = 0;
            for (keys[0 .. entries + 1], values[0 .. entries + 1]) |key, value| {
                if (value > threshold) sum += key * value;
                order = order * 10 + key;
            }
            return .{ .value = sum + order * 1000 };
        },
        // An arithmetic error in a binding clause is not a failed iteration: it ends the run.
        8 => {
            const low = 1 + draw(c, 3);
            const high = low + draw(c, 4);
            const pole = draw(c, 8);
            try out.print("Sum:=native{{\"std.sum\"}}\nValue:i64=Sum(For(X:{d}..{d},Z:=100/(X-{d}),Z))", .{ low, high, pole });
            if (pole >= low and pole <= high) return .{ .failed = .division_by_zero };
            var sum: i64 = 0;
            var x = low;
            while (x <= high) : (x += 1) sum += @divTrunc(100, x - pole);
            return .{ .value = sum };
        },
        9 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=For(I:1..,I).Length",
                "Value:i64=For(I:1.0..2.0,I).Length",
                "R:=1..3\nValue:i64=1",
                "Value:i64=For(X:5,X).Length",
                "Value:i64=For(I:1..3).Length",
                "Value:i64=For(I->J:1..3,I).Length",
            }));
            return .syntax_failure;
        },

        // ---- Comparable keys: tuples as keys, `Without`, and a constructor with equal keys.
        10 => {
            var points: [3][2]i64 = undefined;
            points[0] = .{ 0, 0 };
            for (points[1..3]) |*point| point.* = .{ draw(c, 3), draw(c, 3) };
            const query: [2]i64 = .{ draw(c, 3), draw(c, 3) };
            try out.print("var Cells:map(tuple(i64,i64),i64)=map{{tuple{{0,0}}=>1,tuple{{{d},{d}}}=>2,tuple{{{d},{d}}}=>3}}\n" ++
                "Drop(K:tuple(i64,i64))<transacts><decides>:i64=Block{{set Cells=Without[Cells,K];Cells.Length}}\n" ++
                "A:i64=Attempt(Drop[tuple{{{d},{d}}}],-1)\nB:i64=Attempt(Drop[tuple{{{d},{d}}}],-1)\nHit:i64=Attempt(Cells[tuple{{{d},{d}}}],-7)\nValue:i64=A*100+B*10+Hit+Cells.Length*1000", .{ points[1][0], points[1][1], points[2][0], points[2][1], query[0], query[1], query[0], query[1], points[2][0], points[2][1] });
            const same = struct {
                fn same(x: [2]i64, y: [2]i64) bool {
                    return x[0] == y[0] and x[1] == y[1];
                }
            }.same;
            if (same(points[0], points[1]) or same(points[0], points[2]) or same(points[1], points[2])) return .{ .failed = .duplicate_map_key };
            var present = [_]bool{ true, true, true };
            var length: i64 = 3;
            var dropped: i64 = -1;
            for (points[0..3], &present) |point, *held| if (same(point, query)) {
                held.* = false;
                length -= 1;
                dropped = length;
            };
            // The second removal of the same key always fails: the key is gone or never was.
            return .{ .value = dropped * 100 - 10 + (if (present[2]) @as(i64, 3) else -7) + length * 1000 };
        },
        // Equality is structural for records, arrays, tuples and options, also through a
        // `comparable` type parameter and as the key of a lookup.
        11 => {
            const x = draw(c, 2);
            const y = draw(c, 2);
            const u = draw(c, 2);
            const v = draw(c, 2);
            try out.print("Pt:=struct{{X:i64,Y:i64}}\nSame[T:comparable](A:T,B:T)<computes>:logic{{A==B}}\nP:Pt=Pt{{X:={d},Y:={d}}}\nQ:Pt=Pt{{X:={d},Y:={d}}}\nM:map(Pt,i64)=map{{P=>1}}\n" ++
                "Value:i64=If(Same[Pt](P,Q),1,0)+Attempt(M[Q],0)*10+If(array{{{d},{d}}}==array{{{d},{d}}},100,0)+If(tuple{{option{{{d}}},{d}}}!=tuple{{option{{{d}}},{d}}},1000,0)", .{ x, y, u, v, x, y, u, v, x, y, u, v });
            return .{ .value = if (x == u and y == v) 111 else 1000 };
        },
        // A removal and an insertion are undone together when the block that made them fails.
        12 => {
            const query = choose(c, i64, &.{ 0, 1, 9, 7 });
            try out.print("var Cells:map(tuple(i64,i64),i64)=map{{tuple{{0,0}}=>1,tuple{{1,1}}=>2}}\nValue:i64=Attempt(Block{{set Cells=Without[Cells,tuple{{0,0}}];set Cells[tuple{{9,9}}]=5;Cells[tuple{{{d},{d}}}]}},-1)*100+Cells.Length*10+Attempt(Cells[tuple{{0,0}}],0)", .{ query, query });
            return .{ .value = switch (query) {
                1 => 2 * 100 + 20,
                9 => 5 * 100 + 20,
                else => -100 + 20 + 1,
            } };
        },
        13 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F(X:i64)<computes>:i64=X\nValue:logic=F==F",
                "M:map(i64,i64)=map{}\nValue:i64=Attempt(Without[M].Length,0)",
                "Same[T:comparable](A:T,B:T)<computes>:logic{A==B}\nF(X:i64)<computes>:i64=X\nValue:logic=Same[function(tuple(i64),i64)](F,F)",
                "M:map(i64,i64)=map{1=>1}\nValue:i64=Attempt(Without[M,\"a\"].Length,0)",
            }));
            return .syntax_failure;
        },

        // ---- `Case`: type tests in declaration order, a record pattern with a guard, a default.
        14 => {
            const which = draw(c, 4);
            const width = 1 + draw(c, 3);
            const height = width + 1 + draw(c, 3);
            try out.writeAll("Shape:=class{}\nCircle:=class(Shape){R:i64}\nRect:=class(Shape){W:i64,H:i64}\nArea(S:Shape)<transacts>:i64=Case(S,C:Circle=>3*C.R*C.R,Rect{W:=W,H:=H} where W==H=>W*W+1,R:Rect=>R.W*R.H,_=>0)\n");
            switch (which) {
                0 => try out.print("Value:i64=Area(Circle{{R:={d}}})", .{b}),
                1 => try out.print("Value:i64=Area(Rect{{W:={d},H:={d}}})", .{ width, width }),
                2 => try out.print("Value:i64=Area(Rect{{W:={d},H:={d}}})", .{ width, height }),
                else => try out.writeAll("Value:i64=Area(Shape{})"),
            }
            return .{ .value = switch (which) {
                0 => 3 * b * b,
                1 => width * width + 1,
                2 => width * height,
                else => 0,
            } };
        },
        // Tuple and option patterns: the first arm whose pattern and guard both hold.
        15 => {
            const left = choose(c, i64, &.{ 0, 5, 20, offset });
            const present = draw(c, 2) == 0;
            try out.print("Pick(P:tuple(i64,i64))<computes>:i64=Case(P,tuple{{0,Y}}=>Y,tuple{{X,_}} where X>10=>X,tuple{{X,Y}}=>X+Y)\nInc(M:option(i64))<computes>:i64=Case(M,option{{X}}=>X+1,option{{}}=>0)\nValue:i64=Pick(tuple{{{d},{d}}})*10+", .{ left, offset });
            if (present) try out.print("Inc(option{{{d}}})", .{a}) else try out.writeAll("Inc(option{})");
            const picked = if (left == 0) offset else if (left > 10) left else left + offset;
            return .{ .value = picked * 10 + if (present) a + 1 else 0 };
        },
        // The scrutinee is evaluated once; a guard that does not hold leaves no effect behind.
        16 => {
            const n = draw(c, 8);
            try out.print("var Calls:i64=0\nNext(N:i64)<transacts>:i64=Block{{set Calls=Calls+1;N}}\nStep(N:i64)<transacts>:i64=Case(Next(N)+1,X:i64 where Next(X)>3=>1,2=>20,X:i64=>X)\nValue:i64=Step({d})*100+Calls", .{n});
            const scrutinee = n + 1;
            if (scrutinee > 3) return .{ .value = 1 * 100 + 2 };
            return .{ .value = (if (scrutinee == 2) @as(i64, 20) else scrutinee) * 100 + 1 };
        },
        // A `Case` over an enumeration needs no default when it names every case exactly once,
        // and is refused when one is missing.
        17 => {
            const picked: usize = @intCast(draw(c, 3));
            const missing: usize = @intCast(draw(c, 4));
            const names = [_][]const u8{ "Red", "Green", "Blue" };
            const results = [_]i64{ a, b, offset };
            try out.writeAll("Color:=enum{Red,Green,Blue}\nName(C:Color)<computes>:i64=Case(C");
            for (names, results, 0..) |name, result, index| if (index != missing) try out.print(",Color.{s}=>{d}", .{ name, result });
            try out.print(")\nValue:i64=Name(Color.{s})", .{names[picked]});
            return if (missing < names.len) .syntax_failure else .{ .value = results[picked] };
        },
        // Only the arm that is taken is evaluated; an error in it ends the run.
        18 => {
            const n = 1 + draw(c, 4);
            const pole = 1 + draw(c, 4);
            try out.print("Value:i64=Case({d},1=>10,2=>20,_=>100/({d}-{d}))", .{ n, n, pole });
            if (n == 1) return .{ .value = 10 };
            if (n == 2) return .{ .value = 20 };
            return if (n == pole) .{ .failed = .division_by_zero } else .{ .value = @divTrunc(100, n - pole) };
        },
        19 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=Case(1)",
                "Value:i64=Case(1,1=>)",
                "Value:i64=Case(1,\"a\"=>1,_=>2)",
                "Value:i64=Case(1,_=>1,2=>3)",
                "Value:i64=Case(option{1},option{X}=>X)",
                "Value:i64=Case(tuple{1,2},tuple{X}=>X,_=>0)",
                "Value:i64=Case(3,1=>10,2=>20)",
            }));
            return .syntax_failure;
        },

        // ---- Early exit: `Return` leaves the function from inside a loop.
        20 => {
            var items: [4]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 6);
            const targets = [_]i64{ draw(c, 6), draw(c, 6) };
            try out.print("Items:[]i64=array{{{d},{d},{d},{d}}}\nFind(T:i64)<transacts>:i64=Block{{For(I->X:Items,If(X==T,Return(I),false));-1}}\nValue:i64=Find({d})*10+Find({d})", .{ items[0], items[1], items[2], items[3], targets[0], targets[1] });
            var found = [_]i64{ -1, -1 };
            for (targets, &found) |target, *place| for (items, 0..) |item, index| if (item == target) {
                place.* = @intCast(index);
                break;
            };
            return .{ .value = found[0] * 10 + found[1] };
        },
        // `Loop{}` runs until `Break()`.
        21 => {
            try out.print("Bits(X:i64)<transacts>:i64=Block{{var B:i64=1;var C:i64=0;Loop{{If(B>X,Break(),false);set B=2*B;set C=C+1}};C}}\nValue:i64=Bits({d})", .{b});
            var power: i64 = 1;
            var turns: i64 = 0;
            while (power <= b) : (turns += 1) power *= 2;
            return .{ .value = turns };
        },
        // Deferred code runs last-in first-out when its block ends normally or by `Return`, and
        // not at all when the block fails.
        22 => {
            const early = draw(c, 2) == 1;
            const risk = draw(c, 3);
            try out.writeAll("var Trace:i64=0\nNote(D:i64)<transacts>:i64=Set(Trace,Trace*10+D)\n" ++
                "Cleanup(N:i64)<transacts>:i64=Block{Defer{Note(1)};Block{Defer{Note(2)};If(N>0,Return(Note(3)),false);Note(4);0};Note(5);9}\n" ++
                "Risky(N:i64)<transacts><decides>:i64=Block{Note(6);Defer{Note(7)};Require[N>0];N}\n");
            try out.print("F:i64=Cleanup({d})\nH:i64=Attempt(Risky[{d}],-1)\nValue:i64=Trace*100+F+H", .{ @intFromBool(early), risk });
            // `Return(Note(3))` hands back the trace as it was when 3 was noted.
            var trace: i64 = if (early) 321 else 4251;
            const cleaned: i64 = if (early) 3 else 9;
            if (risk > 0) trace = trace * 100 + 67;
            return .{ .value = trace * 100 + cleaned + if (risk > 0) risk else -1 };
        },
        // `Err` ends the run, inside an `Attempt` too.
        23 => {
            try out.print("Checked(N:i64)<computes>:i64=Block{{If(N<0,Err(\"negative\"),false);N}}\nValue:i64=Attempt(Checked({d}),0)", .{a});
            return if (a < 0) .{ .failed = .runtime_error } else .{ .value = a };
        },
        24 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=Break()",
                "Return:i64=1\nValue:i64=Return",
                "F()<transacts>:i64=Block{Defer{Return(1)};2}\nValue:i64=F()",
                "F()<computes><decides>:i64=First[X:1..3,Block{If(X>1,Return(X),false);X}>5,X]\nValue:i64=Attempt(F[],0)",
                "F()<transacts>:i64=Block{Break();1}\nValue:i64=F()",
                "F()<transacts>:i64=Block{Defer{Require[false]};2}\nValue:i64=F()",
                "F()<computes>:i64=Return(1)+2\nValue:i64=F()",
            }));
            return .syntax_failure;
        },

        // ---- Strings as code units: an index past the end fails, and a unit need not be a letter.
        25 => {
            const text = Text.random(c);
            const index: usize = @intCast(draw(c, text.len + 2));
            try out.print("Name:string=\"{s}\"\nCode:char=Attempt(Name[{d}],'?')\nValue:i64=Code.ToCodeUnit()*1000+Name.Length", .{ text.slice(), index });
            const unit: i64 = if (index < text.len) text.bytes[index] else '?';
            return .{ .value = unit * 1000 + @as(i64, @intCast(text.len)) };
        },
        // A slice is a view of whole letters within the text, or it fails. An empty slice
        // splits nothing, so it is valid at every unit, inside a letter too (RFC-0069).
        26 => {
            const text = Text.random(c);
            const low: usize = @intCast(draw(c, text.len + 2));
            const high: usize = @intCast(draw(c, text.len + 2));
            try out.print("Name:string=\"{s}\"\nValue:i64=Attempt(Name.Slice[{d},{d}],\"0123456789012345678901234567890123456789\").Length*10+For(C:Name,C=='a',C).Length", .{ text.slice(), low, high });
            const valid = low <= high and high <= text.len and (low == high or (text.boundary(low) and text.boundary(high)));
            const length: i64 = if (valid) @intCast(high - low) else 40;
            return .{ .value = length * 10 + @as(i64, @intCast(std.mem.count(u8, text.slice(), "a"))) };
        },
        // Conversions fail outside the type: a code unit is below 256, a scalar is no surrogate
        // and at most U+10FFFF.
        27 => {
            const unit = draw(c, 300);
            const scalar = choose(c, i64, &.{ 65, 233, 55295, 55296, 57343, 57344, 1114111, 1114112 });
            try out.print("Made:char=Attempt(({d}).ToChar[],'?')\nWide:char32=Attempt(({d}).ToChar32[],0u3F)\nValue:i64=Made.ToCodeUnit()+Wide.ToCodePoint()*1000", .{ unit, scalar });
            const made: i64 = if (unit < 256) unit else '?';
            const wide: i64 = if (scalar <= 0x10ffff and (scalar < 0xd800 or scalar > 0xdfff)) scalar else '?';
            return .{ .value = made + wide * 1000 };
        },
        // Characters are keys; a failed call undoes the count it added.
        28 => {
            var letters: [3]u8 = undefined;
            for (&letters) |*letter| letter.* = choose(c, u8, "xy!");
            try out.print("var Seen:map(char,i64)=map{{}}\nNote(C:char)<transacts><decides>:i64=Block{{set Seen[C]=Or(Lookup(Seen,C),0)+1;Require[C!='!'];Seen.Length}}\nA:i64=Attempt(Note['{c}'],-1)\nB:i64=Attempt(Note['{c}'],-1)\nC:i64=Attempt(Note['{c}'],-1)\nValue:i64=A*100+B*10+C+Seen.Length*1000", .{ letters[0], letters[1], letters[2] });
            var seen = [_]bool{ false, false };
            var results: [3]i64 = undefined;
            for (letters, &results) |letter, *result| {
                if (letter == '!') {
                    result.* = -1;
                    continue;
                }
                seen[letter - 'x'] = true;
                result.* = @as(i64, @intFromBool(seen[0])) + @intFromBool(seen[1]);
            }
            const distinct = @as(i64, @intFromBool(seen[0])) + @intFromBool(seen[1]);
            return .{ .value = results[0] * 100 + results[1] * 10 + results[2] + distinct * 1000 };
        },
        // Text from code units fails softly when they are not UTF-8; an arithmetic error in an
        // index is not a failed index and ends the run; a malformed character literal and an
        // index outside a failure context are refused.
        29 => {
            const form = draw(c, 7);
            if (form == 6) {
                const divisor = draw(c, 4);
                try out.print("Name:string=\"abcdef\"\nCode:char=Attempt(Name[6/{d}],'?')\nValue:i64=Code.ToCodeUnit()", .{divisor});
                if (divisor == 0) return .{ .failed = .division_by_zero };
                const index: usize = @intCast(@divTrunc(6, divisor));
                return .{ .value = if (index < 6) "abcdef"[index] else '?' };
            }
            try out.writeAll(switch (form) {
                0 => "Value:i64=Attempt(string[array{0oC3,0oA9}],\"!!!\").Length",
                1 => "Value:i64=Attempt(string[array{0oC3,0o28}],\"!!!\").Length",
                2 => "Value:char32=0uD800",
                3 => "Value:char='ab'",
                4 => "Value:char=0o100",
                else => "Value:char=\"abc\"[0]",
            });
            return switch (form) {
                0 => .{ .value = 2 },
                1 => .{ .value = 3 },
                else => .syntax_failure,
            };
        },

        // ---- Bit operations on two's complement 64-bit integers.
        30 => {
            try out.print("Value:i64=BitXor(BitAnd({d},{d}),BitOr({d},BitNot({d})))", .{ a, offset, b, a });
            return .{ .value = (a & offset) ^ (b | ~a) };
        },
        // `First` yields the body for the first combination, in generator order, that passes.
        31 => {
            const low = 1 + draw(c, 4);
            const target = (1 + draw(c, 9)) * (1 + draw(c, 9));
            try out.print("Value:i64=Attempt(First[A:{d}..9,B:A..9,A*B=={d},A*10+B],-1)", .{ low, target });
            var x = low;
            while (x <= 9) : (x += 1) {
                var y = x;
                while (y <= 9) : (y += 1) if (x * y == target) return .{ .value = x * 10 + y };
            }
            return .{ .value = -1 };
        },
        // Iterations that do not pass leave no effect; `logic{}` and `option{}` turn a failure
        // into a value.
        32 => {
            var items: [3]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 10);
            const minimum = draw(c, 10);
            const probe: usize = @intCast(draw(c, 5));
            const wanted: usize = @intCast(draw(c, 5));
            try out.print("Xs:[]i64=array{{{d},{d},{d}}}\nvar Log:i64=0\nSearch(Min:i64)<transacts>:i64=Attempt(First[X:Xs,Block{{set Log=Log+X;X}}>Min,X*10],-1)\nR:i64=Search({d})\nHas:logic=logic{{Xs[{d}]}}\nOpt:option(i64)=option{{Xs[{d}]}}\nValue:i64=R*100+Log*10+If(Has,1,0)+Or(Opt,-5)", .{ items[0], items[1], items[2], minimum, probe, wanted });
            var result: i64 = -1;
            var log: i64 = 0;
            for (items) |item| if (item > minimum) {
                result = item * 10;
                log = item;
                break;
            };
            return .{ .value = result * 100 + log * 10 + @intFromBool(probe < items.len) + if (wanted < items.len) items[wanted] else -5 };
        },
        // An arithmetic error in a condition is not a failed iteration.
        33 => {
            const items = [_]i64{ draw(c, 4), 1 + draw(c, 3) };
            try out.print("Xs:[]i64=array{{{d},{d}}}\nValue:i64=Or(option{{First[X:Xs,10/X>5,X]}},-1)", .{ items[0], items[1] });
            for (items) |item| {
                if (item == 0) return .{ .failed = .division_by_zero };
                if (@divTrunc(10, item) > 5) return .{ .value = item };
            }
            return .{ .value = -1 };
        },
        // `?.` fails on an empty option before it calls or reads anything.
        34 => {
            const present = draw(c, 2) == 0;
            try out.print("Entity:=class{{\nvar Health:i64\nHit(D:i64)<transacts>:i64=Block{{set Self.Health=Self.Health-D;Self.Health}}\n}}\nHero:option(Entity)={s}\nChain()<transacts>:[]i64=array{{Attempt(Hero?.Hit({d}),-1),Attempt(Hero?.Health,-1)}}\nR:[]i64=Chain()\nValue:i64=Attempt(R[0],0)*1000+Attempt(R[1],0)", .{ if (present) "option{Entity{Health:=100}}" else "option{}", b });
            return .{ .value = if (present) (100 - b) * 1001 else -1001 };
        },
        35 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=BitAnd(1)",
                "Value:i64=Attempt(First[],0)",
                "Value:i64=BitAnd(1,true)",
                "Value:logic=logic{}",
                "Value:i64=BitShift(1,2)",
                "Value:logic=logic{1}",
                "Value:i64=BitNot(1.0)",
                "Value:i64=First[X:1..3,X>1,X]",
            }));
            return .syntax_failure;
        },
        // ---- Locals a `For` carries, and conditions that bind or unwrap.
        // A filter skips an element before it assigns; an index out of range fails the
        // iteration after it has assigned, and what it assigned is put back.
        41 => {
            var items: [5]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 10);
            const minimum = draw(c, 10);
            const room = 1 + draw(c, 10);
            try out.print("Xs:[]i64=array{{{d},{d},{d},{d},{d}}}\n", .{ items[0], items[1], items[2], items[3], items[4] });
            try out.writeAll("Room:[]i64=array{");
            for (0..@intCast(room)) |index| try out.print("{s}0", .{if (index == 0) "" else ","});
            try out.print("}}\nSum()<transacts>:i64=Block{{var T:i64=0;var N:i64=0;Ys:=For(X:Xs,X>={d},Block{{set T=T+X;set N=N+1;Room[X];X}});T*100+N*10+Ys.Length}}\nValue:i64=Sum()", .{minimum});
            var total: i64 = 0;
            var kept: i64 = 0;
            for (items) |item| if (item >= minimum and item < room) {
                total += item;
                kept += 1;
            };
            return .{ .value = total * 100 + kept * 10 + kept };
        },
        // Two generators, and a `Return` from the inner one: the locals have, at the exit and
        // after the loop, what the iterations before gave them.
        42 => {
            const high = 1 + draw(c, 4);
            const stop = 1 + draw(c, 14);
            try out.print("Count(Stop:i64)<transacts>:i64=Block{{var T:i64=0;var N:i64=0;For(X:1..{d},Y:1..X,Block{{set N=N+1;set T=T+X*Y;If(N==Stop,Return(T*100+N),false)}});T*100+N+5000}}\nValue:i64=Count({d})", .{ high, stop });
            var total: i64 = 0;
            var visits: i64 = 0;
            var x: i64 = 1;
            while (x <= high) : (x += 1) {
                var y: i64 = 1;
                while (y <= x) : (y += 1) {
                    visits += 1;
                    total += x * y;
                    if (visits == stop) return .{ .value = total * 100 + visits };
                }
            }
            return .{ .value = total * 100 + visits + 5000 };
        },
        // A `While` and an `If` with one condition that binds, and an `If` whose condition
        // fails by a lone unwrap: the else branch, with no failure context around it.
        43 => {
            var items: [4]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 10);
            const limit = draw(c, 10);
            const present = draw(c, 2) == 0;
            const probe: usize = @intCast(draw(c, 6));
            try out.print("Xs:[]i64=array{{{d},{d},{d},{d}}}\nMaybe:option(i64)={s}\n", .{ items[0], items[1], items[2], items[3], if (present) "option{7}" else "option{}" });
            try out.print("Drain()<transacts>:i64=Block{{var I:i64=0;var T:i64=0;While(N:=Xs[I],Block{{set T=T+N;set I=I+1}});T*10+I}}\nPick:i64=If(N:=Xs[{d}],N,-1)\nOver:i64=If(Maybe?>{d},1,2)\nValue:i64=Drain()*1000+(Pick+1)*10+Over", .{ probe, limit });
            const total = items[0] + items[1] + items[2] + items[3];
            const pick: i64 = if (probe < items.len) items[probe] else -1;
            const over: i64 = if (present and 7 > limit) 1 else 2;
            return .{ .value = (total * 10 + 4) * 1000 + (pick + 1) * 10 + over };
        },
        // An arithmetic error in an iteration is not a skipped iteration: it ends the run.
        44 => {
            const items = [_]i64{ 1 + draw(c, 5), draw(c, 3), 1 + draw(c, 5) };
            try out.print("Xs:[]i64=array{{{d},{d},{d}}}\nSum()<transacts>:i64=Block{{var T:i64=0;For(X:Xs,Block{{set T=T+60/X;T}});T}}\nValue:i64=Sum()", .{ items[0], items[1], items[2] });
            var total: i64 = 0;
            for (items) |item| {
                if (item == 0) return .{ .failed = .division_by_zero };
                total += @divTrunc(60, item);
            }
            return .{ .value = total };
        },
        // What a loop binds is not the code's to assign, an immutable name is not carried, and
        // neither a branch nor a condition with `Require` is a failure context.
        45 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Xs:[]i64=array{1,2}\nF()<transacts>:i64=Block{var X:i64=0;For(X:Xs,Block{set X=X+1;X});X}\nValue:i64=F()",
                "Xs:[]i64=array{1,2}\nF()<transacts>:i64=Block{T:=0;For(X:Xs,Block{set T=T+X;T});T}\nValue:i64=F()",
                "Xs:[]i64=array{1,2}\nF()<transacts>:i64=Block{var I:i64=0;For(I->X:Xs,Block{set I=I+X;I});I}\nValue:i64=F()",
                "Xs:[]i64=array{1,2}\nF()<computes>:i64=Block{var T:i64=0;For(X:Xs,Block{set T=T+X;T});T}\nValue:i64=F()",
                "E:option(i64)=option{}\nValue:i64=If(true,E?,0)",
                "E:option(i64)=option{}\nXs:[]i64=array{1}\nValue:i64=If(E?>0 and Require[Xs.Length>0],1,0)",
                "Xs:[]i64=array{1,2}\nValue:i64=If(N:=Xs[0],1,N)",
            }));
            return .syntax_failure;
        },
        // ---- Parametric types: one type for each argument list, wherever it is first named.
        // A list of a parametric node, an instantiated interface dispatched through, and a
        // struct over an instantiation, each named at a place the seed picks.
        46 => {
            const length: usize = @intCast(draw(c, 6));
            const early = draw(c, 2) == 0;
            try out.writeAll("Has[T:type]:=interface{Get()<transacts>:T}\n" ++
                "Node[T:type]:=class{V:T,Next:option(Node[T])=option{}}\n" ++
                "Box[T:type]:=class(Has[T]){\nvar V:T\nGet<override>()<transacts>:T=Self.V\nPut(N:T)<transacts>:T=Block{Old:T=Self.V;set Self.V=N;Old}\n}\n" ++
                "Pair[A:type,B:type]:=struct{X:A,Y:B}\n");
            // Naming the types first changes nothing: an instantiation is found, not made again.
            if (early) try out.writeAll("Pre:option(Pair[i64,Box[i64]])=option{}\nAlso:option(Has[i64])=option{}\n");
            try out.writeAll("Sum(L:option(Node[i64]))<transacts>:i64=Attempt(Block{H:=L?;H.V+Sum(H.Next)},0)\nL:option(Node[i64])=");
            var sum: i64 = 0;
            for (0..length) |_| {
                const item = draw(c, 50);
                sum += item;
                try out.print("option{{Node[i64]{{V:={d},Next:=", .{item});
            }
            try out.writeAll("option{}");
            for (0..length) |_| try out.writeAll("}}");
            try out.print("\nB:Has[i64]=Box[i64]{{V:={d}}}\nP:=Pair[i64,Box[i64]]{{X:={d},Y:=Box[i64]{{V:={d}}}}}\nOld:i64=P.Y.Put({d})\nValue:i64=Sum(L)+B.Get()+P.X+P.Y.Get()+Old", .{ a, b, offset, b });
            return .{ .value = sum + a + b + b + offset };
        },
        // A failed region undoes a write to an instance of an instantiation; a division by a
        // field that is zero ends the run.
        47 => {
            const limit = draw(c, 64);
            const divisor = draw(c, 3);
            try out.print("Box[T:type]:=class{{\nvar V:T\nPut(N:T)<transacts>:T=Block{{set Self.V=N;N}}\n}}\n" ++
                "B:=Box[i64]{{V:={d}}}\nD:=Box[i64]{{V:={d}}}\n" ++
                "Try(N:i64)<transacts>:i64=Attempt(Block{{B.Put(N);Require[N>{d}];1}},0)\nR:i64=Try({d})\nValue:i64=(B.V*2+R)/D.V", .{ a, divisor, limit, b });
            if (divisor == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(if (b > limit) b * 2 + 1 else a * 2, divisor) };
        },
        48 => {
            try out.writeAll("Animal:=class{N:i64=1}\nShape:=class<abstract>{}\nBox[T:type]:=class{V:T}\nPen[T:subtype(Animal)]:=class{K:T}\nBag[K:comparable]:=class{M:map(K,i64)=map{}}\nMake[T:type]()<transacts>:T{T{}}\n");
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=Box{V:=1}.V",
                "Value:i64=Box[i64,i64]{V:=1}.V",
                "Value:i64=Box[string]{V:=1}.V",
                "X:Box[string]=Box[i64]{V:=1}\nValue:i64=1",
                "X:=Pen[i64]{K:=1}\nValue:i64=1",
                "X:=Bag[function(tuple(i64),i64)]{}\nValue:i64=1",
                "Grow[T:type]:=class{In:option(Grow[Grow[T]])=option{}}\nX:option(Grow[i64])=option{}\nValue:i64=1",
                "Bad[T:type]:=class(Bad[T]){}\nX:option(Bad[i64])=option{}\nValue:i64=1",
                "Mix[T:type]:=class(T){}\nX:option(Mix[Animal])=option{}\nValue:i64=1",
                "X:=Make[Shape]()\nValue:i64=1",
                "Odd[T:subtype(i64)]:=class{}\nValue:i64=1",
            }));
            return .syntax_failure;
        },

        // ---- `and` / `or` run their right operand only when the left one does not decide
        // (RFC-0076). The right operands here add their own weight to a cell, so the cell says
        // exactly which of them ran.
        49 => {
            var left: [4]bool = undefined;
            var bounds: [4][2]i64 = undefined;
            for (&left, &bounds) |*holds, *pair| {
                pair.* = .{ draw(c, 3), draw(c, 3) };
                holds.* = pair[0] < pair[1];
            }
            var right: [6]bool = undefined;
            for (&right) |*value| value.* = draw(c, 2) == 0;
            try out.writeAll("var C:i64=0\nMark(V:logic,By:i64)<transacts>:logic=Block{set C=C+By;V}\n");
            try out.print("R0:logic={d}<{d} and Mark({s},1)\n", .{ bounds[0][0], bounds[0][1], word(right[0]) });
            try out.print("R1:logic={d}<{d} or Mark({s},2)\n", .{ bounds[1][0], bounds[1][1], word(right[1]) });
            try out.print("R2:logic=({d}<{d} and Mark({s},4)) or Mark({s},8)\n", .{ bounds[2][0], bounds[2][1], word(right[2]), word(right[3]) });
            try out.print("R3:logic=Mark({s},16) and ({d}<{d} or Mark({s},32))\n", .{ word(right[4]), bounds[3][0], bounds[3][1], word(right[5]) });
            try out.writeAll("Value:i64=C*16+If(R0,1,0)+If(R1,2,0)+If(R2,4,0)+If(R3,8,0)");
            var ran: i64 = 0;
            var results: [4]bool = undefined;
            // `and`: a left operand that is false decides.
            results[0] = false;
            if (left[0]) {
                ran += 1;
                results[0] = right[0];
            }
            // `or`: a left operand that is true decides.
            results[1] = true;
            if (!left[1]) {
                ran += 2;
                results[1] = right[1];
            }
            var inner = false;
            if (left[2]) {
                ran += 4;
                inner = right[2];
            }
            results[2] = true;
            if (!inner) {
                ran += 8;
                results[2] = right[3];
            }
            ran += 16;
            results[3] = false;
            if (right[4]) {
                results[3] = true;
                if (!left[3]) {
                    ran += 32;
                    results[3] = right[5];
                }
            }
            var value = ran * 16;
            for (results, 0..) |result, index| {
                if (result) value += @as(i64, 1) << @intCast(index);
            }
            return .{ .value = value };
        },
        // A right operand that divides by zero ends the run only when it runs.
        50 => {
            const bounds = [_]i64{ draw(c, 3), draw(c, 3), draw(c, 3), draw(c, 3) };
            const divisors = [_]i64{ draw(c, 3), draw(c, 3) };
            const limits = [_]i64{ draw(c, 12), draw(c, 12) };
            try out.print("Den:i64={d}\nNum:i64={d}\nValue:i64=If({d}<{d} and 12/Den>{d},1,0)+If({d}<{d} or 12/Num>{d},10,0)", .{ divisors[0], divisors[1], bounds[0], bounds[1], limits[0], bounds[2], bounds[3], limits[1] });
            var value: i64 = 0;
            if (bounds[0] < bounds[1]) {
                if (divisors[0] == 0) return .{ .failed = .division_by_zero };
                if (@divTrunc(12, divisors[0]) > limits[0]) value += 1;
            }
            if (bounds[2] < bounds[3]) {
                value += 10;
            } else {
                if (divisors[1] == 0) return .{ .failed = .division_by_zero };
                if (@divTrunc(12, divisors[1]) > limits[1]) value += 10;
            }
            return .{ .value = value };
        },
        // A comparison chain is the conjunction of its links: an operand between two links is
        // evaluated once, and the operands after a link that does not hold are not evaluated.
        51 => {
            const x = draw(c, 4);
            const y = draw(c, 4);
            const z = draw(c, 4);
            const u = draw(c, 3);
            const v = draw(c, 3);
            const w = draw(c, 3);
            const s = draw(c, 3);
            const divisor = draw(c, 3);
            try out.print("var C:i64=0\nMid(V:i64)<transacts>:i64=Block{{set C=C+1;V}}\nDen:i64={d}\nR0:logic={d}<Mid({d})<={d}\n", .{ divisor, x, y, z });
            try out.print("R1:logic={d}>=Mid({d})=={d}!=Mid({d})\n", .{ u, v, w, s });
            try out.print("R2:logic={d}<={d}<12/Den\nValue:i64=C*8+If(R0,1,0)+If(R1,2,0)+If(R2,4,0)", .{ x, y });
            // The second operand of the first link always runs, and once.
            var calls: i64 = 1;
            const first_chain = x < y and y <= z;
            var second_chain = false;
            calls += 1;
            if (u >= v and v == w) {
                calls += 1;
                second_chain = w != s;
            }
            var third_chain = false;
            if (x <= y) {
                if (divisor == 0) return .{ .failed = .division_by_zero };
                third_chain = y < @divTrunc(12, divisor);
            }
            return .{ .value = calls * 8 + @as(i64, @intFromBool(first_chain)) + @as(i64, @intFromBool(second_chain)) * 2 + @as(i64, @intFromBool(third_chain)) * 4 };
        },
        // A chain compares numbers: a `logic` operand in it is a type error, as is an operand
        // of `and` or `or` that is not a `logic`.
        52 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:logic=1==1==true",
                "Value:logic=1<2<true",
                "A:logic=true\nValue:logic=A==A==A",
                "Value:logic=false!=(1<2)<3",
                "Value:logic=1 and true",
                "Value:logic=true or 1/0",
            }));
            return .syntax_failure;
        },

        // ---- A comparison whose result is dropped is refused; `Require[...]` makes it a check
        // that fails the function, and a binding keeps it as a value.
        53 => {
            const form = draw(c, 3);
            const variant = draw(c, 4);
            const x = draw(c, 7);
            const n = draw(c, 35);
            const m = draw(c, if (variant == 2) 8 else 70);
            try out.writeAll("var C:i64=0\nCheck(X:i64)<transacts><decides>:i64=Block{set C=C+1;");
            try out.writeAll(switch (form) {
                0 => "",
                1 => "Require[",
                else => "Held:logic=",
            });
            switch (variant) {
                0 => try out.print("60/X>{d}", .{n}),
                1 => try out.print("not (60/X>{d})", .{n}),
                2 => try out.print("60/X>{d} and X<{d}", .{ n, m }),
                else => try out.print("{d}<60/X<{d}", .{ n, m }),
            }
            try out.writeAll(switch (form) {
                0 => ";X*2}\n",
                1 => "];X*2}\n",
                else => ";If(Held,X*2,X*3)}\n",
            });
            try out.print("Value:i64=Attempt(Check[{d}],-1)*10+C", .{x});
            if (form == 0) return .syntax_failure;
            // Every variant divides before it compares anything.
            if (x == 0) return .{ .failed = .division_by_zero };
            const quotient = @divTrunc(60, x);
            const holds = switch (variant) {
                0 => quotient > n,
                1 => !(quotient > n),
                2 => quotient > n and x < m,
                else => n < quotient and quotient < m,
            };
            // A check that fails undoes the count the call had added.
            if (form == 1) return .{ .value = if (holds) x * 2 * 10 + 1 else -10 };
            return .{ .value = (if (holds) x * 2 else x * 3) * 10 + 1 };
        },
        // A name that is visible may not be declared again: a local against a parameter, a
        // parameter against a binding of the file, a `For` variable against a local, a binding
        // of the file or a parameter. With every name its own, the program has its value.
        54 => {
            const which = draw(c, 10);
            const items = [_]i64{ draw(c, 10), draw(c, 10), draw(c, 10) };
            const n = draw(c, 10);
            const base = draw(c, 100);
            const parameter: []const u8 = if (which == 1) "Base" else "N";
            const local: []const u8 = if (which == 0) "N" else "T";
            const variable: []const u8 = switch (which) {
                2 => "T",
                3 => "Base",
                4 => "N",
                else => "X",
            };
            try out.print("Base:i64={d}\nXs:[]i64=array{{{d},{d},{d}}}\nSum:=native{{\"std.sum\"}}\n", .{ base, items[0], items[1], items[2] });
            try out.print("Calc({s}:i64)<computes>:i64=Block{{{s}:i64={s}*2;Sum(For({s}:Xs,{s}*{s}))+{s}+Base}}\nValue:i64=Calc({d})", .{ parameter, local, parameter, variable, variable, local, parameter, n });
            if (which < 5) return .syntax_failure;
            return .{ .value = (items[0] + items[1] + items[2]) * (n * 2) + n + base };
        },
        // What the rule leaves alone: the same name in two arms side by side, a field and a
        // named argument called as a parameter is, and a local called as a binding the file
        // declares only later.
        55 => {
            const threshold = draw(c, 10);
            const n = draw(c, 10);
            const m = draw(c, 10);
            const tail = draw(c, 10);
            try out.print("p:=struct{{N:i64}}\nF(N:i64)<computes>:i64=If(N>{d},Block{{A:=N*2;A}},Block{{A:=N+1;A}})\n" ++
                "G(N:i64)<computes>:i64=Block{{Tail:=p{{N:=N+1}};Tail.N}}\nTail:i64={d}\nValue:i64=F({d})+G(N:={d})*1000+Tail*100000", .{ threshold, tail, n, m });
            return .{ .value = (if (n > threshold) n * 2 else n + 1) + (m + 1) * 1000 + tail * 100000 };
        },

        // ---- Instances of a `class<unique>` are equal when they are the same instance, never
        // by their fields, and are map keys by that identity. A class that is not unique has no
        // equality, and a class below a unique one says `<unique>` too.
        56 => {
            const unique = draw(c, 4) != 0;
            const sub = draw(c, 4);
            const alias_first = draw(c, 2) == 0;
            const key_alias = draw(c, 3) == 0;
            const fields = [_]i64{ draw(c, 2), draw(c, 2) };
            const held = [_]i64{ 1 + draw(c, 9), 1 + draw(c, 9) };
            try out.print("K:=class{s}{{N:i64}}\n", .{if (unique) "<unique>" else ""});
            if (sub == 1) try out.writeAll("S:=class<unique>(K){}\n");
            if (sub == 2) try out.writeAll("S:=class(K){}\n");
            try out.print("A:=K{{N:={d}}}\nB:=K{{N:={d}}}\nD:K={s}\n", .{ fields[0], fields[1], if (alias_first) "A" else "B" });
            if (sub == 1 or sub == 2) try out.print("E:K=S{{N:={d}}}\n", .{fields[0]});
            try out.print("M:map(K,i64)=map{{A=>{d},{s}=>{d}}}\nValue:i64=If(A==D,1,0)+If(B==D,2,0)+If(A!=B,4,0)+", .{ held[0], if (key_alias) "D" else "B", held[1] });
            if (sub == 1 or sub == 2) try out.writeAll("If(E==A,8,0)+");
            try out.writeAll("Attempt(M[D],0)*16+M.Length*10000");
            if (!unique or sub == 2) return .syntax_failure;
            // `D` is `A` under another name: the same key twice.
            if (key_alias and alias_first) return .{ .failed = .duplicate_map_key };
            // `E` has the fields of `A` and is another instance, so it adds nothing.
            const same: i64 = if (alias_first) 1 else 2;
            const found = if (alias_first) held[0] else held[1];
            return .{ .value = same + 4 + found * 16 + 2 * 10000 };
        },
        // Overloads that one value could fit are refused: a class and a class below it, an
        // interface and a class that is not final, the same type twice. Unrelated ones are
        // told apart by the type and the number of the arguments.
        57 => {
            const extra = draw(c, 8);
            const argument = draw(c, 5);
            const n = draw(c, 10);
            const weight = draw(c, 4);
            const x = draw(c, 10);
            try out.writeAll("An:=class{N:i64}\nDog:=class(An){}\nRock:=class{W:i64}\nWalker:=interface{}\n" ++
                "Size(A:An)<transacts>:i64=A.N+1\nSize(R:Rock)<transacts>:i64=100/R.W\nSize(X:i64)<transacts>:i64=X*3\nSize(D:Dog,K:i64)<transacts>:i64=D.N+K\n");
            try out.writeAll(switch (extra) {
                0 => "Size(P:Dog)<transacts>:i64=7\n",
                1 => "Size(P:Walker)<transacts>:i64=9\n",
                2 => "Size(P:i64)<transacts>:i64=P\n",
                else => "",
            });
            switch (argument) {
                0 => try out.print("Value:i64=Size(An{{N:={d}}})", .{n}),
                // A `Dog` is an `An`, and no other overload of one parameter admits it.
                1 => try out.print("Value:i64=Size(Dog{{N:={d}}})", .{n}),
                2 => try out.print("Value:i64=Size(Rock{{W:={d}}})", .{weight}),
                3 => try out.print("Value:i64=Size({d})", .{x}),
                else => try out.print("Value:i64=Size(Dog{{N:={d}}},{d})", .{ n, x }),
            }
            if (extra < 3) return .syntax_failure;
            return switch (argument) {
                0, 1 => .{ .value = n + 1 },
                2 => if (weight == 0) .{ .failed = .division_by_zero } else .{ .value = @divTrunc(100, weight) },
                3 => .{ .value = x * 3 },
                else => .{ .value = n + x },
            };
        },

        // ---- `option{E}` catches the failure of `E` wherever it is written: in a function that
        // may fail, in the body of an `Attempt` and in an iteration of a `For`. What `E` wrote
        // before it failed is undone, and the code around the option goes on.
        58 => {
            const items = [_]i64{ draw(c, 10), draw(c, 10), draw(c, 10) };
            const limit = draw(c, 10);
            const places = [_]usize{ @intCast(draw(c, 5)), @intCast(draw(c, 5)) };
            const amounts = [_]i64{ draw(c, 10), draw(c, 10), draw(c, 10) };
            const divisor = draw(c, 4);
            try out.print("Sum:=native{{\"std.sum\"}}\nvar Log:i64=0\nXs:[]i64=array{{{d},{d},{d}}}\n" ++
                "Put(N:i64)<transacts><decides>:i64=Block{{set Log=Log+N;Require[N<{d}];N}}\n" ++
                "Find(I:i64,N:i64)<transacts><decides>:i64=Block{{O:=option{{Block{{set Log=Log+100;Put[N]}}}};set Log=Log+1;Xs[I]+Or(O,-7)}}\n" ++
                "Each()<transacts>:[]i64=For(X:Xs,Or(option{{Put[X]}},-3))\n" ++
                "R0:i64=Attempt(Find[{d},{d}],-1)\nR1:i64=Attempt(Find[{d},{d}],-1)\nYs:[]i64=Each()\n" ++
                "R2:i64=Attempt(Block{{Got:=option{{Put[{d}]}};Or(Got,-2)+Log/{d}}},-9)\n" ++
                "Value:i64=R0+R1*100+R2*10000+Sum(Ys)*7+Ys.Length*13+Log*1000000", .{ items[0], items[1], items[2], limit, places[0], amounts[0], places[1], amounts[1], amounts[2], divisor });
            var log: i64 = 0;
            var found: [2]i64 = undefined;
            for (places, amounts[0..2], &found) |place, amount, *result| {
                const before = log;
                var caught: i64 = -7;
                // The option's own writes stay only when `Put` succeeds.
                if (amount < limit) {
                    log += 100 + amount;
                    caught = amount;
                }
                log += 1;
                if (place < items.len) {
                    result.* = items[place] + caught;
                } else {
                    // The index fails the function, and the `Attempt` undoes all of the call.
                    log = before;
                    result.* = -1;
                }
            }
            // No iteration is skipped: a failed `Put` is an empty option, not a failed iteration.
            var sum: i64 = 0;
            for (items) |item| {
                if (item < limit) {
                    log += item;
                    sum += item;
                } else sum -= 3;
            }
            var got: i64 = -2;
            if (amounts[2] < limit) {
                log += amounts[2];
                got = amounts[2];
            }
            if (divisor == 0) return .{ .failed = .division_by_zero };
            const last = got + @divTrunc(log, divisor);
            return .{ .value = found[0] + found[1] * 100 + last * 10000 + sum * 7 + 3 * 13 + log * 1000000 };
        },
        // The condition of an `If` is its own failure context wherever the `If` stands: a lone
        // unwrap of an empty option takes the else branch in a function that may fail, in the
        // body of an `Attempt` and in an iteration, and fails none of them.
        59 => {
            const present = draw(c, 2) == 0;
            const held = draw(c, 10);
            const n = draw(c, 10);
            const bad = 1 + draw(c, 11);
            const m = draw(c, 10);
            const divisor = draw(c, 4);
            const threshold = draw(c, 10);
            var options: [3]?i64 = undefined;
            for (&options) |*option| option.* = if (draw(c, 2) == 0) draw(c, 10) else null;
            try out.print("Sum:=native{{\"std.sum\"}}\nPick(O:option(i64),N:i64)<computes><decides>:i64=Block{{R:=If(O?>N,1,2);Require[R+N!={d}];R}}\nMaybe:option(i64)=", .{bad});
            if (present) try out.print("option{{{d}}}", .{held}) else try out.writeAll("option{}");
            try out.writeAll("\nOpts:[]option(i64)=array{");
            for (options, 0..) |option, index| {
                if (index != 0) try out.writeAll(",");
                if (option) |value| try out.print("option{{{d}}}", .{value}) else try out.writeAll("option{}");
            }
            try out.print("}}\nR0:i64=Attempt(Pick[Maybe,{d}],-1)\nR1:i64=Attempt(Block{{If(Maybe?>{d},10,20)+60/{d}}},-5)\nYs:[]i64=For(P:Opts,If(P?>{d},1,2))\n" ++
                "Value:i64=R0+R1*10+Sum(Ys)*1000+Ys.Length*10000", .{ n, m, divisor, threshold });
            const picked: i64 = if (present and held > n) 1 else 2;
            const first_result: i64 = if (picked + n == bad) -1 else picked;
            if (divisor == 0) return .{ .failed = .division_by_zero };
            const second_result = (if (present and held > m) @as(i64, 10) else 20) + @divTrunc(60, divisor);
            var sum: i64 = 0;
            for (options) |option| sum += if (option != null and option.? > threshold) 1 else 2;
            return .{ .value = first_result + second_result * 10 + sum * 1000 + 3 * 10000 };
        },
        // A default reads the parameters before it, and `Self` in a method. The caller works
        // the defaults out in parameter order with each argument evaluated once: an argument
        // that counts its calls counts one, however many defaults read its parameter.
        60 => {
            const start = draw(c, 10);
            const form = draw(c, 3);
            const x = draw(c, 10);
            const y = draw(c, 10);
            const added = [_]i64{ draw(c, 10), draw(c, 10), draw(c, 10) };
            const given = draw(c, 2) == 0;
            const g = draw(c, 4);
            try out.print("var C:i64=0\nBump()<transacts>:i64=Block{{set C=C+1;C}}\n" ++
                "F(X:i64,Y:i64=X*2,Z:i64=X+Y)<computes>:i64=X*100+Y*10+Z\nG(X:i64,Y:i64=60/X)<computes>:i64=X+Y\n" ++
                "Acc:=class{{\nvar Total:i64={d}\nAdd(N:i64,M:i64=N+Self.Total+Bump())<transacts>:i64=Block{{set Self.Total=Self.Total+N+M;Self.Total}}\n}}\n" ++
                "K:=Acc{{}}\nR1:i64=F(Bump())\n", .{start});
            switch (form) {
                0 => try out.print("R2:i64=F({d})\n", .{x}),
                1 => try out.print("R2:i64=F({d},{d})\n", .{ x, y }),
                else => try out.print("R2:i64=F({d},Z:={d})\n", .{ x, y }),
            }
            try out.print("R3:i64=K.Add({d})\nR4:i64=K.Add({d},{d})\n", .{ added[0], added[1], added[2] });
            if (given) try out.print("R5:i64=G({d},Y:={d})\n", .{ g, y }) else try out.print("R5:i64=G({d})\n", .{g});
            try out.writeAll("Value:i64=R1+R2*3+R3*5+R4*7+R5*11+C*1000000");
            const shape = struct {
                fn f(first_argument: i64, second: ?i64, third: ?i64) i64 {
                    const second_value = second orelse first_argument * 2;
                    const third_value = third orelse first_argument + second_value;
                    return first_argument * 100 + second_value * 10 + third_value;
                }
            };
            // `Bump()` is the argument: it runs once and `X` is one in both defaults.
            var bumps: i64 = 1;
            const r1 = shape.f(1, null, null);
            const r2 = switch (form) {
                0 => shape.f(x, null, null),
                1 => shape.f(x, y, null),
                else => shape.f(x, null, y),
            };
            // The default reads the total as it is when the call is made, and bumps once.
            bumps += 1;
            var total = start;
            total += added[0] + (added[0] + total + bumps);
            const r3 = total;
            // An argument that is given leaves the default unevaluated.
            total += added[1] + added[2];
            const r4 = total;
            if (!given and g == 0) return .{ .failed = .division_by_zero };
            const r5 = g + if (given) y else @divTrunc(60, g);
            return .{ .value = r1 + r2 * 3 + r3 * 5 + r4 * 7 + r5 * 11 + bumps * 1000000 };
        },
        // A default reads neither a later parameter nor its own, has the parameter's type, and
        // finds `Self` only in a method and only the fields the class has.
        61 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F(X:i64=Y,Y:i64=2)<computes>:i64=X+Y\nValue:i64=F()",
                "F(X:i64,Y:i64=Y+1)<computes>:i64=X+Y\nValue:i64=F(1)",
                "F(X:i64,Y:logic=X)<computes>:i64=X\nValue:i64=F(1)",
                "c:=class{\nV:i64=1\nGet(N:i64=Self.W)<transacts>:i64=N\n}\nValue:i64=c{}.Get()",
                "F(X:i64=Self.V)<computes>:i64=X\nValue:i64=F()",
            }));
            return .syntax_failure;
        },
        // ---- The standard library (RFC-0077): searches, slices and reads from the end.
        // A value that is absent, a range that is none and a position before the start fail;
        // nothing else does.
        64 => {
            var items: [6]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 4);
            const wanted = draw(c, 5);
            const start = draw(c, 9) - 1;
            const end = draw(c, 9) - 1;
            const back = draw(c, 8) - 1;
            try out.print("Xs:[]i64=array{{{d},{d},{d},{d},{d},{d}}}\n", .{ items[0], items[1], items[2], items[3], items[4], items[5] });
            try out.print("Where:i64=Attempt(Xs.Find[{d}],-1)\nRest:[]i64=Xs.RemoveAllElements({d})\nPart:[]i64=Attempt(Xs.Slice[{d},{d}],array{{9,9,9,9,9,9,9,9}})\nEnd:i64=Attempt(Xs.Last[{d}],-9)\nValue:i64=Where*10000+Rest.Length*1000+Part.Length*100+End", .{ wanted, wanted, start, end, back });
            var where: i64 = -1;
            var rest: i64 = 0;
            for (items, 0..) |item, index| {
                if (item == wanted and where < 0) where = @intCast(index);
                if (item != wanted) rest += 1;
            }
            const part: i64 = if (start >= 0 and start <= end and end <= 6) end - start else 8;
            const last: i64 = if (back >= 0 and back < 6) items[@intCast(5 - back)] else -9;
            return .{ .value = where * 10000 + rest * 1000 + part * 100 + last };
        },
        // An array rebuilt form after form: runs replaced from the left without overlap,
        // elements inserted, a range removed, an element and then every 8 replaced, and the
        // result joined to the original. The sum weighs each element by its place.
        65 => {
            var items: [5]i64 = undefined;
            for (&items) |*item| item.* = draw(c, 3);
            const pattern_length: usize = @intCast(1 + draw(c, 2));
            const pattern = [_]i64{ draw(c, 3), draw(c, 3) };
            const replacement_length: usize = @intCast(draw(c, 3));
            const replacement = [_]i64{ 3 + draw(c, 2), 3 + draw(c, 2) };
            const at = draw(c, 12) - 1;
            const from = draw(c, 8) - 1;
            const to = draw(c, 12) - 1;
            const index = draw(c, 12) - 1;
            try out.print("Sum:=native{{\"std.sum\"}}\nXs:[]i64=array{{{d},{d},{d},{d},{d}}}\nPs:[]i64=array{{", .{ items[0], items[1], items[2], items[3], items[4] });
            for (pattern[0..pattern_length], 0..) |value, place| try out.print("{s}{d}", .{ if (place == 0) "" else ",", value });
            try out.writeAll("}\nRs:[]i64=array{");
            for (replacement[0..replacement_length], 0..) |value, place| try out.print("{s}{d}", .{ if (place == 0) "" else ",", value });
            try out.print("}}\nYs:[]i64=Xs.ReplaceAll(Ps,Rs)\nZs:[]i64=Attempt(Ys.Insert[{d},array{{7,8}}],Ys)\nWs:[]i64=Attempt(Zs.Remove[{d},{d}],Zs)\nUs:[]i64=Attempt(Ws.ReplaceElement[{d},8],Ws).ReplaceAllElements(8,6)\nAll:[]i64=Concatenate(Us,Xs)\nValue:i64=Sum(For(I->X:All,(I+1)*X))+All.Length*100000", .{ at, from, to, index });
            var buffer: [32]i64 = undefined;
            var length: usize = 0;
            var read: usize = 0;
            while (read < items.len) {
                if (read + pattern_length <= items.len and std.mem.eql(i64, items[read..][0..pattern_length], pattern[0..pattern_length])) {
                    for (replacement[0..replacement_length]) |value| {
                        buffer[length] = value;
                        length += 1;
                    }
                    read += pattern_length;
                } else {
                    buffer[length] = items[read];
                    length += 1;
                    read += 1;
                }
            }
            if (at >= 0 and at <= @as(i64, @intCast(length))) {
                const place: usize = @intCast(at);
                std.mem.copyBackwards(i64, buffer[place + 2 .. length + 2], buffer[place..length]);
                buffer[place] = 7;
                buffer[place + 1] = 8;
                length += 2;
            }
            if (from >= 0 and from <= to and to <= @as(i64, @intCast(length))) {
                const low: usize = @intCast(from);
                const high: usize = @intCast(to);
                std.mem.copyForwards(i64, buffer[low .. length - (high - low)], buffer[high..length]);
                length -= high - low;
            }
            if (index >= 0 and index < @as(i64, @intCast(length))) buffer[@intCast(index)] = 8;
            for (buffer[0..length]) |*value| if (value.* == 8) {
                value.* = 6;
            };
            for (items) |item| {
                buffer[length] = item;
                length += 1;
            }
            var sum: i64 = 0;
            for (buffer[0..length], 1..) |value, weight| sum += @as(i64, @intCast(weight)) * value;
            return .{ .value = sum + @as(i64, @intCast(length)) * 100000 };
        },
        // Text stays text: a pattern is replaced wherever it occurs, and an insertion or a
        // removal at a position inside a letter of two units fails.
        66 => {
            const text = Text.random(c);
            const patterns = [_][]const u8{ "a", "b", "ab", "\xc3\xa9", "xy", "z" };
            const replacements = [_][]const u8{ "", "q", "\xc3\xa9\xc3\xa9", "abc" };
            const pattern = choose(c, []const u8, &patterns);
            const replacement = choose(c, []const u8, &replacements);
            const at = draw(c, text.len + 3) - 1;
            const from = draw(c, text.len + 2) - 1;
            const to = draw(c, text.len + 3) - 1;
            const letter = "abcxyz"[@intCast(draw(c, 6))];
            try out.print("S:string=\"{s}\"\nR:string=S.ReplaceAll(\"{s}\",\"{s}\")\nI:string=Attempt(S.Insert[{d},\"-\"],\"\")\nD:string=Attempt(S.Remove[{d},{d}],\"{s}????\")\nF:i64=Attempt(S.Find['{c}'],-1)\nValue:i64=R.Length*1000000+I.Length*10000+D.Length*100+F+1", .{ text.slice(), pattern, replacement, at, from, to, text.slice(), letter });
            const found: i64 = @intCast(std.mem.count(u8, text.slice(), pattern));
            const size: i64 = @intCast(text.len);
            const replaced = size + found * (@as(i64, @intCast(replacement.len)) - @as(i64, @intCast(pattern.len)));
            const whole = struct {
                fn place(t: *const Text, position: i64) bool {
                    return position >= 0 and position <= @as(i64, @intCast(t.len)) and t.boundary(@intCast(position));
                }
            };
            const inserted: i64 = if (whole.place(&text, at)) size + 1 else 0;
            const removed: i64 = if (whole.place(&text, from) and whole.place(&text, to) and from <= to) size - (to - from) else size + 4;
            const first_at: i64 = if (std.mem.indexOfScalar(u8, text.slice(), letter)) |position| @intCast(position) else -1;
            return .{ .value = replaced * 1000000 + inserted * 10000 + removed * 100 + first_at + 1 };
        },
        // Two maps merged: the first one's keys in their order, the second one's values where
        // both have a key, then the keys only the second has. And the integer functions, whose
        // bounds may come in either order.
        67 => {
            var maps: [2][6]?i64 = .{ @splat(null), @splat(null) };
            try out.writeAll("Sum:=native{\"std.sum\"}\n");
            var orders: [2][6]usize = undefined;
            var sizes: [2]usize = .{ 0, 0 };
            for (&maps, &orders, &sizes, 0..) |*map, *order, *size, which| {
                try out.print("{s}:map(i64,i64)=map{{", .{if (which == 0) "A" else "B"});
                for (0..@intCast(draw(c, 5))) |_| {
                    const key: usize = @intCast(draw(c, 6));
                    if (map[key] != null) continue;
                    map[key] = 10 + draw(c, 90);
                    try out.print("{s}{d}=>{d}", .{ if (size.* == 0) "" else ",", key, map[key].? });
                    order[size.*] = key;
                    size.* += 1;
                }
                try out.writeAll("}\n");
            }
            try out.print("J:map(i64,i64)=ConcatenateMaps(A,B)\nPs:[]i64=For(K->V:J,K*100+V)\nValue:i64=Sum(For(I->P:Ps,(I+1)*P))+Abs({d})+Min({d},{d})*3+Max({d},{d})*5+Clamp({d},{d},{d})", .{ a, b, offset, b, offset, a, offset, b });
            var sum: i64 = 0;
            var weight: i64 = 0;
            for (orders[0][0..sizes[0]]) |key| {
                weight += 1;
                sum += weight * (@as(i64, @intCast(key)) * 100 + (maps[1][key] orelse maps[0][key].?));
            }
            for (orders[1][0..sizes[1]]) |key| {
                if (maps[0][key] != null) continue;
                weight += 1;
                sum += weight * (@as(i64, @intCast(key)) * 100 + maps[1][key].?);
            }
            const low = @min(b, offset);
            const high = @max(b, offset);
            return .{ .value = sum + (if (a < 0) -a else a) + low * 3 + high * 5 + @max(low, @min(a, high)) };
        },
        // The float functions that IEEE arithmetic defines exactly: a square root, the larger
        // and the smaller of two, a clamp and an interpolation, in the order the Book gives.
        68 => {
            const square: f64 = @floatFromInt(draw(c, 200));
            const left: f64 = @floatFromInt(draw(c, 40) - 20);
            const right: f64 = @as(f64, @floatFromInt(draw(c, 40) - 20)) + 0.5;
            const other: f64 = @floatFromInt(draw(c, 9) - 2);
            const parameter = choose(c, f64, &.{ 0.0, 0.25, 0.5, 1.0, 2.0, -1.0 });
            try out.print("Value:float=Lerp(Sqrt({d:.1}),Max({d:.1},Min({d:.1},{d:.1})),{d:.2})+Abs(Clamp({d:.1},1.0,3.0)-2.0)", .{ square, left, right, other, parameter, other });
            const from = @sqrt(square);
            const to = @max(left, @min(right, other));
            const clamped = @max(1.0, @min(other, 3.0));
            return .{ .float_value = from * (1.0 - parameter) + to * parameter + @abs(clamped - 2.0) };
        },
        // A failed region undoes the write a standard form computed, and the magnitude of the
        // least `i64` ends the run where no `Attempt` catches it.
        69 => {
            const taken = 1 + draw(c, 4);
            const needed = 1 + draw(c, 4);
            const least = draw(c, 4) == 0;
            try out.print("var Cell:[]i64=array{{1,2,3}}\nTake(V:i64)<transacts><decides>:i64=Block{{set Cell=Cell.RemoveFirstElement[V];Cell.Find[{d}]}}\nR:i64=Attempt(Take[{d}],-1)\nBig:i64={s}\nValue:i64=Attempt(R*1000+Cell.Length*100+Abs(Big),-5)", .{ needed, taken, if (least) "0-9223372036854775807-1" else "-77" });
            if (least) return .{ .failed = .arithmetic_overflow };
            // The value is removed when it is there, and the search that follows must succeed
            // for the removal to stay.
            const found: i64 = if (taken > 3 or needed > 3 or needed == taken) -1 else if (needed < taken) needed - 1 else needed - 2;
            const length: i64 = if (found < 0) 3 else 2;
            return .{ .value = found * 1000 + length * 100 + 77 };
        },
        70 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Xs:[]i64=array{1}\nValue:i64=Xs.Find[1]",
                "Value:float=Sqrt(4)",
                "Value:i64=Min(1,2.0)",
                "Xs:[]i64=array{1}\nValue:i64=Attempt(Xs.Find(1),0)",
                "Value:i64=Attempt(\"ab\".Find[\"a\"],0)",
                "F(V:i64)<computes>:i64=V\nFs:[]function(tuple(i64),i64)=array{F}\nValue:i64=Attempt(Fs.Find[F],0)",
                "Value:i64=ConcatenateMaps(map{1=>2},map{\"a\"=>2}).Length",
                "Xs:[]i64=array{1}\nValue:i64=Xs.RemoveAllElements(1,2).Length",
                "Xs:[]i64=array{1}\nValue:i64=Attempt(Xs.Slice[0,1,2],Xs).Length",
                "Value:i64=Attempt(\"ab\".ReplaceElement[0,'a'],\"\").Length",
                "Value:i64=Concatenate(array{1,2}).Length",
                "Value:float=Attempt(5.IsFinite[],0.0)",
            }));
            return .syntax_failure;
        },
        // ---- A type parameter is a declaration: it may not take a visible name, and nothing
        // in its template may take its name. A generic function that nobody calls is refused
        // for the shadowing its body shows. With every name its own, the program has its value.
        71 => {
            const which = draw(c, 5);
            const n = draw(c, 50);
            const m = draw(c, 50);
            try out.print("Base:i64={d}\n", .{n});
            switch (which) {
                0 => try out.writeAll("Id[Base:type](X:Base)<computes>:Base{X}\n"),
                1 => try out.writeAll("Id[t:type](X:t,N:i64)<computes>:i64{Block{N:i64=2;N}}\n"),
                2 => try out.writeAll("Id[t:type](X:t,N:i64)<computes>:i64{Block{t:=N;t}}\nUse:i64=Id[string](\"s\",1)\n"),
                3 => try out.writeAll("Id[t:type](X:t,N:i64)<computes>:i64{Block{Base:=N;Base}}\n"),
                else => try out.writeAll("Id[t:type](X:t,N:i64)<computes>:i64{Block{M:=N*2;M}}\n"),
            }
            try out.print("Value:i64=Base+{d}", .{m});
            if (which < 4) return .syntax_failure;
            return .{ .value = n + m };
        },
        // ---- Instances that calls create and drop, beside one that a binding holds: the
        // report lists only the one a binding reaches, so the run stored, replayed with every
        // reclamation and replayed with none report alike.
        72 => {
            const kept = draw(c, 50);
            const n = draw(c, 50);
            const calls = 1 + draw(c, 4);
            // A run that ends with a fatal error after the instances are made reports nothing.
            const divisor: i64 = if (draw(c, 4) == 0) 0 else 1;
            try out.print("Node:=class{{V:i64,Next:option(Node)=option{{}}}}\nMake(N:i64)<transacts>:i64=Block{{A:=Node{{V:=N}};B:=Node{{V:=N*2,Next:=option{{A}}}};B.V+A.V}}\nKeep:=Node{{V:={d}}}\nStep(S:i64)<transacts>:i64=S+Make({d})\nTotal:i64=Iterate(Step,{d},0)\nValue:i64=Total+Keep.V/{d}", .{ kept, n, calls, divisor });
            if (divisor == 0) return .{ .failed = .division_by_zero };
            return .{ .value = 3 * n * calls + kept };
        },

        // ---- Effect families (RFC-0078): each function declares exactly what its body does, a
        // failed `<writes><decides>` call leaves no trace, and a function, an override and an
        // anonymous function with fewer effects are used where `<transacts>` is expected.
        73 => {
            const start = draw(c, 50);
            const held = draw(c, 50);
            const put = draw(c, 10);
            const limit = draw(c, 10);
            const made = draw(c, 9);
            const pure_leaf = draw(c, 2) == 0;
            const spelled = draw(c, 2) == 0;
            try out.print("var C:i64={d}\ncell:=class{{var N:i64={d}}}\nQ:cell=cell{{}}\n" ++
                "Peek()<reads>:i64=C+Q.N\n" ++
                "Put(V:i64)<decides><writes>:i64=Block{{set C=V;set Q.N=V;Require[V<{d}];V}}\n" ++
                "Make(V:i64)<allocates>:cell=cell{{N:=V}}\n" ++
                "Run(F:function<transacts>(tuple(),i64)){s}:i64=F()\n" ++
                "Base:=class<abstract>{{\nGet<abstract>()<transacts>:i64\n}}\n", .{ start, held, limit, if (spelled) "<transacts>" else "<allocates><writes><reads>" });
            try out.print("Leaf:=class(Base){{\nGet<override>(){s}\n}}\n" ++
                "Total(B:Base)<transacts>:i64=B.Get()\n" ++
                "R:i64=Attempt(Put[{d}],-1)\n" ++
                "Value:i64=R*10000+Run(Peek)*100+Total(Leaf{{}})+Make({d}).N+Run(Fn()<computes>:i64{{{d}}})", .{ if (pure_leaf) "<computes>:i64=7" else "<reads>:i64=C", put, made, made });
            const kept = put < limit;
            const variable = if (kept) put else start;
            const field = if (kept) put else held;
            const result: i64 = if (kept) put else -1;
            return .{ .value = result * 10000 + (variable + field) * 100 + (if (pure_leaf) @as(i64, 7) else variable) + made + made };
        },
        // A fatal error in a `<reads>` function is no failure: nothing catches it.
        74 => {
            const parts = draw(c, 3);
            const start = draw(c, 90);
            try out.print("var C:i64={d}\nShare(P:i64)<reads>:i64=C/P\nTell()<reads><writes>:i64=Block{{set C=C+1;Share({d})}}\nValue:i64=Attempt(Tell(),1)", .{ start, parts });
            return if (parts == 0) .{ .failed = .division_by_zero } else .{ .value = @divTrunc(start + 1, parts) };
        },
        75 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var C:i64=1\nF()<computes>:i64=C\nValue:i64=F()",
                "var C:i64=1\nF()<writes><allocates>:i64=C\nValue:i64=F()",
                "var C:i64=1\nF()<reads>:i64=Block{set C=2;2}\nValue:i64=F()",
                "c:=class{var N:i64=1}\nF()<reads><writes>:i64=c{}.N\nValue:i64=F()",
                "c:=class{var N:i64=1}\nF(X:c)<allocates>:i64=X.N\nValue:i64=F(c{})",
                "var C:i64=1\nG()<reads>:i64=C\nF()<writes>:i64=G()\nValue:i64=F()",
                "var C:i64=1\nG()<transacts>:i64=C\nF:function<reads>(tuple(),i64)=G\nValue:i64=F()",
                "G()<computes><decides>:i64=1\nF:function<transacts>(tuple(),i64)=G\nValue:i64=F()",
                "B:=class<abstract>{\nGet<abstract>()<reads>:i64\n}\nL:=class(B){\nGet<override>()<transacts>:i64=1\n}\nValue:i64=L{}.Get()",
                "F()<computes><suspends>:i64=1\nValue:i64=F()",
                "F()<computes><decides><suspends>:i64=1\nValue:i64=1",
                "F()<computes><reads>:i64=1\nValue:i64=F()",
                "F()<reads><reads>:i64=1\nValue:i64=F()",
                "F()<computes><converges>:i64=1\nValue:i64=F()",
                "F()<decides>:i64=1\nValue:i64=Attempt(F[],0)",
                "c:=class<transacts>{}\nF()<allocates>:c=c{}\nValue:i64=1",
                "c:=class<decides>{}\nValue:i64=1",
                "F()<reads>:i64=Block{var X:i64=1;X}\nValue:i64=F()",
                "I:=interface{\nGet()<computes>:i64\n}\nU:=class{\nGet()<reads>:i64=1\n}\nK:=class(U,I){}\nValue:i64=1",
                "P:=class{\nvar N:i64=0\nBlock{set Self.N=1}\n}\nK:=class<computes>(P){}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0080. A value held as `any` is the value it was made as: a type test selects
        // the arm of its type, and an instance also the arms of what its class inherits. A
        // function whose result is `void` runs its body and yields the unit value.
        76 => {
            const pick = draw(c, 9);
            try out.print("P:=struct{{X:i64,Y:i64}}\nInts:=[]i64\nAnimal:=class{{Legs:i64=4}}\nBird:=class(Animal){{Wings:i64=2}}\n" ++
                "MkB()<transacts>:Animal=Bird{{Legs:=2}}\nMkA()<transacts>:Animal=Animal{{}}\n" ++
                "var Seen:i64=0\nNote(V:i64)<transacts>:void=Set(Seen,Seen+V)\n" ++
                "Vs:[]any=array{{any({d}),any(\"text\"),any(P{{X:={d},Y:={d}}}),any(array{{{d},{d},{d}}}),any(MkB()),any(MkA()),any(2.5),any(true)}}\n" ++
                "Pick:any=Attempt(Vs[{d}],any(tuple{{}}))\nU:void=Note({d})\nSame:logic=U==tuple{{}}\n" ++
                "Kind:i64=Case(Pick,N:i64=>N,S:string=>S.Length+100,Q:P=>Q.X*Q.Y+200,L:Ints=>L.Length+300,B:Bird=>B.Wings+B.Legs+400,M:Animal=>M.Legs+500,F:float=>600,G:logic=>700,_=>800)\n" ++
                "Value:i64=If(Same,Kind,0-1)+Seen*1000", .{ a, a, b, a, b, a, pick, b });
            const selected: i64 = switch (pick) {
                0 => a,
                1 => 104,
                2 => a * b + 200,
                3 => 303,
                4 => 404,
                5 => 504,
                6 => 600,
                7 => 700,
                else => 800,
            };
            return .{ .value = selected + b * 1000 };
        },
        // A cast out of `any` fails unless the value is of the type, and a failure undoes what
        // its region wrote. A type test that selects an arm runs that arm, with its error.
        77 => {
            const pick = draw(c, 4);
            const divide = draw(c, 5) == 0;
            try out.print("P:=struct{{X:i64}}\nvar Count:i64=0\n" ++
                "Open(V:any)<transacts><decides>:i64=Block{{set Count=Count+10;T:=i64[V];set Count=Count+1;T}}\n" ++
                "Vs:[]any=array{{any({d}),any(\"x\"),any(P{{X:={d}}}),any({d})}}\n" ++
                "A:i64=Attempt(Open[any({d})],0-1)\nB:i64=Attempt(Open[any(\"x\")],0-2)\nR:i64=Attempt(Open[Vs[{d}]],0-3)\n" ++
                "D:i64=Case(Attempt(Vs[{d}],any(false)),N:i64=>{s},Q:P=>Q.X,_=>7)\n" ++
                "Value:i64=A+B*3+R*5+D*7+Count*11", .{ b, a, a + 1, offset, pick, pick, if (divide) "N/(N-N)" else "N+1" });
            const integer: ?i64 = switch (pick) {
                0 => b,
                3 => a + 1,
                else => null,
            };
            if (divide and integer != null) return .{ .failed = .division_by_zero };
            const r: i64 = integer orelse -3;
            const d: i64 = if (integer) |value| value + 1 else if (pick == 2) a else 7;
            const opened: i64 = 1 + @as(i64, @intFromBool(integer != null));
            return .{ .value = offset + (-2) * 3 + r * 5 + d * 7 + opened * 11 * 11 };
        },
        // Nothing converts to `any` or to `void` by itself, `any` has no operation but the
        // cast, and a `Case[...]` is a failable form with arms that can each be chosen.
        78 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:any=5",
                "A:any=any(5)\nValue:logic=A==A",
                "A:any=any(5)\nB:any=A+A\nValue:i64=1",
                "A:any=any(5)\nValue:i64=i64[A]",
                "A:any=any(5)\nValue:string=\"{A}\"",
                "M:map(any,i64)=map{}\nValue:i64=1",
                "A:i64=5\nValue:i64=Attempt(i64[A],0)",
                "Value:void=5",
                "F(X:i64)<computes>:void=X<3\nValue:i64=1",
                "F(X:i64)<computes>:void=Block{Return(X)}\nValue:i64=1",
                "Value:i64=Case[1,1=>2]",
                "Value:i64=Attempt(Case[1,1=>2,_=>3],0)",
                "Value:i64=Attempt(Case[1,1=>2,1=>3],0)",
                "Value:[]i64=tuple{1,2}",
                "Value:[]i64=ToArray(tuple{1,\"a\"})",
                "Xs:=Concatenate()\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // `Case[...]` fails when no arm takes the scrutinee, which undoes what evaluating the
        // scrutinee wrote; an arm that is taken keeps it. Strings are scrutinees too.
        79 => {
            const first_arm = draw(c, 5);
            const second_arm = first_arm + 1 + draw(c, 3);
            const scrutinee = draw(c, 9);
            const spelled = choose(c, []const u8, &.{ "ab", "cd", "ef", "" });
            try out.print("var Log:i64=0\nMark(V:i64)<transacts>:i64=Block{{set Log=Log*10+V+1;V}}\n" ++
                "F(N:i64)<transacts><decides>:i64=Case[Mark(N),{d}=>100,{d}=>200]\n" ++
                "R:i64=Attempt(F[{d}],0-1)\nS:i64=Attempt(Case[\"{s}\",\"ab\"=>1,\"cd\"=>2],0)\n" ++
                "T:i64=If(Case[{d},{d}=>true],5,6)\n" ++
                "Value:i64=R+S*1000+T*10000+Log*100000+{d}", .{ first_arm, second_arm, scrutinee, spelled, scrutinee, second_arm, offset });
            const r: i64 = if (scrutinee == first_arm) 100 else if (scrutinee == second_arm) 200 else -1;
            const text: i64 = if (std.mem.eql(u8, spelled, "ab")) 1 else if (std.mem.eql(u8, spelled, "cd")) 2 else 0;
            const t: i64 = if (scrutinee == second_arm) 5 else 6;
            const log: i64 = if (r < 0) 0 else scrutinee + 1;
            return .{ .value = r + text * 1000 + t * 10000 + log * 100000 + offset };
        },
        // `ToArray` gives the elements of a tuple in order; `Concatenate()` and an empty first
        // argument take their type from where they stand.
        80 => {
            const index = draw(c, 6);
            try out.print("T:tuple(i64,i64,i64)=tuple{{{d},{d},{d}}}\nXs:[]i64=ToArray(T)\nE:[]i64=Concatenate()\n" ++
                "All:[]i64=Concatenate(E,Xs,ToArray(tuple{{{d}}}))\nJ:string=Join(array{{}},\",\")\nG:[]i64=Concatenate(array{{}},Xs)\n" ++
                "Value:i64=Attempt(All[{d}],0-1)*10+All.Length+J.Length+G.Length", .{ a, b, a + b, offset, index });
            const all = [_]i64{ a, b, a + b, offset };
            const element: i64 = if (index < 4) all[@intCast(index)] else -1;
            return .{ .value = element * 10 + 4 + 0 + 3 };
        },
        // ---- Native effects (RFC-0079). A draw inside a region that fails is spent, and the
        // next draw is the next value of the stream; its use is undone with the region.
        81 => {
            const low = draw(c, 20) - 10;
            const high = low + draw(c, 1000);
            const threshold = low + draw(c, 1001);
            const swap = draw(c, 2) == 0;
            try out.print("Roll()<transacts>:i64=GetRandomInt({d},{d})\nA:i64=Attempt(Block{{X:=Roll();Require[X<{d}];X}},-1)\nB:i64=GetRandomInt({d},{d})\nC:[]i64=Shuffle(array{{1,2}})\nD:i64=GetRandomInt(0,9)\nValue:i64=A*1000000+B*10+D", .{ if (swap) high else low, if (swap) low else high, threshold, low, high });
            var stream: Stream = .{};
            const x = stream.integer(low, high);
            const a_value: i64 = if (x < threshold) x else -1;
            const b_value = stream.integer(low, high);
            _ = stream.next();
            const d_value = stream.integer(0, 9);
            return .{ .effects = .{ .value = a_value * 1000000 + b_value * 10 + d_value, .draws = stream.position } };
        },
        // Lines printed in regions that commit and that fail, by functions that fail, and a
        // fatal error after them: what was committed before it stays, nothing else does.
        82 => {
            const first_arg = draw(c, 6) - 2;
            const second_arg = draw(c, 6) - 2;
            const threshold = draw(c, 3);
            const fatal = draw(c, 5) == 0;
            try out.print("Note(N:i64)<transacts><decides>:i64=Block{{Print(\"n{{N}}\");Require[N>{d}];N}}\nA:=Print(\"a\")\nB:i64=Attempt(Block{{Print(\"b\");X:=Note[{d}];Y:i64=Attempt(Note[{d}],0);Print(\"y{{Y}}\");X*10+Y}},-1)\nC:=Print(\"c{{B}}\")\n", .{ threshold, first_arg, second_arg });
            if (fatal) {
                try out.writeAll("Big:i64=Abs(0-9223372036854775807-1)\nValue:i64=B+Big");
                return .{ .failed = .arithmetic_overflow };
            }
            try out.writeAll("Value:i64=B");
            var model: Effects = .{ .value = -1 };
            model.line("a", .{});
            // The region of B: everything it prints goes if `Note[first]` fails.
            const region_start = model.length;
            const region_lines = model.lines;
            var pending: u64 = 0;
            model.line("b", .{});
            model.line("n{d}", .{first_arg});
            pending += 2;
            if (first_arg > threshold) {
                model.line("n{d}", .{second_arg});
                const y: i64 = if (second_arg > threshold) second_arg else 0;
                if (second_arg <= threshold) {
                    model.length -= std.fmt.count("n{d}", .{second_arg});
                    model.lines -= 1;
                    model.discarded += 1;
                }
                model.line("y{d}", .{y});
                model.value = first_arg * 10 + y;
            } else {
                model.discarded += pending;
                model.length = region_start;
                model.lines = region_lines;
            }
            model.line("c{d}", .{model.value});
            return .{ .effects = model };
        },
        83 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<computes>:i64=Block{Print(\"x\");1}\nValue:i64=F()",
                "F()<computes>:i64=GetRandomInt(1,6)\nValue:i64=F()",
                "F(Xs:[]i64)<computes>:i64=Shuffle(Xs).Length\nValue:i64=F(array{1})",
                "Value:i64=Block{D:=ToDiagnostic(1);1}",
                "A:=Print(42)\nValue:i64=1",
                "A:=Print(ToDiagnostic(1)+\"x\")\nValue:i64=1",
                "Value:i64=GetRandomInt(1.0,2.0)",
                "Value:i64=Shuffle(\"text\").Length",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0081. A generic method is specialized for its receiver's class and its own
        // arguments, and reaches the instance's fields; one of a parametric type sees the type's
        // argument.
        84 => {
            const scale = 1 + draw(c, 9);
            const extra = draw(c, 50);
            try out.print("Box[T:type]:=class{{\nV:T\nWith[U:type](X:U,F:function(tuple(T,U),i64))<reads>:i64{{F(Self.V,X)}}\n}}\n" ++
                "Acc:=class{{\nvar N:i64={d}\nAdd[U:type](Xs:[]U)<transacts>:i64{{Block{{set Self.N=Self.N+Xs.Length*{d};Self.N}}}}\n}}\n" ++
                "B:=Box[i64]{{V:={d}}}\nT:=Box[string]{{V:=\"abc\"}}\nK:=Acc{{}}\n" ++
                "P:i64=B.With[i64]({d},Fn(A:i64,X:i64)<computes>:i64{{A*X}})\nQ:i64=T.With[i64]({d},Fn(S:string,X:i64)<computes>:i64{{S.Length+X}})\n" ++
                "Run()<transacts>:i64=K.Add[i64](array{{1,2}})+K.Add[string](array{{\"x\"}})\n" ++
                "Value:i64=P+Q*7+Run()*11", .{ offset, scale, a, b, extra });
            const first_add = offset + 2 * scale;
            const second_add = first_add + scale;
            return .{ .value = a * b + (3 + extra) * 7 + (first_add + second_add) * 11 };
        },
        // `SortBy` is stable: elements of one key keep their order. A comparison that fails
        // undoes its writes and one that succeeds keeps them, so the count of kept writes is the
        // number of comparisons that succeeded.
        85 => {
            var keys: [7]i64 = undefined;
            for (&keys) |*key| key.* = draw(c, 4);
            try out.writeAll("P:=struct{K:i64,I:i64}\nvar Won:i64=0\nLess(A:P,B:P)<transacts><decides>:void=Block{set Won=Won+1;Require[A.K<B.K]}\nXs:[]P=array{");
            for (keys, 0..) |key, index| try out.print("{s}P{{K:={d},I:={d}}}", .{ if (index == 0) "" else ",", key, index });
            try out.print("}}\nSort()<transacts>:[]P=SortBy(Xs,Less)\nYs:[]P=Sort()\nValue:i64=Attempt(Ys[0].I+Ys[3].I*10+Ys[6].I*100,0)+{d}", .{offset});
            var order = [7]usize{ 0, 1, 2, 3, 4, 5, 6 };
            const Context = struct {
                keys: []const i64,
                fn less(context: @This(), x: usize, y: usize) bool {
                    return context.keys[x] < context.keys[y];
                }
            };
            std.sort.insertion(usize, &order, Context{ .keys = &keys }, Context.less);
            return .{ .value = @as(i64, @intCast(order[0])) + @as(i64, @intCast(order[3])) * 10 + @as(i64, @intCast(order[6])) * 100 + offset };
        },
        // A `castable_subtype` value casts to the class it names; a `concrete_subtype` value
        // builds one with its defaults.
        86 => {
            const picked = draw(c, 3);
            const made = draw(c, 3);
            try out.print("Base:=class<castable>{{N:i64={d}}}\nOne:=class<concrete>(Base){{N<override>:i64={d}}}\nTwo:=class<concrete>(Base){{N<override>:i64={d}}}\n" ++
                "Kinds:[]castable_subtype(Base)=array{{Base,One,Two}}\nMakers:[]concrete_subtype(Base)=array{{One,Two,One}}\n" ++
                "Build(M:concrete_subtype(Base))<allocates>:Base=M{{}}\nIs(X:Base,K:castable_subtype(Base))<computes>:logic=Attempt(Block{{K[X];true}},false)\n" ++
                "M:concrete_subtype(Base)=Attempt(Makers[{d}],One)\nK:castable_subtype(Base)=Attempt(Kinds[{d}],Base)\nX:Base=Build(M)\nHit:i64=If(Is(X,K),1,0)\nValue:i64=Hit*1000+X.N", .{ a, b, offset, made, picked });
            const class_of_made: u64 = if (made == 1) 2 else 1;
            const hit: i64 = if (picked == 0 or picked == class_of_made) 1 else 0;
            const n = if (class_of_made == 1) b else offset;
            return .{ .value = hit * 1000 + n };
        },
        // A generic method's writes are undone with the region that fails after it, and a
        // comparison that divides by zero ends the sort and the run.
        87 => {
            const fail = draw(c, 2) == 0;
            const divide = draw(c, 3) == 0;
            try out.print("Acc:=class{{\nvar N:i64=0\nAdd[U:type](X:U)<transacts>:i64{{Block{{set Self.N=Self.N+{d};Self.N}}}}\n}}\nK:=Acc{{}}\n" ++
                "Try()<transacts><decides>:i64=Block{{K.Add[i64](1);Require[{s}];K.N}}\nR:i64=Attempt(Try[],0-1)\n" ++
                "Less(A:i64,B:i64)<computes><decides>:void=Require[A{s}<B]\nYs:[]i64=SortBy(array{{3,1,2}},Less)\n" ++
                "Value:i64=R*10+K.N+Attempt(Ys[0],0)*1000", .{ a, if (fail) "1>2" else "1<2", if (divide) "/(A-A)" else "" });
            if (divide) return .{ .failed = .division_by_zero };
            const kept: i64 = if (fail) 0 else a;
            const r: i64 = if (fail) -1 else a;
            return .{ .value = r * 10 + kept + 1000 };
        },
        88 => {
            try out.writeAll(choose(c, []const u8, &.{
                "A:=class{\nG<override>[U:type](X:U)<computes>:U{X}\n}\nValue:i64=1",
                "I:=interface{\nG[U:type](X:U)<computes>:U\n}\nValue:i64=1",
                "A:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nB:=class(A){\nG()<computes>:i64=1\n}\nValue:i64=1",
                "A:=class{\nG[U:type](X:U)<computes>:U{X}\n}\nValue:i64=A{}.G(1)",
                "Root:=class{}\nLeaf:=class(Root){}\nK:castable_subtype(Root)=Leaf\nValue:i64=1",
                "E:=class<abstract>{}\nK:concrete_subtype(E)=E\nValue:i64=1",
                "B:=class<castable>{}\nK:subtype(B)=B\nValue:i64=Attempt(Block{K[B{}];1},0)",
                "Less(A:i64,B:i64)<computes>:logic=A<B\nValue:i64=SortBy(array{2,1},Less)[0]",
                "Value:i64=SortBy(array{2,1})[0]",
            }));
            return .syntax_failure;
        },
        // ---- Loops at the root do what the root does (RFC-0079, `fix2`): print, write a module
        // `var`, carry a local `var`, and `First` stops at the first element its clause keeps.
        // A division by zero after them ends the run with the lines already committed.
        89 => {
            var xs: [3]i64 = undefined;
            for (&xs) |*x| x.* = draw(c, 21) - 10;
            const k = draw(c, 4);
            const threshold = draw(c, 21) - 10;
            const fatal = draw(c, 5) == 0;
            try out.print("var C:i64=0\nXs:[]i64=array{{{d},{d},{d}}}\nP:[]tuple()=For(X:Xs, Print(\"e{{X}}\"))\nS:[]i64=For(X:Xs, Block{{set C=C+X;C}})\n", .{ xs[0], xs[1], xs[2] });
            try out.print("W:i64=Block{{var I:i64=0;While(I<{d},Block{{set C=C+1;set I=I+1}});I}}\nF:i64=Attempt(First[X:Xs,X>{d},Block{{Print(\"f{{X}}\");X}}],-1)\n", .{ k, threshold });
            if (fatal) {
                try out.writeAll("Value:i64=F/(C-C)");
                return .{ .failed = .division_by_zero };
            }
            try out.writeAll("Value:i64=C*100+F");
            var model: Effects = .{ .value = 0 };
            for (xs) |x| model.line("e{d}", .{x});
            var kept: i64 = -1;
            for (xs) |x| if (x > threshold) {
                kept = x;
                model.line("f{d}", .{x});
                break;
            };
            model.value = (xs[0] + xs[1] + xs[2] + k) * 100 + kept;
            return .{ .effects = model };
        },
        // ---- Function arms join to the union of their effects, and a function type takes a
        // function of a wider parameter and a narrower result (RFC-0078, `fix2`).
        90 => {
            const flag = draw(c, 2) == 0;
            const add = draw(c, 100);
            const start = draw(c, 100);
            const v = draw(c, 100);
            const m = draw(c, 100);
            try out.print("var C:i64={d}\nPure(X:i64)<computes>:i64=X+{d}\nBump(X:i64)<transacts>:i64=Block{{set C=C+X;C}}\nG:=If({s},Pure,Bump)\n", .{ start, add, word(flag) });
            try out.print("animal:=class{{N:i64=1}}\ndog:=class(animal){{}}\nFeed(A:animal)<allocates>:dog=dog{{N:={d}}}\nH:function<allocates>(tuple(dog),animal)=Feed\nValue:i64=G({d})*1000+H(dog{{}}).N", .{ m, v });
            const g = if (flag) v + add else start + v;
            return .{ .value = g * 1000 + m };
        },
        // ---- Refused: a template body that shadows a local of its own, uncalled; a method of
        // a parametric type that redeclares its parameter; arms whose effects cannot join; a
        // loop inside a function that writes what its function may not.
        91 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F[T:type](A:T)<computes>:T{Block{X:=1;Block{X:=2;A}}}\nValue:i64=1",
                "F[T:type](A:T)<computes>:T{Block{X:=1;X:=2;A}}\nValue:i64=1",
                "b[T:type]:=class{M(A:T)<computes>:T=Block{A:=2;A}}\nValue:i64=1",
                "Wait(X:i64)<computes><suspends>:i64=X\nCheck(X:i64)<computes><decides>:i64=X\nG:=If(true,Check,Wait)\nValue:i64=1",
                "back(A:i64)<computes>:i64=A\nanimal:=class{N:i64=1}\nOld(A:animal)<computes>:i64=1\nF:function<computes>(tuple(i64),i64)=If(true,back,Old)\nValue:i64=1",
                "var C:i64=0\nXs:[]i64=array{1}\nF()<computes>:[]i64=For(X:Xs,Block{set C=X;X})\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.1. Tasks spawned by the root run at once until they first wait (S2);
        // after the root the clock jumps to each deadline and wakes its sleepers in the order
        // they began to wait (S3, S6). The schedule is worked out again here.
        92 => {
            const tasks: usize = 2 + @as(usize, @intCast(draw(c, 3)));
            var halves: [4]i64 = undefined;
            for (halves[0..tasks]) |*half| half.* = 1 + draw(c, 3);
            for (halves[0..tasks], 0..) |half, index| try out.print("B{d}()<transacts><suspends>:void=Block{{Print(\"a{d}\");Sleep({d}.{d});Print(\"b{d}\")}}\n", .{ index, index, @divTrunc(half, 2), @mod(half, 2) * 5, index });
            for (0..tasks) |index| try out.print("T{d}:task(void)=Spawn{{B{d}()}}\n", .{ index, index });
            try out.print("R:=Print(\"root\")\nValue:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            for (0..tasks) |index| model.line("a{d}", .{index});
            model.line("root", .{});
            // Every deadline is a whole number of half seconds; equal ones wake in spawn order.
            var order: [4]usize = .{ 0, 1, 2, 3 };
            const Context = struct {
                halves: []const i64,
                fn less(context: @This(), x: usize, y: usize) bool {
                    return context.halves[x] < context.halves[y];
                }
            };
            std.sort.insertion(usize, order[0..tasks], Context{ .halves = halves[0..tasks] }, Context.less);
            for (order[0..tasks]) |index| model.line("b{d}", .{index});
            return .{ .effects = model };
        },
        // A spawn inside a region starts when the outermost region commits, after what it printed;
        // one in a region that fails never runs.
        93 => {
            const threshold = draw(c, 3);
            const first_arg = draw(c, 4);
            const second_arg = draw(c, 4);
            try out.print("Body(N:i64)<transacts><suspends>:void=Print(\"t{{N}}\")\nF(N:i64)<transacts><decides>:i64=Block{{Spawn{{Body(N)}};Print(\"in{{N}}\");Require[N>{d}];N}}\nA:i64=Attempt(F[{d}],-1)\nB:i64=Attempt(F[{d}],-1)\nValue:i64=A*10+B", .{ threshold, first_arg, second_arg });
            var model: Effects = .{ .value = 0 };
            var value: i64 = 0;
            for ([_]i64{ first_arg, second_arg }) |argument| {
                if (argument > threshold) {
                    model.line("in{d}", .{argument});
                    model.line("t{d}", .{argument});
                    value = value * 10 + argument;
                } else {
                    model.discarded += 1;
                    value = value * 10 - 1;
                }
            }
            model.value = value;
            return .{ .effects = model };
        },
        // A task that sleeps for NaN seconds ends the run.
        94 => {
            const nan = draw(c, 2) == 0;
            try out.print("Nap(S:float)<transacts><suspends>:void=Sleep(S)\nT:task(void)=Spawn{{Nap({s})}}\nValue:i64={d}", .{ if (nan) "0.0/0.0" else "0.5", a });
            if (nan) return .{ .failed = .invalid_sleep_duration };
            return .{ .value = a };
        },
        95 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=Block{Sleep(1.0);1}",
                "F()<transacts>:void=Sleep(1.0)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Attempt(Block{Sleep(1.0);1},0)\nValue:i64=1",
                "F()<transacts>:i64=Block{T:=Spawn{Return(1)};0}\nValue:i64=1",
                "F()<transacts>:i64=Block{X:i64=1;T:=Spawn{set X=2;X};X}\nValue:i64=1",
                "F()<reads>:i64=Block{T:=Spawn{1};0}\nValue:i64=1",
                "Value:i64=Block{X:=Spawn(1);1}",
                "W()<transacts><suspends>:i64=1\nT:task(i64)=Spawn{W()}\nValue:task(string)=T",
            }));
            return .syntax_failure;
        },

        // ---- Refinements, qualifiers and aliases (RFC-0083).
        // A cast to a refinement takes exactly the values within its bounds; a failed one undoes
        // what its region wrote. Converted back, a zero divides by zero and ends the run.
        96 => {
            const low = draw(c, 7) - 3;
            const high = low + draw(c, 6);
            // Some integer lies between the bounds: an empty refinement is refused (case 97).
            const open_low = draw(c, 2) == 0 and high > low;
            const open_high = draw(c, 2) == 0 and high > low + 1;
            var values: [5]i64 = undefined;
            for (&values) |*value| value.* = draw(c, 13) - 6;
            const divide = draw(c, 3) == 0;
            const lowest = if (open_low) low + 1 else low;
            const highest = if (open_high) high - 1 else high;
            try out.print("Sum:=native{{\"std.sum\"}}\nR:=type{{_X:i64 where {d}{s}_X,_X{s}{d}}}\nvar Log:i64=0\n" ++
                "Take(N:i64)<transacts><decides>:i64=Block{{set Log=Log+1;V:=R[N];set Log=Log+100;i64(V)}}\n" ++
                "Vs:[]i64=array{{{d},{d},{d},{d},{d}}}\nTotal:i64=Sum(For(X:Vs,Attempt(Take[X],-1000)))\nSeen:i64=Log\nZ:R=Attempt(R[Vs[0]],{d})\n" ++
                "Value:i64=Total+Seen*1000000{s}", .{ low, if (open_low) "<" else "<=", if (open_high) "<" else "<=", high, values[0], values[1], values[2], values[3], values[4], lowest, if (divide) "+100/i64(Z)" else "" });
            var sum: i64 = 0;
            var log: i64 = 0;
            for (values) |value| {
                // A cast that fails fails `Take`, whose first write is undone with it.
                if (value >= lowest and value <= highest) {
                    log += 101;
                    sum += value;
                } else sum -= 1000;
            }
            var result = sum + log * 1000000;
            if (divide) {
                const z = if (values[0] >= lowest and values[0] <= highest) values[0] else lowest;
                if (z == 0) return .{ .failed = .division_by_zero };
                result += @divTrunc(100, z);
            }
            return .{ .value = result };
        },
        // The forms the rules refuse: bounds that are not literals of the base, a constant
        // outside the bounds, a refinement where its base is expected, a qualifier of nothing,
        // an open enum covered without a default, and an arm an earlier arm's type subsumes.
        97 => {
            try out.writeAll(choose(c, []const u8, &.{
                "R:=type{_X:float where _X<1}\nValue:i64=1",
                "L:i64=1\nR:=type{_X:i64 where _X<L}\nValue:i64=1",
                "R:=type{_X:i64 where _X>3,_X<2}\nValue:i64=1",
                "R:=type{_X:i64 where _X<3,_X<5}\nValue:i64=1",
                "R:=type{_X:float where _X<NaN}\nValue:i64=1",
                "R:=type{_X:i64 where 0<=_X}\nX:R=-1\nValue:i64=1",
                "R:=type{_X:i64 where 0<=_X}\nX:R=1\nValue:i64=X",
                "R:=type{_X:i64 where 0<=_X}\nX:R=1\nValue:i64=i64(X)+X",
                "R:=type{_X:i64 where 0<=_X}\nN:i64=1\nX:R=N\nValue:i64=1",
                "R:=type{_X:i64 where 0<=_X}\nX:R=1\nA:any=any(X)\nValue:i64=1",
                "(local:)Value:i64=1",
                "X:i64=1\nF()<computes>:i64=(local:)X\nValue:i64=F()",
                "M:=enum<open>{A,B}\nValue:i64=Case(M.A,M.A=>1,M.B=>2)",
                "P:=class{}\nQ:=class(P){}\nF(V:any)<computes><decides>:i64=Case[V,X:P=>1,Y:Q=>2]\nValue:i64=1",
                "S[T:type]:=[]T\nValue:S=array{}",
            }));
            return .syntax_failure;
        },
        // A local declared `(local:)` beside a module binding of its name means the local
        // there, and the binding everywhere else; `(Module:)` is not needed for that.
        98 => {
            const outer = draw(c, 50);
            const inner = draw(c, 50);
            const n = draw(c, 6);
            const divide = draw(c, 5) == 0;
            try out.print("X:i64={d}\nF((local:)X:i64)<computes>:i64=Block{{(local:)Y:i64=X*2;(local:)Y+{s}}}\n" ++
                "G()<computes>:i64=Block{{(local:)X:i64={d};For((local:)I:0..{d},(local:)I+X).Length*1000+X}}\n" ++
                "Value:i64=F({d})*100000+G()+X*10000000", .{ outer, if (divide) "100/(X-X)" else "1", inner, n, inner });
            if (divide) return .{ .failed = .division_by_zero };
            return .{ .value = (inner * 2 + 1) * 100000 + (n + 1) * 1000 + inner + outer * 10000000 };
        },
        // A parametric alias is the type its text names, and `Case[...]` over an open enum fails
        // where no arm takes the case instead of being refused for want of a default.
        99 => {
            const pick = draw(c, 3);
            const listed = draw(c, 3);
            const a_value = draw(c, 20);
            try out.print("Pair[T:type]:=tuple(T,T)\nTable[K:comparable]:=map(K,Pair[i64])\nMode:=enum<open>{{A,B,C}}\n" ++
                "T:Table[string]=map{{\"x\"=>tuple{{{d},2}}}}\nM:Mode=Mode.{s}\n" ++
                "Pick(V:Mode)<computes><decides>:i64=Case[V,Mode.A=>1,Mode.{s}=>10]\n" ++
                "Value:i64=Attempt(T[\"x\"](0),-1)*100+Attempt(Pick[M],0)", .{ a_value, switch (pick) {
                0 => "A",
                1 => "B",
                else => "C",
            }, switch (listed) {
                0 => "B",
                1 => "C",
                else => "B",
            } });
            const second: i64 = if (listed == 1) 2 else 1;
            const picked: i64 = if (pick == 0) 1 else if (pick == second) 10 else 0;
            return .{ .value = a_value * 100 + picked };
        },
        // ---- RFC-0082, P3.2. A signal wakes every task waiting on its event then, in the order
        // they began to wait, after the signaller's turn (S4, S6); one that waits only later
        // (here after a sleep) misses it and is abandoned at quiescence.
        100 => {
            const waiters: usize = 2 + @as(usize, @intCast(draw(c, 3)));
            const late: usize = @intCast(draw(c, waiters));
            const value = draw(c, 100);
            try out.writeAll("E:event(i64)=event(i64){}\n");
            for (0..waiters) |index| try out.print("W{d}()<transacts><suspends>:void=Block{{Print(\"a{d}\");{s}V:=E.Await();Print(\"b{d} {{V}}\")}}\n", .{ index, index, if (index == late) "Sleep(1.0);" else "", index });
            try out.print("Sig()<transacts><suspends>:void=Block{{E.Signal({d});Print(\"s\")}}\n", .{value});
            for (0..waiters) |index| try out.print("T{d}:task(void)=Spawn{{W{d}()}}\n", .{ index, index });
            try out.print("S:task(void)=Spawn{{Sig()}}\nValue:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            for (0..waiters) |index| model.line("a{d}", .{index});
            model.line("s", .{});
            for (0..waiters) |index| if (index != late) model.line("b{d} {d}", .{ index, value });
            return .{ .effects = model };
        },
        // `Await` of a handle gives its task's result, waiting for it if it has not completed;
        // a value that a signal hands on can end the run, here as a sleep of NaN seconds.
        101 => {
            const fatal = draw(c, 2) == 0;
            try out.print("E:event(float)=event(float){{}}\nWork(N:i64)<transacts><suspends>:i64=Block{{Sleep(0.5);N*2}}\nNap()<transacts><suspends>:void=Sleep(E.Await())\nWatch(T:task(i64))<transacts><suspends>:void=Block{{V:=T.Await();Print(\"w{{V}}\");E.Signal({s})}}\nN:task(void)=Spawn{{Nap()}}\nT:task(i64)=Spawn{{Work({d})}}\nU:task(void)=Spawn{{Watch(T)}}\nValue:i64={d}", .{ if (fatal) "0.0/0.0" else "0.25", a, b });
            if (fatal) return .{ .failed = .invalid_sleep_duration };
            var model: Effects = .{ .value = b };
            model.line("w{d}", .{a * 2});
            return .{ .effects = model };
        },
        // A signal inside a region happens when the region commits and never when it fails. The
        // ear is ready after the first signal delivered to it and has not waited again before the
        // root's next one, which is lost.
        102 => {
            const threshold = draw(c, 3);
            const first_arg = draw(c, 4);
            const second_arg = draw(c, 4);
            try out.print("E:event(i64)=event(i64){{}}\nEar()<transacts><suspends>:void=Loop{{V:=E.Await();Print(\"e{{V}}\")}}\nF(N:i64)<transacts><decides>:i64=Block{{E.Signal(N);Print(\"in{{N}}\");Require[N>{d}];N}}\nT:task(void)=Spawn{{Ear()}}\nA:i64=Attempt(F[{d}],-1)\nB:i64=Attempt(F[{d}],-1)\nValue:i64=A*10+B", .{ threshold, first_arg, second_arg });
            var model: Effects = .{ .value = 0 };
            var value: i64 = 0;
            var delivered: ?i64 = null;
            for ([_]i64{ first_arg, second_arg }) |argument| {
                if (argument > threshold) {
                    model.line("in{d}", .{argument});
                    if (delivered == null) delivered = argument;
                    value = value * 10 + argument;
                } else {
                    model.discarded += 1;
                    value = value * 10 - 1;
                }
            }
            if (delivered) |signalled| model.line("e{d}", .{signalled});
            model.value = value;
            return .{ .effects = model };
        },
        103 => {
            try out.writeAll(choose(c, []const u8, &.{
                "E:event(i64)=event(i64){}\nValue:i64=E.Await()",
                "E:event(i64)=event(i64){}\nF()<transacts>:i64=E.Await()\nValue:i64=1",
                "E:event(i64)=event(i64){}\nF()<transacts><suspends>:i64=Attempt(E.Await(),0)\nValue:i64=1",
                "E:event(i64)=event(i64){}\nF()<reads>:void=E.Signal(1)\nValue:i64=1",
                "F()<reads>:event(i64)=event(i64){}\nValue:i64=1",
                "E:event(i64)=event(i64){}\nValue:void=E.Signal(\"x\")",
                "E:event(i64)=event(i64){1}\nValue:i64=1",
                "W()<transacts><suspends>:i64=1\nT:task(i64)=Spawn{W()}\nF()<transacts><suspends>:string=T.Await()\nValue:i64=1",
                "E:event(i64)=event(i64){}\nValue:logic=logic{E==E}",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.3. A `Race` of three arms with different sleeps: the first to wake
        // completes (its `Defer` runs at its end) and wins, and the two others are cancelled, in
        // arm order, each running its `Defer` in its landing, before the `Race` yields.
        104 => {
            const fastest: usize = @intCast(draw(c, 3));
            const slots = [3][]const u8{ "1.5", "2.5", "3.5" };
            var order: [3]usize = .{ 1, 2, 0 };
            if (draw(c, 2) == 0) order = .{ 2, 1, 0 };
            var seconds: [3][]const u8 = undefined;
            seconds[fastest] = "0.5";
            var next: usize = 0;
            for (0..3) |arm| if (arm != fastest) {
                seconds[arm] = slots[order[next]];
                next += 1;
            };
            try out.print("Arm(N:i64,S:float)<transacts><suspends>:i64=Block{{Defer{{Print(\"d{{N}}\")}};Sleep(S);N}}\nMain()<transacts><suspends>:void=Block{{W:=Race(Arm(1,{s}),Arm(2,{s}),Arm(3,{s}));Print(\"w{{W}}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ seconds[0], seconds[1], seconds[2], offset });
            var model: Effects = .{ .value = offset };
            model.line("d{d}", .{fastest + 1});
            for (0..3) |arm| if (arm != fastest) model.line("d{d}", .{arm + 1});
            model.line("w{d}", .{fastest + 1});
            return .{ .effects = model };
        },
        // A `Sync` yields the tuple of its arms' results in arm order, once all completed, each
        // having run its `Defer` as it ended; an arm that sleeps NaN seconds ends the run.
        105 => {
            const fatal = draw(c, 4) == 0;
            const late = draw(c, 2) == 0;
            try out.print("Arm(N:i64,S:float)<transacts><suspends>:i64=Block{{Defer{{Print(\"d{{N}}\")}};Sleep(S);N*({d})}}\nMain()<transacts><suspends>:void=Block{{P:=Sync(Arm(1,{s}),Arm(2,{s}));Print(\"s{{P(0)}} {{P(1)}}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ a, if (late) "1.0" else "0.5", if (fatal) "0.0/0.0" else if (late) "0.5" else "1.0", offset });
            if (fatal) return .{ .failed = .invalid_sleep_duration };
            var model: Effects = .{ .value = offset };
            if (late) {
                model.line("d2", .{});
                model.line("d1", .{});
            } else {
                model.line("d1", .{});
                model.line("d2", .{});
            }
            model.line("s{d} {d}", .{ a, 2 * a });
            return .{ .effects = model };
        },
        // A `Race` that resolves cancels a `Sync` arm: the request reaches the `Sync`'s arms
        // first, depth first in arm order, so the leaves' `Defer`s run before the `Sync`'s task's.
        106 => {
            const leaves: usize = 2 + @as(usize, @intCast(draw(c, 2)));
            try out.writeAll("Leaf(N:i64)<transacts><suspends>:void=Block{Defer{Print(\"l{N}\")};Sleep(Inf)}\nGroup()<transacts><suspends>:i64=Block{Defer{Print(\"g\")};S:=Sync(");
            for (0..leaves) |leaf| try out.print("{s}Leaf({d})", .{ if (leaf == 0) "" else ",", leaf });
            try out.print(");0}}\nMain()<transacts><suspends>:void=Block{{W:=Race(Group(),Block{{Sleep(0.25);{d}}});Print(\"w{{W}}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ b, offset });
            var model: Effects = .{ .value = offset };
            for (0..leaves) |leaf| model.line("l{d}", .{leaf});
            model.line("g", .{});
            model.line("w{d}", .{b});
            return .{ .effects = model };
        },
        107 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:tuple(i64,i64)=Sync(1,2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Race(Block{Sleep(1.0);1})\nValue:i64=1",
                "F()<transacts><suspends>:i64=Race(Block{Sleep(1.0);T:=Spawn{Return(1)};1},2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{N:i64=0;Race(Block{Sleep(1.0);set N=1;N},2)}\nValue:i64=1",
                "F()<transacts>:i64=Race(Block{Sleep(1.0);1},2)\nValue:i64=1",
                "Value:i64=Race(1,2)",
                "F(N:i64)<transacts><suspends>:i64=Block{Defer{set N=1};Sleep(1.0);N}\nG()<transacts><suspends>:i64=Race(F(1),2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Attempt(Race(Block{Sleep(1.0);1},2),0)\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.4. A branch sleeping half a second, in a function that sleeps less or
        // more: ended first, the function's end cancels the branch, whose `Defer` runs then;
        // ended last, the branch has finished, its `Defer` at its own end.
        108 => {
            const early = draw(c, 2) == 0;
            try out.print("Fire()<transacts><suspends>:void=Block{{Branch{{Defer{{Print(\"c\")}};Sleep(0.5);Print(\"b\")}};Sleep({s});Print(\"m\")}}\nMain()<transacts><suspends>:void=Block{{Fire();Print(\"r{d}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ if (early) "0.25" else "1.0", a, offset });
            var model: Effects = .{ .value = offset };
            if (early) {
                model.line("m", .{});
                model.line("c", .{});
            } else {
                model.line("b", .{});
                model.line("c", .{});
                model.line("m", .{});
            }
            model.line("r{d}", .{a});
            return .{ .effects = model };
        },
        // A `Rush` of three arms of different sleeps: the first to wake yields, and the others go
        // on under the frame, each printing when it wakes, before the frame ends five seconds
        // later; an arm that sleeps NaN seconds ends the run.
        109 => {
            const fatal = draw(c, 4) == 0;
            const fastest: usize = @intCast(draw(c, 3));
            const slots = [2][]const u8{ "1.5", "2.5" };
            var order: [2]usize = .{ 0, 1 };
            if (draw(c, 2) == 0) order = .{ 1, 0 };
            var seconds: [3][]const u8 = undefined;
            var rank: [3]usize = undefined;
            seconds[fastest] = "0.5";
            rank[fastest] = 0;
            var next: usize = 0;
            for (0..3) |arm| if (arm != fastest) {
                seconds[arm] = slots[order[next]];
                rank[arm] = order[next] + 1;
                next += 1;
            };
            try out.print("Arm(N:i64,S:float)<transacts><suspends>:i64=Block{{Sleep(S);Print(\"a{{N}}\");N}}\nMain()<transacts><suspends>:void=Block{{W:=Rush(Arm(1,{s}),Arm(2,{s}),Arm(3,{s}));Print(\"w{{W}}\");Sleep(5.0);Print(\"e\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ if (fatal and fastest != 0) "0.0/0.0" else seconds[0], if (fatal and fastest == 0) "0.0/0.0" else seconds[1], seconds[2], offset });
            if (fatal) return .{ .failed = .invalid_sleep_duration };
            var model: Effects = .{ .value = offset };
            for (0..3) |position| for (0..3) |arm| if (rank[arm] == position) {
                model.line("a{d}", .{arm + 1});
                if (position == 0) model.line("w{d}", .{arm + 1});
            };
            model.line("e", .{});
            return .{ .effects = model };
        },
        // A function that owns two to four branches, each waiting for ever, cancels them at its
        // end in the order they came: each `Defer` runs, and then the function returns.
        110 => {
            const branches: usize = 2 + @as(usize, @intCast(draw(c, 3)));
            try out.writeAll("Leaf(N:i64)<transacts><suspends>:void=Block{Defer{Print(\"l{N}\")};Sleep(Inf)}\nOwner()<transacts><suspends>:void=Block{");
            for (0..branches) |branch| try out.print("Branch{{Leaf({d})}};", .{branch});
            try out.print("Print(\"o\")}}\nMain()<transacts><suspends>:void=Block{{Owner();Print(\"m{d}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ b, offset });
            var model: Effects = .{ .value = offset };
            model.line("o", .{});
            for (0..branches) |branch| model.line("l{d}", .{branch});
            model.line("m{d}", .{b});
            return .{ .effects = model };
        },
        111 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:void=Loop{Branch{Sleep(1.0)};Break()}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{var N:i64=0;While(N<3,Block{X:=Rush(Block{Sleep(1.0);1},2);set N=N+X});N}\nValue:i64=1",
                "F()<transacts>:void=Branch{Print(\"x\")}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{Branch{Sleep(1.0);Return(1)};2}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Rush(Block{Sleep(1.0);1})\nValue:i64=1",
                "F()<transacts><suspends>:i64=Attempt(Block{Branch{Sleep(1.0)};1},0)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{N:i64=0;Branch{Sleep(1.0);set N=1};N}\nValue:i64=1",
                "Value:i64=Rush(1,2)",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.1. A chain of live variables follows its source: through a write at
        // the root and a region whose failure restores the source and every record's value.
        112 => {
            const links: usize = 1 + @as(usize, @intCast(draw(c, 4)));
            const start = draw(c, 50);
            const tried = draw(c, 7) - 3;
            const step = draw(c, 20);
            try out.print("var S:i64={d}\nvar live C1:i64=S+1\n", .{start});
            for (2..links + 1) |link| try out.print("var live C{d}:i64=C{d}+{d}\n", .{ link, link - 1, link });
            try out.print("R:i64=Attempt(Block{{set S={d};Require[S>0];1}},0)\nset S=S+{d}\nValue:i64=C{d}*10+R", .{ tried, step, links });
            const kept = tried > 0;
            const source = (if (kept) tried else start) + step;
            const sum: i64 = @intCast(links * (links + 1) / 2);
            return .{ .value = (source + sum) * 10 + @intFromBool(kept) };
        },
        // Two records that read each other: a pair that settles at once, and a pair that grows
        // without end, stopped by the per-record bound.
        113 => {
            const grows = draw(c, 2) == 0;
            const seed = draw(c, 9);
            try out.print("var A:i64=0\nvar B:i64={d}\nset live A=B+1\nset live B={s}\nValue:i64=A*100+B", .{ seed, if (grows) "A+1" else "Max(A-1,0)" });
            if (grows) return .{ .failed = .live_unstable };
            // A = seed + 1, then B = seed, the value it holds: not written, so A is not run again.
            return .{ .value = (seed + 1) * 100 + seed };
        },
        // A diamond in a function's frames: written once per call, the record that reads both
        // sides is evaluated once per propagation, after them (its height is above theirs).
        114 => {
            const calls = 1 + draw(c, 6);
            const left_first = draw(c, 2) == 0;
            try out.writeAll("var S:i64=0\n");
            if (left_first) try out.writeAll("var live L:i64=S+1\nvar live R:i64=S*2\n") else try out.writeAll("var live R:i64=S*2\nvar live L:i64=S+1\n");
            try out.print("var live J:i64=L+R\nBump(N:i64)<transacts>:i64=Block{{set S=S+N;J}}\nX:[]i64=For(K:1..{d},Bump(K))\nValue:i64=J*1000+X.Length", .{calls});
            const total = @divTrunc(calls * (calls + 1), 2);
            return .{ .value = (3 * total + 1) * 1000 + calls };
        },
        115 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var X:i64=0\nvar Y:i64=0\nset live X=Block{set Y=1;2}\nValue:i64=1",
                "F()<transacts>:i64=Block{L:i64=1;set live L=2;L}\nValue:i64=1",
                "F(P:i64)<transacts>:i64=Block{set live P=1;P}\nValue:i64=1",
                "var S:i64=0\nlive X:i64=S\nF()<transacts>:i64=Block{set X=2;X}\nValue:i64=1",
                "Value:i64=Block{live L:i64=1;L}",
                "var X:i64=0\nF()<reads>:i64=Block{set live X=1;0}\nValue:i64=1",
                "var X:i64=0\nset live X=Print(\"x\")\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.5. Two or three service loops, each visit building and printing what a
        // frame made before the loop still holds, and sleeping: every visit saw a switch, so its
        // end reclaims with the suspended tasks' registers as roots. The schedule, written again
        // here: at tick 0 each task runs its first visit as it is spawned; at each later tick the
        // tasks still alive wake in the order they were spawned, and a task whose visits are done
        // prints its end.
        116 => {
            const tasks: usize = 2 + @as(usize, @intCast(draw(c, 2)));
            var visits: [3]i64 = undefined;
            for (visits[0..tasks]) |*count_of| count_of.* = 1 + draw(c, 4);
            try out.writeAll("Serve(N:i64,V:i64,Keep:[]i64)<transacts><suspends>:void=Block{Name:=\"t{N}\";var I:i64=0;Loop{If(I>=V,Break(),false);set I=I+1;J:=array{I,N};Print(\"{Name} {I} {Keep.Length+J.Length}\");Sleep(0.0)};Print(\"e{N}\")}\n");
            for (0..tasks) |task| {
                try out.print("T{d}:task(void)=Spawn{{Serve({d},{d},array{{", .{ task, task + 1, visits[task] });
                for (0..task + 1) |element| try out.print("{s}{d}", .{ if (element == 0) "" else ",", element });
                try out.writeAll("})}\n");
            }
            try out.print("Value:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            for (0..tasks) |task| model.line("t{d} 1 {d}", .{ task + 1, task + 3 });
            var tick: i64 = 1;
            while (tick <= 4) : (tick += 1) for (0..tasks) |task| {
                if (tick > visits[task]) continue;
                if (tick == visits[task]) model.line("e{d}", .{task + 1}) else model.line("t{d} {d} {d}", .{ task + 1, tick + 1, task + 3 });
            };
            return .{ .effects = model };
        },
        // A task whose visits each sleep a duration it works out: at the visit drawn, NaN, which
        // ends the run with the fatal error at the `Sleep`, after visits that reclaimed.
        117 => {
            const fatal = draw(c, 2) == 0;
            const visits = 2 + draw(c, 4);
            const at = 1 + draw(c, @intCast(visits));
            try out.print("Serve(V:i64,M:i64)<transacts><suspends>:i64=Block{{Kept:=array{{V,M}};var I:i64=0;Loop{{If(I>=V,Break(),false);set I=I+1;J:=array{{I,I}};S:=If(I==M,{s},0.0);Sleep(S)}};I+Kept.Length}}\nT:task(i64)=Spawn{{Serve({d},{d})}}\nValue:i64={d}", .{ if (fatal) "0.0/0.0" else "0.5/60.0", visits, at, offset });
            if (fatal) return .{ .failed = .invalid_sleep_duration };
            return .{ .value = offset };
        },
        // Two tasks hand built arrays back and forth through an event and a reply, in loops whose
        // visits each await: the values woken and the arrays held across every wait are roots.
        // The waiter ends first, after the last reply; the lengths both saw, written again here.
        118 => {
            const rounds = 1 + draw(c, 4);
            const width = 1 + draw(c, 3);
            try out.print("E:event([]i64)=event([]i64){{}}\nR:event(i64)=event(i64){{}}\nEar(N:i64)<transacts><suspends>:void=Block{{var I:i64=0;var Seen:i64=0;Loop{{If(I>=N,Break(),false);set I=I+1;Xs:=E.Await();Mine:=Xs+array{{I}};set Seen=Seen+Mine.Length;R.Signal(Mine.Length)}};Print(\"s{{Seen}}\")}}\nMouth(N:i64,W:i64)<transacts><suspends>:void=Block{{Head:=array{{W,W}};var I:i64=0;var Got:i64=0;Loop{{If(I>=N,Break(),false);set I=I+1;Xs:=For(K:1..W,K);E.Signal(Xs);set Got=Got+R.Await()}};Print(\"g{{Got+Head.Length}}\")}}\nA:task(void)=Spawn{{Ear({d})}}\nB:task(void)=Spawn{{Mouth({d},{d})}}\nValue:i64={d}", .{ rounds, rounds, width, offset });
            var model: Effects = .{ .value = offset };
            model.line("s{d}", .{rounds * (width + 1)});
            model.line("g{d}", .{rounds * (width + 1) + 2});
            return .{ .effects = model };
        },
        119 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:i64=Block{var N:i64=0;For(I:1..3){Sleep(0.0);set N=N+I};N}\nValue:i64=1",
                "F()<transacts><suspends>:void=Loop{Branch{Sleep(0.0)};Sleep(0.0)}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{N:i64=0;T:=Spawn{Loop{Sleep(0.0);set N=N+1}};N}\nValue:i64=1",
                "F()<transacts>:void=Loop{Sleep(0.0)}\nValue:i64=1",
                "Value:i64=Block{var I:i64=0;Loop{If(I>=3,Break(),false);set I=I+1;Sleep(0.0)};I}",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.2. Live fields declared in either order follow the field they read
        // and a module var, through writes in a function's frames.
        120 => {
            const base = draw(c, 20);
            const s = draw(c, 20);
            const calls = 1 + draw(c, 6);
            const forward = draw(c, 2) == 0;
            // Two fields that read each other and grow: the per-record bound stops the
            // construction that attaches them.
            if (draw(c, 4) == 0) {
                try out.print("ring:=class{{var live P:i64=Self.Q+{d};var live Q:i64=Self.P+1}}\nZ:ring=ring{{}}\nValue:i64=Z.P", .{1 + s});
                return .{ .failed = .live_unstable };
            }
            try out.print("var S:i64={d}\nmeter:=class{{var A:i64={d};", .{ s, base });
            if (forward) try out.writeAll("var live B:i64=Self.A+S;var live C:i64=Self.B*2}\n") else try out.writeAll("var live C:i64=Self.B*2;var live B:i64=Self.A+S}\n");
            try out.print("M:meter=meter{{}}\nBump(N:i64)<transacts>:i64=Block{{set M.A=M.A+N;M.C}}\nX:[]i64=For(K:1..{d},Bump(K))\nset S=S+1\nValue:i64=M.C*1000+X.Length", .{calls});
            const final_a = base + @divTrunc(calls * (calls + 1), 2);
            return .{ .value = 2 * (final_a + s + 1) * 1000 + calls };
        },
        // `set live` on a field inside a region: kept when the region commits, forgotten with
        // its record when it fails, so that a later write leaves the field alone.
        121 => {
            const start = draw(c, 30);
            const tried = draw(c, 7) - 3;
            const shift = draw(c, 9);
            const step = draw(c, 20);
            try out.print("box:=class{{var V:i64=0}}\nO:box=box{{}}\nvar S:i64={d}\nR:i64=Attempt(Block{{set S={d};set live O.V=S+{d};Require[S>0];1}},0)\nset S=S+{d}\nValue:i64=O.V*10+R", .{ start, tried, shift, step });
            const kept = tried > 0;
            const field = if (kept) tried + step + shift else 0;
            return .{ .value = field * 10 + @intFromBool(kept) };
        },
        // Each visit builds an instance whose live-only field reads only its own fields, and one
        // of a subclass whose field reads a module var too: a reclamation forgets the first
        // kind with its records, and keeps the second, which the later write evaluates.
        122 => {
            const s = draw(c, 20);
            const visits = 1 + draw(c, 12);
            try out.print("var S:i64={d}\nown:=class{{var A:i64=0;live B:i64=Self.A*3}}\nshared:=class(own){{var live C:i64=S+Self.B}}\nVisit(N:i64)<transacts>:i64=Block{{O:own=own{{A:=N}};P:shared=shared{{A:=N}};O.B+P.C}}\nX:[]i64=For(K:1..{d},Visit(K))\nset S=S+1\nLast:shared=shared{{A:=2}}\nValue:i64=Last.C*1000+X.Length", .{ s, visits });
            return .{ .value = (s + 1 + 6) * 1000 + visits };
        },
        123 => {
            try out.writeAll(choose(c, []const u8, &.{
                "tag:=class{live T:i64=1}\nO:tag=tag{}\nset O.T=2\nValue:i64=1",
                "box:=class{var V:i64=0;F:i64=0}\nO:box=box{}\nset live O.F=1\nValue:i64=1",
                "var S:i64=0\nm:=class{var live V:i64=S}\nF()<allocates>:m=m{}\nValue:i64=1",
                "box:=class{}\nB:box=box{}\nh:=class{var P:logic=false;var live K:box=If(Self.P,B,B)}\nValue:i64=1",
                "var S:i64=0\nm:=class{var live V:i64=S}\nX:m=m{V:=1}\nValue:i64=1",
                "box:=class{var V:i64=0}\nO:box=box{}\nF()<reads><writes>:i64=Block{set live O.V=1}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.3. A variable whose type is a function holds what is assigned and
        // follows the function of it: through a write of its raw value and of what the function
        // reads, at the root and in a function's frames, hidden or named `In->Out`.
        124 => {
            const m = 1 + draw(c, 9);
            const add = draw(c, 20);
            const raw = draw(c, 30);
            const calls = 1 + draw(c, 6);
            const named = draw(c, 2) == 0;
            try out.print("var M:i64={d}\nF(A:i64)<reads>:i64=A*M+{d}\n", .{ m, add });
            if (named) try out.print("var In->X:F={d}\n", .{raw}) else try out.print("var X:F={d}\n", .{raw});
            try out.print("Bump(N:i64)<transacts>:i64=Block{{set X+=N;X}}\nY:[]i64=For(K:1..{d},Bump(K))\nset M=M+1\nValue:i64=X*1000+Y.Length", .{calls});
            // `set X += N` reads X, the function of the raw value, and assigns X + N to the raw.
            var value = raw;
            for (1..@intCast(calls + 1)) |k| value = value * m + add + @as(i64, @intCast(k));
            return .{ .value = (value * (m + 1) + add) * 1000 + calls };
        },
        // A field whose type is a method of a module binding, clamped by it: each visit builds an
        // instance, and a write of the bound after the loop reaches the one kept.
        125 => {
            const high = 10 + draw(c, 40);
            const visits = 1 + draw(c, 10);
            const raw = draw(c, 100);
            const lowered = draw(c, 10);
            try out.print("clamp:=class{{var High:i64={d};Apply(V:i64)<reads>:i64=If(V>Self.High,Self.High,V)}}\nB:clamp=clamp{{}}\nunit:=class{{var Raw->Health:B.Apply={d}}}\nVisit(N:i64)<transacts>:i64=Block{{U:unit=unit{{}};set U.Health=N*7;U.Health}}\nX:[]i64=For(K:1..{d},Visit(K))\nKept:unit=unit{{}}\nset B.High={d}\nValue:i64=Kept.Health*1000+Kept.Raw*10+X.Length", .{ high, raw, visits, lowered });
            return .{ .value = @min(raw, lowered) * 1000 + raw * 10 + visits };
        },
        // A write inside a region that fails is undone with its propagation; a function that
        // reads the variable it is the type of never settles.
        126 => {
            if (draw(c, 3) == 0) {
                try out.print("var Y:i64=0\nF(A:i64)<reads>:i64=A+Y\nvar X:F={d}\nset live Y=X+1\nValue:i64=X", .{draw(c, 9)});
                return .{ .failed = .live_unstable };
            }
            const m = 1 + draw(c, 9);
            const raw = draw(c, 20);
            const tried = draw(c, 20);
            const keep = draw(c, 2) == 0;
            try out.print("var M:i64={d}\nF(A:i64)<reads>:i64=A*M\nvar X:F={d}\nR:i64=Attempt(Block{{set X={d};set M=M+1;Require[{d}>0];1}},0)\nValue:i64=X*10+R", .{ m, raw, tried, @intFromBool(keep) });
            if (keep) return .{ .value = tried * (m + 1) * 10 + 1 };
            return .{ .value = raw * m * 10 };
        },
        127 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var M:i64=1\nF(A:i64)<reads>:i64=A*M\nvar X:F(M)=1\nValue:i64=1",
                "var M:i64=1\nF(A:i64)<reads>:i64=A*M\nvar X:F\nValue:i64=1",
                "var M:i64=1\nF(A:i64)<transacts>:i64=Block{set M=A;A}\nvar X:F=1\nValue:i64=1",
                "var M:i64=1\nF(A:i64)<reads>:i64=A*M\nIn->Out:F=1\nset Out=2\nValue:i64=1",
                "var M:i64=1\nF(A:i64)<reads>:i64=A*M\nG()<transacts>:i64=Block{X:F=1;X}\nValue:i64=1",
                "var M:i64=1\nF(A:i64,B:i64)<reads>:i64=A*M\nvar X:F=1\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.6. A `Return` in an arm returns from the function: the other arm is
        // cancelled first and runs its `Defer`, then the function's runs. Without it the arm
        // completes and wins; the slow arm is cancelled either way.
        128 => {
            const k = 1 + draw(c, 9);
            const exits = draw(c, 2) == 0;
            try out.print("Slow()<transacts><suspends>:i64=Block{{Defer{{Print(\"slow\")}};Sleep(1.0);1}}\nF(K:i64,C:logic)<transacts><suspends>:i64=Block{{Defer{{Print(\"f\")}};R:=Race(Slow(),Block{{Sleep(0.5);If(C,Return(K*10),2)}});R+K}}\nT:task(void)=Spawn{{Print(\"v{{F({d},{s})}}\")}}\nValue:i64={d}", .{ k, word(exits), offset });
            var model: Effects = .{ .value = offset };
            model.line("slow", .{});
            model.line("f", .{});
            model.line("v{d}", .{if (exits) k * 10 else k + 2});
            return .{ .effects = model };
        },
        // The function's `Defer`, which the exit runs where the expression stands, ends the run
        // with `Err` when asked to.
        129 => {
            const fatal = draw(c, 2) == 0;
            try out.print("F(B:logic)<transacts><suspends>:i64=Block{{Defer{{X:=If(B,Err(\"boom\"),0)}};R:=Race(Block{{Sleep(1.0);1}},Block{{Sleep(0.1);Return(3)}});R}}\nT:task(i64)=Spawn{{F({s})}}\nValue:i64={d}", .{ word(fatal), offset });
            if (fatal) return .{ .failed = .runtime_error };
            return .{ .value = offset };
        },
        // A `Break` in an arm leaves the `Loop{}` around the `Race` at the visit drawn. The
        // schedule, written again here: each earlier visit's fast arm wins and the slow one is
        // cancelled, then the visit prints and its `Defer` runs; the last visit's `Break`
        // cancels the slow arm and runs the visit's `Defer`, and the loop is left.
        130 => {
            const last = 1 + draw(c, 4);
            try out.print("Count(M:i64)<transacts><suspends>:i64=Block{{var N:i64=0;Loop{{set N=N+1;Defer{{Print(\"d{{N}}\")}};R:=Race(Block{{Defer{{Print(\"s{{N}}\")}};Sleep(2.0);2}},Block{{Sleep(1.0);If(N==M,Break(),1)}});Print(\"r{{N}}\")}};N}}\nT:task(void)=Spawn{{Print(\"c{{Count({d})}}\")}}\nValue:i64={d}", .{ last, offset });
            var model: Effects = .{ .value = offset };
            var n: i64 = 1;
            while (n <= last) : (n += 1) {
                model.line("s{d}", .{n});
                if (n < last) model.line("r{d}", .{n});
                model.line("d{d}", .{n});
            }
            model.line("c{d}", .{last});
            return .{ .effects = model };
        },
        // ---- RFC-0082, P3.7. A task that sleeps, cancelled before or after it wakes, with a
        // task awaiting it. Asked first, it unwinds when it next runs and runs its `Defer`, and
        // its awaiter is cancelled in turn; asked after it completed, the request does nothing.
        140 => {
            const work = draw(c, 3);
            var ask = draw(c, 2);
            if (ask >= work) ask += 1;
            const seconds = [3][]const u8{ "0.5", "1.0", "1.5" };
            try out.print("Work()<transacts><suspends>:i64=Block{{Defer{{Print(\"w\")}};Sleep({s});Print(\"done\");{d}}}\nWait(T:task(i64))<transacts><suspends>:void=Block{{Defer{{Print(\"x\")}};Print(\"got {{T.Await()}}\")}}\nMain()<transacts><suspends>:void=Block{{T:=Spawn{{Work()}};W:=Spawn{{Wait(T)}};Sleep({s});T.Cancel();T.Cancel();Print(\"m\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ seconds[@intCast(work)], a, seconds[@intCast(ask)], offset });
            var model: Effects = .{ .value = offset };
            if (work < ask) {
                model.line("done", .{});
                model.line("w", .{});
                model.line("got {d}", .{a});
                model.line("x", .{});
                model.line("m", .{});
            } else {
                model.line("m", .{});
                model.line("w", .{});
                model.line("x", .{});
            }
            return .{ .effects = model };
        },
        // `NextTick()` is `Sleep(0.0)`: after `n` of them the clock reads `n / 60` seconds. A
        // cancelled task whose `Defer` calls `Err` ends the run as it unwinds.
        141 => {
            const ticks = 1 + draw(c, 6);
            const fatal = draw(c, 3) == 0;
            try out.print("Count(N:i64)<transacts><suspends>:void=Block{{var I:i64=0;While(I<N,Block{{NextTick();set I=I+1}});Print(If(GetSimulationElapsedTime()=={d}.0/60.0,\"t{{N}}\",\"bad\"))}}\nSlow(B:logic)<transacts><suspends>:void=Block{{Defer{{X:=If(B,Err(\"boom\"),0)}};Sleep(Inf)}}\nMain()<transacts><suspends>:void=Block{{S:=Spawn{{Slow({s})}};Count({d});S.Cancel();Print(\"z{{GetSimulationElapsedTime()>0.0}}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ ticks, word(fatal), ticks, offset });
            if (fatal) return .{ .failed = .runtime_error };
            var model: Effects = .{ .value = offset };
            model.line("t{d}", .{ticks});
            model.line("ztrue", .{});
            return .{ .effects = model };
        },
        // An arm awaits a task that is cancelled: the arm is cancelled from outside its `Sync`,
        // which cancels the task running the `Sync`: its other arm first, then its own `Defer`,
        // and the task awaiting it in turn. In its first run, the arm stops the start phase.
        142 => {
            const first_run = draw(c, 2) == 0;
            try out.print("W()<transacts><suspends>:i64=Block{{Sleep(1.0);3}}\nArm(T:task(i64))<transacts><suspends>:i64=Block{{Defer{{Print(\"arm\")}};T.Await()}}\nP(T:task(i64))<transacts><suspends>:i64=Block{{Defer{{Print(\"p\")}};R:=Sync(Arm(T),Block{{Defer{{Print(\"o{d}\")}};Sleep(5.0);1}});R(0)}}\nMain()<transacts><suspends>:void=Block{{T:=Spawn{{W()}};{s}U:=Spawn{{P(T)}};{s}Print(\"u{{U.Await()}}\")}}\nT:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ b, if (first_run) "T.Cancel();Sleep(0.0);" else "", if (first_run) "" else "T.Cancel();", offset });
            var model: Effects = .{ .value = offset };
            model.line("arm", .{});
            if (!first_run) model.line("o{d}", .{b});
            model.line("p", .{});
            return .{ .effects = model };
        },
        143 => {
            try out.writeAll(choose(c, []const u8, &.{
                "W()<transacts><suspends>:void=Sleep(1.0)\nF(T:task(void))<transacts>:void=T.Cancel()\nValue:i64=1",
                "F(T:task(void))<transacts><suspends>:i64=Attempt(Block{T.Cancel();1},0)\nValue:i64=1",
                "F(T:task(void))<reads><suspends>:void=T.Cancel()\nValue:i64=1",
                "X:void=NextTick()\nValue:i64=1",
                "F()<computes>:float=GetSimulationElapsedTime()\nValue:i64=1",
                "F(S:awaitable(i64))<transacts><suspends>:void=S.Signal(1)\nValue:i64=1",
                "E:event(i64)=event(i64){}\nF()<transacts><suspends>:void=E.Cancel()\nValue:i64=1",
                "E:event(i64)=event(i64){}\nS:awaitable(string)=E\nValue:i64=1",
                "F(N:i64)<transacts><suspends>:i64=Block{Defer{set N=1};Sleep(1.0);N}\nG(T:task(i64))<transacts><suspends>:void=T.Cancel()\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        131 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:i64=Race(Block{Sleep(1.0);T:=Spawn{Return(1)};1},2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Race(Block{Sleep(1.0);Branch{Return(1)};1},2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Race(Block{Defer{Return(1)};Sleep(1.0);1},2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Race(Block{Sleep(1.0);Break()},2)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Race(Block{Sleep(1.0);1+Return(1)},2)\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.4. A `When` runs at once and after every write of what its guard reads,
        // at the root and in a function's frames; a write in a region is delivered when it
        // commits, and one in a region that fails is not.
        132 => {
            const writes = 1 + draw(c, 8);
            const framed = draw(c, 2) == 0;
            try out.writeAll("var S:i64=0\nvar U:i64=0\nW:task(void)=When(S,Set(U,U+1))\nBump(K:i64)<transacts>:i64=Block{set S=K;K}\n");
            var count_written: i64 = 1;
            for (0..@intCast(writes)) |index| {
                const shape = draw(c, 3);
                switch (shape) {
                    0 => if (framed) try out.print("B{d}:i64=Bump({d})\n", .{ index, index }) else try out.print("set S={d}\n", .{index}),
                    1 => try out.print("R{d}:logic=Attempt(Block{{set S={d};true}},false)\n", .{ index, index }),
                    else => try out.print("R{d}:logic=Attempt(Block{{set S={d};Require[S<0];true}},false)\n", .{ index, index }),
                }
                if (shape != 2) count_written += 1;
            }
            try out.print("Value:i64=U+({d})", .{offset});
            return .{ .value = count_written + offset };
        },
        // An `Upon` fires once, when its guard first holds: at its creation, or at the first of
        // the writes after it that makes it hold. The DST works the value out from the writes.
        133 => {
            const threshold = draw(c, 10);
            var level = draw(c, 20);
            try out.print("var H:i64={d}\nvar F:i64=-1\nU:task(i64)=Upon(H<{d},Set(F,H))\n", .{ level, threshold });
            var fired: i64 = if (level < threshold) level else -1;
            const writes = 1 + draw(c, 8);
            for (0..@intCast(writes)) |_| {
                level = draw(c, 20);
                try out.print("set H={d}\n", .{level});
                if (fired < 0 and level < threshold) fired = level;
            }
            try out.print("Value:i64=F*1000+({d})", .{offset});
            return .{ .value = fired * 1000 + offset };
        },
        // Three `When`s over two cells, delivered in the order of their first trigger: a write
        // notifies the reactions that read the cell in the order they last registered, and each
        // registers again after its body. The order is worked out again here.
        134 => {
            try out.writeAll("var A:i64=0\nvar B:i64=0\nvar N:i64=0\nW1:task(void)=When(A,Set(N,N*4+1))\nW2:task(void)=When(B,Set(N,N*4+2))\nW3:task(void)=When(A+B,Set(N,N*4+3))\n");
            // Each reaction's registration time; W1 reads A, W2 reads B, W3 both.
            var time: [3]u64 = .{ 1, 2, 3 };
            var clock: u64 = 3;
            var n: i64 = 1 * 16 + 2 * 4 + 3;
            const writes = 1 + draw(c, 6);
            for (0..@intCast(writes)) |index| {
                const on_a = draw(c, 2) == 0;
                try out.print("set {s}={d}\n", .{ if (on_a) "A" else "B", index + 1 });
                // The reactions that read the cell, by registration time.
                var order: [3]usize = undefined;
                var count_notified: usize = 0;
                for (0..3) |reaction| {
                    const reads = if (on_a) reaction != 1 else reaction != 0;
                    if (!reads) continue;
                    order[count_notified] = reaction;
                    count_notified += 1;
                }
                std.mem.sort(usize, order[0..count_notified], &time, struct {
                    fn before(times: *[3]u64, left: usize, right: usize) bool {
                        return times[left] < times[right];
                    }
                }.before);
                for (order[0..count_notified]) |reaction| {
                    n = n * 4 + @as(i64, @intCast(reaction + 1));
                    clock += 1;
                    time[reaction] = clock;
                }
            }
            try out.print("Value:i64=N+({d})", .{offset});
            return .{ .value = n + offset };
        },
        // A body that ends the run ends it at its delivery; a pair of `When`s that write each
        // other's guards settles at its fixed point (Book 15:506). (`reaction_limit` comes
        // after more steps than a `full` run keeps: the machines' tests take it in an `off` run.)
        135 => {
            if (draw(c, 2) == 0) {
                try out.print("var X:i64=0\nW:task(void)=When(X>{d},Err(\"boom\"))\nset X=1\nset X={d}\nValue:i64=X", .{ draw(c, 3), 3 + draw(c, 5) });
                return .{ .failed = .runtime_error };
            }
            const start = 1 + draw(c, 9);
            try out.print("var X:i64={d}\nvar Y:i64={d}\nWY:task(void)=When(Y,Block{{Z:=If(Y<0,0,Y-1);If(Z!=X,Set(X,Z),X)}})\nWX:task(void)=When(X,Block{{Z:=If(X<0,0,X-1);If(Z!=Y,Set(Y,Z),Y)}})\nValue:i64=X*100+Y+({d})", .{ start, start, offset });
            // From X = Y = s: WY sets X = s - 1; WX sets Y = s - 2, which wakes WY: X = s - 3 ... down
            // to the first value below 1, where both stop: the values the Book's example reaches.
            var x = start;
            var y = start;
            var turn_y = true;
            while (true) {
                if (turn_y) {
                    const z = if (y < 0) 0 else y - 1;
                    if (z == x) break;
                    x = z;
                } else {
                    const z = if (x < 0) 0 else x - 1;
                    if (z == y) break;
                    y = z;
                }
                turn_y = !turn_y;
            }
            return .{ .value = x * 100 + y + offset };
        },
        // A reaction made in a region starts when the outermost region commits, in a function's
        // frame or at the root, and never when the region fails (R3).
        136 => {
            const fails = draw(c, 2) == 0;
            const k = 1 + draw(c, 9);
            const in_function = draw(c, 2) == 0;
            try out.writeAll("var X:i64=1\nvar N:i64=0\n");
            var text: [128]u8 = undefined;
            const region = try std.fmt.bufPrint(&text, "Attempt(Block{{U:task(i64)=Upon(X>0,Set(N,N+{d}));Require[{d}>0];true}},false)", .{ k, @intFromBool(!fails) });
            if (in_function) try out.print("F()<transacts>:logic={s}\nR:logic=F()\n", .{region}) else try out.print("R:logic={s}\n", .{region});
            try out.print("set X=2\nValue:i64=N+({d})", .{offset});
            return .{ .value = (if (fails) 0 else k) + offset };
        },
        // An `Upon`'s handle completes with its body's result, which a task awaiting it prints.
        137 => {
            const factor = 1 + draw(c, 9);
            const level = 1 + draw(c, 9);
            try out.print("var X:i64=0\nU:task(i64)=Upon(X>0,X*{d})\nT:task(void)=Spawn{{Print(\"g{{U.Await()}}\")}}\nset X={d}\nValue:i64={d}", .{ factor, level, offset });
            var model: Effects = .{ .value = offset };
            model.line("g{d}", .{factor * level});
            return .{ .effects = model };
        },
        // A body that runs on top of the frame of its delivery point writes what other
        // reactions read; those are delivered by the same loop, in order, after it returns.
        138 => {
            const k = 1 + draw(c, 5);
            try out.print("var X:i64=0\nvar Y:i64=0\nvar L:i64=0\nP:task(void)=When(X>0,Block{{set Y=X+{d};Set(L,L*10+1)}})\nQ:task(void)=When(Y>0,Set(L,L*10+2))\nWrite()<transacts>:i64=Block{{set X=1;L}}\nA:i64=Write()\nValue:i64=A*100+Y+({d})", .{ k, offset });
            return .{ .value = 12 * 100 + (1 + k) + offset };
        },
        139 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:void=Block{W:task(void)=When(1,Sleep(1.0))}\nValue:i64=1",
                "F()<transacts>:i64=Block{W:task(void)=When(1,Return(1));1}\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(Set(X,1),1)\nValue:i64=1",
                "F()<transacts>:i64=Block{var L:i64=0;W:task(void)=When(Set(L,1),1);1}\nValue:i64=1",
                "F()<reads>:task(void)=When(1,1)\nValue:i64=1",
                "W:task(void)=When(1)\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.5. A `When` that counts the writes of S, which come one by one, in
        // batches, in batches nested in batches and in a function's batch: a batch that writes S
        // notifies it once, when its outermost body ends, after the body has seen the count as
        // it was before (Book 15:552).
        144 => {
            try out.writeAll("var S:i64=0\nvar T:i64=0\nvar U:i64=0\nvar Last:i64=0\nW:task(void)=When(S,Set(U,U+1))\nF(K:i64)<transacts>:i64=Batch{set S=K;set T=K;set S=K+1;set Last=U;K}\n");
            var count_u: i64 = 1;
            var last: i64 = 0;
            const statements = 1 + draw(c, 6);
            for (0..@intCast(statements)) |index| {
                switch (draw(c, 4)) {
                    0 => {
                        try out.print("set S={d}\n", .{index});
                        count_u += 1;
                    },
                    1 => {
                        // Writes of S and of T, which nothing reads, in some order.
                        const writes = draw(c, 4);
                        var touches = false;
                        try out.print("B{d}:i64=Batch{{", .{index});
                        for (0..@intCast(writes)) |write| {
                            const on_s = draw(c, 2) == 0;
                            try out.print("set {s}={d};", .{ if (on_s) "S" else "T", write });
                            touches = touches or on_s;
                        }
                        try out.writeAll("set Last=U;U}\n");
                        last = count_u;
                        if (touches) count_u += 1;
                    },
                    2 => {
                        try out.print("B{d}:i64=Batch{{set S={d};C:=Batch{{set S={d};set Last=U;U}};set S={d};C}}\n", .{ index, index, index + 1, index + 2 });
                        last = count_u;
                        count_u += 1;
                    },
                    else => {
                        try out.print("B{d}:i64=F({d})\n", .{ index, index });
                        last = count_u;
                        count_u += 1;
                    },
                }
            }
            try out.print("Value:i64=U*1000+Last+({d})", .{offset});
            return .{ .value = count_u * 1000 + last + offset };
        },
        // A batch in a region, at the root or in a function's frame: its notification is
        // delivered when the region commits, and dropped with its write when it fails.
        145 => {
            try out.writeAll("var S:i64=0\nvar U:i64=0\nW:task(void)=When(S,Set(U,U+1))\n");
            var count_u: i64 = 1;
            var value_s: i64 = 0;
            const statements = 1 + draw(c, 5);
            for (0..@intCast(statements)) |index| {
                const commits = draw(c, 2) == 0;
                const v = 1 + draw(c, 9);
                var text: [160]u8 = undefined;
                const region = try std.fmt.bufPrint(&text, "Attempt(Block{{B:=Batch{{set S={d};0}};Require[{d}>0];true}},false)", .{ v, @intFromBool(commits) });
                if (draw(c, 2) == 0) try out.print("F{d}()<transacts>:logic={s}\nR{d}:logic=F{d}()\n", .{ index, region, index, index }) else try out.print("R{d}:logic={s}\n", .{ index, region });
                if (commits) {
                    count_u += 1;
                    value_s = v;
                }
            }
            try out.print("Value:i64=U*100+S+({d})", .{offset});
            return .{ .value = count_u * 100 + value_s + offset };
        },
        // A task handed off inside a batch runs under it until it first waits: its writes before
        // are delivered when the batch ends, those after when it runs again, at once. Or a body
        // that ends the run does so at the batch's end, its delivery point.
        146 => {
            if (draw(c, 2) == 0) {
                const k = draw(c, 5);
                try out.print("var X:i64=0\nW:task(void)=When(X>{d},Err(\"boom\"))\nB:i64=Batch{{set X={d};set X={d};0}}\nValue:i64=X", .{ k, k + 1, k + 2 });
                return .{ .failed = .runtime_error };
            }
            const before = draw(c, 3);
            try out.writeAll("var X:i64=0\nW:task(void)=When(X,Print(\"w{X}\"))\nWorker()<transacts><suspends>:void=Block{");
            for (0..@intCast(before)) |_| try out.writeAll("set X=X+1;");
            try out.print("Print(\"t\");Sleep(0.0);set X=X+1;Print(\"u\")}}\nB:i64=Batch{{T:task(void)=Spawn{{Worker()}};Print(\"b\");0}}\nValue:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            model.line("w0", .{});
            model.line("t", .{});
            model.line("b", .{});
            if (before != 0) model.line("w{d}", .{before});
            model.line("w{d}", .{before + 1});
            model.line("u", .{});
            return .{ .effects = model };
        },
        147 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:void=Block{B:i64=Batch{Sleep(1.0);1}}\nValue:i64=1",
                "F()<transacts>:i64=Batch{Return(1)}\nValue:i64=1",
                "F()<transacts>:i64=Block{L:i64=0;B:i64=Batch{set L=1;1};L}\nValue:i64=1",
                "B:i64=Batch(1)\nValue:i64=1",
                "var A:[]i64=array{1}\nB:i64=Batch{A[0]}\nValue:i64=1",
                "var X:i64=0\nF()<computes>:i64=Batch{set X=1;1}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.6. A task waits at an `Await` until its guard holds. Each write of
        // what the guard read wakes it to the ready queue, and it evaluates the guard again when
        // it runs: after the writer's next wait. So it goes on with the first value written,
        // at a tick of its own, that passes its threshold; a write in a region that fails wakes
        // nothing; two writes at the root before it runs leave it the second. The DST works the
        // printed lines out from the writes.
        148 => {
            const threshold = draw(c, 10);
            const fatal = draw(c, 6) == 0;
            const root_first = draw(c, 10);
            const root_second = draw(c, 10);
            try out.print("var X:i64=0\nW()<transacts><suspends>:void=Block{{Defer{{Print(\"d\")}};V:=Await(Block{{Require[X>{d}];X}});{s}Print(\"got {{V}}\")}}\nT:task(void)=Spawn{{W()}}\nset X={d}\nset X={d}\nWriter()<transacts><suspends>:void=Block{{Sleep(0.0);", .{ threshold, if (fatal) "Q:=If(V>0,Err(\"late\"),0);" else "", root_first, root_second });
            var model: Effects = .{ .value = offset };
            // The root's writes woke it; it runs before the writer starts, on the second value.
            var done = root_second > threshold;
            // A value that passes is positive: the fatal variant ends the run there.
            var ended = false;
            if (done) {
                ended = fatal;
                model.line("got {d}", .{root_second});
                model.line("d", .{});
            }
            const writes = 1 + draw(c, 6);
            for (0..@intCast(writes)) |index| {
                const value = draw(c, 12);
                const failing = draw(c, 4) == 0;
                if (failing) {
                    try out.print("F{d}:=Attempt(Block{{set X={d};Require[X<0];true}},false);Sleep(0.0);", .{ index, value });
                    continue;
                }
                try out.print("set X={d};Sleep(0.0);", .{value});
                if (done or value <= threshold) continue;
                done = true;
                ended = fatal;
                model.line("got {d}", .{value});
                model.line("d", .{});
            }
            try out.print("Print(\"w\")}}\nK:task(void)=Spawn{{Writer()}}\nValue:i64={d}", .{offset});
            if (ended) return .{ .failed = .runtime_error };
            model.line("w", .{});
            return .{ .effects = model };
        },
        // A task waiting at an `Await` is cancelled by another: it unwinds at its site and runs
        // its `Defer`. Woken first by a write that makes its guard hold, it completes, and the
        // request finds it settled.
        149 => {
            const kill = draw(c, 3);
            var write = draw(c, 2);
            if (write >= kill) write += 1;
            const seconds = [3][]const u8{ "0.5", "1.0", "1.5" };
            const level = 1 + draw(c, 9);
            try out.print("var X:i64=0\nW()<transacts><suspends>:void=Block{{Defer{{Print(\"d\")}};Await(X>0);Print(\"got {{X}}\")}}\nT:task(void)=Spawn{{W()}}\nKiller()<transacts><suspends>:void=Block{{Sleep({s});T.Cancel();Print(\"k\")}}\nWriter()<transacts><suspends>:void=Block{{Sleep({s});set X={d};Print(\"x\")}}\nA:task(void)=Spawn{{Killer()}}\nB:task(void)=Spawn{{Writer()}}\nValue:i64={d}", .{ seconds[@intCast(kill)], seconds[@intCast(write)], level, offset });
            var model: Effects = .{ .value = offset };
            if (write < kill) {
                model.line("x", .{});
                model.line("got {d}", .{level});
                model.line("d", .{});
                model.line("k", .{});
            } else {
                model.line("k", .{});
                model.line("d", .{});
                model.line("x", .{});
            }
            return .{ .effects = model };
        },
        // Several tasks wait on one cell, each until it passes a threshold of its own; one write
        // wakes them all, in the order they registered, and those whose guard fails register
        // again in that order. The DST keeps the order itself.
        150 => {
            const tasks: usize = @intCast(2 + draw(c, 4));
            var thresholds: [6]i64 = undefined;
            try out.writeAll("var X:i64=0\nW(K:i64,L:i64)<transacts><suspends>:void=Block{Await(X>L);Print(\"a{K}\")}\n");
            for (0..tasks) |index| {
                thresholds[index] = draw(c, 8);
                try out.print("T{d}:task(void)=Spawn{{W({d},{d})}}\n", .{ index, index, thresholds[index] });
            }
            try out.writeAll("Writer()<transacts><suspends>:void=Block{");
            var waiting: [6]bool = .{ true, true, true, true, true, true };
            var model: Effects = .{ .value = offset };
            const writes = 1 + draw(c, 5);
            for (0..@intCast(writes)) |_| {
                const value = draw(c, 9);
                try out.print("set X={d};Sleep(0.0);", .{value});
                for (0..tasks) |index| {
                    if (!waiting[index] or value <= thresholds[index]) continue;
                    waiting[index] = false;
                    model.line("a{d}", .{index});
                }
            }
            try out.print("Print(\"w\")}}\nK:task(void)=Spawn{{Writer()}}\nValue:i64={d}", .{offset});
            model.line("w", .{});
            return .{ .effects = model };
        },
        151 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var X:i64=0\nV:logic=Await(X>0)\nValue:i64=1",
                "var X:i64=0\nF()<transacts>:logic=Await(X>0)\nValue:i64=1",
                "var X:i64=0\nF()<transacts><suspends>:logic=Attempt(Await(X>0),false)\nValue:i64=1",
                "var X:i64=0\nF()<transacts><suspends>:logic=Await(Set(X,1)>0)\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{var L:i64=0;Await(Set(L,1)>0);1}\nValue:i64=1",
                "var X:i64=0\nF()<transacts><suspends>:logic=Await(X>0,X>1)\nValue:i64=1",
                "var X:i64=0\nF()<transacts><suspends>:i64=Block{W:task(void)=When(X,Await(X>0));1}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.9. A sticky event keeps the value signalled last: a task that waits
        // on it before any `Signal` is woken by the first one that commits, and every `Await`
        // after a `Signal` gets that value at once, without suspending. A `Signal` in a region
        // that fails is dropped with its latch.
        152 => {
            try out.writeAll("S:sticky_event(i64)=sticky_event(i64){}\nW()<transacts><suspends>:void=Block{V:=S.Await();Print(\"w {V}\")}\nT:task(void)=Spawn{W()}\n");
            var model: Effects = .{ .value = offset };
            var first_value: ?i64 = null;
            const roots: usize = @intCast(draw(c, 3));
            for (0..roots) |index| {
                const value = draw(c, 50);
                const keep = draw(c, 2) == 0;
                try out.print("R{d}:i64=Attempt(Block{{S.Signal({d});Require[{s}];1}},0)\n", .{ index, value, word(keep) });
                if (keep and first_value == null) first_value = value;
            }
            try out.writeAll("M()<transacts><suspends>:void=Block{");
            const signals: usize = @intCast(1 + draw(c, 4));
            for (0..signals) |_| {
                const value = draw(c, 50);
                const awaits: usize = @intCast(1 + draw(c, 2));
                try out.print("S.Signal({d});", .{value});
                if (first_value == null) first_value = value;
                for (0..awaits) |_| {
                    try out.writeAll("Print(\"m {S.Await()}\");");
                    model.line("m {d}", .{value});
                }
            }
            try out.print("Print(\"e\")}}\nN:task(void)=Spawn{{M()}}\nValue:i64={d}", .{offset});
            model.line("e", .{});
            model.line("w {d}", .{first_value.?});
            return .{ .effects = model };
        },
        // Subscriptions of a subscribable event, made and cancelled at the root, in regions
        // that commit or fail: each `Signal` calls, in order, the subscriptions active when it
        // begins, and one that the second callback cancels before its turn is not called. The
        // DST keeps its own list.
        153 => {
            try out.writeAll("E:subscribable_event(i64)=subscribable_event(i64){}\nvar H:[]cancelable=array{}\nStop(I:i64)<transacts>:void=Block{Y:=Attempt(Block{C:=H[I];C.Cancel();1},0);void(Y)}\nA(N:i64)<transacts>:void=Print(\"a {N}\")\n");
            const victim = draw(c, 4);
            try out.print("B(N:i64)<transacts>:void=Block{{Stop({d});Print(\"b {{N}}\")}}\n", .{victim});
            var callbacks: [8]u8 = undefined;
            var active: [8]bool = undefined;
            var made: usize = 0;
            var model: Effects = .{ .value = offset };
            const steps: usize = @intCast(3 + draw(c, 5));
            for (0..steps) |index| {
                const pick = draw(c, 4);
                const keep = draw(c, 3) != 0;
                if (pick <= 1 and made < callbacks.len) {
                    // A subscription, which a region that fails takes back.
                    const callback: u8 = if (draw(c, 2) == 0) 'A' else 'B';
                    try out.print("P{d}:i64=Attempt(Block{{Set(H,H+array{{E.Subscribe({c})}});Require[{s}];1}},0)\n", .{ index, callback, word(keep) });
                    if (keep) {
                        callbacks[made] = callback;
                        active[made] = true;
                        made += 1;
                    }
                } else if (pick == 2) {
                    const handle: usize = @intCast(draw(c, 4));
                    try out.print("P{d}:i64=Attempt(Block{{Stop({d});Require[{s}];1}},0)\n", .{ index, handle, word(keep) });
                    if (keep and handle < made) active[handle] = false;
                } else {
                    const value = draw(c, 10);
                    try out.print("P{d}:void=E.Signal({d})\n", .{ index, value });
                    const limit = made;
                    for (0..limit) |at| {
                        if (!active[at]) continue;
                        if (callbacks[at] == 'B' and victim < made) active[@intCast(victim)] = false;
                        model.line("{c} {d}", .{ callbacks[at] + ('a' - 'A'), value });
                    }
                }
            }
            try out.print("Value:i64={d}", .{offset});
            return .{ .effects = model };
        },
        // A callback that ends the run with `Err` does so inside the `Signal` that calls it:
        // the lines of the callbacks before it stay, nothing after it runs.
        154 => {
            const limit = draw(c, 10);
            try out.print("E:subscribable_event(i64)=subscribable_event(i64){{}}\nA(N:i64)<transacts>:void=Print(\"a {{N}}\")\nB(N:i64)<transacts>:void=Block{{Q:=If(N>{d},Err(\"big\"),0);Print(\"b {{N}}\")}}\nX:cancelable=E.Subscribe(A)\nY:cancelable=E.Subscribe(B)\n", .{limit});
            var model: Effects = .{ .value = offset };
            const signals: usize = @intCast(1 + draw(c, 4));
            var ended = false;
            for (0..signals) |index| {
                const value = draw(c, 12);
                try out.print("S{d}:void=E.Signal({d})\n", .{ index, value });
                if (ended) continue;
                model.line("a {d}", .{value});
                if (value > limit) {
                    ended = true;
                    continue;
                }
                model.line("b {d}", .{value});
            }
            try out.print("Value:i64={d}", .{offset});
            if (ended) return .{ .failed = .runtime_error };
            return .{ .effects = model };
        },
        155 => {
            try out.writeAll(choose(c, []const u8, &.{
                "E:subscribable_event(i64)=subscribable_event(i64){}\nF(N:i64)<writes>:void=E.Signal(N)\nValue:i64=1",
                "E:subscribable_event(i64)=subscribable_event(i64){}\nF(N:i64)<transacts><suspends>:void=Sleep(1.0)\nC:cancelable=E.Subscribe(F)\nValue:i64=1",
                "E:subscribable_event(i64)=subscribable_event(i64){}\nF(N:i64)<transacts>:i64=N\nC:cancelable=E.Subscribe(F)\nValue:i64=1",
                "S:sticky_event(i64)=sticky_event(i64){1}\nValue:i64=1",
                "S:sticky_event(i64)=sticky_event(i64){}\nF()<transacts>:i64=S.Await()\nValue:i64=1",
                "E:event(i64)=event(i64){}\nF(N:i64)<transacts>:void=void(N)\nC:cancelable=E.Subscribe(F)\nValue:i64=1",
                "E:subscribable_event(i64)=subscribable_event(i64){}\nW:signalable(i64)=E\nValue:i64=1",
                "E:subscribable_event(i64)=subscribable_event(i64){}\nF(N:i64)<transacts>:void=void(N)\nC:cancelable=E.Subscribe(F)\nB:logic=C==C\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0084, P4.7. A reaction waiting on its guard is cancelled by another task: it
        // settles at once and never runs again. Before the cancel a `When` runs at each write
        // that makes its guard hold, an `Upon` at the first; the DST orders the writes, the
        // cancel and the writer's end by their ticks. In the fatal variant a run of the body
        // past a bound ends the run.
        156 => {
            const upon = draw(c, 2) == 0;
            const threshold = draw(c, 5);
            const writes: usize = @intCast(1 + draw(c, 5));
            const kill = draw(c, 6);
            const fatal = draw(c, 5) == 0;
            try out.print("var X:i64=0\nNote(V:i64)<transacts>:void=Block{{{s}Print(\"w{{V}}\")}}\nW:task(void)={s}(X>{d},Note(X))\nKiller()<transacts><suspends>:void=Block{{Sleep({d}.5);W.Cancel();Print(\"k\")}}\nWriter()<transacts><suspends>:void=Block{{", .{ if (fatal) "Q:=If(V>5,Err(\"late\"),0);" else "", if (upon) "Upon" else "When", threshold, kill });
            var model: Effects = .{ .value = offset };
            var fired = false;
            var ended = false;
            var killed = false;
            for (0..writes) |index| {
                const value = draw(c, 9);
                try out.print("Sleep(1.0);set X={d};", .{value});
                // The write at second `index + 1` comes before the cancel at `kill + 0.5`
                // exactly when `index + 1 <= kill`.
                if (!killed and @as(i64, @intCast(index)) + 1 > kill) {
                    killed = true;
                    model.line("k", .{});
                }
                if (ended or killed or value <= threshold or (upon and fired)) continue;
                fired = true;
                if (fatal and value > 5) {
                    ended = true;
                    continue;
                }
                model.line("w{d}", .{value});
            }
            try out.print("Print(\"x\")}}\nA:task(void)=Spawn{{Killer()}}\nB:task(void)=Spawn{{Writer()}}\nValue:i64={d}", .{offset});
            if (ended) return .{ .failed = .runtime_error };
            model.line("x", .{});
            if (!killed) model.line("k", .{});
            return .{ .effects = model };
        },
        // A firing `When` (or `Upon`) is cancelled by a task its body hands off to, at the write
        // of a chosen value: the body goes on to its end, a `When` then settles cancelled and runs
        // at no later write, and an `Upon` completes. A task awaiting the reaction is cancelled
        // with a `When` (its `Defer` prints) and gets the `Upon`'s value, after the root.
        157 => {
            const upon = draw(c, 2) == 0;
            const at = 1 + draw(c, 4);
            try out.print("var X:i64=0\nvar H:[]task(void)=array{{}}\nStopper()<transacts><suspends>:void=Block{{If(T:=H[0],T.Cancel(),void(0));Print(\"c\")}}\nStop()<transacts>:i64=Block{{T:task(void)=Spawn{{Stopper()}};0}}\nW:task(void)={s}(X>0,Block{{Print(\"w{{X}}\");Z:=If(X=={d},Stop(),0);Print(\"e\")}})\nset H=array{{W}}\nWait()<transacts><suspends>:void=Block{{Defer{{Print(\"d\")}};W.Await();Print(\"a\")}}\nA:task(void)=Spawn{{Wait()}}\n", .{ if (upon) "Upon" else "When", at });
            var model: Effects = .{ .value = offset };
            var canceled = false;
            var fired = false;
            const writes: usize = @intCast(1 + draw(c, 5));
            for (0..writes) |_| {
                const value = draw(c, 5);
                try out.print("set X={d}\n", .{value});
                if (canceled or value <= 0 or (upon and fired)) continue;
                fired = true;
                model.line("w{d}", .{value});
                if (value == at) {
                    canceled = true;
                    model.line("c", .{});
                }
                model.line("e", .{});
            }
            try out.print("Value:i64={d}", .{offset});
            // The awaiter runs once the root has ended: woken by an `Upon` that completed, or
            // asked by the cancel of a `When`.
            if (upon and fired) {
                model.line("a", .{});
                model.line("d", .{});
            } else if (!upon and canceled) model.line("d", .{});
            return .{ .effects = model };
        },
        // An `Upon` made in a region that commits is cancelled, before its start's turn, by a
        // task started earlier in the same drain: it never evaluates its guard. Not cancelled it
        // starts in its turn, fires if its guard holds, and else at the root's write that makes it
        // hold. A region that fails starts neither.
        158 => {
            const cancel = draw(c, 2) == 0;
            const fail = draw(c, 4) == 0;
            const threshold = draw(c, 4);
            const initial = draw(c, 4);
            const second = draw(c, 4);
            try out.print("var X:i64={d}\nvar H:[]task(void)=array{{}}\nFirst()<transacts><suspends>:void=Block{{Print(\"f\");{s}Print(\"g\")}}\nMain()<transacts><suspends>:void=Block{{R:=Attempt(Block{{A:=Spawn{{First()}};U:=Upon(X>={d},Print(\"u\"));set H=array{{U}};{s}true}},false);Print(\"m\")}}\nM:task(void)=Spawn{{Main()}}\nset X={d}\nValue:i64={d}", .{ initial, if (cancel) "If(T:=H[0],T.Cancel(),void(0));" else "", threshold, if (fail) "Require[false];" else "", second, offset });
            var model: Effects = .{ .value = offset };
            var waiting = false;
            if (!fail) {
                model.line("f", .{});
                model.line("g", .{});
                if (!cancel) {
                    if (initial >= threshold) model.line("u", .{}) else waiting = true;
                }
            }
            model.line("m", .{});
            if (waiting and second >= threshold) model.line("u", .{});
            return .{ .effects = model };
        },
        159 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var X:i64=0\nW:task(void)=When(X>0,1)\nU:task(i64)=Upon(Block{W.Cancel();X>0},1)\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(X>0,1)\nU:task(void)=When(X>1,W.Cancel())\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(X>0,1)\nF()<transacts>:void=W.Cancel()\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(X>0,1)\nF()<transacts><suspends>:logic=Attempt(Block{W.Cancel();true},false)\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(X>0,1)\nF()<transacts><suspends>:i64=Batch{W.Cancel();1}\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(X>0,1)\nF()<reads><suspends>:void=W.Cancel()\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- Rooms (RFC-0055): a `For` long enough to grow its result into the room its copies
        // leave, two joins of that one result (the first fills the room, the second copies), and
        // a general `For` whose inner loops grow their own results between the outer appends.
        160 => {
            const n = 4 + draw(c, 40);
            const k = draw(c, 7) - 3;
            const first_tail = draw(c, 50);
            const second_tail = draw(c, 50) - 25;
            const outer = 1 + draw(c, 12);
            const inner = 1 + draw(c, 12);
            const pick = draw(c, 14);
            try out.print("Sum:=native{{\"std.sum\"}}\nXs:[]i64=For(I:1..{d},I*{d})\nYs:[]i64=Xs+array{{{d}}}\nZs:[]i64=Xs+array{{{d}}}\nPs:[]i64=For(I:1..{d},J:1..{d},(I>J) or (I=={d}),I*100+J)\nValue:i64=Sum(Ys)+Sum(Zs)*3+Ps.Length*7+Sum(Ps)+Attempt(Ys[{d}],0)*11+Attempt(Zs[{d}],0)*13+Xs.Length*17", .{ n, k, first_tail, second_tail, outer, inner, pick, n, n });
            const xs = k * @divExact(n * (n + 1), 2);
            var kept: i64 = 0;
            var sum: i64 = 0;
            var i: i64 = 1;
            while (i <= outer) : (i += 1) {
                var j: i64 = 1;
                while (j <= inner) : (j += 1) if (i > j or i == pick) {
                    kept += 1;
                    sum += i * 100 + j;
                };
            }
            return .{ .value = (xs + first_tail) + (xs + second_tail) * 3 + kept * 7 + sum + first_tail * 11 + second_tail * 13 + n * 17 };
        },
        // A binding over the grown result divides by zero at the element its room took (the run
        // ends there), or does not when that element is not the pole.
        161 => {
            const n = 4 + draw(c, 40);
            const tail = draw(c, 3);
            const pole = n + 1 - draw(c, 2) * (1 + draw(c, @intCast(n)));
            try out.print("Sum:=native{{\"std.sum\"}}\nXs:[]i64=For(K:1..{d},K)\nYs:[]i64=Xs+array{{{d}}}\nValue:i64=Sum(For(Y:Ys,Z:=1000/(Y-{d}),Z))", .{ n, n + 1 - tail, pole });
            var sum: i64 = 0;
            var k: i64 = 1;
            while (k <= n + 1) : (k += 1) {
                const y = if (k <= n) k else n + 1 - tail;
                if (y == pole) return .{ .failed = .division_by_zero };
                sum += @divTrunc(1000, y - pole);
            }
            return .{ .value = sum };
        },
        // A grown result joined with an array of another element type is refused.
        162 => {
            const n = 4 + draw(c, 40);
            try out.print("Xs:[]i64=For(K:1..{d},K)\nYs:[]i64=Xs+array{{\"a\"}}\nValue:i64=Ys.Length", .{n});
            return .syntax_failure;
        },
        // ---- RFC-0085, I7. Transparent functions: the result type of each is its body's, a
        // tuple, an array of a loop, an integer; a division by zero in one ends the run.
        163 => {
            const k = draw(c, 9);
            const n = draw(c, 4);
            const xs = [_]i64{ draw(c, 7), draw(c, 7) };
            try out.print("Next(X:i64)<computes> := X + {d}\nDiv(X:i64, Y:i64)<computes> := X / Y\nPair(X:i64)<computes> := tuple{{Next(X), Div(60, X)}}\nAll(Xs:[]i64)<computes> := For(X:Xs, Next(X) * 2)\nP:tuple(i64, i64) = Pair({d})\nQ:[]i64 = All(array{{{d}, {d}}})\nValue:i64 = P(0) * 1000 + P(1) * 10 + Attempt(Q[0], 0) * 100000 + Attempt(Q[1], 0)", .{ k, n, xs[0], xs[1] });
            if (n == 0) return .{ .failed = .division_by_zero };
            return .{ .value = (n + k) * 1000 + @divTrunc(60, n) * 10 + (xs[0] + k) * 2 * 100000 + (xs[1] + k) * 2 };
        },
        164 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Count(N:i64)<computes> := If(N > 0, Count(N - 1) + 1, 0)\nValue:i64 = Count(2)",
                "F(X:i64)<computes> := If(X > 0, Return(1), 2)\nValue:i64 = F(1)",
                "c := class{ M()<computes> := 1 }\nValue:i64 = 1",
                "Id[T:type](X:T)<computes> := X\nValue:i64 = 1",
                "F(X:i64) := X + 1\nValue:i64 = F(1)",
                "var V:i64 = 0\nF()<computes> := V\nValue:i64 = F()",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0085, I10. An enumerator qualified by its enum, of a name the module also
        // declares and of a reserved word, named qualified and unqualified alike.
        165 => {
            const n = draw(c, 3);
            const m = draw(c, 4);
            try out.print("Start:i64 = {d}\ne := enum{{ (e:)Start, (e:)set, Other }}\nPick(N:i64)<computes>:e = If(N > 1, (e:)set, If(N > 0, e.Start, (e:)Other))\nCode(V:e)<computes>:i64 = Case(V, (e:)Start => 1, e.set => 2, _ => 3)\nValue:i64 = Code(Pick({d})) * 1000 + Start + 60 / {d}", .{ a, n, m });
            if (m == 0) return .{ .failed = .division_by_zero };
            const code: i64 = if (n > 1) 2 else if (n > 0) 1 else 3;
            return .{ .value = code * 1000 + a + @divTrunc(60, m) };
        },
        166 => {
            try out.writeAll(choose(c, []const u8, &.{
                "other := enum{ A }\ne := enum{ (other:)B }\nValue:i64 = 1",
                "e := enum{ A }\nX:e = (e:)B\nValue:i64 = 1",
                "e := enum{ A }\nX:e = (f:)A\nValue:i64 = 1",
                "X:i64 = (M:)set\nValue:i64 = 1",
                "e := enum{ (local:)A }\nValue:i64 = 1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0085, I12. Predicting functions that call predicting ones, through a loop and
        // a value of a dictating type: the run is the run without the specifier.
        167 => {
            const n = draw(c, 4);
            const k = draw(c, 9);
            try out.print("Half(X:i64)<computes><predicts>:i64 = 60 / X\nTwice(X:i64)<computes><predicts>:i64 = X * 2\nRun(Xs:[]i64)<computes><predicts>:[]i64 = For(X:Xs, Twice(Half(X)))\nF:function<computes>(tuple(i64), i64) = Twice\nR:[]i64 = Run(array{{{d}}})\nValue:i64 = Attempt(R[0], 0) * 100 + F({d})", .{ n, k });
            if (n == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(60, n) * 2 * 100 + k * 2 };
        },
        168 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Plain(X:i64)<computes>:i64 = X\nP(X:i64)<computes><predicts>:i64 = Plain(X)\nValue:i64 = P(1)",
                "P()<transacts><predicts>:i64 = GetRandomInt(1, 6)\nValue:i64 = 1",
                "var X:i64 = 0\nP()<transacts><predicts>:i64 = Batch{ set X = 1; 2 }\nValue:i64 = 1",
                "var X:i64 = 0\nP()<transacts><predicts>:i64 = Block{ set live X = 1; 0 }\nValue:i64 = 1",
                "c := class{ M()<computes><predicts>:i64 = 1 }\nd := class(c){ M<override>()<computes>:i64 = 2 }\nValue:i64 = 1",
                "Plain(X:i64)<computes>:i64 = X\nF:function<computes><predicts>(tuple(i64), i64) = Plain\nValue:i64 = 1",
                "P()<predicts>:i64 = 1\nValue:i64 = 1",
            }));
            return .syntax_failure;
        },
        // ---- Inputs (RFC-0086, P2.2): the wall clock. Tasks that wake at seconds of their own
        // read it twice each, once inside a region that fails; tasks at one tick share a
        // reading, a later tick takes a new one, and a world that goes back is held.
        169 => {
            const tasks: usize = @intCast(1 + draw(c, 4));
            var waits: [4]u64 = undefined;
            try out.writeAll("Note(N:string)<transacts>:void=Print(\"{N} {GetSecondsSinceEpoch()}\")\nLater(N:string,W:float)<transacts><suspends>:void=Block{Sleep(W);Note(N);X:=Attempt(Block{Y:=GetSecondsSinceEpoch();Require[Y<0.0];Y},GetSecondsSinceEpoch());Print(\"{N} again {X}\")}\n");
            for (waits[0..tasks], 0..) |*wait, index| {
                wait.* = @intCast(1 + draw(c, 4));
                try out.print("T{d}:task(void)=Spawn{{Later(\"t{d}\",{d}.0)}}\n", .{ index, index, wait.* });
            }
            try out.print("R:tuple()=Note(\"r\")\nValue:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            var clock: SeenClock = .{};
            model.line("r {d}", .{clock.at(0)});
            // Timers that fall due at one tick wake in the order they were set.
            for (1..5) |second| for (waits[0..tasks], 0..) |wait, index| {
                if (wait != second) continue;
                const seen = clock.at(second * 60);
                model.line("t{d} {d}", .{ index, seen });
                model.line("t{d} again {d}", .{ index, seen });
            };
            model.inputs = clock.entries;
            return .{ .effects = model };
        },
        // A world that gives no number ends the run where it is read; what was committed before
        // it stays.
        170 => {
            const bad = draw(c, 2) == 0;
            const wait: u64 = if (bad) 7 else @intCast(5 + draw(c, 2) * 3);
            try out.print("A:tuple()=Print(\"a {{GetSecondsSinceEpoch()}}\")\nLater()<transacts><suspends>:void=Block{{Sleep({d}.0);Print(\"b {{GetSecondsSinceEpoch()}}\")}}\nT:task(void)=Spawn{{Later()}}\nValue:i64={d}", .{ wait, offset });
            if (bad) return .{ .failed = .input_invalid };
            var model: Effects = .{ .value = offset };
            var clock: SeenClock = .{};
            model.line("a {d}", .{clock.at(0)});
            model.line("b {d}", .{clock.at(wait * 60)});
            model.inputs = clock.entries;
            return .{ .effects = model };
        },
        // What the clock needs and where it may not stand.
        171 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<reads>:float=GetSecondsSinceEpoch()\nValue:i64=1",
                "F()<computes>:float=GetSecondsSinceEpoch()\nValue:i64=1",
                "F()<reads><writes>:float=GetSecondsSinceEpoch()\nValue:i64=1",
                "var X:float=0.0\nW:task(void)=When(X<GetSecondsSinceEpoch(),Print(\"late\"))\nValue:i64=1",
                "var X:float=0.0\nU:task(void)=Upon(GetSecondsSinceEpoch()>X,Print(\"late\"))\nValue:i64=1",
                "A:float=GetSecondsSinceEpoch(1.0)\nValue:i64=1",
                "A:i64=GetSecondsSinceEpoch()\nValue:i64=1",
                "Now:=native{\"std.clock_seconds\"}\nF()<reads>:float=Now()\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // The name yields to the program's own declaration of it; the standard clock read in a
        // region that fails keeps its reading for the rest of the tick.
        172 => {
            const own = draw(c, 2) == 0;
            const constant = draw(c, 100);
            if (own) try out.print("GetSecondsSinceEpoch()<computes>:float={d}.0\n", .{constant});
            const expected: i64 = if (own) constant else 1000;
            try out.print("Z:float=Attempt(Block{{Y:=GetSecondsSinceEpoch();Require[Y<0.0];Y}},0.0)\nValue:i64=If(GetSecondsSinceEpoch()=={d}.0,{d},{d})", .{ expected, offset, offset + 1 });
            return .{ .value = offset };
        },
        // ---- RFC-0085, I8. Fields with accessors: `set` calls the setter, which may refuse a
        // value, a compound `set` reads through the getter once, and the field has no cell.
        173 => {
            const start = draw(c, 50);
            const values = [_]i64{ draw(c, 201) - 50, draw(c, 201) - 50 };
            const step = draw(c, 30) - 10;
            const m = draw(c, 4);
            try out.print("entity := class{{\n    var Health<getter(GetHealth)><setter(SetHealth)>:i64 = external{{}}\n    var Internal:i64 = {d}\n    var Writes:i64 = 0\n    GetHealth(:accessor)<reads>:i64 = Self.Internal\n    SetHealth(:accessor, V:i64)<transacts>:void = If(V >= 0 and V <= 100, Block{{ set Self.Internal = V; set Self.Writes += 1; 0 }}, 0)\n}}\nE := entity{{}}\nset E.Health = {d}\nset E.Health = {d}\nset E.Health += {d}\nValue:i64 = E.Health * 1000 + E.Writes * 100 + 60 / {d}", .{ start, values[0], values[1], step, m });
            if (m == 0) return .{ .failed = .division_by_zero };
            var internal = start;
            var writes: i64 = 0;
            for ([_]?i64{ values[0], values[1], null }) |given| {
                const v = given orelse internal + step;
                if (v < 0 or v > 100) continue;
                internal = v;
                writes += 1;
            }
            return .{ .value = internal * 1000 + writes * 100 + @divTrunc(60, m) };
        },
        // The Book's example 100: an interface's field with accessors, read and assigned through
        // the interface and through the class that implements it.
        174 => {
            const storage = draw(c, 100);
            const k = draw(c, 20);
            const values = [_]i64{ draw(c, 41) - 20, draw(c, 41) - 20 };
            const m = draw(c, 3);
            try out.print("prop := interface{{\n    var Level<getter(GetLevel)><setter(SetLevel)>:i64 = external{{}}\n    var Storage:i64 = {d}\n    GetLevel(:accessor)<reads>:i64 = Self.Storage + {d}\n    SetLevel(:accessor, V:i64)<transacts>:void = If(V >= 0, Block{{ set Self.Storage = V; 0 }}, 0)\n}}\ntracked := class(prop){{}}\nO := tracked{{}}\nP:prop = O\nset P.Level = {d}\nset O.Level = {d}\nValue:i64 = P.Level * 100 + O.Level / {d}", .{ storage, k, values[0], values[1], m });
            if (m == 0) return .{ .failed = .division_by_zero };
            var held = storage;
            for (values) |v| {
                if (v >= 0) held = v;
            }
            const level = held + k;
            return .{ .value = level * 100 + @divTrunc(level, m) };
        },
        // A setter's writes inside a region that fails are undone with the region.
        175 => {
            const limit = 5 + draw(c, 10);
            const steps = [_]i64{ draw(c, 10), draw(c, 10), draw(c, 10) };
            try out.print("counter := class{{\n    var Count<getter(GetCount)><setter(SetCount)>:i64 = external{{}}\n    var Raw:i64 = 0\n    var Sets:i64 = 0\n    GetCount(:accessor)<reads>:i64 = Self.Raw\n    SetCount(:accessor, V:i64)<transacts>:void = Block{{ set Self.Raw = V; set Self.Sets += 1; 0 }}\n}}\nC := counter{{}}\nBump(X:counter, N:i64)<transacts><decides>:i64 = Block{{ set X.Count += N; Require[X.Count < {d}]; X.Count }}\nR1:i64 = Attempt(Bump[C, {d}], -1)\nR2:i64 = Attempt(Bump[C, {d}], -1)\nR3:i64 = Attempt(Bump[C, {d}], -1)\nValue:i64 = C.Count * 1000 + C.Sets * 10 + R1 + R2 + R3", .{ limit, steps[0], steps[1], steps[2] });
            var raw: i64 = 0;
            var sets: i64 = 0;
            var results: i64 = 0;
            for (steps) |n| {
                if (raw + n < limit) {
                    raw += n;
                    sets += 1;
                    results += raw;
                } else results -= 1;
            }
            return .{ .value = raw * 1000 + sets * 10 + results };
        },
        // A path through a field with accessors rebuilds the struct and hands it to the setter;
        // a guard that reads the field follows what the getter reads.
        176 => {
            const x = draw(c, 50);
            const y = draw(c, 50);
            const start = draw(c, 50);
            const later = draw(c, 50);
            try out.print("point := struct{{ X:i64 = 0, Y:i64 = 0 }}\nshape := class{{\n    var Pos<getter(GetPos)><setter(SetPos)>:point = external{{}}\n    var Raw:point = point{{Y := {d}}}\n    GetPos(:accessor)<reads>:point = Self.Raw\n    SetPos(:accessor, P:point)<writes>:void = Block{{ set Self.Raw = P; 0 }}\n}}\nsquare := class(shape){{ Side:i64 = 1 }}\nS:shape = square{{}}\nset S.Pos.X = {d}\nset S.Pos.Y += {d}\nvar Seen:i64 = 0\nset live Seen = S.Pos.X * 2 + 1\nset S.Pos.X = {d}\nValue:i64 = S.Pos.X * 10000 + S.Pos.Y * 100 + Seen", .{ start, x, y, later });
            return .{ .value = later * 10000 + (start + y) * 100 + later * 2 + 1 };
        },
        // A getter that divides ends the run where the field is read.
        177 => {
            const raw = draw(c, 5);
            const n = draw(c, 100);
            try out.print("ratio := class{{\n    var Share<getter(GetShare)><setter(SetShare)>:i64 = external{{}}\n    var Parts:i64 = {d}\n    GetShare(:accessor)<reads>:i64 = 100 / Self.Parts\n    SetShare(:accessor, V:i64)<writes>:void = Block{{ set Self.Parts = V; 0 }}\n}}\nR := ratio{{}}\nA:i64 = R.Share\nset R.Share = {d}\nValue:i64 = A + R.Share", .{ raw, n });
            if (raw == 0 or n == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(100, raw) + @divTrunc(100, n) };
        },
        // The declarations that are refused.
        178 => {
            try out.writeAll(choose(c, []const u8, &.{
                "c := class{\n var H<getter(G)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n}\nValue:i64 = 1",
                "c := class{\n H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nValue:i64 = 1",
                "c := class{\n var H<getter(G)><setter(S)>:i64 = 3\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nValue:i64 = 1",
                "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(A:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nValue:i64 = 1",
                "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads><decides>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nValue:i64 = 1",
                "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:string = \"h\"\n S(:accessor, V:i64)<writes>:void = 0\n}\nValue:i64 = 1",
                "c := class{\n var live H<getter(G)><setter(S)>:i64 = external{}\n G(:accessor)<reads>:i64 = 1\n S(:accessor, V:i64)<writes>:void = 0\n}\nValue:i64 = 1",
                "F(:i64)<computes>:i64 = 1\nValue:i64 = 1",
            }));
            return .syntax_failure;
        },
        // And the uses that are refused: building an accessor, an archetype or a live target
        // that names the field, a subclass that restates it, and an access without its effects.
        179 => {
            const class_text = "c := class{\n var H<getter(G)><setter(S)>:i64 = external{}\n var I:i64 = 1\n G(:accessor)<reads>:i64 = Self.I\n S(:accessor, V:i64)<writes>:void = Block{ set Self.I = V; 0 }\n}\n";
            try out.writeAll(class_text);
            try out.writeAll(choose(c, []const u8, &.{
                "A:accessor = accessor{}\nValue:i64 = 1",
                "X := c{H := 3}\nValue:i64 = 1",
                "X := c{}\nset live X.H = 3\nValue:i64 = 1",
                "d := class(c){\n var H:i64 = 3\n}\nValue:i64 = 1",
                "d := class(c){\n G<override>(:accessor)<reads>:i64 = 2\n}\nValue:i64 = 1",
                "F(X:c)<computes>:i64 = X.H\nValue:i64 = 1",
                "F(X:c)<reads>:i64 = Block{ set X.H = 1; 0 }\nValue:i64 = 1",
                "X := c{}\nValue:i64 = X.G()",
            }));
            return .syntax_failure;
        },
        // ---- Grants and handles (RFC-0086, P2.3). Tasks that wake at seconds of their own read
        // the reader `config`, one line inside a region that fails (it is spent all the same);
        // two handles of the grant share its stream, and past its end a read fails.
        180 => {
            const tasks: usize = @intCast(1 + draw(c, 3));
            var waits: [3]u64 = undefined;
            try out.writeAll("Take(R:reader)<transacts>:string=Attempt(R.ReadLine[],\"<end>\")\nSpend(R:reader)<transacts>:string=Attempt(Block{L:=R.ReadLine[];Require[L==\"never\"];L},\"spent\")\nLater(N:string,W:float)<transacts><suspends>:void=Block{Sleep(W);Attempt(Block{H:=OpenReader[\"config\"];Print(\"{N} {Take(H)}\");Print(\"{N} {Spend(H)}\");Print(\"{N} {Take(H)}\")},Print(\"{N} none\"))}\n");
            for (waits[0..tasks], 0..) |*wait, index| {
                wait.* = @intCast(1 + draw(c, 3));
                try out.print("T{d}:task(void)=Spawn{{Later(\"t{d}\",{d}.0)}}\n", .{ index, index, wait.* });
            }
            try out.print("Root:tuple()=Attempt(Block{{H:=OpenReader[\"config\"];Print(\"r {{Take(H)}}\")}},Print(\"r none\"))\nValue:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            var lines: SeenLines = .{};
            model.line("r {s}", .{lines.take() orelse "<end>"});
            // Timers that fall due at one tick wake in the order they were set.
            for (1..4) |second| for (waits[0..tasks], 0..) |wait, index| {
                if (wait != second) continue;
                model.line("t{d} {s}", .{ index, lines.take() orelse "<end>" });
                _ = lines.take();
                model.line("t{d} spent", .{index});
                model.line("t{d} {s}", .{ index, lines.take() orelse "<end>" });
            };
            model.inputs = lines.reads;
            return .{ .effects = model };
        },
        // Writers: lines on two writers' channels and `Print`'s, in nested regions that commit
        // or fail as drawn, are committed in program order with the outermost region, each on
        // its channel; what a region that fails wrote is discarded with it.
        181 => {
            const f1 = draw(c, 2) == 0;
            const f2 = draw(c, 2) == 0;
            const f3 = draw(c, 2) == 0;
            try out.print("Note(W:writer,T:string)<transacts>:void=W.WriteLine(T)\nBody(L:writer,A:writer)<transacts>:i64=Block{{Note(L,\"l1\");Print(\"p1\");X:=Attempt(Block{{Note(A,\"a1\");Require[{s}];1}},2);Y:=Attempt(Block{{Print(\"p2\");Note(L,\"l2\");Z:=Attempt(Block{{Note(A,\"a2\");Require[{s}];3}},4);Require[{s}];Z}},5);X+Y}}\nValue:i64=Attempt(Block{{L:=OpenWriter[\"log\"];A:=OpenWriter[\"audit\"];Body(L,A)}},0)+{d}", .{ word(f1), word(f3), word(f2), offset });
            const x: i64 = if (f1) 1 else 2;
            const y: i64 = if (f2) (if (f3) 3 else 4) else 5;
            var model: Effects = .{ .value = x + y + offset };
            model.lineOn(2, "l1", .{});
            model.lineOn(0, "p1", .{});
            if (f1) model.lineOn(4, "a1", .{});
            if (f2) {
                model.lineOn(0, "p2", .{});
                model.lineOn(2, "l2", .{});
                if (f3) model.lineOn(4, "a2", .{});
            }
            model.discarded = (if (f1) @as(u64, 0) else 1) + (if (!f2) @as(u64, 3) else if (f3) @as(u64, 0) else 1);
            return .{ .effects = model };
        },
        // Opening: a name is looked up among the grants of its kind, and two handles of one
        // grant are equal.
        182 => {
            const names = [_][]const u8{ "config", "log", "extra", "audit", "bad", "none", "Config" };
            const readers = [_]bool{ true, false, true, false, true, false, false };
            const writers = [_]bool{ false, true, false, true, false, false, false };
            try out.writeAll("Try(N:string)<reads>:i64=Attempt(Block{R:=OpenReader[N];1},0)\nTryW(N:string)<reads>:i64=Attempt(Block{W:=OpenWriter[N];10},0)\n");
            var expected: i64 = offset;
            try out.writeAll("Value:i64=");
            for (0..3) |_| {
                const r: usize = @intCast(draw(c, names.len));
                const w: usize = @intCast(draw(c, names.len));
                try out.print("Try(\"{s}\")+TryW(\"{s}\")+", .{ names[r], names[w] });
                if (readers[r]) expected += 1;
                if (writers[w]) expected += 10;
            }
            const e: usize = @intCast(draw(c, names.len));
            try out.print("If(OpenReader[\"config\"]==OpenReader[\"{s}\"],100,200)+{d}", .{ names[e], offset });
            expected += if (e == 0) 100 else 200;
            return .{ .value = expected };
        },
        // A reader whose world gives bytes that are no text ends the run where it is read; the
        // others give the lengths of their lines, and an end.
        183 => {
            const which = draw(c, 3);
            const name = ([_][]const u8{ "config", "extra", "bad" })[@intCast(which)];
            const reads = 1 + draw(c, 4);
            try out.print("Read(N:string,K:i64)<transacts>:i64=Attempt(Block{{R:=OpenReader[N];var I:i64=0;var T:i64=0;While(I<K,Block{{set T=T+Attempt(R.ReadLine[],\"\").Length;set I=I+1}});T}},0)\nValue:i64=Read(\"{s}\",{d})+{d}", .{ name, reads, offset });
            if (which == 2) return if (reads >= 2) .{ .failed = .input_invalid } else .{ .value = offset + 2 };
            const available: i64 = if (which == 0) 6 else 2;
            return .{ .value = offset + 2 * @min(reads, available) };
        },
        // What the forms need and where they may not stand.
        184 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<computes><decides>:reader=OpenReader[\"config\"]\nValue:i64=1",
                "F(R:reader)<reads><decides>:string=R.ReadLine[]\nValue:i64=1",
                "F(W:writer)<reads><writes>:void=W.WriteLine(\"x\")\nValue:i64=1",
                "A:reader=OpenReader[\"config\"]\nValue:i64=1",
                "F(W:writer)<transacts>:void=W.WriteLine(1)\nValue:i64=1",
                "A:reader=reader{}\nValue:i64=1",
                "F(R:reader)<transacts><predicts><decides>:string=R.ReadLine[]\nValue:i64=1",
                "F(R:reader)<transacts>:void=R.WriteLine(\"x\")\nValue:i64=1",
                "var X:i64=0\nO:option(writer)=option{OpenWriter[\"log\"]}\nU:task(void)=Upon(Block{Attempt(Block{H:=O?;H.WriteLine(\"x\");1},0);X>0},Print(\"late\"))\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // The names yield to the program's own declarations of them.
        185 => {
            const own = draw(c, 2) == 0;
            const names = [_][]const u8{ "config", "log", "none", "extra" };
            const pick: usize = @intCast(draw(c, names.len));
            if (own) {
                try out.print("OpenReader(N:string)<computes><decides>:i64=N.Length\nreader:=class{{N:i64}}\nK:reader=reader{{N:=2}}\nValue:i64=Attempt(OpenReader[\"{s}\"],0)+K.N+{d}", .{ names[pick], offset });
                return .{ .value = @as(i64, @intCast(names[pick].len)) + 2 + offset };
            }
            try out.print("Value:i64=Attempt(Block{{R:=OpenReader[\"{s}\"];1}},0)+{d}", .{ names[pick], offset });
            return .{ .value = (if (pick == 0 or pick == 3) @as(i64, 1) else 0) + offset };
        },
        // Handles are values: in an array, as keys of a map, and a writer held in an array is
        // written to by the body of a `For`, outside every region, a line committed at once.
        186 => {
            const first_value = draw(c, 50);
            const second_value = 50 + draw(c, 50);
            const pick = draw(c, 2);
            try out.print("Rs:[]reader=Attempt(array{{OpenReader[\"config\"],OpenReader[\"extra\"]}},array{{}})\nM:map(reader,i64)=Attempt(map{{OpenReader[\"extra\"]=>{d},OpenReader[\"config\"]=>{d}}},map{{}})\nWs:[]writer=Attempt(array{{OpenWriter[\"audit\"]}},array{{}})\nOut:[]tuple()=For(W:Ws,W.WriteLine(\"w {d}\"))\nValue:i64=Attempt(M[Rs[{d}]],0)+{d}", .{ first_value, second_value, first_value, pick, offset });
            var model: Effects = .{ .value = (if (pick == 0) second_value else first_value) + offset };
            model.lineOn(4, "w {d}", .{first_value});
            model.inputs = 0;
            return .{ .effects = model };
        },
        // ---- RFC-0085, I2. Shared locals: an `Fn` that assigns a local `var` of the function
        // around it shares it, and every closure and the function itself use the one cell. A
        // write in a region that fails is undone like a field's.
        187 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const limit = draw(c, 20);
            try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=N;G:=Fn(K:i64)<transacts>:i64{{Set(X,X+K)}};A:=Attempt(Block{{G({d});Require[X<{d}];X}},-1);G(1);A*1000+X}}\nValue:i64=F({d})", .{ k, limit, n });
            const kept = n + k < limit;
            const first_value: i64 = if (kept) n + k else -1;
            const x: i64 = (if (kept) n + k else n) + 1;
            return .{ .value = first_value * 1000 + x };
        },
        // A task and its creator write one cell through one `Fn`, across their sleeps; at equal
        // deadlines the task, which registered first, wakes first.
        188 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const w = 1 + draw(c, 3);
            const v = 1 + draw(c, 3);
            try out.print("Run(N:i64)<transacts><suspends>:i64=Block{{var S:i64=N;Add:=Fn(K:i64)<transacts>:void{{Set(S,S+K)}};T:=Spawn{{Sleep({d}.0);Add({d});Print(\"t {{S}}\")}};Sleep({d}.0);Add(100);Print(\"c {{S}}\");T.Await();Print(\"e {{S}}\");S}}\nP:task(i64)=Spawn{{Run({d})}}\nValue:i64={d}", .{ w, k, v, n, offset });
            var model: Effects = .{ .value = offset };
            if (w <= v) {
                model.line("t {d}", .{n + k});
                model.line("c {d}", .{n + k + 100});
            } else {
                model.line("c {d}", .{n + 100});
                model.line("t {d}", .{n + k + 100});
            }
            model.line("e {d}", .{n + k + 100});
            return .{ .effects = model };
        },
        // No loop carries a shared local: the closure's writes during the loop stay.
        189 => {
            const n = draw(c, 6);
            const k = draw(c, 9);
            const form = draw(c, 3);
            switch (form) {
                0 => try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=0;G:=Fn()<transacts>:i64{{Set(X,X+{d})}};For(I:1..N,Block{{set X=X+I;G()}});X}}\nValue:i64=F({d})", .{ k, n }),
                1 => try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=0;var I:i64=0;G:=Fn()<transacts>:i64{{Set(X,X+{d})}};While(I<N,Block{{set I=I+1;set X=X+I;G()}});X}}\nValue:i64=F({d})", .{ k, n }),
                else => try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=0;var I:i64=0;G:=Fn()<transacts>:i64{{Set(X,X+{d})}};Loop{{If(I>=N,Break(),false);set I=I+1;set X=X+I;G()}};X}}\nValue:i64=F({d})", .{ k, n }),
            }
            return .{ .value = @divExact(n * (n + 1), 2) + n * k };
        },
        // What sharing does not lift, and the effects a shared local needs.
        190 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<writes>:i64=Block{var X:i64=0;G:=Fn()<writes>:void{Set(X,1)};G();X}\nValue:i64=F()",
                "F()<transacts>:i64=Block{var X:i64=0;W:=Fn()<transacts>:void{Set(X,1)};R:=Fn()<writes>:i64{X};W();R()}\nValue:i64=F()",
                "F()<transacts>:i64=Block{var X:i64=0;W:=Fn()<reads>:void{Set(X,1)};W();X}\nValue:i64=F()",
                "var Y:i64=0\nF()<transacts>:i64=Block{L:i64=1;G:=Fn()<transacts>:i64{Block{set live L=Y+1;0}};G()}\nValue:i64=F()",
                "F()<transacts>:i64=Block{var X:i64=1;G:=Fn[Y:i64=X]()<transacts>:i64{Set(Y,2)};G()}\nValue:i64=F()",
                "F()<transacts>:i64=Block{X:=1;G:=Fn()<transacts>:i64{Set(X,2)};G()}\nValue:i64=F()",
                // RFC-0085, I5: a task body shares a local `var` it assigns; a parameter stays a copy.
                "F(X:i64)<transacts><suspends>:i64=Block{T:=Spawn{Set(X,2)};T.Await()}\nP:task(i64)=Spawn{F(1)}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // Closures that outlive the frame keep its cell: two counters, each its own.
        191 => {
            const i = draw(c, 50);
            const j = draw(c, 50);
            const p = draw(c, 4);
            try out.print("C:=tuple(function<reads>(tuple(),i64),function<transacts>(tuple(),void))\nMake(I:i64)<transacts>:C=Block{{var N:i64=I;tuple{{Fn()<reads>:i64{{N}},Fn()<transacts>:void{{Set(N,N+1)}}}}}}\nA:C=Make({d})\nB:C=Make({d})\nValue:i64=Block{{For(K:1..{d},A(1)());B(1)();A(0)()*1000+B(0)()}}", .{ i, j, p });
            return .{ .value = (i + p) * 1000 + j + 1 };
        },
        // A local nothing assigns from a closure is shared too since Q1 (RFC-0085, I13): the
        // `Fn` that only reads `L` sees `set L=50`, beside the one an `Fn` assigns.
        192 => {
            const n = draw(c, 20);
            const k = draw(c, 20);
            // A division by zero after the closures ran ends the run.
            const d = draw(c, 4);
            try out.print("F(N:i64)<transacts>:i64=Block{{var L:i64=N;var M:i64=N;S:=Fn(X:i64){{L+X}};W:=Fn()<transacts>:void{{Set(M,M*2)}};R:=Fn(){{M}};set L=50;set M=M+1;W();S({d})*1000+R()+60/{d}}}\nValue:i64=F({d})", .{ k, d, n });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = (50 + k) * 1000 + (n + 1) * 2 + @divTrunc(60, d) };
        },
        // A visit of a `For` that fails undoes what the closure wrote in it.
        193 => {
            const n = 1 + draw(c, 6);
            const m = 1 + draw(c, 7);
            try out.print("F()<transacts>:i64=Block{{var X:i64=0;G:=Fn(K:i64)<transacts>:i64{{Set(X,X+K)}};Rs:=For(K:1..{d},Block{{G(K);Require[K!={d}];K}});X*100+Rs.Length}}\nValue:i64=F()", .{ n, m });
            const dropped: i64 = if (m <= n) m else 0;
            const kept: i64 = if (m <= n) n - 1 else n;
            return .{ .value = (@divExact(n * (n + 1), 2) - dropped) * 100 + kept };
        },
        // ---- RFC-0087, P5.1: `weak_map(K, V)`. A local is set and looked up one key at a time,
        // an update in a region that fails is undone, and the local is reassigned whole from a
        // literal built at its type and from a map, which converts to it. The model keeps the
        // entries in insertion order, as a map does.
        194 => {
            var keys: [4]i64 = undefined;
            var values: [4]i64 = undefined;
            var held: usize = 0;
            const Entries = struct {
                fn put(k: *[4]i64, v: *[4]i64, n: *usize, key: i64, value: i64) void {
                    for (k[0..n.*], 0..) |existing, index| if (existing == key) {
                        v[index] = value;
                        return;
                    };
                    k[n.*] = key;
                    v[n.*] = value;
                    n.* += 1;
                }
            };
            try out.writeAll("F()<transacts>:i64=Block{\nvar W:weak_map(i64,i64)=map{}\n");
            const steps: usize = @intCast(2 + draw(c, 6));
            for (0..steps) |step| {
                const key = draw(c, 4);
                const value = draw(c, 50);
                switch (draw(c, 4)) {
                    0, 1 => {
                        try out.print("set W[{d}]={d}\n", .{ key, value });
                        Entries.put(&keys, &values, &held, key, value);
                    },
                    // Key 9 is never set: the lookup fails and the region takes its update back.
                    2 => try out.print("Attempt(Block{{set W[{d}]={d};W[9]}},0)\n", .{ key, value }),
                    else => {
                        const literal = draw(c, 2) == 0;
                        if (literal) try out.print("set W=map{{{d}=>{d}}}\n", .{ key, value }) else try out.print("M{d}:map(i64,i64)=map{{{d}=>{d}}}\nset W=M{d}\n", .{ step, key, value, step });
                        held = 0;
                        Entries.put(&keys, &values, &held, key, value);
                    },
                }
            }
            try out.print("Attempt(W[0],-1)+Attempt(W[1],-1)*100+Attempt(W[2],-1)*10000+Attempt(W[3],-1)*1000000\n}}\nValue:i64=F()+{d}", .{offset});
            var total: i64 = offset;
            var scale: i64 = 1;
            for (0..4) |key| {
                var found: i64 = -1;
                for (keys[0..held], values[0..held]) |k, v| if (k == @as(i64, @intCast(key))) {
                    found = v;
                };
                total += found * scale;
                scale *= 100;
            }
            return .{ .value = total };
        },
        // A top-level `var` of a `weak_map` type is an ordinary cell (W4, Q8): functions add to
        // its entries one key at a time, and an addition past a bound is undone with its call.
        195 => {
            const bound = 10 + draw(c, 30);
            try out.print("var Scores:weak_map(string,i64)=map{{}}\nAdd(K:string,N:i64)<transacts><decides>:i64=Block{{set Scores[K]=Attempt(Scores[K],0)+N;Require[Attempt(Scores[K],0)<={d}];Attempt(Scores[K],0)}}\n", .{bound});
            var totals = [2]i64{ 0, 0 };
            var results: i64 = 0;
            const calls: usize = @intCast(1 + draw(c, 5));
            for (0..calls) |index| {
                const who = draw(c, 2);
                const amount = draw(c, 15);
                try out.print("R{d}:i64=Attempt(Add[\"{s}\",{d}],-1)\n", .{ index, if (who == 0) "a" else "b", amount });
                const slot: usize = @intCast(who);
                if (totals[slot] + amount <= bound) {
                    totals[slot] += amount;
                    results += totals[slot];
                } else results -= 1;
            }
            try out.writeAll("Value:i64=Attempt(Scores[\"a\"],0)*10000+Attempt(Scores[\"b\"],0)*100");
            for (0..calls) |index| try out.print("+R{d}", .{index});
            return .{ .value = totals[0] * 10000 + totals[1] * 100 + results };
        },
        // A literal at the `weak_map` type checks its keys as a map's does, and a value worked
        // out for an update can end the run.
        196 => {
            const first_key = draw(c, 3);
            const second_key = draw(c, 3);
            const divisor = draw(c, 4);
            try out.print("W:weak_map(i64,i64)=map{{{d}=>{d},{d}=>{d}}}\nF(D:i64)<transacts>:i64=Block{{var V:weak_map(i64,i64)=W;set V[7]=60/D;Attempt(V[7],0)}}\nValue:i64=F({d})+Attempt(W[{d}],0)", .{ first_key, a, second_key, b, divisor, first_key });
            if (first_key == second_key) return .{ .failed = .duplicate_map_key };
            if (divisor == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(60, divisor) + a };
        },
        // What a `weak_map` does not have (03:1112), and its keys.
        197 => {
            try out.writeAll(choose(c, []const u8, &.{
                "W:weak_map(i64,i64)=map{}\nValue:i64=W.Length",
                "W:weak_map(i64,i64)=map{}\nValue:i64=Block{X:=For(E:W,E);0}",
                "W:weak_map(i64,i64)=map{}\nE:logic=W==W\nValue:i64=1",
                "W:weak_map(i64,i64)=map{}\nM:map(i64,i64)=W\nValue:i64=1",
                "W:weak_map(i64,i64)=map{}\nM:map(i64,i64)=ConcatenateMaps(W,W)\nValue:i64=1",
                "W:weak_map(i64,i64)=map{1=>2}\nValue:i64=Attempt(Block{Without[W,1];0},1)",
                "M:map(weak_map(i64,i64),i64)=map{}\nValue:i64=1",
                "W:weak_map(function(tuple(),i64),i64)=map{}\nValue:i64=1",
                "c:=class{}\nW:weak_map(c,i64)=map{}\nValue:i64=1",
                "Same[T:comparable](A:T,B:T)<computes>:logic{A==B}\nW:weak_map(i64,i64)=map{}\nE:logic=Same[weak_map(i64,i64)](W,W)\nValue:i64=1",
                "W:weak_map(i64,i64)=map{}\nV:weak_map(i64,string)=W\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // The name yields to what the program declares by it: a struct or a function.
        198 => {
            const n = draw(c, 50);
            if (draw(c, 2) == 0) {
                try out.print("weak_map:=struct{{N:i64}}\nX:weak_map=weak_map{{N:={d}}}\nValue:i64=X.N+{d}", .{ n, offset });
            } else {
                try out.print("weak_map(A:i64,B:i64)<computes>:i64=A*2+B\nValue:i64=weak_map({d},{d})-{d}", .{ n, offset, n });
            }
            return .{ .value = n + offset };
        },
        // A `weak_map` held as `any` stays one: a cast finds it, and the map it was made from
        // is not found in it.
        199 => {
            const key = draw(c, 5);
            const value = draw(c, 90);
            try out.print("Tm:=map(i64,i64)\nTw:=weak_map(i64,i64)\nM:map(i64,i64)=map{{{d}=>{d}}}\nW:weak_map(i64,i64)=M\nA:any=any(W)\nK(P:any)<computes>:i64=Case(P,X:Tm=>1,Y:Tw=>2,_=>3)\nValue:i64=Attempt(Tw[A][{d}],-1)*100+Attempt(Tm[A].Length,-1)*10+K(A)+K(any(M))*1000", .{ key, value, key });
            return .{ .value = value * 100 - 10 + 2 + 1000 };
        },
        // Updates of a `weak_map` cell in a region that fails are undone, and the lines the
        // region printed with them are discarded.
        200 => {
            const limit = draw(c, 40);
            const steps: usize = @intCast(1 + draw(c, 4));
            try out.print("var W:weak_map(i64,i64)=map{{}}\nStep(K:i64,V:i64)<transacts><decides>:void=Block{{set W[K]=V;Print(\"s{{K}} {{V}}\");Require[V<{d}]}}\n", .{limit});
            var model: Effects = .{ .value = 0 };
            var last = [_]i64{ -1, -1 };
            for (0..steps) |index| {
                const key = draw(c, 2);
                const value = draw(c, 60);
                try out.print("R{d}:i64=Attempt(Block{{Step[{d},{d}];1}},0)\n", .{ index, key, value });
                if (value < limit) {
                    last[@intCast(key)] = value;
                    model.line("s{d} {d}", .{ key, value });
                    model.value += 1;
                } else model.discarded += 1;
            }
            try out.print("Value:i64=Attempt(W[0],-1)*1000+Attempt(W[1],-1)*10+{d}", .{offset});
            for (0..steps) |index| try out.print("+R{d}", .{index});
            model.value += last[0] * 1000 + last[1] * 10 + offset;
            return .{ .effects = model };
        },
        // ---- RFC-0085, I3. Nested functions: statements of a block that capture what they name,
        // a local `var` by its cell, call themselves, and are values where not called.
        // A recursive one, and one that calls it.
        201 => {
            const n = 1 + draw(c, 8);
            const k = draw(c, 5);
            try out.print("F(N:i64)<computes>:i64=Block{{Go(J:i64,Acc:i64)<computes>:i64=If(J<=1,Acc,Go(J-1,Acc*J));Plus(J:i64)<computes>:i64=Go(J,1)+{d};Plus(N)}}\nValue:i64=F({d})", .{ k, n });
            var fact: i64 = 1;
            for (2..@as(usize, @intCast(n)) + 1) |j| fact *= @intCast(j);
            return .{ .value = fact + k };
        },
        // Two counters whose nested functions outlive the frame, each with its own cell.
        202 => {
            const i = draw(c, 50);
            const j = draw(c, 50);
            const p = draw(c, 4);
            try out.print("C:=tuple(function<reads>(tuple(),i64),function<transacts>(tuple(),void))\nMake(I:i64)<transacts>:C=Block{{var N:i64=I;Get()<reads>:i64=N;Inc()<transacts>:void=Set(N,N+1);tuple{{Get,Inc}}}}\nA:C=Make({d})\nB:C=Make({d})\nValue:i64=Block{{For(K:1..{d},A(1)());B(1)();A(0)()*1000+B(0)()}}", .{ i, j, p });
            return .{ .value = (i + p) * 1000 + j + 1 };
        },
        // A write a nested function makes in a region that fails is undone.
        203 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const limit = draw(c, 20);
            try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=N;G(K:i64)<transacts>:i64=Set(X,X+K);A:=Attempt(Block{{G({d});Require[X<{d}];X}},-1);G(1);A*1000+X}}\nValue:i64=F({d})", .{ k, limit, n });
            const kept = n + k < limit;
            const first_value: i64 = if (kept) n + k else -1;
            const x: i64 = (if (kept) n + k else n) + 1;
            return .{ .value = first_value * 1000 + x };
        },
        // A task and its creator write one cell through one nested function, across their sleeps.
        204 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const w = 1 + draw(c, 3);
            const v = 1 + draw(c, 3);
            try out.print("Run(N:i64)<transacts><suspends>:i64=Block{{var S:i64=N;Add(K:i64)<transacts>:void=Set(S,S+K);T:=Spawn{{Sleep({d}.0);Add({d});Print(\"t {{S}}\")}};Sleep({d}.0);Add(100);Print(\"c {{S}}\");T.Await();Print(\"e {{S}}\");S}}\nP:task(i64)=Spawn{{Run({d})}}\nValue:i64={d}", .{ w, k, v, n, offset });
            var model: Effects = .{ .value = offset };
            if (w <= v) {
                model.line("t {d}", .{n + k});
                model.line("c {d}", .{n + k + 100});
            } else {
                model.line("c {d}", .{n + 100});
                model.line("t {d}", .{n + k + 100});
            }
            model.line("e {d}", .{n + k + 100});
            return .{ .effects = model };
        },
        // An `Fn` and a loop's body that call one carry its captures; no loop carries the cell.
        205 => {
            const n = draw(c, 6);
            const k = draw(c, 9);
            try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=0;G()<transacts>:i64=Set(X,X+{d});H:=Fn(I:i64)<transacts>:i64{{Block{{set X=X+I;G()}}}};For(I:1..N,H(I));X}}\nValue:i64=F({d})", .{ k, n });
            return .{ .value = @divExact(n * (n + 1), 2) + n * k };
        },
        // What nested functions refuse.
        206 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<computes>:i64=Block{G<public>()<computes>:i64=1;G()}\nValue:i64=F()",
                "F()<computes>:i64=Block{G[t:type](X:t)<computes>:t=X;G(1)}\nValue:i64=F()",
                "F()<transacts>:i64=Block{Defer{G()<computes>:i64=1;G()};0}\nValue:i64=F()",
                "F()<computes>:i64=Block{X:=G();G()<computes>:i64=1;X}\nValue:i64=F()",
                "F()<computes>:i64=Block{G():i64=1;G()}\nValue:i64=F()",
                "F(N:i64)<computes>:i64=Block{N()<computes>:i64=1;0}\nValue:i64=F(1)",
                "F()<transacts>:i64=Block{var X:i64=1;G()<computes>:i64=X;G()}\nValue:i64=F()",
                "b:=class{M()<computes>:i64=1}\nd:=class(b){M<override>()<computes>:i64=Block{G()<computes>:i64=Super.M();G()}}\nValue:i64=d{}.M()",
            }));
            return .syntax_failure;
        },
        // A value of one, called after a division that may end the run.
        207 => {
            const n = draw(c, 20);
            const d = draw(c, 4);
            try out.print("F(N:i64)<computes>:function<computes>(tuple(i64),i64)=Block{{G(K:i64)<computes>:i64=K*N+60/{d};G}}\nValue:i64=F({d})(3)", .{ d, n });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = 3 * n + @divTrunc(60, d) };
        },
        // ---- RFC-0085, I9. Fields with accessors and no default: the archetype's values in
        // the order written, then the block clause, then the setters in declaration order.
        208 => {
            const start = draw(c, 100);
            const h = draw(c, 201) - 50;
            const armour = draw(c, 100);
            const health_first = draw(c, 2) == 0;
            try out.print("var T:i64=0\nNote(D:i64,V:i64)<transacts>:i64=Block{{set T=T*10+D;V}}\nentity:=class{{\n var Health<getter(GH)><setter(SH)>:i64\n var Armour<getter(GA)><setter(SA)>:i64\n var H:i64={d}\n var A:i64=0\n Block{{Note(3,0)}}\n GH(:accessor)<reads>:i64=Self.H\n SH(:accessor,V:i64)<transacts>:void=Block{{Note(4,0);If(V>=0 and V<=100,Block{{set Self.H=V;0}},0)}}\n GA(:accessor)<reads>:i64=Self.A\n SA(:accessor,V:i64)<transacts>:void=Block{{Note(5,0);set Self.A=V*2;0}}\n}}\n", .{start});
            if (health_first) try out.print("E:=entity{{Health:=Note(1,{d}),Armour:=Note(2,{d})}}\n", .{ h, armour }) else try out.print("E:=entity{{Armour:=Note(2,{d}),Health:=Note(1,{d})}}\n", .{ armour, h });
            try out.writeAll("Value:i64=T*1000000+E.Health*1000+E.Armour");
            const trace: i64 = if (health_first) 12345 else 21345;
            const health = if (h >= 0 and h <= 100) h else start;
            return .{ .value = trace * 1000000 + health * 1000 + armour * 2 };
        },
        // Through an interface: the implementing class's archetype gives the field, and a
        // compound `set` then reads through the getter once.
        209 => {
            const r = draw(c, 21);
            const m = 1 + draw(c, 3);
            const k = draw(c, 10);
            const s = draw(c, 10);
            try out.print("titled:=interface{{\n var Rank<getter(GR)><setter(SR)>:i64\n var Raw:i64=0\n GR(:accessor)<reads>:i64=Self.Raw+{d}\n SR(:accessor,V:i64)<writes>:void=Block{{set Self.Raw=V*{d};0}}\n}}\nbadge:=class(titled){{}}\nP:titled=badge{{Rank:={d}}}\nset P.Rank+={d}\nValue:i64=P.Rank", .{ k, m, r, s });
            return .{ .value = (r * m + k + s) * m + k };
        },
        // Delegation lends the value a constructor function gives such a field, wherever the
        // delegation is written among the archetype's entries.
        210 => {
            const l = draw(c, 50);
            const t = draw(c, 50);
            try out.writeAll("base:=class{\n var Level<getter(GL)><setter(SL)>:i64\n var Raw:i64=0\n GL(:accessor)<reads>:i64=Self.Raw\n SL(:accessor,V:i64)<writes>:void=Block{set Self.Raw=V+1;0}\n}\nMakeBase<constructor>(L:i64)<transacts>:=base{Level:=L*2}\nhero:=class(base){\n var Tag<getter(GT)><setter(ST)>:i64\n var TagRaw:i64=0\n GT(:accessor)<reads>:i64=Self.TagRaw\n ST(:accessor,V:i64)<writes>:void=Block{set Self.TagRaw=V*10;0}\n}\n");
            if (draw(c, 2) == 0) try out.print("X:=hero{{MakeBase<constructor>({d}),Tag:={d}}}\n", .{ l, t }) else try out.print("X:=hero{{Tag:={d},MakeBase<constructor>({d})}}\n", .{ t, l });
            try out.writeAll("Value:i64=X.Level*1000+X.Tag");
            return .{ .value = (2 * l + 1) * 1000 + 10 * t };
        },
        // An archetype in a region that fails: what its setter wrote is undone with it.
        211 => {
            const lim = draw(c, 21);
            const values = [_]i64{ draw(c, 20), draw(c, 20) };
            try out.print("var T:i64=0\nc:=class{{\n var V<getter(G)><setter(S)>:i64\n var Raw:i64=0\n G(:accessor)<reads>:i64=Self.Raw\n S(:accessor,X:i64)<transacts>:void=Block{{set T+=X;set Self.Raw=X;0}}\n}}\nTry(N:i64)<transacts><decides>:i64=Block{{O:=c{{V:=N}};Require[O.V<{d}];O.V}}\nR1:i64=Attempt(Try[{d}],-1)\nR2:i64=Attempt(Try[{d}],-1)\nValue:i64=T*1000+R1*10+R2", .{ lim, values[0], values[1] });
            var total: i64 = 0;
            var results: [2]i64 = undefined;
            for (values, &results) |n, *result| {
                if (n < lim) {
                    total += n;
                    result.* = n;
                } else result.* = -1;
            }
            return .{ .value = total * 1000 + results[0] * 10 + results[1] };
        },
        // A setter that divides by the value it is given ends the run when that is 0.
        212 => {
            const d = draw(c, 5);
            try out.print("c:=class{{\n var V<getter(G)><setter(S)>:i64\n var Raw:i64=0\n G(:accessor)<reads>:i64=Self.Raw\n S(:accessor,X:i64)<writes>:void=Block{{set Self.Raw=100/X;0}}\n}}\nO:=c{{V:={d}}}\nValue:i64=O.V", .{d});
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(100, d) };
        },
        // The archetypes that are refused: a field not given, or given twice, a class whose
        // archetype may be empty, a value of another type, the setter's effects missing, and
        // an `external{}` field named.
        213 => {
            try out.writeAll("c:=class{\n var V<getter(G)><setter(S)>:i64\n var Raw:i64=0\n G(:accessor)<reads>:i64=Self.Raw\n S(:accessor,X:i64)<writes>:void=Block{set Self.Raw=X;0}\n}\n");
            try out.writeAll(choose(c, []const u8, &.{
                "X:=c{}\nValue:i64=1",
                "X:=c{V:=1,V:=2}\nValue:i64=1",
                "k:=class<concrete>(c){}\nValue:i64=1",
                "d:=class(c){}\nX:=d{}\nValue:i64=1",
                "M()<allocates>:c=c{V:=1}\nValue:i64=1",
                "X:=c{V:=\"s\"}\nValue:i64=1",
                "M<constructor>()<transacts>:=c{V:=1}\nX:=c{V:=2,M<constructor>()}\nValue:i64=1",
                "e:=class{\n var W<getter(G)><setter(S)>:i64=external{}\n var Raw:i64=0\n G(:accessor)<reads>:i64=Self.Raw\n S(:accessor,X:i64)<writes>:void=Block{set Self.Raw=X;0}\n}\nY:=e{W:=1}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // Two classes: the values as written, both block clauses (the superclass's first), then
        // the superclass's setter and the subclass's.
        214 => {
            const p = draw(c, 100);
            const q = draw(c, 100);
            const q_first = draw(c, 2) == 0;
            try out.writeAll("var T:i64=0\nNote(D:i64,V:i64)<transacts>:i64=Block{set T=T*10+D;V}\na:=class{\n var P<getter(GP)><setter(SP)>:i64\n var RP:i64=0\n Block{Note(5,0)}\n GP(:accessor)<reads>:i64=Self.RP\n SP(:accessor,V:i64)<transacts>:void=Block{Note(7,0);set Self.RP=V;0}\n}\nb:=class(a){\n var Q<getter(GQ)><setter(SQ)>:i64\n var RQ:i64=0\n Block{Note(6,0)}\n GQ(:accessor)<reads>:i64=Self.RQ\n SQ(:accessor,V:i64)<transacts>:void=Block{Note(8,0);set Self.RQ=V;0}\n}\n");
            if (q_first) try out.print("O:=b{{Q:=Note(2,{d}),P:=Note(1,{d})}}\n", .{ q, p }) else try out.print("O:=b{{P:=Note(1,{d}),Q:=Note(2,{d})}}\n", .{ p, q });
            try out.writeAll("Value:i64=T*10000+O.P*100+O.Q");
            const trace: i64 = if (q_first) 215678 else 125678;
            return .{ .value = trace * 10000 + p * 100 + q };
        },
        // RFC-0085, I11: a parameter, a local a `For` carries, a nested function and an `Fn` whose
        // capture has the parameter's name, which names the parameter again after the `Fn`.
        215 => {
            const n = 1 + draw(c, 9);
            const base = draw(c, 100);
            try out.print("F(Base:i64)<transacts>:i64=Block{{var Sum:i64=0;Twice(M:i64)<computes>:i64=M*2;G:=Fn[Base:i64=Base](N:i64)<computes>:i64{{Base+N}};For(K:1..{d},Block{{set Sum=Sum+K;Sum}});G(Sum)+Twice(Base)}}\nValue:i64=F({d})", .{ n, base });
            return .{ .value = @divExact(n * (n + 1), 2) + 3 * base };
        },
        // Members of a class, an enumerator qualified by its enum in an expression and in the enum.
        216 => {
            const scale = draw(c, 50);
            const by = draw(c, 50);
            const start = c.rng.below(2) == 0;
            try out.print("light:=enum{{(light:)Start,Glow}}\nshape:=class{{var Scale:i64={d}\nGrow(By:i64)<transacts>:i64=Block{{set Self.Scale=Self.Scale+By;Self.Scale}}}}\nS:shape=shape{{}}\nL:light={s}\nValue:i64=S.Grow({d})*10+If(L==light.Start,1,0)", .{ scale, if (start) "(light:)Start" else "light.Glow", by });
            return .{ .value = (scale + by) * 10 + @intFromBool(start) };
        },
        // Overloads, picked by their arguments, an extension method and a type parameter.
        217 => {
            const x = draw(c, 30);
            const y = draw(c, 30);
            const label = choose(c, []const u8, &.{ "a", "four", "seven" });
            try out.print("point:=struct{{X:i64=0,Y:i64=0}}\nSize(P:point)<computes>:i64=P.X+P.Y\nSize(S:string)<computes>:i64=S.Length\n(P:point).Product()<computes>:i64=P.X*P.Y\nIdentity[T:type](V:T)<computes>:T{{V}}\nC:point=point{{X:={d},Y:={d}}}\nValue:i64=Identity[i64](Size(C)*1000+Size(\"{s}\")*100+C.Product())", .{ x, y, label });
            return .{ .value = (x + y) * 1000 + @as(i64, @intCast(label.len)) * 100 + x * y };
        },
        // `(local:)Start` beside a module's `Start`: in the function the name is the local.
        218 => {
            const outer = draw(c, 100);
            const inner = draw(c, 100);
            try out.print("Start:i64={d}\nMix()<computes>:i64=Block{{(local:)Start:i64={d};(local:)Start*10+Start}}\nValue:i64=Mix()+Start", .{ outer, inner });
            return .{ .value = inner * 11 + outer };
        },
        // A `While` that carries two locals; a division by zero after it ends the run.
        219 => {
            const n = draw(c, 12);
            const d = draw(c, 3);
            try out.print("Sum(N:i64)<transacts>:i64=Block{{var I:i64=0;var Total:i64=0;While(I<N,Block{{set Total=Total+I;set I=I+1}});Total}}\nValue:i64=Sum({d})*60/{d}", .{ n, d });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(@divExact(n * (n - 1), 2) * 60, d) };
        },
        // What `forbic qualify` prints is not source (Q6), and a qualifier names what it can.
        220 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Start:i64=0\nValue:i64=(/:)Start",
                "Start:i64=0\nValue:i64=(/Verse.org/Verse:)i64(Start)",
                "(local:)Value:i64=1",
                "light:=enum{(other:)Start,Glow}\nValue:i64=0",
                "F(X:i64)<computes>:i64=(local:)Y\nValue:i64=F(1)",
            }));
            return .syntax_failure;
        },
        // Members of a struct, the fields of an archetype and a method of a subclass.
        221 => {
            const side = 1 + draw(c, 20);
            const scale = 1 + draw(c, 5);
            try out.print("base:=class{{var Scale:i64={d}\nArea()<transacts>:i64=Self.Scale}}\nsquare:=class(base){{Side:i64=1\nArea<override>()<transacts>:i64=Self.Side*Self.Side*Self.Scale}}\nShapes:[]base=array{{square{{Side:={d}}},base{{}}}}\nValue:i64=Attempt(Shapes[0].Area()*100+Shapes[1].Area(),-1)", .{ scale, side });
            return .{ .value = side * side * scale * 100 + scale };
        },
        // ---- The durable journal (RFC-0086, P2.4). Every run's log tells a sink where each of
        // its commit points ends (J3): one seal after the actions of an outermost region that
        // commits, or after an action outside every region; none for a region that fails or
        // commits nothing. The cases work the seals out from that rule. Regions three deep, with
        // `Print` and a writer, commit or fail as drawn.
        222 => {
            const f1 = draw(c, 2) == 0;
            const f2 = draw(c, 2) == 0;
            const f3 = draw(c, 2) == 0;
            try out.print("Note(W:writer,T:string)<transacts>:void=W.WriteLine(T)\nValue:i64=Attempt(Block{{L:=OpenWriter[\"log\"];Print(\"a\");X:=Attempt(Block{{Note(L,\"b\");Y:=Attempt(Block{{Print(\"c\");Require[{s}];1}},0);Require[{s}];Y+1}},0);Require[{s}];X+10}},0)+{d}\nAfter:tuple()=Print(\"d\")", .{ word(f3), word(f2), word(f1), offset });
            const y: i64 = if (f3) 1 else 0;
            const x: i64 = if (f2) y + 1 else 0;
            var model: Effects = .{ .value = (if (f1) x + 10 else 0) + offset };
            if (f1) {
                model.lineOn(0, "a", .{});
                if (f2) {
                    model.lineOn(2, "b", .{});
                    if (f3) model.lineOn(0, "c", .{});
                }
                model.seal();
            }
            model.lineOn(0, "d", .{});
            model.seal();
            const inner: u64 = if (f3) 1 else 0;
            const middle: u64 = if (f2) 1 + inner else 0;
            model.discarded = (if (f3) @as(u64, 0) else 1) + (if (f2) @as(u64, 0) else 1 + inner) + (if (f1) @as(u64, 0) else 1 + middle);
            return .{ .effects = model };
        },
        // Each line a `For` prints outside every region is a commit point of its own; regions
        // that commit nothing, or fail, have no seal.
        223 => {
            const n: usize = @intCast(1 + draw(c, 5));
            const empty_ok = draw(c, 2) == 0;
            try out.print("E:i64=Attempt(Block{{Require[{s}];1}},0)\nOut:[]tuple()=For(I:1..{d},Print(\"i{{I}}\"))\nF:i64=Attempt(Block{{Require[{s}];2}},0)\nValue:i64=E+F+{d}", .{ word(empty_ok), n, word(!empty_ok), offset });
            var model: Effects = .{ .value = (if (empty_ok) @as(i64, 1) else 2) + offset };
            for (1..n + 1) |i| {
                model.line("i{d}", .{i});
                model.seal();
            }
            return .{ .effects = model };
        },
        // A region left by `Return` commits at the exit, as a commit point; the region of a call
        // that does not return there commits at its end, and what follows is one more.
        224 => {
            const n = draw(c, 3);
            try out.print("F(N:i64)<transacts>:i64=Block{{Attempt(Block{{Print(\"in {{N}}\");If(N>0,Return(N),0)}},0);Print(\"after {{N}}\");0}}\nValue:i64=F({d})+F(0)+{d}", .{ n, offset });
            var model: Effects = .{ .value = n + offset };
            model.line("in {d}", .{n});
            model.seal();
            if (n == 0) {
                model.line("after 0", .{});
                model.seal();
            }
            model.line("in 0", .{});
            model.seal();
            model.line("after 0", .{});
            model.seal();
            return .{ .effects = model };
        },
        // Tasks that wake at seconds of their own print outside every region and in one that
        // commits or fails; their commit points are sealed in the order the schedule runs them.
        225 => {
            const waits = [2]u64{ @intCast(1 + draw(c, 3)), @intCast(1 + draw(c, 3)) };
            const keeps = [2]bool{ draw(c, 2) == 0, draw(c, 2) == 0 };
            try out.print("Later(N:string,W:float,K:logic)<transacts><suspends>:void=Block{{Sleep(W);Print(\"{{N}} a\");Attempt(Block{{Print(\"{{N}} b\");Require[K];Print(\"{{N}} c\")}},Print(\"{{N}} x\"))}}\nT0:task(void)=Spawn{{Later(\"t0\",{d}.0,{s})}}\nT1:task(void)=Spawn{{Later(\"t1\",{d}.0,{s})}}\nValue:i64={d}", .{ waits[0], word(keeps[0]), waits[1], word(keeps[1]), offset });
            var model: Effects = .{ .value = offset };
            // Timers that fall due at one tick wake in the order they were set.
            for (1..4) |second| for (waits, keeps, 0..) |wait, keep, index| {
                if (wait != second) continue;
                model.line("t{d} a", .{index});
                model.seal();
                if (keep) {
                    model.line("t{d} b", .{index});
                    model.line("t{d} c", .{index});
                } else {
                    model.discarded += 1;
                    model.line("t{d} x", .{index});
                }
                model.seal();
            };
            return .{ .effects = model };
        },
        // A fatal error in a region ends the run: what was sealed before it stays, what the region
        // held is dropped unsealed. With a divisor that is not zero the region commits.
        226 => {
            const divisor = draw(c, 2);
            try out.print("K:tuple()=Print(\"kept\")\nZero:i64={d}\nBad:i64=Attempt(Block{{Print(\"pending\");1/Zero}},0)\nValue:i64={d}+Bad", .{ divisor, offset });
            if (divisor == 0) return .{ .failed = .division_by_zero };
            var model: Effects = .{ .value = offset + 1 };
            model.line("kept", .{});
            model.seal();
            model.line("pending", .{});
            model.seal();
            return .{ .effects = model };
        },
        // What the forms of an action need, which the journal does not change.
        227 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<reads>:void=Print(\"x\")\nValue:i64=1",
                "F(W:writer)<writes>:void=W.WriteLine(\"x\")\nValue:i64=1",
                "F(W:writer)<transacts><predicts>:void=W.WriteLine(\"x\")\nValue:i64=1",
                "F(R:reader)<writes><decides>:string=R.ReadLine[]\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // Lines read and written in regions: a region that commits seals the line it wrote and
        // the line it printed together; a line equal to the one drawn fails its region, and the
        // end of the stream fails the read itself. Every read is recorded either way (I2).
        228 => {
            const calls: usize = @intCast(1 + draw(c, 8));
            const refused = draw(c, 6);
            try out.print("Copy(R:reader,W:writer)<transacts><decides>:void=Block{{L:=R.ReadLine[];W.WriteLine(\"got {{L}}\");Print(\"seen\");Require[L!=\"c{d}\"]}}\n", .{refused});
            var model: Effects = .{ .value = offset };
            var lines: SeenLines = .{};
            for (0..calls) |index| {
                try out.print("V{d}:i64=Attempt(Block{{R:=OpenReader[\"config\"];W:=OpenWriter[\"log\"];Copy[R,W];1}},0)\n", .{index});
                const line = lines.take() orelse continue;
                var name: [8]u8 = undefined;
                if (std.mem.eql(u8, line, std.fmt.bufPrint(&name, "c{d}", .{refused}) catch unreachable)) {
                    model.discarded += 2;
                    continue;
                }
                model.lineOn(2, "got {s}", .{line});
                model.lineOn(0, "seen", .{});
                model.seal();
                model.value += 1;
            }
            try out.print("Value:i64={d}", .{offset});
            for (0..calls) |index| try out.print("+V{d}", .{index});
            model.inputs = lines.reads;
            return .{ .effects = model };
        },
        // ---- RFC-0085, I4. Overloads, defaults and named parameters of nested functions, as
        // top-level functions have them (RFC-0058, RFC-0061).
        // Overloads chosen by the types and the number of the arguments, each with its captures.
        229 => {
            const n = draw(c, 10);
            const x = draw(c, 20);
            const length: usize = @intCast(draw(c, 5));
            const y = draw(c, 9);
            const z = draw(c, 9);
            try out.print("F(N:i64)<computes>:i64=Block{{G(X:i64)<computes>:i64=X*2+N;G(S:string)<computes>:i64=S.Length+N;G(X:i64,Y:i64)<computes>:i64=X*Y;G({d})+G(\"", .{x});
            for (0..length) |_| try out.writeAll("a");
            try out.print("\")*100+G({d},{d})*10000}}\nValue:i64=F({d})", .{ y, z, n });
            return .{ .value = x * 2 + n + (@as(i64, @intCast(length)) + n) * 100 + y * z * 10000 };
        },
        // Defaults that read the parameters before them; arguments by position, then by name in
        // any order.
        230 => {
            const k = draw(c, 9);
            const pa = 1 + draw(c, 9);
            const pb = draw(c, 9);
            const cc = draw(c, 9);
            const form = draw(c, 5);
            try out.print("F()<computes>:i64=Block{{G(A:i64,B:i64=A+{d},C:i64=B*2)<computes>:i64=A*10000+B*100+C;", .{k});
            var values = [3]i64{ pa, pa + k, 0 };
            switch (form) {
                0 => try out.print("G({d})", .{pa}),
                1 => {
                    try out.print("G({d},{d})", .{ pa, pb });
                    values[1] = pb;
                },
                2 => {
                    try out.print("G({d},C:={d})", .{ pa, cc });
                    values[2] = cc;
                },
                3 => {
                    try out.print("G(B:={d},A:={d})", .{ pb, pa });
                    values[1] = pb;
                },
                else => {
                    try out.print("G(C:={d},A:={d},B:={d})", .{ cc, pa, pb });
                    values[1] = pb;
                    values[2] = cc;
                },
            }
            if (form != 2 and form != 4) values[2] = values[1] * 2;
            try out.writeAll("}\nValue:i64=F()");
            return .{ .value = values[0] * 10000 + values[1] * 100 + values[2] };
        },
        // A call that leaves out a default, writing a cell in a region that fails, is undone.
        231 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const limit = draw(c, 20);
            try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=N;Add(K:i64=1)<transacts>:i64=Set(X,X+K);A:=Attempt(Block{{Add(K:={d});Require[X<{d}];X}},-1);Add();A*1000+X}}\nValue:i64=F({d})", .{ k, limit, n });
            const kept = n + k < limit;
            const first_value: i64 = if (kept) n + k else -1;
            const x: i64 = (if (kept) n + k else n) + 1;
            return .{ .value = first_value * 1000 + x };
        },
        // An overloaded one as a value, chosen by the expected type, called after its frame
        // ended, after a division that may end the run.
        232 => {
            const n = draw(c, 20);
            const d = draw(c, 4);
            try out.print("F(N:i64)<computes>:function<computes>(tuple(i64),i64)=Block{{G(K:i64)<computes>:i64=K*N+60/{d};G(S:string)<computes>:i64=S.Length;G}}\nValue:i64=F({d})(3)", .{ d, n });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = 3 * n + @divTrunc(60, d) };
        },
        // An `Fn` that calls overloads (with every argument: a call of overloads names none and
        // leaves none out) carries the captures of each; a call of another leaves out a default.
        233 => {
            const n = draw(c, 10);
            const k = draw(c, 9);
            const m = 1 + draw(c, 9);
            try out.print("F(N:i64,T:string)<computes>:i64=Block{{G(X:i64,Y:i64={d})<computes>:i64=X+Y+N;G(S:string)<computes>:i64=S.Length+T.Length;H:=Fn(I:i64)<computes>:i64{{G(I,1)+G(\"ab\")*1000}};P(X:i64,Y:i64={d})<computes>:i64=X*Y+N;H({d})+P(2)*1000000}}\nValue:i64=F({d},\"xyz\")", .{ k, k, m, n });
            return .{ .value = (m + 1 + n) + 5 * 1000 + (2 * k + n) * 1000000 };
        },
        // What overloads, defaults and named arguments of nested functions refuse.
        234 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<computes>:i64=Block{G(X:i64)<computes>:i64=X;G(Y:i64)<computes>:i64=Y;G(1)}\nValue:i64=F()",
                "F()<computes>:i64=Block{G(X:i64)<computes>:i64=X;G(X:string)<computes><decides>:i64=X.Length;G(1)}\nValue:i64=F()",
                "b:=class{}\nd:=class(b){}\nF()<computes>:i64=Block{G(X:b)<computes>:i64=1;G(X:d)<computes>:i64=2;0}\nValue:i64=F()",
                "F()<computes>:i64=Block{G(X:i64)<computes>:i64=X;G(X:string)<computes>:i64=X.Length;G(X:=1)}\nValue:i64=F()",
                "F()<computes>:i64=Block{G(X:i64)<computes>:i64=X;G(X:string)<computes>:i64=X.Length;W:=G;0}\nValue:i64=F()",
                "F(N:i64)<computes>:i64=Block{G(X:i64=N)<computes>:i64=X;G()}\nValue:i64=F(1)",
                "F()<computes>:i64=Block{G(X:i64=1)<computes>:i64=X;G(Y:=2)}\nValue:i64=F()",
                "F()<computes>:i64=Block{G(X:i64,Y:i64=1)<computes>:i64=X+Y;G(1,X:=2)}\nValue:i64=F()",
            }));
            return .syntax_failure;
        },
        // A suspending one with defaults and named arguments, run by a task across its sleeps.
        235 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const w = 1 + draw(c, 3);
            try out.print("Run(N:i64)<transacts><suspends>:i64=Block{{var S:i64=N;Add(K:i64=1,Tag:string=\"a\")<transacts><suspends>:void=Block{{Sleep({d}.0);Set(S,S+K);Print(\"{{Tag}} {{S}}\")}};Add();Add(Tag:=\"b\",K:={d});S}}\nP:task(i64)=Spawn{{Run({d})}}\nValue:i64={d}", .{ w, k, n, offset });
            var model: Effects = .{ .value = offset };
            model.line("a {d}", .{n + 1});
            model.line("b {d}", .{n + 1 + k});
            return .{ .effects = model };
        },
        // ---- RFC-0085, I5: shared locals in tasks. A task body, an arm, a reaction body, a
        // `Batch{}` body and a landing that assign a local `var` share it (S1d); a task sees every
        // write made before a switch (S5).
        // A task writes the cell after its sleep; the creator reads it after `Await`, or has
        // returned and hands on a closure that reads it later.
        236 => {
            const n = draw(c, 10);
            const k = 1 + draw(c, 9);
            const w = 1 + draw(c, 3);
            var model: Effects = .{ .value = offset };
            if (draw(c, 2) == 0) {
                try out.print("Run(N:i64)<transacts><suspends>:i64=Block{{var S:i64=N;T:=Spawn{{Sleep({d}.0);Set(S,S+{d})}};T.Await();Print(\"s {{S}}\");S}}\nP:task(i64)=Spawn{{Run({d})}}\nValue:i64={d}", .{ w, k, n, offset });
                model.line("s {d}", .{n + k});
            } else {
                try out.print("Make(N:i64)<transacts><suspends>:function<reads>(tuple(),i64)=Block{{var S:i64=N;T:=Spawn{{Sleep({d}.0);Set(S,S+{d})}};Fn()<reads>:i64{{S}}}}\nRun(N:i64)<transacts><suspends>:i64=Block{{R:=Make(N);A:=R();Print(\"a {{A}}\");Sleep(4.0);B:=R();Print(\"s {{B}}\");B}}\nP:task(i64)=Spawn{{Run({d})}}\nValue:i64={d}", .{ w, k, n, offset });
                model.line("a {d}", .{n});
                model.line("s {d}", .{n + k});
            }
            return .{ .effects = model };
        },
        // Two tasks write one cell in the order of their deadlines; at equal deadlines the one
        // that registered first wakes first.
        237 => {
            const w1 = 1 + draw(c, 3);
            const w2 = 1 + draw(c, 3);
            const n = draw(c, 10);
            try out.print("Run()<transacts><suspends>:i64=Block{{var X:i64={d};T:=Spawn{{Sleep({d}.0);Set(X,X*10+1)}};U:=Spawn{{Sleep({d}.0);Set(X,X*10+2)}};T.Await();U.Await();Print(\"x {{X}}\");X}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ n, w1, w2, offset });
            var model: Effects = .{ .value = offset };
            model.line("x {d}", .{if (w1 <= w2) (n * 10 + 1) * 10 + 2 else (n * 10 + 2) * 10 + 1});
            return .{ .effects = model };
        },
        // `Sync` arms write one cell in schedule order; a `Race` loser is cancelled before its write.
        238 => {
            const first_sleep = 1 + draw(c, 3);
            const second_sleep = 1 + draw(c, 3);
            const k = draw(c, 9);
            try out.print("Run()<transacts><suspends>:i64=Block{{var N:i64={d};R:=Sync(Block{{Sleep({d}.0);set N=N*10+1;N}},Block{{Sleep({d}.0);set N=N*10+2;N}});Print(\"n {{R(0)}} {{R(1)}} {{N}}\");W:=Race(Block{{Sleep(1.0);Set(N,N+1)}},Block{{Sleep(2.0);Set(N,N+1000)}});Print(\"w {{W}} {{N}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ k, first_sleep, second_sleep, offset });
            var model: Effects = .{ .value = offset };
            // The first arm registered first: it wins a tie.
            const first_arm: i64 = if (first_sleep <= second_sleep) k * 10 + 1 else (k * 10 + 2) * 10 + 1;
            const second_arm: i64 = if (first_sleep <= second_sleep) (k * 10 + 1) * 10 + 2 else k * 10 + 2;
            const n = if (first_sleep <= second_sleep) second_arm else first_arm;
            model.line("n {d} {d} {d}", .{ first_arm, second_arm, n });
            model.line("w {d} {d}", .{ n + 1, n + 1 });
            return .{ .effects = model };
        },
        // A `Defer` in an arm writes the local of the function around the `Race`: at the arm's
        // end, or in its landing when the other arm wins (the second share wave).
        239 => {
            const d = 1 + draw(c, 9);
            const wins = draw(c, 2) == 0;
            try out.print("Run()<transacts><suspends>:i64=Block{{var X:i64=0;W:=Race(Block{{Defer{{set X=X+{d}}};Sleep({d}.0);1}},Block{{Sleep(2.0);2}});Print(\"x {{W}} {{X}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ d, @as(i64, if (wins) 1 else 5), offset });
            var model: Effects = .{ .value = offset };
            model.line("x {d} {d}", .{ @as(i64, if (wins) 1 else 2), d });
            return .{ .effects = model };
        },
        // A `Spawn` held in a region: dropped with the creator's write when the region fails,
        // carried out at the commit otherwise. A division by zero afterwards ends the run.
        240 => {
            const limit = draw(c, 200);
            const d = draw(c, 3);
            try out.print("Run(D:i64)<transacts><suspends>:i64=Block{{var X:i64=1;A:=Attempt(Block{{T:=Spawn{{Set(X,X+10)}};set X=X+100;Require[X<{d}];0}},-1);Sleep(1.0);Print(\"x {{X}} {{A}}\");60/D}}\nP:task(i64)=Spawn{{Run({d})}}\nValue:i64={d}", .{ limit, d, offset });
            if (d == 0) return .{ .failed = .division_by_zero };
            var model: Effects = .{ .value = offset };
            if (101 < limit) model.line("x 111 0", .{}) else model.line("x 1 -1", .{});
            return .{ .effects = model };
        },
        // A `Batch{}` body and a `When` body write the creator's local.
        241 => {
            const k = draw(c, 9);
            const g = 1 + draw(c, 9);
            try out.print("var G:i64=0\nRun()<transacts><suspends>:i64=Block{{var L:i64={d};B:i64=Batch{{set L=L+1;L*2}};W:task(void)=When(G,Set(L,L*10+G));set G={d};Sleep(1.0);Print(\"l {{B}} {{L}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ k, g, offset });
            var model: Effects = .{ .value = offset };
            // The body runs when the reaction starts (G is 0) and again at the change.
            model.line("l {d} {d}", .{ 2 * (k + 1), (k + 1) * 100 + g });
            return .{ .effects = model };
        },
        // What I5 does not lift, and the effects a shared local needs in a body.
        242 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F(X:i64)<transacts><suspends>:i64=Block{T:=Spawn{Set(X,2)};T.Await()}\nP:task(i64)=Spawn{F(1)}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{X:i64=1;R:=Sync(Block{Sleep(1.0);Set(X,2)},Block{Sleep(1.0);1});R(0)}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<transacts>:i64=Block{X:i64=1;B:i64=Batch{Set(X,2)};X}\nValue:i64=F()",
                "F()<transacts>:i64=Block{var X:i64=1;G:=Fn[Y:i64=X]()<transacts>:i64{Block{T:=Spawn{Set(Y,2)};1}};G()}\nValue:i64=F()",
                "F()<writes><allocates><suspends>:i64=Block{var X:i64=0;T:=Spawn{Set(X,X+1)};0}\nValue:i64=1",
                "F()<transacts>:i64=Block{var X:i64=0;G:=Fn()<reads><allocates>:i64{Block{T:=Spawn{Set(X,1)};0}};G()}\nValue:i64=F()",
                "F(N:i64)<transacts><suspends>:i64=Block{Defer{set N=1};Sleep(1.0);N}\nG()<transacts><suspends>:i64=Race(F(1),2)\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0087, P5.2: `<persistable>` types. A struct whose fields have literal
        // defaults (T5), built with some of them given: what `p{...}` holds is the default of
        // every field it does not give.
        243 => {
            const level = draw(c, 50) - 25;
            const bonus = draw(c, 9);
            const given = draw(c, 2) == 0;
            const experience = draw(c, 1000);
            try out.print("stats:=struct<persistable>{{Level:i64={d},Experience:i64=0,Name:string=\"n\",Rate:float=-0.0}}\nS:stats=stats{{", .{level});
            if (given) try out.print("Experience:={d}", .{experience});
            try out.print("}}\nValue:i64=S.Level*1000+S.Experience+{d}+If(S.Name==\"n\",1,0)", .{bonus});
            return .{ .value = level * 1000 + (if (given) experience else 0) + bonus + 1 };
        },
        // A persistable class and enums, open and closed, with a method, matched by `Case`
        // (T3, T6, T7).
        244 => {
            const start = draw(c, 3);
            const level = 1 + draw(c, 40);
            try out.print("mode:=enum<persistable><closed>{{Easy,Normal,Hard}}\nbadge:=enum<open><persistable>{{First}}\nprofile:=class<final><persistable>{{Level:i64={d}\nMode:mode=mode.{s}\nB:badge=badge.First\nScore()<reads>:i64=Self.Level*Case(Self.Mode,mode.Easy=>1,mode.Normal=>2,mode.Hard=>3)}}\nP:profile=profile{{}}\nValue:i64=P.Score()+Case(P.B,badge.First=>{d},_=>0)", .{ level, ([_][]const u8{ "Easy", "Normal", "Hard" })[@intCast(start)], offset });
            return .{ .value = level * (start + 1) + offset };
        },
        // Containers of persistable types as defaults: an array, an option and a map, read as
        // any other value.
        245 => {
            const length: usize = @intCast(draw(c, 4));
            const key = draw(c, 4);
            const present = draw(c, 2) == 0;
            const value = draw(c, 100);
            try out.writeAll("kit:=struct<persistable>{A:[]i64=array{");
            var head: i64 = -1;
            for (0..length) |index| {
                const element = draw(c, 20);
                if (index != 0) try out.writeAll(",");
                try out.print("{d}", .{element});
                if (index == 0) head = element;
            }
            try out.writeAll("},O:option(i64)=option{");
            if (present) try out.print("{d}", .{value});
            try out.writeAll("},M:map(i64,string)=map{0=>\"z\",2=>\"t\"}}\nK:kit=kit{}\n");
            try out.print("Value:i64=Attempt(K.A[0],-1)*1000+K.A.Length*100+Attempt(K.O?,-1)+Attempt(Block{{V:=K.M[{d}];V.Length*7}},-2)*10000", .{key});
            const found: i64 = if (key == 0 or key == 2) 7 else -2;
            return .{ .value = head * 1000 + @as(i64, @intCast(length)) * 100 + (if (present) value else -1) + found * 10000 };
        },
        // A default is a value: one that divides by zero where the program uses it ends the
        // run there, and an instance built in a region that fails is gone with it.
        246 => {
            const divisor = draw(c, 3);
            const limit = draw(c, 10);
            try out.print("cfg:=class<final><persistable>{{D:i64={d},N:i64={d}}}\nMake()<transacts><decides>:i64=Block{{C:=cfg{{}};Require[C.N>5];C.N}}\nValue:i64=Attempt(Make[],-1)*10+60/cfg{{}}.D", .{ divisor, limit });
            if (divisor == 0) return .{ .failed = .division_by_zero };
            return .{ .value = (if (limit > 5) limit else -1) * 10 + @divTrunc(60, divisor) };
        },
        // The rules (T3 to T5), each refused.
        247 => {
            try out.writeAll(choose(c, []const u8, &.{
                "p:=class<persistable>{X:i64=0}\nValue:i64=1",
                "p:=class<final><unique><persistable>{X:i64=0}\nValue:i64=1",
                "b:=class{X:i64=0}\np:=class<final><persistable>(b){}\nValue:i64=1",
                "p[t:type]:=struct<persistable>{V:t}\nValue:i64=1",
                "p:=class<final><persistable>{var X:i64=0}\nValue:i64=1",
                "p:=struct<persistable>{var X:i64=0}\nValue:i64=1",
                "q:=struct{X:i64=0}\np:=struct<persistable>{Q:q=q{}}\nValue:i64=1",
                "p:=struct<persistable>{X:any=any(1)}\nValue:i64=1",
                "M:i64=2\np:=struct<persistable>{X:i64=M}\nValue:i64=1",
                "p:=struct<persistable>{X:i64=1+1}\nValue:i64=1",
                "F()<computes>:i64=1\np:=struct<persistable>{X:i64=F()}\nValue:i64=1",
                "p:=struct<persistable>{M:map(i64,i64)=map{1=>1,1=>2}}\nValue:i64=1",
                "p:=struct<persistable><persistable>{X:i64=0}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // `persistable` is a specifier, not a reserved word: a struct, a function and a field
        // of the name keep their meaning.
        248 => {
            const n = draw(c, 50);
            switch (draw(c, 3)) {
                0 => try out.print("persistable:=struct{{N:i64={d}}}\nValue:i64=persistable{{}}.N+{d}", .{ n, offset }),
                1 => try out.print("persistable(A:i64)<computes>:i64=A+{d}\nValue:i64=persistable({d})", .{ offset, n }),
                else => try out.print("p:=struct<persistable>{{persistable:i64={d}}}\nValue:i64=p{{}}.persistable+{d}", .{ n, offset }),
            }
            return .{ .value = n + offset };
        },
        // Persistable structs compare as structs do: a zero of either sign is one key.
        249 => {
            const sign_left = draw(c, 2) == 0;
            const sign_right = draw(c, 2) == 0;
            const scale = 1 + draw(c, 9);
            try out.print("pt:=struct<persistable>{{X:float={s}0.0,K:i64={d}}}\nM:map(pt,i64)=map{{pt{{}}=>1}}\nValue:i64=Attempt(M[pt{{X:={s}0.0}}],0)*{d}+If(pt{{}}==pt{{X:=0.0}},1,0)", .{ if (sign_left) "-" else "", scale, if (sign_right) "-" else "", scale });
            return .{ .value = scale + 1 };
        },
        // ---- Recovery (RFC-0086, P2.5). Every case below is also run journaled, crashed at a
        // commit point it draws, its journal torn after it, and resumed: the run again is served
        // what was sealed, its sealed actions are compared rather than written, and it must end as
        // the uninterrupted run did and leave its journal byte for byte. Regions three deep with
        // `Print`, a writer and a draw, which the resumed run draws again from the header's seed.
        250 => {
            const f1 = draw(c, 2) == 0;
            const f2 = draw(c, 2) == 0;
            const bound = 2 + draw(c, 50);
            try out.print("Value:i64=Attempt(Block{{L:=OpenWriter[\"log\"];Print(\"a\");X:=Attempt(Block{{D:=GetRandomInt(1,{d});L.WriteLine(\"d {{D}}\");Require[{s}];D}},0);Print(\"x {{X}}\");Require[{s}];X+10}},0)+{d}\nAfter:tuple()=Print(\"z\")", .{ bound, word(f2), word(f1), offset });
            var stream: Stream = .{};
            const d = stream.integer(1, bound);
            const x: i64 = if (f2) d else 0;
            var model: Effects = .{ .value = (if (f1) x + 10 else 0) + offset, .draws = stream.position };
            if (f1) {
                model.lineOn(0, "a", .{});
                if (f2) model.lineOn(2, "d {d}", .{d});
                model.lineOn(0, "x {d}", .{x});
                model.seal();
            }
            model.lineOn(0, "z", .{});
            model.seal();
            model.discarded = (if (f2) @as(u64, 0) else 1) + (if (f1) @as(u64, 0) else 2 + @as(u64, if (f2) 1 else 0));
            return .{ .effects = model };
        },
        // A loop of commit points, crashed between any two of them.
        251 => {
            const n: usize = @intCast(2 + draw(c, 8));
            try out.print("Out:[]tuple()=For(I:1..{d},Print(\"i{{I}}\"))\nValue:i64=Out.Length+{d}", .{ n, offset });
            var model: Effects = .{ .value = @as(i64, @intCast(n)) + offset };
            for (1..n + 1) |i| {
                model.line("i{d}", .{i});
                model.seal();
            }
            return .{ .effects = model };
        },
        // A region left by `Return` commits at the exit; resumed past it, the run takes the same
        // exit again.
        252 => {
            const n = draw(c, 3);
            try out.print("F(N:i64)<transacts>:i64=Block{{Attempt(Block{{Print(\"in {{N}}\");If(N>0,Return(N),0)}},0);Print(\"after {{N}}\");0}}\nValue:i64=F({d})+F(0)+{d}", .{ n, offset });
            var model: Effects = .{ .value = n + offset };
            model.line("in {d}", .{n});
            model.seal();
            if (n == 0) {
                model.line("after 0", .{});
                model.seal();
            }
            model.line("in 0", .{});
            model.seal();
            model.line("after 0", .{});
            model.seal();
            return .{ .effects = model };
        },
        // A task that wakes at a later second and reads the clock: the readings sealed before the
        // cut are served from the journal, and the rest are the world's, one per tick (I5).
        253 => {
            const waits = [2]u64{ @intCast(1 + draw(c, 3)), @intCast(4 + draw(c, 2)) };
            try out.print("A:tuple()=Print(\"a {{GetSecondsSinceEpoch()}}\")\nLater(W:float)<transacts><suspends>:void=Block{{Sleep(W);Print(\"b {{GetSecondsSinceEpoch()}}\")}}\nT0:task(void)=Spawn{{Later({d}.0)}}\nT1:task(void)=Spawn{{Later({d}.0)}}\nValue:i64={d}", .{ waits[0], waits[1], offset });
            var model: Effects = .{ .value = offset };
            var clock: SeenClock = .{};
            model.line("a {d}", .{clock.at(0)});
            model.seal();
            for (waits) |wait| {
                model.line("b {d}", .{clock.at(wait * 60)});
                model.seal();
            }
            model.inputs = clock.entries;
            return .{ .effects = model };
        },
        // A fatal error after commit points: resumed, the run ends with it again, at the node.
        254 => {
            const divisor = draw(c, 2);
            const lines: usize = @intCast(1 + draw(c, 3));
            try out.print("K:[]tuple()=For(I:1..{d},Print(\"kept {{I}}\"))\nZero:i64={d}\nBad:i64=Attempt(Block{{Print(\"pending\");1/Zero}},0)\nValue:i64={d}+Bad", .{ lines, divisor, offset });
            if (divisor == 0) return .{ .failed = .division_by_zero };
            var model: Effects = .{ .value = offset + 1 };
            for (1..lines + 1) |i| {
                model.line("kept {d}", .{i});
                model.seal();
            }
            model.line("pending", .{});
            model.seal();
            return .{ .effects = model };
        },
        // Lines read and written in regions: the sealed lines are served from the journal, and
        // the reader goes on past them (R6); a line equal to the one drawn fails its region.
        255 => {
            const calls: usize = @intCast(1 + draw(c, 8));
            const refused = draw(c, 6);
            try out.print("Copy(R:reader,W:writer)<transacts><decides>:void=Block{{L:=R.ReadLine[];W.WriteLine(\"got {{L}}\");Print(\"seen\");Require[L!=\"c{d}\"]}}\n", .{refused});
            var model: Effects = .{ .value = offset };
            var lines: SeenLines = .{};
            for (0..calls) |index| {
                try out.print("V{d}:i64=Attempt(Block{{R:=OpenReader[\"config\"];W:=OpenWriter[\"log\"];Copy[R,W];1}},0)\n", .{index});
                const line = lines.take() orelse continue;
                var name: [8]u8 = undefined;
                if (std.mem.eql(u8, line, std.fmt.bufPrint(&name, "c{d}", .{refused}) catch unreachable)) {
                    model.discarded += 2;
                    continue;
                }
                model.lineOn(2, "got {s}", .{line});
                model.lineOn(0, "seen", .{});
                model.seal();
                model.value += 1;
            }
            try out.print("Value:i64={d}", .{offset});
            for (0..calls) |index| try out.print("+V{d}", .{index});
            model.inputs = lines.reads;
            return .{ .effects = model };
        },
        // Recovery is the host's: the language gains no form for it, and the names of its options
        // are no names a program can use.
        256 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Value:i64=Resume()",
                "Value:i64=Abandon[]",
                "X:i64=1\nValue:i64=--resume",
                "F(W:writer)<reads>:void=W.WriteLine(\"x\")\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0082, P3.8.
        // The Book's 14:1086: a task counts in a `For` that waits a tick an iteration; its
        // creator waits `k` ticks and cancels it. The loop makes one step a tick, the first at
        // tick 0, and the task is asked before its next, or has finished; its `Defer` runs as it
        // unwinds, after the creator has gone on, or as it completes, before.
        257 => {
            const n = 1 + draw(c, 6);
            const k = draw(c, 8);
            try out.print("var Steps:i64=0\nWork()<transacts><suspends>:void=Block{{Defer{{Print(\"w\")}};For(I:0..{d},Block{{set Steps=Steps+1;NextTick()}})}}\nMain()<transacts><suspends>:void=Block{{T:=Spawn{{Work()}};For(J:1..{d},NextTick());T.Cancel();Print(\"s{{Steps}}\")}}\nP:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ n - 1, k, offset });
            var model: Effects = .{ .value = offset };
            if (n > k) {
                model.line("s{d}", .{k + 1});
                model.line("w", .{});
            } else {
                model.line("w", .{});
                model.line("s{d}", .{n});
            }
            return .{ .effects = model };
        },
        // A filter, a binding and a carried local across the waits: the iterations the filter
        // keeps add their binding to the local, and the loop's array has one element for each.
        258 => {
            const n = 1 + draw(c, 7);
            const skip = draw(c, 8);
            const m = 1 + draw(c, 9);
            try out.print("Run()<transacts><suspends>:i64=Block{{var T:i64=0;R:=For(I:0..{d},I!={d},J:=I*{d},Block{{set T=T+J;NextTick();J+1}});Print(\"v{{T}} {{R.Length}}\");T}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ n - 1, skip, m, offset });
            var model: Effects = .{ .value = offset };
            var total: i64 = 0;
            var kept: i64 = 0;
            var i: i64 = 0;
            while (i < n) : (i += 1) if (i != skip) {
                total += i * m;
                kept += 1;
            };
            model.line("v{d} {d}", .{ total, kept });
            return .{ .effects = model };
        },
        // Two tasks, each a loop that waits a tick an iteration: one with two generators, which
        // started first and so goes first at every tick, then the other. The schedule is worked
        // out again here.
        259 => {
            const p = 1 + draw(c, 3);
            const q = 1 + draw(c, 5);
            try out.print("A()<transacts><suspends>:void=For(I:1..2,J:1..{d},Block{{Print(\"a{{I}}{{J}}\");NextTick()}})\nB()<transacts><suspends>:void=For(X:array{{", .{p});
            for (0..@intCast(q)) |index| try out.print("{s}{d}", .{ if (index != 0) "," else "", index + 1 });
            try out.print("}},Block{{Print(\"b{{X}}\");NextTick()}})\nTA:task(void)=Spawn{{A()}}\nTB:task(void)=Spawn{{B()}}\nValue:i64={d}", .{offset});
            var model: Effects = .{ .value = offset };
            var tick: i64 = 0;
            while (tick < @max(2 * p, q)) : (tick += 1) {
                if (tick < 2 * p) model.line("a{d}{d}", .{ @divTrunc(tick, p) + 1, @mod(tick, p) + 1 });
                if (tick < q) model.line("b{d}", .{tick + 1});
            }
            return .{ .effects = model };
        },
        // A `Return` from a loop that waits: the iterations before it print, the one that returns
        // does not, and the function's value is the returned one, or the value after the loop.
        260 => {
            const n = 1 + draw(c, 6);
            const k = draw(c, 8);
            try out.print("Find()<transacts><suspends>:i64=Block{{For(I:0..{d},Block{{If(I=={d},Return(I*10+{d}),0);Print(\"i{{I}}\");NextTick()}});-1}}\nRun()<transacts><suspends>:void=Block{{R:=Find();Print(\"r{{R}}\")}}\nP:task(void)=Spawn{{Run()}}\nValue:i64={d}", .{ n - 1, k, b, offset });
            var model: Effects = .{ .value = offset };
            var i: i64 = 0;
            while (i < @min(n, k)) : (i += 1) model.line("i{d}", .{i});
            if (k < n) model.line("r{d}", .{k * 10 + b}) else model.line("r-1", .{});
            return .{ .effects = model };
        },
        // A fatal error after a wait in a loop ends the run: no region of an iteration is there
        // to take it back, and none would.
        261 => {
            const n = 1 + draw(c, 6);
            const pole = draw(c, 8);
            try out.print("Run()<transacts><suspends>:void=For(I:0..{d},I>=0,Block{{NextTick();Print(\"q{{60/(I-{d})}}\")}})\nP:task(void)=Spawn{{Run()}}\nValue:i64={d}", .{ n - 1, pole, offset });
            if (pole < n) return .{ .failed = .division_by_zero };
            var model: Effects = .{ .value = offset };
            var i: i64 = 0;
            while (i < n) : (i += 1) model.line("q{d}", .{@divTrunc(60, i - pole)});
            return .{ .effects = model };
        },
        // A task cancelled in the iteration it sleeps in, `k` and a half seconds in: each earlier
        // iteration ran its `Defer` as its body ended; the one cancelled runs its own, then the
        // function's. Ten iterations end before a request at ten and a half seconds or later.
        262 => {
            const k = draw(c, 12);
            try out.print("Work()<transacts><suspends>:void=Block{{Defer{{Print(\"f\")}};For(I:0..9,J:=I,Block{{Defer{{Print(\"d{{J}}\")}};Print(\"s{{I}}\");Sleep(1.0)}})}}\nMain()<transacts><suspends>:void=Block{{T:=Spawn{{Work()}};Sleep({d}.5);T.Cancel()}}\nP:task(void)=Spawn{{Main()}}\nValue:i64={d}", .{ k, offset });
            var model: Effects = .{ .value = offset };
            var i: i64 = 0;
            while (i < @min(k + 1, 10)) : (i += 1) {
                model.line("s{d}", .{i});
                model.line("d{d}", .{i});
            }
            model.line("f", .{});
            return .{ .effects = model };
        },
        // What a loop whose body suspends may not have: a clause or a body that can fail, a site
        // in a clause, a region or a `Defer` around its site, or a place at the root.
        263 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Xs:[]i64=array{1}\nF()<transacts><suspends>:[]i64=For(I:0..1,Y:=Xs[I],Block{NextTick();Y})\nValue:i64=1",
                "Xs:[]i64=array{1}\nF()<transacts><suspends>:[]i64=For(I:0..1,Xs[I]>0,Block{NextTick();I})\nValue:i64=1",
                "Ys:[][]i64=array{array{1}}\nF()<transacts><suspends>:[]i64=For(I:0..1,J:Ys[I],Block{NextTick();J})\nValue:i64=1",
                "Xs:[]i64=array{1}\nF()<transacts><suspends>:[]i64=For(I:0..1,Block{NextTick();Xs[I]})\nValue:i64=1",
                "W()<transacts><suspends>:i64=Block{Sleep(1.0);1}\nF()<transacts><suspends>:[]i64=For(I:0..1,W()>0,I)\nValue:i64=1",
                "W()<transacts><suspends>:i64=Block{Sleep(1.0);1}\nF()<transacts><suspends>:[]i64=Attempt(For(I:0..1,W()),array{})\nValue:i64=1",
                "W()<transacts><suspends>:i64=Block{Sleep(1.0);1}\nF()<transacts><suspends>:[]i64=For(I:0..1,Block{Defer{X:=W()};I})\nValue:i64=1",
                "W()<transacts><suspends>:i64=Block{Sleep(1.0);1}\nA:[]i64=For(I:0..1,W())\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0087, P5.4: session cells. A module `var` of type `weak_map(session, V)` is
        // read as `X[K]` and set as `set X[K] = V`, one key at a time; the run has one session.
        // The Book's 16:620: a per-session counter, incremented by calls that stop at a limit,
        // whose increment is undone with the call that fails.
        264 => {
            try out.writeAll("var C:weak_map(session,i64)=map{}\nInc(Limit:i64)<reads><writes><decides>:i64=Block{K:=GetSession();N:=Attempt(C[K],0)+1;set C[K]=N;Require[N<=Limit];N}\n");
            var counter: i64 = 0;
            var results: i64 = 0;
            const calls: usize = @intCast(1 + draw(c, 6));
            for (0..calls) |index| {
                const limit = draw(c, 6);
                try out.print("R{d}:i64=Attempt(Inc[{d}],-1)\n", .{ index, limit });
                if (counter + 1 <= limit) {
                    counter += 1;
                    results += counter;
                } else results -= 1;
            }
            try out.print("Value:i64=Attempt(C[GetSession()],0)*1000+{d}", .{offset});
            for (0..calls) |index| try out.print("+R{d}", .{index});
            return .{ .value = counter * 1000 + offset + results };
        },
        // An entry updated inside, through an index: a position past the end fails, and the
        // update in its region is undone with the rest of the region.
        265 => {
            var entry = [3]i64{ draw(c, 10), draw(c, 10), draw(c, 10) };
            try out.print("var A:weak_map(session,[]i64)=map{{}}\nS:session=GetSession()\nset A[S]=array{{{d},{d},{d}}}\n", .{ entry[0], entry[1], entry[2] });
            const steps: usize = @intCast(1 + draw(c, 5));
            for (0..steps) |index| {
                const position = draw(c, 4);
                const value = draw(c, 10);
                try out.print("U{d}:i64=Attempt(Block{{set A[S][{d}]={d};1}},0)\n", .{ index, position, value });
                if (position < 3) entry[@intCast(position)] = value;
            }
            try out.print("Value:i64=Attempt(A[S][0]*10000+A[S][1]*100+A[S][2],-1)+{d}", .{offset});
            return .{ .value = entry[0] * 10000 + entry[1] * 100 + entry[2] + offset };
        },
        // Writes in regions that fail are undone, and the lines printed with them discarded.
        266 => {
            const limit = draw(c, 40);
            const steps: usize = @intCast(1 + draw(c, 4));
            try out.print("var W:weak_map(session,i64)=map{{}}\nStep(V:i64)<transacts><decides>:void=Block{{set W[GetSession()]=V;Print(\"s {{V}}\");Require[V<{d}]}}\n", .{limit});
            var model: Effects = .{ .value = 0 };
            var last: i64 = -1;
            for (0..steps) |index| {
                const value = draw(c, 60);
                try out.print("R{d}:i64=Attempt(Block{{Step[{d}];1}},0)\n", .{ index, value });
                if (value < limit) {
                    last = value;
                    model.line("s {d}", .{value});
                    model.value += 1;
                } else model.discarded += 1;
            }
            try out.print("Value:i64=Attempt(W[GetSession()],-1)*10+{d}", .{offset});
            for (0..steps) |index| try out.print("+R{d}", .{index});
            model.value += last * 10 + offset;
            return .{ .effects = model };
        },
        // A live variable reads the entry, and follows each write of it.
        267 => {
            const k = 1 + draw(c, 9);
            const n = draw(c, 50);
            const m = draw(c, 50);
            try out.print("var C:weak_map(session,i64)=map{{}}\nvar live D:i64=Attempt(C[GetSession()],-1)*{d}\nA:i64=D\nset C[GetSession()]={d}\nB:i64=D\nset C[GetSession()]={d}\nValue:i64=A*1000000+B*1000+D+{d}", .{ k, n, m, offset });
            return .{ .value = -k * 1000000 + n * k * 1000 + m * k + offset };
        },
        // A task writes the entry after its sleep; the creator reads it after `Await`.
        268 => {
            const k = draw(c, 50);
            const w = 1 + draw(c, 3);
            try out.print("var C:weak_map(session,i64)=map{{}}\nPut(V:i64)<reads><writes>:i64=Block{{set C[GetSession()]=V;V}}\nRun()<transacts><suspends>:i64=Block{{B:=Attempt(C[GetSession()],-1);T:=Spawn{{Sleep({d}.0);Put({d})}};T.Await();X:=Attempt(C[GetSession()],-1);Print(\"c {{B}} {{X}}\");X}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ w, k, offset });
            var model: Effects = .{ .value = offset };
            model.line("c -1 {d}", .{k});
            return .{ .effects = model };
        },
        // The value written is worked out first: a division by zero ends the run.
        269 => {
            const d = draw(c, 4);
            const n = draw(c, 50);
            try out.print("var C:weak_map(session,i64)=map{{}}\nS:session=GetSession()\nset C[S]={d}\nF(D:i64)<reads><writes>:i64=Block{{set C[S]=60/D;Attempt(C[S],-1)}}\nValue:i64=F({d})+Attempt(C[S],-1)", .{ n, d });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = 2 * @divTrunc(60, d) };
        },
        // A session cell named whole, set whole, made live or given entries, and its effects.
        270 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var C:weak_map(session,i64)=map{}\nD:weak_map(session,i64)=C\nValue:i64=1",
                "var C:weak_map(session,i64)=map{}\nset C=map{}\nValue:i64=1",
                "var C:weak_map(session,i64)=map{GetSession()=>1}\nValue:i64=1",
                "var live C:weak_map(session,i64)=map{}\nValue:i64=1",
                "var C:weak_map(session,i64)=map{}\nF()<computes>:i64=Attempt(C[GetSession()],0)\nValue:i64=F()",
                "var C:weak_map(session,i64)=map{}\nF()<reads>:i64=Block{set C[GetSession()]=1;1}\nValue:i64=F()",
                "var C:weak_map(session,i64)=map{}\nValue:i64=C[GetSession()]",
                "var C:weak_map(session,i64)=map{}\nValue:i64=Attempt(C[1],0)",
                "S:session=session{}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0085, I6: the closure forms of I1 to I5 composed.
        // A nested function with a default, an overloaded one and an `Fn` that calls the first
        // share one cell with a task body that calls both after its sleep.
        271 => {
            const n = draw(c, 10);
            const d = 1 + draw(c, 9);
            const k = draw(c, 9);
            const w = 1 + draw(c, 3);
            try out.print("Run()<transacts><suspends>:i64=Block{{var C:i64={d};Add(K:i64={d})<transacts>:i64=Set(C,C+K);Scale(K:i64)<transacts>:i64=Set(C,C*K);Scale(S:string)<transacts>:i64=Set(C,C*10);F:=Fn()<transacts>:i64{{Add()}};T:=Spawn{{Sleep({d}.0);Scale(\"x\");Add(K:={d})}};F();T.Await();Scale(2);Print(\"c {{C}}\");C}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ n, d, w, k, offset });
            var model: Effects = .{ .value = offset };
            model.line("c {d}", .{((n + d) * 10 + k) * 2});
            return .{ .effects = model };
        },
        // Both arms of a `Race` defer a call of one nested function: the winner's runs at its
        // end, the loser's as its landing when it is cancelled, on the cell of the function.
        272 => {
            const x = 1 + draw(c, 9);
            const y = 1 + draw(c, 9);
            const s1 = 1 + draw(c, 4);
            const s2 = 1 + draw(c, 4);
            try out.print("Run()<transacts><suspends>:i64=Block{{var L:i64=0;Note(D:i64)<transacts>:i64=Set(L,L*10+D);W:=Race(Block{{Defer{{Note({d})}};Sleep({d}.0);1}},Block{{Defer{{Note({d})}};Sleep({d}.0);2}});Print(\"w {{W}} {{L}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ x, s1, y, s2, offset });
            var model: Effects = .{ .value = offset };
            // The first arm registered first and wins a tie.
            if (s1 <= s2) model.line("w 1 {d}", .{x * 10 + y}) else model.line("w 2 {d}", .{y * 10 + x});
            return .{ .effects = model };
        },
        // A recursive nested function writes the cell at every level inside a region that fails
        // past a bound, which undoes every write; a division by zero afterwards ends the run.
        273 => {
            const n = 1 + draw(c, 8);
            const limit = draw(c, 40);
            const d = draw(c, 3);
            try out.print("F(N:i64,D:i64)<transacts>:i64=Block{{var C:i64=0;Sum(K:i64)<transacts>:i64=If(K<=0,C,Block{{Set(C,C+K);Sum(K-1)}});A:=Attempt(Block{{X:=Sum(N);Require[X<{d}];X}},-1);(A*1000+C)/D}}\nValue:i64=F({d},{d})", .{ limit, n, d });
            if (d == 0) return .{ .failed = .division_by_zero };
            const total = @divExact(n * (n + 1), 2);
            return .{ .value = @divTrunc(if (total < limit) total * 1001 else -1000, d) };
        },
        // A `Batch{}` body and a `When` body call a nested function with a default over the
        // creator's cell; the reaction runs when it starts and at the write of `G`.
        274 => {
            const k = draw(c, 9);
            const add = 1 + draw(c, 9);
            const g = 1 + draw(c, 9);
            try out.print("var G:i64=0\nRun()<transacts><suspends>:i64=Block{{var L:i64={d};Bump(D:i64=1)<transacts>:i64=Set(L,L+D);B:i64=Batch{{Bump({d});L}};W:task(void)=When(G,Bump(G));set G={d};Bump();Sleep(1.0);Print(\"l {{B}} {{L}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ k, add, g, offset });
            var model: Effects = .{ .value = offset };
            model.line("l {d} {d}", .{ k + add, k + add + g + 1 });
            return .{ .effects = model };
        },
        // A nested function kept in a module `var` outlives its frame with the cell, which a task
        // writes later; an `Fn` that only reads another local reads the variable (S8 before
        // Q1, RFC-0085 I13): the `set S=S+100` made after it was built.
        275 => {
            const n = draw(c, 10);
            const m = 2 + draw(c, 5);
            const w = 1 + draw(c, 4);
            const s = draw(c, 9);
            try out.print("var Keep:option(function<reads>(tuple(),i64))=option{{}}\nMake(N:i64)<transacts><suspends>:i64=Block{{var C:i64=N;var S:i64={d};Get()<reads>:i64=C;Snap:=Fn()<reads>:i64{{S}};set Keep=option{{Get}};T:=Spawn{{Sleep({d}.0);Set(C,C*{d})}};set S=S+100;Snap()}}\nRun()<transacts><suspends>:i64=Block{{Z:=Make({d});A:=Attempt(Keep?(),-1);Sleep(5.0);B:=Attempt(Keep?(),-1);Print(\"k {{Z}} {{A}} {{B}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ s, w, m, n, offset });
            var model: Effects = .{ .value = offset };
            model.line("k {d} {d} {d}", .{ s + 100, n, n * m });
            return .{ .effects = model };
        },
        // A `For` whose visits may fail assigns a local a nested function also writes: no loop
        // carries it (S2), so each visit sees the cell; a division by zero afterwards ends the run.
        276 => {
            const n = 1 + draw(c, 5);
            const limit = draw(c, 30);
            const d = draw(c, 3);
            try out.print("F(D:i64)<transacts>:i64=Block{{var X:i64=0;G()<transacts>:i64=Set(X,X+1);V:=For(I:1..{d},Block{{set X=X+I;G();Require[X<{d}];0}});X*10/D}}\nValue:i64=F({d})", .{ n, limit, d });
            if (d == 0) return .{ .failed = .division_by_zero };
            var x: i64 = 0;
            for (1..@as(usize, @intCast(n)) + 1) |i| {
                const next = x + @as(i64, @intCast(i)) + 1;
                if (next < limit) x = next;
            }
            return .{ .value = @divTrunc(x * 10, d) };
        },
        // What composing the forms still refuses: a guard that writes a local through a body's
        // captures, a guard that calls a nested function that writes the local, a read without
        // `<reads>` in a nested function a task's write shares, a default reading a local, a
        // nested function in a `Defer` of an arm, an assignment of an explicit capture in a body,
        // and of a nested function's parameter from its task body.
        277 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<transacts><suspends>:i64=Block{var X:i64=0;T:=Spawn{U:task(void)=When(Set(X,1),X);0};X}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "var G:i64=0\nF()<transacts><suspends>:i64=Block{var X:i64=0;Bump()<transacts>:i64=Set(X,X+1);U:task(i64)=Upon(Bump()>0,G);X}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{var X:i64=0;Get()<writes>:i64=X;T:=Spawn{Set(X,1)};Get()}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<transacts>:i64=Block{var X:i64=0;Add(K:i64=X)<transacts>:i64=Set(X,X+K);Add()}\nValue:i64=F()",
                "F()<transacts><suspends>:i64=Block{var X:i64=0;W:=Race(Block{Defer{G()<transacts>:i64=Set(X,1);0};Sleep(2.0);1},Block{Sleep(1.0);2});W}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{var X:i64=0;H:=Fn[Y:i64=X]()<transacts><suspends>:i64{Block{T:=Spawn{Set(Y,2)};T.Await()}};H()}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<transacts><suspends>:i64=Block{Inner(N:i64)<transacts><suspends>:i64=Block{T:=Spawn{Sleep(1.0);Set(N,3)};T.Await()};Inner(4)}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0087, P5.3: JSON (E1 to E10). A persistable struct written canonically (E2):
        // the text is the one worked out here, and reading it back gives the value (PM1).
        278 => {
            const level = draw(c, 2000) - 1000;
            const length: usize = @intCast(draw(c, 4));
            var elements: [3]i64 = undefined;
            var sum: i64 = 0;
            for (elements[0..length]) |*element| {
                element.* = draw(c, 200) - 100;
                sum += element.*;
            }
            const present = draw(c, 2) == 0;
            var text: [256]u8 = undefined;
            var written: std.Io.Writer = .fixed(&text);
            try written.print("{{\"$package_name\":\"/\",\"$class_name\":\"p\",\"x_A\":{d},\"x_B\":[", .{level});
            for (elements[0..length], 0..) |element, index| try written.print("{s}{d}", .{ if (index == 0) "" else ",", element });
            try written.writeAll("],\"x_C\":");
            if (present) try written.print("{{\"\":{d}}}", .{offset}) else try written.writeAll("false");
            try written.writeAll("}");
            try out.writeAll("p:=struct<persistable>{A:i64=0,B:[]i64=array{},C:option(i64)=option{}}\nV:p=p{A:=");
            try out.print("{d},B:=array{{", .{level});
            for (elements[0..length], 0..) |element, index| try out.print("{s}{d}", .{ if (index == 0) "" else ",", element });
            try out.writeAll("},C:=option{");
            if (present) try out.print("{d}", .{offset});
            try out.writeAll("}}\nT:string=ToJson(V)\nSame:i64=If(T==");
            try forbicString(out, written.buffered());
            try out.writeAll(",1,0)\nBack:p=Attempt(FromJson[p][T],p{A:=-1})\nValue:i64=Same*1000000+Back.A*1000+Attempt(Back.C?,0)+Back.B.Length*10+");
            try out.print("{d}", .{sum});
            return .{ .value = 1000000 + level * 1000 + (if (present) offset else 0) + @as(i64, @intCast(length)) * 10 + sum };
        },
        // A text with members in any order, whitespace, and fields left out, which take their
        // defaults (E3, 17:352); metadata may be absent.
        279 => {
            const given_a = draw(c, 2) == 0;
            const given_b = draw(c, 2) == 0;
            const a_value = draw(c, 100);
            const flip = draw(c, 2) == 0;
            const meta = draw(c, 2) == 0;
            var text: [256]u8 = undefined;
            var written: std.Io.Writer = .fixed(&text);
            try written.writeAll(" { ");
            var any = false;
            const parts = [_]?[]const u8{
                if (meta) "\"$class_name\" : \"q\"" else null,
                if (given_a) "\"x_A\":" else null,
                if (given_b) "\"x_B\": \"b\"" else null,
            };
            const order = if (flip) [_]usize{ 2, 1, 0 } else [_]usize{ 0, 1, 2 };
            for (order) |index| if (parts[index]) |part| {
                if (any) try written.writeAll(" ,\n");
                any = true;
                try written.writeAll(part);
                if (index == 1) try written.print("{d}", .{a_value});
            };
            try written.writeAll(" } ");
            try out.print("q:=struct<persistable>{{A:i64={d},B:string=\"d\"}}\nR:q=Attempt(FromJson[q][", .{offset});
            try forbicString(out, written.buffered());
            try out.writeAll("],q{A:=-1})\nValue:i64=R.A*10+If(R.B==\"b\",1,2)");
            return .{ .value = (if (given_a) a_value else offset) * 10 + (if (given_b) @as(i64, 1) else 2) };
        },
        // A text that breaks one rule of E3 decodes to nothing: the fallback.
        280 => {
            const texts = [_][]const u8{
                "{\"x_A\":1,\"x_A\":2}",
                "{\"x_Z\":1}",
                "{\"x_A\":1.5}",
                "{\"x_A\":9223372036854775808}",
                "{\"$class_name\":\"other\"}",
                "{\"$package_name\":\"/x\"}",
                "{\"x_A\":1} 2",
                "[1]",
                "{\"x_A\":\"1\"}",
                "{\"x_B\":\"\\ud800\"}",
                "{\"x_N\":{\"\":1,\"\":2}}",
                "{\"x_N\":{\"x\":1}}",
            };
            const index: usize = @intCast(draw(c, texts.len + 1));
            try out.print("q:=struct<persistable>{{A:i64=0,B:string=\"\",N:option(i64)=option{{}}}}\nValue:i64=Attempt(FromJson[q][", .{});
            try forbicString(out, if (index == texts.len) "{\"x_A\":5}" else texts[index]);
            try out.print("].A,{d})", .{offset});
            return .{ .value = if (index == texts.len) 5 else offset };
        },
        // Instances a decode builds in a region that fails are gone with it; a chain is built
        // from its innermost link (E4), and encoded again canonically.
        281 => {
            const links: usize = @intCast(1 + draw(c, 4));
            const threshold = draw(c, 6);
            var text: [512]u8 = undefined;
            var written: std.Io.Writer = .fixed(&text);
            for (0..links) |index| {
                try written.print("{{\"x_L\":{d},\"x_Next\":", .{index});
                if (index + 1 == links) try written.writeAll("false") else try written.writeAll("{\"\":");
            }
            for (0..links) |index| try written.writeAll(if (index == 0) "}" else "}}");
            try out.writeAll("n:=class<final><persistable>{L:i64=0,Next:option(n)=option{}}\nDepth(X:n)<reads>:i64=1+Attempt(Depth(X.Next?),0)\nMake(T:string)<transacts><decides>:i64=Block{X:=FromJson[n][T];D:=Depth(X);Require[D>");
            try out.print("{d}];D}}\nT:string=", .{threshold});
            try forbicString(out, written.buffered());
            try out.writeAll("\nValue:i64=Attempt(Make[T],-1)*100+Attempt(Block{X:=FromJson[n][T];Require[ToJson(X).Length>0];1},0)");
            const depth: i64 = @intCast(links);
            return .{ .value = (if (depth > threshold) depth else -1) * 100 + 1 };
        },
        // A decoded value is a value: one that divides by zero where the program uses it ends
        // the run there.
        282 => {
            const divisor = draw(c, 3);
            try out.print("D:i64=Attempt(FromJson[i64][\"{d}\"],1)\nValue:i64=60/D+{d}", .{ divisor, offset });
            if (divisor == 0) return .{ .failed = .division_by_zero };
            return .{ .value = @divTrunc(60, divisor) + offset };
        },
        // The forms' refusals: a type that is not persistable, a decode outside a failure
        // context, and the effects a class needs (E1, E4).
        283 => {
            try out.writeAll(choose(c, []const u8, &.{
                "q:=struct{A:i64=0}\nT:string=ToJson(q{})\nValue:i64=1",
                "Value:i64=Attempt(Block{FromJson[any][\"1\"];1},0)",
                "F(X:i64)<computes>:i64=X\nT:string=ToJson(F)\nValue:i64=1",
                "Value:i64=FromJson[i64][\"1\"]",
                "c:=class<final><persistable>{A:i64=0}\nF(X:c)<computes>:string=ToJson(X)\nValue:i64=1",
                "c:=class<final><persistable>{A:i64=0}\nF(T:string)<reads><decides>:c=FromJson[c][T]\nValue:i64=1",
                "Value:i64=Attempt(Block{FromJson[i64][1];1},0)",
                "T:string=ToJson(1,2)\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // The names yield: a function, a local and a parameter named ToJson or FromJson are what
        // the program declares, and `ToJson` of an i64 is its decimal text elsewhere.
        284 => {
            const n = draw(c, 1000);
            switch (draw(c, 4)) {
                0 => try out.print("ToJson(X:i64)<computes>:i64=X+{d}\nValue:i64=ToJson({d})", .{ offset, n }),
                1 => try out.print("FromJson(X:i64)<computes><decides>:i64=X+{d}\nValue:i64=Attempt(FromJson[{d}],0)", .{ offset, n }),
                2 => try out.print("F(ToJson:function(tuple(i64),i64))<computes>:i64=ToJson({d})\nG(X:i64)<computes>:i64=X+{d}\nValue:i64=F(G)", .{ n, offset }),
                else => try out.print("T:string=ToJson({d})\nValue:i64=T.Length*0+Attempt(FromJson[i64][T],0)+{d}", .{ n, offset }),
            }
            return .{ .value = n + offset };
        },
        // ---- RFC-0085, I14 (RFC-0084, P4.8): live locals. A local `var` that a guard names or
        // that is a live target is shared (S1b, S1c), and its cell carries a live record as a
        // module cell does. `set live` on a local follows the locals its guard reads; a plain
        // `set` detaches it (L2).
        285 => {
            const n = draw(c, 9);
            const k = 1 + draw(c, 5);
            const d = draw(c, 7);
            const detach = draw(c, 2) == 0;
            try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=N;var Y:i64=0;set live Y=X*{d}+1;set X=X+{d};{s}set X=X+1;Y}}\nValue:i64=F({d})+{d}", .{ k, d, if (detach) "set Y=Y+100;" else "", n, offset });
            const after = (n + d) * k + 1;
            return .{ .value = offset + if (detach) after + 100 else (n + d + 1) * k + 1 };
        },
        // `var live` locals follow each other in a chain, declared in dependency order, and the
        // Book's converging cycle (15:297) over locals settles (X = -1, Y = 0 from 2, as the Book
        // says; X = 0, Y = -1 from 3), each record re-evaluated until both are stable.
        286 => {
            const v = draw(c, 9);
            const s = 1 + draw(c, 6);
            try out.print("F(V:i64)<transacts>:i64=Block{{var A:i64=0;var live B:i64=A+1;var live C:i64=B*2;set A=V;C}}\nG(S:i64)<transacts>:i64=Block{{var X:i64=S;var Y:i64=S;set live X=If(Y<0,0,Y-1);set live Y=If(X<0,0,X-1);X*10+Y}}\nValue:i64=F({d})*1000+G({d})+{d}", .{ v, s, offset });
            // X is attached first, reading the plain Y; Y's attachment then dirties X, and each
            // write of one dirties the other, until one is stable.
            var x: i64 = s - 1;
            var y: i64 = if (x < 0) 0 else x - 1;
            while (true) {
                const next_x: i64 = if (y < 0) 0 else y - 1;
                if (next_x == x) break;
                x = next_x;
                const next_y: i64 = if (x < 0) 0 else x - 1;
                if (next_y == y) break;
                y = next_y;
            }
            return .{ .value = (v + 1) * 2 * 1000 + x * 10 + y + offset };
        },
        // A region that fails takes back a `set live` on a local, its record and its value; one
        // that commits keeps them.
        287 => {
            const t = draw(c, 3);
            const later = draw(c, 9);
            try out.print("F(T:i64)<transacts>:i64=Block{{var X:i64=1;var Y:i64=0;R:=Attempt(Block{{set live Y=X+10;Require[X>T];1}},0);set X={d};Y*10+R}}\nValue:i64=F({d})+{d}", .{ later, t, offset });
            if (1 > t) return .{ .value = (later + 10) * 10 + 1 + offset };
            return .{ .value = offset };
        },
        // Reactions on locals: a `When` counts every write of a local, and the Book's 15:533,
        // `StopObserving`: an `Upon` cancelled before the write never runs, so `Y` stays 0;
        // not cancelled, it copies `X`.
        288 => {
            const writes: usize = @intCast(1 + draw(c, 5));
            const cancel = draw(c, 2) == 0;
            const x = 6 + draw(c, 9);
            try out.writeAll("Run()<transacts><suspends>:void=Block{var X:i64=0;var N:i64=0;W:task(void)=When(X,Set(N,N+1));");
            for (0..writes) |index| try out.print("set X={d};", .{index});
            try out.print("Print(\"n {{N}}\")}}\nStopObserving()<transacts><suspends>:void=Block{{var X:i64=0;var Y:i64=0;Watch:=Upon(X>5,Set(Y,X));{s}set X={d};Print(\"y {{Y}}\")}}\nP:task(void)=Spawn{{Run()}}\nQ:task(void)=Spawn{{StopObserving()}}\nValue:i64={d}", .{ if (cancel) "Watch.Cancel();" else "", x, offset });
            var model: Effects = .{ .value = offset };
            // It fires when it starts and at each write.
            model.line("n {d}", .{writes + 1});
            model.line("y {d}", .{if (cancel) 0 else x});
            return .{ .effects = model };
        },
        // A local's cell outlives the frame that declared it: a module var follows it through
        // its guard, and a closure the frame handed on writes it later.
        289 => {
            const k = 1 + draw(c, 5);
            const v = draw(c, 20);
            const d = draw(c, 3);
            try out.print("var M:i64=0\nMake()<transacts>:function<transacts>(tuple(i64),i64)=Block{{var L:i64=1;set live M=L*{d};Fn(V:i64)<transacts>:i64{{Set(L,V)}}}}\nS:function<transacts>(tuple(i64),i64)=Make()\nA:i64=M\nB:i64=S({d})\nValue:i64=A*1000+M+{d}/{d}", .{ k, v, offset, d });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = k * 1000 + v * k + @divTrunc(offset, d) };
        },
        // The Book's 15:325, `Diverge`, over locals: from X > 0 the cycle never settles and the
        // run ends with `live_unstable`; from X <= 0 both are 0.
        290 => {
            const x = draw(c, 5) - 2;
            try out.print("Diverge(S:i64)<transacts>:i64=Block{{var X:i64=S;var live Y:i64=If(X>0,X+1,0);set live X=Y;X*10+Y}}\nValue:i64=Diverge({d})+{d}", .{ x, offset });
            if (x > 0) return .{ .failed = .live_unstable };
            return .{ .value = offset };
        },
        // What stays refused: a type without a default, a live-only local, an immutable local,
        // a parameter, an explicit capture, a local whose type is a function, and the effects.
        291 => {
            try out.writeAll(choose(c, []const u8, &.{
                "point:=class{X:i64=0}\nF()<transacts>:i64=Block{var live P:point=point{};1}\nValue:i64=F()",
                "F()<transacts>:i64=Block{live L:i64=1;L}\nValue:i64=F()",
                "F()<transacts>:i64=Block{L:i64=1;set live L=2;L}\nValue:i64=F()",
                "F(P:i64)<transacts>:i64=Block{set live P=2;P}\nValue:i64=F(1)",
                "F()<transacts>:i64=Block{var X:i64=1;G:=Fn[Y:i64=X]()<transacts>:i64{Block{set live Y=2;Y}};G()}\nValue:i64=F()",
                "M(A:i64)<reads>:i64=A\nF()<transacts>:i64=Block{var X:M=1;X}\nValue:i64=F()",
                "F()<reads><writes>:i64=Block{var live X:i64=1;X}\nValue:i64=F()",
                "F()<writes>:i64=Block{var X:i64=1;var Y:i64=0;set live Y=X;0}\nValue:i64=F()",
            }));
            return .syntax_failure;
        },
        // ---- `pf2`. A generic function and a method of one name, each used.
        292 => {
            const m = draw(c, 4);
            try out.print("Put[T:type](V:T)<computes>:T{{ V }}\nbox := class{{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }}\nValue:i64 = Put[i64]({d}) * 1000 + box{{V := {d}}}.Put() + 60 / {d}", .{ a, b, m });
            if (m == 0) return .{ .failed = .division_by_zero };
            return .{ .value = a * 1000 + b + @divTrunc(60, m) };
        },
        // An `Fn` written in the body of a `For` of a generic function, which a specialization of
        // it runs for each of its visits.
        293 => {
            const n = 1 + draw(c, 4);
            const m = draw(c, 4);
            try out.print("G[T:type](X:T)<transacts>:i64{{ Block{{ Xs := For(I:1..{d}, Block{{ W := Fn(J:i64)<computes>:i64{{ 60 / J }}; W({d}) }}); Xs.Length * 1000 + Attempt(Xs[0], 0) }} }}\nValue:i64 = G[i64](1) + G[string](\"a\")", .{ n, m });
            if (m == 0) return .{ .failed = .division_by_zero };
            return .{ .value = 2 * (n * 1000 + @divTrunc(60, m)) };
        },
        // The namesakes the compiler refuses still are.
        294 => {
            try out.writeAll(choose(c, []const u8, &.{
                "box := class{ V:i64 = 0\n  Put()<reads>:i64 = Self.V }\nPut[T:type](V:T)<computes>:T{ V }\nValue:i64 = Put[i64](3)",
                "Put[T:type](V:T)<computes>:T{ V }\nValue:i64 = Put[i64](3)\n(N:i64).Put()<computes>:i64 = N + 1",
                "box := class{ V:i64 = 0\n  Put[T:type](X:T)<computes>:T{ X }\n  Put()<computes>:i64 = 7 }\nValue:i64 = box{}.Put[i64](3)",
            }));
            return .syntax_failure;
        },
        // ---- RFC-0087, P5.5: persistent cells. A module `var` of type `weak_map(persistent_key, V)` is
        // loaded where it is declared, for each key the host granted (`worldStore` holds what the
        // store has), and a write of an entry is saved as an action on the store channel.
        // A counter of the first cell: the entry of `alice` is loaded, `bob` has none; each add is
        // an action, committed in order with the region around the three calls.
        295 => {
            const n1 = draw(c, 20);
            const n2 = draw(c, 20);
            const n3 = draw(c, 20);
            try out.print("var C:weak_map(persistent_key,i64)=map{{}}\nAdd(K:persistent_key,N:i64)<reads><writes>:i64=Block{{set C[K]=Attempt(C[K],0)+N;N}}\nValue:i64=Attempt(Block{{A:=GetPersistentKey[\"alice\"];B:=GetPersistentKey[\"bob\"];Add(A,{d});Add(A,{d});Add(B,{d});Attempt(C[A],0)*1000+Attempt(C[B],0)}},-1)+{d}", .{ n1, n2, n3, offset });
            var model: Effects = .{ .value = (7 + n1 + n2) * 1000 + n3 + offset };
            const store_channel = @import("forbic").effects.store_channel;
            model.lineOn(store_channel, "{{\"cell\":\":C\",\"key\":\"alice\",\"value\":{d}}}", .{7 + n1});
            model.lineOn(store_channel, "{{\"cell\":\":C\",\"key\":\"alice\",\"value\":{d}}}", .{7 + n1 + n2});
            model.lineOn(store_channel, "{{\"cell\":\":C\",\"key\":\"bob\",\"value\":{d}}}", .{n3});
            model.inputs = 2;
            return .{ .effects = model };
        },
        // A write in a region that fails is undone with its action, and the line printed after it:
        // both are prepared, and both dropped. The entry starts as the store held it.
        296 => {
            const limit = draw(c, 40);
            const steps: usize = @intCast(1 + draw(c, 4));
            try out.print("var C:weak_map(persistent_key,i64)=map{{}}\nStep(V:i64)<transacts><decides>:void=Block{{set C[GetPersistentKey[\"alice\"]]=V;Print(\"s {{V}}\");Require[V<{d}]}}\n", .{limit});
            var model: Effects = .{ .value = 0 };
            const store_channel = @import("forbic").effects.store_channel;
            var last: i64 = 7;
            for (0..steps) |index| {
                const value = draw(c, 60);
                try out.print("R{d}:i64=Attempt(Block{{Step[{d}];1}},0)\n", .{ index, value });
                if (value < limit) {
                    last = value;
                    model.lineOn(store_channel, "{{\"cell\":\":C\",\"key\":\"alice\",\"value\":{d}}}", .{value});
                    model.line("s {d}", .{value});
                    model.value += 1;
                } else model.discarded += 2;
            }
            try out.print("Value:i64=Attempt(C[GetPersistentKey[\"alice\"]],-1)*10+{d}", .{offset});
            for (0..steps) |index| try out.print("+R{d}", .{index});
            model.value += last * 10 + offset;
            model.inputs = 2;
            return .{ .effects = model };
        },
        // Two cells, of two types, each loaded for both keys; a lookup of an entry the store lacks
        // fails, and the default stands in.
        297 => {
            const k = draw(c, 30);
            try out.print("var N:weak_map(persistent_key,i64)=map{{}}\nvar S:weak_map(persistent_key,string)=map{{}}\nValue:i64=Attempt(Block{{A:=GetPersistentKey[\"alice\"];B:=GetPersistentKey[\"bob\"];N[A]*100+S[A].Length*10+S[B].Length}},-1)+Attempt(Block{{N[GetPersistentKey[\"bob\"]]}},{d})+{d}", .{ k, offset });
            var model: Effects = .{ .value = 722 + k + offset };
            model.inputs = 4;
            return .{ .effects = model };
        },
        // A task that writes the entry after its sleep, and the creator that reads it after `Await`:
        // the action is committed with the write's region, before the line printed after it.
        298 => {
            const k = draw(c, 50);
            const w = 1 + draw(c, 3);
            try out.print("var C:weak_map(persistent_key,i64)=map{{}}\nPut(V:i64)<reads><writes><decides>:i64=Block{{set C[GetPersistentKey[\"alice\"]]=V;V}}\nRun()<transacts><suspends>:i64=Block{{B:=Attempt(C[GetPersistentKey[\"alice\"]],-1);T:=Spawn{{Sleep({d}.0);Attempt(Put[{d}],-1)}};T.Await();X:=Attempt(C[GetPersistentKey[\"alice\"]],-1);Print(\"c {{B}} {{X}}\");X}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ w, k, offset });
            var model: Effects = .{ .value = offset };
            const store_channel = @import("forbic").effects.store_channel;
            model.lineOn(store_channel, "{{\"cell\":\":C\",\"key\":\"alice\",\"value\":{d}}}", .{k});
            model.line("c 7 {d}", .{k});
            model.inputs = 2;
            return .{ .effects = model };
        },
        // An entry the store holds that is no value of the cell's type ends the run at the cell:
        // the first cell's entry for `alice` is the number 7, the second's the string "hi".
        299 => {
            const which = draw(c, 3);
            try out.writeAll(switch (which) {
                0 => "var A:weak_map(persistent_key,i64)=map{}\nvar B:weak_map(persistent_key,i64)=map{}\nValue:i64=1",
                1 => "var A:weak_map(persistent_key,string)=map{}\nValue:i64=1",
                else => "var A:weak_map(persistent_key,i64)=map{}\nvar B:weak_map(persistent_key,[]i64)=map{}\nValue:i64=1",
            });
            return .{ .failed = .load_invalid };
        },
        // What is refused: a value type that is not persistable, the cell named whole, a lookup
        // outside a failure context, a key made by a function that only computes, a key built or
        // held where it cannot be, a cell made live, and a class that is not persistable.
        300 => {
            try out.writeAll(choose(c, []const u8, &.{
                "var C:weak_map(persistent_key,rational)=map{}\nValue:i64=1",
                "var C:weak_map(persistent_key,i64)=map{}\nD:weak_map(persistent_key,i64)=C\nValue:i64=1",
                "var C:weak_map(persistent_key,i64)=map{}\nValue:i64=C[GetPersistentKey[\"alice\"]]",
                "K:persistent_key=GetPersistentKey[\"alice\"]\nValue:i64=1",
                "K:persistent_key=persistent_key{}\nValue:i64=1",
                "var C:weak_map(persistent_key,i64)=map{}\nF()<computes>:i64=Attempt(C[GetPersistentKey[\"alice\"]],0)\nValue:i64=F()",
                "var live C:weak_map(persistent_key,i64)=map{}\nValue:i64=1",
                "p:=class{N:i64}\nvar C:weak_map(persistent_key,p)=map{}\nValue:i64=1",
                "F()<reads><decides>:any=any(GetPersistentKey[\"alice\"])\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // Keys as values: equal by grant, map keys, held in an option; a name no key has fails.
        301 => {
            const names = [_][]const u8{ "alice", "bob", "carol" };
            const pick = draw(c, 3);
            try out.print("Pick()<reads><decides>:persistent_key=GetPersistentKey[\"{s}\"]\nM:option(map(persistent_key,i64))=option{{map{{GetPersistentKey[\"alice\"]=>3,GetPersistentKey[\"bob\"]=>4}}}}\nValue:i64=Attempt(Block{{K:=Pick[];Mm:=M?;Mm[K]*10}},-1)+{d}", .{ names[@intCast(pick)], offset });
            return .{ .value = (if (pick == 0) @as(i64, 30) else if (pick == 1) @as(i64, 40) else -1) + offset };
        },
        // ---- RFC-0085, I13 (Q1): one capture rule for every closure. A local `var` that any
        // closure form names is shared, and the closure refers to the variable. An `Fn` names a
        // local that the code around it writes after the `Fn` is built, and a loop writes it too:
        // it reads the variable (the Book's `Snap`, 51), where the snapshot gave `N + K`.
        302 => {
            const n = draw(c, 20);
            const d = 1 + draw(c, 9);
            const m = 1 + draw(c, 3);
            const k = draw(c, 9);
            try out.print("Run(N:i64)<transacts>:i64=Block{{var L:i64=N;R:=Fn(X:i64){{L+X}};set L=L+{d};For(I:1..{d},Block{{set L=L+I;0}});R({d})}}\nValue:i64=Run({d})", .{ d, m, k, n });
            return .{ .value = n + d + @divExact(m * (m + 1), 2) + k };
        },
        // A task body reads the local after its sleep, and so does a `Branch{}`; the creator
        // wrote it after both were built. Both see the write.
        303 => {
            const a0 = draw(c, 10);
            const b0 = 1 + draw(c, 9);
            const s = 1 + draw(c, 3);
            const t = 1 + draw(c, 3);
            try out.print("var Out:i64=0\nRun()<transacts><suspends>:i64=Block{{var X:i64={d};T:=Spawn{{Sleep({d}.0);X*10}};Branch{{Sleep({d}.0);Set(Out,X)}};set X=X+{d};R:=T.Await();Sleep(5.0);Print(\"t {{R}} {{Out}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ a0, s, t, b0, offset });
            var model: Effects = .{ .value = offset };
            model.line("t {d} {d}", .{ (a0 + b0) * 10, a0 + b0 });
            return .{ .effects = model };
        },
        // The arms of a `Sync`, a `Batch{}` body and the landing of a `Race` loser's `Defer`
        // only name the local: it is a cell now, and they read it.
        304 => {
            const x = draw(c, 10);
            const d = 1 + draw(c, 9);
            const s1 = 1 + draw(c, 3);
            const s2 = 1 + draw(c, 3);
            try out.print("var M:i64=0\nRun()<transacts><suspends>:i64=Block{{var X:i64={d};R:=Sync(Block{{Sleep({d}.0);X}},Block{{Sleep({d}.0);X+{d}}});B:i64=Batch{{X*2}};W:=Race(Block{{Defer{{set M=X*10}};Sleep(9.0);1}},Block{{Sleep(1.0);2}});A:=R(0);Z:=R(1);Print(\"a {{A}} {{Z}} {{B}} {{W}} {{M}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ x, s1, s2, d, offset });
            var model: Effects = .{ .value = offset };
            model.line("a {d} {d} {d} 2 {d}", .{ x, x + d, x * 2, x * 10 });
            return .{ .effects = model };
        },
        // Reaction bodies: an `Upon` and a `When` read the local the creator wrote after they
        // were made, when the write of `G` fires them.
        305 => {
            const a0 = draw(c, 10);
            const b0 = 1 + draw(c, 9);
            const g = 1 + draw(c, 5);
            try out.print("var Out:i64=0\nvar Seen:i64=0\nvar G:i64=0\nRun()<transacts><suspends>:i64=Block{{var X:i64={d};U:task(i64)=Upon(G>0,Set(Out,X*2));W:task(void)=When(G>0,Set(Seen,X));set X=X+{d};set G={d};Sleep(1.0);Print(\"u {{Out}} {{Seen}}\");0}}\nP:task(i64)=Spawn{{Run()}}\nValue:i64={d}", .{ a0, b0, g, offset });
            var model: Effects = .{ .value = offset };
            model.line("u {d} {d}", .{ (a0 + b0) * 2, a0 + b0 });
            return .{ .effects = model };
        },
        // What stays by value: a parameter, an immutable local and an explicit capture, which
        // reads the local where the `Fn` is built (`a`), though the code around writes it later.
        306 => {
            const p = draw(c, 10);
            const a0 = draw(c, 10);
            const b0 = 1 + draw(c, 9);
            try out.print("Run(P:i64)<transacts>:i64=Block{{var X:i64={d};K:=P+1;R:=Fn[C:i64=X,Q:i64=K+P](Y:i64)<computes>:i64{{C+Y+Q}};set X=X+{d};R(1)}}\nValue:i64=Run({d})", .{ a0, b0, p });
            return .{ .value = a0 + 1 + (p + 1) + p };
        },
        // A region that fails takes back a write the closure saw, and the run ends with a
        // division by zero once it reads the restored local.
        307 => {
            const a0 = draw(c, 10);
            const b0 = 1 + draw(c, 9);
            const limit = draw(c, 30);
            const d = draw(c, 3);
            try out.print("F(D:i64)<transacts>:i64=Block{{var X:i64={d};R:=Fn()<reads>:i64{{X}};A:=Attempt(Block{{set X=X+{d};V:=R();Require[V<{d}];V}},-1);(A*1000+R())/D}}\nValue:i64=F({d})", .{ a0, b0, limit, d });
            if (d == 0) return .{ .failed = .division_by_zero };
            const written = a0 + b0;
            return .{ .value = @divTrunc(if (written < limit) written * 1001 else -1000 + a0, d) };
        },
        // What Q1 makes loud or keeps refused: a closure that reads a local `var` in a function
        // without `<reads>`, in each form, and an explicit capture that is assigned.
        308 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F()<writes>:i64=Block{var X:i64=1;R:=Fn()<computes>:i64{X};R()}\nValue:i64=F()",
                "F()<writes><allocates><suspends>:i64=Block{var X:i64=1;T:=Spawn{X};T.Await()}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<writes><allocates><suspends>:i64=Block{var X:i64=1;R:=Sync(Block{Sleep(1.0);X},Block{Sleep(1.0);2});R(0)}\nP:task(i64)=Spawn{F()}\nValue:i64=1",
                "F()<writes>:i64=Block{var X:i64=1;B:i64=Batch{X+1};B}\nValue:i64=F()",
                "F()<transacts>:i64=Block{var X:i64=1;R:=Fn[C:i64=X]()<transacts>:i64{Set(C,2)};R()}\nValue:i64=F()",
            }));
            return .syntax_failure;
        },
        // ---- Control-flow completion (RFC-0090, B2).
        // An `If` without an else runs its arm for what it does, a binding condition too.
        309 => {
            const t = draw(c, 10);
            const u = draw(c, 20);
            const w = draw(c, 20);
            const i = draw(c, 4);
            const items = [_]i64{ draw(c, 9), draw(c, 9), draw(c, 9) };
            try out.print("var C:i64=0\nXs:[]i64=array{{{d},{d},{d}}}\nF(N:i64)<transacts>:void=If(N>{d},Set(C,C+N))\nG(I:i64)<transacts>:void=If(X:=Xs[I],Set(C,C+X*100))\nRun()<transacts>:i64=Block{{F({d});F({d});G({d});C}}\nValue:i64=Run()", .{ items[0], items[1], items[2], t, u, w, i });
            var value: i64 = 0;
            if (u > t) value += u;
            if (w > t) value += w;
            if (i < 3) value += items[@intCast(i)] * 100;
            return .{ .value = value };
        },
        // An `If` without an else in a region that fails: its write is taken back.
        310 => {
            const u = draw(c, 10);
            const t = draw(c, 10);
            const limit = draw(c, 10);
            try out.print("var C:i64=0\nRun()<transacts>:i64=Block{{R:=Attempt(Block{{If({d}>{d},Set(C,C+5));Require[{d}<{d}];1}},0);R*100+C}}\nValue:i64=Run()", .{ u, t, u, limit });
            if (u >= limit) return .{ .value = 0 };
            return .{ .value = 100 + @as(i64, if (u > t) 5 else 0) };
        },
        // A `For` without a generator: the body runs at most once.
        311 => {
            const i = draw(c, 4);
            const t = draw(c, 9);
            const items = [_]i64{ draw(c, 9), draw(c, 9), draw(c, 9) };
            try out.print("Xs:[]i64=array{{{d},{d},{d}}}\nR:[]i64=For(X:=Xs[{d}],X>{d},X*10)\nValue:i64=R.Length*1000+Attempt(R[0],-1)", .{ items[0], items[1], items[2], i, t });
            if (i < 3 and items[@intCast(i)] > t) return .{ .value = 1000 + items[@intCast(i)] * 10 };
            return .{ .value = -1 };
        },
        // A binding before the first generator feeds its range; when it fails, nothing runs.
        312 => {
            const i = draw(c, 4);
            const high = draw(c, 8);
            const items = [_]i64{ draw(c, 6), draw(c, 6), draw(c, 6) };
            try out.print("Sum:=native{{\"std.sum\"}}\nXs:[]i64=array{{{d},{d},{d}}}\nR:[]i64=For(Y:=Xs[{d}],N:Y..{d},N*10+Y)\nValue:i64=Sum(R)*100+R.Length", .{ items[0], items[1], items[2], i, high });
            if (i >= 3) return .{ .value = 0 };
            const y = items[@intCast(i)];
            var sum: i64 = 0;
            var length: i64 = 0;
            var n = y;
            while (n <= high) : (n += 1) {
                sum += n * 10 + y;
                length += 1;
            }
            return .{ .value = sum * 100 + length };
        },
        // A leading filter that writes and then fails undoes its write, and the loop never starts.
        313 => {
            const u = 1 + draw(c, 9);
            const limit = draw(c, 12);
            const n = draw(c, 5);
            try out.print("var C:i64=0\nRun()<transacts>:i64=Block{{R:=For(Block{{set C=C+{d};C<{d}}},N:1..{d},Block{{set C=C+1;N}});R.Length*100+C}}\nValue:i64=Run()", .{ u, limit, n });
            if (u >= limit) return .{ .value = 0 };
            return .{ .value = n * 100 + u + n };
        },
        // A division by zero in a leading binding is not a failure: it ends the run.
        314 => {
            const d = draw(c, 3);
            const t = draw(c, 12);
            try out.print("R:[]i64=For(X:=10/{d},X>{d},X)\nValue:i64=R.Length", .{ d, t });
            if (d == 0) return .{ .failed = .division_by_zero };
            return .{ .value = if (@divTrunc(10, d) > t) 1 else 0 };
        },
        // What the Book refuses: the value of an `If` without an else, an unreachable `Case` arm,
        // a `Case` that compares a float, and an exit from a `For` that starts with a filter.
        315 => {
            try out.writeAll(choose(c, []const u8, &.{
                "N:i64=3\nValue:i64=If(N>1,N)",
                "F(N:i64)<computes>:i64=Case(N,1=>10,1=>20,_=>0)\nValue:i64=F(1)",
                "F(X:float)<computes>:i64=Case(X,1.0=>1,_=>0)\nValue:i64=F(1.0)",
                "F(N:i64)<computes>:i64=Block{For(N>0,Return(1));2}\nValue:i64=F(1)",
                "Animal:=class{}\nDog:=class(Animal){}\nF(A:Animal)<transacts>:i64=Case(A,X:Animal=>1,D:Dog=>2,_=>0)\nValue:i64=F(Dog{})",
            }));
            return .syntax_failure;
        },
        // ---- Functions completion (RFC-0091, B3). Mutual recursion among module functions: a
        // body calls a function declared further down, in either order of declaration.
        316 => {
            const n = draw(c, 12);
            const even_first = draw(c, 2) == 0;
            const even = "IsEven(N:i64)<computes>:logic=If(N==0,true,IsOdd(N-1))\n";
            const odd = "IsOdd(N:i64)<computes>:logic=If(N==0,false,IsEven(N-1))\n";
            try out.print("{s}{s}Value:i64=If(IsEven({d}),{d},{d})", .{ if (even_first) even else odd, if (even_first) odd else even, n, offset, offset + 1 });
            return .{ .value = if (@mod(n, 2) == 0) offset else offset + 1 };
        },
        // The writes of a cycle of calls, and a failure deep in it that the attempt around the
        // first call takes back with all of them.
        317 => {
            const n = 1 + draw(c, 8);
            const fails = draw(c, 2) == 0;
            const at = 1 + draw(c, @intCast(n));
            try out.print("var Log:i64=0\nPing(N:i64)<transacts><decides>:i64=If(N<=0,Log,Block{{set Log=Log*2+1;Require[N!={d}];Pong[N-1]}})\nPong(N:i64)<transacts><decides>:i64=If(N<=0,Log,Block{{set Log=Log*2;Ping[N-1]}})\nA:i64=Attempt(Ping[{d}],-1)\nValue:i64=A*1000+Log", .{ if (fails) at else -1, n });
            // Ping writes at odd depths from the top (n, n-2, ...), Pong at the others.
            var log: i64 = 0;
            var depth = n;
            var ping = true;
            var failed = false;
            while (depth > 0) : (depth -= 1) {
                log = log * 2 + @intFromBool(ping);
                if (ping and fails and depth == at) {
                    failed = true;
                    break;
                }
                ping = !ping;
            }
            if (failed) return .{ .value = -1000 };
            return .{ .value = log * 1000 + log };
        },
        // A cycle that never reaches its base runs out of frames in both machines.
        318 => {
            try out.print("Down(N:i64)<computes>:i64=Up(N+1)+1\nUp(N:i64)<computes>:i64=Down(N)+{d}\nValue:i64=Down({d})", .{ offset, a });
            return .{ .failed = .call_depth_limit };
        },
        // What the forward call refuses: a value between the two functions, a later overload, a
        // transparent result, a default left out, and the root.
        319 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F(N:i64)<computes>:i64=G(N)\nX:i64=1\nG(N:i64)<computes>:i64=N\nValue:i64=F(1)",
                "F(N:i64)<computes>:i64=G(N)\nValue:i64=F(1)\nG(N:i64)<computes>:i64=N",
                "F(N:i64)<computes>:i64=G(N)\nG(N:i64)<computes>:i64=N\nG(N:float)<computes>:float=N\nValue:i64=F(1)",
                "F(N:i64)<computes>:i64=G(N)\nG(N:i64)<computes>:=N\nValue:i64=F(1)",
                "F(N:i64)<computes>:i64=G(N)\nG(N:i64,M:i64=2)<computes>:i64=N+M\nValue:i64=F(1)",
                "Value:i64=G(1)\nG(N:i64)<computes>:i64=N",
            }));
            return .syntax_failure;
        },
        // Parameters that destructure tuples, nested, typed on the names or the whole.
        320 => {
            const x = draw(c, 20);
            const y = draw(c, 20);
            const z = draw(c, 20);
            const annotated = draw(c, 2) == 0;
            if (annotated) {
                try out.print("F(A:i64,(B,(C,D)):tuple(i64,tuple(i64,i64)))<computes>:i64=A*1000+B*100+C*10+D\nValue:i64=F({d},tuple{{{d},tuple{{{d},{d}}}}})", .{ offset, x, y, z });
            } else {
                try out.print("F(A:i64,(B:i64,(C:i64,D:i64)))<computes>:i64=A*1000+B*100+C*10+D\nValue:i64=F({d},tuple{{{d},tuple{{{d},{d}}}}})", .{ offset, x, y, z });
            }
            return .{ .value = offset * 1000 + x * 100 + y * 10 + z };
        },
        // What a pattern refuses.
        321 => {
            try out.writeAll(choose(c, []const u8, &.{
                "F((A:i64))<computes>:i64=A\nValue:i64=1",
                "F((A,B))<computes>:i64=A\nValue:i64=1",
                "F((A,B:i64):tuple(i64,i64))<computes>:i64=A\nValue:i64=1",
                "F((A,B):tuple(i64,i64,i64))<computes>:i64=A\nValue:i64=1",
                "F((A:i64,A:i64))<computes>:i64=A\nValue:i64=1",
                "F((A:i64,B:i64)=tuple{1,2})<computes>:i64=A\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // `false`, the bottom type: a function of it stands in either arm, and ends the run
        // when it is called.
        322 => {
            const n = draw(c, 20) - 10;
            const leading = draw(c, 2) == 0;
            try out.writeAll("Fatal(M:string)<computes>:false=Err(M)\n");
            if (leading) try out.print("F(N:i64)<computes>:i64=If(N<0,Fatal(\"negative\"),N+{d})\n", .{offset}) else try out.print("F(N:i64)<computes>:i64=If(N>=0,N+{d},Fatal(\"negative\"))\n", .{offset});
            try out.print("Value:i64=F({d})", .{n});
            if (n < 0) return .{ .failed = .runtime_error };
            return .{ .value = n + offset };
        },
        // Type arguments read off the arguments of a generic call, and one they cannot give.
        323 => {
            const x = draw(c, 50);
            const y = draw(c, 50);
            if (draw(c, 4) == 0) {
                try out.writeAll(choose(c, []const u8, &.{
                    "Make[T:type](N:i64)<computes>:[]T{array{}}\nValue:i64=Make(1).Length",
                    "Same[T:type](X:T,Y:T)<computes>:T{X}\nValue:i64=Same(1,\"a\")",
                    "Pick[T:type](X:T)<computes><decides>:T{X}\nValue:i64=Attempt(Pick(1),0)",
                }));
                return .syntax_failure;
            }
            try out.print("Second[A:type,B:type](P:tuple(A,B))<computes>:B{{P(1)}}\nFirst[T:type](Xs:[]T,D:T)<computes>:T{{If(Xs.Length>0,ElementAt(Xs,0),D)}}\nValue:i64=Second(tuple{{\"s\",{d}}})+First(array{{{d}}},0)+{d}", .{ x, y, offset });
            return .{ .value = x + y + offset };
        },
        // ---- RFC-0092, B4: an override narrows its result. Through the base, dispatch reaches
        // the override, which builds on `Super`; through the subclass the narrower type is seen.
        324 => {
            const base_tag = draw(c, 50);
            const extra = 1 + draw(c, 9);
            const through_base = draw(c, 2) == 0;
            try out.print("Item:=class{{Tag:i64={d}}}\nTool:=class(Item){{Extra:i64={d}}}\nMaker:=class{{Make()<reads><allocates>:Item=Item{{}}}}\nSmith:=class(Maker){{Make<override>()<reads><allocates>:Tool=Tool{{Tag:=Super.Make().Tag+1}}}}\n", .{ base_tag, extra });
            if (through_base) {
                try out.print("M:Maker=Smith{{}}\nValue:i64=M.Make().Tag+{d}", .{offset});
                return .{ .value = base_tag + 1 + offset };
            }
            try out.print("Value:i64=Smith{{}}.Make().Extra*100+Smith{{}}.Make().Tag+{d}", .{offset});
            return .{ .value = extra * 100 + base_tag + 1 + offset };
        },
        // An override narrows its access: called through the base as before, and by the
        // methods of its class's subclasses.
        325 => {
            const one = draw(c, 20);
            const two = draw(c, 20);
            try out.print("Base:=class{{Get<public>()<computes>:i64={d}}}\nMid:=class(Base){{Get<override><protected>()<computes>:i64={d}}}\nLow:=class(Mid){{Twice()<computes>:i64=Self.Get()+Super.Get()}}\nB:Base=Low{{}}\nValue:i64=B.Get()*1000+Low{{}}.Twice()+{d}", .{ one, two, offset });
            return .{ .value = two * 1000 + two * 2 + offset };
        },
        // `Super{...}` builds a fresh instance of the superclass, whose state is its own.
        326 => {
            const start = draw(c, 30);
            const update = 31 + draw(c, 30);
            const given = draw(c, 2) == 0;
            try out.print("Counter:=class{{var N:i64={d}\nGet()<reads><allocates>:i64=Self.N}}\nFresh:=class(Counter){{Get<override>()<reads><allocates>:i64={s}.Get()}}\nX:Counter=Fresh{{}}\nset X.N={d}\nValue:i64=X.Get()*1000+X.N+{d}", .{ start, if (given) "Super{N:=7}" else "Super{}", update, offset });
            return .{ .value = (if (given) @as(i64, 7) else start) * 1000 + update + offset };
        },
        // The family of a castable base: the `<final_super>` class directly below it on the way
        // up from the instance, or a failure when that class is not marked.
        327 => {
            const marked = [_]bool{ draw(c, 2) == 0, draw(c, 2) == 0, draw(c, 2) == 0 };
            const pick = draw(c, 3);
            const deep = draw(c, 2) == 0;
            try out.print("Root:=class<castable>{{}}\nA0:=class{s}(Root){{}}\nA1:=class{s}(Root){{}}\nA2:=class{s}(Root){{}}\nD0:=class(A0){{}}\nD1:=class(A1){{}}\nD2:=class(A2){{}}\n", .{ if (marked[0]) "<final_super>" else "", if (marked[1]) "<final_super>" else "", if (marked[2]) "<final_super>" else "" });
            try out.print("Which(K:castable_subtype(Root),X0:A0,X1:A1,X2:A2)<computes>:i64=If(Attempt(Block{{K[X0];true}},false),0,If(Attempt(Block{{K[X1];true}},false),1,If(Attempt(Block{{K[X2];true}},false),2,9)))\nValue:i64=Attempt(Block{{K:=GetCastableFinalSuperClass[Root,{s}{d}{{}}];Which(K,A0{{}},A1{{}},A2{{}})}},-1)+{d}", .{ if (deep) "D" else "A", pick, offset });
            return .{ .value = (if (marked[@intCast(pick)]) pick else -1) + offset };
        },
        // A struct that states `<reads>` is built where the function may read, and a
        // `<computes>` one anywhere.
        328 => {
            const scale = draw(c, 40);
            const x = draw(c, 40);
            try out.print("var Scale:i64={d}\nPoint:=struct<computes>{{X:i64=0}}\nScaled:=struct<reads>{{F:i64=1}}\nMake()<reads>:Scaled=Scaled{{F:=Scale}}\nPure(V:i64)<computes>:Point=Point{{X:=V}}\nValue:i64=Make().F*100+Pure({d}).X+{d}", .{ scale, x, offset });
            return .{ .value = scale * 100 + x + offset };
        },
        // A failed region takes back an instance `Super{...}` built and a write; a run that
        // divides by a zero the family query gives ends.
        329 => {
            const n = draw(c, 20);
            const zero = draw(c, 2) == 0;
            try out.print("Counter:=class{{var N:i64={d}}}\nFresh:=class(Counter){{Make()<allocates>:Counter=Super{{}}}}\nRoot:=class<castable>{{}}\nAnchor:=class<final_super>(Root){{}}\nOther:=class(Root){{}}\nvar Kept:i64=0\nF:=Fresh{{}}\nTried:i64=Attempt(Block{{C:=F.Make();set Kept=C.N;Require[C.N>{d}];1}},2)\nD:i64=Attempt(Block{{GetCastableFinalSuperClass[Root,{s}{{}}];1}},0)\nValue:i64=Tried*100+Kept+{d}/D", .{ n, n, if (zero) "Other" else "Anchor", offset });
            if (zero) return .{ .failed = .division_by_zero };
            return .{ .value = 2 * 100 + 0 + @divTrunc(offset, 1) };
        },
        // What B4 refuses: a widening override, a class below a final_super_base class without
        // the mark, a final_super class after its base's family was asked for, a struct built
        // without the effect it states, and `Super{...}` in a class without a superclass.
        330 => {
            try out.writeAll(choose(c, []const u8, &.{
                "A:=class{}\nB:=class(A){}\nP:=class{Make()<allocates>:B=B{}}\nS:=class(P){Make<override>()<allocates>:A=A{}}\nValue:i64=1",
                "R:=class<final_super_base>{}\nC:=class(R){}\nValue:i64=1",
                "R:=class<castable>{}\nF(X:R)<computes><decides>:castable_subtype(R)=GetCastableFinalSuperClass[R,X]\nL:=class<final_super>(R){}\nValue:i64=1",
                "S:=struct<reads>{N:i64=1}\nF()<computes>:i64=S{}.N\nValue:i64=F()",
                "C:=class{Make()<allocates>:C=Super{}}\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // ---- `Profile(Tag, Body)` (RFC-0094, B6): the clock read, the body, the clock read and a
        // line. Tasks that sleep in two profiled steps each measure the recorded clock of the
        // world (held when it goes back, one reading per tick); a world with no number at second 7
        // ends the run where the second reading is taken.
        331 => {
            const bad = draw(c, 4) == 0;
            const tasks: usize = @intCast(1 + draw(c, 3));
            var waits: [3][2]u64 = undefined;
            try out.writeAll("Run(P:string,Q:string,X:float,Y:float)<transacts><suspends>:void=Block{Profile(P,Sleep(X));Profile(Q,Sleep(Y))}\n");
            for (waits[0..tasks], 0..) |*wait, index| {
                wait.* = .{ @intCast(1 + draw(c, 3)), @intCast(1 + draw(c, 3)) };
                if (bad and index == 0) wait[0] = 7;
                try out.print("T{d}:task(void)=Spawn{{Run(\"a{d}\",\"b{d}\",{d}.0,{d}.0)}}\n", .{ index, index, index, wait[0], wait[1] });
            }
            try out.print("Value:i64={d}", .{offset});
            if (bad) return .{ .failed = .input_invalid };
            var model: Effects = .{ .value = offset };
            var clock: SeenClock = .{};
            // Every task starts its first step at tick 0, in the order they were spawned; a timer
            // that falls due wakes its task, which ends a step, begins the next one in the same
            // tick and sets its timer. Timers due at one tick fire in the order they were set.
            var began: [3]i64 = undefined;
            var due: [3]u64 = undefined;
            var order: [3]u64 = undefined;
            var stage: [3]u8 = @splat(0);
            for (0..tasks) |index| {
                began[index] = clock.at(0);
                due[index] = waits[index][0] * 60;
                order[index] = index;
            }
            var counter: u64 = tasks;
            var live = tasks;
            while (live > 0) {
                var next: usize = tasks;
                for (0..tasks) |index| {
                    if (stage[index] == 2) continue;
                    if (next == tasks or due[index] < due[next] or (due[index] == due[next] and order[index] < order[next])) next = index;
                }
                const ended = clock.at(due[next]);
                model.line("profile {s}{d}: {d} s", .{ if (stage[next] == 0) "a" else "b", next, ended - began[next] });
                stage[next] += 1;
                if (stage[next] == 1) {
                    began[next] = clock.at(due[next]);
                    due[next] += waits[next][1] * 60;
                    order[next] = counter;
                    counter += 1;
                } else live -= 1;
            }
            model.inputs = clock.entries;
            return .{ .effects = model };
        },
        // What `Profile` refuses: arguments, types, the effects it needs, a body that is a
        // `Return`, a suspension where the function does not suspend, and the name as a value.
        332 => {
            try out.writeAll(choose(c, []const u8, &.{
                "A:i64=Profile(\"x\")\nValue:i64=1",
                "A:i64=Profile(\"x\",1,2)\nValue:i64=1",
                "A:i64=Profile(5,1)\nValue:i64=1",
                "A:i64=Profile\nValue:i64=1",
                "F()<computes>:i64=Profile(\"x\",1)\nValue:i64=1",
                "F()<reads>:i64=Profile(\"x\",1)\nValue:i64=1",
                "F()<transacts><predicts>:i64=Profile(\"x\",1)\nValue:i64=1",
                "var X:i64=0\nW:task(void)=When(Profile(\"g\",X)>0,Print(\"late\"))\nValue:i64=1",
                "F()<transacts>:i64=Profile(\"x\",Return(1))\nValue:i64=1",
                "F()<transacts>:float=Profile(\"x\",Block{Sleep(1.0);1.0})\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // A body that leaves, and a region that fails after the form: no line for either; one that
        // finishes and a region that holds show theirs. The clock is read once, at the root's tick.
        333 => {
            const n = draw(c, 8);
            const cut = draw(c, 8);
            const holds = draw(c, 2) == 0;
            try out.print("Early(N:i64)<transacts>:i64=Block{{Profile(\"e\",Block{{If(N<{d},Return(-1),false);N+{d}}})}}\n", .{ cut, offset });
            try out.print("R:i64=Attempt(Block{{Profile(\"r\",1);Require[{d}>{d}];1}},0)\nValue:i64=Early({d})", .{ n, if (holds) n - 1 else n + 1, n });
            var model: Effects = .{ .value = if (n < cut) -1 else n + offset };
            if (holds) model.line("profile r: 0 s", .{}) else model.discarded += 1;
            if (n >= cut) model.line("profile e: 0 s", .{});
            model.inputs = 1;
            return .{ .effects = model };
        },
        // ---- Book tightening (TASK-0109, B8). A `castable_concrete_subtype` value builds the
        // class it names with its defaults and tests an instance with the same value; a program
        // that divides by the test's answer ends the run where the test said no.
        334 => {
            const made = draw(c, 3);
            const asked = draw(c, 3);
            const divide = draw(c, 3) == 0;
            const numerator = 1 + draw(c, 50);
            try out.print("Base:=class<castable>{{N:i64={d}}}\nOne:=class<castable><concrete>(Base){{N<override>:i64={d}}}\nTwo:=class<castable><concrete>(Base){{N<override>:i64={d}}}\n" ++
                "Pairs:[]castable_concrete_subtype(Base)=array{{One,Two,One}}\n" ++
                "Build(M:castable_concrete_subtype(Base))<allocates>:Base=M{{}}\nIs(X:Base,K:castable_concrete_subtype(Base))<computes>:logic=Attempt(Block{{K[X];true}},false)\n" ++
                "M:castable_concrete_subtype(Base)=Attempt(Pairs[{d}],One)\nK:castable_concrete_subtype(Base)=Attempt(Pairs[{d}],Two)\nX:Base=Build(M)\nHit:i64=If(Is(X,K),1,0)\nValue:i64=X.N*100+Hit", .{ a, b, offset, made, asked });
            if (divide) try out.print("+{d}/Hit", .{numerator});
            const class_made: u64 = if (made == 1) 2 else 1;
            const class_asked: u64 = if (asked == 1) 2 else 1;
            const hit: i64 = if (class_made == class_asked) 1 else 0;
            if (divide and hit == 0) return .{ .failed = .division_by_zero };
            const n = if (class_made == 1) b else offset;
            return .{ .value = n * 100 + hit + (if (divide) numerator else 0) };
        },
        // What `castable_concrete_subtype` asks of its class and of its uses: castable and
        // concrete, a class bound, a failure context for the cast, the effects of building the
        // class and nothing in the braces, and no exchange with the metatypes it composes.
        335 => {
            try out.writeAll(choose(c, []const u8, &.{
                "Base:=class<castable>{}\nOdd:=class<castable>(Base){}\nK:castable_concrete_subtype(Base)=Odd\nValue:i64=1",
                "Root:=class{}\nLeaf:=class<concrete>(Root){}\nK:castable_concrete_subtype(Root)=Leaf\nValue:i64=1",
                "K:castable_concrete_subtype(i64)=i64\nValue:i64=1",
                "B:=class<castable><concrete>{}\nF(K:castable_concrete_subtype(B))<computes>:B=K{}\nValue:i64=1",
                "B:=class<castable><concrete>{N:i64=1}\nF(K:castable_concrete_subtype(B))<allocates>:B=K{N:=2}\nValue:i64=1",
                "B:=class<castable><concrete>{}\nK:castable_concrete_subtype(B)=B\nF()<computes>:B=K[B{}]\nValue:i64=1",
                "B:=class<castable><concrete>{}\nK:castable_concrete_subtype(B)=B\nC:castable_subtype(B)=K\nValue:i64=1",
                "B:=class<castable><concrete>{}\nK:castable_subtype(B)=B\nC:castable_concrete_subtype(B)=K\nValue:i64=1",
                "B:=class<castable><concrete>{}\nBuild[T:castable_concrete_subtype(B)]()<allocates>:T{T{}}\nV:=Build[i64]()\nValue:i64=1",
            }));
            return .syntax_failure;
        },
        // `<castable>` is not declared on a parametric class (10:2450), and a parametric class
        // may stand below a castable one.
        336 => {
            const declared = draw(c, 3) == 0;
            try out.print("Root:=class<castable>{{N:i64=1}}\nBox[T:type]:=class{s}{{V:T}}\nK:castable_subtype(Root)=Root\nValue:i64=Box[i64]{{V:={d}}}.V+Attempt(Block{{K[Root{{}}];1}},0)*1000", .{ if (declared) "<castable>" else "(Root)", a });
            if (declared) return .syntax_failure;
            return .{ .value = a + 1000 };
        },
        // `_` declares nothing (the Book reserves it), whatever it would name.
        337 => {
            try out.writeAll(choose(c, []const u8, &.{
                "_:i64=1\nValue:i64=1",
                "_:=2\nValue:i64=1",
                "F(_:i64)<computes>:i64=1\nValue:i64=F(2)",
                "_()<computes>:i64=1\nValue:i64=1",
                "C:=class{_:i64=0}\nValue:i64=1",
                "S:=struct{_:i64}\nValue:i64=1",
                "E:=enum{_,b}\nValue:i64=1",
                "Value:i64=Block{_:=1;2}",
                "Value:i64=Block{var _:i64=1;2}",
                "Value:i64=For(_:array{1,2},1).Length",
                "Value:i64=Case(1,1=>Block{_:=2;3},_=>0)",
                "Value:i64=Case(1,2=>1,_=>Block{_:=2;3})",
            }));
            return .syntax_failure;
        },
        // `_` stays the wildcard of a Case pattern: the last arm, inside shapes, and in a Case
        // that stands in an arm of another.
        338 => {
            const scrutinee = draw(c, 4);
            const pattern = draw(c, 4);
            const inner = draw(c, 4);
            const second = draw(c, 4);
            try out.print("F(X:i64,Y:i64)<computes>:i64=Case(X,{d}=>{d},_=>Case(Y,{d}=>{d},_=>{d}))\nG(O:option(i64))<computes>:i64=Case(O,option{{_}}=>1,_=>0)\nValue:i64=F({d},{d})*10+G(option{{{d}}})+G(option{{}})+{d}", .{ pattern, a, inner, b, offset, scrutinee, second, a, offset });
            const first_arm: i64 = if (scrutinee == pattern) a else if (second == inner) b else offset;
            return .{ .value = first_arm * 10 + 1 + offset };
        },
        else => unreachable,
    }
}

/// RFC-0087, P5.3: `text` as a Forbic string literal: quotes, backslashes and braces escaped.
fn forbicString(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeByte('"');
    for (text) |c| switch (c) {
        '"', '\\', '{', '}' => try out.print("\\{c}", .{c}),
        '\n' => try out.writeAll("\\n"),
        '\t' => try out.writeAll("\\t"),
        else => try out.writeByte(c),
    };
    try out.writeByte('"');
}

fn word(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// `<public>`, or one of the two ways to say that a declaration of a module is not.
fn accessWord(c: *kernel.Context, public: bool) []const u8 {
    if (public) return "<public>";
    return if (draw(c, 2) == 0) "" else "<internal>";
}

/// The cases of two files (RFC-0074). `root` is `main.forb`, which imports `lib.forb` as `L`;
/// the result is the root's `Value`. The expectation is worked out here from the rules of the
/// RFC: a scope reads the scopes around it, a path needs every step in reach, a `using` holds
/// for the modules nested in its scope, and a field is assigned by whoever its `var` admits.
pub fn generateBundle(comptime Expected: type, kind: u64, c: *kernel.Context, root: *std.Io.Writer, library: *std.Io.Writer, a: i64, b: i64, offset: i64) !Expected {
    std.debug.assert(bundled(kind));
    try root.writeAll("L:=import{\"lib.forb\"}\n");
    switch (kind - first) {
        // ---- Paths, lexical reach, and the three ways to reach a nested module. A nested module
        // that declares again a name of the file around it is refused (RFC-0076).
        36 => {
            const shadow = draw(c, 2) == 0;
            const way = draw(c, 3);
            const n = draw(c, 100);
            const m = draw(c, 100);
            try library.print("Seed:i64={d}\nKit<public>:=module{{\nStep<public>:i64={d}\nDeep<public>:=module{{\n", .{ a, b });
            // `Seed` of the file is visible in the module: declaring it again shadows it.
            if (shadow) try library.print("Seed:i64={d}\n", .{offset});
            try library.writeAll("Scale<public>(X:i64)<computes>:i64=X*Step+Seed\n}\nSum<public>(X:i64)<computes>:i64=Deep.Scale(X)+Seed\n}");
            // A `using` of the file holds inside the module the file declares.
            try root.writeAll(switch (way) {
                0 => "using{L.Kit}\nLocal:=module{\nTwice<public>(X:i64)<computes>:i64=Deep.Scale(X)*2\n}\n",
                1 => "using{L.Kit.Deep}\nLocal:=module{\nTwice<public>(X:i64)<computes>:i64=Scale(X)*2\n}\n",
                else => "Local:=module{\nTwice<public>(X:i64)<computes>:i64=L.Kit.Deep.Scale(X)*2\n}\n",
            });
            try root.print("Value:i64=L.Kit.Sum({d})+Local.Twice({d})+L.Kit.Step", .{ n, m });
            if (shadow) return .syntax_failure;
            return .{ .value = (n * b + a + a) + (m * b + a) * 2 + b };
        },
        // ---- A class of a nested module: a field read anywhere and assigned by its class, an
        // exported alias, and a constructor function another module delegates to. Every member
        // the other file uses is `<public>`: members are internal to their module (RFC-0076).
        37 => {
            const start = draw(c, 50);
            const rate = 1 + draw(c, 5);
            const bonus = draw(c, 9);
            const first_amount = draw(c, 20);
            const second_amount = draw(c, 20);
            try library.print("Bank<public>:=module{{\nrow<public>:=[]i64\naccount<public>:=class{{\nvar<private> Total<public>:i64=0\nRate<public><final>:i64={d}\nvar Notes<public>:i64=0\n" ++
                "Block{{set Self.Notes=Self.Total*Self.Rate}}\nAdd<public>(N:i64)<transacts>:i64=Block{{set Self.Total=Self.Total+N;Self.Total}}\n}}\n" ++
                "Open<public><constructor>(Start:i64)<transacts>:=account{{Total:=Start}}\n}}", .{rate});
            try root.print("Shop:=module{{\nusing{{L.Bank}}\nsaver<public>:=class(account){{Bonus<public>:i64=0}}\n" ++
                "Make<public><constructor>(Start:i64,Bonus:i64)<transacts>:=saver{{Bonus:=Bonus,Open<constructor>(Start)}}\n}}\n" ++
                "S:=Shop.Make({d},{d})\nXs:L.Bank.row=array{{{d},{d}}}\nR1:i64=S.Add(Attempt(Xs[0],0))\nR2:i64=S.Add(Attempt(Xs[1],0))\n" ++
                "Value:i64=S.Total*100000+S.Notes*100+S.Bonus*10+R1+R2+S.Rate", .{ start, bonus, first_amount, second_amount });
            // The clause runs on the complete instance, before anything is added.
            const notes = start * rate;
            const after_first = start + first_amount;
            const total = after_first + second_amount;
            return .{ .value = total * 100000 + notes * 100 + bonus * 10 + after_first + total + rate };
        },
        // ---- Cells of nested modules: a failed call leaves them as they were, and an
        // arithmetic error in a function of a module of another file ends the run.
        38 => {
            var amounts: [3]i64 = undefined;
            for (&amounts) |*amount| amount.* = draw(c, 21);
            const parts = draw(c, 3);
            try library.print("Vault<public>:=module{{\nvar Stock:i64={d}\nInner<public>:=module{{\nShare<public>(Parts:i64)<transacts>:i64=Stock/Parts\n}}\n}}", .{a});
            try root.print("Tally:=module{{\nvar Count<public>:i64=0\nAdd<public>(N:i64)<transacts><decides>:i64=Block{{set Count=Count+N;Require[Count<=25];Count}}\n}}\n" ++
                "R1:i64=Attempt(Tally.Add[{d}],-1)\nR2:i64=Attempt(Tally.Add[{d}],-1)\nR3:i64=Attempt(Tally.Add[{d}],-1)\n" ++
                "Value:i64=Tally.Count*1000+R1+R2+R3+L.Vault.Inner.Share({d})", .{ amounts[0], amounts[1], amounts[2], parts });
            var count_now: i64 = 0;
            var results: i64 = 0;
            for (amounts) |amount| {
                if (count_now + amount <= 25) {
                    count_now += amount;
                    results += count_now;
                } else results -= 1;
            }
            if (parts == 0) return .{ .failed = .division_by_zero };
            return .{ .value = count_now * 1000 + results + @divTrunc(a, parts) };
        },
        // ---- Every step of a path must be in reach of the code that writes it: from another
        // file each module and the name are public; inside the outer module the middle one is
        // its own; inside the middle one only the name has to be public.
        39 => {
            const from = draw(c, 3);
            const outer = from != 0 or draw(c, 2) == 0;
            const middle = draw(c, 2) == 0;
            const inner = draw(c, 2) == 0;
            const name = draw(c, 2) == 0;
            try library.print("A{s}:=module{{\nB{s}:=module{{\nC{s}:=module{{\nName{s}:i64={d}\n}}\n", .{ accessWord(c, outer), accessWord(c, middle), accessWord(c, inner), accessWord(c, name), a });
            if (from == 2) try library.writeAll("FromB<public>:i64=C.Name\n");
            try library.writeAll("}\n");
            if (from == 1) try library.writeAll("Out<public>:i64=B.C.Name\n");
            if (from == 2) try library.writeAll("Out<public>:i64=B.FromB\n");
            try library.writeAll("}");
            try root.writeAll(if (from == 0) "Value:i64=L.A.B.C.Name" else "Value:i64=L.A.Out");
            const admitted = switch (from) {
                0 => outer and middle and inner and name,
                1 => inner and name,
                else => name,
            };
            return if (admitted) .{ .value = a } else .syntax_failure;
        },
        40 => {
            const Pair = struct { []const u8, []const u8 };
            const pair = choose(c, Pair, &.{
                // A module, an alias or a function that is not public, named from another file.
                .{ "Kit:=module{\nOffset<public>:i64=1\n}", "Value:i64=L.Kit.Offset" },
                .{ "Kit<public>:=module{\nrow:=[]i64\n}", "Xs:L.Kit.row=array{1}\nValue:i64=1" },
                .{ "Kit<public>:=module{\nIn:=module{\nGet<public>()<computes>:i64=1\n}\n}", "using{L.Kit.In}\nValue:i64=Get()" },
                // A module is named after its declaration, and declares no imports.
                .{ "Kit<public>:=module{\nOffset<public>:i64=1\n}", "Value:i64=M.X\nM:=module{\nX<public>:i64=1\n}" },
                .{ "Kit<public>:=module{\nOffset<public>:i64=1\n}", "M:=module{\nK:=import{\"lib.forb\"}\n}\nValue:i64=1" },
                .{ "Kit<public>:=module{\nOffset<private>:i64=1\n}", "Value:i64=1" },
                // The write access guards `set` outside the class, and is never the wider one.
                .{ "Kit<public>:=module{\nc<public>:=class{\nvar<private> X<public>:i64=0\n}\n}", "Poke(P:L.Kit.c)<transacts>:i64=Block{set P.X=1;1}\nValue:i64=Poke(L.Kit.c{})" },
                .{ "Kit<public>:=module{\nc<public>:=class{\nvar<public> X<private>:i64=0\n}\n}", "Value:i64=1" },
                // A constructor function that is not public lends nothing to another file, and a
                // final field is given by nobody.
                .{ "Kit<public>:=module{\nc<public>:=class{\nX<public>:i64=0\n}\nMake<constructor>(X:i64)<transacts>:=c{X:=X}\n}", "P:L.Kit.c=L.Kit.c{L.Kit.Make<constructor>(1)}\nValue:i64=P.X" },
                .{ "Kit<public>:=module{\nc<public>:=class{\nvar<private> X<public><final>:i64=0\n}\n}", "P:L.Kit.c=L.Kit.c{X:=1}\nValue:i64=P.X" },
            });
            try library.writeAll(pair[0]);
            try root.writeAll(pair[1]);
            return .syntax_failure;
        },
        // ---- Members of a class are internal to the module that declares it (RFC-0076):
        // another file calls, reads, assigns or initialises only what says `<public>`, and the
        // declaring module uses every member whatever its access says.
        62 => {
            const level_public = draw(c, 3) != 0;
            const cap_public = draw(c, 3) != 0;
            const fill_public = draw(c, 3) != 0;
            const use = draw(c, 6);
            const start = draw(c, 2);
            const cap = draw(c, 50);
            const n = draw(c, 2);
            const probe = draw(c, 100);
            try library.print("Kit<public>:=module{{\ntank<public>:=class{{\nvar Level{s}:i64={d}\n", .{ accessWord(c, level_public), start });
            try library.print("Cap{s}:i64={d}\n", .{ accessWord(c, cap_public), cap });
            try library.print("Fill{s}(N:i64)<transacts>:i64=Block{{set Self.Level=Self.Level+N;Self.Cap/Self.Level}}\n}}\n", .{accessWord(c, fill_public)});
            // The module itself gives, assigns, calls and reads all three.
            try library.writeAll("Peek<public>(T:tank)<transacts>:i64=T.Cap*1000+T.Level\n" ++
                "Make<public>(N:i64)<transacts>:tank=tank{Cap:=N}\nPoke<public>(T:tank)<transacts>:i64=Block{set T.Level=T.Level+1;T.Fill(1)+T.Level*10+T.Cap*100}\n}");
            switch (use) {
                0, 5 => try root.print("T:=L.Kit.tank{{}}\nR:i64=T.Fill({d})\n", .{n}),
                1 => try root.writeAll("T:=L.Kit.tank{}\nR:i64=T.Level+T.Cap\n"),
                2 => try root.print("T:=L.Kit.tank{{Cap:={d}}}\nR:i64=1\n", .{probe}),
                3 => try root.print("T:=L.Kit.tank{{}}\nset T.Level={d}\nR:i64=0\n", .{n}),
                else => try root.writeAll("T:=L.Kit.tank{}\nR:i64=0\n"),
            }
            try root.print("U:=L.Kit.Make({d})\nValue:i64=R+L.Kit.Peek(T)*7+L.Kit.Poke(U)", .{probe});
            const admitted = switch (use) {
                0, 5 => fill_public,
                1 => level_public and cap_public,
                2 => cap_public,
                3 => level_public,
                else => true,
            };
            if (!admitted) return .syntax_failure;
            var level = start;
            var held = cap;
            var result: i64 = 0;
            switch (use) {
                0, 5 => {
                    level += n;
                    if (level == 0) return .{ .failed = .division_by_zero };
                    result = @divTrunc(cap, level);
                },
                1 => result = level + cap,
                2 => {
                    held = probe;
                    result = 1;
                },
                3 => level = n,
                else => {},
            }
            // The second tank is made and poked by its module: one more by assignment, one more
            // by `Fill`.
            const probed = @divTrunc(probe, start + 2) + (start + 2) * 10 + probe * 100;
            return .{ .value = result + (held * 1000 + level) * 7 + probed };
        },
        // The same for a class of a module nested in the file that uses it: the file around the
        // module is outside it. And a `using` with an extension method of the file leaves the
        // plain function of that name, which the library exports, in reach.
        63 => {
            const count_public = draw(c, 3) != 0;
            const step_public = draw(c, 3) != 0;
            const use = draw(c, 3);
            const start = draw(c, 2);
            const m = draw(c, 2);
            const n = 1 + draw(c, 5);
            const k = draw(c, 10);
            try library.writeAll("Twice<public>(X:i64)<computes>:i64=X*3\nKit<public>:=module{\nOne<public>:i64=1\n}");
            try root.print("using{{L}}\nLocal:=module{{\ncell<public>:=class{{\nvar Count{s}:i64={d}\n", .{ accessWord(c, count_public), start });
            try root.print("Step{s}(N:i64)<transacts>:i64=Block{{set Self.Count=Self.Count+N;60/Self.Count}}\n}}\n", .{accessWord(c, step_public)});
            try root.writeAll("Make<public>()<transacts>:cell=cell{}\nRun<public>(X:cell,N:i64)<transacts>:i64=Block{X.Step(N);X.Step(N)+X.Count}\n}\n(V:i64).Twice()<computes>:i64=V+V\nY:=Local.cell{}\nZ:=Local.Make()\n");
            switch (use) {
                0 => try root.print("R:i64=Y.Step({d})\n", .{m}),
                1 => try root.writeAll("R:i64=Y.Count\n"),
                else => try root.writeAll("R:i64=0\n"),
            }
            try root.print("Value:i64=R+Local.Run(Z,{d})*100+Twice({d})*10000+({d}).Twice()*1000000", .{ n, k, k });
            const admitted = switch (use) {
                0 => step_public,
                1 => count_public,
                else => true,
            };
            if (!admitted) return .syntax_failure;
            var result: i64 = 0;
            if (use == 0) {
                if (start + m == 0) return .{ .failed = .division_by_zero };
                result = @divTrunc(60, start + m);
            }
            if (use == 1) result = start;
            const stepped = start + 2 * n;
            return .{ .value = result + (@divTrunc(60, stepped) + stepped) * 100 + k * 3 * 10000 + k * 2 * 1000000 };
        },
        else => unreachable,
    }
}

test "feature case numbers continue the workload and the text helper keeps letters whole" {
    try std.testing.expectEqual(@as(u64, 199), first);
    try std.testing.expect(!bundled(first) and !bundled(first_bundle - 1) and bundled(first_bundle) and bundled(first_bundle + bundle_count - 1) and !bundled(first_bundle + bundle_count));
    try std.testing.expect(!bundled(first_member_bundle - 1) and bundled(first_member_bundle) and bundled(first_member_bundle + member_bundle_count - 1) and !bundled(first_member_bundle + member_bundle_count));
    // The standard library's cases follow the member bundles and are programs of one file.
    // The five cases of RFC-0080 after them are programs of one file too.
    // The three of native effects (RFC-0079) follow them, then the five of RFC-0081.
    // The three of the `fix2` pass follow the five of RFC-0081, then the four of structured
    // concurrency (RFC-0082), then the four of RFC-0083, then the four of the events of
    // RFC-0082 (P3.2), then the four of P3.3, the four of P3.4, the four of live variables
    // (RFC-0084), the four of reclamation across task stacks (RFC-0082, P3.5), the four of
    // live fields (RFC-0084, P4.2), the four of functions as types (P4.3) and the four of
    // exits from arms (RFC-0082, P3.6), the eight of reactions (RFC-0084, P4.4), and the four
    // of cancellation (RFC-0082, P3.7), and the four of batches (RFC-0084, P4.5), and the four
    // of `Await` (P4.6), and the four of sticky and subscribable events (RFC-0082, P3.9), and the
    // four of cancelling reactions (P4.7), and the three of the rooms of array joins (RFC-0055),
    // and the two each of transparent functions, enumerator qualification and `<predicts>`
    // (RFC-0085, I7, I10, I12), and the four of inputs (RFC-0086), and the seven of accessors
    // (RFC-0085, I8), and the seven of grants and handles (RFC-0086, P2.3), and the seven of
    // shared locals (RFC-0085, I2), and the seven of `weak_map` (RFC-0087, P5.1), and the seven
    // of nested functions (RFC-0085, I3).
    // And the seven of automatic qualification (RFC-0085, I11), and the seven of the durable
    // journal's seals (RFC-0086, P2.4), and the seven of the overloads, defaults and named
    // parameters of nested functions (RFC-0085, I4), and the seven of shared locals in tasks
    // (RFC-0085, I5), and the seven of `<persistable>` (RFC-0087, P5.2), and the seven of recovery
    // (RFC-0086, P2.5), and the seven of `For` loops whose bodies suspend (RFC-0082, P3.8), and
    // the seven of session cells (RFC-0087, P5.4), and the seven of the closure forms composed
    // (RFC-0085, I6), and the seven of JSON (RFC-0087, P5.3), and the seven of live locals (RFC-0085, I14), and the three of generic functions beside
    // methods and an `Fn` in a `For` (`pf2`), and the seven of the one capture rule (RFC-0085, I13), and the seven of persistent cells (RFC-0087, P5.5).
    // And the seven of control-flow completion (RFC-0090, B2), and the eight of the functions
    // completion (RFC-0091, B3).
    // And the seven of classes completion (RFC-0092, B4), and the three of `Profile` (RFC-0094, B6).
    try std.testing.expectEqual(first + count, first_member_bundle + member_bundle_count + 12 + 5 + 3 + 5 + 3 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 8 + 4 + 4 + 4 + 4 + 4 + 3 + 2 + 2 + 2 + 4 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 7 + 3 + 7 + 7 + 7 + 8 + 7 + 3 + 5);
    try std.testing.expect(recovering(first_recovering) and recovering(first_recovering + recovering_count - 1) and !recovering(first_recovering - 1) and !recovering(first_recovering + recovering_count));
    try std.testing.expect(qualifying(first_qualifying) and qualifying(first_qualifying + qualifying_count - 1) and !qualifying(first_qualifying - 1) and !qualifying(first_qualifying + qualifying_count));
    try std.testing.expect(!bundled(first + count - 1));
    var context = kernel.Context.init(7, .swarm);
    for (0..200) |_| {
        const text = Text.random(&context);
        try std.testing.expect(text.len >= 1 and text.len <= 12);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
        try std.testing.expect(text.boundary(0) and text.boundary(text.len));
        for (0..text.len) |index| try std.testing.expectEqual(text.bytes[index] != 0xa9, text.boundary(index));
    }
}
