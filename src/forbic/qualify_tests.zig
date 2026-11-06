//! Automatic qualification (RFC-0085, I11): `forbic qualify` prints a program with every
//! identifier in its fully qualified form (the Book's 16:789), from the definitions the compiler
//! resolved. These tests check the forms against the Book's examples, the resolution property of
//! RFC-0085 Part 4 over every conformance fixture, that `verify` refuses tables that break it,
//! and that asking for the table changes nothing else of a compile.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const inspection = @import("inspection.zig");
const qualify = @import("qualify.zig");
const modules = @import("modules.zig");
const bundle_packet = @import("bundle_packet.zig");
const conformance_fixtures = @import("conformance_fixtures.zig");

const Harness = struct {
    compiler: compiler.Workspace,
    inspector: inspection.Workspace,
    packet: bundle_packet.Workspace,
    written: [types.limits.modules]types.Span,
};

fn harness() !*Harness {
    const h = try scratch.storage(Harness);
    scratch.initialise(h);
    return h;
}

const Input = union(enum) { source: []const u8, bundle: modules.Bundle };
const Compiled = union(enum) { ok: types.Program, failed: types.Diagnostic };

fn compileWith(h: *Harness, input: Input, qualifying: bool) Compiled {
    h.compiler.qualify = qualifying;
    return switch (input) {
        .source => |source| switch (h.compiler.compile(source)) {
            .ok => |program| .{ .ok = program },
            .failed => |diagnostic| .{ .failed = diagnostic },
        },
        .bundle => |bundle| switch (h.compiler.compileBundle(bundle)) {
            .ok => |program| .{ .ok = program },
            .failed => |problem| .{ .failed = problem.diagnostic },
        },
    };
}

fn verified(h: *Harness, program: types.Program, text: qualify.Text) ?qualify.Problem {
    return h.compiler.verifyQualification(program, text);
}

fn report(name: []const u8, text: qualify.Text, at: u32, reason: []const u8) void {
    const position = (types.Diagnostic{ .span = .{ .start = at, .end = at }, .code = .unknown_name }).location(text.source);
    std.debug.print("{s}:{d}:{d}: `{s}`: {s}\n", .{ name, position.line, position.column, text.name(at), reason });
}

/// Compiles `input` without the table and with it, and requires the same program both ways (by
/// its inspection), no position noted twice with two meanings, and the resolution property.
/// Writes the qualified text to `out`. Returns false for a program that does not compile.
fn check(h: *Harness, name: []const u8, input: Input, out: *std.Io.Writer) !bool {
    var plain: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer plain.deinit();
    var noted: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer noted.deinit();
    const first = compileWith(h, input, false);
    // Without the flag nothing is noted.
    try std.testing.expectEqual(@as(u32, 0), h.compiler.resolution_count);
    if (first == .ok) _ = try h.inspector.write(&plain.writer, first.ok);
    const second = compileWith(h, input, true);
    defer h.compiler.qualify = false;
    errdefer std.debug.print("fixture {s}\n", .{name});
    try std.testing.expectEqual(first == .ok, second == .ok);
    if (second == .failed) {
        try std.testing.expectEqual(first.failed.code, second.failed.code);
        try std.testing.expectEqual(first.failed.span, second.failed.span);
        return false;
    }
    const text = h.compiler.qualification(second.ok, &h.written);
    // The inspection reads the program, which the table does not touch.
    _ = try h.inspector.write(&noted.writer, second.ok);
    try std.testing.expectEqualStrings(plain.written(), noted.written());
    if (h.compiler.resolution_conflicts != 0) {
        report(name, text, h.compiler.resolution_conflict, "noted with two meanings");
        return error.TestUnexpectedResult;
    }
    if (verified(h, second.ok, text)) |problem| {
        report(name, text, problem.at, problem.reason);
        return error.TestUnexpectedResult;
    }
    try qualify.write(text, out);
    return true;
}

