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
or a working-directory/time match into a conversation ID. Automatic binding of a
new Codex tab requires a captured kernel PID/birth identity for its own direct
child, a stable descendant tree, and exactly one held JSONL file below the
store's captured Codex history root. That file must be writable, created since
the child started, and match the discovered rollout's exact canonical path,
device and inode. A fresh supported session envelope must agree on its native ID
and project path. Kernel identity/file snapshots must agree before and after
validation; npm-style shims may supply evidence through their descendants.

Missing, denied, partial or changing evidence leaves the tab without identity.
Multiple held rollouts remain ambiguous, including unreadable or unsupported
ones; file recency and tab order never choose one. Reused PIDs, reparented
descendants and closed/replaced tabs cannot inherit an earlier observation.
Automatic live bindings are rechecked on scans: `/new` ambiguity removes the
live reference and saved-open entry, while keeping the earlier history and names.

An unbound Codex tab offers **Link Conversation…** in Session actions. Each
same-folder history choice explicitly asks to link that tab to the named native
conversation. The click revalidates its envelope and still-open target; a
conversation already bound to another tab or duplicated in history is excluded.
Until process proof or an explicit user link succeeds, the existing unknown-ID
Restart message remains and the tab is not saved for restoration. Opening a
known conversation from history still resumes it normally. Linking does not
start another process or certify turn completion (REA-1218). The original
transcript remains owned by Codex.

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
  or authentication will remain usable at launch. Version-check timeouts are
  separate from missing/invalid installations. One shared timer retries only
  timeouts, with delays of 5, 15 and 45 seconds between attempts; the next app
  activation can advance one of those attempts without replenishing the budget.
  Pending recovery says the CLI is still being checked. After three retries,
  it says **Version check timed out** and offers **Check Again**. Explicit
  checks reset only their requested provider's recovery; routine inventory,
  entry and remote Options preserve exhausted budgets. Activation recovery uses
  the app-wide delegate's model hook, including when only Settings remains open.
  Timeout cleanup freezes and terminates a bounded owned descendant tree,
  including separate child groups, before confirming the direct probe's exit.
  Parent/birth identities fence signals. Incomplete cleanup is unavailable and
  receives no automatic retry; deliberately detached/reparented daemons are not
  inferred from the process inventory. Explicit refresh and Grok configuration
  changes fence canceled timers and old probe
  results. Saved restoration keeps the ready prefix in order and retains
  deferred positions/selection, including recovery after exhaustion. A saved
  position transfers when a live peer is restarted or replaced. Settings lists
  all six providers and its single **Check Again** explicitly refreshes their
  shared inventory, including exhausted timeout budgets.
- `CLIProvider.checkedVersion` records these checked contracts. When an available
  CLI reports a newer semantic version, the selected provider in New Session
  names both versions in its compatibility notice. In the sidebar, compatible
  newer versions share one default-collapsed **Compatibility** footer control
  (⌘⇧I), regardless of provider count. Its native popover lists each provider's
  installed and checked versions and says history and turn state are best effort;
  Done or Escape dismisses it and returns focus to the control. The footer takes
  34 points, leaving navigation and the top of the history viewport stable.
  An unsupported Codex or Claude major retains a visible history-format warning
  and Settings action in the history list. Incomplete/unsupported-file notices
  retain their own Settings action; actual read failures retain the existing
  failure state and Retry. Unknown version output makes no version claim, and
  unavailable or failed probes cannot become benign compatibility details.
  A version notice does not prevent starting the installed CLI. This presentation
  change (REA-1351) does not change the checked baselines, parser, lifecycle or
  tab-binding identity rules.

## Provider availability in New Session and Settings

Both the inline one-click surface and the Options sheet show every provider's
availability before selection. Unknown/stale successes say **Check required**;
pending probes and bounded timeout recovery say **Checking…**. A confirmed
login-shell lookup failure says **Not installed**, a failed `--version` says
**Check failed**, and an exhausted timeout says **Check timed out**. Unclassified
errors and unavailable custom paths retain their full problem and **Unavailable**
status. A found path remains visible when its version command fails. No status
claims that a CLI account is authenticated: **Needs sign-in** is used only for
Kimi's configured API-key mode when Sigil has no key. Other sign-ins belong to
the CLI. The probe never starts a model call.

