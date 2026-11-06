//! Source templates for the compiler's token macros (`For`, ...).
//!
//! A macro expands to ordinary Forbic source. The template text lives here. A module that
//! calls a macro carries the templates and a pool of `Fn` words after its own text, as comment
//! lines (the lexer skips them), so they sit inside the module's span and module provenance
//! checks hold. The compiler lexes each template once per compile and splices its tokens,
//! giving them spans inside the calling module's comment block and replacing the placeholder
//! identifiers (`__X`, `__ITEMS`, ...) with ranges of user tokens.
const std = @import("std");
const types = @import("types.zig");

pub const Template = enum { and_word, true_word, tuple_word, numerals, temporaries, for_each, for_each_indexed, for_filter, for_filter_indexed, if_bound, check_bind, check_test, unpack_if, tuple_bind, unpack_tuple, while_loop, loop_type, loop_name, loop_decl, loop_store, not_test, for_gen, for_gen_indexed, for_range, for_try, for_yield, case_words, first_gen, first_gen_indexed, first_range, first_try, first_yield, first_inner, for_carry, for_carry_indexed, for_carry_range, sort_by };

/// Template text, in `Template` order. Compiler-generated names start with `__`.
/// `__elem(Name)` is the element type of an array in scope and `__result(Name)` the result
/// type of a function in scope, so no user type has to be spelled.
pub const text = [_][]const u8{
    // Words the compiler splices between user tokens.
    "and",
    "true",
    "tuple{,}",
    "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15",
    "__t0 __t1 __t2 __t3 __t4 __t5 __t6 __t7 __t8 __t9 __t10 __t11 __t12 __t13 __t14 __t15 __t16 __t17 __t18 __t19 __t20 __t21 __t22 __t23 __t24 __t25 __t26 __t27 __t28 __t29 __t30 __t31",
    // `For(X:Items, Body)`: map over the elements; the accumulator is the state of `Iterate`, so each
    // new element's literal sits right behind it and the append costs one member (RFC-0055).
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__X:__elem(__for_items)){__BODY};Iterate(Fn(__for_acc:[]__result(__for_f)){__for_acc+array{__for_f(ElementAt(__for_items,__for_acc.Length))}},__for_items.Length,array{})}",
    // `For(I->X:Items, Body)`: the body also receives the element's index.
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__I:__key(__for_items),__X:__elem(__for_items)){__BODY};Iterate(Fn(__for_acc:[]__result(__for_f)){__for_acc+array{__for_f(KeyAt(__for_items,__for_acc.Length),ElementAt(__for_items,__for_acc.Length))}},__for_items.Length,array{})}",
    // `For(X:Items, Condition, Body)`: elements whose condition fails are skipped. The index is no longer
    // the accumulator length, so the state is a tuple and appends copy the accumulator.
    "Block{__for_items:=(__ITEMS);__for_keep:=Fn(__X:__elem(__for_items)){If(__COND,true,false)};__for_f:=Fn(__X:__elem(__for_items)){__BODY};Loop(Fn(__for_s:tuple(i64,[]__result(__for_f))){If(__for_s(0)<__for_items.Length,option{tuple{__for_s(0)+1,If(__for_keep(ElementAt(__for_items,__for_s(0))),__for_s(1)+array{__for_f(ElementAt(__for_items,__for_s(0)))},__for_s(1))}},option{})},tuple{0,array{}})(1)}",
    "Block{__for_items:=(__ITEMS);__for_keep:=Fn(__I:__key(__for_items),__X:__elem(__for_items)){If(__COND,true,false)};__for_f:=Fn(__I:__key(__for_items),__X:__elem(__for_items)){__BODY};Loop(Fn(__for_s:tuple(i64,[]__result(__for_f))){If(__for_s(0)<__for_items.Length,option{tuple{__for_s(0)+1,If(__for_keep(KeyAt(__for_items,__for_s(0)),ElementAt(__for_items,__for_s(0))),__for_s(1)+array{__for_f(KeyAt(__for_items,__for_s(0)),ElementAt(__for_items,__for_s(0)))},__for_s(1))}},option{})},tuple{0,array{}})(1)}",
    // `If(C1, ..., Cn, Then, Else)`: bindings and tests run inside an attempt that yields the bound
    // values as a one-element array, or an empty array when a condition fails.
    "Block{__if_r:=Attempt(Block{__CHECKS array{__PACK}},array{});If(__if_r.Length>0,Block{__if_b:=ElementAt(__if_r,0);__UNPACK __THEN},__ELSE)}",
    "__NAME:=(__EXPR);",
    "Require[(__EXPR)];",
    "__NAME:=__if_b(__INDEX);",
    // `(A, B) := value`.
    "__TEMP:=(__EXPR);",
    "__NAME:=__TEMP(__INDEX);",
    // `While(C1, ..., Body)`: the mutated locals travel through the state of a `Loop`; each visit
    // re-declares them from the state, and after the loop they are stored back.
    "Block{__w:=Loop(Fn(__s:tuple(logic __VARTYPES)){Block{__VARDECLS If(__CONDS,Block{__STMTS option{tuple{true __VARNAMES}}},option{})}},tuple{true __VARNAMES});__VARSTORES true}",
    ",__var(__NAME)",
    ",__NAME",
    "var __NAME:__type(__NAME)=__s(__INDEX);",
    "set __NAME=__w(__INDEX);",
    // `Not[E]` succeeds exactly when `E` fails, undoing what `E` did.
    "Require[Attempt(Block{__EXPR;false},true)]",
};

/// The templates of the general `For` (RFC-0064), in the order of the `Template` values after
/// `not_test`. Like the templates of `First` they are not part of every block: only a module
/// with a `For` that needs the general lowering gets them (`Extension.loops`), as the lines
/// right after the fixed ones, so the block of a module without one is what it was before
/// that RFC.
pub const for_text = [_][]const u8{
    // The general `For` (RFC-0064): one level per generator, each a function of its binding that
    // returns the array of the levels inside it, and a loop that joins those arrays in order.
    // The state carries the position, because a level may contribute any number of elements.
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__X:__elem(__for_items)){__REST};Iterate(Fn(__for_s:tuple(i64,__result(__for_f))){tuple{__for_s(0)+1,__for_s(1)+__for_f(ElementAt(__for_items,__for_s(0)))}},__for_items.Length,tuple{0,array{}})(1)}",
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__I:__key(__for_items),__X:__elem(__for_items)){__REST};Iterate(Fn(__for_s:tuple(i64,__result(__for_f))){tuple{__for_s(0)+1,__for_s(1)+__for_f(KeyAt(__for_items,__for_s(0)),ElementAt(__for_items,__for_s(0)))}},__for_items.Length,tuple{0,array{}})(1)}",
    // `X:Low..High`: the state counts offsets from `Low`, so no array is built and neither the
    // count of a short range nor a value next to an i64 edge overflows.
    "Block{__for_lo:=(__ITEMS);__for_hi:=(__HIGH);__for_f:=Fn(__X:i64){__REST};Iterate(Fn(__for_s:tuple(i64,__result(__for_f))){tuple{__for_s(0)+1,__for_s(1)+__for_f(__for_lo+__for_s(0))}},If(__for_lo<=__for_hi,__for_hi-__for_lo+1,0),tuple{0,array{}})(1)}",
    // Bindings, filters and whatever can fail after them run in one attempt per iteration: a
    // failure contributes nothing and undoes the iteration's writes.
    "Attempt(Block{__CHECKS __REST},array{})",
    "array{__BODY}",
};

/// Words of a `Case` with binding patterns (RFC-0066), in `CaseWord` order: the scrutinee's
/// temporary, the compiler-only forms that test and narrow it without a failure context, and
/// what carries the names an effectful guard bound out of its attempt. Only a module with such
/// a `Case` gets the line (`Extension.cases`), after the lines of `for_text`.
pub const case_text = "Block __case_s __case_is __case_as __case_all __case_some __case_none __case_value __case_tuple __case_r option tuple";

