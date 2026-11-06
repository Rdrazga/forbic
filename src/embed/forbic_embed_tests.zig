//! TASK-0109, W4.4: tests of the embedding API (`forbic_embed.zig`).
const std = @import("std");
const embed = @import("forbic_embed.zig");
const forbic_host = @import("forbic_host").command;
const forbic_host_project = @import("forbic_host").project;
const native = embed.native;

const testing = std.testing;

/// A host's table: rates by region, in basis points.
const Rates = struct { eu: i64, us: i64 };
/// Another type with the same layout, which a native must not read as `Rates`.
const Fees = struct { eu: i64, us: i64 };

fn rate(context: *native.Context, region: []const u8) ?i64 {
    const rates = context.hostContext(Rates) orelse return null;
    if (std.mem.eql(u8, region, "EU")) return rates.eu;
    if (std.mem.eql(u8, region, "US")) return rates.us;
    return null;
}
/// The same signature, reading the context as another type: it finds none.
fn fee(context: *native.Context, region: []const u8) ?i64 {
    const fees = context.hostContext(Fees) orelse return null;
    return if (std.mem.eql(u8, region, "EU")) fees.eu else null;
}
fn double(_: *native.Context, value: i64) i64 {
    return value *% 2;
}
fn triple(_: *native.Context, value: i64) i64 {
    return value *% 3;
}
fn half(_: *native.Context, value: f64) f64 {
    return value / 2;
}
/// An output native must return nothing: this one is refused.
fn loud(_: *native.Context, value: i64) i64 {
    return value;
}

/// The storage of a table with room for the host's natives.
const Table = struct {
    storage: [embed.standard_natives + 4]native.Entry = undefined,
    natives: embed.Natives = undefined,

    fn init(self: *Table) !void {
        self.natives = try embed.Natives.init(&self.storage);
    }
};

const Bench = struct {
    compiler: *embed.Compiler,
    worker: *embed.Worker,

    fn create() !Bench {
        const compiler = try embed.Compiler.create(testing.allocator);
        errdefer compiler.destroy();
        return .{ .compiler = compiler, .worker = try embed.Worker.create(testing.allocator) };
    }
    fn destroy(self: Bench) void {
        self.compiler.destroy();
        self.worker.destroy();
    }
    /// Compiles and prepares `text`; the program is the caller's.
    fn program(self: Bench, text: []const u8, natives: ?*const embed.Natives) !*embed.Program {
        const compiled = try self.compiler.compile(.{ .text = .{ .name = "test.forb", .bytes = text } }, .{ .natives = natives });
        const compilation = switch (compiled) {
            .ok => |compilation| compilation,
            .failed => |failure| {
                var buffer: [512]u8 = undefined;
                var out: std.Io.Writer = .fixed(&buffer);
                try failure.write(&out, .plain);
                std.debug.print("unexpected failure: {s}", .{out.buffered()});
                return error.TestUnexpectedResult;
            },
        };
        return switch (try embed.prepare(testing.allocator, compilation)) {
            .ok => |made| made,
            .refused => error.TestUnexpectedResult,
        };
    }
};

fn integer(completed: embed.Completed, name: []const u8) !i64 {
    const found = (try completed.value(name)) orelse return error.TestUnexpectedResult;
    return switch (found) {
        .integer => |value| value,
        else => error.TestUnexpectedResult,
    };
}

fn completedOf(outcome: embed.Outcome) !embed.Completed {
    return switch (outcome) {
        .completed => |completed| completed,
        .failed => |diagnostic| {
            std.debug.print("run failed: {t} {s}\n", .{ diagnostic.code(), diagnostic.message() });
            return error.TestUnexpectedResult;
        },
    };
}

test "a native table starts with the standard natives and refuses what it cannot hold or call" {
    var tiny: [1]native.Entry = undefined;
    try testing.expectError(error.StorageTooSmall, embed.Natives.init(&tiny));
    const huge = try testing.allocator.alloc(native.Entry, embed.max_natives + 1);
    defer testing.allocator.free(huge);
    try testing.expectError(error.StorageTooLarge, embed.Natives.init(huge));

    var storage: [embed.standard_natives + 2]native.Entry = undefined;
    var natives = try embed.Natives.init(&storage);
    try testing.expectEqual(@as(usize, embed.standard_natives), natives.table().len);
    try testing.expectEqualStrings(embed.forbic.native_std.table[0].id, natives.table()[0].id);
    const rates: Rates = .{ .eu = 2000, .us = 700 };
    try natives.registerWith(Rates, &rates, native.entry("test.rate", rate, .{}));
    // A name is held once, the standard ones' included.
    try testing.expectError(error.DuplicateNative, natives.register(native.entry("test.rate", double, .{})));
    try testing.expectError(error.DuplicateNative, natives.register(native.entry("std.sum", double, .{})));
    // An entry the machines would not admit: an action that returns a value, or a bad name.
    try testing.expectError(error.InvalidNative, natives.register(native.effectEntry("test.loud", loud, .{}, .output)));
    try testing.expectError(error.InvalidNative, natives.register(native.entry("", double, .{})));
    try testing.expectError(error.InvalidNative, natives.register(native.entry("test.\xff", double, .{})));
    // A host context is given by `registerWith` only, once.
    var carried = native.entry("test.carried", double, .{});
    carried.host = .{ .pointer = &rates, .type_name = @typeName(Rates) };
    try testing.expectError(error.InvalidNative, natives.register(carried));
    try testing.expectError(error.InvalidNative, natives.registerWith(Rates, &rates, carried));
    try natives.register(native.entry("test.double", double, .{}));
    try testing.expectError(error.TooManyNatives, natives.register(native.entry("test.triple", triple, .{})));
    // Refusals change nothing.
    try testing.expectEqual(@as(usize, embed.standard_natives + 2), natives.table().len);
    try testing.expectEqualStrings("test.double", natives.table()[embed.standard_natives + 1].id);
}

test "a native reads the host context it was registered with, in the run and in its replayed report" {
    const bench = try Bench.create();
    defer bench.destroy();
    var table: Table = .{};
    try table.init();
    const rates: Rates = .{ .eu = 2000, .us = 700 };
    const fees: Fees = .{ .eu = 5, .us = 6 };
    try table.natives.registerWith(Rates, &rates, native.entry("test.rate", rate, .{}));
    try table.natives.registerWith(Rates, &rates, native.entry("test.fee", fee, .{}));
    const text =
        \\Rate := native{"test.rate"}
        \\Fee := native{"test.fee"}
        \\Eu<public>:i64 = Or(Rate("EU"), -1)
        \\Us<public>:i64 = Or(Rate("US"), -1)
        \\Mars<public>:i64 = Or(Rate("Mars"), -1)
        \\Wrong<public>:i64 = Or(Fee("EU"), -1)
    ;
    const program = try bench.program(text, &table.natives);
    defer program.destroy();
    for ([_]embed.TraceMode{ .full, .digest, .off }) |trace| {
        const completed = try completedOf(try program.run(bench.worker, .{ .trace = trace }));
        try testing.expectEqual(@as(i64, 2000), try integer(completed, "Eu"));
        try testing.expectEqual(@as(i64, 700), try integer(completed, "Us"));
        try testing.expectEqual(@as(i64, -1), try integer(completed, "Mars"));
        // A context of another type is no context.
        try testing.expectEqual(@as(i64, -1), try integer(completed, "Wrong"));
        if (trace == .off) continue;
        // The report calls the native again, with the same context, and agrees.
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try completed.writeValues(&out);
        try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"Eu\":2000,\"Us\":700,\"Mars\":-1,\"Wrong\":-1}") != null);
    }
    _ = fees;
    // Another table of the same natives, whose context is another value, gives another answer,
    // and is the same program by identity: a cache tells them apart by the context's address.
    var other: Table = .{};
    try other.init();
    const higher: Rates = .{ .eu = 2100, .us = 800 };
    try other.natives.registerWith(Rates, &higher, native.entry("test.rate", rate, .{}));
    try other.natives.registerWith(Rates, &higher, native.entry("test.fee", fee, .{}));
    const again = try bench.program(text, &other.natives);
    defer again.destroy();
    try testing.expect(again.identity().eql(program.identity()));
    const completed = try completedOf(try again.run(bench.worker, .{}));
    try testing.expectEqual(@as(i64, 2100), try integer(completed, "Eu"));
}

