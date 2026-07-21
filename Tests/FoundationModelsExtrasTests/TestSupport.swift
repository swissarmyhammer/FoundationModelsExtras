import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Resolves `url` to its real, firmlink-free path via POSIX `realpath(3)`.
///
/// On macOS, `/var` (and thus `FileManager.default.temporaryDirectory`) is a
/// *firmlink* to `/private/var` — a construct `URL.resolvingSymlinksInPath()`
/// deliberately does not cross, but `FileManager.contentsOfDirectory` returns
/// paths that already have crossed it (via the kernel's own path
/// resolution). Fixture roots are canonicalized once at creation so every
/// URL built from them compares equal to what directory enumeration
/// returns.
///
/// Shared across the test target (`DotfolderLoaderTests`,
/// `DotfolderStackTests`, `UntrustedRenderingTests`, `IgnoreProcessorTests`,
/// and any future suite that builds throwaway fixture trees under a temp
/// directory) rather than duplicated per file.
func canonicalize(_ url: URL) -> URL {
  var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
  guard realpath(url.path, &buffer) != nil else { return url }
  let nullTerminatorIndex = buffer.firstIndex(of: 0) ?? buffer.count
  let path = String(
    decoding: buffer[..<nullTerminatorIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
  return URL(fileURLWithPath: path, isDirectory: true)
}
