internal import CIDAX

/// A category in IDA's problem list.
///
/// Mirrors C++ `ida::problem::Kind`. The raw values are IDA's own and are not
/// contiguous with any other enumeration here.
public enum ProblemKind: Int32, Sendable {
    case missingOffsetBase = 1
    case missingName = 2
    case missingForcedOperand = 3
    case missingComment = 4
    case missingReferences = 5
    case ignoredJumpTable = 6
    case disassemblyFailure = 7
    case alreadyItemHead = 8
    case flowBeyondLimits = 9
    case tooManyLines = 10
    case stackTraceFailure = 11
    case attention = 12
    case analysisDecision = 13
    case rolledBackDecision = 14
    case flairCollision = 15
    case flairIndecision = 16
}

/// IDA's problem list — the addresses the analyser flagged as needing attention.
public enum Problem {

    /// IDA's description of the problem recorded at `address`.
    public static func description(
        of kind: ProblemKind,
        at address: Address
    ) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_problem_description(kind.rawValue, address, &out),
            "problem.description"
        )
        return takeCString(out)
    }

    /// Records a problem of `kind` at `address`.
    public static func remember(
        _ kind: ProblemKind,
        at address: Address,
        message: String = ""
    ) throws(IDAError) {
        try checkStatus(
            idax_problem_remember(kind.rawValue, address, message),
            "problem.remember"
        )
    }

    /// The first address at or after `address` carrying a problem of `kind`.
    ///
    /// - Returns: `nil` when there is no such address, which is not an error.
    public static func next(
        _ kind: ProblemKind,
        atOrAfter address: Address
    ) throws(IDAError) -> Address? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_problem_next(kind.rawValue, address, &out, &hasValue),
            "problem.next"
        )
        return hasValue != 0 ? out : nil
    }

    /// Removes the problem of `kind` recorded at `address`.
    ///
    /// - Returns: whether a problem was actually removed.
    @discardableResult
    public static func remove(
        _ kind: ProblemKind,
        at address: Address
    ) throws(IDAError) -> Bool {
        try withOutput("problem.remove", Int32(0)) {
            idax_problem_remove(kind.rawValue, address, $0)
        } != 0
    }

    /// IDA's name for a problem category.
    ///
    /// - Parameter longForm: request the descriptive sentence rather than the
    ///   short identifier.
    public static func name(
        of kind: ProblemKind,
        longForm: Bool = false
    ) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_problem_name(kind.rawValue, longForm ? 1 : 0, &out),
            "problem.name"
        )
        return takeCString(out)
    }

    /// Whether a problem of `kind` is recorded at `address`.
    public static func contains(
        _ kind: ProblemKind,
        at address: Address
    ) throws(IDAError) -> Bool {
        try withOutput("problem.contains", Int32(0)) {
            idax_problem_contains(kind.rawValue, address, $0)
        } != 0
    }
}
