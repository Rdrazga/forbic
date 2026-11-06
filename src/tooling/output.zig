//! Standard output and error of the command-line tools.
//!
//! Two things go wrong when a tool's output is a pipe rather than a file, and both are handled
//! here so every tool ends the same way:
//!
//! - On Windows a pipe may have been opened for asynchronous I/O by the process that created it
//!   (MSYS and Git Bash do this for `a | b`). A write to such a handle returns `PENDING` once the
//!   pipe's buffer (64 KiB there) is full, and `std.Io.File.stdout()` describes every standard
//!   handle as synchronous, so the standard library reaches `unreachable`: a panic in safe builds
//!   and undefined behaviour in fast ones. `standard` asks the handle how it was opened and
//!   describes it truthfully, after which the library waits for the write to complete.
//! - A reader may close its end before the tool has finished (`forbic inspect F | head -1`). That
//!   is not a fault of the tool: `conclude` ends it without a message and without an error
//!   trace, with the status a shell reports for a process stopped by `SIGPIPE`.
const std = @import("std");
const builtin = @import("builtin");
const File = std.Io.File;

/// What a POSIX shell reports for a command ended by `SIGPIPE` (128 + 13). Used on every
/// platform, so that scripts see one value for "the reader went away".
pub const closed_status: u8 = 141;
/// Any other failure to write output: the device is full, the handle is invalid.
pub const failed_status: u8 = 1;

pub const Stream = enum { stdout, stderr };

/// The standard handle, with `nonblocking` set when the handle really is asynchronous.
pub fn standard(stream: Stream) File {
    return describe(switch (stream) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    });
}

/// A handle this process was given rather than opened, described as it really is.
pub fn describe(file: File) File {
    var described = file;
    if (builtin.os.tag == .windows) described.flags.nonblocking = asynchronous(file.handle);
    return described;
}

/// Whether a Windows handle was opened without either synchronous-I/O option. A handle that
/// cannot be asked (a closed or detached standard handle) is left as the library describes it;
/// writing to it fails with an ordinary error.
fn asynchronous(handle: std.os.windows.HANDLE) bool {
    if (builtin.os.tag != .windows) unreachable;
    const windows = std.os.windows;
    var block: windows.IO_STATUS_BLOCK = undefined;
    var information: windows.FILE.MODE.INFORMATION = undefined;
    const status = windows.ntdll.NtQueryInformationFile(handle, &block, &information, @sizeOf(windows.FILE.MODE.INFORMATION), .Mode);
    if (status != .SUCCESS) return false;
    return information.Mode.IO == .ASYNCHRONOUS;
}

/// A writer and the place where its implementation records why a write failed.
/// `std.Io.Writer` reports only `WriteFailed`; the reason stays with the implementation.
pub const Sink = struct {
    writer: *std.Io.Writer,
    cause: *const ?File.Writer.Error,

    pub fn of(writer: *File.Writer) Sink {
        return .{ .writer = &writer.interface, .cause = &writer.err };
    }

    fn closed(self: Sink) bool {
        const cause = self.cause.* orelse return false;
        return cause == error.BrokenPipe;
    }
};

/// Turns the outcome of a tool's work into its exit status, flushing both streams.
///
/// `result` is what the tool computed while writing to `out` and `err`. A failure that is not a
/// write failure is returned unchanged. A write failure is attributed through the sinks: a closed
/// reader gives `closed_status` and silence; another cause on standard output is named once on
/// standard error and gives `failed_status`. A write failure neither sink explains (an internal
/// writer the tool did not handle) stays an error.
pub fn conclude(result: anyerror!u8, out: Sink, err: Sink) anyerror!u8 {
    const status = result catch |problem| {
        if (problem != error.WriteFailed) return problem;
        return writeFailed(out, err);
    };
    out.writer.flush() catch return writeFailed(out, err);
    err.writer.flush() catch return writeFailed(out, err);
    return status;
}

fn writeFailed(out: Sink, err: Sink) anyerror!u8 {
    if (out.closed() or err.closed()) {
        // What was already produced on the stream that is still open belongs to the user:
        // diagnostics when the reader of the output left, output when standard error closed.
        if (!out.closed()) out.writer.flush() catch {};
        if (!err.closed()) err.writer.flush() catch {};
        return closed_status;
    }
    if (out.cause.*) |cause| {
        // Standard error may be the stream that is failing; then there is nobody to tell.
        if (err.cause.* == null) {
            err.writer.print("error: cannot write output ({s})\n", .{@errorName(cause)}) catch {};
            err.writer.flush() catch {};
        }
        return failed_status;
    }
    if (err.cause.* != null) {
        // Only standard error is failing: the output is still deliverable.
        out.writer.flush() catch {};
        return failed_status;
    }
    return error.WriteFailed;
}

