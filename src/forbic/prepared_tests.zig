//! Prepare once, run many (TASK-0109 W4.3; RFC-0088 A1, A3, A4): a prepared handle's runs on
//! both machines equal compile-and-run, its admissions are made once and each by its own
//! machine, it owns everything it holds, and nothing of one run reaches the next.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const vm = @import("vm.zig");
const bytecode = @import("bytecode.zig");
const evaluator = @import("evaluator.zig");
const effects = @import("effects.zig");
const native = @import("native.zig");
const compiler = @import("compiler.zig");
const bundle_packet = @import("bundle_packet.zig");
const reporting = @import("value_report.zig");
const trace_report = @import("failure_report.zig");
const trace_replay = @import("trace_replay.zig");
const prepared = @import("prepared.zig");
const conformance_fixtures = @import("conformance_fixtures.zig");

const transcript_bytes = 4 * 1024 * 1024;

/// The grants the differential draws from, and the lines its readers read.
const grant_pool = [_]effects.Grant{
    .{ .kind = .reader, .name = "config" },
    .{ .kind = .writer, .name = "log" },
    .{ .kind = .reader, .name = "extra" },
    .{ .kind = .writer, .name = "audit" },
};
const config_lines = [_][]const u8{ "alpha", "beta", "gamma" };
const extra_lines = [_][]const u8{"one"};

