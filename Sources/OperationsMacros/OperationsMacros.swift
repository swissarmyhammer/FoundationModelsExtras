import Foundation
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Diagnostics

/// Diagnostic messages emitted while expanding `@Operation`.
internal enum OperationMacroDiagnostic: DiagnosticMessage {
    /// `@Operation` was attached to a declaration that isn't a struct.
    case requiresStruct

    /// The `verb` argument was absent or an empty string literal.
    case verbMustNotBeEmpty

    /// The `noun` argument was absent or an empty string literal.
    case nounMustNotBeEmpty

    /// A stored property's name normalizes to `"op"`, colliding with the
    /// fused-tool discriminator field.
    case reservedParameterName(String)

    /// A stored property's type isn't one `@Operation` can map to a
    /// `ParamType`.
    case unsupportedParameterType(String)

    internal var message: String {
        switch self {
        case .requiresStruct:
            return "'@Operation' can only be applied to a struct"
        case .verbMustNotBeEmpty:
            return "'@Operation' requires a non-empty 'verb' string literal argument"
        case .nounMustNotBeEmpty:
            return "'@Operation' requires a non-empty 'noun' string literal argument"
        case .reservedParameterName(let name):
            return
                "parameter '\(name)' is reserved: it normalizes to '\(opFieldName)', which collides with the fused-tool discriminator field"
        case .unsupportedParameterType(let name):
            return
                "parameter '\(name)' has an unsupported type; '@Operation' supports String, Int, Double, Float, Bool, Array of those, and Optional wrapping any of those"
        }
    }

    internal var diagnosticID: MessageID {
        MessageID(domain: "OperationsMacros", id: "Operation.\(self)")
    }

    internal var severity: DiagnosticSeverity { .error }
}

extension OperationMacroDiagnostic {
    internal func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(node: Syntax(node), message: self)
    }
}

// MARK: - Syntax helpers

extension LabeledExprListSyntax {
    /// Retrieves the first element with the given argument label.
    fileprivate func first(labeled name: String) -> Element? {
        first { $0.label?.text == name }
    }
}

extension ExprSyntax {
    /// The literal string value of this expression, if it is a plain string
    /// literal with no interpolation.
    fileprivate var plainStringLiteralValue: String? {
        guard let literal = self.as(StringLiteralExprSyntax.self),
            literal.segments.count == 1,
            case .stringSegment(let segment)? = literal.segments.first
        else {
            return nil
        }
        return segment.content.text
    }
}

extension DeclModifierSyntax {
    fileprivate var isNeededAccessLevelModifier: Bool {
        switch name.tokenKind {
        case .keyword(.public): return true
        default: return false
        }
    }
}

/// Escapes `value` as the contents of a Swift double-quoted string literal.
private func swiftStringLiteral(_ value: String) -> String {
    var escaped = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        default: escaped.unicodeScalars.append(scalar)
        }
    }
    return "\"\(escaped)\""
}

/// Source text of an empty Swift string literal, used as the default `verb`,
/// `noun`, and `description` text when the corresponding `@Operation(...)`
/// argument is absent.
private let emptyStringLiteralText = "\"\""

/// The fused-tool discriminator field name.
///
/// The single source of truth, within
/// this file, for the reserved parameter name (the reserved-name check, its
/// diagnostic message, and the discriminator key `commandStructText(...)`
/// emits into the generated `Command`'s payload all reference this constant
/// instead of repeating the literal). Mirrors `SchemaFusion.swift`'s
/// identically named, identically valued `opFieldName` — duplicated rather
/// than shared because that file lives in a runtime target this
/// compiler-plugin target cannot depend on.
private let opFieldName = "op"

/// Normalizes `name` by lowercasing it and stripping `_`/`-` separators, for
/// comparison against `opFieldName`.
///
/// Deliberately mirrors the runtime `Operations` target's
/// `OperationKeys.normalized(_:)` algorithm rather than calling it: this
/// compiler-plugin target cannot depend on that runtime target (the same
/// constraint documented on `opFieldName` above), so the reserved-name check
/// in `operationParameterEntry(for:identifierPattern:variable:in:)` needs its
/// own copy. If `OperationKeys.normalized(_:)`'s algorithm ever changes, this
/// must change with it.
private func normalized(_ name: String) -> String {
    name.lowercased().filter { $0 != "_" && $0 != "-" }
}

