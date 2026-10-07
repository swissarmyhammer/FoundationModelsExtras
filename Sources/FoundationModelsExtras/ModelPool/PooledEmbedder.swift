import Foundation

/// The interface of each embedder: a model that turns texts into vectors.
/// ``PooledEmbedder`` conforms to it, and a loader gives a container that
/// conforms to it for a key of the `.embedding` role. Each vector carries its
/// length, so a caller does not need a dimension before the first call.
public protocol PooledEmbedding: Sendable {
    /// Gives one vector for each text.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text, in the order of `texts`.
    func embed(texts: [String]) async throws -> [[Float]]
}

/// An embedder that keeps one ``ModelHold``, so the model stays resident while
/// the embedder exists. Each ``embed(texts:)`` call is one job in the queue of
/// the hold.
///
/// An embedder made from a name loads nothing when you make it. Its first
/// ``embed(texts:)`` call acquires the model from the pool, one time only, also
/// when first calls run at the same time. All copies of one embedder share
/// that one hold, and the hold goes with the last copy.
///
/// ```swift
/// let embedder = PooledEmbedder(ref: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")   // loads nothing
/// let vectors = try await embedder.embed(texts: ["save my work"])                     // loads the model
/// ```
public struct PooledEmbedder: PooledEmbedding {
    /// The hold of the model, which all copies of this embedder share.
    private let resident: ResidentHold<LoadedEmbedding>

    /// Makes an embedder of the model `ref`. This loads nothing: the first
    /// ``embed(texts:)`` call acquires the model from `pool`.
    ///
    /// - Parameters:
    ///   - ref: The Hugging Face name of the embedding model.
    ///   - pool: The pool that loads the model with its loader. The default is
    ///     ``ModelPool/shared``.
    public init(ref: ModelRef, pool: ModelPool = .shared) {
        let key = ModelPoolKey(ref: ref, role: .embedding)
        resident = ResidentHold { try LoadedEmbedding(hold: try await pool.acquire(key)) }
    }

    /// Makes an embedder that keeps `hold`. Use this when you acquire the
    /// model with your own byte counts.
    ///
    /// - Parameter hold: A hold of an embedding model.
    /// - Throws: ``PooledEmbedderError/notAnEmbedding(key:containerType:)``
    ///   when the container of `hold` does not conform to ``PooledEmbedding``.
    public init(hold: ModelHold) throws {
        resident = ResidentHold(loaded: try LoadedEmbedding(hold: hold))
    }

    /// Gives one vector for each text. The call waits in the queue of the
    /// model. The first call of an embedder made from a name loads the model
    /// first.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text, in the order of `texts`.
    /// - Throws: The error of the load, of
    ///   ``GenerationQueue/submit(isolation:_:)``, or of the model; or
    ///   ``PooledEmbedderError/notAnEmbedding(key:containerType:)`` when the
    ///   loaded container does not conform to ``PooledEmbedding``.
    public func embed(texts: [String]) async throws -> [[Float]] {
        let loaded = try await resident.loaded()
        return try await loaded.hold.queue.submit { [embedding = loaded.embedding] in
            try await embedding.embed(texts: texts)
        }
    }
}

/// A hold of an embedding model, and its container as a ``PooledEmbedding``.
private struct LoadedEmbedding: Sendable {
    /// The hold of the model.
    let hold: ModelHold
    /// The container of the hold, as an embedding model.
    let embedding: any PooledEmbedding

    /// Takes the container of `hold` as an embedding model.
    ///
    /// - Parameter hold: A hold of an embedding model.
    /// - Throws: ``PooledEmbedderError/notAnEmbedding(key:containerType:)``
    ///   when the container of `hold` does not conform to ``PooledEmbedding``.
    init(hold: ModelHold) throws {
        guard let embedding = hold.container as? any PooledEmbedding else {
            throw PooledEmbedderError.notAnEmbedding(
                key: hold.key, containerType: String(describing: type(of: hold.container)))
        }
        self.hold = hold
        self.embedding = embedding
    }
}

/// An error of ``PooledEmbedder``.
public enum PooledEmbedderError: Error, Equatable, LocalizedError {
    /// The container of `key` has the type `containerType`, which does not
    /// conform to ``PooledEmbedding``.
    case notAnEmbedding(key: ModelPoolKey, containerType: String)

    /// A message that tells what is wrong.
    public var errorDescription: String? {
        switch self {
        case .notAnEmbedding(let key, let containerType):
            return """
                The container of \(key.ref.stringValue) is a \(containerType), which does not conform to \
                PooledEmbedding. The first loader of a key gives the container of all holds, so each \
                loader of an embedding key must return a PooledEmbedding.
                """
        }
    }
}