fn expectQualified(h: *Harness, input: Input, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try check(h, "example", input, &out.writer));
    try std.testing.expectEqualStrings(expected, out.written());
}

test "the Book's examples 21 and 22 (16:810, 16:837): parameters, locals, built-in types and members" {
    const h = try harness();
    defer scratch.release(h);
    try expectQualified(h, .{ .source =
        \\ProcessValue(Input:i64, Multiplier:i64)<computes>:i64 = Input * Multiplier
        \\player_class := class{
        \\    var Health:float = 100.0
        \\    TakeDamage(Amount:float)<transacts>:void = Block{ set Self.Health = Self.Health - Amount; 0 }
        \\}
        \\P:player_class = player_class{}
        \\X:i64 = ProcessValue(2, 3)
        \\
    },
        \\(/:)ProcessValue((local:)Input:(/Verse.org/Verse:)i64, (local:)Multiplier:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = (local:)Input * (local:)Multiplier
        \\(/:)player_class := class{
        \\    var (/player_class:)Health:(/Verse.org/Verse:)float = 100.0
        \\    (/player_class:)TakeDamage((local:)Amount:(/Verse.org/Verse:)float)<transacts>:(/Verse.org/Verse:)void = Block{ set Self.(/player_class:)Health = Self.(/player_class:)Health - (local:)Amount; 0 }
        \\}
        \\(/:)P:(/:)player_class = (/:)player_class{}
        \\(/:)X:(/Verse.org/Verse:)i64 = (/:)ProcessValue(2, 3)
        \\
    );
}

test "the Book's example 23 (16:880): a bundle's path, nested modules and the names they reach" {
    const h = try harness();
    defer scratch.release(h);
    const inputs = [_]modules.Input{.{ .path = "YourGame.forb", .source =
        \\GameSystem := module{
        \\    BaseValue:i64 = 42
        \\    Calculator<public> := module{
        \\        Multiplier:i64 = 2
        \\        Calculate<public>(Input:i64)<computes>:i64 = Input * Multiplier + BaseValue
        \\    }
        \\}
        \\Result:i64 = GameSystem.Calculator.Calculate(5)
        \\
    }};
    try expectQualified(h, .{ .bundle = .{ .root = "YourGame.forb", .modules = &inputs } },
        \\# YourGame.forb
        \\(/YourGame:)GameSystem := module{
        \\    (/YourGame/GameSystem:)BaseValue:(/Verse.org/Verse:)i64 = 42
        \\    (/YourGame/GameSystem:)Calculator<public> := module{
        \\        (/YourGame/GameSystem/Calculator:)Multiplier:(/Verse.org/Verse:)i64 = 2
        \\        (/YourGame/GameSystem/Calculator:)Calculate<public>((local:)Input:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = (local:)Input * (/YourGame/GameSystem/Calculator:)Multiplier + (/YourGame/GameSystem:)BaseValue
        \\    }
        \\}
        \\(/YourGame:)Result:(/Verse.org/Verse:)i64 = (/YourGame:)GameSystem.(/YourGame/GameSystem:)Calculator.(/YourGame/GameSystem/Calculator:)Calculate(5)
        \\
    );
}

test "an overloaded call names the overload its arguments pick, and a written qualifier is replaced" {
    const h = try harness();
    defer scratch.release(h);
    const source =
        \\Size(N:i64)<computes>:i64 = N
        \\Size(S:string)<computes>:i64 = S.Length
        \\Start:i64 = 0
        \\light := enum{ (light:)Start, Glow }
        \\Lamp:light = (light:)Start
        \\Mix()<computes>:i64 = Block{(local:)Start:i64 = 5; (local:)Start + Start}
        \\Value:i64 = Size("four") + Size(1) + Mix()
        \\
    ;
    try expectQualified(h, .{ .source = source },
        \\(/:)Size((local:)N:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = (local:)N
        \\(/:)Size((local:)S:(/Verse.org/Verse:)string)<computes>:(/Verse.org/Verse:)i64 = (local:)S.Length
        \\(/:)Start:(/Verse.org/Verse:)i64 = 0
        \\(/:)light := enum{ (/light:)Start, (/light:)Glow }
        \\(/:)Lamp:(/:)light = (/light:)Start
        \\(/:)Mix()<computes>:(/Verse.org/Verse:)i64 = Block{(local:)Start:(/Verse.org/Verse:)i64 = 5; (local:)Start + (local:)Start}
        \\(/:)Value:(/Verse.org/Verse:)i64 = (/:)Size("four") + (/:)Size(1) + (/:)Mix()
        \\
    );
    // The two calls name the two declarations.
    const text = h.compiler.qualification(compileWith(h, .{ .source = source }, true).ok, &h.written);
    defer h.compiler.qualify = false;
    const second = std.mem.indexOf(u8, source, "Size(S").?;
    const first = std.mem.indexOf(u8, source, "Size(N").?;
    try std.testing.expectEqual(@as(u32, @intCast(second)), text.find(@intCast(std.mem.indexOf(u8, source, "Size(\"").?)).?.declared);
    try std.testing.expectEqual(@as(u32, @intCast(first)), text.find(@intCast(std.mem.indexOf(u8, source, "Size(1").?)).?.declared);
}

test "the conformance fixture qualification: its qualified text is its golden" {
    const io = std.testing.io;
    const h = try harness();
    defer scratch.release(h);
    var source_bytes: [8192]u8 = undefined;
    var golden_bytes: [16384]u8 = undefined;
    // Run from a tree without the conformance fixtures (the package alone), there is nothing to check.
    var directory = try conformance_fixtures.open(io, .{}) orelse return error.SkipZigTest;
    defer directory.close(io);
    const source = directory.readFile(io, "qualification.forb", &source_bytes) catch |problem| switch (problem) {
        error.FileNotFound => return error.SkipZigTest,
        else => return problem,
    };
    const golden = try directory.readFile(io, "qualification-qualified.txt", &golden_bytes);
    try expectQualified(h, .{ .source = source }, golden);
}

/// Every conformance fixture, single files and bundles, in name order, and the directory that
/// holds them (`conformance_fixtures.zig`), which the caller closes.
fn fixtures(io: std.Io, names: *std.ArrayList([]u8)) !std.Io.Dir {
    var directory = try conformance_fixtures.open(io, .{ .iterate = true }) orelse return error.SkipZigTest;
    errdefer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".forb") and !std.mem.endsWith(u8, entry.name, ".bundle.json")) continue;
        try names.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.name));
    }
    std.sort.pdq([]u8, names.items, {}, struct {
        fn before(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.before);
    return directory;
}

test "every conformance fixture: the resolution property, one meaning per identifier, and the same program" {
    const io = std.testing.io;
    const h = try harness();
    defer scratch.release(h);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| std.testing.allocator.free(name);
        names.deinit(std.testing.allocator);
    }
    var directory = try fixtures(io, &names);
    defer directory.close(io);
    try std.testing.expect(names.items.len > 100);
    const buffer = scratch.alloc(u8, bundle_packet.max_packet_bytes) orelse return error.OutOfMemory;
    defer scratch.free(buffer);
    var compiled: usize = 0;
    var noted: usize = 0;
    var failures: usize = 0;
    for (names.items) |name| {
        const bytes = try directory.readFile(io, name, buffer);
        const input: Input = if (std.mem.endsWith(u8, name, ".json")) .{ .bundle = try h.packet.parse(bytes) } else .{ .source = bytes };
        var out: std.Io.Writer.Discarding = .init(&.{});
        // Every fixture is checked, and each failure is reported.
        const ok = check(h, name, input, &out.writer) catch {
            failures += 1;
            continue;
        };
        if (ok) {
            compiled += 1;
            noted += h.compiler.resolution_count;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    // Error fixtures that are refused are refused the same way with the table.
    try std.testing.expect(compiled > 150);
    try std.testing.expect(noted > 8000);
}

/// A table taken from a compile, which a test may change: `verify` must refuse every change that
/// breaks the property.
const Forged = struct {
    entries: [64]qualify.Resolution = undefined,
    count: usize = 0,
    base: qualify.Text = undefined,

    fn take(self: *Forged, table: qualify.Text) void {
        @memcpy(self.entries[0..table.entries.len], table.entries);
        self.count = table.entries.len;
        self.base = table;
    }
    fn text(self: *Forged) qualify.Text {
        var result = self.base;
        result.entries = self.entries[0..self.count];
        return result;
    }
    fn at(self: *Forged, source: []const u8, needle: []const u8, nth: usize) *qualify.Resolution {
        var from: usize = 0;
        var seen: usize = 0;
        while (std.mem.indexOfPos(u8, source, from, needle)) |found| : (from = found + 1) {
            if (seen == nth) {
                for (self.entries[0..self.count]) |*entry| if (entry.at == found) return entry;
                unreachable;
            }
            seen += 1;
        }
        unreachable;
    }
};

test "verify refuses a table that breaks the resolution property, whatever it breaks" {
    const h = try harness();
    defer scratch.release(h);
    const source =
        \\A:i64 = 1
        \\B:i64 = A
        \\F(X:i64)<computes>:i64 = X
        \\G(X:i64)<computes>:i64 = X + A
        \\point := struct{ Y:i64 = 0 }
        \\
    ;
    const program = compileWith(h, .{ .source = source }, true).ok;
    defer h.compiler.qualify = false;
    const text = h.compiler.qualification(program, &h.written);
    try std.testing.expect(verified(h, program, text) == null);
    try std.testing.expect(text.entries.len <= 64);
    const Case = struct { reason: []const u8, forge: *const fn (*Forged, []const u8) void };
    const cases = [_]Case{
        // G's `X` named as F's parameter, which is out of reach there.
        .{ .reason = "(local:) names another local here", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "X", 3).declared = f.at(s, "X", 0).at;
            }
        }.forge },
        // A use of a global noted as a local.
        .{ .reason = "of another kind than its declaration", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "A", 1).kind = .local;
            }
        }.forge },
        // A use that names another use.
        .{ .reason = "its declaration is a use", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "A", 2).declared = f.at(s, "A", 1).at;
            }
        }.forge },
        // A declaration the table does not have.
        .{ .reason = "its declaration is not noted", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "A", 1).declared = 3;
            }
        }.forge },
        // A name the program declares, printed as a built-in.
        .{ .reason = "not a built-in name", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "A", 1).kind = .builtin;
            }
        }.forge },
        // A second declaration of `A` where the first is used: the form names two.
        .{ .reason = "its form names several definitions", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                const use = f.at(s, "A", 1);
                use.declared = use.at;
            }
        }.forge },
        // A member without the type that declares it.
        .{ .reason = "a member without its type", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "Y", 0).owner = qualify.none;
            }
        }.forge },
        // A declaration named otherwise than its use.
        .{ .reason = "named otherwise than its declaration", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "A", 1).declared = f.at(s, "B", 0).at;
            }
        }.forge },
    };
    for (cases) |case| {
        var forged: Forged = .{};
        forged.take(text);
        case.forge(&forged, source);
        const problem = verified(h, program, forged.text()) orelse {
            std.debug.print("not refused: {s}\n", .{case.reason});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(case.reason, problem.reason);
    }
    // An entry beyond the author's text, and one noted twice.
    var forged: Forged = .{};
    forged.take(text);
    forged.entries[forged.count] = .{ .at = @intCast(source.len), .kind = .builtin };
    forged.count += 1;
    try std.testing.expectEqualStrings("noted outside the text the author wrote", verified(h, program, forged.text()).?.reason);
    forged.take(text);
    forged.entries[forged.count] = forged.entries[forged.count - 1];
    forged.count += 1;
    try std.testing.expectEqualStrings("noted twice", verified(h, program, forged.text()).?.reason);
}