/// One run's storage of each kind that every prepared run shares, the fresh storage of the
/// compile-and-run path (made fresh for every run), and what both write their transcripts to.
const Bench = struct {
    vm_run: *prepared.VmRun,
    reference_run: *prepared.ReferenceRun,
    fresh_vm: *bytecode.Workspace,
    fresh_reference: *prepared.ReferenceRun,
    replay: *trace_replay.Storage,
    front: *compiler.Workspace,
    packet: *bundle_packet.Workspace,
    script: effects.Script = .{ .streams = &.{ &config_lines, &.{}, &extra_lines } },
    expected: []u8,
    actual: []u8,
    /// Admissions made by prepared runs, which must make none.
    admitted: usize = 0,
    /// Whether a refused compile is told: the corpus has error fixtures, the other tests do not.
    loud: bool = true,

    fn create() !*Bench {
        const self = try std.testing.allocator.create(Bench);
        errdefer std.testing.allocator.destroy(self);
        self.* = .{
            .vm_run = try scratch.storage(prepared.VmRun),
            .reference_run = try scratch.storage(prepared.ReferenceRun),
            .fresh_vm = try scratch.storage(bytecode.Workspace),
            .fresh_reference = try scratch.storage(prepared.ReferenceRun),
            .replay = try scratch.storage(trace_replay.Storage),
            .front = try scratch.storage(compiler.Workspace),
            .packet = try scratch.storage(bundle_packet.Workspace),
            .expected = scratch.alloc(u8, transcript_bytes) orelse return error.OutOfMemory,
            .actual = scratch.alloc(u8, transcript_bytes) orelse return error.OutOfMemory,
        };
        scratch.initialise(self.vm_run);
        scratch.initialise(self.reference_run);
        scratch.initialise(self.front);
        scratch.initialise(self.packet);
        return self;
    }
    fn destroy(self: *Bench) void {
        scratch.release(self.vm_run);
        scratch.release(self.reference_run);
        scratch.release(self.fresh_vm);
        scratch.release(self.fresh_reference);
        scratch.release(self.replay);
        scratch.release(self.front);
        scratch.release(self.packet);
        scratch.free(self.expected);
        scratch.free(self.actual);
        std.testing.allocator.destroy(self);
    }

    const Source = union(enum) { file: []const u8, bundle: []const u8 };
    fn compile(self: *Bench, source: Source) ?types.Program {
        return switch (source) {
            .file => |text| switch (self.front.compile(text)) {
                .ok => |program| program,
                .failed => |d| {
                    if (self.loud) std.debug.print("compile: {t} at {d}..{d}\n", .{ d.code, d.span.start, d.span.end });
                    return null;
                },
            },
            .bundle => |packet| switch (self.front.compileBundle(self.packet.parse(packet) catch return null)) {
                .ok => |program| program,
                .failed => null,
            },
        };
    }

    /// Compile and run on the VM, in storage made fresh for this run, as the CLI does.
    fn freshVm(self: *Bench, source: Source, options: prepared.Options) !Summary {
        const program = self.compile(source) orelse return error.Compile;
        scratch.initialise(self.fresh_vm);
        const control = &self.fresh_vm.machine.control;
        self.choose(control, options);
        const result = self.fresh_vm.evaluate(program, options.work_budget);
        return self.transcript(self.expected, result, program, options);
    }
    fn freshReference(self: *Bench, source: Source, options: prepared.Options) !Summary {
        const program = self.compile(source) orelse return error.Compile;
        scratch.initialise(self.fresh_reference);
        const run = self.fresh_reference;
        self.choose(&run.control, options);
        const result = evaluator.evaluateWithRuntimeStorage(program, &run.values, &run.members, &run.control, &run.state, &run.frames, options.work_budget);
        return self.transcript(self.expected, result, program, options);
    }
    fn preparedVm(self: *Bench, handle: *const prepared.Prepared, options: prepared.Options) !Summary {
        self.script.rewind();
        const before = admissions();
        const result = try handle.runVm(self.vm_run, self.world(options));
        self.admitted += admissions() - before;
        return self.transcript(self.actual, result, handle.replayProgram(&self.vm_run.strings), options);
    }
    fn preparedReference(self: *Bench, handle: *const prepared.Prepared, options: prepared.Options) !Summary {
        self.script.rewind();
        const before = admissions();
        const result = try handle.runReference(self.reference_run, self.world(options));
        self.admitted += admissions() - before;
        // The reference run built its strings in its own pool; its replay is given that pool.
        return self.transcript(self.actual, result, handle.replayProgram(&self.reference_run.strings), options);
    }
    fn world(self: *Bench, options: prepared.Options) prepared.Options {
        var given = options;
        given.source = self.script.source();
        return given;
    }
    /// The fresh path sets on new storage what `Options` gives a prepared run, in its own words.
    fn choose(self: *Bench, control: *types.ControlStorage, options: prepared.Options) void {
        self.script.rewind();
        control.trace = options.trace;
        control.tick_rate = options.tick_rate;
        control.effects.seed = options.seed;
        control.effects.inputs.grants = options.grants;
        control.effects.inputs.source = self.script.source();
    }

    /// Fresh storage for the second run of a replayed report, on the reported run's clock.
    fn replayer(self: *Bench, options: prepared.Options) *trace_replay.Storage {
        scratch.initialise(self.replay);
        self.replay.control.effects.seed = options.seed;
        self.replay.control.tick_rate = options.tick_rate;
        return self.replay;
    }

    /// Everything a host can see of a run: its diagnostic, or its value and trace reports
    /// (replayed for a run that kept no steps), its output and its witness.
    fn transcript(self: *Bench, head: []u8, result: evaluator.Result, program: types.Program, options: prepared.Options) !Summary {
        var buffer: [4096]u8 = undefined;
        var sink: Transcript = .{ .head = head, .writer = .{ .buffer = &buffer, .vtable = &.{ .drain = Transcript.drain } } };
        const w = &sink.writer;
        switch (result) {
            .failed => |d| try w.print("failed {t} {d}..{d}\n", .{ d.code, d.span.start, d.span.end }),
            .ok => |x| {
                try w.print("trace {t}\n", .{x.trace});
                if (x.callWitness()) |witness| try w.print("witness {d} {x}\n", .{ witness.count, witness.digest });
                try w.print("output {d} {d} {d}\n", .{ x.effects.entries.len, x.effects.draws, x.effects.discarded });
                try w.writeAll(x.effects.bytes);
                try w.print("\ninputs {d}\n", .{x.effects.inputs.len});
                try w.writeAll(x.effects.input_bytes);
                try w.writeAll("\n");
                // A completed run's reports must validate: an error here fails the test, so two
                // paths that refused alike are no agreement.
                if (x.trace == .digest) {
                    _ = try reporting.writeReplayed(w, x, self.replayer(options).producer(program, options.work_budget), false, .{});
                    try trace_report.writeReplayed(w, x, self.replayer(options).producer(program, options.work_budget), "corpus.forb", .{});
                } else {
                    _ = try reporting.write(w, x, false, .{});
                    try trace_report.write(w, x, "corpus.forb", .{});
                }
            },
        }
        try w.flush();
        return .{ .digest = sink.hasher.finalResult(), .total = sink.total, .head = head[0..sink.kept] };
    }
};

