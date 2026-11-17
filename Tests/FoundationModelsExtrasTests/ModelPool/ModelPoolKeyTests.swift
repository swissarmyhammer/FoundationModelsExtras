import Testing

@testable import FoundationModelsExtras

/// The KV-cache quantization of a ``ModelPoolKey``: it is part of the identity
/// of the key, the key keeps it without its context, and a resident key serves
/// only a request of the same quantization.
@Suite("Model pool key: the KV-cache quantization is part of the key")
struct ModelPoolKeyTests {
    /// The model of each test.
    private static let ref: ModelRef = "org/a"

    /// The context of a request.
    private static let smallContext = 8192

    /// A context larger than ``smallContext``.
    private static let largeContext = 32768

    @Test(
        "each quantization gives the bits of its cache elements",
        arguments: [(KVCacheQuantization.bits8, 8), (KVCacheQuantization.bits4, 4)])
    func quantizationBits(quantization: KVCacheQuantization, bits: Int) {
        #expect(quantization.bits == bits)
    }

    @Test("a key with no quantization is the default of the init")
    func noQuantizationByDefault() {
        #expect(ModelPoolKey(ref: Self.ref, role: .llm).kvCache == nil)
    }

    @Test("two keys that differ only in their quantization are not equal")
    func quantizationIsPartOfTheIdentity() {
        #expect(Self.key(nil, .bits8) != Self.key(nil, .bits4))
    }

    @Test("a quantized key and the full-precision key of the same model are not equal")
    func quantizedIsNotFullPrecision() {
        #expect(Self.key(nil, .bits8) != Self.key(nil, nil))
    }

    @Test("a key without its context keeps its quantization")
    func withoutContextKeepsTheQuantization() {
        #expect(Self.key(Self.largeContext, .bits4).withoutContext == Self.key(nil, .bits4))
    }

    @Test("a resident key of a larger context and the same quantization serves a request")
    func largerContextOfTheSameQuantizationServes() {
        #expect(Self.key(Self.largeContext, .bits8).serves(Self.key(Self.smallContext, .bits8)))
    }

    @Test("a resident key of a larger context and another quantization does not serve a request")
    func largerContextOfAnotherQuantizationDoesNotServe() {
        #expect(!Self.key(Self.largeContext, .bits8).serves(Self.key(Self.smallContext, nil)))
    }

    // MARK: Helpers

    /// The key of ``ref`` as an LLM at `contextSize` with the KV cache `kvCache`.
    ///
    /// - Parameters:
    ///   - contextSize: The context size, or `nil`.
    ///   - kvCache: The quantization of the KV cache, or `nil`.
    /// - Returns: The key.
    private static func key(_ contextSize: Int?, _ kvCache: KVCacheQuantization?) -> ModelPoolKey {
        ModelPoolKey(ref: ref, role: .llm, contextSize: contextSize, kvCache: kvCache)
    }
}
