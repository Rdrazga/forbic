//! Capacity profiles. A profile is the complete set of structural capacities one
//! build of the compiler, machines, reports and tooling agrees on. `bootstrap` is
//! the original fixed capacity set and the regression anchor; `program` sizes the
//! language for real programs and large configurations (docs/development/capacity-review.md).
//!
//! The active profile is chosen at compile time: the root source file of the final
//! program (or a custom test runner) may declare `pub const forbic_profile_name =
//! "program"`; otherwise `bootstrap` is used. Every capacity is a comptime constant,
//! so storage stays allocate-once and admission in both machines checks the same
//! numbers.
const std = @import("std");
const root = @import("root");

pub const Profile = struct {
    name: []const u8,
    natives: usize,
    source_bytes: usize,
    tokens: usize,
    nodes: usize,
    bindings: usize,
    local_bindings: usize,
    expression_depth: usize,
    string_bytes: usize,
    identifier_bytes: usize,
    functions: usize,
    parameters: usize,
    template_nodes: usize,
    compiler_work: usize,
    user_types: usize,
    fields: usize,
    record_fields: usize,
    cases: usize,
    enum_cases: usize,
    tuple_elements: usize,
    tuple_arity: usize,
    aggregate_elements: usize,
    control_depth: usize,
    failure_traces: usize,
    source_cells: usize,
    source_undos: usize,
    /// Regions (`Attempt`, failable conditions, failing calls) open at once in a run. They nest
    /// with calls, so this follows `call_depth`, not the lexical `control_depth`.
    source_frames: usize,
    object_cells: usize,
    methods: usize,
    dispatch: usize,
    call_depth: usize,
    call_registers: usize,
    call_arguments: usize,
    call_steps: usize,
    modules: usize,
    /// How deep `Name := module{...}` may nest inside a file (RFC-0074). It bounds the walk from
    /// a position to the module that holds it, so that walk never costs the number of modules.
    module_depth: usize,
    imports: usize,
    module_path_bytes: usize,
    /// RFC-0093, B7: the files of a bundle given as a folder tree. Several files make one
    /// module there, so this bounds the inventory, and `modules` the modules it compiles to.
    module_files: usize,
    /// Fuel a host gives a run when it has no budget of its own: a bound on time. Fuel is 64-bit
    /// in both machines, so this is a default a host may exceed, never a limit of the type.
    evaluation_work: u64,
    /// Default budgets of the value report: the work of replaying a run and the bytes it prints.
    report_work: usize,
    report_bytes: usize,
    /// Default size of an inspection or failure-trace document.
    document_bytes: usize,
    /// Parametric types being instantiated at once (RFC-0073): a type whose body names another
    /// instantiation compiles that one first, on the native stack.
    instantiation_depth: usize,
    /// Actions a run holds in its effect log at once (RFC-0079): the ones whose region is still
    /// open, and, in a `full` run, the committed ones its report lists.
    effect_entries: usize,
    /// The bytes of those actions, which the log copies so that reclamation never moves them.
    effect_bytes: usize,
    /// Live tasks of a run (RFC-0082): running, ready, waiting, and spawned in a region that is
    /// still open. Waiter lists, timers and the ready queue hold at most one entry per task.
    tasks: usize,
    /// Frames of all suspended tasks, and the registers of those frames (one per body node).
    saved_frames: usize,
    saved_registers: usize,
    /// `Spawn` and `Signal` actions held in rollback regions that are still open.
    scheduler_actions: usize,
    /// RFC-0084, live variables. Dependency entries that must be kept (`live_edge_limit`).
    live_edges: usize,
    /// Guard evaluations in one propagation (`live_propagation_limit`).
    live_evaluations: usize,
    /// Evaluations of one live record in one propagation (`live_unstable`, the cycle detector).
    live_record_evaluations: usize,
    /// The cap on the heights that order a propagation. Not an error: heights stop rising.
    live_height: usize,
    /// RFC-0084, P4.4: deliveries in one delivery loop (`reaction_limit`).
    deliveries: usize,
    /// RFC-0086, P2.2: entries a run's input record holds (`input_limit`), and the bytes of
    /// their values, which the record copies so that reclamation never moves them.
    input_entries: usize,
    input_bytes: usize,
    /// RFC-0086, P2.3: grants a host may give a run (`OpenReader`, `OpenWriter`). The list is the
    /// host's, borrowed by the run: nothing is reserved for it.
    grants: usize,
};

