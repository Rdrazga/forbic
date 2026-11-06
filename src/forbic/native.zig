//! Native Zig functions callable from Forbic (RFC-0042).
//!
//! A host registers ordinary typed Zig functions. `entry` derives the Forbic
//! signature from the Zig type at compile time, so source and Zig cannot disagree,
//! and anything Forbic cannot represent is a compile error. Native functions are
//! pure and total: they see only their arguments and a `Context` that bounds
//! allocation and charges work. They never touch guest state.
const std = @import("std");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");
const run_strings = @import("run_strings.zig");
const keys = @import("map_keys.zig");
const effects = @import("effects.zig");

/// Most parameters a native can declare; operands are stored inline in the node.
pub const max_parameters = 4;

/// Element types a native can exchange with Forbic. Strings are parameters only. `any` is the
/// one type variable `T` of a generic native (RFC-0077): every `any` of a signature stands for
/// the same Forbic type, which the call site chooses and each machine's admission re-derives.
///
/// RFC-0086, P2.3: `reader` and `writer` are handles, values of the built-in types of those names
/// (`grant(kind)`), which an effect native takes as its first parameter and receives as the
/// index of the grant they name. No native returns one, and none takes a collection of them.
pub const Scalar = enum { i64, logic, float, string, any, reader, writer };

/// The handle parameters of a native (RFC-0086): the index of the grant the handle names.
pub const Reader = struct { grant: u32 };
pub const Writer = struct { grant: u32 };
pub const Shape = struct {
    element: Scalar,
    /// `nested` is `[][]element`; `map` is `map(K, element)`, where `K` is the signature's one
    /// key variable, a comparable type like every map key.
    /// `unit` is `tuple()`, the result of a native that yields nothing (RFC-0079); its
    /// `element` says nothing.
    kind: enum { scalar, array, option, nested, map, unit },

    /// The builtin type of a concrete element. A generic shape has none, and neither has a
    /// handle, whose type is a definition of the program's catalogue (`typeMatches`).
    pub fn builtin(self: Shape) types.Type {
        return switch (self.element) {
            .i64 => .i64,
            .logic => .logic,
            .float => .float,
            .string => .string,
            .any, .reader, .writer => unreachable,
        };
    }

    /// Whether the shape is a handle, a `reader` or a `writer` (RFC-0086).
    pub fn handle(self: Shape) bool {
        return self.element == .reader or self.element == .writer;
    }

    /// Whether the shape names a type variable, or a container only generic natives exchange.
    pub fn generic(self: Shape) bool {
        return self.element == .any or self.kind == .nested or self.kind == .map;
    }
};
/// Work charged before a call: `base + per_element * N`, where N is the total length of
/// array arguments plus the total byte length of string arguments.
pub const Cost = struct { base: u32 = 1, per_element: u32 = 0 };

/// Why a native call stopped. Each maps to one fatal diagnostic.
pub const Fault = enum { work_limit, aggregate_limit, string_limit, failed, invalid, overflow, scratch, effect_limit, effect_prepare_failed, effect_commit_failed, input_limit, input_failed, input_unavailable, input_invalid, input_diverged };

/// What a native does beyond computing (RFC-0079). A pure native is a function of its
/// arguments. An `output` native describes an action on the world with `Context.act`; a `draw`
/// native reads the run's stream with `Context.draw`. Either is a function of scalar and string
/// arguments only, so that a report replay can run it again against its own port and learn
/// what it did without a device. A caller needs `<transacts>`. An `input` native (RFC-0086)
/// reads what the world gives the run with `Context.input`: the run's input log records it, and
/// every later reader of the run is given the record, not the world.
pub const Effect = enum { none, output, draw, input };
pub const Error = error{ WorkLimit, AggregateLimit, StringLimit, Failed, Overflow, ScratchUnavailable };

/// A native result is a scalar or `members`: a span of freshly allocated run-owned
/// members that the machine wraps in an array or option of the node's type.
pub const Outcome = union(enum) { scalar: types.Value, members: types.Span, fault: Fault };

