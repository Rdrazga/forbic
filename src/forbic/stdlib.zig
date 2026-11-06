//! The names of the Book's standard functions over numbers, arrays, maps and strings
//! (RFC-0077), and how each is called. The compiler asks this table what a name means only
//! after everything a program can declare has been asked, so none of the names is reserved.
//!
//! A function is called by its bare name with parentheses (`Sqrt(X)`); a method is written
//! after a value (`Items.Find[V]`) and belongs to the kind of its receiver. A failable form
//! takes brackets and needs a failure context, as in the Book.
const std = @import("std");

pub const Form = enum(u32) {
    // Functions.
    sqrt,
    pow,
    exp,
    ln,
    log,
    sin,
    cos,
    tan,
    arc_sin,
    arc_cos,
    arc_tan,
    sinh,
    cosh,
    tanh,
    ar_sinh,
    ar_cosh,
    ar_tanh,
    lerp,
    abs,
    min,
    max,
    clamp,
    concatenate,
    concatenate_maps,
    join,
    // Methods.
    find,
    remove_first_element,
    remove_all_elements,
    remove,
    replace_first_element,
    replace_all_elements,
    replace_element,
    replace_all,
    insert,
    last,
    slice,
    is_finite,
    // Functions added by RFC-0080, after the methods so that no earlier form moves.
    to_any,
    to_void,
    to_array,
    // Effects (RFC-0079): functions, which a caller needs `<transacts>` to call.
    print,
    to_diagnostic,
    get_random_int,
    get_random_float,
    shuffle,
    // Structured concurrency (RFC-0082). `Sleep(Seconds)` is a site; `Spawn{...}` and the type
    // `task(T)` are written with braces and as a type, and are here so that each yields to a
    // declaration of the name as the other standard names do.
    sleep,
    spawn,
    task_type,
    // The conversions of a refinement back to its base (RFC-0083), the Book's `int(X)` and
    // `float(X)`, spelled with the names of the base types.
    to_base_int,
    to_base_float,
    // P3.2: `T.Await()` and `E.Await()` (one form, read by the kind of the receiver),
    // `E.Signal(V)`, and the type `event(T)`, built with `event(T){}`.
    await_value,
    signal,
    event_type,
    // P3.3: `Sync(A1, ..., An)` and `Race(A1, ..., An)`, whose arguments are arms: each is
    // compiled as a function of its own, so the compiler reads them where it opens the form.
    sync,
    race,
    // P3.4: `Rush(A1, ..., An)`, read as `Sync` and `Race` are, and `Branch{...}`, written with
    // braces as `Spawn` is.
    rush,
    branch,
    // RFC-0084, P4.4: `Upon(G, Body)` and `When(G, Body)`, whose two arguments, the guard and
    // the body, are each compiled as a function of their own where the form is opened.
    upon,
    when,
    // P3.7: `T.Cancel()`, `NextTick()` (`Sleep(0.0)`), `GetSimulationElapsedTime()`, and the
    // types `awaitable(T)` and `signalable(T)`, the interfaces handles and events implement.
    cancel,
    next_tick,
    elapsed_time,
    awaitable_type,
    signalable_type,
    // RFC-0084, P4.5: `Batch{...}`, whose braces hold the body, as `Spawn`'s do.
    batch,
    // RFC-0084, P4.6: `Await(G)` without a receiver, whose argument, the guard, is compiled as a
    // function of its own where the form is opened, as the guard of `Upon` and `When` is.
    await_guard,
    // RFC-0082, P3.9: the types `sticky_event(T)`, built with `sticky_event(T){}`,
    // `subscribable_event(T)`, built with `subscribable_event(T){}`, and `cancelable`; and
    // `E.Subscribe(F)` of a subscribable event. `Await`, `Signal` and a `cancelable`'s `Cancel`
    // are the forms above, read by the kind of the receiver.
    sticky_event_type,
    subscribable_event_type,
    cancelable_type,
    subscribe,
    // RFC-0086, P2.2: `GetSecondsSinceEpoch()`, the wall clock, an input of the world.
    seconds_since_epoch,
    // RFC-0085, I8: the type `accessor`, of the unnamed parameter of a getter and a setter.
    accessor_type,
    // RFC-0086, P2.3: the types `reader` and `writer`, the handles of grants; `OpenReader[N]` and
    // `OpenWriter[N]`, which fail when the run has no grant of the name; and `R.ReadLine[]`, which
    // fails at the end of the stream, and `W.WriteLine(T)`.
    reader_type,
    writer_type,
    open_reader,
    open_writer,
    read_line,
    write_line,
    // RFC-0087, P5.1: the type `weak_map(K, V)`, here so that it yields to a declaration of the
    // name as `task(T)` does.
    weak_map_type,
    // RFC-0087, P5.4: the type `session` and `GetSession()`, which gives the run's one session.
    session_type,
    get_session,
    // RFC-0087, P5.3: `ToJson(V)`, and `FromJson[T][Text]`, which fails, and whose first bracket
    // holds a type, which the compiler reads where it opens the form.
    to_json,
    from_json,
    // RFC-0087, P5.5: the type `persistent_key` and `GetPersistentKey[Name]`, which gives the key
    // the host granted under the name, or fails.
    persistent_key_type,
    get_persistent_key,
    // RFC-0094, B6: `Profile(Tag, Body)`, the Book's `profile("Tag"): body`.
    profile,

    /// Whether the form can fail: it is then written with brackets.
    pub fn decides(self: Form) bool {
        return switch (self) {
            .find, .remove_first_element, .remove, .replace_first_element, .replace_element, .insert, .last, .slice, .is_finite => true,
            .open_reader, .open_writer, .read_line => true,
            .from_json => true,
            .get_persistent_key => true,
            else => false,
        };
    }

    /// The fewest and the most arguments the form takes after its receiver.
    pub fn arguments(self: Form) struct { min: u32, max: u32 } {
        return switch (self) {
            .sqrt, .exp, .ln, .sin, .cos, .tan, .arc_sin, .arc_cos, .sinh, .cosh, .tanh, .ar_sinh, .ar_cosh, .ar_tanh, .abs => .{ .min = 1, .max = 1 },
            .pow, .log, .min, .max, .concatenate_maps, .join => .{ .min = 2, .max = 2 },
            .arc_tan => .{ .min = 1, .max = 2 },
            .lerp, .clamp => .{ .min = 3, .max = 3 },
            // One array of arrays, or the arrays themselves: as many as a call has arguments.
            .concatenate => .{ .min = 1, .max = max_concatenated },
            .find, .remove_first_element, .remove_all_elements => .{ .min = 1, .max = 1 },
            .remove, .replace_first_element, .replace_all_elements, .replace_element, .replace_all, .insert => .{ .min = 2, .max = 2 },
            .last => .{ .min = 0, .max = 1 },
            .slice => .{ .min = 1, .max = 2 },
            .is_finite => .{ .min = 0, .max = 0 },
            .to_any, .to_void, .to_array => .{ .min = 1, .max = 1 },
            .await_value, .event_type => .{ .min = 0, .max = 0 },
            .signal => .{ .min = 1, .max = 1 },
            .print, .to_diagnostic, .shuffle => .{ .min = 1, .max = 1 },
            .get_random_int, .get_random_float => .{ .min = 2, .max = 2 },
            .sleep => .{ .min = 1, .max = 1 },
            .spawn, .task_type, .branch => .{ .min = 0, .max = 0 },
            .to_base_int, .to_base_float => .{ .min = 1, .max = 1 },
            // The arms are counted where the form ends (`concurrency_arms`).
            .sync, .race, .rush => .{ .min = 0, .max = std.math.maxInt(u32) },
            .upon, .when => .{ .min = 2, .max = 2 },
            .cancel, .next_tick, .elapsed_time, .awaitable_type, .signalable_type => .{ .min = 0, .max = 0 },
            .batch => .{ .min = 0, .max = 0 },
            .await_guard => .{ .min = 1, .max = 1 },
            .sticky_event_type, .subscribable_event_type, .cancelable_type => .{ .min = 0, .max = 0 },
            .subscribe => .{ .min = 1, .max = 1 },
            .seconds_since_epoch => .{ .min = 0, .max = 0 },
            .accessor_type => .{ .min = 0, .max = 0 },
            .reader_type, .writer_type, .read_line => .{ .min = 0, .max = 0 },
            .open_reader, .open_writer, .write_line => .{ .min = 1, .max = 1 },
            .weak_map_type => .{ .min = 0, .max = 0 },
            .session_type, .get_session => .{ .min = 0, .max = 0 },
            .to_json, .from_json => .{ .min = 1, .max = 1 },
            .persistent_key_type => .{ .min = 0, .max = 0 },
            .get_persistent_key => .{ .min = 1, .max = 1 },
            .profile => .{ .min = 2, .max = 2 },
        };
    }
};

