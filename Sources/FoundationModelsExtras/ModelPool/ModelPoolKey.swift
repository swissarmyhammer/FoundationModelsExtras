/// What a pooled model does.
public enum ModelRole: Hashable, Sendable { case llm, embedding }

/// The key of one model in a ``ModelPool``.
public struct ModelPoolKey: Hashable, Sendable {
    /// The model.
    public let ref: ModelRef
    /// What the model does.
    public let role: ModelRole

    /// Makes the key of `ref` in the role `role`.
    public init(ref: ModelRef, role: ModelRole) {
        self.ref = ref
        self.role = role
    }
}

/// Loads a model into memory, and removes it from memory.
public protocol PooledModelLoader: Sendable {
    /// Loads the model of `key`, and returns its container.
    func load(_ key: ModelPoolKey) async throws -> any Sendable
    /// Removes a container that ``load(_:)`` returned from memory.
    func evict(_ container: any Sendable) async
    /// Measures the bytes of the model of `key` in memory. The pool calls
    /// this after ``load(_:)`` of `key`, and ``ModelPool/acquire(_:)`` counts
    /// the result as the footprint of the model.
    ///
    /// - Parameter key: The model that ``load(_:)`` loaded.
    /// - Returns: The bytes of the model.
    /// - Throws: The error of the measure. The pool then evicts the model.
    func footprintBytes(of key: ModelPoolKey) async throws -> Int64
}

extension PooledModelLoader {
    /// A loader that does not measure its models counts no bytes for them.
    ///
    /// - Parameter key: The model that ``load(_:)`` loaded.
    /// - Returns: 0.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 { 0 }
}

/// The memory that the models of a ``ModelPool`` use.
public struct ModelPoolFootprint: Equatable, Sendable {
    /// The bytes of each resident model: its weights, and the session of each hold.
    public let resident: [ModelPoolKey: Int64]
    /// The bytes of the load that runs now, or 0.
    public let loadingBytes: Int64
    /// All the bytes.
    public var totalBytes: Int64 { resident.values.reduce(loadingBytes, +) }
}
