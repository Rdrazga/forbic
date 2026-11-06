//! Developer report, not an executable artifact. Validate before writing.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const bytecode = @import("bytecode.zig");
const vm = @import("vm.zig");
const reporting = @import("value_report.zig");
const modules = @import("modules.zig");
const catalogue = @import("aggregate_types.zig");
const persist_json = @import("persist_json.zig");
pub const Result = union(enum) { ok, failed: types.Diagnostic };
pub const Limits = struct { output_bytes: u64 = types.limits.document_bytes };

pub const Workspace = struct {
    instructions: [types.limits.nodes]vm.Instruction = undefined,
    register_types: [types.limits.nodes]types.Type = undefined,

    /// All IR/source/strings/bindings remain immutable and borrowed until this
    /// call returns; the workspace has one writer. No VM values/journal allocation
    /// or guest execution occurs. Successful validation does not grant cached trust.
    pub fn write(self: *Workspace, out: *std.Io.Writer, ir: types.Program) std.Io.Writer.Error!Result {
        return self.writeBounded(out, ir, .{});
    }

    /// Metadata traversal is linear in the fixed instruction/type/member pools.
    /// Exact compact JSON byte admission includes escaping and the trailing LF.
    pub fn writeBounded(self: *Workspace, out: *std.Io.Writer, ir: types.Program, limits: Limits) std.Io.Writer.Error!Result {
        const program = switch (bytecode.lower(ir, &self.instructions)) {
            .ok => |program| program,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        const registers = switch (vm.verify(program, &self.register_types)) {
            .ok => |count| count,
            .failed => |diagnostic| return .{ .failed = diagnostic },
        };
        // The VM uses binding spans as metadata. A report emits names as JSON
        // text, so reject a slice through a UTF-8 code point before any output.
        for (program.bindings) |binding| {
            if (!std.unicode.utf8ValidateSlice(binding.name.text(program.source))) {
                return .{ .failed = .{ .span = binding.name, .code = .invalid_bytecode } };
            }
        }
        var count_buffer: [256]u8 = undefined;
        var counter = reporting.CountingWriter.init(&count_buffer, limits.output_bytes);
        writeVerified(&counter.writer, program, registers) catch return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .report_limit } };
        counter.writer.flush() catch return .{ .failed = .{ .span = .{ .start = 0, .end = 0 }, .code = .report_limit } };
        try writeVerified(out, program, registers);
        return .ok;
    }
};