/// The only capability a native receives. It can allocate result members from the
/// run's aggregate pool and result bytes from the run's string pool, each charged
/// work, and nothing else.
pub const Context = struct {
    pool: []types.Value,
    used: usize,
    remaining: u64,
    strings: *run_strings.Pool,
    /// Work charged through `reserve`/`text`; `invoke` reconciles it with `remaining`.
    charged: u64 = 0,
    /// What a structural comparison needs beyond the native stack: the calling machine's.
    work: ?*keys.Work = null,
    /// What the native's entry declared, and the port it is lent when that is an effect.
    effect: Effect = .none,
    port: ?effects.Port = null,
    /// Why an effect could not be prepared; `invoke` reports it in place of `failed`.
    fault: ?Fault = null,
    /// The members a native reads its arguments from and the values it compares name, when
    /// they are not `pool[0..used]`: a report replay runs a native again on the run's own
    /// members and gives it only the room of its result as `pool` (`value_report.zig`).
    members: ?[]const types.Value = null,

    /// RFC-0086, P2.3: the grant index of the handle the native was given as its first
    /// argument, when its entry declares one. A native reaches only the grant it was given.
    handle: ?u32 = null,
    /// TASK-0109, W4.4: the host's context of the native's entry (`Entry.host`), read with
    /// `hostContext`.
    host: ?Host = null,

    /// TASK-0109, W4.4: the host's context the native's entry was registered with, when it is a
    /// `T`; null when the entry has none or another type's. Whatever a native reads through it
    /// is part of what it computes: the host keeps it unchanged while any run, or the report of
    /// one, may call the native, so that both machines and the replay see one function.
    pub fn hostContext(self: *const Context, comptime T: type) ?*const T {
        const given = self.host orelse return null;
        if (!std.mem.eql(u8, given.type_name, @typeName(T))) return null;
        return @ptrCast(@alignCast(given.pointer));
    }

    /// Describes an action on the world: the bytes go to the run's effect log under the
    /// rollback region open at the call, and are charged as a string of that length is.
    /// It is the last thing an `output` native does.
    pub fn act(self: *Context, action: []const u8) Error!void {
        return self.actOn(0, action);
    }

    /// `act` on `channel` (RFC-0086 H5): 0, `Print`'s, for a native without a handle, and the
    /// channel of the writer it was given for one with a writer. Any other is a native that is
    /// not what its table says.
    pub fn actOn(self: *Context, channel: u32, action: []const u8) Error!void {
        const port = self.port orelse return self.refuse();
        if (self.effect != .output) return self.refuse();
        if (self.handle) |grant| {
            if (grant >= port.grants.len or port.grants[grant].kind != .writer or channel != effects.writerChannel(grant)) return self.refuse();
        } else if (channel != 0) return self.refuse();
        try self.spend(run_strings.work(action.len));
        port.act(port.context, channel, action) catch |err| {
            self.fault = switch (err) {
                error.EffectLimit => .effect_limit,
                error.EffectPrepareFailed => .effect_prepare_failed,
                error.EffectCommitFailed => .effect_commit_failed,
            };
            return error.Failed;
        };
    }

    /// The next word of the run's stream, charged one unit.
    pub fn draw(self: *Context) Error!u64 {
        const source = try self.stream();
        try self.spend(1);
        return source.next();
    }

    /// A uniform integer between two bounds, both included, in either order: a unit per word.
    pub fn drawInteger(self: *Context, first: i64, second: i64) Error!i64 {
        const source = try self.stream();
        const before = source.position;
        const value = source.integer(first, second);
        try self.spend(source.position -% before);
        return value orelse error.Failed;
    }

    /// A uniform float between two bounds, in either order: one word.
    pub fn drawFloat(self: *Context, first: f64, second: f64) Error!f64 {
        const source = try self.stream();
        try self.spend(1);
        return source.float(first, second);
    }

    fn stream(self: *Context) Error!*effects.Stream {
        const port = self.port orelse return self.refuse();
        if (self.effect != .draw) return self.refuse();
        return port.stream;
    }

    /// One input from the world (RFC-0086), through the run's input log at the tick of the
    /// call: recorded there before the native sees it, and never taken back.
    pub fn input(self: *Context, kind: effects.InputKind, request: u32) Error!effects.Answer {
        const port = self.port orelse return self.refuse();
        if (self.effect != .input) return self.refuse();
        const log = port.inputs orelse return self.refuse();
        // The clock is one: a native that asks for another is not what its table says.
        if (kind == .clock and request != 0) return self.refuse();
        // RFC-0087, P5.5: a load is the machine's, at a persistent cell's declaration; no native
        // reads the store.
        if (kind == .load) return self.refuse();
        // A line comes from the reader the native was given, and from no other (RFC-0086 I6).
        if (kind == .line) {
            const grant = self.handle orelse return self.refuse();
            if (request != grant or grant >= port.grants.len or port.grants[grant].kind != .reader) return self.refuse();
        }
        return log.read(.{ .kind = kind, .request = request, .tick = port.tick }) catch |err| {
            self.fault = switch (err) {
                error.InputLimit => .input_limit,
                error.InputFailed => .input_failed,
                error.InputUnavailable => .input_unavailable,
                error.InputInvalid => .input_invalid,
                error.InputDiverged => .input_diverged,
            };
            return error.Failed;
        };
    }

    /// A native reached for an effect its entry did not declare: the table is wrong.
    fn refuse(self: *Context) Error {
        self.fault = .invalid;
        return error.Failed;
    }

    /// Charges `amount` units for work the declared cost does not cover.
    pub fn spend(self: *Context, amount: u64) Error!void {
        if (amount > self.remaining) return error.WorkLimit;
        self.remaining -= amount;
        self.charged += amount;
    }

    fn compared(self: *const Context) []const types.Value {
        return self.members orelse self.pool[0..self.used];
    }

    /// Whether two values of one comparable type are equal, as `==` has it, charged as `==`
    /// charges: a unit per value visited and per string byte compared.
    pub fn equal(self: *Context, lhs: types.Value, rhs: types.Value) Error!bool {
        const work = self.work orelse return error.ScratchUnavailable;
        const before = self.remaining;
        defer self.charged += before - self.remaining;
        return keys.equal(work, self.compared(), lhs, rhs, &self.remaining) catch |err| switch (err) {
            error.WorkLimit => error.WorkLimit,
            error.ScratchUnavailable => error.ScratchUnavailable,
        };
    }

    /// A table over the keys of the map `pairs`, for looking up many keys in it. It lives in
    /// `small` or in the machine's scratch until the next table is asked for.
    pub fn mapIndex(self: *Context, small: *[keys.small_slots]u32, pairs: []const types.Value) Error!keys.Index {
        const work = self.work orelse return error.ScratchUnavailable;
        const before = self.remaining;
        defer self.charged += before - self.remaining;
        return keys.indexed(work, small, self.compared(), pairs, &self.remaining) catch |err| switch (err) {
            error.WorkLimit => error.WorkLimit,
            error.ScratchUnavailable => error.ScratchUnavailable,
        };
    }

    /// The offset in the indexed map of the value under a key equal to `key`, if any.
    pub fn mapFind(self: *Context, index: keys.Index, key: types.Value) Error!?usize {
        const work = self.work orelse return error.ScratchUnavailable;
        const before = self.remaining;
        defer self.charged += before - self.remaining;
        return index.find(work, self.compared(), key, &self.remaining) catch |err| switch (err) {
            error.WorkLimit => error.WorkLimit,
            error.ScratchUnavailable => error.ScratchUnavailable,
        };
    }

    /// Adds one member behind the used part of the pool, for a result that is built member
    /// by member: it must end where the pool's used part does when the function returns.
    pub fn append(self: *Context, value: types.Value) Error!void {
        if (self.used == self.pool.len) return error.AggregateLimit;
        try self.spend(1);
        self.pool[self.used] = value;
        self.used += 1;
    }

    /// Allocates `length` writable bytes for a string result.
    pub fn text(self: *Context, length: usize) Error![]u8 {
        const before = self.remaining;
        defer self.charged += before - self.remaining;
        return run_strings.reserve(self.strings, length, &self.remaining) catch |err| switch (err) {
            error.StringLimit => error.StringLimit,
            error.WorkLimit => error.WorkLimit,
        };
    }

    pub fn reserve(self: *Context, count: usize) Error!types.Span {
        if (count > self.pool.len - self.used) return error.AggregateLimit;
        if (count > self.remaining) return error.WorkLimit;
        self.remaining -= count;
        self.charged += count;
        const span: types.Span = .{ .start = @intCast(self.used), .end = @intCast(self.used + count) };
        self.used += count;
        return span;
    }
    /// Starts an array result of `count` elements.
    pub fn array(self: *Context, comptime T: type, count: usize) Error!ArrayOut(T) {
        const span = try self.reserve(count);
        return .{ .span = span, .items = self.pool[span.start..span.end] };
    }
};

