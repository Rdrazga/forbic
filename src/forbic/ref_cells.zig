//! RFC-0085, I1: variable cells on hand-built IR. No compiled program reaches `ref(T)` before
//! the compiler shares locals (I2), so the tests and the simulation build programs that use
//! cells from programs that use a class: `fromClass` turns a class with exactly one field into
//! the cell type `ref(T)` of that field's type, in place (the same type id), and its
//! constructions, reads and writes into `ref_new`, `ref_get` and `ref_set`. An instance of such
//! a class has the cells a variable cell has (a header naming its type, then the value), every
//! operation costs what the one it replaces costs, and the type keeps its id, so the program
//! made computes what the program it was made from computes, cell for cell and unit of fuel for
//! unit of fuel. Only the report tells them apart (`$ref` for `$object`).
//!
//! This is not an execution path: it allocates its copies from the allocator it is given.
//! Whether the result is admissible is the machines' matter; a program that uses the class in
//! any other way (a cast, a method, an equality, a live field) is made into one that admission
//! refuses, which the forgery tests rely on.
const std = @import("std");
const types = @import("types.zig");
const catalogue = @import("aggregate_types.zig");

pub const Options = struct {
    /// Leave the constructions as they are: `object_new` of what is now a `ref(T)` (F11).
    keep_constructions: bool = false,
};

pub const Converted = struct {
    program: types.Program,
    definitions: []types.Definition,
    fields: []types.Field,
    nodes: []types.Node,
    function_nodes: []types.FunctionNode,
    call_arguments: []u32,
    function_arguments: []u32,
    /// The type of the cells, which was the class's.
    ref: types.Type,

    pub fn deinit(self: Converted, allocator: std.mem.Allocator) void {
        allocator.free(self.function_arguments);
        allocator.free(self.call_arguments);
        allocator.free(self.function_nodes);
        allocator.free(self.nodes);
        allocator.free(self.fields);
        allocator.free(self.definitions);
    }
};

pub const Error = error{ OutOfMemory, NotConvertible };

/// The class named `name` in `program`, if there is one.
pub fn classNamed(program: types.Program, name: []const u8) ?types.Type {
    for (program.definitions, 0..) |item, index| if (item == .class and std.mem.eql(u8, item.class.name.text(program.source), name)) {
        return @fromBackingInt(@intCast(index + catalogue.builtin_count));
    };
    return null;
}

/// Whether `class` is a class `fromClass` can make into a cell type: exactly one field, of a type
/// defined before it, which is `var` (a read of an immutable field is no dependency of a guard, a
/// read of a cell always is), no parent, no type arguments and nothing below it.
pub fn convertible(program: types.Program, class: types.Type) bool {
    const item = catalogue.definition(class, program.definitions) orelse return false;
    if (item != .class) return false;
    const shape = item.class;
    if (shape.fields.end != shape.fields.start + 1 or shape.fields.end > program.fields.len or !program.fields[shape.fields.start].is_var or shape.parent != null or shape.arguments != null or shape.is_abstract or shape.is_interface) return false;
    const held = program.fields[shape.fields.start].value_type;
    if (held == class or (@backingInt(held) >= catalogue.builtin_count and !held.isCharacter() and held != types.Type.any and @backingInt(held) >= @backingInt(class))) return false;
    if (catalogue.isRef(held, program.definitions)) return false;
    for (program.definitions) |other| if (other == .class and other.class.parent != null and other.class.parent.? == class) return false;
    for (program.slots) |slot| if (slot.owner == class) return false;
    for (program.dispatch) |entry| if (entry.class == class) return false;
    for (program.functions) |f| if (f.clauses_of != null and f.clauses_of.? == class) return false;
    return true;
}

