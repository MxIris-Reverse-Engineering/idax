import CIDA
import Darwin

/// Storage class for a decompiler local variable.
public enum VariableStorage: Int, Sendable {
    case unknown = 0
    case register = 1
    case stack = 2
}

/// Local variable from decompilation.
public struct LocalVariable: Sendable {
    public let name: String
    public let typeName: String
    public let isArgument: Bool
    public let width: Int
    public let hasUserName: Bool
    public let storage: VariableStorage
    public let comment: String
}

/// Decompiled function handle.
///
/// Reference type — `deinit` frees the underlying handle.
public final class DecompiledFunction: @unchecked Sendable {
    let handle: IdaxDecompiledHandle

    init(_ handle: IdaxDecompiledHandle) {
        self.handle = handle
    }

    deinit {
        idax_decompiled_free(handle)
    }

    public var pseudocode: String {
        get throws(IDAError) {
            try withStringOutput("decompiled.pseudocode") { idax_decompiled_pseudocode(handle, $0) }
        }
    }

    public var declaration: String {
        get throws(IDAError) {
            try withStringOutput("decompiled.declaration") { idax_decompiled_declaration(handle, $0) }
        }
    }

    public var entryAddress: Address {
        get throws(IDAError) {
            try withOutput("decompiled.entryAddress", UInt64(0)) { idax_decompiled_entry_address(handle, $0) }
        }
    }

    public var lines: [String] {
        get throws(IDAError) {
            var ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var count: Int = 0
            try checkStatus(idax_decompiled_lines(handle, &ptr, &count), "decompiled.lines")
            defer { idax_decompiled_lines_free(ptr, count) }
            guard let ptr, count > 0 else { return [] }
            return (0..<count).map { i in
                if let s = ptr[i] { String(cString: s) } else { "" }
            }
        }
    }

    public var variables: [LocalVariable] {
        get throws(IDAError) {
            var ptr: UnsafeMutablePointer<IdaxLocalVariable>? = nil
            var count: Int = 0
            try checkStatus(idax_decompiled_variables(handle, &ptr, &count), "decompiled.variables")
            defer { idax_decompiled_variables_free(ptr, count) }
            guard let ptr, count > 0 else { return [] }
            let buf = UnsafeBufferPointer(start: ptr, count: count)
            return buf.map { v in
                LocalVariable(
                    name: borrowCString(v.name),
                    typeName: borrowCString(v.type_name),
                    isArgument: v.is_argument != 0,
                    width: Int(v.width),
                    hasUserName: v.has_user_name != 0,
                    storage: VariableStorage(rawValue: Int(v.storage)) ?? .unknown,
                    comment: borrowCString(v.comment)
                )
            }
        }
    }

    public func renameVariable(from oldName: String, to newName: String) throws(IDAError) {
        try checkStatus(
            oldName.withCString { o in
                newName.withCString { n in
                    idax_decompiled_rename_variable(handle, o, n)
                }
            },
            "decompiled.renameVariable"
        )
    }

    // MARK: - Additional properties

    public var microcode: String {
        get throws(IDAError) {
            try withStringOutput("decompiled.microcode") { idax_decompiled_microcode(handle, $0) }
        }
    }

    public var rawLines: [String] {
        get throws(IDAError) {
            var ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var count: Int = 0
            try checkStatus(idax_decompiled_raw_lines(handle, &ptr, &count), "decompiled.rawLines")
            defer { idax_decompiled_lines_free(ptr, count) }
            guard let ptr, count > 0 else { return [] }
            return (0..<count).map { i in
                if let s = ptr[i] { String(cString: s) } else { "" }
            }
        }
    }

    public func setRawLine(at lineIndex: Int, text: String) throws(IDAError) {
        try checkStatus(
            text.withCString { idax_decompiled_set_raw_line(handle, lineIndex, $0) },
            "decompiled.setRawLine"
        )
    }

    public var headerLineCount: Int {
        get throws(IDAError) {
            var out: Int32 = 0
            try checkStatus(idax_decompiled_header_line_count(handle, &out), "decompiled.headerLineCount")
            return Int(out)
        }
    }