pub const Entry = struct {
    id: []const u8,
    params: []const Shape,
    result: Shape,
    cost: Cost,
    call: *const fn (*Context, []const types.Value) Outcome,
    /// The type variable must be a comparable type: the function compares values of it.
    comparable: bool = false,
    /// What the native does beyond computing (RFC-0079); its callers need `<transacts>`.
    effect: Effect = .none,
    /// The effect the host declares for the function (RFC-0078). A kernel sees its arguments
    /// and the context only and is bounded by them, so the one set a native of this slice can
    /// truthfully have is the narrowest: no heap effect, no failure, no suspension, and
    /// `<converges>`, which the host vouches for and nothing checks. `wellFormed` refuses any
    /// other until native effects exist (P2).
    effects: types.EffectSet = .{ .diverges = false },
    /// RFC-0085, I12: an effect native that predicts, so that a `<predicts>` function may call
    /// it. A native that only computes predicts without it: pure computation needs no
    /// authority. `wellFormed` allows it only on the string `Print`, so a host table cannot
    /// let predicting code draw or act otherwise.
    predicts: bool = false,
    /// TASK-0109, W4.4: a context the host lends the native (`Context.hostContext`), borrowed
    /// for as long as any program compiled with the table may run. None for the standard ones.
    host: ?Host = null,
};

/// TASK-0109, W4.4: a host's context of a native entry: the host's pointer and the name of its
/// type, which `Context.hostContext` compares so that a native reads it only as what it is.
pub const Host = struct { pointer: *const anyopaque, type_name: []const u8 };

/// Whether calling the native needs a caller that dictates (RFC-0085, I12): an effect native
/// does, unless its entry predicts.
pub fn dictates(entry_: Entry) bool {
    return entry_.effect != .none and !entry_.predicts;
}

/// A value of the signature's type variable. A native cannot look inside one; it can move it
/// and, when its entry is `comparable`, compare it with `Context.equal`.
pub const Any = struct { value: types.Value };

/// Immutable view of an array of the type variable.
pub const AnyArray = struct { items: []const types.Value };

/// Immutable view of an array of arrays of the type variable.
pub const AnyNested = struct {
    rows: []const types.Value,
    pool: []const types.Value,

    pub fn row(self: AnyNested, index: usize) []const types.Value {
        const range = self.rows[index].aggregate.elements;
        return self.pool[range.start..range.end];
    }
};

/// Immutable view of a map from the key variable to the type variable: its pairs in insertion
/// order, key then value.
pub const AnyMap = struct { pairs: []const types.Value };

/// A result of members of the type variable, built with `Context.append`: an array, or the
/// pairs of a map (`AnyMapOut`).
pub const AnyOut = struct { span: types.Span, items: []types.Value };
pub const AnyMapOut = struct { out: AnyOut };

/// Immutable view of a Forbic array argument.
pub fn Array(comptime T: type) type {
    return struct {
        items: []const types.Value,
        pub const element = T;
        pub fn len(self: @This()) usize {
            return self.items.len;
        }
        pub fn at(self: @This(), index: usize) T {
            return decode(T, self.items[index]);
        }
    };
}

/// Array result under construction; fill every slot, then return it.
pub fn ArrayOut(comptime T: type) type {
    return struct {
        span: types.Span,
        items: []types.Value,
        pub const element = T;
        pub fn set(self: @This(), index: usize, value: T) void {
            self.items[index] = encode(T, value);
        }
    };
}

