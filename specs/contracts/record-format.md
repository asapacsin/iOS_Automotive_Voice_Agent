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
| 1 | f4dc949 (T-031u) | Adds the first line `recordFormat 1`; every other line is unchanged from format 0. |
| 2 | 0c685e2 (T-031y) | Header gains `agentVersion <v>`, `agentHash <h>`, `model <requested>` right after the `app` line (F-09b §15 item 6); event lines unchanged. |
| 3 | bff0cfb (T-031z) | Adds the `screen <key>=<on\|off> … musicVolume=<n>` event line, one per `屏幕` line sent (F-09b §16 item 9); every other line unchanged. |
| 4 | ee866b2 (T-031zb) | Adds the `panel <key> <on\|off> top=<panel\|none>` event line, one per view report at that moment (F-09b §17 item 7); every other line unchanged. |
| 5 | (T-040zj) | The `screen …` line gains `tripNextButton=<on\|off> stopNavigationButton=<on\|off>` after `navigation=` (F-15b §57 item 4); a `tool-result` whose data has `problems` writes `problems=<n>` instead of the lines and a `REPEATED_FAILURE` adds `trip repeat-blocked code=<code>` (F-15b §56 item 6); every other line unchanged. |
