import Foundation
import FoundationModelsExtras
import Synchronization
import Testing

/// The tests of `DotfolderWatcher` that need the real file system events of
/// the OS: a real write under a watched root gives a callback, a root that
/// appears later is seen through its armed ancestor and then through its
/// own recursive watch, an unreadable directory does not silence its
/// readable siblings, a change made inside `onChange` is not lost, and the
/// README example works.
///
/// The unit tests in the root package give the events by hand and check the
/// counts exactly. These tests use the public API with the real
/// `DispatchSource` values and the real debounce timer, thus they check only
/// that the expected callbacks come.
///
/// Each wait ends on the callback that it expects, and reads no clock. When
/// the OS never gives an event, the wait does not end, and the run stops
/// making output.
@Suite("Dotfolder watcher with real file system events")
struct DotfolderWatcherIntegrationTests {
  /// The quiet period of each watcher under test. A short period keeps the
  /// tests fast. A slow host can divide one burst into two callbacks, thus
  /// no test asserts an exact count.
  private static let debounceInterval: DispatchTimeInterval = .milliseconds(50)

  /// The name of the document that each test writes in an entry folder.
  private static let documentName = "document.md"

  /// How many callbacks the test of the edit inside `onChange` waits for:
  /// one for the first write, and one for the edit.
  private static let callbacksWithTheEditInsideOnChange = 2

  @Test("a real file write under a watched root gives a callback")
  func aRealFileWriteUnderAWatchedRootGivesACallback() async throws {
    try await Self.withTemporaryDirectory { root in
      let (callbacks, onChange) = AsyncStream.makeStream(of: Void.self)
      let watcher = DotfolderWatcher(roots: [root], debounceInterval: Self.debounceInterval) {
        onChange.yield()
      }
      watcher.start()
      defer { watcher.stop() }

      var arrivals = callbacks.makeAsyncIterator()
      try Self.writeDocument(named: "new-entry", in: root)
      #expect(await Self.wait(for: 1, from: &arrivals))
    }
  }

  @Test("a root that appears later is seen through its armed ancestor, then through its own watch")
  func aRootThatAppearsLaterIsSeenThroughItsArmedAncestor() async throws {
    try await Self.withTemporaryDirectory { privateDirectory in
      let lateRoot = privateDirectory.appendingPathComponent("arrives-later", isDirectory: true)
      let (callbacks, onChange) = AsyncStream.makeStream(of: Void.self)
      let watcher = DotfolderWatcher(roots: [lateRoot], debounceInterval: Self.debounceInterval) {
        onChange.yield()
      }
      watcher.start()
      defer { watcher.stop() }

      var arrivals = callbacks.makeAsyncIterator()
      try Self.writeDocument(named: "arrived-entry", in: lateRoot)
      #expect(await Self.wait(for: 1, from: &arrivals))

      // The flush escalated to the recursive watch of the root. An edit two
      // levels under it never touches the ancestor.
      try Self.writeDocument(named: "arrived-entry", in: lateRoot, bodySuffix: "edited")
      #expect(await Self.wait(for: 1, from: &arrivals))
    }
  }

