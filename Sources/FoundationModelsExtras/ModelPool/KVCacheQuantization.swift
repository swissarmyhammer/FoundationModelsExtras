/// The quantization of the KV cache of a generation model, which is part of
/// its ``ModelPoolKey``. Only the KV cache is quantized: the weights stay as
/// the files give them.
///
/// Each engine maps the quantization to its own cache type:
/// ``MLXModelLoader`` to affine compression of ``bits`` in groups of 64, and
/// the GGUF loader to the `Q8_0` or `Q4_0` cache of llama.cpp. A key with no
/// quantization keeps full-precision caches.
public enum KVCacheQuantization: Sendable, Hashable {
    /// 8-bit cache elements: about half the memory of full precision.
    case bits8

    /// 4-bit cache elements: about a quarter of the memory of full precision.
    case bits4

    /// The bits of each cache element: 8 or 4.
    public var bits: Int {
        switch self {
        case .bits8: 8
        case .bits4: 4
        }
    }
}
