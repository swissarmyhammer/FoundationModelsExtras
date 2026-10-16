import Foundation
import ULID

/// Which interaction an ``ElicitationRequest`` asks the host to run. Wire values
/// follow the MCP spec; an omitted `mode` key decodes as ``form``.
public enum ElicitationMode: String, Codable, Sendable, Equatable {
    /// The host presents a flat form described by ``ElicitationRequest/requestedSchema``.
    case form

    /// The host asks the user to open ``ElicitationRequest/url``. The flow's
    /// completion arrives separately.
    case url
}

/// An MCP-spec-shaped request for user input, posted by a running operation
/// and presented by a host.
///
/// Unlike MCP's form-mode `elicitation/create`, this envelope requires
/// ``elicitationId`` in both modes, because answers arrive decoupled through
/// `respond(elicitationId, response)`. The id is a ULID distinct from the run's
/// correlation: one run can elicit more than once.
public struct ElicitationRequest: Codable, Sendable, Equatable {
    /// Which interaction this request asks the host to run.
    public let mode: ElicitationMode

    /// The human-readable question or instruction the host shows the user.
    public let message: String

    /// The identifier an answer addresses.
    public let elicitationId: ULID

    /// The flat-object form schema. Non-nil exactly when ``mode`` is ``ElicitationMode/form``.
    public let requestedSchema: ElicitationRequestedSchema?

    /// The URL the user is asked to open. Non-nil exactly when ``mode`` is ``ElicitationMode/url``.
    public let url: URL?

    /// The names of the agents that relayed this question to the user, from
    /// the agent nearest the user to the agent that asked. Empty for a
    /// question that a run of this session asked.
    public let agentPath: [String]

    /// The tool of the run that asked this question, at the level where the
    /// question was asked, or `nil` when no relay set it.
    public let source: String?

    /// Creates a form-mode request.
    ///
    /// - Parameters:
    ///   - message: The question or instruction that the host shows the user.
    ///   - elicitationId: The identifier that an answer addresses.
    ///   - requestedSchema: The form.
    ///   - agentPath: The agents that relayed the question. The default is
    ///     no agent.
    ///   - source: The tool of the run that asked the question. The default
    ///     is `nil`.
    public init(
        message: String, elicitationId: ULID, requestedSchema: ElicitationRequestedSchema, agentPath: [String] = [],
        source: String? = nil
    ) {
        self.init(
            mode: .form, message: message, elicitationId: elicitationId, requestedSchema: requestedSchema, url: nil,
            agentPath: agentPath, source: source)
    }

    /// Creates a URL-mode request.
    ///
    /// - Parameters:
    ///   - message: The question or instruction that the host shows the user.
    ///   - elicitationId: The identifier that an answer addresses.
    ///   - url: The URL that the user is asked to open.
    ///   - agentPath: The agents that relayed the question. The default is
    ///     no agent.
    ///   - source: The tool of the run that asked the question. The default
    ///     is `nil`.
    public init(message: String, elicitationId: ULID, url: URL, agentPath: [String] = [], source: String? = nil) {
        self.init(
            mode: .url, message: message, elicitationId: elicitationId, requestedSchema: nil, url: url,
            agentPath: agentPath, source: source)
    }

    /// The one memberwise entry point. Private, so the payload always
    /// matches the mode.
    private init(
        mode: ElicitationMode, message: String, elicitationId: ULID, requestedSchema: ElicitationRequestedSchema?,
        url: URL?, agentPath: [String], source: String?
    ) {
        self.mode = mode
        self.message = message
        self.elicitationId = elicitationId
        self.requestedSchema = requestedSchema
        self.url = url
        self.agentPath = agentPath
        self.source = source
    }

