//! Test-only compiler and independent reference-result ownership.
const compiler = @import("compiler.zig");
const types = @import("types.zig");

// Production compilation has no evaluator registers. Differential fixtures keep
// their oracle results here, separate from the VM's own machine registers.
pub const Workspace = struct {
    compiler: compiler.Workspace = .{},
    values: [types.limits.nodes]types.Value = undefined,

    pub fn compile(self: *Workspace, source: []const u8) compiler.Result {
        return self.compiler.compile(source);
    }
};