Unavailable tiles remain inspectable; their status is an accessibility value,
and help/accessibility hints explain the problem. A ready inline tile still
starts in one click. Settings lists all six paths, reported version strings (or
**Version not reported**) and current problems. Existing installed-versus-checked
history notices remain separate from launch availability: an unsupported Codex
history major can still be an installed, launchable CLI.

Without a valid stored default, the first completed six-provider inventory picks
the first available CLI in tile order. This automatic choice is not persisted as
a user preference. An explicit stored default always wins, and provider interaction or editing an
Options override freezes initial selection before pending results can change it.
A later refresh cannot reorder an already established initial choice. With no
available CLI, the provisional choice remains unavailable rather than implying
Grok is installed.

## Grok executable selection

Installed Grok is the default. Its bounded availability check discovers `grok`
through the user's login shell, with standard install directories appended after
the shell's PATH. The ordinary Grok installer directory is a fallback; the
separately pinned `grok-sigil` build never becomes an automatic default. New,
resume, restart and restoration launch the checked absolute path. Model lookup,
transcript export and tab-message registration use that same selection.

Settings shows Installed Grok or Custom executable, the checked path/version or
current problem. The CLIs section's **Check Again** refreshes Grok and the other
five providers. **Choose…** makes a custom or themed
path an explicit choice. That choice survives relaunch, including a missing file,
and does not silently fall back. **Use Installed Grok** clears the override and
rechecks discovery. Known old installer/themed paths without an explicit-choice
marker migrate to installed discovery; marked choices and other legacy custom
paths remain custom. Selection changes invalidate the cached result and pending
generation immediately, including switching back to automatic mode. Existing
terminals keep running until restarted.

Grok selection (REA-1329) uses the shared bounded timeout recovery above
(REA-1250). The full six-provider Settings inventory remains separate (REA-1261).

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
it. Codex 0.0.x, Codex 1.x, malformed metadata and unsupported envelopes produce a
visible compatibility notice without inventing conversations. The checked Codex contract stays **0.157.1**; accepting
a synthetic newer-version envelope is not a claim that a newer CLI was fully checked.

Claude cold scans stream the whole JSONL file in 64 KiB chunks. Complete records
up to 512 KiB are parsed, with a carried partial JSON/UTF-8 record; larger records
are discarded through their newline and retain an incomplete-history notice.
The newest explicit `custom-title` wins even in the middle of a long transcript.
An explicit empty title resets to the first prompt. A complete legacy final JSON
object without a newline is projected without committing the unfinished line.

Claude's in-memory cache holds display/identity fields, a scan offset, bounded
partial-record bytes and a SHA-256 fingerprint of every byte through that offset.
Unchanged files are zero-read cache hits. A changed, growing file resumes parsing
at the prior offset only after its inode/device/birth identity matches and a
cancellable 64 KiB-chunk reread of the entire old prefix reproduces the fingerprint.
Only new records are then parsed, but validation deliberately reads old bytes:
this is incremental parsing, not append-only byte I/O. Replacement, truncation,
a changed same-size file, or any old-prefix fingerprint mismatch triggers a cold
scan. Identity/timestamps are checked again before publishing a result; concurrent
writes and read failures preserve saved rows with uncertain coverage. Caller
cancellation reaches the store's detached scanner, and canceled results cannot
publish cache, sessions, notices or coverage. Existing scan ordering and force
epochs remain authoritative. `ignoringCache` always performs a full scan.

Both adapters select possible row-changing records before Foundation JSON decoding.
Markers never supply metadata: selected envelopes still validate normally. Identity,
version and model candidates remain selected after a title is known; escaped keys
or values fall back to full decoding. First-prompt and observed-content candidates
remain selected until found, including Codex event and response-item titles.
Claude's unfinished final record always validates for its incomplete-history notice.
Record limits and all identity/version acceptance rules stay the same.

