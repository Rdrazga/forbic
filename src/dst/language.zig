//! Compiler/IR evaluator/VM differential work with independent arithmetic checks.
const std = @import("std");
const kernel = @import("kernel.zig");
const forbic = @import("forbic");
const types = forbic.types;
const features = @import("language_features.zig");
const origin: types.Span = .{ .start = 0, .end = 0 };
const Expected = union(enum) { value: i64, float_value: f64, boolean: bool, enumeration: u32, failed: types.Diagnostic.Code, syntax_failure, unchecked, effects: features.Effects };

/// A changed value of the same kind, or null for one that names storage.
fn forgedValue(value: types.Value) ?types.Value {
    return switch (value) {
        .integer => |x| .{ .integer = x +% 1 },
        .boolean => |x| .{ .boolean = !x },
        .floating => |x| .{ .floating = if (types.isNan(x) or std.math.isInf(x)) 0.0 else if (x + 1.0 == x) x * 0.5 else x + 1.0 },
        .string => |text| if (text.len != 0) .{ .string = text[0..0] } else null,
        .rational, .enumeration, .aggregate, .callable, .object => null,
    };
}
/// Whether a root node's value is one the replay works out from its operands alone.
fn pureRoot(node: types.Node) bool {
    return switch (node.kind) {
        .integer, .boolean, .floating, .string, .negate, .binary, .float_negate, .float_binary, .int_to_float, .float_to_int, .compare, .logic_not, .logic_binary, .array_length, .string_length, .option_present, .option_or, .field, .tuple_element, .array_get, .string_concat, .to_string => true,
        else => false,
    };
}

/// The workload's world (RFC-0086): its wall clock, `features.worldClock`, a function of the tick,
/// and from P2.3 the streams of its readers, `features.worldLine`, which each machine reads with
/// cursors of its own, rewound before every run.
const World = struct {
    cursors: [features.world_grants.len]usize = @splat(0),

    fn rewind(self: *World) void {
        self.cursors = @splat(0);
    }
    fn read(context: *anyopaque, request: forbic.effects.Request) error{InputFailed}!forbic.effects.Answer {
        const self: *World = @ptrCast(@alignCast(context));
        switch (request.kind) {
            .clock => return .{ .bits = @bitCast(features.worldClock(request.tick)) },
            // RFC-0087, P5.5: the entries of the workload's store, or their end.
            .load => return if (features.worldStore(request.request / forbic.effects.load_grants, request.request % forbic.effects.load_grants)) |text| .{ .bytes = text } else .{ .status = .end },
            .line => {
                if (request.request >= self.cursors.len) return error.InputFailed;
                const cursor = &self.cursors[request.request];
                const line = features.worldLine(request.request, cursor.*) orelse return .{ .status = .end };
                cursor.* += 1;
                return .{ .bytes = line };
            },
        }
    }
    fn source(self: *World) forbic.effects.InputSource {
        return .{ .context = self, .read = read };
    }
};

