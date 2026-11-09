/// What a pooled model does.
public enum ModelRole: Hashable, Sendable { case llm, embedding }

/// The key of one model in a ``ModelPool``.
///
/// The context size is part of the key only for a loader that loads a model
/// at a fixed context, such as the GGUF loader: the pool asks the loader for
/// the key with ``PooledModelLoader/poolKey(for:)`` at each acquire, and the
/// default drops the context. A resident model of the same reference and role
/// whose context is at least the context of a request gives the hold of that
/// request.
public struct ModelPoolKey: Hashable, Sendable {
    /// The model.
    public let ref: ModelRef
    /// What the model does.
    public let role: ModelRole
    /// The context size, in tokens, that the model loads at, or `nil` for the
    /// default of the loader.
    public let contextSize: Int?

    /// Makes the key of `ref` in the role `role`.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - role: What the model does.
    ///   - contextSize: The context size, in tokens, that the model loads at,
    ///     or `nil`, the default, for the default of the loader.
    public init(ref: ModelRef, role: ModelRole, contextSize: Int? = nil) {
        self.ref = ref
        self.role = role
        self.contextSize = contextSize
    }

    /// The key with no context size.
    public var withoutContext: ModelPoolKey { ModelPoolKey(ref: ref, role: role) }

    /// Whether a model resident under this key can give the hold of
    /// `request`: the same key, or the same reference and role at a context
    /// at least as large.
    ///
    /// - Parameter request: The key of a request.
    /// - Returns: `true` when this key serves the request.
    func serves(_ request: ModelPoolKey) -> Bool {
        guard self != request else { return true }
        guard ref == request.ref, role == request.role,
            let contextSize, let requested = request.contextSize
        else { return false }
        return contextSize >= requested
    }
}

/// Loads a model into memory, and removes it from memory.
public protocol PooledModelLoader: Sendable {
    /// The key that the pool keeps the model of `key` under. The pool calls
    /// this at each acquire, before it looks for a resident model, and gives
    /// the result to ``load(key:progressHandler:)`` and
    /// ``footprintBytes(of:)``.
    ///
    /// The default drops the context size, because a loader that does not
    /// load at a fixed context must not keep one model for each context. A
    /// loader that loads at the context of the key keeps it.
    ///
    /// - Parameter key: The key of a request.
    /// - Returns: The key of the model in the pool.
    /// - Throws: The error of the decision. The acquire throws it.
    func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey
    /// Loads the model of `key`, and returns its container.
    func load(_ key: ModelPoolKey) async throws -> any Sendable
    /// Loads the model of `key`, reports each step to `progressHandler`, and
    /// returns its container. The pool calls this for each load, and gives the
    /// reports to ``ModelPool/progress(for:)``.
    ///
    /// Report ``ModelLoadProgress/downloading(completedBytes:totalBytes:)``
    /// with the real byte counts of each part of a download, then
    /// ``ModelLoadProgress/loading``. The pool reports
    /// ``ModelLoadProgress/ready`` or ``ModelLoadProgress/failed(_:)``, and
    /// drops each report that breaks this order, and each download with fewer
    /// completed bytes than the download before it. Each acquire method of
    /// the pool gives this handler, thus a loader that implements only
    /// ``load(_:)`` reports only ``ModelLoadProgress/loading``.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets each step of the load. It can run on any
    ///     thread.
    /// - Returns: The container of the model.
    /// - Throws: The error of the load.
    func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable
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
    /// A loader that ignores the context keeps one model for each reference
    /// and role.
    ///
    /// - Parameter key: The key of a request.
    /// - Returns: `key` with no context size.
    public func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey { key.withoutContext }

    /// A loader that does not measure its models counts no bytes for them.
    ///
    /// - Parameter key: The model that ``load(_:)`` loaded.
    /// - Returns: 0.
    public func footprintBytes(of key: ModelPoolKey) async throws -> Int64 { 0 }

    /// A loader that reports nothing reports ``ModelLoadProgress/loading``,
    /// and then loads with ``load(_:)``.
    ///
    /// - Parameters:
    ///   - key: The model and its role.
    ///   - progressHandler: Gets ``ModelLoadProgress/loading``.
    /// - Returns: The container that ``load(_:)`` returns.
    /// - Throws: The error of ``load(_:)``.
    public func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        progressHandler(.loading)
        return try await load(key)
    }
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
