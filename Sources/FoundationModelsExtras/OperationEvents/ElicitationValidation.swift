import Foundation

extension ElicitationRequestedSchema {
    /// The start of the decline reason for an accepted form answer that is
    /// not valid.
    ///
    /// A host that finds a failure with ``validationFailure(of:)`` makes the
    /// reason of its decline as `invalidAnswerReasonPrefix + failure`.
    public static let invalidAnswerReasonPrefix = "the answer is not valid: "

    /// Tells why `content` is not a valid answer to this schema.
    ///
    /// The function is pure. It examines the fields in the order of their
    /// names, and gives the first failure that it finds:
    ///
    /// - A field in ``required`` that `content` does not give. `nil` content
    ///   gives no field.
    /// - A key of `content` that is not in ``properties``, when the schema
    ///   declares one or more properties. A schema with no properties asks
    ///   for a free answer: each key of the answer is then valid, and only
    ///   the ``required`` fields are checked.
    /// - A value of the wrong type. A string property and a single select take
    ///   ``ElicitationValue/string(_:)``, a number property takes
    ///   ``ElicitationValue/number(_:)`` (a finite number, and a whole number
    ///   when its type is ``ElicitationNumberSchema/NumberType/integer``;
    ///   NaN and infinity fail each number field), a boolean property
    ///   takes ``ElicitationValue/boolean(_:)``, and a multi select takes
    ///   ``ElicitationValue/stringArray(_:)``.
    /// - A value that breaks a rule of its property: the length, the pattern,
    ///   the format, the minimum and the maximum, the values of a select, and
    ///   the number of items of a multi select.
    ///
    /// The length and the pattern follow JSON Schema:
    ///
    /// - ``ElicitationStringSchema/minLength`` and
    ///   ``ElicitationStringSchema/maxLength`` count Unicode code points
    ///   (`String.unicodeScalars`), not Characters and not UTF-16 code units.
    ///   Thus `"e\u{301}"` has a length of 2, and `"👍"` has a length of 1.
    /// - ``ElicitationStringSchema/pattern`` is an ECMA-262 regular expression
    ///   with the meaning of the `u` flag and no other flag: the match works on
    ///   Unicode code points. The pattern is not anchored: the value is valid
    ///   when the pattern matches a part of it. A pattern that must match the
    ///   whole value starts with `^` and ends with `$`.
    ///
    /// The pattern runs on `NSRegularExpression` (ICU) after a translation that
    /// gives the ECMA-262 meaning to these parts:
    ///
    /// - `\d` and `\D` are `[0-9]` and its complement, `\w` and `\W` are
    ///   `[A-Za-z0-9_]` and its complement, and `\b` and `\B` use that `\w`.
    ///   ICU gives each of them a Unicode meaning: for example, ICU `\d`
    ///   matches the Arabic-Indic digit `"١"`, and ECMA-262 `\d` does not.
    /// - `\s` and `\S` also take U+000B and U+FEFF as white space, and `\v`
    ///   is U+000B. ICU `\v` is each vertical white space.
    /// - `.` matches each code point except `\n`, `\r`, U+2028 and U+2029.
    ///   ICU `.` also does not match U+0085.
    /// - `$` matches only at the end of the value. ICU `$` also matches before
    ///   a line terminator at the end.
    /// - `[]` matches nothing, and `[^]` matches each code point.
    /// - In a character class, `[` and `&` are literal, and `[\b]` is the
    ///   backspace U+0008. ICU reads `[` and `&&` in a class as set
    ///   operations.
    ///
    /// These gaps stay:
    ///
    /// - A pattern with syntax that only ICU knows compiles here, and
    ///   ECMA-262 rejects it or reads it in a different way: possessive
    ///   quantifiers, atomic groups, inline flags such as `(?i)`, `\Q…\E`,
    ///   `\x{…}`, and the escapes `\A`, `\z`, `\Z`, `\G`, `\X`, `\h`, `\H`,
    ///   `\V`, `\R` and `\N{…}`. With the `u` flag, ECMA-262
    ///   rejects an escape of a letter that has no meaning.
    /// - A pattern with syntax that only ECMA-262 knows does not compile here,
    ///   and the field fails: for example, `\u{…}`, or a backreference before
    ///   its group.
    /// - `--` in a class, and a range next to a class escape such as
    ///   `[\d-z]`, can have a different meaning.
    /// - The names in `\p{…}` are the names of ICU.
    ///
    /// A host calls this function before it sends or posts an accepted form
    /// answer. For example, a router that also posts the answer as mail to the
    /// model, or a UI that keeps a form open for a correction. When the
    /// function gives a failure, the host keeps the form open, or it sends
    /// `.decline(reason: ElicitationRequestedSchema.invalidAnswerReasonPrefix + failure)`
    /// in place of the accept. ``ToolContext/elicit(_:)`` does the same check
    /// before it gives an answer to a run.
    ///
    /// - Parameter content: The content of an accepted form answer.
    /// - Returns: `nil` when the content is valid, or one sentence that names
    ///   the first field that failed and the rule that it broke. The sentence
    ///   is the ``ElicitationValidationIssue/failureText`` of
    ///   ``validationIssue(of:)``.
    public func validationFailure(of content: [String: ElicitationValue]?) -> String? {
        validationIssue(of: content)?.failureText
    }