/// `Concatenate(A, B, ...)` joins its arguments pairwise, so their number is bounded like the
/// parameters of a function.
pub const max_concatenated = 16;

/// Where the operator of a standard form keeps its `Form`: above every text method.
pub const first_head: u32 = 1 << 16;

const Named = struct { name: []const u8, form: Form };

const function_names = [_]Named{
    .{ .name = "Sqrt", .form = .sqrt },
    .{ .name = "Pow", .form = .pow },
    .{ .name = "Exp", .form = .exp },
    .{ .name = "Ln", .form = .ln },
    .{ .name = "Log", .form = .log },
    .{ .name = "Sin", .form = .sin },
    .{ .name = "Cos", .form = .cos },
    .{ .name = "Tan", .form = .tan },
    .{ .name = "ArcSin", .form = .arc_sin },
    .{ .name = "ArcCos", .form = .arc_cos },
    .{ .name = "ArcTan", .form = .arc_tan },
    .{ .name = "Sinh", .form = .sinh },
    .{ .name = "Cosh", .form = .cosh },
    .{ .name = "Tanh", .form = .tanh },
    .{ .name = "ArSinh", .form = .ar_sinh },
    .{ .name = "ArCosh", .form = .ar_cosh },
    .{ .name = "ArTanh", .form = .ar_tanh },
    .{ .name = "Lerp", .form = .lerp },
    .{ .name = "Abs", .form = .abs },
    .{ .name = "Min", .form = .min },
    .{ .name = "Max", .form = .max },
    .{ .name = "Clamp", .form = .clamp },
    .{ .name = "Concatenate", .form = .concatenate },
    .{ .name = "ConcatenateMaps", .form = .concatenate_maps },
    .{ .name = "Join", .form = .join },
    // The Book's `any(X)` and `void(X)` (RFC-0080): the explicit ways to the top type and to
    // the unit value. Like every name here they yield to a declaration of the program.
    .{ .name = "any", .form = .to_any },
    .{ .name = "void", .form = .to_void },
    // The explicit tuple-to-array conversion (RFC-0067 D8).
    .{ .name = "ToArray", .form = .to_array },
    .{ .name = "Print", .form = .print },
    .{ .name = "ToDiagnostic", .form = .to_diagnostic },
    .{ .name = "GetRandomInt", .form = .get_random_int },
    .{ .name = "GetRandomFloat", .form = .get_random_float },
    .{ .name = "Shuffle", .form = .shuffle },
    .{ .name = "Sleep", .form = .sleep },
    .{ .name = "Spawn", .form = .spawn },
    .{ .name = "task", .form = .task_type },
    .{ .name = "event", .form = .event_type },
    .{ .name = "Sync", .form = .sync },
    .{ .name = "Race", .form = .race },
    .{ .name = "Rush", .form = .rush },
    .{ .name = "Branch", .form = .branch },
    .{ .name = "Upon", .form = .upon },
    .{ .name = "When", .form = .when },
    .{ .name = "NextTick", .form = .next_tick },
    .{ .name = "GetSimulationElapsedTime", .form = .elapsed_time },
    .{ .name = "awaitable", .form = .awaitable_type },
    .{ .name = "signalable", .form = .signalable_type },
    .{ .name = "Batch", .form = .batch },
    .{ .name = "Await", .form = .await_guard },
    .{ .name = "sticky_event", .form = .sticky_event_type },
    .{ .name = "subscribable_event", .form = .subscribable_event_type },
    .{ .name = "cancelable", .form = .cancelable_type },
    .{ .name = "GetSecondsSinceEpoch", .form = .seconds_since_epoch },
    .{ .name = "accessor", .form = .accessor_type },
    .{ .name = "reader", .form = .reader_type },
    .{ .name = "writer", .form = .writer_type },
    .{ .name = "OpenReader", .form = .open_reader },
    .{ .name = "OpenWriter", .form = .open_writer },
    .{ .name = "weak_map", .form = .weak_map_type },
    .{ .name = "session", .form = .session_type },
    .{ .name = "GetSession", .form = .get_session },
    .{ .name = "ToJson", .form = .to_json },
    .{ .name = "FromJson", .form = .from_json },
    .{ .name = "persistent_key", .form = .persistent_key_type },
    .{ .name = "GetPersistentKey", .form = .get_persistent_key },
    .{ .name = "Profile", .form = .profile },
};

