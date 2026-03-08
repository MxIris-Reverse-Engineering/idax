# Ctree API Extension — Full StatementView + Handle-Based C Shim

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose full ctree sub-structure navigation (if/for/while/do/switch/block/return branches, conditions, bodies) through the C++ `StatementView`, the C shim, and the Swift binding layer.

**Architecture:** Three-layer extension: (1) Add sub-structure navigation methods to C++ `StatementView` (condition, branches, body, init/step, block children, switch cases, expression). (2) Add handle-based C query functions to `idax_shim` that take opaque `void*` ctree handles and return child handles/values — matching the existing microcode context pattern. (3) Add a new `visitCtree` API to the C shim that passes opaque handles instead of flat info structs, plus per-handle query functions. The new visitor callback will pass opaque expression/statement handles; consumers call query functions to inspect them during the callback.

**Tech Stack:** C++23, C ABI (idax_shim), Swift 6.0

---

## Summary of SDK ctree structures

```
cinsn_t (statement) — union of:
  cblock_t  *cblock   → qlist<cinsn_t>   (block children)
  cexpr_t   *cexpr    → expression        (expr-stmt)
  cif_t     *cif      → {expr, ithen, ielse}
  cfor_t    *cfor     → {expr, init, step, body}
  cwhile_t  *cwhile   → {expr, body}
  cdo_t     *cdo      → {expr, body}
  cswitch_t *cswitch  → {expr, cases[{values, cinsn_t}]}
  creturn_t *creturn  → {expr}
  cgoto_t   *cgoto    → {label_num}
  casm_t    *casm     → eavec_t
  ctry_t    *ctry     → cblock_t + catchs
  cthrow_t  *cthrow   → {expr}

ceinsn_t base → { cexpr_t expr }  (condition/init/step/return expression)
cloop_t  base → ceinsn_t + { cinsn_t* body }
```

---

### Task 1: Extend C++ StatementView — sub-structure navigation

**Files:**
- Modify: `include/ida/decompiler.hpp:951-968`
- Modify: `src/decompiler.cpp:3496-3514`

**Step 1: Add method declarations to StatementView in the header**

In `include/ida/decompiler.hpp`, insert after line 960 (`goto_target_label`) and before the `// ── Internal` comment at line 962:

```cpp
    // ── Sub-structure navigation ──────────────────────────────────────

    /// For if/for/while/do/switch/return/throw: the condition or value expression.
    /// - if → condition
    /// - for → condition (loop test)
    /// - while → condition
    /// - do → condition
    /// - switch → switch expression
    /// - return → return value expression
    /// - throw → thrown expression
    [[nodiscard]] Result<ExpressionView> condition() const;

    /// For StmtIf: the then-branch statement.
    [[nodiscard]] Result<StatementView> then_branch() const;

    /// For StmtIf: the else-branch statement (error if no else).
    [[nodiscard]] Result<StatementView> else_branch() const;

    /// For StmtIf: whether an else-branch exists.
    [[nodiscard]] bool has_else_branch() const noexcept;

    /// For StmtFor/StmtWhile/StmtDo: the loop body statement.
    [[nodiscard]] Result<StatementView> body() const;

    /// For StmtFor: the initialization expression.
    [[nodiscard]] Result<ExpressionView> init_expression() const;

    /// For StmtFor: the step (increment) expression.
    [[nodiscard]] Result<ExpressionView> step_expression() const;

    /// For StmtExpr: the expression in this expression-statement.
    [[nodiscard]] Result<ExpressionView> expression() const;

    /// For StmtBlock: the number of child statements.
    [[nodiscard]] Result<std::size_t> block_size() const;

    /// For StmtBlock: get the child statement at the given index.
    [[nodiscard]] Result<StatementView> block_statement(std::size_t index) const;

    /// For StmtSwitch: the number of cases (including default).
    [[nodiscard]] Result<std::size_t> switch_case_count() const;

    /// For StmtSwitch: the case values at the given index (empty = default).
    [[nodiscard]] Result<std::vector<std::uint64_t>> switch_case_values(std::size_t index) const;

    /// For StmtSwitch: the case body statement at the given index.
    [[nodiscard]] Result<StatementView> switch_case_body(std::size_t index) const;
```

**Step 2: Implement the methods in decompiler.cpp**

In `src/decompiler.cpp`, insert after the `goto_target_label()` implementation (after line 3514) and before the `CtreeVisitor` default implementations:

