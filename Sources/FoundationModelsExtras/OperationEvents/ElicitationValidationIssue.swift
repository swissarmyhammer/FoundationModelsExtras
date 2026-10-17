import Foundation

/// Why an accepted form answer is not valid against its requested schema, as
/// data that a UI can localize.
///
/// ``ElicitationRequestedSchema/validationIssue(of:)`` gives this value.
/// ``ElicitationRequestedSchema/validationFailure(of:)`` gives
/// ``failureText``, the English sentence of the same issue.
public struct ElicitationValidationIssue: Sendable, Equatable {
    /// The type of value that a field takes.
    public enum ExpectedValue: Sendable, Equatable {
        /// A string: a string property or a single select.
        case string

        /// A finite number.
        case number

        /// A finite whole number: a number property of type
        /// ``ElicitationNumberSchema/NumberType/integer``.
        case wholeNumber

        /// `true` or `false`.
        case boolean

        /// A list of strings: a multi select.
        case stringList
    }

    /// The rule that the answer breaks, with the limit of that rule.
    public enum Kind: Sendable, Equatable {
        /// The field is in ``ElicitationRequestedSchema/required``, and the
        /// answer does not give it.
        case requiredFieldMissing

        /// The answer gives a key that is not in
        /// ``ElicitationRequestedSchema/properties``.
        case fieldNotInSchema

        /// The value is not of the type that the field takes.
        case wrongType(expected: ExpectedValue)

        /// The string has fewer Unicode code points than
        /// ``ElicitationStringSchema/minLength``.
        case tooShort(minLength: Int)

        /// The string has more Unicode code points than
        /// ``ElicitationStringSchema/maxLength``.
        case tooLong(maxLength: Int)

        /// The string does not match ``ElicitationStringSchema/pattern``.
        case patternMismatch(pattern: String)

        /// ``ElicitationStringSchema/pattern`` does not compile. This is a
        /// fault of the schema, not of the answer.
        case invalidPattern(pattern: String)

        /// The string does not have ``ElicitationStringSchema/format``.
        case invalidFormat(ElicitationStringFormat)

        /// The number is less than ``ElicitationNumberSchema/minimum``.
        case belowMinimum(Double)

        /// The number is more than ``ElicitationNumberSchema/maximum``.
        case aboveMaximum(Double)

        /// The value of a single select is not one of its values.
        case valueNotAllowed(allowed: [String])

        /// An item of a multi select is not one of its values. `value` is the
        /// first such item.
        case itemNotAllowed(value: String, allowed: [String])

        /// The multi select has fewer items than
        /// ``ElicitationMultiSelectSchema/minItems``.
        case tooFewItems(minItems: Int)

        /// The multi select has more items than
        /// ``ElicitationMultiSelectSchema/maxItems``.
        case tooManyItems(maxItems: Int)
    }

    /// The name of the field that failed, or `nil` when the issue is about the
    /// whole answer. Each kind of issue that the validation gives now names a
    /// field.
    public let field: String?

    /// The rule that the answer breaks.
    public let kind: Kind

    /// Makes an issue.
    ///
    /// - Parameters:
    ///   - field: The name of the field that failed, or `nil` for the whole
    ///     answer.
    ///   - kind: The rule that the answer breaks.
    public init(field: String?, kind: Kind) {
        self.field = field
        self.kind = kind
    }

    /// The English sentence of this issue, as
    /// ``ElicitationRequestedSchema/validationFailure(of:)`` gives it.
    ///
    /// For example, `the field "zip" does not match the pattern "^[0-9]{5}$"`.
    public var failureText: String {
        let subject = field.map(FailureText.field) ?? FailureText.wholeAnswer
        switch kind {
        case .requiredFieldMissing:
            return "\(subject) is required, and the answer does not give it"
        case .fieldNotInSchema:
            return "\(subject) is not in the requested schema"
        case .wrongType(let expected):
            return "\(subject) must be \(FailureText.words(for: expected))"
        case .tooShort(let minLength):
            return "\(subject) must have \(minLength) or more characters"
        case .tooLong(let maxLength):
            return "\(subject) must have \(maxLength) or fewer characters"
        case .patternMismatch(let pattern):
            return "\(subject) does not match the pattern \(FailureText.quoted(pattern))"
        case .invalidPattern(let pattern):
            return "the pattern \(FailureText.quoted(pattern)) of \(subject) is not a valid regular expression"
        case .invalidFormat(let format):
            return "\(subject) is not a valid \(FailureText.valueName(of: format))"
        case .belowMinimum(let minimum):
            return "\(subject) must be \(FailureText.number(minimum)) or more"
        case .aboveMaximum(let maximum):
            return "\(subject) must be \(FailureText.number(maximum)) or less"
        case .valueNotAllowed(let allowed):
            return "\(subject) must be one of these values: \(FailureText.quotedList(allowed))"
        case .itemNotAllowed(let value, let allowed):
            return "\(subject) has the value \(FailureText.quoted(value)), "
                + "which is not one of these values: \(FailureText.quotedList(allowed))"
        case .tooFewItems(let minItems):
            return "\(subject) must have \(minItems) or more values"
        case .tooManyItems(let maxItems):
            return "\(subject) must have \(maxItems) or fewer values"
        }
    }
}

/// The parts of the sentences that the validation gives.
private enum FailureText {
    /// The end of the text of a `Double` that is a whole number.
    private static let wholeNumberSuffix = ".0"

    /// The words that name the whole answer, for an issue with no field.
    static let wholeAnswer = "the answer"

    /// The words that name the field `name`.
    ///
    /// - Parameter name: The name of the field.
    /// - Returns: The words, for example `the field "zip"`.
    static func field(_ name: String) -> String {
        "the field \(quoted(name))"
    }

    /// `text` in double quotation marks.
    ///
    /// - Parameter text: The text.
    /// - Returns: The quoted text.
    static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }

    /// Each of `values` in double quotation marks, with commas between them.
    ///
    /// - Parameter values: The values.
    /// - Returns: The list, for example `"red", "green"`.
    static func quotedList(_ values: [String]) -> String {
        values.map(quoted).joined(separator: ", ")
    }

    /// The text of `value`, with no `.0` at the end of a whole number.
    ///
    /// - Parameter value: The number.
    /// - Returns: The text, for example `150` or `0.5`.
    static func number(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(wholeNumberSuffix) ? String(text.dropLast(wholeNumberSuffix.count)) : text
    }

    /// The words for a type of value.
    ///
    /// - Parameter expected: The type of value that a field takes.
    /// - Returns: The words, for example `a whole number`.
    static func words(for expected: ElicitationValidationIssue.ExpectedValue) -> String {
        switch expected {
        case .string: "a string"
        case .number: "a number"
        case .wholeNumber: "a whole number"
        case .boolean: "true or false"
        case .stringList: "a list of strings"
        }
    }

    /// The words for a value of `format`.
    ///
    /// - Parameter format: The format of a string field.
    /// - Returns: The words, for example `email address`.
    static func valueName(of format: ElicitationStringFormat) -> String {
        switch format {
        case .email: "email address"
        case .uri: "URI"
        case .date: "date (yyyy-MM-dd)"
        case .dateTime: "date and time (ISO 8601)"
        }
    }
}