test "a program that calls a native against its signature is refused when it compiles" {
    const bench = try Bench.create();
    defer bench.destroy();
    var table: Table = .{};
    try table.init();
    const rates: Rates = .{ .eu = 1, .us = 2 };
    try table.natives.registerWith(Rates, &rates, native.entry("test.rate", rate, .{}));
    const Case = struct { text: []const u8, code: embed.Code };
    for ([_]Case{
        .{ .text = "Rate := native{\"test.rate\"}\nX:i64 = Or(Rate(1), 0)\n", .code = .type_mismatch },
        .{ .text = "Rate := native{\"test.rate\"}\nX:i64 = Or(Rate(\"EU\", \"US\"), 0)\n", .code = .argument_count },
        .{ .text = "Rate := native{\"test.rate\"}\nX:string = Rate(\"EU\")\n", .code = .type_mismatch },
        .{ .text = "Missing := native{\"test.missing\"}\n", .code = .unknown_native },
    }) |case| {
        const compiled = try bench.compiler.compile(.{ .text = .{ .name = "wrong.forb", .bytes = case.text } }, .{ .natives = &table.natives });
        try testing.expectEqual(@as(?embed.Code, case.code), compiled.failed.code());
    }
    // Without the table the program names a native the standard table does not have.
    const compiled = try bench.compiler.compile(.{ .text = .{ .name = "wrong.forb", .bytes = "Rate := native{\"test.rate\"}\n" } }, .{});
    try testing.expectEqual(@as(?embed.Code, .unknown_native), compiled.failed.code());
}

/// A temporary directory with the absolute path of each name in it.
const Directory = struct {
    temporary: std.testing.TmpDir,
    at: [std.Io.Dir.max_path_bytes]u8 = undefined,
    length: usize = 0,
    paths: [8][std.Io.Dir.max_path_bytes + 32]u8 = undefined,
    used: usize = 0,

    fn create() !*Directory {
        const self = try testing.allocator.create(Directory);
        self.* = .{ .temporary = std.testing.tmpDir(.{}) };
        self.length = try self.temporary.dir.realPath(testing.io, &self.at);
        return self;
    }
    fn destroy(self: *Directory) void {
        self.temporary.cleanup();
        testing.allocator.destroy(self);
    }
    fn write(self: *Directory, name: []const u8, data: []const u8) !void {
        try self.temporary.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }
    fn path(self: *Directory, name: []const u8) ![:0]const u8 {
        defer self.used += 1;
        return std.mem.printSentinel(&self.paths[self.used], "{s}/{s}", .{ self.at[0..self.length], name }, 0);
    }
};

test "a program compiles from text, a file, a packet, a packet file, files and a folder tree" {
    const bench = try Bench.create();
    defer bench.destroy();
    const directory = try Directory.create();
    defer directory.destroy();
    try directory.write("main.forb", "Base<public>:i64 = 20\nTotal<public>:i64 = Base * 2 + 2\n");
    const packet =
        \\{"root": "main.forb", "modules": [{"path": "main.forb", "source": "Lib := import{\"lib.forb\"}\nTotal<public>:i64 = Lib.Base * 2 + 2\n"}, {"path": "lib.forb", "source": "Base<public>:i64 = 20\n"}]}
    ;
    try directory.write("bundle.json", packet);
    const files = [_]embed.File{
        .{ .path = "main.forb", .source = "Lib := import{\"lib.forb\"}\nTotal<public>:i64 = Lib.Base * 2 + 2\n" },
        .{ .path = "lib.forb", .source = "Base<public>:i64 = 20\n" },
    };
    // A folder tree: the two files of the App folder are one module, in the order of their names.
    const folder = [_]embed.File{
        .{ .path = "test@example.com/App/a.forb", .source = "Base<public>:i64 = 20\n" },
        .{ .path = "test@example.com/App/b.forb", .source = "Total<public>:i64 = Base * 2 + 2\n" },
    };
    const sources = [_]embed.Source{
        .{ .text = .{ .name = "main.forb", .bytes = "Base<public>:i64 = 20\nTotal<public>:i64 = Base * 2 + 2\n" } },
        .{ .file = .{ .io = testing.io, .path = try directory.path("main.forb") } },
        .{ .packet = .{ .name = "bundle.json", .bytes = packet } },
        .{ .packet_file = .{ .io = testing.io, .path = try directory.path("bundle.json") } },
        .{ .files = .{ .root = "main.forb", .files = &files } },
        .{ .files = .{ .root = "/test@example.com/App", .files = &folder } },
    };
    for (sources) |source| {
        const compiled = try bench.compiler.compile(source, .{});
        const program = switch (try embed.prepare(testing.allocator, compiled.ok)) {
            .ok => |program| program,
            .refused => return error.TestUnexpectedResult,
        };
        defer program.destroy();
        const completed = try completedOf(try program.run(bench.worker, .{}));
        try testing.expectEqual(@as(i64, 42), try integer(completed, "Total"));
    }
    // A packet and the same files are one program.
    const from_packet = (try bench.compiler.compile(sources[2], .{})).ok.identity;
    const from_files = (try bench.compiler.compile(sources[4], .{})).ok.identity;
    try testing.expect(from_packet.eql(from_files));
}

test "a source that does not compile is a failure value, written as the forbic tool writes it" {
    const bench = try Bench.create();
    defer bench.destroy();
    const directory = try Directory.create();
    defer directory.destroy();
    try directory.write("bad.forb", "A:i64 = 1\nValue:i64 = Missing + 1\n");
    try directory.write("bad.json", "{\"root\": 1}");
    const bad = try directory.path("bad.forb");
    const missing = try directory.path("missing.forb");
    const bad_packet = try directory.path("bad.json");
    // `dispatch` uses only `io` of the process state on these paths.
    const init: std.process.Init = .{ .minimal = undefined, .arena = undefined, .gpa = testing.allocator, .io = testing.io, .environ_map = undefined, .preopens = undefined };
    const Case = struct { source: embed.Source, args: []const [:0]const u8, style: embed.Style, code: ?embed.Code };
    for ([_]Case{
        .{ .source = .{ .file = .{ .io = testing.io, .path = bad } }, .args = &.{ "forbic", "check", bad }, .style = .plain, .code = .unknown_name },
        .{ .source = .{ .file = .{ .io = testing.io, .path = bad } }, .args = &.{ "forbic", "check", bad, "--diagnostics=excerpt" }, .style = .excerpt, .code = .unknown_name },
        .{ .source = .{ .file = .{ .io = testing.io, .path = missing } }, .args = &.{ "forbic", "check", missing }, .style = .plain, .code = null },
        .{ .source = .{ .packet_file = .{ .io = testing.io, .path = bad_packet } }, .args = &.{ "forbic", "check", bad_packet, "--bundle" }, .style = .plain, .code = null },
    }) |case| {
        var expected_bytes: [1024]u8 = undefined;
        var unused_bytes: [64]u8 = undefined;
        var expected: std.Io.Writer = .fixed(&expected_bytes);
        var unused: std.Io.Writer = .fixed(&unused_bytes);
        try testing.expectEqual(@as(u8, 1), try forbic_host.dispatch(init, case.args, &unused, &expected));
        const compiled = try bench.compiler.compile(case.source, .{});
        var actual_bytes: [1024]u8 = undefined;
        var actual: std.Io.Writer = .fixed(&actual_bytes);
        try compiled.failed.write(&actual, case.style);
        try testing.expectEqualStrings(expected.buffered(), actual.buffered());
        try testing.expectEqual(case.code, compiled.failed.code());
    }
    const compiled = try bench.compiler.compile(.{ .file = .{ .io = testing.io, .path = bad } }, .{});
    const diagnostic = compiled.failed.diagnostic;
    try testing.expectEqual(@as(u32, 2), diagnostic.location().line);
    try testing.expectEqual(@as(u32, 13), diagnostic.location().column);
    try testing.expectEqualStrings("name must refer to a parameter or earlier declaration", diagnostic.message());
    try testing.expectEqualStrings("FileNotFound", (try bench.compiler.compile(.{ .file = .{ .io = testing.io, .path = missing } }, .{})).failed.unreadable.reason);
    try testing.expectEqualStrings("InvalidBundle", (try bench.compiler.compile(.{ .packet = .{ .name = "p", .bytes = "[]" } }, .{})).failed.invalid_bundle.reason);
}

test "a program is prepared from its compiler's last compile only, and owns what it holds" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text = try testing.allocator.dupe(u8, "Value<public>:i64 = 6 * 7\n");
    defer testing.allocator.free(text);
    const first = (try bench.compiler.compile(.{ .text = .{ .name = "first.forb", .bytes = text } }, .{})).ok;
    try testing.expect(first.current());
    _ = (try bench.compiler.compile(.{ .text = .{ .name = "second.forb", .bytes = "Other<public>:i64 = 1\n" } }, .{})).ok;
    try testing.expect(!first.current());
    try testing.expectError(error.StaleCompilation, embed.prepare(testing.allocator, first));
    // An identity is a use of the compiler too: it reads into the same buffers.
    const identified = (try bench.compiler.compile(.{ .text = .{ .name = "first.forb", .bytes = text } }, .{})).ok;
    _ = (try bench.compiler.identify(.{ .text = .{ .name = "second.forb", .bytes = "Other<public>:i64 = 1\n" } }, .{})).ok;
    try testing.expect(!identified.current());
    try testing.expectError(error.StaleCompilation, embed.prepare(testing.allocator, identified));
    const compilation = (try bench.compiler.compile(.{ .text = .{ .name = "first.forb", .bytes = text } }, .{})).ok;
    const program = (try embed.prepare(testing.allocator, compilation)).ok;
    defer program.destroy();
    try testing.expectEqualStrings("first.forb", program.name());
    try testing.expect(program.bytes() > text.len);
    // Neither the host's bytes nor the compiler's next compile reach the program.
    @memset(text, ' ');
    _ = try bench.compiler.compile(.{ .text = .{ .name = "third.forb", .bytes = "Value<public>:i64 = 1\n" } }, .{});
    const completed = try completedOf(try program.run(bench.worker, .{}));
    try testing.expectEqual(@as(i64, 42), try integer(completed, "Value"));
    // A compilation a host altered so that it no longer admits is refused by a machine, and
    // nothing is kept.
    var forged = (try bench.compiler.compile(.{ .text = .{ .name = "forged.forb", .bytes = "Value<public>:i64 = 6 * 7\n" } }, .{})).ok;
    var bindings: [1]embed.forbic.types.Binding = .{forged.program.bindings[0]};
    bindings[0].node = std.math.maxInt(u32);
    forged.program.bindings = &bindings;
    const refusal = (try embed.prepare(testing.allocator, forged)).refused;
    try testing.expectEqual(embed.Code.invalid_ir, refusal.diagnostic.code());
}