fn writeVerified(out: *std.Io.Writer, program: vm.Program, registers: usize) std.Io.Writer.Error!void {
    std.debug.assert(registers <= types.limits.nodes);
    std.debug.assert(program.code.len <= types.limits.nodes);
    var json: std.json.Stringify = .{ .writer = out };
    try json.beginObject();
    try json.objectField("format");
    const aggregates = program.definitions.len != 0;
    const enums = hasEnums(program.definitions);
    const tuples = hasTuples(program.definitions);
    var collections = false;
    for (program.definitions) |definition| if (definition == .map or definition == .option) {
        collections = true;
        break;
    };
    const bundled = program.modules.len != 0;
    var predicates = false;
    for (program.code) |instruction| if (instruction.op == .compare or instruction.op == .logic_not or instruction.op == .logic_binary) {
        predicates = true;
        break;
    };
    var specialized = false;
    for (program.functions) |f| specialized = specialized or f.specialization != null;
    var anonymous = false;
    for (program.functions) |f| anonymous = anonymous or f.anonymous;
    var bound_captures = false;
    for (program.code) |instruction| if (instruction.op == .bind) {
        bound_captures = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .bind) {
        bound_captures = true;
    };
    var state_loop = false;
    for (program.code) |instruction| if (instruction.op == .loop) {
        state_loop = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .loop) {
        state_loop = true;
    };
    var callable_iteration = false;
    for (program.code) |instruction| if (instruction.op == .iterate_value) {
        callable_iteration = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .iterate_value) {
        callable_iteration = true;
    };
    var callables = false;
    for (program.definitions) |definition| if (definition == .callable) {
        callables = true;
    };
    var recursion = false;
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .recur) {
        recursion = true;
    };
    var iteration = false;
    for (program.code) |instruction| if (instruction.op == .iterate) {
        iteration = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .iterate) {
        iteration = true;
    };
    var local_state = false;
    for (program.code) |instruction| if (instruction.op == .local_set) {
        local_state = true;
    };
    for (program.functions) |f| if (f.has_local) {
        local_state = true;
    };
    var frame_control = false;
    var frame_failure = false;
    var frame_decides = false;
    var frame_transacts = false;
    for (program.functions) |f| if (f.transacts) {
        frame_transacts = true;
    };
    for (program.functions) |f| if (f.decides) {
        frame_decides = true;
    };
    for (program.functions) |f| if (f.has_failure) {
        frame_failure = true;
    };
    for (program.functions) |f| if (f.has_control) {
        frame_control = true;
    };
    // Format 26: a function or a function type declares an effect set the earlier formats
    // cannot say (RFC-0078): some of `reads`, `writes`, `allocates`, or `suspends`, `converges`.
    // Every function and function type then lists its whole set under `effects`.
    var effect_families = false;
    for (program.functions) |f| if (@as(u8, @bitCast(f.detail)) != 0) {
        effect_families = true;
    };
    for (program.definitions) |item| if (item == .callable and @as(u8, @bitCast(item.callable.detail)) != 0) {
        effect_families = true;
    };
    // Format 25: a function body leaves early (`exit`) or the program can end with `err`.
    var early_exit = false;
    for (program.code) |instruction| if (instruction.op == .err) {
        early_exit = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .exit or entry.node.kind == .err)) {
        early_exit = true;
    };
    // Format 27: a node of structured concurrency (RFC-0082): `spawn`, `sleep`, a check, or from
    // P3.2 an await, an event or a signal, or from P3.3 a `Sync` or a `Race`, or from P3.4 a `Branch`.
    var concurrency = false;
    for (program.code) |instruction| switch (instruction.op) {
        .spawn, .sleep, .canceling, .cancel_exit, .task_await, .event_new, .event_signal, .event_await, .structured, .branch, .task_cancel, .elapsed_time, .await_guard => concurrency = true,
        .event_subscribe, .subscription_cancel, .event_notify => concurrency = true,
        else => {},
    };
    for (program.function_nodes) |entry| if (entry.input == .operation) switch (entry.node.kind) {
        .spawn, .sleep, .canceling, .cancel_exit, .task_await, .event_new, .event_signal, .event_await, .structured, .branch, .task_cancel, .elapsed_time, .await_guard => concurrency = true,
        .event_subscribe, .subscription_cancel, .event_notify => concurrency = true,
        else => {},
    };
    // P3.7: `awaitable(T)` and `signalable(T)` are catalogue entries of format 27 too, and from
    // P3.9 `cancelable` and the sticky and subscribable kinds of event.
    for (program.definitions) |item| if (item == .scheduled_interface or item == .cancelable or (item == .event and item.event.kind != .plain)) {
        concurrency = true;
    };
    // Format 29: a live program (RFC-0084): it holds a `cell_live`, and its catalogue a `live(T)`,
    // or from P4.4 a `reaction`, or from P4.5 a `batch`, or from P4.6 an `await_guard`.
    var live_program = false;
    for (program.code) |instruction| if (instruction.op == .cell_live or instruction.op == .object_live or instruction.op == .reaction or instruction.op == .batch or instruction.op == .await_guard) {
        live_program = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .cell_live or entry.node.kind == .object_live or entry.node.kind == .reaction or entry.node.kind == .batch or entry.node.kind == .await_guard)) {
        live_program = true;
    };
    // Format 32: a variable cell (RFC-0085, I1): a `ref(T)` definition or a `ref_*` operation.
    var variable_cells = false;
    for (program.definitions) |item| if (item == .ref) {
        variable_cells = true;
    };
    for (program.code) |instruction| if (instruction.op == .ref_new or instruction.op == .ref_get or instruction.op == .ref_set) {
        variable_cells = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and (entry.node.kind == .ref_new or entry.node.kind == .ref_get or entry.node.kind == .ref_set)) {
        variable_cells = true;
    };
    // Format 35: a handle (RFC-0086, P2.3): a `grant(kind)` definition or a `grant` operation.
    var handles = false;
    for (program.definitions) |item| if (item == .grant) {
        handles = true;
    };
    for (program.code) |instruction| if (instruction.op == .grant) {
        handles = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .grant) {
        handles = true;
    };
    // Format 28: a refinement type, a `refine` node or an open enum (RFC-0083).
    var refinements = false;
    for (program.definitions) |item| if (item == .refinement or (item == .enumeration and item.enumeration.is_open)) {
        refinements = true;
    };
    for (program.code) |instruction| if (instruction.op == .refine) {
        refinements = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .refine) {
        refinements = true;
    };
    // Format 30: a transparent function (RFC-0085, I7), listed under `function_transparent`.
    var transparent = false;
    for (program.functions) |f| transparent = transparent or f.transparent;
    // Format 31: a function or a function type predicts (RFC-0085, I12); its effect list of
    // format 26 says `predicts`.
    var predicting = false;
    for (program.functions) |f| predicting = predicting or f.detail.predicts;
    for (program.definitions) |item| if (item == .callable and item.callable.detail.predicts) {
        predicting = true;
    };
    // Format 36: a `weak_map(K, V)` definition (RFC-0087, P5.1).
    var weak_maps = false;
    for (program.definitions) |item| if (item == .weak_map) {
        weak_maps = true;
    };
    // Format 37: a nested function (RFC-0085, I3), listed under `function_nested`.
    var nested = false;
    for (program.functions) |f| nested = nested or f.nested;
    // Format 39: a `<persistable>` struct, class or enum (RFC-0087, P5.2): the flag, the
    // fields' constants and the table of them.
    var persistables = false;
    for (program.definitions) |item| switch (item) {
        .record => |record| persistables = persistables or record.persistable,
        .class => |class| persistables = persistables or class.persistable,
        .enumeration => |enumeration| persistables = persistables or enumeration.persistable,
        else => {},
    };
    // Format 43: a keyed cell or the session (RFC-0087, P5.4): a cell that says `keyed`, a
    // `weak_*` operation, a `grant(session)` definition or a `grant` of kind `session`.
    var keyed = false;
    for (program.source_cells) |cell| keyed = keyed or cell.keyed != .none;
    for (program.definitions) |item| if (item == .grant and item.grant == .session) {
        keyed = true;
    };
    for (program.code) |instruction| if (keyedOperation(instruction.op)) {
        keyed = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and keyedOperation(vm.instructionFromNode(entry.node).op)) {
        keyed = true;
    };
    // Format 46: a JSON operation (RFC-0087, P5.3), `{"json_encode":N}` or `{"json_decode":N}`.
    var json_operations = false;
    for (program.code) |instruction| json_operations = json_operations or instruction.op == .json_encode or instruction.op == .json_decode;
    for (program.function_nodes) |entry| json_operations = json_operations or (entry.input == .operation and (entry.node.kind == .json_encode or entry.node.kind == .json_decode));
    // Format 47: a persistent cell or key (RFC-0087, P5.5): a cell that says `persistent`, a
    // `grant(key)` definition or a `grant` of kind `key`.
    var persistent = false;
    for (program.source_cells) |cell| persistent = persistent or cell.keyed == .persistent;
    for (program.definitions) |item| if (item == .grant and item.grant == .key) {
        persistent = true;
    };
    for (program.code) |instruction| if (instruction.op == .grant and instruction.op.grant.kind == .key) {
        persistent = true;
    };
    for (program.function_nodes) |entry| if (entry.input == .operation and entry.node.kind == .grant and entry.node.kind.grant.kind == .key) {
        persistent = true;
    };
    // Format 52: a `<final_super>` or `<final_super_base>` class (RFC-0092, B4).
    var final_supers = false;
    for (program.definitions) |item| if (item == .class and (item.class.final_super or item.class.final_super_base)) {
        final_supers = true;
    };
    try json.write(@as(u8, if (final_supers) 52 else if (persistent) 47 else if (json_operations) 46 else if (keyed) 43 else if (persistables) 39 else if (nested) 37 else if (weak_maps) 36 else if (handles) 35 else if (variable_cells) 32 else if (predicting) 31 else if (transparent) 30 else if (live_program) 29 else if (refinements) 28 else if (concurrency) 27 else if (effect_families) 26 else if (early_exit) 25 else if (program.slots.len != 0) 24 else if (specialized) 23 else if (anonymous) 22 else if (bound_captures) 21 else if (state_loop) 20 else if (callable_iteration) 19 else if (callables) 18 else if (recursion) 17 else if (iteration) 16 else if (local_state) 15 else if (frame_transacts) 14 else if (frame_decides) 13 else if (frame_failure) 12 else if (frame_control) 11 else if (program.functions.len != 0 or program.call_ops != 0) 10 else if (program.source_ops != 0) 9 else if (program.control_ops != 0) 8 else if (predicates) 7 else if (bundled) 6 else if (collections) 5 else if (tuples) 4 else if (enums) 3 else if (aggregates) 2 else 1));
    try json.objectField("representation");
    try json.write("forbos_in_memory_register_bytecode");
    try json.objectField("instruction_count");
    try json.write(program.code.len);
    try json.objectField("register_count");
    try json.write(registers);
    try json.objectField("string_bytes");
    try json.write(program.strings.len);
    // Emit the decoded pool once. Function-expanded literals can share spans;
    // repeating their text per instruction would amplify large inspection output.
    try json.objectField("string_pool");
    try json.write(program.strings);
    if (bundled) {
        try json.objectField("modules");
        try json.beginArray();
        for (program.modules, 0..) |module, index| try json.write(.{ .id = index, .path = module.path.text(program.paths), .source = module.source, .imports = module.imports });
        try json.endArray();
        try json.objectField("imports");
        try json.beginArray();
        for (program.imports, 0..) |edge, index| try json.write(.{ .index = index, .alias = edge.alias.text(program.source), .path = edge.path.text(program.source), .target = edge.target, .span = edge.alias });
        try json.endArray();
        // Modules declared inside files (RFC-0074). A program without one prints what it always did.
        if (program.nested.len != 0) {
            try json.objectField("nested_modules");
            try json.beginArray();
            for (program.nested, 0..) |module, index| {
                const parent: ?u32 = if (module.parent == types.no_parent) null else module.parent;
                try json.write(.{ .index = index, .name = module.name.text(program.source), .module = modules.owner(module.source, program.modules).?, .parent = parent, .public = module.is_public, .source = module.source, .span = module.name });
            }
            try json.endArray();
        }
        // The files of the modules of a folder tree (RFC-0093); no other program prints this.
        if (program.parts.len != 0) {
            try json.objectField("module_files");
            try json.beginArray();
            for (program.parts, 0..) |part, index| try json.write(.{ .index = index, .path = part.path.text(program.file_paths), .module = modules.owner(part.source, program.modules).?, .source = part.source });
            try json.endArray();
        }
    }
    if (aggregates) {
        try json.objectField("type_definitions");
        try json.beginArray();
        for (program.definitions, 0..) |definition, index| {
            switch (definition) {
                .record => |record| if (record.persistable) {
                    // RFC-0087, P5.2: a persistable struct says so; no other struct prints otherwise.
                    try json.beginObject();
                    try json.objectField("id");
                    try json.write(index + 4);
                    try json.objectField("kind");
                    try json.write("record");
                    try json.objectField("name");
                    try json.write(record.name.text(program.source));
                    if (bundled) {
                        try json.objectField("module");
                        try json.write(modules.owner(record.name, program.modules).?);
                    }
                    try json.objectField("fields");
                    try json.write(record.fields);
                    try json.objectField("public");
                    try json.write(record.is_public);
                    try json.objectField("persistable");
                    try json.write(true);
                    try json.endObject();
                } else if (record.arguments) |arguments| {
                    // An instantiation of a parametric struct (RFC-0073): the template's name
                    // with the types it was made for.
                    try json.beginObject();
                    try json.objectField("id");
                    try json.write(index + 4);
                    try json.objectField("kind");
                    try json.write("record");
                    try json.objectField("name");
                    try json.write(record.name.text(program.source));
                    if (bundled) {
                        try json.objectField("module");
                        try json.write(modules.owner(record.name, program.modules).?);
                    }
                    try json.objectField("fields");
                    try json.write(record.fields);
                    try json.objectField("public");
                    try json.write(record.is_public);
                    try json.objectField("arguments");
                    const list = catalogue.definition(arguments, program.definitions).?.tuple;
                    try json.write(program.tuple_elements[list.start..list.end]);
                    try json.endObject();
                } else if (bundled) try json.write(.{ .id = index + 4, .kind = "record", .name = record.name.text(program.source), .module = modules.owner(record.name, program.modules).?, .fields = record.fields, .public = record.is_public }) else try json.write(.{ .id = index + 4, .kind = "record", .name = record.name.text(program.source), .fields = record.fields, .public = record.is_public }),
                .class => |class| {
                    // Inheritance and specifiers appear only when used, so plain classes keep their shape.
                    try json.beginObject();
                    try json.objectField("id");
                    try json.write(index + 4);
                    try json.objectField("kind");
                    try json.write(if (class.is_interface) "interface" else "class");
                    try json.objectField("name");
                    try json.write(class.name.text(program.source));
                    if (bundled) {
                        try json.objectField("module");
                        try json.write(modules.owner(class.name, program.modules).?);
                    }
                    try json.objectField("fields");
                    try json.write(class.fields);
                    try json.objectField("public");
                    try json.write(class.is_public);
                    if (class.parent) |parent| {
                        try json.objectField("parent");
                        try json.write(parent);
                        try json.objectField("inherited");
                        try json.write(class.inherited);
                    }
                    if (class.interface_count != 0) {
                        try json.objectField("interfaces");
                        try json.write(class.implemented());
                    }
                    if (class.is_abstract and !class.is_interface) {
                        try json.objectField("abstract");
                        try json.write(true);
                    }
                    if (class.is_final) {
                        try json.objectField("final");
                        try json.write(true);
                    }
                    if (class.is_unique) {
                        try json.objectField("unique");
                        try json.write(true);
                    }
                    if (class.persistable) {
                        try json.objectField("persistable");
                        try json.write(true);
                    }
                    if (class.final_super) {
                        try json.objectField("final_super");
                        try json.write(true);
                    }
                    if (class.final_super_base) {
                        try json.objectField("final_super_base");
                        try json.write(true);
                    }
                    if (class.arguments) |arguments| {
                        // An instantiation of a parametric type (RFC-0073): `name` is the
                        // template's, and these are the types it was made for.
                        try json.objectField("arguments");
                        const list = catalogue.definition(arguments, program.definitions).?.tuple;
                        try json.write(program.tuple_elements[list.start..list.end]);
                    }
                    try json.endObject();
                },
                .array => |element| try json.write(.{ .id = index + 4, .kind = "array", .element = element }),
                .enumeration => |enumeration| if (enumeration.is_open or enumeration.persistable) {
                    // An open enum (RFC-0083) says so; a closed one prints as it did.
                    try json.beginObject();
                    try json.objectField("id");
                    try json.write(index + 4);
                    try json.objectField("kind");
                    try json.write("enumeration");
                    try json.objectField("name");
                    try json.write(enumeration.name.text(program.source));
                    if (bundled) {
                        try json.objectField("module");
                        try json.write(modules.owner(enumeration.name, program.modules).?);
                    }
                    try json.objectField("cases");
                    try json.write(enumeration.cases);
                    try json.objectField("public");
                    try json.write(enumeration.is_public);
                    if (enumeration.is_open) {
                        try json.objectField("open");
                        try json.write(true);
                    }
                    if (enumeration.persistable) {
                        try json.objectField("persistable");
                        try json.write(true);
                    }
                    try json.endObject();
                } else if (bundled) try json.write(.{ .id = index + 4, .kind = "enumeration", .name = enumeration.name.text(program.source), .module = modules.owner(enumeration.name, program.modules).?, .cases = enumeration.cases, .public = enumeration.is_public }) else try json.write(.{ .id = index + 4, .kind = "enumeration", .name = enumeration.name.text(program.source), .cases = enumeration.cases, .public = enumeration.is_public }),
                .tuple => |span| try json.write(.{ .id = index + 4, .kind = "tuple", .elements = span }),
                .option => |element| try json.write(.{ .id = index + 4, .kind = "option", .element = element }),
                .rational => try json.write(.{ .id = index + 4, .kind = "rational" }),
                // A task handle type (RFC-0082): its result and the option of it its result cell holds.
                .task => |shape| try json.write(.{ .id = index + 4, .kind = "task", .result = shape.result, .option = shape.option }),
                // An event type (P3.2): the type its signals carry.
                // From P3.9 of a kind: `sticky_event` or `subscribable_event`.
                .event => |event| try json.write(.{ .id = index + 4, .kind = switch (event.kind) {
                    .plain => "event",
                    .sticky => "sticky_event",
                    .subscribable => "subscribable_event",
                }, .value = event.value }),
                // P3.9: the type of a subscription.
                .cancelable => try json.write(.{ .id = index + 4, .kind = "cancelable" }),
                // A live record type (RFC-0084): the type of the cell it follows.
                .live => |value| try json.write(.{ .id = index + 4, .kind = "live", .value = value }),
                // A variable cell type (RFC-0085, I1): the type of the value it holds.
                .ref => |value| try json.write(.{ .id = index + 4, .kind = "ref", .value = value }),
                // A handle type (RFC-0086, P2.3): the kind of grant it names.
                .grant => |kind| try json.write(.{ .id = index + 4, .kind = "grant", .grant = kind }),
                // RFC-0082, P3.7.
                .scheduled_interface => |interface| try json.write(.{ .id = index + 4, .kind = @tagName(interface.kind), .value = interface.value }),
                // A refinement type (RFC-0083): its base and its bounds, which are open only
                // where that is said.
                .refinement => |refinement| {
                    try json.beginObject();
                    try json.objectField("id");
                    try json.write(index + 4);
                    try json.objectField("kind");
                    try json.write("refinement");
                    try json.objectField("name");
                    try json.write(refinement.name.text(program.source));
                    if (bundled) {
                        try json.objectField("module");
                        try json.write(modules.owner(refinement.name, program.modules).?);
                    }
                    try json.objectField("base");
                    try json.write(refinement.base);
                    try json.objectField("low");
                    if (refinement.base == .i64) try json.write(@as(i64, @bitCast(refinement.low))) else try json.write(types.FloatReport{ .value = @bitCast(refinement.low) });
                    try json.objectField("high");
                    if (refinement.base == .i64) try json.write(@as(i64, @bitCast(refinement.high))) else try json.write(types.FloatReport{ .value = @bitCast(refinement.high) });
                    if (refinement.low_open) {
                        try json.objectField("low_open");
                        try json.write(true);
                    }
                    if (refinement.high_open) {
                        try json.objectField("high_open");
                        try json.write(true);
                    }
                    try json.objectField("public");
                    try json.write(refinement.is_public);
                    try json.endObject();
                },
                .callable => |shape| if (effect_families) {
                    var names: EffectNames = undefined;
                    try json.write(.{ .id = index + 4, .kind = "function", .parameters = shape.parameters, .result = shape.result, .transacts = shape.transacts, .decides = shape.decides, .effects = effectNames(shape.effects(), &names) });
                } else try json.write(.{ .id = index + 4, .kind = "function", .parameters = shape.parameters, .result = shape.result, .transacts = shape.transacts, .decides = shape.decides }),
                .map => |shape| try json.write(.{ .id = index + 4, .kind = "map", .key = shape.key, .value = shape.value }),
                // RFC-0087, P5.1: a weak map type, with its key and value types.
                .weak_map => |shape| try json.write(.{ .id = index + 4, .kind = "weak_map", .key = shape.key, .value = shape.value }),
            }
        }
        try json.endArray();
        try json.objectField("fields");
        try json.beginArray();
        for (program.fields, 0..) |field, index| {
            if (field.hidden or field.live_only or field.constant != null) {
                // Appended only when set, so a program without such a field prints as before.
                try json.beginObject();
                try json.objectField("index");
                try json.write(index);
                try json.objectField("name");
                try json.write(field.name.text(program.source));
                try json.objectField("type");
                try json.write(field.value_type);
                try json.objectField("span");
                try json.write(field.name);
                if (field.is_var) {
                    try json.objectField("var");
                    try json.write(true);
                }
                if (field.hidden) {
                    try json.objectField("hidden");
                    try json.write(true);
                }
                // A live-only field (RFC-0084, P4.2) says so; no other field does.
                if (field.live_only) {
                    try json.objectField("live_only");
                    try json.write(true);
                }
                // RFC-0087, P5.2: the constant of a persistable field's default.
                if (field.constant) |constant| {
                    try json.objectField("constant");
                    try json.write(constant);
                }
                try json.endObject();
            } else if (field.is_var) try json.write(.{ .index = index, .name = field.name.text(program.source), .type = field.value_type, .span = field.name, .@"var" = true }) else try json.write(.{ .index = index, .name = field.name.text(program.source), .type = field.value_type, .span = field.name });
        }
        try json.endArray();
        try json.objectField("member_pool");
        try json.write(program.members);
        if (persistables) {
            // RFC-0087, P5.2: the field constants, each a type and a literal, and the members
            // of those that are aggregates.
            try json.objectField("constants");
            try json.beginArray();
            for (program.constants, 0..) |constant, index| {
                try json.beginObject();
                try json.objectField("index");
                try json.write(index);
                try json.objectField("type");
                try json.write(constant.value_type);
                switch (constant.kind) {
                    .integer => |value| {
                        try json.objectField("integer");
                        try json.write(value);
                    },
                    .boolean => |value| {
                        try json.objectField("boolean");
                        try json.write(value);
                    },
                    .floating => |value| {
                        try json.objectField("floating");
                        try json.write(types.FloatReport{ .value = value });
                    },
                    .string => |span| {
                        try json.objectField("string");
                        try json.write(span);
                    },
                    .enumeration => |case| {
                        try json.objectField("enumeration");
                        try json.write(case);
                    },
                    .character => |code| {
                        try json.objectField("character");
                        try json.write(code);
                    },
                    .aggregate => |span| {
                        try json.objectField("aggregate");
                        try json.write(span);
                    },
                }
                try json.endObject();
            }
            try json.endArray();
            try json.objectField("constant_members");
            try json.write(program.constant_members);
        }
        if (tuples) {
            try json.objectField("tuple_elements");
            try json.write(program.tuple_elements);
        }
        if (enums) {
            try json.objectField("cases");
            try json.beginArray();
            for (program.cases, 0..) |case, index| try json.write(.{ .index = index, .name = case.text(program.source), .span = case });
            try json.endArray();
        }
    }
    if (program.slots.len != 0) {
        try json.objectField("methods");
        try json.beginArray();
        for (program.slots, 0..) |slot, index| try json.write(.{ .slot = index, .name = slot.name.text(program.source), .owner = slot.owner, .type = slot.callable, .span = slot.name });
        try json.endArray();
        try json.objectField("dispatch");
        try json.beginArray();
        for (program.dispatch) |entry| try json.write(.{ .class = entry.class, .slot = entry.slot, .function = entry.function });
        try json.endArray();
    }
    if (program.source_ops != 0) {
        try json.objectField("source_operation_count");
        try json.write(program.source_ops);
        try json.objectField("source_cells");
        try json.beginArray();
        for (program.source_cells, 0..) |cell, index| {
            // A live-only cell (RFC-0084) says so; every other cell prints as it did.
            if (cell.live_only) {
                try json.beginObject();
                try json.objectField("index");
                try json.write(index);
                try json.objectField("name");
                try json.write(cell.name.text(program.source));
                try json.objectField("type");
                try json.write(cell.value_type);
                try json.objectField("initial");
                try json.write(cell.initial);
                try json.objectField("public");
                try json.write(cell.is_public);
                try json.objectField("span");
                try json.write(cell.name);
                if (bundled) {
                    try json.objectField("module");
                    try json.write(modules.owner(cell.name, program.modules).?);
                }
                try json.objectField("live_only");
                try json.write(true);
                try json.endObject();
            } else if (cell.keyed != .none) {
                // RFC-0087, P5.4: a keyed cell says what it is.
                try json.beginObject();
                try json.objectField("index");
                try json.write(index);
                try json.objectField("name");
                try json.write(cell.name.text(program.source));
                try json.objectField("type");
                try json.write(cell.value_type);
                try json.objectField("initial");
                try json.write(cell.initial);
                try json.objectField("public");
                try json.write(cell.is_public);
                try json.objectField("span");
                try json.write(cell.name);
                if (bundled) {
                    try json.objectField("module");
                    try json.write(modules.owner(cell.name, program.modules).?);
                }
                try json.objectField("keyed");
                try json.write(cell.keyed);
                // RFC-0087, P5.5 (S2): and a persistent cell the name its entries are stored under,
                // worked out from the program's files and modules.
                if (cell.keyed == .persistent) {
                    const name = persist_json.storeName(persist_json.Catalogue.of(program), cell.name);
                    try json.objectField("store_name");
                    try json.beginWriteRaw();
                    try json.writer.writeByte('"');
                    for (name.slice()) |part| try std.json.Stringify.encodeJsonStringChars(part, .{}, json.writer);
                    try json.writer.writeByte('"');
                    json.endWriteRaw();
                }
                try json.endObject();
            } else if (bundled) try json.write(.{ .index = index, .name = cell.name.text(program.source), .type = cell.value_type, .initial = cell.initial, .public = cell.is_public, .span = cell.name, .module = modules.owner(cell.name, program.modules).? }) else try json.write(.{ .index = index, .name = cell.name.text(program.source), .type = cell.value_type, .initial = cell.initial, .public = cell.is_public, .span = cell.name });
        }
        try json.endArray();
    }
    if (program.functions.len != 0 or program.call_ops != 0) {
        try json.objectField("call_operation_count");
        try json.write(program.call_ops);
        try json.objectField("call_arguments");
        try json.write(program.call_arguments);
        try json.objectField("functions");
        try json.beginArray();
        for (program.functions, 0..) |f, index| {
            if (specialized) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .has_failure = f.has_failure, .decides = f.decides, .transacts = f.transacts, .source_ops = f.source_ops, .has_source = f.has_source, .has_local = f.has_local, .public = f.is_public, .anonymous = f.anonymous, .specialization = f.specialization, .generic_source = f.generic_source, .template_public = f.template_public }) else if (anonymous) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .has_failure = f.has_failure, .decides = f.decides, .transacts = f.transacts, .source_ops = f.source_ops, .has_source = f.has_source, .has_local = f.has_local, .public = f.is_public, .anonymous = f.anonymous }) else if (callables or local_state or iteration or recursion) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .has_failure = f.has_failure, .decides = f.decides, .transacts = f.transacts, .source_ops = f.source_ops, .has_source = f.has_source, .has_local = f.has_local, .public = f.is_public }) else if (frame_transacts) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .has_failure = f.has_failure, .decides = f.decides, .transacts = f.transacts, .source_ops = f.source_ops, .has_source = f.has_source, .public = f.is_public }) else if (frame_decides) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .has_failure = f.has_failure, .decides = f.decides, .public = f.is_public }) else if (frame_failure) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .has_failure = f.has_failure, .public = f.is_public }) else if (frame_control) try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .control_ops = f.control_ops, .has_control = f.has_control, .public = f.is_public }) else try json.write(.{ .index = index, .name = f.name.text(program.source), .span = f.name, .parameters = f.parameters[0..f.parameter_count], .result = f.value_type, .body = f.body, .root = f.root, .available_at = f.available_at, .member_work = f.member_work, .public = f.is_public });
        }
        try json.endArray();
        // Format 26: the effect set of each function, in the order of `functions`.
        if (effect_families) {
            try json.objectField("function_effects");
            try json.beginArray();
            for (program.functions) |f| {
                var names: EffectNames = undefined;
                try json.write(effectNames(f.effects(), &names));
            }
            try json.endArray();
        }
        // RFC-0084, P4.2: the block-clause functions of classes with live fields, and the class
        // each holds the clauses of; listed only by a program that has one.
        var clauses = false;
        for (program.functions) |f| clauses = clauses or f.clauses_of != null;
        if (clauses) {
            try json.objectField("function_clauses");
            try json.beginArray();
            for (program.functions, 0..) |f, index| if (f.clauses_of) |class| try json.write(.{ .function = index, .class = class });
            try json.endArray();
        }
        // RFC-0082, P3.6: the arms that may exit, and the type of their pending exits; listed
        // only by a program that has one.
        var exiting = false;
        for (program.functions) |f| exiting = exiting or f.exits != null;
        if (exiting) {
            try json.objectField("function_exits");
            try json.beginArray();
            for (program.functions, 0..) |f, index| if (f.exits) |exits| try json.write(.{ .function = index, .exits = exits });
            try json.endArray();
        }
        // RFC-0085, I7: the transparent functions, whose bodies P5 will hold to; listed only by
        // a program that has one.
        if (transparent) {
            try json.objectField("function_transparent");
            try json.beginArray();
            for (program.functions, 0..) |f, index| if (f.transparent) try json.write(index);
            try json.endArray();
        }
        // RFC-0085, I3: the nested functions, anonymous entries named by their declared names;
        // listed only by a program that has one.
        if (nested) {
            try json.objectField("function_nested");
            try json.beginArray();
            for (program.functions, 0..) |f, index| if (f.nested) try json.write(index);
            try json.endArray();
        }
        try json.objectField("captures");
        try json.beginArray();
        for (program.globals, 0..) |g, index| try json.write(.{ .index = index, .name = g.name.text(program.source), .span = g.name, .register = g.node, .type = g.value_type, .public = g.is_public });
        try json.endArray();
        try json.objectField("function_nodes");
        try json.beginArray();
        for (program.function_nodes, 0..) |entry, index| try json.write(.{ .index = index, .type = entry.node.value_type, .span = entry.node.span, .input = entry.input, .op = ReportOperation{ .operation = vm.instructionFromNode(entry.node).op } });
        try json.endArray();
        try json.objectField("function_members");
        try json.write(program.function_members);
        try json.objectField("function_arguments");
        try json.write(program.function_arguments);
    }
    try json.objectField("instructions");
    try json.beginArray();
    var register: usize = 0;
    for (program.code, 0..) |instruction, index| {
        const result: ?usize = if (instruction.value_type != null) register else null;
        if (bundled) {
            const namespace = modules.owner(instruction.span, program.modules).?;
            const base = program.modules[namespace].source.start;
            try json.write(.{ .index = index, .register = result, .type = instruction.value_type, .span = instruction.span, .module = namespace, .local_span = types.Span{ .start = instruction.span.start - base, .end = instruction.span.end - base }, .op = ReportOperation{ .operation = instruction.op } });
        } else try json.write(.{ .index = index, .register = result, .type = instruction.value_type, .span = instruction.span, .op = ReportOperation{ .operation = instruction.op } });
        register += @intFromBool(result != null);
    }
    try json.endArray();
    std.debug.assert(register == registers);
    try json.objectField("bindings");
    try json.beginArray();
    for (program.bindings) |binding| {
        try json.write(.{ .name = binding.name.text(program.source), .type = binding.value_type, .public = binding.is_public, .register = binding.node, .span = binding.name });
    }
    try json.endArray();
    try json.endObject();
    try out.writeByte('\n');
}

