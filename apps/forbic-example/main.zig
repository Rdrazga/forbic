//! TASK-0109, W4.4: an example host of the Forbic embedding API, a tiny orders service.
//!
//! `forbic-example WORK_DIR` registers one native (a tax rate lookup over the host's table),
//! compiles and prepares `orders.forb` once, quotes a batch of requests in memory (nothing is
//! saved), then serves the same batch as a durable run whose customers' records are kept in
//! `WORK_DIR/state`. Run it twice on one directory: the second run's records start where the
//! first run's ended. See `README.md` and `docs/embedding.md`.
const std = @import("std");
const embed = @import("forbic_embed");

/// The capacities of real programs; a host chooses its profile as the `forbic` tool does.
pub const forbic_profile_name = "program";

/// The host's tax table: what the native reads through its context.
const TaxTable = struct {
    regions: []const []const u8,
    basis_points: []const i64,
};

/// `orders.tax_rate(Region:string):?i64`: a function of its argument and of the table, which
/// the host does not change while the program can run.
fn taxRate(context: *embed.native.Context, region: []const u8) ?i64 {
    const table = context.hostContext(TaxTable) orelse return null;
    for (table.regions, table.basis_points) |name, rate| {
        if (std.mem.eql(u8, name, region)) return rate;
    }
    return null;
}

/// Today's requests: the last one names a region the table does not have.
const requests =
    \\acme EU 3 10
    \\globex US 1 250
    \\acme EU 2 5
    \\initech MARS 1 1
    \\
;
const customers = [_][]const u8{ "acme", "globex", "initech" };

/// The durable run's visitor: the program's `Revenue`, given while the run's storage lives.
const Served = struct {
    out: *std.Io.Writer,

    pub fn completed(self: *Served, run: embed.Completed) !void {
        const revenue = (try run.value("Revenue")) orelse return error.NoRevenue;
        try self.out.print("revenue: {d}\n", .{revenue.integer});
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const out = &stdout_file.interface;
    const err = &stderr_file.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        try err.writeAll("usage: forbic-example WORK_DIR\n");
        return 2;
    }
    const work = args[1];

    // The natives: the standard ones, and the host's tax lookup with its table.
    const taxes: TaxTable = .{ .regions = &.{ "EU", "US" }, .basis_points = &.{ 2000, 700 } };
    var storage: [embed.standard_natives + 1]embed.native.Entry = undefined;
    var natives = try embed.Natives.init(&storage);
    try natives.registerWith(TaxTable, &taxes, embed.native.entry("orders.tax_rate", taxRate, .{ .base = 1, .per_element = 1 }));

    // Compile and prepare once; the compiler is not needed after.
    const program = prepared: {
        const compiler = try embed.Compiler.create(gpa);
        defer compiler.destroy();
        const compiled = try compiler.compile(.{ .text = .{ .name = "orders.forb", .bytes = @embedFile("orders.forb") } }, .{ .natives = &natives });
        const compilation = switch (compiled) {
            .ok => |compilation| compilation,
            .failed => |failure| {
                try failure.write(err, .excerpt);
                return 1;
            },
        };
        break :prepared switch (try embed.prepare(gpa, compilation)) {
            .ok => |program| program,
            .refused => |refusal| {
                try refusal.diagnostic.write(err, .plain);
                return 1;
            },
        };
    };
    defer program.destroy();

    // A quote: the batch in memory, from the host's own buffer. Without a state directory every
    // customer starts afresh and nothing is saved.
    try out.writeAll("quote (in memory, nothing saved):\n");
    const worker = try embed.Worker.create(gpa);
    defer worker.destroy();
    var lines: std.Io.Reader = .fixed(requests);
    var grants: [1 + customers.len]embed.Grant = undefined;
    grants[0] = .{ .reader = .{ .name = "requests", .from = &lines } };
    for (customers, grants[1..]) |name, *grant| grant.* = .{ .key = name };
    switch (try program.run(worker, .{ .grants = &grants, .output = out })) {
        .completed => |quote| try out.print("quoted revenue: {d}\n", .{(try quote.value("Revenue")).?.integer}),
        .failed => |diagnostic| {
            try diagnostic.write(err, .excerpt);
            return 1;
        },
    }

    // The orders: a durable run, which reads the batch from a file and keeps the customers'
    // records in the state directory.
    var path_bytes: [2][std.Io.Dir.max_path_bytes]u8 = undefined;
    const requests_path = try std.fmt.bufPrint(&path_bytes[0], "{s}/requests.txt", .{work});
    const state = try std.fmt.bufPrint(&path_bytes[1], "{s}/state", .{work});
    try std.Io.Dir.cwd().createDirPath(io, work);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = requests_path, .data = requests });
    var file_grants: [1 + customers.len]embed.FileGrant = undefined;
    file_grants[0] = .{ .reader = .{ .name = "requests", .path = requests_path } };
    for (customers, file_grants[1..]) |name, *grant| grant.* = .{ .key = name };
    try out.writeAll("orders (kept in the state directory):\n");
    var served: Served = .{ .out = out };
    const outcome = try program.runDurable(io, gpa, .{ .state = state, .grants = &file_grants, .output = out, .messages = err }, &served);
    return switch (outcome) {
        .completed => 0,
        .nothing_ran => 0,
        .failed => 1,
    };
}