fn scalarOf(comptime T: type) Scalar {
    return switch (T) {
        i64 => .i64,
        bool => .logic,
        f64 => .float,
        []const u8 => .string,
        Reader => .reader,
        Writer => .writer,
        else => @compileError("native functions exchange only i64, bool, f64 and []const u8, not " ++ @typeName(T)),
    };
}
fn decode(comptime T: type, value: types.Value) T {
    return switch (T) {
        i64 => value.integer,
        bool => value.boolean,
        f64 => value.floating,
        []const u8 => value.string,
        Reader, Writer => .{ .grant = value.enumeration.index },
        else => comptime unreachable,
    };
}
/// The guest's one NaN for any NaN a kernel computed. The test reads the bits: a float
/// comparison of the result of a floating-point operation with itself is something an
/// optimiser may decide without looking, and `@sqrt` of a negative number then kept the
/// host's NaN, which the check on the way out refused (RFC-0077).
fn canonical(value: f64) f64 {
    const bits: u64 = @bitCast(value);
    const is_nan = bits & 0x7fff_ffff_ffff_ffff > 0x7ff0_0000_0000_0000;
    return if (is_nan) @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) else value;
}
fn encode(comptime T: type, value: T) types.Value {
    return switch (T) {
        i64 => .{ .integer = value },
        bool => .{ .boolean = value },
        f64 => .{ .floating = canonical(value) },
        []const u8 => .{ .string = value },
        else => @compileError("native results cannot contain " ++ @typeName(T)),
    };
}

fn isArray(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "element") and @hasField(T, "items") and !@hasField(T, "span");
}
fn isArrayOut(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "element") and @hasField(T, "span");
}
fn paramShape(comptime T: type) Shape {
    if (T == Any) return .{ .element = .any, .kind = .scalar };
    if (T == AnyArray) return .{ .element = .any, .kind = .array };
    if (T == AnyNested) return .{ .element = .any, .kind = .nested };
    if (T == AnyMap) return .{ .element = .any, .kind = .map };
    if (comptime isArray(T)) return .{ .element = scalarOf(T.element), .kind = .array };
    return .{ .element = scalarOf(T), .kind = .scalar };
}
fn resultShape(comptime R: type) Shape {
    if (R == void) return .{ .element = .i64, .kind = .unit };
    if (R == AnyOut) return .{ .element = .any, .kind = .array };
    if (R == AnyMapOut) return .{ .element = .any, .kind = .map };
    const shape: Shape = if (comptime isArrayOut(R))
        .{ .element = scalarOf(R.element), .kind = .array }
    else if (comptime @typeInfo(R) == .optional)
        .{ .element = scalarOf(@typeInfo(R).optional.child), .kind = .option }
    else
        .{ .element = scalarOf(R), .kind = .scalar };
    return shape;
}

/// Derives a table entry from a Zig function `fn (*Context, params...) Result`.
/// `Result` is `i64`, `bool`, `f64`, `?T`, `ArrayOut(T)` or an error union of those
/// with `Error`.
pub fn entry(comptime id: []const u8, comptime function: anytype, comptime budget: Cost) Entry {
    return entryWith(id, function, budget, false);
}

/// `entry` for a generic native whose type variable must be comparable.
pub fn comparableEntry(comptime id: []const u8, comptime function: anytype, comptime budget: Cost) Entry {
    return entryWith(id, function, budget, true);
}

/// `entry` for a native that acts on the world or draws from it (RFC-0079). An `output` native
/// returns nothing, `void` in Zig and `tuple()` in Forbic; a `draw` native returns a number or a
/// `logic`. The table refuses any other shape (`wellFormed`).
pub fn effectEntry(comptime id: []const u8, comptime function: anytype, comptime budget: Cost, comptime effect: Effect) Entry {
    var made = entryWith(id, function, budget, false);
    made.effect = effect;
    return made;
}

