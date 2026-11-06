//! Bounded developer trace report. Admission completes before any output.
const std = @import("std");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const reporting = @import("value_report.zig");
const modules = @import("modules.zig");
pub const Limits = struct { output_bytes: u64 = types.limits.document_bytes };
pub fn write(out: *std.Io.Writer, execution: evaluator.Execution, fallback_path: []const u8, limits: Limits) (reporting.Error || std.Io.Writer.Error)!void {
    _ = try reporting.validate(execution, false, .{});
    return writeAdmitted(out, execution, fallback_path, limits);
}
/// `write` for a run that kept only the digest of its witness; see `reporting.validateReplayed`.
pub fn writeReplayed(out: *std.Io.Writer, execution: evaluator.Execution, again: types.TraceProducer, fallback_path: []const u8, limits: Limits) (reporting.Error || std.Io.Writer.Error)!void {
    _ = try reporting.validateReplayed(execution, again, false, .{});
    return writeAdmitted(out, execution, fallback_path, limits);
}
fn writeAdmitted(out: *std.Io.Writer, execution: evaluator.Execution, fallback_path: []const u8, limits: Limits) (reporting.Error || std.Io.Writer.Error)!void {
    var buffer: [256]u8 = undefined;
    var counter = reporting.CountingWriter.init(&buffer, limits.output_bytes);
    writeReport(&counter.writer, execution, fallback_path) catch return error.ReportLimit;
    counter.writer.flush() catch return error.ReportLimit;
    try writeReport(out, execution, fallback_path);
}
fn writeReport(out: *std.Io.Writer, execution: evaluator.Execution, fallback_path: []const u8) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = out };
    var scoped = false;
    for (execution.call_steps) |event| if (event.kind == .failure) {
        scoped = true;
        break;
    };
    // A digest run kept the number of such steps instead of the steps; the replay checked it.
    if (execution.trace == .digest and execution.witness.failures != 0) scoped = true;
    try json.beginObject();
    try json.objectField("format");
    try json.write(@as(u8, if (scoped) 2 else 1));
    try json.objectField("failure_count");
    try json.write(execution.failure_count);
    try json.objectField("truncated");
    try json.write(execution.failures.len < execution.failure_count);
    try json.objectField("failures");
    try json.beginArray();
    const p = execution.program;
    for (execution.failures) |trace| {
        const problem = modules.locateIn(p, .{ .span = trace.span, .code = trace.code }, fallback_path);
        const location = problem.diagnostic.location(problem.source);
        if (scoped) try json.write(.{ .instruction = trace.instruction, .function = trace.function, .local_instruction = trace.pc, .code = @tagName(trace.code), .reason = trace.reason, .path = problem.path, .span = problem.diagnostic.span, .line = location.line, .column = location.column }) else try json.write(.{ .instruction = trace.instruction, .code = @tagName(trace.code), .reason = trace.reason, .path = problem.path, .span = problem.diagnostic.span, .line = location.line, .column = location.column });
    }
    try json.endArray();
    try json.endObject();
    try out.writeByte('\n');
}