/// The templates of `First[...]` (RFC-0072), in the order of the last `Template` values. They
/// are not part of every block: a module that uses the form gets them as generated lines at the
/// very end of its block (`Extension.first`), so the block of a module that does not is, byte
/// for byte, what it was before that RFC, and so is everything a report prints about it.
pub const first_text = [_][]const u8{
    // `First[...]` (RFC-0072): the levels of the general `For`, but a level yields the option of
    // its first iteration that succeeds, and its loop stops there: the state is the position
    // and that option, and no later element, source, filter or body is evaluated.
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__X:__elem(__for_items)){__REST};Loop(Fn(__for_s:tuple(i64,__result(__for_f))){If(not __for_s(1).IsSet and __for_s(0)<__for_items.Length,option{tuple{__for_s(0)+1,__for_f(ElementAt(__for_items,__for_s(0)))}},option{})},tuple{0,option{}})(1)}",
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__I:__key(__for_items),__X:__elem(__for_items)){__REST};Loop(Fn(__for_s:tuple(i64,__result(__for_f))){If(not __for_s(1).IsSet and __for_s(0)<__for_items.Length,option{tuple{__for_s(0)+1,__for_f(KeyAt(__for_items,__for_s(0)),ElementAt(__for_items,__for_s(0)))}},option{})},tuple{0,option{}})(1)}",
    // The count is computed as `For` computes it, so an empty range and an over-long one behave alike.
    "Block{__for_lo:=(__ITEMS);__for_hi:=(__HIGH);__for_n:=If(__for_lo<=__for_hi,__for_hi-__for_lo+1,0);__for_f:=Fn(__X:i64){__REST};Loop(Fn(__for_s:tuple(i64,__result(__for_f))){If(not __for_s(1).IsSet and __for_s(0)<__for_n,option{tuple{__for_s(0)+1,__for_f(__for_lo+__for_s(0))}},option{})},tuple{0,option{}})(1)}",
    // One iteration: a failure anywhere in it yields the empty option and undoes its writes.
    "Attempt(Block{__CHECKS __REST},option{})",
    "option{__BODY}",
    // An outer iteration succeeds only if the level inside it found something.
    "option{(__REST)?}",
};

/// The levels of a general `For` whose clauses or body assign `var` locals declared outside it
/// (RFC-0064, "Assigned locals"), in the order of the last `Template` values. A level's function
/// takes the locals as `__s`, a tuple shaped like the state of a `While` (a flag, then the
/// locals), declares them anew from it, and returns its array with the locals as they are then;
/// the loop joins the arrays and hands the locals from one iteration to the next, and the code
/// after it stores them back. An iteration that fails leaves them as they were: its attempt,
/// which is the `__REST` of the general templates, restores what it assigned. Only a module
/// with such a `For` carries these lines (`Extension.carries`), after every other line.
pub const carry_text = [_][]const u8{
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__X:__elem(__for_items),__s:tuple(logic __VARTYPES)){Block{__VARDECLS __for_r:=(__REST);tuple{__for_r,tuple{true __VARNAMES}}}};__for_e:=Iterate(Fn(__for_s:tuple(i64,__result(__for_f))){Block{__for_q:=__for_f(ElementAt(__for_items,__for_s(0)),__for_s(1)(1));tuple{__for_s(0)+1,tuple{__for_s(1)(0)+__for_q(0),__for_q(1)}}}},__for_items.Length,tuple{0,tuple{array{},tuple{true __VARNAMES}}})(1);__w:=__for_e(1);__VARSTORES __for_e(0)}",
    "Block{__for_items:=(__ITEMS);__for_f:=Fn(__I:__key(__for_items),__X:__elem(__for_items),__s:tuple(logic __VARTYPES)){Block{__VARDECLS __for_r:=(__REST);tuple{__for_r,tuple{true __VARNAMES}}}};__for_e:=Iterate(Fn(__for_s:tuple(i64,__result(__for_f))){Block{__for_q:=__for_f(KeyAt(__for_items,__for_s(0)),ElementAt(__for_items,__for_s(0)),__for_s(1)(1));tuple{__for_s(0)+1,tuple{__for_s(1)(0)+__for_q(0),__for_q(1)}}}},__for_items.Length,tuple{0,tuple{array{},tuple{true __VARNAMES}}})(1);__w:=__for_e(1);__VARSTORES __for_e(0)}",
    "Block{__for_lo:=(__ITEMS);__for_hi:=(__HIGH);__for_f:=Fn(__X:i64,__s:tuple(logic __VARTYPES)){Block{__VARDECLS __for_r:=(__REST);tuple{__for_r,tuple{true __VARNAMES}}}};__for_e:=Iterate(Fn(__for_s:tuple(i64,__result(__for_f))){Block{__for_q:=__for_f(__for_lo+__for_s(0),__for_s(1)(1));tuple{__for_s(0)+1,tuple{__for_s(1)(0)+__for_q(0),__for_q(1)}}}},If(__for_lo<=__for_hi,__for_hi-__for_lo+1,0),tuple{0,tuple{array{},tuple{true __VARNAMES}}})(1);__w:=__for_e(1);__VARSTORES __for_e(0)}",
};

/// `SortBy(Items, Less)` (RFC-0081): a stable bottom-up merge sort. `__sb_p` is the order the
/// passes settle on, as positions in `Items`; a pass of width `__sb_w` merges each two runs of
/// that width into an array of slots of the order before it (`__sb_t`), which a second loop
/// turns into positions again. The next slot is computed from how many the pass has taken and
/// the last one it took, which says which run was read last and how far into both runs the
/// pass is, so each pass is an `Iterate` whose state is the array it appends to: a constant
/// cost per element (RFC-0055) and no recursion. The element of the right run goes first only
/// when `Less` succeeds with it on the left, so equal elements keep their order; a `Less` that
/// fails undoes what it did, as the condition of an `If` does, and one that succeeds keeps it.
/// `__sb_ys` holds the items as an array of their elements, which a map or a string is not.
/// Only a module that calls the function gets the line (`Extension.sorts`), after every other.
pub const sort_text = [_][]const u8{
    "Block{__sb_xs:=(__ITEMS);__sb_ys:[]__elem(__sb_xs)=__sb_xs;__sb_less:=(__BODY);__sb_n:=__sb_xs.Length;__sb_p:=Loop(Fn(__sb_s:tuple(i64,[]i64)){If(__sb_s(0)<__sb_n,option{tuple{__sb_s(0)*2,Block{__sb_w:=__sb_s(0);__sb_q:=__sb_s(1);__sb_t:=Iterate(Fn(__sb_a:[]i64){Block{__sb_m:=__sb_a.Length;__sb_lo:=__sb_m/(__sb_w*2)*(__sb_w*2);__sb_mid:=If(__sb_lo+__sb_w<__sb_n,__sb_lo+__sb_w,__sb_n);__sb_hi:=If(__sb_lo+__sb_w*2<__sb_n,__sb_lo+__sb_w*2,__sb_n);__sb_last:=If(__sb_m==__sb_lo,__sb_lo,ElementAt(__sb_a,__sb_m-1));__sb_k:=__sb_mid+__sb_m-__sb_last-1;__sb_i:=If(__sb_m==__sb_lo,__sb_lo,If(__sb_last<__sb_mid,__sb_last+1,__sb_k));__sb_j:=If(__sb_m==__sb_lo,__sb_mid,If(__sb_last<__sb_mid,__sb_k,__sb_last+1));__sb_a+array{If(__sb_i==__sb_mid,__sb_j,If(__sb_j==__sb_hi,__sb_i,If(Block{__sb_less[ElementAt(__sb_xs,ElementAt(__sb_q,__sb_j)),ElementAt(__sb_xs,ElementAt(__sb_q,__sb_i))];true},__sb_j,__sb_i)))}}},__sb_n,array{});Iterate(Fn(__sb_b:[]i64){__sb_b+array{ElementAt(__sb_q,ElementAt(__sb_t,__sb_b.Length))}},__sb_n,array{})}}},option{})},tuple{1,Iterate(Fn(__sb_a:[]i64){__sb_a+array{__sb_a.Length}},__sb_n,array{})})(1);Iterate(Fn(__sb_r:[]__elem(__sb_xs)){__sb_r+array{ElementAt(__sb_xs,ElementAt(__sb_p,__sb_r.Length))}},__sb_n,array{})}",
};

