const std = @import("std");

const native = @import("native.zig");
const effects = @import("effects.zig");

const active = @import("profile.zig").active;

/// Structural capacities of the active profile (see profile.zig). Derived values
/// follow their definitions so a profile cannot make them disagree.
pub const limits = struct {
    pub const natives: comptime_int = active.natives;
    pub const source_bytes: comptime_int = active.source_bytes;
    pub const tokens: comptime_int = active.tokens;
    pub const nodes: comptime_int = active.nodes;
    pub const bindings: comptime_int = active.bindings;
    pub const local_bindings: comptime_int = active.local_bindings;
    pub const local_checkpoints = control_depth;
    pub const expression_depth: comptime_int = active.expression_depth;
    pub const string_bytes: comptime_int = active.string_bytes;
    pub const identifier_bytes: comptime_int = active.identifier_bytes;
    pub const functions: comptime_int = active.functions;
    pub const parameters: comptime_int = active.parameters;
    pub const template_nodes: comptime_int = active.template_nodes;
    pub const compiler_work: comptime_int = active.compiler_work;
    pub const user_types: comptime_int = active.user_types;
    pub const fields: comptime_int = active.fields;
    pub const record_fields: comptime_int = active.record_fields;
    pub const cases: comptime_int = active.cases;
    pub const enum_cases: comptime_int = active.enum_cases;
    pub const tuple_elements: comptime_int = active.tuple_elements;
    pub const tuple_arity: comptime_int = active.tuple_arity;
    pub const aggregate_elements: comptime_int = active.aggregate_elements;
    pub const evaluation_work: comptime_int = active.evaluation_work;
    pub const control_depth: comptime_int = active.control_depth;
    pub const failure_traces: comptime_int = active.failure_traces;
    pub const source_cells: comptime_int = active.source_cells;
    pub const source_undos: comptime_int = active.source_undos;
    pub const object_cells: comptime_int = active.object_cells;
    pub const methods: comptime_int = active.methods;
    pub const dispatch: comptime_int = active.dispatch;
    pub const source_frames: comptime_int = active.source_frames;
    pub const call_depth: comptime_int = active.call_depth;
    pub const call_registers: comptime_int = active.call_registers;
    pub const call_arguments: comptime_int = active.call_arguments;
    pub const call_steps: comptime_int = active.call_steps;
    pub const modules: comptime_int = active.modules;
    pub const module_depth: comptime_int = active.module_depth;
    pub const imports: comptime_int = active.imports;
    pub const module_path_bytes: comptime_int = active.module_path_bytes;
    pub const module_paths_bytes = modules * module_path_bytes;
    /// RFC-0093, B7: the files of a bundle given as a folder tree, and the pool of their paths.
    pub const module_files: comptime_int = active.module_files;
    pub const module_file_paths_bytes = module_files * module_path_bytes;
    pub const report_work: comptime_int = active.report_work;
    pub const report_bytes: comptime_int = active.report_bytes;
    pub const document_bytes: comptime_int = active.document_bytes;
    pub const instantiation_depth: comptime_int = active.instantiation_depth;
    pub const effect_entries: comptime_int = active.effect_entries;
    pub const effect_bytes: comptime_int = active.effect_bytes;
    pub const tasks: comptime_int = active.tasks;
    pub const saved_frames: comptime_int = active.saved_frames;
    pub const saved_registers: comptime_int = active.saved_registers;
    pub const scheduler_actions: comptime_int = active.scheduler_actions;
    pub const live_edges: comptime_int = active.live_edges;
    pub const live_evaluations: comptime_int = active.live_evaluations;
    pub const live_record_evaluations: comptime_int = active.live_record_evaluations;
    pub const live_height: comptime_int = active.live_height;
    pub const deliveries: comptime_int = active.deliveries;
};

pub const Span = struct {
    start: u32,
    end: u32,

    /// The name of the receiver parameter of a method. It has no place in the source text.
    pub const self_word: Span = .{ .start = std.math.maxInt(u32) - 4, .end = std.math.maxInt(u32) };

    pub fn text(self: Span, source: []const u8) []const u8 {
        if (self.start == self_word.start and self.end == self_word.end) return "Self";
        std.debug.assert(self.start <= self.end);
        std.debug.assert(self.end <= source.len);
        return source[self.start..self.end];
    }
};