    /// This question as the parent of `agent` sends it to its own host.
    ///
    /// The copy keeps ``elicitationId``, so an answer at any level reaches
    /// the run that asked. Each relay puts its agent at the front of
    /// ``agentPath``, thus after the relays of all levels the path goes from
    /// the agent nearest the user to the agent that asked. The first relay
    /// sets ``source``, and a later relay keeps it.
    ///
    /// - Parameters:
    ///   - agent: The name of the agent whose question this is.
    ///   - tool: The tool of the run that asked the question in `agent`.
    /// - Returns: The relayed copy.
    public func relayed(by agent: String, askedBy tool: String) -> ElicitationRequest {
        ElicitationRequest(
            mode: mode, message: message, elicitationId: elicitationId, requestedSchema: requestedSchema, url: url,
            agentPath: [agent] + agentPath, source: source ?? tool)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case message
        case elicitationId
        case requestedSchema
        case url
        case agentPath
        case source
    }

    /// Decodes a request. An omitted `mode` defaults to ``ElicitationMode/form``.
    /// The decoded mode's payload is required. An omitted `agentPath` decodes
    /// as no agent, and an omitted `source` as `nil`, so a request that was
    /// recorded before these keys existed still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decodeIfPresent(ElicitationMode.self, forKey: .mode) ?? .form
        self.mode = mode
        self.message = try container.decode(String.self, forKey: .message)
        self.elicitationId = try container.decode(ULID.self, forKey: .elicitationId)
        switch mode {
        case .form:
            self.requestedSchema = try container.decode(ElicitationRequestedSchema.self, forKey: .requestedSchema)
            self.url = nil
        case .url:
            self.requestedSchema = nil
            self.url = try container.decode(URL.self, forKey: .url)
        }
        self.agentPath = try container.decodeIfPresent([String].self, forKey: .agentPath) ?? []
        self.source = try container.decodeIfPresent(String.self, forKey: .source)
    }

    /// Encodes this request with its mode explicit. The `agentPath` key is
    /// present only when the path is not empty, and the `source` key only
    /// when there is a source.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(message, forKey: .message)
        try container.encode(elicitationId, forKey: .elicitationId)
        try container.encodeIfPresent(requestedSchema, forKey: .requestedSchema)
        try container.encodeIfPresent(url, forKey: .url)
        if !agentPath.isEmpty {
            try container.encode(agentPath, forKey: .agentPath)
        }
        try container.encodeIfPresent(source, forKey: .source)
    }
}

/// The `requestedSchema` of a form-mode ``ElicitationRequest``: a flat object
/// whose properties are all ``ElicitationPrimitiveSchema``, per the MCP
/// elicitation subset. Decoding a nested-object property throws.
public struct ElicitationRequestedSchema: Codable, Sendable, Equatable {
    /// The form's fields, by property name.
    public let properties: [String: ElicitationPrimitiveSchema]

    /// The property names the user must fill, or `nil` when every field is optional.
    public let required: [String]?

    /// Creates a schema from its fields. `required` defaults to `nil`.
    public init(properties: [String: ElicitationPrimitiveSchema], required: [String]? = nil) {
        self.properties = properties
        self.required = required
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
    }

    /// The one root `type` the subset allows.
    private static let objectTypeName = "object"

    /// Decodes a schema, rejecting any root whose `type` is not `"object"`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == Self.objectTypeName else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription:
                    "an elicitation requestedSchema root must be type \"object\", not \"\(type)\"")
        }
        self.properties = try container.decode([String: ElicitationPrimitiveSchema].self, forKey: .properties)
        self.required = try container.decodeIfPresent([String].self, forKey: .required)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.objectTypeName, forKey: .type)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(required, forKey: .required)
    }
}

/// One property of an ``ElicitationRequestedSchema``, restricted to the MCP
/// elicitation subset's primitive shapes. No case can hold another object.
public enum ElicitationPrimitiveSchema: Codable, Sendable, Equatable {
    /// A free-text string (``ElicitationStringSchema``).
    case string(ElicitationStringSchema)

    /// A number or integer (``ElicitationNumberSchema``).
    case number(ElicitationNumberSchema)

    /// A boolean (``ElicitationBooleanSchema``).
    case boolean(ElicitationBooleanSchema)