/// A transcript: the SHA-256 and length of all of its text, and as much of its start as fits
/// `head`, for a message. Reports at the program profile's scale can be long.
const Summary = struct {
    digest: [32]u8,
    total: usize,
    head: []const u8,

    fn failed(self: Summary) bool {
        return std.mem.startsWith(u8, self.head, "failed");
    }
};
const Transcript = struct {
    head: []u8,
    kept: usize = 0,
    total: usize = 0,
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),
    writer: std.Io.Writer,

    fn take(self: *Transcript, bytes: []const u8) void {
        self.hasher.update(bytes);
        const room = @min(bytes.len, self.head.len - self.kept);
        @memcpy(self.head[self.kept..][0..room], bytes[0..room]);
        self.kept += room;
        self.total += bytes.len;
    }
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Transcript = @alignCast(@fieldParentPtr("writer", w));
        self.take(w.buffered());
        w.end = 0;
        var taken: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.take(slice);
            taken += slice.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.take(last);
        return taken + last.len * splat;
    }
};

/// Calls of both machines' admissions so far.
fn admissions() usize {
    return vm.verifications + evaluator.validations;
}

const Corpus = struct {
    names: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]u8) = .empty,
    bundled: std.ArrayList(bool) = .empty,

    fn load(self: *Corpus) !void {
        const io = std.testing.io;
        var dir = try conformance_fixtures.open(io, .{ .iterate = true }) orelse return;
        defer dir.close(io);
        var walker = try dir.walk(std.testing.allocator);
        defer walker.deinit();
        const buffer = scratch.alloc(u8, bundle_packet.max_packet_bytes + 1) orelse return error.OutOfMemory;
        defer scratch.free(buffer);
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const bundle = std.mem.endsWith(u8, entry.basename, ".bundle.json");
            if (!bundle and !std.mem.endsWith(u8, entry.basename, ".forb")) continue;
            const text = try entry.dir.readFile(io, entry.basename, buffer);
            if (!bundle and text.len > types.limits.source_bytes) continue;
            try self.names.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.path));
            try self.texts.append(std.testing.allocator, try std.testing.allocator.dupe(u8, text));
            try self.bundled.append(std.testing.allocator, bundle);
        }
    }
    fn deinit(self: *Corpus) void {
        for (self.names.items) |name| std.testing.allocator.free(name);
        for (self.texts.items) |text| std.testing.allocator.free(text);
        self.names.deinit(std.testing.allocator);
        self.texts.deinit(std.testing.allocator);
        self.bundled.deinit(std.testing.allocator);
    }
    fn source(self: *const Corpus, index: usize) Bench.Source {
        return if (self.bundled.items[index]) .{ .bundle = self.texts.items[index] } else .{ .file = self.texts.items[index] };
    }
};

fn expectSame(name: []const u8, machine: []const u8, run: usize, expected: Summary, actual: Summary) !void {
    if (expected.total == actual.total and std.mem.eql(u8, &expected.digest, &actual.digest)) return;
    std.debug.print("{s}: the {s} run {d} of the prepared handle differs from compile-and-run ({d} and {d} bytes)\n--- expected\n{s}\n--- actual\n{s}\n", .{ name, machine, run, expected.total, actual.total, expected.head[0..@min(expected.head.len, 2000)], actual.head[0..@min(actual.head.len, 2000)] });
    return error.TestExpectedEqual;
}

fn randomOptions(random: std.Random, grants: []effects.Grant) prepared.Options {
    var count: usize = 0;
    for (grant_pool) |grant| if (random.boolean()) {
        grants[count] = grant;
        count += 1;
    };
    const budgets = [_]u64{ 0, 1, 7, 50, 400, 5_000, types.limits.evaluation_work };
    const rates = [_]u64{ 1, 60, 1000, types.Scheduler.max_tick_rate };
    return .{
        .seed = random.int(u64),
        .tick_rate = rates[random.uintLessThan(usize, rates.len)],
        .work_budget = if (random.uintLessThan(u8, 4) == 0) budgets[random.uintLessThan(usize, budgets.len)] else types.limits.evaluation_work,
        .trace = if (random.uintLessThan(u8, 3) == 0) .digest else .full,
        .grants = grants[0..count],
    };
}