pub const Diagnostic = struct {
    span: Span,
    code: Code,
    /// A second place the diagnostic names, empty when it names one: for `shadowed_name`, the
    /// declaration that already gives the name a meaning, when it is in the same file. Only
    /// the compiler sets it; a machine's diagnostics name one place.
    related: Span = .{ .start = 0, .end = 0 },

    pub const Code = enum {
        source_limit,
        invalid_utf8,
        invalid_character,
        token_limit,
        identifier_limit,
        unterminated_string,
        invalid_escape,
        expected_name,
        expected_type,
        unsupported_type,
        unsupported_specifier,
        expected_equal,
        expected_expression,
        unexpected_token,
        unmatched_parenthesis,
        expression_limit,
        node_limit,
        binding_limit,
        local_binding_limit,
        function_limit,
        parameter_limit,
        template_limit,
        compiler_work_limit,
        expected_parameter,
        expected_computes,
        argument_count,
        expected_call,
        not_callable,
        recursive_call,
        string_limit,
        duplicate_name,
        unknown_name,
        type_mismatch,
        integer_range,
        arithmetic_overflow,
        division_by_zero,
        index_out_of_range,
        work_limit,
        invalid_ir,
        unknown_native,
        case_scrutinee,
        case_arms,
        case_not_exhaustive,
        case_pattern,
        for_syntax,
        overload_conflict,
        ambiguous_call,
        macro_syntax,
        macro_unavailable,
        unknown_parameter,
        duplicate_argument,
        named_argument_order,
        macro_limit,
        path_index_effects,
        interpolation_depth,
        scratch_unavailable,
        native_failed,
        invalid_native,
        invalid_bytecode,
        transaction_limit,
        undo_limit,
        object_limit,
        invalid_parent,
        missing_override,
        unexpected_override,
        override_mismatch,
        final_method,
        unimplemented_method,
        method_limit,
        inaccessible_member,
        invalid_interface,
        abstract_instance,
        intent_limit,
        outbox_limit,
        requirement_failed,
        invalid_number,
        float_range,
        type_limit,
        field_limit,
        aggregate_limit,
        expected_field,
        unknown_field,
        duplicate_field,
        missing_field,
        array_type_required,
        report_limit,
        case_limit,
        expected_case,
        unknown_case,
        duplicate_case,
        tuple_limit,
        tuple_arity,
        expected_tuple_index,
        tuple_index,
        option_arity,
        contextual_type_required,
        invalid_map_key,
        expected_map_value,
        duplicate_map_key,
        module_limit,
        import_limit,
        invalid_module_path,
        duplicate_module,
        missing_module,
        module_cycle,
        late_import,
        private_name,
        private_type_escape,
        invalid_module_metadata,
        module_bundle_required,
        failure_context_required,
        control_limit,
        control_storage_required,
        language_failure,
        not_mutable,
        effect_mismatch,
        source_cell_limit,
        state_storage_required,
        call_depth_limit,
        call_register_limit,
        call_argument_limit,
        call_trace_limit,
        negative_iteration_count,
        not_comparable,
        failure_expected,
        return_outside_function,
        return_not_tail,
        return_type_required,
        break_outside_loop,
        defer_position,
        defer_empty,
        defer_exit,
        defer_failure,
        runtime_error,
        first_exit,
        invalid_char_literal,
        constructor_body,
        invalid_delegation,
        construction_cycle,
        final_field,
        instantiation_limit,
        type_argument_bound,
        type_arguments_required,
        discarded_comparison,
        shadowed_name,
        internal_member,
        not_unique,
        related_overloads,
        used_before_declaration,
        variable_read_requires_reads,
        field_read_requires_reads,
        set_requires_writes,
        construction_requires_allocates,
        call_requires_reads,
        call_requires_writes,
        call_requires_allocates,
        call_requires_reads_writes,
        call_requires_reads_allocates,
        call_requires_writes_allocates,
        call_requires_transacts,
        call_requires_suspends,
        suspends_in_failure_context,
        effect_specifier_conflict,
        decides_with_suspends,
        converges_position,
        override_widens_reads,
        override_widens_writes,
        override_widens_allocates,
        override_widens_decides,
        override_widens_suspends,
        class_effect_specifier,
        class_effect_narrower_reads,
        class_effect_narrower_writes,
        class_effect_narrower_allocates,
        class_effect_required_reads,
        class_effect_required_writes,
        class_effect_required_allocates,
        local_var_requires_writes,
        effect_specifier_repeated,
        unreachable_arm,
        case_cannot_fail,
        effect_limit,
        effect_prepare_failed,
        effect_commit_failed,
        diagnostic_position,
        generic_method_slot,
        not_castable,
        not_concrete,
        /// RFC-0082: structured concurrency.
        return_in_task_body,
        arm_assigns_local,
        task_limit,
        suspended_frame_limit,
        scheduler_action_limit,
        invalid_sleep_duration,
        /// RFC-0083: refinement types, qualifiers, open enums.
        refinement_bound,
        outside_refinement,
        invalid_qualifier,
        open_enum_case,
        subsumed_arm,
        /// RFC-0082, P3.3: `Sync` and `Race`, and the landings of cancellation.
        sync_arms,
        concurrency_arms,
        exit_in_arm,
        landing_assigns_local,
        /// RFC-0082, P3.4: `Rush` and `Branch` in a loop.
        concurrency_in_loop,
        /// RFC-0084: live variables.
        guard_effect,
        guard_local_var,
        live_target,
        live_assigned,
        live_unstable,
        live_propagation_limit,
        live_edge_limit,
        live_deferred,
        /// RFC-0084, P4.2: live fields.
        live_field_default,
        construction_requires_reads,
        construction_requires_writes,
        /// RFC-0084, P4.3: functions as types.
        live_type_form,
        live_initializer,
        /// RFC-0084, P4.4: reactions.
        reaction_limit,
        reaction_body_suspends,
        /// RFC-0084, P4.5: `Batch{...}`.
        batch_suspends,
        /// RFC-0085, I7: transparent functions.
        transparent_recursion,
        transparent_method,
        transparent_generic,
        /// RFC-0085, I12: `<predicts>`.
        call_requires_dictates,
        form_requires_dictates,
        construction_requires_dictates,
        override_widens_dictates,
        /// RFC-0086, P2.2: inputs.
        input_limit,
        input_failed,
        input_unavailable,
        input_invalid,
        input_diverged,
        /// RFC-0085, I8: accessors.
        accessor_pair,
        accessor_mutable,
        accessor_signature,
        accessor_effect,
        accessor_default,
        accessor_override,
        accessor_construction,
        accessor_archetype,
        accessor_live,
        /// RFC-0085, I2: shared locals.
        local_read_requires_reads,
        guard_capture_var,
        /// RFC-0087, P5.1: `weak_map(K, V)`.
        weak_map_operation,
        weak_map_key,
        /// RFC-0085, I3: nested functions.
        nested_access,
        nested_super,
        nested_generic,
        nested_position,
        /// RFC-0085, I4: overloads, defaults and named parameters of nested functions.
        nested_default,
        /// RFC-0087, P5.2: `<persistable>` types.
        persistable_final,
        persistable_unique,
        persistable_inherits,
        persistable_parametric,
        persistable_field,
        persistable_default,
        /// RFC-0086, P2.5: recovery. The first a resumed run's journal gives; the other two the
        /// tool gives before anything runs.
        recovery_diverged,
        recovery_mismatch,
        run_unfinished,
        /// RFC-0082, P3.8: a clause or the body of a `For` whose body suspends can fail.
        suspending_for_fails,
        /// RFC-0087, P5.4: keyed cells.
        weak_map_whole,
        weak_map_initializer,
        /// RFC-0087, P5.3: JSON.
        json_type,
        json_depth_limit,
        /// RFC-0085, I14 (RFC-0084, P4.8): live locals.
        live_local_default,
        /// RFC-0087, P5.5: a persistent cell's value type is persistable (W7), and a stored entry
        /// that does not decode as it ends the run (S4, G7).
        weak_map_value,
        load_invalid,
        /// RFC-0089, B1: lexical completion.
        unterminated_comment,
        invalid_hex_literal,
        misplaced_indented_comment,
        /// RFC-0053, B5: a program's own `ToString`.
        to_string_signature,
        /// RFC-0087, P5.6 (G3): the host's, before a run: the schema of the store's generation
        /// refuses the program's. The reason follows the message.
        schema_incompatible,
        /// RFC-0090, B2: control-flow completion.
        if_without_else,
        for_clause_exit,
        case_scrutinee_type,
        /// RFC-0091, B3: calls of module functions declared further down.
        forward_value_between,
        forward_signature,
        forward_arguments,
        parameter_pattern,
        type_inference,
        /// RFC-0092, B4: classes completion.
        struct_effect_required_reads,
        struct_effect_required_writes,
        struct_effect_required_allocates,
        final_super_parent,
        final_super_required,
        final_super_after_query,
        /// RFC-0093, B7: a module path in a program that is not a bundle given as a folder tree.
        folder_bundle_required,
        path_import_required,
        /// RFC-0076 D16 (TASK-0109 W2 round 2, N-3): an option beside `logic`.
        option_logic_overloads,
        /// TASK-0109, B8: tightened to the Book (RFC-0067 amendment).
        castable_parametric,
        underscore_name,
    };

    pub fn message(self: Diagnostic) []const u8 {
        return switch (self.code) {
            .source_limit => "source exceeds the 64 KiB limit",
            .invalid_utf8 => "source must be valid UTF-8",
            .invalid_character => "unsupported character",
            .token_limit => "token budget exhausted",
            .identifier_limit => "identifier exceeds 128 bytes",
            .unterminated_string => "string must close before the end of the line",
            .invalid_escape => "unsupported string escape or control character",
            .expected_name => "expected a declaration name",
            .expected_type => "expected a type annotation after ':'",
            .unsupported_type => "expected a scalar, earlier record/enum, array, tuple, option, map or function type",
            .unsupported_specifier => "unsupported specifier in the pure core",
            .expected_equal => "expected '=' before the binding expression",
            .expected_expression => "expected a value expression",
            .unexpected_token => "unexpected token in expression",
            .unmatched_parenthesis => "unmatched parenthesis",
            .expression_limit => "expression nesting/stack budget exhausted",
            .node_limit => "IR node budget exhausted",
            .binding_limit => "binding budget exhausted",
            .local_binding_limit => "live local binding budget exhausted",
            .function_limit => "pure function budget exhausted",
            .parameter_limit => "function parameter budget exhausted",
            .template_limit => "function template node budget exhausted",
            .compiler_work_limit => "pure function expansion work budget exhausted",
            .expected_parameter => "expected a typed function parameter",
            .expected_computes => "functions require a heap effect: <computes>, <transacts>, or any of <reads>, <writes>, <allocates>",
            .argument_count => "call argument count does not match the function signature",
            .expected_call => "call argument syntax does not match the function signature",
            .not_callable => "this value is not a function",
            .recursive_call => "this operation requires an earlier function",
            .string_limit => "decoded string budget exhausted",
            .duplicate_name => "name is already defined in this scope",
            .unknown_name => "name must refer to a parameter or earlier declaration",
            .type_mismatch => "expression type does not match the required type",
            .integer_range => "integer literal is outside the i64 range",
            .arithmetic_overflow => "i64 arithmetic overflow",
            .division_by_zero => "division by zero",
            .index_out_of_range => "array index is outside the array",
            .work_limit => "evaluation work budget exhausted",
            .invalid_ir => "invalid typed IR",
            .unknown_native => "no native function with this id is registered with the host",
            .case_scrutinee => "a Case needs a scrutinee expression before its arms",
            .case_arms => "Case takes a scrutinee and pattern=>value arms; _=>value is only allowed last",
            .case_not_exhaustive => "a Case without a _=>value default must list every case of an enum exactly once, match an option both ways, or end in an arm that takes every value",
            .macro_limit => "too many macro expansions in one program",
            .unknown_parameter => "the function has no parameter with this name",
            .duplicate_argument => "this parameter already has an argument",
            .named_argument_order => "positional arguments must come before named ones",
            .macro_syntax => "this macro call is malformed: an If with several conditions or a tuple pattern",
            .macro_unavailable => "this macro needs its library block, which the compiler adds and retries",
            .overload_conflict => "functions of one name must agree on whether they can fail",
            .ambiguous_call => "this name has several definitions; the context does not choose one",
            .for_syntax => "For and First take generators (X:Items, K->V:Items, X:Low..High), bindings (Y:=value), conditions and a body",
            .case_pattern => "a Case pattern is a constant of names, literals and arithmetic, Name:Type, option{...}, tuple{...} or Type{Field:=...}; test anything else in a where guard",
            .interpolation_depth => "string interpolations nest too deeply",
            .path_index_effects => "an index repeated by a nested or compound update may use only names, numbers and + - * /; bind it first",
            .scratch_unavailable => "host scratch memory for cold evaluation is unavailable",
            .native_failed => "a native function reported a fatal error",
            .invalid_native => "a native function produced a result that does not match its declared type",
            .invalid_bytecode => "invalid typed bytecode or transaction structure",
            .transaction_limit => "transaction nesting budget exhausted",
            .undo_limit => "transaction undo budget exhausted",
            .object_limit => "object storage exhausted",
            .invalid_parent => "a class inherits from an earlier, complete class that is not final",
            .missing_override => "a method that redeclares an inherited method must say <override>",
            .unexpected_override => "<override> needs an inherited method of the same name",
            .override_mismatch => "an override keeps the parameter types of the method it replaces; its result and its access may only stay or narrow",
            .final_method => "a final method cannot be overridden",
            .unimplemented_method => "a class that is not abstract must implement every method it inherits",
            .method_limit => "too many methods",
            .invalid_interface => "an interface declares only methods without bodies; a class names one superclass and up to eight interfaces",
            .inaccessible_member => "a private member is used only by its class, a protected one also by subclasses",
            .abstract_instance => "an abstract class cannot be constructed",
            .intent_limit => "pending intent budget exhausted",
            .outbox_limit => "committed intent queue is full",
            .requirement_failed => "transaction requirement failed",
            .invalid_number => "expected digits in a decimal fraction or exponent",
            .float_range => "finite float literal exceeds binary64 range; use Inf explicitly",
            .type_limit => "type definition budget exhausted",
            .field_limit => "record field budget exhausted",
            .aggregate_limit => "aggregate element storage budget exhausted",
            .expected_field => "expected a named record field",
            .unknown_field => "record has no such field",
            .duplicate_field => "record field is supplied more than once",
            .missing_field => "record constructor must supply every field",
            .array_type_required => "empty array requires a contextual array type",
            .report_limit => "value report exceeds its work or output budget",
            .case_limit => "enum case budget exhausted",
            .expected_case => "expected a named enum case",
            .unknown_case => "enum has no such case",
            .duplicate_case => "enum case is declared more than once",
            .tuple_limit => "tuple element type budget exhausted",
            .tuple_arity => "tuple member count does not match its type",
            .expected_tuple_index => "tuple selection requires an unsigned integer literal",
            .tuple_index => "tuple position is outside its element range",
            .option_arity => "option constructor requires zero or one member",
            .contextual_type_required => "empty option or map requires its contextual type",
            .invalid_map_key => "map keys require a comparable type: no function, nor anything that holds one",
            .expected_map_value => "map entries require a key => value pair",
            .duplicate_map_key => "map constructor contains an equal key more than once",
            .module_limit => "module inventory budget exhausted",
            .import_limit => "module import budget exhausted",
            .invalid_module_path => "module path must stay inside the virtual bundle root",
            .duplicate_module => "module path occurs more than once in the inventory",
            .missing_module => "module path is absent from the supplied inventory",
            .module_cycle => "module imports contain a cycle",
            .late_import => "imports must form the module declaration prefix",
            .private_name => "imported declaration is private",
            .private_type_escape => "public API cannot expose a private nominal type",
            .invalid_module_metadata => "invalid module source or import metadata",
            .failure_context_required => "failable expression requires an Attempt body or <decides>",
            .control_limit => "control nesting budget exhausted",
            .control_storage_required => "control evaluation requires caller-owned ControlStorage",
            .language_failure => "explicit language failure",
            .not_mutable => "write target must be a declared mutable binding",
            .effect_mismatch => "mutable state and transacts calls require <transacts>",
            .source_cell_limit => "typed source cell budget exhausted",
            .state_storage_required => "source mutation requires caller-owned ReferenceState",
            .call_depth_limit => "runtime call depth budget exhausted",
            .call_register_limit => "runtime call register budget exhausted",
            .call_argument_limit => "call argument reference budget exhausted",
            .call_trace_limit => "runtime call step trace budget exhausted",
            .negative_iteration_count => "iteration count must be nonnegative",
            .not_comparable => "this type has no equality: a function, a task, a value held as any, or something that holds one",
            .failure_expected => "logic{...} needs an expression that can fail",
            .return_outside_function => "Return needs an enclosing function",
            .return_not_tail => "Return must be the last expression of its block or arm",
            .return_type_required => "Return needs a function with a declared result type",
            .break_outside_loop => "Break needs an enclosing Loop{...}",
            .defer_position => "Defer must be a statement of a Block or Loop{...} with code after it",
            .defer_empty => "Defer needs code to run",
            .defer_exit => "deferred code cannot leave its Defer with Return or Break",
            .defer_failure => "deferred code cannot fail",
            .runtime_error => "Err ended the run",
            .first_exit => "Return and Break cannot leave a First[...]",
            .invalid_char_literal => "a character literal is one character or escape in single quotes, 0oXX for a code unit or 0uXXXXXX for a Unicode scalar value",
            .constructor_body => "the body of a constructor function is one archetype of its class",
            .invalid_delegation => "an archetype delegates once, to a constructor function of its class or of a superclass",
            .construction_cycle => "a class cannot be built inside its own block clauses",
            .final_field => "a final field keeps its default: it cannot be given a value or restated",
            .instantiation_limit => "parametric types are instantiated too deeply: a type whose body names itself with a growing argument never ends",
            .type_argument_bound => "this type argument is not a subtype of the bound its parameter declares",
            .type_arguments_required => "a parametric type is named with its type arguments: Name[type, ...]",
            .used_before_declaration => "this name was already used in this scope as a standard function before this declaration of it",
            .variable_read_requires_reads => "reading a `var` requires <reads>",
            .field_read_requires_reads => "reading a field of a class instance requires <reads>",
            .set_requires_writes => "`set` requires <writes>",
            .construction_requires_allocates => "constructing a class instance requires <allocates>",
            .call_requires_reads => "this call requires <reads>: what it calls reads mutable state",
            .call_requires_writes => "this call requires <writes>: what it calls writes mutable state",
            .call_requires_allocates => "this call requires <allocates>: what it calls constructs class instances",
            .call_requires_reads_writes => "this call requires <reads> and <writes>: what it calls reads and writes mutable state",
            .call_requires_reads_allocates => "this call requires <reads> and <allocates>: what it calls reads mutable state and constructs class instances",
            .call_requires_writes_allocates => "this call requires <writes> and <allocates>: what it calls writes mutable state and constructs class instances",
            .call_requires_transacts => "this call requires <transacts>: what it calls reads, writes and allocates",
            .call_requires_suspends => "this call requires <suspends>: a <suspends> function is called only from a <suspends> function",
            .suspends_in_failure_context => "a <suspends> function cannot be called in a failure context or in deferred code",
            .effect_specifier_conflict => "<computes> and <transacts> each stand alone: neither combines with the other or with <reads>, <writes>, <allocates>",
            .decides_with_suspends => "<decides> and <suspends> cannot be combined on one function",
            .converges_position => "<converges> is allowed only on a native, an abstract method and a function type",
            .override_widens_reads => "an override may narrow the effects of the method it replaces, never widen them: this one adds <reads>",
            .override_widens_writes => "an override may narrow the effects of the method it replaces, never widen them: this one adds <writes>",
            .override_widens_allocates => "an override may narrow the effects of the method it replaces, never widen them: this one adds <allocates>",
            .override_widens_decides => "an override may narrow the effects of the method it replaces, never widen them: this one adds <decides>",
            .override_widens_suspends => "an override may narrow the effects of the method it replaces, never widen them: this one adds <suspends>",
            .class_effect_specifier => "a class, interface or struct takes only heap effects: <computes>, <reads>, <writes>, <allocates> or <transacts>",
            .class_effect_narrower_reads => "a class declares at least the effects of what it extends and of the block clauses it inherits: <reads> is missing",
            .class_effect_narrower_writes => "a class declares at least the effects of what it extends and of the block clauses it inherits: <writes> is missing",
            .class_effect_narrower_allocates => "a class declares at least the effects of what it extends and of the block clauses it inherits: <allocates> is missing",
            .class_effect_required_reads => "constructing an instance of this class requires <reads>, which its class declares",
            .class_effect_required_writes => "constructing an instance of this class requires <writes>, which its class declares",
            .class_effect_required_allocates => "constructing an instance of this class requires <allocates>, which its class declares",
            .local_var_requires_writes => "declaring a local `var` requires <writes>",
            .effect_specifier_repeated => "this effect is already written in this signature: each effect is written once",
            .module_bundle_required => "imports require an explicit immutable module bundle",
            .discarded_comparison => "the result of this comparison is discarded: write Require[...] to make it a check, or bind or use the value",
            .shadowed_name => "this name is already visible here and may not be shadowed: choose another name",
            .internal_member => "this member is internal to the module that declares its type: mark it <public> to use it from another module",
            .not_unique => "only instances of a class<unique> are compared or used as map keys, and a class below a unique class says <unique> too",
            .effect_limit => "effect log budget exhausted: too many actions, or too many bytes, wait for a region to commit",
            .effect_prepare_failed => "the host refused to prepare an effect",
            .effect_commit_failed => "the host could not commit an effect: what was committed before it stays",
            .diagnostic_position => "a diagnostic is only printed: write Print(ToDiagnostic(Value))",
            .related_overloads => "these overloads take class types related by subtyping at the same parameter, so one value fits both: keep one, or make it a method",
            .unreachable_arm => "no value selects this Case arm: an arm before it is written the same and takes whatever it would",
            .case_cannot_fail => "Case[...] fails when no arm takes the value, so it has no arm that takes every value: write Case(...)",
            .generic_method_slot => "a generic method has no dispatch slot: its body is written in braces, as a generic function's, and it is not abstract, overrides nothing and nothing overrides it",
            .not_castable => "only a <castable> class, or one below it, is a castable_subtype; a type value casts only as a castable_subtype",
            .not_concrete => "only a <concrete> class that is not abstract is a concrete_subtype, built with {} and nothing in the braces",
            .return_in_task_body => "Return and Break cannot leave the body of a Spawn or a Branch: a task has no caller to return to",
            .arm_assigns_local => "the body of a Spawn or a Branch and an arm of Sync, Race or Rush capture the parameters and immutable locals around them by value and cannot assign them; a local var they assign is shared",
            .task_limit => "live task budget exhausted",
            .suspended_frame_limit => "suspended task frame or register budget exhausted",
            .scheduler_action_limit => "pending Spawn and Signal budget exhausted: too many held by rollback regions, or committed and not yet carried out",
            .invalid_sleep_duration => "Sleep needs a number of seconds, not NaN",
            .refinement_bound => "a refinement is type{_X:i64 where ...} or type{_X:float where ...}: each constraint compares the placeholder with a literal of the base type (an integer; a float with a point, Inf or -Inf, never NaN) by <, <=, > or >=, with at most one bound on each side and some value between them",
            .outside_refinement => "this constant lies outside the bounds of the refinement type: a value known only at run time is converted with Type[Value]",
            .invalid_qualifier => "a qualifier is (local:) before a local or a parameter of a function, (Module:) before a name that the module declares, or (e:) before an enumerator of the enum e",
            .open_enum_case => "an open enum may gain cases: a Case(...) over it needs a _=>value arm, or write Case[...], which fails instead",
            .subsumed_arm => "no value selects this Case arm: an arm before it takes every value of its type, which is the same type or one below it",
            .sync_arms => "Sync waits for at least two arms that can suspend: an arm that never waits is code to write before or after it",
            .concurrency_arms => "Sync, Race and Rush take at least two arms, and no more than a call takes arguments",
            .exit_in_arm => "Return and Break cannot leave an arm of Sync, Race or Rush",
            .landing_assigns_local => "a Defer whose scope holds a suspension site also runs, when its task is cancelled there, as a function of its own: it cannot assign a parameter or an immutable local of the code around it",
            .concurrency_in_loop => "Rush and Branch cannot stand in the body of a Loop{} or a While, whose visits are not the function's frame: write them in a function the loop calls",
            .guard_effect => "a guard may only read: it runs again whenever what it read changes, so it cannot write, build an instance, act, draw or suspend",
            .guard_local_var => "a guard cannot name a local var: it would capture a copy that never changes, so the guard would never follow it; use a module var",
            .live_target => "set live attaches a guard to a module var, a local var or a var field of an instance: a parameter, an immutable binding, a local declared with a function as its type (a function's name or `->` in the type position; an ordinary function type is fine), a live-only local, an element or a struct field is not a live target",
            .live_assigned => "a live variable declared with live is never set by the program: only its guard gives it a value",
            .live_unstable => "a live variable was evaluated too many times in one update: it lies on a cycle of live variables that does not settle",
            .live_propagation_limit => "live variable update budget exhausted: too many guard evaluations in one update",
            .live_edge_limit => "live dependency budget exhausted: the guards read too many variables",
            .live_deferred => "set live cannot stand in a Defer body that runs at more than one exit: each copy would need a guard of its own",
            .live_field_default => "a live field starts from the default of its type until its guard is attached, and this type has none: give the field a type with a default",
            .construction_requires_reads => "constructing an instance of a class with a live field requires <reads>: its guards run",
            .construction_requires_writes => "constructing an instance of a class with a live field requires <writes>: its guards write its fields",
            .live_type_form => "a function used as a type is a function's name or an instance's method, of one parameter, that reads at most: not a call, not a value, and without <decides>, <suspends>, <writes> or <allocates>",
            .live_initializer => "a variable whose type is a function needs an initial value: write '= value' after its type",
            .reaction_limit => "reaction budget exhausted: too many deliveries in one round of notifications, as when two When bodies keep writing what each other's guard reads",
            .reaction_body_suspends => "the body of an Upon or a When runs at once when its guard succeeds and cannot suspend: start a task with Spawn{...} in it to wait",
            .batch_suspends => "the body of a Batch holds notifications back until it ends and cannot suspend: start a task with Spawn{...} in it to wait",
            .transparent_recursion => "a transparent function takes its result type from its body, so its body cannot name the function itself: write the result type, Name(...)<effects>:Type = ...",
            .transparent_method => "a method cannot be transparent: write its result type, Name(...)<effects>:Type = ...",
            .transparent_generic => "a generic function cannot be transparent: write its result type, Name[...](...)<effects>:Type = ...",
            .call_requires_dictates => "a <predicts> function can only call <predicts> functions: this one dictates, as every function does that does not say <predicts>",
            .form_requires_dictates => "live state is authoritative: set live, Upon, When, Await of a guard and Batch dictate, and a <predicts> function cannot use them",
            .construction_requires_dictates => "a <predicts> function builds only instances whose block clauses and field defaults predict: state <predicts> on the class, beside its effect",
            .override_widens_dictates => "the method this overrides predicts, so whoever calls it may predict: the override must say <predicts> too",
            .input_limit => "input record budget exhausted: the run read more from the world than its record holds",
            .input_failed => "the host could not read an input: the device answered with an error",
            .input_unavailable => "the run read an input, and its host gives it none",
            .input_invalid => "the host gave an input that is not a value of its kind: a time that is not a number, or a line that is not UTF-8 text",
            .weak_map_operation => "a weak_map can only be looked up and set one key at a time: it has no Length, no iteration, no equality and no conversion back to a map, and it cannot be a map key, comparable or joined with ConcatenateMaps",
            .weak_map_key => "weak_map keys require a comparable type: no function, class without <unique>, any or weak_map, nor anything that holds one",
            .input_diverged => "the run asked for an input other than the one its record holds at this place: the record is of another run",
            .accessor_pair => "a field with accessors states both <getter(G)> and <setter(S)>",
            .accessor_mutable => "only a var field has accessors: write var Name<getter(G)><setter(S)>:Type = external{}",
            .accessor_signature => "an accessor is a method of the field's own class or interface, with a body: the getter G(:accessor)<effects>:Type, the setter S(:accessor, Value:Type)<effects>:void, the accessor parameter unnamed and Type the field's",
            .accessor_effect => "a field access neither fails nor suspends, so its getter and setter cannot declare <decides> or <suspends>",
            .accessor_default => "a field with accessors has no cell of its own: its default is = external{}, or it has none and every archetype gives it a value",
            .accessor_override => "the accessors of a field are fixed where the field is declared: no subclass or implementing class restates the field, declares a member of its name, or overrides its getter or setter",
            .accessor_construction => "an accessor value is made only by an access to a field with accessors, so that its getter and setter run only through the field",
            .accessor_archetype => "a field with = external{} has no cell to initialise: assign it with set after the instance is built",
            .accessor_live => "a field with accessors has no cell, so it cannot be live: a guard that reads it tracks what its getter reads",
            .local_read_requires_reads => "this local var is shared with a closure that names it, so other code can change it: reading it needs <reads>, as reading any var does",
            .guard_capture_var => "a guard cannot name a local var through what an Fn, a task body or an arm captured: it would follow a copy that never changes; use a module var",
            .nested_access => "a nested function is private to the function that declares it, so it takes no access specifier",
            .nested_super => "a nested function cannot call the superclass's method: call it in the method, Super.Name(...), and use its result in the nested function",
            .nested_generic => "a nested function cannot have type parameters; the function around it may",
            .nested_position => "a nested function is a statement of a Block{...} written as such, and none stands in a Defer body, which is copied to every exit",
            .nested_default => "a default of a nested function reads what a top-level function's default reads: literals, module declarations and the parameters before it, not the locals or parameters of the code around it",
            .persistable_final => "a <persistable> class is <final>: saved data names its class, so no subclass can stand for it",
            .persistable_unique => "a <persistable> class cannot be <unique>: an instance's identity ends with the run, and saved data has none",
            .persistable_inherits => "a <persistable> class has no superclass and implements no interface",
            .persistable_parametric => "a <persistable> type is not parametric: saved data names its type, which a type parameter would leave open",
            .persistable_field => "every field of a <persistable> type is persistable: logic, i64, float, string, char, char32, arrays, options, tuples and maps of persistable types, and <persistable> structs, classes and enums; a var field never is",
            .persistable_default => "a field default of a <persistable> type is a literal constant: a number, character, string without interpolation, true, false, an enumerator, option{}, or option{...}, array{...}, map{...}, tuple{...} or a <persistable> struct's archetype of literal constants",
            .recovery_diverged => "the resumed run did not do what its journal holds: it committed another action or commit point, asked for another input, or ended before the journal's last seal; the journal is left as it was",
            .recovery_mismatch => "the journal is of another run: its program, toolchain, profile, seed, tick rate or grants differ, or a reader cannot be repositioned or has changed since",
            .run_unfinished => "the state directory holds an unfinished run: continue it with --resume, or end it with --abandon",
            .suspending_for_fails => "the body of this For suspends, so an iteration has no rollback region: none of its generators, filters, bindings or body may fail, and this one can",
            .weak_map_whole => "a module var of type weak_map(session, V) is a keyed cell: it can neither be read nor replaced whole, only looked up as X[K] and set as set X[K] = V",
            .weak_map_initializer => "a keyed cell starts empty: its initialiser is map{}",
            .json_type => "ToJson and FromJson take a persistable type: logic, i64, float, string, char, char32, arrays, options, tuples and maps of persistable types, and <persistable> structs, classes and enums",
            .json_depth_limit => "JSON depth limit exceeded: the value nests more than 65,536 arrays and objects",
            .live_local_default => "a live local's type has no default value for its cell to hold before its guard gives it one: a class, a function, any, a task, an event, rational or a refinement",
            .weak_map_value => "a persistent cell's value type is persistable: logic, i64, float, string, char, char32, arrays, options, tuples and maps of persistable types, and <persistable> structs, classes and enums",
            .load_invalid => "a stored entry of a persistent cell does not decode as the cell's value type: the store is damaged, or was written for another schema",
            .unterminated_comment => "a block comment opened with <# must close with #> before the end of the source",
            .invalid_hex_literal => "a hexadecimal literal is 0x followed by hexadecimal digits and no name character or fraction",
            .misplaced_indented_comment => "an indented comment <#> stands alone at the start of its line, after white space only",
            .to_string_signature => "a ToString the program declares takes one value of a type with no built-in text and returns a string that does not fail: ToString(Value:Point):string",
            .schema_incompatible => "the program is incompatible with the store's schema",
            .if_without_else => "an If without an else has no value: it stands as a statement, or give it an else, If(Condition, Then, Else)",
            .for_clause_exit => "Return and Break cannot leave a For whose first clause is not a generator: start it with the generator, or test the clauses in an If around it",
            .case_scrutinee_type => "a Case arm that compares with a constant needs a scrutinee of an integer, logic, char, string, enum or integer refinement type, not a float, rational, tuple, struct, option or array: test it with a guard, X:float where X == 1.0 => ..., or with If",
            .forward_value_between => "this function calls one declared after it, and a module value is declared between the two: a value is computed where it is declared, so declare it before the first of the functions or after the last",
            .forward_signature => "a function called before its declaration must have a signature that can be read at the call: one declaration of the name, no type parameters, a written result type (not :=), and parameter and result types declared before the call",
            .forward_arguments => "a call of a function declared after it gives every argument, by position or by name: a default is compiled with the declaration, which comes later",
            .parameter_pattern => "a destructured parameter is a tuple of two or more elements, each a name or a pattern, whose types are written once: on every name, (A:i64, B:i64), or on the whole pattern, (A, B):tuple(i64, i64); it has no default and is not a constructor's",
            .type_inference => "the type arguments of this call cannot be read off its arguments: each type parameter must be the type, or a part of an array, option, tuple or map type, of an argument, the same in all of them, with no effect parameter, no named argument and no failure; write them, Name[Type](...)",
            .struct_effect_required_reads => "constructing a value of this struct requires <reads>, which its struct declares",
            .struct_effect_required_writes => "constructing a value of this struct requires <writes>, which its struct declares",
            .struct_effect_required_allocates => "constructing a value of this struct requires <allocates>, which its struct declares",
            .final_super_parent => "a <final_super> class names its superclass: a class, not an interface",
            .final_super_required => "a class directly below a <final_super_base> class is <final_super>",
            .final_super_after_query => "a <final_super> class must be declared before a GetCastableFinalSuperClass that asks for its superclass",
            .castable_parametric => "a parametric class is not <castable>: its instantiations are not type values of any class bound; a class below a castable class may be parametric",
            .underscore_name => "_ is the wildcard of a Case pattern and names nothing else: give the declaration, parameter or field a name",
            .path_import_required => "in a bundle given as a folder tree, import names the module of a folder by its path, Name := import{/Domain/Folder}; a module declared in a file is reached through its folder's module",
            .folder_bundle_required => "a module path (/Domain/Path) names a module of a bundle given as a folder tree, whose root is a module path; a bundle of files imports a file by its relative path in quotes",
            .option_logic_overloads => "these overloads take an option and a logic at the same parameter, which the Book does not tell apart (its false is both): keep one, or give them different names",
        };
    }

    /// Where `related` is, if the diagnostic names a second place.
    pub fn relatedLocation(self: Diagnostic, source: []const u8) ?@TypeOf(self.location(source)) {
        if (self.related.start == self.related.end) return null;
        return (Diagnostic{ .span = self.related, .code = self.code }).location(source);
    }

    pub fn location(self: Diagnostic, source: []const u8) struct { line: u32, column: u32 } {
        var line: u32 = 1;
        var column: u32 = 1;
        for (source[0..@min(self.span.start, source.len)]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        return .{ .line = line, .column = column };
    }
};

/// Builtins retain stable IDs; user types index Program.definitions at ID - 4.
pub const Type = enum(u16) {
    i64 = 0,
    logic = 1,
    string = 2,
    float = 3,
    _,

    /// `char`, one UTF-8 code unit, and `char32`, one Unicode scalar value (RFC-0069). Their IDs
    /// lie above every catalogue ID, so no ID of an existing program moves. They are
    /// declarations and not fields on purpose: a field would make the word reserved
    /// (`std.meta.stringToEnum` is how names are reserved), and programs that already use
    /// `char` as a name must keep compiling.
    pub const char: Type = @fromBackingInt(character_base);
    pub const char32: Type = @fromBackingInt(character_base + 1);
    const character_base: u16 = 0xFF00;
    comptime {
        std.debug.assert(limits.user_types + 4 <= character_base);
    }

    /// Whether this is one of the two character types.
    pub fn isCharacter(self: Type) bool {
        return self == char or self == char32;
    }

    /// `any`, the top type (RFC-0080): a value of it is a value of some other type, unchanged.
    /// Nothing reads such a value but a checked cast (`instance_of`, `downcast`), which asks the
    /// value itself what it is. Like the character types it is a declaration, so that the word
    /// is not reserved, and its ID lies above the catalogue.
    pub const any: Type = @fromBackingInt(character_base + 2);

    /// `false`, the bottom type (RFC-0091, B3): it has no values, so a node of it never yields
    /// one (it ends the run, fails, exits or recurs without end) and stands where any type is
    /// expected. Its ID lies above the catalogue too; the word is a literal, never a name.
    pub const bottom: Type = @fromBackingInt(character_base + 3);

    pub fn jsonStringify(self: Type, json: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (self) {
            .i64 => try json.write("i64"),
            .logic => try json.write("logic"),
            .string => try json.write("string"),
            .float => try json.write("float"),
            else => if (self == char) try json.write("char") else if (self == char32) try json.write("char32") else if (self == any) try json.write("any") else if (self == bottom) try json.write("false") else try json.write(@backingInt(self)),
        }
    }
};

/// Whether `code` is a value of the character type `value_type`: a byte for `char`, and for
/// `char32` a Unicode scalar value, which excludes the surrogates and everything past U+10FFFF.
/// A character value is an `EnumValue` of its type whose index is the code, so this is the
/// whole of what distinguishes a well-formed character from a forged one.
pub fn validCharacter(value_type: Type, code: u64) bool {
    if (value_type == Type.char) return code <= 0xFF;
    if (value_type == Type.char32) return code <= 0x10FFFF and (code < 0xD800 or code > 0xDFFF);
    return false;
}

/// The value of a character of type `value_type`; `code` is already known to be valid.
pub fn characterValue(value_type: Type, code: u32) Value {
    std.debug.assert(validCharacter(value_type, code));
    return .{ .enumeration = .{ .value_type = value_type, .index = code } };
}

/// The operations of the `[]char` view of a string and of the character types (RFC-0069).
/// Positions are byte positions. Each machine implements and admits them on its own.
pub const TextOp = enum {
    /// `(string, i64) -> char`: the code unit at a position. The compiler guards `S[I]` with a
    /// bounds `demand`; a loop reads without one, so a position outside the string is the fatal
    /// `index_out_of_range`, never a read outside the pool.
    unit,
    /// `(string, i64) -> logic`: whether a position lies in `0..Length` and does not split the
    /// encoding of a scalar value. Total: any other integer is simply not a boundary.
    boundary,
    /// `(string, i64, i64) -> string`: the bytes from the first position up to the second, as a
    /// view of the same bytes. The positions lie in `0..Length` in order, and both are
    /// boundaries unless they are equal: exactly the slices that are valid UTF-8. An empty
    /// slice is the empty view at the start of the string, wherever it was taken. The compiler
    /// guards the operation with a `demand`; each machine still rejects any other slice.
    slice,
    /// `(string, i64) -> char32`: the scalar value whose encoding starts at a position. Guarded
    /// like `slice`; each machine still rejects a position that starts none.
    scalar,
    /// `(char) -> i64` or `(char32) -> i64`: the code unit or the code point.
    code,
    /// `(i64) -> char` or `(i64) -> char32`, by the node's type. Guarded by a range `demand`;
    /// each machine still rejects an integer that is no value of the type.
    from_code,
    /// `([]char) -> logic`: whether the code units, in order, are valid UTF-8.
    valid,
    /// `([]char) -> string`: the string of those code units. Guarded by `valid`; each machine
    /// still rejects units that are not valid UTF-8, so no string value ever holds any.
    join,

    pub fn arity(self: TextOp) usize {
        return switch (self) {
            .code, .from_code, .valid, .join => 1,
            .unit, .boundary, .scalar => 2,
            .slice => 3,
        };
    }
    /// The operations whose cost depends on how many code units they visit. They are control
    /// operations, like `to_string`: only the paths that charge fuel per operation run them.
    pub fn walks(self: TextOp) bool {
        return self == .valid or self == .join;
    }
};
/// Operands are register indexes; the ones an operation does not take are zero.
pub const Text = struct {
    op: TextOp,
    a: u32,
    b: u32 = 0,
    c: u32 = 0,

    pub fn operand(self: Text, ordinal: usize) u32 {
        std.debug.assert(ordinal < self.op.arity());
        return switch (ordinal) {
            0 => self.a,
            1 => self.b,
            else => self.c,
        };
    }
    /// The same operation on other registers.
    pub fn mapped(self: Text, operands: [3]u32) Text {
        const count = self.op.arity();
        return .{ .op = self.op, .a = operands[0], .b = if (count > 1) operands[1] else 0, .c = if (count > 2) operands[2] else 0 };
    }
    /// No operand that the operation does not take is set: one encoding per operation.
    pub fn canonical(self: Text) bool {
        const count = self.op.arity();
        return (count > 1 or self.b == 0) and (count > 2 or self.c == 0);
    }
};
/// `hidden` is set on a field of a public class that is `<internal>` or `<private>` and whose
/// type cannot be named outside its module (RFC-0076 D14): the field does not make its class
/// private, and no `public_only` report prints it or follows it.
/// `live_only` (RFC-0084, P4.2): a class field declared `live F:T = G`, which only its guard
/// writes; it is not `is_var`, but its reads are dependencies.
/// `constant` (RFC-0087, P5.2): on a field of a `<persistable>` struct or class that has a
/// default, the index in `Program.constants` of that default as a value (T5).
pub const Field = struct { name: Span, value_type: Type, is_var: bool = false, hidden: bool = false, live_only: bool = false, constant: ?u32 = null };
/// `arguments` is set on an instantiation of a parametric struct (RFC-0073): see `Class.arguments`.
pub const Record = struct {
    name: Span,
    fields: Span,
    is_public: bool,
    arguments: ?Type = null,
    /// A metatype (RFC-0081): a struct the compiler makes for `subtype(T)`, `castable_subtype(T)`
    /// or `concrete_subtype(T)`, named where the program first writes it. No template declares
    /// it, and it reaches wherever its argument does, as a structural type would.
    metatype: bool = false,
    /// `struct<persistable>` (RFC-0087, P5.2, T4).
    persistable: bool = false,
};
/// A class lists its parent's fields first (`inherited` of them, copied), so a field index means the
/// same field in every subclass. `abstract` classes cannot be constructed and `final` ones have no subclass.
pub const Class = struct {
    name: Span,
    fields: Span,
    is_public: bool,
    parent: ?Type = null,
    inherited: u32 = 0,
    is_abstract: bool = false,
    is_final: bool = false,
    /// An interface is an abstract class without fields or superclass; a class may list several.
    is_interface: bool = false,
    interfaces: [max_interfaces]Type = @splat(.i64),
    interface_count: u8 = 0,
    /// Set on an instantiation of a parametric class or interface (RFC-0073): the tuple type of
    /// its type arguments, as `RuntimeFunction.specialization` is for a generic function. `name`
    /// is then the template's name, shared by every instantiation, and `is_public` says whether
    /// the template is public. Name and arguments together are the identity of the type.
    arguments: ?Type = null,
    /// `class<unique>` (RFC-0076, D15): instances compare by identity with `==` and `!=` and may
    /// be map keys. Instances of any other class have no observable identity. A class below a
    /// unique class is unique; an interface never is.
    is_unique: bool = false,
    /// `class<final><persistable>` (RFC-0087, P5.2, T3).
    persistable: bool = false,
    /// `class<final_super>(Parent)` (RFC-0092, B4): the class is an anchor of its superclass's
    /// family, which `GetCastableFinalSuperClass` finds. It has a superclass, is no interface
    /// and no instantiation. A class directly below a `final_super_base` class has the mark.
    final_super: bool = false,
    /// `class<final_super_base>` (RFC-0092, B4): every class directly below it is `final_super`.
    final_super_base: bool = false,

    pub const max_interfaces = 8;
    pub fn implemented(self: *const Class) []const Type {
        return self.interfaces[0..@min(self.interface_count, max_interfaces)];
    }
};
/// `is_open` is set on an `enum<open>` (RFC-0083): a `Case(...)` over it is never exhaustive.
/// It is a property of the source only; no machine reads it.
/// `persistable` is set on an `enum<persistable>` (RFC-0087, P5.2, T6).
pub const Enumeration = struct { name: Span, cases: Span, is_public: bool, is_open: bool = false, persistable: bool = false };
/// RFC-0087, P5.2 (T5): a field default of a `<persistable>` type as a value, which the decoder
/// of P5.3 reads where a text lacks the field. `integer` is an `i64`; `enumeration` is the case
/// of an enum and `character` the code of a `char` or `char32`, as their nodes have them; `string`
/// is a span of the program's strings; `aggregate` is a span of `Program.constant_members`,
/// each an earlier constant, laid out as the members of a value of its type are (an option's
/// value, an array's elements, a tuple's or a struct's fields in order, a map's keys and values
/// side by side). No constant holds an instance: a class has no literal.
pub const Constant = struct {
    value_type: Type,
    kind: union(enum) {
        integer: i64,
        boolean: bool,
        floating: f64,
        string: Span,
        enumeration: u32,
        character: u32,
        aggregate: Span,
    },
};
/// A refinement type (RFC-0083): the values of its base, `i64` or `float`, that lie between two
/// bounds. A value of it is the base's value, unchanged: the type is what guarantees the bounds.
/// Only `refine` makes one, and each machine checks the bounds there.
///
/// The bounds are the bits of an `i64` or of an `f64`, by the base. An integer refinement has
/// closed bounds, a missing one being the end of the `i64` range, so `low_open` and `high_open`
/// are false. A float refinement has a bound on each side too, `-Inf` and `Inf` where none is
/// written, open or closed as written. No bound is a NaN, and some value lies between them.
pub const Refinement = struct {
    name: Span,
    base: Type,
    low: u64,
    high: u64,
    low_open: bool = false,
    high_open: bool = false,
    is_public: bool,

    /// Whether the bounds are well formed, as above.
    pub fn wellFormed(self: Refinement) bool {
        if (self.base == .i64) return !self.low_open and !self.high_open and @as(i64, @bitCast(self.low)) <= @as(i64, @bitCast(self.high));
        if (self.base != .float) return false;
        const low: f64 = @bitCast(self.low);
        const high: f64 = @bitCast(self.high);
        if (isNan(low) or isNan(high) or !isCanonicalFloat(low) or !isCanonicalFloat(high)) return false;
        if (low < high) return true;
        return low == high and !self.low_open and !self.high_open;
    }
};
pub const EnumValue = struct { value_type: Type, index: u32 };
pub const Map = struct { key: Type, value: Type };
/// What a declared effect says beyond `transacts` and `decides` (RFC-0078). `transacts` alone
/// is the Book's `<transacts>`, the heap effects `reads`, `writes` and `allocates` together; a
/// function that declares only some of them is `transacts` with the others given up here. The
/// form is canonical (`effectsCanonical`), so equal effect sets are equal bits and a signature
/// written before the families existed means what it meant.
pub const EffectDetail = packed struct(u8) {
    no_reads: bool = false,
    no_writes: bool = false,
    no_allocates: bool = false,
    /// `<suspends>`: may span updates once P3 lands. Excludes `decides`.
    suspends: bool = false,
    /// `<converges>`: vouched to terminate. Only a native's entry and a function type carry it.
    converges: bool = false,
    /// `<predicts>` (RFC-0085, I12): the function gives up `dictates`, so it may call only
    /// functions that predict too. No execution reads it.
    predicts: bool = false,
    reserved: u2 = 0,
};
/// One bit per fundamental effect, as the Book counts them: fewer bits is the subtype.
/// `diverges` is the absence of `<converges>`, so that a converging function has fewer.
pub const EffectSet = packed struct(u8) {
    reads: bool = false,
    writes: bool = false,
    allocates: bool = false,
    decides: bool = false,
    suspends: bool = false,
    diverges: bool = true,
    /// The Book's default prediction effect (13:401): the function runs with authority. A
    /// `<predicts>` function has it cleared and may call only functions without it.
    dictates: bool = true,
    reserved: u1 = 0,

    /// Every effect of `self` is one of `allowed`: `self` is usable where `allowed` is expected.
    pub fn within(self: EffectSet, allowed: EffectSet) bool {
        return @as(u8, @bitCast(self)) & ~@as(u8, @bitCast(allowed)) == 0;
    }
    /// The heap effects alone: what a call asks of the function it is written in.
    pub fn heap(self: EffectSet) EffectSet {
        return .{ .reads = self.reads, .writes = self.writes, .allocates = self.allocates, .diverges = false, .dictates = false };
    }
};
pub fn effectSet(transacts: bool, decides: bool, detail: EffectDetail) EffectSet {
    return .{
        .reads = transacts and !detail.no_reads,
        .writes = transacts and !detail.no_writes,
        .allocates = transacts and !detail.no_allocates,
        .decides = decides,
        .suspends = detail.suspends,
        .diverges = !detail.converges,
        .dictates = !detail.predicts,
    };
}
/// The one encoding of each effect set: nothing given up by a function that has no heap effect,
/// never all three given up (that is `<computes>`), and never `decides` with `suspends`.
pub fn effectsCanonical(transacts: bool, decides: bool, detail: EffectDetail) bool {
    if (detail.reserved != 0 or (decides and detail.suspends)) return false;
    const given_up = detail.no_reads or detail.no_writes or detail.no_allocates;
    if (!transacts) return !given_up;
    return !(detail.no_reads and detail.no_writes and detail.no_allocates);
}
/// The detail of the heap effects `reads`, `writes`, `allocates`, at least one of them set.
pub fn heapDetail(reads: bool, writes: bool, allocates: bool) EffectDetail {
    std.debug.assert(reads or writes or allocates);
    return .{ .no_reads = !reads, .no_writes = !writes, .no_allocates = !allocates };
}
pub const Callable = struct {
    parameters: Type,
    result: Type,
    transacts: bool = false,
    decides: bool = false,
    detail: EffectDetail = .{},

    pub fn effects(self: Callable) EffectSet {
        return effectSet(self.transacts, self.decides, self.detail);
    }
};
pub const CallableValue = struct { value_type: Type, function: u32, captures: Span = .{ .start = 0, .end = 0 } };
pub const Invoke = struct { callable: u32, arguments: Span };
/// A `class` has identity: its values are references to run state, and its fields may name any type, including itself.
pub const Definition = union(enum) {
    record: Record,
    array: Type,
    enumeration: Enumeration,
    tuple: Span,
    option: Type,
    map: Map,
    callable: Callable,
    class: Class,
    rational,
    /// `task(T)` (RFC-0082): the handle of a spawned task whose body yields `T`. It is interned
    /// per `T`, like `option(T)`, and is a definition of its own rather than a class, so that
    /// no class operation (construction, fields, casts, equality, keys) can reach one. An
    /// instance has the cells of a final class with three hidden fields: a header, then the
    /// sequence (`i64`), the state (`i64`: 0 active, 1 completed, 2 canceled) and the result
    /// (`option(T)`, the earlier definition `option` names). Only `spawn` creates one and only
    /// the scheduler writes it.
    task: TaskShape,
    /// A refinement type (RFC-0083), declared by name like an enum.
    refinement: Refinement,
    /// `event(T)` (RFC-0082, P3.2): a rendezvous whose `Signal` carries a `T` to every task
    /// waiting on it. Interned per `T` and not a class, as `task(T)` is. An instance has a
    /// header, then three hidden `i64` cells: how many tasks wait, and the sequences of the
    /// first and the last of them in the order they began to wait (0 when none does). Only
    /// `event_new` creates one and only the scheduler writes it. From P3.9 its kind may be
    /// `sticky_event(T)` or `subscribable_event(T)`, an event with more cells (`EventShape`).
    event: EventShape,
    /// `live(T)` (RFC-0084): a live record, which ties a cell of type `T` to its guard. Interned
    /// per `T` after the guard's type `function<reads>(tuple(), T)`, and not a class. An
    /// instance has a header, then six hidden cells: the guard, its latest stamp (`i64`), its
    /// height (`i64`), its owner (an instance: the record itself for a module cell), the place
    /// of its target (`i64`) and the node that made it (`i64`). Only `cell_live` creates one;
    /// no node yields one and no report lists one.
    live: Type,
    /// `awaitable(T)` and `signalable(T)` (RFC-0082, P3.7): the built-in parametric interfaces
    /// that `task(T)` (awaitable) and `event(T)` (both) implement. Interned per kind and `T`,
    /// and not a class: a value of one is the handle or the event itself, which `upcast` makes
    /// one of from `task(T)` or `event(T)`, and only `Await` (`task_await`) and `Signal`
    /// (`event_signal`) reach what it holds.
    scheduled_interface: ScheduledInterface,
    /// `cancelable` (RFC-0082, P3.9): a subscription to a `subscribable_event(T)`, which only
    /// `event_subscribe` creates. Interned once and not a class. An instance has a header, then
    /// six hidden cells: its state (`i64`: 0 active, 1 cancelled), its callback, its event, the
    /// subscriptions before and after it on the event's list (an instance, or `false` for none)
    /// and its number on that event (`i64`).
    cancelable,
    /// `ref(T)` (RFC-0085, I1): a variable cell, which holds the value of a shared local. Interned
    /// once per `T`, after `T`, and not a class: no class operation reaches one. An instance has
    /// a header, then one cell holding the value (`aggregate_types.ref_value`). Only `ref_new`
    /// creates one, `ref_get` reads it and `ref_set` writes it.
    ref: Type,
    /// `grant(kind)` (RFC-0086, P2.3): the built-in types `reader` and `writer`, the handles of
    /// the run's grants. Interned once per kind and not a class. A value of one is an
    /// enumeration value whose index is the grant's index in the run's list; only `grant`
    /// makes one, and it has no cases a program can name.
    grant: GrantKind,
    /// `weak_map(K, V)` (RFC-0087, P5.1, W1): a map that can only be looked up and set one key at
    /// a time. Interned per `(K, V)`, after both, and not a class. Its values are those of
    /// `map(K, V)`: an aggregate of key and value members in insertion order, which only
    /// `map_lookup` and `map_set` reach. A `map(K, V)` becomes one by `upcast`; nothing converts
    /// one back, and it has no length, no iteration and no equality.
    weak_map: Map,
};
/// RFC-0086, P2.3: the kinds of grant; RFC-0087 appends its own.
pub const GrantKind = effects.GrantKind;
/// RFC-0086, P2.3: `grant`, the handle of the first grant of `kind` named by the string in the
/// operand `name`, as an option: `option{}` when the run has none. `name` is an operand index
/// that template remapping moves.
pub const Grant = struct { kind: GrantKind, name: u32 };
/// RFC-0087, P5.4: the `name` of a `grant` of kind `session`, which has none: it is no operand,
/// and template remapping leaves it.
pub const no_grant_name: u32 = std.math.maxInt(u32);
/// RFC-0087, P5.4 (W4): what a module cell is. A cell of type `weak_map(session, V)` is a
/// session cell, named only by `weak_init`, `weak_get` and `weak_set`; RFC-0087, P5.5: one of type
/// `weak_map(persistent_key, V)` is a persistent cell, loaded where it is declared and saved
/// when it is set; every other is `none`. Each admission derives it from the cell's type and
/// compares it with the input.
pub const Keyed = enum(u8) { none, session, persistent, _ };
/// `weak_get`: the entry of `key` in the keyed cell `cell`, as an option.
pub const WeakGet = struct { cell: u32, key: u32 };
/// `weak_set`: the entry of `key` in the keyed cell `cell` replaced by `value`, or appended.
pub const WeakSet = struct { cell: u32, key: u32, value: u32 };
/// P3.9: an event's kind. A plain `event(T)` is `plain`; a `sticky_event(T)` keeps a latch and
/// the last value signalled; a `subscribable_event(T)` keeps a list of subscriptions.
pub const EventKind = enum(u8) { plain, sticky, subscribable };
pub const EventShape = struct { value: Type, kind: EventKind = .plain };
/// P3.9: `event_subscribe`: the subscribable event, and the callback it adds.
pub const EventSubscribe = struct { event: u32, callback: u32 };
/// RFC-0085, I1: `ref_set`: the variable cell, a `ref(T)`, and the value written, a `T`. Both are
/// operand indexes that template remapping moves (unlike `CellWrite.cell`).
pub const RefSet = struct { ref: u32, value: u32 };
/// P3.7: `awaitable(value)` or `signalable(value)`.
pub const ScheduledInterface = struct { kind: enum(u8) { awaitable, signalable }, value: Type };
pub const TaskShape = struct { result: Type, option: Type };
/// `event_signal`: the event, and the value it carries to the tasks waiting on it.
pub const EventSignal = struct { event: u32, value: u32 };
/// `structured` (RFC-0082, P3.3): `Sync(...)` or `Race(...)` over its arms, callables of no
/// parameters that suspend, in the argument pool like a call's arguments; from P3.4 also
/// `Rush(...)`.
pub const Structured = struct { kind: StructuredKind, arms: Span };
pub const StructuredKind = enum { sync, race, rush };
pub const Lookup = struct { map: u32, key: u32 };
/// Pure element read. The compiler emits it only after a bounds `demand`; each machine still rejects out-of-range indexes.
pub const ArrayIndex = struct { array: u32, index: u32 };
pub const ArraySet = struct { array: u32, index: u32, value: u32 };
pub const MapSet = struct { map: u32, key: u32, value: u32 };
/// Host function call with inline operands; `native` indexes `Program.natives`.
pub const StringPair = struct { lhs: u32, rhs: u32 };
pub const NativeCall = struct { native: u16, count: u16, args: [native.max_parameters]u32 };
/// Float-to-integer conversions are defined only for finite values in [-2^63, 2^63).
/// The compiler guards them with a `demand`; each machine still rejects forged inputs.
pub const FloatRounding = enum { floor, ceil, round_even, truncate };
pub const FloatToInt = struct { mode: FloatRounding, operand: u32 };
pub const integer_float_bound: f64 = 9223372036854775808.0;
pub const Choice = struct { option: u32, fallback: u32 };
pub const FieldAccess = struct { value: u32, index: u32 };
/// `Class{...}`: the field values are operands in call-argument order.
pub const ObjectNew = struct { arguments: Span };
pub const ObjectSet = struct { object: u32, index: u32, value: u32 };
/// Whether the instance's class is `class` or a subclass of it.
pub const InstanceOf = struct { value: u32, class: Type };
/// A method as callers see it: the class that declared it and the function type with the receiver first.
pub const Slot = struct { owner: Type, callable: Type, name: Span };
/// The function that runs when a method slot is called on an instance of exactly `class`.
pub const Dispatch = struct { class: Type, slot: u32, function: u32 };
/// The function that implements `slot` for the receiver's own class, as a callable value.
pub const MethodValue = struct { receiver: u32, slot: u32 };
pub const Aggregate = struct { value_type: Type, elements: Span };
/// `quotient` and `modulo` are Euclidean integer division (RFC-0070): only `binary` admits them.
/// The `bit_*` operators (RFC-0072) are defined on `i64` only: they combine the two's-complement
/// bits of their operands, are total and cannot overflow. A `float_binary` that names one is
/// invalid IR, which each admission rejects.
pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    quotient,
    modulo,
    bit_and,
    bit_or,
    bit_xor,

    pub fn bitwise(self: BinaryOp) bool {
        return self == .bit_and or self == .bit_or or self == .bit_xor;
    }
};
pub const Binary = struct { op: BinaryOp, lhs: u32, rhs: u32 };
/// An exact fraction (RFC-0070). Every value a machine holds is normalised: the denominator is
/// positive and shares no factor with the numerator, so zero is 0/1 and equal fractions are
/// equal word for word. Only `rational` nodes build one, and each machine normalises on its own.
pub const Rational = struct {
    numerator: i64,
    denominator: i64,

    pub fn normalised(self: Rational) bool {
        return self.denominator > 0 and std.math.gcd(@abs(self.numerator), @abs(self.denominator)) == 1;
    }
};
/// `make` divides two integers; `add`, `subtract` and `multiply` take two rationals; `negate`,
/// `floor`, `ceil` and `to_float` take one, named by both operands so that each node has one encoding.
pub const RationalOp = enum {
    make,
    add,
    subtract,
    multiply,
    negate,
    floor,
    ceil,
    to_float,

    pub fn unary(self: RationalOp) bool {
        return @backingInt(self) >= @backingInt(RationalOp.negate);
    }
};
pub const RationalNode = struct { op: RationalOp, lhs: u32, rhs: u32 };
pub const CompareOp = enum { equal, unequal, less, less_equal, greater, greater_equal };
pub const Comparison = struct { op: CompareOp, lhs: u32, rhs: u32 };
pub const LogicOp = enum { both, either };
pub const LogicBinary = struct { op: LogicOp, lhs: u32, rhs: u32 };
pub const Branch = struct { condition: u32, alternative: u32, end: u32 };
pub const Merge = struct { begin: u32, left: u32, right: u32 };
pub const CellWrite = struct { cell: u32, value: u32 };
pub const Call = struct { function: u32, arguments: Span };
pub const Iteration = struct { function: u32, count: u32, initial: u32 };
pub const CallableIteration = struct { callable: u32, count: u32, initial: u32 };
pub const StateLoop = struct { callable: u32, initial: u32 };
pub const ResolvedCall = struct { function: u32, arguments: Span, captures: Span = .{ .start = 0, .end = 0 } };
pub const ResolvedIteration = struct { function: u32, count: u32, initial: u32, captures: Span = .{ .start = 0, .end = 0 } };
pub const LoopCall = struct { function: u32, initial: u32, captures: Span = .{ .start = 0, .end = 0 } };
/// Encoding only. Each admission/execution/replay machine checks its own operands.
pub const Invocation = union(enum) {
    call: ResolvedCall,
    iterate: ResolvedIteration,
    loop: LoopCall,
    pub fn captures(self: Invocation) Span {
        return switch (self) {
            .call => |c| c.captures,
            .iterate => |i| i.captures,
            .loop => |l| l.captures,
        };
    }
    pub fn target(self: Invocation) u32 {
        return switch (self) {
            .call => |c| c.function,
            .iterate => |i| i.function,
            .loop => |l| l.function,
        };
    }
};
/// `live_only` (RFC-0084): a cell declared `live Y:T = G`, which only its guard writes.
pub const SourceCell = struct { name: Span, value_type: Type, initial: u32, is_public: bool, live_only: bool = false, keyed: Keyed = .none };
/// `cell_live` (RFC-0084): attaches the closure `guard` to `cell`; `initialize` when it is the
/// declaration of the cell, at the root.
pub const CellLive = struct { cell: u32, guard: u32, initialize: bool };
/// `object_live` (RFC-0084, P4.2): attaches the closure `guard` to field `field` of the instance
/// `object`, a `var` field or a live-only one.
pub const ObjectLive = struct { object: u32, field: u32, guard: u32 };
/// `reaction` (RFC-0084, P4.4): `Upon(G, Body)` or `When(G, Body)`. `guard` is a closure of no
/// parameters and the effect `<reads>` yielding `option(T)`, whose presence is the guard's
/// success; `body` a closure of no parameters that cannot fail or suspend. The node yields the
/// reaction's `task(T)` handle: of the body's result for `upon`, `task(void)` for `when`.
pub const Reaction = struct { kind: ReactionKind, guard: u32, body: u32 };
pub const ReactionKind = enum { upon, when };
pub const FailureTrace = struct { instruction: u32, span: Span, code: Diagnostic.Code, reason: ?[]const u8 = null, function: ?u32 = null, pc: u32 = 0 };
/// An `exit` step is the `exit` node's own: its value is the result the frame returns.
/// A `root` step is the result of an effect native called outside every function (RFC-0079):
/// `pc` is the root node and `function` is zero. Root nodes otherwise leave no step, because a
/// report reads their values from the registers; an effect is the one thing a replay of a run
/// that stored nothing has to read in step with the second run, and a step is what keeps the
/// two in step.
///
/// The kinds from `start` on are the scheduler's (RFC-0082, "Steps"): `start` (a task's entry
/// frame is pushed; the value is its sequence), `suspend` (a task waits at the site `pc` of
/// `function`; the value says until when: the wake tick, or `false` for never), `resume` (a
/// task is restored and its site completes with the value), `resume_canceled`, `settle` (a
/// task's entry frame ends; the value is its result), `tick` (the clock moves to the value),
/// `cancel_exit` and `call_canceled`. The three about cancellation have no source before P3.3.
///
/// RFC-0084: `live_eval` comes before the frame of a guard a machine evaluates for a live
/// record (`function` is the guard's, `pc` 0, the value the record), and `live_settle` after it
/// (`pc` the guard's body length, the value whether the target was written).
///
/// RFC-0082, P3.6: `arm_exit` is an `arm_exit` node's own, as `exit` is an `exit` node's; its
/// value is the pending exit. `resume_exited` is the step of a `structured` site that yields the
/// pending exit of one of its arms (at once, or when restored); its value is that exit's.
///
/// RFC-0084, P4.4: `observe` comes before the frame of a reaction's guard (the guard's
/// function, `pc` 0, the task's sequence), `deliver` at each delivery (`function` and `pc` 0,
/// the sequence), and `fire` before the frame of a reaction's body (the body's function, `pc`
/// 0, the sequence).
///
/// RFC-0084, P4.6: an `await_guard` site leaves `observe` before its guard's frame too, with the
/// sequence of the task at the site; then the site's `value` when the guard holds, or `suspend`
/// with `false` when the task waits on it; restored there, `resume` with `true` at the site,
/// which evaluates its guard again.
pub const CallStep = struct { function: u32, pc: u32, value: Value, kind: enum { value, failure, propagate, root_failure, exit, root, start, @"suspend", @"resume", resume_canceled, settle, tick, cancel_exit, call_canceled, live_eval, live_settle, arm_exit, resume_exited, observe, deliver, fire } = .value };
/// Defining cause is copied across continuations; its Value borrows only the
/// immutable program pool (string) or is a false logic scalar.
pub const CallFailure = struct { function: u32, pc: u32, value: Value };
/// How a run keeps its call witness. The host chooses it in `ControlStorage.trace` before a run.
pub const TraceMode = enum {
    /// Every step is stored; the run stops with `call_trace_limit` when the storage is full.
    full,
    /// No step outlives its window: the run keeps the count and a hash of the steps it would
    /// have stored, so its length is not bounded by witness storage.
    digest,
    /// Nothing is recorded, for a host that wants only the result.
    off,
};
/// The count and a 64-bit hash of a step stream: function, pc, kind and value of every step in
/// order. Two machines, or a machine and a replay, that fold the same stream agree on all of it.
/// The hash detects divergence; it is not a defence against a chosen collision.
pub const Witness = struct {
    count: u64 = 0,
    digest: u64 = seed,
    /// Steps of kind `failure`: a failure report needs to know whether a frame failed.
    failures: u64 = 0,

    const seed: u64 = 0x243f6a8885a308d3;
    const head_key: u64 = 0x9e3779b97f4a7c15;
    const value_key: u64 = 0xd6e8feb86659fd93;

    fn mix(a: u64, b: u64) u64 {
        const product = @as(u128, a) * @as(u128, b);
        return @as(u64, @truncate(product)) ^ @as(u64, @truncate(product >> 64));
    }

    /// Appends `steps` to the stream. `strings` is the start of the program's string pool: a
    /// string counts as its place and length there, which both machines share, so a step costs
    /// the same however long its string is.
    pub fn fold(self: *Witness, steps: []const CallStep, strings: [*]const u8) void {
        var digest = self.digest;
        var failures: u64 = 0;
        for (steps) |step| {
            var first: u64 = 0;
            var second: u64 = 0;
            switch (step.value) {
                .integer => |value| first = @bitCast(value),
                .boolean => |value| first = @intFromBool(value),
                .floating => |value| first = @bitCast(value),
                .string => |value| {
                    // An empty string has no bytes, so where it points is not part of its value.
                    if (value.len != 0) first = @intFromPtr(value.ptr) -% @intFromPtr(strings);
                    second = value.len;
                },
                .aggregate => |value| {
                    first = @backingInt(value.value_type);
                    second = @as(u64, value.elements.start) | @as(u64, value.elements.end) << 32;
                },
                .enumeration => |value| {
                    first = @backingInt(value.value_type);
                    second = value.index;
                },
                .callable => |value| {
                    first = @as(u64, @backingInt(value.value_type)) | @as(u64, value.function) << 32;
                    second = @as(u64, value.captures.start) | @as(u64, value.captures.end) << 32;
                },
                .object => |value| {
                    first = @backingInt(value.value_type);
                    second = value.id;
                },
                .rational => |value| {
                    first = @bitCast(value.numerator);
                    second = @bitCast(value.denominator);
                },
            }
            const shape = @as(u64, @backingInt(step.kind)) | @as(u64, @backingInt(std.meta.activeTag(step.value))) << 8;
            digest = mix(digest ^ (@as(u64, step.function) | @as(u64, step.pc) << 32), head_key ^ shape);
            digest = mix(digest ^ first, value_key ^ second);
            failures += @intFromBool(step.kind == .failure);
        }
        self.digest = digest;
        self.failures += failures;
        self.count += steps.len;
    }
    pub fn of(steps: []const CallStep, strings: [*]const u8) Witness {
        var witness: Witness = .{};
        witness.fold(steps, strings);
        return witness;
    }
    pub fn eql(self: Witness, other: Witness) bool {
        return self.count == other.count and self.digest == other.digest and self.failures == other.failures;
    }
};
/// What a run's scheduler did (RFC-0082, "The run's record"). Both machines produce it, and a
/// report replay works it out again from the steps and refuses a record that differs.
pub const Scheduler = struct {
    /// Ticks per second of the virtual clock: the host's choice, like the seed.
    tick_rate: u64 = default_tick_rate,
    /// The clock when the run ended.
    tick: u64 = 0,
    /// Tasks that started, and of those the ones that completed and that were cancelled.
    created: u64 = 0,
    completed: u64 = 0,
    canceled: u64 = 0,
    /// Hand-off starts, saves and restores.
    switches: u64 = 0,
    /// The tasks still waiting when the run became quiescent, by sequence. They are abandoned.
    waiting: []const Waiting = &.{},

    pub const default_tick_rate: u64 = 60;
    pub const max_tick_rate: u64 = 1_000_000;
    /// No deadline is ever at or above this tick, so the clock stays below it (RFC-0082, "Time").
    pub const clock_limit: u64 = 1 << 62;
    pub const Waiting = struct { task: u64, kind: TaskKind, wait: WaitKind, span: Span };
    pub const TaskKind = enum { spawn, branch, arm, upon, when };
    pub const WaitKind = enum { sleep, event, task, record, frame_end, guard };

    pub fn validRate(rate: u64) bool {
        return rate >= 1 and rate <= max_tick_rate;
    }
};
/// What a run's live variables did (RFC-0084, "The run's record"). Every field counts events,
/// never what is reachable at the end, so the record is the same in every trace mode. Both
/// machines produce it, and a report replay works it out again from the steps.
pub const Live = struct {
    /// Records created, by every `cell_live` and `object_live` that completed (with those a
    /// rollback forgot).
    records: u64 = 0,
    /// Propagations run: one per program write and per establishing write of a live program.
    propagations: u64 = 0,
    /// Guard evaluations, of every kind, and dependency entries recorded.
    evaluations: u64 = 0,
    entries: u64 = 0,
    /// Deliveries and firings of reactions (P4.4).
    deliveries: u64 = 0,
    firings: u64 = 0,
};
/// Receives each window of steps of a `digest` run, in order, before the run reuses the
/// storage. The steps borrow the run's storage for the length of the call only.
///
/// `members` is the run's member pool as it is during the call. It holds every span the steps
/// name, because a run sends the window it holds before it reclaims members (see
/// `ControlStorage.reclaim_floor`); afterwards the same positions may hold other values.
/// `strings` is how many bytes of the program's string pool are in use at that moment: the
/// run's steps name strings up to there, and a run that reclaims moves them afterwards.
pub const TraceSink = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, steps: []const CallStep, members: []const Value, strings: usize) void,
    /// Asked after each window: false when the sink wants no more of them (its report has been
    /// refused), and the run then stops with `call_trace_limit` at the next step instead of
    /// running to its end. Null: always more.
    more: ?*const fn (context: *anyopaque) bool = null,
};
/// Runs a program again and sends its whole step stream to `sink`; false when that run did not
/// complete. A report uses one to replay a run whose steps were not stored.
pub const TraceProducer = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, sink: TraceSink) bool,
    /// The input log of the second run (RFC-0086): the replay gives it the reported run's
    /// record as its prefix and no source, so that it never asks the world. A producer that
    /// wraps another passes the inner one's on.
    inputs: ?*effects.Inputs = null,
};
pub const ControlStorage = struct {
    activity: [limits.nodes]bool = undefined,
    traces: [limits.failure_traces]FailureTrace = undefined,
    trace_count: usize = 0,
    failure_count: u32 = 0,
    calls: [limits.call_steps]CallStep = undefined,
    call_count: usize = 0,
    /// The host's choice for the runs that use this storage; a run does not change it.
    trace: TraceMode = .full,
    /// Steps a `digest` or `off` run keeps before it folds them. Small, so that the window
    /// stays in cache and memory does not grow with the run.
    trace_window: u32 = default_trace_window,
    trace_sink: ?TraceSink = null,
    /// The sink asked for no more windows: the window shrinks to one step and `makeRoom` refuses,
    /// so the run stops within a step or two (a pair of folds at the end of a call) of the answer.
    stopped: bool = false,
    /// Room in `calls` for the current run: all of it for `full`, one window otherwise.
    call_limit: usize = limits.call_steps,
    /// Steps already folded by the current `digest` run.
    witness: Witness = .{},
    /// Start of the running program's string pool, which the digest measures strings from.
    strings: [*]const u8 = "",
    /// The host's choice of how much unreclaimed room a `digest` or `off` run may use beyond the
    /// members that survived its last reclamation; `reclaim_never` turns reclamation off. A
    /// `full` run never reclaims: its stored steps name every span it built.
    ///
    /// Members are reclaimed where a traced call or loop visit ends. Everything the frame built
    /// lies above the pool mark taken when it was pushed, and all that can still reach it is
    /// the value the frame hands on (the next loop state or the result) and the cells. What
    /// those reach above the mark slides down to the mark in order, every span that names it
    /// is renumbered, and the rest is free again. Both machines and the report replay follow
    /// this one rule, each in its own code, so they hold the same layout afterwards. The work
    /// is not charged as fuel; `reclaimDue` spaces it out so that it stays proportional to the
    /// members the run was charged for.
    ///
    /// The same reclamation frees the run strings and the class instances the frame built:
    /// each frame also marks the string pool and the cells, an instance nothing reaches is no
    /// root, and what stays slides down to its mark in each store. See `Usage`, `reclaimNow`
    /// and "Member reclamation" in `docs/pure-core.md`.
    reclaim_floor: u32 = default_reclaim_floor,
    /// The pool size at which the current run next reclaims at the end of a frame or visit.
    reclaim_at: u64 = reclaim_idle,
    /// Reclamations of the current run and the members they freed.
    reclaims: u64 = 0,
    reclaimed_members: u64 = 0,
    /// The same reclamation frees run strings and class instances (see `Usage`). These are the
    /// sizes of the string pool and of the cells at which the run next reclaims, and what the
    /// reclamations freed of each.
    string_reclaim_at: u64 = reclaim_idle,
    object_reclaim_at: u64 = reclaim_idle,
    reclaimed_bytes: u64 = 0,
    reclaimed_cells: u64 = 0,
    /// How many frames were on the stack at the last reclamation, and the sizes of the three
    /// stores from which that reclamation has been paid for (see `reclaimNow`).
    reclaim_depth: u32 = 0,
    reclaim_paid: Usage = .{ .members = reclaim_idle, .strings = reclaim_idle, .cells = reclaim_idle },
    /// What the end of a task's frame at depth 1 after a switch waits for (`reclaimReturn`):
    /// `reclaim_paid`, or half the room left in the store, whichever comes first, so that a
    /// store nearly full of live data is reclaimed there as it was before RFC-0085 I6-D3.
    reclaim_across: Usage = .{ .members = reclaim_idle, .strings = reclaim_idle, .cells = reclaim_idle },
    /// The scheduler's switch count at the last reclamation: a frame that saw a switch waits
    /// for `reclaim_across` only if another has happened since (`reclaimReturn`).
    reclaim_switches: u64 = 0,
    /// The program's own cells in the current run: its instances may take `object_cells` more.
    program_cells: u64 = 0,
    /// Where the running machine keeps the size of its string pool, for a sink.
    string_used: ?*const usize = null,
    /// What the run does to the world and draws from it (RFC-0079). Each machine has its own:
    /// the host gives both the same seed, and at most one of them a sink.
    effects: effects.Log = .{},
    /// The tick rate of the runs that use this storage (RFC-0082), from 1 to
    /// `Scheduler.max_tick_rate`: the host's choice, recorded in the run's scheduler record.
    tick_rate: u64 = Scheduler.default_tick_rate,
    /// RFC-0082, P3.5: what the three stores held when the root had run to its end. A frame
    /// end that saw another task run reclaims above these sizes as well as above its marks, so
    /// that nothing the root's registers name ever moves (`acrossMarks`).
    root_end: Usage = .{},
    root_ended: bool = false,

    pub const default_trace_window: u32 = @min(1024, limits.call_steps);
    /// An eighth of the pool: a run with little live data reclaims a few times per pool-full.
    pub const default_reclaim_floor: u32 = limits.aggregate_elements / 8;
    pub const reclaim_never: u32 = std.math.maxInt(u32);
    const reclaim_idle: u64 = std.math.maxInt(u64);
    /// What a run holds of the three stores a reclamation compacts: members of the pool, bytes
    /// of the string pool (literals included) and cells (the program's own included).
    pub const Usage = struct { members: u64 = 0, strings: u64 = 0, cells: u64 = 0 };

    pub fn reset(self: *ControlStorage, count: usize) void {
        std.debug.assert(count <= self.activity.len);
        @memset(self.activity[0..count], false);
        self.trace_count = 0;
        self.failure_count = 0;
        self.call_count = 0;
        self.stopped = false;
        self.witness = .{};
        self.call_limit = if (self.trace == .full) self.calls.len else @max(1, @min(self.trace_window, self.calls.len));
        self.reclaims = 0;
        self.reclaimed_members = 0;
        self.reclaim_at = if (self.trace == .full) reclaim_idle else reclaimDue(self.reclaim_floor, 0, 0);
        self.reclaimed_bytes = 0;
        self.reclaimed_cells = 0;
        self.string_reclaim_at = if (self.trace == .full) reclaim_idle else stringDue(self.reclaim_floor, 0, 0);
        self.program_cells = 0;
        self.object_reclaim_at = if (self.trace == .full) reclaim_idle else objectDue(self.reclaim_floor, 0, 0, 0);
        self.string_used = null;
        self.reclaim_depth = 0;
        self.reclaim_paid = .{ .members = reclaim_idle, .strings = reclaim_idle, .cells = reclaim_idle };
        self.reclaim_across = .{ .members = reclaim_idle, .strings = reclaim_idle, .cells = reclaim_idle };
        self.reclaim_switches = 0;
        self.root_end = .{};
        self.root_ended = false;
    }
    /// RFC-0082, P3.5: the root has run to its end, holding `now` of the three stores.
    pub fn rootEnded(self: *ControlStorage, now: Usage) void {
        self.root_end = now;
        self.root_ended = true;
    }
    /// The marks a frame end that saw another task run reclaims above: its own, or what the
    /// stores held when the root ended where that is more. Before the root has ended, a frame
    /// on the stack was pushed after everything the root holds; after it, the root's registers
    /// name only what lies below `root_end`, and they are never rewritten.
    pub fn acrossMarks(self: *const ControlStorage, marks: Usage) Usage {
        if (!self.root_ended) return marks;
        return .{ .members = @max(marks.members, self.root_end.members), .strings = @max(marks.strings, self.root_end.strings), .cells = @max(marks.cells, self.root_end.cells) };
    }
    /// The floor is stated in members; each other store gets the same share of its capacity.
    pub fn storeFloor(floor: u32, capacity: u64) u64 {
        return @as(u64, floor) * capacity / limits.aggregate_elements;
    }
    /// `reclaimDue` for the string pool, in bytes. A string operation is charged one unit of
    /// fuel per eight bytes, so the wait for the work of the last reclamation is that work in
    /// bytes, not an eighth of it.
    pub fn stringDue(floor: u32, kept: u64, examined: u64) u64 {
        if (floor == reclaim_never) return reclaim_idle;
        std.debug.assert(kept <= limits.string_bytes);
        const room = @min(storeFloor(floor, limits.string_bytes), (limits.string_bytes - kept) / 2);
        return kept + @max(room, examined);
    }
    /// `reclaimDue` for the cells, of which `own` are the program's and the rest, at most
    /// `object_cells`, its instances'. Creating an instance is charged one unit per cell.
    pub fn objectDue(floor: u32, own: u64, kept: u64, examined: u64) u64 {
        if (floor == reclaim_never) return reclaim_idle;
        std.debug.assert(kept >= own and kept - own <= limits.object_cells);
        const room = @min(storeFloor(floor, limits.object_cells), (limits.object_cells - (kept - own)) / 2);
        return kept + @max(room, examined / 8);
    }
    /// Says how many cells the program of the run that `reset` prepared has of its own.
    pub fn programCells(self: *ControlStorage, own: u64) void {
        self.program_cells = own;
        if (self.trace != .full) self.object_reclaim_at = objectDue(self.reclaim_floor, own, own, 0);
    }
    /// Whether a frame or visit that ends now reclaims: a store has reached the size at which
    /// the run reclaims next, and the frame built some of what that store holds. `now` is what
    /// the run holds and `mark` what it held when the frame was pushed.
    ///
    /// `depth` is the number of frames on the stack, the ending one included, and `returning`
    /// says that the frame returns and is not a loop going on to its next visit. Two more
    /// frames reclaim besides the ones the sizes ask for:
    ///
    /// A frame below the one that reclaimed last. That reclamation could free nothing below
    /// its own mark, and counted whatever lay there as in use when it scheduled the next. A
    /// frame nearer the root can free it, so it does not wait for the floor: it reclaims as
    /// soon as the last reclamation is paid for, that is once a store has grown by the wait
    /// `reclaimed` works out. Without this a loop whose every visit runs a shorter loop would
    /// leave each inner loop's remains below the next one's mark until the pool was full.
    ///
    /// The frame a call from the root pushed, as it returns, in a run that has reclaimed
    /// before. What the call leaves behind is then what it handed on and what the cells hold,
    /// and a report lists no instance that the visits after the last reclamation happened to
    /// leave. It does so only when what lies above its marks, all of which the call was
    /// charged for, is at least an eighth of what the reclamation would examine (`records` is
    /// the number of undo records): a short call in a run with many cells does not read them
    /// all to free a little.
    ///
    /// A frame at depth 1 that saw a switch since its push (`reclaimReturn` with `across`) is
    /// the entry frame of a task the scheduler resumed. Other tasks built above its marks too,
    /// and much of it is live (the closures and frames of the tasks still waiting), so "an
    /// eighth of what would be examined" can hold at every such return while each reclamation
    /// frees almost nothing: a fan-out of 60,000 tasks reclaimed 7,826 times as they completed,
    /// each time examining every task, in 80 seconds (RFC-0085, I6-D3). Such a frame also waits
    /// for the last reclamation to be paid for, as a frame below it does: a store has grown by
    /// the wait `reclaimed` works out. That holds only if another switch has happened since the
    /// last reclamation: a task that reclaimed in its own loop after it resumed has paid for it,
    /// and what it built since is its own. So the work stays proportional to what the run
    /// appends, and what such tasks build after they resume is still reclaimed at their ends.
    pub inline fn reclaimNow(self: *const ControlStorage, now: Usage, mark: Usage, depth: u32, returning: bool, records: u64) bool {
        return self.reclaimReturn(now, mark, depth, returning, 0, 0, records);
    }
    /// `reclaimNow` for the end of a frame pushed when the scheduler had switched `entered`
    /// times and has now switched `switches` times. The frame waits for `reclaim_across` only
    /// if a switch has happened since its push and since the last reclamation: a task that
    /// reclaimed inside its own loop is not held back at its end by the switch that resumed
    /// it, since what it built since is its own. A reclamation change may make a run faster,
    /// never make a run that succeeded fail (RFC-0085, I6-D3).
    pub inline fn reclaimReturn(self: *const ControlStorage, now: Usage, mark: Usage, depth: u32, returning: bool, entered: u64, switches: u64, records: u64) bool {
        const across = entered != switches and switches != self.reclaim_switches;
        if ((now.members >= self.reclaim_at and now.members > mark.members) or
            (now.strings >= self.string_reclaim_at and now.strings > mark.strings) or
            (now.cells >= self.object_reclaim_at and now.cells > mark.cells)) return true;
        if (depth >= self.reclaim_depth and !(returning and depth == 1)) return false;
        return self.reclaimLate(now, mark, depth, returning, across, records);
    }
    fn reclaimLate(self: *const ControlStorage, now: Usage, mark: Usage, depth: u32, returning: bool, across: bool, records: u64) bool {
        if (self.reclaims == 0) return false;
        if (returning and depth == 1 and (now.members > mark.members or now.strings > mark.strings or now.cells > mark.cells)) {
            const built = (now.members - mark.members) + (now.cells - mark.cells) + (now.strings - mark.strings) / 8;
            if (built * 8 >= reclaimExamined(now, mark, records) and (!across or reached(now, mark, self.reclaim_across))) return true;
        }
        return depth < self.reclaim_depth and reached(now, mark, self.reclaim_paid);
    }
    /// Whether a store the frame built in has reached its size in `at`.
    fn reached(now: Usage, mark: Usage, at: Usage) bool {
        return (now.members >= at.members and now.members > mark.members) or
            (now.strings >= at.strings and now.strings > mark.strings) or
            (now.cells >= at.cells and now.cells > mark.cells);
    }
    /// What a reclamation examined, the measure its wait is taken from: the members, string
    /// bytes and cells above the frame's marks, every older cell (each is a root) and every
    /// undo record (each may name a cell that moved). Bytes count an eighth, as they are charged.
    pub fn reclaimExamined(now: Usage, mark: Usage, records: u64) u64 {
        return (now.members - mark.members) + now.cells + (now.strings - mark.strings) / 8 + records;
    }
    /// The pool size at which to reclaim next, when `kept` members survived a reclamation that
    /// examined `examined` members and cells. A run waits for the floor, or for half the room
    /// that is left when that is less, so that a pool that is nearly full of live members is
    /// still reclaimed; and it waits for an eighth of what the last reclamation examined, so
    /// that reclaiming costs at most eight visits per member the run appends in between. Each
    /// appended member is charged as fuel, which bounds the work that fuel does not count.
    pub fn reclaimDue(floor: u32, kept: u64, examined: u64) u64 {
        if (floor == reclaim_never) return reclaim_idle;
        std.debug.assert(kept <= limits.aggregate_elements);
        const room = @min(@as(u64, floor), (limits.aggregate_elements - kept) / 2);
        return kept + @max(room, examined / 8);
    }
    /// Records a reclamation that examined `examined` (see `reclaimExamined`) and left `kept`
    /// of what the run held `before`, with `depth` frames on the stack, and schedules the next
    /// one for each store. Whatever frame makes the next one, it is not due before a store has
    /// grown by the wait for this one's work, which is what bounds the work fuel does not count.
    pub fn reclaimed(self: *ControlStorage, before: Usage, kept: Usage, examined: u64, depth: u32, switches: u64) void {
        std.debug.assert(self.trace != .full and kept.members <= before.members and kept.strings <= before.strings and kept.cells <= before.cells);
        self.reclaims += 1;
        self.reclaimed_members += before.members - kept.members;
        self.reclaimed_bytes += before.strings - kept.strings;
        self.reclaimed_cells += before.cells - kept.cells;
        self.reclaim_at = reclaimDue(self.reclaim_floor, kept.members, examined);
        self.string_reclaim_at = stringDue(self.reclaim_floor, kept.strings, examined);
        self.object_reclaim_at = objectDue(self.reclaim_floor, @min(self.program_cells, kept.cells), kept.cells, examined);
        self.reclaim_depth = depth;
        self.reclaim_switches = switches;
        self.reclaim_paid = if (self.reclaim_floor == reclaim_never) .{ .members = reclaim_idle, .strings = reclaim_idle, .cells = reclaim_idle } else .{ .members = kept.members + examined / 8, .strings = kept.strings + examined, .cells = kept.cells + examined / 8 };
        const own = @min(self.program_cells, kept.cells);
        self.reclaim_across = if (self.reclaim_floor == reclaim_never) self.reclaim_paid else .{
            .members = @min(self.reclaim_paid.members, kept.members + (limits.aggregate_elements -| kept.members) / 2),
            .strings = @min(self.reclaim_paid.strings, kept.strings + (limits.string_bytes -| kept.strings) / 2),
            .cells = @min(self.reclaim_paid.cells, kept.cells + (limits.object_cells -| (kept.cells - own)) / 2),
        };
    }
    /// Called when `calls` has no room for the next step. A full witness has none to give, and
    /// the run stops; the other modes fold the window and start it again.
    pub noinline fn makeRoom(self: *ControlStorage, members: []const Value) bool {
        @branchHint(.cold);
        std.debug.assert(self.call_count == self.call_limit);
        if (self.trace == .full or self.stopped) return false;
        self.foldCalls(members);
        return !self.stopped;
    }
    /// Moves the steps held in `calls` into the witness. A run does this when the window is
    /// full, before it reclaims members, and once more when it completes. `members` is the
    /// pool in use, for a sink that checks the steps against it.
    pub fn foldCalls(self: *ControlStorage, members: []const Value) void {
        std.debug.assert(self.trace != .full and self.call_count <= self.call_limit);
        const steps = self.calls[0..self.call_count];
        if (self.trace == .digest) {
            self.witness.fold(steps, self.strings);
            if (self.trace_sink) |sink| {
                sink.write(sink.context, steps, members, if (self.string_used) |used| used.* else 0);
                if (sink.more) |more| if (!more(sink.context)) {
                    self.stopped = true;
                    // The window is empty below: one step fills it, and the next asks for room.
                    self.call_limit = 1;
                };
            }
        }
        self.call_count = 0;
    }
    pub fn record(self: *ControlStorage, trace: FailureTrace) void {
        self.failure_count += 1; // At most one defining failure per bounded executed call-step/root opcode.
        if (self.trace_count < self.traces.len) {
            self.traces[self.trace_count] = trace;
            self.trace_count += 1;
        }
    }
};
pub const Node = struct {
    span: Span,
    value_type: Type,
    kind: union(enum) {
        integer: i64,
        boolean: bool,
        string: Span,
        negate: u32,
        binary: Binary,
        floating: f64,
        float_negate: u32,
        int_to_float: u32,
        float_to_int: FloatToInt,
        float_binary: Binary,
        /// Exact fractions (RFC-0070). The compiler guards `make` with a nonzero `demand`; each
        /// machine still rejects a zero divisor and a result outside checked `i64` terms.
        rational: RationalNode,
        aggregate: Span,
        field: FieldAccess,
        array_length: u32,
        enumeration: u32,
        tuple_element: FieldAccess,
        option_present: u32,
        option_value: u32,
        option_or: Choice,
        map_lookup: Lookup,
        array_get: ArrayIndex,
        /// The key and the value of a map's entry at a position in insertion order; out of range is fatal.
        map_key: ArrayIndex,
        map_value: ArrayIndex,
        native_call: NativeCall,
        string_concat: StringPair,
        array_concat: StringPair,
        array_set: ArraySet,
        map_set: MapSet,
        /// A copy of a map without one entry, the others in their order. `key` is not a key here
        /// but the option a `map_lookup` in that map returned: it views the value it found, so
        /// the removal does not search again. The compiler emits it only after a presence
        /// `demand`; each machine still rejects an option that is empty or views anything else.
        map_remove: Lookup,
        string_length: u32,
        to_string: u32,
        compare: Comparison,
        logic_not: u32,
        logic_binary: LogicBinary,
        if_begin: Branch,
        attempt_begin: Branch,
        otherwise: u32,
        merge: Merge,
        demand: u32,
        fail: u32,
        /// Leaves the function with the operand as its result, keeping every effect: the regions
        /// the frame still has open are committed, not rolled back. Function bodies only.
        exit: u32,
        /// Ends the run with `runtime_error`. The operand is the message, a string.
        err: u32,
        cell_init: CellWrite,
        cell_read: u32,
        cell_write: CellWrite,
        object_new: ObjectNew,
        object_get: FieldAccess,
        object_set: ObjectSet,
        upcast: u32,
        downcast: u32,
        instance_of: InstanceOf,
        method_value: MethodValue,
        local_set: u32,
        call: Call,
        iterate: Iteration,
        recur: Span,
        function_value: u32,
        self_value,
        invoke: Invoke,
        bind: Invoke,
        iterate_value: CallableIteration,
        loop: StateLoop,
        /// A `char` or `char32` constant, by the node's type: the code unit or the code point.
        character: u32,
        text: Text,
        /// Structured concurrency (RFC-0082). `spawn` starts a task that runs its operand, a
        /// callable of no parameters whose type says `suspends`, and yields its `task(T)` handle;
        /// inside a rollback region the start waits for the outermost region to commit. `sleep`
        /// waits on the virtual clock for its operand, a `float` of seconds, and yields the unit
        /// value. Every site (a `sleep`, or a call of a function that suspends) is followed by its
        /// check: `canceling`, an `if_begin` on it whose first arm is the landing and ends with
        /// `cancel_exit`, an empty `otherwise` and a `merge` of the `cancel_exit` and the site.
        spawn: u32,
        sleep: u32,
        canceling,
        cancel_exit,
        /// RFC-0083: the operand seen as another type that has its representation. Either the
        /// node's type is a refinement whose base is the operand's type, and each machine checks
        /// the bounds (the compiler guards the operation with a `demand`; a value outside them is
        /// invalid bytecode), or the operand's type is a refinement and the node's is its base.
        refine: u32,
        /// RFC-0082, P3.2. `task_await` is a site that yields the result of its operand's task,
        /// at once if it has completed. `event_new` builds an `event(T)`. `event_signal` wakes
        /// every task waiting on its event with its value, and inside a rollback region waits
        /// for the outermost region to commit. `event_await` is a site that waits for the next
        /// `Signal` of its operand and yields its value.
        task_await: u32,
        event_new,
        event_signal: EventSignal,
        event_await: u32,
        /// RFC-0082, P3.3. A site that starts its arms, each a task handed off to in order, and
        /// yields when they are settled: for `sync` the tuple of their results in arm order,
        /// for `race` the result of the first to complete, the others cancelled.
        structured: Structured,
        /// RFC-0082, P3.4. A site that starts a task running its operand, a callable of no
        /// parameters that suspends and yields the unit value, by hand-off; the task is owned by
        /// the frame that ran the node, whose end waits until it is settled. Yields the unit
        /// value. (`structured` of kind `rush` hands its losers to that frame the same way.)
        branch: u32,
        /// RFC-0084, P4.1. Evaluates its guard, a closure of no parameters and the effect
        /// `<reads>`, with tracking, attaches a new live record to the cell and writes the value;
        /// later writes of what the guard read update the cell.
        cell_live: CellLive,
        /// RFC-0084, P4.2. The same for a field of an instance: `set live E.F = G`, and the
        /// attachment of a live field in its class's block-clause function.
        object_live: ObjectLive,
        /// RFC-0082, P3.6. In the entry function of an arm that may exit (`RuntimeFunction.exits`):
        /// like `exit`, it commits the frame's open regions and ends the frame with its operand,
        /// and the arm's expression is abandoned with the operand as its pending exit. Its type is
        /// the position's, as an `exit`'s; it never yields.
        arm_exit: u32,
        /// RFC-0082, P3.6. The second test of the check of a `structured` site whose arms may
        /// exit, right after the check's empty `otherwise`: whether the site yielded the pending
        /// exit of an arm. `arm_exit_value`, first in the arm it opens, is that exit's value.
        arm_exited,
        arm_exit_value,
        /// RFC-0084, P4.4. `Upon` or `When`: takes a task slot and yields the handle. Outside
        /// every region the guard is evaluated at once with tracking and, if it succeeds, the
        /// body fires on top of the active stack; inside one the start waits for the commit.
        reaction: Reaction,
        /// RFC-0082, P3.7. A site that makes a cancellation request to the task of its operand, a
        /// `task(T)` handle, and goes on with the unit value: `T.Cancel()`.
        task_cancel: u32,
        /// RFC-0082, P3.7. The virtual clock in seconds, `now / R`, as a `float`:
        /// `GetSimulationElapsedTime()`. It reads the clock and needs `<reads>`.
        elapsed_time,
        /// RFC-0084, P4.5. `Batch{...}`: calls the closure, of no parameters, that cannot fail or
        /// suspend, with the run's batch count raised by one, and yields what it returns. While
        /// the count is above 0 nothing is delivered; the return that brings it to 0 is a
        /// delivery point.
        batch: u32,
        /// RFC-0084, P4.6. `Await(G)`: a primitive site whose operand is the guard, a closure of
        /// no parameters and the effect `<reads>` yielding `option(T)`. The guard is evaluated
        /// with tracking; when it succeeds the site yields `T`, otherwise the task waits on its
        /// guard until a write notifies it, and then evaluates it again at the same site (N7).
        await_guard: u32,
        /// RFC-0082, P3.9. `E.Subscribe(F)` of a `subscribable_event(T)`: builds a `cancelable`
        /// and appends it to the event's subscriptions. Its writes are journalled like a field's.
        event_subscribe: EventSubscribe,
        /// RFC-0082, P3.9. `C.Cancel()` of a `cancelable`: an active subscription becomes
        /// cancelled and leaves its event's list. Yields the unit value.
        subscription_cancel: u32,
        /// RFC-0082, P3.9. The second half of a subscribable event's `Signal`: calls each
        /// subscription that was active when it began and still is, in order, with the one
        /// argument (the value), and yields the unit value. `callable` is the event.
        event_notify: Invoke,
        /// RFC-0085, I1. `ref_new` builds a variable cell `ref(T)` holding its operand, a `T`;
        /// `ref_get` reads the cell of its operand, a `ref(T)`, and is tracked while a guard runs;
        /// `ref_set` is a program write of the cell (journalled; in a live program it detaches,
        /// writes, notifies and propagates) and yields the value written.
        ref_new: u32,
        ref_get: u32,
        ref_set: RefSet,
        /// RFC-0086, P2.3: see `Grant`. A control operation, as a native call is: it reads the
        /// run's grant list, which only the machine's control storage holds. RFC-0087, P5.4: of
        /// kind `session` it has no name and yields the run's one `grant(session)`, index 0.
        grant: Grant,
        /// RFC-0087, P5.4 (W4 to W6). A keyed cell is named by these three and nothing else.
        /// `weak_init` declares the cell, at the root and outside every region: it is the cell's
        /// `initial`, and yields the empty map of its type. `weak_get` reads the cell and yields
        /// the option of the entry of its key, viewing the value as `map_lookup` does; in a guard
        /// it is a tracked read of the whole cell. `weak_set` is a program write of the cell: the
        /// map with the entry replaced or appended, as `map_set` builds it, written, journalled
        /// and, in a live program, propagated; it yields the value.
        weak_init: u32,
        weak_get: WeakGet,
        weak_set: WeakSet,
        /// RFC-0087, P5.3: `ToJson(V)`, the canonical JSON of its operand, a value of a
        /// persistable type, as a `string` (E1, E2); and `FromJson[T][S]`, the value of `T` its
        /// operand, a `string`, encodes, as an `option(T)`, the node's type, that is empty when
        /// the text encodes none (E3, E4). Both run `persist_json.zig`, read instances (the
        /// encoder) or build them (the decoder), and are control and source operations whatever
        /// the type, as an operation's kind alone says which it is.
        json_encode: u32,
        json_decode: u32,
    },
    /// Resolve representation from already admitted typed Values. This helper
    /// performs no signature, effect, visibility or schedule admission.
    pub fn invocationWith(self: Node, function: ?u32, values: []const Value) ?Invocation {
        return switch (self.kind) {
            .invoke => |i| .{ .call = .{ .function = values[i.callable].callable.function, .arguments = i.arguments, .captures = values[i.callable].callable.captures } },
            .iterate_value => |i| .{ .iterate = .{ .function = values[i.callable].callable.function, .count = i.count, .initial = i.initial, .captures = values[i.callable].callable.captures } },
            .loop => |l| .{ .loop = .{ .function = values[l.callable].callable.function, .initial = l.initial, .captures = values[l.callable].callable.captures } },
            .recur => |r| .{ .call = .{ .function = function.?, .arguments = r } },
            else => self.invocation(),
        };
    }
    pub fn isInvocation(self: Node) bool {
        return self.kind == .call or self.kind == .iterate or self.kind == .recur or self.kind == .invoke or self.kind == .iterate_value or self.kind == .loop;
    }
    /// A self continuation gets its target only inside its admitted body.
    pub fn invocationIn(self: Node, function: u32) ?Invocation {
        if (self.kind == .recur) return .{ .call = .{ .function = function, .arguments = self.kind.recur } };
        return self.invocation();
    }
    pub fn invocation(self: Node) ?Invocation {
        return switch (self.kind) {
            .call => |c| .{ .call = .{ .function = c.function, .arguments = c.arguments } },
            .iterate => |i| .{ .iterate = .{ .function = i.function, .count = i.count, .initial = i.initial } },
            else => null,
        };
    }
};
pub const FunctionNode = struct {
    node: Node,
    // Compiler templates use immutable binding indexes for global inputs;
    // published runtime bodies use the admitted capture catalogue instead.
    input: union(enum) { operation, parameter: u32, global: u32 } = .operation,
};
pub const RuntimeFunction = struct {
    name: Span,
    parameters: [limits.parameters]Type = undefined,
    parameter_count: u32,
    value_type: Type,
    body: Span,
    root: u32,
    available_at: u32,
    member_work: u32,
    control_ops: u32 = 0,
    has_control: bool = false,
    has_failure: bool = false,
    decides: bool = false,
    transacts: bool = false,
    /// The rest of the declared effect (RFC-0078); admission checks the body against the set.
    detail: EffectDetail = .{},
    source_ops: u32 = 0,
    has_source: bool = false,
    has_local: bool = false,
    is_public: bool,
    anonymous: bool = false,
    specialization: ?Type = null,
    generic_source: Span = .{ .start = 0, .end = 0 },
    template_public: bool = false,
    /// RFC-0084, P4.2: this is the block-clause function of the class `clauses_of`, which has
    /// live fields of its own; only it attaches the guards of that class's live-only fields, and
    /// it is only called on an instance just built.
    clauses_of: ?Type = null,
    /// RFC-0082, P3.6: this anonymous function is an arm whose `arm_exit`s hand their
    /// expression a pending exit of this type; it runs only as an arm of a `structured` site
    /// whose check reads an exit of that type.
    exits: ?Type = null,
    /// RFC-0085, I7: declared `Name(...)<effects> := Body`, its result type the body's. Metadata
    /// for the evolution checks of P5 and for inspection: it changes no execution, and both
    /// admissions accept either value.
    transparent: bool = false,
    /// RFC-0085, I3: a nested function, anonymous and named by the name it was declared with
    /// (admission rule 8): an identifier the source follows with `(`, on an entry that is not
    /// public, exits no arm and holds no clauses. Without it an anonymous entry is named by the
    /// word that made it (`Fn`, `Spawn`, `Branch`, `live`).
    nested: bool = false,

    pub fn effects(self: RuntimeFunction) EffectSet {
        return effectSet(self.transacts, self.decides, self.detail);
    }
};
pub const Binding = struct { name: Span, node: u32, value_type: Type, is_public: bool };
pub const Module = struct { path: Span, source: Span, imports: Span };
pub const Import = struct { alias: Span, path: Span, target: u32 };
/// A module declared inside a file as `Name := module{...}` (RFC-0074). `source` is the text
/// between its braces; `parent` is the nested module that declares it, or `no_parent` when the
/// file itself does. The table is ordered by `source.start`, so a parent precedes its children.
pub const NestedModule = struct { name: Span, source: Span, parent: u32, is_public: bool };
/// RFC-0093, B7: one file of a module given as a folder. The files of a folder are joined, in the
/// byte order of their paths, into the text of the folder's module; `source` is the file's part of
/// that text (the last part also holds the module's library block) and `path` its path in the
/// bundle, in `Program.file_paths`. Only a diagnostic reads this table: it says where to point.
pub const ModulePart = struct { path: Span, source: Span };
pub const no_parent: u32 = std.math.maxInt(u32);
pub const Program = struct {
    source: []const u8,
    nodes: []const Node,
    bindings: []const Binding,
    strings: []const u8,
    definitions: []const Definition = &.{},
    fields: []const Field = &.{},
    members: []const u32 = &.{},
    cases: []const Span = &.{},
    tuple_elements: []const Type = &.{},
    paths: []const u8 = "",
    modules: []const Module = &.{},
    imports: []const Import = &.{},
    nested: []const NestedModule = &.{},
    /// RFC-0093, B7: the files of the modules of a bundle given as a folder tree, in the order of
    /// the modules; empty for a single file and for a bundle of files.
    parts: []const ModulePart = &.{},
    file_paths: []const u8 = "",
    string_comparisons: u32 = 0,
    control_ops: u32 = 0,
    source_cells: []const SourceCell = &.{},
    source_ops: u32 = 0,
    call_ops: u32 = 0,
    call_arguments: []const u32 = &.{},
    functions: []const RuntimeFunction = &.{},
    function_nodes: []const FunctionNode = &.{},
    function_members: []const u32 = &.{},
    function_arguments: []const u32 = &.{},
    globals: []const Binding = &.{},
    /// Host table this program was compiled against; `native_call` indexes it.
    natives: []const native.Entry = &.{},
    /// Writable remainder of the buffer behind `strings`; run-built strings append here.
    string_tail: []u8 = &.{},
    /// Methods declared by classes and the function each one resolves to for each class.
    slots: []const Slot = &.{},
    dispatch: []const Dispatch = &.{},
    /// RFC-0087, P5.2: the field defaults of `<persistable>` types (`Field.constant`), and the
    /// members of those that are aggregates: the static part of the members, which no run builds.
    constants: []const Constant = &.{},
    constant_members: []const u32 = &.{},
};
/// A reference to a class instance: its class and the first of its consecutive state cells, which
/// are a header holding the class followed by one cell per field.
pub const ObjectRef = struct { value_type: Type, id: u32 };
pub const Value = union(enum) { integer: i64, boolean: bool, string: []const u8, floating: f64, aggregate: Aggregate, enumeration: EnumValue, callable: CallableValue, object: ObjectRef, rational: Rational };
comptime {
    // Enum immediates must not enlarge every register/member reservation.
    const PreviousValue = union(enum) { integer: i64, boolean: bool, string: []const u8, floating: f64, aggregate: Aggregate };
    std.debug.assert(@sizeOf(Value) == @sizeOf(PreviousValue));
    std.debug.assert(@sizeOf(EnumValue) <= @sizeOf(Aggregate));
    std.debug.assert(@sizeOf(ObjectRef) <= @sizeOf(Aggregate));
    // Two words, like a string: a rational is a scalar and takes no members.
    std.debug.assert(@sizeOf(Rational) == @sizeOf([]const u8));
}

