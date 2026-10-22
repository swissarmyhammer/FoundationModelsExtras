import Darwin
import Foundation

/// The system calls of a file write that a test can watch or break: the
/// `write(2)` of the bytes and the `fsync(2)` after them. `JSONLFile` and the
/// save of `FrontmatterDocument` make their writes through it, and each gives
/// the cases of its own error type to the checks below.
struct FileWriteCalls: Sendable {
  /// Writes the bytes to the descriptor, as `write(2)` does.
  let write: @Sendable (_ descriptor: Int32, _ bytes: UnsafeRawBufferPointer) -> Int

  /// Flushes the descriptor to the disk, as `fsync(2)` does.
  let sync: @Sendable (_ descriptor: Int32) -> Int32

  /// The calls of the system.
  static let system = FileWriteCalls(
    write: { descriptor, bytes in Darwin.write(descriptor, bytes.baseAddress, bytes.count) },
    sync: { descriptor in Darwin.fsync(descriptor) })

  /// Gives `bytes` to one `write(2)`. No second write sends the rest of a
  /// short write.
  ///
  /// - Parameters:
  ///   - bytes: The bytes to write.
  ///   - descriptor: The descriptor of the file.
  ///   - failed: Makes the error of a write that fails, from its `errno`.
  ///   - short: Makes the error of a write that wrote part of the bytes,
  ///     from the count it wrote and the count it had to write.
  /// - Throws: The error that `failed` or `short` makes.
  func writeWhole<Failure: Error>(
    _ bytes: Data, to descriptor: Int32, failed: (_ errorNumber: Int32) -> Failure,
    short: (_ written: Int, _ expected: Int) -> Failure
  ) throws(Failure) {
    let (written, errorNumber) = bytes.withUnsafeBytes { buffer in
      SystemCall.retryingInterrupts { write(descriptor, buffer) }
    }
    guard written != SystemCall.failure else {
      throw failed(errorNumber)
    }
    guard written == bytes.count else {
      throw short(written, bytes.count)
    }
  }

  /// Flushes the file to the disk with `fsync(2)`.
  ///
  /// - Parameters:
  ///   - descriptor: The descriptor of the file.
  ///   - failed: Makes the error of a sync that fails, from its `errno`.
  /// - Throws: The error that `failed` makes.
  func synchronize<Failure: Error>(
    _ descriptor: Int32, failed: (_ errorNumber: Int32) -> Failure
  ) throws(Failure) {
    let (result, errorNumber) = SystemCall.retryingInterrupts { sync(descriptor) }
    guard result != SystemCall.failure else {
      throw failed(errorNumber)
    }
  }

  /// Closes the descriptor with `close(2)`.
  ///
  /// - Parameters:
  ///   - descriptor: The descriptor of the file.
  ///   - failed: Makes the error of a close that fails, from its `errno`.
  /// - Throws: The error that `failed` makes.
  static func close<Failure: Error>(
    _ descriptor: Int32, failed: (_ errorNumber: Int32) -> Failure
  ) throws(Failure) {
    guard Darwin.close(descriptor) != SystemCall.failure else {
      throw failed(errno)
    }
  }
}