fn entryWith(comptime id: []const u8, comptime function: anytype, comptime budget: Cost, comptime comparable: bool) Entry {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    if (info.param_types.len < 1 or info.param_types[0].? != *Context) @compileError("a native function takes *native.Context first");
    const count = info.param_types.len - 1;
    if (count > max_parameters) @compileError("a native function takes at most four Forbic parameters");
    const return_type = info.return_type.?;
    const fallible = @typeInfo(return_type) == .error_union;
    if (fallible and @typeInfo(return_type).error_union.error_set != Error) @compileError("a fallible native returns native.Error!T");
    const Result = if (fallible) @typeInfo(return_type).error_union.payload else return_type;
    const shapes: [count]Shape = comptime blk: {
        var list: [count]Shape = undefined;
        for (info.param_types[1..], 0..) |param, i| list[i] = paramShape(param.?);
        break :blk list;
    };
    const result = comptime resultShape(Result);
    const Adapter = struct {
        fn call(ctx: *Context, args: []const types.Value) Outcome {
            if (args.len != count) return .{ .fault = .invalid };
            var tuple: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            tuple[0] = ctx;
            inline for (info.param_types[1..], 0..) |param, i| {
                const P = param.?;
                if (P == Any) {
                    tuple[i + 1] = .{ .value = args[i] };
                } else if (P == AnyArray or P == AnyMap or P == AnyNested) {
                    if (args[i] != .aggregate) return .{ .fault = .invalid };
                    const range = args[i].aggregate.elements;
                    const readable = ctx.compared();
                    if (range.start > range.end or range.end > readable.len) return .{ .fault = .invalid };
                    const items = readable[range.start..range.end];
                    if (P == AnyNested) {
                        for (items) |item| {
                            if (item != .aggregate) return .{ .fault = .invalid };
                            const inner = item.aggregate.elements;
                            if (inner.start > inner.end or inner.end > readable.len) return .{ .fault = .invalid };
                        }
                        tuple[i + 1] = .{ .rows = items, .pool = readable };
                    } else if (P == AnyMap) {
                        if (items.len % 2 != 0) return .{ .fault = .invalid };
                        tuple[i + 1] = .{ .pairs = items };
                    } else {
                        tuple[i + 1] = .{ .items = items };
                    }
                } else if (comptime isArray(P)) {
                    if (args[i] != .aggregate) return .{ .fault = .invalid };
                    const range = args[i].aggregate.elements;
                    const readable: []const types.Value = ctx.members orelse ctx.pool;
                    if (range.start > range.end or range.end > readable.len) return .{ .fault = .invalid };
                    const items = readable[range.start..range.end];
                    const tag = comptime valueTag(scalarOf(P.element));
                    for (items) |item| if (std.meta.activeTag(item) != tag) return .{ .fault = .invalid };
                    tuple[i + 1] = .{ .items = items };
                } else {
                    if (std.meta.activeTag(args[i]) != comptime valueTag(scalarOf(P))) return .{ .fault = .invalid };
                    tuple[i + 1] = decode(P, args[i]);
                }
            }
            const raw = @call(.auto, function, tuple);
            const value = if (comptime fallible) raw catch |err| return .{ .fault = switch (err) {
                error.WorkLimit => .work_limit,
                error.AggregateLimit => .aggregate_limit,
                error.StringLimit => .string_limit,
                error.Overflow => .overflow,
                error.ScratchUnavailable => .scratch,
                error.Failed => .failed,
            } } else raw;
            if (Result == void) return .{ .members = .{ .start = @intCast(ctx.used), .end = @intCast(ctx.used) } };
            if (Result == AnyOut) return .{ .members = value.span };
            if (Result == AnyMapOut) return .{ .members = value.out.span };
            if (comptime isArrayOut(Result)) return .{ .members = value.span };
            if (comptime @typeInfo(Result) == .optional) {
                const present = value orelse return .{ .members = .{ .start = @intCast(ctx.used), .end = @intCast(ctx.used) } };
                const span = ctx.reserve(1) catch |err| return .{ .fault = if (err == error.WorkLimit) .work_limit else .aggregate_limit };
                ctx.pool[span.start] = encode(@typeInfo(Result).optional.child, present);
                return .{ .members = span };
            }
            return .{ .scalar = encode(Result, value) };
        }
    };
    return .{ .id = id, .params = &shapes, .result = result, .cost = budget, .call = Adapter.call, .comparable = comparable };
}

/// Total work to charge for a call: saturating, never wraps.
pub fn callCost(native_entry: Entry, arguments: []const types.Value) u64 {
    var elements: u64 = 0;
    for (arguments) |argument| {
        if (argument == .aggregate) elements += argument.aggregate.elements.end - argument.aggregate.elements.start;
        if (argument == .string) elements += argument.string.len;
    }
    return @as(u64, native_entry.cost.base) +| @as(u64, native_entry.cost.per_element) *| elements;
}

/// A string a native returns must be a boundary-aligned reference into the pool and
/// valid UTF-8. Empty strings are normalised to the pool's canonical empty string.
fn stringResult(pool: run_strings.Pool, value: *[]const u8) bool {
    if (value.len == 0) {
        value.* = pool.empty();
        return true;
    }
    return pool.aliases(value.*) and std.unicode.utf8ValidateSlice(value.*);
}

/// What a machine gets back from `invoke`.
pub const Invocation = union(enum) { ok: types.Value, fault: Fault };

/// Shared call glue: charge the declared cost, run the function with a pool-bounded
/// context, then verify the outcome against the declared shape before committing any
/// allocation. A machine admits the node's operands and types independently.
pub fn invoke(entry_: Entry, node_type: types.Type, arguments: []const types.Value, pool: []types.Value, used: *usize, strings: *run_strings.Pool, work: ?*keys.Work, remaining: *u64) Invocation {
    return invokeWith(entry_, node_type, arguments, pool, used, strings, work, remaining, null);
}

