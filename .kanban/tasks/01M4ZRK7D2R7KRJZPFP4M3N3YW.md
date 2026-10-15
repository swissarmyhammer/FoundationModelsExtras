---
assignees:
- claude-code
depends_on:
- 01M4ZRK3F96XBGNPNDEV5E64D3
position_column: todo
position_ordinal: '8280'
title: 'Mail step 8 T2: build with no new warnings, one full test run, commit, and report the removed public names'
---
- [ ] Build FoundationModelsExtras. The build has no new warnings.
- [ ] Run the full test suite one time. Do not repeat the run.
- [ ] Make a local commit.
- [ ] Report the commit and each removed public name to the coordinating session.
- [ ] Push only after the coordinating session accepts T2. This change removes public API.

Rules: a test that fails only sometimes is a bad test; find and fix the cause. No time limit, sleep, poll or retry. Sample a hung process of this session before you stop it, and stop only the pids of this session.

#mail-step-8