test "prepared: runs of one handle on both machines equal compile and run over the conformance corpus" {
    const bench = try Bench.create();
    defer bench.destroy();
    var corpus: Corpus = .{};
    defer corpus.deinit();
    try corpus.load();
    // Run from a tree without its fixtures, the test has nothing to compare: it says so.
    if (corpus.texts.items.len == 0) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x0ddba11_0430);
    const random = prng.random();
    // The handles of every program the corpus compiles, prepared first, so that each program's
    // runs follow the compiles and runs of all the others on the same workspace and storage.
    var handles: std.ArrayList(?*prepared.Prepared) = .empty;
    defer {
        for (handles.items) |handle| if (handle) |held| held.destroy();
        handles.deinit(std.testing.allocator);
    }
    var count: usize = 0;
    bench.loud = false;
    for (0..corpus.texts.items.len) |index| {
        const program = bench.compile(corpus.source(index)) orelse {
            try handles.append(std.testing.allocator, null);
            continue;
        };
        const before = .{ vm.verifications, evaluator.validations };
        const preparation = try prepared.prepare(std.testing.allocator, program);
        // One admission of each kind per handle, and no more.
        if (before[0] + 1 != vm.verifications or before[1] + 1 != evaluator.validations) {
            std.debug.print("{s}: {d} verifications and {d} validations\n", .{ corpus.names.items[index], vm.verifications - before[0], evaluator.validations - before[1] });
            return error.TestUnexpectedResult;
        }
        if (preparation == .failed) {
            std.debug.print("{s}: compiled but refused by the {t} admission: {t}\n", .{ corpus.names.items[index], preparation.failed.by, preparation.failed.diagnostic.code });
            return error.TestUnexpectedResult;
        }
        try handles.append(std.testing.allocator, preparation.ok);
        count += 1;
    }
    // Run every handle three times on each machine, in an order that mixes the programs, with
    // random seeds, tick rates, grants, budgets (some too small) and trace modes.
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(std.testing.allocator);
    for (0..3) |_| for (handles.items, 0..) |handle, index| if (handle != null) try order.append(std.testing.allocator, index);
    random.shuffle(usize, order.items);
    var grants: [grant_pool.len]effects.Grant = undefined;
    var runs: [2]usize = .{ 0, 0 };
    for (order.items, 0..) |index, step| {
        const handle = handles.items[index].?;
        const options = randomOptions(random, &grants);
        const name = corpus.names.items[index];
        const expected_vm = try bench.freshVm(corpus.source(index), options);
        const actual_vm = try bench.preparedVm(handle, options);
        try expectSame(name, "VM", step, expected_vm, actual_vm);
        const expected_reference = try bench.freshReference(corpus.source(index), options);
        const actual_reference = try bench.preparedReference(handle, options);
        try expectSame(name, "reference", step, expected_reference, actual_reference);
        // The prepared runs admitted nothing (a replayed report admits for itself, after the run).
        try std.testing.expectEqual(@as(usize, 0), bench.admitted);
        runs[@intFromBool(actual_vm.failed())] += 1;
    }
    try std.testing.expect(count >= 100 and runs[0] >= 100 and runs[1] >= 10);
}

/// The address range of a handle: every slice it holds must lie inside it.
fn inside(handle: *const prepared.Prepared, bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    const start = @intFromPtr(handle);
    return @intFromPtr(bytes.ptr) >= start and @intFromPtr(bytes.ptr) + bytes.len <= start + handle.bytes();
}
fn ownsAll(handle: *const prepared.Prepared) !void {
    const program = handle.program();
    inline for (@typeInfo(types.Program).@"struct".field_names) |name| {
        const field = @field(program, name);
        if (@typeInfo(@TypeOf(field)) == .pointer) try std.testing.expect(inside(handle, std.mem.sliceAsBytes(field)));
    }
    for (program.natives) |entry| try std.testing.expect(inside(handle, entry.id) and inside(handle, std.mem.sliceAsBytes(entry.params)));
    try std.testing.expectEqual(@as(usize, 0), program.string_tail.len);
    try std.testing.expect(inside(handle, std.mem.sliceAsBytes(handle.vmAdmission().registers())));
}