fn hasEnums(definitions: []const types.Definition) bool {
    for (definitions) |definition| if (definition == .enumeration) return true;
    return false;
}

fn hasTuples(definitions: []const types.Definition) bool {
    for (definitions) |definition| if (definition == .tuple) return true;
    return false;
}

/// RFC-0087, P5.4: whether an operation is of a keyed cell or makes the session.
fn keyedOperation(op: @FieldType(vm.Instruction, "op")) bool {
    return switch (op) {
        .weak_init, .weak_get, .weak_set => true,
        .grant => |g| g.kind == .session,
        else => false,
    };
}

const ReportOperation = struct {
    operation: @FieldType(vm.Instruction, "op"),

    pub fn jsonStringify(self: ReportOperation, json: *std.json.Stringify) std.Io.Writer.Error!void {
        // RFC-0087, P5.4: the session's grant has no name.
        if (self.operation == .grant and self.operation.grant.kind == .session) return json.write(.{ .grant = .{ .kind = types.GrantKind.session } });
        if (self.operation != .floating) return json.write(self.operation);
        try json.beginObject();
        try json.objectField("floating");
        try json.write(types.FloatReport{ .value = self.operation.floating });
        try json.endObject();
    }
};

test "inspection exposes checked mapping and escaped pool without executing arithmetic" {
    const compiler = try scratch.storage(@import("compiler.zig").Workspace);
    defer scratch.release(compiler);
    scratch.initialise(compiler);
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    const source = "Keep(X:i64)<computes>:i64=7;Answer<public>:i64=Keep(1/0);Alias:i64=Answer;Text:string=\"雪\\n\\\"\\\\\"";
    const ir = compiler.compile(source).ok;
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, ir));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const instructions = object.get("instructions").?.array.items;
    try std.testing.expectEqual(@as(i64, 5), object.get("instruction_count").?.integer);
    try std.testing.expectEqual(@as(i64, 5), object.get("register_count").?.integer);
    try std.testing.expectEqual(@as(usize, 5), instructions.len);
    try std.testing.expectEqualStrings("divide", instructions[2].object.get("op").?.object.get("binary").?.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 3), instructions[3].object.get("register").?.integer);
    const bindings = object.get("bindings").?.array.items;
    try std.testing.expectEqual(@as(i64, 3), bindings[0].object.get("register").?.integer);
    try std.testing.expect(bindings[0].object.get("public").?.bool);
    try std.testing.expectEqual(@as(i64, 3), bindings[1].object.get("register").?.integer);
    try std.testing.expectEqualStrings("雪\n\"\\", object.get("string_pool").?.string);
    try std.testing.expectEqual(@as(i64, 6), object.get("string_bytes").?.integer);
}