/// A writer for tests that behaves like a slow or closing pipe: it accepts at most `step` bytes
/// per call, keeps what it accepted in `accepted`, and fails with `failure` once `limit` bytes
/// have been accepted.
pub const Faulty = struct {
    interface: std.Io.Writer,
    accepted: *std.Io.Writer,
    step: usize,
    limit: usize = std.math.maxInt(usize),
    failure: File.Writer.Error = error.BrokenPipe,
    count: usize = 0,
    calls: usize = 0,
    err: ?File.Writer.Error = null,

    pub fn init(buffer: []u8, accepted: *std.Io.Writer, step: usize) Faulty {
        std.debug.assert(step > 0);
        return .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer }, .accepted = accepted, .step = step };
    }

    pub fn sink(self: *Faulty) Sink {
        return .{ .writer = &self.interface, .cause = &self.err };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Faulty = @alignCast(@fieldParentPtr("interface", writer));
        self.calls += 1;
        // Like a file: the buffered bytes go first, then the first piece that has any.
        const pattern = data[data.len - 1];
        var piece: []const u8 = writer.buffered();
        if (piece.len == 0) for (data[0 .. data.len - 1]) |bytes| {
            if (bytes.len == 0) continue;
            piece = bytes;
            break;
        };
        if (piece.len == 0 and splat != 0) piece = pattern;
        if (piece.len == 0) return 0;
        if (self.count >= self.limit) {
            self.err = self.failure;
            return error.WriteFailed;
        }
        const amount = @min(piece.len, self.step, self.limit - self.count);
        self.accepted.writeAll(piece[0..amount]) catch unreachable;
        self.count += amount;
        return writer.consume(amount);
    }
};

fn produce(out: *std.Io.Writer) !u8 {
    for (0..4000) |index| {
        try out.print("{d}:", .{index});
        try out.splatByteAll('x', index % 37);
        try out.writeAll("\n");
    }
    return 0;
}

test "tool output survives a pipe that accepts a few bytes at a time" {
    const expected = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(expected);
    var whole: std.Io.Writer = .fixed(expected);
    try std.testing.expectEqual(@as(u8, 0), try produce(&whole));
    try std.testing.expect(whole.buffered().len > 64 * 1024);
    const actual = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(actual);
    for ([_]usize{ 1, 3, 4095, 4096, 4097 }) |step| for ([_]usize{ 0, 1, 64, 4096 }) |buffered| {
        var accepted: std.Io.Writer = .fixed(actual);
        var buffer: [4096]u8 = undefined;
        var pipe: Faulty = .init(buffer[0..buffered], &accepted, step);
        var no_cause: ?File.Writer.Error = null;
        var silent_bytes: [64]u8 = undefined;
        var silent: std.Io.Writer = .fixed(&silent_bytes);
        const status = try conclude(produce(&pipe.interface), pipe.sink(), .{ .writer = &silent, .cause = &no_cause });
        try std.testing.expectEqual(@as(u8, 0), status);
        try std.testing.expectEqualStrings(whole.buffered(), accepted.buffered());
        try std.testing.expectEqualStrings("", silent.buffered());
        if (step == 1 and buffered == 0) try std.testing.expect(pipe.calls >= whole.buffered().len);
    };
}

test "a reader that closes early ends the tool quietly and other write failures are named" {
    const actual = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(actual);
    var no_cause: ?File.Writer.Error = null;
    for ([_]usize{ 0, 1, 4096, 70_000 }) |limit| {
        var accepted: std.Io.Writer = .fixed(actual);
        var buffer: [4096]u8 = undefined;
        var pipe: Faulty = .init(&buffer, &accepted, 1024);
        pipe.limit = limit;
        var message_bytes: [128]u8 = undefined;
        var message: std.Io.Writer = .fixed(&message_bytes);
        try std.testing.expectEqual(closed_status, try conclude(produce(&pipe.interface), pipe.sink(), .{ .writer = &message, .cause = &no_cause }));
        try std.testing.expectEqual(limit, accepted.buffered().len);
        try std.testing.expectEqualStrings("", message.buffered());

        accepted = .fixed(actual);
        pipe = .init(&buffer, &accepted, 1024);
        pipe.limit = limit;
        pipe.failure = error.NoSpaceLeft;
        message = .fixed(&message_bytes);
        try std.testing.expectEqual(failed_status, try conclude(produce(&pipe.interface), pipe.sink(), .{ .writer = &message, .cause = &no_cause }));
        try std.testing.expectEqualStrings("error: cannot write output (NoSpaceLeft)\n", message.buffered());
    }
}

