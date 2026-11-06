//! Strict fixed-storage JSON packaging for immutable module inventories.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const modules = @import("modules.zig");
// Worst-case six-byte JSON escaping of every source/path/root byte, plus the
// exact schema's structural/key overhead. Whitespace also consumes this bound.
// A folder tree (RFC-0093) has up to `module_files` files, a bundle of files up to
// `modules`; the bootstrap profile gives both the same numbers.
const inventory = @max(types.limits.modules, types.limits.module_files);
const inventory_paths = @max(types.limits.module_paths_bytes, types.limits.module_file_paths_bytes);
pub const max_packet_bytes = 6 * (types.limits.source_bytes + inventory_paths + types.limits.module_path_bytes) + inventory * 64 + 64;
pub const Error = error{ InvalidBundle, BundleLimit };
pub const Workspace = struct {
    sources: [types.limits.source_bytes]u8 = undefined,
    paths: [inventory_paths + types.limits.module_path_bytes]u8 = undefined,
    inputs: [inventory]modules.Input = undefined,
    source_count: usize = 0,
    path_count: usize = 0,
    input_count: usize = 0,

    /// Packet bytes must be immutable and disjoint from this writable storage.
    /// The returned inventory borrows this workspace until its next parse.
    pub fn parse(self: *Workspace, packet: []const u8) Error!modules.Bundle {
        self.source_count = 0;
        self.path_count = 0;
        self.input_count = 0;
        if (packet.len > max_packet_bytes) return error.BundleLimit;
        // Pinned ArrayList grows its first one-byte BitStack reservation by
        // one cache line. At most four container bits are ever consumed.
        var stack: [std.atomic.cache_line + 1]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&stack);
        var scanner = std.json.Scanner.initCompleteInput(allocator.allocator(), packet);
        defer scanner.deinit();
        scanner.ensureTotalStackCapacity(4) catch return error.BundleLimit;
        if (try next(&scanner) != .object_begin) return error.InvalidBundle;
        var fields: u2 = 0;
        var root: []const u8 = undefined;
        while (try peek(&scanner) != .object_end) {
            var name: [7]u8 = undefined;
            const length = try string(&scanner, &name);
            if (std.mem.eql(u8, name[0..length], "root")) {
                if (fields & 1 != 0) return error.InvalidBundle;
                fields |= 1;
                root = try self.path(&scanner);
            } else if (std.mem.eql(u8, name[0..length], "modules")) {
                if (fields & 2 != 0) return error.InvalidBundle;
                fields |= 2;
                if (try next(&scanner) != .array_begin) return error.InvalidBundle;
                while (try peek(&scanner) != .array_end) {
                    if (self.input_count == self.inputs.len) return error.BundleLimit;
                    self.inputs[self.input_count] = try self.module(&scanner);
                    self.input_count += 1;
                }
                _ = try next(&scanner);
            } else return error.InvalidBundle;
        }
        _ = try next(&scanner);
        if (fields != 3 or try next(&scanner) != .end_of_document) return error.InvalidBundle;
        // A bundle of files has at most `modules` files; one whose root is a module path is a
        // folder tree (RFC-0093), whose files make fewer modules.
        if (self.input_count > types.limits.modules and (root.len == 0 or root[0] != '/')) return error.BundleLimit;
        return .{ .root = root, .modules = self.inputs[0..self.input_count] };
    }

    fn module(self: *Workspace, scanner: *std.json.Scanner) Error!modules.Input {
        if (try next(scanner) != .object_begin) return error.InvalidBundle;
        var fields: u2 = 0;
        var input: modules.Input = undefined;
        while (try peek(scanner) != .object_end) {
            var name: [6]u8 = undefined;
            const length = try string(scanner, &name);
            if (std.mem.eql(u8, name[0..length], "path")) {
                if (fields & 1 != 0) return error.InvalidBundle;
                fields |= 1;
                input.path = try self.path(scanner);
            } else if (std.mem.eql(u8, name[0..length], "source")) {
                if (fields & 2 != 0) return error.InvalidBundle;
                fields |= 2;
                const start = self.source_count;
                self.source_count += try string(scanner, self.sources[start..]);
                input.source = self.sources[start..self.source_count];
            } else return error.InvalidBundle;
        }
        _ = try next(scanner);
        if (fields != 3) return error.InvalidBundle;
        return input;
    }
    fn path(self: *Workspace, scanner: *std.json.Scanner) Error![]const u8 {
        const start = self.path_count;
        const capacity = @min(types.limits.module_path_bytes, self.paths.len - start);
        self.path_count += try string(scanner, self.paths[start..][0..capacity]);
        return self.paths[start..self.path_count];
    }
};

fn peek(scanner: *std.json.Scanner) Error!std.json.TokenType {
    return scanner.peekNextTokenType() catch return error.InvalidBundle;
}
fn next(scanner: *std.json.Scanner) Error!std.json.Token {
    return scanner.next() catch return error.InvalidBundle;
}
fn append(destination: []u8, length: *usize, bytes: []const u8) Error!void {
    if (bytes.len > destination.len - length.*) return error.BundleLimit;
    @memcpy(destination[length.*..][0..bytes.len], bytes);
    length.* += bytes.len;
}
fn string(scanner: *std.json.Scanner, destination: []u8) Error!usize {
    var length: usize = 0;
    while (true) switch (try next(scanner)) {
        .string => |bytes| {
            try append(destination, &length, bytes);
            return length;
        },
        .partial_string => |bytes| try append(destination, &length, bytes),
        .partial_string_escaped_1 => |bytes| try append(destination, &length, &bytes),
        .partial_string_escaped_2 => |bytes| try append(destination, &length, &bytes),
        .partial_string_escaped_3 => |bytes| try append(destination, &length, &bytes),
        .partial_string_escaped_4 => |bytes| try append(destination, &length, &bytes),
        else => return error.InvalidBundle,
    };
}