/// A source as a host holds it that frees or reuses its buffers once `compile` returns: every
/// byte, and the list of files, in memory of its own, which `spoil` overwrites.
const Lent = struct {
    arena: std.heap.ArenaAllocator,
    spoiled: [16][]u8 = undefined,
    count: usize = 0,

    fn init() Lent {
        return .{ .arena = .init(testing.allocator) };
    }
    fn deinit(self: *Lent) void {
        self.arena.deinit();
    }
    fn held(self: *Lent, made: []u8) void {
        std.debug.assert(self.count < self.spoiled.len);
        self.spoiled[self.count] = made;
        self.count += 1;
    }
    fn bytes(self: *Lent, data: []const u8) ![]const u8 {
        const made = try self.arena.allocator().dupe(u8, data);
        self.held(made);
        return made;
    }
    fn path(self: *Lent, data: []const u8) ![:0]const u8 {
        const made = try self.arena.allocator().dupeSentinel(u8, data, 0);
        self.held(made);
        return made;
    }
    fn files(self: *Lent, list: []const embed.File) ![]const embed.File {
        const made = try self.arena.allocator().alloc(embed.File, list.len);
        for (list, made) |file, *copy| copy.* = .{ .path = try self.bytes(file.path), .source = try self.bytes(file.source) };
        self.held(std.mem.sliceAsBytes(made));
        return made;
    }
    /// What a host may do with its buffers once `compile` returns (s6-1).
    fn spoil(self: *Lent) void {
        for (self.spoiled[0..self.count]) |made| @memset(made, 0xAA);
    }
};

test "a compilation keeps its own copy of its source: the host's buffers are the host's again once compile returns" {
    const bench = try Bench.create();
    defer bench.destroy();
    const directory = try Directory.create();
    defer directory.destroy();
    const single = "Base<public>:i64 = 20\nTotal<public>:i64 = Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n";
    const packet =
        \\{"root": "main.forb", "modules": [{"path": "main.forb", "source": "Lib := import{\"lib.forb\"}\nTotal<public>:i64 = Lib.Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n"}, {"path": "lib.forb", "source": "Base<public>:i64 = 20\n"}]}
    ;
    const files = [_]embed.File{
        .{ .path = "main.forb", .source = "Lib := import{\"lib.forb\"}\nTotal<public>:i64 = Lib.Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n" },
        .{ .path = "lib.forb", .source = "Base<public>:i64 = 20\n" },
    };
    const folder = [_]embed.File{
        .{ .path = "test@example.com/App/a.forb", .source = "Base<public>:i64 = 20\n" },
        .{ .path = "test@example.com/App/b.forb", .source = "Total<public>:i64 = Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n" },
    };
    try directory.write("main.forb", single);
    try directory.write("bundle.json", packet);
    const main_path = try directory.path("main.forb");
    const bundle_path = try directory.path("bundle.json");
    const names = [_][]const u8{ "main.forb", main_path, "bundle.json", bundle_path, "main.forb", "/test@example.com/App" };
    for (names, 0..) |name, case| {
        var lent: Lent = .init();
        defer lent.deinit();
        const source: embed.Source = switch (case) {
            0 => .{ .text = .{ .name = try lent.bytes(name), .bytes = try lent.bytes(single) } },
            1 => .{ .file = .{ .io = testing.io, .path = try lent.path(name) } },
            2 => .{ .packet = .{ .name = try lent.bytes(name), .bytes = try lent.bytes(packet) } },
            3 => .{ .packet_file = .{ .io = testing.io, .path = try lent.path(name) } },
            4 => .{ .files = .{ .root = try lent.bytes(name), .files = try lent.files(&files) } },
            else => .{ .files = .{ .root = try lent.bytes(name), .files = try lent.files(&folder) } },
        };
        const identity = (try bench.compiler.identify(source, .{})).ok;
        const compilation = (try bench.compiler.compile(source, .{})).ok;
        lent.spoil();
        try testing.expectEqualStrings(name, compilation.name());
        const program = (try embed.prepare(testing.allocator, compilation)).ok;
        defer program.destroy();
        try testing.expect(program.identity().eql(identity));
        try testing.expectEqualStrings(name, program.name());
        var output_bytes: [64]u8 = undefined;
        var output: std.Io.Writer = .fixed(&output_bytes);
        const completed = try completedOf(try program.run(bench.worker, .{ .output = &output }));
        try testing.expectEqual(@as(i64, 42), try integer(completed, "Total"));
        try testing.expectEqualStrings("total 42\n", output.buffered());
        // A durable run compiles again the bytes whose identity it records: the ones compiled.
        var message_bytes: [256]u8 = undefined;
        var messages: std.Io.Writer = .fixed(&message_bytes);
        var state_bytes: [16]u8 = undefined;
        const state = try directory.path(try std.fmt.bufPrint(&state_bytes, "state{d}", .{case}));
        output = .fixed(&output_bytes);
        try testing.expectEqual(embed.DurableOutcome.completed, try program.runDurable(testing.io, testing.allocator, .{ .state = state, .output = &output, .messages = &messages }, null));
        try testing.expectEqualStrings("", messages.buffered());
        try testing.expectEqualStrings("total 42\n", output.buffered());
    }
}

test "a failure keeps its own copy of what it points into: the host's buffers are the host's again once compile returns" {
    const bench = try Bench.create();
    defer bench.destroy();
    const files = [_]embed.File{
        .{ .path = "main.forb", .source = "Lib := import{\"lib.forb\"}\nTotal<public>:i64 = Lib.Missing + 1\n" },
        .{ .path = "lib.forb", .source = "Base<public>:i64 = 20\n" },
    };
    const folder = [_]embed.File{
        .{ .path = "test@example.com/App/a.forb", .source = "Base<public>:i64 = 20\n" },
        .{ .path = "test@example.com/App/b.forb", .source = "Total<public>:i64 = Base * 2 +\n" },
    };
    for (0..5) |case| {
        var lent: Lent = .init();
        defer lent.deinit();
        const source: embed.Source = switch (case) {
            0 => .{ .text = .{ .name = try lent.bytes("bad.forb"), .bytes = try lent.bytes("A:i64 = 1\nValue:i64 = Missing + 1\n") } },
            1 => .{ .file = .{ .io = testing.io, .path = try lent.path("no/such/file.forb") } },
            2 => .{ .packet = .{ .name = try lent.bytes("bad.json"), .bytes = try lent.bytes("[]") } },
            3 => .{ .files = .{ .root = try lent.bytes("main.forb"), .files = try lent.files(&files) } },
            else => .{ .files = .{ .root = try lent.bytes("/test@example.com/App"), .files = try lent.files(&folder) } },
        };
        const failure = (try bench.compiler.compile(source, .{})).failed;
        var before_bytes: [512]u8 = undefined;
        var before: std.Io.Writer = .fixed(&before_bytes);
        try failure.write(&before, .plain);
        try failure.write(&before, .excerpt);
        lent.spoil();
        var after_bytes: [512]u8 = undefined;
        var after: std.Io.Writer = .fixed(&after_bytes);
        try failure.write(&after, .plain);
        try failure.write(&after, .excerpt);
        try testing.expectEqualStrings(before.buffered(), after.buffered());
        try testing.expect(std.mem.indexOfScalar(u8, after.buffered(), 0xAA) == null);
    }
}

