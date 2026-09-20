import Foundation

/// A debounced "something changed" signal over the layer roots of a stack.
///
/// The watcher watches the directory tree of each existing root
/// recursively -- each directory and each file under it, at any depth --
/// and joins a burst of file system work (the several fast writes of one
/// save of an editor, a `mkdir` and then the writes of several files into
/// it, and so on) into one `onChange` call after a quiet period. It has no
/// opinion about WHAT changed, or about what to do with it: the consumer
/// reads the stack again from the start on each `onChange` call, and it
/// takes nothing from the internals of the watcher.
///
/// `DotfolderStack` holds no cache, thus it needs no watcher of its own.
/// A consumer that caches a result keeps this watcher instead of a watcher
/// of its own: the raw file system work lives beside the stack, and the
/// consumer keeps the work of its own schema only.
///
/// A root that is not there when `start()` runs is armed, and not skipped:
/// the watcher watches the nearest existing ancestor directory of that
/// root, thus the later creation of the root, or a delete and a new create,
/// still fires `onChange`. The rebuild that each flush does resolves the
/// existence of each root again, thus it escalates from an ancestor watch
/// to the real recursive watch at the moment that the root appears.
///
/// Arming has a cost that the consumer must know. The nearest existing
/// ancestor of a missing root can be a busy directory -- `~` when
/// `~/.config` is not there, for example -- and each entry that is made,
/// removed or renamed directly under it wakes this watcher for as long as
/// the root is missing. Each wake is cheap: it stats the awaited path
/// component, which is the child of the ancestor on the way to the root,
/// and the ancestor itself. An event that made the awaited component, or
/// removed the ancestor, schedules a rebuild and an `onChange` call. Each
/// other event under the ancestor costs those stats and nothing more.
///
/// The watcher is built over one
/// `DispatchSource.makeFileSystemObjectSource` for each watched directory
/// and file, and not over FSEvents, and it is built again from the start
/// after each quiet period, thus the entries that a burst made, or removed,
/// are watched (or are no longer watched) when `onChange` fires.
// swiftlint:disable:next no_unchecked_sendable  The serial queue guards each value that changes, and the documentation of each value says so; the compiler cannot check that rule.
public final class DotfolderWatcher: @unchecked Sendable {
  /// The number of milliseconds of quiet that `defaultDebounceInterval`
  /// waits.
  private static let defaultDebounceMilliseconds = 200

  /// The quiet period that each public initializer takes when the caller
  /// names no interval: 200 ms.
  ///
  /// A caller that wants the default period, together with an argument of
  /// its own that comes after it, names this value.
  public static let defaultDebounceInterval = DispatchTimeInterval.milliseconds(
    defaultDebounceMilliseconds)

  /// Marks `queue`, thus `runOnQueue(_:)` can find a reentrant call from
  /// inside an event handler of one of the `DispatchSource` values of this
  /// watcher.
  private static let queueSpecificKey = DispatchSpecificKey<Bool>()

  /// The event mask that each directory-level `DispatchSource` observes,
  /// for a directory of a watched tree and for the nearest existing
  /// ancestor of a missing root alike -- the two must see an entry that is
  /// made, removed or renamed directly under them.
  ///
  /// `nonisolated(unsafe)` here (and not for `queueSpecificKey` above),
  /// because `DispatchSource.FileSystemEvent` itself is not `Sendable`,
  /// although this `OptionSet` of raw bits does not change and is safe to
  /// share.
  nonisolated(unsafe) private static let directoryEventMask: DispatchSource.FileSystemEvent = [
    .write, .delete, .rename,
  ]

  /// The event mask that the `DispatchSource` of a watched file observes:
  /// the events of a directory, and the two events that a write to a file
  /// gives.
  ///
  /// `nonisolated(unsafe)` for the reason that `directoryEventMask` states.
  nonisolated(unsafe) private static let fileEventMask: DispatchSource.FileSystemEvent = [
    .write, .delete, .rename, .extend, .attrib,
  ]

  /// Starts one debounce timer: calls `fire` on `queue` when `interval` is
  /// complete.
  ///
  /// The watcher starts a new timer for each event and cancels no earlier
  /// one. An earlier timer that fires later finds that it is stale and does
  /// nothing (see `flushIfCurrent(_:)`). A timer must call `fire` on
  /// `queue`, because `fire` touches the state that `queue` guards.
  ///
  /// This is the seam that lets a test own the length of the quiet period.
  /// A test that waits on the real clock races its own file work against
  /// the interval, and a loaded host then divides one burst into two
  /// callbacks.
  typealias DebounceTimer = @Sendable (
    _ interval: DispatchTimeInterval, _ queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void
  ) -> Void