/// The `Fn` words one expansion of `sort_text` takes.
pub const sort_words = 5;

/// Templates of all tables together.
pub const template_count = text.len + for_text.len + 1 + first_text.len + carry_text.len + sort_text.len;

/// Words of the early-exit lowering (RFC-0068), in `ExitWord` order: a loop that can be left is
/// a `Loop` over a state `__exit_s` that carries a mode, what the loop assigns and the pending
/// `Return` value; `__exit_w` is the state it ended in and `__exit_v` a value on its way out.
/// They are no template: only a module that uses `Loop{}`, `Defer` or an exit from a loop gets
/// the line, as the last generated line of its block (`Extension.exits`), so the block of every
/// other module, and every position in it, is what it was before these words existed.
pub const exit_words = "Block Loop option tuple true __exit_w __exit_s __exit_v __ret var set If Attempt Require ElementAt KeyAt Length and __for_items __for_lo __for_hi __for_n __case_value __type __var i64";

comptime {
    std.debug.assert(template_count == std.enums.values(Template).len);
    std.debug.assert(@backingInt(Template.for_gen) == text.len);
    std.debug.assert(@backingInt(Template.case_words) == text.len + for_text.len);
    std.debug.assert(@backingInt(Template.first_gen) == first_base);
    std.debug.assert(@backingInt(Template.for_carry) == carry_base);
    std.debug.assert(@backingInt(Template.sort_by) == sort_base);
    @setEvalBranchQuota(20000);
    std.debug.assert(std.mem.count(u8, sort_text[0], "Fn(") == sort_words);
}

/// The index of the `SortBy` template.
const sort_base = carry_base + carry_text.len;

/// Bytes of the `SortBy` template lines together.
const sort_length: u32 = blk: {
    var length: u32 = 0;
    for (sort_text) |template| length += @intCast(template.len + 2);
    break :blk length;
};

/// The index of the first carrying `For` template.
const carry_base = first_base + first_text.len;

/// Where each carrying template's text starts, relative to the first of their lines.
const carry_offsets: [carry_text.len]u32 = blk: {
    var result: [carry_text.len]u32 = undefined;
    var position: u32 = 0;
    for (carry_text, 0..) |template, index| {
        position += 1; // `#`
        result[index] = position;
        position += @intCast(template.len + 1); // Text and its newline.
    }
    break :blk result;
};

/// Bytes of the carrying template lines together.
const carry_length: u32 = blk: {
    var length: u32 = 0;
    for (carry_text) |template| length += @intCast(template.len + 2);
    break :blk length;
};

/// The index of the first `First` template.
const first_base = text.len + for_text.len + 1;

/// The text of any template.
pub fn templateText(template: Template) []const u8 {
    const index: usize = @backingInt(template);
    if (index < text.len) return text[index];
    if (index < text.len + for_text.len) return for_text[index - text.len];
    if (index < first_base) return case_text;
    if (index >= sort_base) return sort_text[index - sort_base];
    return if (index < carry_base) first_text[index - first_base] else carry_text[index - carry_base];
}

/// Where each general `For` template's text starts, relative to the first of their lines.
const for_offsets: [for_text.len]u32 = blk: {
    var result: [for_text.len]u32 = undefined;
    var position: u32 = 0;
    for (for_text, 0..) |template, index| {
        position += 1; // `#`
        result[index] = position;
        position += @intCast(template.len + 1); // Text and its newline.
    }
    break :blk result;
};

/// Bytes of the general `For` template lines together.
const for_length: u32 = blk: {
    var length: u32 = 0;
    for (for_text) |template| length += @intCast(template.len + 2);
    break :blk length;
};

/// Where each `First` template's text starts, relative to the first of their lines.
const first_offsets: [first_text.len]u32 = blk: {
    var result: [first_text.len]u32 = undefined;
    var position: u32 = 0;
    for (first_text, 0..) |template, index| {
        position += 1; // `#`
        result[index] = position;
        position += @intCast(template.len + 1); // Text and its newline.
    }
    break :blk result;
};

/// Bytes of the `First` template lines together.
const first_length: u32 = blk: {
    var length: u32 = 0;
    for (first_text) |template| length += @intCast(template.len + 2);
    break :blk length;
};

/// The words of the `case_words` template, in order.
pub const CaseWord = enum(u8) { block, scrutinee, is, as, all, some, none, value, tuple, carrier, option_word, tuple_word };

comptime {
    std.debug.assert(wordCount(case_text) == std.enums.values(CaseWord).len);
}

/// The words of the `exit_words` template, in order.
pub const ExitWord = enum(u8) { block, loop, option_word, tuple_word, true_word, ended, state, value, result_type, var_word, set_word, if_word, attempt, require, element_at, key_at, length, and_word, items, low, high, count, unwrap, type_of, var_type, integer };

comptime {
    std.debug.assert(wordCount(exit_words) == std.enums.values(ExitWord).len);
}

/// `Fn` words pooled per macro call: the most a call with one generator needs. A `For` with
/// several generators takes two per generator and gets the rest from its block's `Extension`.
pub const fn_words_per_call = 3;

/// How many `Fn` words the pool of a block whose template lines start `templates` bytes in holds.
pub fn pooledWords(templates: u32) u32 {
    std.debug.assert(templates > pool_offset);
    return (templates - pool_offset - 1) / 3;
}

/// The library block of a module is a newline, a `#` line of pooled `Fn` words, one `#` line per
/// template, the generated lines of its `Extension`, and a final `#}` line (the closing brace matters: the span of an anonymous function
/// that a generic specialization generates reaches the pool and must end like a template does).
/// The pool comes first so that adding a template moves nothing a report prints.
pub const pool_offset: u32 = 2;

/// Offset of the first template line within a block whose pool has `calls` macro calls.
pub fn templatesOffset(calls: usize) usize {
    return pool_offset + 3 * fn_words_per_call * calls + 1;
}

/// Where each template's text starts, relative to the first template line.
pub const offsets: [text.len]u32 = blk: {
    var result: [text.len]u32 = undefined;
    var position: u32 = 0;
    for (text, 0..) |template, index| {
        position += 1; // `#`
        result[index] = position;
        position += @intCast(template.len + 1); // Text and its newline.
    }
    break :blk result;
};

/// Bytes of all template lines together.
pub const templates_length: u32 = blk: {
    var length: u32 = 0;
    for (text) |template| length += @intCast(template.len + 2);
    break :blk length;
};

/// How many positions and temporaries the fixed `numerals` and `temporaries` lines spell.
pub const fixed_numerals = wordCount(text[@backingInt(Template.numerals)]);
pub const fixed_temporaries = wordCount(text[@backingInt(Template.temporaries)]);

/// A position indexes a tuple (the names of a pattern, the state of a loop), so no macro needs
/// a numeral beyond the widest tuple.
pub const numeral_count = types.limits.tuple_arity;

const temporary_prefix = "__t";