    /// Tells why `content` is not a valid answer to this schema, as data that
    /// a UI can localize.
    ///
    /// The function applies the rules of ``validationFailure(of:)`` in the
    /// same order, and gives the same first failure.
    ///
    /// - Parameter content: The content of an accepted form answer.
    /// - Returns: `nil` when the content is valid, or the issue of the first
    ///   field that failed.
    public func validationIssue(of content: [String: ElicitationValue]?) -> ElicitationValidationIssue? {
        let content = content ?? [:]
        let names = Set(required ?? []).union(content.keys).sorted()
        return names.lazy.compactMap { name in
            issueKind(ofField: name, in: content).map { ElicitationValidationIssue(field: name, kind: $0) }
        }.first
    }

    /// Tells why the field `name` of `content` is not valid.
    ///
    /// - Parameters:
    ///   - name: The name of a required field, or a key of `content`.
    ///   - content: The content of the answer.
    /// - Returns: `nil` when the field is valid, or the kind of its issue.
    private func issueKind(
        ofField name: String, in content: [String: ElicitationValue]
    ) -> ElicitationValidationIssue.Kind? {
        guard let value = content[name] else { return .requiredFieldMissing }
        guard let property = properties[name] else {
            // A schema with no properties asks for a free answer, so each key
            // of the answer is valid.
            return properties.isEmpty ? nil : .fieldNotInSchema
        }
        return property.issueKind(of: value)
    }
}

extension ElicitationPrimitiveSchema {
    /// Tells why `value` is not a valid value of this property.
    ///
    /// - Parameter value: The value in the answer.
    /// - Returns: `nil` when the value is valid, or the kind of its issue.
    fileprivate func issueKind(of value: ElicitationValue) -> ElicitationValidationIssue.Kind? {
        let wrongType = ElicitationValidationIssue.Kind.wrongType(expected: expectedValue)
        switch self {
        case .string(let schema):
            guard case .string(let text) = value else { return wrongType }
            return schema.issueKind(of: text)
        case .number(let schema):
            guard case .number(let number) = value, schema.admits(number) else { return wrongType }
            return schema.boundIssueKind(of: number)
        case .boolean:
            guard case .boolean = value else { return wrongType }
            return nil
        case .singleSelect(let schema):
            guard case .string(let choice) = value else { return wrongType }
            return schema.issueKind(of: choice)
        case .multiSelect(let schema):
            guard case .stringArray(let choices) = value else { return wrongType }
            return schema.issueKind(of: choices)
        }
    }

    /// The type of value that this property takes.
    private var expectedValue: ElicitationValidationIssue.ExpectedValue {
        switch self {
        case .string, .singleSelect: .string
        case .number(let schema): schema.type == .integer ? .wholeNumber : .number
        case .boolean: .boolean
        case .multiSelect: .stringList
        }
    }
}

extension ElicitationStringSchema {
    /// Tells why `text` is not a valid value of this property.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `nil` when the value is valid, or the kind of its issue.
    fileprivate func issueKind(of text: String) -> ElicitationValidationIssue.Kind? {
        lengthIssueKind(of: text) ?? patternIssueKind(of: text) ?? formatIssueKind(of: text)
    }

