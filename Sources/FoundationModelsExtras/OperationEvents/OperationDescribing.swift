import FoundationModels

/// A `Tool` that tells a host its operations and lets the host dispatch one operation directly.
///
/// A host finds these tools with `tool as? any OperationDescribing`. The protocol declares no associated types, so that cast succeeds on an `any Tool` existential.
/// A host that holds only `any Tool` cannot see the generic operation list of a tool. This protocol gives the host that list as type-erased values.
public protocol OperationDescribing: Tool {
    /// The descriptors of all the operations that this tool can do.
    var operationDescriptors: [OperationDescriptor] { get }

    /// Dispatches one operation and returns its output text.
    ///
    /// The payload has the same shape as a model call: an `op` key and the fields of one operation.
    ///
    /// This method is different from `Tool.call(arguments:)`. When the tool refuses the payload (an unknown op, a missing required field, or a decode failure), this method throws the refusal. It does not return the refusal as text.
    /// `call(arguments:)` keeps its rule: it returns a refusal as text to the model, and does not throw it.
    /// - Parameter arguments: The payload with the `op` key and the fields of one operation.
    /// - Returns: The output text of the operation.
    /// - Throws: The refusal when the tool cannot dispatch the payload, or the error of the operation.
    func perform(_ arguments: GeneratedContent) async throws -> String
}

/// A type-erased description of one operation of an `OperationDescribing` tool.
public struct OperationDescriptor: Sendable, Equatable {
    /// The verb of the operation, for example `add`.
    public let verb: String

    /// The noun of the operation, for example `task`.
    public let noun: String

    /// The op string that selects the operation in a payload, for example `add task`.
    public let opString: String

    /// The text that tells what the operation does.
    public let description: String

    /// The parameters of the operation.
    public let parameters: [OperationParameterDescriptor]

    /// Makes a descriptor from all its fields.
    /// - Parameters:
    ///   - verb: The verb of the operation.
    ///   - noun: The noun of the operation.
    ///   - opString: The op string that selects the operation in a payload.
    ///   - description: The text that tells what the operation does.
    ///   - parameters: The parameters of the operation.
    public init(
        verb: String,
        noun: String,
        opString: String,
        description: String,
        parameters: [OperationParameterDescriptor]
    ) {
        self.verb = verb
        self.noun = noun
        self.opString = opString
        self.description = description
        self.parameters = parameters
    }
}

/// A type-erased description of one parameter of an operation.
public struct OperationParameterDescriptor: Sendable, Equatable {
    /// The name of the parameter in a payload.
    public let name: String

    /// The value type of the parameter.
    public let type: OperationParameterType

    /// `true` when a payload must have this parameter.
    public let required: Bool

    /// The text that tells what the parameter is.
    public let description: String

    /// The other names that a payload can use for this parameter.
    public let aliases: [String]

    /// The only values that the parameter accepts, or `nil` when the parameter accepts all values of its type.
    public let allowedValues: [String]?

    /// Makes a parameter descriptor from all its fields.
    /// - Parameters:
    ///   - name: The name of the parameter in a payload.
    ///   - type: The value type of the parameter.
    ///   - required: `true` when a payload must have this parameter.
    ///   - description: The text that tells what the parameter is.
    ///   - aliases: The other names that a payload can use for this parameter.
    ///   - allowedValues: The only values that the parameter accepts, or `nil` when the parameter accepts all values of its type.
    public init(
        name: String,
        type: OperationParameterType,
        required: Bool,
        description: String,
        aliases: [String],
        allowedValues: [String]?
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.aliases = aliases
        self.allowedValues = allowedValues
    }
}

/// The value type of an operation parameter.
public indirect enum OperationParameterType: Sendable, Equatable {
    /// A text value.
    case string
    /// A whole number.
    case integer
    /// A number that can have a fraction.
    case number
    /// A `true` or `false` value.
    case boolean
    /// A list of values. All the values have the given element type.
    case array(of: OperationParameterType)
}