```cpp
Result<ExpressionView> StatementView::condition() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    switch (s->op) {
        case cit_if:
            if (s->cif == nullptr)
                return std::unexpected(Error::internal("null if details"));
            return ExpressionView(ExpressionView::Tag{}, &s->cif->expr);
        case cit_for:
            if (s->cfor == nullptr)
                return std::unexpected(Error::internal("null for details"));
            return ExpressionView(ExpressionView::Tag{}, &s->cfor->expr);
        case cit_while:
            if (s->cwhile == nullptr)
                return std::unexpected(Error::internal("null while details"));
            return ExpressionView(ExpressionView::Tag{}, &s->cwhile->expr);
        case cit_do:
            if (s->cdo == nullptr)
                return std::unexpected(Error::internal("null do details"));
            return ExpressionView(ExpressionView::Tag{}, &s->cdo->expr);
        case cit_switch:
            if (s->cswitch == nullptr)
                return std::unexpected(Error::internal("null switch details"));
            return ExpressionView(ExpressionView::Tag{}, &s->cswitch->expr);
        case cit_return:
            if (s->creturn == nullptr)
                return std::unexpected(Error::internal("null return details"));
            return ExpressionView(ExpressionView::Tag{}, &s->creturn->expr);
        case cit_throw:
            if (s->cthrow == nullptr)
                return std::unexpected(Error::internal("null throw details"));
            return ExpressionView(ExpressionView::Tag{}, &s->cthrow->expr);
        default:
            return std::unexpected(Error::validation("Statement type does not have a condition expression"));
    }
}

Result<StatementView> StatementView::then_branch() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_if || s->cif == nullptr)
        return std::unexpected(Error::validation("Statement is not an if"));
    if (s->cif->ithen == nullptr)
        return std::unexpected(Error::internal("null then-branch"));
    return StatementView(StatementView::Tag{}, s->cif->ithen);
}

Result<StatementView> StatementView::else_branch() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_if || s->cif == nullptr)
        return std::unexpected(Error::validation("Statement is not an if"));
    if (s->cif->ielse == nullptr)
        return std::unexpected(Error::validation("If statement has no else-branch"));
    return StatementView(StatementView::Tag{}, s->cif->ielse);
}

bool StatementView::has_else_branch() const noexcept {
    if (!raw_) return false;
    auto* s = static_cast<cinsn_t*>(raw_);
    return s->op == cit_if && s->cif != nullptr && s->cif->ielse != nullptr;
}

Result<StatementView> StatementView::body() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    switch (s->op) {
        case cit_for:
            if (s->cfor == nullptr || s->cfor->body == nullptr)
                return std::unexpected(Error::internal("null for-loop body"));
            return StatementView(StatementView::Tag{}, s->cfor->body);
        case cit_while:
            if (s->cwhile == nullptr || s->cwhile->body == nullptr)
                return std::unexpected(Error::internal("null while-loop body"));
            return StatementView(StatementView::Tag{}, s->cwhile->body);
        case cit_do:
            if (s->cdo == nullptr || s->cdo->body == nullptr)
                return std::unexpected(Error::internal("null do-loop body"));
            return StatementView(StatementView::Tag{}, s->cdo->body);
        default:
            return std::unexpected(Error::validation("Statement is not a loop"));
    }
}

Result<ExpressionView> StatementView::init_expression() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_for || s->cfor == nullptr)
        return std::unexpected(Error::validation("Statement is not a for-loop"));
    return ExpressionView(ExpressionView::Tag{}, &s->cfor->init);
}

Result<ExpressionView> StatementView::step_expression() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_for || s->cfor == nullptr)
        return std::unexpected(Error::validation("Statement is not a for-loop"));
    return ExpressionView(ExpressionView::Tag{}, &s->cfor->step);
}

Result<ExpressionView> StatementView::expression() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_expr || s->cexpr == nullptr)
        return std::unexpected(Error::validation("Statement is not an expression-statement"));
    return ExpressionView(ExpressionView::Tag{}, s->cexpr);
}

Result<std::size_t> StatementView::block_size() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_block || s->cblock == nullptr)
        return std::unexpected(Error::validation("Statement is not a block"));
    return static_cast<std::size_t>(s->cblock->size());
}

Result<StatementView> StatementView::block_statement(std::size_t index) const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_block || s->cblock == nullptr)
        return std::unexpected(Error::validation("Statement is not a block"));
    if (index >= static_cast<std::size_t>(s->cblock->size()))
        return std::unexpected(Error::validation("Block statement index out of range"));
    auto it = s->cblock->begin();
    std::advance(it, index);
    return StatementView(StatementView::Tag{}, &*it);
}

Result<std::size_t> StatementView::switch_case_count() const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_switch || s->cswitch == nullptr)
        return std::unexpected(Error::validation("Statement is not a switch"));
    return static_cast<std::size_t>(s->cswitch->cases.size());
}

Result<std::vector<std::uint64_t>> StatementView::switch_case_values(std::size_t index) const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_switch || s->cswitch == nullptr)
        return std::unexpected(Error::validation("Statement is not a switch"));
    if (index >= static_cast<std::size_t>(s->cswitch->cases.size()))
        return std::unexpected(Error::validation("Switch case index out of range"));
    const auto& cc = s->cswitch->cases[index];
    std::vector<std::uint64_t> vals;
    vals.reserve(cc.values.size());
    for (std::size_t i = 0; i < cc.values.size(); ++i)
        vals.push_back(cc.values[i]);
    return vals;
}

Result<StatementView> StatementView::switch_case_body(std::size_t index) const {
    if (!raw_) return std::unexpected(Error::internal("null statement"));
    auto* s = static_cast<cinsn_t*>(raw_);
    if (s->op != cit_switch || s->cswitch == nullptr)
        return std::unexpected(Error::validation("Statement is not a switch"));
    if (index >= static_cast<std::size_t>(s->cswitch->cases.size()))
        return std::unexpected(Error::validation("Switch case index out of range"));
    // ccase_t inherits from cinsn_t, so we can treat it as a statement
    return StatementView(StatementView::Tag{}, &s->cswitch->cases[index]);
}
```