/// Guest floats have a single NaN representation; signed zeros remain distinct
/// in storage; predicate equality merges signed zero while arithmetic preserves it.
/// Whether `value` is a NaN, read from its bits: an exponent of all ones and a fraction that
/// is not zero. `std.math.isNan` is `x != x`, a float comparison that an optimiser may decide
/// without looking when it sees the operation that made `x`: in ReleaseSafe `@sqrt` of a
/// negative number was taken for a number that way (RFC-0077). Integer operations on the bits
/// leave it nothing to assume.
pub fn isNan(value: f64) bool {
    return @as(u64, @bitCast(value)) & 0x7fff_ffff_ffff_ffff > 0x7ff0_0000_0000_0000;
}

pub fn canonicalFloat(value: f64) f64 {
    return if (isNan(value)) @bitCast(@as(u64, 0x7ff8000000000000)) else value;
}

pub fn isCanonicalFloat(value: f64) bool {
    return !isNan(value) or @as(u64, @bitCast(value)) == 0x7ff8000000000000;
}

/// JSON has no nonfinite numbers. Preserve them as explicit strings rather than
/// emitting invalid JSON, silently substituting null or losing infinities.
pub const FloatReport = struct {
    value: f64,

    pub fn jsonStringify(self: FloatReport, json: *std.json.Stringify) std.Io.Writer.Error!void {
        if (isNan(self.value)) return json.write("NaN");
        if (std.math.isInf(self.value)) return json.write(if (self.value < 0) "-Inf" else "Inf");
        return json.write(self.value);
    }
};

