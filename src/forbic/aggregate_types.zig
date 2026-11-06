//! Bounded nominal record/enum and structurally interned array type catalogue.
//! Published definitions reference only builtins or earlier definitions, so
//! validating and consuming the catalogue needs neither recursion nor allocation.
const std = @import("std");
const name_index = @import("name_index.zig");
/// Debug builds answer every indexed lookup a second time by the scan it replaced.
const paired_scans = @import("builtin").mode == .debug;
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const scratch = @import("scratch.zig");
const modules = @import("modules.zig");

pub const builtin_count: u16 = 4;
const name_slots = 2 * @max(types.limits.user_types, @max(types.limits.record_fields, types.limits.enum_cases));

pub const Storage = struct {
    definitions: [types.limits.user_types]types.Definition = undefined,
    fields: [types.limits.fields]types.Field = undefined,
    cases: [types.limits.cases]types.Span = undefined,
    tuple_elements: [types.limits.tuple_elements]types.Type = undefined,
    /// Whether each definition has an equality (RFC-0065), decided when it is added: its parts
    /// are earlier definitions, so their answers are already here. Live up to `count`.
    comparable: [types.limits.user_types]bool = undefined,
    count: u32 = 0,
    field_count: u32 = 0,
    case_count: u32 = 0,
    tuple_count: u32 = 0,
    /// The modules declared inside files (RFC-0074). A scope's text contains the text of the
    /// modules nested in it, so whether a name belongs to a scope is asked with this table.
    nested: []const types.NestedModule = &.{},
    /// The structural definitions (arrays, tuples, options, maps, function types, the rational
    /// type) by shape, in a table that grows with them (`name_index.Table`): interning a type
    /// asks the definitions of its shape, where comparing it with every definition cost the
    /// square of what a program interns. Definitions before `shapes_seen` have been entered;
    /// the rest are entered when the table is next asked (`indexShapes`).
    shapes: name_index.Table = .{},
    shape_slots: [name_index.slotCount(types.limits.user_types).?]u32 = undefined,
    shapes_seen: u32 = 0,
    /// The named definitions (records, classes, enumerations) by name and by the nested module
    /// that declares them (`scopeKey`), entered as they are added: every name a program reads
    /// or declares is looked up here (`findNamedIn`). `name_homes` is the hash each was entered
    /// under, for when the table makes room.
    names: name_index.Table = .{},
    name_slots: [name_index.slotCount(types.limits.user_types).?]u32 = undefined,
    name_homes: [types.limits.user_types]u64 = undefined,

    pub fn reset(self: *Storage) void {
        self.assertCounts();
        self.nested = &.{};
        self.count = 0;
        self.field_count = 0;
        self.case_count = 0;
        self.tuple_count = 0;
        self.shapes.clear();
        self.shapes_seen = 0;
        self.names.clear();
        std.debug.assert(self.count == 0 and self.field_count == 0 and self.case_count == 0);
    }

    pub fn findRecord(self: *const Storage, name: []const u8, source: []const u8) ?types.Type {
        const result = self.findNamed(name, source) orelse return null;
        return if (definition(result, self.definitions[0..self.count]).? == .record) result else null;
    }

    pub fn findClass(self: *const Storage, name: []const u8, source: []const u8) ?types.Type {
        const result = self.findNamed(name, source) orelse return null;
        return if (definition(result, self.definitions[0..self.count]).? == .class) result else null;
    }

    pub fn findNamed(self: *const Storage, name: []const u8, source: []const u8) ?types.Type {
        return self.findNamedIn(name, source, .{ .start = 0, .end = @intCast(source.len) });
    }

    pub fn findNamedIn(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) ?types.Type {
        self.assertCounts();
        // The definitions of this name declared by this scope, the oldest first: the answer is
        // the first one, as it was when every definition was read in order. A name declared
        // by a module nested in the scope is entered under that module and is not met here
        // (RFC-0074); `owned` says so again for the names of files, which share one key.
        var same = self.names.walk(&self.name_slots, name_index.hashName(self.lookupKey(scope), name));
        const found: ?types.Type = while (same.next()) |index| {
            // An entry may outlive its definition where the compiler has taken some back.
            if (index >= self.count) continue;
            const span = declaredName(self.definitions[index]) orelse continue;
            if (span.end -% span.start != name.len or !modules.contains(scope, span)) continue;
            // An instantiation carries its template's name; it is found by its arguments.
            if (typeArguments(self.definitions[index]) != null) continue;
            const text = nameText(span, source) orelse break null;
            if (std.mem.eql(u8, text, name) and modules.owned(scope, span, self.nested)) {
                const result = typeAt(index);
                std.debug.assert(validType(result, self.definitions[0..self.count]));
                break result;
            }
        } else null;
        if (paired_scans) std.debug.assert(found == self.scanNamedIn(name, source, scope));
        return found;
    }

    /// `findNamedIn` by reading every definition in order: what defines its answer.
    fn scanNamedIn(self: *const Storage, name: []const u8, source: []const u8, scope: types.Span) ?types.Type {
        for (self.definitions[0..self.count], 0..) |item, index| {
            const span = declaredName(item) orelse continue;
            if (span.end -% span.start != name.len or !modules.contains(scope, span)) continue;
            if (typeArguments(item) != null) continue;
            const text = nameText(span, source) orelse return null;
            if (std.mem.eql(u8, text, name) and modules.owned(scope, span, self.nested)) return typeAt(index);
        }
        return null;
    }

    /// The part of a name's key that says which scope declares it: one more than the number
    /// of the innermost nested module around it, or zero for a name of a file. Sibling modules
    /// that declare one name so keep apart, and a lookup reads the names of its own scope.
    fn scopeKey(self: *const Storage, span: types.Span) u32 {
        if (self.nested.len == 0) return 0;
        const inner = modules.innermost(span, self.nested) orelse return 0;
        return inner + 1;
    }

    /// `scopeKey` of the names a lookup in `scope` can find: those of the nested module whose
    /// braces are exactly `scope`, or else those of files.
    fn lookupKey(self: *const Storage, scope: types.Span) u32 {
        if (self.nested.len == 0) return 0;
        const inner = modules.innermost(scope, self.nested) orelse return 0;
        const held = self.nested[inner].source;
        return if (held.start == scope.start and held.end == scope.end) inner + 1 else 0;
    }

    /// Enters the named definition that was just added, `text` being its name.
    fn enterName(self: *Storage, text: []const u8) void {
        std.debug.assert(self.count != 0);
        const index = self.count - 1;
        const home = name_index.hashName(self.scopeKey(declaredName(self.definitions[index]).?), text);
        self.name_homes[index] = home;
        if (self.names.crowded()) {
            // Entries of definitions that were taken back are dropped here.
            if (self.names.live < self.name_slots.len) self.names.grow(&self.name_slots) else self.names.empty(&self.name_slots);
            for (self.definitions[0..index], 0..) |earlier, at| {
                // An instantiation (RFC-0073) has its template's name and was never entered.
                if (declaredName(earlier) != null and typeArguments(earlier) == null) self.names.enter(&self.name_slots, self.name_homes[at], @intCast(at));
            }
        }
        self.names.enter(&self.name_slots, home, index);
    }

    /// Reuses an existing exact element type, including when the catalogue is
    /// full. Invalid input and a genuinely new over-quota type leave it intact.
    pub fn internArray(self: *Storage, element: types.Type) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(element, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .array = element })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .array = element };
        self.count += 1;
        self.decideComparable();
        std.debug.assert(self.count <= self.definitions.len);
        std.debug.assert(definition(result, self.definitions[0..self.count]).?.array == element);
        return result;
    }

    /// Structural reuse precedes capacity checks. Rejects invalid members before
    /// writing any prefix; nested/borrowed schemas remain immutable.
    pub fn internTuple(self: *Storage, elements: []const types.Type) error{ TypeLimit, TupleLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (elements.len > types.limits.tuple_arity) return error.TupleLimit;
        for (elements) |element| if (!validType(element, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .tuple = elements })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        if (elements.len > self.tuple_elements.len - self.tuple_count) return error.TupleLimit;
        const start = self.tuple_count;
        const end = start + @as(u32, @intCast(elements.len));
        const target = self.tuple_elements[start..end];
        if (@intFromPtr(target.ptr) > @intFromPtr(elements.ptr)) std.mem.copyBackwards(types.Type, target, elements) else std.mem.copyForwards(types.Type, target, elements);
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .tuple = .{ .start = start, .end = end } };
        self.tuple_count = end;
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(result, self.definitions[0..self.count]).?.tuple.end == self.tuple_count);
        return result;
    }

    pub fn internCallable(self: *Storage, shape: types.Callable) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(shape.result, self.definitions[0..self.count])) return error.InvalidType;
        const parameters = definition(shape.parameters, self.definitions[0..self.count]) orelse return error.InvalidType;
        if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start > types.limits.parameters) return error.InvalidType;
        if (!types.effectsCanonical(shape.transacts, shape.decides, shape.detail)) return error.InvalidType;
        if (self.findShape(.{ .callable = shape })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .callable = shape };
        self.count += 1;
        self.decideComparable();
        return result;
    }

    /// The type of exact fractions (RFC-0070). It has no parts and one definition, added where a
    /// program first names it, so programs without rationals keep their catalogue.
    pub fn internRational(self: *Storage) error{TypeLimit}!types.Type {
        self.assertCounts();
        if (self.findShape(.rational)) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .rational;
        self.count += 1;
        self.decideComparable();
        return result;
    }

    pub fn internOption(self: *Storage, element: types.Type) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(element, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .option = element })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .option = element };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(result, self.definitions[0..self.count]).?.option == element);
        return result;
    }

    /// The handle type `task(result)` (RFC-0082): one per result type, added where a program first
    /// names it or spawns a task of that result, so programs without tasks keep their catalogue.
    pub fn internTask(self: *Storage, result: types.Type) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(result, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .task = result })) |index| return typeAt(index);
        // The type of the result cell comes first: a definition names only earlier ones.
        const option = try self.internOption(result);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const created = typeAt(self.count);
        self.definitions[self.count] = .{ .task = .{ .result = result, .option = option } };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(created, self.definitions[0..self.count]).?.task.result == result);
        return created;
    }

    /// The type `event(value)` (RFC-0082, P3.2): one per value type, added where a program
    /// first names it, so programs without events keep their catalogue.
    pub fn internEvent(self: *Storage, value: types.Type) error{ TypeLimit, InvalidType }!types.Type {
        return self.internEventOf(.{ .value = value });
    }

    /// P3.9: `event(value)`, `sticky_event(value)` or `subscribable_event(value)`: one per kind
    /// and value type, added where a program first names it.
    pub fn internEventOf(self: *Storage, shape: types.EventShape) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(shape.value, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .event = shape })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const created = typeAt(self.count);
        self.definitions[self.count] = .{ .event = shape };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(std.meta.eql(definition(created, self.definitions[0..self.count]).?.event, shape));
        return created;
    }

    /// RFC-0085, I1: the type `ref(value)` of a variable cell: one per value type, after it,
    /// added where a program first shares a local of that type, so programs without shared
    /// locals keep their catalogue. A `ref` of a `ref` is no type (admission rule 1).
    pub fn internRef(self: *Storage, value: types.Type) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(value, self.definitions[0..self.count]) or isRef(value, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .ref = value })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const created = typeAt(self.count);
        self.definitions[self.count] = .{ .ref = value };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(created, self.definitions[0..self.count]).?.ref == value);
        return created;
    }

    /// RFC-0087, P5.1 (W1): the type `weak_map(key, value)`, one per key and value type, after
    /// both, added where a program first names it, so programs without one keep their catalogue.
    /// The key is comparable, as a map's is (`weak_map_key`); the map type itself is not needed.
    pub fn internWeakMap(self: *Storage, key: types.Type, value: types.Type) error{ TypeLimit, InvalidType, InvalidKey }!types.Type {
        self.assertCounts();
        if (!validType(value, self.definitions[0..self.count])) return error.InvalidType;
        if (!self.comparableType(key)) return error.InvalidKey;
        const shape: types.Map = .{ .key = key, .value = value };
        if (self.findShape(.{ .weak_map = shape })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const created = typeAt(self.count);
        self.definitions[self.count] = .{ .weak_map = shape };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(std.meta.eql(definition(created, self.definitions[0..self.count]).?.weak_map, shape));
        return created;
    }

    /// P3.9: the type `cancelable` of a subscription, added where a program first names it.
    pub fn internCancelable(self: *Storage) error{TypeLimit}!types.Type {
        self.assertCounts();
        if (self.findShape(.cancelable)) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .cancelable;
        self.count += 1;
        self.decideComparable();
        return result;
    }

    /// RFC-0086, P2.3: the type `reader` or `writer`, `grant(kind)`, added where a program first
    /// names it or opens a grant of the kind, so programs without handles keep their catalogue.
    pub fn internGrant(self: *Storage, kind: types.GrantKind) error{TypeLimit}!types.Type {
        self.assertCounts();
        // RFC-0087, P5.4: and `session`, named or made by `GetSession()`.
        std.debug.assert(kind == .reader or kind == .writer or kind == .session or kind == .key);
        if (self.findShape(.{ .grant = kind })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .grant = kind };
        self.count += 1;
        self.decideComparable();
        return result;
    }

    /// `awaitable(value)` or `signalable(value)` (RFC-0082, P3.7): one per kind and value type,
    /// added where a program first names it, so programs without them keep their catalogue.
    pub fn internScheduledInterface(self: *Storage, shape: types.ScheduledInterface) error{ TypeLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(shape.value, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .scheduled_interface = shape })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const created = typeAt(self.count);
        self.definitions[self.count] = .{ .scheduled_interface = shape };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(std.meta.eql(definition(created, self.definitions[0..self.count]).?.scheduled_interface, shape));
        return created;
    }

    /// The type `live(result)` of a live record (RFC-0084): one per target type, added where a
    /// program first attaches a guard to a cell of that type, after the guard's type
    /// `function<reads>(tuple(), result)`, so programs without live variables keep their catalogue.
    pub fn internLive(self: *Storage, result: types.Type) error{ TypeLimit, TupleLimit, InvalidType }!types.Type {
        self.assertCounts();
        if (!validType(result, self.definitions[0..self.count])) return error.InvalidType;
        if (self.findShape(.{ .live = result })) |index| return typeAt(index);
        const empty = try self.internTuple(&.{});
        _ = try self.internCallable(liveGuard(empty, result));
        if (self.count == self.definitions.len) return error.TypeLimit;
        const created = typeAt(self.count);
        self.definitions[self.count] = .{ .live = result };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(created, self.definitions[0..self.count]).?.live == result);
        return created;
    }

    pub fn internMap(self: *Storage, key: types.Type, value: types.Type) error{ TypeLimit, InvalidType, InvalidKey }!types.Type {
        self.assertCounts();
        if (!validType(value, self.definitions[0..self.count])) return error.InvalidType;
        if (!self.comparableType(key)) return error.InvalidKey;
        const shape: types.Map = .{ .key = key, .value = value };
        if (self.findShape(.{ .map = shape })) |index| return typeAt(index);
        if (self.count == self.definitions.len) return error.TypeLimit;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .map = shape };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(std.meta.eql(definition(result, self.definitions[0..self.count]).?.map, shape));
        return result;
    }

    /// Validates all fields before publishing either storage prefix. Record
    /// identity is nominal; fields may use any earlier type, but not this record.
    pub fn addRecord(
        self: *Storage,
        name: types.Span,
        field_slice: []const types.Field,
        is_public: bool,
        source: []const u8,
    ) error{ TypeLimit, FieldLimit, InvalidType, InvalidName, DuplicateName }!types.Type {
        return self.addRecordIn(name, field_slice, is_public, source, .{ .start = 0, .end = @intCast(source.len) });
    }

    pub fn addRecordIn(self: *Storage, name: types.Span, field_slice: []const types.Field, is_public: bool, source: []const u8, scope: types.Span) error{ TypeLimit, FieldLimit, InvalidType, InvalidName, DuplicateName }!types.Type {
        return self.addRecordAs(name, null, field_slice, is_public, source, scope);
    }

    /// An instantiation of a parametric struct (RFC-0073): a record named like its template whose
    /// identity is that name with `arguments`. The caller interns by template and arguments, so
    /// no name is searched for here.
    pub fn addRecordInstance(self: *Storage, name: types.Span, arguments: types.Type, field_slice: []const types.Field, is_public: bool, source: []const u8, scope: types.Span) error{ TypeLimit, FieldLimit, InvalidType, InvalidName, DuplicateName }!types.Type {
        if (!argumentList(arguments, self.definitions[0..self.count])) return error.InvalidType;
        return self.addRecordAs(name, arguments, field_slice, is_public, source, scope);
    }

    fn addRecordAs(self: *Storage, name: types.Span, arguments: ?types.Type, field_slice: []const types.Field, is_public: bool, source: []const u8, scope: types.Span) error{ TypeLimit, FieldLimit, InvalidType, InvalidName, DuplicateName }!types.Type {
        self.assertCounts();
        const text = nameText(name, source) orelse return error.InvalidName;
        if (builtinName(text)) return error.InvalidName;
        if (field_slice.len > types.limits.record_fields or field_slice.len > self.fields.len - self.field_count)
            return error.FieldLimit;
        if (self.count == self.definitions.len) return error.TypeLimit;
        if (!modules.within(scope, name, self.nested)) return error.InvalidName;
        if (arguments == null and self.findNamedIn(text, source, scope) != null) return error.DuplicateName;
        var field_names: [name_slots]u16 = undefined;
        @memset(field_names[0..nameSlots(field_slice.len)], 0);
        for (field_slice, 0..) |field, index| {
            const field_name = nameText(field.name, source) orelse return error.InvalidName;
            if (!validType(field.value_type, self.definitions[0..self.count])) return error.InvalidType;
            if (!insertName(types.Field, field_slice, index, field_name, source, &field_names)) return error.DuplicateName;
        }

        const start = self.field_count;
        const end: u32 = start + @as(u32, @intCast(field_slice.len));
        const destination = self.fields[start..end];
        // Support callers borrowing an existing field prefix as a new schema.
        // Direction selection also handles any other overlapping admitted slice.
        if (@intFromPtr(destination.ptr) > @intFromPtr(field_slice.ptr)) {
            std.mem.copyBackwards(types.Field, destination, field_slice);
        } else {
            std.mem.copyForwards(types.Field, destination, field_slice);
        }
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .record = .{
            .name = name,
            .fields = .{ .start = start, .end = end },
            .is_public = is_public,
            .arguments = arguments,
        } };
        self.field_count = end;
        self.count += 1;
        // An instantiation is found by its template and arguments, never by its name.
        if (arguments == null) self.enterName(text);
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(result, self.definitions[0..self.count]).?.record.fields.end == self.field_count);
        return result;
    }

    /// Declares a class before its fields are known so that they may name it, or name each other (a
    /// list node holding an optional next node). Its fields are given later by `completeClass`.
    pub fn reserveClass(self: *Storage, name: types.Span, is_public: bool, source: []const u8, scope: types.Span) error{ TypeLimit, InvalidName, DuplicateName }!types.Type {
        self.assertCounts();
        const text = nameText(name, source) orelse return error.InvalidName;
        if (builtinName(text)) return error.InvalidName;
        if (self.count == self.definitions.len) return error.TypeLimit;
        if (!modules.within(scope, name, self.nested)) return error.InvalidName;
        if (self.findNamedIn(text, source, scope) != null) return error.DuplicateName;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .class = .{ .name = name, .fields = pending_fields, .is_public = is_public } };
        self.count += 1;
        self.enterName(text);
        self.decideComparable();
        self.assertCounts();
        return result;
    }

    /// Marks the class that was reserved last as `<unique>` (RFC-0076). It is said before any
    /// type is built from the class, because what is comparable is decided as types are added.
    pub fn markUnique(self: *Storage, class: types.Type) void {
        const index = @backingInt(class) - builtin_count;
        std.debug.assert(index + 1 == self.count and self.definitions[index] == .class and pendingClass(self.definitions[index].class));
        self.definitions[index].class.is_unique = true;
        self.comparable[index] = true;
    }

    /// Declares an instantiation of a parametric class or interface (RFC-0073) before its fields
    /// are known, like `reserveClass`. It is named like its template and told apart by
    /// `arguments`; the caller interns by template and arguments, so no name is searched for.
    pub fn reserveInstance(self: *Storage, name: types.Span, arguments: types.Type, is_public: bool, source: []const u8, scope: types.Span) error{ TypeLimit, InvalidName, InvalidType }!types.Type {
        self.assertCounts();
        const text = nameText(name, source) orelse return error.InvalidName;
        if (builtinName(text)) return error.InvalidName;
        if (!argumentList(arguments, self.definitions[0..self.count])) return error.InvalidType;
        if (self.count == self.definitions.len) return error.TypeLimit;
        // The scope is the one that declares the template, a module nested in a file or the file.
        if (!modules.within(scope, name, self.nested)) return error.InvalidName;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .class = .{ .name = name, .fields = pending_fields, .is_public = is_public, .arguments = arguments } };
        self.count += 1;
        self.decideComparable();
        self.assertCounts();
        return result;
    }

    /// Gives a reserved class its fields. Field types are checked against the whole catalogue so far,
    /// which is what lets a class refer to itself and to classes declared later.
    pub fn completeClass(self: *Storage, class: types.Type, shape: ClassShape, own: []const types.Field, source: []const u8) error{ FieldLimit, InvalidType, InvalidName, DuplicateName, InvalidParent }!void {
        self.assertCounts();
        const index = @backingInt(class) - builtin_count;
        std.debug.assert(index < self.count and self.definitions[index] == .class and pendingClass(self.definitions[index].class));
        var inherited: u32 = 0;
        var parent_fields: types.Span = .{ .start = 0, .end = 0 };
        if (shape.parent) |parent| {
            // A parent is declared, complete and open to subclasses before its child.
            const item = definition(parent, self.definitions[0..self.count]) orelse return error.InvalidParent;
            if (item != .class or pendingClass(item.class) or item.class.is_final or @backingInt(parent) - builtin_count >= index) return error.InvalidParent;
            if (item.class.is_interface or shape.is_interface) return error.InvalidParent;
            parent_fields = item.class.fields;
            inherited = parent_fields.end - parent_fields.start;
        }
        if (shape.interface_count > types.Class.max_interfaces) return error.InvalidParent;
        if (shape.is_interface and (own.len != 0 or !shape.is_abstract or shape.is_final)) return error.InvalidParent;
        for (shape.interfaces[0..shape.interface_count], 0..) |interface, position| {
            const item = definition(interface, self.definitions[0..self.count]) orelse return error.InvalidParent;
            if (item != .class or pendingClass(item.class) or !item.class.is_interface or @backingInt(interface) - builtin_count >= index) return error.InvalidParent;
            for (shape.interfaces[0..position]) |earlier| if (earlier == interface) return error.InvalidParent;
        }
        const total = inherited + own.len;
        if (total > types.limits.record_fields or total > self.fields.len - self.field_count) return error.FieldLimit;
        const start = self.field_count;
        @memcpy(self.fields[start..][0..inherited], self.fields[parent_fields.start..parent_fields.end]);
        @memcpy(self.fields[start + inherited ..][0..own.len], own);
        const all = self.fields[start..][0..total];
        var field_names: [name_slots]u16 = undefined;
        @memset(field_names[0..nameSlots(all.len)], 0);
        for (all, 0..) |field, field_index| {
            const field_name = nameText(field.name, source) orelse return error.InvalidName;
            if (!validType(field.value_type, self.definitions[0..self.count])) return error.InvalidType;
            if (!insertName(types.Field, all, field_index, field_name, source, &field_names)) return error.DuplicateName;
        }
        const end: u32 = start + @as(u32, @intCast(total));
        const published = &self.definitions[index].class;
        published.fields = .{ .start = start, .end = end };
        published.parent = shape.parent;
        published.inherited = inherited;
        published.is_abstract = shape.is_abstract;
        published.is_final = shape.is_final;
        published.is_interface = shape.is_interface;
        published.interfaces = shape.interfaces;
        published.interface_count = shape.interface_count;
        self.field_count = end;
        self.assertCounts();
    }

    /// Publish only after all names and quotas are admitted. Empty enums are
    /// valid schemas but caseAt rejects every index into them.
    pub fn addEnum(self: *Storage, name: types.Span, case_slice: []const types.Span, is_public: bool, source: []const u8) error{ TypeLimit, CaseLimit, InvalidName, DuplicateName }!types.Type {
        return self.addEnumIn(name, case_slice, is_public, source, .{ .start = 0, .end = @intCast(source.len) });
    }

    pub fn addEnumIn(self: *Storage, name: types.Span, case_slice: []const types.Span, is_public: bool, source: []const u8, scope: types.Span) error{ TypeLimit, CaseLimit, InvalidName, DuplicateName }!types.Type {
        self.assertCounts();
        const text = nameText(name, source) orelse return error.InvalidName;
        if (builtinName(text)) return error.InvalidName;
        if (case_slice.len > types.limits.enum_cases or case_slice.len > self.cases.len - self.case_count) return error.CaseLimit;
        if (self.count == self.definitions.len) return error.TypeLimit;
        if (!modules.within(scope, name, self.nested)) return error.InvalidName;
        if (self.findNamedIn(text, source, scope) != null) return error.DuplicateName;
        var names: [name_slots]u16 = undefined;
        @memset(names[0..nameSlots(case_slice.len)], 0);
        for (case_slice, 0..) |span, index| {
            const case_name = nameText(span, source) orelse return error.InvalidName;
            if (!insertName(types.Span, case_slice, index, case_name, source, &names)) return error.DuplicateName;
        }
        const start = self.case_count;
        const end = start + @as(u32, @intCast(case_slice.len));
        const destination = self.cases[start..end];
        if (@intFromPtr(destination.ptr) > @intFromPtr(case_slice.ptr)) {
            std.mem.copyBackwards(types.Span, destination, case_slice);
        } else std.mem.copyForwards(types.Span, destination, case_slice);
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .enumeration = .{ .name = name, .cases = .{ .start = start, .end = end }, .is_public = is_public } };
        self.case_count = end;
        self.count += 1;
        self.enterName(text);
        self.decideComparable();
        self.assertCounts();
        std.debug.assert(definition(result, self.definitions[0..self.count]).?.enumeration.cases.end == self.case_count);
        return result;
    }

    /// Declares a refinement type (RFC-0083) named like an enum. The caller has read its bounds.
    pub fn addRefinementIn(self: *Storage, refinement: types.Refinement, source: []const u8, scope: types.Span) error{ TypeLimit, InvalidName, DuplicateName, InvalidType }!types.Type {
        self.assertCounts();
        const text = nameText(refinement.name, source) orelse return error.InvalidName;
        if (builtinName(text)) return error.InvalidName;
        if (!refinement.wellFormed()) return error.InvalidType;
        if (self.count == self.definitions.len) return error.TypeLimit;
        if (!modules.within(scope, refinement.name, self.nested)) return error.InvalidName;
        if (self.findNamedIn(text, source, scope) != null) return error.DuplicateName;
        const result = typeAt(self.count);
        self.definitions[self.count] = .{ .refinement = refinement };
        self.count += 1;
        self.enterName(text);
        self.decideComparable();
        self.assertCounts();
        return result;
    }

    /// Whether values of this type have an equality: `==`, `!=` and map keys require it.
    pub fn comparableType(self: *const Storage, value_type: types.Type) bool {
        return comparableIn(value_type, self.comparable[0..self.count]);
    }

    /// Records the answer for the definition that was just added.
    fn decideComparable(self: *Storage) void {
        std.debug.assert(self.count != 0);
        const index = self.count - 1;
        // A definition added where one was taken back: the table has to hear of it.
        if (index < self.shapes_seen) self.shapes_seen = index;
        self.comparable[index] = comparableDefinition(self.definitions[index], self.comparable[0..index], self.fields[0..self.field_count], self.tuple_elements[0..self.tuple_count]);
    }

    const shape_array = 1;
    const shape_tuple = 2;
    const shape_option = 3;
    const shape_map = 4;
    const shape_callable = 5;
    const shape_rational = 6;
    const shape_task = 7;
    const shape_event = 8;
    const shape_live = 9;
    const shape_awaitable = 10;
    const shape_signalable = 11;
    /// P3.9: the event kinds after `plain` hash from here on, and `cancelable` after them.
    const shape_event_kinds = 12;
    const shape_cancelable = 15;
    /// RFC-0086, P2.3: both kinds hash alike; `hasShape` tells them apart.
    const shape_grant = 17;
    /// RFC-0087, P5.1.
    const shape_weak_map = 18;
    /// RFC-0085, I1.
    const shape_ref = 16;

    fn eventHash(shape: types.EventShape) u64 {
        return hashTypes(if (shape.kind == .plain) shape_event else shape_event_kinds + @as(u64, @backingInt(shape.kind)), &.{shape.value});
    }

    fn hashTypes(kind: u64, parts: []const types.Type) u64 {
        return std.hash.Wyhash.hash(kind, std.mem.sliceAsBytes(parts));
    }

    /// The hash a structural definition is entered under; null for a named one, which is found
    /// by its name and never interned.
    fn shapeHash(self: *const Storage, item: types.Definition) ?u64 {
        return switch (item) {
            .array => |element| hashTypes(shape_array, &.{element}),
            .tuple => |range| hashTypes(shape_tuple, self.tuple_elements[range.start..range.end]),
            .option => |element| hashTypes(shape_option, &.{element}),
            .map => |shape| hashTypes(shape_map, &.{ shape.key, shape.value }),
            .callable => |shape| hashTypes(shape_callable, &.{ shape.parameters, shape.result }),
            .rational => shape_rational,
            .task => |shape| hashTypes(shape_task, &.{shape.result}),
            .event => |shape| eventHash(shape),
            .live => |value| hashTypes(shape_live, &.{value}),
            .scheduled_interface => |interface| hashTypes(if (interface.kind == .awaitable) shape_awaitable else shape_signalable, &.{interface.value}),
            .cancelable => shape_cancelable,
            .ref => |value| hashTypes(shape_ref, &.{value}),
            .grant => shape_grant,
            .weak_map => |shape| hashTypes(shape_weak_map, &.{ shape.key, shape.value }),
            .record, .enumeration, .class, .refinement => null,
        };
    }

    /// A structural type that is asked for: the parts of a tuple are given, not yet stored.
    const Shape = union(enum) { array: types.Type, tuple: []const types.Type, option: types.Type, map: types.Map, callable: types.Callable, rational, task: types.Type, event: types.EventShape, live: types.Type, scheduled_interface: types.ScheduledInterface, cancelable, ref: types.Type, grant: types.GrantKind, weak_map: types.Map };

    fn hasShape(self: *const Storage, item: types.Definition, shape: Shape) bool {
        return switch (shape) {
            .array => |element| item == .array and item.array == element,
            .tuple => |elements| item == .tuple and std.mem.eql(types.Type, elements, self.tuple_elements[item.tuple.start..item.tuple.end]),
            .option => |element| item == .option and item.option == element,
            .map => |map| item == .map and std.meta.eql(item.map, map),
            .callable => |callable| item == .callable and std.meta.eql(item.callable, callable),
            .rational => item == .rational,
            .task => |result| item == .task and item.task.result == result,
            .event => |event| item == .event and std.meta.eql(item.event, event),
            .live => |value| item == .live and item.live == value,
            .scheduled_interface => |interface| item == .scheduled_interface and std.meta.eql(item.scheduled_interface, interface),
            .cancelable => item == .cancelable,
            .ref => |value| item == .ref and item.ref == value,
            .grant => |kind| item == .grant and item.grant == kind,
            .weak_map => |map| item == .weak_map and std.meta.eql(item.weak_map, map),
        };
    }

    /// The definition of `shape`, if it has been interned: the first one, as reading every
    /// definition in order found.
    fn findShape(self: *Storage, shape: Shape) ?usize {
        self.indexShapes();
        const hash: u64 = switch (shape) {
            .array => |element| hashTypes(shape_array, &.{element}),
            .tuple => |elements| hashTypes(shape_tuple, elements),
            .option => |element| hashTypes(shape_option, &.{element}),
            .map => |map| hashTypes(shape_map, &.{ map.key, map.value }),
            .callable => |callable| hashTypes(shape_callable, &.{ callable.parameters, callable.result }),
            .rational => shape_rational,
            .task => |result| hashTypes(shape_task, &.{result}),
            .event => |event| eventHash(event),
            .live => |value| hashTypes(shape_live, &.{value}),
            .scheduled_interface => |interface| hashTypes(if (interface.kind == .awaitable) shape_awaitable else shape_signalable, &.{interface.value}),
            .cancelable => shape_cancelable,
            .ref => |value| hashTypes(shape_ref, &.{value}),
            .grant => shape_grant,
            .weak_map => |map| hashTypes(shape_weak_map, &.{ map.key, map.value }),
        };
        var same = self.shapes.walk(&self.shape_slots, hash);
        const found: ?usize = while (same.next()) |index| {
            // An entry may outlive its definition where the compiler has taken some back.
            if (index < self.count and self.hasShape(self.definitions[index], shape)) break index;
        } else null;
        if (paired_scans) {
            const scanned: ?usize = for (self.definitions[0..self.count], 0..) |item, index| {
                if (self.hasShape(item, shape)) break index;
            } else null;
            std.debug.assert(found == scanned);
        }
        return found;
    }

    /// Enters the structural definitions added since the table was last asked. The compiler
    /// takes definitions back (the placeholders of a generic header) by lowering `count`: their
    /// entries stay, as candidates that are past the end or no longer match, and what is
    /// added in their place is entered like anything new. Such entries are dropped when the
    /// table next has to make room.
    fn indexShapes(self: *Storage) void {
        if (self.shapes_seen > self.count) self.shapes_seen = self.count;
        while (self.shapes_seen < self.count) : (self.shapes_seen += 1) {
            const index = self.shapes_seen;
            const hash = self.shapeHash(self.definitions[index]) orelse continue;
            if (self.shapes.crowded()) {
                if (self.shapes.live < self.shape_slots.len) self.shapes.grow(&self.shape_slots) else self.shapes.empty(&self.shape_slots);
                for (self.definitions[0..index], 0..) |earlier, at| {
                    if (self.shapeHash(earlier)) |home| self.shapes.enter(&self.shape_slots, home, @intCast(at));
                }
            }
            self.shapes.enter(&self.shape_slots, hash, index);
        }
    }

    fn assertCounts(self: *const Storage) void {
        std.debug.assert(self.count <= self.definitions.len);
        std.debug.assert(self.field_count <= self.fields.len);
        std.debug.assert(self.case_count <= self.cases.len);
        std.debug.assert(self.tuple_count <= self.tuple_elements.len);
    }
};