    /// Tells why the length of `text` is less than ``minLength`` or more than
    /// ``maxLength``. The length is the count of Unicode code points.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `nil` when the length is in its limits, or the kind of the
    ///   issue.
    private func lengthIssueKind(of text: String) -> ElicitationValidationIssue.Kind? {
        switch Bound.check(ElicitationValidation.codePointLength(text), minimum: minLength, maximum: maxLength) {
        case .within: nil
        case .below(let minimum): .tooShort(minLength: minimum)
        case .above(let maximum): .tooLong(maxLength: maximum)
        }
    }

    /// Tells why `text` does not match ``pattern``.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `nil` when there is no pattern or the pattern matches a part
    ///   of the value, or the kind of the issue.
    private func patternIssueKind(of text: String) -> ElicitationValidationIssue.Kind? {
        guard let pattern else { return nil }
        guard let matches = ElicitationValidation.patternMatches(text, pattern: pattern) else {
            return .invalidPattern(pattern: pattern)
        }
        return matches ? nil : .patternMismatch(pattern: pattern)
    }

    /// Tells why `text` does not have ``format``.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `nil` when there is no format or the value has it, or the
    ///   kind of the issue.
    private func formatIssueKind(of text: String) -> ElicitationValidationIssue.Kind? {
        guard let format, !format.accepts(text) else { return nil }
        return .invalidFormat(format)
    }
}

/// The text rules of an elicitation string field, for a client that checks
/// a form field before it sends the answer.
///
/// ``ElicitationRequestedSchema/validationFailure(of:)`` uses these
/// functions, thus a client that calls them gets the same result as the run
/// plane. The doc of ``ElicitationRequestedSchema/validationFailure(of:)``
/// gives the full rules and the gaps that stay.
public enum ElicitationValidation {
    /// Tells if the ECMA-262 regular expression `pattern` matches a part of
    /// `text`.
    ///
    /// The check is a search, as JSON Schema `pattern` is: a pattern with no
    /// `^` and no `$` can match in the middle of `text`. The pattern has the
    /// meaning of the ECMA-262 `u` flag (code points), and no other flag.
    ///
    /// - Parameters:
    ///   - text: The value of the field.
    ///   - pattern: An ECMA-262 regular expression with the `u` flag only.
    /// - Returns: `nil` when `pattern` does not compile, `true` when a match
    ///   is in `text`, and `false` when no match is in `text`.
    public static func patternMatches(_ text: String, pattern: String) -> Bool? {
        ECMAPattern.search(text, for: pattern)
    }

    /// The length of `text` for `minLength` and `maxLength`: the count of its
    /// Unicode code points, as JSON Schema counts it.
    ///
    /// For example, "👍" has the length 1, "e" followed by U+0301 has the
    /// length 2, and a family emoji of three persons has the length 5.
    ///
    /// - Parameter text: The value of the field.
    /// - Returns: The count of the Unicode code points of `text`.
    public static func codePointLength(_ text: String) -> Int {
        text.unicodeScalars.count
    }
}

/// The search of an ECMA-262 pattern, on `NSRegularExpression`.
///
/// ``ElicitationRequestedSchema/validationFailure(of:)`` tells which parts of
/// the pattern get their ECMA-262 meaning, and which gaps stay.
private enum ECMAPattern {
    /// The code points of ECMA-262 `\w`, for a character class.
    private static let wordMembers = "A-Za-z0-9_"

    /// The code points of ECMA-262 `\d`, for a character class.
    private static let digitMembers = "0-9"

    /// The code points of ECMA-262 `\s`, for a character class: ICU `\s`, and
    /// the two code points that ICU `\s` does not have.
    private static let spaceMembers = "\\s\\x{0B}\\x{FEFF}"

    /// ECMA-262 `.`: each code point except a line terminator.
    private static let anyButLineTerminator = "[^\\n\\r\\x{2028}\\x{2029}]"

    /// ECMA-262 `\b`, with the `\w` of ECMA-262.
    private static let wordBoundary =
        "(?:(?<=[\(wordMembers)])(?![\(wordMembers)])|(?<![\(wordMembers)])(?=[\(wordMembers)]))"

