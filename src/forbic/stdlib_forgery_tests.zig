//! Every forgery of an operand, a result type and a kernel index of the standard forms'
//! `native_call` nodes (RFC-0077), written by the increment's independent review: whatever
//! one machine admits the other admits, and whatever both admit they run alike, never reading
//! outside a pool.
const std = @import("std");
const scratch = @import("scratch.zig");
const types = @import("types.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const harness = @import("generic_function_tests.zig");

const source =
    \\Twice(V:i64)<computes>:i64=V*2
    \\Pt:=struct{X:i64,Y:i64}
    \\Col:=enum{Red,Green}
    \\Animal:=class{}
    \\Dog:=class(Animal){}
    \\Xs:[]i64=array{1,2,3}
    \\Ws:[]string=array{"a","bc"}
    \\Fl:[]float=array{1.0,NaN}
    \\Cs:[]char=array{'a','b'}
    \\Ps:[]Pt=array{Pt{X:=1,Y:=2}}
    \\Es:[]Col=array{Col.Red}
    \\Os:[]option(i64)=array{option{1},option{}}
    \\Ts:[]tuple(i64,string)=array{tuple{1,"a"}}
    \\Fs:[]function(tuple(i64),i64)=array{Twice}
    \\F:function(tuple(i64),i64)=Twice
    \\T:string="x"
    \\Big:i64=99
    \\Neg:i64=0-1
    \\Fv:float=1.5
    \\Lg:logic=true
    \\Ch:char='a'
    \\Op:option(i64)=option{4}
    \\Tu:tuple(i64,string)=tuple{1,"a"}
    \\Pv:Pt=Pt{X:=1,Y:=2}
    \\N:map(string,i64)=map{"a"=>1}
    \\M:map(i64,i64)=map{1=>2}
    \\MP:map(Pt,[]i64)=map{Pt{X:=1,Y:=2}=>array{1}}
    \\MM:map(i64,map(i64,i64))=map{1=>M}
    \\Ms:[]map(i64,i64)=array{M,M}
    \\Rows:[][]i64=array{Xs,Xs}
    \\Deep:[][][]i64=array{Rows,Rows}
    \\SRows:[][]string=array{Ws}
    \\D:Animal=Dog{}
    \\Ds:[]Animal=array{D}
    \\I:i64=Attempt(Xs.Find[2],0-1)
    \\S:[]i64=Attempt(Xs.Slice[0,2],array{})
    \\Rm:[]i64=Attempt(Xs.Remove[0,1],array{})
    \\In:[]i64=Attempt(Xs.Insert[1,Xs],array{})
    \\R:[]i64=Xs.RemoveAllElements(2)
    \\Re:[]i64=Xs.ReplaceAllElements(2,5)
    \\P:[]i64=Xs.ReplaceAll(Xs,Xs)
    \\C:[]i64=Concatenate(Rows)
    \\Q:map(i64,i64)=ConcatenateMaps(M,M)
    \\SF:i64=Attempt(T.Find['x'],0-1)
    \\SR:string=T.ReplaceAll("x","yy")
    \\J:string=Join(Ws,",")
;

fn attempt(h: *harness.Harness, p: types.Program, what: []const u8, index: usize, a: usize, b: usize, counts: *[3]usize) !void {
    const reference = evaluator.evaluateWithRuntimeStorage(p, &h.values, &h.members, &h.control, &h.state, &h.frames, 100_000);
    if (reference == .failed and reference.failed.code == .invalid_ir) {
        const lowered = bytecode.lower(p, &h.runtime.instructions);
        if (lowered != .ok) {
            counts[0] += 1;
            return;
        }
        const actual = h.runtime.machine.run(lowered.ok, 100_000);
        if (actual != .failed or actual.failed.code != .invalid_bytecode) {
            std.debug.print("DIVERGE admission {s} node {d} a {d} b {d}: reference invalid_ir, vm {s}\n", .{ what, index, a, b, if (actual == .failed) @tagName(actual.failed.code) else "ok" });
            return error.TestUnexpectedResult;
        }
        counts[0] += 1;
        return;
    }
    const result = h.run(p, 100_000) catch |err| {
        std.debug.print("FINDING {s} node {d} a {d} b {d}: {s}\n", .{ what, index, a, b, @errorName(err) });
        return err;
    };
    if (result == .ok) counts[1] += 1 else {
        counts[2] += 1;
        if (result.failed.code != .native_failed and result.failed.code != .aggregate_limit) std.debug.print("note {s} node {d} a {d} b {d}: {s}\n", .{ what, index, a, b, @tagName(result.failed.code) });
    }
}

test "every forged operand, result type and kernel of the standard native calls is refused by both machines or run alike" {
    const h = try harness.create();
    defer scratch.release(h);
    const p = try h.compile(source);
    const nodes = try std.testing.allocator.dupe(types.Node, p.nodes);
    defer std.testing.allocator.free(nodes);
    var forged = p;
    forged.nodes = nodes;
    _ = try h.run(forged, 100_000);
    var counts = [3]usize{ 0, 0, 0 };
    // Distinct types seen in the program.
    var seen: [256]types.Type = undefined;
    var seen_count: usize = 0;
    for (p.nodes) |node| {
        var known = false;
        for (seen[0..seen_count]) |t| known = known or t == node.value_type;
        if (!known and seen_count < seen.len) {
            seen[seen_count] = node.value_type;
            seen_count += 1;
        }
    }
    for (p.nodes, 0..) |node, index| {
        if (node.kind != .native_call) continue;
        const call = node.kind.native_call;
        // One operand replaced.
        for (0..call.count) |position| {
            for (0..index) |other| {
                var changed = node;
                changed.kind.native_call.args[position] = @intCast(other);
                nodes[index] = changed;
                try attempt(h, forged, "operand", index, position, other, &counts);
                // And the result typed as the new operand.
                changed.value_type = p.nodes[other].value_type;
                nodes[index] = changed;
                try attempt(h, forged, "operand+type", index, position, other, &counts);
            }
        }
        // All operands replaced by one node, and by pairs, with each result type.
        for (0..index) |other| {
            if (p.nodes[other].kind == .native_call) continue;
            var changed = node;
            for (0..call.count) |position| changed.kind.native_call.args[position] = @intCast(other);
            for (seen[0..seen_count], 0..) |t, ti| {
                changed.value_type = t;
                nodes[index] = changed;
                try attempt(h, forged, "all+type", index, other, ti, &counts);
            }
        }
        // Another kernel behind the same operands.
        for (0..p.natives.len) |native_index| {
            var changed = node;
            changed.kind.native_call.native = @intCast(native_index);
            for (seen[0..seen_count], 0..) |t, ti| {
                changed.value_type = t;
                nodes[index] = changed;
                try attempt(h, forged, "kernel+type", index, native_index, ti, &counts);
            }
        }
        // Every pair and triple of bindings as the operands, typed as the first, as the call was, or as an option of i64.
        if (call.count >= 2) {
            for (p.bindings) |b0| for (p.bindings) |b1| {
                var changed = node;
                changed.kind.native_call.args[0] = b0.node;
                changed.kind.native_call.args[1] = b1.node;
                if (call.count == 2) {
                    for ([_]types.Type{ node.value_type, p.nodes[b0.node].value_type, p.nodes[b1.node].value_type }) |t| {
                        changed.value_type = t;
                        nodes[index] = changed;
                        try attempt(h, forged, "pair", index, b0.node, b1.node, &counts);
                    }
                } else for (p.bindings) |b2| {
                    changed.kind.native_call.args[2] = b2.node;
                    for ([_]types.Type{ node.value_type, p.nodes[b0.node].value_type }) |t| {
                        changed.value_type = t;
                        nodes[index] = changed;
                        try attempt(h, forged, "triple", index, b0.node, b1.node * 1000 + b2.node, &counts);
                    }
                }
            };
        }
        nodes[index] = node;
    }
    // The forgeries are not all refused, and not all admitted: both paths were walked.
    try std.testing.expect(counts[0] > 1000 and counts[1] > 100 and counts[2] > 10);
}