comptime {
    std.debug.assert(fixed_numerals <= numeral_count);
    std.debug.assert(std.mem.startsWith(u8, text[@backingInt(Template.temporaries)], temporary_prefix ++ "0 "));
}

fn wordCount(comptime words: []const u8) comptime_int {
    return std.mem.count(u8, words, " ") + 1;
}

/// The numerals after the fixed ones, `fixed_numerals ... numeral_count - 1`, and where each
/// starts and ends within that text.
const more_numerals = blk: {
    @setEvalBranchQuota(200 * numeral_count + 1000);
    var line: []const u8 = "";
    var spans: [numeral_count - fixed_numerals][2]u32 = undefined;
    for (fixed_numerals..numeral_count) |number| {
        if (number != fixed_numerals) line = line ++ " ";
        const word = std.fmt.comptimePrint("{d}", .{number});
        spans[number - fixed_numerals] = .{ line.len, line.len + word.len };
        line = line ++ word;
    }
    const final_line = line;
    const final_spans = spans;
    break :blk .{ .line = final_line, .spans = final_spans };
};

/// Generated lines after the templates. The fixed `numerals` and `temporaries` lines cover most
/// modules, and a module that stays within them gets no generated line, so its block (and
/// everything a report prints about it) is what it was before these lines existed. A module that
/// needs more is recompiled with the lines it asked for: the tuple patterns of a module are
/// bounded only by its tokens, so no fixed text could name a temporary for each.
pub const Extension = struct {
    /// The block has the line of numerals `fixed_numerals ... numeral_count - 1`.
    numerals: bool = false,
    /// Temporaries on the line after it: `__t32`, `__t33`, ... in order.
    temporaries: u32 = 0,
    /// `Fn` words on the line after that, for the calls the pool is too small for.
    words: u32 = 0,
    /// The lines of `first_text` after that, for a module that uses `First[...]`.
    first: bool = false,
    /// The line of `exit_words` after those: the last one, so that it moves no other.
    exits: bool = false,
    /// The lines of `for_text`, for a module with a general `For`. They and the line of
    /// `cases` come before every other generated line: that is where they stood while every
    /// block had them, so a module that uses both forms has the block it had then.
    loops: bool = false,
    /// The line of `case_text`, for a module with a pattern `Case`.
    cases: bool = false,
    /// The lines of `carry_text`, for a module with a `For` that assigns outer locals: after
    /// every other line, the exit words included, so that they move none.
    carries: bool = false,
    /// The line of `sort_text`, for a module that calls the standard `SortBy` (RFC-0081): after
    /// every other line, so that it moves none.
    sorts: bool = false,
    /// `Spawn` words on a last line (RFC-0082): each copy of a `Defer` body after the first names
    /// the task body of a `Spawn` in it by one of them, as `Fn` words name copied functions.
    spawns: u32 = 0,
    /// `Branch` words on a line after that (P3.4), for the bodies of the `Branch`es in the `Fn`s
    /// of copied `Defer` bodies, as `Spawn` words are for `Spawn`s.
    branches: u32 = 0,
    /// Names of hidden raw cells and fields on a line after that (RFC-0084, P4.3): `__raw0`,
    /// `__raw1`, ... in order, one for each variable whose type is a function and whose raw
    /// value is not named by the program (`var X:F = E`).
    raws: u32 = 0,
    /// RFC-0092, B4: the line of `castable_word` after every other, for a module whose
    /// `GetCastableFinalSuperClass` makes the metatype `castable_subtype(T)` that the program
    /// never writes: the metatype is named by the word, as it would be where a program writes it.
    castables: bool = false,

    /// Whether `self` asks for a line, or for more of one, than `granted` holds.
    pub fn exceeds(self: Extension, granted: Extension) bool {
        return (self.numerals and !granted.numerals) or self.temporaries > granted.temporaries or self.words > granted.words or (self.first and !granted.first) or (self.exits and !granted.exits) or (self.loops and !granted.loops) or (self.cases and !granted.cases) or (self.carries and !granted.carries) or (self.sorts and !granted.sorts) or self.spawns > granted.spawns or self.branches > granted.branches or self.raws > granted.raws or (self.castables and !granted.castables);
    }

    pub fn merged(self: Extension, other: Extension) Extension {
        return .{ .numerals = self.numerals or other.numerals, .temporaries = @max(self.temporaries, other.temporaries), .words = @max(self.words, other.words), .first = self.first or other.first, .exits = self.exits or other.exits, .loops = self.loops or other.loops, .cases = self.cases or other.cases, .carries = self.carries or other.carries, .sorts = self.sorts or other.sorts, .spawns = @max(self.spawns, other.spawns), .branches = @max(self.branches, other.branches), .raws = @max(self.raws, other.raws), .castables = self.castables or other.castables };
    }

    /// Bytes of the lines of `loops` and `cases`, which precede the other generated lines.
    fn headLength(self: Extension) usize {
        return self.loopsLength() + if (self.cases) case_text.len + 2 else 0;
    }

    fn loopsLength(self: Extension) usize {
        return if (self.loops) for_length else 0;
    }

    fn numeralsLength(self: Extension) usize {
        return if (self.numerals) more_numerals.line.len + 2 else 0;
    }

    fn temporariesLineLength(self: Extension) usize {
        return if (self.temporaries != 0) temporariesLength(self.temporaries) + 2 else 0;
    }

    fn length(self: Extension) usize {
        return self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength() + self.firstLength() + self.exitsLength() + self.carriesLength() + (if (self.sorts) sort_length else 0) + self.spawnsLineLength() + self.branchesLineLength() + self.rawsLineLength() + self.castablesLength();
    }

    fn castablesLength(self: Extension) usize {
        return if (self.castables) castable_word.len + 2 else 0;
    }

    /// Where the text of `castable_word` starts, relative to the first template line: on the
    /// last line, after the raw names (RFC-0092, B4).
    pub fn castableWord(self: Extension) u32 {
        std.debug.assert(self.castables);
        const before = self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength() + self.firstLength() + self.exitsLength() + self.carriesLength() + (if (self.sorts) sort_length else 0) + self.spawnsLineLength() + self.branchesLineLength() + self.rawsLineLength();
        return @intCast(templates_length + before + 1);
    }

    fn rawsLineLength(self: Extension) usize {
        return if (self.raws != 0) rawsLength(self.raws) + 2 else 0;
    }

    /// Where generated raw name `index` (`__raw{index}`) is, relative to the first template
    /// line: on the last line, after the `Branch` words (RFC-0084, P4.3).
    pub fn rawWord(self: Extension, index: u32) [2]u32 {
        std.debug.assert(index < self.raws);
        const before = self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength() + self.firstLength() + self.exitsLength() + self.carriesLength() + (if (self.sorts) sort_length else 0) + self.spawnsLineLength() + self.branchesLineLength();
        const start: u32 = @intCast(templates_length + before + 1 + rawsLength(index));
        return .{ start, start + @as(u32, @intCast(raw_prefix.len + digitCount(index))) };
    }

    fn branchesLineLength(self: Extension) usize {
        return if (self.branches != 0) branch_word.len * @as(usize, self.branches) + 2 else 0;
    }

    /// Where generated `Branch` word `index` starts, relative to the first template line: on the
    /// last line, after the `Spawn` words (P3.4).
    pub fn branchWord(self: Extension, index: u32) u32 {
        std.debug.assert(index < self.branches);
        const before = self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength() + self.firstLength() + self.exitsLength() + self.carriesLength() + (if (self.sorts) sort_length else 0) + self.spawnsLineLength();
        return @intCast(templates_length + before + 1 + branch_word.len * @as(usize, index));
    }

    fn spawnsLineLength(self: Extension) usize {
        return if (self.spawns != 0) spawn_word.len * @as(usize, self.spawns) + 2 else 0;
    }

    /// Where generated `Spawn` word `index` starts, relative to the first template line.
    pub fn spawnWord(self: Extension, index: u32) u32 {
        std.debug.assert(index < self.spawns);
        const before = self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength() + self.firstLength() + self.exitsLength() + self.carriesLength() + (if (self.sorts) sort_length else 0);
        return @intCast(templates_length + before + 1 + spawn_word.len * @as(usize, index));
    }

    fn carriesLength(self: Extension) usize {
        return if (self.carries) carry_length else 0;
    }

    fn firstLength(self: Extension) usize {
        return if (self.first) first_length else 0;
    }

    fn exitsLength(self: Extension) usize {
        return if (self.exits) exit_words.len + 2 else 0;
    }

    /// Where the text of `exit_words` starts, relative to the first template line. The line
    /// follows the `First` lines, so a module with only one of the two has what that one alone gives.
    pub fn exitWords(self: Extension) u32 {
        std.debug.assert(self.exits);
        return @intCast(templates_length + self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength() + self.firstLength() + 1);
    }

    fn wordsLineLength(self: Extension) usize {
        return if (self.words != 0) 3 * @as(usize, self.words) + 2 else 0;
    }

    /// Where the text of `template` starts, relative to the first template line. The templates
    /// every block has are at fixed places; those of the general `For` and the words of `Case`
    /// follow them, and those of `First` follow every other generated line but the exit words.
    pub fn offset(self: Extension, template: Template) u32 {
        const index: usize = @backingInt(template);
        if (index < text.len) return offsets[index];
        if (index < text.len + for_text.len) {
            std.debug.assert(self.loops);
            return templates_length + for_offsets[index - text.len];
        }
        if (index < first_base) {
            std.debug.assert(self.cases);
            return @intCast(templates_length + self.loopsLength() + 1);
        }
        const before_first = templates_length + self.headLength() + self.numeralsLength() + self.temporariesLineLength() + self.wordsLineLength();
        if (index < carry_base) {
            std.debug.assert(self.first);
            return @intCast(before_first + first_offsets[index - first_base]);
        }
        if (index >= sort_base) {
            std.debug.assert(self.sorts);
            return @intCast(before_first + self.firstLength() + self.exitsLength() + self.carriesLength() + 1);
        }
        std.debug.assert(self.carries);
        return @intCast(before_first + self.firstLength() + self.exitsLength() + carry_offsets[index - carry_base]);
    }

    /// Where generated `Fn` word `index` starts, relative to the first template line.
    pub fn word(self: Extension, index: u32) u32 {
        std.debug.assert(index < self.words);
        return @intCast(templates_length + self.headLength() + self.numeralsLength() + self.temporariesLineLength() + 1 + 3 * @as(usize, index));
    }

    /// Where numeral `number` (one the fixed line lacks) is, relative to the first template line.
    pub fn numeral(self: Extension, number: usize) [2]u32 {
        std.debug.assert(self.numerals);
        std.debug.assert(number >= fixed_numerals and number < numeral_count);
        const span = more_numerals.spans[number - fixed_numerals];
        const line: u32 = @intCast(templates_length + self.headLength() + 1);
        return .{ line + span[0], line + span[1] };
    }

    /// Where generated temporary `index` (0 names `__t32`) is, relative to the first template line.
    pub fn temporary(self: Extension, index: u32) [2]u32 {
        std.debug.assert(index < self.temporaries);
        const start: u32 = @intCast(templates_length + self.headLength() + self.numeralsLength() + 1 + temporariesLength(index));
        return .{ start, start + @as(u32, @intCast(temporary_prefix.len + digitCount(@as(u64, fixed_temporaries) + index))) };
    }
};

