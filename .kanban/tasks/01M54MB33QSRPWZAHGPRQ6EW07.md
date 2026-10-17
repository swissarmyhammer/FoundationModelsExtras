---
assignees:
- claude-code
depends_on:
- 01M53BTZ0M0DH3HXBD47N7BNKZ
- 01M54QGXNTCEDD848YPNBB4PPJ
position_column: todo
position_ordinal: '80'
title: 'IntegrationTests: share the model loads and remove redundant tests'
---
## Goal

Make the integration tests use less time in CI. Do not change swift-ci.yaml or the .github files.

## Scope

1. Share the model loads.
   - Load each model one time in each suite. If the pool already permits it, load each model one time in each process.
   - Put the shared fixture in IntegrationTests/Support.
   - Each test must close or release what it holds. This is also necessary when the test throws.
   - Do not add a clock, sleep, poll, retry or time limit.
2. Remove redundant tests.
   - Remove a test only when a different test proves the same behavior.
   - Make a list on this card. For each test to remove, write the test that covers it.
   - Send the list to the peer session before you delete a test. The peer reviews the list.
   - The first candidates are: MPS:12, MPS:24, GQ:61, GQ:83, GQ:140, MP:68, MP:106 (merge it into MP:119), PE:191, PE:210, PE:226, TH:111, TH:129. Also merge TH:199 and TH:220, use L1B in place of Q4B in MP:90, and give PE:242 fewer tokens.
3. Report the integration time before and after. Use the CI times. Do not use repeated local runs.

## Order

Start this card only after ^7n7bnkz is done. Do not do the two cards at the same time.

## Acceptance

- Each model loads one time in each suite, or one time in each process.
- The peer approved the list of removed tests before the deletion.
- One full local run passes. CI passes.
- The card records the CI integration time before and after.