  /// The debounce timer of the package: `fire` runs on `queue` when
  /// `interval` of real time is complete.
  private static let startDispatchTimer: DebounceTimer = { interval, queue, fire in
    queue.asyncAfter(deadline: .now() + interval, execute: fire)
  }

  private let roots: [URL]
  private let debounceInterval: DispatchTimeInterval
  private let startDebounceTimer: DebounceTimer
  private let onChange: @Sendable () -> Void
  private let queue: DispatchQueue

  /// Each directory source and file source that is open now, keyed by
  /// absolute path.
  ///
  /// Read and changed only while the code runs on `queue`.
  private var watchedSources: [String: DispatchSourceFileSystemObject] = [:]

  /// For each armed ancestor (keyed by absolute path), the absolute paths
  /// of the entries directly under it whose creation would bring a missing
  /// root nearer to existence. An event on the ancestor that made none of
  /// them, and left the ancestor itself in place, is ignored.
  ///
  /// Read and changed only while the code runs on `queue`.
  private var awaitedChildren: [String: Set<String>] = [:]

  /// How many descriptors `installSource(at:eventMask:onEvent:)` opened
  /// whose cancel handler did not close them yet.
  ///
  /// Read and changed only while the code runs on `queue`.
  private var openDescriptorCount = 0

  /// The number of the newest debounce timer. Each event increases it and
  /// starts a timer that keeps the new value, and `stop()` increases it
  /// too. A timer whose value is not the newest one is stale: a later event
  /// replaced it, or the watcher stopped.
  ///
  /// Read and changed only while the code runs on `queue`.
  private var newestTimerNumber = 0

  /// Whether `start()` ran with no `stop()` after it.
  ///
  /// Read and changed only while the code runs on `queue`.
  private var isWatching = false

  /// Creates a watcher over `roots`, which does not watch yet.
  ///
  /// - Parameters:
  ///   - roots: The layer roots to watch, in the order that the consumer
  ///     gives them -- this type names no directory convention of its own.
  ///     A root that is not on disk when `start()` runs gets its nearest
  ///     existing ancestor directory armed instead, thus the later creation
  ///     of the root is still seen.
  ///   - debounceInterval: How long the tree must stay quiet before a burst
  ///     of events becomes one `onChange` call. The default is
  ///     `defaultDebounceInterval`.
  ///   - onChange: Called one time for each quiet period at the most, on an
  ///     unspecified queue, when something changed under any watched root.
  ///     Never called again after `stop()` gives back control.
  public convenience init(
    roots: [URL],
    debounceInterval: DispatchTimeInterval = DotfolderWatcher.defaultDebounceInterval,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.init(
      roots: roots, debounceInterval: debounceInterval,
      startDebounceTimer: Self.startDispatchTimer, onChange: onChange)
  }

  /// Creates a watcher over the layer roots of `stack`, which does not
  /// watch yet.
  ///
  /// The stack holds no cache: each lookup reads the disk at the time of
  /// the call. A consumer that caches what a lookup gave watches the layer
  /// roots with this initializer and reads the stack again on each
  /// `onChange` call.
  ///
  /// - Parameters:
  ///   - stack: The stack whose layer roots the watcher watches. A layer
  ///     root that is not on disk is armed, as it is for the initializer
  ///     that takes the roots.
  ///   - debounceInterval: How long the tree must stay quiet before a burst
  ///     of events becomes one `onChange` call. The default is
  ///     `defaultDebounceInterval`.
  ///   - onChange: Called one time for each quiet period at the most, on an
  ///     unspecified queue, when something changed under any layer root.
  ///     Never called again after `stop()` gives back control.
  public convenience init(
    stack: some DotfolderStacking,
    debounceInterval: DispatchTimeInterval = DotfolderWatcher.defaultDebounceInterval,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.init(
      stack: stack, debounceInterval: debounceInterval,
      startDebounceTimer: Self.startDispatchTimer, onChange: onChange)
  }

