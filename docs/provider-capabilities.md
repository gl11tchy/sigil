# Provider integration boundaries

Sigil runs the real interactive provider CLI. It does not replace it with an SDK
chat, headless run, or a separate app-server conversation.

## Implemented capabilities

`CLIProvider.capabilities` is the shared host definition. `TerminalTab.capabilities`
removes operations that require a native identity when the current tab has none.
The host sends those contextual capabilities to the phone clients.

| Capability | Grok Build | Claude Code | Codex | Devin / Cursor / Kimi |
|---|---|---|---|---|
| Interactive terminal | Yes | Yes | Yes | Yes |
| Read-only sidebar history and title/path search | Yes | Yes | Yes | No |
| Resume known native conversation | Yes | Yes | Yes | No |
| Native identity chosen before launch | Yes | Yes | No | No |
| Restore a saved, known conversation | Yes | Yes | Yes | No |
| Local names, pins, archive, notes | Yes | Known identity | Known identity | No |
| CLI transcript export | Yes | No | No | No |
| Delete provider history from Sigil | Yes | No | No | No |
| Tab messaging | Yes | No | No | No |
| Observed successful turn completion | Matched journal event | Unavailable | Validated known transcript only | Unavailable |
| Verified structured remote approval | No | No | No | No |

Codex allocates its own native ID. Sigil does not turn a tab UUID, a recent file,
or a working-directory match into a conversation ID. A newly launched Codex tab
cannot be restored or safely restarted until opened from its discovered native
history. The original transcript remains owned by Codex.

A failed resume never falls back to a new conversation. Missing projects,
inaccessible history, unavailable executables, and authentication errors retain
the saved reference. CLI authentication remains in the CLI.

## Installed contracts checked

On 2026-09-27, local read-only checks reported Claude Code **2.1.283**, Codex CLI
**0.157.1**, and Grok **1.0.40**. `--help`, `--version`, and `codex resume --help`
were checked without model calls by `Scripts/verify-provider-contracts.sh`.
This optional local gate requires installed CLIs; ordinary CI does not.