    /// A single-select enum (``ElicitationSingleSelectSchema``).
    case singleSelect(ElicitationSingleSelectSchema)

    /// A multi-select enum (``ElicitationMultiSelectSchema``).
    case multiSelect(ElicitationMultiSelectSchema)

    /// The wire keys this dispatch inspects: `type`, and `enum` for single-select.
    private enum DiscriminatorKeys: String, CodingKey {
        case type
        case enumValues = "enum"
    }

    /// Decodes one property by its `type`. Throws for `"object"` and for any type outside the subset.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "string":
            if container.contains(.enumValues) {
                self = .singleSelect(try ElicitationSingleSelectSchema(from: decoder))
            } else {
                self = .string(try ElicitationStringSchema(from: decoder))
            }
        case "number", "integer":
            self = .number(try ElicitationNumberSchema(from: decoder))
        case "boolean":
            self = .boolean(try ElicitationBooleanSchema(from: decoder))
        case "array":
            self = .multiSelect(try ElicitationMultiSelectSchema(from: decoder))
        case "object":
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription:
                    "nested object schemas are outside the MCP elicitation subset — every property must be primitive")
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription:
                    "property type \"\(type)\" is outside the MCP elicitation subset")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let schema): try schema.encode(to: encoder)
        case .number(let schema): try schema.encode(to: encoder)
        case .boolean(let schema): try schema.encode(to: encoder)
        case .singleSelect(let schema): try schema.encode(to: encoder)
        case .multiSelect(let schema): try schema.encode(to: encoder)
        }
    }
}

/// The string formats the MCP elicitation subset allows on an ``ElicitationStringSchema``.
public enum ElicitationStringFormat: String, Codable, Sendable, Equatable {
    /// An email address.
    case email

    /// A URI.
    case uri

    /// A calendar date.
    case date

    /// A date with time.
    case dateTime = "date-time"
}

/// A free-text string property, optionally bounded and formatted, with an optional default.
public struct ElicitationStringSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The minimum accepted length.
    public let minLength: Int?

    /// The maximum accepted length.
    public let maxLength: Int?

    /// The expected format, when the field is more specific than free text.
    public let format: ElicitationStringFormat?

    /// The pre-filled default, carried on the wire as `default`.
    public let defaultValue: String?

    /// A regular expression that the whole value must match.
    public let pattern: String?

    /// Creates a string schema from its fields. Every parameter defaults to `nil`.
    public init(
        title: String? = nil,
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        format: ElicitationStringFormat? = nil,
        defaultValue: String? = nil,
        pattern: String? = nil
    ) {
        self.title = title
        self.description = description
        self.minLength = minLength
        self.maxLength = maxLength
        self.format = format
        self.defaultValue = defaultValue
        self.pattern = pattern
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case minLength
        case maxLength
        case format
        case defaultValue = "default"
        case pattern
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.minLength = try container.decodeIfPresent(Int.self, forKey: .minLength)
        self.maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
        self.format = try container.decodeIfPresent(ElicitationStringFormat.self, forKey: .format)
        self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        self.pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("string", forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(minLength, forKey: .minLength)
        try container.encodeIfPresent(maxLength, forKey: .maxLength)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(pattern, forKey: .pattern)
    }
}

/// A numeric property, `"number"` or `"integer"`, optionally bounded, with an optional default.
public struct ElicitationNumberSchema: Codable, Sendable, Equatable {
    /// The wire `type`: any number, or integers only.
    public enum NumberType: String, Codable, Sendable, Equatable {
        /// Any number.
        case number

        /// Integers only.
        case integer
    }

    /// Whether the field accepts any number or only integers.
    public let type: NumberType

    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The minimum accepted value.
    public let minimum: Double?

    /// The maximum accepted value.
    public let maximum: Double?

    /// The pre-filled default, carried on the wire as `default`.
    public let defaultValue: Double?

    /// Creates a number schema from its fields. Every parameter but `type` defaults to `nil`.
    public init(
        type: NumberType,
        title: String? = nil,
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        defaultValue: Double? = nil
    ) {
        self.type = type
        self.title = title
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case minimum
        case maximum
        case defaultValue = "default"
    }
}