/// `invoke` by a machine that has a world: `port` is lent to the native only when its entry
/// declares an effect, so a pure native has nothing to act on or to draw from.
pub fn invokeWith(entry_: Entry, node_type: types.Type, arguments: []const types.Value, pool: []types.Value, used: *usize, strings: *run_strings.Pool, work: ?*keys.Work, remaining: *u64, port: ?effects.Port) Invocation {
    const charge = callCost(entry_, arguments);
    if (charge > remaining.*) return .{ .fault = .work_limit };
    remaining.* -= charge;
    const strings_before = strings.used;
    var context: Context = .{ .pool = pool, .used = used.*, .remaining = remaining.*, .strings = strings, .work = work, .effect = entry_.effect, .port = if (entry_.effect == .none) null else port, .handle = handleOf(entry_, arguments) orelse return .{ .fault = .invalid }, .host = entry_.host };
    const outcome = entry_.call(&context, arguments);
    // An effect that could not be prepared says why; the native only knows that it failed.
    if (outcome == .fault) return .{ .fault = context.fault orelse outcome.fault };
    if (!outcomeMatches(entry_.result, outcome)) return .{ .fault = .invalid };
    if (context.used < used.* or context.used > pool.len) return .{ .fault = .invalid };
    // Work spent must be exactly what the context's allocators charged, and bytes may only
    // be allocated by a native whose result is made of strings.
    if (context.remaining > remaining.* or remaining.* - context.remaining != context.charged) return .{ .fault = .invalid };
    if (context.charged < context.used - used.*) return .{ .fault = .invalid };
    if (entry_.result.element != .string and strings.used != strings_before) return .{ .fault = .invalid };
    switch (outcome) {
        .scalar => |value| {
            // A scalar result may not leave hidden members behind: replay accounts exactly.
            if (context.used != used.*) return .{ .fault = .invalid };
            var result = value;
            if (result == .string and !stringResult(strings.*, &result.string)) return .{ .fault = .invalid };
            if (result == .floating and !types.isCanonicalFloat(result.floating)) return .{ .fault = .invalid };
            used.* = context.used;
            remaining.* = context.remaining;
            return .{ .ok = result };
        },
        .members => |span| {
            if (span.start != used.* or span.end != context.used) return .{ .fault = .invalid };
            if (entry_.result.kind == .map and (span.end - span.start) % 2 != 0) return .{ .fault = .invalid };
            // Every fresh element must have the declared type; strings must alias the pool.
            for (pool[span.start..span.end]) |*element| {
                if (entry_.result.generic()) {
                    // A member of the type variable was moved from an argument: whatever it
                    // names was there before the call.
                    if (!movedValue(element, used.*, strings.*)) return .{ .fault = .invalid };
                    continue;
                }
                if (std.meta.activeTag(element.*) != valueTag(entry_.result.element)) return .{ .fault = .invalid };
                if (element.* == .string and !stringResult(strings.*, &element.string)) return .{ .fault = .invalid };
                if (element.* == .floating and !types.isCanonicalFloat(element.floating)) return .{ .fault = .invalid };
            }
            used.* = context.used;
            remaining.* = context.remaining;
            return .{ .ok = .{ .aggregate = .{ .value_type = node_type, .elements = span } } };
        },
        .fault => unreachable,
    }
}

/// The grant index of the handle an entry takes first, null within when it takes none; null when
/// the argument is no handle, which no admitted call passes.
fn handleOf(entry_: Entry, arguments: []const types.Value) ??u32 {
    if (entry_.params.len == 0 or !entry_.params[0].handle()) return @as(?u32, null);
    if (arguments.len == 0 or arguments[0] != .enumeration) return null;
    return @as(?u32, arguments[0].enumeration.index);
}

/// Whether a member a generic native produced can be one it was given: a structural value
/// names members that existed before the call, a string lies in the pool, a float is canonical.
fn movedValue(value: *types.Value, used_before: usize, strings: run_strings.Pool) bool {
    return switch (value.*) {
        .aggregate => |aggregate| aggregate.elements.start <= aggregate.elements.end and aggregate.elements.end <= used_before,
        .callable => |callable| callable.captures.start <= callable.captures.end and callable.captures.end <= used_before,
        // A string that was moved is text already. It is not read again: a view of the pool
        // that starts and ends between scalar values is text because the pool is, and a check
        // of its bytes would cost its length for every element that names it.
        .string => |text| moved: {
            if (text.len == 0) value.string = strings.empty();
            break :moved strings.aliases(text);
        },
        .floating => |float| types.isCanonicalFloat(float),
        .integer, .boolean, .enumeration, .object, .rational => true,
    };
}

/// The Forbic types a call binds the variables of a signature to.
const Binding = struct {
    element: ?types.Type = null,
    key: ?types.Type = null,

    fn unify(slot: *?types.Type, value_type: types.Type) bool {
        if (slot.*) |bound| return bound == value_type;
        slot.* = value_type;
        return true;
    }

    fn match(self: *Binding, shape: Shape, value_type: types.Type, definitions: []const types.Definition) bool {
        if (!shape.generic()) return typeMatches(shape, value_type, definitions);
        if (shape.kind == .scalar) return catalogue.validType(value_type, definitions) and unify(&self.element, value_type);
        const definition = catalogue.definition(value_type, definitions) orelse return false;
        switch (shape.kind) {
            .scalar, .unit => unreachable,
            .array => return definition == .array and self.matchElement(shape, definition.array),
            .option => return definition == .option and self.matchElement(shape, definition.option),
            .nested => {
                if (definition != .array) return false;
                const inner = catalogue.definition(definition.array, definitions) orelse return false;
                return inner == .array and self.matchElement(shape, inner.array);
            },
            .map => return definition == .map and unify(&self.key, definition.map.key) and self.matchElement(shape, definition.map.value),
        }
    }

    fn matchElement(self: *Binding, shape: Shape, element: types.Type) bool {
        // No collection of handles is a shape (`wellFormed`), whoever asks before checking.
        if (shape.handle()) return false;
        return if (shape.element == .any) unify(&self.element, element) else element == shape.builtin();
    }
};

/// Whether a call of `entry_` with operands of these types and this result type is well typed:
/// every concrete shape is matched exactly, the type variables are bound consistently, and a
/// `comparable` entry's variable is a comparable type (`comparable` is the catalogue's table).
/// Both machines admit a `native_call` with this, each from the types it derived itself.
pub fn admits(entry_: Entry, operands: []const types.Type, result: types.Type, definitions: []const types.Definition, comparable: []const bool) bool {
    if (operands.len != entry_.params.len) return false;
    var binding: Binding = .{};
    for (entry_.params, operands) |shape, operand| if (!binding.match(shape, operand, definitions)) return false;
    // A result names only variables the parameters bound (`wellFormed`).
    if (!binding.match(entry_.result, result, definitions)) return false;
    if (entry_.comparable) {
        const element = binding.element orelse return false;
        if (!catalogue.comparableIn(element, comparable)) return false;
    }
    if (binding.key) |key| if (!catalogue.comparableIn(key, comparable)) return false;
    return true;
}