test "prepared: a handle owns what it holds, so a later compile and a rewritten source change nothing" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text =
        \\var Count:i64 = 0
        \\Step(N:i64)<transacts>:i64 = Block{ set Count = Count + N; Count }
        \\Words:[]string = array{"alpha", "beta"}
        \\Joined<public>:string = Attempt(Words[0] + "-" + Words[1], "none")
        \\Total<public>:i64 = Iterate(Step, 5, 1)
        \\Root<public>:float = Sqrt(2.0)
        \\Seen<public>:i64 = Count
    ;
    const source = try std.testing.allocator.dupe(u8, text);
    defer std.testing.allocator.free(source);
    const program = bench.compile(.{ .file = source }).?;
    try std.testing.expect(program.natives.len != 0 and program.strings.len != 0);
    const handle = (try prepared.prepare(std.testing.allocator, program)).ok;
    defer handle.destroy();
    try ownsAll(handle);
    // The bytes held are the copy and nothing more than its tables, bytecode and register types.
    try std.testing.expect(handle.bytes() >= program.source.len + program.strings.len + program.nodes.len * (@sizeOf(types.Node) + @sizeOf(vm.Instruction)));
    const expected_vm = try bench.freshVm(.{ .file = text }, .{});
    const expected_reference = try bench.freshReference(.{ .file = text }, .{});
    // Another program compiled into the same workspace overwrites everything the first one
    // borrowed there, and the source buffer is rewritten.
    @memset(source, 'x');
    _ = bench.compile(.{ .file = "Other<public>:string = \"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\" + \"y\"\nN:i64 = 99\nM:[]i64 = array{1, 2, 3, 4, 5, 6, 7, 8}" }).?;
    try std.testing.expectEqualStrings(text, handle.program().source);
    try expectSame("owned", "VM", 0, expected_vm, try bench.preparedVm(handle, .{}));
    try expectSame("owned", "reference", 0, expected_reference, try bench.preparedReference(handle, .{}));
    // A bundle's modules are held as well: the combined source and module maps were the
    // workspace's own.
    const packet =
        \\{"root":"main.forb","modules":[{"path":"main.forb","source":"L:=import{\"lib.forb\"}\nA<public>:i64 = L.Twice(21)\nT<public>:string = L.Name"},{"path":"lib.forb","source":"Twice<public>(N:i64)<computes>:i64 = N * 2\nName<public>:string = \"lib\""}]}
    ;
    const bundled = bench.compile(.{ .bundle = packet }) orelse return error.Compile;
    try std.testing.expect(bundled.modules.len == 2);
    const second = (try prepared.prepare(std.testing.allocator, bundled)).ok;
    defer second.destroy();
    try ownsAll(second);
    const expected_bundle = try bench.freshVm(.{ .bundle = packet }, .{});
    _ = bench.compile(.{ .file = "Q:i64 = 1" }).?;
    try expectSame("bundle", "VM", 0, expected_bundle, try bench.preparedVm(second, .{}));
}