/// Extracts a joined description from a stored property's `///` doc-comment
/// trivia, or `nil` if it carries none.
private func docCommentDescription(from trivia: Trivia) -> String? {
    let lines = trivia.compactMap { piece -> String? in
        guard case .docLineComment(let text) = piece else { return nil }
        var line = Substring(text)
        if line.hasPrefix("///") {
            line = line.dropFirst(3)
        }
        return String(line).trimmingCharacters(in: .whitespaces)
    }
    let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return joined.isEmpty ? nil : joined
}

// MARK: - Type mapping

/// Maps a supported primitive Swift type name to the source text of its
/// corresponding `ParamType` case.
///
/// The single source of truth for which
/// primitive types `@Operation` supports, so adding or changing a mapping is
/// a one-line edit instead of a switch arm kept in sync by hand.
private let primitiveTypeMapping: [String: String] = [
    "String": ".string",
    "Int": ".integer",
    "Double": ".number",
    "Float": ".number",
    "Bool": ".boolean",
]

/// Maps a non-`Optional` field type to the source text of a `ParamType`
/// expression (e.g. `.string`, `.array(of: .string)`), or `nil` if the type
/// isn't one `@Operation` supports.
private func primitiveParamTypeExprText(_ type: TypeSyntax) -> String? {
    if let arrayType = type.as(ArrayTypeSyntax.self) {
        guard let elementText = primitiveParamTypeExprText(arrayType.element) else { return nil }
        return ".array(of: \(elementText))"
    }
    if let identifierType = type.as(IdentifierTypeSyntax.self) {
        return primitiveTypeMapping[identifierType.name.text]
    }
    return nil
}

/// Unwraps a single level of `Optional` (`T?`) from `type`, deriving
/// `required` (`Optional` ⇒ `false`).
///
/// Shared by `operationParameterEntry(for:identifierPattern:variable:in:)`,
/// which unwraps a property's type once and reuses the result to derive both
/// its `ParamType` source text (via `primitiveParamTypeExprText(_:)`) and its
/// `CommandFieldKind` (via `commandFieldKind(for:)`).
private func unwrappingOptional(_ type: TypeSyntax) -> (wrapped: TypeSyntax, required: Bool) {
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return (optionalType.wrappedType, false)
    }
    return (type, true)
}

// MARK: - Command field mapping

/// The nested `Command`'s CLI representation of one parameter: which
/// `ArgumentParser` property wrapper `@Operation` synthesizes for it.
private enum CommandFieldKind {
    /// `Bool` ⇒ `@Flag`, a presence-only switch defaulting to `false`.
    case flag

    /// `[Element]` ⇒ `@Option`, repeatable (one CLI value per occurrence),
    /// defaulting to an empty array.
    ///
    /// `elementTypeText` is the array element's Swift type name (e.g.
    /// `"String"`), used verbatim in the generated property's type
    /// annotation.
    case repeatableOption(elementTypeText: String)

    /// A scalar primitive ⇒ `@Option`.
    ///
    /// `typeText` is the property's Swift type name (e.g. `"String"`,
    /// `"Int"`), used verbatim in the generated property's type annotation.
    case scalarOption(typeText: String)
}

/// Maps a non-`Optional` field type to the `CommandFieldKind` `@Operation`
/// synthesizes for it, or `nil` if the type has no CLI representation.
///
/// Array element types are restricted to one level of primitive (no nested
/// arrays): `ArgumentParser`'s repeatable `@Option` needs its element type to
/// itself conform to `ExpressibleByArgument`, which none of the primitives'
/// own array forms do.
private func commandFieldKind(for type: TypeSyntax) -> CommandFieldKind? {
    if let arrayType = type.as(ArrayTypeSyntax.self) {
        guard let elementIdentifier = arrayType.element.as(IdentifierTypeSyntax.self),
            primitiveTypeMapping[elementIdentifier.name.text] != nil
        else { return nil }
        return .repeatableOption(elementTypeText: elementIdentifier.name.text)
    }
    guard let identifierType = type.as(IdentifierTypeSyntax.self),
        primitiveTypeMapping[identifierType.name.text] != nil
    else { return nil }
    return identifierType.name.text == "Bool" ? .flag : .scalarOption(typeText: identifierType.name.text)
}

// MARK: - `@Guide` / `@OperationParam` introspection

/// Finds every attribute named `name` in `attributes` and yields its
/// argument list, skipping attributes that carry no parenthesized arguments.
///
/// Shared by `guideInfo(from:)` and `operationParamInfo(from:)`, which differ
/// only in the attribute name they look for.
private func argumentLists(
    forAttributeNamed name: String,
    in attributes: AttributeListSyntax
) -> [LabeledExprListSyntax] {
    attributes.compactMap { element in
        guard case .attribute(let attribute) = element,
            attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == name,
            case .argumentList(let arguments) = attribute.arguments
        else {
            return nil
        }
        return arguments
    }
}

