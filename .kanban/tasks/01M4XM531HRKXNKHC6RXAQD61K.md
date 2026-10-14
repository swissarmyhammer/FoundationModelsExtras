---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'TelemetryCapture.Context: add an event wait for spans, log records and metric records'
---
TelemetryTestSupport.TelemetryCapture.Context gives only reads of its spans, logRecords and metricsFactory. Thus, ACPAgent tests must poll it.

Add an event wait on Context: `func wait(until condition: @Sendable (Context) -> Bool) async`. If a different shape fits the type better, use that shape and tell the mail peer session which shape you used.

Rules:
- [ ] Each finished span, each log record and each metric record resumes the waits whose condition is now true.
- [ ] Do not use a clock, a poll, a sleep or a retry.
- [ ] A cancel of the waiting task ends the wait.
- [ ] Fixed-order test: a wait that starts before the record ends.
- [ ] Fixed-order test: a wait that starts after the record ends at once.
- [ ] Fixed-order test: a cancel ends a wait.
- [ ] Run the full suite one time. Push when it is green. Send the commit to the mail peer session.

The mail step 4 work found this gap. #mail-step-4