test "prepared: each admission refuses a forgery of its own representation that the other accepts" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text = "F(N:i64)<computes>:i64 = N + 1\nA<public>:i64 = F(41)\nB<public>:string = \"b\"";
    const program = bench.compile(.{ .file = text }).?;
    const nodes = try std.testing.allocator.dupe(types.Node, program.nodes);
    defer std.testing.allocator.free(nodes);
    const code = try std.testing.allocator.alloc(vm.Instruction, program.nodes.len);
    defer std.testing.allocator.free(code);
    for (program.nodes, code) |node, *instruction| instruction.* = vm.instructionFromNode(node);
    // The honest pair is admitted by both.
    const honest = (try prepared.prepareLowered(std.testing.allocator, program, code)).ok;
    honest.destroy();
    const scratch_registers = scratch.alloc(types.Type, types.limits.nodes) orelse return error.OutOfMemory;
    defer scratch.free(scratch_registers);
    const registers = scratch_registers[0..types.limits.nodes];
    // Forged bytecode over honest IR: the reference admission accepts the IR, the VM refuses.
    const integer = for (code, 0..) |instruction, index| {
        if (instruction.op == .integer) break index;
    } else return error.TestUnexpectedResult;
    const kept = code[integer];
    code[integer].value_type = .string;
    try std.testing.expect(evaluator.validate(program, program.nodes.len) == null);
    try std.testing.expect(vm.verify(bytecode.borrow(program, code), registers) == .failed);
    const forged_code = try prepared.prepareLowered(std.testing.allocator, program, code);
    try std.testing.expectEqual(prepared.Admission.vm, forged_code.failed.by);
    try std.testing.expectEqual(types.Diagnostic.Code.invalid_ir, forged_code.failed.diagnostic.code);
    code[integer] = kept;
    // Forged IR with honest bytecode: the VM accepts its bytecode, the reference refuses the IR.
    var forged = program;
    forged.nodes = nodes;
    nodes[integer].value_type = .string;
    try std.testing.expect(vm.verify(bytecode.borrow(forged, code), registers) == .ok);
    try std.testing.expect(evaluator.validate(forged, forged.nodes.len) != null);
    const forged_ir = try prepared.prepareLowered(std.testing.allocator, forged, code);
    try std.testing.expectEqual(prepared.Admission.reference, forged_ir.failed.by);
    // Raw forged IR still reaches both checked entry points and is refused by each.
    try std.testing.expect(evaluator.evaluateWithRuntimeStorage(forged, &bench.reference_run.values, &bench.reference_run.members, &bench.reference_run.control, &bench.reference_run.state, &bench.reference_run.frames, 1000) == .failed);
    scratch.initialise(bench.fresh_vm);
    try std.testing.expect(bench.fresh_vm.evaluate(forged, 1000) == .failed);
    // `prepare` lowers the forged IR itself, so the VM refuses the bytecode made from it first.
    const lowered = try prepared.prepare(std.testing.allocator, forged);
    try std.testing.expectEqual(prepared.Admission.vm, lowered.failed.by);
    // Bytecode that both machines admit but that is not the lowering of the IR: the literal
    // 41 becomes 42, well typed. Each admission accepts its own input; the handle is refused.
    const literal = for (code, 0..) |instruction, index| {
        if (instruction.op == .integer and instruction.op.integer == 41) break index;
    } else return error.TestUnexpectedResult;
    code[literal].op.integer = 42;
    try std.testing.expect(vm.verify(bytecode.borrow(program, code), registers) == .ok);
    const mismatched = try prepared.prepareLowered(std.testing.allocator, program, code);
    try std.testing.expectEqual(prepared.Admission.lowering, mismatched.failed.by);
    code[literal].op.integer = 41;
    // Bytecode of another length is refused too (here by the VM's own count of its operations).
    try std.testing.expect(try prepared.prepareLowered(std.testing.allocator, program, code[0 .. code.len - 1]) == .failed);
    // Lengths beyond what a compiled program can have are refused before anything is read or
    // allocated: an allocator that fails at once is never asked.
    var never = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oversized = program;
    oversized.nodes = nodes.ptr[0 .. types.limits.nodes + 1];
    try std.testing.expectEqual(prepared.Admission.reference, (try prepared.prepare(never.allocator(), oversized)).failed.by);
    var field: [1]types.Field = undefined;
    oversized = program;
    oversized.fields = @as([*]const types.Field, &field)[0 .. types.limits.fields + 1];
    try std.testing.expectEqual(prepared.Admission.reference, (try prepared.prepare(never.allocator(), oversized)).failed.by);
    oversized = program;
    oversized.file_paths = @as([*]const u8, text)[0 .. types.limits.module_file_paths_bytes + 1];
    try std.testing.expectEqual(prepared.Admission.reference, (try prepared.prepare(never.allocator(), oversized)).failed.by);
    oversized = program;
    var wide = program.natives[0];
    wide.params = &.{ wide.result, wide.result, wide.result, wide.result, wide.result };
    oversized.natives = &.{wide};
    try std.testing.expectEqual(prepared.Admission.reference, (try prepared.prepare(never.allocator(), oversized)).failed.by);
    const too_long = code.ptr[0 .. types.limits.nodes + 1];
    try std.testing.expectEqual(prepared.Admission.vm, (try prepared.prepareLowered(never.allocator(), program, too_long)).failed.by);
    try std.testing.expectEqual(@as(usize, 0), never.allocations);
    // A host allocator that fails leaves nothing behind (the testing allocator checks).
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, prepared.prepare(failing.allocator(), program));
}