const array_methods = [_]Named{
    .{ .name = "Find", .form = .find },
    .{ .name = "RemoveFirstElement", .form = .remove_first_element },
    .{ .name = "RemoveAllElements", .form = .remove_all_elements },
    .{ .name = "Remove", .form = .remove },
    .{ .name = "ReplaceFirstElement", .form = .replace_first_element },
    .{ .name = "ReplaceAllElements", .form = .replace_all_elements },
    .{ .name = "ReplaceElement", .form = .replace_element },
    .{ .name = "ReplaceAll", .form = .replace_all },
    .{ .name = "Insert", .form = .insert },
    .{ .name = "Last", .form = .last },
    .{ .name = "Slice", .form = .slice },
};

/// A string is text, not an array of code units (RFC-0067 D11), so it has the methods that
/// keep it text. `Slice` is the text method of RFC-0069. The element-wise ones are those of a
/// `[]char`, which `For(C:S, C)` gives and `string[Units]` takes back.
const string_methods = [_]Named{
    .{ .name = "Find", .form = .find },
    .{ .name = "Remove", .form = .remove },
    .{ .name = "ReplaceAll", .form = .replace_all },
    .{ .name = "Insert", .form = .insert },
    .{ .name = "Last", .form = .last },
};

const float_methods = [_]Named{.{ .name = "IsFinite", .form = .is_finite }};

