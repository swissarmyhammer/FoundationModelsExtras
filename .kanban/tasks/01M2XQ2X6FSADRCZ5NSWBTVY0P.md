---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: 'MarketplaceLocation: the normalized URL of a file:// git source changes when its folder is gone'
---
## What

`MarketplaceLocation.localFolder(_:)` normalizes a `file://` URL with `URL(fileURLWithPath:isDirectory:).standardizedFileURL`. On macOS that call removes the `/private` prefix of a path only when the path exists on the disk. Thus a `file:///private/var/.../fixture.git` source normalizes to `file:///var/.../fixture.git` while the repository exists, and to `file:///private/var/.../fixture.git` after the repository is deleted.

`MarketplaceIdentity.cacheFolderName(key:normalizedURL:)` hashes the normalized URL. Thus a store over the same source string reads a different cache folder after the local repository is gone, and it does not find the snapshot that an earlier store installed. Card ^qtwjzx9 found this when its "unreachable URL keeps the last good snapshot" test deleted the fixture repository between two stores; that test now fails the remote through a transport double instead.

Decide and implement one rule: the normalized `file://` URL must not depend on whether the path exists. One option is to keep the path as the host wrote it, with only the lexical clean-up (`..`, `.`, trailing `/`). Another is `resolvingSymlinksInPath()` on both forms. Write the rule in the doc comment of `normalizedURL`.

## Acceptance Criteria

- [ ] A `file://` git source under `/private/var` gives the same normalized URL and the same cache folder name before and after its folder is deleted.
- [ ] `MarketplaceSourceTests` or `MarketplaceLocalSourceTests` holds a test for that rule.
- [ ] `swift test` is green.

#marketplace