/// RFC-0086, P2.4: a sink that writes down where a run's log ends its commit points (J3), so that
/// both machines can be seen to seal alike, in every trace mode, and as a case's model says.
const Sealer = struct {
    commits: u64 = 0,
    seals: [64]u64 = undefined,
    count: u32 = 0,
    lost: u32 = 0,
    /// Seals that came before any new commit, or named another count.
    wrong: u32 = 0,
    /// The latest seal's `through`, and a hash of every seal, past the array too.
    last: u64 = 0,
    hash: u64 = 0,

    fn prepare(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn commit(context: *anyopaque, action: forbic.effects.Action) bool {
        const self: *Sealer = @ptrCast(@alignCast(context));
        if (action.sequence != self.commits) self.wrong += 1;
        self.commits += 1;
        return true;
    }
    fn abort(_: *anyopaque, _: []const u8) void {}
    fn seal(context: *anyopaque, through: u64) bool {
        const self: *Sealer = @ptrCast(@alignCast(context));
        if (through != self.commits or through <= self.last) self.wrong += 1;
        self.last = through;
        self.hash = std.hash.Wyhash.hash(self.hash, std.mem.asBytes(&through));
        if (self.count == self.seals.len) self.lost += 1 else {
            self.seals[self.count] = through;
            self.count += 1;
        }
        return true;
    }
    fn sink(self: *Sealer) forbic.effects.Sink {
        return .{ .context = self, .prepare = prepare, .commit = commit, .abort = abort, .seal = seal };
    }
    fn same(a: *const Sealer, b: *const Sealer) bool {
        return a.commits == b.commits and a.count == b.count and a.lost == b.lost and a.wrong == b.wrong and a.last == b.last and a.hash == b.hash and std.mem.eql(u64, a.seals[0..a.count], b.seals[0..b.count]);
    }
    /// Every committed action was sealed: the last seal names them all.
    fn whole(self: *const Sealer) bool {
        return if (self.commits == 0) self.count + self.lost == 0 else self.last == self.commits;
    }
};

/// RFC-0086, P2.5: what the recovery cases need of each machine: a disk in memory, its journal,
/// the inputs a resume serves, and how the run ended.
const Recovery = struct {
    const Outcome = union(enum) { value: ?i64, failed: types.Diagnostic };
    disks: [2][64 * 1024]u8 = undefined,
    memories: [2]forbic.durable.Memory = undefined,
    buffers: [2][8 * 1024]u8 = undefined,
    journals: [2]forbic.durable.Journal = undefined,
    sealed: [2]forbic.durable.SealedInputs = undefined,
    outcomes: [2]Outcome = undefined,
    diverged: [2]bool = undefined,
    whole: [64 * 1024]u8 = undefined,
    image: [64 * 1024]u8 = undefined,
};

pub const State = struct {
    compiler: forbic.Workspace = .{},
    /// The parts of a qualification case the author wrote (RFC-0085, I11).
    qualify_written: [types.limits.modules]types.Span = undefined,
    runtime: forbic.bytecode.Workspace = .{},
    reference_values: [types.limits.nodes]types.Value = undefined,
    reference_control: types.ControlStorage = .{},
    reference_state: forbic.source_state.ReferenceState = .{},
    reference_frames: forbic.call_frames.ReferenceStorage = .{},
    reference_members: [types.limits.aggregate_elements]types.Value = undefined,
    source: [4096]u8 = undefined,
    module_source: [4096]u8 = undefined,
    second_module_source: [4096]u8 = undefined,
    generated: u64 = 0,
    /// The second run a report of a `digest` run replays, and the two reports compared.
    again: forbic.trace_replay.Storage = .{},
    /// RFC-0086, P2.4: the seals of each machine's run, and those of the stored run whose trace
    /// modes are compared with it.
    sealers: [2]Sealer = .{ .{}, .{} },
    stored_seals: Sealer = .{},
    /// RFC-0086, P2.3: the world each machine reads, with cursors of its own.
    reference_world: World = .{},
    runtime_world: World = .{},
    reports: [2][report_bytes]u8 = undefined,
    /// What the workload has exercised, so that a test can require each kind of outcome.
    refused: u64 = 0,
    failed: u64 = 0,
    succeeded: u64 = 0,
    replayed: u64 = 0,
    reclaimed: u64 = 0,
    /// Bytes of `source` the last single-file case wrote, for a failure message.
    written: usize = 0,
    /// RFC-0086, P2.5: whether the case is one of recovery, and the journals, sealed inputs and
    /// disks each machine's journaled runs use; `resumed` counts the resumes the cases checked.
    resuming: bool = false,
    recovery: Recovery = .{},
    resumed: u64 = 0,
    /// The same for `module_source`, of a case of two files.
    module_written: usize = 0,

    const report_bytes = 16 * 1024;

    /// Defaults in place: the state is language storage, and `.{}` would build an image of
    /// every capacity in the binary and copy it here.
    pub fn initInPlace(self: *State, _: std.mem.Allocator) !void {
        forbic.scratch.initialise(self);
    }

    pub fn step(self: *State, c: *kernel.Context) !void {
        var kind = c.rng.below(features.first + features.count);
        if (c.fault(.corrupt)) kind = 8 + c.rng.below(3);
        try self.case(c, kind);
    }

    /// One generated case of the given number, with its operands drawn from the seed.
    fn case(self: *State, c: *kernel.Context, kind: u64) !void {
        // RFC-0085, I11: the qualification cases are compiled with the resolution table.
        self.compiler.qualify = features.qualifying(kind);
        defer self.compiler.qualify = false;
        // RFC-0086, P2.5: the recovery cases are crashed and resumed too.
        self.resuming = features.recovering(kind);
        defer self.resuming = false;
        const a: i64 = @as(i64, @intCast(c.rng.below(2_000_001))) - 1_000_000;
        const b: i64 = @as(i64, @intCast(c.rng.below(64))) + 1;
        const offset: i64 = @as(i64, @intCast(c.rng.below(2001))) - 1000;
        c.record("language_case", kind, @bitCast(a));
        c.record("language_operands", @bitCast(b), @bitCast(offset));
        if (kind >= 49 and kind < 57) {
            try self.moduleCase(c, kind, a, offset, c.fault(.exhaustion));
            self.generated += 1;
            return;
        }
        if (features.bundled(kind)) {
            try self.bundleCase(c, kind, a, b, offset);
            self.generated += 1;
            return;
        }
        var out = std.Io.Writer.fixed(&self.source);
        const expected: Expected = switch (kind) {
            0, 1, 2, 3 => blk: {
                try out.print("Base:i64={d};Scale(X:i64)<computes>:i64=(X+{d})*{d};Mix(X:i64,Y:i64)<computes>:i64=Scale(X)-Y+Base;Value:i64=Mix(Base,{d})/{d};Theme:string=\"snow: ", .{ a, offset, b, offset, b });
                try out.writeAll("\xe9\x9b\xaa\xf0\x9f\x8c\xb2\\n\\\"\\\\\";Alias:string=Theme;Enabled:logic=true;Copy:logic=Enabled");
                break :blk .{ .value = @divTrunc((a + offset) * b - offset + a, b) };
            },
            4 => blk: {
                try out.writeAll("F(X:i64)<computes>:i64=X+1;Value:i64=F(9223372036854775807)");
                break :blk .{ .failed = .arithmetic_overflow };
            },
            5 => blk: {
                try out.writeAll("Unused()<computes>:i64=1/0;First(A:i64,B:i64)<computes>:i64=A;Value:i64=First(7,1/0)");
                break :blk .{ .failed = .division_by_zero };
            },
            6 => blk: {
                try out.writeAll("Value:i64=-9223372036854775808/-1");
                break :blk .{ .failed = .arithmetic_overflow };
            },
            7 => blk: {
                try out.writeAll("F(X:i64)<computes>:i64=X;Value:i64=");
                const nesting: usize = @intCast(c.rng.below(types.limits.expression_depth + 2));
                c.record("language_nesting", nesting, @intFromBool(a < 0));
                for (0..nesting) |_| try out.writeAll("F(");
                try out.print("{d}", .{a});
                for (0..nesting) |_| try out.writeByte(')');
                break :blk if (nesting + @intFromBool(a < 0) > types.limits.expression_depth) .syntax_failure else .{ .value = a };
            },
            8 => blk: {
                try out.print("F(X:i64,Y:i64)<computes>:i64=X+Y;Value:i64=F({d},{d})", .{ a, offset });
                const punctuation = "()+-*/,;:<>=\"\\\n";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            9 => {
                try self.malformedTail(c);
                return;
            },
            10 => {
                try self.invalidBytecodeTail(c);
                return;
            },
            11 => blk: {
                try out.print("Bad()<computes>:i64=1/0;Keep(X:i64)<computes>:i64=X;Value:i64=Keep({d})", .{a});
                break :blk .{ .value = a };
            },
            12 => blk: {
                try out.print("F(X:float)<computes>:float=(X+{d}.0)*{d}.0/8.0;Value:float=F({d}.0);Neg:float=-Value", .{ offset, b, a });
                // Integer arithmetic is exact in this range; division by eight
                // is an exactly representable dyadic, independent of the guest.
                break :blk .{ .float_value = @as(f64, @floatFromInt((a + offset) * b)) / 8.0 };
            },
            13 => blk: {
                try out.writeAll("Value:float=0.0/0.0;Infinity:float=Inf;NegativeZero:float=-0.0");
                break :blk .{ .float_value = @bitCast(@as(u64, 0x7ff8000000000000)) };
            },
            14 => blk: {
                try out.writeAll("Value:float=1.0000000000000002*0.9999999999999998-1.0;Small:float=4.9406564584124654e-324");
                break :blk .{ .float_value = 0.0 };
            },
            15 => blk: {
                try out.writeAll("F(X:float)<computes>:float=X;Value:float=F(1)");
                break :blk .syntax_failure;
            },
            16 => blk: {
                try out.writeAll("Value:float=1e309");
                break :blk .syntax_failure;
            },
            17 => blk: {
                try out.writeAll("p:=struct{X:i64,Y:i64};wrap:=struct{P:p,A:[]p};Make(X:i64)<computes>:wrap=wrap{A:=array{p{Y:=");
                try out.print("{d}", .{offset});
                try out.writeAll(",X:=X}},P:=p{X:=X,Y:=");
                try out.print("{d}", .{offset});
                try out.writeAll("}};All:wrap=Make(");
                try out.print("{d}", .{a});
                try out.writeAll(");Alias:wrap=All;Value:i64=All.P.X+All.P.Y+All.A.Length");
                break :blk .{ .value = a + offset + 1 };
            },
            18 => blk: {
                try out.writeAll("Length(X:[][]i64)<computes>:i64=X.Length;Empty:[][]i64=array{array{},array{");
                try out.print("{d}", .{a});
                try out.writeAll("}};Value:i64=Length(Empty)+Length(array{})");
                break :blk .{ .value = 2 };
            },
            19 => blk: {
                try out.writeAll("p:=struct{X:i64};Value:p=p{X:=1,X:=2}");
                break :blk .syntax_failure;
            },
            20 => blk: {
                try out.writeAll("p:=struct{X:i64};q:=struct{X:i64};Value:q=p{X:=1}");
                break :blk .syntax_failure;
            },
            21 => blk: {
                try out.writeAll("p:=struct{X:i64};Value:[]p=array{p{X:=1},p{X:=2}}");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_aggregate_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            22 => blk: {
                // A parameter called as the binding a field default reads was hidden from the
                // default; now it may not have that name at all (RFC-0076).
                const shadowed = c.rng.below(2) == 1;
                c.record("language_shadowed_parameter", @intFromBool(shadowed), 0);
                try out.print("Seed:i64={d};Adjust(X:i64)<computes>:i64=X+{d};p:=struct{{X:i64=Adjust(Seed),Y:i64={d}}};wrap:=struct{{P:p=p{{}},Rows:[][]p=array{{array{{}},array{{p{{}}}}}}}};Make({s}:i64)<computes>:wrap=wrap{{}};All:wrap=Make(1);Value:i64=All.P.X+All.P.Y+All.Rows.Length", .{ a, offset, b, if (shadowed) "Seed" else "Other" });
                break :blk if (shadowed) .syntax_failure else .{ .value = a + offset + b + 2 };
            },
            23 => blk: {
                try out.print("p:=struct{{X:i64=1/0,Y:i64=9223372036854775807+1}};All:p=p{{Y:={d},X:={d}}};Value:i64=All.X+All.Y", .{ offset, a });
                break :blk .{ .value = a + offset };
            },
            24 => blk: {
                try out.writeAll("p:=struct{X:i64=1/0,Y:i64=9223372036854775807+1};All:p=p{};Value:i64=All.X");
                break :blk .{ .failed = .division_by_zero };
            },
            25 => blk: {
                try out.writeAll("p:=struct{X:i64=1/0,Required:i64};All:p=p{};Value:i64=All.X");
                break :blk .syntax_failure;
            },
            26 => blk: {
                try out.writeAll("p:=struct{X:logic=i64};All:p=p{};Value:i64=1");
                break :blk .syntax_failure;
            },
            27 => blk: {
                try out.writeAll("p:=struct{X:i64=7,A:[][]i64=array{array{},array{1,2}}};Make(X:i64)<computes>:p=p{X:=X};All:p=Make(9);Value:i64=All.X+All.A.Length");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_default_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            28 => blk: {
                const index: u32 = @intCast(c.rng.below(3));
                c.record("language_enum_case", index, 0);
                try out.print("mode:=enum<closed>{{Light,Dark,Auto}};p:=struct{{Mode:mode=mode.Dark,Allowed:[]mode=array{{mode.Light,mode.Auto}}}};Keep(X:mode)<computes>:mode=X;All:p=p{{Mode:=Keep(mode.{s})}};Value:mode=All.Mode;Empty:[]mode=array{{}}", .{([_][]const u8{ "Light", "Dark", "Auto" })[index]});
                break :blk .{ .enumeration = index };
            },
            29 => blk: {
                try out.writeAll("a:=enum{Same};b:=enum{Same};Value:b=a.Same");
                break :blk .syntax_failure;
            },
            30 => blk: {
                try out.writeAll("mode:=enum{Dark};Shadow(mode:mode)<computes>:mode=mode.Dark;Value:mode=mode.Dark");
                break :blk .syntax_failure;
            },
            31 => blk: {
                try out.writeAll("mode:=enum{Dark,Dark};Value:mode=mode.Dark");
                break :blk .syntax_failure;
            },
            32 => blk: {
                try out.writeAll("mode:=enum{Light,Dark};p:=struct{Mode:mode=mode.Dark};All:p=p{};Value:mode=All.Mode");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_enum_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            33 => blk: {
                try out.writeAll("empty:=enum{};mode:=enum{A,B};Keep(X:mode)<computes>:mode=X;Value:mode=Keep(mode.B);Unused:[]empty=array{}");
                break :blk .{ .enumeration = 1 };
            },
            34 => blk: {
                try out.print("Pick(P:tuple(i64,string,tuple(i64)))<computes>:i64=P(0)+P(2)(0);Pair:tuple(i64,string,tuple(i64))=tuple{{{d},\"label\",tuple{{{d}}}}};Value:i64=Pick(Pair)", .{ a, offset });
                break :blk .{ .value = a + offset };
            },
            35 => blk: {
                try out.print("p:=struct{{Pair:tuple([]i64,i64)=tuple{{array{{}},{d}}}}};All:p=p{{}};Value:i64=All.Pair(0).Length+All.Pair(1)", .{a});
                break :blk .{ .value = a };
            },
            36 => blk: {
                try out.writeAll("Pair:tuple(i64,string)=tuple{1,\"x\"};Value:i64=Pair(1)");
                break :blk .syntax_failure;
            },
            37 => blk: {
                try out.writeAll("Value:i64=tuple{1}(1)");
                break :blk .syntax_failure;
            },
            38 => blk: {
                try out.writeAll("Value:i64=tuple{3,1/0}(0)");
                break :blk .{ .failed = .division_by_zero };
            },
            39 => blk: {
                try out.writeAll("Pair:tuple(i64,tuple([]i64))=tuple{3,tuple{array{}}};Value:i64=Pair(0)+Pair(1)(0).Length");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_tuple_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            40 => blk: {
                try out.writeAll("Unit:tuple()=tuple{};Keep(P:tuple(tuple(),i64))<computes>:i64=P(1);Value:i64=Keep(tuple{Unit,42})");
                break :blk .{ .value = 42 };
            },
            41 => blk: {
                try out.print("M:map(i64,i64)=map{{1=>{d},2=>{d}}};Value:i64=Or(Lookup(M,2),0)+M.Length", .{ a, offset });
                break :blk .{ .value = offset + 2 };
            },
            42 => blk: {
                try out.print("M:map(string,option(i64))=map{{\"gap\"=>option{{{d}}},\"none\"=>option{{}}}};Value:i64=Or(Or(Lookup(M,\"gap\"),option{{}}),{d})", .{ a, offset });
                break :blk .{ .value = a };
            },
            43 => blk: {
                try out.print("M:map(i64,i64)=map{{1=>{d}}};Value:i64=Or(Lookup(M,2),{d})", .{ a, offset });
                break :blk .{ .value = offset };
            },
            44 => blk: {
                try out.writeAll("M:map(float,i64)=map{NaN=>1,0.0/0.0=>2};Value:i64=0");
                break :blk .{ .failed = .duplicate_map_key };
            },
            45 => blk: {
                try out.writeAll("Value:i64=Or(option{7},1/0)");
                break :blk .{ .failed = .division_by_zero };
            },
            46 => blk: {
                try out.writeAll("M:map(i64,i64)=map{1=>1/0,1=>2};Value:i64=0");
                break :blk .{ .failed = .division_by_zero };
            },
            47 => blk: {
                // Arrays are comparable keys since RFC-0065; a function never is.
                try out.writeAll("M:map(function(tuple(i64),i64),i64)=map{};Value:i64=0");
                break :blk .syntax_failure;
            },
            48 => blk: {
                try out.writeAll("M:map(string,i64)=map{\"a\"=>3};Value:i64=Or(Lookup(M,\"a\"),4)");
                const punctuation = "{}[]().,:;=>+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_collection_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            57 => blk: {
                try out.print("Value:logic={d}<{d}", .{ a, offset });
                break :blk .{ .boolean = a < offset };
            },
            58 => blk: {
                try out.print("Valid(x:i64)<computes>:logic=x>=-1000 and x<=1000;Value:logic=Valid({d})", .{a});
                break :blk .{ .boolean = a >= -1000 and a <= 1000 };
            },
            59 => blk: {
                try out.writeAll("Value:logic=NaN==0.0/0.0 and not (NaN>=Inf) and 0.0==-0.0");
                break :blk .{ .boolean = true };
            },
            60 => blk: {
                try out.writeAll("Text:string=\"snow\\n\";Value:logic=Text==Text and Text!=\"other\"");
                break :blk .{ .boolean = true };
            },
            61 => blk: {
                // `and` runs its right operand only when the left one holds (RFC-0076): the
                // division is an error of the run exactly when the left operand is `true`.
                const left = c.rng.below(2) == 1;
                c.record("language_short_circuit_left", @intFromBool(left), 0);
                try out.print("Value:logic={s} and (1/0==0)", .{if (left) "true" else "false"});
                break :blk if (left) .{ .failed = .division_by_zero } else .{ .boolean = false };
            },
            62 => blk: {
                // A chain is the conjunction of its links (RFC-0076); it was refused before.
                try out.print("Value:logic={d}<{d}<{d}", .{ offset, a, b });
                break :blk .{ .boolean = offset < a and a < b };
            },
            63 => blk: {
                try out.print("Value:logic=not ({d}=={d}) and 1<=2", .{ a, offset });
                const punctuation = "=!<>()+-*/,;:\"\\\n";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_predicate_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            64 => blk: {
                try out.print("Value:logic=not ({d}>{d}) or {d}=={d} and false", .{ a, offset, a, offset });
                break :blk .{ .boolean = a <= offset };
            },
            65 => blk: {
                try out.print("Value:i64=If({s},{d},1/0)", .{ if (a < b) "true" else "false", a });
                break :blk if (a < b) .{ .value = a } else .{ .failed = .division_by_zero };
            },
            66 => blk: {
                try out.print("F(X:i64)<computes><decides>:i64=If(Require[X>=0],X,0);Value:i64=Attempt(F[{d}],{d})", .{ a, offset });
                break :blk .{ .value = if (a >= 0) a else offset };
            },
            67 => blk: {
                try out.print("Rows:[][]i64=If({s},array{{array{{1,2}}}},array{{array{{}}}});Value:i64=Rows.Length", .{if (a >= 0) "true" else "false"});
                break :blk .{ .value = 1 };
            },
            68 => blk: {
                try out.writeAll("Value:i64=Attempt(Attempt(Fail[\"first\"],Fail[\"second\"]),42)");
                break :blk .{ .value = 42 };
            },
            69 => blk: {
                try out.writeAll("Value:i64=Attempt(1/0,42)");
                break :blk .{ .failed = .division_by_zero };
            },
            70 => blk: {
                try out.writeAll("Value:logic=Require[true]");
                break :blk .syntax_failure;
            },
            71 => blk: {
                try out.writeAll("Value:i64=Attempt(Fail[\"reason\"],If(false,1/0,42))");
                const punctuation = "()[]{},;:<>=+-*/\"\\\n";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_control_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            73 => blk: {
                try out.print("var C:i64={d};set C=C+{d};Value:i64=C", .{ a, offset });
                break :blk .{ .value = a + offset };
            },
            74 => blk: {
                try out.print("var C:i64={d};First(X:i64,Y:i64)<computes>:i64=X;R:i64=Attempt(First(Set(C,C+{d}),Fail[\"abort\"]),Set(C,C+{d}));Value:i64=C", .{ a, b, offset });
                break :blk .{ .value = a + offset };
            },
            75 => blk: {
                try out.print("var C:i64={d};First(X:i64,Y:i64)<computes>:i64=X;R:i64=Attempt(First(Attempt(Set(C,C+{d}),0),Fail[\"parent\"]),Set(C,C+{d}));Value:i64=C", .{ a, b, offset });
                break :blk .{ .value = a + offset };
            },
            76 => blk: {
                try out.print("var M:map(string,i64)=map{{\"a\"=>{d}}};Frozen:map(string,i64)=M;First(X:i64,Y:i64)<computes>:i64=X;R:i64=Attempt(First(Set(M,map{{\"b\"=>{d}}}).Length,Fail[\"map\"]),M.Length);Value:i64=Or(Lookup(M,\"a\"),0)+Or(Lookup(Frozen,\"a\"),0)", .{ a, b });
                break :blk .{ .value = 2 * a };
            },
            77 => blk: {
                try out.writeAll("var C:i64=1;Bad()<computes>:i64=If(true,1,C)");
                break :blk .syntax_failure;
            },
            78 => blk: {
                try out.writeAll("var C:i64=1;Value:i64=Attempt(Set(C,9223372036854775807)+1,C)");
                break :blk .{ .failed = .arithmetic_overflow };
            },
            79 => blk: {
                try out.writeAll("var C:i64=1;Value:i64=Attempt(Set(C,2),Set(C,3));set C=C+1");
                const punctuation = "()[]{},;:<>=+-*/\"\\\n";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_state_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            81 => blk: {
                const depth = c.rng.below(35) + 1;
                c.record("language_call_depth", depth, 0);
                try out.writeAll("F0(N:i64)<computes>:i64=-N;");
                for (1..depth) |id| try out.print("F{d}(N:i64)<computes>:i64=F{d}(N);", .{ id, id - 1 });
                try out.print("Value:i64=F{d}({d})", .{ depth - 1, a });
                break :blk if (depth > 32) .{ .failed = .call_depth_limit } else .{ .value = -a };
            },
            82 => blk: {
                try out.print("var C:i64={d};Frozen:i64=C;F(N:i64)<computes>:i64=N+Frozen;G(N:i64)<computes>:i64=F(N)*2;set C=9;Value:i64=G({d})", .{ a, offset });
                break :blk .{ .value = (a + offset) * 2 };
            },
            83 => blk: {
                try out.print("Make(N:i64)<computes>:map(i64,i64)=map{{1=>N,2=>N+1}};Read(N:i64)<computes>:i64=Or(Lookup(Make(N),2),0);A:map(i64,i64)=Make({d});Held:map(i64,i64)=A;B:map(i64,i64)=Make({d});Value:i64=Read({d})+Or(Lookup(Held,1),0)", .{ a, offset, a });
                break :blk .{ .value = a * 2 + 1 };
            },
            84 => blk: {
                try out.writeAll("var C:i64=1;Bad(N:i64)<computes>:i64=1/N;Value:i64=Attempt(Set(C,9)+Bad(0),0)");
                break :blk .{ .failed = .division_by_zero };
            },
            85 => blk: {
                try out.writeAll("Self(N:i64)<computes>:i64=Self(N);Value:i64=Self(1)");
                break :blk .{ .failed = .call_depth_limit };
            },
            86 => blk: {
                try out.print("F(N:i64)<computes>:i64=N+1;G(N:i64)<computes>:i64=If(N>0,F(N),F(N+2));Value:i64=G({d})", .{a});
                break :blk .{ .value = if (a > 0) a + 1 else a + 3 };
            },
            87 => blk: {
                try out.writeAll("F(N:i64)<computes>:tuple(i64,float)=tuple{N+1,-0.0};Value:i64=F(3)(0)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_call_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            160 => blk: {
                try out.print("Make(N:i64)<computes>:function(tuple(i64),i64)=Fn[A:i64=N](X:i64)<computes>:i64{{A+X}};var Cell:i64={d};F:function(tuple(i64),i64)=Make(Cell);set Cell=100;Value:i64=F({d})", .{ a, b });
                break :blk .{ .value = a + b };
            },
            161 => blk: {
                const seed: i64 = @intCast(c.rng.below(16));
                const amount: i64 = if (@mod(seed, 2) == 0) 1 else 2;
                var expected = seed;
                var cell: i64 = 5;
                while (true) {
                    cell += amount;
                    if (expected == 5) {
                        expected = seed;
                        cell = 5;
                        break;
                    }
                    if (expected >= 8) break;
                    expected += amount;
                }
                try out.print("var C:i64=5;Make(A:i64)<computes>:function<transacts><decides>(tuple(i64),option(i64))=Fn[Amount:i64=A](N:i64)<transacts><decides>:option(i64){{Block{{set C=C+Amount;Require[N!=5];If(N<8,option{{N+Amount}},option{{}})}}}};A:i64=Attempt(Loop(Make({d}),{d}),{d});Value:i64=A+C", .{ amount, seed, seed });
                break :blk .{ .value = expected + cell };
            },
            162 => blk: {
                try out.print("F:function(tuple(i64),function(tuple(i64),i64))=Fn[A:i64={d}](B:i64)<computes>:function(tuple(i64),i64){{Fn[Sum:i64=A+B](C:i64)<computes>:i64{{Sum+C}}}};Value:i64=F({d})(7)", .{ a, b });
                break :blk .{ .value = a + b + 7 };
            },
            163 => blk: {
                const visits: i64 = @intCast(c.rng.below(16));
                const amount: i64 = @intCast(c.rng.below(3) + 1);
                try out.print("F:function(tuple(i64),i64)=Fn[Amount:i64={d}](N:i64)<computes>:i64{{N+Amount}};Value:i64=Iterate(F,{d},{d})", .{ amount, visits, a });
                break :blk .{ .value = a + visits * amount };
            },
            164 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=Fn[Again:function(tuple(i64),i64)=F,Next:i64=N]()<computes>:i64{Again(Next)}();Value:i64=Attempt(F(0),0)");
                break :blk .{ .failed = .call_depth_limit };
            },
            165 => blk: {
                try out.writeAll("F:function(tuple(i64),i64)=Fn[A:i64=2](N:i64)<computes>:i64{A+N};Value:i64=F(40)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_anonymous_function_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            166 => blk: {
                try out.print("Identity[T:type](X:T)<computes>:T{{X}};Value:i64=Identity[i64]({d})+{d}", .{ a, b });
                break :blk .{ .value = a + b };
            },
            167 => blk: {
                try out.print("Twice[T:type](F:function(tuple(T),T),X:T)<computes>:T{{F(F(X))}};Add(N:i64)<computes>:i64=N+{d};Value:i64=Twice[i64](Add,{d})", .{ b, a });
                break :blk .{ .value = a + 2 * b };
            },
            168 => blk: {
                try out.writeAll("Identity[T:type](X:T)<computes>:T{X};Value:i64=Identity[i64](40)+Identity[i64](2)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_generic_function_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            169 => blk: {
                try out.print("Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{{F(F(X))}};Add(N:i64)<computes>:i64=N+{d};Value:i64=Apply[computes,i64](Add,{d})", .{ b, a });
                break :blk .{ .value = a + 2 * b };
            },
            170 => blk: {
                const start: i64 = @intCast(c.rng.below(32));
                try out.print("var C:i64={d};Apply[E:effect,T:type](F:function<E>(tuple(T),T),X:T)<E>:T{{F(F(X))}};Bump(N:i64)<transacts>:i64=Block{{set C=C+N;C}};Value:i64=Apply[transacts,i64](Bump,{d})", .{ start, b });
                break :blk .{ .value = 2 * (start + b) };
            },
            171 => blk: {
                try out.writeAll("Pass[E:effect](F:function<E>(tuple(i64),i64),X:i64)<E>:i64{F[X]};Pos(N:i64)<computes><decides>:i64=Block{Require[N>0];N};Value:i64=Attempt(Pass[computes<decides>][Pos,7],0)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_effect_function_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            172 => blk: {
                const length: usize = @intCast(c.rng.below(6) + 1);
                const position: i64 = @as(i64, @intCast(c.rng.below(10))) - 2;
                var values: [6]i64 = undefined;
                try out.writeAll("Items:[]i64=array{");
                for (0..length) |element| {
                    values[element] = @as(i64, @intCast(c.rng.below(200))) - 100;
                    try out.print("{s}{d}", .{ if (element == 0) "" else ",", values[element] });
                }
                try out.print("}};Value:i64=Attempt(Items[{d}],{d})", .{ position, a });
                break :blk .{ .value = if (position >= 0 and position < length) values[@intCast(position)] else a };
            },
            173 => blk: {
                try out.writeAll("Items:[]i64=array{4,5,6};Pick(I:i64)<computes>:i64=Attempt(Items[I],-1);Value:i64=Pick(2)+Pick(7)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_array_index_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            174 => blk: {
                const k: i64 = @as(i64, @intCast(c.rng.below(8001))) - 4000;
                const q = @divFloor(k, 4);
                const r = k - 4 * q;
                const mode = c.rng.below(4);
                const names = [_][]const u8{ "Floor", "Ceil", "Round", "Int" };
                const name = names[@intCast(mode)];
                try out.print("Value:i64=Attempt({s}[{d:.2}],{d})", .{ name, @as(f64, @floatFromInt(k)) / 4.0, a });
                break :blk .{ .value = switch (mode) {
                    0 => q,
                    1 => if (r == 0) q else q + 1,
                    2 => if (r < 2) q else if (r > 2) q + 1 else if (@mod(q, 2) == 0) q else q + 1,
                    else => @divTrunc(k, 4),
                } };
            },
            175 => blk: {
                try out.print("Value:i64=Attempt(Floor[ToFloat({d})],0)", .{a});
                break :blk .{ .value = a };
            },
            176 => blk: {
                try out.writeAll("Big:float=1.0e30;Pick(X:float)<computes>:i64=Attempt(Round[X],-1);Value:i64=Pick(2.5)+Pick(Big)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_numeric_conversion_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            177 => blk: {
                const length: usize = @intCast(c.rng.below(8) + 1);
                var values: [8]i64 = undefined;
                var total: i64 = 0;
                var biggest: i64 = std.math.minInt(i64);
                try out.writeAll("Sum:=native{\"std.sum\"};Max:=native{\"std.max\"};Items:[]i64=array{");
                for (0..length) |element| {
                    values[element] = @as(i64, @intCast(c.rng.below(2000))) - 1000;
                    total += values[element];
                    biggest = @max(biggest, values[element]);
                    try out.print("{s}{d}", .{ if (element == 0) "" else ",", values[element] });
                }
                try out.writeAll("};Value:i64=Sum(Items)+Or(Max(Items),0)");
                break :blk .{ .value = total + biggest };
            },
            178 => blk: {
                const count: i64 = @intCast(c.rng.below(40));
                try out.print("Sum:=native{{\"std.sum\"}};Range:=native{{\"std.range\"}};Value:i64=Sum(Range({d}))", .{count});
                break :blk .{ .value = @divExact(count * (count - 1), 2) };
            },
            179 => blk: {
                try out.writeAll("Sum:=native{\"std.sum\"};Sorted:=native{\"std.sorted\"};Value:i64=Sum(Sorted(array{5,1,3}))");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_native_call_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            180 => blk: {
                const left: usize = @intCast(c.rng.below(12));
                const right: usize = @intCast(c.rng.below(12));
                try out.writeAll("Value:i64=(\"");
                for (0..left) |_| try out.writeByte('a' + @as(u8, @intCast(c.rng.below(26))));
                try out.writeAll("\"+\"");
                for (0..right) |_| try out.writeByte('a' + @as(u8, @intCast(c.rng.below(26))));
                try out.writeAll("\"+\"\u{96EA}\").Length");
                break :blk .{ .value = @intCast(left + right + 3) };
            },
            181 => blk: {
                try out.print("ParseInt:=native{{\"std.parse_int\"}};Value:i64=Or(ParseInt(ToString({d})),0)", .{a});
                break :blk .{ .value = a };
            },
            182 => blk: {
                try out.writeAll("Upper:=native{\"std.upper\"};Value:string=\"<\"+Upper(\"ab\")+ToString(7)+\">\"");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_string_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            183 => blk: {
                try out.print("Rec:=struct{{A:i64=0,B:i64=0}};var R:Rec=Rec{{}};set R.A={d};set R.B+=R.A+{d};Value:i64=R.A+R.B", .{ a, b });
                break :blk .{ .value = a + a + b };
            },
            184 => blk: {
                try out.print("var Xs:[]i64=array{{1,2,3}};Put()<transacts><decides>:i64=Block{{set Xs[1]={d};set Xs[2]+={d};Xs[1]+Xs[2]}};Miss:i64=Attempt(Block{{set Xs[5]=1;1}},-9);Value:i64=Attempt(Put[],-1)+Miss", .{ a, b });
                break :blk .{ .value = a + 3 + b - 9 };
            },
            185 => blk: {
                try out.print("N:i64={d};Value:i64=\"n={{N}}|{{N+{d}}}\".Length", .{ a, b });
                var expected_text: [96]u8 = undefined;
                const text = std.fmt.bufPrint(&expected_text, "n={d}|{d}", .{ a, a + b }) catch unreachable;
                break :blk .{ .value = @intCast(text.len) };
            },
            186 => blk: {
                try out.print("Make(N:i64)<computes>:function(tuple(i64),i64)=Fn(X:i64){{N*X}};Scale(K:i64)<computes>:i64=Iterate(Fn(S:i64){{S+K}},{d},0);Value:i64=Make({d})({d})+Scale({d})", .{ b, a, b, offset });
                break :blk .{ .value = a * b + offset * b };
            },
            187 => blk: {
                try out.print("Sum:=native{{\"std.sum\"}};Items:[]i64=array{{1,2,3,4}};Value:i64=Sum(For(X:Items,X*{d}))+Sum(For(I->X:Items,X>2,X+I+{d}))", .{ b, offset });
                break :blk .{ .value = 10 * b + (3 + 2 + offset) + (4 + 3 + offset) };
            },
            188 => blk: {
                try out.print("var M:map(i64,i64)=map{{1=>10}};set M[{d}]={d};set M[1]=5;Maybe:option(i64)=option{{{d}}};Value:i64=Attempt(M[{d}],-1)+Attempt(Maybe?,0)", .{ b, a, offset, b });
                break :blk .{ .value = (if (b == 1) @as(i64, 5) else a) + offset };
            },
            189 => blk: {
                try out.print("Make(A:i64,B:i64=5,C:i64=7)<computes>:i64=A*100+B*10+C;Value:i64=Make({d})+Make({d},C:={d})+Make(C:=1,A:={d},B:=2)", .{ b, b, offset, a });
                break :blk .{ .value = (b * 100 + 57) + (b * 100 + 50 + offset) + (a * 100 + 21) };
            },
            190 => blk: {
                try out.print("Items:[]i64=array{{10,20,30}};Pick(I:i64)<computes>:i64=If(X:=Items[I],X>{d},X*2,0);Value:i64=Pick(0)+Pick(2)+Pick(9)+Block{{(P,Q):=tuple{{{d},{d}}};P*Q}}", .{ b, b, offset });
                const first: i64 = if (10 > b) 20 else 0;
                const third: i64 = if (30 > b) 60 else 0;
                break :blk .{ .value = first + third + b * offset };
            },
            191 => blk: {
                try out.print("Run(N:i64)<transacts>:i64=Block{{var I:i64=0;var Acc:i64=0;While(I<N,Block{{set Acc=Acc+I*{d};set I=I+1}});Acc}};Value:i64=Run({d})", .{ offset, b });
                var expected_sum: i64 = 0;
                var turn: i64 = 0;
                while (turn < b) : (turn += 1) expected_sum += turn * offset;
                break :blk .{ .value = expected_sum };
            },
            192 => blk: {
                try out.print("Mix(N:i64)<computes>:i64=N*2;Mix(S:string)<computes>:i64=S.Length;Mix(N:i64,M:i64)<computes>:i64=N-M;Value:i64=Mix({d})+Mix(\"hello\")+Mix({d},{d})", .{ a, b, offset });
                break :blk .{ .value = 2 * a + 5 + (b - offset) };
            },
            193 => blk: {
                const index: i64 = @mod(b, 5);
                try out.print("Items:[]i64=array{{1,2}};Absent(I:i64)<computes><decides>:i64=Block{{Not[Items[I]];{d}}};Value:i64=Attempt(Absent[{d}],-1)", .{ a, index });
                break :blk .{ .value = if (index >= 2) a else -1 };
            },
            194, 195 => blk: {
                // Euclidean division (RFC-0070): the remainder is never negative, the quotient
                // is what restores the dividend, and a zero divisor fails softly.
                try out.print("Value:i64=Attempt({s}[{d},{d}],{d})", .{ if (kind == 194) "Quotient" else "Mod", a, offset, b });
                if (offset == 0) break :blk .{ .value = b };
                const remainder = @mod(a, @as(i64, @intCast(@abs(offset))));
                break :blk .{ .value = if (kind == 194) @divExact(a - remainder, offset) else remainder };
            },
            196 => blk: {
                // The one pair whose quotient does not fit is fatal for both, inside `Attempt` too.
                try out.print("Least:i64=-9223372036854775807-1;Value:i64=Attempt({s}[Least,-1],{d})", .{ if (a < 0) "Quotient" else "Mod", b });
                break :blk .{ .failed = .arithmetic_overflow };
            },
            197 => blk: {
                // Rounding an exact fraction both ways, whatever the signs of its terms.
                try out.print("R:rational=Attempt(Rational[{d},{d}],MakeRationalFromInt({d}));Value:i64=Floor(R)*4+Ceil(R)+Floor(R+R-R*MakeRationalFromInt(2))", .{ a, offset, b });
                if (offset == 0) break :blk .{ .value = 5 * b };
                const down = @divFloor(a, offset);
                const up = -@divFloor(-a, offset);
                break :blk .{ .value = down * 4 + up };
            },
            198 => blk: {
                // Order and equality of fractions by exact cross products.
                try out.print("Z:rational=MakeRationalFromInt(0);P:rational=Attempt(Rational[{d},{d}],Z);Q:rational=Attempt(Rational[{d},{d}],Z);Value:logic=P<Q and not (P>=Q) and P!=Q or P==Q and P<=Q and Attempt(Rational[{d},{d}],Z)==P", .{ a, b, offset, b + 1, 3 * a, 3 * b });
                break :blk .{ .boolean = a * (b + 1) <= offset * b };
            },
            154 => blk: {
                try out.print("Add(A:i64,B:i64)<computes>:i64=A+B;Make(N:i64)<computes>:function(tuple(i64),i64)=Bind(Add,N);var Cell:i64={d};F:function(tuple(i64),i64)=Make(Cell);set Cell=100;Value:i64=F({d})", .{ a, b });
                break :blk .{ .value = a + b };
            },
            155 => blk: {
                const seed: i64 = @intCast(c.rng.below(16));
                const amount: i64 = if (@mod(seed, 2) == 0) 1 else 2;
                var expected = seed;
                var cell: i64 = 5;
                while (true) {
                    cell += amount;
                    if (expected == 5) {
                        expected = seed;
                        cell = 5;
                        break;
                    }
                    if (expected >= 8) break;
                    expected += amount;
                }
                try out.print("var C:i64=5;Step(A:i64,N:i64)<transacts><decides>:option(i64)=Block{{set C=C+A;Require[N!=5];If(N<8,option{{N+A}},option{{}})}};Make(A:i64)<computes>:function<transacts><decides>(tuple(i64),option(i64))=Bind(Step,A);A:i64=Attempt(Loop(Make({d}),{d}),{d});Value:i64=A+C", .{ amount, seed, seed });
                break :blk .{ .value = expected + cell };
            },
            156 => blk: {
                try out.print("Sum(A:i64,B:i64,C:i64)<computes>:i64=A+B+C;F:function(tuple(i64),i64)=Bind(Bind(Sum,{d}),{d});Value:i64=F(7)", .{ a, b });
                break :blk .{ .value = a + b + 7 };
            },
            157 => blk: {
                const visits: i64 = @intCast(c.rng.below(16));
                const amount: i64 = @intCast(c.rng.below(3) + 1);
                try out.print("Step(A:i64,N:i64)<computes>:i64=N+A;F:function(tuple(i64),i64)=Bind(Step,{d});Value:i64=Iterate(F,{d},{d})", .{ amount, visits, a });
                break :blk .{ .value = a + visits * amount };
            },
            158 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=Bind(F,N)();Value:i64=Attempt(F(0),0)");
                break :blk .{ .failed = .call_depth_limit };
            },
            159 => blk: {
                try out.writeAll("Add(A:i64,B:i64)<computes>:i64=A+B;F:function(tuple(i64),i64)=Bind(Add,2);Value:i64=F(40)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_bound_function_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            148 => blk: {
                const limit = a + @as(i64, @intCast(c.rng.below(25)));
                const increment: i64 = @intCast(c.rng.below(3) + 1);
                var expected = a;
                while (expected < limit) expected += increment;
                try out.print("F(X:i64)<computes>:option(i64)=If(X<{d},option{{X+{d}}},option{{}});Run(G:function(tuple(i64),option(i64)),N:i64)<computes>:i64=Loop(G,N);Value:i64=Run(F,{d})", .{ limit, increment, a });
                break :blk .{ .value = expected };
            },
            149 => blk: {
                const seed: i64 = @intCast(c.rng.below(16));
                var expected = seed;
                var cell: i64 = 5;
                while (true) {
                    cell += 1;
                    if (expected == 5) {
                        expected = seed;
                        cell = 5;
                        break;
                    }
                    if (expected >= 8) break;
                    expected += if (@mod(seed, 2) == 0) 1 else 2;
                }
                try out.print("var C:i64=5;One(N:i64)<transacts><decides>:option(i64)=Block{{set C=C+1;Require[N!=5];If(N<8,option{{N+1}},option{{}})}};Two(N:i64)<transacts><decides>:option(i64)=Block{{set C=C+1;Require[N!=5];If(N<8,option{{N+2}},option{{}})}};A:i64=Attempt(Loop(If({s},One,Two),{d}),{d});Value:i64=A+C", .{ if (@mod(seed, 2) == 0) "true" else "false", seed, seed });
                break :blk .{ .value = expected + cell };
            },
            150 => blk: {
                try out.writeAll("Stop(X:i64)<computes>:option(i64)=option{};Step(X:i64)<computes>:option(i64)=If(X<42,option{X+1},option{});var V:function(tuple(i64),option(i64))=Step;Change()<transacts>:i64=Block{set V=Stop;39};Value:i64=Loop(V,Change())");
                break :blk .{ .value = 42 };
            },
            151 => blk: {
                try out.writeAll("F(N:i64)<computes>:option(i64)=option{Loop(F,N)};Value:i64=Attempt(Loop(F,0),0)");
                break :blk .{ .failed = .call_depth_limit };
            },
            152 => blk: {
                const limit = a + @as(i64, @intCast(c.rng.below(25)));
                try out.print("F(X:tuple(i64,string))<computes>:option(tuple(i64,string))=If(X(0)<{d},option{{tuple{{X(0)+1,X(1)}}}},option{{}});Box:=struct{{F:function(tuple(tuple(i64,string)),option(tuple(i64,string)))=F}};Make()<computes>:Box=Box{{}};S:tuple(i64,string)=Loop(Make().F,tuple{{{d},\"雪\"}});Value:i64=S(0)", .{ limit, a });
                break :blk .{ .value = limit };
            },
            153 => blk: {
                try out.writeAll("F(N:i64)<computes>:option(i64)=If(N<42,option{N+1},option{});Value:i64=Loop(F,40)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_state_loop_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            142 => blk: {
                const count = c.rng.below(25);
                try out.print("F(X:i64)<computes>:i64=X+({d});Run(G:function(tuple(i64),i64),N:i64,X:i64)<computes>:i64=Iterate(G,N,X);Value:i64=Run(F,{d},{d})", .{ offset, count, a });
                break :blk .{ .value = a + @as(i64, @intCast(count)) * offset };
            },
            143 => blk: {
                const count = c.rng.below(19);
                const selected = c.rng.below(2) == 0;
                var expected = a;
                var cell: i64 = 5;
                for (0..count) |_| {
                    if (expected < 3) {
                        cell += expected;
                        expected += if (selected) 2 else 1;
                    } else expected -= if (selected) 7 else 5;
                }
                try out.print("var C:i64=5;F(X:i64)<transacts>:i64=Attempt(Block{{Set(C,C+X);Require[X<3];X+2}},X-7);G(X:i64)<transacts>:i64=Attempt(Block{{Set(C,C+X);Require[X<3];X+1}},X-5);A:i64=Iterate(If({s},F,G),{d},{d});Value:i64=A+C", .{ if (selected) "true" else "false", count, a });
                break :blk .{ .value = expected + cell };
            },
            144 => blk: {
                try out.writeAll("F(X:i64)<computes>:i64=X+1;G(X:i64)<computes>:i64=X*2;var V:function(tuple(i64),i64)=F;Change()<transacts>:i64=Block{set V=G;3};Value:i64=Iterate(V,Change(),39)");
                break :blk .{ .value = 42 };
            },
            145 => blk: {
                try out.writeAll("F(X:i64)<computes>:i64=Iterate(F,1,X);Value:i64=Attempt(F(0),0)");
                break :blk .{ .failed = .call_depth_limit };
            },
            146 => blk: {
                const n = c.rng.below(25);
                try out.print("F(X:tuple(i64,string))<computes>:tuple(i64,string)=tuple{{X(0)+1,X(1)}};Box:=struct{{F:function(tuple(tuple(i64,string)),tuple(i64,string))=F}};Make()<computes>:Box=Box{{}};S:tuple(i64,string)=Iterate(Make().F,{d},tuple{{{d},\"雪\"}});Value:i64=S(0)", .{ n, a });
                break :blk .{ .value = a + @as(i64, @intCast(n)) };
            },
            147 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=N+1;Value:i64=Iterate((F),2,40)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_callable_iteration_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            136 => blk: {
                try out.print("F(X:i64)<computes>:i64=X+({d});Apply(G:function(tuple(i64),i64),X:i64)<computes>:i64=G(X);Value:i64=Apply(F,{d})", .{ offset, a });
                break :blk .{ .value = a + offset };
            },
            137 => blk: {
                const selected = c.rng.below(2) == 0;
                const argument: i64 = if (c.rng.below(2) == 0) b else -b;
                const factor: i64 = if (selected) 1 else 2;
                try out.print("var C:i64=5;F(N:i64)<transacts><decides>:i64=Block{{set C=C+N;Require[N>0];C}};G(N:i64)<transacts><decides>:i64=Block{{set C=C+2*N;Require[N>0];C}};V:function<transacts><decides>(tuple(i64),i64)=If({s},F,G);A:i64=Attempt(V[{d}],C);Value:i64=A+C", .{ if (selected) "true" else "false", argument });
                break :blk .{ .value = if (argument > 0) 2 * (5 + factor * argument) else 10 };
            },
            138 => blk: {
                try out.print("F(X:i64)<computes>:i64=X+({d});Box:=struct{{F:function(tuple(i64),i64)=F}};Make()<computes>:Box=Box{{}};B:Box=Make();Value:i64=B.F({d})", .{ offset, a });
                break :blk .{ .value = a + offset };
            },
            139 => blk: {
                try out.writeAll("Apply(F:function(tuple(i64),i64),N:i64)<computes>:i64=F(N);Spin(N:i64)<computes>:i64=Apply(Spin,N);Value:i64=Attempt(Spin(0),0)");
                break :blk .{ .failed = .call_depth_limit };
            },
            140 => blk: {
                try out.print("F(X:i64)<computes>:i64=X+({d});G(X:i64)<computes>:i64=X*2;Choose(X:i64)<transacts>:i64=Block{{var V:function(tuple(i64),i64)=F;Ignored:i64=Attempt(Block{{set V=G;Require[false];0}},0);V(X)}};Value:i64=Choose({d})", .{ offset, a });
                break :blk .{ .value = a + offset };
            },
            141 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=N+1;V:function(tuple(i64),i64)=F;Value:i64=V(41)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_callable_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            130 => blk: {
                const count = c.rng.below(25);
                try out.print("F(N:i64,X:i64)<computes>:i64=If(N==0,X,F(N-1,X+({d})));Value:i64=F({d},{d})", .{ offset, count, a });
                break :blk .{ .value = a + @as(i64, @intCast(count)) * offset };
            },
            131 => blk: {
                const n = c.rng.below(24);
                var expected: i64 = offset;
                var cell: i64 = 5;
                for (0..n + 1) |depth| {
                    const current = @as(i64, @intCast(n - depth));
                    if (@rem(current, 3) == 0) {
                        expected += 10;
                    } else {
                        expected += current;
                        cell += current;
                    }
                }
                try out.print("var C:i64=5;F(N:i64,X:i64)<transacts>:i64=Block{{V:i64=Attempt(Block{{set C=C+N;Require[N/3*3!=N];X+N}},X+10);If(N==0,V,F(N-1,V))}};A:i64=F({d},{d});Value:i64=A+C", .{ n, offset });
                break :blk .{ .value = expected + cell };
            },
            132 => blk: {
                const count = c.rng.below(25);
                try out.print("F(N:i64,X:tuple(i64,string))<computes>:tuple(i64,string)=If(N==0,X,F(N-1,tuple{{X(0)+1,X(1)}}));S:tuple(i64,string)=F({d},tuple{{{d},\"雪\"}});Value:i64=S(0)", .{ count, a });
                break :blk .{ .value = a + @as(i64, @intCast(count)) };
            },
            133 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=If(N==0,42,F(N-1));Value:i64=Attempt(F(32),0)");
                break :blk .{ .failed = .call_depth_limit };
            },
            134 => blk: {
                const count = c.rng.below(25);
                try out.print("var C:i64=5;F(N:i64)<transacts><decides>:i64=Block{{set C=C+1;If(N==0,Block{{Require[false];N}},F[N-1])}};A:i64=Attempt(F[{d}],C);Value:i64=A+C", .{count});
                break :blk .{ .value = 10 };
            },
            135 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=If(N==0,7,F(N-1));Value:i64=F(4)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_recursion_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            124 => blk: {
                const count = c.rng.below(25);
                try out.print("F(X:i64)<computes>:i64=X+({d});Value:i64=Iterate(F,{d},{d})", .{ offset, count, a });
                break :blk .{ .value = a + @as(i64, @intCast(count)) * offset };
            },
            125 => blk: {
                const count = c.rng.below(19);
                var expected: i64 = offset;
                var cell: i64 = 5;
                for (0..count) |_| {
                    if (expected < 3) {
                        cell += expected;
                        expected += 2;
                    } else expected -= 7;
                }
                try out.print("var C:i64=5;F(X:i64)<transacts>:i64=Attempt(Block{{Set(C,C+X);If(Require[X<3],X+2,X)}},X-7);A:i64=Iterate(F,{d},{d});Value:i64=A+C", .{ count, offset });
                break :blk .{ .value = expected + cell };
            },
            126 => blk: {
                const count = c.rng.below(17);
                try out.print("F(X:tuple(i64,string))<computes>:tuple(i64,string)=tuple{{X(0)+1,X(1)}};S:tuple(i64,string)=Iterate(F,{d},tuple{{{d},\"雪\"}});Value:i64=S(0)", .{ count, a });
                break :blk .{ .value = a + @as(i64, @intCast(count)) };
            },
            127 => blk: {
                try out.writeAll("Id(X:i64)<computes>:i64=X;Value:i64=Iterate(Id,-1,3)");
                break :blk .{ .failed = .negative_iteration_count };
            },
            128 => blk: {
                const count = c.rng.below(33);
                try out.print("Id(X:i64)<computes>:i64=X;Value:i64=Iterate(Id,{d},{d})", .{ count, a });
                break :blk .{ .value = a };
            },
            129 => blk: {
                try out.writeAll("F(X:i64)<computes>:i64=Attempt(If(Require[X<3],X+1,X),X-7);Value:i64=Iterate(F,4,0)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_iteration_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            118 => blk: {
                try out.print("var C:i64={d};F(N:i64)<transacts>:i64=Block{{var X:i64={d};Old:i64=X;R:i64=Attempt(Block{{If(Block{{set X=X+1;N>=0}},Set(X,X+N),Set(X,X-N));Set(C,C+X);If(Require[N>=0],X,X)}},Block{{set X=X+7;Set(C,C+X);X}});Old+R+X}};A:i64=F({d});Value:i64=A+C", .{ a, a, offset });
                break :blk .{ .value = 2 * a + 3 * (if (offset >= 0) a + 1 + offset else a + 7) };
            },
            119 => blk: {
                try out.print("F(N:i64)<transacts>:i64=Block{{var X:i64=N;If(Block{{Set(X,X+1);false}},Set(X,X+10),Set(X,X+100));X}};Value:i64=F({d})", .{a});
                break :blk .{ .value = a + 101 };
            },
            120 => blk: {
                try out.writeAll("var C:i64=1;F()<transacts>:i64=Block{var X:i64=1;Set(X,3);Set(C,3);1/0;X};Value:i64=Attempt(F(),9)");
                break :blk .{ .failed = .division_by_zero };
            },
            121 => blk: {
                try out.print("F(N:i64)<transacts>:map(string,i64)=Block{{var M:map(string,i64)=map{{\"雪\"=>N}};Held:map(string,i64)=M;Attempt(Block{{Set(M,map{{\"雪\"=>N+1}});Fail[\"undo\"];M}},M);Held}};Value:i64=Or(Lookup(F({d}),\"雪\"),0)", .{a});
                break :blk .{ .value = a };
            },
            122 => blk: {
                const count = 1 + c.rng.below(257);
                c.record("language_mutable_local_capacity", count, 0);
                try out.writeAll("Value:i64=Block{");
                for (0..count) |id| try out.print("var X{d}:i64=1;", .{id});
                try out.writeAll("X0}");
                break :blk if (count > types.limits.local_bindings) .syntax_failure else .{ .value = 1 };
            },
            123 => blk: {
                try out.writeAll("F()<transacts>:i64=Block{var X:i64=1;Attempt(Block{Set(X,3);Fail[\"undo\"];X},Set(X,7));X};Value:i64=F()");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_mutable_local_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            112 => blk: {
                // A local may not take the name of a parameter, nor an inner local that of an
                // outer one (RFC-0076): either is refused, and with names of their own the
                // blocks have the value they had when the inner name hid the outer.
                const shadowed = c.rng.below(3);
                c.record("language_shadowed_local", shadowed, 0);
                const outer: []const u8 = if (shadowed == 1) "N" else "M";
                const inner: []const u8 = if (shadowed == 2) outer else "K";
                try out.print("Base:i64={d};F(N:i64)<computes>:i64=Block{{{s}:i64=N+{d};Inner:i64=Block{{{s}:i64={s}+2;{s}*3}};{s}+Inner}};Value:i64=F(Base)", .{ a, outer, offset, inner, outer, inner, outer });
                break :blk if (shadowed != 0) .syntax_failure else .{ .value = 4 * (a + offset) + 6 };
            },
            113 => blk: {
                try out.print("var C:i64={d};F(N:i64)<transacts>:i64=Block{{Old:i64=C;R:i64=Attempt(Block{{M:i64=Set(C,C+N);If(Require[M>=0],M,M)}},Block{{M:i64=Set(C,Old+7);M}});Old+R}};A:i64=F({d});Value:i64=A+C", .{ a, offset });
                break :blk .{ .value = a + 2 * (if (a + offset >= 0) a + offset else a + 7) };
            },
            114 => blk: {
                try out.writeAll("var C:i64=1;F()<transacts>:i64=Block{Set(C,3);1/0;7};Value:i64=Attempt(F(),9)");
                break :blk .{ .failed = .division_by_zero };
            },
            115 => blk: {
                try out.print("F(N:i64)<computes>:map(string,i64)=Block{{M:map(string,i64)=map{{\"雪\"=>N}};M}};Value:i64=Block{{M:map(string,i64)=F({d});R:i64=Or(Lookup(M,\"雪\"),0);R}}", .{a});
                break :blk .{ .value = a };
            },
            116 => blk: {
                const count = 1 + c.rng.below(257);
                c.record("language_block_live_locals", count, 0);
                try out.writeAll("Value:i64=Block{");
                for (0..count) |id| try out.print("X{d}:i64=1;", .{id});
                try out.writeAll("X0}");
                break :blk if (count > types.limits.local_bindings) .syntax_failure else .{ .value = 1 };
            },
            117 => blk: {
                try out.writeAll("F(N:i64)<computes>:i64=Block{N:i64=N+1;Inner:i64=Block{N:i64=N+2;N};N+Inner};Value:i64=F(4)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_block_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            106 => blk: {
                try out.print("var C:i64={d};Add(N:i64)<transacts>:i64=Set(C,C+N);A:i64=Add({d});Value:i64=Add({d})+C", .{ a, b, offset });
                break :blk .{ .value = 2 * (a + b + offset) };
            },
            107 => blk: {
                try out.print("var C:i64={d};First(A:i64,B:i64)<computes>:i64=A;Leaf(N:i64)<transacts><decides>:i64=First(Set(C,C+N),If(Require[N>=0],C,C));Own(N:i64)<transacts>:i64=Attempt(Leaf[N],Set(C,C+7));A:i64=Own({d});B:i64=Attempt(Leaf[{d}],C);Value:i64=C+A+B", .{ a, offset, -b });
                break :blk .{ .value = 3 * (a + if (offset >= 0) offset else @as(i64, 7)) };
            },
            108 => blk: {
                try out.print("var M:map(string,i64)=map{{\"old\"=>{d}}};Change(N:i64)<transacts><decides>:map(string,i64)=If(Require[N>=0],Set(M,map{{\"雪\"=>N}}),M);Held:map(string,i64)=M;A:map(string,i64)=Attempt(Change[{d}],Held);Value:i64=Or(Lookup(M,\"雪\"),Or(Lookup(M,\"old\"),0))", .{ a, offset });
                break :blk .{ .value = if (offset >= 0) offset else a };
            },
            109 => blk: {
                try out.writeAll("var C:i64=1;First(A:i64,B:i64)<computes>:i64=A;Leaf()<transacts><decides>:i64=First(Set(C,3),Fail[\"stop\"]);Own()<transacts>:i64=Attempt(Leaf[],Set(C,1/0));Value:i64=Attempt(Own(),9)");
                break :blk .{ .failed = .division_by_zero };
            },
            110 => blk: {
                const depth = 1 + c.rng.below(34);
                c.record("language_transactional_source_depth", depth, 0);
                try out.writeAll("var C:i64=1;F()<transacts>:i64=");
                for (0..depth) |_| try out.writeAll("Attempt(");
                try out.writeAll("Set(C,7)");
                for (0..depth) |_| try out.writeAll(",8)");
                try out.writeAll(";Value:i64=F()");
                break :blk if (depth > 32) .syntax_failure else .{ .value = 7 };
            },
            111 => blk: {
                try out.writeAll("var C:i64=1;Leaf(N:i64)<transacts><decides>:i64=If(Require[N>=0],Set(C,N),C);Own()<transacts>:i64=Attempt(Leaf[-1],Set(C,7));Value:i64=Own()+C");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_transactional_frame_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            100 => blk: {
                try out.print("Leaf(N:i64)<computes><decides>:i64=If(Require[N>0],N+3,N);Chain(N:i64)<computes><decides>:i64=Leaf[N]*2;Own(N:i64)<computes>:i64=Attempt(Chain[N],7);Value:i64=Attempt(Own({d})+Chain[{d}],9)", .{ a, offset });
                break :blk .{ .value = if (offset <= 0) 9 else (if (a > 0) (a + 3) * 2 else @as(i64, 7)) + (offset + 3) * 2 };
            },
            101 => blk: {
                try out.print("var C:i64=1;First(A:i64,B:i64)<computes>:i64=A;Leaf()<computes><decides>:i64=Fail[\"stop\"];Chain()<computes><decides>:i64=Leaf[];R:i64=Attempt(First(Set(C,{d}),Chain[]),C);Value:i64=C+R", .{a});
                break :blk .{ .value = 2 };
            },
            102 => blk: {
                try out.print("Leaf(N:i64)<computes><decides>:map(string,i64)=If(Require[N>=0],map{{\"雪\"=>N}},map{{}});Chain(N:i64)<computes><decides>:map(string,i64)=Leaf[N];M:map(string,i64)=Attempt(Chain[{d}],map{{\"fallback\"=>7}});Value:i64=Or(Lookup(M,\"雪\"),Or(Lookup(M,\"fallback\"),0))", .{a});
                break :blk .{ .value = if (a >= 0) a else 7 };
            },
            103 => blk: {
                try out.writeAll("var C:i64=1;Leaf()<computes><decides>:i64=Attempt(Fail[\"caught\"],1/0);Chain()<computes><decides>:i64=Leaf[];set C=2;Value:i64=Attempt(Chain[],9)");
                break :blk .{ .failed = .division_by_zero };
            },
            104 => blk: {
                const depth = 1 + c.rng.below(35);
                c.record("language_failable_call_depth", depth, 0);
                try out.writeAll("F0()<computes><decides>:i64=Fail[\"deep\"];");
                for (1..depth) |id| try out.print("F{d}()<computes><decides>:i64=F{d}[];", .{ id, id - 1 });
                try out.print("Value:i64=Attempt(F{d}[],7)", .{depth - 1});
                break :blk if (depth > 32) .{ .failed = .call_depth_limit } else .{ .value = 7 };
            },
            105 => blk: {
                try out.writeAll("F(L:logic)<computes><decides>:i64=If(Require[L],7,8);G(L:logic)<computes><decides>:i64=F[L];Value:i64=Attempt(G[false],9)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_failable_frame_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            94 => blk: {
                try out.print("F(N:i64)<computes>:i64=Attempt(Attempt(If(Require[N>0],N+3,N),Fail[\"fallback\"]),9);G(N:i64)<computes>:i64=Attempt(If(Require[F(N)<10],N*2,N),7);Value:i64=G({d})", .{a});
                const inner = if (a > 0) a + 3 else 9;
                break :blk .{ .value = if (inner < 10) a * 2 else 7 };
            },
            95 => blk: {
                try out.print("var C:i64=1;F()<computes>:i64=Attempt(Fail[\"caught\"],7);set C={d};Recovered:i64=F();Value:i64=C+Recovered", .{a});
                break :blk .{ .value = a + 7 };
            },
            96 => blk: {
                try out.print("F(N:i64)<computes>:map(string,i64)=Attempt(If(Require[N>=0],map{{\"雪\"=>N}},map{{}}),map{{\"fallback\"=>7}});M:map(string,i64)=F({d});Value:i64=Or(Lookup(M,\"雪\"),Or(Lookup(M,\"fallback\"),0))", .{a});
                break :blk .{ .value = if (a >= 0) a else 7 };
            },
            97 => blk: {
                try out.writeAll("var C:i64=1;Bad()<computes>:i64=Attempt(Fail[\"caught\"],1/0);set C=2;Value:i64=Attempt(Bad(),9)");
                break :blk .{ .failed = .division_by_zero };
            },
            98 => blk: {
                const depth = 1 + c.rng.below(35);
                try out.writeAll("F()<computes>:i64=");
                for (0..depth) |_| try out.writeAll("Attempt(");
                try out.writeAll("Fail[\"deep\"]");
                for (0..depth) |_| try out.writeAll(",7)");
                try out.writeAll(";Value:i64=F()");
                break :blk if (depth <= 32) .{ .value = 7 } else .syntax_failure;
            },
            99 => blk: {
                try out.writeAll("F(L:logic)<computes>:i64=Attempt(If(Require[L],7,8),9);Value:i64=F(false)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_frame_failure_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            88 => blk: {
                const choice = a < offset;
                try out.print("F(L:logic,A:i64,B:i64)<computes>:i64=If(L,If(A>B,A*2,B-3),A+B);G(L:logic,A:i64,B:i64)<computes>:i64=F(L,A,B)+1;Value:i64=G({s},{d},{d})", .{ if (choice) "true" else "false", a, offset });
                break :blk .{ .value = 1 + if (choice) (if (a > offset) a * 2 else offset - 3) else a + offset };
            },
            89 => blk: {
                const choice = a < 0;
                try out.print("Next(N:i64)<computes>:i64=N+1;F(L:logic,N:i64)<computes>:[]i64=If(L,array{{Next(N),Next(N+1)}},array{{{d}}});A:[]i64=F({s},{d});Keep:[]i64=A;B:[]i64=F(false,0);Value:i64=Keep.Length", .{ b, if (choice) "true" else "false", a });
                break :blk .{ .value = if (choice) 2 else 1 };
            },
            90 => blk: {
                const choice = a >= 0;
                try out.print("F(L:logic,N:i64)<computes>:map(string,i64)=If(L,map{{\"雪\"=>N+1}},map{{}});M:map(string,i64)=F({s},{d});Value:i64=Or(Lookup(M,\"雪\"),7)", .{ if (choice) "true" else "false", a });
                break :blk .{ .value = if (choice) a + 1 else 7 };
            },
            91 => blk: {
                try out.writeAll("var C:i64=1;Bad(L:logic)<computes>:i64=If(L,7,1/0);set C=2;Value:i64=Attempt(Bad(false),9)");
                break :blk .{ .failed = .division_by_zero };
            },
            92 => blk: {
                const depth = 1 + c.rng.below(35);
                try out.writeAll("F()<computes>:i64=");
                for (0..depth) |_| try out.writeAll("If(true,");
                try out.writeAll("7");
                for (0..depth) |_| try out.writeAll(",8)");
                try out.writeAll(";Value:i64=F()");
                break :blk if (depth <= 32) .{ .value = 7 } else .syntax_failure;
            },
            93 => blk: {
                try out.writeAll("F(L:logic,N:i64)<computes>:i64=If(L,N+1,N-2);Value:i64=F(true,3)");
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(out.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_frame_branch_source_mutation", position, self.source[position]);
                break :blk .unchecked;
            },
            80 => blk: {
                try out.writeAll("var C:i64=1;set C=2;Value:map(i64,i64)=Attempt(map{1=>0,1=>1},map{})");
                break :blk .{ .failed = .duplicate_map_key };
            },
            72 => blk: {
                try out.writeAll("Value:logic=Attempt(Require[false],true)");
                break :blk .{ .boolean = true };
            },
            // The bundles among the feature cases were taken above.
            features.first...features.first + features.count - 1 => try features.generate(Expected, kind, c, &out, a, b, offset),
            else => unreachable,
        };
        const exhaust = c.fault(.exhaustion);
        self.written = out.end;
        try self.evaluate(c, out.buffered(), expected, exhaust);
        self.generated += 1;
    }

    pub fn finish(self: *State, c: *kernel.Context) !void {
        c.record("language_recovery", self.generated, 0);
        try self.evaluate(c, "F(X:i64)<computes>:i64=X;Value:i64=F(-9223372036854775808)", .{ .value = std.math.minInt(i64) }, false);
        try self.evaluate(c, "Value:i64=9223372036854775807", .{ .value = std.math.maxInt(i64) }, false);
        try self.evaluate(c, "Value:i64=42", .{ .value = 42 }, false);
        try self.evaluate(c, "Value:float=-0.0", .{ .float_value = -0.0 }, false);
        try self.evaluate(c, "mode:=enum{Light,Dark};Value:mode=mode.Dark", .{ .enumeration = 1 }, false);
        try self.evaluate(c, "Value:i64=tuple{42,tuple{array{1,2}}}(0)", .{ .value = 42 }, false);
        try self.evaluate(c, "M:map(string,option(i64))=map{\"gap\"=>option{42}};Value:i64=Or(Or(Lookup(M,\"gap\"),option{}),0)", .{ .value = 42 }, false);
        try self.moduleCase(c, 49, 7, 35, false);
        try self.evaluate(c, "Value:i64=Attempt(Fail[\"recovery\"],If(true,42,1/0))", .{ .value = 42 }, false);
        try self.evaluate(c, "Value:logic=NaN==NaN and not (NaN<=NaN)", .{ .boolean = true }, false);
        try self.evaluate(c, "var C:i64=1;First(X:i64,Y:i64)<computes>:i64=X;R:i64=Attempt(First(Set(C,99),Fail[\"undo\"]),Set(C,42));Value:i64=C", .{ .value = 42 }, false);
        try c.check(self.runtime.machine.journal.depth == 0 and self.runtime.machine.source.depth == 0, "language_recovery_keeps_journal_idle");
    }

    fn evaluate(self: *State, c: *kernel.Context, source: []const u8, expected: Expected, exhaust: bool) !void {
        const ir = switch (self.compiler.compile(source)) {
            .failed => |diagnostic| {
                c.record("language_compile_diagnostic", @backingInt(diagnostic.code), diagnostic.span.start);
                try c.check(expected == .syntax_failure or expected == .unchecked, "generated_supported_source_compiles");
                try self.checkDiagnostic(c, diagnostic, source.len);
                self.refused += 1;
                c.reject(@tagName(diagnostic.code));
                return;
            },
            .ok => |ir| ir,
        };
        if (self.compiler.qualify) try self.checkQualified(c, ir);
        try self.evaluateIr(c, ir, expected, exhaust);
    }

    /// RFC-0085, I11: each identifier has one meaning, and each printed form resolves again to
    /// the definition it was computed from (`qualify.verify`).
    fn checkQualified(self: *State, c: *kernel.Context, ir: types.Program) !void {
        try c.check(self.compiler.resolution_conflicts == 0, "qualified_identifier_has_one_meaning");
        const text = self.compiler.qualification(ir, &self.qualify_written);
        try c.check(text.entries.len != 0, "qualified_identifiers_noted");
        const problem = self.compiler.verifyQualification(ir, text);
        if (problem) |found| c.record("language_qualify_problem", found.at, 0);
        try c.check(problem == null, "qualified_form_resolves_to_its_definition");
    }

    fn evaluateIr(self: *State, c: *kernel.Context, ir: types.Program, expected: Expected, exhaust: bool) !void {
        const source = ir.source;
        // Both machines read the workload's world (RFC-0086), each from a world of its own that
        // answers alike, and are given the same grants (P2.3); the replay's second run is given
        // the record, the grants and no world.
        self.reference_world.rewind();
        self.runtime_world.rewind();
        self.reference_control.effects.inputs.source = self.reference_world.source();
        self.runtime.machine.control.effects.inputs.source = self.runtime_world.source();
        self.reference_control.effects.inputs.grants = &features.world_grants;
        self.runtime.machine.control.effects.inputs.grants = &features.world_grants;
        // RFC-0086, P2.4: each machine's log tells a sink of its own where its commit points end.
        self.sealers = .{ .{}, .{} };
        self.reference_control.effects.sink = self.sealers[0].sink();
        self.runtime.machine.control.effects.sink = self.sealers[1].sink();
        try c.check(expected != .syntax_failure, "generated_excess_nesting_rejects");
        const budget: u64 = if (exhaust) @intCast(c.rng.below(ir.nodes.len + 1)) else types.limits.nodes;
        var required_work: usize = ir.nodes.len;
        for (ir.nodes) |node| if (node.kind == .aggregate) {
            required_work += node.kind.aggregate.end - node.kind.aggregate.start;
        };
        var dynamic_work = ir.string_comparisons != 0 or types.cold(ir);
        // A `weak_map`'s lookups and updates are a map's (RFC-0087).
        for (ir.definitions) |definition| if (definition == .map or definition == .weak_map) {
            dynamic_work = true;
            break;
        };
        // Non-exhaustion generated cases have independently bounded small maps.
        // Dynamic key costs prevent inferring full funding from IR size alone.
        const fully_funded = !exhaust or (!dynamic_work and budget >= required_work);
        c.record("language_run", ir.nodes.len, budget);
        const reference = forbic.evaluator.evaluateWithRuntimeStorage(ir, &self.reference_values, &self.reference_members, &self.reference_control, &self.reference_state, &self.reference_frames, budget);
        const actual = self.runtime.evaluate(ir, budget);
        try c.check(self.runtime.machine.source.depth == 0 and self.reference_state.depth == 0, "language_source_transactions_idle");
        try c.check(self.runtime.machine.calls.depth == 0 and self.runtime.machine.calls.count == 0 and self.reference_frames.depth == 0 and self.reference_frames.count == 0, "language_call_frames_idle");
        try c.check(self.runtime.machine.source.cell_count == self.reference_state.cell_count, "language_source_cell_counts_agree");
        for (self.runtime.machine.source.cells[0..self.runtime.machine.source.cell_count], self.reference_state.cells[0..self.reference_state.cell_count]) |cell, image| {
            try c.check(cell.initialized == image.initialized, "language_source_initialization_agrees");
            if (cell.initialized) try self.compareValues(c, &.{cell.value}, &.{image.value});
        }
        try c.check(std.meta.activeTag(reference) == std.meta.activeTag(actual), "language_evaluator_vm_result_agreement");
        // Both machines sealed the same commit points, each after its last action (RFC-0086 J3),
        // whether the run completed or not.
        try c.check(Sealer.same(&self.sealers[0], &self.sealers[1]) and self.sealers[0].wrong == 0, "language_seals_agree");
        switch (reference) {
            .failed => |diagnostic| {
                try c.check(self.reference_control.call_count == 0 and self.runtime.machine.control.call_count == 0, "language_fatal_call_trace_cleared");
                try c.check(self.reference_control.trace_count == 0 and self.runtime.machine.control.trace_count == 0 and self.reference_control.failure_count == 0 and self.runtime.machine.control.failure_count == 0, "language_fatal_failure_trace_cleared");
                try c.check(std.meta.eql(diagnostic, actual.failed), "language_evaluator_vm_diagnostic_agreement");
                // A fatal error keeps the input record, and both machines read alike (I8).
                try c.check(sameInputs(self.reference_control.effects.inputs.record(), self.runtime.machine.control.effects.inputs.record()), "language_fatal_input_records_agree");
                try self.checkDiagnostic(c, diagnostic, source.len);
                try c.check(diagnostic.code != .invalid_ir, "compiler_emits_valid_typed_ir");
                if (fully_funded and expected == .failed) try c.check(diagnostic.code == expected.failed, "language_arithmetic_matches_independent_error");
                if (fully_funded and (expected == .value or expected == .float_value or expected == .enumeration or expected == .boolean or expected == .effects)) try c.check(false, "generated_valid_arithmetic_succeeds");
                self.failed += 1;
                c.reject(@tagName(diagnostic.code));
            },
            .ok => |execution| {
                try c.check(execution.call_steps.len == actual.ok.call_steps.len, "language_call_step_counts_agree");
                for (execution.call_steps, actual.ok.call_steps) |event, other| {
                    try c.check(event.function == other.function and event.pc == other.pc and event.kind == other.kind, "language_call_step_schedule_agrees");
                    try self.compareValues(c, &.{event.value}, &.{other.value});
                    c.record("language_call_step", event.function, event.pc);
                    c.record("language_call_step_kind", @backingInt(event.kind), 0);
                }
                if (!types.cold(ir)) try self.compareValues(c, execution.values, actual.ok.values) else {
                    try c.check(std.mem.eql(bool, execution.activity, actual.ok.activity), "language_control_activity_agrees");
                    for (0..execution.values.len) |index| if (execution.active(index)) {
                        try self.compareValues(c, execution.values[index..][0..1], actual.ok.values[index..][0..1]);
                    };
                    try c.check(std.meta.eql(execution.failure_count, actual.ok.failure_count) and execution.failures.len == actual.ok.failures.len, "language_failure_counts_agree");
                    for (execution.failures, actual.ok.failures) |trace, other| {
                        try c.check(std.meta.eql(trace, other), "language_failure_traces_agree");
                        c.record("language_caught_failure", trace.instruction, @backingInt(trace.code));
                        c.record("language_failure_scope", trace.function orelse std.math.maxInt(u32), trace.pc);
                        if (trace.reason) |reason| c.record("language_failure_reason", std.hash.Wyhash.hash(0, reason), reason.len);
                    }
                    _ = forbic.value_report.validate(execution, false, .{}) catch {
                        try c.check(false, "language_reference_control_report_admitted");
                        return;
                    };
                    _ = forbic.value_report.validate(actual.ok, false, .{}) catch {
                        try c.check(false, "language_vm_control_report_admitted");
                        return;
                    };
                }
                try self.compareValues(c, execution.aggregate_values, actual.ok.aggregate_values);
                // Both machines did the same to the world and drew the same from it (RFC-0079).
                try c.check(sameEffects(execution.effects, actual.ok.effects), "language_effect_records_agree");
                // And their schedulers did the same (RFC-0082).
                try c.check(sameScheduler(execution.scheduler, actual.ok.scheduler), "language_scheduler_records_agree");
                // And their live variables did the same (RFC-0084).
                try c.check(std.meta.eql(execution.live, actual.ok.live), "language_live_records_agree");
                // The replay works out every value the program decides (RFC-0024, "Amendment: the
                // replay works out every value"): the report with one pure root value changed is
                // one the program could not have produced.
                try self.forgedRootRefused(c, execution);
                if (fully_funded) {
                    try c.check(expected != .failed, "generated_arithmetic_error_rejects");
                    if (expected == .effects) {
                        const model = expected.effects;
                        const value = execution.get("Value");
                        try c.check(value != null and value.? == .integer and value.?.integer == model.value, "language_effect_value_matches_model");
                        try c.check(std.mem.eql(u8, execution.effects.bytes, model.text[0..model.length]) and execution.effects.entries.len == model.lines, "language_committed_output_matches_model");
                        try c.check(execution.effects.discarded == model.discarded, "language_discarded_output_matches_model");
                        try c.check(execution.effects.draws == model.draws, "language_draws_match_model_stream");
                        if (model.inputs) |entries| try c.check(execution.effects.inputs.len == entries, "language_input_entries_match_model_clock");
                        // RFC-0086, P2.3: each committed line on its channel, `Print`'s or a writer's.
                        for (execution.effects.entries, 0..) |entry, index| if (index < model.channels.len) try c.check(entry.channel == model.channels[index], "language_committed_channels_match_model");
                        // RFC-0086, P2.4: the commit points the case works out are the ones sealed.
                        if (model.seal_count) |points| try c.check(self.sealers[0].lost == 0 and self.sealers[0].count == points and std.mem.eql(u64, self.sealers[0].seals[0..points], model.seal_points[0..points]), "language_seals_match_model");
                        c.record("language_effects", model.lines, model.draws);
                    }
                    if (expected == .value) {
                        const value = execution.get("Value");
                        try c.check(value != null and value.? == .integer, "language_value_binding_present");
                        try c.check(value.?.integer == expected.value, "language_arithmetic_matches_independent_value");
                    }
                    if (expected == .float_value) {
                        const value = execution.get("Value");
                        try c.check(value != null and value.? == .floating, "language_float_binding_present");
                        try c.check(@as(u64, @bitCast(value.?.floating)) == @as(u64, @bitCast(expected.float_value)), "language_float_matches_independent_bits");
                    }
                    if (expected == .boolean) {
                        const value = execution.get("Value");
                        try c.check(value != null and value.? == .boolean, "language_predicate_binding_present");
                        try c.check(value.?.boolean == expected.boolean, "language_predicate_matches_independent_value");
                    }
                    if (expected == .enumeration) {
                        const value = execution.get("Value");
                        try c.check(value != null and value.? == .enumeration, "language_enum_binding_present");
                        try c.check(value.?.enumeration.index == expected.enumeration, "language_enum_matches_independent_case");
                        const definition = forbic.aggregate_types.definition(value.?.enumeration.value_type, ir.definitions);
                        try c.check(definition != null and definition.? == .enumeration, "language_enum_has_nominal_type");
                        try c.check(std.mem.eql(u8, definition.?.enumeration.name.text(source), "mode"), "language_enum_matches_independent_type");
                    }
                }
                if (execution.get("Theme")) |theme| {
                    try c.check(theme == .string, "language_theme_has_string_type");
                    try c.check(std.mem.eql(u8, theme.string, "snow: \xe9\x9b\xaa\xf0\x9f\x8c\xb2\n\"\\"), "language_utf8_escapes_decode_exactly");
                    const alias = execution.get("Alias");
                    try c.check(alias != null and alias.? == .string, "language_string_alias_present");
                    try c.check(std.mem.eql(u8, alias.?.string, theme.string), "language_string_alias_preserves_content");
                    const enabled = execution.get("Enabled");
                    const copy = execution.get("Copy");
                    try c.check(enabled != null and enabled.? == .boolean and enabled.?.boolean, "language_logic_literal_preserves_value");
                    try c.check(copy != null and copy.? == .boolean and copy.?.boolean, "language_logic_alias_preserves_value");
                }
                // Every action a run commits is sealed by the end (RFC-0086 J3).
                try c.check(self.sealers[0].whole() and self.sealers[0].commits == execution.effects.output.count, "language_every_commit_is_sealed");
                // Last: the runs below reuse the storage `execution` and `actual` borrow.
                if (types.cold(ir)) try self.traceModes(c, ir, budget, execution);
                self.succeeded += 1;
                c.counters.committed += 1;
            },
        }
        // RFC-0086, P2.5: last, as it reuses the machines' storage.
        if (self.resuming and fully_funded) try self.checkResume(c, ir);
        try c.check(self.runtime.machine.journal.depth == 0 and self.runtime.machine.journal.undo_count == 0 and self.runtime.machine.journal.pending_count == 0, "language_run_releases_active_journal_state");
    }

    /// RFC-0086, P2.5: both machines' run of `ir` journaled, to a fresh disk or (`image`) resuming
    /// what a crash left there (R1, R4); the world is the workload's, its readers repositioned
    /// past the lines the journal sealed (R6). Each machine's outcome is in `recovery.outcomes`.
    fn journaled(self: *State, ir: types.Program, image: ?[]const u8, group: u32) !void {
        const r = &self.recovery;
        const controls = [2]*types.ControlStorage{ &self.reference_control, &self.runtime.machine.control };
        const worlds = [2]*World{ &self.reference_world, &self.runtime_world };
        for (controls, worlds, 0..) |control, world, side| {
            world.rewind();
            r.memories[side] = .{ .bytes = &r.disks[side] };
            r.journals[side] = .init(r.memories[side].disk(), &r.buffers[side]);
            r.journals[side].group = group;
            control.effects.sink = r.journals[side].sink();
            control.effects.inputs.source = world.source();
            control.effects.inputs.journal = r.journals[side].inputJournal();
            control.effects.inputs.grants = &features.world_grants;
            control.effects.inputs.prefix = .{};
            control.trace = .full;
            const disk = r.memories[side].disk();
            if (image) |bytes| {
                @memcpy(r.disks[side][0..bytes.len], bytes);
                r.memories[side].len = bytes.len;
                r.memories[side].synced = bytes.len;
                const found = try forbic.durable.scan(disk, &r.buffers[side]);
                std.debug.assert(found.has_header and !found.finished());
                try forbic.durable.cutAt(disk, found);
                const sealed = try r.sealed[side].load(disk, &r.buffers[side]);
                for (sealed.entries) |entry| if (entry.kind == .line and entry.status == .value) {
                    world.cursors[entry.request] += 1;
                };
                control.effects.inputs.prefix = sealed;
                r.journals[side].resumeAt(found);
            } else {
                var header: [256]u8 = undefined;
                try r.journals[side].start(try forbic.durable.encodeHeader(.{ .toolchain = "dst", .profile = "bootstrap", .program = @splat(0), .seed = forbic.effects.default_seed, .tick_rate = 60, .grants = &.{} }, &header));
            }
        }
        const reference = forbic.evaluator.evaluateWithRuntimeStorage(ir, &self.reference_values, &self.reference_members, &self.reference_control, &self.reference_state, &self.reference_frames, types.limits.nodes);
        const actual = self.runtime.evaluate(ir, types.limits.nodes);
        for ([2]forbic.evaluator.Result{ reference, actual }, &r.journals, &r.outcomes, 0..) |result, *journal, *outcome, side| {
            outcome.* = switch (result) {
                .ok => |execution| .{ .value = if (execution.get("Value")) |value| (if (value == .integer) value.integer else null) else null },
                .failed => |diagnostic| .{ .failed = diagnostic },
            };
            r.diverged[side] = journal.diverged;
            if (journal.failed) continue;
            const end: forbic.durable.End = switch (result) {
                .ok => .{ .outcome = .completed },
                .failed => |diagnostic| .{ .outcome = .fatal, .code = @tagName(diagnostic.code), .start = diagnostic.span.start, .end = diagnostic.span.end },
            };
            journal.finish(end) catch {};
        }
        for (controls) |control| {
            control.effects.inputs.journal = null;
            control.effects.inputs.prefix = .{};
        }
    }

    /// RFC-0086, P2.5: the case run journaled, crashed after a commit point drawn from its seals
    /// with the next record torn, and resumed on both machines: neither diverges, both end as
    /// the uninterrupted run did, and the journal each leaves is the uninterrupted one, byte for
    /// byte (R4, R5, JM1).
    fn checkResume(self: *State, c: *kernel.Context, ir: types.Program) !void {
        const r = &self.recovery;
        const group: u32 = @intCast(1 + c.rng.below(3));
        try self.journaled(ir, null, group);
        try c.check(std.meta.eql(r.outcomes[0], r.outcomes[1]), "language_journaled_machines_end_alike");
        try c.check(std.mem.eql(u8, r.memories[0].contents(), r.memories[1].contents()), "language_journaled_machines_write_one_journal");
        const whole_len = r.memories[0].len;
        @memcpy(r.whole[0..whole_len], r.memories[0].contents());
        const whole = r.whole[0..whole_len];
        const uninterrupted = r.outcomes[0];
        // Where the seals end, and the record after each.
        var ends: [64]u64 = undefined;
        var count: usize = 0;
        {
            var image: forbic.durable.Image = .{ .bytes = whole };
            var prefix = try forbic.durable.Prefix.init(image.disk(), &r.buffers[0]);
            while (try prefix.next()) |record| switch (record.decoded) {
                .header, .seal => if (count < ends.len) {
                    ends[count] = record.item.end;
                    count += 1;
                },
                else => {},
            };
        }
        const at = ends[@intCast(c.rng.below(count))];
        // A crash keeps the cut and a torn prefix of what followed it.
        const kept = at + c.rng.below(@min(whole_len - at, 24) + 1);
        @memcpy(r.image[0..kept], whole[0..kept]);
        if (kept > at and c.rng.below(2) == 0) r.image[kept - 1] ^= 0x5a;
        // A crash after the end was durable leaves a finished journal, which nothing resumes.
        var image: forbic.durable.Image = .{ .bytes = r.image[0..kept] };
        const found = try forbic.durable.scan(image.disk(), &r.buffers[0]);
        if (found.finished()) return;
        c.record("language_resume", at, kept);
        try self.journaled(ir, r.image[0..kept], group);
        try c.check(!r.diverged[0] and !r.diverged[1], "language_resume_does_not_diverge");
        try c.check(std.meta.eql(r.outcomes[0], uninterrupted) and std.meta.eql(r.outcomes[1], uninterrupted), "language_resume_ends_as_the_uninterrupted_run");
        try c.check(std.mem.eql(u8, r.memories[0].contents(), whole) and std.mem.eql(u8, r.memories[1].contents(), whole), "language_resume_writes_the_uninterrupted_journal");
        self.resumed += 1;
    }

    /// The host's choice of witness for the runs that follow, in both machines and the replay.
    fn traceMode(self: *State, trace: types.TraceMode, window: u32, floor: u32) void {
        // Every run reads the world from its start (RFC-0086, P2.3).
        self.reference_world.rewind();
        self.runtime_world.rewind();
        for ([_]*types.ControlStorage{ &self.reference_control, &self.runtime.machine.control }) |control| {
            control.trace = trace;
            control.trace_window = window;
            control.reclaim_floor = floor;
        }
        self.again.control.trace_window = window;
        self.again.control.reclaim_floor = floor;
        // And seals afresh (RFC-0086, P2.4).
        self.sealers = .{ .{}, .{} };
    }

    /// Runs a program that has just succeeded with its witness stored (`stored`) again in the
    /// two modes that store none, with a seeded window and a seeded reclamation floor. A floor
    /// of zero reclaims members at every frame end, so the short programs of this workload
    /// reclaim as a ten-million-step run does under pressure. Whatever the mode, window and
    /// floor: both machines agree on everything a run leaves behind, the step stream has the
    /// stored run's count (and its digest when nothing was reclaimed), no member is left naming
    /// reclaimed room, and the replayed report is the stored run's report byte for byte.
    fn traceModes(self: *State, c: *kernel.Context, ir: types.Program, budget: u64, stored: forbic.evaluator.Execution) !void {
        const Control = types.ControlStorage;
        var full = std.Io.Writer.fixed(&self.reports[0]);
        _ = forbic.value_report.write(&full, stored, false, .{}) catch {
            // A report larger than the buffer here says nothing about the modes.
            c.record("language_trace_modes_skipped", ir.nodes.len, 0);
            return;
        };
        const witness = stored.callWitness();
        const stored_pool = stored.aggregate_values.len;
        try c.check(witness != null and witness.?.count == stored.call_steps.len and stored.reclaims == 0, "language_stored_witness_counts_every_step_and_never_reclaims");
        const window = ([_]u32{ 1, 2, 3, 7, 64, Control.default_trace_window })[@intCast(c.rng.below(6))];
        const floor = ([_]u32{ 0, 0, 1, 5, 40, Control.default_reclaim_floor, Control.reclaim_never })[@intCast(c.rng.below(7))];
        c.record("language_trace_mode", window, floor);
        // RFC-0086, P2.4: every mode seals the stored run's commit points.
        self.stored_seals = self.sealers[0];
        defer self.traceMode(.full, Control.default_trace_window, Control.default_reclaim_floor);

        self.traceMode(.digest, window, floor);
        const digest_reference = forbic.evaluator.evaluateWithRuntimeStorage(ir, &self.reference_values, &self.reference_members, &self.reference_control, &self.reference_state, &self.reference_frames, budget);
        const digest_actual = self.runtime.evaluate(ir, budget);
        // Reclamation is not charged, so the fuel that sufficed with a stored witness suffices.
        try c.check(digest_reference == .ok and digest_actual == .ok, "language_digest_run_succeeds_where_stored_run_did");
        try self.sameRun(c, digest_reference.ok, digest_actual.ok);
        try c.check(Sealer.same(&self.sealers[0], &self.stored_seals) and Sealer.same(&self.sealers[1], &self.stored_seals), "language_modes_seals_agree");
        for ([_]forbic.evaluator.Execution{ digest_reference.ok, digest_actual.ok }) |run| {
            try c.check(run.trace == .digest and run.call_steps.len == 0, "language_digest_run_stores_no_step");
            // The stream has the stored run's steps. Its hash covers the spans the steps name,
            // which a reclamation renumbers, so the hashes are equal when nothing was reclaimed.
            const folded = run.callWitness();
            try c.check(folded != null and folded.?.count == witness.?.count and folded.?.failures == witness.?.failures, "language_digest_witness_counts_the_stored_steps");
            if (run.reclaims == 0) try c.check(std.meta.eql(folded, witness), "language_digest_witness_equals_stored_witness");
            try c.check(run.aggregate_values.len <= stored_pool, "language_reclamation_never_grows_the_pool");
            if (floor == Control.reclaim_never) try c.check(run.reclaims == 0 and run.aggregate_values.len == stored_pool, "language_unreclaimed_digest_run_keeps_the_stored_pool");
        }
        var replayed = std.Io.Writer.fixed(&self.reports[1]);
        _ = forbic.value_report.writeReplayed(&replayed, digest_actual.ok, self.again.producer(ir, budget), false, .{}) catch {
            try c.check(false, "language_vm_digest_report_admitted");
            return;
        };
        try c.check(std.mem.eql(u8, full.buffered(), replayed.buffered()), "language_replayed_report_equals_stored_report");
        _ = forbic.value_report.validateReplayed(digest_reference.ok, self.again.producer(ir, budget), false, .{}) catch {
            try c.check(false, "language_reference_digest_report_admitted");
            return;
        };
        c.record("language_reclaims", digest_actual.ok.reclaims, digest_actual.ok.aggregate_values.len);
        self.replayed += 1;
        self.reclaimed += digest_actual.ok.reclaims;

        // Without a witness there is nothing to replay; the machines still agree and reclaim alike.
        self.traceMode(.off, window, floor);
        const off_reference = forbic.evaluator.evaluateWithRuntimeStorage(ir, &self.reference_values, &self.reference_members, &self.reference_control, &self.reference_state, &self.reference_frames, budget);
        const off_actual = self.runtime.evaluate(ir, budget);
        try c.check(off_reference == .ok and off_actual == .ok, "language_unwitnessed_run_succeeds_where_stored_run_did");
        try self.sameRun(c, off_reference.ok, off_actual.ok);
        try c.check(Sealer.same(&self.sealers[0], &self.stored_seals) and Sealer.same(&self.sealers[1], &self.stored_seals), "language_modes_seals_agree");
        try c.check(off_actual.ok.callWitness() == null and off_actual.ok.call_steps.len == 0, "language_unwitnessed_run_has_no_witness");
        try c.check(off_actual.ok.aggregate_values.len <= stored_pool, "language_reclamation_never_grows_the_pool");
    }

    /// The last active pure root node whose value has a changed form is changed in the
    /// reference's own storage, the report is replayed, and the value is put back.
    fn forgedRootRefused(self: *State, c: *kernel.Context, execution: forbic.evaluator.Execution) !void {
        var index = execution.values.len;
        while (index != 0) {
            index -= 1;
            if (!execution.active(index) or !pureRoot(execution.program.nodes[index])) continue;
            const forged = forgedValue(execution.values[index]) orelse continue;
            const original = self.reference_values[index];
            self.reference_values[index] = forged;
            defer self.reference_values[index] = original;
            const refused = if (forbic.value_report.validate(execution, false, .{})) |_| false else |err| err == error.InvalidExecution;
            try c.check(refused, "language_forged_root_value_refused");
            c.record("language_forged_root_value", index, @backingInt(std.meta.activeTag(execution.program.nodes[index].kind)));
            return;
        }
    }

    /// Two machines ran the same program in the same mode: everything a run leaves behind is
    /// the same, the member-pool layout and the reclamations included, and what is left is
    /// well formed (nothing names a member at or above itself or beyond the pool).
    fn sameRun(self: *State, c: *kernel.Context, reference: forbic.evaluator.Execution, actual: forbic.evaluator.Execution) !void {
        try c.check(std.mem.eql(bool, reference.activity, actual.activity), "language_modes_activity_agrees");
        try c.check(reference.values.len == actual.values.len, "language_register_counts_agree");
        for (0..reference.values.len) |index| if (actual.active(index)) {
            try self.compareValues(c, reference.values[index..][0..1], actual.values[index..][0..1]);
            try c.check(memberEnd(actual.values[index]) <= actual.aggregate_values.len, "language_values_name_members_inside_the_pool");
        };
        try self.compareValues(c, reference.aggregate_values, actual.aggregate_values);
        for (actual.aggregate_values, 0..) |member, index| try c.check(memberEnd(member) <= index, "language_members_name_only_members_below");
        try c.check(reference.failure_count == actual.failure_count and reference.failures.len == actual.failures.len, "language_failure_counts_agree");
        for (reference.failures, actual.failures) |trace, other| try c.check(std.meta.eql(trace, other), "language_failure_traces_agree");
        try c.check(self.runtime.machine.source.cell_count == self.reference_state.cell_count, "language_source_cell_counts_agree");
        for (self.runtime.machine.source.cells[0..self.runtime.machine.source.cell_count], self.reference_state.cells[0..self.reference_state.cell_count]) |cell, image| {
            try c.check(cell.initialized == image.initialized, "language_source_initialization_agrees");
            if (cell.initialized) try self.compareValues(c, &.{cell.value}, &.{image.value});
        }
        try c.check(reference.object_cells.len == actual.object_cells.len, "language_instance_cell_counts_agree");
        for (reference.object_cells, actual.object_cells) |image, cell| {
            try c.check(cell.initialized == image.initialized, "language_instance_initialization_agrees");
            if (cell.initialized) try self.compareValues(c, &.{image.value}, &.{cell.value});
            try c.check(!cell.initialized or memberEnd(cell.value) <= actual.aggregate_values.len, "language_instances_name_members_inside_the_pool");
        }
        try c.check(reference.trace == actual.trace and std.meta.eql(reference.witness, actual.witness), "language_witness_agrees");
        try c.check(sameEffects(reference.effects, actual.effects), "language_modes_effect_records_agree");
        try c.check(sameScheduler(reference.scheduler, actual.scheduler), "language_modes_scheduler_records_agree");
        try c.check(std.meta.eql(reference.live, actual.live), "language_modes_live_records_agree");
        try c.check(reference.reclaims == actual.reclaims, "language_reclamation_counts_agree");
        const controls = .{ &self.reference_control, &self.runtime.machine.control };
        try c.check(controls[0].reclaims == controls[1].reclaims and controls[0].reclaimed_members == controls[1].reclaimed_members and controls[0].reclaim_at == controls[1].reclaim_at, "language_reclamation_schedules_agree");
        try c.check(self.runtime.machine.source.depth == 0 and self.reference_state.depth == 0 and self.runtime.machine.calls.depth == 0 and self.reference_frames.depth == 0, "language_modes_leave_frames_idle");
    }

    /// Whether two runs scheduled alike: the same clock, counts, switches and waiting tasks.
    fn sameScheduler(reference: types.Scheduler, actual: types.Scheduler) bool {
        if (reference.tick_rate != actual.tick_rate or reference.tick != actual.tick or reference.created != actual.created or reference.completed != actual.completed or reference.canceled != actual.canceled or reference.switches != actual.switches) return false;
        if (reference.waiting.len != actual.waiting.len) return false;
        for (reference.waiting, actual.waiting) |a, b| if (!std.meta.eql(a, b)) return false;
        return true;
    }

    /// Whether two runs committed the same actions, discarded as many and drew as far.
    fn sameEffects(reference: forbic.effects.Record, actual: forbic.effects.Record) bool {
        if (reference.entries.len != actual.entries.len or reference.grants.len != actual.grants.len) return false;
        // RFC-0086, P2.3: each listed action on the same channel, under the same grants.
        for (reference.entries, actual.entries) |a, b| if (a.channel != b.channel) return false;
        for (reference.grants, actual.grants) |a, b| if (a.kind != b.kind or !std.mem.eql(u8, a.name, b.name)) return false;
        return reference.output.eql(actual.output) and reference.draws == actual.draws and reference.discarded == actual.discarded and reference.seed == actual.seed and std.mem.eql(u8, reference.bytes, actual.bytes) and reference.entries.len == actual.entries.len and sameInputs(reference.inputRecord(), actual.inputRecord());
    }

    /// Whether two runs took the same inputs from the world, entry for entry (RFC-0086).
    fn sameInputs(reference: forbic.effects.InputRecord, actual: forbic.effects.InputRecord) bool {
        if (reference.entries.len != actual.entries.len or !std.mem.eql(u8, reference.bytes, actual.bytes)) return false;
        for (reference.entries, actual.entries) |a, b| if (!std.meta.eql(a, b)) return false;
        return true;
    }

    /// One past the last pool member a value names; zero when it names none.
    fn memberEnd(value: types.Value) usize {
        const span = switch (value) {
            .aggregate => |aggregate| aggregate.elements,
            .callable => |callable| callable.captures,
            else => return 0,
        };
        return if (span.start == span.end) 0 else span.end;
    }

    fn moduleCase(self: *State, c: *kernel.Context, kind: u64, a: i64, offset: i64, exhaust: bool) !void {
        var root = std.Io.Writer.fixed(&self.source);
        var dependency = std.Io.Writer.fixed(&self.module_source);
        var second = std.Io.Writer.fixed(&self.second_module_source);
        var expected: Expected = .{ .value = a + offset };
        const root_path = if (kind == 50) "app/sub/main.forb" else "main.forb";
        const path = if (kind == 50) "../.././dep.forb" else if (kind == 53) "missing.forb" else "dep.forb";
        try root.print("T:=import{{\"{s}\"}};", .{path});
        switch (kind) {
            49 => {
                try root.writeAll("U:=import{\"second.forb\"};Value:i64=T.Get()+U.Get()");
                try dependency.print("Value:i64={d};Get<public>()<computes>:i64=Value", .{a});
                try second.print("Value:i64={d};Get<public>()<computes>:i64=Value", .{offset});
            },
            50 => {
                try root.print("Point:T.point=T.Make();Value:i64=Point.X+{d}", .{offset});
                try dependency.print("Bias:i64={d};point<public>:=struct{{X:i64=Bias}};Make<public>()<computes>:point=point{{}}", .{a});
            },
            51 => {
                try root.writeAll("Value:i64=T.Secret");
                try dependency.print("Secret:i64={d}", .{a});
                expected = .syntax_failure;
            },
            52 => {
                try dependency.writeAll("Back:=import{\"main.forb\"}");
                expected = .syntax_failure;
            },
            53 => expected = .syntax_failure,
            54 => {
                try dependency.writeAll("Unused()<computes>:i64=Missing");
                expected = .syntax_failure;
            },
            55 => {
                try root.writeAll("Value:i64=T.Fault()");
                try dependency.writeAll("Fault<public>()<computes>:i64=1/0");
                expected = .{ .failed = .division_by_zero };
            },
            56 => {
                try root.writeAll("Value:i64=T.Get()");
                try dependency.print("Value:i64={d};Get<public>()<computes>:i64=Value", .{a});
                const punctuation = "{}[]().,:;=+-*/<>\n\"\\";
                const position: usize = @intCast(c.rng.below(root.end));
                self.source[position] = punctuation[@intCast(c.rng.below(punctuation.len))];
                c.record("language_module_mutation", position, self.source[position]);
                expected = .unchecked;
            },
            else => unreachable,
        }
        const inventory = [_]forbic.modules.Input{
            .{ .path = root_path, .source = root.buffered() },
            .{ .path = "dep.forb", .source = dependency.buffered() },
            .{ .path = "second.forb", .source = second.buffered() },
        };
        const ir = switch (self.compiler.compileBundle(.{ .root = root_path, .modules = &inventory })) {
            .failed => |problem| {
                c.record("language_module_diagnostic", @backingInt(problem.diagnostic.code), problem.diagnostic.span.start);
                c.record("language_module_path", std.hash.Wyhash.hash(0, problem.path), problem.source.len);
                try self.checkDiagnostic(c, problem.diagnostic, problem.source.len);
                try c.check(expected == .syntax_failure or expected == .unchecked, "generated_modules_compile_with_hygienic_names");
                c.reject(@tagName(problem.diagnostic.code));
                return;
            },
            .ok => |ir| ir,
        };
        try c.check(ir.modules.len > 0 and ir.bindings.len <= 2, "module_execution_exposes_root_bindings_only");
        try self.evaluateIr(c, ir, expected, exhaust);
    }

    /// A feature case of two files: `main.forb`, the root, imports `lib.forb`. It is held to
    /// its model exactly as a case of one file is, in every trace mode.
    fn bundleCase(self: *State, c: *kernel.Context, kind: u64, a: i64, b: i64, offset: i64) !void {
        var root = std.Io.Writer.fixed(&self.source);
        var library = std.Io.Writer.fixed(&self.module_source);
        const expected = try features.generateBundle(Expected, kind, c, &root, &library, a, b, offset);
        const exhaust = c.fault(.exhaustion);
        self.written = root.end;
        self.module_written = library.end;
        const inventory = [_]forbic.modules.Input{
            .{ .path = "main.forb", .source = root.buffered() },
            .{ .path = "lib.forb", .source = library.buffered() },
        };
        const ir = switch (self.compiler.compileBundle(.{ .root = "main.forb", .modules = &inventory })) {
            .failed => |problem| {
                c.record("language_bundle_diagnostic", @backingInt(problem.diagnostic.code), problem.diagnostic.span.start);
                c.record("language_bundle_path", std.hash.Wyhash.hash(0, problem.path), problem.source.len);
                try c.check(expected == .syntax_failure, "generated_supported_bundle_compiles");
                try self.checkDiagnostic(c, problem.diagnostic, problem.source.len);
                self.refused += 1;
                c.reject(@tagName(problem.diagnostic.code));
                return;
            },
            .ok => |ir| ir,
        };
        try c.check(ir.modules.len == 2 and ir.nested.len != 0, "bundle_case_declares_modules_in_two_files");
        try self.evaluateIr(c, ir, expected, exhaust);
    }

    fn checkDiagnostic(_: *const State, c: *kernel.Context, value: types.Diagnostic, source_length: usize) !void {
        try c.check(value.span.start <= value.span.end and value.span.end <= source_length, "language_diagnostic_has_valid_source_span");
    }

    fn compareValues(_: *const State, c: *kernel.Context, reference: []const types.Value, actual: []const types.Value) !void {
        try c.check(reference.len == actual.len, "language_register_counts_agree");
        for (reference, actual) |expected, value| {
            try c.check(std.meta.activeTag(expected) == std.meta.activeTag(value), "language_register_tags_agree");
            const equal = switch (expected) {
                .integer => |integer| integer == value.integer,
                .floating => |floating| @as(u64, @bitCast(floating)) == @as(u64, @bitCast(value.floating)),
                .boolean => |boolean| boolean == value.boolean,
                .string => |string| std.mem.eql(u8, string, value.string),
                .aggregate => |aggregate| std.meta.eql(aggregate, value.aggregate),
                .enumeration => |enumeration| std.meta.eql(enumeration, value.enumeration),
                .callable => |callable| std.meta.eql(callable, value.callable),
                .object => |object| std.meta.eql(object, value.object),
                .rational => |rational| std.meta.eql(rational, value.rational),
            };
            try c.check(equal, "language_register_values_agree");
            if (value == .string) try c.check(std.unicode.utf8ValidateSlice(value.string), "language_strings_remain_valid_utf8");
        }
    }

    fn malformedTail(self: *State, c: *kernel.Context) !void {
        var nodes = [_]types.Node{
            .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 1 } },
            .{ .span = origin, .value_type = .i64, .kind = .{ .integer = 0 } },
            .{ .span = origin, .value_type = .i64, .kind = .{ .binary = .{ .op = .divide, .lhs = 0, .rhs = 1 } } },
            .{ .span = origin, .value_type = .i64, .kind = .{ .negate = 4 } },
        };
        const kind = c.rng.below(6);
        switch (kind) {
            0 => {},
            1 => nodes[3] = .{ .span = .{ .start = 0, .end = 1 }, .value_type = .i64, .kind = .{ .negate = 0 } },
            2 => nodes[3] = .{ .span = origin, .value_type = .logic, .kind = .{ .integer = 0 } },
            3 => nodes[3] = .{ .span = origin, .value_type = .string, .kind = .{ .string = .{ .start = 1, .end = 2 } } },
            4 => nodes[3] = .{ .span = origin, .value_type = .float, .kind = .{ .float_negate = 0 } },
            5 => nodes[3] = .{ .span = origin, .value_type = .logic, .kind = .{ .floating = 1.0 } },
            else => unreachable,
        }
        c.record("language_invalid_ir_tail", kind, 0);
        const ir: types.Program = .{ .source = "", .strings = "\xe9\x9b\xaa", .nodes = &nodes, .bindings = &.{} };
        const budget: u64 = @intCast(c.rng.below(nodes.len + 1));
        @memset(self.reference_values[0..nodes.len], .{ .integer = 42 });
        const reference = forbic.evaluator.evaluate(ir, &self.reference_values, budget);
        const actual = self.runtime.evaluate(ir, budget);
        try c.check(self.runtime.machine.source.depth == 0 and self.reference_state.depth == 0, "language_source_transactions_idle");
        try c.check(self.runtime.machine.calls.depth == 0 and self.runtime.machine.calls.count == 0 and self.reference_frames.depth == 0 and self.reference_frames.count == 0, "language_call_frames_idle");
        try c.check(self.runtime.machine.source.cell_count == self.reference_state.cell_count, "language_source_cell_counts_agree");
        for (self.runtime.machine.source.cells[0..self.runtime.machine.source.cell_count], self.reference_state.cells[0..self.reference_state.cell_count]) |cell, image| {
            try c.check(cell.initialized == image.initialized, "language_source_initialization_agrees");
            if (cell.initialized) try self.compareValues(c, &.{cell.value}, &.{image.value});
        }
        try c.check(reference == .failed and actual == .failed, "language_invalid_tail_rejects_before_execution");
        try c.check(reference.failed.code == .invalid_ir and actual.failed.code == .invalid_ir, "language_invalid_tail_wins_over_fuel_and_arithmetic");
        for (self.reference_values[0..nodes.len]) |value| try c.check(value == .integer and value.integer == 42, "language_invalid_tail_preserves_reference_results");
        c.reject("invalid_ir");
    }

    fn invalidBytecodeTail(self: *State, c: *kernel.Context) !void {
        const value: i64 = @bitCast(c.rng.next());
        var code = [_]forbic.vm.Instruction{
            .{ .value_type = .i64, .op = .{ .integer = value } },
            .{ .op = .begin },
            .{ .op = .{ .store_cell = .{ .cell = 0, .value = 0 } } },
            .{ .op = .{ .enqueue = .{ .kind = 1, .argument = 0 } } },
            .{ .op = .commit },
            .{ .value_type = .i64, .op = .{ .negate = 99 } },
        };
        if (c.rng.below(2) == 1) code[5] = .{ .value_type = .float, .op = .{ .float_negate = 0 } };
        c.record("language_invalid_bytecode_tail", @bitCast(value), 0);
        const old_cell = try self.runtime.machine.journal.read(0);
        const old_outbox = self.runtime.machine.journal.committed().len;
        const result = self.runtime.machine.run(.{ .code = &code }, @intCast(c.rng.below(code.len + 1)));
        try c.check(result == .failed and result.failed.code == .invalid_bytecode, "language_invalid_bytecode_tail_rejects_before_commit");
        try c.check(try self.runtime.machine.journal.read(0) == old_cell, "language_invalid_bytecode_tail_preserves_cells");
        try c.check(self.runtime.machine.journal.committed().len == old_outbox and self.runtime.machine.journal.depth == 0, "language_invalid_bytecode_tail_preserves_intents_and_idle_ownership");
        c.reject("invalid_bytecode");
    }
};

test "language seeded workload reproduces typed values diagnostics and malformed tails" {
    const state = try forbic.scratch.storage(State);
    defer forbic.scratch.release(state);
    forbic.scratch.initialise(state);
    var first = kernel.Context.init(0x69722d7265766965, .swarm);
    for (0..300) |step| {
        first.step = @intCast(step);
        try state.step(&first);
    }
    first.heal();
    try state.finish(&first);
    forbic.scratch.initialise(state);
    var second = kernel.Context.init(0x69722d7265766965, .swarm);
    for (0..300) |step| {
        second.step = @intCast(step);
        try state.step(&second);
    }
    second.heal();
    try state.finish(&second);
    try std.testing.expectEqualDeep(first.counters, second.counters);
    try std.testing.expectEqualSlices(u8, &first.hash(), &second.hash());
    try std.testing.expect(first.counters.rejected > 0 and first.counters.committed > 0);
}

test "language differential oracle detects a wrong register result" {
    const state = try forbic.scratch.storage(State);
    defer forbic.scratch.release(state);
    forbic.scratch.initialise(state);
    var context = kernel.Context.init(1, .swarm);
    try std.testing.expectError(error.Invariant, state.compareValues(&context, &.{.{ .integer = 1 }}, &.{.{ .integer = 2 }}));
    try std.testing.expectEqualStrings("language_register_values_agree", context.failure.?);
    context = kernel.Context.init(2, .swarm);
    try std.testing.expectError(error.Invariant, state.compareValues(&context, &.{.{ .floating = 0.0 }}, &.{.{ .floating = -0.0 }}));
    try std.testing.expectEqualStrings("language_register_values_agree", context.failure.?);
}

/// The features of `language_features.zig`, by their case numbers.
const feature_groups = [_]struct { name: []const u8, first: u64, count: u64 }{
    .{ .name = "classes", .first = 0, .count = 5 },
    .{ .name = "for", .first = 5, .count = 5 },
    .{ .name = "comparable", .first = 10, .count = 4 },
    .{ .name = "case", .first = 14, .count = 6 },
    .{ .name = "exit", .first = 20, .count = 5 },
    .{ .name = "characters", .first = 25, .count = 5 },
    .{ .name = "failure forms", .first = 30, .count = 6 },
    .{ .name = "nested modules", .first = 36, .count = 5 },
    .{ .name = "loop locals and conditions", .first = 41, .count = 5 },
    .{ .name = "parametric types", .first = 46, .count = 3 },
    .{ .name = "short circuit and chains", .first = 49, .count = 4 },
    .{ .name = "dropped comparisons and shadowing", .first = 53, .count = 3 },
    .{ .name = "unique classes and overloads", .first = 56, .count = 2 },
    .{ .name = "option catching, conditions and defaults", .first = 58, .count = 4 },
    .{ .name = "class members across modules", .first = 62, .count = 2 },
    .{ .name = "standard library", .first = 64, .count = 7 },
    .{ .name = "type parameters, uncalled generics and dropped instances", .first = 71, .count = 2 },
    .{ .name = "effect families", .first = 73, .count = 3 },
    .{ .name = "remaining types", .first = 76, .count = 5 },
    .{ .name = "native effects", .first = 81, .count = 3 },
    .{ .name = "generic methods, SortBy and type values", .first = 84, .count = 5 },
    .{ .name = "root loops, joins and template shadowing", .first = 89, .count = 3 },
    .{ .name = "structured concurrency", .first = 92, .count = 4 },
    .{ .name = "refinements, qualifiers and aliases", .first = 96, .count = 4 },
    .{ .name = "events and awaits", .first = 100, .count = 4 },
    .{ .name = "sync, race and cancellation", .first = 104, .count = 4 },
    .{ .name = "rush, branch and owned tasks", .first = 108, .count = 4 },
    .{ .name = "live variables", .first = 112, .count = 4 },
    .{ .name = "reclamation across task stacks", .first = 116, .count = 4 },
    .{ .name = "live fields", .first = 120, .count = 4 },
    .{ .name = "functions as types", .first = 124, .count = 4 },
    .{ .name = "exits from arms", .first = 128, .count = 4 },
    .{ .name = "reactions", .first = 132, .count = 8 },
    .{ .name = "cancellation, the clock and NextTick", .first = 140, .count = 4 },
    .{ .name = "batches", .first = 144, .count = 4 },
    .{ .name = "await of a guard", .first = 148, .count = 4 },
    .{ .name = "sticky and subscribable events", .first = 152, .count = 4 },
    .{ .name = "cancelling reactions", .first = 156, .count = 4 },
    .{ .name = "rooms of array joins", .first = 160, .count = 3 },
    .{ .name = "transparent functions", .first = 163, .count = 2 },
    .{ .name = "enumerator qualification", .first = 165, .count = 2 },
    .{ .name = "predicts", .first = 167, .count = 2 },
    .{ .name = "inputs and the clock", .first = 169, .count = 4 },
    .{ .name = "accessors", .first = 173, .count = 7 },
    .{ .name = "grants and handles", .first = 180, .count = 7 },
    .{ .name = "shared locals", .first = 187, .count = 7 },
    .{ .name = "weak maps", .first = 194, .count = 7 },
    .{ .name = "nested functions", .first = 201, .count = 7 },
    .{ .name = "accessor initialisation", .first = 208, .count = 7 },
    .{ .name = "automatic qualification", .first = 215, .count = 7 },
    .{ .name = "durable journal seals", .first = 222, .count = 7 },
    .{ .name = "nested overloads, defaults and named arguments", .first = 229, .count = 7 },
    .{ .name = "shared locals in tasks", .first = 236, .count = 7 },
    .{ .name = "persistable types", .first = 243, .count = 7 },
    .{ .name = "recovery from the durable journal", .first = 250, .count = 7 },
    .{ .name = "suspending For", .first = 257, .count = 7 },
    .{ .name = "session cells", .first = 264, .count = 7 },
    .{ .name = "closures composed", .first = 271, .count = 7 },
    // RFC-0087, P5.3.
    .{ .name = "JSON", .first = 278, .count = 7 },
    // RFC-0085, I14.
    .{ .name = "live locals", .first = 285, .count = 7 },
    .{ .name = "generic functions beside methods, and an Fn in a For", .first = 292, .count = 3 },
    // RFC-0087, P5.5.
    .{ .name = "persistent cells", .first = 295, .count = 7 },
    // RFC-0085, I13.
    .{ .name = "one capture rule", .first = 302, .count = 7 },
    // RFC-0090, B2.
    .{ .name = "control-flow completion", .first = 309, .count = 7 },
    // RFC-0091, B3.
    .{ .name = "functions completion", .first = 316, .count = 8 },
    // RFC-0092, B4.
    .{ .name = "classes completion", .first = 324, .count = 7 },
    // RFC-0094, B6.
    .{ .name = "profile", .first = 331, .count = 3 },
    // TASK-0109, B8.
    .{ .name = "book tightening", .first = 334, .count = 5 },
};

test "every feature case meets its model on both machines, and each feature succeeds, fails and is refused" {
    comptime {
        var next: u64 = 0;
        for (feature_groups) |group| {
            std.debug.assert(group.first == next);
            next += group.count;
        }
        std.debug.assert(next == features.count);
    }
    const state = try forbic.scratch.storage(State);
    defer forbic.scratch.release(state);
    forbic.scratch.initialise(state);
    for (feature_groups) |group| {
        const before = .{ state.refused, state.failed, state.succeeded };
        for (group.first..group.first + group.count) |index| {
            const kind = features.first + index;
            const case_before = state.refused + state.failed + state.succeeded;
            for (0..48) |seed| {
                var context = kernel.Context.init(0x66656174 +% @as(u64, seed) *% 0x9e3779b97f4a7c15 +% kind, .swarm);
                // Faults off: every case is fully funded and must do exactly what its model says.
                context.heal();
                state.case(&context, kind) catch |err| {
                    std.debug.print("feature case {d} ({s}) seed {d}: {s}\n{s}\n", .{ kind, group.name, seed, context.failure orelse "?", state.source[0..state.written] });
                    if (features.bundled(kind)) std.debug.print("lib.forb:\n{s}\n", .{state.module_source[0..state.module_written]});
                    return err;
                };
            }
            try std.testing.expectEqual(case_before + 48, state.refused + state.failed + state.succeeded);
        }
        // Each feature is seen to be refused, to end a run with a diagnostic, and to succeed.
        errdefer std.debug.print("feature {s}: refused {d}, failed {d}, succeeded {d}\n", .{ group.name, state.refused - before[0], state.failed - before[1], state.succeeded - before[2] });
        try std.testing.expect(state.refused > before[0]);
        try std.testing.expect(state.failed > before[1]);
        try std.testing.expect(state.succeeded > before[2]);
    }
    // Trace modes and reclamation were exercised by the same programs, not vacuously.
    errdefer std.debug.print("replayed {d} runs, {d} reclamations\n", .{ state.replayed, state.reclaimed });
    try std.testing.expect(state.replayed >= 1000);
    try std.testing.expect(state.reclaimed >= 1000);
    // RFC-0086, P2.5: the recovery cases were crashed and resumed, not skipped.
    errdefer std.debug.print("resumed {d} runs\n", .{state.resumed});
    try std.testing.expect(state.resumed >= 150);
}

test "the trace mode oracle detects machines that disagree after a digest run" {
    const state = try forbic.scratch.storage(State);
    defer forbic.scratch.release(state);
    forbic.scratch.initialise(state);
    var context = kernel.Context.init(3, .swarm);
    context.heal();
    const program = state.compiler.compile("Step(S:i64)<computes>:i64=Block{T:=tuple{S,S+1};T(1)}\nValue:i64=Iterate(Step,20,0)").ok;
    state.traceMode(.digest, 3, 0);
    const reference = forbic.evaluator.evaluateWithRuntimeStorage(program, &state.reference_values, &state.reference_members, &state.reference_control, &state.reference_state, &state.reference_frames, types.limits.nodes).ok;
    var actual = state.runtime.evaluate(program, types.limits.nodes).ok;
    try std.testing.expect(reference.reclaims > 0);
    try state.sameRun(&context, reference, actual);
    actual.reclaims += 1;
    try std.testing.expectError(error.Invariant, state.sameRun(&context, reference, actual));
    try std.testing.expectEqualStrings("language_reclamation_counts_agree", context.failure.?);
    actual.reclaims -= 1;
    actual.witness.digest ^= 1;
    try std.testing.expectError(error.Invariant, state.sameRun(&context, reference, actual));
    try std.testing.expectEqualStrings("language_witness_agrees", context.failure.?);
}
