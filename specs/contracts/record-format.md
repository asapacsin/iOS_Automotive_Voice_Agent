# Record formats (F-12 §21 item 4)

Every conversation record (`Documents/conversations/*.txt`) starts with `recordFormat <n>`. A file without that line is
format 0. `ConversationRecord.formatVersion` in `Packages/NovaCore/Sources/NovaAgent/Record/ConversationRecord.swift`
is the format new files are written in; `Packages/NovaCore/Tests/NovaAgentTests/Fixtures/record-format-<n>.txt` is
its fixed session. `scripts/gates/check_record_format.py` fails when a format has no row here or no fixture.

To change a line: raise `formatVersion` by one, add the new fixture (old ones stay), add a row here, and give
`scripts/records/read.py` a reader for it.

| Format | First commit that writes it | What changed from the one before |
|---|---|---|
| 0 | (before T-031u) | Records written before `recordFormat` existed: §17 header (`app …`) then `<ms> <kind> <content>` lines. Read best-effort, rows marked `legacy=true`. |
| 1 | T-031u (branch claude/nice-mccarthy-4af8pp) | Adds the first line `recordFormat 1`; every other line is unchanged from format 0. |