test "prepared: a run leaves nothing to the next: cells, fuel, handles, output and failures" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text =
        \\var Count:i64 = 0
        \\Bump(N:i64)<transacts>:i64 = Block{ set Count = Count + N; Count }
        \\Kept<public>:i64 = Iterate(Bump, 10, 1)
        \\Line<public>:string = Attempt(Block{ R := OpenReader["config"]; R.ReadLine[] }, "none")
        \\Said<public>:i64 = Block{ Print("count {Count}"); Count }
        \\Lost<public>:i64 = Attempt(Block{ set Count = 1000; Require[Count < 0]; Count }, -1)
        \\After<public>:i64 = Count
        \\Draw<public>:i64 = GetRandomInt(1, 1000000)
    ;
    const handle = (try prepared.prepare(std.testing.allocator, bench.compile(.{ .file = text }).?)).ok;
    defer handle.destroy();
    var grants = [_]effects.Grant{grant_pool[0]};
    const plans = [_]prepared.Options{
        .{ .grants = &grants, .seed = 1 },
        // Fuel runs out in the middle: cells written, a reader opened, output pending.
        .{ .grants = &grants, .seed = 2, .work_budget = 60 },
        .{ .seed = 3 },
        .{ .grants = &grants, .seed = 1 },
        .{ .grants = &grants, .seed = 4, .trace = .digest },
        .{ .seed = 3, .work_budget = 5 },
        .{ .grants = &grants, .seed = 1 },
    };
    var first: ?[32]u8 = null;
    for (plans, 0..) |options, step| {
        const expected_vm = try bench.freshVm(.{ .file = text }, options);
        try expectSame("leak", "VM", step, expected_vm, try bench.preparedVm(handle, options));
        const expected_reference = try bench.freshReference(.{ .file = text }, options);
        try expectSame("leak", "reference", step, expected_reference, try bench.preparedReference(handle, options));
        // The same choices give the same transcript, whatever ran between.
        if (options.seed == 1) {
            if (first) |kept| try std.testing.expectEqualSlices(u8, &kept, &expected_reference.digest) else first = expected_reference.digest;
        }
    }
    const last = (try handle.runVm(bench.vm_run, .{ .grants = &grants, .seed = 1, .source = bench.script.source() })).ok;
    try std.testing.expectEqual(@as(i64, 512), last.get("Kept").?.integer);
    try std.testing.expectEqual(@as(i64, 512), last.get("After").?.integer);
}

test "prepared: every run checks its own grants and choices" {
    const bench = try Bench.create();
    defer bench.destroy();
    const handle = (try prepared.prepare(std.testing.allocator, bench.compile(.{ .file = "A<public>:i64 = Attempt(Block{ R := OpenReader[\"config\"]; 1 }, 0)" }).?)).ok;
    defer handle.destroy();
    var granted = [_]effects.Grant{grant_pool[0]};
    var other = [_]effects.Grant{grant_pool[2]};
    const expect = struct {
        fn value(result: evaluator.Result, wanted: i64) !void {
            try std.testing.expectEqual(wanted, result.ok.get("A").?.integer);
        }
    };
    for (0..2) |_| {
        try expect.value(try handle.runVm(bench.vm_run, .{ .grants = &granted }), 1);
        try expect.value(try handle.runReference(bench.reference_run, .{ .grants = &granted }), 1);
        try expect.value(try handle.runVm(bench.vm_run, .{}), 0);
        try expect.value(try handle.runReference(bench.reference_run, .{ .grants = &other }), 0);
        try expect.value(try handle.runVm(bench.vm_run, .{ .grants = &other }), 0);
    }
    // A list no host may give, and a clock no run may have, are refused before the run.
    var twice = [_]effects.Grant{ grant_pool[0], grant_pool[0] };
    try std.testing.expectError(error.InvalidOptions, handle.runVm(bench.vm_run, .{ .grants = &twice }));
    try std.testing.expectError(error.InvalidOptions, handle.runReference(bench.reference_run, .{ .tick_rate = 0 }));
    try std.testing.expectError(error.InvalidOptions, handle.runVm(bench.vm_run, .{ .tick_rate = types.Scheduler.max_tick_rate + 1 }));
    try expect.value(try handle.runVm(bench.vm_run, .{ .grants = &granted }), 1);
}