/// The original fixed capacities. Exact-boundary tests are written against these.
pub const bootstrap: Profile = .{
    .name = "bootstrap",
    .natives = 32,
    .source_bytes = 64 * 1024,
    .tokens = 16 * 1024,
    .nodes = 8 * 1024,
    .bindings = 256,
    .local_bindings = 256,
    .expression_depth = 128,
    .string_bytes = 64 * 1024,
    .identifier_bytes = 128,
    .functions = 64,
    .parameters = 16,
    .template_nodes = 8 * 1024,
    .compiler_work = 64 * 1024,
    .user_types = 256,
    .fields = 1024,
    .record_fields = 256,
    .cases = 1024,
    .enum_cases = 256,
    .tuple_elements = 1024,
    .tuple_arity = 256,
    .aggregate_elements = 8192,
    .control_depth = 32,
    .failure_traces = 32,
    .source_cells = 256,
    .source_undos = 8192,
    .source_frames = 33,
    .object_cells = 1024,
    .methods = 256,
    .dispatch = 2048,
    .call_depth = 32,
    .call_registers = 8192,
    .call_arguments = 8192,
    .call_steps = 8192,
    .modules = 64,
    .module_depth = 16,
    .imports = 256,
    .module_path_bytes = 256,
    .module_files = 64,
    .evaluation_work = 8 * 1024 + 8192,
    .report_work = 65536,
    .report_bytes = 1024 * 1024,
    .document_bytes = 4 * 1024 * 1024,
    .instantiation_depth = 8,
    .effect_entries = 1024,
    // Every string a run can hold, once.
    .effect_bytes = 64 * 1024,
    .tasks = 64,
    .saved_frames = 256,
    .saved_registers = 8192,
    .scheduler_actions = 256,
    .live_edges = 4096,
    .live_evaluations = 1024,
    .live_record_evaluations = 64,
    .live_height = 256,
    .deliveries = 1024,
    .input_entries = 1024,
    .input_bytes = 64 * 1024,
    .grants = 16,
};