  @Test(
    "an unreadable directory inside a root is skipped, and its readable siblings still report",
    .disabled(if: isRoot, "root reads a mode-0o000 directory, thus the unreadable branch is not reachable"))
  func anUnreadableDirectoryInsideARootIsSkippedAndItsReadableSiblingsStillReport() async throws {
    try await Self.withTemporaryDirectory { root in
      let lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
      try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: Self.unreadableMode], ofItemAtPath: lockedDirectory.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: Self.ownerAccessMode], ofItemAtPath: lockedDirectory.path)
      }

      let (callbacks, onChange) = AsyncStream.makeStream(of: Void.self)
      let watcher = DotfolderWatcher(roots: [root], debounceInterval: Self.debounceInterval) {
        onChange.yield()
      }
      watcher.start()
      defer { watcher.stop() }

      var arrivals = callbacks.makeAsyncIterator()
      try Self.writeDocument(named: "readable-entry", in: root)
      #expect(await Self.wait(for: 1, from: &arrivals))
    }
  }

  @Test("a change made inside onChange is reported after the flush")
  func aChangeMadeInsideOnChangeIsReported() async throws {
    try await Self.withTemporaryDirectory { root in
      try Self.writeDocument(named: "edited-in-flush", in: root)
      let edit = OneTimeEdit(entryName: "edited-in-flush", root: root)
      let (callbacks, onChange) = AsyncStream.makeStream(of: Void.self)
      let watcher = DotfolderWatcher(roots: [root], debounceInterval: Self.debounceInterval) {
        onChange.yield()
        edit.run()
      }
      watcher.start()
      defer { watcher.stop() }

      var arrivals = callbacks.makeAsyncIterator()
      try Self.writeDocument(named: "edited-in-flush", in: root, bodySuffix: "first edit")
      #expect(await Self.wait(for: Self.callbacksWithTheEditInsideOnChange, from: &arrivals))
      #expect(edit.failure == nil)
    }
  }

  // MARK: - README example

  /// Mirrored in the `DotfolderWatcher` section of README.md. Keep the two
  /// in sync.
  ///
  /// Makes the watcher that the README shows over a stack whose project
  /// layer is not there yet, then makes that layer and waits for the
  /// callback, thus the README cannot go stale without a test that fails.
  /// The test binds `workingDirectory` and `userDirectory` to one temporary
  /// folder, thus it touches no home directory.
  @Test("the README example: a watcher over a stack reports a new project layer")
  func readmeStackWatcherExample() async throws {
    try await Self.withTemporaryDirectory { home in
      let workingDirectory = home.appendingPathComponent("project", isDirectory: true)
      let userDirectory = home.appendingPathComponent("config", isDirectory: true)
      try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
      let (callbacks, reloads) = AsyncStream.makeStream(of: Void.self)
      let reload: @Sendable () -> Void = { reloads.yield() }

      let stack = DotfolderStack(
        name: "myagent", workingDirectory: workingDirectory, userDirectory: userDirectory)

      let watcher = DotfolderWatcher(stack: stack) {
        // A layer changed on disk. The stack holds no cache, thus the next
        // lookup gives the new files.
        reload()
      }
      watcher.start()
      defer { watcher.stop() }

      var arrivals = callbacks.makeAsyncIterator()
      try Self.writeDocument(
        named: "new-entry", in: workingDirectory.appendingPathComponent(".myagent", isDirectory: true))
      #expect(await Self.wait(for: 1, from: &arrivals))
    }
  }

  // MARK: - Test helpers

  /// The file mode that refuses each read, thus a directory listing fails.
  private static let unreadableMode = 0o000

  /// The file mode that the teardown puts back, thus the temporary
  /// directory can be removed.
  private static let ownerAccessMode = 0o700

  /// Whether the test process is root. Root reads a mode-`0o000`
  /// directory, thus the test of the unreadable directory cannot reach the
  /// branch that it covers and is skipped there.
  private static var isRoot: Bool { geteuid() == 0 }

  /// Waits until `count` more callbacks arrive.
  ///
  /// - Parameters:
  ///   - count: The number of callbacks to wait for.
  ///   - arrivals: The iterator of the callbacks of the watcher.
  /// - Returns: `true` when the callbacks arrived, and `false` when the
  ///   stream ended first.
  private static func wait(for count: Int, from arrivals: inout AsyncStream<Void>.Iterator) async -> Bool {
    for _ in 0..<count {
      guard await arrivals.next() != nil else { return false }
    }
    return true
  }

  /// Makes a new temporary directory, hands it to `body`, then removes it
  /// in each case.
  ///
  /// - Parameter body: The body of the test, with the directory.
  /// - Throws: The error of `body` or of the directory.
  private static func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
  }

  /// Writes `<directory>/<name>/document.md`, and makes the entry folder
  /// first when it is not there.
  ///
  /// - Parameters:
  ///   - name: The name of the entry folder.
  ///   - directory: The root to write under.
  ///   - bodySuffix: Text that the body ends with, thus two writes of one
  ///     name give two different texts.
  /// - Throws: The error of `FileManager.createDirectory` or of
  ///   `String.write`.
  fileprivate static func writeDocument(named name: String, in directory: URL, bodySuffix: String = "") throws {
    let entryDirectory = directory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
    try "Body text for \(name). \(bodySuffix)\n".write(
      to: entryDirectory.appendingPathComponent(documentName), atomically: true, encoding: .utf8)
  }
}

/// Edits the document of one entry the first time that `run()` is called,
/// and does nothing on each later call.
///
/// A test calls `run` inside `onChange`. The edit is then in the flush that
/// made the callback, and only the first flush makes an edit, thus the test
/// has an end.
///
/// A `Mutex` guards each value that changes, thus the compiler checks the
/// plain `Sendable` conformance.
private final class OneTimeEdit: Sendable {
  private let entryName: String
  private let root: URL
  private let hasRun = Mutex(false)
  private let failureText = Mutex<String?>(nil)

  /// The error text of an edit that failed, or `nil`.
  var failure: String? {
    failureText.withLock { $0 }
  }

  /// Makes an edit that writes the document of `entryName`.
  ///
  /// - Parameters:
  ///   - entryName: The name of the entry folder whose document the edit
  ///     writes.
  ///   - root: The watched root that holds the entry.
  init(entryName: String, root: URL) {
    self.entryName = entryName
    self.root = root
  }

  /// Writes the file on the first call only. The error of a write goes to
  /// `failure`, because `onChange` cannot throw.
  func run() {
    let isFirstCall = hasRun.withLock { hasRun in
      defer { hasRun = true }
      return !hasRun
    }
    guard isFirstCall else { return }
    do {
      try DotfolderWatcherIntegrationTests.writeDocument(
        named: entryName, in: root, bodySuffix: "edit inside onChange")
    } catch {
      failureText.withLock { $0 = String(describing: error) }
    }
  }
}