/// True when `value_type` is exactly the Forbic type this shape denotes. A generic shape denotes
/// no one type: `admits` decides those.
pub fn typeMatches(shape: Shape, value_type: types.Type, definitions: []const types.Definition) bool {
    if (shape.generic()) return false;
    // A handle is the program's `grant(kind)` of its kind, and is only ever a scalar (RFC-0086).
    if (shape.handle()) return shape.kind == .scalar and catalogue.grantKind(value_type, definitions) == @as(?effects.GrantKind, if (shape.element == .reader) .reader else .writer);
    const element = shape.builtin();
    if (shape.kind == .scalar) return value_type == element;
    const definition = catalogue.definition(value_type, definitions) orelse return false;
    return switch (shape.kind) {
        .array => definition == .array and definition.array == element,
        .option => definition == .option and definition.option == element,
        .unit => definition == .tuple and definition.tuple.start == definition.tuple.end,
        .scalar, .nested, .map => unreachable,
    };
}

/// A registered entry is usable by programs only if it denotes representable types.
pub fn wellFormed(entry_: Entry) bool {
    if (entry_.params.len > max_parameters) return false;
    // A `native_call` runs outside every journal and frame: it has no effect to declare.
    if (@as(u8, @bitCast(entry_.effects)) != @as(u8, @bitCast(types.EffectSet{ .diverges = false }))) return false;
    // A variable the result names, or one that must be comparable, is bound by a parameter.
    var element = false;
    var key = false;
    for (entry_.params) |shape| {
        element = element or shape.element == .any;
        key = key or shape.kind == .map;
    }
    if (entry_.result.element == .any and !element) return false;
    if (entry_.result.kind == .map and !key) return false;
    if (entry_.result.kind == .nested or (entry_.result.kind != .array and entry_.result.kind != .map and entry_.result.element == .any)) return false;
    for (entry_.params) |shape| if (shape.kind == .unit) return false;
    // Nothing comes back from an action, or the guest would learn of the world through it;
    // and only an action yields nothing.
    if ((entry_.effect == .output) != (entry_.result.kind == .unit)) return false;
    // An effect is a function of scalars and strings, so that a replay can run it again
    // without the run's pools; what a draw gives is a number or a `logic`.
    if (entry_.effect != .none) for (entry_.params) |shape| {
        if (shape.kind != .scalar or shape.element == .any) return false;
    };
    if (entry_.effect == .draw and (entry_.result.kind != .scalar or entry_.result.element == .string or entry_.result.element == .any)) return false;
    // RFC-0086, P2.3: no native makes a handle (admission rule 3), and a handle is taken only
    // first, once: a reader by an input, a writer by an action, which acts on its channel.
    if (entry_.result.handle()) return false;
    for (entry_.params, 0..) |shape, index| if (shape.handle()) {
        if (index != 0 or shape.kind != .scalar) return false;
        if (shape.element != @as(Scalar, if (entry_.effect == .input) .reader else if (entry_.effect == .output) .writer else return false)) return false;
    };
    // What the world gives is a scalar, or an option of a scalar or a string (RFC-0086).
    if (entry_.effect == .input and ((entry_.result.kind != .scalar and entry_.result.kind != .option) or entry_.result.element == .any)) return false;
    // Of the effect natives only the output of one string predicts (RFC-0085, V22).
    if (entry_.predicts and entry_.effect != .none and (entry_.effect != .output or entry_.params.len != 1 or entry_.params[0].kind != .scalar or entry_.params[0].element != .string)) return false;
    return !entry_.comparable or element;
}

/// RFC-0087, P5.5: the diagnostics of an action a machine prepares itself (a store action), and
/// of an input it asks for (a load).
pub fn effectErrorCode(err: effects.Error) types.Diagnostic.Code {
    return switch (err) {
        error.EffectLimit => .effect_limit,
        error.EffectPrepareFailed => .effect_prepare_failed,
        error.EffectCommitFailed => .effect_commit_failed,
    };
}
pub fn inputErrorCode(err: effects.InputError) types.Diagnostic.Code {
    return switch (err) {
        error.InputLimit => .input_limit,
        error.InputFailed => .input_failed,
        error.InputUnavailable => .input_unavailable,
        error.InputInvalid => .input_invalid,
        error.InputDiverged => .input_diverged,
    };
}

/// The diagnostic a fault ends the run with.
pub fn faultCode(fault: Fault) types.Diagnostic.Code {
    return switch (fault) {
        .work_limit => .work_limit,
        .aggregate_limit => .aggregate_limit,
        .string_limit => .string_limit,
        .failed => .native_failed,
        .invalid => .invalid_native,
        .overflow => .arithmetic_overflow,
        .scratch => .scratch_unavailable,
        .effect_limit => .effect_limit,
        .effect_prepare_failed => .effect_prepare_failed,
        .effect_commit_failed => .effect_commit_failed,
        .input_limit => .input_limit,
        .input_failed => .input_failed,
        .input_unavailable => .input_unavailable,
        .input_invalid => .input_invalid,
        .input_diverged => .input_diverged,
    };
}

