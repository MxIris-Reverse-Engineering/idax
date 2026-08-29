import Foundation
import Testing
@testable import IDAX

@Suite(
    "IDA Script Values",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct ScriptValueTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func integerValuesRoundTrip() throws {
        let value = try ScriptValue(integer: -1234)
        #expect(try value.kind() == .integer)
        #expect(try value.asInteger() == -1234)
    }

    @Test func floatingPointValuesRoundTrip() throws {
        let value = try ScriptValue(floatingPoint: 2.5)
        #expect(try value.kind() == .floatingPoint)
        #expect(try value.asFloatingPoint() == 2.5)
    }

    @Test func stringValuesRoundTrip() throws {
        let value = try ScriptValue(string: "idax")
        #expect(try value.kind() == .string)
        #expect(try value.asString() == "idax")
    }

    @Test func objectValuesReportTheirKind() throws {
        let value = try ScriptValue.object()
        #expect(try value.kind() == .object)
    }

    @Test func coercionCrossesKindsWhereReadingWouldNot() throws {
        let value = try ScriptValue(integer: 42)
        // Reading demands the exact kind; coercion applies IDC's rules.
        // IDC's integer-to-string format is its own; only that a conversion
        // happened is contractual.
        #expect(!(try value.coerceToString().isEmpty))
        #expect(try value.coerceToFloatingPoint() == 42.0)
        // `#expect(throws:)` would have to capture the ~Copyable value in a
        // Copyable-constrained closure, so this is a plain do/catch.
        var readingRejectedTheKind = false
        do {
            _ = try value.asString()
        } catch {
            readingRejectedTheKind = true
        }
        #expect(readingRejectedTheKind)
    }

    @Test func clonesAreIndependentOfTheOriginal() throws {
        let original = try ScriptValue(integer: 7)
        let copy = try original.clone()
        #expect(try copy.asInteger() == 7)
        // Both must remain usable: cloning does not consume the original.
        #expect(try original.asInteger() == 7)
    }

    @Test func deepCopyDuplicatesNestedObjects() throws {
        let object = try ScriptValue.object()
        try object.setAttribute("inner", to: ScriptValue(integer: 1))

        let copy = try object.deepCopy()
        // Mutating the copy must not be visible through the original.
        try copy.setAttribute("inner", to: ScriptValue(integer: 2))

        #expect(try object.attribute("inner").asInteger() == 1)
        #expect(try copy.attribute("inner").asInteger() == 2)
    }

    @Test func attributesAreWrittenListedAndRemoved() throws {
        let object = try ScriptValue.object()
        try object.setAttribute("alpha", to: ScriptValue(integer: 1))
        try object.setAttribute("beta", to: ScriptValue(string: "two"))

        let names = try object.attributeNames()
        #expect(names.contains("alpha"))
        #expect(names.contains("beta"))

        #expect(try object.attribute("beta").asString() == "two")
        #expect(try object.removeAttribute("beta"))
        #expect(try object.attributeNames().contains("beta") == false)
    }

    @Test func settingAnAttributeBorrowsRatherThanConsumes() throws {
        let object = try ScriptValue.object()
        let attribute = try ScriptValue(integer: 99)
        try object.setAttribute("value", to: attribute)
        // The C++ side copies out of the handle, so the caller keeps it.
        #expect(try attribute.asInteger() == 99)
        #expect(try object.attribute("value").asInteger() == 99)
    }

    @Test func slicesAStringValue() throws {
        let value = try ScriptValue(string: "abcdef")
        #expect(try value.slice(from: 1, to: 4).asString() == "bcd")
    }

    @Test func replacesASliceInPlace() throws {
        let value = try ScriptValue(string: "abcdef")
        try value.replaceSlice(from: 0, to: 3, with: ScriptValue(string: "XY"))
        #expect(try value.asString() == "XYdef")
    }

    @Test func rendersAValueTheWayIDAPrintsIt() throws {
        let value = try ScriptValue(integer: 5)
        #expect(!(try value.render(name: "n").isEmpty))
    }
}

@Suite(
    "IDA Script Execution",
    .serialized,
    .enabled(if: IntegrationEnvironment.isAvailable, "\(IntegrationEnvironment.unavailableReason)")
)
@MainActor
struct ScriptExecutionTests {

    init() throws {
        try IntegrationDatabase.ensureOpen()
    }

    @Test func evaluatesAnIntegerExpression() throws {
        let result = try Script.evaluateInteger("2 + 3")
        #expect(result.succeeded, "evaluation failed: \(result.error)")
        #expect(result.value == 5)
    }

    @Test func evaluatesAnExpressionToAValue() throws {
        var result = try Script.evaluateIDC("1 + 1")
        let succeeded = result.succeeded
        let errorText = result.error
        #expect(succeeded, "evaluation failed: \(errorText)")

        var coerced: Int64? = nil
        if let value = result.takeValue() {
            coerced = try value.coerceToInteger()
        }
        #expect(coerced == 2)
    }