    public var variableCount: Int {
        get throws(IDAError) {
            var out: Int = 0
            try checkStatus(idax_decompiled_variable_count(handle, &out), "decompiled.variableCount")
            return out
        }
    }

    // MARK: - Comments

    public func setComment(at address: Address, text: String, position: Int) throws(IDAError) {
        try checkStatus(
            text.withCString { idax_decompiled_set_comment(handle, address, $0, Int32(position)) },
            "decompiled.setComment"
        )
    }

    public func comment(at address: Address, position: Int) throws(IDAError) -> String {
        try withStringOutput("decompiled.comment") {
            idax_decompiled_get_comment(handle, address, Int32(position), $0)
        }
    }

    public func saveComments() throws(IDAError) {
        try checkStatus(idax_decompiled_save_comments(handle), "decompiled.saveComments")
    }

    // MARK: - Line / address mapping

    public func lineToAddress(_ lineNumber: Int) throws(IDAError) -> Address {
        try withOutput("decompiled.lineToAddress", UInt64(0)) {
            idax_decompiled_line_to_address(handle, Int32(lineNumber), $0)
        }
    }

    // MARK: - Visitors

    public func forEachExpression(_ visitor: @escaping (Int, Address) -> Bool) throws(IDAError) -> Int {
        final class VisitorBox {
            let visitor: (Int, Address) -> Bool
            init(_ visitor: @escaping (Int, Address) -> Bool) { self.visitor = visitor }
        }
        let box = VisitorBox(visitor)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<VisitorBox>.fromOpaque(ctx).release() }
        var visited: Int32 = 0
        let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerExpressionInfo>?) -> Int32 = { ctx, expr in
            guard let ctx, let expr else { return 0 }
            let box = Unmanaged<VisitorBox>.fromOpaque(ctx).takeUnretainedValue()
            return box.visitor(Int(expr.pointee.type), expr.pointee.address) ? 1 : 0
        }
        try checkStatus(
            idax_decompiler_for_each_expression(handle, trampoline, ctx, &visited),
            "decompiled.forEachExpression"
        )
        return Int(visited)
    }

    public func forEachItem(
        expressionVisitor: @escaping (Int, Address) -> Bool,
        statementVisitor: @escaping (Int, Address) -> Bool
    ) throws(IDAError) -> Int {
        final class ItemVisitorBox {
            let exprVisitor: (Int, Address) -> Bool
            let stmtVisitor: (Int, Address) -> Bool
            init(
                _ exprVisitor: @escaping (Int, Address) -> Bool,
                _ stmtVisitor: @escaping (Int, Address) -> Bool
            ) {
                self.exprVisitor = exprVisitor
                self.stmtVisitor = stmtVisitor
            }
        }
        let box = ItemVisitorBox(expressionVisitor, statementVisitor)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ItemVisitorBox>.fromOpaque(ctx).release() }
        var visited: Int32 = 0
        let exprTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerExpressionInfo>?) -> Int32 = { ctx, expr in
            guard let ctx, let expr else { return 0 }
            let box = Unmanaged<ItemVisitorBox>.fromOpaque(ctx).takeUnretainedValue()
            return box.exprVisitor(Int(expr.pointee.type), expr.pointee.address) ? 1 : 0
        }
        let stmtTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerStatementInfo>?) -> Int32 = { ctx, stmt in
            guard let ctx, let stmt else { return 0 }
            let box = Unmanaged<ItemVisitorBox>.fromOpaque(ctx).takeUnretainedValue()
            return box.stmtVisitor(Int(stmt.pointee.type), stmt.pointee.address) ? 1 : 0
        }
        try checkStatus(
            idax_decompiler_for_each_item(handle, exprTrampoline, stmtTrampoline, ctx, &visited),
            "decompiled.forEachItem"
        )
        return Int(visited)
    }

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
}

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
public struct CtreeExpression: @unchecked Sendable {
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
public struct CtreeStatement: @unchecked Sendable {
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

// MARK: - Microcode types

/// Item at a position in decompiler output.
public struct DecompilerItemAtPosition: Sendable {
    public let type: Int32
    public let address: Address
    public let itemIndex: Int32
    public let isExpression: Bool
}

/// Microcode operand descriptor.
public struct MicrocodeOperand: Sendable {
    public let kind: Int32
    public let registerID: Int32
    public let localVariableIndex: Int32
    public let localVariableOffset: Int64
    public let secondRegisterID: Int32
    public let globalAddress: UInt64
    public let stackOffset: Int64
    public let helperName: String
    public let blockIndex: Int32
    public let unsignedImmediate: UInt64
    public let signedImmediate: Int64
    public let byteWidth: Int32
    public let markUserDefinedType: Int32
}

/// Microcode instruction descriptor.
public struct MicrocodeInstruction: Sendable {
    public let opcode: Int32
    public let left: MicrocodeOperand
    public let right: MicrocodeOperand
    public let destination: MicrocodeOperand
    public let floatingPointInstruction: Bool
}

/// Convert a C IdaxMicrocodeOperand to the Swift MicrocodeOperand value type.
private func makeMicrocodeOperand(_ op: IdaxMicrocodeOperand) -> MicrocodeOperand {
    MicrocodeOperand(
        kind: op.kind,
        registerID: op.register_id,
        localVariableIndex: op.local_variable_index,
        localVariableOffset: op.local_variable_offset,
        secondRegisterID: op.second_register_id,
        globalAddress: op.global_address,
        stackOffset: op.stack_offset,
        helperName: borrowCString(op.helper_name),
        blockIndex: op.block_index,
        unsignedImmediate: op.unsigned_immediate,
        signedImmediate: op.signed_immediate,
        byteWidth: op.byte_width,
        markUserDefinedType: op.mark_user_defined_type
    )
}

/// Convert a C IdaxMicrocodeInstruction to the Swift MicrocodeInstruction value type.
private func makeMicrocodeInstruction(_ raw: IdaxMicrocodeInstruction) -> MicrocodeInstruction {
    MicrocodeInstruction(
        opcode: raw.opcode,
        left: makeMicrocodeOperand(raw.left),
        right: makeMicrocodeOperand(raw.right),
        destination: makeMicrocodeOperand(raw.destination),
        floatingPointInstruction: raw.floating_point_instruction != 0
    )
}

// MARK: - Decompiler subscription

/// RAII decompiler event subscription token. Unsubscribes on deinit.
public final class DecompilerSubscription: @unchecked Sendable {
    private let token: UInt64
    private let context: UnsafeMutableRawPointer
    private var active = true