test "a source larger than the profile allows is refused before more of it is copied" {
    const bench = try Bench.create();
    defer bench.destroy();
    const limits = embed.forbic.types.limits;
    // A text: the lexer's refusal, at its start, pointing into the part the profile holds.
    const long = try testing.allocator.alloc(u8, limits.source_bytes + 1);
    defer testing.allocator.free(long);
    @memset(long, ' ');
    @memcpy(long[0..10], "A:i64 = 1\n");
    for ([_]bool{ false, true }) |identifying| {
        const failure = if (identifying)
            (try bench.compiler.identify(.{ .text = .{ .name = "long.forb", .bytes = long } }, .{})).failed
        else
            (try bench.compiler.compile(.{ .text = .{ .name = "long.forb", .bytes = long } }, .{})).failed;
        try testing.expectEqual(@as(?embed.Code, .source_limit), failure.code());
        try testing.expectEqual(@as(u32, 1), failure.diagnostic.location().line);
        try testing.expectEqual(@as(u32, 1), failure.diagnostic.location().column);
        try testing.expectEqual(limits.source_bytes, failure.diagnostic.source.len);
        try testing.expectEqual("long.forb".len + limits.source_bytes, bench.compiler.kept.len);
    }
    // A packet: `BundleLimit`, as its parse says, with only its name copied.
    const packet = try testing.allocator.alloc(u8, embed.forbic.bundle_packet.max_packet_bytes + 1);
    defer testing.allocator.free(packet);
    @memset(packet, ' ');
    const refused = (try bench.compiler.compile(.{ .packet = .{ .name = "long.json", .bytes = packet } }, .{})).failed;
    try testing.expectEqualStrings("BundleLimit", refused.invalid_bundle.reason);
    try testing.expectEqualStrings("long.json", refused.invalid_bundle.name);
    try testing.expectEqual("long.json".len, bench.compiler.kept.len);
    // Files: more of them, or more bytes of sources, than any bundle that compiles holds.
    const many = try testing.allocator.alloc(embed.File, @max(limits.modules, limits.module_files) + 1);
    defer testing.allocator.free(many);
    for (many) |*file| file.* = .{ .path = "a.forb", .source = "" };
    const tall = [_]embed.File{ .{ .path = "main.forb", .source = long[0 .. limits.source_bytes / 2 + 1] }, .{ .path = "lib.forb", .source = long[0 .. limits.source_bytes / 2] } };
    for ([_][]const embed.File{ many, &tall }) |list| {
        const failure = (try bench.compiler.compile(.{ .files = .{ .root = "main.forb", .files = list } }, .{})).failed;
        try testing.expectEqualStrings("BundleLimit", failure.invalid_bundle.reason);
        try testing.expectEqualStrings("main.forb", failure.invalid_bundle.name);
        try testing.expectEqual(@as(usize, 0), bench.compiler.kept_files.len);
    }
    // At the bounds a bundle is the compiler's to judge.
    const full = [_]embed.File{ .{ .path = "main.forb", .source = long[0 .. limits.source_bytes / 2] }, .{ .path = "lib.forb", .source = long[0 .. limits.source_bytes / 2] } };
    const judged = try bench.compiler.compile(.{ .files = .{ .root = "main.forb", .files = &full } }, .{});
    try testing.expect(judged == .ok or judged.failed == .diagnostic);
    try testing.expectEqual(@as(usize, 2), bench.compiler.kept_files.len);
}

test "a compile that runs out of memory while it copies its source keeps nothing" {
    const files = [_]embed.File{
        .{ .path = "main.forb", .source = "Lib := import{\"lib.forb\"}\nTotal<public>:i64 = Lib.Base * 2 + 2\n" },
        .{ .path = "lib.forb", .source = "Base<public>:i64 = 20\n" },
    };
    const sources = [_]embed.Source{
        .{ .text = .{ .name = "main.forb", .bytes = "Total<public>:i64 = 42\n" } },
        .{ .files = .{ .root = "main.forb", .files = &files } },
    };
    // The compiler itself is the first allocation; the files' bytes, then their list, follow.
    for ([_]usize{ 1, 1, 2 }, [_]usize{ 0, 1, 1 }) |fail_index, which| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const compiler = try embed.Compiler.create(failing.allocator());
        defer compiler.destroy();
        try testing.expectError(error.OutOfMemory, compiler.compile(sources[which], .{}));
        try testing.expectEqual(@as(usize, 0), compiler.kept.len);
        try testing.expectEqual(@as(usize, 0), compiler.kept_files.len);
    }
    // With memory, the same compiler compiles them.
    const compiler = try embed.Compiler.create(testing.allocator);
    defer compiler.destroy();
    for (sources) |source| try testing.expect((try compiler.compile(source, .{})) == .ok);
}

const effects_text =
    \\Line(R:reader)<transacts>:string = Attempt(R.ReadLine[], "<end>")
    \\First<public>:string = Attempt(Block{ R := OpenReader["in"]; Line(R) }, "")
    \\Second<public>:string = Attempt(Block{ R := OpenReader["in"]; Line(R) }, "")
    \\Wrote<public>:i64 = Attempt(Block{ W := OpenWriter["log"]; W.WriteLine("got {First}"); Print("shown"); 1 }, 0)
    \\Lost<public>:i64 = Attempt(Block{ Print("never"); Require[false]; 1 }, 0)
    \\Die<public>:i64 = GetRandomInt(1, 1000000)
    \\Now<public>:float = GetSecondsSinceEpoch()
    \\Keyed<public>:logic = Attempt(Block{ K := GetPersistentKey["alice"]; true }, false)
;

test "a run is given its readers, writers, keys, seed, clock and fuel, and gives back its values and lines" {
    const bench = try Bench.create();
    defer bench.destroy();
    const program = try bench.program(effects_text, null);
    defer program.destroy();
    var dice: [2]i64 = undefined;
    for (0..2) |attempt| {
        var lines: std.Io.Reader = .fixed("alpha\nbeta\n");
        var log_bytes: [64]u8 = undefined;
        var log: std.Io.Writer = .fixed(&log_bytes);
        var output_bytes: [64]u8 = undefined;
        var output: std.Io.Writer = .fixed(&output_bytes);
        const completed = try completedOf(try program.run(bench.worker, .{
            .seed = 7,
            .clock = .{ .start = 1700000000 },
            .grants = &.{ .{ .reader = .{ .name = "in", .from = &lines } }, .{ .writer = .{ .name = "log", .to = &log } }, .{ .key = "alice" } },
            .output = &output,
        }));
        try testing.expectEqualStrings("alpha", (try completed.value("First")).?.string);
        try testing.expectEqualStrings("beta", (try completed.value("Second")).?.string);
        try testing.expectEqual(@as(i64, 1), try integer(completed, "Wrote"));
        try testing.expectEqual(@as(i64, 0), try integer(completed, "Lost"));
        try testing.expectEqual(@as(f64, 1700000000), (try completed.value("Now")).?.float);
        try testing.expect((try completed.value("Keyed")).?.logic);
        try testing.expectEqual(@as(?embed.Value, null), try completed.value("Nothing"));
        // What a failed region printed is never written.
        try testing.expectEqualStrings("shown\n", output.buffered());
        try testing.expectEqualStrings("got alpha\n", log.buffered());
        dice[attempt] = try integer(completed, "Die");
        const record = try completed.effects();
        try testing.expectEqual(@as(usize, 3), record.inputs.len);
    }
    // One seed, one stream.
    try testing.expectEqual(dice[0], dice[1]);
    // Another seed, another draw; no grant, no line and no key.
    const other = try completedOf(try program.run(bench.worker, .{ .seed = 8 }));
    try testing.expect(try integer(other, "Die") != dice[0]);
    try testing.expectEqualStrings("", (try other.value("First")).?.string);
    try testing.expect(!(try other.value("Keyed")).?.logic);
    // Too little fuel ends the run, as a value.
    const starved = try program.run(bench.worker, .{ .fuel = 3 });
    try testing.expectEqual(embed.Code.work_limit, starved.failed.code());
}

test "a run's choices that cannot be are errors, checked before anything runs" {
    const bench = try Bench.create();
    defer bench.destroy();
    const program = try bench.program(effects_text, null);
    defer program.destroy();
    var lines: std.Io.Reader = .fixed("a\n");
    var sink_bytes: [16]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_bytes);
    try testing.expectError(error.InvalidTickRate, program.run(bench.worker, .{ .tick_rate = 0 }));
    try testing.expectError(error.InvalidTickRate, program.run(bench.worker, .{ .tick_rate = 1_000_001 }));
    try testing.expectError(error.InvalidClock, program.run(bench.worker, .{ .clock = .{ .start = std.math.nan(f64) } }));
    try testing.expectError(error.InvalidClock, program.run(bench.worker, .{ .clock = .{ .start = std.math.inf(f64) } }));
    try testing.expectError(error.InvalidGrants, program.run(bench.worker, .{ .grants = &.{ .{ .key = "a" }, .{ .key = "a" } } }));
    try testing.expectError(error.InvalidGrants, program.run(bench.worker, .{ .grants = &.{.{ .key = "" }} }));
    try testing.expectError(error.InvalidGrants, program.run(bench.worker, .{ .grants = &.{.{ .writer = .{ .name = "\xff", .to = &sink } }} }));
    try testing.expectError(error.SharedReader, program.run(bench.worker, .{ .grants = &.{ .{ .reader = .{ .name = "a", .from = &lines } }, .{ .reader = .{ .name = "b", .from = &lines } } } }));
    var many: [embed.grant_capacity + 1]embed.Grant = undefined;
    var names: [embed.grant_capacity + 1][8]u8 = undefined;
    for (&many, &names, 0..) |*grant, *name, index| grant.* = .{ .key = try std.fmt.bufPrint(name, "k{d}", .{index}) };
    try testing.expectError(error.InvalidGrants, program.run(bench.worker, .{ .grants = &many }));
    // The most the profile allows runs.
    _ = try completedOf(try program.run(bench.worker, .{ .grants = many[0..embed.grant_capacity] }));
    // A reader and a writer may share a name; a stream refused before the run read nothing.
    _ = try completedOf(try program.run(bench.worker, .{ .grants = &.{ .{ .reader = .{ .name = "in", .from = &lines } }, .{ .writer = .{ .name = "in", .to = &sink } } } }));
}