    /// ECMA-262 `\B`, with the `\w` of ECMA-262.
    private static let notWordBoundary =
        "(?:(?<=[\(wordMembers)])(?=[\(wordMembers)])|(?<![\(wordMembers)])(?![\(wordMembers)]))"

    /// Tells if `pattern` matches a part of `text`.
    ///
    /// - Parameters:
    ///   - text: The value in the answer.
    ///   - pattern: An ECMA-262 regular expression with the `u` flag only.
    /// - Returns: `nil` when `pattern` does not compile, else whether a match
    ///   is in `text`.
    static func search(_ text: String, for pattern: String) -> Bool? {
        guard let regex = try? NSRegularExpression(pattern: icuPattern(of: pattern)) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The ICU form of the ECMA-262 `pattern`.
    ///
    /// The translation reads the pattern one code point at a time, and it
    /// knows if it is in a character class. It changes only the parts that
    /// the doc of ``ElicitationRequestedSchema/validationFailure(of:)`` names,
    /// and it copies each other part.
    ///
    /// - Parameter pattern: An ECMA-262 regular expression with the `u` flag only.
    /// - Returns: The ICU regular expression.
    static func icuPattern(of pattern: String) -> String {
        let scalars = Array(pattern.unicodeScalars)
        var output = ""
        var isInClass = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if scalar == "\\", let next {
                output += (isInClass ? classEscape(next) : escape(next)) ?? "\\\(next)"
                index += 2
                continue
            }
            if isInClass {
                switch scalar {
                case "]": isInClass = false; output += "]"
                case "[", "&": output += "\\\(scalar)"
                default: output.unicodeScalars.append(scalar)
                }
                index += 1
                continue
            }
            switch scalar {
            case "[":
                let afterCaret = index + 2 < scalars.count ? scalars[index + 2] : nil
                if next == "]" {
                    output += "(?!)"
                    index += 2
                    continue
                }
                if next == "^", afterCaret == "]" {
                    output += "[\\s\\S]"
                    index += 3
                    continue
                }
                isInClass = true
                output += "["
                if next == "^" {
                    output += "^"
                    index += 1
                }
            case ".": output += anyButLineTerminator
            case "$": output += "\\z"
            default: output.unicodeScalars.append(scalar)
            }
            index += 1
        }
        return output
    }

    /// The ICU form of the escape `\` + `letter` out of a character class.
    ///
    /// - Parameter letter: The code point after the backslash.
    /// - Returns: The ICU form, or `nil` when the escape stays as it is.
    private static func escape(_ letter: Unicode.Scalar) -> String? {
        switch letter {
        case "d": "[\(digitMembers)]"
        case "D": "[^\(digitMembers)]"
        case "w": "[\(wordMembers)]"
        case "W": "[^\(wordMembers)]"
        case "s": "[\(spaceMembers)]"
        case "S": "[^\(spaceMembers)]"
        case "b": wordBoundary
        case "B": notWordBoundary
        case "v": "\\x{0B}"
        default: nil
        }
    }

    /// The ICU form of the escape `\` + `letter` in a character class. A
    /// complement goes in as a nested set, which ICU adds to the class.
    ///
    /// - Parameter letter: The code point after the backslash.
    /// - Returns: The ICU form, or `nil` when the escape stays as it is.
    private static func classEscape(_ letter: Unicode.Scalar) -> String? {
        switch letter {
        case "d": digitMembers
        case "D": "[^\(digitMembers)]"
        case "w": wordMembers
        case "W": "[^\(wordMembers)]"
        case "s": spaceMembers
        case "S": "[^\(spaceMembers)]"
        case "b": "\\x{08}"
        case "v": "\\x{0B}"
        default: nil
        }
    }
}

extension ElicitationStringFormat {
    /// Tells if `text` has this format.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `true` when `text` has this format.
    fileprivate func accepts(_ text: String) -> Bool {
        switch self {
        case .email: text.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[^@\s]+/#) != nil
        case .uri: !(URL(string: text)?.scheme ?? "").isEmpty
        case .date: Self.isCalendarDate(text)
        case .dateTime: Self.isDateTime(text)
        }
    }