    init(token: UInt64, context: UnsafeMutableRawPointer) {
        self.token = token
        self.context = context
    }

    deinit {
        if active {
            idax_decompiler_unsubscribe(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
        }
    }

    public func cancel() {
        if active {
            idax_decompiler_unsubscribe(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
            active = false
        }
    }
}

/// RAII microcode filter subscription token. Unregisters on deinit.
public final class MicrocodeFilterSubscription: @unchecked Sendable {
    private let token: UInt64
    private let context: UnsafeMutableRawPointer
    private var active = true

    init(token: UInt64, context: UnsafeMutableRawPointer) {
        self.token = token
        self.context = context
    }

    deinit {
        if active {
            idax_decompiler_unregister_microcode_filter(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
        }
    }

    public func cancel() {
        if active {
            idax_decompiler_unregister_microcode_filter(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
            active = false
        }
    }
}

// MARK: - Decompiler callback boxes and trampolines

private final class MaturityChangedBox {
    let handler: (Address, Int) -> Void
    init(handler: @escaping (Address, Int) -> Void) { self.handler = handler }
}

private final class PseudocodeEventBox {
    let handler: (Address) -> Void
    init(handler: @escaping (Address) -> Void) { self.handler = handler }
}

private final class CursorPositionBox {
    let handler: (Address, Address) -> Void
    init(handler: @escaping (Address, Address) -> Void) { self.handler = handler }
}

private final class CreateHintBox {
    let handler: (Address, Address) -> (String, Int)?
    init(handler: @escaping (Address, Address) -> (String, Int)?) { self.handler = handler }
}

private final class MicrocodeFilterBox {
    let match: (Address, Int) -> Bool
    let apply: (UnsafeMutableRawPointer) -> Bool
    init(
        match: @escaping (Address, Int) -> Bool,
        apply: @escaping (UnsafeMutableRawPointer) -> Bool
    ) {
        self.match = match
        self.apply = apply
    }
}

private let maturityChangedTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerMaturityEvent>?) -> Void = { ctx, event in
    guard let ctx, let event else { return }
    let box = Unmanaged<MaturityChangedBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(event.pointee.function_address, Int(event.pointee.new_maturity))
}

private let funcPrintedTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerPseudocodeEvent>?) -> Void = { ctx, event in
    guard let ctx, let event else { return }
    let box = Unmanaged<PseudocodeEventBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(event.pointee.function_address)
}

private let refreshPseudocodeTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerPseudocodeEvent>?) -> Void = { ctx, event in
    guard let ctx, let event else { return }
    let box = Unmanaged<PseudocodeEventBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(event.pointee.function_address)
}

private let cursorPositionTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerCursorPositionEvent>?) -> Void = { ctx, event in
    guard let ctx, let event else { return }
    let box = Unmanaged<CursorPositionBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(event.pointee.function_address, event.pointee.cursor_address)
}

private let createHintTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<IdaxDecompilerHintRequestEvent>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?, UnsafeMutablePointer<Int32>?) -> Int32 = { ctx, event, outText, outLines in
    guard let ctx, let event else { return 0 }
    let box = Unmanaged<CreateHintBox>.fromOpaque(ctx).takeUnretainedValue()
    guard let result = box.handler(event.pointee.function_address, event.pointee.item_address) else {
        return 0
    }
    outText?.pointee = UnsafePointer(strdup(result.0))
    outLines?.pointee = Int32(result.1)
    return 1
}

private let microcodeMatchTrampoline: @convention(c) (UnsafeMutableRawPointer?, UInt64, Int32) -> Int32 = { ctx, address, itype in
    guard let ctx else { return 0 }
    let box = Unmanaged<MicrocodeFilterBox>.fromOpaque(ctx).takeUnretainedValue()
    return box.match(address, Int(itype)) ? 1 : 0
}

private let microcodeApplyTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { ctx, mctx in
    guard let ctx, let mctx else { return 0 }
    let box = Unmanaged<MicrocodeFilterBox>.fromOpaque(ctx).takeUnretainedValue()
    return box.apply(mctx) ? 1 : 0
}

/// Decompiler facade.
///
/// Mirrors C++ `ida::decompiler`.
public enum Decompiler {
    public static func isAvailable() throws(IDAError) -> Bool {
        var out: Int32 = 0
        try checkStatus(idax_decompiler_available(&out), "decompiler.available")
        return out != 0
    }