fn digitCount(number: u64) usize {
    var digits: usize = 1;
    var rest = number / 10;
    while (rest != 0) : (rest /= 10) digits += 1;
    return digits;
}

/// Bytes of the first `count` generated temporaries, each followed by a blank. The names of one
/// decade have one length, so this takes a step per decade rather than per name.
fn temporariesLength(count: u32) usize {
    var length: u64 = 0;
    var low: u64 = fixed_temporaries;
    const end = low + count;
    var digits = digitCount(low);
    var decade_end = std.math.pow(u64, 10, digits);
    while (low < end) : (digits += 1) {
        const high = @min(end, decade_end);
        length += (high - low) * @as(u64, temporary_prefix.len + digits + 1);
        low = high;
        decade_end *= 10;
    }
    return @intCast(length);
}

/// The prefix of the hidden raw names (RFC-0084, P4.3).
const raw_prefix = "__raw";

/// Bytes of the first `count` raw names, each followed by a blank.
fn rawsLength(count: u32) usize {
    var length: usize = 0;
    var low: u64 = 0;
    var digits: usize = 1;
    var decade_end: u64 = 10;
    while (low < count) : (digits += 1) {
        const high = @min(@as(u64, count), decade_end);
        length += @intCast((high - low) * @as(u64, raw_prefix.len + digits + 1));
        low = high;
        decade_end *= 10;
    }
    return length;
}

/// Bytes of the library block for a module that makes `calls` macro calls.
pub fn libraryLength(calls: usize, extension: Extension) usize {
    return templatesOffset(calls) + templates_length + extension.length() + 2;
}

/// Writes the library block for `calls` macro calls into `out` (which must hold `libraryLength`).
pub fn writeLibrary(out: []u8, calls: usize, extension: Extension) void {
    std.debug.assert(out.len >= libraryLength(calls, extension));
    var at: usize = 0;
    out[at] = '\n';
    out[at + 1] = '#';
    at += 2;
    for (0..fn_words_per_call * calls) |_| {
        @memcpy(out[at..][0..3], "Fn ");
        at += 3;
    }
    out[at] = '\n';
    at += 1;
    std.debug.assert(at == templatesOffset(calls));
    for (text) |template| {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..template.len], template);
        out[at + 1 + template.len] = '\n';
        at += template.len + 2;
    }
    std.debug.assert(at == templatesOffset(calls) + templates_length);
    if (extension.loops) for (for_text) |template| {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..template.len], template);
        out[at + 1 + template.len] = '\n';
        at += template.len + 2;
    };
    if (extension.cases) {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..case_text.len], case_text);
        out[at + 1 + case_text.len] = '\n';
        at += case_text.len + 2;
    }
    if (extension.numerals) {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..more_numerals.line.len], more_numerals.line);
        out[at + 1 + more_numerals.line.len] = '\n';
        at += more_numerals.line.len + 2;
    }
    if (extension.temporaries != 0) {
        out[at] = '#';
        at += 1;
        for (0..extension.temporaries) |index| {
            const name = std.fmt.bufPrint(out[at..], temporary_prefix ++ "{d} ", .{fixed_temporaries + index}) catch unreachable;
            at += name.len;
        }
        out[at] = '\n';
        at += 1;
    }
    if (extension.words != 0) {
        out[at] = '#';
        at += 1;
        for (0..extension.words) |_| {
            @memcpy(out[at..][0..3], "Fn ");
            at += 3;
        }
        out[at] = '\n';
        at += 1;
    }
    if (extension.first) for (first_text) |template| {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..template.len], template);
        out[at + 1 + template.len] = '\n';
        at += template.len + 2;
    };
    if (extension.exits) {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..exit_words.len], exit_words);
        out[at + 1 + exit_words.len] = '\n';
        at += exit_words.len + 2;
    }
    if (extension.carries) for (carry_text) |template| {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..template.len], template);
        out[at + 1 + template.len] = '\n';
        at += template.len + 2;
    };
    if (extension.sorts) for (sort_text) |template| {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..template.len], template);
        out[at + 1 + template.len] = '\n';
        at += template.len + 2;
    };
    if (extension.spawns != 0) {
        out[at] = '#';
        at += 1;
        for (0..extension.spawns) |_| {
            @memcpy(out[at..][0..spawn_word.len], spawn_word);
            at += spawn_word.len;
        }
        out[at] = '\n';
        at += 1;
    }
    if (extension.branches != 0) {
        out[at] = '#';
        at += 1;
        for (0..extension.branches) |_| {
            @memcpy(out[at..][0..branch_word.len], branch_word);
            at += branch_word.len;
        }
        out[at] = '\n';
        at += 1;
    }
    if (extension.raws != 0) {
        out[at] = '#';
        at += 1;
        for (0..extension.raws) |index| {
            const name = std.fmt.bufPrint(out[at..], raw_prefix ++ "{d} ", .{index}) catch unreachable;
            at += name.len;
        }
        out[at] = '\n';
        at += 1;
    }
    if (extension.castables) {
        out[at] = '#';
        @memcpy(out[at + 1 ..][0..castable_word.len], castable_word);
        out[at + 1 + castable_word.len] = '\n';
        at += castable_word.len + 2;
    }
    out[at] = '#';
    out[at + 1] = '}';
    at += 2;
    std.debug.assert(at == libraryLength(calls, extension));
}