**Step 3: Build the C++ library to verify compilation**

Run: `cmake --build bindings/swift/.cmake-build --target idax 2>&1 | tail -5`
Expected: `[100%] Built target idax`

**Step 4: Commit**

```bash
git add include/ida/decompiler.hpp src/decompiler.cpp
git commit -m "feat(decompiler): extend StatementView with full ctree sub-structure navigation"
```

---

### Task 2: Add handle-based ctree query C functions to shim header

**Files:**
- Modify: `bindings/rust/idax-sys/shim/idax_shim.h:1373` (after `idax_decompiler_for_each_item`)

**Step 1: Add ctree handle types, visitor callback types, and query function declarations**

Insert after line 1373 in `idax_shim.h` (after the existing `for_each_item` declaration), before the `/* Microcode filter support */` comment:

```c
/* ── Ctree handle-based API ──────────────────────────────────────────── */

/** Opaque ctree expression handle. Valid only during visitor callback. */
typedef const void* IdaxCtreeExprHandle;
/** Opaque ctree statement handle. Valid only during visitor callback. */
typedef const void* IdaxCtreeStmtHandle;

/** Visitor callback receiving an opaque expression handle.
 *  Return: 0=Continue, 1=Stop, 2=SkipChildren */
typedef int (*IdaxCtreeExprVisitor)(void* context, IdaxCtreeExprHandle expr);
/** Visitor callback receiving an opaque statement handle.
 *  Return: 0=Continue, 1=Stop, 2=SkipChildren */
typedef int (*IdaxCtreeStmtVisitor)(void* context, IdaxCtreeStmtHandle stmt);

/** Visit all ctree items with opaque handles.
 *  Set expr_cb or stmt_cb to NULL to skip that item type. */
int idax_ctree_visit(IdaxDecompiledHandle handle,
                     IdaxCtreeExprVisitor expr_cb,
                     IdaxCtreeStmtVisitor stmt_cb,
                     void* context,
                     int post_order,
                     int* out_visited);

/* ── Expression query functions ──────────────────────────────────────── */

int idax_ctree_expr_type(IdaxCtreeExprHandle expr, int* out);
int idax_ctree_expr_address(IdaxCtreeExprHandle expr, uint64_t* out);
int idax_ctree_expr_number_value(IdaxCtreeExprHandle expr, uint64_t* out);
int idax_ctree_expr_string_value(IdaxCtreeExprHandle expr, char** out);
int idax_ctree_expr_object_address(IdaxCtreeExprHandle expr, uint64_t* out);
int idax_ctree_expr_variable_index(IdaxCtreeExprHandle expr, int* out);
int idax_ctree_expr_operand_count(IdaxCtreeExprHandle expr, int* out);
int idax_ctree_expr_left(IdaxCtreeExprHandle expr, IdaxCtreeExprHandle* out);
int idax_ctree_expr_right(IdaxCtreeExprHandle expr, IdaxCtreeExprHandle* out);
int idax_ctree_expr_call_argument_count(IdaxCtreeExprHandle expr, size_t* out);
int idax_ctree_expr_call_callee(IdaxCtreeExprHandle expr, IdaxCtreeExprHandle* out);
int idax_ctree_expr_call_argument(IdaxCtreeExprHandle expr, size_t index,
                                  IdaxCtreeExprHandle* out);
int idax_ctree_expr_member_offset(IdaxCtreeExprHandle expr, uint32_t* out);
int idax_ctree_expr_to_string(IdaxCtreeExprHandle expr, char** out);

/* ── Statement query functions ───────────────────────────────────────── */

int idax_ctree_stmt_type(IdaxCtreeStmtHandle stmt, int* out);
int idax_ctree_stmt_address(IdaxCtreeStmtHandle stmt, uint64_t* out);
int idax_ctree_stmt_goto_target_label(IdaxCtreeStmtHandle stmt, int* out);

/** For if/for/while/do/switch/return/throw: the condition or value expression. */
int idax_ctree_stmt_condition(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out);
/** For if: the then-branch. */
int idax_ctree_stmt_then_branch(IdaxCtreeStmtHandle stmt, IdaxCtreeStmtHandle* out);
/** For if: the else-branch. Returns error if no else. */
int idax_ctree_stmt_else_branch(IdaxCtreeStmtHandle stmt, IdaxCtreeStmtHandle* out);
/** For if: whether an else-branch exists. */
int idax_ctree_stmt_has_else_branch(IdaxCtreeStmtHandle stmt, int* out);
/** For for/while/do: the loop body. */
int idax_ctree_stmt_body(IdaxCtreeStmtHandle stmt, IdaxCtreeStmtHandle* out);
/** For for: the init expression. */
int idax_ctree_stmt_init_expression(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out);
/** For for: the step expression. */
int idax_ctree_stmt_step_expression(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out);
/** For expr-stmt: the expression. */
int idax_ctree_stmt_expression(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out);
/** For block: number of child statements. */
int idax_ctree_stmt_block_size(IdaxCtreeStmtHandle stmt, size_t* out);
/** For block: child statement at index. */
int idax_ctree_stmt_block_statement(IdaxCtreeStmtHandle stmt, size_t index,
                                    IdaxCtreeStmtHandle* out);
/** For switch: number of cases (including default). */
int idax_ctree_stmt_switch_case_count(IdaxCtreeStmtHandle stmt, size_t* out);
/** For switch: case values at index (empty values = default case). */
int idax_ctree_stmt_switch_case_values(IdaxCtreeStmtHandle stmt, size_t index,
                                       uint64_t** out, size_t* count);
/** For switch: case body statement at index. */
int idax_ctree_stmt_switch_case_body(IdaxCtreeStmtHandle stmt, size_t index,
                                     IdaxCtreeStmtHandle* out);
void idax_ctree_switch_case_values_free(uint64_t* values);
```