test "a run that ends in an error is a located diagnostic, and a writer that refuses a line ends the run" {
    const bench = try Bench.create();
    defer bench.destroy();
    const program = try bench.program("Zero:i64 = 0\nShown:tuple() = Print(\"before\")\nBad:i64 = 1 / Zero\n", null);
    defer program.destroy();
    var output_bytes: [64]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_bytes);
    const outcome = try program.run(bench.worker, .{ .output = &output });
    const diagnostic = outcome.failed;
    try testing.expectEqual(embed.Code.division_by_zero, diagnostic.code());
    try testing.expectEqual(@as(u32, 3), diagnostic.location().line);
    var text_bytes: [256]u8 = undefined;
    var text: std.Io.Writer = .fixed(&text_bytes);
    try diagnostic.write(&text, .excerpt);
    try testing.expectEqualStrings("test.forb:3:13: error: division by zero\n  3 | Bad:i64 = 1 / Zero\n    |             ^\n", text.buffered());
    // What was committed before the error has happened.
    try testing.expectEqualStrings("before\n", output.buffered());
    // A host's writer with no room for a line: the run ends where the line was committed.
    const printing = try bench.program("Shown:tuple() = Print(\"a line too long\")\n", null);
    defer printing.destroy();
    var small_bytes: [4]u8 = undefined;
    var small: std.Io.Writer = .fixed(&small_bytes);
    try testing.expectEqual(embed.Code.effect_commit_failed, (try printing.run(bench.worker, .{ .output = &small })).failed.code());
}

test "a completed run's values and reports are refused once its worker has run again" {
    const bench = try Bench.create();
    defer bench.destroy();
    const program = try bench.program("Value<public>:i64 = 6 * 7\nTwice(X:i64)<computes>:i64 = X * 2\nCalled<public>:i64 = Twice(21)\n", null);
    defer program.destroy();
    var reports: [2][2][512]u8 = undefined;
    var lengths: [2][2]usize = undefined;
    for ([_]embed.TraceMode{ .full, .digest }, 0..) |trace, index| {
        const completed = try completedOf(try program.run(bench.worker, .{ .trace = trace }));
        var values: std.Io.Writer = .fixed(&reports[index][0]);
        try completed.writeValues(&values);
        var traced: std.Io.Writer = .fixed(&reports[index][1]);
        try completed.writeTrace(&traced);
        lengths[index] = .{ values.buffered().len, traced.buffered().len };
        _ = try completedOf(try program.run(bench.worker, .{}));
        try testing.expectError(error.Stale, completed.value("Value"));
        try testing.expectError(error.Stale, completed.writeValues(&values));
        try testing.expectError(error.Stale, completed.writeTrace(&traced));
        try testing.expectError(error.Stale, completed.effects());
    }
    // A run that kept no trace has no report to check.
    const untraced = try completedOf(try program.run(bench.worker, .{ .trace = .off }));
    try testing.expectEqual(embed.TraceMode.off, untraced.execution.trace);
    var unused: [8]u8 = undefined;
    var none: std.Io.Writer = .fixed(&unused);
    try testing.expectError(error.NoTrace, untraced.writeValues(&none));
    try testing.expectError(error.NoTrace, untraced.writeTrace(&none));
    try testing.expectEqual(@as(i64, 42), try integer(untraced, "Called"));
    // A digest run's reports, replayed, are a full run's.
    try testing.expectEqualStrings(reports[0][0][0..lengths[0][0]], reports[1][0][0..lengths[1][0]]);
    try testing.expectEqualStrings("{\"Value\":42,\"Called\":42}\n", reports[0][0][0..lengths[0][0]]);
}

const threaded_runs = 6;

fn runOn(program: *const embed.Program, seeds: []const u64, out: *[threaded_runs]i64, failed: *bool) void {
    const worker = embed.Worker.create(std.heap.page_allocator) catch {
        failed.* = true;
        return;
    };
    defer worker.destroy();
    for (seeds, out) |seed, *die| {
        const outcome = program.run(worker, .{ .seed = seed }) catch {
            failed.* = true;
            return;
        };
        const completed = switch (outcome) {
            .completed => |completed| completed,
            .failed => {
                failed.* = true;
                return;
            },
        };
        die.* = switch ((completed.value("Die") catch null) orelse return) {
            .integer => |value| value,
            else => -1,
        };
    }
}

test "one prepared program runs on several workers at once, each on its own storage" {
    const bench = try Bench.create();
    defer bench.destroy();
    const program = try bench.program("Die<public>:i64 = GetRandomInt(1, 1000000)\nSum<public>:i64 = Die + 1\n", null);
    defer program.destroy();
    const seeds = [threaded_runs]u64{ 1, 2, 3, 4, 5, 6 };
    var expected: [threaded_runs]i64 = undefined;
    var failed = false;
    runOn(program, &seeds, &expected, &failed);
    try testing.expect(!failed);
    var results: [3][threaded_runs]i64 = undefined;
    var failures: [3]bool = .{ false, false, false };
    var threads: [3]std.Thread = undefined;
    for (&threads, &results, &failures) |*thread, *result, *failure| thread.* = try std.Thread.spawn(.{}, runOn, .{ program, &seeds, result, failure });
    for (threads) |thread| thread.join();
    for (results, failures) |result, failure| {
        try testing.expect(!failure);
        try testing.expectEqualSlices(i64, &expected, &result);
    }
    // Workers interleaved on one thread do not disturb each other's results.
    const second = try embed.Worker.create(testing.allocator);
    defer second.destroy();
    const a = try completedOf(try program.run(bench.worker, .{ .seed = 1 }));
    const b = try completedOf(try program.run(second, .{ .seed = 2 }));
    try testing.expectEqual(expected[0], try integer(a, "Die"));
    try testing.expectEqual(expected[1], try integer(b, "Die"));
}

fn identityOf(compiler: *embed.Compiler, source: embed.Source, natives: ?*const embed.Natives) !embed.Identity {
    return (try compiler.identify(source, .{ .natives = natives })).ok;
}