/// A `Spawn` word of the last generated line, with the blank after it.
pub const spawn_word = "Spawn ";
/// RFC-0092, B4: the metatype word a `GetCastableFinalSuperClass` names its result type by,
/// written as a type is, before its argument's parenthesis.
pub const castable_word = "castable_subtype()";
/// A `Branch` word of the line after it (P3.4).
pub const branch_word = "Branch ";

/// Upper bound on the tokens of all templates together.
pub const max_tokens = 3072;

/// How many macro calls `source` may contain that need `Fn` words: each `For` or `While` directly
/// before `(` and each `Loop` directly before `{` (blanks allowed). An overcount only enlarges the
/// pool, which changes nothing else. The state loop `Loop(` is no macro and is not counted, so
/// the pool of a program without `Loop{` is what it was.
pub fn callCount(source: []const u8) usize {
    return countWord(source, "For", '(') + countWord(source, "While", '(') + countWord(source, "Loop", '{');
}

fn countWord(source: []const u8, word: []const u8, opener: u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, word)) |found| {
        at = found + word.len;
        if (found != 0 and (std.ascii.isAlphanumeric(source[found - 1]) or source[found - 1] == '_' or source[found - 1] == '.')) continue;
        var after = found + word.len;
        while (after < source.len and (source[after] == ' ' or source[after] == '\t' or source[after] == '\r')) after += 1;
        if (after < source.len and source[after] == opener) count += 1;
    }
    return count;
}

/// The words that follow a parameter of a generic function: `First[T:type](...)` is the header
/// of a program's own function, not the form of RFC-0072.
pub fn kindWord(word: []const u8) bool {
    return std.mem.eql(u8, word, "type") or std.mem.eql(u8, word, "comparable") or std.mem.eql(u8, word, "effect");
}

test "the library block lists the pool then every template and ends with a brace" {
    var out: [libraryLength(2, .{})]u8 = undefined;
    writeLibrary(&out, 2, .{});
    try std.testing.expectEqual(@as(u8, '\n'), out[0]);
    try std.testing.expectEqualStrings("Fn Fn ", out[pool_offset..][0..6]);
    const first = templatesOffset(2);
    for (text, offsets) |template, offset| {
        try std.testing.expectEqualStrings(template, out[first + offset ..][0..template.len]);
        try std.testing.expectEqual(@as(u8, '#'), out[first + offset - 1]);
    }
    try std.testing.expectEqualStrings("#}", out[out.len - 2 ..]);
}

test "callCount counts For calls and ignores other words" {
    try std.testing.expectEqual(@as(usize, 1), callCount("A:[]i64=For(X:Items,X)"));
    try std.testing.expectEqual(@as(usize, 2), callCount("A=For (X:Items,For(Y:X,Y))"));
    try std.testing.expectEqual(@as(usize, 2), callCount("While(C,B)+For(X:I,X)"));
    try std.testing.expectEqual(@as(usize, 0), callCount("Meanwhile(1)"));
    try std.testing.expectEqual(@as(usize, 0), callCount("Format(1)"));
    try std.testing.expectEqual(@as(usize, 0), callCount("A:=BeforeFor(1)"));
    try std.testing.expectEqual(@as(usize, 0), callCount("Items.For(1)"));
    try std.testing.expectEqual(@as(usize, 0), callCount("A:=For"));
    try std.testing.expectEqual(@as(usize, 0), callCount(""));
    // The brace form of `Loop` takes a word; the state loop takes none.
    try std.testing.expectEqual(@as(usize, 1), callCount("Loop{Break()}"));
    try std.testing.expectEqual(@as(usize, 2), callCount("Loop {For(X:I,X)}"));
    try std.testing.expectEqual(@as(usize, 0), callCount("Loop(Step,0)"));
    // A `First[...]` is not counted: a comment or a string that looks like one must not change
    // the pool of a module that compiled before RFC-0072. Its words are generated lines.
    try std.testing.expectEqual(@as(usize, 0), callCount("A:=First[X:Xs,X]+First [I:1..3,I] # First[X:Xs,X]"));
}

test "an extension appends the numerals and temporaries the fixed lines lack" {
    try std.testing.expectEqual(16, fixed_numerals);
    try std.testing.expectEqual(32, fixed_temporaries);
    const calls = 1;
    const plain = comptime libraryLength(calls, .{});
    const first = templatesOffset(calls);
    const largest: Extension = .{ .numerals = true, .temporaries = 969, .words = 7 };
    // Counts on both sides of a change of decade, where a name gets longer.
    for ([_]Extension{ .{ .numerals = true }, .{ .temporaries = 1 }, .{ .temporaries = 68 }, .{ .temporaries = 69 }, .{ .words = 1 }, .{ .temporaries = 3, .words = 5 }, largest }) |extension| {
        var out: [libraryLength(calls, largest)]u8 = undefined;
        const block = out[0..libraryLength(calls, extension)];
        writeLibrary(block, calls, extension);
        // The fixed part is the block of a module without an extension.
        var fixed: [plain]u8 = undefined;
        writeLibrary(&fixed, calls, .{});
        try std.testing.expectEqualStrings(fixed[0 .. plain - 2], block[0 .. plain - 2]);
        try std.testing.expectEqualStrings("#}", block[block.len - 2 ..]);
        if (extension.numerals) {
            for (fixed_numerals..numeral_count) |number| {
                const span = extension.numeral(number);
                try std.testing.expectEqual(number, try std.fmt.parseInt(usize, block[first + span[0] .. first + span[1]], 10));
                try std.testing.expect(!std.ascii.isDigit(block[first + span[0] - 1]) and !std.ascii.isDigit(block[first + span[1]]));
            }
        }
        var name: [16]u8 = undefined;
        for (0..extension.temporaries) |index| {
            const span = extension.temporary(@intCast(index));
            const expected = try std.fmt.bufPrint(&name, "__t{d}", .{fixed_temporaries + index});
            try std.testing.expectEqualStrings(expected, block[first + span[0] .. first + span[1]]);
            try std.testing.expectEqual(@as(u8, ' '), block[first + span[1]]);
        }
        for (0..extension.words) |index| {
            const start = first + extension.word(@intCast(index));
            try std.testing.expectEqualStrings("Fn ", block[start..][0..3]);
        }
        try std.testing.expectEqual(@as(u32, fn_words_per_call * calls), pooledWords(@intCast(first)));
        // Every generated line is a comment line, so the lexer skips it.
        var lines = std.mem.splitScalar(u8, block[1..], '\n');
        while (lines.next()) |line| try std.testing.expectEqual(@as(u8, '#'), line[0]);
    }
}