**Step 2: Copy the updated header to Swift CIDA module**

Run: `cp bindings/rust/idax-sys/shim/idax_shim.h bindings/swift/Sources/CIDA/include/idax_shim.h`

**Step 3: Commit**

```bash
git add bindings/rust/idax-sys/shim/idax_shim.h bindings/swift/Sources/CIDA/include/idax_shim.h
git commit -m "feat(shim): declare handle-based ctree query API in idax_shim.h"
```

---

### Task 3: Implement handle-based ctree functions in shim .cpp

**Files:**
- Modify: `bindings/rust/idax-sys/shim/idax_shim.cpp` (after `idax_decompiler_for_each_item` at ~line 4971, before microcode filter section)

**Step 1: Implement `idax_ctree_visit`**

Insert after the `idax_decompiler_for_each_item` function (line ~4971):

```cpp
// ── Ctree handle-based API ──────────────────────────────────────────────

int idax_ctree_visit(IdaxDecompiledHandle handle,
                     IdaxCtreeExprVisitor expr_cb,
                     IdaxCtreeStmtVisitor stmt_cb,
                     void* context,
                     int post_order,
                     int* out_visited) {
    clear_error();
    if (expr_cb == nullptr && stmt_cb == nullptr)
        return fail(ida::Error::validation("at least one ctree visitor callback is required"));

    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    ida::decompiler::VisitOptions opts;
    opts.post_order = (post_order != 0);

    class Visitor : public ida::decompiler::CtreeVisitor {
    public:
        IdaxCtreeExprVisitor expr_cb_;
        IdaxCtreeStmtVisitor stmt_cb_;
        void* ctx_;

        Visitor(IdaxCtreeExprVisitor ec, IdaxCtreeStmtVisitor sc, void* c)
            : expr_cb_(ec), stmt_cb_(sc), ctx_(c) {}

        ida::decompiler::VisitAction visit_expression(ida::decompiler::ExpressionView expr) override {
            if (expr_cb_ == nullptr)
                return ida::decompiler::VisitAction::Continue;
            return visit_action_from_c_int(expr_cb_(ctx_, expr.raw_handle()));
        }
        ida::decompiler::VisitAction visit_statement(ida::decompiler::StatementView stmt) override {
            if (stmt_cb_ == nullptr)
                return ida::decompiler::VisitAction::Continue;
            return visit_action_from_c_int(stmt_cb_(ctx_, stmt.raw_handle()));
        }
    };

    Visitor visitor(expr_cb, stmt_cb, context);
    auto result = df->visit(visitor, opts);
    if (!result) return fail(result.error());
    *out_visited = *result;
    return 0;
}
```

**Important:** This requires adding a `raw_handle()` accessor to both `ExpressionView` and `StatementView`. Add to the header after each class's `Tag` constructor:

In `ExpressionView` (line ~942, after `explicit ExpressionView(Tag, void* raw)`):
```cpp
    /// Return the opaque raw pointer for C interop (valid only during visitor lifetime).
    [[nodiscard]] const void* raw_handle() const noexcept { return raw_; }
```

In `StatementView` (line ~964, after `explicit StatementView(Tag, void* raw)`):
```cpp
    /// Return the opaque raw pointer for C interop (valid only during visitor lifetime).
    [[nodiscard]] const void* raw_handle() const noexcept { return raw_; }
```

**Step 2: Implement expression query functions**

```cpp
// ── Expression query functions ──────────────────────────────────────────

int idax_ctree_expr_type(IdaxCtreeExprHandle expr, int* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    *out = static_cast<int>(ev.type());
    return 0;
}

int idax_ctree_expr_address(IdaxCtreeExprHandle expr, uint64_t* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    *out = ev.address();
    return 0;
}

int idax_ctree_expr_number_value(IdaxCtreeExprHandle expr, uint64_t* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.number_value();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_expr_string_value(IdaxCtreeExprHandle expr, char** out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.string_value();
    if (!r) return fail(r.error());
    *out = dup_string(*r);
    return 0;
}

int idax_ctree_expr_object_address(IdaxCtreeExprHandle expr, uint64_t* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.object_address();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_expr_variable_index(IdaxCtreeExprHandle expr, int* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.variable_index();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_expr_operand_count(IdaxCtreeExprHandle expr, int* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    *out = ev.operand_count();
    return 0;
}

int idax_ctree_expr_left(IdaxCtreeExprHandle expr, IdaxCtreeExprHandle* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.left();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_expr_right(IdaxCtreeExprHandle expr, IdaxCtreeExprHandle* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.right();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_expr_call_argument_count(IdaxCtreeExprHandle expr, size_t* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.call_argument_count();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_expr_call_callee(IdaxCtreeExprHandle expr, IdaxCtreeExprHandle* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.call_callee();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_expr_call_argument(IdaxCtreeExprHandle expr, size_t index,
                                  IdaxCtreeExprHandle* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.call_argument(index);
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_expr_member_offset(IdaxCtreeExprHandle expr, uint32_t* out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.member_offset();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_expr_to_string(IdaxCtreeExprHandle expr, char** out) {
    clear_error();
    auto ev = ida::decompiler::ExpressionView(
        ida::decompiler::ExpressionView::Tag{}, const_cast<void*>(expr));
    auto r = ev.to_string();
    if (!r) return fail(r.error());
    *out = dup_string(*r);
    return 0;
}
```