Codex retains its 512 KiB prefix/128 KiB tail transcript samples and latest 2 MiB
name-index window. A store-scoped in-memory index cache checks the full regular-file
snapshot (path, inode/device/birth identity, size, mtime and ctime); unchanged files
need no content reads or JSON decoding. Growing files resume complete-record parsing
only after every byte of the previously retained window matches its SHA-256
fingerprint. Replacement, truncation, same-size changes or rewrite-with-growth
mismatches rebuild the current window. Moving windows evict earlier names and restore
the transcript's title when an index override disappears. Reads use 64 KiB chunks;
index records must remain below 16 KiB, with bounded partial UTF-8/JSON carry and
legacy complete-EOF projection. A symlink is never followed, and read races or
cancellation cannot replace validated index state. Explicit Retry/recovery rebuilds it.
Changed-index validation deliberately rereads old bytes; this is incremental parsing,
not append-only byte I/O. Watcher behavior remains scoped to the captured history roots.

Reload Conversations (Cmd-R) rereads Grok `summary.json` files but retains unchanged
native transcripts and Codex title-index entries after checking their file identities.
Changed native files still parse normally. Delete uses an immediate cached refresh,
with one refresh for a selection; requests during a forced pass share its queued
cached follow-up, including watcher events. Saved display rows are parsed on Reload
even when their metadata matches, so cache reuse cannot grant source authority.
The sidebar's Retry and View > Rebuild Conversation History (Option-Cmd-R) explicitly
rebuild all provider history and the Codex title index, including unchanged failed
paths whose previous rows were retained. The same `rebuildHistory()` entry point
provides deliberate recovery from stale metadata or filesystem timestamp limitations;
ordinary Reload is not a byte-level integrity proof.

At launch the default store loads `~/Library/Application Support/Sigil/history-index.json`
into the list and title/path search before its first background scan. The versioned
index holds display fields and source identity, including Codex title-index snapshots;
it omits transcript bytes and Claude incremental parser state. An unchanged first
scan reads no summary, transcript or Codex title-index bodies. Changed files are
parsed normally; the first change after a relaunch rebuilds the relevant parser state.
Applied-scan sequencing advances only when an actual scan publishes its result.

The saved index is untrusted display data. Decoding always clears source-validation
authority, even if the file claims otherwise. Metadata cache hits and title overrides
retain that distinction. Opening, saved-tab restoration, export and Trash validate
source envelopes before using their identities. After the first stat-only scan, a
250 ms delayed shared pass parses the remaining saved rows once. Housekeeping and
legacy-note migration resume when that pass publishes source-validated rows. Saved
tabs and actions await the same pass, including an in-flight forced refresh. Failed
unchanged sources remain display-only and do not trigger restoration retry loops;
source changes or manual refresh can recover them. Stop/reload cancel the pending
pass, publication uses scan sequencing, and watcher requests wait behind its source
validation rather than superseding it. Codex tab binding still requires its independent process/file proof,
with the existing exact identity and cwd rules.

The private cache is limited to 8 MiB, 10,000 rows and bounded display fields. Version,
captured-root or decoding failures discard it and a later applied scan rewrites it.
Grok keeps its supported safe folder identifiers; native providers require UUIDs.
Cache/file identity compares paths with only macOS system aliases (/var, /tmp and
/etc) expanded, independent of whether the source still exists. Raw traversal
components and arbitrary symlinks remain rejected by the no-follow checks.
Absolute paths must remain inside the corresponding captured root; existing source
symlink components, index symlinks and aliased index files are rejected. Index reads
validate descriptor/path identity. Debounced writes run off the main actor and use
private temporary files and atomic replacement, with mode 0600 checked before and
after commit. Preparation failures retain the preceding index; no index failure
writes or removes provider history. Multiple app copies may atomically replace this
disposable cache, and each copy revalidates identities. Custom-root stores persist
only when an isolated index location is explicitly injected.