test "inspection rejects malformed tails and names before any output" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const nodes = [_]types.Node{
        .{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .integer = 1 } },
        .{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .negate = 9 } },
    };
    const invalid: types.Program = .{ .source = "雪", .strings = "", .nodes = &nodes, .bindings = &.{} };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, invalid)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const bad_name: types.Binding = .{ .name = .{ .start = 1, .end = 2 }, .value_type = .i64, .node = 0, .is_public = false };
    var named = invalid;
    named.nodes = nodes[0..1];
    named.bindings = &.{bad_name};
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, named)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    named.strings = "\xff";
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, named)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "inspection handles empty programs, reuse and writer exhaustion" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    var buffer: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const empty: types.Program = .{ .source = "", .strings = "", .nodes = &.{}, .bindings = &.{} };
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, empty));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("register_count").?.integer);
    out = std.Io.Writer.fixed(buffer[0..8]);
    try std.testing.expectError(error.WriteFailed, workspace.write(&out, empty));
}

test "expanded literals share one emitted string pool" {
    const compiler = try scratch.storage(@import("compiler.zig").Workspace);
    defer scratch.release(compiler);
    scratch.initialise(compiler);
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    var source_buffer: [8192]u8 = undefined;
    var source = std.Io.Writer.fixed(&source_buffer);
    try source.writeAll("Label()<computes>:string=\"");
    for (0..350) |_| try source.writeAll("0123456789");
    try source.writeAll("\";\n");
    for (0..128) |index| try source.print("Text{d}:string=Label();\n", .{index});
    const ir = compiler.compile(source.buffered()).ok;
    try std.testing.expectEqual(@as(usize, 3500), ir.strings.len);
    var output_buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&output_buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, ir));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3500), parsed.value.object.get("string_pool").?.string.len);
    const instructions = parsed.value.object.get("instructions").?.array.items;
    try std.testing.expectEqual(@as(usize, 128), instructions.len);
    for (instructions) |instruction| try std.testing.expectEqual(@as(i64, 0), instruction.object.get("op").?.object.get("call").?.object.get("function").?.integer);
    const body = parsed.value.object.get("function_nodes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    for (body) |instruction| {
        const span = instruction.object.get("op").?.object.get("string").?.object;
        try std.testing.expectEqual(@as(i64, 0), span.get("start").?.integer);
        try std.testing.expectEqual(@as(i64, 3500), span.get("end").?.integer);
    }
}