  /// Creates a watcher over the layer roots of `stack` with a given
  /// debounce timer, which does not watch yet.
  ///
  /// Internal, for `@testable` access only: a test gives a timer that the
  /// test ends by hand, thus the speed of the host cannot divide one burst
  /// into two callbacks.
  ///
  /// - Parameters:
  ///   - stack: The stack whose layer roots the watcher watches.
  ///   - debounceInterval: The interval that `startDebounceTimer` receives.
  ///   - startDebounceTimer: Starts one debounce timer. See
  ///     `DebounceTimer` for the contract.
  ///   - onChange: Called one time for each quiet period at the most, as it
  ///     is for the public initializer.
  convenience init(
    stack: some DotfolderStacking,
    debounceInterval: DispatchTimeInterval,
    startDebounceTimer: @escaping DebounceTimer,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.init(
      roots: stack.layers.map(\.root), debounceInterval: debounceInterval,
      startDebounceTimer: startDebounceTimer, onChange: onChange)
  }

  /// Creates a watcher over `roots` with a given debounce timer, which does
  /// not watch yet.
  ///
  /// Internal, for `@testable` access only, for the reason that the
  /// initializer above states.
  ///
  /// - Parameters:
  ///   - roots: The layer roots to watch, as they are for the public
  ///     initializer.
  ///   - debounceInterval: The interval that `startDebounceTimer` receives.
  ///   - startDebounceTimer: Starts one debounce timer. See
  ///     `DebounceTimer` for the contract.
  ///   - onChange: Called one time for each quiet period at the most, as it
  ///     is for the public initializer.
  init(
    roots: [URL],
    debounceInterval: DispatchTimeInterval,
    startDebounceTimer: @escaping DebounceTimer,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.roots = roots
    self.debounceInterval = debounceInterval
    self.startDebounceTimer = startDebounceTimer
    self.onChange = onChange
    queue = DispatchQueue(label: "FoundationModelsExtras.DotfolderWatcher")
    queue.setSpecific(key: Self.queueSpecificKey, value: true)
  }

  /// Starts to watch each existing root, recursively.
  ///
  /// Safe to call more than one time; a call while the watcher watches
  /// already does nothing.
  public func start() {
    runOnQueue {
      guard !self.isWatching else { return }
      self.isWatching = true
      // Defensive: this makes sure that the watcher never watches on top
      // of a source that stayed behind. There must be none, because each
      // path that fills `watchedSources` has a path that clears it first,
      // but this keeps `start()` correct if that pair is ever broken
      // somewhere else.
      self.cancelAllWatchedSources()
      self.armRoots()
    }
  }

  /// Stops the watch and discards each debounce timer that is in flight.
  ///
  /// No more `onChange` call happens after `stop()` gives back control.
  /// Safe to call more than one time, and safe to call with no `start()`
  /// before it.
  public func stop() {
    runOnQueue {
      guard self.isWatching else { return }
      self.isWatching = false
      // This makes each timer that is still in flight stale, thus a timer
      // from before this `stop()` cannot flush after a later `start()`.
      self.newestTimerNumber += 1
      self.cancelAllWatchedSources()
    }
  }

  /// Cancels each open source and each debounce timer that is in flight,
  /// the same as an explicit `stop()`, thus a watcher that goes out of
  /// scope with no `stop()` never leaks a file descriptor and never fires
  /// `onChange` again.
  deinit {
    stop()
  }

  /// How many watch sources the watcher holds now.
  ///
  /// Internal, for `@testable` access only: a test verifies directly that a
  /// reentrant `stop()` call from inside `onChange` leaves no source open,
  /// and does not infer it from the times of the callbacks.
  var watchedSourceCountForTesting: Int {
    queue.sync { watchedSources.count }
  }

  /// How many descriptors are open for watch sources and are not closed by
  /// a cancel handler yet.
  ///
  /// Internal, for `@testable` access only: a test verifies that a source
  /// that a later source replaced under the same path was cancelled (thus
  /// its descriptor is closed) and was not dropped without a cancel. While
  /// the watcher watches, this value settles to
  /// `watchedSourceCountForTesting`; after `stop()` it settles to zero. It
  /// settles and does not agree immediately, because a cancel handler runs
  /// on `queue` after `cancel()`.
  var openDescriptorCountForTesting: Int {
    queue.sync { openDescriptorCount }
  }

  // MARK: - Queue reentrancy

  /// Runs `work` with exclusive access to the state of this watcher that
  /// changes: directly when the code runs on `queue` already (a nested call
  /// from inside the event handler of a `DispatchSource`), and through
  /// `queue.sync` in each other case.
  ///
  /// This prevents the deadlock that a plain `queue.sync` would risk if
  /// `stop()` (or `deinit`) ever ran from inside an `onChange` call that
  /// itself runs on `queue`.
  ///
  /// - Parameter work: The work to do.
  private func runOnQueue(_ work: @escaping () -> Void) {
    guard DispatchQueue.getSpecific(key: Self.queueSpecificKey) == nil else {
      work()
      return
    }
    queue.sync(execute: work)
  }