- Claude uses `--session-id UUID` for a new known identity and `--resume ID` for
  the existing conversation. See the [official CLI reference](https://code.claude.com/docs/en/cli-reference).
- Codex uses `resume ID`, or `resume --last` only for an explicitly requested
  continue-latest launch. See [official CLI documentation](https://developers.openai.com/codex/cli/features).
- Installed-version detection runs login-shell executable lookup and `--version`
  on dispatch threads, outside Swift's cooperative executor. It bounds time and
  output. Routine New Session entry reuses successful results for five minutes,
  keyed by provider and executable configuration. Missing, unavailable, expired
  or explicitly refreshed results require a current check; an in-flight
  replacement never permits launch from its old result. Grok path changes
  invalidate immediately. Existing terminals keep running, and saved restoration
  waits for the current batch to retain order. Remote launch actions and Options
  start or join a required check and revalidate after it finishes; cancelling a
  waiter does not cancel another request's check. Availability does not establish
  authentication or model entitlement; a cached result cannot prove an executable
  or authentication will remain usable at launch. Automatic timeout retries and
  the Settings CLI inventory remain separate work (REA-1250 and REA-1261).
- `CLIProvider.checkedVersion` records these checked contracts. When an available
  CLI reports a newer semantic version, the sidebar and selected provider in New
  Session name both versions in a quiet compatibility notice. Compatible versions
  say history and turn state are best effort; an unsupported Codex or Claude major
  says its history format is unsupported. Unknown version output makes no version
  claim. Sidebar notices share the history scroll area so wrapped text preserves
  navigation and the list viewport at small window sizes. A version notice does
  not prevent starting the installed CLI.

## History format boundaries

Claude history is read from `CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`.
Codex history is read from `CODEX_HOME/sessions` or `~/.codex/sessions`.
Its adjacent `session_index.jsonl` supplies validated native display names; each
scan reads at most its latest 2 MiB.
`NativeSessionScanner` is the only native JSONL history parser. It validates
provider version, UUID, absolute project path, and record shape. It accepts the
Claude 2.x shape and well-formed Codex 0.x versions with a minor version of at
least 1, only when `session_meta` validates. Compatible newer minor releases,
including prerelease suffixes and a resumed conversation's newer metadata, are
accepted without a minor-version cap.
Every observed metadata header must keep the same session ID and cwd. The first
accepted header supplies the creation timestamp; resumed headers cannot replace
it. Codex 0.0.x, Codex 1.x, malformed metadata and unsupported envelopes remain a
visible read problem, not invented conversations. The checked Codex contract stays **0.157.1**; accepting
a synthetic newer-version envelope is not a claim that a newer CLI was fully checked.

Each changed file contributes at most a 512 KiB prefix and 128 KiB tail. The
scanner keeps metadata and display fields, not full transcripts. Large history
files may therefore use a folder fallback instead of an inaccessible title.
Search covers discovered titles and project paths, not every transcript message.
Subagent directories are excluded. Cached entries survive read errors and
unrecognized rewrites. Native transcripts are never rewritten or deleted.
Filesystem events refresh native JSONL changes and the adjacent Codex title index.
The Codex watcher excludes unrelated files in its parent directory. Grok still
watches summaries rather than its frequently changing journals. Scanner and watcher
use the same captured roots, including canonical paths for symlinked locations.

## Lifecycle truth

The internal states are starting, working, waiting for approval, confirmed idle,
interrupted, exited, failed, disconnected, and unknown. A live CLI initially has
unknown turn state. User submission means input was sent, not accepted.

After submission, Claude Code, Devin, Cursor, Kimi and new Codex tabs keep an
unknown state, with a neutral last-input tooltip and no Working loader or elapsed
timer. They do not count as working on the Mac or in phone snapshots. A running
CLI still requires confirmation before close or quit. No completion-watch task
runs for these tabs, including Claude history tabs. A known Codex transcript
enables observation only after its session metadata passes the existing scanner's
shape, version and native identity checks. Missing or rejected metadata stays
unknown. Codex writer identity invalidation ends its watch and disables lifecycle
observation; Grok can still observe a journal created after submission.

Neither terminal title symbols nor output silence can complete a turn. The
bounded journal reader checks native session/turn identity and a submission-time
boundary. It rejects duplicate events and old completions. Replacement or
truncation invalidates active turn evidence rather than replaying the file.
Grok uses `params._meta.agentTimestampMs` for precise event time and requires a matching `promptId` / `prompt_id` and `end_turn`; cancellation is
interrupted. Codex requires validated session metadata and matching
`task_started` / `task_complete` turn IDs. Unknown stop reasons stay unknown.
History acceptance alone does not certify events: Codex lifecycle still requires
the owned file's validated session identity, supported `event_msg` types, a valid
post-submission timestamp and matching nonempty native turn IDs. Unknown or
malformed event shapes cannot complete a turn. A new appended metadata header
invalidates the current reader's writer/turn evidence.
These journal formats are version-sensitive, not promised stable provider APIs.
Grok tab-message delivery waits for confirmed idle. An unknown or active tab
keeps queued messages rather than typing them into an uncertain prompt.

Claude and Codex official `Stop` hooks can be blocked by other hooks, causing
further work. Merely observing `Stop` is therefore not proof of final completion.
Sigil does not replace user hooks or launch another conversation for observation.
See [Claude hooks](https://code.claude.com/docs/en/hooks) and
[Codex hooks](https://developers.openai.com/codex/hooks).

A finished alert means the observed provider turn ended. It does not prove that
its requested programming work passed tests or achieved its goal. Failed process
exits and normal process stops are distinct from finished turns.

## Conversation notes

Notes remain plain Markdown in Sigil's existing provider/session/folder paths.
Directory events refresh cached idle notes, including atomic editor saves and
deletion. A local draft stays in memory during the existing 300ms write debounce.
The save compares file identity and bytes, so equal timestamps do not hide edits.
If both versions changed, the latest outside bytes are preserved beside the note
as `<id>.conflict-<milliseconds>-<suffix>.md` before saving the local draft.
Existing conflict files are never overwritten. Outside deletion keeps a dirty
local draft and shows a notice; idle deletion clears the pad.

Failed preservation leaves the canonical file untouched, retains both versions
in memory, and shows an unsaved conflict with Retry. Successfully preserved files
survive relaunch. Unsaved local text remains memory-only if disk writes keep failing.
File coordination serializes other Sigil instances and cooperating editors. A
fresh read after preservation checks independent outside edits; an uncoordinated
writer racing the final check and atomic replacement is not a filesystem transaction.
Synthetic tests prove the recorded cases, not every external editor's save protocol.

## Verification limits

Deterministic fixtures cover format changes, identity mismatch, delayed journals,
partial lines, oversized records, duplicate completion, replacement, truncation,
and real subprocess writes. Version probes never make model calls. These checks
do not prove live authenticated responses, expired-account recovery, or native
provider behavior after every future CLI update.

REA-1214 owns the Codex version rule and the compatibility notice. New-tab identity
binding remains a separate verified-identity requirement in [REA-1216](https://linear.app/reasonable-glyph/issue/REA-1216).
It does not gain evidence from a compatible envelope or a cwd/time match. Separating
unsupported-format notices from I/O failures and housekeeping is [REA-1264](https://linear.app/reasonable-glyph/issue/REA-1264);
the existing read-error behavior remains here. Installation captions and the CLIs
Settings list belong to [REA-1261](https://linear.app/reasonable-glyph/issue/REA-1261).