fn aggregateInspectionFixture() types.Program {
    return .{
        .source = "Pair Left Right A",
        .strings = "雪",
        .definitions = &.{.{ .record = .{ .name = .{ .start = 0, .end = 4 }, .fields = .{ .start = 0, .end = 2 }, .is_public = true } }},
        .fields = &.{
            .{ .name = .{ .start = 5, .end = 9 }, .value_type = .i64 },
            .{ .name = .{ .start = 10, .end = 15 }, .value_type = .string },
        },
        .nodes = &.{
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = .i64, .kind = .{ .integer = 7 } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = .string, .kind = .{ .string = .{ .start = 0, .end = 3 } } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = @fromBackingInt(@intCast(4)), .kind = .{ .aggregate = .{ .start = 0, .end = 2 } } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = .string, .kind = .{ .field = .{ .value = 2, .index = 1 } } },
        },
        .members = &.{ 0, 1 },
        .bindings = &.{.{ .name = .{ .start = 16, .end = 17 }, .node = 2, .value_type = @fromBackingInt(@intCast(4)), .is_public = true }},
    };
}

test "aggregate inspection format two emits type fields and members once" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, aggregateInspectionFixture()));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 2), object.get("format").?.integer);
    try std.testing.expect(object.get("cases") == null);
    const definitions = object.get("type_definitions").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    try std.testing.expectEqual(@as(i64, 4), definitions[0].object.get("id").?.integer);
    try std.testing.expectEqualStrings("Pair", definitions[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("record", definitions[0].object.get("kind").?.string);
    const fields = object.get("fields").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("Right", fields[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("string", fields[1].object.get("type").?.string);
    const members = object.get("member_pool").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqual(@as(i64, 1), members[1].integer);
    const instructions = object.get("instructions").?.array.items;
    try std.testing.expectEqual(@as(i64, 4), instructions[2].object.get("type").?.integer);
    try std.testing.expectEqual(@as(i64, 2), instructions[2].object.get("op").?.object.get("aggregate").?.object.get("end").?.integer);
    try std.testing.expectEqualStrings("雪", object.get("string_pool").?.string);
    out = std.Io.Writer.fixed(&buffer);
    const scalar: types.Program = .{ .source = "", .strings = "", .nodes = &.{}, .bindings = &.{} };
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, scalar));
    const legacy = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer legacy.deinit();
    try std.testing.expectEqual(@as(i64, 1), legacy.value.object.get("format").?.integer);
    try std.testing.expect(legacy.value.object.get("type_definitions") == null);
    try std.testing.expect(legacy.value.object.get("member_pool") == null);
    try std.testing.expect(legacy.value.object.get("cases") == null);
}

test "inspection exact byte budget and malformed aggregate tails precede writing" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const original = aggregateInspectionFixture();
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, original));
    const bytes = out.end;
    out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.writeBounded(&out, original, .{ .output_bytes = bytes }));
    out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try workspace.writeBounded(&out, original, .{ .output_bytes = bytes - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    var malformed = original;
    malformed.members = &.{ 0, 1, 999 };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, malformed)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const broken = [_]types.Field{
        .{ .name = .{ .start = 5, .end = 9 }, .value_type = @fromBackingInt(@intCast(999)) },
        original.fields[1],
    };
    malformed = original;
    malformed.fields = &broken;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, malformed)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

