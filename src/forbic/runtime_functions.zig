//! Compiler-owned published computes bodies. No runtime dispatch or admission.
const std = @import("std");
const types = @import("types.zig");
const templates = @import("functions.zig");
const catalogue = @import("aggregate_types.zig");
const name_index = @import("name_index.zig");
pub const Error = error{ FunctionLimit, NodeLimit, MemberLimit, ArgumentLimit, GlobalLimit };
pub const Storage = struct {
    definitions: [types.limits.functions]types.RuntimeFunction = undefined,
    nodes: [types.limits.template_nodes]types.FunctionNode = undefined,
    members: [types.limits.aggregate_elements]u32 = undefined,
    arguments: [types.limits.call_arguments]u32 = undefined,
    globals: [types.limits.bindings]types.Binding = undefined,
    count: u32 = 0,
    node_count: u32 = 0,
    member_count: u32 = 0,
    argument_count: u32 = 0,
    global_count: u32 = 0,
    /// The captured globals by where their name is written (`name_index.Table`): a body that
    /// reads a global asks this, where reading every captured global cost their square.
    global_table: name_index.Table = .{},
    global_slots: [name_index.slotCount(types.limits.bindings).?]u32 = undefined,
    /// RFC-0091 (B3): calls of a module function declared after the code that calls them. Until
    /// that function is published such a call names `forward_base + k`, where `k` is its entry
    /// here; `resolve` gives the entry the published ID, and `finish` rewrites every call that
    /// still names an entry. One entry stands for one declaration, found by its name's span.
    forward: [types.limits.functions]Forward = undefined,
    forward_count: u32 = 0,
    forward_table: name_index.Table = .{},
    forward_slots: [name_index.slotCount(types.limits.functions).?]u32 = undefined,

    pub fn reset(self: *Storage) void {
        self.count = 0;
        self.node_count = 0;
        self.member_count = 0;
        self.argument_count = 0;
        self.global_count = 0;
        self.global_table.clear();
        self.forward_count = 0;
        self.forward_table.clear();
    }
    fn capture(self: *Storage, binding: types.Binding) Error!u32 {
        const hash = name_index.hashSpan(binding.name.start, binding.name.end);
        var same = self.global_table.walk(&self.global_slots, hash);
        while (same.next()) |index| if (std.meta.eql(self.globals[index].name, binding.name)) return index;
        // Debug builds read every captured global too: none of them has this name.
        if (@import("builtin").mode == .debug) for (self.globals[0..self.global_count]) |global| std.debug.assert(!std.meta.eql(global.name, binding.name));
        if (self.global_count == self.globals.len) return error.GlobalLimit;
        const index = self.global_count;
        if (self.global_table.crowded()) {
            self.global_table.grow(&self.global_slots);
            for (self.globals[0..index], 0..) |global, earlier| self.global_table.enter(&self.global_slots, name_index.hashSpan(global.name.start, global.name.end), @intCast(earlier));
        }
        self.globals[index] = binding;
        self.global_table.enter(&self.global_slots, hash, index);
        self.global_count += 1;
        return index;
    }
    /// Ineligible/alias bodies remain compiler templates. Body parameters and
    /// captures never become fake scalar operations in the published catalogue.
    pub fn publish(self: *Storage, function: templates.Definition, source: *const templates.Storage, definitions: []const types.Definition, bindings: []const types.Binding, binding_cells: []const u16, available_at: u32) Error!?u32 {
        return self.publishBody(function, source, definitions, bindings, binding_cells, available_at, false);
    }
    pub fn publishAlias(self: *Storage, function: templates.Definition, source: *const templates.Storage, definitions: []const types.Definition, bindings: []const types.Binding, binding_cells: []const u16, available_at: u32) Error!?u32 {
        return self.publishBody(function, source, definitions, bindings, binding_cells, available_at, true);
    }
    fn publishBody(self: *Storage, function: templates.Definition, source: *const templates.Storage, definitions: []const types.Definition, bindings: []const types.Binding, binding_cells: []const u16, available_at: u32, force_alias: bool) Error!?u32 {
        const body = source.nodes[function.start..function.end];
        var parameter_alias = true;
        for (body) |entry| if (entry.input != .parameter) {
            parameter_alias = false;
        };
        if (parameter_alias and !force_alias) return null;
        for (body) |entry| if (entry.input == .operation and entry.node.kind == .cell_init) return null;
        if (self.count == self.definitions.len) return error.FunctionLimit;
        if (body.len > self.nodes.len - self.node_count) return error.NodeLimit;
        const id = self.count;
        var definition: types.RuntimeFunction = .{
            .name = function.name,
            .parameter_count = function.parameter_count,
            .value_type = function.value_type,
            .body = .{ .start = self.node_count, .end = self.node_count + @as(u32, @intCast(body.len)) },
            .root = function.root - function.start,
            .available_at = available_at,
            .member_work = 0,
            .is_public = function.is_public,
            .anonymous = function.anonymous,
            .specialization = function.specialization,
            .generic_source = function.generic_source,
            .template_public = function.template_public,
            .decides = function.decides,
            .transacts = function.transacts,
            .detail = function.detail,
            .transparent = function.is_transparent,
        };
        for (function.parameters[0..function.parameter_count], definition.parameters[0..function.parameter_count]) |parameter, *value_type| value_type.* = parameter.value_type;
        var recursive = false;
        for (body) |original| {
            var entry = original;
            switch (entry.input) {
                .parameter => {},
                .global => |binding| {
                    std.debug.assert(binding < bindings.len and binding_cells[binding] == std.math.maxInt(u16));
                    entry.input = .{ .global = try self.capture(bindings[binding]) };
                },
                .operation => {
                    remap(&entry.node, function.start);
                    if (types.controlOp(original.node)) {
                        definition.control_ops += 1;
                        definition.has_control = true;
                    }
                    if (original.node.kind == .local_set) definition.has_local = true;
                    if (original.node.kind == .demand or original.node.kind == .fail) definition.has_failure = true;
                    if (types.sourceOp(original.node)) {
                        definition.source_ops += 1;
                        definition.has_source = true;
                    }
                    switch (original.node.kind) {
                        .aggregate => |range| {
                            const count = range.end - range.start;
                            if (count > self.members.len - self.member_count) return error.MemberLimit;
                            entry.node.kind.aggregate = .{ .start = self.member_count, .end = self.member_count + count };
                            for (source.members[range.start..range.end]) |operand| {
                                self.members[self.member_count] = operand - function.start;
                                self.member_count += 1;
                            }
                            definition.member_work = @min(types.limits.aggregate_elements + 1, definition.member_work + count);
                        },
                        .array_concat, .array_set, .map_set, .map_remove => definition.member_work = types.limits.aggregate_elements + 1,
                        // A task builds what its body builds, and a settled one its result's option.
                        .spawn => definition.member_work = types.limits.aggregate_elements + 1,
                        // So does a branch (RFC-0082, P3.4).
                        .branch => definition.member_work = types.limits.aggregate_elements + 1,
                        // A guard and the propagation after it build what they build (RFC-0084).
                        // The guard runs from the live machinery and may fail inside a region of
                        // its own, so the function has failure traces (RFC-0085, I14-D11).
                        .cell_live, .object_live => {
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                        },
                        // A reaction builds its handle, and its guard and body what they build (P4.4).
                        .reaction => {
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                        },
                        // A batch calls its body, as an `invoke` does (P4.5): its regions journal
                        // what the body writes, and it builds what the body builds.
                        .batch => |operand| {
                            const shape = catalogue.definition(source.nodes[operand].node.value_type, definitions).?.callable;
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                            definition.has_source = definition.has_source or shape.transacts;
                            definition.has_local = definition.has_local or shape.transacts;
                        },
                        // The guard of an `Await` builds what it builds (P4.6).
                        .await_guard => {
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                        },
                        // So do arms (RFC-0082, P3.3), which lie in the argument pool like a
                        // call's arguments; a `Sync` builds the tuple of their results too.
                        .structured => |s| {
                            definition.member_work = types.limits.aggregate_elements + 1;
                            const count = s.arms.end - s.arms.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind = .{ .structured = .{ .kind = s.kind, .arms = .{ .start = self.argument_count, .end = self.argument_count + count } } };
                            for (source.arguments[s.arms.start..s.arms.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                        },
                        .native_call => {
                            // An array or option result appends a run-dependent number of members.
                            if (@backingInt(original.node.value_type) >= 4) definition.member_work = types.limits.aggregate_elements + 1;
                        },
                        // RFC-0086, P2.3: so does a `grant`, whose option has a member or none.
                        .grant => definition.member_work = types.limits.aggregate_elements + 1,
                        // RFC-0087, P5.4: a keyed cell's update builds its map, as `map_set` does,
                        // and a live program's propagation what it builds.
                        .weak_set => definition.member_work = types.limits.aggregate_elements + 1,
                        // RFC-0087, P5.3: and a decode, which builds what its text holds.
                        .json_decode => definition.member_work = types.limits.aggregate_elements + 1,
                        .iterate => |iteration| {
                            std.debug.assert(iteration.function < self.count);
                            const step = self.definitions[iteration.function];
                            if (step.member_work != 0) definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = definition.has_failure or step.has_failure;
                            definition.has_source = definition.has_source or step.has_source;
                            definition.has_local = definition.has_local or step.has_local;
                        },
                        .loop => |transition| {
                            const shape = catalogue.definition(source.nodes[transition.callable].node.value_type, definitions).?.callable;
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                            definition.has_source = definition.has_source or shape.transacts;
                            definition.has_local = definition.has_local or shape.transacts;
                        },
                        .iterate_value => |iteration| {
                            const shape = catalogue.definition(source.nodes[iteration.callable].node.value_type, definitions).?.callable;
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                            definition.has_source = definition.has_source or shape.transacts;
                            definition.has_local = definition.has_local or shape.transacts;
                        },
                        .bind => |binding| {
                            const count = binding.arguments.end - binding.arguments.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind = .{ .bind = .{ .callable = binding.callable - function.start, .arguments = .{ .start = self.argument_count, .end = self.argument_count + count } } };
                            for (source.arguments[binding.arguments.start..binding.arguments.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                            definition.member_work = @min(types.limits.aggregate_elements + 1, definition.member_work + types.limits.parameters);
                        },
                        // P3.9: the callbacks of a subscribable event's `Signal`, `<transacts>`
                        // functions called as an `invoke` calls its callable.
                        .event_notify => |n| {
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                            definition.has_local = true;
                            const count = n.arguments.end - n.arguments.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind = .{ .event_notify = .{ .callable = n.callable - function.start, .arguments = .{ .start = self.argument_count, .end = self.argument_count + count } } };
                            for (source.arguments[n.arguments.start..n.arguments.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                        },
                        .invoke => |invocation| {
                            const shape = catalogue.definition(source.nodes[invocation.callable].node.value_type, definitions).?.callable;
                            definition.member_work = types.limits.aggregate_elements + 1;
                            definition.has_failure = true;
                            definition.has_source = definition.has_source or shape.transacts;
                            definition.has_local = definition.has_local or shape.transacts;
                            const count = invocation.arguments.end - invocation.arguments.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind = .{ .invoke = .{ .callable = invocation.callable - function.start, .arguments = .{ .start = self.argument_count, .end = self.argument_count + count } } };
                            for (source.arguments[invocation.arguments.start..invocation.arguments.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                        },
                        .recur => |range| {
                            recursive = true;
                            const count = range.end - range.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind = .{ .recur = .{ .start = self.argument_count, .end = self.argument_count + count } };
                            for (source.arguments[range.start..range.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                        },
                        .object_new => |c| {
                            const count = c.arguments.end - c.arguments.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind.object_new.arguments = .{ .start = self.argument_count, .end = self.argument_count + count };
                            for (source.arguments[c.arguments.start..c.arguments.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                        },
                        .call => |call| {
                            std.debug.assert(call.function < self.count or self.forwardEntry(call.function) != null);
                            const count = call.arguments.end - call.arguments.start;
                            if (count > self.arguments.len - self.argument_count) return error.ArgumentLimit;
                            entry.node.kind.call.arguments = .{ .start = self.argument_count, .end = self.argument_count + count };
                            for (source.arguments[call.arguments.start..call.arguments.end]) |operand| {
                                self.arguments[self.argument_count] = operand - function.start;
                                self.argument_count += 1;
                            }
                            // RFC-0091: a call copied from a template after the function it
                            // names was published names that function, earlier than this one.
                            var target = call.function;
                            if (self.forwardEntry(target)) |pending| if (self.forward[pending].resolved) |published| {
                                target = published;
                                entry.node.kind.call.function = published;
                            };
                            if (self.forwardEntry(target)) |pending| {
                                // What a function declared later does is not known here, so
                                // the call counts as an `invoke` of its signature does.
                                const callee = self.forward[pending].definition;
                                definition.member_work = types.limits.aggregate_elements + 1;
                                definition.has_control = true;
                                definition.has_failure = true;
                                definition.has_source = definition.has_source or callee.transacts;
                                definition.has_local = definition.has_local or callee.transacts;
                            } else {
                                definition.member_work = @min(types.limits.aggregate_elements + 1, definition.member_work + self.definitions[target].member_work);
                                definition.has_control = definition.has_control or self.definitions[target].has_control;
                                definition.has_failure = definition.has_failure or self.definitions[target].has_failure;
                                definition.has_source = definition.has_source or self.definitions[target].has_source;
                                definition.has_local = definition.has_local or self.definitions[target].has_local;
                            }
                        },
                        else => {},
                    }
                },
            }
            self.nodes[self.node_count] = entry;
            self.node_count += 1;
        }
        if (recursive and definition.member_work != 0) definition.member_work = types.limits.aggregate_elements + 1;
        self.definitions[id] = definition;
        self.count += 1;
        return id;
    }

    /// The entry a call target names, if it is one of `forward`'s placeholders.
    pub fn forwardEntry(self: *const Storage, function: u32) ?u32 {
        if (function < forward_base) return null;
        const entry = function - forward_base;
        std.debug.assert(entry < self.forward_count);
        return entry;
    }

    /// The signature of the function a call names: published, or declared further down.
    pub fn signature(self: *const Storage, function: u32) types.RuntimeFunction {
        const entry = self.forwardEntry(function) orelse return self.definitions[function];
        const d = self.forward[entry].definition;
        var result: types.RuntimeFunction = .{ .name = d.name, .parameter_count = d.parameter_count, .value_type = d.value_type, .body = .{ .start = 0, .end = 0 }, .root = 0, .available_at = self.forward[entry].available_at, .member_work = types.limits.aggregate_elements + 1, .has_control = true, .has_failure = true, .decides = d.decides, .transacts = d.transacts, .detail = d.detail, .is_public = d.is_public };
        for (d.parameters[0..d.parameter_count], result.parameters[0..d.parameter_count]) |parameter, *value_type| value_type.* = parameter.value_type;
        return result;
    }

    /// The entry of the declaration named at `name`, made on its first call.
    pub fn findForward(self: *const Storage, name: types.Span) ?u32 {
        var same = self.forward_table.walk(&self.forward_slots, name_index.hashSpan(name.start, name.end));
        while (same.next()) |index| if (std.meta.eql(self.forward[index].definition.name, name)) return index;
        return null;
    }

    /// A new entry for the declaration `signature`, first called at `call` where the module
    /// had emitted `available_at` nodes.
    pub fn addForward(self: *Storage, signature_: templates.Definition, has_default: [types.limits.parameters]bool, call: types.Span, available_at: u32) Error!u32 {
        std.debug.assert(self.findForward(signature_.name) == null);
        if (self.forward_count == self.forward.len) return error.FunctionLimit;
        const index = self.forward_count;
        if (self.forward_table.crowded()) {
            self.forward_table.grow(&self.forward_slots);
            for (self.forward[0..index], 0..) |entry, earlier| self.forward_table.enter(&self.forward_slots, name_index.hashSpan(entry.definition.name.start, entry.definition.name.end), @intCast(earlier));
        }
        self.forward[index] = .{ .definition = signature_, .has_default = has_default, .call = call, .available_at = available_at, .last_call = call.start };
        self.forward_table.enter(&self.forward_slots, name_index.hashSpan(signature_.name.start, signature_.name.end), index);
        self.forward_count += 1;
        return index;
    }

    /// Rewrites every call of a placeholder in `nodes` with the function its entry was given.
    /// Returns the first call of an entry that was never published: what its header promised
    /// was not declared after all.
    pub fn finish(self: *const Storage, nodes: []types.FunctionNode) ?types.Span {
        if (self.forward_count == 0) return null;
        for (nodes) |*entry| if (entry.input == .operation and entry.node.kind == .call) {
            const index = self.forwardEntry(entry.node.kind.call.function) orelse continue;
            const target = self.forward[index].resolved orelse return self.forward[index].call;
            entry.node.kind.call.function = target;
        };
        return null;
    }

    /// The same for the module's own nodes. A root call names an earlier function, so none
    /// should hold a placeholder; one copied there from a template still names its function.
    pub fn finishRoot(self: *const Storage, nodes: []types.Node) ?types.Span {
        if (self.forward_count == 0) return null;
        for (nodes) |*node| if (node.kind == .call) {
            const index = self.forwardEntry(node.kind.call.function) orelse continue;
            const target = self.forward[index].resolved orelse return self.forward[index].call;
            node.kind.call.function = target;
        };
        return null;
    }
};

/// RFC-0091: the first placeholder. No program has this many functions.
pub const forward_base: u32 = std.math.maxInt(u32) - types.limits.functions;

pub const Forward = struct {
    /// The signature read from the declaration's header where it was first called.
    definition: templates.Definition,
    has_default: [types.limits.parameters]bool,
    /// The first call, for diagnostics.
    call: types.Span,
    /// The nodes the module had emitted at that call: the function must be published with
    /// the same availability, so that no module value lies between the two.
    available_at: u32,
    resolved: ?u32 = null,
    /// Where the latest call is written. A body that called the declaration may not declare
    /// a local or nested function of its name after that call (c3-1): the name would mean both.
    last_call: u32 = 0,
};

fn remap(node: *types.Node, start: u32) void {
    switch (node.kind) {
        .negate, .float_negate, .int_to_float, .string_length, .to_string, .logic_not, .array_length, .option_present, .option_value, .demand, .fail, .exit, .err, .local_set, .upcast, .downcast, .spawn, .sleep, .refine, .task_await, .event_await, .branch, .arm_exit, .task_cancel, .await_guard => |operand| {
            const mapped = operand - start;
            node.kind = switch (node.kind) {
                .negate => .{ .negate = mapped },
                .float_negate => .{ .float_negate = mapped },
                .int_to_float => .{ .int_to_float = mapped },
                .string_length => .{ .string_length = mapped },
                .to_string => .{ .to_string = mapped },
                .logic_not => .{ .logic_not = mapped },
                .array_length => .{ .array_length = mapped },
                .option_present => .{ .option_present = mapped },
                .option_value => .{ .option_value = mapped },
                .demand => .{ .demand = mapped },
                .fail => .{ .fail = mapped },
                .exit => .{ .exit = mapped },
                .arm_exit => .{ .arm_exit = mapped },
                .err => .{ .err = mapped },
                .local_set => .{ .local_set = mapped },
                .upcast => .{ .upcast = mapped },
                .downcast => .{ .downcast = mapped },
                .spawn => .{ .spawn = mapped },
                .sleep => .{ .sleep = mapped },
                .task_await => .{ .task_await = mapped },
                .event_await => .{ .event_await = mapped },
                .refine => .{ .refine = mapped },
                .branch => .{ .branch = mapped },
                .task_cancel => .{ .task_cancel = mapped },
                .await_guard => .{ .await_guard = mapped },
                else => unreachable,
            };
        },
        .binary, .float_binary => |b| {
            const mapped: types.Binary = .{ .op = b.op, .lhs = b.lhs - start, .rhs = b.rhs - start };
            node.kind = if (node.kind == .binary) .{ .binary = mapped } else .{ .float_binary = mapped };
        },
        .rational => |r| node.kind.rational = .{ .op = r.op, .lhs = r.lhs - start, .rhs = r.rhs - start },
        .compare => |b| node.kind.compare = .{ .op = b.op, .lhs = b.lhs - start, .rhs = b.rhs - start },
        .logic_binary => |b| node.kind.logic_binary = .{ .op = b.op, .lhs = b.lhs - start, .rhs = b.rhs - start },
        .field, .tuple_element => |a| {
            const mapped: types.FieldAccess = .{ .value = a.value - start, .index = a.index };
            node.kind = if (node.kind == .field) .{ .field = mapped } else .{ .tuple_element = mapped };
        },
        .option_or => |c| node.kind.option_or = .{ .option = c.option - start, .fallback = c.fallback - start },
        .map_lookup => |c| node.kind.map_lookup = .{ .map = c.map - start, .key = c.key - start },
        .map_remove => |c| node.kind.map_remove = .{ .map = c.map - start, .key = c.key - start },
        .string_concat => |c| node.kind.string_concat = .{ .lhs = c.lhs - start, .rhs = c.rhs - start },
        .text => |t| {
            var operands: [3]u32 = @splat(0);
            for (operands[0..t.op.arity()], 0..) |*operand, ordinal| operand.* = t.operand(ordinal) - start;
            node.kind = .{ .text = t.mapped(operands) };
        },
        .array_concat => |c| node.kind.array_concat = .{ .lhs = c.lhs - start, .rhs = c.rhs - start },
        .float_to_int => |c| node.kind.float_to_int = .{ .mode = c.mode, .operand = c.operand - start },
        .native_call => |c| {
            var mapped = c;
            for (mapped.args[0..mapped.count]) |*operand| operand.* -= start;
            node.kind = .{ .native_call = mapped };
        },
        .array_get => |c| node.kind.array_get = .{ .array = c.array - start, .index = c.index - start },
        .map_key => |c| node.kind.map_key = .{ .array = c.array - start, .index = c.index - start },
        .map_value => |c| node.kind.map_value = .{ .array = c.array - start, .index = c.index - start },
        .array_set => |c| node.kind.array_set = .{ .array = c.array - start, .index = c.index - start, .value = c.value - start },
        .map_set => |c| node.kind.map_set = .{ .map = c.map - start, .key = c.key - start, .value = c.value - start },
        .if_begin => |b| node.kind.if_begin = .{ .condition = b.condition - start, .alternative = b.alternative - start, .end = b.end - start },
        .attempt_begin => |b| node.kind.attempt_begin = .{ .condition = b.condition, .alternative = b.alternative - start, .end = b.end - start },
        .otherwise => |begin| node.kind.otherwise = begin - start,
        .merge => |m| node.kind.merge = .{ .begin = m.begin - start, .left = m.left - start, .right = m.right - start },
        .cell_write => |c| node.kind.cell_write = .{ .cell = c.cell, .value = c.value - start },
        .object_get => |a| node.kind.object_get = .{ .value = a.value - start, .index = a.index },
        .instance_of => |c| node.kind.instance_of = .{ .value = c.value - start, .class = c.class },
        .method_value => |m| node.kind.method_value = .{ .receiver = m.receiver - start, .slot = m.slot },
        .object_set => |c| node.kind.object_set = .{ .object = c.object - start, .index = c.index, .value = c.value - start },
        .iterate => |i| node.kind = .{ .iterate = .{ .function = i.function, .count = i.count - start, .initial = i.initial - start } },
        .iterate_value => |i| node.kind = .{ .iterate_value = .{ .callable = i.callable - start, .count = i.count - start, .initial = i.initial - start } },
        .loop => |l| node.kind = .{ .loop = .{ .callable = l.callable - start, .initial = l.initial - start } },
        .invoke, .bind, .function_value, .self_value, .aggregate, .call, .object_new, .integer, .floating, .boolean, .string, .enumeration, .character, .cell_read, .recur => {},
        .canceling, .cancel_exit => {},
        .arm_exited, .arm_exit_value => {},
        .elapsed_time => {},
        .event_signal => |s| node.kind.event_signal = .{ .event = s.event - start, .value = s.value - start },
        .event_new => {},
        .structured => {},
        .cell_init => unreachable,
        .cell_live => |c| node.kind.cell_live = .{ .cell = c.cell, .guard = c.guard - start, .initialize = c.initialize },
        .object_live => |c| node.kind.object_live = .{ .object = c.object - start, .field = c.field, .guard = c.guard - start },
        .reaction => |r| node.kind.reaction = .{ .kind = r.kind, .guard = r.guard - start, .body = r.body - start },
        .batch => |n| node.kind.batch = n - start,
        .event_subscribe => |s| node.kind.event_subscribe = .{ .event = s.event - start, .callback = s.callback - start },
        .subscription_cancel => |n| node.kind.subscription_cancel = n - start,
        .event_notify => {},
        // RFC-0085, I1: both operands of each move.
        .ref_new => |n| node.kind.ref_new = n - start,
        .ref_get => |n| node.kind.ref_get = n - start,
        .ref_set => |r| node.kind.ref_set = .{ .ref = r.ref - start, .value = r.value - start },
        // RFC-0086, P2.3: the name moves.
        .grant => |g| node.kind.grant = .{ .kind = g.kind, .name = if (g.kind == .session) g.name else g.name - start },
        // RFC-0087, P5.4: the key and the value move. A keyed cell is declared at the root only.
        .weak_get => |g| node.kind.weak_get = .{ .cell = g.cell, .key = g.key - start },
        .weak_set => |c| node.kind.weak_set = .{ .cell = c.cell, .key = c.key - start, .value = c.value - start },
        .weak_init => unreachable,
        // RFC-0087, P5.3: the value or the text moves.
        .json_encode => |n| node.kind.json_encode = n - start,
        .json_decode => |n| node.kind.json_decode = n - start,
    }
}