test "the First templates are lines of their own at the end, and a block without them is unchanged" {
    // The block of a module that uses no form of RFC-0072, as it was before that RFC: its
    // length is what programs near the source limit depend on. That was with the general `For`
    // templates and the `Case` words in it, which only a module using those forms has now.
    try std.testing.expectEqual(@as(usize, 3176), libraryLength(1, .{ .loops = true, .cases = true }));
    try std.testing.expectEqual(@as(usize, 3176 + 9), libraryLength(2, .{ .loops = true, .cases = true }));
    const calls = 1;
    const start = templatesOffset(calls);
    for ([_]Extension{ .{ .first = true }, .{ .first = true, .words = 4 }, .{ .first = true, .numerals = true, .temporaries = 70, .words = 9 } }) |extension| {
        var without = extension;
        without.first = false;
        var out: [8192]u8 = undefined;
        const block = out[0..libraryLength(calls, extension)];
        writeLibrary(block, calls, extension);
        var before: [8192]u8 = undefined;
        const plain = before[0..libraryLength(calls, without)];
        writeLibrary(plain, calls, without);
        // Everything the block had stays where it was; the new lines come last.
        try std.testing.expectEqualStrings(plain[0 .. plain.len - 2], block[0 .. plain.len - 2]);
        try std.testing.expectEqual(plain.len + first_length, block.len);
        try std.testing.expectEqualStrings("#}", block[block.len - 2 ..]);
        for (first_text, 0..) |template, index| {
            const at = start + extension.offset(@fromBackingInt(@as(@typeInfo(Template).@"enum".tag_type, @intCast(first_base + index))));
            try std.testing.expectEqualStrings(template, block[at..][0..template.len]);
            try std.testing.expectEqual(@as(u8, '#'), block[at - 1]);
        }
        try std.testing.expectEqual(offsets[@backingInt(Template.not_test)], extension.offset(.not_test));
        try std.testing.expect(extension.exceeds(without) and !without.exceeds(extension) and without.merged(extension).first);
        var lines = std.mem.splitScalar(u8, block[1..], '\n');
        while (lines.next()) |line| try std.testing.expectEqual(@as(u8, '#'), line[0]);
    }
}

test "the exit words are the last generated line and cost a module without them nothing" {
    const calls = 2;
    // The block of a module that uses none of RFC-0068 is what it was: its length is that of the
    // pool, the templates up to `not_test` and the closing line, and nothing else.
    try std.testing.expectEqual(Template.not_test, std.enums.values(Template)[text.len - 1]);
    var expected: usize = 2 + 3 * fn_words_per_call * calls + 1 + 2;
    for (text) |template| expected += template.len + 2;
    try std.testing.expectEqual(expected, libraryLength(calls, .{}));
    for (text) |template| try std.testing.expect(std.mem.indexOf(u8, template, "__exit") == null);
    // With the words, everything before them stays where it was.
    for ([_]Extension{ .{}, .{ .numerals = true, .temporaries = 5, .words = 4 }, .{ .first = true }, .{ .first = true, .temporaries = 40, .words = 2 } }) |before| {
        var with = before;
        with.exits = true;
        var old: [16384]u8 = undefined;
        var new: [16384]u8 = undefined;
        const old_block = old[0..libraryLength(calls, before)];
        const new_block = new[0..libraryLength(calls, with)];
        writeLibrary(old_block, calls, before);
        writeLibrary(new_block, calls, with);
        try std.testing.expectEqual(old_block.len + exit_words.len + 2, new_block.len);
        try std.testing.expectEqualStrings(old_block[0 .. old_block.len - 2], new_block[0 .. old_block.len - 2]);
        const start = templatesOffset(calls) + with.exitWords();
        try std.testing.expectEqualStrings(exit_words, new_block[start..][0..exit_words.len]);
        try std.testing.expectEqual(@as(u8, '#'), new_block[start - 1]);
        try std.testing.expectEqualStrings("\n#}", new_block[new_block.len - 3 ..]);
        if (before.words != 0) try std.testing.expectEqual(before.word(before.words - 1), with.word(before.words - 1));
        // The `First` lines of a module that has both are where they are without the exit words.
        if (before.first) try std.testing.expectEqual(before.offset(.first_inner), with.offset(.first_inner));
        try std.testing.expect(with.exceeds(before) and !before.exceeds(with) and before.merged(with).exits);
    }
}

test "extensions compare and merge by line" {
    const numerals: Extension = .{ .numerals = true };
    const names: Extension = .{ .temporaries = 4 };
    try std.testing.expect(numerals.exceeds(.{}) and names.exceeds(.{}) and names.exceeds(numerals));
    try std.testing.expect(!numerals.exceeds(numerals) and !names.exceeds(.{ .temporaries = 4 }));
    const both = numerals.merged(names);
    try std.testing.expect(both.numerals and both.temporaries == 4);
    try std.testing.expect(!numerals.exceeds(both) and !names.exceeds(both));
    const words: Extension = .{ .words = 2 };
    try std.testing.expect(words.exceeds(both) and !words.exceeds(both.merged(words)) and both.merged(words).temporaries == 4);
}

fn expectBlock(calls: usize, extension: Extension, length: usize, digest: []const u8) !void {
    var out: [8192]u8 = undefined;
    const block = out[0..libraryLength(calls, extension)];
    writeLibrary(block, calls, extension);
    try std.testing.expectEqual(length, block.len);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(block, &hash, .{});
    try std.testing.expectEqualStrings(digest, &std.fmt.bytesToHex(hash, .lower));
}

test "a block without the general For and Case lines is the block of before RFC-0064, byte for byte" {
    // Lengths and SHA-256 of the blocks the tree had before RFC-0064 (its table ended with the
    // `not_test` template), computed from that tree's text.
    try expectBlock(0, .{}, 2207, "14f0c87c7056c015348660839c6457bc3ccb4c71f5f7ee0a0ab2ae4256aaea3f");
    try expectBlock(1, .{}, 2216, "b8b2a072ac54bc78cb48bf954d7b6242bb0dfa5e75eadbcd609316f38187eb17");
    try expectBlock(2, .{}, 2225, "03b9a4709ef0f97618a2761b4509f0703f739eda9fd119ad09b1e1f9e82df22a");
    // And with both, the block every module had between RFC-0066 and this change.
    const both: Extension = .{ .loops = true, .cases = true };
    try expectBlock(0, both, 3167, "e1fea4afb0f7ac91c619b5f1811d28980a222c5a0d087cbe74e1fa8ce6c5313e");
    try expectBlock(1, both, 3176, "e83a1625b6b9c4e722bb5082a8c719c7c314ad8cb7af10120d7c71cb7389fe82");
    try expectBlock(2, both, 3185, "63d33a188adbdd669711187606da59d227f5fcd3e4241e5d682dd0ed94231ce2");
    try std.testing.expectEqual(Template.not_test, std.enums.values(Template)[text.len - 1]);
}