fn enumInspectionFixture() types.Program {
    const mode: types.Type = @fromBackingInt(@as(u16, 4));
    const modes: types.Type = @fromBackingInt(@as(u16, 6));
    return .{
        .source = "mode Light Dark Empty A H",
        .strings = "雪\n",
        .definitions = &.{
            .{ .enumeration = .{ .name = .{ .start = 0, .end = 4 }, .cases = .{ .start = 0, .end = 2 }, .is_public = true } },
            .{ .enumeration = .{ .name = .{ .start = 16, .end = 21 }, .cases = .{ .start = 2, .end = 2 }, .is_public = false } },
            .{ .array = mode },
        },
        .cases = &.{ .{ .start = 5, .end = 10 }, .{ .start = 11, .end = 15 } },
        .nodes = &.{
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = mode, .kind = .{ .enumeration = 1 } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = mode, .kind = .{ .enumeration = 0 } },
            .{ .span = .{ .start = 0, .end = 0 }, .value_type = modes, .kind = .{ .aggregate = .{ .start = 0, .end = 3 } } },
        },
        .members = &.{ 0, 1, 0 },
        .bindings = &.{
            .{ .name = .{ .start = 22, .end = 23 }, .node = 2, .value_type = modes, .is_public = true },
            .{ .name = .{ .start = 24, .end = 25 }, .node = 0, .value_type = mode, .is_public = false },
        },
    };
}