pub const ClassShape = struct { parent: ?types.Type = null, is_abstract: bool = false, is_final: bool = false, is_interface: bool = false, interfaces: [types.Class.max_interfaces]types.Type = @splat(.i64), interface_count: u8 = 0 };

/// Whether `sub` is `super`, inherits from it or implements it.
pub fn subtype(sub: types.Type, super: types.Type, definitions: []const types.Definition) bool {
    // The superclass chain first: it is the common case and needs no working memory.
    var current = sub;
    var steps: usize = 0;
    var branching = false;
    while (steps <= definitions.len) : (steps += 1) {
        if (current == super) return true;
        const item = definition(current, definitions) orelse return false;
        if (item != .class) return false;
        branching = branching or item.class.interface_count != 0;
        current = item.class.parent orelse break;
    }
    if (!branching) return false;
    var reached: std.StaticBitSet(types.limits.user_types) = .empty;
    return supertypes(sub, definitions, &reached) and @backingInt(super) >= builtin_count and @backingInt(super) - builtin_count < definitions.len and reached.isSet(@backingInt(super) - builtin_count);
}

/// The set of `class` and all its supertypes, for callers that test many candidates against one class.
pub const Supertypes = struct {
    reached: std.StaticBitSet(types.limits.user_types) = .empty,

    pub fn of(class: types.Type, definitions: []const types.Definition) ?Supertypes {
        var result: Supertypes = .{};
        return if (supertypes(class, definitions, &result.reached)) result else null;
    }
    pub fn has(self: *const Supertypes, candidate: types.Type) bool {
        const id = @backingInt(candidate);
        return id >= builtin_count and id - builtin_count < types.limits.user_types and self.reached.isSet(id - builtin_count);
    }
};

