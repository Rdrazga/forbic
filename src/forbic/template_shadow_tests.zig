//! The bodies of templates are shadow-checked from their tokens where the template is declared
//! (RFC-0076, `fix2`): a generic function's locals against each other and against the
//! parameters of the `Fn`s around them, and the members of a parametric type: method
//! parameters, the locals of method bodies, field defaults and `Block{...}` clauses. A
//! template nobody instantiates is not exempt, and what this check finds is exactly what
//! compiling the body would find, with the same diagnostic.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const harness = @import("generic_function_tests.zig");

const Outcome = struct { code: ?types.Diagnostic.Code, at: u32, related: ?u32 };

/// What compiling `source` says, with positions taken relative to `base` (the start of the
/// text both forms share).
fn outcome(h: *harness.Harness, source: []const u8, base: usize) Outcome {
    return switch (h.front.compile(source)) {
        .ok => .{ .code = null, .at = 0, .related = null },
        .failed => |d| .{ .code = d.code, .at = @intCast(d.span.start -| base), .related = if (d.related.start != d.related.end) @intCast(d.related.start -| base) else null },
    };
}

fn expectSame(h: *harness.Harness, template: []const u8, template_base: usize, plain: []const u8, plain_base: usize) !void {
    const a = outcome(h, template, template_base);
    const b = outcome(h, plain, plain_base);
    if (a.code != b.code or (a.code != null and (a.at != b.at or a.related != b.related))) {
        std.debug.print("template:\n{s}\n-> {?s} at {d} ({?d})\nplain:\n{s}\n-> {?s} at {d} ({?d})\n", .{ template, if (a.code) |c| @tagName(c) else null, a.at, a.related, plain, if (b.code) |c| @tagName(c) else null, b.at, b.related });
        return error.TestUnexpectedResult;
    }
}

test "an uncalled generic body is refused for a local that shadows another, as a called one is" {
    const h = try harness.create();
    defer scratch.release(h);
    const bodies = [_]struct { body: []const u8, code: ?types.Diagnostic.Code }{
        .{ .body = "X:=1;Block{X:=2;A}", .code = .shadowed_name },
        .{ .body = "X:=1;X:=2;A", .code = .duplicate_name },
        .{ .body = "X:=1;G:=Fn(X:i64){X};A", .code = .shadowed_name },
        .{ .body = "X:=Block{X:=1;X};A", .code = .shadowed_name },
        .{ .body = "G:=Fn(Y:i64,Y:i64){Y};A", .code = .duplicate_name },
        .{ .body = "G:=Fn(Y:i64){Block{Y:=1;Y}};A", .code = .shadowed_name },
        .{ .body = "G:=Fn(Y:i64)<computes>{Block{Y:=1;Y}};A", .code = .shadowed_name },
        .{ .body = "X:=2;Z:=For(X:array{1}, X);A", .code = .shadowed_name },
        // Siblings and later declarations do not see each other.
        .{ .body = "G:=Fn(X:i64){X};X:=2;A", .code = null },
        .{ .body = "Block{X:=1;X};X:=2;A", .code = null },
        .{ .body = "Z:=For(X:array{1}, X);X:=2;A", .code = null },
        .{ .body = "P:=If(true,Block{X:=1;X},Block{X:=2;X});A", .code = null },
        .{ .body = "G:=Fn(X:i64)<computes>{tuple{X,X}};X:=1;A", .code = null },
        // A name whose initialiser is being read is not seen inside an `Fn` in it.
        .{ .body = "X:=Fn(Y:i64){Block{X:=Y;X}};A", .code = null },
        .{ .body = "X:=Block{Z:=For(Y:array{1}, Block{X:=Y;X});1};A", .code = null },
    };
    var template: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for (bodies) |case| {
        const prefix = "F[T:type](A:T)<computes>:T{Block{";
        const generic = try std.fmt.bufPrint(&template, "{s}{s}}}}}", .{ prefix, case.body });
        const result = outcome(h, generic, 0);
        if (result.code != case.code) {
            std.debug.print("{s}: expected {?s}, got {?s}\n", .{ generic, if (case.code) |c| @tagName(c) else null, if (result.code) |c| @tagName(c) else null });
            return error.TestUnexpectedResult;
        }
        // The same body in a plain function, compiled at once, says the same at the same place.
        const plain_prefix = "F(A:i64)<computes>:i64=Block{";
        const ordinary = try std.fmt.bufPrint(&plain, "{s}{s}}}", .{ plain_prefix, case.body });
        try expectSame(h, generic, prefix.len, ordinary, plain_prefix.len);
        // And called, it says the same again: the check ran where it was declared.
        const called = try std.fmt.bufPrint(&plain, "{s}\nY0:i64=F[i64](1)", .{generic});
        try expectSame(h, generic, 0, called, 0);
    }
}