test "enum inspection format three emits case catalogue once and typed local literals" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, enumInspectionFixture()));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.buffered(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 3), object.get("format").?.integer);
    try std.testing.expectEqualStrings("雪\n", object.get("string_pool").?.string);
    const definitions = object.get("type_definitions").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), definitions.len);
    try std.testing.expectEqualStrings("enumeration", definitions[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("mode", definitions[0].object.get("name").?.string);
    try std.testing.expect(definitions[0].object.get("public").?.bool);
    try std.testing.expectEqual(@as(i64, 2), definitions[0].object.get("cases").?.object.get("end").?.integer);
    try std.testing.expectEqualStrings("Empty", definitions[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), definitions[1].object.get("cases").?.object.get("start").?.integer);
    const cases = object.get("cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), cases.len);
    try std.testing.expectEqual(@as(i64, 1), cases[1].object.get("index").?.integer);
    try std.testing.expectEqualStrings("Dark", cases[1].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 11), cases[1].object.get("span").?.object.get("start").?.integer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.buffered(), "\"Dark\""));
    const instructions = object.get("instructions").?.array.items;
    try std.testing.expectEqual(@as(i64, 4), instructions[0].object.get("type").?.integer);
    try std.testing.expectEqual(@as(i64, 1), instructions[0].object.get("op").?.object.get("enumeration").?.integer);
    try std.testing.expectEqual(@as(i64, 0), instructions[1].object.get("op").?.object.get("enumeration").?.integer);
    try std.testing.expectEqual(@as(usize, 3), object.get("member_pool").?.array.items.len);
    // Merely declaring an uninhabited enum requires format three too.
    const empty: types.Program = .{ .source = "Empty", .strings = "", .nodes = &.{}, .bindings = &.{}, .definitions = &.{.{ .enumeration = .{ .name = .{ .start = 0, .end = 5 }, .cases = .{ .start = 0, .end = 0 }, .is_public = false } }} };
    out = .fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, empty));
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "{\"format\":3,"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"cases\":[]") != null);
}