test "a capture of a local's own name names the local again after the Fn, and a loop's carried local is the local" {
    const h = try harness();
    defer scratch.release(h);
    try expectQualified(h, .{ .source =
        \\F(Base:i64)<transacts>:i64 = Block{ var Sum:i64 = 0; G := Fn[Base:i64 = Base](N:i64)<computes>:i64{Base + N}; For(K:1..3, Block{ set Sum = Sum + K; Sum }); G(Sum) + Base }
        \\
    },
        \\(/:)F((local:)Base:(/Verse.org/Verse:)i64)<transacts>:(/Verse.org/Verse:)i64 = Block{ var (local:)Sum:(/Verse.org/Verse:)i64 = 0; (local:)G := Fn[(local:)Base:(/Verse.org/Verse:)i64 = (local:)Base]((local:)N:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64{(local:)Base + (local:)N}; For((local:)K:1..3, Block{ set (local:)Sum = (local:)Sum + (local:)K; (local:)Sum }); (local:)G((local:)Sum) + (local:)Base }
        \\
    );
    // The capture is its own declaration, in reach in the `Fn`'s body only.
    const source_text = h.compiler.qualification(compileWith(h, .{ .source = "F(Base:i64)<computes>:i64 = Block{ G := Fn[Base:i64 = Base]()<computes>:i64{Base}; G() + Base }" }, true).ok, &h.written);
    defer h.compiler.qualify = false;
    const s = source_text.source;
    const outer: u32 = @intCast(std.mem.indexOf(u8, s, "Base").?);
    const capture: u32 = @intCast(std.mem.indexOf(u8, s, "[Base").? + 1);
    const value: u32 = @intCast(std.mem.indexOf(u8, s, "= Base").? + 2);
    const body: u32 = @intCast(std.mem.indexOf(u8, s, "{Base}").? + 1);
    const after: u32 = @intCast(std.mem.lastIndexOf(u8, s, "Base").?);
    try std.testing.expectEqual(capture, source_text.find(capture).?.declared);
    try std.testing.expectEqual(outer, source_text.find(value).?.declared);
    try std.testing.expectEqual(capture, source_text.find(body).?.declared);
    try std.testing.expectEqual(outer, source_text.find(after).?.declared);
}

test "verify checks the table against what the program reaches: members, their types, overloads, locals and built-ins" {
    const h = try harness();
    defer scratch.release(h);
    const source =
        \\p1:=struct{X:i64=0}
        \\p2:=struct{X:i64=0}
        \\C:p1=p1{}
        \\V:i64=C.X
        \\Size(N:i64)<computes>:i64=N
        \\Size(S:string)<computes>:i64=S.Length
        \\W:i64=Size("ab")
        \\F(Y:i64)<computes>:i64=Y+1
        \\G(Abs:i64)<computes>:i64=Abs+1
        \\holder:=struct{Abs:i64=0}
        \\H:holder=holder{}
        \\U:i64=H.Abs
        \\
    ;
    const program = compileWith(h, .{ .source = source }, true).ok;
    defer h.compiler.qualify = false;
    const text = h.compiler.qualification(program, &h.written);
    try std.testing.expect(verified(h, program, text) == null);
    const Case = struct { reason: []const u8, forge: *const fn (*Forged, []const u8) void };
    const cases = [_]Case{
        // `C.X` named as the field of the other struct.
        .{ .reason = "names another definition than the program reaches", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "X", 2).declared = f.at(s, "X", 1).at;
            }
        }.forge },
        // A field declared by the value `C`.
        .{ .reason = "a member of another type than the one that declares it", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "X", 0).owner = f.at(s, "C", 0).at;
            }
        }.forge },
        // The call of `Size("ab")` named as the overload of `i64`.
        .{ .reason = "names another definition than the program reaches", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "Size", 2).declared = f.at(s, "Size", 0).at;
            }
        }.forge },
        // A use of the parameter `Y` noted as a declaration of its own.
        .{ .reason = "a local declared where its name is read", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                const use = f.at(s, "Y", 1);
                use.declared = use.at;
            }
        }.forge },
        // The parameter `Abs` printed as the standard `Abs`.
        .{ .reason = "a built-in form for a name a local in reach has", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "Abs", 1).kind = .builtin;
            }
        }.forge },
        // The field `Abs` printed as the standard `Abs`.
        .{ .reason = "a member printed as a built-in", .forge = struct {
            fn forge(f: *Forged, s: []const u8) void {
                f.at(s, "Abs", 3).kind = .builtin;
            }
        }.forge },
    };
    for (cases) |case| {
        var forged: Forged = .{};
        forged.take(text);
        case.forge(&forged, source);
        const problem = verified(h, program, forged.text()) orelse {
            std.debug.print("not refused: {s}\n", .{case.reason});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(case.reason, problem.reason);
    }
}