test "a program's identity changes when an input it covers changes, and only then" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text = "Value<public>:i64 = 1\n";
    const base = try identityOf(bench.compiler, .{ .text = .{ .name = "a.forb", .bytes = text } }, null);
    // The same inputs in other buffers.
    const copy = try testing.allocator.dupe(u8, text);
    defer testing.allocator.free(copy);
    try testing.expect(base.eql(try identityOf(bench.compiler, .{ .text = .{ .name = "a.forb", .bytes = copy } }, null)));
    var standard: Table = .{};
    try standard.init();
    try testing.expect(base.eql(try identityOf(bench.compiler, .{ .text = .{ .name = "a.forb", .bytes = text } }, &standard.natives)));
    // A byte of the source, its name.
    try testing.expect(!base.eql(try identityOf(bench.compiler, .{ .text = .{ .name = "a.forb", .bytes = "Value<public>:i64 = 2\n" } }, null)));
    try testing.expect(!base.eql(try identityOf(bench.compiler, .{ .text = .{ .name = "b.forb", .bytes = text } }, null)));
    // The natives: one more, its cost, its signature, its effect, the type of its context; not
    // the context's address, which the cache compares.
    const rates: Rates = .{ .eu = 1, .us = 2 };
    const other_rates: Rates = .{ .eu = 3, .us = 4 };
    const fees: Fees = .{ .eu = 1, .us = 2 };
    const Variant = struct { entry: native.Entry, host: enum { none, rates, other_rates, fees } = .none };
    const variants = [_]Variant{
        .{ .entry = native.entry("test.double", double, .{}) },
        .{ .entry = native.entry("test.double", double, .{ .base = 2 }) },
        .{ .entry = native.entry("test.double", half, .{}) },
        .{ .entry = native.effectEntry("test.double", double, .{}, .draw) },
        .{ .entry = native.entry("test.double", double, .{}), .host = .rates },
        .{ .entry = native.entry("test.double", double, .{}), .host = .fees },
        .{ .entry = native.entry("test.other", double, .{}) },
    };
    var seen: [variants.len + 1]embed.Identity = undefined;
    seen[0] = base;
    for (variants, 1..) |variant, index| {
        var table: Table = .{};
        try table.init();
        switch (variant.host) {
            .none => try table.natives.register(variant.entry),
            .rates => try table.natives.registerWith(Rates, &rates, variant.entry),
            .other_rates => try table.natives.registerWith(Rates, &other_rates, variant.entry),
            .fees => try table.natives.registerWith(Fees, &fees, variant.entry),
        }
        seen[index] = try identityOf(bench.compiler, .{ .text = .{ .name = "a.forb", .bytes = text } }, &table.natives);
        for (seen[0..index]) |earlier| try testing.expect(!earlier.eql(seen[index]));
    }
    var moved: Table = .{};
    try moved.init();
    try moved.natives.registerWith(Rates, &other_rates, native.entry("test.double", double, .{}));
    try testing.expect(seen[5].eql(try identityOf(bench.compiler, .{ .text = .{ .name = "a.forb", .bytes = text } }, &moved.natives)));
    // A bundle: its root, the order of its modules, a module's path and its bytes; and a single
    // source is not the bundle of that one file.
    const files = [_]embed.File{ .{ .path = "main.forb", .source = text }, .{ .path = "lib.forb", .source = "B<public>:i64 = 2\n" } };
    const bundle = try identityOf(bench.compiler, .{ .files = .{ .root = "main.forb", .files = &files } }, null);
    try testing.expect(!bundle.eql(try identityOf(bench.compiler, .{ .files = .{ .root = "lib.forb", .files = &files } }, null)));
    const reordered = [_]embed.File{ files[1], files[0] };
    try testing.expect(!bundle.eql(try identityOf(bench.compiler, .{ .files = .{ .root = "main.forb", .files = &reordered } }, null)));
    const renamed = [_]embed.File{ files[0], .{ .path = "other.forb", .source = files[1].source } };
    try testing.expect(!bundle.eql(try identityOf(bench.compiler, .{ .files = .{ .root = "main.forb", .files = &renamed } }, null)));
    const edited = [_]embed.File{ files[0], .{ .path = "lib.forb", .source = "B<public>:i64 = 3\n" } };
    try testing.expect(!bundle.eql(try identityOf(bench.compiler, .{ .files = .{ .root = "main.forb", .files = &edited } }, null)));
    const one = [_]embed.File{files[0]};
    try testing.expect(!base.eql(try identityOf(bench.compiler, .{ .files = .{ .root = "a.forb", .files = &.{.{ .path = "a.forb", .source = text }} } }, null)));
    _ = one;
    // The packet of those files is the same bundle.
    try testing.expect(bundle.eql(try identityOf(bench.compiler, .{ .packet = .{ .name = "x.json", .bytes = "{\"root\":\"main.forb\",\"modules\":[{\"path\":\"main.forb\",\"source\":\"Value<public>:i64 = 1\\n\"},{\"path\":\"lib.forb\",\"source\":\"B<public>:i64 = 2\\n\"}]}" } }, null)));
    // A compile's identity is the one `identify` gives.
    try testing.expect(base.eql((try bench.compiler.compile(.{ .text = .{ .name = "a.forb", .bytes = text } }, .{})).ok.identity));
}

fn obtained(cache: *embed.Cache, compiler: *embed.Compiler, text: []const u8, natives: ?*const embed.Natives) !embed.Lease {
    return switch (try cache.obtain(compiler, .{ .text = .{ .name = "cached.forb", .bytes = text } }, .{ .natives = natives })) {
        .ok => |lease| lease,
        .failed, .refused => error.TestUnexpectedResult,
    };
}

test "a cache holds programs within its entry and byte ceilings, pins what it lends and evicts the oldest unpinned first" {
    const bench = try Bench.create();
    defer bench.destroy();
    const a = "Value<public>:i64 = 1\n";
    const b = "Value<public>:i64 = 2\n";
    const c = "Value<public>:i64 = 3\n";
    // No cache by default: every program is the lease's, and given back is destroyed.
    const none = try embed.Cache.create(testing.allocator, .{});
    const once = try obtained(none, bench.compiler, a, null);
    try testing.expect(!once.kept and !once.hit);
    const size = once.program.bytes();
    try none.release(once);
    const twice = try obtained(none, bench.compiler, a, null);
    try testing.expect(!twice.hit and !twice.kept);
    try none.release(twice);
    try none.destroy();
    try testing.expectError(error.TooManyEntries, embed.Cache.create(testing.allocator, .{ .entries = embed.max_cache_entries + 1, .bytes = 1 }));
    // The three programs are of one size.
    for ([_][]const u8{ b, c }) |text| {
        const probe = try embed.Cache.create(testing.allocator, .{});
        const lease = try obtained(probe, bench.compiler, text, null);
        try testing.expectEqual(size, lease.program.bytes());
        try probe.release(lease);
        try probe.destroy();
    }

    // Exactly the bytes of one program: kept, and the next obtain is a hit.
    const exact = try embed.Cache.create(testing.allocator, .{ .entries = 1, .bytes = size });
    const kept = try obtained(exact, bench.compiler, a, null);
    try testing.expect(kept.kept and !kept.hit);
    try testing.expectEqual(size, exact.usage().bytes);
    try exact.release(kept);
    const hit = try obtained(exact, bench.compiler, a, null);
    try testing.expect(hit.hit and hit.program == kept.program);
    try exact.release(hit);
    try exact.destroy();
    // One byte fewer: never kept.
    const short = try embed.Cache.create(testing.allocator, .{ .entries = 1, .bytes = size - 1 });
    const bypassed = try obtained(short, bench.compiler, a, null);
    try testing.expect(!bypassed.kept);
    try testing.expectEqual(@as(u32, 0), short.usage().entries);
    try short.release(bypassed);
    try short.destroy();

    // A pinned entry is never evicted: a full cache whose entries are lent bypasses.
    const pinned = try embed.Cache.create(testing.allocator, .{ .entries = 1, .bytes = 10 * size });
    const first = try obtained(pinned, bench.compiler, a, null);
    const second = try obtained(pinned, bench.compiler, b, null);
    try testing.expect(!second.kept);
    const again = try obtained(pinned, bench.compiler, a, null);
    try testing.expect(again.hit);
    try testing.expectEqual(@as(u32, 1), pinned.usage().pinned);
    try testing.expectError(error.InUse, pinned.destroy());
    try pinned.release(second);
    try pinned.release(first);
    try pinned.release(again);
    try testing.expectError(error.UnknownLease, pinned.release(again));
    try testing.expectEqual(@as(u32, 0), pinned.usage().pinned);
    try pinned.destroy();

    // FIFO by insertion: hits do not refresh an entry.
    const fifo = try embed.Cache.create(testing.allocator, .{ .entries = 2, .bytes = 10 * size });
    for ([_][]const u8{ a, b }) |text| try fifo.release(try obtained(fifo, bench.compiler, text, null));
    try fifo.release(try obtained(fifo, bench.compiler, a, null)); // a hit
    const inserted_c = try obtained(fifo, bench.compiler, c, null); // evicts a, the oldest
    try testing.expect(!inserted_c.hit and inserted_c.kept);
    try fifo.release(inserted_c);
    const still_b = try obtained(fifo, bench.compiler, b, null);
    try testing.expect(still_b.hit);
    try fifo.release(still_b);
    const back_a = try obtained(fifo, bench.compiler, a, null); // evicts b
    try testing.expect(!back_a.hit);
    try fifo.release(back_a);
    const still_c = try obtained(fifo, bench.compiler, c, null);
    try testing.expect(still_c.hit);
    try fifo.release(still_c);
    const back_b = try obtained(fifo, bench.compiler, b, null);
    try testing.expect(!back_b.hit);
    try testing.expectError(error.InUse, fifo.destroy());
    try fifo.release(back_b);
    try fifo.destroy();

    // The byte ceiling evicts as the entry ceiling does.
    const bytes = try embed.Cache.create(testing.allocator, .{ .entries = 3, .bytes = 2 * size });
    for ([_][]const u8{ a, b, c }) |text| try bytes.release(try obtained(bytes, bench.compiler, text, null));
    try testing.expectEqual(@as(u32, 2), bytes.usage().entries);
    try testing.expectEqual(2 * size, bytes.usage().bytes);
    const evicted = try obtained(bytes, bench.compiler, a, null);
    try testing.expect(!evicted.hit);
    try bytes.release(evicted);
    try bytes.destroy();

    // A source that does not compile, and a lease of another cache, keep nothing.
    const other = try embed.Cache.create(testing.allocator, .{ .entries = 2, .bytes = 10 * size });
    const failed = try other.obtain(bench.compiler, .{ .text = .{ .name = "bad.forb", .bytes = "Value:i64 = Missing\n" } }, .{});
    try testing.expectEqual(@as(?embed.Code, .unknown_name), failed.failed.code());
    try testing.expectEqual(@as(u32, 0), other.usage().entries);
    const foreign = try embed.Cache.create(testing.allocator, .{ .entries = 2, .bytes = 10 * size });
    const lent = try obtained(foreign, bench.compiler, a, null);
    try testing.expectError(error.UnknownLease, other.release(lent));
    try foreign.release(lent);
    try foreign.destroy();
    try other.destroy();
}