test "enum inspection exact budget and malformed unused case or literal tails precede output" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    const original = enumInspectionFixture();
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, original));
    const bytes = out.end;
    out = .fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.writeBounded(&out, original, .{ .output_bytes = bytes }));
    out = .fixed(&buffer);
    try std.testing.expectEqual(types.Diagnostic.Code.report_limit, (try workspace.writeBounded(&out, original, .{ .output_bytes = bytes - 1 })).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    var malformed = original;
    malformed.cases = &.{ original.cases[0], original.cases[1], original.cases[0] };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, malformed)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    malformed = original;
    malformed.cases = &.{ original.cases[0], .{ .start = 11, .end = 65535 } };
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, malformed)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    var definitions: [3]types.Definition = undefined;
    @memcpy(&definitions, original.definitions);
    definitions[1].enumeration.name = .{ .start = 21, .end = 20 };
    malformed = original;
    malformed.definitions = &definitions;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, malformed)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    const tail: types.Node = .{ .span = .{ .start = 0, .end = 0 }, .value_type = @fromBackingInt(@as(u16, 4)), .kind = .{ .enumeration = std.math.maxInt(u32) } };
    const nodes = [_]types.Node{ original.nodes[0], original.nodes[1], original.nodes[2], tail };
    malformed = original;
    malformed.nodes = &nodes;
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_bytecode, (try workspace.write(&out, malformed)).failed.code);
    try std.testing.expectEqual(@as(usize, 0), out.end);
    out = .fixed(buffer[0..8]);
    try std.testing.expectError(error.WriteFailed, workspace.write(&out, original));
    out = .fixed(&buffer);
    try std.testing.expectEqual(Result.ok, try workspace.write(&out, original));
}

/// The effects of a set by name, in the order the Book lists its families (RFC-0078).
const EffectNames = [7][]const u8;
fn effectNames(set: types.EffectSet, names: *EffectNames) []const []const u8 {
    var count: usize = 0;
    for ([_]struct { bool, []const u8 }{
        .{ set.reads, "reads" },
        .{ set.writes, "writes" },
        .{ set.allocates, "allocates" },
        .{ set.decides, "decides" },
        .{ set.suspends, "suspends" },
        .{ !set.diverges, "converges" },
        // RFC-0085, I12: format 31.
        .{ !set.dictates, "predicts" },
    }) |entry| if (entry[0]) {
        names[count] = entry[1];
        count += 1;
    };
    return names[0..count];
}