/// The program with `class` made into `ref(T)`; see the file's comment.
pub fn fromClass(allocator: std.mem.Allocator, program: types.Program, class: types.Type, options: Options) Error!Converted {
    if (!convertible(program, class)) return error.NotConvertible;
    const index = @backingInt(class) - catalogue.builtin_count;
    const shape = program.definitions[index].class;
    const dropped = shape.fields.start;
    const held = program.fields[dropped].value_type;

    const definitions = try allocator.dupe(types.Definition, program.definitions);
    errdefer allocator.free(definitions);
    definitions[index] = .{ .ref = held };
    // The class's field leaves the table; the ranges after it move down by one.
    const fields = try allocator.alloc(types.Field, program.fields.len - 1);
    errdefer allocator.free(fields);
    @memcpy(fields[0..dropped], program.fields[0..dropped]);
    @memcpy(fields[dropped..], program.fields[dropped + 1 ..]);
    for (definitions) |*item| switch (item.*) {
        .record => |*record| shiftRange(&record.fields, dropped),
        .class => |*other| shiftRange(&other.fields, dropped),
        else => {},
    };

    const nodes = try allocator.dupe(types.Node, program.nodes);
    errdefer allocator.free(nodes);
    const function_nodes = try allocator.dupe(types.FunctionNode, program.function_nodes);
    errdefer allocator.free(function_nodes);
    // The argument of each construction leaves its pool.
    var root_drop: std.ArrayList(u32) = .empty;
    defer root_drop.deinit(allocator);
    var body_drop: std.ArrayList(u32) = .empty;
    defer body_drop.deinit(allocator);
    for (nodes) |*node| {
        const typeOf = struct {
            fn get(all: []const types.Node, operand: u32) types.Type {
                return all[operand].value_type;
            }
        }.get;
        try rewrite(allocator, node, class, program.call_arguments, &root_drop, nodes, typeOf, options);
    }
    for (program.functions) |f| {
        const body = function_nodes[f.body.start..f.body.end];
        for (body) |*entry| if (entry.input == .operation) {
            const typeOf = struct {
                fn get(all: []const types.FunctionNode, operand: u32) types.Type {
                    return all[operand].node.value_type;
                }
            }.get;
            try rewrite(allocator, &entry.node, class, program.function_arguments, &body_drop, body, typeOf, options);
        };
    }
    const call_arguments = try dropAll(allocator, program.call_arguments, root_drop.items);
    errdefer allocator.free(call_arguments);
    const function_arguments = try dropAll(allocator, program.function_arguments, body_drop.items);
    errdefer allocator.free(function_arguments);
    for (nodes) |*node| shiftSpans(node, root_drop.items);
    for (function_nodes) |*entry| if (entry.input == .operation) shiftSpans(&entry.node, body_drop.items);

    var converted = program;
    converted.definitions = definitions;
    converted.fields = fields;
    converted.nodes = nodes;
    converted.function_nodes = function_nodes;
    converted.call_arguments = call_arguments;
    converted.function_arguments = function_arguments;
    return .{ .program = converted, .definitions = definitions, .fields = fields, .nodes = nodes, .function_nodes = function_nodes, .call_arguments = call_arguments, .function_arguments = function_arguments, .ref = class };
}

/// A construction becomes `ref_new` of its one argument, whose place in the pool is dropped; a
/// read or a write of the one field becomes `ref_get` or `ref_set`.
fn rewrite(allocator: std.mem.Allocator, node: *types.Node, class: types.Type, pool: []const u32, drop: *std.ArrayList(u32), all: anytype, comptime typeOf: anytype, options: Options) Error!void {
    switch (node.kind) {
        .object_new => |c| if (node.value_type == class and !options.keep_constructions) {
            if (c.arguments.end != c.arguments.start + 1 or c.arguments.end > pool.len) return error.NotConvertible;
            try drop.append(allocator, c.arguments.start);
            node.kind = .{ .ref_new = pool[c.arguments.start] };
        },
        .object_get => |a| if (a.value < all.len and typeOf(all, a.value) == class) {
            if (a.index != 0) return error.NotConvertible;
            node.kind = .{ .ref_get = a.value };
        },
        .object_set => |c| if (c.object < all.len and typeOf(all, c.object) == class) {
            if (c.index != 0) return error.NotConvertible;
            node.kind = .{ .ref_set = .{ .ref = c.object, .value = c.value } };
        },
        else => {},
    }
}

fn shiftRange(span: *types.Span, dropped: u32) void {
    if (span.start > dropped) span.start -= 1;
    if (span.end > dropped) span.end -= 1;
}

/// `pool` without the positions in `drop`, which ascend.
fn dropAll(allocator: std.mem.Allocator, pool: []const u32, drop: []const u32) Error![]u32 {
    const out = try allocator.alloc(u32, pool.len - drop.len);
    var next: usize = 0;
    var skip: usize = 0;
    for (pool, 0..) |operand, at| {
        if (skip < drop.len and drop[skip] == at) {
            skip += 1;
            continue;
        }
        out[next] = operand;
        next += 1;
    }
    std.debug.assert(next == out.len and skip == drop.len);
    return out;
}

/// How many dropped positions lie below `position`.
fn below(drop: []const u32, position: u32) u32 {
    var count: u32 = 0;
    for (drop) |at| {
        if (at < position) count += 1;
    }
    return count;
}

fn moved(span: types.Span, drop: []const u32) types.Span {
    return .{ .start = span.start - below(drop, span.start), .end = span.end - below(drop, span.end) };
}

/// The argument spans of a node, moved down past the dropped positions.
fn shiftSpans(node: *types.Node, drop: []const u32) void {
    if (drop.len == 0) return;
    switch (node.kind) {
        .call => |*c| c.arguments = moved(c.arguments, drop),
        .invoke, .bind, .event_notify => |*i| i.arguments = moved(i.arguments, drop),
        .recur => |*r| r.* = moved(r.*, drop),
        .object_new => |*c| c.arguments = moved(c.arguments, drop),
        .structured => |*s| s.arms = moved(s.arms, drop),
        else => {},
    }
}