test "a failure that surfaces only at the final flush is still classified" {
    var accepted_bytes: [64]u8 = undefined;
    var accepted: std.Io.Writer = .fixed(&accepted_bytes);
    var buffer: [4096]u8 = undefined;
    var pipe: Faulty = .init(&buffer, &accepted, 8);
    pipe.limit = 4;
    var no_cause: ?File.Writer.Error = null;
    var message_bytes: [64]u8 = undefined;
    var message: std.Io.Writer = .fixed(&message_bytes);
    // Everything fits the tool's buffer, so the work itself succeeds with status 3.
    try pipe.interface.writeAll("short answer\n");
    try std.testing.expectEqual(closed_status, try conclude(3, pipe.sink(), .{ .writer = &message, .cause = &no_cause }));
    try std.testing.expectEqualStrings("shor", accepted.buffered());
}

test "standard error closing, unexplained write failures and other errors" {
    var accepted_bytes: [64]u8 = undefined;
    var accepted: std.Io.Writer = .fixed(&accepted_bytes);
    var out_buffer: [16]u8 = undefined;
    var out: Faulty = .init(&out_buffer, &accepted, 8);
    var lost_bytes: [64]u8 = undefined;
    var lost: std.Io.Writer = .fixed(&lost_bytes);
    var err_buffer: [16]u8 = undefined;
    var err: Faulty = .init(&err_buffer, &lost, 8);
    err.limit = 0;
    try err.interface.writeAll("diagnostic\n");
    try out.interface.writeAll("kept\n");
    // The diagnostic cannot be delivered; the status says why and nothing is retried forever.
    try std.testing.expectEqual(closed_status, try conclude(1, out.sink(), err.sink()));
    try std.testing.expectEqualStrings("kept\n", accepted.buffered());

    var no_cause: ?File.Writer.Error = null;
    var fixed_bytes: [8]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&fixed_bytes);
    var quiet_bytes: [8]u8 = undefined;
    var quiet: std.Io.Writer = .fixed(&quiet_bytes);
    const plain: Sink = .{ .writer = &fixed, .cause = &no_cause };
    try std.testing.expectError(error.WriteFailed, conclude(error.WriteFailed, plain, .{ .writer = &quiet, .cause = &no_cause }));
    try std.testing.expectError(error.OutOfMemory, conclude(error.OutOfMemory, plain, .{ .writer = &quiet, .cause = &no_cause }));
    try std.testing.expectEqual(@as(u8, 2), try conclude(2, plain, .{ .writer = &quiet, .cause = &no_cause }));
}

test "output already produced is delivered when standard error is the stream that fails during the work" {
    for ([_]File.Writer.Error{ error.BrokenPipe, error.NoSpaceLeft }, [_]u8{ closed_status, failed_status }) |failure, expected| {
        var accepted_bytes: [64]u8 = undefined;
        var accepted: std.Io.Writer = .fixed(&accepted_bytes);
        var out_buffer: [4096]u8 = undefined;
        var out: Faulty = .init(&out_buffer, &accepted, 4096);
        var lost_bytes: [64]u8 = undefined;
        var lost: std.Io.Writer = .fixed(&lost_bytes);
        var err_buffer: [16]u8 = undefined;
        var err: Faulty = .init(&err_buffer, &lost, 8);
        err.limit = 0;
        err.failure = failure;
        try out.interface.writeAll("answer\n");
        // The diagnostic does not fit the buffer, so the work itself sees the write fail.
        const work: anyerror!u8 = if (err.interface.writeAll("a warning longer than the buffer of standard error\n")) @as(u8, 0) else |problem| problem;
        try std.testing.expectError(error.WriteFailed, work);
        try std.testing.expectEqual(expected, try conclude(work, out.sink(), err.sink()));
        try std.testing.expectEqualStrings("answer\n", accepted.buffered());
        try std.testing.expectEqual(@as(usize, 0), out.interface.buffered().len);
    }
}

