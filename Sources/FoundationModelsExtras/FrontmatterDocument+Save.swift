import Darwin
import Foundation

/// The save of a document: its metadata as YAML between two `---` fences,
/// then its body unchanged. A read of the saved file with
/// ``FrontmatterDocument/split(text:)`` and a YAML decode of the frontmatter
/// gives the same metadata and the same body back.
///
/// The YAML encode runs inside this module, through
/// `PlainNumberYAMLEncoder`, which writes each `Double` and `Float` as plain
/// decimal text that a person can read: no Yams type crosses the public
/// API, only ``FrontmatterDocumentSaveError``.
///
/// The ``FrontmatterDocument/enablement`` of the document is not written: it
/// comes from the `enabled` key of the metadata, thus the metadata carries
/// it.
extension FrontmatterDocument where Metadata: Encodable {
  /// The text of the file that ``save(to:)`` writes.
  ///
  /// With metadata, the text is a `---` line, the metadata as YAML, a `---`
  /// line, and then ``content`` unchanged. With no metadata, the text is
  /// ``content`` alone; when ``content`` itself opens with a frontmatter
  /// block, an empty frontmatter block goes in front of it, so that a read
  /// gives ``content`` back as the body.
  ///
  /// - Returns: The text of the document file.
  /// - Throws: ``FrontmatterDocumentSaveError/encodingFailed(description:)``
  ///   when the metadata does not encode as YAML.
  public func rendered() throws(FrontmatterDocumentSaveError) -> String {
    guard let metadata else {
      return Self.standingAlone(content)
    }
    return Self.fenceLine + (try Self.yaml(of: metadata)) + Self.fenceLine + content
  }

  /// Saves the document to the file at `url`, and replaces the file that is
  /// there.
  ///
  /// The save writes ``rendered()`` to a new temporary file in the folder of
  /// the target, flushes it to the disk, gives it the permissions of the old
  /// file, or those of a new file when there is none, and then swaps it into
  /// place with one `rename(2)`. A reader sees the old file or the new file,
  /// never a file that is half written. A save that fails leaves the old
  /// file whole and removes its temporary file. A symbolic link at `url`
  /// stays: the save replaces the file that the link names.
  ///
  /// - Parameter url: The document file. Its folder must exist.
  /// - Throws: ``FrontmatterDocumentSaveError`` when the metadata does not
  ///   encode or a system call fails.
  public func save(to url: URL) throws(FrontmatterDocumentSaveError) {
    try save(to: url, calls: .system)
  }

  /// Saves the document to the file at `url` with the write and the sync
  /// that `calls` gives.
  ///
  /// - Parameters:
  ///   - url: The document file. Its folder must exist.
  ///   - calls: The write and the sync of the temporary file.
  /// - Throws: The errors of ``save(to:)``.
  func save(to url: URL, calls: FileWriteCalls) throws(FrontmatterDocumentSaveError) {
    let bytes = Data(try rendered().utf8)
    try FileReplacement(target: url.resolvingSymlinksInPath(), calls: calls).replace(with: bytes)
  }

  /// A fence line: the fence and its line terminator.
  private static var fenceLine: String { "\(FrontmatterDocument<Never>.fence)\n" }

  /// Gives the text of a document with no metadata: `body`, behind an empty
  /// frontmatter block when `body` would read back as a frontmatter block.
  ///
  /// - Parameter body: The body of the document.
  /// - Returns: The text that reads back with `body` as its body.
  private static func standingAlone(_ body: String) -> String {
    guard FrontmatterDocument<Never>.split(text: body).frontmatter != nil else {
      return body
    }
    return fenceLine + fenceLine + body
  }

  /// Encodes `metadata` as YAML.
  ///
  /// - Parameter metadata: The metadata.
  /// - Returns: The YAML text, which ends with a line terminator.
  /// - Throws: ``FrontmatterDocumentSaveError/encodingFailed(description:)``
  ///   when the encode fails.
  private static func yaml(of metadata: Metadata) throws(FrontmatterDocumentSaveError) -> String {
    do {
      return try PlainNumberYAMLEncoder.yaml(of: metadata)
    } catch {
      throw .encodingFailed(description: String(describing: error))
    }
  }
}

/// One replace of a file by new bytes: a temporary file in the folder of the
/// target, then one `rename(2)` over the target.
private struct FileReplacement {
  /// The permissions of a new file: the owner reads and writes, the others
  /// read.
  private static let newFileMode: mode_t = 0o644

  /// The bits of `st_mode` that are the permissions, with the set-id and
  /// sticky bits.
  private static let permissionBits: mode_t = 0o7777

  /// The start of the name of a temporary file: a dot, which hides it.
  private static let temporaryPrefix = "."

  /// The end of the name of a temporary file: `mkostemp(3)` puts a unique
  /// text in place of the `X`s.
  private static let temporarySuffix = ".XXXXXX"

  /// The file to replace. Not a symbolic link.
  let target: URL

  /// The write and the sync of the temporary file.
  let calls: FileWriteCalls

  /// The path of the target.
  private var targetPath: String { target.path(percentEncoded: false) }