/// Marks `class` and everything it inherits from or implements. A supertype is always an earlier
/// definition, so one descending pass reaches all of them; false when the catalogue breaks that rule.
pub fn supertypes(class: types.Type, definitions: []const types.Definition, reached: *std.StaticBitSet(types.limits.user_types)) bool {
    const id = @backingInt(class);
    if (id < builtin_count or id - builtin_count >= definitions.len or definitions.len > types.limits.user_types) return false;
    var index: usize = id - builtin_count;
    reached.set(index);
    // Nothing below the lowest type reached so far is reached, so the pass ends there: for a
    // class without supertypes it is one step, where a pass down the whole catalogue for every
    // class cost the square of the number of classes.
    var lowest = index;
    // From one reached type to the next one below it (`reachedBelow`), not through every
    // definition between them: a class far from its parent, as each of many classes below
    // one parent is, would otherwise cost the distance, and all of them its square.
    while (true) : (index = reachedBelow(reached, index)) {
        std.debug.assert(reached.isSet(index));
        if (definitions[index] == .class) {
            const item = definitions[index].class;
            if (item.parent) |parent| {
                const above = @backingInt(parent);
                if (above < builtin_count or above - builtin_count >= index) return false;
                reached.set(above - builtin_count);
                lowest = @min(lowest, above - builtin_count);
            }
            for (item.implemented()) |interface| {
                const above = @backingInt(interface);
                if (above < builtin_count or above - builtin_count >= index) return false;
                reached.set(above - builtin_count);
                lowest = @min(lowest, above - builtin_count);
            }
        }
        if (index <= lowest) break;
    }
    return true;
}

/// The highest reached type below `index`; the caller knows there is one.
fn reachedBelow(reached: *const std.StaticBitSet(types.limits.user_types), index: usize) usize {
    if (!@hasField(std.StaticBitSet(types.limits.user_types), "masks")) {
        // A set that fits one word has no words to skip.
        var below = index - 1;
        while (!reached.isSet(below)) below -= 1;
        return below;
    }
    const bits = @bitSizeOf(usize);
    var word = index / bits;
    var mask = reached.masks[word] & ((@as(usize, 1) << @intCast(index % bits)) - 1);
    while (mask == 0) {
        word -= 1;
        mask = reached.masks[word];
    }
    return word * bits + (bits - 1 - @clz(mask));
}

/// Whether a value seen as `source` could turn out to be a `target`: a subclass can, and so can
/// anything across an interface, because some class may implement both sides.
pub fn castable(target: types.Type, source: types.Type, definitions: []const types.Definition) bool {
    if (subtype(target, source, definitions)) return true;
    const to = definition(target, definitions) orelse return false;
    const from = definition(source, definitions) orelse return false;
    if (to != .class or from != .class or target == source) return false;
    // A final class that does not already implement the interface never will.
    if (to.class.is_interface) return !from.class.is_final;
    return from.class.is_interface and !to.class.is_final;
}

/// Whether a function of type `actual` may stand where the different type `expected` is
/// required: no effect `expected` does not allow (RFC-0078), a result that is the expected
/// one or a class below it, and parameters that are the expected ones or classes above them
/// (`fix2`, the Book's variance, 06:771). Only classes and interfaces vary: an instance is the
/// same reference at every class it is seen as, so the function behind the value receives and
/// returns exactly what it would through its own type. Types are interned, so equal parameter
/// lists are equal types.
pub fn widens(actual: types.Type, expected: types.Type, definitions: []const types.Definition, tuple_elements: []const types.Type) bool {
    if (actual == expected) return false;
    const from = definition(actual, definitions) orelse return false;
    const to = definition(expected, definitions) orelse return false;
    if (from != .callable or to != .callable) return false;
    if (!from.callable.effects().within(to.callable.effects())) return false;
    return fitsFunction(from.callable.parameters, from.callable.result, to.callable, definitions, tuple_elements);
}

/// Whether a function with the parameter list `parameters` and the result `result` may be
/// called through the function type `shape`: its result is `shape`'s or a class below it,
/// and each of `shape`'s parameters is its own or a class below its own. Effects are not asked.
pub fn fitsFunction(parameters: types.Type, result: types.Type, shape: types.Callable, definitions: []const types.Definition, tuple_elements: []const types.Type) bool {
    if (!classBelow(result, shape.result, definitions)) return false;
    if (parameters == shape.parameters) return true;
    const own = definition(parameters, definitions) orelse return false;
    const wanted = definition(shape.parameters, definitions) orelse return false;
    if (own != .tuple or wanted != .tuple or own.tuple.end - own.tuple.start != wanted.tuple.end - wanted.tuple.start) return false;
    for (tuple_elements[own.tuple.start..own.tuple.end], tuple_elements[wanted.tuple.start..wanted.tuple.end]) |taken, given| if (!classBelow(given, taken, definitions)) return false;
    return true;
}

/// Whether `narrow` is `wide`, or both are classes (or interfaces) and `narrow` lies below.
pub fn classBelow(narrow: types.Type, wide: types.Type, definitions: []const types.Definition) bool {
    if (narrow == wide) return true;
    const lower = definition(narrow, definitions) orelse return false;
    const upper = definition(wide, definitions) orelse return false;
    return lower == .class and upper == .class and subtype(narrow, wide, definitions);
}

/// Whether a value of static type `actual` may be used where `expected` is required.
pub fn assignable(actual: types.Type, expected: types.Type, definitions: []const types.Definition) bool {
    return actual == expected or subtype(actual, expected, definitions);
}

/// The function implementing `slot` for instances of exactly `class`.
pub fn dispatchLookup(dispatch: []const types.Dispatch, class: types.Type, slot: u32) ?u32 {
    var low: usize = 0;
    var high: usize = dispatch.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = dispatch[middle];
        if (entry.class == class and entry.slot == slot) return entry.function;
        const before = @backingInt(entry.class) < @backingInt(class) or (entry.class == class and entry.slot < slot);
        if (before) low = middle + 1 else high = middle;
    }
    return null;
}

/// Every implementation an instance of `class` can dispatch to was available by `available`
/// (a root node index, or the availability of the function building the instance).
pub fn dispatchReady(dispatch: []const types.Dispatch, functions: []const types.RuntimeFunction, class: types.Type, available: u32) bool {
    var low: usize = 0;
    var high: usize = dispatch.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (@backingInt(dispatch[middle].class) < @backingInt(class)) low = middle + 1 else high = middle;
    }
    while (low < dispatch.len and dispatch[low].class == class) : (low += 1) {
        if (dispatch[low].function >= functions.len or functions[dispatch[low].function].available_at > available) return false;
    }
    return true;
}

/// The functions that implement methods. Implementations of one slot share a name and a signature,
/// which is otherwise a duplicate definition; they are told apart by class in the dispatch table.
pub fn methodFunctions(dispatch: []const types.Dispatch) std.StaticBitSet(types.limits.functions) {
    var found: std.StaticBitSet(types.limits.functions) = .empty;
    for (dispatch) |entry| if (entry.function < types.limits.functions) found.set(entry.function);
    return found;
}

/// Methods and their dispatch table are closed over the class catalogue and the function table.
pub fn validDispatch(slots: []const types.Slot, dispatch: []const types.Dispatch, definitions: []const types.Definition, tuple_elements: []const types.Type, functions: []const types.RuntimeFunction) bool {
    if (slots.len > types.limits.methods or dispatch.len > types.limits.dispatch) return false;
    for (slots) |slot| {
        const owner = definition(slot.owner, definitions) orelse return false;
        if (owner != .class or pendingClass(owner.class)) return false;
        const shape = definition(slot.callable, definitions) orelse return false;
        if (shape != .callable) return false;
        const parameters = definition(shape.callable.parameters, definitions) orelse return false;
        if (parameters != .tuple or parameters.tuple.start >= parameters.tuple.end or parameters.tuple.end > tuple_elements.len or tuple_elements[parameters.tuple.start] != slot.owner) return false;
    }
    var previous: ?types.Dispatch = null;
    var above: Supertypes = .{};
    for (dispatch) |entry| {
        if (previous) |before| {
            if (@backingInt(entry.class) < @backingInt(before.class) or (entry.class == before.class and entry.slot <= before.slot)) return false;
        }
        if (entry.slot >= slots.len or entry.function >= functions.len) return false;
        const slot = slots[entry.slot];
        const own = definition(entry.class, definitions) orelse return false;
        if (own != .class or pendingClass(own.class)) return false;
        // Entries are grouped by class, so its supertypes are found once for the whole group.
        if (previous == null or previous.?.class != entry.class) above = Supertypes.of(entry.class, definitions) orelse return false;
        previous = entry;
        if (!above.has(slot.owner)) return false;
        const f = functions[entry.function];
        const shape = definition(slot.callable, definitions).?.callable;
        const parameters = definition(shape.parameters, definitions).?.tuple;
        // An implementation may do less than its slot allows, never more (RFC-0078): whoever
        // calls through the slot has declared every effect of the slot.
        if (f.anonymous or f.parameter_count != parameters.end - parameters.start or f.value_type != shape.result or !f.effects().within(shape.effects())) return false;
        const receiver = definition(f.parameters[0], definitions) orelse return false;
        // Exactly the slot's signature: a method value is then an ordinary callable of the slot's type.
        if (receiver != .class or f.parameters[0] != slot.owner) return false;
        for (f.parameters[1..f.parameter_count], tuple_elements[parameters.start + 1 .. parameters.end]) |actual, expected| if (actual != expected) return false;
    }
    return completeDispatch(slots, dispatch, definitions);
}

/// Every class that can be instantiated resolves every slot it declares or inherits, so a method
/// lookup on an admitted program always finds its entry. Entries are already unique and each names
/// a slot of its class, so counting them is enough.
fn completeDispatch(slots: []const types.Slot, dispatch: []const types.Dispatch, definitions: []const types.Definition) bool {
    if (definitions.len > types.limits.user_types) return false;
    var own: [types.limits.user_types]u32 = undefined;
    var missing: [types.limits.user_types]u32 = undefined;
    // A class is plain when nothing above it implements an interface: its slots are then its
    // parent's plus its own. Otherwise supertypes can be reached twice and are counted as a set.
    var plain: std.StaticBitSet(types.limits.user_types) = .empty;
    @memset(own[0..definitions.len], 0);
    @memset(missing[0..definitions.len], 0);
    for (slots) |slot| own[@backingInt(slot.owner) - builtin_count] += 1;
    for (definitions, 0..) |item, index| {
        if (item != .class) continue;
        var inherited: u32 = 0;
        var simple = item.class.interface_count == 0;
        if (item.class.parent) |parent| {
            // A parent is an earlier definition, so its count already includes its own ancestors.
            const id = @backingInt(parent);
            if (id < builtin_count or id - builtin_count >= index) return false;
            inherited = missing[id - builtin_count];
            simple = simple and plain.isSet(id - builtin_count);
        }
        if (simple) {
            plain.set(index);
            missing[index] = own[index] + inherited;
            continue;
        }
        var reached: std.StaticBitSet(types.limits.user_types) = .empty;
        if (!supertypes(@fromBackingInt(@intCast(index + builtin_count)), definitions, &reached)) return false;
        var above = reached.iterator(.{});
        while (above.next()) |supertype| missing[index] += own[supertype];
    }
    for (dispatch) |entry| {
        const index = @backingInt(entry.class) - builtin_count;
        if (missing[index] == 0) return false;
        missing[index] -= 1;
    }
    for (definitions, 0..) |item, index| {
        if (item == .class and !item.class.is_abstract and missing[index] != 0) return false;
    }
    return true;
}

/// A reserved class whose fields are not yet known has this inverted range.
pub const pending_fields: types.Span = .{ .start = 1, .end = 0 };
pub fn pendingClass(class: types.Class) bool {
    return class.fields.start > class.fields.end;
}

/// Resolving an ID is separate from validating its definition graph. Builtins
/// have no catalogue definition; malformed and out-of-profile IDs return null.
pub fn definition(value_type: types.Type, definitions: []const types.Definition) ?types.Definition {
    const id = @backingInt(value_type);
    if (id < builtin_count) return null;
    const index: usize = id - builtin_count;
    if (index >= types.limits.user_types or index >= definitions.len) return null;
    return definitions[index];
}

/// Specialization keys carry an effect argument as the canonical function type
/// `function<E>(tuple(i64),i64)`; admission accepts nothing else for effect parameters.
pub fn effectWitness(witness: types.Type, definitions: []const types.Definition, tuple_elements: []const types.Type) bool {
    const shape = definition(witness, definitions) orelse return false;
    if (shape != .callable or shape.callable.result != .i64) return false;
    const parameters = definition(shape.callable.parameters, definitions) orelse return false;
    if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start != 1 or parameters.tuple.start >= tuple_elements.len) return false;
    return tuple_elements[parameters.tuple.start] == .i64;
}