/// Description and `anyOf` allowed values recognized from a property's
/// `@Guide(...)` attribute, per plan.md's extraction contract: only literal
/// `description:` strings and a literal `.anyOf([...])` guide are read;
/// every other `@Guide` constraint form is left to Apple's schema.
private func guideInfo(from attributes: AttributeListSyntax) -> (description: String?, allowedValues: [String]?) {
    var description: String?
    var allowedValues: [String]?

    for arguments in argumentLists(forAttributeNamed: "Guide", in: attributes) {
        for argument in arguments {
            if argument.label?.text == "description", let literal = argument.expression.plainStringLiteralValue {
                description = literal
            } else if argument.label == nil, let values = anyOfAllowedValues(from: argument.expression) {
                allowedValues = values
            }
        }
    }

    return (description, allowedValues)
}

/// Recognizes a `.anyOf(["a", "b"])` `GenerationGuide` expression and
/// extracts its literal string values, or `nil` if the expression isn't that
/// recognized shape.
private func anyOfAllowedValues(from expr: ExprSyntax) -> [String]? {
    guard let call = expr.as(FunctionCallExprSyntax.self),
        let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
        memberAccess.base == nil,
        memberAccess.declName.baseName.text == "anyOf",
        call.arguments.count == 1,
        let arrayExpr = call.arguments.first?.expression.as(ArrayExprSyntax.self)
    else {
        return nil
    }

    var values: [String] = []
    for element in arrayExpr.elements {
        guard let literal = element.expression.plainStringLiteralValue else { return nil }
        values.append(literal)
    }
    return values
}

/// The `@OperationParam(short:)` argument label.
///
/// The single source of truth for this name, matching `aliasesLabel`'s and
/// `allowedValuesLabel`'s role for their own labels.
private let shortLabel = "short"

/// The `@OperationParam(aliases:)` argument label.
///
/// Also the `ParamMeta`
/// initializer argument label `operationParameterEntry(for:identifierPattern:variable:in:)`
/// emits for it, since `@OperationParam`'s array-valued arguments round-trip
/// directly into `ParamMeta`'s same-named initializer arguments — the two
/// must agree by design. The single source of truth for this name; every
/// other reference in this file uses this constant instead of repeating the
/// literal.
private let aliasesLabel = "aliases"

/// The `@OperationParam(allowedValues:)` argument label, and the
/// corresponding `ParamMeta(allowedValues:)` initializer argument label.
///
/// See
/// `aliasesLabel`'s documentation for why the two labels coincide, and why
/// this is the single source of truth for this name.
private let allowedValuesLabel = "allowedValues"

/// Labels of `@OperationParam(...)` arguments whose value is a string-array
/// literal.
///
/// Driving `operationParamInfo(from:)`'s loop from this table —
/// rather than one hand-written `case` branch per label — keeps `aliases`
/// and `allowedValues` a single code path instead of two copies that differ
/// only by name.
private let operationParamArrayArgumentLabels = [aliasesLabel, allowedValuesLabel]

/// Applies a single `@OperationParam(...)` argument to the accumulated
/// `short`/array-argument state, if it matches a recognized argument label.
///
/// Unrecognized labels (and labels whose value doesn't match the expected
/// shape) are left untouched. Extracted from `operationParamInfo(from:)`'s
/// inner loop so that function's control flow doesn't nest a loop inside a
/// loop inside a conditional.
private func applyOperationParamArgument(
    _ argument: LabeledExprListSyntax.Element,
    short: inout Character?,
    arrayArguments: inout [String: [String]]
) {
    guard let label = argument.label?.text else { return }

    if label == shortLabel {
        guard let literal = argument.expression.plainStringLiteralValue, let first = literal.first else { return }
        short = first
        return
    }

    guard operationParamArrayArgumentLabels.contains(label),
        let arrayExpr = argument.expression.as(ArrayExprSyntax.self)
    else { return }
    arrayArguments[label] = arrayExpr.elements.compactMap { $0.expression.plainStringLiteralValue }
}

