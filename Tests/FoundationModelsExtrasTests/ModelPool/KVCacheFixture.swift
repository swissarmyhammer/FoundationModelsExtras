import MLXLMCommon

/// The KV-cache configuration that the loader tests give to a loader: affine
/// compression of 8 bits, in groups of 64.
enum KVCacheFixture {
    /// The bits of each compressed value.
    static let affineBits = 8

    /// The count of values that share one scale and one bias.
    static let affineGroupSize = 64

    /// Makes the configuration of affine 8-bit compression in groups of 64.
    ///
    /// - Returns: The configuration.
    /// - Throws: The error of `AffineKVCacheConfiguration` for bits or a group
    ///   size that it does not support.
    static func eightBitAffine() throws -> KVCacheConfiguration {
        KVCacheConfiguration(
            strategy: .affine(try AffineKVCacheConfiguration(bits: affineBits, groupSize: affineGroupSize)))
    }
}
