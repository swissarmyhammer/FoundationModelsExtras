---
assignees:
- claude-code
position_column: done
position_ordinal: ff9d80
title: 'R1: a cancelled run asks no new question, and a cancel of a closed token ends its questions'
---
## Problem

a. `awaitAnswer` does not check for a cancelled run. A snippet that asks again after a cancel (`while (r.action === "cancel") r = await elicit(...)`) opens question 2 after `cancel(completionToken:)` ended question 1. Only the user, `sweep()` or `cancelOpenElicitations()` can end question 2. The run does not settle, and the session shows idle.

b. `cancel(completionToken:)` of a settled or unknown token returns before it ends the questions of that token. A top-level foreground call asks with a token that is not on the run plane (ContextBindingTool, RunToCompletionRunner). A child task can ask after the run body returned.

## Fix

- The run plane records each token that `cancel(completionToken:)` or `sweep()` cancelled, for all tokens: open, settled and unknown.
- `awaitAnswer` for a cancelled token gives `.cancel(reason: "run cancelled")` at once. It stores no question and posts no event.
- `cancel(completionToken:)` ends the open questions of the token with that cancel also when the token is settled or unknown, and then returns the same outcome as before.

## Tests (fail on the old code)

- After a cancel of an open run, a second question of the run gets the cancel at once, with no post.
- A cancel of an unknown token ends its open question, and returns `.unknownToken`.
- A cancel of a settled token ends its open question, and returns `.alreadySettled`. #bug