**Step 3: Implement statement query functions**

```cpp
// ── Statement query functions ───────────────────────────────────────────

int idax_ctree_stmt_type(IdaxCtreeStmtHandle stmt, int* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    *out = static_cast<int>(sv.type());
    return 0;
}

int idax_ctree_stmt_address(IdaxCtreeStmtHandle stmt, uint64_t* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    *out = sv.address();
    return 0;
}

int idax_ctree_stmt_goto_target_label(IdaxCtreeStmtHandle stmt, int* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.goto_target_label();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_stmt_condition(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.condition();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_then_branch(IdaxCtreeStmtHandle stmt, IdaxCtreeStmtHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.then_branch();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_else_branch(IdaxCtreeStmtHandle stmt, IdaxCtreeStmtHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.else_branch();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_has_else_branch(IdaxCtreeStmtHandle stmt, int* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    *out = sv.has_else_branch() ? 1 : 0;
    return 0;
}

int idax_ctree_stmt_body(IdaxCtreeStmtHandle stmt, IdaxCtreeStmtHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.body();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_init_expression(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.init_expression();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_step_expression(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.step_expression();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_expression(IdaxCtreeStmtHandle stmt, IdaxCtreeExprHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.expression();
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_block_size(IdaxCtreeStmtHandle stmt, size_t* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.block_size();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_stmt_block_statement(IdaxCtreeStmtHandle stmt, size_t index,
                                    IdaxCtreeStmtHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.block_statement(index);
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

int idax_ctree_stmt_switch_case_count(IdaxCtreeStmtHandle stmt, size_t* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.switch_case_count();
    if (!r) return fail(r.error());
    *out = *r;
    return 0;
}

int idax_ctree_stmt_switch_case_values(IdaxCtreeStmtHandle stmt, size_t index,
                                       uint64_t** out, size_t* count) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.switch_case_values(index);
    if (!r) return fail(r.error());
    *count = r->size();
    if (r->empty()) {
        *out = nullptr;
        return 0;
    }
    auto* arr = static_cast<uint64_t*>(malloc(r->size() * sizeof(uint64_t)));
    std::copy(r->begin(), r->end(), arr);
    *out = arr;
    return 0;
}

int idax_ctree_stmt_switch_case_body(IdaxCtreeStmtHandle stmt, size_t index,
                                     IdaxCtreeStmtHandle* out) {
    clear_error();
    auto sv = ida::decompiler::StatementView(
        ida::decompiler::StatementView::Tag{}, const_cast<void*>(stmt));
    auto r = sv.switch_case_body(index);
    if (!r) return fail(r.error());
    *out = r->raw_handle();
    return 0;
}

void idax_ctree_switch_case_values_free(uint64_t* values) {
    free(values);
}
```

**Step 4: Rebuild the shim library**

Run: `cd bindings/swift && bash scripts/build-libs.sh 2>&1 | tail -5`
Expected: `==> Libraries ready in ...`

**Step 5: Commit**

```bash
git add include/ida/decompiler.hpp bindings/rust/idax-sys/shim/idax_shim.cpp
git commit -m "feat(shim): implement handle-based ctree query functions"
```

---

### Task 4: Copy updated shim files to Swift CIDA module and verify Swift build

**Files:**
- Copy: `bindings/rust/idax-sys/shim/idax_shim.h` → `bindings/swift/Sources/CIDA/include/idax_shim.h`

**Step 1: Copy the header**

Run: `cp bindings/rust/idax-sys/shim/idax_shim.h bindings/swift/Sources/CIDA/include/idax_shim.h`

**Step 2: Build Swift package**

Run: `cd bindings/swift && swift build 2>&1 | tail -10`
Expected: Build succeeds (the new C functions are declared but not yet called from Swift)

**Step 3: Commit**

```bash
git add bindings/swift/Sources/CIDA/include/idax_shim.h
git commit -m "chore: sync shim header to Swift CIDA module"
```

---

### Task 5: Add Swift ctree types and wrapper API

**Files:**
- Modify: `bindings/swift/Sources/IDA/Decompiler.swift`

**Step 1: Add Swift ctree types and handle-based visitor**

Add before the `// MARK: - Microcode types` section (line 231):