test "the members of an uninstantiated parametric type are shadow-checked as an instantiation checks them" {
    const h = try harness.create();
    defer scratch.release(h);
    const members = [_]struct { members: []const u8, code: ?types.Diagnostic.Code }{
        .{ .members = "M(A:i64)<computes>:i64=Block{X:=2;A}", .code = .shadowed_name },
        .{ .members = "M(A:i64)<computes>:i64=Block{A:=2;A}", .code = .shadowed_name },
        .{ .members = "M(A:i64)<computes>:i64=Block{M:=2;A}", .code = .shadowed_name },
        .{ .members = "M(X:i64)<computes>:i64=X", .code = .shadowed_name },
        .{ .members = "M(A:i64,A:i64)<computes>:i64=A", .code = .duplicate_name },
        .{ .members = "M(M:i64)<computes>:i64=M", .code = .shadowed_name },
        .{ .members = "F:i64=Block{Y:=1;Block{Y:=2;Y}}", .code = .shadowed_name },
        .{ .members = "F:i64=Block{F:=1;F}", .code = .shadowed_name },
        .{ .members = "M(A:i64)<computes>:i64=Block{Y:=1;Block{Y:=2;A}}", .code = .shadowed_name },
        .{ .members = "M(A:i64)<computes>:i64=Block{G:=Fn(A:i64){A};1}", .code = .shadowed_name },
        .{ .members = "Block{X:=1}", .code = .shadowed_name },
        .{ .members = "var<private> V<public>:i64=Block{V:=1;V}", .code = .shadowed_name },
        // Members do not see each other's parameters or names.
        .{ .members = "F:i64=1\nM(F:i64)<computes>:i64=F", .code = null },
        .{ .members = "M(A:i64)<computes>:i64=A\nN(A:i64)<computes>:i64=A", .code = null },
        .{ .members = "M(A:i64)<computes>:i64=Block{N:=1;A}\nN(B:i64)<computes>:i64=B", .code = null },
        .{ .members = "M(A:i64)<computes>:i64=Block{B:=1;A}\nN(B:i64)<computes>:i64=B", .code = null },
    };
    var template: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for (members) |case| {
        // `X` is a binding of the module, `T` the type parameter, `b` the template.
        const prefix = "X:i64=1\nb[T:type]:=class{";
        const parametric = try std.fmt.bufPrint(&template, "{s}{s}}}", .{ prefix, case.members });
        const result = outcome(h, parametric, 0);
        if (result.code != case.code) {
            std.debug.print("{s}: expected {?s}, got {?s}\n", .{ parametric, if (case.code) |c| @tagName(c) else null, if (result.code) |c| @tagName(c) else null });
            return error.TestUnexpectedResult;
        }
        const plain_prefix = "X:i64=1\nbb:=class{";
        const ordinary = try std.fmt.bufPrint(&plain, "{s}{s}}}", .{ plain_prefix, case.members });
        try expectSame(h, parametric, prefix.len, ordinary, plain_prefix.len);
        const instantiated = try std.fmt.bufPrint(&plain, "{s}\nV:=b[i64]{{}}", .{parametric});
        try expectSame(h, parametric, 0, instantiated, 0);
    }
    // The template's own name and its type parameters.
    const own = [_][]const u8{ "M(A:i64)<computes>:i64=Block{T:=2;A}", "M(b:i64)<computes>:i64=b", "M(A:i64)<computes>:i64=Block{b:=2;A}" };
    for (own) |text| {
        const parametric = try std.fmt.bufPrint(&template, "b[T:type]:=class{{{s}}}", .{text});
        try std.testing.expectEqual(@as(?types.Diagnostic.Code, .shadowed_name), outcome(h, parametric, 0).code);
    }
}

test "a Defer body is not read by the token check, so it refuses only what compiling refuses" {
    const h = try harness.create();
    defer scratch.release(h);
    // The copy of the `Defer` body stands after `Y:=5`, which it does not see: compiling the
    // body accepts it, and so does the token check.
    const source = "Note(N:i64)<transacts>:i64=N\nF[T:type](A:T)<transacts>:T{Block{Defer{Block{Y:=1;Note(Y)}};Y:=5;A}}\nV:i64=F[i64](1)";
    try std.testing.expectEqual(@as(?types.Diagnostic.Code, null), outcome(h, source, 0).code);
}

