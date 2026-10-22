@testable import FoundationModelsExtras

/// The calls of the system, but each write puts only the first half of its
/// bytes on disk, as a full disk does. The tests of `JSONLFile` and of the
/// save of `FrontmatterDocument` break their writes with it.
enum HalfWriteCalls {
  /// The part of the bytes of a write that ``calls`` puts on disk: one in
  /// this number.
  static let shortWriteDivisor = 2

  /// The calls.
  static let calls = FileWriteCalls(
    write: { descriptor, bytes in
      FileWriteCalls.system.write(
        descriptor, UnsafeRawBufferPointer(rebasing: bytes.prefix(bytes.count / shortWriteDivisor)))
    },
    sync: FileWriteCalls.system.sync)
}