```swift
// MARK: - Ctree types

/// Type of a ctree item (expression or statement).
public enum CtreeItemType: Int32, Sendable {
    // Expressions
    case exprEmpty = 0
    case exprComma = 1
    case exprAssign = 2
    case exprAssignBitOr = 3
    case exprAssignXor = 4
    case exprAssignBitAnd = 5
    case exprAssignAdd = 6
    case exprAssignSub = 7
    case exprAssignMul = 8
    case exprAssignShiftRightSigned = 9
    case exprAssignShiftRightUnsigned = 10
    case exprAssignShiftLeft = 11
    case exprAssignDivSigned = 12
    case exprAssignDivUnsigned = 13
    case exprAssignModSigned = 14
    case exprAssignModUnsigned = 15
    case exprTernary = 16
    case exprLogicalOr = 17
    case exprLogicalAnd = 18
    case exprBitOr = 19
    case exprXor = 20
    case exprBitAnd = 21
    case exprEqual = 22
    case exprNotEqual = 23
    case exprSignedGE = 24
    case exprUnsignedGE = 25
    case exprSignedLE = 26
    case exprUnsignedLE = 27
    case exprSignedGT = 28
    case exprUnsignedGT = 29
    case exprSignedLT = 30
    case exprUnsignedLT = 31
    case exprShiftRightSigned = 32
    case exprShiftRightUnsigned = 33
    case exprShiftLeft = 34
    case exprAdd = 35
    case exprSub = 36
    case exprMul = 37
    case exprDivSigned = 38
    case exprDivUnsigned = 39
    case exprModSigned = 40
    case exprModUnsigned = 41
    case exprFloatAdd = 42
    case exprFloatSub = 43
    case exprFloatMul = 44
    case exprFloatDiv = 45
    case exprFloatNeg = 46
    case exprNeg = 47
    case exprCast = 48
    case exprLogicalNot = 49
    case exprBitNot = 50
    case exprDeref = 51
    case exprRef = 52
    case exprPostInc = 53
    case exprPostDec = 54
    case exprPreInc = 55
    case exprPreDec = 56
    case exprCall = 57
    case exprIndex = 58
    case exprMemberRef = 59
    case exprMemberPtr = 60
    case exprNumber = 61
    case exprFloatNumber = 62
    case exprString = 63
    case exprObject = 64
    case exprVariable = 65
    case exprInsn = 66
    case exprSizeof = 67
    case exprHelper = 68
    case exprType = 69

    // Statements
    case stmtEmpty = 70
    case stmtBlock = 71
    case stmtExpr = 72
    case stmtIf = 73
    case stmtFor = 74
    case stmtWhile = 75
    case stmtDo = 76
    case stmtSwitch = 77
    case stmtBreak = 78
    case stmtContinue = 79
    case stmtReturn = 80
    case stmtGoto = 81
    case stmtAsm = 82
    case stmtTry = 83
    case stmtThrow = 84

    public var isExpression: Bool { rawValue <= 69 }
    public var isStatement: Bool { rawValue > 69 }
}

/// Result returned from ctree visitor callbacks.
public enum CtreeVisitAction: Int32, Sendable {
    case `continue` = 0
    case stop = 1
    case skipChildren = 2
}

/// Non-owning handle to a ctree expression. Valid only during visitor callback.
public struct CtreeExpression: ~Copyable {
    let handle: IdaxCtreeExprHandle

    init(_ handle: IdaxCtreeExprHandle) { self.handle = handle }

    public var type: CtreeItemType {
        get throws(IDAError) {
            let raw = try withOutput("ctree.expr.type", Int32(0)) { idax_ctree_expr_type(handle, $0) }
            return CtreeItemType(rawValue: raw) ?? .exprEmpty
        }
    }

    public var address: Address {
        get throws(IDAError) {
            try withOutput("ctree.expr.address", UInt64(0)) { idax_ctree_expr_address(handle, $0) }
        }
    }

    public var numberValue: UInt64 {
        get throws(IDAError) {
            try withOutput("ctree.expr.numberValue", UInt64(0)) { idax_ctree_expr_number_value(handle, $0) }
        }
    }

    public var stringValue: String {
        get throws(IDAError) {
            try withStringOutput("ctree.expr.stringValue") { idax_ctree_expr_string_value(handle, $0) }
        }
    }

    public var objectAddress: Address {
        get throws(IDAError) {
            try withOutput("ctree.expr.objectAddress", UInt64(0)) { idax_ctree_expr_object_address(handle, $0) }
        }
    }

    public var variableIndex: Int {
        get throws(IDAError) {
            let raw = try withOutput("ctree.expr.variableIndex", Int32(0)) { idax_ctree_expr_variable_index(handle, $0) }
            return Int(raw)
        }
    }

    public var operandCount: Int {
        get throws(IDAError) {
            let raw = try withOutput("ctree.expr.operandCount", Int32(0)) { idax_ctree_expr_operand_count(handle, $0) }
            return Int(raw)
        }
    }

    public var memberOffset: UInt32 {
        get throws(IDAError) {
            try withOutput("ctree.expr.memberOffset", UInt32(0)) { idax_ctree_expr_member_offset(handle, $0) }
        }
    }

    public func toString() throws(IDAError) -> String {
        try withStringOutput("ctree.expr.toString") { idax_ctree_expr_to_string(handle, $0) }
    }

    // Sub-expression navigation — returns borrowing closures to keep handle safety
    public func withLeft<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_expr_left(handle, &raw), "ctree.expr.left")
        return try body(CtreeExpression(raw!))
    }

    public func withRight<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_expr_right(handle, &raw), "ctree.expr.right")
        return try body(CtreeExpression(raw!))
    }

    public var callArgumentCount: Int {
        get throws(IDAError) {
            var out: Int = 0
            try checkStatus(idax_ctree_expr_call_argument_count(handle, &out), "ctree.expr.callArgumentCount")
            return out
        }
    }

    public func withCallCallee<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_expr_call_callee(handle, &raw), "ctree.expr.callCallee")
        return try body(CtreeExpression(raw!))
    }

    public func withCallArgument<T>(at index: Int, _ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_expr_call_argument(handle, index, &raw), "ctree.expr.callArgument")
        return try body(CtreeExpression(raw!))
    }
}

/// Non-owning handle to a ctree statement. Valid only during visitor callback.
public struct CtreeStatement: ~Copyable {
    let handle: IdaxCtreeStmtHandle

    init(_ handle: IdaxCtreeStmtHandle) { self.handle = handle }

    public var type: CtreeItemType {
        get throws(IDAError) {
            let raw = try withOutput("ctree.stmt.type", Int32(0)) { idax_ctree_stmt_type(handle, $0) }
            return CtreeItemType(rawValue: raw) ?? .stmtEmpty
        }
    }

    public var address: Address {
        get throws(IDAError) {
            try withOutput("ctree.stmt.address", UInt64(0)) { idax_ctree_stmt_address(handle, $0) }
        }
    }

    public var gotoTargetLabel: Int {
        get throws(IDAError) {
            let raw = try withOutput("ctree.stmt.gotoTargetLabel", Int32(0)) { idax_ctree_stmt_goto_target_label(handle, $0) }
            return Int(raw)
        }
    }

    // Sub-structure navigation with borrowing closures

    public func withCondition<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_stmt_condition(handle, &raw), "ctree.stmt.condition")
        return try body(CtreeExpression(raw!))
    }

    public func withThenBranch<T>(_ body: (CtreeStatement) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeStmtHandle?
        try checkStatus(idax_ctree_stmt_then_branch(handle, &raw), "ctree.stmt.thenBranch")
        return try body(CtreeStatement(raw!))
    }

    public func withElseBranch<T>(_ body: (CtreeStatement) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeStmtHandle?
        try checkStatus(idax_ctree_stmt_else_branch(handle, &raw), "ctree.stmt.elseBranch")
        return try body(CtreeStatement(raw!))
    }

    public var hasElseBranch: Bool {
        get throws(IDAError) {
            let raw = try withOutput("ctree.stmt.hasElseBranch", Int32(0)) { idax_ctree_stmt_has_else_branch(handle, $0) }
            return raw != 0
        }
    }

    public func withBody<T>(_ body: (CtreeStatement) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeStmtHandle?
        try checkStatus(idax_ctree_stmt_body(handle, &raw), "ctree.stmt.body")
        return try body(CtreeStatement(raw!))
    }

    public func withInitExpression<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_stmt_init_expression(handle, &raw), "ctree.stmt.initExpression")
        return try body(CtreeExpression(raw!))
    }

    public func withStepExpression<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_stmt_step_expression(handle, &raw), "ctree.stmt.stepExpression")
        return try body(CtreeExpression(raw!))
    }

    public func withExpression<T>(_ body: (CtreeExpression) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeExprHandle?
        try checkStatus(idax_ctree_stmt_expression(handle, &raw), "ctree.stmt.expression")
        return try body(CtreeExpression(raw!))
    }

    public var blockSize: Int {
        get throws(IDAError) {
            var out: Int = 0
            try checkStatus(idax_ctree_stmt_block_size(handle, &out), "ctree.stmt.blockSize")
            return out
        }
    }

    public func withBlockStatement<T>(at index: Int, _ body: (CtreeStatement) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeStmtHandle?
        try checkStatus(idax_ctree_stmt_block_statement(handle, index, &raw), "ctree.stmt.blockStatement")
        return try body(CtreeStatement(raw!))
    }

    public var switchCaseCount: Int {
        get throws(IDAError) {
            var out: Int = 0
            try checkStatus(idax_ctree_stmt_switch_case_count(handle, &out), "ctree.stmt.switchCaseCount")
            return out
        }
    }

    public func switchCaseValues(at index: Int) throws(IDAError) -> [UInt64] {
        var ptr: UnsafeMutablePointer<UInt64>?
        var count: Int = 0
        try checkStatus(
            idax_ctree_stmt_switch_case_values(handle, index, &ptr, &count),
            "ctree.stmt.switchCaseValues"
        )
        defer { idax_ctree_switch_case_values_free(ptr) }
        guard let ptr, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    public func withSwitchCaseBody<T>(at index: Int, _ body: (CtreeStatement) throws(IDAError) -> T) throws(IDAError) -> T {
        var raw: IdaxCtreeStmtHandle?
        try checkStatus(idax_ctree_stmt_switch_case_body(handle, index, &raw), "ctree.stmt.switchCaseBody")
        return try body(CtreeStatement(raw!))
    }
}
```