    public static func decompile(at address: Address) throws(IDAError) -> DecompiledFunction {
        var handle: IdaxDecompiledHandle?
        try checkStatus(idax_decompiler_decompile(address, &handle), "decompiler.decompile")
        guard let handle else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return DecompiledFunction(handle)
    }

    // MARK: - Raw cfunc operations

    public static func rawPseudocodeLines(_ cfuncHandle: UnsafeMutableRawPointer) throws(IDAError) -> [String] {
        var ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int = 0
        try checkStatus(idax_decompiler_raw_pseudocode_lines(cfuncHandle, &ptr, &count), "decompiler.rawPseudocodeLines")
        defer { idax_decompiler_pseudocode_lines_free(ptr, count) }
        guard let ptr, count > 0 else { return [] }
        return (0..<count).map { i in
            if let s = ptr[i] { String(cString: s) } else { "" }
        }
    }

    public static func setPseudocodeLine(_ cfuncHandle: UnsafeMutableRawPointer, at lineIndex: Int, text: String) throws(IDAError) {
        try checkStatus(
            text.withCString { idax_decompiler_set_pseudocode_line(cfuncHandle, lineIndex, $0) },
            "decompiler.setPseudocodeLine"
        )
    }

    public static func pseudocodeHeaderLineCount(_ cfuncHandle: UnsafeMutableRawPointer) throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(idax_decompiler_pseudocode_header_line_count(cfuncHandle, &out), "decompiler.pseudocodeHeaderLineCount")
        return Int(out)
    }