  /// Writes `bytes` to a temporary file and swaps it into place of the
  /// target. A failure removes the temporary file and leaves the target as
  /// it was.
  ///
  /// - Parameter bytes: The new content of the target.
  /// - Throws: ``FrontmatterDocumentSaveError`` when a system call fails.
  func replace(with bytes: Data) throws(FrontmatterDocumentSaveError) {
    let mode = try modeOfTarget()
    let temporary = try makeTemporaryFile()
    do throws(FrontmatterDocumentSaveError) {
      try fill(temporary.descriptor, with: bytes, mode: mode)
      try swap(temporary.path)
    } catch {
      // The failure is the error of the save; the temporary file goes.
      _ = unlink(temporary.path)
      throw error
    }
  }

  /// Gives the permissions for the new file: those of the target, or those
  /// of a new file when the target is not there.
  ///
  /// - Returns: The permission bits.
  /// - Throws: ``FrontmatterDocumentSaveError/modeFailed(errno:)`` when the
  ///   `stat(2)` fails for a reason other than a missing target.
  private func modeOfTarget() throws(FrontmatterDocumentSaveError) -> mode_t {
    var status = stat()
    guard stat(targetPath, &status) != SystemCall.failure else {
      let errorNumber = errno
      guard errorNumber == ENOENT else {
        throw .modeFailed(errno: errorNumber)
      }
      return Self.newFileMode
    }
    return status.st_mode & Self.permissionBits
  }

  /// Makes a new temporary file in the folder of the target, closed on
  /// exec.
  ///
  /// `mkostemp(3)` is not run again on `EINTR`: a failed run can leave its
  /// template changed.
  ///
  /// - Returns: The descriptor of the file, which the caller closes, and its
  ///   path, which the caller removes or renames.
  /// - Throws: ``FrontmatterDocumentSaveError/temporaryFileFailed(errno:)``
  ///   when the file cannot be made.
  private func makeTemporaryFile() throws(FrontmatterDocumentSaveError) -> (
    descriptor: Int32, path: String
  ) {
    let name = Self.temporaryPrefix + target.lastPathComponent + Self.temporarySuffix
    let templateURL = target.deletingLastPathComponent().appendingPathComponent(name)
    var template = templateURL.path(percentEncoded: false).utf8CString
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
      buffer.baseAddress.map { mkostemp($0, O_CLOEXEC) } ?? Int32(SystemCall.failure)
    }
    guard descriptor != SystemCall.failure else {
      throw .temporaryFileFailed(errno: errno)
    }
    let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return (descriptor, path)
  }

  /// Gives the temporary file its permissions and its bytes, flushes it to
  /// the disk, and closes it.
  ///
  /// - Parameters:
  ///   - descriptor: The descriptor of the temporary file. Closed on return.
  ///   - bytes: The new content of the target.
  ///   - mode: The permissions of the new file.
  /// - Throws: ``FrontmatterDocumentSaveError`` when a system call fails.
  private func fill(
    _ descriptor: Int32, with bytes: Data, mode: mode_t
  ) throws(FrontmatterDocumentSaveError) {
    do throws(FrontmatterDocumentSaveError) {
      guard fchmod(descriptor, mode) != SystemCall.failure else {
        throw .modeFailed(errno: errno)
      }
      try calls.writeWhole(
        bytes, to: descriptor, failed: FrontmatterDocumentSaveError.writeFailed,
        short: FrontmatterDocumentSaveError.shortWrite)
      try calls.synchronize(descriptor, failed: FrontmatterDocumentSaveError.syncFailed)
    } catch {
      // The failure of the fill is the error of the save.
      _ = Darwin.close(descriptor)
      throw error
    }
    try FileWriteCalls.close(descriptor, failed: FrontmatterDocumentSaveError.closeFailed)
  }

  /// Puts the temporary file in place of the target with one `rename(2)`.
  ///
  /// - Parameter temporaryPath: The path of the temporary file.
  /// - Throws: ``FrontmatterDocumentSaveError/replaceFailed(errno:)`` when
  ///   the rename fails.
  private func swap(_ temporaryPath: String) throws(FrontmatterDocumentSaveError) {
    guard rename(temporaryPath, targetPath) != SystemCall.failure else {
      throw .replaceFailed(errno: errno)
    }
  }
}

/// The failures of ``FrontmatterDocument/save(to:)``. Each failure leaves
/// the old file whole.
public enum FrontmatterDocumentSaveError: Error, Equatable, Sendable {
  /// The metadata does not encode as YAML.
  case encodingFailed(description: String)

  /// The `stat(2)` of the target or the `fchmod(2)` of the temporary file
  /// failed with this `errno`.
  case modeFailed(errno: Int32)

  /// The `mkostemp(3)` of the temporary file failed with this `errno`, for
  /// example `ENOENT` when the folder of the file is not there.
  case temporaryFileFailed(errno: Int32)

  /// The `write(2)` of the temporary file failed with this `errno`.
  case writeFailed(errno: Int32)

  /// The `write(2)` of the temporary file wrote only part of the bytes, for
  /// example on a full disk.
  case shortWrite(written: Int, expected: Int)

  /// The `fsync(2)` of the temporary file failed with this `errno`.
  case syncFailed(errno: Int32)

  /// The `close(2)` of the temporary file failed with this `errno`.
  case closeFailed(errno: Int32)

  /// The `rename(2)` of the temporary file over the target failed with this
  /// `errno`.
  case replaceFailed(errno: Int32)
}