test "a cache gives a program out only for the native functions and contexts it was prepared with" {
    const bench = try Bench.create();
    defer bench.destroy();
    const rates: Rates = .{ .eu = 2000, .us = 700 };
    const higher: Rates = .{ .eu = 2100, .us = 800 };
    var first: Table = .{};
    try first.init();
    try first.natives.registerWith(Rates, &rates, native.entry("test.rate", rate, .{}));
    var second: Table = .{};
    try second.init();
    try second.natives.registerWith(Rates, &higher, native.entry("test.rate", rate, .{}));
    var same: Table = .{};
    try same.init();
    try same.natives.registerWith(Rates, &rates, native.entry("test.rate", rate, .{}));
    const text = "Rate := native{\"test.rate\"}\nEu<public>:i64 = Or(Rate(\"EU\"), -1)\n";
    const cache = try embed.Cache.create(testing.allocator, .{ .entries = 4, .bytes = 1 << 30 });
    const kept = try obtained(cache, bench.compiler, text, &first.natives);
    try testing.expect(kept.kept);
    // Another context: same identity, not the same program; it is not kept beside the first.
    const moved = try obtained(cache, bench.compiler, text, &second.natives);
    try testing.expect(!moved.hit and !moved.kept);
    try testing.expect(moved.program.identity().eql(kept.program.identity()));
    try testing.expectEqual(@as(i64, 2100), try integer(try completedOf(try moved.program.run(bench.worker, .{})), "Eu"));
    try cache.release(moved);
    // Another table with the same functions and contexts: the same program.
    const shared = try obtained(cache, bench.compiler, text, &same.natives);
    try testing.expect(shared.hit and shared.program == kept.program);
    try testing.expectEqual(@as(i64, 2000), try integer(try completedOf(try shared.program.run(bench.worker, .{})), "Eu"));
    try cache.release(shared);
    try cache.release(kept);
    try cache.destroy();
}

test "every lease is given back once, to the cache that lent it, whether the cache kept its program or not" {
    const bench = try Bench.create();
    defer bench.destroy();
    const a = "Value<public>:i64 = 1\n";
    const b = "Value<public>:i64 = 2\n";
    try testing.expectError(error.TooManyLeases, embed.Cache.create(testing.allocator, .{ .leases = 0 }));
    try testing.expectError(error.TooManyLeases, embed.Cache.create(testing.allocator, .{ .leases = embed.max_cache_leases + 1 }));
    const cache = try embed.Cache.create(testing.allocator, .{ .entries = 1, .bytes = 1 << 30, .leases = 2 });
    const one = try obtained(cache, bench.compiler, a, null);
    const two = try obtained(cache, bench.compiler, a, null);
    try testing.expect(one.kept and two.hit and two.program == one.program);
    // Two leases of one program are two tickets: the first given back twice is refused, and the
    // second still pins the program.
    try cache.release(one);
    try testing.expectError(error.UnknownLease, cache.release(one));
    try testing.expectEqual(@as(u32, 1), cache.usage().pinned);
    try testing.expectError(error.InUse, cache.destroy());
    const other = try obtained(cache, bench.compiler, b, null);
    try testing.expect(!other.kept);
    try testing.expectEqual(@as(i64, 1), try integer(try completedOf(try two.program.run(bench.worker, .{})), "Value"));
    // A full table of leases refuses before anything is read.
    try testing.expectError(error.TooManyLeases, cache.obtain(bench.compiler, .{ .text = .{ .name = "a", .bytes = a } }, .{}));
    // A lease the cache did not keep is given back once, and to no other cache.
    const foreign = try embed.Cache.create(testing.allocator, .{});
    try testing.expectError(error.UnknownLease, foreign.release(other));
    try testing.expectError(error.UnknownLease, foreign.release(two));
    try testing.expectEqual(@as(i64, 2), try integer(try completedOf(try other.program.run(bench.worker, .{})), "Value"));
    try cache.release(other);
    try testing.expectError(error.UnknownLease, cache.release(other));
    try cache.release(two);
    try testing.expectEqual(@as(u32, 0), cache.usage().leases);
    try cache.destroy();
    // A cache that keeps nothing is in use while a lease of it is out.
    const lent = try obtained(foreign, bench.compiler, a, null);
    try testing.expectError(error.InUse, foreign.destroy());
    try foreign.release(lent);
    try foreign.destroy();
}

test "a run that is refused ends the worker's last result, and so does a report whose replay stops short" {
    const bench = try Bench.create();
    defer bench.destroy();
    const program = try bench.program(effects_text, null);
    defer program.destroy();
    const kept = try completedOf(try program.run(bench.worker, .{ .grants = &.{.{ .key = "alice" }} }));
    try testing.expectEqualStrings("alice", (try kept.effects()).grants[0].name);
    try testing.expectError(error.InvalidGrants, program.run(bench.worker, .{ .grants = &.{ .{ .key = "bob" }, .{ .key = "bob" } } }));
    try testing.expectError(error.Stale, kept.effects());
    try testing.expectError(error.Stale, kept.value("Keyed"));
    // Every refusal ends it, the ones checked before the grants are read too (c8-1).
    var too_many: [embed.grant_capacity + 1]embed.Grant = undefined;
    for (&too_many, 0..) |*grant, index| grant.* = .{ .key = if (index % 2 == 0) "a" else "b" };
    const refusals = [_]struct { options: embed.RunOptions, refusal: embed.RunError }{
        .{ .options = .{ .tick_rate = 0 }, .refusal = error.InvalidTickRate },
        .{ .options = .{ .tick_rate = 1_000_001 }, .refusal = error.InvalidTickRate },
        .{ .options = .{ .clock = .{ .start = std.math.nan(f64) } }, .refusal = error.InvalidClock },
        .{ .options = .{ .clock = .{ .start = std.math.inf(f64) } }, .refusal = error.InvalidClock },
        .{ .options = .{ .grants = &too_many }, .refusal = error.InvalidGrants },
    };
    for (refusals) |case| {
        const last = try completedOf(try program.run(bench.worker, .{ .grants = &.{.{ .key = "alice" }} }));
        try testing.expectEqual(true, (try last.value("Keyed")).?.logic);
        try testing.expectError(case.refusal, program.run(bench.worker, case.options));
        try testing.expectError(error.Stale, last.effects());
        try testing.expectError(error.Stale, last.value("Keyed"));
    }
    // A report replays a `digest` run in the run's own string pool: a replay stopped by the
    // report's work limit leaves it rebuilt part way, so the result is spent.
    try @import("forbic").profile.requireBootstrap();
    const long = try bench.program(
        \\Step(S:i64)<computes>:i64 = Block{ T := ToString(S); S + T.Length - T.Length + 1 }
        \\Total:i64 = Iterate(Step, 100000, 0)
        \\Text<public>:string = ToString(Total)
    , null);
    defer long.destroy();
    const completed = try completedOf(try long.run(bench.worker, .{ .trace = .digest, .fuel = 100_000_000 }));
    try testing.expectEqualStrings("100000", (try completed.value("Text")).?.string);
    const report = try testing.allocator.alloc(u8, 1 << 16);
    defer testing.allocator.free(report);
    var out: std.Io.Writer = .fixed(report);
    try testing.expectError(error.ReportLimit, completed.writeValues(&out));
    try testing.expectError(error.Stale, completed.value("Text"));
    try testing.expectError(error.Stale, completed.writeTrace(&out));
}

const progress_text =
    \\stats := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
    \\var Stats:weak_map(persistent_key, stats) = map{}
    \\Add(K:persistent_key, Points:i64)<reads><writes>:i64 = Block{
    \\    Current := Attempt(Stats[K], stats{})
    \\    set Stats[K] = stats{Level := Current.Level, Experience := Current.Experience + Points}
    \\    Points
    \\}
    \\Gained<public>:i64 = Attempt(Block{ K := GetPersistentKey["alice"]; Add(K, 10); Stats[K].Experience }, -1)
    \\Shown:tuple() = Print("saved {Gained}")
;

/// A durable run's visitor: the value of `Gained` and the values' report.
const Visit = struct {
    gained: i64 = 0,
    report: [512]u8 = undefined,
    length: usize = 0,
    calls: usize = 0,
    fail: bool = false,

    pub fn completed(self: *Visit, run: embed.Completed) !void {
        self.calls += 1;
        if (self.fail) return error.VisitorRefused;
        self.gained = try integer(run, "Gained");
        var out: std.Io.Writer = .fixed(&self.report);
        try run.writeValues(&out);
        self.length = out.buffered().len;
    }
};