    @Test func takingTheValueTwiceYieldsNilTheSecondTime() throws {
        var result = try Script.evaluateIDC("7")
        var firstTakeProducedAValue = false
        if let value = result.takeValue() {
            firstTakeProducedAValue = true
            _ = consume value
        }
        var secondTakeProducedAValue = false
        if let value = result.takeValue() {
            secondTakeProducedAValue = true
            _ = consume value
        }
        #expect(firstTakeProducedAValue)
        // Ownership moved out on the first call; a second must not double-free.
        #expect(secondTakeProducedAValue == false)
        // Metadata survives taking the value.
        let succeeded = result.succeeded
        #expect(succeeded)
    }

    @Test func aFailedEvaluationReportsRatherThanThrows() throws {
        let result = try Script.evaluateInteger("this is not valid idc @@@")
        #expect(result.succeeded == false)
        #expect(!result.error.isEmpty)
    }

    @Test func compilesAFunctionAndCallsItWithArguments() throws {
        // A snippet is a bare body with no parameters; a function that takes
        // arguments has to be declared through compileText.
        let compilation = try Script.compileText(
            "static idax_test_add(a, b) { return a + b + IDAX_TEST_BASE; }",
            options: ScriptCompileOptions(
                resolvedNames: [ScriptResolvedName(name: "IDAX_TEST_BASE", value: 40)]
            )
        )
        #expect(compilation.succeeded, "compilation failed: \(compilation.error)")

        var arguments = ScriptArguments()
        arguments.append(try ScriptValue(integer: 1))
        arguments.append(try ScriptValue(integer: 1))
        #expect(arguments.count == 2)

        var result = try Script.call("idax_test_add", arguments: arguments)
        let succeeded = result.succeeded
        let errorText = result.error
        #expect(succeeded, "call failed: \(errorText)")

        var coerced: Int64? = nil
        if let value = result.takeValue() {
            coerced = try value.coerceToInteger()
        }
        #expect(coerced == 42)
    }

    @Test func compilesAParameterlessSnippet() throws {
        // Names a snippet refers to must be pre-resolved; it has no parameters
        // of its own.
        let compilation = try Script.compileSnippet(
            functionName: "idax_test_snippet",
            body: "return IDAX_TEST_CONST + 2;",
            options: ScriptCompileOptions(
                resolvedNames: [ScriptResolvedName(name: "IDAX_TEST_CONST", value: 40)]
            )
        )
        #expect(compilation.succeeded, "compilation failed: \(compilation.error)")

        var result = try Script.call("idax_test_snippet", arguments: ScriptArguments())
        let succeeded = result.succeeded
        #expect(succeeded, "call failed: \(result.error)")
        var coerced: Int64? = nil
        if let value = result.takeValue() {
            coerced = try value.coerceToInteger()
        }
        #expect(coerced == 42)
    }

    @Test func compilingInvalidSourceReportsRatherThanThrows() throws {
        let compilation = try Script.compileText("this is not idc @@@")
        #expect(compilation.succeeded == false)
        #expect(!compilation.error.isEmpty)
    }

    @Test func listsFunctionNames() throws {
        // Enumerates IDC's registered and built-in functions, which a stock
        // database always has some of.
        let names = try Script.functionNames(prefix: "", maximum: 16)
        #expect(!names.isEmpty)
    }

    @Test func aZeroMaximumIsRejected() throws {
        var rejected = false
        do {
            _ = try Script.functionNames(prefix: "", maximum: 0)
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test func globalsAreWrittenReadBackAndDistinguishedFromAbsent() throws {
        var absentExists = false
        if let value = try Script.global("idax_test_absent_global") {
            absentExists = true
            _ = consume value
        }
        #expect(absentExists == false)

        let created = try Script.setGlobal(
            "idax_test_global", to: ScriptValue(integer: 123)
        )
        #expect(created)

        var readBack: Int64? = nil
        if let value = try Script.global("idax_test_global") {
            readBack = try value.coerceToInteger()
        }
        #expect(readBack == 123)

        // Writing again overwrites rather than creates.
        let createdAgain = try Script.setGlobal(
            "idax_test_global", to: ScriptValue(integer: 124)
        )
        #expect(createdAgain == false)

        var overwritten: Int64? = nil
        if let value = try Script.global("idax_test_global") {
            overwritten = try value.coerceToInteger()
        }
        #expect(overwritten == 124)
    }

    @Test func referencingAGlobalRequiresItToExist() throws {
        var rejected = false
        do {
            _ = try Script.referenceGlobal("idax_test_definitely_absent_global")
        } catch {
            rejected = true
        }
        #expect(rejected, "referencing an absent global should fail, not create it")

        try Script.setGlobal("idax_test_referenced", to: ScriptValue(integer: 5))
        let reference = try Script.referenceGlobal("idax_test_referenced")
        #expect(try reference.kind() == .reference)
        #expect(try reference.dereference().coerceToInteger() == 5)
    }

    @Test func resolvingAFileThatCannotExistYieldsNil() throws {
        // String? is Copyable, so this one can be asserted directly.
        #expect(try Script.resolveFile("idax_no_such_include_file.idc") == nil)
    }

    @Test func includePathsCanBeAppended() throws {
        // Appending an existing directory must be accepted; the assertion is
        // that the call is well-formed, since reading the list back is not
        // exposed by the C ABI.
        try Script.appendIncludePaths([FileManager.default.temporaryDirectory.path])
    }
}