/// Operand enumeration is representation metadata, not a dominance validator.
/// Merge arm roots and forward targets have separate structured admission.
pub fn operandCount(node: Node, members: []const u32) usize {
    _ = members;
    return switch (node.kind) {
        .negate, .float_negate, .int_to_float, .float_to_int, .string_length, .to_string, .logic_not, .field, .tuple_element, .array_length, .option_present, .option_value, .demand, .fail, .exit, .err, .if_begin, .cell_init, .cell_write, .local_set, .object_get, .upcast, .downcast, .instance_of, .method_value, .spawn, .sleep, .refine, .task_await, .event_await, .branch => 1,
        .cell_live => 1,
        .object_live => 2,
        .arm_exit => 1,
        .reaction => 2,
        .task_cancel => 1,
        .batch => 1,
        .await_guard => 1,
        .event_subscribe => 2,
        .subscription_cancel => 1,
        .event_notify => |i| 1 + i.arguments.end - i.arguments.start,
        .ref_new, .ref_get => 1,
        .ref_set => 2,
        .grant => |g| @intFromBool(g.kind != .session),
        .json_encode, .json_decode => 1,
        .rational => |r| if (r.op.unary()) 1 else 2,
        .weak_get => 1,
        .weak_set => 2,
        .binary, .float_binary, .logic_binary, .compare, .option_or, .map_lookup, .map_remove, .array_get, .map_key, .map_value, .string_concat, .array_concat, .iterate => 2,
        .native_call => |c| c.count,
        .text => |t| t.op.arity(),
        .aggregate => |r| r.end - r.start,
        .call => |c| c.arguments.end - c.arguments.start,
        .recur => |r| r.end - r.start,
        .invoke, .bind => |i| 1 + i.arguments.end - i.arguments.start,
        .iterate_value, .array_set, .map_set => 3,
        .object_set, .event_signal => 2,
        .object_new => |c| c.arguments.end - c.arguments.start,
        .structured => |s| s.arms.end - s.arms.start,
        .loop => 2,
        else => 0,
    };
}
pub fn operandAt(node: Node, ordinal: usize, members: []const u32, arguments: []const u32) u32 {
    return switch (node.kind) {
        .negate, .float_negate, .int_to_float, .string_length, .to_string, .logic_not, .array_length, .option_present, .option_value, .demand, .fail, .exit, .err, .local_set, .upcast, .downcast, .spawn, .sleep, .refine, .task_await, .event_await, .branch => |n| n,
        .event_signal => |s| if (ordinal == 0) s.event else s.value,
        .instance_of => |c| c.value,
        .method_value => |m| m.receiver,
        .string_concat, .array_concat => |c| if (ordinal == 0) c.lhs else c.rhs,
        .float_to_int => |c| c.operand,
        .field, .tuple_element => |a| a.value,
        .binary, .float_binary => |b| if (ordinal == 0) b.lhs else b.rhs,
        .rational => |r| if (ordinal == 0) r.lhs else r.rhs,
        .logic_binary => |b| if (ordinal == 0) b.lhs else b.rhs,
        .compare => |b| if (ordinal == 0) b.lhs else b.rhs,
        .option_or => |c| if (ordinal == 0) c.option else c.fallback,
        .map_lookup, .map_remove => |c| if (ordinal == 0) c.map else c.key,
        .array_get, .map_key, .map_value => |c| if (ordinal == 0) c.array else c.index,
        .array_set => |c| switch (ordinal) {
            0 => c.array,
            1 => c.index,
            else => c.value,
        },
        .map_set => |c| switch (ordinal) {
            0 => c.map,
            1 => c.key,
            else => c.value,
        },
        .native_call => |c| c.args[ordinal],
        .text => |t| t.operand(ordinal),
        .aggregate => |r| members[r.start + ordinal],
        .if_begin => |b| b.condition,
        .cell_init, .cell_write => |c| c.value,
        .call => |c| arguments[c.arguments.start + ordinal],
        .object_new => |c| arguments[c.arguments.start + ordinal],
        .structured => |s| arguments[s.arms.start + ordinal],
        .object_get => |a| a.value,
        .object_set => |c| if (ordinal == 0) c.object else c.value,
        .recur => |r| arguments[r.start + ordinal],
        .invoke, .bind => |i| if (ordinal == 0) i.callable else arguments[i.arguments.start + ordinal - 1],
        .iterate => |i| if (ordinal == 0) i.count else i.initial,
        .iterate_value => |i| switch (ordinal) {
            0 => i.callable,
            1 => i.count,
            else => i.initial,
        },
        .loop => |l| if (ordinal == 0) l.callable else l.initial,
        .cell_live => |c| c.guard,
        .object_live => |c| if (ordinal == 0) c.object else c.guard,
        .arm_exit => |n| n,
        .reaction => |r| if (ordinal == 0) r.guard else r.body,
        .task_cancel => |n| n,
        .batch => |n| n,
        .await_guard => |n| n,
        .event_subscribe => |s| if (ordinal == 0) s.event else s.callback,
        .subscription_cancel => |n| n,
        .event_notify => |i| if (ordinal == 0) i.callable else arguments[i.arguments.start + ordinal - 1],
        .ref_new, .ref_get => |n| n,
        .ref_set => |r| if (ordinal == 0) r.ref else r.value,
        .grant => |g| g.name,
        .weak_get => |c| c.key,
        .weak_set => |c| if (ordinal == 0) c.key else c.value,
        .json_encode, .json_decode => |n| n,
        else => unreachable,
    };
}
pub fn controlOp(node: Node) bool {
    return switch (node.kind) {
        .if_begin, .attempt_begin, .otherwise, .merge, .demand, .fail, .exit, .err, .iterate, .recur, .invoke, .iterate_value, .loop, .bind, .native_call, .string_concat, .array_concat, .array_set, .map_set, .map_remove, .to_string => true,
        .text => |t| t.op.walks(),
        .spawn, .sleep, .canceling, .cancel_exit => true,
        .task_await, .event_new, .event_signal, .event_await => true,
        .structured => true,
        .branch => true,
        .cell_live => true,
        .object_live => true,
        .arm_exit, .arm_exited, .arm_exit_value => true,
        .reaction => true,
        .task_cancel, .elapsed_time => true,
        .batch => true,
        .await_guard => true,
        .event_notify => true,
        // RFC-0086, P2.3: it reads the run's grants, as a native call reads the run's world.
        .grant => true,
        // RFC-0087, P5.4: it builds the map it writes, as `map_set` does.
        .weak_set => true,
        // RFC-0087, P5.3: the codec runs in the control loop, which holds the instances.
        .json_encode, .json_decode => true,
        else => false,
    };
}
/// `spawn` builds an instance, its handle, so it is a source operation too (RFC-0082): a
/// function that holds one journals its regions, and a region that fails forgets the handle
/// of a start it held. The operations of P3.2 read or write the hidden cells of a handle or
/// an event, or build one, so they are source operations as well.
pub fn sourceOp(node: Node) bool {
    return switch (node.kind) {
        .cell_init, .cell_read, .cell_write, .object_new, .object_get, .object_set, .spawn => true,
        .task_await, .event_new, .event_signal, .event_await => true,
        .cell_live => true,
        .object_live => true,
        .reaction => true,
        .task_cancel => true,
        .await_guard => true,
        .event_subscribe, .subscription_cancel, .event_notify => true,
        // RFC-0085, I1: a variable cell is an instance's cells, built, read and written.
        .ref_new, .ref_get, .ref_set => true,
        // RFC-0087, P5.4: a keyed cell is declared, read and written.
        .weak_init, .weak_get, .weak_set => true,
        // RFC-0087, P5.3: the encoder reads an instance's fields as `object_get` does, and the
        // decoder builds instances as `object_new` does, so a region journals what it built.
        .json_encode, .json_decode => true,
        else => false,
    };
}
/// RFC-0087, P5.4: whether the program has a keyed cell. Its final cells are then in its
/// record, from which a report shows each keyed cell's final value (W8).
pub fn keyedCells(program: Program) bool {
    for (program.source_cells) |cell| if (cell.keyed != .none) return true;
    return false;
}
pub fn sparse(program: Program) bool {
    return program.control_ops != 0 or program.source_ops != 0;
}
pub fn cold(program: Program) bool {
    return sparse(program) or program.call_ops != 0;
}
/// Call after full admission: a forged catalogue cannot select execution/storage.
pub fn controlledCalls(program: Program) bool {
    for (program.nodes) |node| if (node.kind == .invoke or node.kind == .iterate_value or node.kind == .loop or node.kind == .event_notify) return true;
    for (program.nodes) |node| if (node.invocation()) |invocation| {
        const f = program.functions[invocation.target()];
        if (invocation == .iterate or f.has_control or f.has_source or f.has_local) return true;
    };
    return false;
}
/// Failure publication is independent of sparse root activity. Call after admission.
pub fn failureCalls(program: Program) bool {
    for (program.nodes) |node| if (node.kind == .invoke or node.kind == .iterate_value or node.kind == .loop or node.kind == .event_notify) return true;
    for (program.nodes) |node| if (node.invocation()) |invocation| {
        if (program.functions[invocation.target()].has_failure) return true;
    };
    return false;
}
pub fn marker(node: Node) bool {
    return switch (node.kind) {
        .if_begin, .attempt_begin, .otherwise => true,
        else => false,
    };
}