    public static func itemAtPosition(_ cfuncHandle: UnsafeMutableRawPointer, taggedLine: String, charIndex: Int) throws(IDAError) -> DecompilerItemAtPosition {
        var raw = IdaxDecompilerItemAtPosition()
        try checkStatus(
            taggedLine.withCString { idax_decompiler_item_at_position(cfuncHandle, $0, Int32(charIndex), &raw) },
            "decompiler.itemAtPosition"
        )
        return DecompilerItemAtPosition(
            type: raw.type,
            address: raw.address,
            itemIndex: raw.item_index,
            isExpression: raw.is_expression != 0
        )
    }

    // MARK: - Dirty / view management

    public static func markDirty(at address: Address, closeViews: Bool = false) throws(IDAError) {
        try checkStatus(
            idax_decompiler_mark_dirty(address, closeViews ? 1 : 0),
            "decompiler.markDirty"
        )
    }

    public static func markDirtyWithCallers(at address: Address, closeViews: Bool = false) throws(IDAError) {
        try checkStatus(
            idax_decompiler_mark_dirty_with_callers(address, closeViews ? 1 : 0),
            "decompiler.markDirtyWithCallers"
        )
    }

    public static func currentView() throws(IDAError) -> Address {
        try withOutput("decompiler.currentView", UInt64(0)) {
            idax_decompiler_current_view($0)
        }
    }

    public static func viewFromHost(_ viewHost: UnsafeMutableRawPointer) throws(IDAError) -> Address {
        try withOutput("decompiler.viewFromHost", UInt64(0)) {
            idax_decompiler_view_from_host(viewHost, $0)
        }
    }

    public static func viewForFunction(at address: Address) throws(IDAError) -> Address {
        try withOutput("decompiler.viewForFunction", UInt64(0)) {
            idax_decompiler_view_for_function(address, $0)
        }
    }

    // MARK: - Item inspection

    public static func itemTypeName(_ itemType: Int) throws(IDAError) -> String {
        try withStringOutput("decompiler.itemTypeName") {
            idax_decompiler_item_type_name(Int32(itemType), $0)
        }
    }

    // MARK: - Event subscriptions

    public static func onMaturityChanged(
        _ handler: @escaping (Address, Int) -> Void
    ) throws(IDAError) -> DecompilerSubscription {
        let box = MaturityChangedBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_decompiler_on_maturity_changed(maturityChangedTrampoline, ctx, &token),
                "decompiler.onMaturityChanged"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return DecompilerSubscription(token: token, context: ctx)
    }

    public static func onFuncPrinted(
        _ handler: @escaping (Address) -> Void
    ) throws(IDAError) -> DecompilerSubscription {
        let box = PseudocodeEventBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_decompiler_on_func_printed(funcPrintedTrampoline, ctx, &token),
                "decompiler.onFuncPrinted"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return DecompilerSubscription(token: token, context: ctx)
    }

    public static func onRefreshPseudocode(
        _ handler: @escaping (Address) -> Void
    ) throws(IDAError) -> DecompilerSubscription {
        let box = PseudocodeEventBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_decompiler_on_refresh_pseudocode(refreshPseudocodeTrampoline, ctx, &token),
                "decompiler.onRefreshPseudocode"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return DecompilerSubscription(token: token, context: ctx)
    }

    public static func onCursorPositionChanged(
        _ handler: @escaping (Address, Address) -> Void
    ) throws(IDAError) -> DecompilerSubscription {
        let box = CursorPositionBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_decompiler_on_curpos_changed(cursorPositionTrampoline, ctx, &token),
                "decompiler.onCursorPositionChanged"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return DecompilerSubscription(token: token, context: ctx)
    }