**Step 2: Add `visitCtree` method to `DecompiledFunction`**

Add after the existing `forEachItem` method (line ~228), before the closing `}` of the class:

```swift
    // MARK: - Handle-based ctree visitor

    /// Visit the ctree with full handle access.
    ///
    /// The closures receive non-owning handles that are only valid during the callback.
    /// Return `.continue` to keep traversing, `.stop` to halt, `.skipChildren` to skip subtree.
    public func visitCtree(
        postOrder: Bool = false,
        expressionVisitor: ((CtreeExpression) -> CtreeVisitAction)? = nil,
        statementVisitor: ((CtreeStatement) -> CtreeVisitAction)? = nil
    ) throws(IDAError) -> Int {
        final class VisitorBox {
            let exprVisitor: ((CtreeExpression) -> CtreeVisitAction)?
            let stmtVisitor: ((CtreeStatement) -> CtreeVisitAction)?
            init(
                _ exprVisitor: ((CtreeExpression) -> CtreeVisitAction)?,
                _ stmtVisitor: ((CtreeStatement) -> CtreeVisitAction)?
            ) {
                self.exprVisitor = exprVisitor
                self.stmtVisitor = stmtVisitor
            }
        }
        let box = VisitorBox(expressionVisitor, statementVisitor)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<VisitorBox>.fromOpaque(ctx).release() }

        var visited: Int32 = 0

        let exprCb: IdaxCtreeExprVisitor? = expressionVisitor != nil ? { ctx, expr in
            guard let ctx, let expr else { return 0 }
            let box = Unmanaged<VisitorBox>.fromOpaque(ctx).takeUnretainedValue()
            let result = box.exprVisitor!(CtreeExpression(expr))
            return result.rawValue
        } : nil

        let stmtCb: IdaxCtreeStmtVisitor? = statementVisitor != nil ? { ctx, stmt in
            guard let ctx, let stmt else { return 0 }
            let box = Unmanaged<VisitorBox>.fromOpaque(ctx).takeUnretainedValue()
            let result = box.stmtVisitor!(CtreeStatement(stmt))
            return result.rawValue
        } : nil

        try checkStatus(
            idax_ctree_visit(handle, exprCb, stmtCb, ctx, postOrder ? 1 : 0, &visited),
            "decompiled.visitCtree"
        )
        return Int(visited)
    }
```

