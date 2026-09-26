import Foundation

/// A model that turns texts into vectors. A loader gives a container that
/// conforms to this protocol for a key of the `.embedding` role.
public protocol PooledEmbedding: Sendable {
    /// The length of each vector.
    var dimension: Int { get }
    /// Gives one vector for each text.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text, in the order of `texts`.
    func embed(texts: [String]) async throws -> [[Float]]
}

/// An embedder that keeps one ``ModelHold``, so the model stays resident while
/// the embedder exists. Each ``embed(texts:)`` call is one job in the queue of
/// the hold.
public struct PooledEmbedder: Sendable {
    /// The hold of the model.
    private let hold: ModelHold
    /// The container of the hold, as an embedding model.
    private let embedding: any PooledEmbedding

    /// Makes an embedder that keeps `hold`.
    ///
    /// - Parameter hold: A hold of an embedding model.
    /// - Throws: ``PooledEmbedderError/notAnEmbedding(key:containerType:)``
    ///   when the container of `hold` does not conform to ``PooledEmbedding``.
    public init(hold: ModelHold) throws {
        guard let embedding = hold.container as? any PooledEmbedding else {
            throw PooledEmbedderError.notAnEmbedding(
                key: hold.key, containerType: String(describing: type(of: hold.container)))
        }
        self.hold = hold
        self.embedding = embedding
    }

    /// The length of each vector.
    public var dimension: Int { embedding.dimension }

    /// Gives one vector for each text. The call waits in the queue of the model.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text, in the order of `texts`.
    /// - Throws: What ``GenerationQueue/submit(isolation:_:)`` or the model throws.
    public func embed(texts: [String]) async throws -> [[Float]] {
        try await hold.queue.submit { [embedding] in try await embedding.embed(texts: texts) }
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