    public static func onCreateHint(
        _ handler: @escaping (Address, Address) -> (String, Int)?
    ) throws(IDAError) -> DecompilerSubscription {
        let box = CreateHintBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_decompiler_on_create_hint(createHintTrampoline, ctx, &token),
                "decompiler.onCreateHint"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return DecompilerSubscription(token: token, context: ctx)
    }

    // MARK: - Microcode filter

    public static func registerMicrocodeFilter(
        match: @escaping (Address, Int) -> Bool,
        apply: @escaping (UnsafeMutableRawPointer) -> Bool
    ) throws(IDAError) -> MicrocodeFilterSubscription {
        let box = MicrocodeFilterBox(match: match, apply: apply)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_decompiler_register_microcode_filter(
                    microcodeMatchTrampoline,
                    microcodeApplyTrampoline,
                    ctx,
                    &token
                ),
                "decompiler.registerMicrocodeFilter"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return MicrocodeFilterSubscription(token: token, context: ctx)
    }

    // MARK: - Microcode context inspection

    public static func microcodeContextAddress(_ mctx: UnsafeRawPointer) throws(IDAError) -> Address {
        try withOutput("decompiler.microcodeContextAddress", UInt64(0)) {
            idax_decompiler_microcode_context_address(mctx, $0)
        }
    }

    public static func microcodeContextInstructionType(_ mctx: UnsafeRawPointer) throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(
            idax_decompiler_microcode_context_instruction_type(mctx, &out),
            "decompiler.microcodeContextInstructionType"
        )
        return Int(out)
    }

    public static func microcodeContextBlockInstructionCount(_ mctx: UnsafeRawPointer) throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(
            idax_decompiler_microcode_context_block_instruction_count(mctx, &out),
            "decompiler.microcodeContextBlockInstructionCount"
        )
        return Int(out)
    }

    public static func microcodeContextHasInstructionAtIndex(_ mctx: UnsafeRawPointer, index: Int) throws(IDAError) -> Bool {
        var out: Int32 = 0
        try checkStatus(
            idax_decompiler_microcode_context_has_instruction_at_index(mctx, Int32(index), &out),
            "decompiler.microcodeContextHasInstructionAtIndex"
        )
        return out != 0
    }

    public static func microcodeContextInstruction(_ mctx: UnsafeRawPointer) throws(IDAError) -> Instruction {
        var raw = IdaxInstruction()
        try checkStatus(
            idax_decompiler_microcode_context_instruction(mctx, &raw),
            "decompiler.microcodeContextInstruction"
        )
        defer { idax_instruction_free(&raw) }
        return Instruction(raw: raw)
    }

    public static func microcodeContextInstructionAtIndex(_ mctx: UnsafeRawPointer, index: Int) throws(IDAError) -> MicrocodeInstruction {
        var raw = IdaxMicrocodeInstruction()
        try checkStatus(
            idax_decompiler_microcode_context_instruction_at_index(mctx, Int32(index), &raw),
            "decompiler.microcodeContextInstructionAtIndex"
        )
        defer { idax_microcode_instruction_free(&raw) }
        return makeMicrocodeInstruction(raw)
    }

    public static func microcodeContextHasLastEmittedInstruction(_ mctx: UnsafeRawPointer) throws(IDAError) -> Bool {
        var out: Int32 = 0
        try checkStatus(
            idax_decompiler_microcode_context_has_last_emitted_instruction(mctx, &out),
            "decompiler.microcodeContextHasLastEmittedInstruction"
        )
        return out != 0
    }

    public static func microcodeContextLastEmittedInstruction(_ mctx: UnsafeRawPointer) throws(IDAError) -> MicrocodeInstruction {
        var raw = IdaxMicrocodeInstruction()
        try checkStatus(
            idax_decompiler_microcode_context_last_emitted_instruction(mctx, &raw),
            "decompiler.microcodeContextLastEmittedInstruction"
        )
        defer { idax_microcode_instruction_free(&raw) }
        return makeMicrocodeInstruction(raw)
    }
}