/// The members of a task handle and of an event (RFC-0082, P3.2).
const task_methods = [_]Named{ .{ .name = "Await", .form = .await_value }, .{ .name = "Cancel", .form = .cancel } };
const event_methods = [_]Named{
    .{ .name = "Await", .form = .await_value },
    .{ .name = "Signal", .form = .signal },
};

/// The members of the interfaces of P3.7: `awaitable(T)` can be awaited, `signalable(T)`
/// signalled, and nothing else (Book 14:1667).
const awaitable_methods = [_]Named{.{ .name = "Await", .form = .await_value }};
const signalable_methods = [_]Named{.{ .name = "Signal", .form = .signal }};

/// The members of the events of P3.9 and of a subscription.
const sticky_event_methods = [_]Named{
    .{ .name = "Await", .form = .await_value },
    .{ .name = "Signal", .form = .signal },
};
const subscribable_event_methods = [_]Named{
    .{ .name = "Await", .form = .await_value },
    .{ .name = "Signal", .form = .signal },
    .{ .name = "Subscribe", .form = .subscribe },
};
const cancelable_methods = [_]Named{.{ .name = "Cancel", .form = .cancel }};
/// RFC-0086, P2.3: the members of the handles.
const reader_methods = [_]Named{.{ .name = "ReadLine", .form = .read_line }};
const writer_methods = [_]Named{.{ .name = "WriteLine", .form = .write_line }};