/// Real programs. A capacity here is a bound on resources, not on what a program may
/// reasonably be: each is set where an index type or the memory budget ends, sized for a
/// program of about 200,000 lines with the run state of a long session. Storage is allocated
/// once and only the part a program uses is ever touched, so a small program pays nothing for
/// the room. The whole toolchain at these capacities reserves on the order of 1.5 GiB.
/// `docs/development/capacity-review.md` records what bounds each number and what it costs.
pub const program: Profile = .{
    .name = "program",
    .natives = 1024,
    // About 40 bytes, 10 tokens and 5 nodes per line.
    .source_bytes = 8 * 1024 * 1024,
    .tokens = 2 * 1024 * 1024,
    .nodes = 1024 * 1024,
    // One per four lines. The symbol table is 32-bit.
    .bindings = 64 * 1024,
    // Bound by the two 128-element tuples that carry a region's local versions.
    .local_bindings = 256,
    // A `Case` or else-if ladder nests one level per arm; this is four times `control_depth`.
    .expression_depth = 4096,
    // Literals and the strings a run builds share one buffer.
    .string_bytes = 64 * 1024 * 1024,
    .identifier_bytes = 255,
    // Below the 16-bit function symbol; every method body is a function too.
    .functions = 32 * 1024,
    .parameters = 32,
    .template_nodes = 1024 * 1024,
    // A bound on compile time, not on storage.
    .compiler_work = 256 * 1024 * 1024,
    // A type is 16 bits; this leaves room for the structural types programs intern.
    .user_types = 16 * 1024,
    .fields = 256 * 1024,
    // One record's fields are staged on the native stack while it is built.
    .record_fields = 1024,
    .cases = 256 * 1024,
    .enum_cases = 4096,
    .tuple_elements = 256 * 1024,
    .tuple_arity = 256,
    // Aggregate members: static literals and everything a run builds (the run pool only grows).
    .aggregate_elements = 4 * 1024 * 1024,
    .control_depth = 1024,
    // A sample of failures for the trace report, which says when it is truncated.
    .failure_traces = 32,
    // `var` bindings of a program. Region images cost cells x source_frames.
    .source_cells = 4096,
    .source_undos = 2 * 1024 * 1024,
    .source_frames = 1024,
    // Cells of all live instances: a header and one per field.
    .object_cells = 4 * 1024 * 1024,
    .methods = 32 * 1024,
    .dispatch = 1024 * 1024,
    .call_depth = 16 * 1024,
    .call_registers = 4 * 1024 * 1024,
    .call_arguments = 1024 * 1024,
    // The call witness that reports replay; one entry per node visited inside calls.
    .call_steps = 4 * 1024 * 1024,
    .modules = 1024,
    .module_depth = 16,
    .imports = 16 * 1024,
    .module_path_bytes = 1024,
    // A file is an inventory entry and a part of a module (16 bytes); its path is in a pool of
    // `module_files * module_path_bytes`, 16 MiB, touched as used.
    .module_files = 16 * 1024,
    // A bound on time, not on the counter: about a trillion node visits, hours of work.
    .evaluation_work = 1 << 40,
    // Replaying a run costs a few units per call step, member and cell it used: a bound on time.
    .report_work = 4 * 1024 * 1024 * 1024,
    .report_bytes = 1024 * 1024 * 1024,
    // About a hundred bytes of inspection per node.
    .document_bytes = 1024 * 1024 * 1024,
    // Each level is one class compile on the native stack. A real program nests two or three;
    // 96 levels were measured to fit the 16 MiB main stack, so this leaves room for a caller
    // on a smaller one.
    .instantiation_depth = 16,
    // An entry is two 32-bit offsets and a mark three words: 20 MiB reserved, touched as used.
    .effect_entries = 1024 * 1024,
    // Offsets are 32-bit. This is the string pool's size: all a run can hold as text, once.
    .effect_bytes = 64 * 1024 * 1024,
    // RFC-0082: a task slot is a few words; the saved frames and registers are reserved, at
    // one and a half times these numbers so that compacting them stays amortised, and
    // touched as tasks wait.
    .tasks = 64 * 1024,
    .saved_frames = 256 * 1024,
    .saved_registers = 4 * 1024 * 1024,
    .scheduler_actions = 1024 * 1024,
    // RFC-0084: an entry is a few words; the store is reserved at a capacity and a half, so
    // that compacting it stays amortised, and touched as entries are recorded.
    .live_edges = 4 * 1024 * 1024,
    .live_evaluations = 1024 * 1024,
    .live_record_evaluations = 1024,
    .live_height = 64 * 1024,
    .deliveries = 1024 * 1024,
    // RFC-0086: an entry is four words, 32 MiB reserved, and the bytes are the string pool's
    // size, as the effect log's are; both are touched as entries are recorded.
    .input_entries = 1024 * 1024,
    .input_bytes = 64 * 1024 * 1024,
    // RFC-0086, P2.3: a grant's index is the index of a handle, and its channel one more.
    .grants = 1024,
};

pub const active: Profile = blk: {
    if (!@hasDecl(root, "forbic_profile_name")) break :blk bootstrap;
    const name: []const u8 = root.forbic_profile_name;
    if (std.mem.eql(u8, name, "program")) break :blk program;
    if (std.mem.eql(u8, name, "bootstrap")) break :blk bootstrap;
    @compileError("unknown Forbic capacity profile: " ++ name);
};

test "the active profile is the bootstrap anchor unless a runner overrides it" {
    if (!@hasDecl(root, "forbic_profile_name")) try std.testing.expectEqualStrings("bootstrap", active.name);
    try std.testing.expect(active.nodes <= active.source_bytes);
}

/// Marks a test that deliberately asserts the original bootstrap capacities. Under a
/// larger profile it is skipped; profile-specific capacity tests cover that profile.
pub fn requireBootstrap() error{SkipZigTest}!void {
    if (!std.mem.eql(u8, active.name, "bootstrap")) return error.SkipZigTest;
}