    /// Tells if `text` is a date of the form `yyyy-MM-dd` that the calendar
    /// has.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `true` when `text` is such a date.
    private static func isCalendarDate(_ text: String) -> Bool {
        guard let parts = text.wholeMatch(of: #/([0-9]{4})-([0-9]{2})-([0-9]{2})/#)?.output,
            let year = Int(parts.1), let month = Int(parts.2), let day = Int(parts.3)
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return DateComponents(year: year, month: month, day: day).isValidDate(in: calendar)
    }

    /// Tells if `text` is an ISO 8601 date with a time and a time zone, with
    /// or without fractional seconds.
    ///
    /// - Parameter text: The value in the answer.
    /// - Returns: `true` when `text` is such a date and time.
    private static func isDateTime(_ text: String) -> Bool {
        let whole = ISO8601DateFormatter()
        whole.formatOptions = .withInternetDateTime
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return whole.date(from: text) != nil || fractional.date(from: text) != nil
    }
}

extension ElicitationNumberSchema {
    /// Tells if `number` is of ``type``: a finite number, or a finite whole
    /// number for ``NumberType/integer``. NaN, infinity and minus infinity
    /// are not JSON numbers, thus no field takes them.
    ///
    /// - Parameter number: The value in the answer.
    /// - Returns: `true` when `number` is of the type.
    fileprivate func admits(_ number: Double) -> Bool {
        number.isFinite && (type == .number || number == number.rounded())
    }

    /// Tells why `number` is less than ``minimum`` or more than ``maximum``.
    ///
    /// - Parameter number: The value in the answer.
    /// - Returns: `nil` when the value is in its limits, or the kind of the
    ///   issue.
    fileprivate func boundIssueKind(of number: Double) -> ElicitationValidationIssue.Kind? {
        switch Bound.check(number, minimum: minimum, maximum: maximum) {
        case .within: nil
        case .below(let minimum): .belowMinimum(minimum)
        case .above(let maximum): .aboveMaximum(maximum)
        }
    }
}

extension ElicitationSingleSelectSchema {
    /// Tells why `choice` is not one of ``values``.
    ///
    /// - Parameter choice: The value in the answer.
    /// - Returns: `nil` when `choice` is one of the values, or the kind of the
    ///   issue.
    fileprivate func issueKind(of choice: String) -> ElicitationValidationIssue.Kind? {
        values.contains(choice) ? nil : .valueNotAllowed(allowed: values)
    }
}

extension ElicitationMultiSelectSchema {
    /// Tells why `choices` is not a valid selection: an item that is not one
    /// of ``values``, fewer items than ``minItems``, or more items than
    /// ``maxItems``.
    ///
    /// - Parameter choices: The value in the answer.
    /// - Returns: `nil` when the selection is valid, or the kind of its issue.
    fileprivate func issueKind(of choices: [String]) -> ElicitationValidationIssue.Kind? {
        if let unknown = choices.first(where: { !values.contains($0) }) {
            return .itemNotAllowed(value: unknown, allowed: values)
        }
        switch Bound.check(choices.count, minimum: minItems, maximum: maxItems) {
        case .within: return nil
        case .below(let minimum): return .tooFewItems(minItems: minimum)
        case .above(let maximum): return .tooManyItems(maxItems: maximum)
        }
    }
}

/// Where a value is, relative to an optional minimum and an optional maximum.
private enum Bound<Value: Comparable> {
    /// The value is in its limits.
    case within

    /// The value is less than this minimum.
    case below(Value)

    /// The value is more than this maximum.
    case above(Value)

    /// Compares `value` with `minimum`, then with `maximum`.
    ///
    /// - Parameters:
    ///   - value: The value to compare.
    ///   - minimum: The smallest value that is in the limits, or `nil`.
    ///   - maximum: The largest value that is in the limits, or `nil`.
    /// - Returns: Where `value` is, relative to the limits.
    static func check(_ value: Value, minimum: Value?, maximum: Value?) -> Bound {
        if let minimum, value < minimum {
            return .below(minimum)
        }
        if let maximum, value > maximum {
            return .above(maximum)
        }
        return .within
    }
}