test "the general For and Case lines follow the fixed ones and every other generated line follows them" {
    const calls = 2;
    const start = templatesOffset(calls);
    const rest: Extension = .{ .numerals = true, .temporaries = 70, .words = 9, .first = true, .exits = true };
    for ([_]Extension{ .{ .loops = true }, .{ .cases = true }, .{ .loops = true, .cases = true } }) |head| {
        for ([_]Extension{ .{}, .{ .words = 3 }, .{ .first = true }, .{ .exits = true }, rest }) |tail| {
            const extension = head.merged(tail);
            var out: [16384]u8 = undefined;
            var plain_out: [16384]u8 = undefined;
            const block = out[0..libraryLength(calls, extension)];
            const plain = plain_out[0..libraryLength(calls, tail)];
            writeLibrary(block, calls, extension);
            writeLibrary(plain, calls, tail);
            const fixed = start + templates_length;
            const added = block.len - plain.len;
            try std.testing.expectEqual(head.headLength(), added);
            // The fixed lines are untouched and the lines of `tail` are those of a block
            // without the head, moved as one piece.
            try std.testing.expectEqualStrings(plain[0..fixed], block[0..fixed]);
            try std.testing.expectEqualStrings(plain[fixed..], block[fixed + added ..]);
            if (head.loops) for (for_text, 0..) |template, index| {
                const at = start + extension.offset(@fromBackingInt(@as(@typeInfo(Template).@"enum".tag_type, @intCast(text.len + index))));
                try std.testing.expectEqualStrings(template, block[at..][0..template.len]);
                try std.testing.expectEqual(@as(u8, '#'), block[at - 1]);
                // Where the template stood while it was part of every block.
                try std.testing.expectEqual(templates_length + for_offsets[index], extension.offset(@fromBackingInt(@as(@typeInfo(Template).@"enum".tag_type, @intCast(text.len + index)))));
            };
            if (head.cases) {
                const at = start + extension.offset(.case_words);
                try std.testing.expectEqualStrings("#" ++ case_text ++ "\n", block[at - 1 ..][0 .. case_text.len + 2]);
            }
            // Every generated word, numeral, temporary and template is found where its
            // accessor says, whatever the head.
            for (0..tail.words) |index| try std.testing.expectEqualStrings("Fn ", block[start + extension.word(@intCast(index)) ..][0..3]);
            if (tail.words != 0) try std.testing.expectEqual(tail.word(0) + added, extension.word(0));
            if (tail.numerals) {
                const span = extension.numeral(fixed_numerals);
                try std.testing.expectEqualStrings("16", block[start + span[0] .. start + span[1]]);
            }
            if (tail.temporaries != 0) {
                const span = extension.temporary(0);
                try std.testing.expectEqualStrings("__t32", block[start + span[0] .. start + span[1]]);
            }
            if (tail.first) {
                const at = start + extension.offset(.first_inner);
                try std.testing.expectEqualStrings(first_text[first_text.len - 1], block[at..][0..first_text[first_text.len - 1].len]);
            }
            if (tail.exits) try std.testing.expectEqualStrings(exit_words, block[start + extension.exitWords() ..][0..exit_words.len]);
            try std.testing.expect(extension.exceeds(tail) and !tail.exceeds(extension));
            var lines = std.mem.splitScalar(u8, block[1..], '\n');
            while (lines.next()) |line| try std.testing.expectEqual(@as(u8, '#'), line[0]);
        }
    }
}

test "the carrying For templates are the last lines and cost a module without them nothing" {
    const calls = 1;
    const start = templatesOffset(calls);
    for ([_]Extension{ .{ .loops = true }, .{ .loops = true, .words = 5, .exits = true }, .{ .loops = true, .cases = true, .numerals = true, .temporaries = 40, .words = 2, .first = true, .exits = true } }) |before| {
        var with = before;
        with.carries = true;
        var old: [16384]u8 = undefined;
        var new: [16384]u8 = undefined;
        const old_block = old[0..libraryLength(calls, before)];
        const new_block = new[0..libraryLength(calls, with)];
        writeLibrary(old_block, calls, before);
        writeLibrary(new_block, calls, with);
        try std.testing.expectEqual(old_block.len + carry_length, new_block.len);
        try std.testing.expectEqualStrings(old_block[0 .. old_block.len - 2], new_block[0 .. old_block.len - 2]);
        try std.testing.expectEqualStrings("\n#}", new_block[new_block.len - 3 ..]);
        for (carry_text, 0..) |template, index| {
            const at = start + with.offset(@fromBackingInt(@as(@typeInfo(Template).@"enum".tag_type, @intCast(carry_base + index))));
            try std.testing.expectEqualStrings(template, new_block[at..][0..template.len]);
            try std.testing.expectEqual(@as(u8, '#'), new_block[at - 1]);
        }
        if (before.exits) try std.testing.expectEqual(before.exitWords(), with.exitWords());
        if (before.first) try std.testing.expectEqual(before.offset(.first_inner), with.offset(.first_inner));
        try std.testing.expectEqual(before.offset(.for_yield), with.offset(.for_yield));
        try std.testing.expect(with.exceeds(before) and !before.exceeds(with) and before.merged(with).carries);
        var lines = std.mem.splitScalar(u8, new_block[1..], '\n');
        while (lines.next()) |line| try std.testing.expectEqual(@as(u8, '#'), line[0]);
    }
}

test "the SortBy line is the last generated line and costs a module without it nothing" {
    const calls = 1;
    const start = templatesOffset(calls);
    for ([_]Extension{ .{}, .{ .words = 5 }, .{ .loops = true, .cases = true, .numerals = true, .temporaries = 40, .words = 2, .first = true, .exits = true, .carries = true } }) |before| {
        var with = before;
        with.sorts = true;
        var old: [16384]u8 = undefined;
        var new: [16384]u8 = undefined;
        const old_block = old[0..libraryLength(calls, before)];
        const new_block = new[0..libraryLength(calls, with)];
        writeLibrary(old_block, calls, before);
        writeLibrary(new_block, calls, with);
        try std.testing.expectEqual(old_block.len + sort_length, new_block.len);
        try std.testing.expectEqualStrings(old_block[0 .. old_block.len - 2], new_block[0 .. old_block.len - 2]);
        try std.testing.expectEqualStrings("\n#}", new_block[new_block.len - 3 ..]);
        const at = start + with.offset(.sort_by);
        try std.testing.expectEqualStrings(sort_text[0], new_block[at..][0..sort_text[0].len]);
        try std.testing.expectEqual(@as(u8, '#'), new_block[at - 1]);
        if (before.exits) try std.testing.expectEqual(before.exitWords(), with.exitWords());
        if (before.carries) try std.testing.expectEqual(before.offset(.for_carry_range), with.offset(.for_carry_range));
        if (before.words != 0) try std.testing.expectEqual(before.word(before.words - 1), with.word(before.words - 1));
        try std.testing.expect(with.exceeds(before) and !before.exceeds(with) and before.merged(with).sorts);
        var lines = std.mem.splitScalar(u8, new_block[1..], '\n');
        while (lines.next()) |line| try std.testing.expectEqual(@as(u8, '#'), line[0]);
    }
}

test "the castable line is the last generated line and costs a module without it nothing" {
    const calls = 1;
    const start = templatesOffset(calls);
    for ([_]Extension{ .{}, .{ .words = 5 }, .{ .loops = true, .cases = true, .numerals = true, .temporaries = 40, .words = 2, .first = true, .exits = true, .carries = true, .sorts = true, .spawns = 2, .branches = 1, .raws = 3 } }) |before| {
        var with = before;
        with.castables = true;
        var old: [16384]u8 = undefined;
        var new: [16384]u8 = undefined;
        const old_block = old[0..libraryLength(calls, before)];
        const new_block = new[0..libraryLength(calls, with)];
        writeLibrary(old_block, calls, before);
        writeLibrary(new_block, calls, with);
        try std.testing.expectEqual(old_block.len + castable_word.len + 2, new_block.len);
        try std.testing.expectEqualStrings(old_block[0 .. old_block.len - 2], new_block[0 .. old_block.len - 2]);
        try std.testing.expectEqualStrings("\n#}", new_block[new_block.len - 3 ..]);
        const at = start + with.castableWord();
        try std.testing.expectEqualStrings(castable_word, new_block[at..][0..castable_word.len]);
        try std.testing.expectEqual(@as(u8, '#'), new_block[at - 1]);
        if (before.raws != 0) try std.testing.expectEqual(before.rawWord(before.raws - 1), with.rawWord(before.raws - 1));
        try std.testing.expect(with.exceeds(before) and !before.exceeds(with) and before.merged(with).castables);
    }
}