  // MARK: - How the watch tree is built

  /// Arms each root in `roots`: an existing root gets the real recursive
  /// watch, and a missing root gets a watch on its nearest existing
  /// ancestor directory instead, thus the later creation of the root still
  /// fires `onChange`. The next `flush()` runs this again and escalates to
  /// the real watch when the root exists.
  ///
  /// Always called on `queue`.
  private func armRoots() {
    for root in roots {
      if FileManager.default.fileExists(atPath: root.path) {
        watchTree(at: root)
      } else if let arming = Self.ancestorArming(for: root) {
        armAncestor(arming.ancestor, awaiting: arming.awaitedChild)
      }
    }
  }

  /// Where the watch of a missing root is armed: the nearest existing
  /// ancestor directory, and the entry directly under it whose creation is
  /// the next step to the existence of the root.
  private struct AncestorArming {
    let ancestor: URL
    let awaitedChild: URL
  }

  /// Finds the nearest existing ancestor directory of `url`, with a walk up
  /// through `deletingLastPathComponent()` until one is on disk, and the
  /// child of that ancestor on the path to `url`.
  ///
  /// - Parameter url: The path that is not there, whose ancestor the walk
  ///   finds.
  /// - Returns: The arming point, or `nil` when not even the root of the
  ///   volume is there, which does not occur in practice.
  private static func ancestorArming(for url: URL) -> AncestorArming? {
    var awaitedChild = url
    var candidate = url.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: candidate.path) {
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { return nil }
      awaitedChild = candidate
      candidate = parent
    }
    return AncestorArming(ancestor: candidate, awaitedChild: awaitedChild)
  }

  /// Records `child` as awaited under `ancestor` and opens a source whose
  /// events `ancestorEventDidOccur(at:)` filters, if `ancestor` does not
  /// have a source already from an earlier root or from a watched tree that
  /// it belongs to.
  ///
  /// Always called on `queue`.
  ///
  /// - Parameters:
  ///   - ancestor: The nearest existing ancestor of a missing root.
  ///   - child: The entry directly under `ancestor` whose creation brings
  ///     that root nearer to existence.
  private func armAncestor(_ ancestor: URL, awaiting child: URL) {
    awaitedChildren[ancestor.path, default: []].insert(child.path)
    guard watchedSources[ancestor.path] == nil else { return }
    let ancestorPath = ancestor.path
    installSource(at: ancestor, eventMask: Self.directoryEventMask) { [weak self] in
      self?.ancestorEventDidOccur(at: ancestorPath)
    }
  }

  /// Opens a `DispatchSource` for `directory` and for each entry under it
  /// now, recursively, and adds each one to `watchedSources`.
  ///
  /// Always called on `queue`.
  ///
  /// - Parameter directory: The directory to watch, together with what is
  ///   under it.
  private func watchTree(at directory: URL) {
    watchEntry(at: directory, eventMask: Self.directoryEventMask)
    for child in Self.directoryContents(of: directory) {
      if child.isDirectory {
        watchTree(at: child.url)
      } else {
        watchEntry(at: child.url, eventMask: Self.fileEventMask)
      }
    }
  }

  /// Opens one `DispatchSource` for an entry of the watched tree at `url`,
  /// which observes `eventMask`; each event starts the debounce timer
  /// again.
  ///
  /// Always called on `queue`.
  ///
  /// - Parameters:
  ///   - url: The file or the directory to watch.
  ///   - eventMask: The events to observe on `url`.
  private func watchEntry(at url: URL, eventMask: DispatchSource.FileSystemEvent) {
    installSource(at: url, eventMask: eventMask) { [weak self] in
      self?.fileSystemEventDidOccur()
    }
  }

  /// Opens one `DispatchSource` for `url`, which observes `eventMask`, and
  /// stores it in `watchedSources` under `url.path`. It cancels a source
  /// that is stored there already first, thus the earlier descriptor is
  /// closed and not leaked. That replacement occurs when the ancestor of a
  /// missing root is armed and the watched tree of a later root then
  /// reaches the same directory.
  ///
  /// A path that the watcher cannot open (a broken symbolic link, or a
  /// permission error, for example) is simply skipped, and is not an error.
  /// Always called on `queue`.
  ///
  /// - Parameters:
  ///   - url: The file or the directory to watch.
  ///   - eventMask: The events to observe on `url`.
  ///   - onEvent: Called on `queue` for each event that the source gives.
  private func installSource(
    at url: URL, eventMask: DispatchSource.FileSystemEvent, onEvent: @escaping () -> Void
  ) {
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    openDescriptorCount += 1

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: eventMask, queue: queue)
    source.setEventHandler(handler: onEvent)
    source.setCancelHandler { [weak self] in
      close(descriptor)
      self?.openDescriptorCount -= 1
    }
    watchedSources[url.path]?.cancel()
    watchedSources[url.path] = source
    source.resume()
  }

  /// Cancels and discards each source that is open now, and forgets each
  /// awaited child, thus the next `armRoots()` starts from nothing.
  ///
  /// Always called on `queue`.
  private func cancelAllWatchedSources() {
    for source in watchedSources.values {
      source.cancel()
    }
    watchedSources.removeAll()
    awaitedChildren.removeAll()
  }

  // MARK: - How an event is handled

  /// Filters an event on an armed ancestor: it starts the debounce timer
  /// only when an awaited child exists now (thus a missing root came nearer
  /// to existence and the rebuild can escalate), or when the ancestor
  /// itself is gone (thus the rebuild must arm higher up). Each other event
  /// is unrelated work in a directory that this watcher never wanted to
  /// watch for its own sake, and is ignored.
  ///
  /// Always called on `queue`, from the event handler of an ancestor
  /// source.
  ///
  /// - Parameter ancestorPath: The absolute path of the armed ancestor.
  private func ancestorEventDidOccur(at ancestorPath: String) {
    let fileManager = FileManager.default
    let ancestorVanished = !fileManager.fileExists(atPath: ancestorPath)
    let childAppeared = (awaitedChildren[ancestorPath] ?? []).contains {
      fileManager.fileExists(atPath: $0)
    }
    guard ancestorVanished || childAppeared else { return }
    fileSystemEventDidOccur()
  }

  /// Starts the shared debounce timer again: it starts a new timer, and the
  /// new timer number makes each earlier timer stale.
  ///
  /// Always called on `queue`, from the event handler of a
  /// `DispatchSource`.
  private func fileSystemEventDidOccur() {
    guard isWatching else { return }
    newestTimerNumber += 1
    let timerNumber = newestTimerNumber
    startDebounceTimer(debounceInterval, queue) { [weak self] in
      self?.flushIfCurrent(timerNumber)
    }
  }

  /// Flushes when the timer that fired is the newest one, and does nothing
  /// for a stale timer.
  ///
  /// Always called on `queue`, from a debounce timer.
  ///
  /// - Parameter timerNumber: The number of the timer that fired.
  private func flushIfCurrent(_ timerNumber: Int) {
    guard timerNumber == newestTimerNumber else { return }
    flush()
  }

  /// Builds the watch tree again from the state of the roots on disk now,
  /// thus the entries that the burst made, or removed, are watched (or are
  /// no longer watched), then fires the one joined `onChange` callback.
  ///
  /// The sequence carries the load. `onChange` tells the consumer to read
  /// the tree, and a consumer can change the tree again as soon as it knows
  /// about the reload. The new sources are thus open before `onChange`
  /// runs: a change before that point is one that `onChange` reads, and a
  /// change after that point is one that a new source reports. A rebuild
  /// after `onChange` loses a change between the two: `cancel()` drops the
  /// event that the old source holds, and the new source opens after the
  /// change.
  ///
  /// Always called on `queue`, at the end of a quiet period. `onChange` is
  /// free to call `stop()` reentrantly (`runOnQueue(_:)` makes that safe);
  /// that `stop()` cancels the sources that this rebuild opened, and
  /// nothing after `onChange` opens a source again.
  private func flush() {
    guard isWatching else { return }
    cancelAllWatchedSources()
    armRoots()
    onChange()
  }

  // MARK: - How a directory is listed

  /// One directory entry that `directoryContents(of:)` gives: its URL, and
  /// whether it is a directory itself.
  private struct DirectoryEntry {
    let url: URL
    let isDirectory: Bool
  }

  /// Lists the immediate contents of `directory`.
  ///
  /// A `directory` that the watcher cannot read, or that is not there,
  /// gives no entry, and does not throw.
  ///
  /// - Parameter directory: The directory to list.
  /// - Returns: One `DirectoryEntry` for each immediate child.
  private static func directoryContents(of directory: URL) -> [DirectoryEntry] {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else {
      return []
    }
    return entries.map { entry in
      let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      return DirectoryEntry(url: entry, isDirectory: isDirectory)
    }
  }
}