/// CLI affordances recognized from a property's `@OperationParam(...)`
/// attribute.
private func operationParamInfo(
    from attributes: AttributeListSyntax
) -> (short: Character?, aliases: [String], allowedValues: [String]?) {
    var short: Character?
    var arrayArguments: [String: [String]] = [:]

    for arguments in argumentLists(forAttributeNamed: "OperationParam", in: attributes) {
        for argument in arguments {
            applyOperationParamArgument(argument, short: &short, arrayArguments: &arrayArguments)
        }
    }

    return (short, arrayArguments[aliasesLabel] ?? [], arrayArguments[allowedValuesLabel])
}

// MARK: - `@Operation`

/// Implements the `@Operation` attached macro declared in the `Operations`
/// module.
///
/// Synthesizes `OperationDefinition` conformance on the annotated struct:
/// `verb`/`noun`/`operationDescription` statics, a `parameterMetadata`
/// table derived from its stored properties, and a nested `Command:
/// AsyncParsableCommand` (ArgumentParser leaf) for the dual-use CLI built
/// from that same property data.
public struct OperationMacro: ExtensionMacro {
    /// Expands `@Operation(verb:noun:description:)` into an
    /// `OperationDefinition` conformance extension on the annotated struct.
    ///
    /// - Parameters:
    ///   - node: The `@Operation(...)` attribute syntax; its `verb`, `noun`,
    ///     and `description` arguments seed the synthesized statics.
    ///   - declaration: The declaration the attribute is attached to. Must
    ///     be a `StructDeclSyntax`; otherwise `.requiresStruct` is diagnosed
    ///     and expansion produces no extension.
    ///   - type: The type being extended, used as the generated extension's
    ///     subject.
    ///   - protocols: The protocols this expansion was asked to conform to.
    ///     Unused: `OperationDefinition` conformance is always synthesized
    ///     regardless of this list.
    ///   - context: The macro expansion context used to emit diagnostics
    ///     (unsupported types, empty `verb`/`noun`, reserved parameter
    ///     names).
    /// - Returns: A single-element array containing the synthesized
    ///   `OperationDefinition` conformance extension, or an empty array if
    ///   `declaration` isn't a struct or `node` carries no argument list.
    /// - Throws: Rethrows from `ExtensionDeclSyntax`'s string-interpolation
    ///   initializer if the assembled extension source text fails to parse
    ///   into valid syntax — an internal invariant violation of this
    ///   function's own code generation, not an outcome triggerable by
    ///   `@Operation` usage; invalid attribute arguments are diagnosed
    ///   instead of thrown.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(OperationMacroDiagnostic.requiresStruct.diagnose(at: declaration))
            return []
        }

        guard case .argumentList(let arguments) = node.arguments else {
            return []
        }

        let (verbText, nounText, descriptionText) = verbNounDescriptionText(from: arguments, node: node, in: context)

        let parameterEntries = synthesizeOperationParameters(from: structDecl, in: context)
        let parameterMetadataText =
            parameterEntries.isEmpty
            ? "[]"
            : "[\n\(parameterEntries.map { "    \($0.paramMetaText)," }.joined(separator: "\n"))\n]"

        let access = structDecl.modifiers.first(where: \.isNeededAccessLevelModifier)
        let accessText = access.map { "\($0.name.text) " } ?? ""

        let commandText = commandStructText(
            accessText: accessText,
            structTypeName: type.trimmedDescription,
            verbText: verbText,
            descriptionText: descriptionText,
            fields: parameterEntries.compactMap(\.commandField)
        )

        // The `OperationDefinition`/`HasCLICommand` conformance's static
        // members, the nested `Command` declaration, and the `CLICommand`
        // typealias satisfying `HasCLICommand` (see `Operations.swift`'s
        // `@Operation` doc comment).
        let membersText = """
            \(accessText)static let verb: String = \(verbText)
            \(accessText)static let noun: String = \(nounText)
            \(accessText)static let operationDescription: String = \(descriptionText)
            \(accessText)static let parameterMetadata: [ParamMeta] = \(parameterMetadataText)

            \(commandText)

            \(accessText)typealias CLICommand = Command
            """

        let extensionDecl = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): OperationDefinition, HasCLICommand {
            \(raw: membersText)
            }
            """
        )

        return [extensionDecl]
    }
}

/// Diagnoses `expr` (via `context`) against `diagnostic`'s non-empty-string
/// requirement when it is absent or an empty string literal.
///
/// Shared by the
/// `verb` and `noun` checks in `verbNounDescriptionText(from:node:in:)`,
/// which otherwise differ only in the expression and diagnostic case.
///
/// - Parameters:
///   - expr: The argument expression to validate, or `nil` if the argument
///     was omitted entirely.
///   - diagnostic: The diagnostic to emit when validation fails.
///   - node: The attribute syntax, used as the diagnostic location when
///     `expr` is `nil` (so there's no argument expression to point at).
///   - context: The macro expansion context used to emit the diagnostic.
private func validateNonEmptyStringArgument(
    expr: ExprSyntax?,
    diagnostic: OperationMacroDiagnostic,
    node: AttributeSyntax,
    in context: some MacroExpansionContext
) {
    if expr?.plainStringLiteralValue?.isEmpty ?? (expr == nil) {
        context.diagnose(diagnostic.diagnose(at: expr.map(Syntax.init) ?? Syntax(node)))
    }
}

/// Derives the source text of `verb`, `noun`, and `description` from an
/// `@Operation(...)` attribute's argument list, diagnosing (via `context`)
/// when `verb` or `noun` is missing entirely or is an empty string literal.
///
/// - Parameters:
///   - arguments: The `@Operation(...)` attribute's argument list.
///   - node: The attribute syntax, used as the diagnostic location when
///     `verb`/`noun` is missing entirely (so there's no argument expression
///     to point the diagnostic at).
///   - context: The macro expansion context used to emit diagnostics.
/// - Returns: The source text of the `verb`, `noun`, and `description`
///   argument expressions, each defaulting to `emptyStringLiteralText` when
///   absent.
private func verbNounDescriptionText(
    from arguments: LabeledExprListSyntax,
    node: AttributeSyntax,
    in context: some MacroExpansionContext
) -> (verbText: String, nounText: String, descriptionText: String) {
    let verbExpr = arguments.first(labeled: "verb")?.expression
    let nounExpr = arguments.first(labeled: "noun")?.expression
    let descriptionExpr = arguments.first(labeled: "description")?.expression

    validateNonEmptyStringArgument(expr: verbExpr, diagnostic: .verbMustNotBeEmpty, node: node, in: context)
    validateNonEmptyStringArgument(expr: nounExpr, diagnostic: .nounMustNotBeEmpty, node: node, in: context)

    let verbText = verbExpr?.trimmedDescription ?? emptyStringLiteralText
    let nounText = nounExpr?.trimmedDescription ?? emptyStringLiteralText
    let descriptionText = descriptionExpr?.trimmedDescription ?? emptyStringLiteralText

    return (verbText, nounText, descriptionText)
}

/// Diagnoses `propertyName` (via `context`) as having an unsupported
/// parameter type at `location`.
///
/// Shared by both unsupported-type call sites
/// in `operationParameterEntry(for:identifierPattern:variable:in:)` — a
/// missing type annotation and a type `primitiveParamTypeExprText(_:)` can't
/// map — which otherwise differ only in the diagnostic's location.
private func diagnoseUnsupportedParameterType(
    _ propertyName: String,
    at location: some SyntaxProtocol,
    in context: some MacroExpansionContext
) {
    context.diagnose(OperationMacroDiagnostic.unsupportedParameterType(propertyName).diagnose(at: location))
}

/// Formats `"\(key): [...]"` as the source text of a `ParamMeta(...)`
/// array-valued argument.
///
/// Shared by the `aliases` and `allowedValues`
/// entries `operationParameterEntry(for:identifierPattern:variable:in:)`
/// builds for its `ParamMeta(...)` argument list, which otherwise differ
/// only in the key, source collection, and when the argument is omitted
/// entirely.
private func arrayArgumentText(key: String, values: [String]) -> String {
    let valuesText = values.map(swiftStringLiteral).joined(separator: ", ")
    return "\(key): [\(valuesText)]"
}

/// One nested `Command` property: everything `commandFieldDeclarationText(_:)`
/// and `payloadAssignmentText(_:)` need to declare its `@Flag`/`@Option` and
/// fold its parsed value into `operationPayload()`'s payload.
fileprivate struct CommandFieldSpec {
    /// The parameter's name, shared with its `ParamMeta` entry's `name`.
    fileprivate let name: String

    /// Which `ArgumentParser` property wrapper this parameter maps to.
    fileprivate let kind: CommandFieldKind

    /// Whether the CLI must supply this parameter.
    ///
    /// Meaningful only for
    /// `.scalarOption` (a required scalar has no default and no `?`); a
    /// `.flag` and a `.repeatableOption` are always optional at the CLI
    /// layer regardless of the parameter's own requiredness.
    fileprivate let required: Bool

    /// Help text, shared with its `ParamMeta` entry's `description`.
    fileprivate let description: String

    /// A single-character CLI short flag, if `@OperationParam(short:)`
    /// supplied one.
    fileprivate let short: Character?
}

/// One eligible stored property's synthesized data: everything both the
/// `parameterMetadata` table and the nested `Command` need for that
/// property.
///
/// Building both from one pass over `structDecl`'s stored
/// properties, rather than two separate traversals, keeps eligibility rules
/// (skip computed/static, diagnose reserved names and unsupported types) and
/// description/`@OperationParam` extraction a single code path instead of
/// two copies that could drift — and avoids diagnosing the same invalid
/// property twice.
fileprivate struct OperationParameterEntry {
    /// The synthesized `ParamMeta(...)` call-expression source text.
    fileprivate let paramMetaText: String

    /// The nested `Command`'s CLI representation of this parameter, or
    /// `nil` when the type has no CLI representation `@Operation` can
    /// generate (e.g. a nested array) — distinct from, and a strict subset
    /// of, the types `primitiveParamTypeExprText(_:)` accepts for
    /// `ParamMeta`, so such a property still gets a `ParamMeta` entry but no
    /// `Command` field (see `commandFieldKind(for:)`).
    fileprivate let commandField: CommandFieldSpec?
}

/// Synthesizes one `OperationParameterEntry` per eligible stored property of
/// `structDecl`, in declaration order.
///
/// Computed properties (an accessor block present), `static` properties, and
/// properties without a type annotation are skipped. Diagnoses (via
/// `context`) and skips properties with the reserved name `"op"` or with a
/// type `@Operation` can't map to a `ParamType`.
///
/// - Parameters:
///   - structDecl: The struct declaration whose stored properties become
///     parameters.
///   - context: The macro expansion context used to emit diagnostics for
///     invalid properties.
/// - Returns: One entry per eligible property.
private func synthesizeOperationParameters(
    from structDecl: StructDeclSyntax,
    in context: some MacroExpansionContext
) -> [OperationParameterEntry] {
    structDecl.memberBlock.members.flatMap { member -> [OperationParameterEntry] in
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { return [] }
        guard !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else { return [] }

        return variable.bindings.compactMap { binding -> OperationParameterEntry? in
            // Computed properties (accessor block present) aren't parameters.
            guard binding.accessorBlock == nil else { return nil }
            guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }

            return operationParameterEntry(
                for: binding,
                identifierPattern: identifierPattern,
                variable: variable,
                in: context
            )
        }
    }
}

/// Builds the `OperationParameterEntry` for one candidate stored-property
/// binding, or `nil` (after diagnosing via `context`) when the property has
/// no type annotation, uses the reserved `"op"` name, or has a type
/// `@Operation` can't map to a `ParamType`.
///
/// - Parameters:
///   - binding: The candidate property's pattern binding. Callers have
///     already confirmed it's non-computed (no accessor block) and its
///     pattern is an identifier pattern.
///   - identifierPattern: `binding.pattern` as an `IdentifierPatternSyntax`,
///     supplying the property name.
///   - variable: The enclosing `VariableDeclSyntax`, supplying attributes
///     (`@Guide`, `@OperationParam`) and leading trivia (doc comments).
///   - context: The macro expansion context used to emit diagnostics for
///     invalid properties.
/// - Returns: The synthesized entry, or `nil` if the property was skipped.
private func operationParameterEntry(
    for binding: PatternBindingSyntax,
    identifierPattern: IdentifierPatternSyntax,
    variable: VariableDeclSyntax,
    in context: some MacroExpansionContext
) -> OperationParameterEntry? {
    let propertyName = identifierPattern.identifier.text

    guard let typeAnnotation = binding.typeAnnotation?.type else {
        diagnoseUnsupportedParameterType(propertyName, at: binding, in: context)
        return nil
    }

    if normalized(propertyName) == opFieldName {
        context.diagnose(
            OperationMacroDiagnostic.reservedParameterName(propertyName).diagnose(at: identifierPattern)
        )
        return nil
    }

    // Unwrapped once, reused below for both the `ParamMeta` and `Command` field mappings.
    let (wrappedType, required) = unwrappingOptional(typeAnnotation)
    guard let typeExprText = primitiveParamTypeExprText(wrappedType) else {
        diagnoseUnsupportedParameterType(propertyName, at: typeAnnotation, in: context)
        return nil
    }

    let guide = guideInfo(from: variable.attributes)
    let operationParam = operationParamInfo(from: variable.attributes)
    let description = guide.description ?? docCommentDescription(from: variable.leadingTrivia) ?? ""
    let allowedValues = operationParam.allowedValues ?? guide.allowedValues

    // Each argument is appended only when set; a table avoids three near-identical checks.
    let optionalArgs: [String?] = [
        operationParam.short.map { "short: \(swiftStringLiteral(String($0)))" },
        operationParam.aliases.isEmpty ? nil : arrayArgumentText(key: aliasesLabel, values: operationParam.aliases),
        allowedValues.map { arrayArgumentText(key: allowedValuesLabel, values: $0) },
    ]
    let args =
        [
            "name: \(swiftStringLiteral(propertyName))",
            "type: \(typeExprText)",
            "required: \(required)",
            "description: \(swiftStringLiteral(description))",
        ] + optionalArgs.compactMap { $0 }

    let commandField = commandFieldKind(for: wrappedType).map {
        CommandFieldSpec(
            name: propertyName,
            kind: $0,
            required: required,
            description: description,
            short: operationParam.short
        )
    }

    return OperationParameterEntry(
        paramMetaText: "ParamMeta(\(args.joined(separator: ", ")))",
        commandField: commandField
    )
}

/// Builds the source text of one nested `Command` property: its
/// `@Flag`/`@Option` attribute plus `var` declaration, for `field`.
private func commandFieldDeclarationText(_ field: CommandFieldSpec) -> String {
    let helpArgumentText = "help: \(swiftStringLiteral(field.description))"
    let nameArgumentText =
        field.short.map { "name: [.long, .customShort(\(swiftStringLiteral(String($0))))], " } ?? ""

    switch field.kind {
    case .flag:
        return """
            @Flag(\(nameArgumentText)\(helpArgumentText))
            var \(field.name): Bool = false
            """
    case .scalarOption(let typeText):
        let optionalSuffix = field.required ? "" : "?"
        return """
            @Option(\(nameArgumentText)\(helpArgumentText))
            var \(field.name): \(typeText)\(optionalSuffix)
            """
    case .repeatableOption(let elementTypeText):
        return """
            @Option(\(nameArgumentText)\(helpArgumentText))
            var \(field.name): [\(elementTypeText)] = []
            """
    }
}

/// Builds the source text of one `operationPayload()` statement folding
/// `field`'s parsed value into the `payload` array of `(name, value)` pairs.
///
/// A `.flag` is always present (its `@Flag` default is `false`); a required
/// `.scalarOption` or `.repeatableOption` is always present (an unsupplied
/// required array is sent as `[]`, not omitted — omitting it would leave the
/// payload missing the key entirely, which `Generable`'s synthesized
/// initializer throws decoding for a non-optional property, unlike a merely
/// empty array); an optional `.scalarOption`/`.repeatableOption` is included
/// only when set/non-empty.
private func payloadAssignmentText(_ field: CommandFieldSpec) -> String {
    let key = swiftStringLiteral(field.name)
    // Every unconditionally-included case (a `.flag`, or a required
    // `.repeatableOption`/`.scalarOption`) emits this identical append —
    // extracted once so the three cases below don't repeat the literal.
    let basePayloadAssignment = "payload.append((\(key), \(field.name)))"
    switch field.kind {
    case .flag:
        return basePayloadAssignment
    case .repeatableOption:
        return conditionalPayloadAssignment(
            unless: field.required,
            conditionText: "!\(field.name).isEmpty",
            assignmentText: basePayloadAssignment
        )
    case .scalarOption:
        return conditionalPayloadAssignment(
            unless: field.required,
            conditionText: "let \(field.name)",
            assignmentText: basePayloadAssignment
        )
    }
}

/// Wraps `assignmentText` in `if \(conditionText) { ... }`, or returns it
/// unwrapped when `required` — the shared shape of a `.repeatableOption`'s
/// emptiness check and a `.scalarOption`'s optional-binding check in
/// `payloadAssignmentText(_:)`, which otherwise differ only in that
/// condition's source text.
private func conditionalPayloadAssignment(unless required: Bool, conditionText: String, assignmentText: String) -> String {
    guard !required else {
        return assignmentText
    }
    return """
        if \(conditionText) {
            \(assignmentText)
        }
        """
}

/// Builds the nested `Command: AsyncParsableCommand` (ArgumentParser leaf)
/// source text `@Operation` emits alongside `OperationDefinition`
/// conformance, per plan.md's "Dual-use CLI".
///
/// One `@Flag`/`@Option` property per `fields` entry; a `CommandConfiguration`
/// naming the command after the operation's verb; and a `run()` that prints
/// the canonical `op` + fields payload `operationPayload()` builds from the
/// parsed values — the identical shape `AnyOperation.run` expects and the
/// model path sends.
///
/// `operationPayload()` builds that payload with
/// `GeneratedContent(properties:uniquingKeysWith:)` directly, rather than
/// round-tripping through `JSONSerialization` and `GeneratedContent(json:)`:
/// it needs no `Foundation` import in the file `@Operation` is applied to
/// (only `FoundationModels`, already required by `@Generable`/`@Guide`), and
/// every parameter type `@Operation` supports already conforms to
/// `ConvertibleToGeneratedContent` (`Generable` refines it; `Array` does too
/// when its `Element` does), so no serialization step can fail.
///
/// - Parameters:
///   - accessText: The access-level modifier text to prefix `Command` and
///     its members with (e.g. `"public "`), or `""` for no explicit
///     modifier.
///   - structTypeName: The annotated struct's name, used to reach its
///     `opString` static (`\(structTypeName).opString`) from inside the
///     nested `Command`.
///   - verbText: The source text of the `CommandConfiguration`'s
///     `commandName` argument.
///   - descriptionText: The source text of the `CommandConfiguration`'s
///     `abstract` argument.
///   - fields: The `Command` properties to declare, in declaration order.
/// - Returns: The `Command` struct's full declaration source text.
private func commandStructText(
    accessText: String,
    structTypeName: String,
    verbText: String,
    descriptionText: String,
    fields: [CommandFieldSpec]
) -> String {
    let fieldDeclarationsText = fields.map(commandFieldDeclarationText).joined(separator: "\n\n")
    let payloadAssignmentsText = fields.map(payloadAssignmentText).joined(separator: "\n")
    // `fields.isEmpty` (a unit struct, or one whose only stored properties
    // have no `Command` representation — e.g. a nested array) means no
    // statement below ever appends to `payload`; declaring it `var` in that
    // case would warn "variable was never mutated".
    let payloadDeclarationKeyword = fields.isEmpty ? "let" : "var"

    return """
        \(accessText)struct Command: AsyncParsableCommand, OperationCommand {
            \(accessText)static let configuration = CommandConfiguration(commandName: \(verbText), abstract: \(descriptionText))

        \(fieldDeclarationsText)

            \(accessText)init() {}

            /// The canonical `op` + fields payload built from this command's
            /// parsed values, in the identical shape `AnyOperation.run`
            /// expects and the model path sends.
            \(accessText)func operationPayload() -> GeneratedContent {
                \(payloadDeclarationKeyword) payload: [(String, any ConvertibleToGeneratedContent)] = [(\(swiftStringLiteral(opFieldName)), \(structTypeName).opString)]
        \(payloadAssignmentsText)
                return GeneratedContent(properties: payload, uniquingKeysWith: { _, new in new })
            }

            \(accessText)mutating func run() async throws {
                print(operationPayload().jsonString)
            }
        }
        """
}

// MARK: - `@OperationParam`

/// Implements the `@OperationParam` attached macro declared in the
/// `Operations` module.
///
/// `@OperationParam` is a pure marker: `@Operation` reads its arguments while
/// synthesizing `parameterMetadata`, but the attribute itself expands to no
/// code of its own.
public struct OperationParamMacro: PeerMacro {
    /// Expands `@OperationParam(short:aliases:allowedValues:)`.
    ///
    /// This is a no-op expansion: `@OperationParam` exists only to be read
    /// back out by `OperationMacro`'s `operationParamInfo(from:)` while it
    /// synthesizes `parameterMetadata`, so this peer macro never emits any
    /// declarations of its own.
    ///
    /// - Parameters:
    ///   - node: The `@OperationParam(...)` attribute syntax (unused here;
    ///     its arguments are read directly by `operationParamInfo(from:)`).
    ///   - declaration: The declaration the attribute is attached to
    ///     (unused).
    ///   - context: The macro expansion context (unused; this expansion
    ///     never diagnoses).
    /// - Returns: An empty array; this macro never produces peer
    ///   declarations.
    /// - Throws: Never. `throws` is a `PeerMacro` protocol requirement, not
    ///   a capability this expansion exercises: it does no diagnosing and no
    ///   syntax construction that could fail, and unconditionally returns an
    ///   empty array.
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Registers every macro implemented by this plugin with the compiler.
@main
internal struct OperationsMacrosPlugin: CompilerPlugin {
    internal let providingMacros: [Macro.Type] = [
        OperationMacro.self,
        OperationParamMacro.self,
    ]
}