**Step 3: Build Swift package**

Run: `cd bindings/swift && swift build 2>&1 | tail -10`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add bindings/swift/Sources/IDA/Decompiler.swift
git commit -m "feat(swift): add CtreeExpression, CtreeStatement, and visitCtree API"
```

---

### Task 6: Add Swift unit tests for ctree types

**Files:**
- Modify: `bindings/swift/Tests/IDATests/UnitTests.swift`

**Step 1: Add ctree type tests**

Add after the `VariableStorageTests` suite (after line ~257):

```swift
@Suite("IDA CtreeItemType")
struct CtreeItemTypeTests {
    @Test func expressionRawValues() {
        #expect(CtreeItemType.exprEmpty.rawValue == 0)
        #expect(CtreeItemType.exprCall.rawValue == 57)
        #expect(CtreeItemType.exprType.rawValue == 69)
    }

    @Test func statementRawValues() {
        #expect(CtreeItemType.stmtEmpty.rawValue == 70)
        #expect(CtreeItemType.stmtBlock.rawValue == 71)
        #expect(CtreeItemType.stmtIf.rawValue == 73)
        #expect(CtreeItemType.stmtFor.rawValue == 74)
        #expect(CtreeItemType.stmtSwitch.rawValue == 77)
        #expect(CtreeItemType.stmtReturn.rawValue == 80)
        #expect(CtreeItemType.stmtThrow.rawValue == 84)
    }

    @Test func isExpressionAndStatement() {
        #expect(CtreeItemType.exprCall.isExpression)
        #expect(!CtreeItemType.exprCall.isStatement)
        #expect(CtreeItemType.stmtIf.isStatement)
        #expect(!CtreeItemType.stmtIf.isExpression)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(CtreeItemType(rawValue: 999) == nil)
    }
}

@Suite("IDA CtreeVisitAction")
struct CtreeVisitActionTests {
    @Test func rawValues() {
        #expect(CtreeVisitAction.continue.rawValue == 0)
        #expect(CtreeVisitAction.stop.rawValue == 1)
        #expect(CtreeVisitAction.skipChildren.rawValue == 2)
    }
}
```

**Step 2: Run tests**

Run: `cd bindings/swift && swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Commit**

```bash
git add bindings/swift/Tests/IDATests/UnitTests.swift
git commit -m "test(swift): add ctree type unit tests"
```

---

## Notes

- The `CtreeExpression` and `CtreeStatement` Swift types are `~Copyable` to enforce that handles cannot outlive the visitor callback scope. Sub-element access uses `with*` closures (`withLeft`, `withCondition`, `withThenBranch`, etc.) that pass borrowed handles.
- The existing `forEachExpression`/`forEachItem` APIs remain unchanged for backward compatibility. The new `visitCtree` API provides richer handle-based access.
- The `raw_handle()` method added to C++ `ExpressionView`/`StatementView` is intentionally `const void*` to match the C shim's `IdaxCtreeExprHandle`/`IdaxCtreeStmtHandle` typedefs.
- Switch case values are heap-allocated arrays in the C shim, freed with `idax_ctree_switch_case_values_free`. The Swift wrapper copies to a Swift `Array` in `switchCaseValues(at:)` and frees immediately.