/// A boolean property, with an optional default.
public struct ElicitationBooleanSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The pre-filled default, carried on the wire as `default`.
    public let defaultValue: Bool?

    /// Creates a boolean schema from its fields. Every parameter defaults to `nil`.
    public init(title: String? = nil, description: String? = nil, defaultValue: Bool? = nil) {
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.defaultValue = try container.decodeIfPresent(Bool.self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("boolean", forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// A single-select enum property: a string constrained to ``values``.
public struct ElicitationSingleSelectSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The accepted values, carried on the wire as `enum`.
    public let values: [String]

    /// Optional display names for ``values``, in the same order (the wire `enumNames`).
    public let enumNames: [String]?

    /// The pre-selected default, carried on the wire as `default`.
    public let defaultValue: String?

    /// Creates a single-select schema from its fields. Every parameter but `values` defaults to `nil`.
    public init(
        title: String? = nil,
        description: String? = nil,
        values: [String],
        enumNames: [String]? = nil,
        defaultValue: String? = nil
    ) {
        self.title = title
        self.description = description
        self.values = values
        self.enumNames = enumNames
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case values = "enum"
        case enumNames
        case defaultValue = "default"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.values = try container.decode([String].self, forKey: .values)
        self.enumNames = try container.decodeIfPresent([String].self, forKey: .enumNames)
        self.defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("string", forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(values, forKey: .values)
        try container.encodeIfPresent(enumNames, forKey: .enumNames)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// A multi-select enum property: an array of strings constrained to ``values``
/// (the wire shape `{"type": "array", "items": {"type": "string", "enum": [...]}}`).
public struct ElicitationMultiSelectSchema: Codable, Sendable, Equatable {
    /// The field's display title.
    public let title: String?

    /// The field's longer description.
    public let description: String?

    /// The accepted values, carried on the wire as `items.enum`.
    public let values: [String]

    /// Optional display names for ``values``, in the same order (the wire `items.enumNames`).
    public let enumNames: [String]?

    /// The minimum number of selections.
    public let minItems: Int?

    /// The maximum number of selections.
    public let maxItems: Int?

    /// The pre-selected defaults, carried on the wire as `default`.
    public let defaultValue: [String]?

    /// Creates a multi-select schema from its fields. Every parameter but `values` defaults to `nil`.
    public init(
        title: String? = nil,
        description: String? = nil,
        values: [String],
        enumNames: [String]? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        defaultValue: [String]? = nil
    ) {
        self.title = title
        self.description = description
        self.values = values
        self.enumNames = enumNames
        self.minItems = minItems
        self.maxItems = maxItems
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case title
        case description
        case items
        case minItems
        case maxItems
        case defaultValue = "default"
    }

    private enum ItemsKeys: String, CodingKey {
        case type
        case values = "enum"
        case enumNames
    }

    /// The one `items.type` the subset allows.
    private static let itemTypeName = "string"

    /// Decodes a multi-select. Throws when `items` is not a string enum.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.nestedContainer(keyedBy: ItemsKeys.self, forKey: .items)
        let itemType = try items.decode(String.self, forKey: .type)
        guard itemType == Self.itemTypeName else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: items,
                debugDescription:
                    "multi-select items must be type \"string\", not \"\(itemType)\" — the MCP elicitation subset has no nested shapes")
        }
        self.values = try items.decode([String].self, forKey: .values)
        self.enumNames = try items.decodeIfPresent([String].self, forKey: .enumNames)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.minItems = try container.decodeIfPresent(Int.self, forKey: .minItems)
        self.maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems)
        self.defaultValue = try container.decodeIfPresent([String].self, forKey: .defaultValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("array", forKey: .type)
        var items = container.nestedContainer(keyedBy: ItemsKeys.self, forKey: .items)
        try items.encode(Self.itemTypeName, forKey: .type)
        try items.encode(values, forKey: .values)
        try items.encodeIfPresent(enumNames, forKey: .enumNames)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(minItems, forKey: .minItems)
        try container.encodeIfPresent(maxItems, forKey: .maxItems)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

/// One filled form value in an accepting ``ElicitationResponse``.
public enum ElicitationValue: Codable, Sendable, Equatable {
    /// A string field's value (free text, formatted string, or single-select choice).
    case string(String)

    /// A number or integer field's value.
    case number(Double)

    /// A boolean field's value.
    case boolean(Bool)

    /// A multi-select field's chosen values.
    case stringArray([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let strings = try? container.decode([String].self) {
            self = .stringArray(strings)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "an elicitation content value must be a string, number, boolean, or array of strings")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number): try container.encode(number)
        case .boolean(let boolean): try container.encode(boolean)
        case .stringArray(let strings): try container.encode(strings)
        }
    }
}

/// The user's answer to an ``ElicitationRequest``: `accept`, `decline`, or
/// `cancel`, with ``content`` present only on a form-mode accept, and an
/// optional ``reason`` only on a decline or a cancel.
///
/// The wire shape is `{ action, content, reason }`. Decoding content with a
/// decline or a cancel throws. Decoding a reason with an accept throws.
public struct ElicitationResponse: Codable, Sendable, Equatable {
    /// The three actions the MCP spec defines for an elicitation answer.
    public enum Action: String, Codable, Sendable, Equatable {
        /// The user submitted the form (form mode) or agreed to open the URL (URL mode).
        case accept

        /// The user explicitly declined to answer.
        case decline

        /// The user dismissed the elicitation without answering.
        case cancel
    }

    /// How the user answered.
    public let action: Action

    /// The filled form values, by property name. Non-nil only on a form-mode accept.
    public let content: [String: ElicitationValue]?

    /// Why the elicitation ended with no answer, in words for a person or a
    /// model. Non-nil only on a decline or a cancel that gives a reason.
    public let reason: String?

    /// The one memberwise entry point. Private, so content on a decline and a
    /// reason on an accept are unrepresentable.
    private init(action: Action, content: [String: ElicitationValue]?, reason: String?) {
        self.action = action
        self.content = content
        self.reason = reason
    }

    /// An accepting response, with the filled form values or `nil` content for URL mode.
    public static func accept(content: [String: ElicitationValue]?) -> ElicitationResponse {
        ElicitationResponse(action: .accept, content: content, reason: nil)
    }

    /// A declining response with no reason. Never carries content.
    public static let decline = ElicitationResponse(action: .decline, content: nil, reason: nil)

    /// A cancelling response with no reason. Never carries content.
    public static let cancel = ElicitationResponse(action: .cancel, content: nil, reason: nil)

    /// A declining response that tells why. Never carries content.
    ///
    /// - Parameter reason: Why the user declined.
    /// - Returns: The response.
    public static func decline(reason: String) -> ElicitationResponse {
        ElicitationResponse(action: .decline, content: nil, reason: reason)
    }

    /// A cancelling response that tells why. Never carries content.
    ///
    /// - Parameter reason: Why the elicitation ended with no answer.
    /// - Returns: The response.
    public static func cancel(reason: String) -> ElicitationResponse {
        ElicitationResponse(action: .cancel, content: nil, reason: reason)
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case content
        case reason
    }

    /// Decodes a response. Content with a decline or a cancel throws. A
    /// reason with an accept throws.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(Action.self, forKey: .action)
        self.content = try container.decodeIfPresent([String: ElicitationValue].self, forKey: .content)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
        guard content == nil || action == .accept else {
            throw DecodingError.dataCorruptedError(
                forKey: .content, in: container,
                debugDescription: "elicitation content is only valid on an accept, not \(action.rawValue)")
        }
        guard reason == nil || action != .accept else {
            throw DecodingError.dataCorruptedError(
                forKey: .reason, in: container,
                debugDescription: "an elicitation reason is only valid on a decline or a cancel, not an accept")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}