// Random generic bodies of nested blocks, `Fn`s, `For`s and `If`s over a few names, against
// the same body in a plain function, which is compiled at once: the uncalled generic is refused
// exactly when the plain function is, with the same diagnostic at the same place.
test "random template bodies are refused from their tokens exactly as compiling them refuses them" {
    const h = try harness.create();
    defer scratch.release(h);
    var prng = std.Random.DefaultPrng.init(0x5ad0);
    const random = prng.random();
    const names = [_][]const u8{ "X", "Y", "Z", "A", "W", "P", "Q", "R", "S", "U", "V", "K" };
    var body: [1024]u8 = undefined;
    var template: [1200]u8 = undefined;
    var plain: [1200]u8 = undefined;
    var refused: usize = 0;
    for (0..600) |_| {
        var out = std.Io.Writer.fixed(&body);
        try statements(random, &out, &names, 0);
        const outer = random.boolean();
        const prefix = if (outer) "W:i64=1\nF[T:type](A:i64)<transacts>:i64{Block{" else "F[T:type](A:i64)<transacts>:i64{Block{";
        const plain_prefix = if (outer) "W:i64=1\nF(A:i64)<transacts>:i64=Block{" else "F(A:i64)<transacts>:i64=Block{";
        const generic = try std.fmt.bufPrint(&template, "{s}{s}A}}}}", .{ prefix, out.buffered() });
        const ordinary = try std.fmt.bufPrint(&plain, "{s}{s}A}}", .{ plain_prefix, out.buffered() });
        try expectSame(h, generic, prefix.len, ordinary, plain_prefix.len);
        if (outcome(h, ordinary, 0).code != null) refused += 1;
        // A parametric type's method holds the same body.
        const method_prefix = if (outer) "W:i64=1\nb[T:type]:=class{M(A:i64)<transacts>:i64=Block{" else "b[T:type]:=class{M(A:i64)<transacts>:i64=Block{";
        const class_prefix = if (outer) "W:i64=1\nbb:=class{M(A:i64)<transacts>:i64=Block{" else "bb:=class{M(A:i64)<transacts>:i64=Block{";
        const parametric = try std.fmt.bufPrint(&template, "{s}{s}A}}}}", .{ method_prefix, out.buffered() });
        const class = try std.fmt.bufPrint(&plain, "{s}{s}A}}}}", .{ class_prefix, out.buffered() });
        try expectSame(h, parametric, method_prefix.len, class, class_prefix.len);
    }
    // Both outcomes occur often enough for the comparison to mean something.
    if (refused < 60 or refused > 540) {
        std.debug.print("{d} of 600 refused\n", .{refused});
        return error.TestUnexpectedResult;
    }
}

fn statements(random: std.Random, out: *std.Io.Writer, names: []const []const u8, depth: usize) !void {
    const count = 1 + random.uintLessThan(usize, 2);
    for (0..count) |_| {
        const name = names[random.uintLessThan(usize, names.len)];
        const other = names[random.uintLessThan(usize, names.len)];
        switch (if (depth >= 2) 0 else random.uintLessThan(u8, 7)) {
            0 => try out.print("{s}:=1;", .{name}),
            1 => try out.print("var {s}:i64=1;", .{name}),
            2 => {
                try out.print("{s}:=Block{{", .{name});
                try statements(random, out, names, depth + 1);
                try out.writeAll("1};");
            },
            3 => {
                try out.print("{s}:=Fn({s}:i64){{Block{{", .{ name, other });
                try statements(random, out, names, depth + 1);
                try out.writeAll("1}};");
            },
            4 => {
                try out.print("{s}:=For({s}:array{{1,2}}, Block{{", .{ name, other });
                try statements(random, out, names, depth + 1);
                try out.writeAll("1});");
            },
            5 => {
                try out.print("{s}:=If(true,Block{{", .{name});
                try statements(random, out, names, depth + 1);
                try out.writeAll("1},Block{");
                try statements(random, out, names, depth + 1);
                try out.writeAll("2});");
            },
            else => {
                try out.writeAll("Block{");
                try statements(random, out, names, depth + 1);
                try out.writeAll("1};");
            },
        }
    }
}