/// Whether this is the type of exact fractions.
pub fn isRational(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    return item == .rational;
}

/// A live record (RFC-0084) is no type a value of the program has: no node, cell, field,
/// parameter or other type names one.
pub fn validType(value_type: types.Type, definitions: []const types.Definition) bool {
    if (@backingInt(value_type) < builtin_count or value_type.isCharacter() or value_type == types.Type.any or value_type == types.Type.bottom) return true;
    const item = definition(value_type, definitions) orelse return false;
    return item != .live;
}

pub fn fieldAt(
    value_type: types.Type,
    index: u32,
    definitions: []const types.Definition,
    fields: []const types.Field,
) ?types.Field {
    const item = definition(value_type, definitions) orelse return null;
    const record = switch (item) {
        .record => |record| record,
        .array, .enumeration, .tuple, .option, .map, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => return null,
    };
    if (!fieldRangeValid(record.fields, fields.len)) return null;
    if (index >= record.fields.end - record.fields.start) return null;
    return fields[record.fields.start + index];
}

/// The field of a record or a class.
pub fn memberAt(value_type: types.Type, index: u32, definitions: []const types.Definition, fields: []const types.Field) ?types.Field {
    return fieldAt(value_type, index, definitions, fields) orelse classFieldAt(value_type, index, definitions, fields);
}

pub fn declaredName(item: types.Definition) ?types.Span {
    return switch (item) {
        .record => |record| record.name,
        .class => |class| class.name,
        .enumeration => |enumeration| enumeration.name,
        .refinement => |refinement| refinement.name,
        .array, .tuple, .option, .map, .callable, .rational, .task, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => null,
    };
}

pub fn declaredPublic(item: types.Definition) bool {
    return switch (item) {
        .record => |record| record.is_public,
        .class => |class| class.is_public,
        .enumeration => |enumeration| enumeration.is_public,
        .refinement => |refinement| refinement.is_public,
        .array, .tuple, .option, .map, .callable, .rational, .task, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => false,
    };
}

/// The field of a class instance. Records have no object identity and answer `fieldAt` instead.
pub fn classFieldAt(
    value_type: types.Type,
    index: u32,
    definitions: []const types.Definition,
    fields: []const types.Field,
) ?types.Field {
    const item = definition(value_type, definitions) orelse return null;
    if (item != .class) return null;
    if (!fieldRangeValid(item.class.fields, fields.len)) return null;
    if (index >= item.class.fields.end - item.class.fields.start) return null;
    return fields[item.class.fields.start + index];
}

/// Cells an instance occupies: a header naming its class, then one per field. A task handle
/// (RFC-0082) is an instance with the header and its three hidden fields, and so is an event.
pub fn classCells(value_type: types.Type, definitions: []const types.Definition) ?u32 {
    const item = definition(value_type, definitions) orelse return null;
    if (item == .task) return task_cells;
    if (item == .event) return eventCells(item.event.kind);
    if (item == .cancelable) return cancelable_cells;
    if (item == .live) return live_cells;
    if (item == .ref) return ref_cells;
    if (item != .class) return null;
    return 1 + item.class.fields.end - item.class.fields.start;
}
/// The cells of a task handle: its header, then the sequence, the state and the result.
pub const task_cells: u32 = 4;
pub const task_sequence: u32 = 1;
pub const task_state: u32 = 2;
pub const task_result: u32 = 3;
/// What the state cell holds.
pub const task_active: i64 = 0;
pub const task_completed: i64 = 1;
pub const task_canceled: i64 = 2;

/// Whether this is a task handle type `task(T)` (RFC-0082).
pub fn isTask(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    return item == .task;
}

/// The refinement `value_type` is (RFC-0083), if it is one.
pub fn refinementOf(value_type: types.Type, definitions: []const types.Definition) ?types.Refinement {
    const item = definition(value_type, definitions) orelse return null;
    return if (item == .refinement) item.refinement else null;
}

/// The cells of an event (RFC-0082, P3.2): its header, then how many tasks wait on it, and the
/// sequences of the first and the last of them (0 when none waits).
pub const event_cells: u32 = 4;
pub const event_waiting: u32 = 1;
pub const event_first: u32 = 2;
pub const event_last: u32 = 3;

/// Whether this is an event type `event(T)` (RFC-0082, P3.2), of any kind (P3.9).
pub fn isEvent(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    return item == .event;
}

/// RFC-0082, P3.9: the cells of an event of each kind. A sticky event has the three cells of an
/// event, then its latch (`i64`, 0 or 1) and the value signalled last (`0` before the first). A
/// subscribable event has the three, then its first and its last subscription (a `cancelable`,
/// or `false` for none) and the number its next subscription takes.
pub fn eventCells(kind: types.EventKind) u32 {
    return switch (kind) {
        .plain => event_cells,
        .sticky => sticky_cells,
        .subscribable => subscribable_cells,
    };
}
pub const sticky_cells: u32 = 6;
pub const sticky_latch: u32 = 4;
pub const sticky_value: u32 = 5;
pub const subscribable_cells: u32 = 7;
pub const subscription_first: u32 = 4;
pub const subscription_last: u32 = 5;
pub const subscription_count: u32 = 6;
/// The cells of a `cancelable`: its header, its state, its callback, its event, its neighbours
/// on the event's list and its number there.
pub const cancelable_cells: u32 = 7;
pub const cancelable_state: u32 = 1;
pub const cancelable_callback: u32 = 2;
pub const cancelable_event: u32 = 3;
pub const cancelable_before: u32 = 4;
pub const cancelable_after: u32 = 5;
pub const cancelable_number: u32 = 6;
pub const cancelable_active: i64 = 0;
pub const cancelable_canceled: i64 = 1;

/// P3.9: the kind and the value type of an event type, if `value_type` is one.
pub fn eventShape(value_type: types.Type, definitions: []const types.Definition) ?types.EventShape {
    const item = definition(value_type, definitions) orelse return null;
    return if (item == .event) item.event else null;
}

/// RFC-0086, P2.3: the kind of a handle type `grant(kind)`; null for any other type.
pub fn grantKind(value_type: types.Type, definitions: []const types.Definition) ?types.GrantKind {
    const item = definition(value_type, definitions) orelse return null;
    return if (item == .grant) item.grant else null;
}

/// P3.9: whether this is the type `cancelable`.
pub fn isCancelable(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    return item == .cancelable;
}

/// P3.9: the type a callback of a `subscribable_event(value)` has, `function<transacts>(tuple(value), void)`,
/// given the tuples `tuple(value)` and `tuple()`.
pub fn subscriptionCallback(parameters: types.Type, unit: types.Type) types.Callable {
    return .{ .parameters = parameters, .result = unit, .transacts = true };
}

/// The cells of a live record (RFC-0084, L1): its header, then the guard, the stamp of its
/// latest evaluation, its height, its owner (the target's instance, or the record itself for a
/// module cell), the place of its target in the owner (the module cell, or the field) and the
/// node that made it, which locates `live_unstable`.
pub const live_cells: u32 = 7;
pub const live_guard: u32 = 1;
pub const live_stamp: u32 = 2;
pub const live_height: u32 = 3;
pub const live_owner: u32 = 4;
pub const live_place: u32 = 5;
pub const live_origin: u32 = 6;

/// The cells of a variable cell `ref(T)` (RFC-0085, I1): its header, then the value.
pub const ref_cells: u32 = 2;
pub const ref_value: u32 = 1;

/// RFC-0085, I1: the value type `T` of a variable cell type `ref(T)`; null for any other type.
pub fn refValue(value_type: types.Type, definitions: []const types.Definition) ?types.Type {
    const item = definition(value_type, definitions) orelse return null;
    return if (item == .ref) item.ref else null;
}

/// RFC-0085, I1: whether this is a variable cell type `ref(T)`.
pub fn isRef(value_type: types.Type, definitions: []const types.Definition) bool {
    return refValue(value_type, definitions) != null;
}

/// RFC-0087, P5.1: the key and value types of a `map(K, V)` or a `weak_map(K, V)`, whose values
/// have one layout (W1); null for any other type. Only lookups, updates and layout ask this.
pub fn entryShape(value_type: types.Type, definitions: []const types.Definition) ?types.Map {
    const item = definition(value_type, definitions) orelse return null;
    return switch (item) {
        .map, .weak_map => |shape| shape,
        else => null,
    };
}

/// RFC-0087, P5.4 (W4): what a module cell of `value_type` is: a session cell when the type is
/// `weak_map(session, V)`; `none` for every other type, a `weak_map` of another key included
/// (Q8).
pub fn keyedKind(value_type: types.Type, definitions: []const types.Definition) types.Keyed {
    const item = definition(value_type, definitions) orelse return .none;
    if (item != .weak_map) return .none;
    const key = grantKind(item.weak_map.key, definitions) orelse return .none;
    // RFC-0087, P5.5: and a persistent cell when it is `weak_map(persistent_key, V)`.
    return if (key == types.GrantKind.session) .session else if (key == types.GrantKind.key) .persistent else .none;
}

/// RFC-0087, P5.1: whether this is a `weak_map(K, V)`.
pub fn isWeakMap(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    return item == .weak_map;
}

/// RFC-0087, W3: whether a value of `actual` is one of `expected` by an `upcast` that changes
/// only its type: `map(K, V)` to `weak_map(K, V)`, the same `K` and `V`. Nothing converts back.
pub fn weakens(actual: types.Type, expected: types.Type, definitions: []const types.Definition) bool {
    const from = definition(actual, definitions) orelse return false;
    const to = definition(expected, definitions) orelse return false;
    return from == .map and to == .weak_map and std.meta.eql(from.map, to.weak_map);
}

/// Whether this is a live record type `live(T)` (RFC-0084).
pub fn isLive(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    return item == .live;
}

/// The type of the guard of a record `live(result)`: `function<reads>(tuple(), result)`.
pub fn liveGuard(empty: types.Type, result: types.Type) types.Callable {
    return .{ .parameters = empty, .result = result, .transacts = true, .detail = types.heapDetail(true, false, false) };
}

/// Whether this is one of the scheduler's own instance types, `task(T)` or `event(T)`: no
/// cast reaches or leaves one. Nor does one reach or leave a variable cell `ref(T)` (RFC-0085,
/// admission rule 5), which is counted here for that reason.
pub fn isScheduled(value_type: types.Type, definitions: []const types.Definition) bool {
    const item = definition(value_type, definitions) orelse return false;
    // RFC-0086, P2.3: nor a handle (admission rule 3): nothing makes one but `grant`.
    return item == .task or item == .event or item == .scheduled_interface or item == .cancelable or item == .ref or item == .grant;
}

/// RFC-0082, P3.7: the interface `value_type` is, if it is `awaitable(T)` or `signalable(T)`.
pub fn scheduledInterface(value_type: types.Type, definitions: []const types.Definition) ?types.ScheduledInterface {
    const item = definition(value_type, definitions) orelse return null;
    return if (item == .scheduled_interface) item.scheduled_interface else null;
}

/// P3.7: whether a value of `actual` is one of the interface `expected` as it is: `task(T)` is
/// `awaitable(T)`, and `event(T)` is both `awaitable(T)` and `signalable(T)`, for the same `T`.
/// The value does not change: the instance keeps its own type, by which `Await` tells a handle
/// from an event.
pub fn implements(actual: types.Type, expected: types.Type, definitions: []const types.Definition) bool {
    const wanted = scheduledInterface(expected, definitions) orelse return false;
    const item = definition(actual, definitions) orelse return false;
    return switch (item) {
        .task => |shape| wanted.kind == .awaitable and shape.result == wanted.value,
        // P3.9: a subscribable event's `Signal` needs more than a `signalable(T)`'s (C103).
        .event => |shape| shape.value == wanted.value and (shape.kind != .subscribable or wanted.kind == .awaitable),
        else => false,
    };
}

pub fn findField(
    value_type: types.Type,
    name: []const u8,
    definitions: []const types.Definition,
    fields: []const types.Field,
    source: []const u8,
) ?u32 {
    const item = definition(value_type, definitions) orelse return null;
    const span = switch (item) {
        .record => |record| record.fields,
        .class => |class| class.fields,
        .array, .enumeration, .tuple, .option, .map, .callable, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => return null,
    };
    if (!fieldRangeValid(span, fields.len)) return null;
    for (fields[span.start..span.end], 0..) |field, index| {
        const text = nameText(field.name, source) orelse return null;
        if (std.mem.eql(u8, text, name)) return @intCast(index);
    }
    return null;
}

/// Raw catalogues are untrusted. Verify the complete bounded graph, including
/// unused definitions and trailing fields, before consumers dereference it.
/// Source UTF-8 admission belongs to the enclosing program validator; names
/// themselves are bounded ASCII identifiers and are checked here.
pub fn validate(definitions: []const types.Definition, fields: []const types.Field, source: []const u8) bool {
    return validateWithCases(definitions, fields, &.{}, source);
}

pub fn validateWithCases(definitions: []const types.Definition, fields: []const types.Field, cases: []const types.Span, source: []const u8) bool {
    return validateAll(definitions, fields, cases, &.{}, source);
}

pub fn validateAll(definitions: []const types.Definition, fields: []const types.Field, cases: []const types.Span, tuple_elements: []const types.Type, source: []const u8) bool {
    if (definitions.len > types.limits.user_types) return false;
    const comparable = scratch.alloc(bool, definitions.len) orelse return false;
    defer scratch.free(comparable);
    comparableTypes(definitions, fields, tuple_elements, comparable);
    return validateAllIn(definitions, fields, cases, tuple_elements, source, &.{}, &.{}, comparable);
}