test "a durable run keeps its persistent cells in its state directory between runs, and reports failures as values" {
    const bench = try Bench.create();
    defer bench.destroy();
    const directory = try Directory.create();
    defer directory.destroy();
    const state = try directory.path("state");
    const program = try bench.program(progress_text, null);
    defer program.destroy();
    var output_bytes: [256]u8 = undefined;
    var message_bytes: [512]u8 = undefined;
    for ([_]i64{ 10, 20, 30 }) |expected| {
        var output: std.Io.Writer = .fixed(&output_bytes);
        var messages: std.Io.Writer = .fixed(&message_bytes);
        var visit: Visit = .{};
        const outcome = try program.runDurable(testing.io, testing.allocator, .{ .state = state, .grants = &.{.{ .key = "alice" }}, .output = &output, .messages = &messages }, &visit);
        try testing.expectEqualStrings("", messages.buffered());
        try testing.expectEqual(embed.DurableOutcome.completed, outcome);
        try testing.expectEqual(expected, visit.gained);
        var line_bytes: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&line_bytes, "saved {d}\n", .{expected}), output.buffered());
        try testing.expect(std.mem.indexOf(u8, visit.report[0..visit.length], "\"Gained\":") != null);
    }
    // An in-memory run of the same program starts from an empty store.
    const fresh = try completedOf(try program.run(bench.worker, .{ .grants = &.{.{ .key = "alice" }} }));
    try testing.expectEqual(@as(i64, 10), try integer(fresh, "Gained"));
    // Abandoning a directory with no unfinished run runs nothing.
    var output: std.Io.Writer = .fixed(&output_bytes);
    var messages: std.Io.Writer = .fixed(&message_bytes);
    try testing.expectEqual(embed.DurableOutcome.nothing_ran, try program.runDurable(testing.io, testing.allocator, .{ .state = state, .intent = .abandon, .output = &output, .messages = &messages }, null));
    try testing.expect(std.mem.endsWith(u8, messages.buffered(), "holds no unfinished run\n"));
    // A program's error is its code, and its text as the tool writes it.
    const fatal = try bench.program("Zero:i64 = 0\nBad:i64 = 1 / Zero\n", null);
    defer fatal.destroy();
    messages = .fixed(&message_bytes);
    const failed = try fatal.runDurable(testing.io, testing.allocator, .{ .state = try directory.path("fatal"), .output = &output, .messages = &messages, .style = .excerpt }, null);
    try testing.expectEqual(@as(?embed.Code, .division_by_zero), failed.failed.code);
    try testing.expectEqual(embed.DurableFailure.Cause.program, failed.failed.cause);
    try testing.expectEqualStrings("test.forb:2:13: error: division by zero", failed.failed.note());
    try testing.expectEqualStrings("test.forb:2:13: error: division by zero\n  2 | Bad:i64 = 1 / Zero\n    |             ^\n", messages.buffered());
    // A visitor that refuses is a failure; the run it was given has finished.
    var refusing: Visit = .{ .fail = true };
    messages = .fixed(&message_bytes);
    const refused = try program.runDurable(testing.io, testing.allocator, .{ .state = state, .grants = &.{.{ .key = "alice" }}, .output = &output, .messages = &messages }, &refusing);
    try testing.expectEqualStrings("VisitorRefused", refused.failed.error_name.?);
    try testing.expectEqual(embed.DurableFailure.Cause.visitor, refused.failed.cause);
    // A state directory that is a file is the state's refusal, said in its note.
    try directory.write("plain.txt", "not a directory\n");
    messages = .fixed(&message_bytes);
    const not_directory = try program.runDurable(testing.io, testing.allocator, .{ .state = try directory.path("plain.txt"), .grants = &.{.{ .key = "alice" }}, .output = &output, .messages = &messages }, null);
    try testing.expectEqual(embed.DurableFailure.Cause.state, not_directory.failed.cause);
    try testing.expectEqual(@as(?embed.Code, null), not_directory.failed.code);
    try testing.expect(std.mem.startsWith(u8, not_directory.failed.note(), "forbic: error: "));
    try testing.expect(std.mem.endsWith(u8, messages.buffered(), "\n"));
    try testing.expectEqualStrings(not_directory.failed.note(), messages.buffered()[0 .. messages.buffered().len - 1]);
    try testing.expectEqual(@as(usize, 1), refusing.calls);
    // Choices that cannot be are errors.
    try testing.expectError(error.InvalidTickRate, program.runDurable(testing.io, testing.allocator, .{ .state = state, .tick_rate = 0, .output = &output, .messages = &messages }, null));
    try testing.expectError(error.InvalidClock, program.runDurable(testing.io, testing.allocator, .{ .state = state, .clock = std.math.nan(f64), .output = &output, .messages = &messages }, null));
    try testing.expectError(error.InvalidGrants, program.runDurable(testing.io, testing.allocator, .{ .state = state, .grants = &.{ .{ .key = "a" }, .{ .key = "a" } }, .output = &output, .messages = &messages }, null));
    try testing.expectError(error.InvalidGrants, program.runDurable(testing.io, testing.allocator, .{ .state = state, .grants = &.{.{ .reader = .{ .name = "in", .path = "" } }}, .output = &output, .messages = &messages }, null));
}

test "a durable run of a bundle of files compiles again from the packet it was prepared from" {
    const bench = try Bench.create();
    defer bench.destroy();
    const directory = try Directory.create();
    defer directory.destroy();
    const files = [_]embed.File{
        .{ .path = "test@example.com/App/a.forb", .source = "Base<public>:i64 = 20\n" },
        .{ .path = "test@example.com/App/b.forb", .source = "Total<public>:i64 = Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n" },
    };
    const compiled = try bench.compiler.compile(.{ .files = .{ .root = "/test@example.com/App", .files = &files } }, .{});
    const program = (try embed.prepare(testing.allocator, compiled.ok)).ok;
    defer program.destroy();
    var output_bytes: [64]u8 = undefined;
    var message_bytes: [256]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_bytes);
    var messages: std.Io.Writer = .fixed(&message_bytes);
    try testing.expectEqual(embed.DurableOutcome.completed, try program.runDurable(testing.io, testing.allocator, .{ .state = try directory.path("state"), .output = &output, .messages = &messages }, null));
    try testing.expectEqualStrings("", messages.buffered());
    try testing.expectEqualStrings("total 42\n", output.buffered());
}

test "a project directory compiles as forbic run DIR reads it, runs durably from its packet, and its refusal is a value" {
    const bench = try Bench.create();
    defer bench.destroy();
    const directory = try Directory.create();
    defer directory.destroy();
    const io = testing.io;
    try directory.temporary.dir.createDirPath(io, "app/src/test@example.com/App");
    try directory.write("app/forbic.json", "{\"root\": \"/test@example.com/App\"}");
    try directory.write("app/src/test@example.com/App/a.forb", "Base<public>:i64 = 20\n");
    try directory.write("app/src/test@example.com/App/b.forb", "Total<public>:i64 = Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n");
    const app = try directory.path("app");
    const compiled = try bench.compiler.compile(.{ .project = .{ .io = io, .path = app } }, .{});
    try testing.expectEqualStrings(app, compiled.ok.name());
    // The same program as the files of its tree: one identity.
    const files = [_]embed.File{
        .{ .path = "test@example.com/App/a.forb", .source = "Base<public>:i64 = 20\n" },
        .{ .path = "test@example.com/App/b.forb", .source = "Total<public>:i64 = Base * 2 + 2\nShown:tuple() = Print(\"total {Total}\")\n" },
    };
    const identity = compiled.ok.identity;
    const program = (try embed.prepare(testing.allocator, compiled.ok)).ok;
    defer program.destroy();
    const as_files = try bench.compiler.identify(.{ .files = .{ .root = "/test@example.com/App", .files = &files } }, .{});
    try testing.expect(identity.eql(as_files.ok));
    const completed = try completedOf(try program.run(bench.worker, .{}));
    try testing.expectEqual(@as(i64, 42), try integer(completed, "Total"));
    var output_bytes: [64]u8 = undefined;
    var message_bytes: [256]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_bytes);
    var messages: std.Io.Writer = .fixed(&message_bytes);
    try testing.expectEqual(embed.DurableOutcome.completed, try program.runDurable(io, testing.allocator, .{ .state = try directory.path("state"), .output = &output, .messages = &messages }, null));
    try testing.expectEqualStrings("", messages.buffered());
    try testing.expectEqualStrings("total 42\n", output.buffered());

    // A diagnostic names the file by its path in the tree.
    try directory.write("app/src/test@example.com/App/b.forb", "Total<public>:i64 = Base * 2 + Missing\n");
    const failed = try bench.compiler.compile(.{ .project = .{ .io = io, .path = app } }, .{});
    try testing.expectEqualStrings("test@example.com/App/b.forb", failed.failed.diagnostic.path);
    // A directory that is no project is refused before anything is compiled, as the tool says.
    const none = try directory.path("state");
    const refused = try bench.compiler.compile(.{ .project = .{ .io = io, .path = none } }, .{});
    try testing.expectEqual(@as(?embed.Code, null), refused.failed.code());
    try testing.expectEqual(forbic_host_project.Reason.no_manifest, refused.failed.project.refusal.reason);
    var written_bytes: [512]u8 = undefined;
    var written: std.Io.Writer = .fixed(&written_bytes);
    try refused.failed.write(&written, .plain);
    var expected_bytes: [512]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected_bytes, "{s}: error: is not a Forbic project: it has no forbic.json naming its root module\n", .{none}), written.buffered());
}
