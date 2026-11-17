import MLXLMCommon

/// The KV-cache configuration that the loader tests expect of a quantized
/// key: affine compression in groups of 64.
enum KVCacheFixture {
    /// The count of values that share one scale and one bias.
    static let affineGroupSize = 64

    /// Makes the configuration of affine compression of `bits` in groups of 64.
    ///
    /// - Parameter bits: The bits of each compressed value.
    /// - Returns: The configuration.
    /// - Throws: The error of `AffineKVCacheConfiguration` for bits or a group
    ///   size that it does not support.
    static func affine(bits: Int) throws -> KVCacheConfiguration {
        KVCacheConfiguration(strategy: .affine(try AffineKVCacheConfiguration(bits: bits, groupSize: affineGroupSize)))
    }
}
