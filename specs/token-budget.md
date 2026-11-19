# Token budget for agent work on this repo (owner request 2026-11-19)

Development process only; nothing here changes the app. Tasks T-900a..T-900f in specs/work.json.

## 1. Why

Usage over the last day was ~80 % subagent requests (`/usage`). The repeated cost is reading: one full read of
`specs/features/trip-plan.md` (~160 KB) is roughly 40–50k tokens, and every builder and reviewer of a trip item
read it. `specs/work.json` (~190 KB) and `specs/STATUS.md` (~120 KB) grow with every finished task.

## 2. Sources (community practice, copied, not invented)

- Large-file read guard as a PreToolUse hook: deny a `Read` of a big file without `offset`, tell the agent to
  Grep then read a range; reads with `offset` pass. openclawdc "Claude Code hooks cut token burn"
  (https://openclawdc.com/blog/claude-code-hooks-cut-token-burn/); pchalasani safety hooks
  `file_size_conditional_hook` (https://pchalasani.github.io/claude-code-tools/plugins-detail/safety-hooks).
  Hook contract: Claude Code hooks guide (https://code.claude.com/docs/en/hooks-guide).
- Short always-loaded entry file, detail read on demand: path-scoped rules / index convention
  (https://ao92265.github.io/claude-code-playbook/docs/path-scoped-rules/).
- Subagent `model` and `tools` in `.claude/agents/*.md` frontmatter; a project agent named like a built-in
  overrides it (https://code.claude.com/docs/en/sub-agents).
- Subagents cost more in total, they protect the main context
  (https://dev.to/onlineeric/claude-code-sub-agents-burn-out-your-tokens-4cd8); `/clear` between tasks
  (https://claude.com/ko/resources/articles/maximizing-the-value-of-your-claude-code-sessions).
- Hot memory capped and visible to the agent, archive searchable, the agent edits through tools (Letta core vs
  archival memory, https://docs.letta.com/advanced/memory-management); live file plus an archive written only by
  a GC step started from the Stop hook (https://gist.github.com/sigalovskinick/e2e329bb37ecc74b9f15d5ba74ee1ee5);
  per entry keep / merge / skip chosen by the agent (REALM, https://arxiv.org/pdf/2609.16053); summarizing is
  safer than deleting (https://publish.obsidian.md/cameron/reports/memory-decay-research).

## 3. Items

1. **Spec section helper (T-900a).** `scripts/spec_section.py <feature>` lists sections with line ranges and
   sizes from the headings (never stale); `<feature> <§>` prints one section. AGENTS.md says to use it.
2. **Read guard (T-900b).** `scripts/hooks/read_guard.py`, PreToolUse on `Read` in `.claude/settings.json`:
   a file over 40 KB read without `offset` or `limit` is denied; the reason names Grep, Read with offset/limit
   and scripts/spec_section.py. With `offset` or `limit`, a small file, a missing file or unreadable input:
   allowed (the guard never blocks on its own error). A relative path is taken from the event's `cwd`. Images and PDFs are not text and are allowed.
   The 40 KB limit is overridable by `NOVA_READ_GUARD_KB`; `0` turns the guard off.
3. **Agent routing (T-900c).** `.claude/agents/Explore.md`: read-only search on `model: haiku` (search does not
   need the main model). `.claude/agents/spec-reviewer.md`: the independent read-only review AGENTS.md requires,
   `model: inherit`, tools Read/Grep/Glob/Bash, told to read only the item's sections via the helper.
4. **Workflow rule (T-900d)** in AGENTS.md: build and fix in the main session; a subagent only for the required
   high-effort PASS review; re-checks after a fix at medium effort; parallel agents only when the owner asks;
   no `/goal` while the work waits on the owner; `/clear` between batches instead of a new session.
5. **Environment setup script (T-900e).** The owner's cloud environment installs Swift 6.1.2 into `/opt/swift`,
   puts it on PATH and runs `swift build --build-tests` for NovaCore, NovaServices, NovaRealtime, so a new
   session does not rebuild by hand. Stored on the environment, not in the repo; text in §5.
6. **History archive with the model's judgment (T-900f).** Trigger: the Stop hook reports
   「history large: STATUS.md N/60 KB, work.json M/80 KB」 only when over. A script prints a compact candidate
   table (id, status, date, one line, open dependents, pending NOT_VERIFIED/device rows, last mention); the model
   picks keep / archive / summarize per item with a one-line reason; the script applies only moves that pass:
   never an open item, a stub left in `work.json` for every archived id (frontier.py needs every dependency id),
   full text kept in `STATUS-archive.md` / `work-archive.json`, archives written only by the script.
   `find <id>` searches the archive. A gate fails on an id in both files or a stub without its archive entry.
   One commit per pass with the reasons.

## 4. Acceptance

| # | Case | Expected | Level |
|---|---|---|---|
| 1 | `spec_section.py trip-plan` / `trip-plan 51` / `trip-plan 5.2` / unknown § | list; §51 only; §5.2 only; error naming the file | unit |
| 2 | Read of trip-plan.md without offset | denied, reason names Grep and spec_section.py | unit |
| 3 | Read with offset; Read of a 2 KB file; Read of a missing path; bad JSON on stdin; a .png over 40 KB | allowed | unit |
| 4 | `NOVA_READ_GUARD_KB=0` | allowed | unit |
| 5 | Static gates and full gates after items 1–4 | green | gate |
| 6 | Fresh session on the environment | swift 6.1.2 on PATH, three packages built | device (fresh container) |
| 7 | T-900f pass on today's files | frontier.py valid, gates green, every archived id once, hot files under the limits | unit + gate |

## 5. Setup script (T-900e, stored on the environment)

See the environment settings; same text as handed to the owner on 2026-11-19 (download
swift-6.1.2-RELEASE-ubuntu24.04.tar.gz from download.swift.org, `/etc/profile.d/swift.sh`, three package builds,
`exit 0`). No keys in it.