The scanner keeps metadata and display fields, not full transcripts. Oversized or
unsupported records can still require a folder fallback.
Search covers discovered titles and project paths; the Mac sidebar also searches
the first 64 KiB of each eligible conversation note. It does not search every
transcript message, and phone search continues to use titles and paths only.
For a nonempty query, results rank exact title, title prefix, every query term at
a folded Unicode word start, title contains, folder/path, then note-only matches.
Within that rank, one category wins: open conversation, pinned, focused project, then other; newer
activity follows, with provider, native ID and cwd breaking final ties. A stronger
match always beats a weaker boosted match. Search remains global inside a project;
substring highlighting is unchanged. Empty queries keep the published newest-first
list without evaluating titles or boosts. This is the shared search contract for
the [workbench rail search (REA-1256)](https://linear.app/reasonable-glyph/issue/REA-1256/give-the-workbench-rail-a-search-field-before-it-replaces-the-sidebar).
Subagent directories are excluded. Cached entries survive read errors and
unrecognized rewrites. Native transcripts are never rewritten or deleted.

A summary-only, mid-write or unsupported native file protects only its previously
recognized row. A complete scan can still remove a different file's deleted row.
Grok folders with missing or invalid `summary.json` follow the same notice policy
and protect saved metadata for that folder. The sidebar shows a concise accessible
history notice; Settings shows provider counts and any observed unsupported
versions. Format notices do not replace the installed-versus-checked CLI notices.

Actual read or enumeration failures set `loadError` and preserve cached records
within uncertain coverage. The store remembers roots observed during its lifetime,
including empty roots: disappearance then reports a read problem, while a missing
never-used root is normal. An incomplete scan cannot clear a prior format notice.
Only a later complete scan that verifies replacement or absence can clear it.
Known deleted Grok rows can lose their pins, archives, names and colors while a
different unsupported folder keeps its metadata. Native identity metadata retains
its existing conservative policy. Project pins and focus stay while any format
notice or read uncertainty prevents proving a project's absence. Notes are not
pruned by history scans. Seeding records verified chats when the scan has notices
alone and completes its one-time migration only after coverage is complete.
Every applied scan signals housekeeping even if the notice count stays equal.

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
The Mac sidebar's read-only note index keys provider, native session ID and
canonical workspace together. Only exact paths for known sessions are inspected;
conflict copies are excluded. An unambiguous Grok flat note may be indexed without
moving it, while a flat note shared by multiple canonical workspaces is omitted.
Indexing never adopts a legacy note or assigns it to an arbitrary conversation.
Native providers never claim Grok flat notes.

Each background read and unsaved-text projection stops at a **64 KiB UTF-8 byte
prefix**, retaining complete Unicode scalars at the boundary. Terms beyond that
prefix are not searchable. Metadata caching avoids rereading unchanged bodies;
one serial background worker coalesces invalidations and cancels stale scans.
Work is bounded by the captured session set and the prefix cap, with no notes-tree
enumeration. Query changes schedule a cancellable, 50ms-debounced matcher on a separate
background queue; title/path results remain immediate and note matches publish
asynchronously. The main actor reads cached match membership without scanning
note text or reading files.
Explicit editor overlays are available even before the first disk snapshot.
Unsaved editor text overrides disk snapshots. Match publication and local edits
invalidate active search snapshots; idle sidebar snapshots do not observe note
generations. directory events refresh unopened indexed notes,
including replacement and deletion. Workspace alias invalidation re-resolves the
canonical paths off the main actor. The search field's help states the prefix
limit and that note matches appear last. No excerpt UI is included.

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
unsupported-format notices from I/O failures and housekeeping is implemented in
[REA-1264](https://linear.app/reasonable-glyph/issue/REA-1264). Installation captions and the CLIs
Settings list belong to [REA-1261](https://linear.app/reasonable-glyph/issue/REA-1261).