test "standard handles are described as they were opened" {
    // The test runner's own handles: whatever they are, asking must not fail or change them.
    const out = standard(.stdout);
    const err = standard(.stderr);
    try std.testing.expectEqual(File.stdout().handle, out.handle);
    try std.testing.expectEqual(File.stderr().handle, err.handle);
    if (builtin.os.tag != .windows) {
        try std.testing.expect(!out.flags.nonblocking);
        try std.testing.expect(!err.flags.nonblocking);
    }
}

/// Reads one end of a pipe to its end on another thread, as the next process of a pipeline does.
const Drain = struct {
    file: File,
    into: []u8,
    len: usize = 0,

    fn run(self: *Drain) void {
        while (self.len < self.into.len) {
            var parts = [_][]u8{self.into[self.len..]};
            self.len += self.file.readStreaming(std.testing.io, &parts) catch return;
        }
    }
};

test "a Windows pipe opened for asynchronous output is described as such and carries far more than its buffer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const windows = std.os.windows;
    const expected = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(expected);
    var whole: std.Io.Writer = .fixed(expected);
    _ = try produce(&whole);
    const received = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(received);
    // What Git Bash and MSYS hand to `a | b`: a pipe whose writing end is asynchronous. The
    // buffer is 4 KiB, so nearly every write finds it full and has to wait for the reader.
    const pipe = try std.testing.io_instance.windowsCreatePipe(.{
        .server = .{ .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
        .client = .{ .mode = .{ .IO = .ASYNCHRONOUS } },
        .inbound = true,
    });
    const reading: File = .{ .handle = pipe[0], .flags = .{ .nonblocking = false } };
    var drain: Drain = .{ .file = reading, .into = received };
    var writing_open = true;
    var thread: ?std.Thread = null;
    defer {
        if (writing_open) windows.CloseHandle(pipe[1]);
        if (thread) |reader| reader.join();
        windows.CloseHandle(pipe[0]);
    }
    // The library calls every standard handle synchronous; asking the handle corrects that
    // for the end that is not, and changes nothing for the end that is.
    try std.testing.expect(!describe(reading).flags.nonblocking);
    const writing = describe(.{ .handle = pipe[1], .flags = .{ .nonblocking = false } });
    try std.testing.expect(writing.flags.nonblocking);
    thread = try std.Thread.spawn(.{}, Drain.run, .{&drain});
    var buffer: [4096]u8 = undefined;
    var out: File.Writer = .init(writing, std.testing.io, &buffer);
    var silent_bytes: [64]u8 = undefined;
    var silent: std.Io.Writer = .fixed(&silent_bytes);
    const no_cause: ?File.Writer.Error = null;
    const status = try conclude(produce(&out.interface), .of(&out), .{ .writer = &silent, .cause = &no_cause });
    windows.CloseHandle(pipe[1]);
    writing_open = false;
    thread.?.join();
    thread = null;
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualStrings("", silent.buffered());
    try std.testing.expectEqualStrings(whole.buffered(), received[0..drain.len]);
}

test "a Windows pipe whose reader has gone ends the tool quietly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const windows = std.os.windows;
    for ([_]bool{ true, false }) |asynchronous_end| {
        const pipe = try std.testing.io_instance.windowsCreatePipe(.{
            .server = .{ .mode = .{ .IO = .SYNCHRONOUS_NONALERT } },
            .client = .{ .mode = .{ .IO = if (asynchronous_end) .ASYNCHRONOUS else .SYNCHRONOUS_NONALERT } },
            .inbound = true,
        });
        defer windows.CloseHandle(pipe[1]);
        windows.CloseHandle(pipe[0]);
        const writing = describe(.{ .handle = pipe[1], .flags = .{ .nonblocking = false } });
        try std.testing.expectEqual(asynchronous_end, writing.flags.nonblocking);
        var buffer: [4096]u8 = undefined;
        var out: File.Writer = .init(writing, std.testing.io, &buffer);
        var message_bytes: [128]u8 = undefined;
        var message: std.Io.Writer = .fixed(&message_bytes);
        const no_cause: ?File.Writer.Error = null;
        try std.testing.expectEqual(closed_status, try conclude(produce(&out.interface), .of(&out), .{ .writer = &message, .cause = &no_cause }));
        try std.testing.expectEqual(@as(?File.Writer.Error, error.BrokenPipe), out.err);
        try std.testing.expectEqualStrings("", message.buffered());
    }
}
