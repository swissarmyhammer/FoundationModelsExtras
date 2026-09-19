import Synchronization

@testable import FoundationModelsExtras

/// The diagnostics that a stack gave, behind a lock so the `@Sendable`
/// hook can append to them.
///
/// Lock-based rather than an `actor` because the hook is called from a
/// synchronous lookup and cannot `await`. A `final class` around the
/// `Mutex` because `Mutex` is non-copyable, so the hook cannot capture it
/// directly.
final class DiagnosticLog: Sendable {
  private let entries = Mutex<[DotfolderStack.Diagnostic]>([])

  /// Appends one diagnostic.
  func record(_ diagnostic: DotfolderStack.Diagnostic) {
    entries.withLock { $0.append(diagnostic) }
  }

  /// A snapshot of the diagnostics recorded so far.
  var diagnostics: [DotfolderStack.Diagnostic] {
    entries.withLock { $0 }
  }
}