/// Runs an effect native again for a report replay, which lends its own port: the action goes
/// to the replay and the draws come from its stream. An effect native takes no aggregate and
/// returns none, so it needs neither the run's member pool nor its string pool; one that
/// reaches for either is not what the run ran. Returns the value of a draw, null for an
/// action, and `error.Failed` when the native does not complete as an effect native must.
/// `remaining` is charged what the native charges.
pub fn replay(entry_: Entry, arguments: []const types.Value, port: effects.Port, remaining: *u64) error{Failed}!?types.Value {
    if (entry_.effect == .none or !wellFormed(entry_) or arguments.len != entry_.params.len) return error.Failed;
    // An input is not run again: what the world gave is in the run's record (RFC-0086), which
    // the replay checks the call's value against.
    if (entry_.effect == .input) return error.Failed;
    const charge = callCost(entry_, arguments);
    if (charge > remaining.*) return error.Failed;
    var no_bytes: [0]u8 = .{};
    var no_members: [0]types.Value = .{};
    var strings = run_strings.Pool.init(no_bytes[0..0], &no_bytes);
    var context: Context = .{ .pool = &no_members, .used = 0, .remaining = remaining.* - charge, .strings = &strings, .effect = entry_.effect, .port = port, .handle = handleOf(entry_, arguments) orelse return error.Failed, .host = entry_.host };
    const outcome = entry_.call(&context, arguments);
    if (outcome == .fault or !outcomeMatches(entry_.result, outcome) or context.used != 0 or strings.used != 0) return error.Failed;
    remaining.* = context.remaining;
    return switch (outcome) {
        .scalar => |value| if (value == .floating and !types.isCanonicalFloat(value.floating)) error.Failed else value,
        .members => null,
        .fault => unreachable,
    };
}

pub fn faultError(fault: Fault) Error {
    return switch (fault) {
        .work_limit => error.WorkLimit,
        .aggregate_limit => error.AggregateLimit,
        .string_limit => error.StringLimit,
        .failed, .invalid => error.Failed,
        // A machine reads these from the fault itself (`faultCode`).
        .effect_limit, .effect_prepare_failed, .effect_commit_failed => error.Failed,
        .input_limit, .input_failed, .input_unavailable, .input_invalid, .input_diverged => error.Failed,
        .overflow => error.Overflow,
        .scratch => error.ScratchUnavailable,
    };
}

fn valueTag(element: Scalar) std.meta.Tag(types.Value) {
    return switch (element) {
        .i64 => .integer,
        .logic => .boolean,
        .float => .floating,
        .string => .string,
        // A handle is a value of its `grant(kind)` definition, an enumeration value (RFC-0086).
        .reader, .writer => .enumeration,
        .any => unreachable,
    };
}

/// Result type check shared by both machines: the outcome must match the declared shape.
pub fn outcomeMatches(shape: Shape, outcome: Outcome) bool {
    return switch (outcome) {
        .scalar => |value| shape.kind == .scalar and shape.element != .any and std.meta.activeTag(value) == valueTag(shape.element),
        .members => |span| shape.kind != .scalar and span.start <= span.end and (shape.kind != .option or span.end - span.start <= 1) and (shape.kind != .unit or span.end == span.start),
        .fault => true,
    };
}

test "entry derives exact signatures and rejects nothing representable" {
    const Fns = struct {
        fn dot(ctx: *Context, a: Array(f64), b: Array(f64)) f64 {
            _ = ctx;
            var total: f64 = 0;
            for (0..@min(a.len(), b.len())) |i| total += a.at(i) * b.at(i);
            return total;
        }
        fn find(ctx: *Context, items: Array(i64), wanted: i64) ?i64 {
            _ = ctx;
            for (0..items.len()) |i| if (items.at(i) == wanted) return @intCast(i);
            return null;
        }
        fn doubled(ctx: *Context, items: Array(i64)) Error!ArrayOut(i64) {
            const out = try ctx.array(i64, items.len());
            for (0..items.len()) |i| out.set(i, items.at(i) * 2);
            return out;
        }
    };
    const dot = comptime entry("t.dot", Fns.dot, .{ .base = 8, .per_element = 1 });
    try std.testing.expectEqual(@as(usize, 2), dot.params.len);
    try std.testing.expectEqual(Shape{ .element = .float, .kind = .array }, dot.params[0]);
    try std.testing.expectEqual(Shape{ .element = .float, .kind = .scalar }, dot.result);
    const find = comptime entry("t.find", Fns.find, .{});
    try std.testing.expectEqual(Shape{ .element = .i64, .kind = .option }, find.result);
    const doubled = comptime entry("t.doubled", Fns.doubled, .{});
    try std.testing.expectEqual(Shape{ .element = .i64, .kind = .array }, doubled.result);

    var pool: [8]types.Value = undefined;
    pool[0] = .{ .integer = 3 };
    pool[1] = .{ .integer = 5 };
    var text_backing: [8]u8 = undefined;
    var text_pool = run_strings.Pool.init(text_backing[0..0], &text_backing);
    var ctx: Context = .{ .pool = &pool, .used = 2, .remaining = 100, .strings = &text_pool };
    const args = [_]types.Value{.{ .aggregate = .{ .value_type = @fromBackingInt(@intCast(4)), .elements = .{ .start = 0, .end = 2 } } }};
    const out = doubled.call(&ctx, &args);
    try std.testing.expectEqual(types.Span{ .start = 2, .end = 4 }, out.members);
    try std.testing.expectEqual(@as(i64, 6), pool[2].integer);
    try std.testing.expectEqual(@as(i64, 10), pool[3].integer);
    try std.testing.expectEqual(@as(u64, 98), ctx.remaining);
    try std.testing.expectEqual(@as(u64, 1), callCost(doubled, &args));
}