test "a name whose meaning a generic body's specializations change is printed as written" {
    const h = try harness();
    defer scratch.release(h);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const source =
        \\p1:=struct{X:i64=1}
        \\p2:=struct{Y:i64=5,X:i64=2}
        \\Size(N:i64)<computes>:i64=N
        \\Size(S:string)<computes>:i64=S.Length
        \\GetX[T:type](V:T)<computes>:i64{V.X}
        \\Measure[T:type](V:T)<computes>:i64{Size(V)}
        \\A:i64 = GetX[p1](p1{}) + GetX[p2](p2{}) + Measure[string]("ab") + Measure[i64](3)
        \\
    ;
    try std.testing.expect(try check(h, "generic", .{ .source = source }, &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(/:)GetX[(local:)T:type]((local:)V:(local:)T)<computes>:(/Verse.org/Verse:)i64{(local:)V.X}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(/:)Measure[(local:)T:type]((local:)V:(local:)T)<computes>:(/Verse.org/Verse:)i64{Size((local:)V)}") != null);
}

test "a bundle whose nested module and file have one path has no qualified forms" {
    const h = try harness();
    defer scratch.release(h);
    const inputs = [_]modules.Input{
        .{ .path = "a.forb", .source = "B:=import{\"a/b.forb\"}\nb<public>:=module{\n  X<public>:i64=1\n}\nY:i64=b.X+B.X\n" },
        .{ .path = "a/b.forb", .source = "X<public>:i64=2\n" },
    };
    const program = compileWith(h, .{ .bundle = .{ .root = "a.forb", .modules = &inputs } }, true).ok;
    defer h.compiler.qualify = false;
    const text = h.compiler.qualification(program, &h.written);
    try std.testing.expect(qualify.ambiguous(text));
    try std.testing.expectEqualStrings("two scopes have this path", verified(h, program, text).?.reason);
    var out: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.AmbiguousPath, qualify.write(text, &out.writer));
}

test "a nested function is a local of its block: its declaration, its calls, its recursion and its value" {
    const h = try harness();
    defer scratch.release(h);
    const source =
        \\F(Base:i64)<transacts>:i64 = Block{
        \\    Twice(M:i64)<computes>:i64 = M * 2
        \\    Fact(N:i64)<computes>:i64 = If(N <= 1, 1, N * Fact(N - 1))
        \\    Apply := Twice
        \\    Twice(Base) + Fact(4) + Apply(1)
        \\}
        \\Value:i64 = F(5)
        \\
    ;
    try expectQualified(h, .{ .source = source },
        \\(/:)F((local:)Base:(/Verse.org/Verse:)i64)<transacts>:(/Verse.org/Verse:)i64 = Block{
        \\    (local:)Twice((local:)M:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = (local:)M * 2
        \\    (local:)Fact((local:)N:(/Verse.org/Verse:)i64)<computes>:(/Verse.org/Verse:)i64 = If((local:)N <= 1, 1, (local:)N * (local:)Fact((local:)N - 1))
        \\    (local:)Apply := (local:)Twice
        \\    (local:)Twice((local:)Base) + (local:)Fact(4) + (local:)Apply(1)
        \\}
        \\(/:)Value:(/Verse.org/Verse:)i64 = (/:)F(5)
        \\
    );
    const text = h.compiler.qualification(compileWith(h, .{ .source = source }, true).ok, &h.written);
    defer h.compiler.qualify = false;
    const twice: u32 = @intCast(std.mem.indexOf(u8, source, "Twice").?);
    const fact: u32 = @intCast(std.mem.indexOf(u8, source, "Fact").?);
    // The value `Twice`, the call `Twice(Base)`, and the recursive call `Fact(N - 1)` name the declarations.
    try std.testing.expectEqual(twice, text.find(@intCast(std.mem.indexOf(u8, source, ":= Twice").? + 3)).?.declared);
    try std.testing.expectEqual(twice, text.find(@intCast(std.mem.indexOf(u8, source, "Twice(Base)").?)).?.declared);
    try std.testing.expectEqual(fact, text.find(@intCast(std.mem.indexOf(u8, source, "Fact(N - 1)").?)).?.declared);
    try std.testing.expectEqual(qualify.Kind.local, text.find(twice).?.kind);
    // A use of a nested function forged as a declaration of its own is refused.
    var forged: Forged = .{};
    forged.take(text);
    for (forged.entries[0..forged.count]) |*entry| if (entry.at == std.mem.indexOf(u8, source, "Fact(4)").?) {
        entry.declared = entry.at;
    };
    try std.testing.expect(verified(h, compileWith(h, .{ .source = source }, true).ok, forged.text()) != null);
}

test "a field with accessors that an archetype gives is the member its class declares" {
    const h = try harness();
    defer scratch.release(h);
    const source =
        \\entity := class{
        \\    var Health<getter(GetHealth)><setter(SetHealth)>:i64
        \\    var Stored:i64 = 0
        \\    GetHealth(:accessor)<reads>:i64 = Self.Stored
        \\    SetHealth(:accessor, NewValue:i64)<transacts>:void = Block{ set Self.Stored = NewValue; 0 }
        \\}
        \\Hero:entity = entity{Health := 40}
        \\Value:i64 = Hero.Health
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(try check(h, "accessors", .{ .source = source }, &out.writer));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(/:)Hero:(/:)entity = (/:)entity{(/entity:)Health := 40}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "(/entity:)SetHealth(:(/Verse.org/Verse:)accessor, ") != null);
    const text = h.compiler.qualification(compileWith(h, .{ .source = source }, true).ok, &h.written);
    defer h.compiler.qualify = false;
    const declared: u32 = @intCast(std.mem.indexOf(u8, source, "Health<").?);
    try std.testing.expectEqual(declared, text.find(@intCast(std.mem.indexOf(u8, source, "Health := 40").?)).?.declared);
    try std.testing.expectEqual(declared, text.find(@intCast(std.mem.lastIndexOf(u8, source, "Health").?)).?.declared);
}

test "qualification replaces spaced local and module qualifiers" {
    const h = try harness();
    defer scratch.release(h);
    try expectQualified(h, .{ .source = "Mix()<computes>:i64 = Block{( local:)X:i64 = 5; ( \tlocal:)X}\n" }, "(/:)Mix()<computes>:(/Verse.org/Verse:)i64 = Block{(local:)X:(/Verse.org/Verse:)i64 = 5; (local:)X}\n");
}