/// What a value can be the receiver of.
pub const Receiver = enum { array, string, float, task, event, awaitable, signalable, sticky_event, subscribable_event, cancelable, reader, writer };

fn lookup(table: []const Named, name: []const u8) ?Form {
    for (table) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.form;
    return null;
}

/// The standard function a bare name spells.
pub fn function(name: []const u8) ?Form {
    return lookup(&function_names, name);
}

/// The standard method `name` of a receiver of this kind.
pub fn method(receiver: Receiver, name: []const u8) ?Form {
    return lookup(switch (receiver) {
        .array => &array_methods,
        .string => &string_methods,
        .float => &float_methods,
        .task => &task_methods,
        .event => &event_methods,
        .awaitable => &awaitable_methods,
        .signalable => &signalable_methods,
        .sticky_event => &sticky_event_methods,
        .subscribable_event => &subscribable_event_methods,
        .cancelable => &cancelable_methods,
        .reader => &reader_methods,
        .writer => &writer_methods,
    }, name);
}

/// The one constant: the nearest `float` to pi (02:457).
pub const pi_name = "PiFloat";

/// Where the compiler remembers, per scope, whether a program declares a name itself: a form
/// by its number, the constant, the four bit operations of RFC-0072 from `bit_base` on and, after
/// them, the four metatype words (RFC-0081, B8).
pub const pi_bit: u32 = 127;
pub const bit_base: u32 = 119;

comptime {
    std.debug.assert(std.enums.values(Form).len <= bit_base);
}

test "names are unique within their table and forms know their calls" {
    for ([_][]const Named{ &function_names, &array_methods, &string_methods, &float_methods, &task_methods, &event_methods, &awaitable_methods, &signalable_methods, &sticky_event_methods, &subscribable_event_methods, &cancelable_methods, &reader_methods, &writer_methods }) |table| {
        for (table, 0..) |entry, index| {
            for (table[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, entry.name, other.name));
            const bounds = entry.form.arguments();
            try std.testing.expect(bounds.min <= bounds.max);
        }
    }
    // Every function takes parentheses, none of them failing, but the openings of grants
    // (RFC-0086, P2.3), which fail when the run has no grant of the name, and `FromJson`
    // (RFC-0087, P5.3), which fails when its text encodes no value.
    for (function_names) |entry| try std.testing.expect(!entry.form.decides() or entry.form == .open_reader or entry.form == .open_writer or entry.form == .get_persistent_key or entry.form == .from_json);
    try std.testing.expect(Form.from_json.decides() and !Form.to_json.decides());
    try std.testing.expect(Form.read_line.decides() and !Form.write_line.decides());
    try std.testing.expectEqual(Form.read_line, method(.reader, "ReadLine").?);
    try std.testing.expect(method(.writer, "ReadLine") == null and method(.reader, "WriteLine") == null);
    try std.testing.expectEqual(Form.find, method(.array, "Find").?);
    try std.testing.expectEqual(Form.find, method(.string, "Find").?);
    try std.testing.expect(method(.string, "ReplaceElement") == null and method(.string, "Slice") == null);
    try std.testing.expect(method(.float, "Find") == null and function("Find") == null and function("IsFinite") == null);
    try std.testing.expectEqual(Form.concatenate_maps, function("ConcatenateMaps").?);
    try std.testing.expectEqual(Form.print, function("Print").?);
    try std.testing.expectEqual(Form.shuffle, function("Shuffle").?);
    try std.testing.expect(method(.array, "Shuffle") == null);
    try std.testing.expect(Form.find.decides() and Form.last.decides() and !Form.replace_all.decides() and !Form.remove_all_elements.decides());
}