/// The enclosing validator first admits the complete module partition. `comparable` is what
/// `comparableTypes` says of these definitions; the admission that owns it uses it afterwards.
pub fn validateAllIn(definitions: []const types.Definition, fields: []const types.Field, cases: []const types.Span, tuple_elements: []const types.Type, source: []const u8, module_table: []const types.Module, nested: []const types.NestedModule, comparable: []const bool) bool {
    if (definitions.len > types.limits.user_types or fields.len > types.limits.fields or cases.len > types.limits.cases) return false;
    if (comparable.len != definitions.len) return false;
    if (tuple_elements.len > types.limits.tuple_elements) return false;
    if (source.len > types.limits.source_bytes) return false;
    if (definitions.len == 0) return fields.len == 0 and cases.len == 0 and tuple_elements.len == 0;
    var field_count: u32 = 0;
    var case_count: u32 = 0;
    var tuple_count: u32 = 0;
    // Classes are completed in source order, not definition order, so each definition's fields are
    // any unclaimed range and together the ranges must cover every field exactly once.
    // Cleared by what the catalogue holds, not by what the profile allows.
    var claimed: [types.limits.fields]bool = undefined;
    @memset(claimed[0..fields.len], false);
    var record_names: [name_slots]u16 = undefined;
    @memset(record_names[0..nameSlots(definitions.len)], 0);
    // One slot per element type that can occur: the builtins, the definitions, and the two
    // character types, `any` and `false`, whose IDs lie above the catalogue and take the last
    // four slots.
    var array_elements: [builtin_count + types.limits.user_types + 4]bool = undefined;
    const character_slots = builtin_count + definitions.len;
    // Instantiations of parametric types (RFC-0073), admitted together once every shape is.
    var instantiated: usize = 0;
    @memset(array_elements[0 .. character_slots + 4], false);
    for (definitions, 0..) |item, index| {
        const earlier_definitions = definitions[0..index];
        switch (item) {
            .callable => |shape| {
                if (!validType(shape.result, earlier_definitions)) return false;
                const parameters = definition(shape.parameters, earlier_definitions) orelse return false;
                if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start > types.limits.parameters) return false;
                // One encoding per effect set (RFC-0078), or equal function types would differ.
                if (!types.effectsCanonical(shape.transacts, shape.decides, shape.detail)) return false;
                for (earlier_definitions) |old| if (old == .callable and std.meta.eql(old.callable, shape)) return false;
            },
            .option => |element| {
                if (!validType(element, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| if (earlier == .option and earlier.option == element) return false;
            },
            // One type, so one definition: two would be unequal types of the same values.
            .rational => for (earlier_definitions) |earlier| if (earlier == .rational) return false,
            // A task handle (RFC-0082): one per result type, which is an earlier definition, as is
            // the option of it that the result cell holds.
            .task => |shape| {
                if (!validType(shape.result, earlier_definitions)) return false;
                const option = definition(shape.option, earlier_definitions) orelse return false;
                if (option != .option or option.option != shape.result) return false;
                for (earlier_definitions) |earlier| if (earlier == .task and earlier.task.result == shape.result) return false;
            },
            // An event (RFC-0082, P3.2): one per value type, which is an earlier definition.
            .event => |shape| {
                if (!validType(shape.value, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| if (earlier == .event and std.meta.eql(earlier.event, shape)) return false;
            },
            // P3.9: one type, so one definition.
            .cancelable => for (earlier_definitions) |earlier| if (earlier == .cancelable) return false,
            // RFC-0085, I1 (admission rule 1): one variable cell type per value type, which is
            // an earlier definition and not itself a `ref`.
            .ref => |value| {
                if (!validType(value, earlier_definitions) or isRef(value, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| if (earlier == .ref and earlier.ref == value) return false;
            },
            // RFC-0086, P2.3 (admission rule 4): a known kind, at most one definition per kind.
            .grant => |kind| {
                // RFC-0087, P5.4: and `session`.
                if (kind != .reader and kind != .writer and kind != .session and kind != .key) return false;
                for (earlier_definitions) |earlier| if (earlier == .grant and earlier.grant == kind) return false;
            },
            // P3.7: one interface per kind and value type, which is an earlier definition.
            .scheduled_interface => |shape| {
                if (!validType(shape.value, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| if (earlier == .scheduled_interface and std.meta.eql(earlier.scheduled_interface, shape)) return false;
            },
            // A live record (RFC-0084, admission rule 7): one per target type, after the type
            // of its guard, `function<reads>(tuple(), T)`.
            .live => |value| {
                if (!validType(value, earlier_definitions)) return false;
                var guard = false;
                for (earlier_definitions) |earlier| {
                    if (earlier == .live and earlier.live == value) return false;
                    if (earlier != .callable or earlier.callable.result != value) continue;
                    const parameters = definition(earlier.callable.parameters, earlier_definitions) orelse continue;
                    if (parameters != .tuple or parameters.tuple.start != parameters.tuple.end) continue;
                    if (std.meta.eql(earlier.callable, liveGuard(earlier.callable.parameters, value))) guard = true;
                }
                if (!guard) return false;
            },
            .map => |shape| {
                // A key is an earlier definition, and the answer for one depends on nothing later.
                if (!comparableIn(shape.key, comparable[0..index]) or !validType(shape.value, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| if (earlier == .map and std.meta.eql(earlier.map, shape)) return false;
            },
            // RFC-0087, admission rule 1: a `weak_map` as a map, one per key and value type.
            .weak_map => |shape| {
                if (!comparableIn(shape.key, comparable[0..index]) or !validType(shape.value, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| if (earlier == .weak_map and std.meta.eql(earlier.weak_map, shape)) return false;
            },
            .tuple => |span| {
                if (!tupleRangeValid(span, tuple_elements.len) or span.start != tuple_count) return false;
                const elements = tuple_elements[span.start..span.end];
                for (elements) |element| if (!validType(element, earlier_definitions)) return false;
                for (earlier_definitions) |earlier| {
                    if (earlier == .tuple and std.mem.eql(types.Type, elements, tuple_elements[earlier.tuple.start..earlier.tuple.end])) return false;
                }
                tuple_count = span.end;
            },
            .array => |element| {
                if (!validType(element, earlier_definitions)) return false;
                const element_id: usize = if (element == types.Type.bottom) character_slots + 3 else if (element == types.Type.any) character_slots + 2 else if (element.isCharacter()) character_slots + @intFromBool(element == types.Type.char32) else @backingInt(element);
                if (array_elements[element_id]) return false;
                array_elements[element_id] = true;
            },
            .record => |record| {
                const name = nameText(record.name, source) orelse return false;
                if (builtinName(name)) return false;
                if (!fieldRangeValid(record.fields, fields.len) or !claim(&claimed, record.fields)) return false;
                // An instantiation shares its template's name; `validOrigins` tells them apart.
                if (record.arguments == null) {
                    if (!insertDefinitionName(definitions, index, name, source, module_table, nested, &record_names)) return false;
                } else instantiated += 1;
                const record_fields = fields[record.fields.start..record.fields.end];
                var field_names: [name_slots]u16 = undefined;
                @memset(field_names[0..nameSlots(record_fields.len)], 0);
                for (record_fields, 0..) |field, field_index| {
                    if (module_table.len != 0 and !modules.contains(module_table[modules.owner(record.name, module_table).?].source, field.name)) return false;
                    const field_name = nameText(field.name, source) orelse return false;
                    // Only a class field can be live-only (RFC-0084, P4.2).
                    if (field.live_only) return false;
                    if (!validType(field.value_type, earlier_definitions)) return false;
                    if (!insertName(types.Field, record_fields, field_index, field_name, source, &field_names)) return false;
                }
                field_count += record.fields.end - record.fields.start;
            },
            .class => |class| {
                const name = nameText(class.name, source) orelse return false;
                if (builtinName(name)) return false;
                if (!fieldRangeValid(class.fields, fields.len) or !claim(&claimed, class.fields)) return false;
                if (class.arguments == null) {
                    if (!insertDefinitionName(definitions, index, name, source, module_table, nested, &record_names)) return false;
                } else instantiated += 1;
                const class_fields = fields[class.fields.start..class.fields.end];
                if (class.inherited > class_fields.len or (class.parent == null and class.inherited != 0)) return false;
                if (class.parent) |parent| {
                    // The parent is an earlier, open class whose fields start this one's.
                    const parent_item = definition(parent, earlier_definitions) orelse return false;
                    if (parent_item != .class or parent_item.class.is_final or parent_item.class.is_interface or !fieldRangeValid(parent_item.class.fields, fields.len)) return false;
                    // Seen as its superclass an instance is compared by identity, so it has one (RFC-0076).
                    if (parent_item.class.is_unique and !class.is_unique) return false;
                    const parent_fields = fields[parent_item.class.fields.start..parent_item.class.fields.end];
                    if (parent_fields.len != class.inherited) return false;
                    for (parent_fields, class_fields[0..class.inherited]) |inherited, own| if (!std.meta.eql(inherited, own)) return false;
                }
                if (class.interface_count > types.Class.max_interfaces) return false;
                if (class.is_interface and (class.parent != null or class_fields.len != 0 or !class.is_abstract or class.is_final or class.is_unique)) return false;
                for (class.implemented(), 0..) |interface, position| {
                    // An interface is an earlier definition without fields, so viewing an instance as one exposes nothing.
                    const above = definition(interface, earlier_definitions) orelse return false;
                    if (above != .class or !above.class.is_interface) return false;
                    for (class.interfaces[0..position]) |earlier| if (earlier == interface) return false;
                }
                var field_names: [name_slots]u16 = undefined;
                @memset(field_names[0..nameSlots(class_fields.len)], 0);
                // The supertypes of this class, found only if a field is named outside its module.
                var above: ?Supertypes = null;
                for (class_fields, 0..) |field, field_index| {
                    if (field_index >= class.inherited and module_table.len != 0 and !modules.contains(module_table[modules.owner(class.name, module_table).?].source, field.name)) {
                        // A class holds the fields of the interfaces it implements under the names
                        // the interface declared, which may lie in the interface's module.
                        if (class.interface_count == 0) return false;
                        if (above == null) above = Supertypes.of(@fromBackingInt(@intCast(index + builtin_count)), definitions[0 .. index + 1]) orelse return false;
                        const named_by_interface = for (earlier_definitions, 0..) |earlier, earlier_index| {
                            if (earlier != .class or !earlier.class.is_interface or !above.?.reached.isSet(earlier_index)) continue;
                            const home = modules.owner(earlier.class.name, module_table) orelse continue;
                            if (modules.contains(module_table[home].source, field.name)) break true;
                        } else false;
                        if (!named_by_interface) return false;
                    }
                    const field_name = nameText(field.name, source) orelse return false;
                    // A live-only field (RFC-0084, P4.2) is written by its guard, never by `set`.
                    if (field.live_only and field.is_var) return false;
                    // Only a class may be named before it is defined; every other shape is acyclic.
                    if (!validType(field.value_type, definitions)) return false;
                    if (!insertName(types.Field, class_fields, field_index, field_name, source, &field_names)) return false;
                }
                field_count += class.fields.end - class.fields.start;
            },
            .enumeration => |enumeration| {
                const name = nameText(enumeration.name, source) orelse return false;
                if (builtinName(name)) return false;
                const span = enumeration.cases;
                if (span.start != case_count or span.start > span.end or span.end > cases.len or span.end - span.start > types.limits.enum_cases) return false;
                if (!insertDefinitionName(definitions, index, name, source, module_table, nested, &record_names)) return false;
                const enum_cases = cases[span.start..span.end];
                var names: [name_slots]u16 = undefined;
                @memset(names[0..nameSlots(enum_cases.len)], 0);
                for (enum_cases, 0..) |case_span, case_index| {
                    if (module_table.len != 0 and !modules.contains(module_table[modules.owner(enumeration.name, module_table).?].source, case_span)) return false;
                    const case_name = nameText(case_span, source) orelse return false;
                    if (!insertName(types.Span, enum_cases, case_index, case_name, source, &names)) return false;
                }
                case_count = span.end;
            },
            // A refinement (RFC-0083) is named like an enum and holds no other definition: its
            // base is a builtin and its bounds are constants of it.
            .refinement => |refinement| {
                const name = nameText(refinement.name, source) orelse return false;
                if (builtinName(name) or !refinement.wellFormed()) return false;
                if (!insertDefinitionName(definitions, index, name, source, module_table, nested, &record_names)) return false;
            },
        }
    }
    if (field_count != fields.len or case_count != cases.len or tuple_count != tuple_elements.len) return false;
    if (!validOrigins(definitions, fields, tuple_elements, source, module_table, nested, comparable, instantiated)) return false;
    // With modules nested in files the reach rule replaces this one; each admission asks it
    // of its own `Privacy` (`fieldsAdmitted`), built once the catalogue is known to be sound.
    if (nested.len == 0 and module_table.len != 0) {
        var exposed: [types.limits.user_types]bool = undefined;
        exportableTypes(definitions, fields, tuple_elements, &exposed);
        // On an instantiation `is_public` is its template's: whether the type itself can cross a
        // module boundary also depends on its arguments, which `exportableTypes` has weighed.
        for (definitions, 0..) |item, index| if ((item == .record and item.record.is_public and item.record.arguments == null and !exposed[index]) or (item == .class and item.class.is_public and item.class.arguments == null and !exposed[index])) return false;
    }
    return true;
}

/// The type arguments of an instantiation of a parametric type (RFC-0073): a tuple type listing
/// them. Null for every definition that is not one.
pub fn typeArguments(item: types.Definition) ?types.Type {
    return switch (item) {
        .record => |record| record.arguments,
        .class => |class| class.arguments,
        .array, .enumeration, .tuple, .option, .map, .callable, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => null,
    };
}

/// Whether `arguments` can list the arguments of an instantiation: a tuple of one type for each
/// parameter a template can have.
pub fn argumentList(arguments: types.Type, definitions: []const types.Definition) bool {
    const shape = definition(arguments, definitions) orelse return false;
    if (shape != .tuple or shape.tuple.start >= shape.tuple.end) return false;
    return shape.tuple.end - shape.tuple.start <= types.limits.parameters;
}

/// The origin records of the catalogue (RFC-0073). An instantiation names the template it was
/// made from by the template's name and lists its type arguments; this admits that
///
/// - the arguments are an earlier tuple definition, so origins cannot form a cycle: a tuple
///   holds only earlier types, and so no instantiation is, directly or not, its own argument;
/// - the source declares a parametric type of that kind at that name, with as many parameters,
///   the same publicity, and every `comparable` parameter given a comparable argument;
/// - no two definitions of one scope (a file, or a module nested in one: `modules.home`, the
///   scope that declares the template) claim the same name with the same arguments, and none
///   claims the name without arguments, so a name with arguments identifies one type;
/// - a definition without arguments is not declared as a template.
///
/// It does not check that the fields and methods are what the template's body gives for those
/// arguments: that would take the compiler. Nothing depends on it. Both machines use an
/// instantiation only through its own definition, which is admitted like any other class or
/// struct; the origin only names the type in reports and inspection.
///
/// One probe per definition, whatever the number of instantiations.
fn validOrigins(definitions: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type, source: []const u8, module_table: []const types.Module, nested: []const types.NestedModule, comparable: []const bool, instantiated: usize) bool {
    for (definitions) |item| {
        if (typeArguments(item) != null) continue;
        // A metatype has its bound as its argument (RFC-0081).
        if (item == .record and item.record.metatype) return false;
        const name = declaredName(item) orelse continue;
        if (declaredTemplate(source, name)) return false;
    }
    if (instantiated == 0) return true;
    // An entry is a definition index plus one. Each instantiation adds itself and at most one
    // marker for its name, so the table stays at most half full.
    const marker: u32 = 1 << 31;
    const slots = @max(16, 4 * instantiated);
    const table = scratch.alloc(u32, slots) orelse return false;
    defer scratch.free(table);
    @memset(table, 0);
    for (definitions, 0..) |item, index| {
        const arguments = typeArguments(item) orelse continue;
        const id = @backingInt(arguments);
        if (id < builtin_count or id - builtin_count >= index or !argumentList(arguments, definitions[0..index])) return false;
        const shape = definitions[id - builtin_count].tuple;
        const name = declaredName(item).?;
        const keyword: []const u8 = if (item == .record) "struct" else if (item.class.is_interface) "interface" else "class";
        // A metatype (RFC-0081) is a struct the compiler makes for `subtype(T)`,
        // `castable_subtype(T)` or `concrete_subtype(T)`, named where the program writes it:
        // a public struct of one argument, made by no template.
        const metatype = item == .record and item.record.metatype;
        if (metatype and (shape.end - shape.start != 1 or !declaredPublic(item) or !metatypeUse(source, name) or !metatypeFields(item.record, tuple_elements[shape.start], std.mem.eql(u8, name.text(source), "castable_concrete_subtype"), definitions[0..index], fields, tuple_elements))) return false;
        // The compiler makes one metatype for each kind and bound; nothing else is named so.
        if (metatype) continue;
        if (!metatype and !templateHeader(source, name, declaredPublic(item), keyword, tuple_elements[shape.start..shape.end], comparable[0..index])) return false;
        const namespace: u32 = if (module_table.len == 0) 0 else modules.home(name, module_table, nested) orelse return false;
        const text = name.text(source);
        var slot = std.hash.Wyhash.hash((@as(u64, namespace) << 16) | id, text) % slots;
        while (table[slot] != 0) : (slot = (slot + 1) % slots) {
            if (table[slot] & marker != 0) continue;
            const other = definitions[table[slot] - 1];
            if (typeArguments(other).? == arguments and sameNominal(declaredName(other).?, name, source, module_table, nested)) return false;
        }
        table[slot] = @intCast(index + 1);
        slot = std.hash.Wyhash.hash((@as(u64, namespace) << 16) | std.math.maxInt(u16), text) % slots;
        const marked = while (table[slot] != 0) : (slot = (slot + 1) % slots) {
            if (table[slot] & marker != 0 and sameNominal(declaredName(definitions[(table[slot] & ~marker) - 1]).?, name, source, module_table, nested)) break true;
        } else false;
        if (!marked) table[slot] = marker | @as(u32, @intCast(index + 1));
    }
    for (definitions) |item| {
        if (typeArguments(item) != null) continue;
        const name = declaredName(item) orelse continue;
        const namespace: u32 = if (module_table.len == 0) 0 else modules.home(name, module_table, nested) orelse return false;
        var slot = std.hash.Wyhash.hash((@as(u64, namespace) << 16) | std.math.maxInt(u16), name.text(source)) % slots;
        while (table[slot] != 0) : (slot = (slot + 1) % slots) {
            if (table[slot] & marker != 0 and sameNominal(declaredName(definitions[(table[slot] & ~marker) - 1]).?, name, source, module_table, nested)) return false;
        }
    }
    return true;
}

/// Two declared names that are one name of one scope: a file, or a module nested in one.
fn sameNominal(a: types.Span, b: types.Span, source: []const u8, module_table: []const types.Module, nested: []const types.NestedModule) bool {
    if (module_table.len != 0 and modules.home(a, module_table, nested) != modules.home(b, module_table, nested)) return false;
    return std.mem.eql(u8, a.text(source), b.text(source));
}

fn skipHeaderSpace(source: []const u8, at: *usize) void {
    while (at.* < source.len) {
        if (std.ascii.isWhitespace(source[at.*])) {
            at.* += 1;
        } else if (lexer.commentOpens(source, at.*)) {
            at.* = lexer.commentEnd(source, at.*);
        } else break;
    }
}

/// Skips `<public>` or `<internal>` (RFC-0074: the access a declaration has without either)
/// after a declared name, and says whether it was `<public>`; null when a specifier there is
/// anything else.
fn skipPublic(source: []const u8, at: *usize) ?bool {
    skipHeaderSpace(source, at);
    if (at.* == source.len or source[at.*] != '<') return false;
    at.* += 1;
    skipHeaderSpace(source, at);
    const word = headerWord(source, at);
    const is_public = std.mem.eql(u8, word, "public");
    if (!is_public and !std.mem.eql(u8, word, "internal")) return null;
    skipHeaderSpace(source, at);
    if (at.* == source.len or source[at.*] != '>') return null;
    at.* += 1;
    skipHeaderSpace(source, at);
    return is_public;
}

fn headerWord(source: []const u8, at: *usize) []const u8 {
    const begin = at.*;
    while (at.* < source.len and (std.ascii.isAlphanumeric(source[at.*]) or source[at.*] == '_')) at.* += 1;
    return source[begin..at.*];
}

/// Whether the source declares a parametric type or function at `name`: `Name[` or `Name<public>[`.
/// The fields of a metatype: none for a bound that is not a class, else one, named like the
/// metatype, that holds the test `(Bound)<decides>:Bound` or the construction
/// `(option(Bound)):Bound` of the class a value names. `castable_concrete_subtype` (`pair`)
/// holds both, the test first and the construction second, named by the tail `concrete_subtype`
/// of the word. Nothing else can travel in one.
fn metatypeFields(record: types.Record, bound: types.Type, pair: bool, earlier: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type) bool {
    const class = if (definition(bound, earlier)) |item| item == .class else false;
    const count = record.fields.end - record.fields.start;
    if (record.fields.start > record.fields.end or record.fields.end > fields.len) return false;
    if (!class) return count == 0 and !pair;
    if (count != @as(u32, if (pair) 2 else 1)) return false;
    for (fields[record.fields.start..record.fields.end], 0..) |field, at| {
        // The test is named like the metatype, the construction of a pair by the tail of the word.
        const tail = types.Span{ .start = record.name.end -| @as(u32, "concrete_subtype".len), .end = record.name.end };
        if (!std.meta.eql(field.name, if (pair and at == 1) tail else record.name) or field.is_var) return false;
        const shape = definition(field.value_type, earlier) orelse return false;
        if (shape != .callable or shape.callable.result != bound) return false;
        const parameters = definition(shape.callable.parameters, earlier) orelse return false;
        if (parameters != .tuple or parameters.tuple.end - parameters.tuple.start != 1 or parameters.tuple.end > tuple_elements.len) return false;
        const taken = tuple_elements[parameters.tuple.start];
        // The test takes the bound, the construction the option that only tells it apart.
        if (pair) {
            if (at == 0) {
                if (taken != bound) return false;
                continue;
            }
            const marker = definition(taken, earlier) orelse return false;
            if (marker != .option or marker.option != bound) return false;
        } else if (taken != bound) {
            const marker = definition(taken, earlier) orelse return false;
            if (marker != .option or marker.option != bound) return false;
        }
    }
    return true;
}

fn metatypeWord(text: []const u8) bool {
    for ([_][]const u8{ "subtype", "castable_subtype", "concrete_subtype", "castable_concrete_subtype" }) |word| {
        if (std.mem.eql(u8, text, word)) return true;
    }
    return false;
}

/// Whether `name` is one of the metatype words written as a type: followed by its argument.
fn metatypeUse(source: []const u8, name: types.Span) bool {
    if (name.start >= name.end or name.end > source.len) return false;
    const text = name.text(source);
    if (!metatypeWord(text)) return false;
    var at: usize = name.end;
    skipHeaderSpace(source, &at);
    return at < source.len and source[at] == '(';
}

fn declaredTemplate(source: []const u8, name: types.Span) bool {
    if (name.start > name.end or name.end > source.len) return false;
    var at: usize = name.end;
    _ = skipPublic(source, &at) orelse return false;
    return at < source.len and source[at] == '[';
}

/// Whether the source declares at `name` a parametric type that `arguments` can instantiate:
/// `Name<public>[P:type, Q:comparable, R:subtype(Bound)] := keyword`. A `subtype` bound is a
/// contract the compiler checked where the type was named; it is not resolved again here.
fn templateHeader(source: []const u8, name: types.Span, is_public: bool, keyword: []const u8, arguments: []const types.Type, comparable: []const bool) bool {
    if (name.start >= name.end or name.end > source.len) return false;
    var at: usize = name.end;
    const declared_public = skipPublic(source, &at) orelse return false;
    if (declared_public != is_public) return false;
    if (at == source.len or source[at] != '[') return false;
    at += 1;
    var count: usize = 0;
    while (true) {
        skipHeaderSpace(source, &at);
        if (headerWord(source, &at).len == 0 or count == arguments.len) return false;
        skipHeaderSpace(source, &at);
        if (at == source.len or source[at] != ':') return false;
        at += 1;
        skipHeaderSpace(source, &at);
        const kind = headerWord(source, &at);
        if (std.mem.eql(u8, kind, "comparable")) {
            if (!comparableIn(arguments[count], comparable)) return false;
        } else if (metatypeWord(kind)) {
            skipHeaderSpace(source, &at);
            if (at == source.len or source[at] != '(') return false;
            var depth: usize = 0;
            while (at < source.len) : (at += 1) {
                if (lexer.commentOpens(source, at)) {
                    const end = lexer.commentEnd(source, at);
                    if (end == source.len) return false;
                    at = end - 1;
                } else if (source[at] == '(' or source[at] == '[') {
                    depth += 1;
                } else if (source[at] == ')' or source[at] == ']') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            if (at == source.len) return false;
            at += 1;
        } else if (!std.mem.eql(u8, kind, "type")) return false;
        count += 1;
        skipHeaderSpace(source, &at);
        if (at == source.len) return false;
        if (source[at] == ']') break;
        if (source[at] != ',') return false;
        at += 1;
    }
    if (count != arguments.len) return false;
    at += 1;
    skipHeaderSpace(source, &at);
    if (at == source.len or source[at] != ':') return false;
    at += 1;
    skipHeaderSpace(source, &at);
    if (at == source.len or source[at] != '=') return false;
    at += 1;
    skipHeaderSpace(source, &at);
    return std.mem.eql(u8, headerWord(source, &at), keyword);
}

/// Where a declaration can be used from, as a scope of `modules.home`: that scope and the
/// modules nested in it. A public declaration of a file reaches every importer.
pub const everywhere: u32 = std.math.maxInt(u32);
/// The reach of a type built from types that no single scope sees together.
pub const nowhere: u32 = std.math.maxInt(u32) - 1;

/// Privacy across modules nested in files (RFC-0074). A `<public>` declaration is usable from
/// the scope around the innermost module on its path that is not public (from every importer
/// when all are), and anything else from its own module. Each type gets the scope that can
/// name all of it; a public declaration may mention only types that reach at least as far as
/// it does. Without nested modules this is the rule of `exportableTypes`, which callers keep
/// for that case.
pub const Privacy = struct {
    modules: []const types.Module,
    nested: []const types.NestedModule,
    reach: []u32,

    /// The caller has admitted the catalogue: a structural type is built from earlier
    /// definitions only, so one pass in order gives every type its reach. A nominal type
    /// reaches as far as its declaration; what its fields are made of does not change who
    /// can name it, and is asked separately of public records and classes (`fieldsAdmitted`).
    pub fn create(definitions: []const types.Definition, tuple_elements: []const types.Type, module_table: []const types.Module, nested: []const types.NestedModule) ?Privacy {
        const reach = scratch.alloc(u32, definitions.len) orelse return null;
        var self: Privacy = .{ .modules = module_table, .nested = nested, .reach = reach[0..0] };
        for (definitions, 0..) |item, index| {
            // Only what is already computed is read: a type that named a later one would be
            // unsound, and counts as reaching nowhere.
            self.reach = reach[0..index];
            reach[index] = switch (item) {
                // An instantiation (RFC-0073) is declared where its template is, and is named
                // only where its arguments can be named too.
                // A metatype (RFC-0081) is named wherever its bound can be.
                .record, .class, .enumeration, .refinement => if (item == .record and item.record.metatype) (if (item.record.arguments) |bound| self.of(bound) else nowhere) else if (typeArguments(item)) |arguments| self.meet(self.declared(declaredName(item).?, declaredPublic(item)), self.of(arguments)) else self.declared(declaredName(item).?, declaredPublic(item)),
                .rational => everywhere,
                .callable => |shape| self.meet(self.of(shape.parameters), self.of(shape.result)),
                .array, .option => |element| self.of(element),
                .task => |shape| self.of(shape.result),
                .event => |shape| self.of(shape.value),
                .cancelable => everywhere,
                .grant => everywhere,
                .ref => |value| self.of(value),
                .live => |value| self.of(value),
                .scheduled_interface => |shape| self.of(shape.value),
                .map, .weak_map => |shape| self.meet(self.of(shape.key), self.of(shape.value)),
                .tuple => |span| elements: {
                    var lowered: u32 = everywhere;
                    for (tuple_elements[span.start..span.end]) |element| lowered = self.meet(lowered, self.of(element));
                    break :elements lowered;
                },
            };
        }
        self.reach = reach;
        return self;
    }

    /// Whether every field of a public record or class is nameable wherever the type is.
    pub fn fieldsAdmitted(self: *const Privacy, definitions: []const types.Definition, fields: []const types.Field) bool {
        for (definitions) |item| {
            // A public template's member types are checked where it is declared; what an
            // instantiation adds is its arguments, which its reach has weighed (RFC-0073).
            const range = switch (item) {
                .record => |record| if (record.is_public and record.arguments == null) record.fields else continue,
                .class => |class| if (class.is_public and class.arguments == null) class.fields else continue,
                else => continue,
            };
            for (fields[range.start..range.end]) |field| if (!(item == .class and field.hidden) and !self.admits(field.value_type, declaredName(item).?, true)) return false;
        }
        return true;
    }

    pub fn destroy(self: Privacy) void {
        scratch.free(self.reach);
    }

    /// The reach of the declaration written at `name`.
    pub fn declared(self: *const Privacy, name: types.Span, is_public: bool) u32 {
        var scope = modules.home(name, self.modules, self.nested) orelse return nowhere;
        if (!is_public) return scope;
        for (0..types.limits.module_depth + 1) |_| {
            if (scope < self.modules.len) return everywhere;
            const outer = modules.enclosing(scope, self.modules, self.nested).?;
            if (!self.nested[scope - self.modules.len].is_public) return outer;
            scope = outer;
        }
        return nowhere;
    }

    fn of(self: *const Privacy, value_type: types.Type) u32 {
        const id = @backingInt(value_type);
        if (id < builtin_count or value_type.isCharacter() or value_type == types.Type.any or value_type == types.Type.bottom) return everywhere;
        return if (id - builtin_count < self.reach.len) self.reach[id - builtin_count] else nowhere;
    }

    fn meet(self: *const Privacy, a: u32, b: u32) u32 {
        if (a == everywhere or b == nowhere) return b;
        if (b == everywhere or a == nowhere) return a;
        if (modules.inside(a, b, self.modules, self.nested)) return a;
        if (modules.inside(b, a, self.modules, self.nested)) return b;
        return nowhere;
    }

    /// Whether `value_type` can be named everywhere: in every module, and by a host that
    /// reads a public report (`value_report.View`).
    pub fn reachesEverywhere(self: *const Privacy, value_type: types.Type) bool {
        return self.of(value_type) == everywhere;
    }

    /// Whether the declaration at `name` may have `value_type` in its signature. Only a public
    /// declaration is asked: what is not public is used where its module's types are.
    pub fn admits(self: *const Privacy, value_type: types.Type, name: types.Span, is_public: bool) bool {
        if (!is_public) return true;
        return self.reaches(self.of(value_type), name);
    }

    /// Whether something with the reach `have` can be named wherever the public declaration
    /// at `name` can be used.
    pub fn reaches(self: *const Privacy, have: u32, name: types.Span) bool {
        const wanted = self.declared(name, true);
        if (have == everywhere) return true;
        if (wanted == everywhere or wanted == nowhere or have == nowhere) return false;
        return modules.inside(wanted, have, self.modules, self.nested);
    }
};

fn claim(claimed: *[types.limits.fields]bool, span: types.Span) bool {
    for (claimed[span.start..span.end]) |*taken| {
        if (taken.*) return false;
        taken.* = true;
    }
    return true;
}

fn nominalName(item: types.Definition) types.Span {
    return switch (item) {
        .record => |record| record.name,
        .class => |class| class.name,
        .enumeration => |enumeration| enumeration.name,
        .refinement => |refinement| refinement.name,
        else => unreachable,
    };
}
fn insertDefinitionName(definitions: []const types.Definition, index: usize, name: []const u8, source: []const u8, module_table: []const types.Module, nested: []const types.NestedModule, symbols: *[name_slots]u16) bool {
    if (module_table.len == 0) return insertName(types.Definition, definitions, index, name, source, symbols);
    const namespace = modules.home(nominalName(definitions[index]), module_table, nested) orelse return false;
    const slots = nameSlots(definitions.len);
    const start = std.hash.Wyhash.hash(namespace, name) % slots;
    for (0..slots) |probe| {
        const slot = (start + probe) % slots;
        if (symbols[slot] == 0) {
            symbols[slot] = @intCast(index + 1);
            return true;
        }
        const span = nominalName(definitions[symbols[slot] - 1]);
        if (modules.home(span, module_table, nested).? == namespace and std.mem.eql(u8, span.text(source), name)) return false;
    }
    unreachable;
}

/// Caller admits the ordered catalogue first. Privacy propagates through all
/// structural shapes; nominal schemas themselves must also be public.
pub fn exportableTypes(definitions: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type, output: *[types.limits.user_types]bool) void {
    // A class may name types defined after it, itself included (`Next:option(Node)`), so the
    // answer is the largest one that is consistent: everything starts out exportable except
    // what is private by its own declaration, and is lowered until every public class
    // mentions only exportable types. Starting the structural types low instead would lower
    // a class that names itself through one of them and never raise it again.
    for (definitions, 0..) |item, index| output[index] = switch (item) {
        .class => |class| class.is_public,
        .record => |record| record.is_public,
        .enumeration => |enumeration| enumeration.is_public,
        .refinement => |refinement| refinement.is_public,
        .rational, .callable, .array, .option, .map, .tuple, .task, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => true,
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (definitions, 0..) |item, index| {
            const before = output[index];
            output[index] = exportableDefinition(item, index, fields, tuple_elements, output);
            if (output[index] != before) changed = true;
        }
    }
}
fn exportableDefinition(item: types.Definition, index: usize, fields: []const types.Field, tuple_elements: []const types.Type, output: *[types.limits.user_types]bool) bool {
    return switch (item) {
        .enumeration => |enumeration| enumeration.is_public,
        .refinement => |refinement| refinement.is_public,
        .rational => true,
        .class => |class| class.is_public and (class.arguments == null or exportable(class.arguments.?, output[0..index])) and field_types: {
            // A class that is still being declared has no fields to weigh yet.
            if (pendingClass(class)) break :field_types true;
            // A hidden field stays inside its module and out of every public report
            // (`types.Field.hidden`), so its type does not travel with the class.
            for (fields[class.fields.start..class.fields.end]) |field| if (!field.hidden and !exportable(field.value_type, output[0..])) break :field_types false;
            break :field_types true;
        },
        .record => |record| record.is_public and (record.arguments == null or exportable(record.arguments.?, output[0..index])) and field_types: {
            for (fields[record.fields.start..record.fields.end]) |field| if (!exportable(field.value_type, output[0..index])) break :field_types false;
            break :field_types true;
        },
        .callable => |shape| exportable(shape.parameters, output[0..index]) and exportable(shape.result, output[0..index]),
        .array, .option => |element| exportable(element, output[0..index]),
        .task => |shape| exportable(shape.result, output[0..index]),
        .event => |shape| exportable(shape.value, output[0..index]),
        .cancelable => true,
        .grant => true,
        .ref => |value| exportable(value, output[0..index]),
        .live => |value| exportable(value, output[0..index]),
        .scheduled_interface => |shape| exportable(shape.value, output[0..index]),
        .map, .weak_map => |shape| exportable(shape.key, output[0..index]) and exportable(shape.value, output[0..index]),
        .tuple => |span| tuple_types: {
            for (tuple_elements[span.start..span.end]) |element| if (!exportable(element, output[0..index])) break :tuple_types false;
            break :tuple_types true;
        },
    };
}
pub fn exportable(value_type: types.Type, admitted: []const bool) bool {
    const id = @backingInt(value_type);
    return id < builtin_count or value_type.isCharacter() or value_type == types.Type.any or value_type == types.Type.bottom or (id - builtin_count < admitted.len and admitted[id - builtin_count]);
}

pub fn tupleElementAt(value_type: types.Type, index: u32, definitions: []const types.Definition, elements: []const types.Type) ?types.Type {
    const item = definition(value_type, definitions) orelse return null;
    if (item != .tuple or !tupleRangeValid(item.tuple, elements.len)) return null;
    if (index >= item.tuple.end - item.tuple.start) return null;
    return elements[item.tuple.start + index];
}

fn tupleRangeValid(span: types.Span, count: usize) bool {
    return span.start <= span.end and span.end <= count and span.end - span.start <= types.limits.tuple_arity;
}

pub fn caseAt(value_type: types.Type, index: u32, definitions: []const types.Definition, cases: []const types.Span) ?types.Span {
    const item = definition(value_type, definitions) orelse return null;
    const enumeration = switch (item) {
        .enumeration => |enumeration| enumeration,
        .record, .array, .tuple, .option, .map, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => return null,
    };
    const span = enumeration.cases;
    if (span.start > span.end or span.end > cases.len or span.end - span.start > types.limits.enum_cases) return null;
    if (index >= span.end - span.start) return null;
    return cases[span.start + index];
}

pub fn findCase(value_type: types.Type, name: []const u8, definitions: []const types.Definition, cases: []const types.Span, source: []const u8) ?u32 {
    const item = definition(value_type, definitions) orelse return null;
    const enumeration = switch (item) {
        .enumeration => |enumeration| enumeration,
        .record, .array, .tuple, .option, .map, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => return null,
    };
    const span = enumeration.cases;
    if (span.start > span.end or span.end > cases.len or span.end - span.start > types.limits.enum_cases) return null;
    for (cases[span.start..span.end], 0..) |case_span, index| {
        const text = nameText(case_span, source) orelse return null;
        if (std.mem.eql(u8, text, name)) return @intCast(index);
    }
    return null;
}

/// Types whose values have an equality: what `==`, `!=` and map keys accept (RFC-0065). Scalars
/// and enums; class instances, equal exactly when they are the same instance; and records, tuples,
/// options, arrays and maps all of whose parts are comparable. A function has no equality, and
/// neither has anything that holds one.
///
/// Decides it for every definition at once, into `output[index]`. A structural type names only
/// earlier definitions, so one ascending pass has every part's answer before it is needed: the
/// cost is the size of the catalogue, whatever is asked afterwards and however often. A class is
/// not entered: its fields are state, not part of its identity, and may name any type. The
/// catalogue need not be admitted yet: a definition that breaks the ordering or names a range
/// outside its table is incomparable instead of being followed.
pub fn comparableTypes(definitions: []const types.Definition, fields: []const types.Field, tuple_elements: []const types.Type, output: []bool) void {
    std.debug.assert(output.len == definitions.len);
    for (definitions, 0..) |item, index| output[index] = comparableDefinition(item, output[0..index], fields, tuple_elements);
}

/// The answer `comparableTypes` gave for `value_type`, in one step. A type outside the
/// catalogue the answers were made for is not comparable.
pub fn comparableIn(value_type: types.Type, comparable: []const bool) bool {
    const id = @backingInt(value_type);
    // The character types (RFC-0069) are builtin IDs above the catalogue, compared by value.
    if (id < builtin_count or value_type.isCharacter()) return true;
    const index: usize = id - builtin_count;
    return index < comparable.len and comparable[index];
}

/// Whether a definition is comparable, given the answers for the definitions before it.
fn comparableDefinition(item: types.Definition, earlier: []const bool, fields: []const types.Field, tuple_elements: []const types.Type) bool {
    switch (item) {
        // A refinement has its base's equality (RFC-0083).
        .enumeration, .rational, .refinement => return true,
        // Only a class that says `<unique>` has an identity to compare (RFC-0076, D15).
        .class => |class| return class.is_unique,
        // A task handle has no identity a program can compare (RFC-0082), like a class that is
        // not `<unique>`, and neither has an event.
        .callable, .task, .event, .live, .scheduled_interface, .cancelable => return false,
        // RFC-0085, I1: a variable cell's identity is not observable (V4), so it has no equality.
        .ref => return false,
        // RFC-0086, P2.3: two handles are equal when they name the same grant (H3).
        .grant => return true,
        // RFC-0087, W1: a `weak_map` has no equality (03:1112).
        .weak_map => return false,
        .array, .option => |element| return comparableIn(element, earlier),
        .map => |shape| return comparableIn(shape.key, earlier) and comparableIn(shape.value, earlier),
        .tuple => |span| {
            if (!tupleRangeValid(span, tuple_elements.len)) return false;
            for (tuple_elements[span.start..span.end]) |element| if (!comparableIn(element, earlier)) return false;
            return true;
        },
        .record => |record| {
            if (!fieldRangeValid(record.fields, fields.len)) return false;
            for (fields[record.fields.start..record.fields.end]) |field| if (!comparableIn(field.value_type, earlier)) return false;
            return true;
        },
    }
}

/// Whether `==` on this type walks its operands, so its cost depends on their values: strings and
/// every structural type. Scalars, enum cases and instances compare in one step.
pub fn walkedEquality(value_type: types.Type, definitions: []const types.Definition) bool {
    if (value_type == .string) return true;
    const item = definition(value_type, definitions) orelse return false;
    return switch (item) {
        .record, .array, .tuple, .option, .map => true,
        .enumeration, .callable, .class, .rational, .task, .refinement, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => false,
    };
}

fn typeAt(index: usize) types.Type {
    std.debug.assert(index < types.limits.user_types);
    const result: types.Type = @fromBackingInt(@intCast(@as(u16, @intCast(index)) + builtin_count));
    return result;
}

/// Slots contain indexes of names already admitted in this invocation. The
/// table is at most half full; collisions never introduce an admission quota.
/// The part of a name table that `count` names use: twice their number, so clearing and probing
/// cost what the declaration holds rather than what the profile allows.
fn nameSlots(count: usize) usize {
    return @min(name_slots, @max(16, 2 * count));
}

fn insertName(
    comptime Item: type,
    items: []const Item,
    index: usize,
    name: []const u8,
    source: []const u8,
    symbols: *[name_slots]u16,
) bool {
    std.debug.assert(index < items.len and items.len <= name_slots / 2);
    const slots = nameSlots(items.len);
    const start = std.hash.Wyhash.hash(0, name) % slots;
    for (0..slots) |probe| {
        const slot = (start + probe) % slots;
        const entry = symbols[slot];
        if (entry == 0) {
            symbols[slot] = @intCast(index + 1);
            return true;
        }
        const earlier_index = entry - 1;
        std.debug.assert(earlier_index < index);
        const earlier_span = if (Item == types.Span) items[earlier_index] else if (Item == types.Field) items[earlier_index].name else switch (items[earlier_index]) {
            .record => |record| record.name,
            .class => |class| class.name,
            .enumeration => |enumeration| enumeration.name,
            .refinement => |refinement| refinement.name,
            .array, .tuple, .option, .map, .callable, .rational, .task, .event, .live, .scheduled_interface, .cancelable, .ref, .grant, .weak_map => unreachable, // Only names of admitted records/enums enter this table.
        };
        // Admission checked this span once when its slot was published.
        if (std.mem.eql(u8, name, source[earlier_span.start..earlier_span.end])) return false;
    }
    unreachable; // At most 256 names occupy a 512-slot table.
}

fn fieldRangeValid(span: types.Span, field_count: usize) bool {
    return span.start <= span.end and span.end <= field_count and span.end - span.start <= types.limits.record_fields;
}

fn nameText(span: types.Span, source: []const u8) ?[]const u8 {
    if (span.start >= span.end or span.end > source.len) return null;
    const name = source[span.start..span.end];
    if (name.len > types.limits.identifier_bytes) return null;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return null;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return null;
    }
    return name;
}

fn builtinName(name: []const u8) bool {
    if (std.meta.stringToEnum(types.Type, name) != null) return true;
    for ([_][]const u8{ "import", "struct", "enum", "array", "tuple", "option", "map", "Lookup", "Or", "true", "false", "Inf", "NaN" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

test "enum publication preserves nominal namespaces and canonical case ownership" {
    const source = "mode Dark Light record Other";
    var storage: Storage = .{};
    const spans = [_]types.Span{ .{ .start = 5, .end = 9 }, .{ .start = 10, .end = 15 } };
    const mode = try storage.addEnum(.{ .start = 0, .end = 4 }, &spans, true, source);
    try std.testing.expectEqual(mode, storage.findNamed("mode", source).?);
    try std.testing.expect(storage.findRecord("mode", source) == null);
    try std.testing.expectEqual(@as(u32, 1), findCase(mode, "Light", storage.definitions[0..storage.count], storage.cases[0..storage.case_count], source).?);
    try std.testing.expect(caseAt(mode, 2, storage.definitions[0..storage.count], storage.cases[0..storage.case_count]) == null);
    const prior = storage.definitions[0];
    try std.testing.expectError(error.DuplicateName, storage.addRecord(.{ .start = 0, .end = 4 }, &.{}, false, source));
    try std.testing.expectError(error.DuplicateName, storage.addEnum(.{ .start = 16, .end = 22 }, &.{ spans[0], spans[0] }, false, source));
    try std.testing.expectEqualDeep(prior, storage.definitions[0]);
    try std.testing.expectEqual(@as(u32, 1), storage.count);
    try std.testing.expectEqual(@as(u32, 2), storage.case_count);
    // Borrowed existing cases are copied safely and have distinct nominal type.
    const other = try storage.addEnum(.{ .start = 23, .end = 28 }, storage.cases[0..2], false, source);
    try std.testing.expect(mode != other);
    try std.testing.expect(validateWithCases(storage.definitions[0..storage.count], &.{}, storage.cases[0..storage.case_count], source));
    try std.testing.expect(!validateWithCases(storage.definitions[0..storage.count], &.{}, storage.cases[0 .. storage.case_count - 1], source));
    try std.testing.expect(!validateWithCases(storage.definitions[0..1], &.{}, storage.cases[0..storage.case_count], source));
    try std.testing.expect(!validate(storage.definitions[0..storage.count], &.{}, source));
    storage.reset();
    try std.testing.expectEqual(@as(u32, 0), storage.case_count);
    const empty = try storage.addEnum(.{ .start = 0, .end = 4 }, &.{}, false, source);
    try std.testing.expect(validateWithCases(storage.definitions[0..storage.count], &.{}, &.{}, source));
    try std.testing.expect(caseAt(empty, 0, storage.definitions[0..storage.count], &.{}) == null);
}

test "catalogue publishes nominal records and structurally interned arrays" {
    const source = "Palette Background Alpha Theme Item Empty";
    var storage: Storage = .{};
    const palette = try storage.addRecord(.{ .start = 0, .end = 7 }, &.{
        .{ .name = .{ .start = 8, .end = 18 }, .value_type = .string },
        .{ .name = .{ .start = 19, .end = 24 }, .value_type = .float },
    }, true, source);
    const palette_array = try storage.internArray(palette);
    try std.testing.expectEqual(palette_array, try storage.internArray(palette));
    const theme = try storage.addRecord(.{ .start = 25, .end = 30 }, &.{
        .{ .name = .{ .start = 31, .end = 35 }, .value_type = palette_array },
    }, false, source);
    _ = try storage.addRecord(.{ .start = 36, .end = 41 }, &.{}, false, source);
    try std.testing.expect(validate(storage.definitions[0..storage.count], storage.fields[0..storage.field_count], source));
    try std.testing.expectEqual(@as(u16, 4), @backingInt(palette));
    try std.testing.expectEqual(palette, storage.findRecord("Palette", source).?);
    try std.testing.expectEqual(theme, storage.findRecord("Theme", source).?);
    try std.testing.expect(storage.findRecord("Missing", source) == null);
    try std.testing.expectEqual(@as(u32, 1), findField(palette, "Alpha", storage.definitions[0..storage.count], storage.fields[0..storage.field_count], source).?);
    try std.testing.expectEqual(types.Type.float, fieldAt(palette, 1, storage.definitions[0..storage.count], storage.fields[0..storage.field_count]).?.value_type);
    try std.testing.expect(fieldAt(palette_array, 0, storage.definitions[0..storage.count], storage.fields[0..storage.field_count]) == null);
    try std.testing.expect(fieldAt(palette, 2, storage.definitions[0..storage.count], storage.fields[0..storage.field_count]) == null);
    storage.reset();
    try std.testing.expectEqual(@as(u32, 0), storage.count);
    try std.testing.expectEqual(@as(u32, 0), storage.field_count);
}

test "rejected record admission preserves the published catalogue" {
    const source = "One Two Field Other i64 Bad-name 1Bad";
    var storage: Storage = .{};
    const one = try storage.addRecord(.{ .start = 0, .end = 3 }, &.{
        .{ .name = .{ .start = 8, .end = 13 }, .value_type = .i64 },
    }, false, source);
    const counts = .{ storage.count, storage.field_count };
    const original_record = storage.definitions[0].record;
    const original_field = storage.fields[0];
    try std.testing.expectError(error.DuplicateName, storage.addRecord(.{ .start = 0, .end = 3 }, &.{}, true, source));
    try std.testing.expectError(error.DuplicateName, storage.addRecord(.{ .start = 4, .end = 7 }, &.{ original_field, original_field }, true, source));
    try std.testing.expectError(error.InvalidType, storage.addRecord(.{ .start = 4, .end = 7 }, &.{
        .{ .name = .{ .start = 14, .end = 19 }, .value_type = @fromBackingInt(@intCast(5)) },
    }, true, source));
    for ([_]types.Span{
        .{ .start = 20, .end = 23 }, // Builtin name.
        .{ .start = 24, .end = 32 }, // Punctuation.
        .{ .start = 33, .end = 37 }, // Leading digit.
        .{ .start = 2, .end = 1 },
        .{ .start = 0, .end = 0 },
    }) |span| try std.testing.expectError(error.InvalidName, storage.addRecord(span, &.{}, false, source));
    try std.testing.expectEqual(counts[0], storage.count);
    try std.testing.expectEqual(counts[1], storage.field_count);
    try std.testing.expectEqualDeep(original_record, storage.definitions[0].record);
    try std.testing.expectEqualDeep(original_field, storage.fields[0]);
    try std.testing.expectEqual(one, storage.findRecord("One", source).?);
    // Borrowing the old field prefix preserves both nominal records.
    _ = try storage.addRecord(.{ .start = 4, .end = 7 }, storage.fields[0..1], true, source);
    try std.testing.expectEqual(@as(u32, 2), storage.field_count);
    try std.testing.expect(validate(storage.definitions[0..storage.count], storage.fields[0..storage.field_count], source));
}

test "array quota permits reuse and rejects malformed custom IDs without mutation" {
    var storage: Storage = .{};
    var element: types.Type = .i64;
    for (0..types.limits.user_types) |_| element = try storage.internArray(element);
    try std.testing.expectEqual(@as(u32, types.limits.user_types), storage.count);
    const last = storage.definitions[storage.count - 1].array;
    try std.testing.expectEqual(element, try storage.internArray(last));
    try std.testing.expectError(error.TypeLimit, storage.internArray(element));
    try std.testing.expectError(error.InvalidType, storage.internArray(@fromBackingInt(@intCast(65535))));
    try std.testing.expectError(error.InvalidType, storage.internArray(@fromBackingInt(@as(u16, builtin_count + types.limits.user_types))));
    try std.testing.expectError(error.TypeLimit, storage.addRecord(.{ .start = 0, .end = 1 }, &.{}, false, "R"));
    try std.testing.expectEqual(@as(u32, types.limits.user_types), storage.count);
    try std.testing.expectEqual(last, storage.definitions[storage.count - 1].array);
    try std.testing.expect(validate(storage.definitions[0..storage.count], &.{}, ""));
    try std.testing.expect(validType(.float, &.{}));
    try std.testing.expect(!validType(@fromBackingInt(@intCast(4)), &.{}));
    try std.testing.expect(!validType(@fromBackingInt(@intCast(65535)), storage.definitions[0..storage.count]));
    try std.testing.expect(definition(.i64, storage.definitions[0..storage.count]) == null);
}

test "record field quotas cover exact record and total boundaries" {
    try @import("profile.zig").requireBootstrap();
    var source: [types.limits.record_fields * 5 + 15]u8 = undefined;
    var fields: [types.limits.record_fields]types.Field = undefined;
    for (&fields, 0..) |*field, index| {
        const start = index * 5;
        _ = try std.fmt.bufPrint(source[start..][0..5], "F{d:0>3} ", .{index});
        field.* = .{ .name = .{ .start = @intCast(start), .end = @intCast(start + 4) }, .value_type = .i64 };
    }
    const names_start = fields.len * 5;
    @memcpy(source[names_start..], "R0 R1 R2 R3 R4 ");
    var storage: Storage = .{};
    for (0..4) |index| {
        const start: u32 = @intCast(names_start + index * 3);
        _ = try storage.addRecord(.{ .start = start, .end = start + 2 }, &fields, false, &source);
    }
    try std.testing.expectEqual(@as(u32, types.limits.fields), storage.field_count);
    const fifth: types.Span = .{ .start = @intCast(names_start + 12), .end = @intCast(names_start + 14) };
    try std.testing.expectError(error.FieldLimit, storage.addRecord(fifth, fields[0..1], false, &source));
    try std.testing.expectEqual(@as(u32, 4), storage.count);
    _ = try storage.addRecord(fifth, &.{}, false, &source);
    try std.testing.expect(validate(storage.definitions[0..storage.count], storage.fields[0..storage.field_count], &source));
    storage.reset();
    const too_many: [types.limits.record_fields + 1]types.Field = @splat(fields[0]);
    try std.testing.expectError(error.FieldLimit, storage.addRecord(fifth, &too_many, false, &source));
    try std.testing.expectEqual(@as(u32, 0), storage.count);
    try std.testing.expectEqual(@as(u32, 0), storage.field_count);
}

test "catalogue validation rejects complete malformed metadata without assertions" {
    const source = "One Two Field Other i64";
    const record: types.Record = .{ .name = .{ .start = 0, .end = 3 }, .fields = .{ .start = 0, .end = 1 }, .is_public = false };
    const field: types.Field = .{ .name = .{ .start = 8, .end = 13 }, .value_type = .i64 };
    try std.testing.expect(validate(&.{.{ .record = record }}, &.{field}, source));
    const cases = [_]types.Definition{
        .{ .array = @fromBackingInt(@intCast(4)) }, // Self reference.
        .{ .array = @fromBackingInt(@intCast(65535)) },
        .{ .record = .{ .name = record.name, .fields = .{ .start = 1, .end = 1 }, .is_public = false } },
        .{ .record = .{ .name = record.name, .fields = .{ .start = 1, .end = 0 }, .is_public = false } },
        .{ .record = .{ .name = record.name, .fields = .{ .start = 0, .end = 2 }, .is_public = false } },
        .{ .record = .{ .name = .{ .start = 20, .end = 23 }, .fields = record.fields, .is_public = false } },
        .{ .record = .{ .name = .{ .start = 0, .end = 65535 }, .fields = record.fields, .is_public = false } },
    };
    for (cases) |item| try std.testing.expect(!validate(&.{item}, &.{field}, source));
    try std.testing.expect(!validate(&.{ .{ .array = @fromBackingInt(@intCast(5)) }, .{ .array = .i64 } }, &.{}, source));
    try std.testing.expect(!validate(&.{ .{ .array = .i64 }, .{ .array = .i64 } }, &.{}, source));
    try std.testing.expect(!validate(&.{.{ .record = record }}, &.{.{ .name = field.name, .value_type = @fromBackingInt(@intCast(4)) }}, source));
    try std.testing.expect(!validate(&.{.{ .record = record }}, &.{.{ .name = .{ .start = 9, .end = 8 }, .value_type = .i64 }}, source));
    try std.testing.expect(!validate(&.{.{ .record = .{ .name = record.name, .fields = .{ .start = 0, .end = 2 }, .is_public = false } }}, &.{ field, field }, source));
    try std.testing.expect(!validate(&.{ .{ .record = record }, .{ .record = .{ .name = record.name, .fields = .{ .start = 1, .end = 1 }, .is_public = false } } }, &.{field}, source));
    try std.testing.expect(!validate(&.{}, &.{field}, source));
    try std.testing.expect(fieldAt(@fromBackingInt(@intCast(4)), 0, &.{cases[2]}, &.{field}) == null);
    try std.testing.expect(findField(@fromBackingInt(@intCast(4)), "Field", &.{.{ .record = record }}, &.{.{ .name = .{ .start = 23, .end = 24 }, .value_type = .i64 }}, source) == null);
    var too_many_definitions: [types.limits.user_types + 1]types.Definition = @splat(.{ .array = .i64 });
    try std.testing.expect(!validate(&too_many_definitions, &.{}, source));
    var too_many_fields: [types.limits.fields + 1]types.Field = @splat(field);
    try std.testing.expect(!validate(&.{}, &too_many_fields, source));
}

test "maximum identifier length is admitted and malformed lengths or Unicode are rejected" {
    var source: [types.limits.identifier_bytes + 1]u8 = @splat('N');
    var storage: Storage = .{};
    _ = try storage.addRecord(.{ .start = 0, .end = types.limits.identifier_bytes }, &.{}, true, &source);
    try std.testing.expect(validate(storage.definitions[0..storage.count], &.{}, &source));
    try std.testing.expectError(error.InvalidName, storage.addRecord(.{ .start = 0, .end = source.len }, &.{}, false, &source));
    const unicode = "名字";
    try std.testing.expectError(error.InvalidName, storage.addRecord(.{ .start = 0, .end = unicode.len }, &.{}, false, unicode));
    try std.testing.expectEqual(@as(u32, 1), storage.count);
    var over_quota_source: [types.limits.source_bytes + 1]u8 = @splat(' ');
    try std.testing.expect(!validate(&.{}, &.{}, &over_quota_source));
}

test "record publication supports both directions of overlapping field input" {
    const source = "One Two A B C";
    const first: types.Field = .{ .name = .{ .start = 8, .end = 9 }, .value_type = .i64 };
    const second: types.Field = .{ .name = .{ .start = 10, .end = 11 }, .value_type = .string };
    const third: types.Field = .{ .name = .{ .start = 12, .end = 13 }, .value_type = .float };
    var storage: Storage = .{};
    _ = try storage.addRecord(.{ .start = 0, .end = 3 }, &.{first}, false, source);
    storage.fields[1] = second;
    _ = try storage.addRecord(.{ .start = 4, .end = 7 }, storage.fields[0..2], false, source);
    try std.testing.expectEqualDeep(first, storage.fields[0]);
    try std.testing.expectEqualDeep(first, storage.fields[1]);
    try std.testing.expectEqualDeep(second, storage.fields[2]);
    try std.testing.expect(validate(storage.definitions[0..storage.count], storage.fields[0..storage.field_count], source));
    storage.reset();
    _ = try storage.addRecord(.{ .start = 0, .end = 3 }, &.{first}, false, source);
    storage.fields[2] = second;
    storage.fields[3] = third;
    _ = try storage.addRecord(.{ .start = 4, .end = 7 }, storage.fields[2..4], false, source);
    try std.testing.expectEqualDeep(first, storage.fields[0]);
    try std.testing.expectEqualDeep(second, storage.fields[1]);
    try std.testing.expectEqualDeep(third, storage.fields[2]);
    try std.testing.expect(validate(storage.definitions[0..storage.count], storage.fields[0..storage.field_count], source));
}

test "all 256 intentionally colliding field and record names are admitted" {
    try @import("profile.zig").requireBootstrap();
    var source: [types.limits.record_fields * 9 + 2]u8 = undefined;
    source[0] = 'R';
    source[1] = ' ';
    var source_len: usize = 2;
    var fields: [types.limits.record_fields]types.Field = undefined;
    var field_count: usize = 0;
    var candidate_bytes: [8]u8 = undefined;
    const collision_slot = name_slots - 1; // Probe wraparound is exercised too.
    for (0..types.limits.record_fields * name_slots * 4) |candidate| {
        if (field_count == fields.len) break;
        const name = try std.fmt.bufPrint(&candidate_bytes, "N{d:0>7}", .{candidate});
        if (std.hash.Wyhash.hash(0, name) % name_slots != collision_slot) continue;
        @memcpy(source[source_len..][0..name.len], name);
        fields[field_count] = .{ .name = .{ .start = @intCast(source_len), .end = @intCast(source_len + name.len) }, .value_type = .i64 };
        source_len += name.len;
        source[source_len] = ' ';
        source_len += 1;
        field_count += 1;
    }
    try std.testing.expectEqual(fields.len, field_count);
    var storage: Storage = .{};
    _ = try storage.addRecord(.{ .start = 0, .end = 1 }, &fields, false, source[0..source_len]);
    try std.testing.expect(validate(storage.definitions[0..storage.count], storage.fields[0..storage.field_count], source[0..source_len]));
    storage.reset();
    for (fields) |field| _ = try storage.addRecord(field.name, &.{}, false, source[0..source_len]);
    try std.testing.expectEqual(@as(u32, types.limits.user_types), storage.count);
    try std.testing.expect(validate(storage.definitions[0..storage.count], &.{}, source[0..source_len]));
    // A duplicate at the very end must still fail after a long collision chain.
    var duplicate_fields = fields;
    duplicate_fields[duplicate_fields.len - 1].name = duplicate_fields[0].name;
    storage.reset();
    try std.testing.expectError(error.DuplicateName, storage.addRecord(.{ .start = 0, .end = 1 }, &duplicate_fields, false, source[0..source_len]));
    try std.testing.expectEqual(@as(u32, 0), storage.count);
    try std.testing.expectEqual(@as(u32, 0), storage.field_count);
}

test "interned types are found by shape, through growth and after definitions are taken back" {
    const source = "Point Node Kind";
    var storage: Storage = .{};
    const point = try storage.addRecord(.{ .start = 0, .end = 5 }, &.{}, true, source);
    // Enough distinct shapes to grow the table several times: every one keeps its identity.
    var arrays: [24]types.Type = undefined;
    var nested = point;
    for (&arrays) |*array| {
        nested = try storage.internArray(nested);
        array.* = nested;
    }
    const pair = try storage.internTuple(&.{ .i64, point });
    const triple = try storage.internTuple(&.{ .i64, point, .string });
    const maybe = try storage.internOption(pair);
    const table = try storage.internMap(.string, maybe);
    const call = try storage.internCallable(.{ .parameters = pair, .result = table, .transacts = false, .decides = false });
    const effectful = try storage.internCallable(.{ .parameters = pair, .result = table, .transacts = true, .decides = false });
    const fraction = try storage.internRational();
    try std.testing.expect(call != effectful and pair != triple);
    try std.testing.expect(storage.shapes.live >= 64);
    const count = storage.count;
    nested = point;
    for (arrays) |array| {
        nested = try storage.internArray(nested);
        try std.testing.expectEqual(array, nested);
    }
    try std.testing.expectEqual(pair, try storage.internTuple(&.{ .i64, point }));
    try std.testing.expectEqual(triple, try storage.internTuple(&.{ .i64, point, .string }));
    try std.testing.expectEqual(maybe, try storage.internOption(pair));
    try std.testing.expectEqual(table, try storage.internMap(.string, maybe));
    try std.testing.expectEqual(call, try storage.internCallable(.{ .parameters = pair, .result = table, .transacts = false, .decides = false }));
    try std.testing.expectEqual(effectful, try storage.internCallable(.{ .parameters = pair, .result = table, .transacts = true, .decides = false }));
    try std.testing.expectEqual(fraction, try storage.internRational());
    try std.testing.expectEqual(count, storage.count);

    // The compiler takes definitions back by lowering the counts (the placeholders of a
    // generic header). What is interned afterwards takes their places and is found again;
    // what was taken back is not found, and can be interned anew.
    const kept = storage.count;
    const kept_tuples = storage.tuple_count;
    const scratch_tuple = try storage.internTuple(&.{ .string, .string });
    const scratch_option = try storage.internOption(scratch_tuple);
    try std.testing.expectEqual(scratch_option, try storage.internOption(scratch_tuple));
    storage.count = kept;
    storage.tuple_count = kept_tuples;
    // A different shape in the same place, asked for before and after the table hears of it.
    const other = try storage.internTuple(&.{ .float, .float });
    try std.testing.expectEqual(@backingInt(scratch_tuple), @backingInt(other));
    try std.testing.expectEqual(other, try storage.internTuple(&.{ .float, .float }));
    const again = try storage.internTuple(&.{ .string, .string });
    try std.testing.expect(again != other);
    try std.testing.expectEqual(again, try storage.internTuple(&.{ .string, .string }));
    const option_again = try storage.internOption(again);
    try std.testing.expectEqual(option_again, try storage.internOption(again));
    try std.testing.expectEqual(pair, try storage.internTuple(&.{ .i64, point }));
    // Taken back and not replaced: lookups see nothing past the end.
    storage.count = kept;
    storage.tuple_count = kept_tuples;
    try std.testing.expectEqual(maybe, try storage.internOption(pair));
    try std.testing.expectEqual(kept, storage.count);
    // Many rounds of taking back leave entries behind; the table drops them when it is full.
    for (0..4 * types.limits.user_types) |round| {
        storage.count = kept;
        storage.tuple_count = kept_tuples;
        const one = try storage.internTuple(&.{ if (round % 2 == 0) .logic else .float, .i64 });
        try std.testing.expectEqual(one, try storage.internTuple(&.{ if (round % 2 == 0) .logic else .float, .i64 }));
        try std.testing.expectEqual(kept + 1, storage.count);
    }
    try std.testing.expect(storage.shapes.used <= types.limits.user_types);

    // Named types are found by name the same way, and a name taken back is not.
    const node = try storage.addRecord(.{ .start = 6, .end = 10 }, &.{}, false, source);
    try std.testing.expectEqual(node, storage.findNamed("Node", source).?);
    try std.testing.expectEqual(point, storage.findNamed("Point", source).?);
    storage.count -= 1;
    try std.testing.expect(storage.findNamed("Node", source) == null);
    const kind = try storage.addEnum(.{ .start = 11, .end = 15 }, &.{}, false, source);
    try std.testing.expectEqual(@backingInt(node), @backingInt(kind));
    try std.testing.expectEqual(kind, storage.findNamed("Kind", source).?);
    try std.testing.expect(storage.findNamed("Node", source) == null);
    storage.reset();
    try std.testing.expect(storage.shapes.live == 0 and storage.names.live == 0 and storage.shapes_seen == 0);
    try std.testing.expect(storage.findNamed("Point", source) == null);
}

test "the supertypes of a class are found without a pass over the whole catalogue" {
    const source = "Aa Bb Cc Dd Ee";
    var storage: Storage = .{};
    var classes: [5]types.Type = undefined;
    for (&classes, 0..) |*class, index| {
        const start: u32 = @intCast(3 * index);
        class.* = try storage.reserveClass(.{ .start = start, .end = start + 2 }, false, source, .{ .start = 0, .end = source.len });
    }
    // Aa and Bb are roots; Cc extends Bb; Dd is unrelated; Ee extends Cc.
    storage.definitions[2].class.parent = classes[1];
    storage.definitions[4].class.parent = classes[2];
    const definitions = storage.definitions[0..storage.count];
    const expected = [5][5]bool{
        .{ true, false, false, false, false },
        .{ false, true, false, false, false },
        .{ false, true, true, false, false },
        .{ false, false, false, true, false },
        .{ false, true, true, false, true },
    };
    for (classes, expected) |class, row| {
        const above = Supertypes.of(class, definitions).?;
        for (classes, row) |candidate, has| {
            try std.testing.expectEqual(has, above.has(candidate));
            try std.testing.expectEqual(has, subtype(class, candidate, definitions));
        }
    }
}