test "bundle packets reject unknown duplicate missing and wrong-shaped fields and recover" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const good = "{\"root\":\"main.forb\",\"modules\":[{\"source\":\"A:string=\\\"\\u03bb\\\"\\n\",\"path\":\"main.forb\"}]}";
    const result = try workspace.parse(good);
    try std.testing.expectEqualStrings("main.forb", result.root);
    try std.testing.expectEqualStrings("A:string=\"λ\"\n", result.modules[0].source);
    for ([_][]const u8{
        "{}",                                                                              "{\"root\":\"x\"}",                                                            "{\"root\":\"x\",\"root\":\"x\",\"modules\":[]}",
        "{\"root\":\"x\",\"modules\":[],\"extra\":0}",                                     "{\"root\":[],\"modules\":[]}",                                                "{\"root\":\"x\",\"modules\":[{\"path\":\"x\"}]}",
        "{\"root\":\"x\",\"modules\":[{\"path\":\"x\",\"source\":\"\",\"source\":\"\"}]}", "{\"root\":\"x\",\"modules\":[{\"path\":\"x\",\"source\":\"\",\"extra\":0}]}", "{\"root\":\"x\",\"modules\":[{\"path\":\"x\",\"source\":{}}]}",
        "{\"root\":\"x\",\"modules\":[]} false",                                           "{\"root\":\"\\ud800\",\"modules\":[]}",
    }) |bad| {
        try std.testing.expectError(error.InvalidBundle, workspace.parse(bad));
        _ = try workspace.parse(good);
    }
}

test "bundle packet decoded pools inventory and serialized caps are exact and reusable" {
    const workspace = try scratch.storage(Workspace);
    defer scratch.release(workspace);
    scratch.initialise(workspace);
    const buffer = try std.testing.allocator.alloc(u8, max_packet_bytes + 1);
    defer std.testing.allocator.free(buffer);
    var out = std.Io.Writer.fixed(buffer);
    try out.writeAll("{\"root\":\"x\",\"modules\":[{\"path\":\"x\",\"source\":\"");
    // An escaped byte charges one decoded byte, not six serialized bytes.
    for (0..types.limits.source_bytes) |_| try out.writeAll("\\u0061");
    const end = out.end;
    try out.writeAll("\"}]}");
    const exact = try workspace.parse(out.buffered());
    try std.testing.expectEqual(@as(usize, types.limits.source_bytes), exact.modules[0].source.len);
    try std.testing.expectEqualStrings("aaaa", exact.modules[0].source[0..4]);
    out.end = end;
    try out.writeAll("a\"}]}");
    try std.testing.expectError(error.BundleLimit, workspace.parse(out.buffered()));
    for ([_]usize{ types.limits.modules, types.limits.modules + 1 }) |count| {
        out = .fixed(buffer);
        try out.writeAll("{\"root\":\"");
        try out.splatByteAll('r', types.limits.module_path_bytes);
        try out.writeAll("\",\"modules\":[");
        for (0..count) |index| {
            if (index != 0) try out.writeByte(',');
            try out.writeAll("{\"path\":\"");
            try out.splatByteAll('p', types.limits.module_path_bytes);
            try out.writeAll("\",\"source\":\"\"}");
        }
        try out.writeAll("]}");
        if (count == types.limits.modules) {
            const result = try workspace.parse(out.buffered());
            try std.testing.expectEqual(count, result.modules.len);
            try std.testing.expectEqual(@as(usize, types.limits.module_paths_bytes + types.limits.module_path_bytes), workspace.path_count);
        } else try std.testing.expectError(error.BundleLimit, workspace.parse(out.buffered()));
    }
    // RFC-0093: a folder tree, whose root is a module path, may list `module_files` files.
    for ([_]usize{ types.limits.module_files, types.limits.module_files + 1 }) |count| {
        out = .fixed(buffer);
        try out.writeAll("{\"root\":\"/");
        try out.splatByteAll('r', types.limits.module_path_bytes - 1);
        try out.writeAll("\",\"modules\":[");
        for (0..count) |index| {
            if (index != 0) try out.writeByte(',');
            try out.writeAll("{\"path\":\"");
            try out.splatByteAll('p', types.limits.module_path_bytes);
            try out.writeAll("\",\"source\":\"\"}");
        }
        try out.writeAll("]}");
        if (count == types.limits.module_files) {
            const result = try workspace.parse(out.buffered());
            try std.testing.expectEqual(count, result.modules.len);
            try std.testing.expectEqual(@as(usize, workspace.paths.len), workspace.path_count);
        } else try std.testing.expectError(error.BundleLimit, workspace.parse(out.buffered()));
    }
    out = .fixed(buffer);
    try out.writeAll("{\"root\":\"");
    try out.splatByteAll('r', types.limits.module_path_bytes + 1);
    try out.writeAll("\",\"modules\":[]}");
    try std.testing.expectError(error.BundleLimit, workspace.parse(out.buffered()));
    out = .fixed(buffer);
    try out.writeAll("{\"root\":\"x\",\"modules\":[]}");
    try out.splatByteAll(' ', max_packet_bytes - out.end);
    _ = try workspace.parse(out.buffered());
    try out.writeByte(' ');
    try std.testing.expectError(error.BundleLimit, workspace.parse(out.buffered()));
    _ = try workspace.parse("{\"root\":\"x\",\"modules\":[{\"path\":\"x\",\"source\":\"Value:i64=7\"}]}");
    try std.testing.expectEqual(@as(usize, 1), workspace.input_count);
    try std.testing.expectEqualStrings("Value:i64=7", workspace.inputs[0].source);
}