test "prepared: the report of a prepared run is replayed and validated by itself" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text = "Step(S:i64)<computes>:i64 = S + 1\nJoin(S:string)<computes>:string = S + \"x\"\nA<public>:i64 = Iterate(Step, 40, 0)\nT<public>:string = Iterate(Join, 6, \"a\")";
    const handle = (try prepared.prepare(std.testing.allocator, bench.compile(.{ .file = text }).?)).ok;
    defer handle.destroy();
    const options: prepared.Options = .{ .trace = .digest, .trace_window = 3 };
    const expected = try bench.freshVm(.{ .file = text }, options);
    const validated = evaluator.validations;
    try expectSame("replay", "VM", 0, expected, try bench.preparedVm(handle, options));
    // The replay's second run went through the checked entry point: it admitted the IR again.
    try std.testing.expect(evaluator.validations > validated);
    const run = (try handle.runVm(bench.vm_run, options)).ok;
    try std.testing.expect(run.trace == .digest);
    var out = std.Io.Writer.fixed(bench.expected);
    scratch.initialise(bench.replay);
    _ = try reporting.writeReplayed(&out, run, bench.replay.producer(handle.replayProgram(&bench.vm_run.strings), options.work_budget), false, .{});
    // A forged result is refused, prepared handle or not.
    var forged = run;
    const values = try std.testing.allocator.dupe(types.Value, run.values);
    defer std.testing.allocator.free(values);
    const a = for (run.program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name.text(run.program.source), "A")) break binding.node;
    } else unreachable;
    values[a] = .{ .integer = 41 };
    forged.values = values;
    out = .fixed(bench.expected);
    scratch.initialise(bench.replay);
    try std.testing.expectError(error.InvalidExecution, reporting.writeReplayed(&out, forged, bench.replay.producer(handle.replayProgram(&bench.vm_run.strings), options.work_budget), false, .{}));
    // And so is a replay of IR forged after the run: the replay admits what it is given.
    const nodes = try std.testing.allocator.dupe(types.Node, run.program.nodes);
    defer std.testing.allocator.free(nodes);
    for (nodes) |*node| if (node.kind == .integer) {
        node.value_type = .string;
        break;
    };
    var program = handle.replayProgram(&bench.vm_run.strings);
    program.nodes = nodes;
    out = .fixed(bench.expected);
    scratch.initialise(bench.replay);
    try std.testing.expectError(error.InvalidExecution, reporting.writeReplayed(&out, run, bench.replay.producer(program, options.work_budget), false, .{}));
}

test "prepared: every run reads and checks the store it is given" {
    const bench = try Bench.create();
    defer bench.destroy();
    const text =
        \\player_stats<public> := struct<persistable>{ Level:i64 = 1, Experience:i64 = 0 }
        \\var Stats<public>:weak_map(persistent_key, player_stats) = map{}
        \\A<public>:i64 = Attempt(Stats[GetPersistentKey["alice"]].Level, -1)
        \\B<public>:i64 = Attempt(Stats[GetPersistentKey["bob"]].Level, -1)
    ;
    const handle = (try prepared.prepare(std.testing.allocator, bench.compile(.{ .file = text }).?)).ok;
    defer handle.destroy();
    var grants = [_]effects.Grant{ .{ .kind = .writer, .name = "log" }, .{ .kind = .key, .name = "alice" }, .{ .kind = .key, .name = "bob" } };
    const first = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":3,\"x_Experience\":7}" }};
    const second = [_]effects.Stored{
        .{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":5,\"x_Experience\":0}" },
        .{ .request = effects.loadRequest(0, 2), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":9,\"x_Experience\":1}" },
    };
    // An entry that is not a value of the cell's type is refused by the run that loads it.
    const broken = [_]effects.Stored{.{ .request = effects.loadRequest(0, 1), .text = "{\"$package_name\":\"/\",\"$class_name\":\"player_stats\",\"x_Level\":\"three\"}" }};
    const stores = [_][]const effects.Stored{ &first, &second, &broken, &.{}, &first };
    const wanted = [_]?[2]i64{ .{ 3, -1 }, .{ 5, 9 }, null, .{ -1, -1 }, .{ 3, -1 } };
    for (stores, wanted, 0..) |store, values, step| {
        bench.script.store = store;
        const options: prepared.Options = .{ .grants = &grants };
        try expectSame("store", "VM", step, try bench.freshVm(.{ .file = text }, options), try bench.preparedVm(handle, options));
        try expectSame("store", "reference", step, try bench.freshReference(.{ .file = text }, options), try bench.preparedReference(handle, options));
        bench.script.rewind();
        const result = try handle.runVm(bench.vm_run, bench.world(options));
        if (values) |pair| {
            try std.testing.expectEqual(pair[0], result.ok.get("A").?.integer);
            try std.testing.expectEqual(pair[1], result.ok.get("B").?.integer);
        } else try std.testing.expect(result == .failed);
    }
}
