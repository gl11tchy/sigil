# Sigil UX baseline (before the native coding workbench)

This records how the app behaved at commit `2885af2` ("list only chats started in Sigil", #127). It is evidence only: no recommendations. Every screenshot comes from the real app, running in an isolated copy with fake CLIs. Journeys count concrete user actions. No timings were measured.

## Environment

| | |
|---|---|
| macOS | 26.5.1 (25F80). Built-in display 1512×982 pt @2x; visible frame 1512×949. |
| App | Debug build of `2885af2` from a clean worktree (`Scripts/build-app.sh`, ad hoc signing), renamed `SigilBase` / `com.gl11tchy.sigil.base`. |
| Harness-only patch | `ux-harness.patch` makes two changes. (1) `SIGIL_UX_HARNESS=1` keeps the remote pairing and Kimi key stores in memory, never the Keychain; nothing else changes. (2) The Sidereal relay binds to `HOST`, set to 127.0.0.1. Why (1) is needed: at 2885af2, `XCTestConfigurationFilePath` also disables provider checks. The New Session sheet then shows "Checking Grok Build… Try again shortly." forever and saved tabs never restore. |
| Isolation | `HOME`, `CFFIXED_USER_HOME`, `GROK_HOME`, `TMPDIR` and `XDG_*` point to `/Users/Shared/sigil-ux/baseline/home`. `SIGIL_BRIDGE_SOCKET` is in that home. `open` is launched from an empty environment with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. |
| Fake CLIs | `grok` (Grok Build) and `claude` (Claude Code). Codex, Devin, Cursor and Kimi Code are not installed. |
| Projects | Git repos `acme-api`, `acme-web` and `infra` under `/Users/Shared/sigil-ux/baseline/projects`. Each has 2 commits plus uncommitted changes. |
| History | 8 seeded Grok chats. 7 are in Sigil's own list: `session.sigilConversations` is written with `defaults` and `session.sigilConversationsSeeded` is set to true. "Show chats from other apps" stays **off**, so the 8th chat is hidden, as intended. |
| Phone | The Sidereal web companion from the same revision. It ran on a local relay (`http://localhost:3099`) in headless Chromium at 390×844 @2x, paired through Settings › Remote › Connect Phone › Copy Pairing Link. The native iOS app was not run. |
| Input | No keystrokes were sent on the Mac; everything used AX presses and menu clicks. Prompts were typed on the phone page (`input`, then `key` Enter). This reaches the same terminal-input path (`onUserSubmit`) as typing on the Mac. |

The harness is in `/Users/Shared/sigil-ux/baseline/harness/`. Its `README.md` has the full recipe and a table of the scripts. The fake CLI and the seeding code are copied at the end of this file.

## Screenshot matrix

- **Narrow** is 900×620 pt, near the minimum width. The minimum is 760 pt without the right panel and 882 pt with it (`WindowColumns.minimumWidth`).
- **Wide** is 1512×949 pt: the full visible screen. The requested 1680×1020 could not be captured, because this Mac's display is 1512×982 pt and macOS limits a window to the visible frame (AX `set size` returned 1512×949).
- All images are @2x.

| State | Narrow dark | Narrow light | Wide dark | Wide light |
|---|---|---|---|---|
| 1 Empty (no tabs) | [img](empty-narrow-dark.png) | [img](empty-narrow-light.png) | [img](empty-wide-dark.png) | [img](empty-wide-light.png) |
| 2 One task (Grok tab, one finished turn) | [img](one-task-narrow-dark.png) | [img](one-task-narrow-light.png) | [img](one-task-wide-dark.png) | [img](one-task-wide-light.png) |
| 3 Busy, 5 tabs in 3 projects | [img](busy-narrow-dark.png) | [img](busy-narrow-light.png) | [img](busy-wide-dark.png) | [img](busy-wide-light.png) |
| 4 Unavailable provider (New Session › Codex) | [img](unavailable-narrow-dark.png) | [img](unavailable-narrow-light.png) | [img](unavailable-wide-dark.png) | [img](unavailable-wide-light.png) |
| 5 Error (tab exited with code 1) | [img](error-narrow-dark.png) | [img](error-narrow-light.png) | [img](error-wide-dark.png) | [img](error-wide-light.png) |

**Busy** tab states, left to right in the strip:

| Tab | Project | State |
|---|---|---|
| Add rate limiting | acme-api | Working |
| Fix flaky token refresh test | acme-api | Finished in the background (unread) |
| Dark mode toggle | acme-web | Idle, selected |
| Checkout button | acme-web | Restored, never prompted: "Status unknown" |
| Split staging VPC | infra | Failed with exit code 1 |

**Phone** (web companion):

| View | Dark | Light |
|---|---|---|
| One task | [img](phone-one-task-dark.png) | [img](phone-one-task-light.png) |
| Chats list, busy | [img](phone-busy-chats-dark.png) | [img](phone-busy-chats-light.png) |
| Failed tab | [img](phone-error-dark.png) | [img](phone-error-light.png) |
| Tab before its first prompt | [img](phone-status-unknown-dark.png) | — |
| New session dialog | [img](phone-new-session-dark.png) | — |
| Mac: Settings › Remote after pairing | [img](phone-mac-remote-connected-dark.png) | — |

**Journey evidence:**
- [journey1-sheet-dark](journey1-sheet-dark.png)
- [journey1-working-dark](journey1-working-dark.png)
- [journey2-project-drill-in-dark](journey2-project-drill-in-dark.png)
- [journey2-switched-dark](journey2-switched-dark.png)
- [journey3-tab-list-dark](journey3-tab-list-dark.png)
- [journey3-recents-light](journey3-recents-light.png)
- [journey4-panel-terminal-dark](journey4-panel-terminal-dark.png)
- [journey4-panel-notes-dark](journey4-panel-notes-dark.png)

**Capture notes:**
- The window was never made frontmost, so the owner's focus was not taken. Some images therefore show inactive window chrome (grey traffic lights).
- Theme was set before each launch, never live. Changing the theme in Settings restarts idle Grok tabs, which would have reset the states shown.

## Journeys

Each numbered step below is one user action.

### 1. Start: choose a project and start a task in it

**Path A (as run), from Home:**
1. Click the project row `acme-web` under Projects. The sidebar drills into the project.
2. Click `+` ("New Session in acme-web (⌘T)") in the drill bar. The sheet opens with Folder = acme-web, CLI = Grok Build and Work in = New worktree.
3. Click **Start**. A worktree `acme-web/5c20cf9d` is created and the tab opens.
4. Type the task.
5. Press Return.

**5 actions.** The tab shows Working, then Idle ([working](journey1-working-dark.png), [done](one-task-narrow-dark.png)).

**Path B: `⌘T` / "New session" from Home, no project drilled in:**
1. Press ⌘T.
2. Open the **Recent** pop-up. The sheet opened on `acme-api`, the remembered default folder, not the project in view.
3. Choose `acme-web`.
4. Click Start.
5. Type the task.
6. Press Return.

**6 actions.** If the project is not among the 8 Recent folders, **Choose…** opens a folder panel instead (+2 or more).

**Accelerator:** pressing a CLI tile twice starts the session ("Press a CLI twice to start it"), which replaces the Start click.

**Friction observed:**
- The folder the sheet opens on depends on hidden state: the focused project, then the selected tab's folder, then the remembered default. From Home it was `acme-api` although the user may be looking at another project.
- The Folder row and the Recent row show the same path twice ([sheet](journey1-sheet-dark.png)).
- Provider tiles look the same whether the CLI is installed or not.
  - Codex, Devin, Cursor and Kimi Code were all missing here. Only after selecting one does a small grey line appear: "Install Codex or check its executable path." Start then dims ([unavailable](unavailable-narrow-dark.png)).
  - Per code, pressing the unavailable tile again does nothing (not tried).
- "New worktree" is the default for a Git repo.
  - The tab is then titled with a worktree label (`acme-web/5c20cf9d`).
  - The Grok banner shows the percent-encoded worktree path.
  - The branch (`sigil/<name>`) is never shown.
- One task gets three names:

  | Where | Before the first turn | After the first turn |
  |---|---|---|
  | Tab | `acme-web/5c20cf9d` | the prompt text |
  | Sidebar row | "Untitled session in acme-web" | the prompt text |
  | Top bar | `acme-web/5c20cf9d` | `acme-web/5c20cf9d` |
- A started but unprompted tab shows a grey dot on the Mac and "Status unknown" on the phone.
- Accessibility: the Start, Cancel and Choose… buttons have no accessible name (AX reports only "button"). The CLI tiles do have identifiers and help text.

### 2. Switch: move between two tasks in different projects

Measured from the failed `infra` tab to "Add rate limiting" in `acme-api`, with 5 tabs open:

| Way | Actions |
|---|---|
| Tab strip chip (wide) | 1 click |
| Tab strip chip (narrow: only 3 of 5 chips fit) | chevron or tab list: 2 or more |
| Home › Open row | 1 click (only while the sidebar shows Home) |
| ⌘1…⌘9 | 1 shortcut; the user must know the tab's position |
| ⇧⌘] / ⇧⌘[ | 1 per tab in between |
| Tab list ⌃⌘T › row | 2 |
| Projects › `acme-api` (drill-in) › chat row, as run | 2 clicks ([drill-in](journey2-project-drill-in-dark.png), [result](journey2-switched-dark.png)); +1 (Back) to see Home again |
| Search ⇧⌘F › type › row | 3 |

**Friction observed:**
- Drilling into a project hides the Home "Open" list.
- The sidebar stays on the drilled project after the selection moves to another project's tab. After switching to an `acme-web` tab, the sidebar still listed `acme-api` ([panel screenshot](journey4-panel-terminal-dark.png)).
- "Home" stays highlighted while the sidebar is drilled into a project.
- Drill-in rows do not say which chats are open tabs. The working chat showed "2h", its last summary time, although it was working at that moment.
- The Projects list re-sorts by recent activity: `acme-web` moved from first to second between two captures ([empty](empty-wide-dark.png), [busy](busy-wide-dark.png)).
- When the selected tab is working, the top bar gains "Working 2m 03s" and every chip in the strip narrows ([switched](journey2-switched-dark.png)).
- At narrow width the selected tab can sit outside the visible strip. The failed tab was selected but not visible ([error narrow](error-narrow-dark.png)).

### 3. Find what needs attention: finished, working, failed

**Wide window, on Home: 0 actions to see the glyphs, but the glyphs are not labelled.**
- Tab strip and Home › Open use:
  - an animated grid for Working;
  - a blue dot for finished-unread;
  - no mark for Idle;
  - a grey dot for "Status unknown";
  - a red dot for failed.
- Per code, a grey dot also means "exited 0".
- Home › Open also colours a failed tab's project name red ([busy](busy-wide-dark.png)).

**To get words: open the tab list (⌃⌘T): 1 action** ([tab list](journey3-tab-list-dark.png)).
- The finished-unread tab reads **"Idle"**, the same as the tab the user has already seen.
- Long paths truncate the status text: "…nown", "…h code 1".

**Narrow window:** 2 of 5 chips are off-strip, including the failed one. The user needs Home › Open (0 actions, if Home is showing) or the tab list (1 action).

**Recents** ([recents](journey3-recents-light.png)):
- Shows the working grid and the unread dot.
- The failed chat has **no** failure mark.
- Titles are cut to about 10 characters ("Fix flaky t…").

**Phone Chats** ([chats](phone-busy-chats-dark.png)):
- Shows Working, Ready, Ready, Status unknown, Failed.
- Unread is not distinguished from Ready.
- No project names.

**Not captured:** the Dock "•" badge and the attention bounce (per code in `AppModel` and `TerminalTab`).

**Friction:**
- Three signals use grey or blue dots with no legend.
- The only text list (the tab list) calls an unread finished turn "Idle".
- Failure is visible in the strip and the Open list, but not in Recents or the drill-in rows.

### 4. Review: see what changed and any checks

**What exists today:**
- The right panel (View › Show Panel, ⌥⌘B, or the top-bar button) with two modes:
  - **Terminal:** a scratch login shell in the selected tab's folder ([terminal](journey4-panel-terminal-dark.png)).
  - **Notes:** a per-chat text pad ([notes](journey4-panel-notes-dark.png)).
- The "…" Session actions menu, which offers only "New Session in Folder…" and "Settings…".
- There is **no** diff view, changed-files list, Git status, branch display, test or CI checks, or PR state anywhere on the Mac or the phone.

**Actions to see what the `acme-web` task changed:**
1. Open the panel.
2. Click into the shell.
3. Type `git status`.
4. Press Return.
5. Type `git diff`.
6. Press Return.

**6 actions**, and the diff is read in a pager in a 280–900 pt panel. Checks mean running the test command by hand or leaving the app for the browser.

**Friction observed:**
- The agent's own edit appears only as a transcript line ("✎ edited CHANGELOG.md"). `git status` in that folder mixes it with changes that were already there (` M src/settings/Theme.tsx`, `?? CHANGELOG.md`), and nothing separates the two.
- Per code, the panel shell starts in the selected tab's folder on first open and then stays there (`RightPanel.swift`). Reviewing a second task means `cd` or Restart Shell.
- The branch of a worktree task (`sigil/<name>`) is never displayed.
- Notes exist for Grok Build chats only. The pad shows the title and a truncated path, with no prompt text.

### 5. Return from the phone

**Pair (once per pairing; in this harness, once per app launch because pairing is kept in memory):**
1. Mac: App menu › Settings… (⌘,).
2. Mac: Click **Remote**.
3. Mac: Click **Connect Phone**. A QR code, **Copy Pairing Link** and an expiry countdown appear (5 min).
4. Phone: Scan the QR code with the camera, or paste the link: +2 (Copy on the Mac, Paste on the phone).
5. Phone: Open the link. The page shows "Connected"; the Mac shows "Connected / Phone connected" ([Mac](phone-mac-remote-connected-dark.png)).

A self-hosted relay adds 2 actions: Server address disclosure, then enter the URL.

**Reach the same task:**
1. Phone: Tap the session title drop-down, or **Chats**.
2. Phone: Choose the task.

**2 actions** after pairing; 7 or more the first time.

**What the phone shows** ([one task](phone-one-task-dark.png), [failed](phone-error-dark.png)):
- A status word (Ready, Working, Status unknown, Failed).
- A plain-text terminal mirror.
- Buttons: Stop / Restart, Chats, Find.
- A message box with attach, keys and send.
- **New** opens "Choose a project" with a CLI drop-down and project rows ([new](phone-new-session-dark.png)).

**Friction observed:**
- Selection is shared. Choosing a tab on the phone moves the Mac's selected tab, and the Mac moves the phone. In the run, the phone header followed the Mac to "Dark mode toggle".
- The unread finished state never reaches the phone. It shows "Ready".
- Right after start or restore, before any prompt, a tab shows "Status unknown" and a red **Stop** although no turn is running ([status unknown](phone-status-unknown-dark.png)).
- The Chats list has no project grouping, and statuses truncate ("Status unkno…").
- The mirror wraps paths mid-word.
- The web "New" dialog has no worktree choice. Per code, the iOS app has one.

**Not captured:** the native iOS app (`iOS/`) was not built or run. Per code it has:
- a Sessions sheet with "Open on <Mac>" and recent chats;
- a coloured terminal mirror with readable and raw modes;
- a composer with Keys, Stop and Send;
- a Restart button on ended sessions;
- push alerts and a Live Activity.

## Concepts and competing hierarchies (from source at 2885af2, checked against the screenshots)

**Concepts and where each appears:**

| Concept | Code | Where it appears |
|---|---|---|
| Project / folder | `SidebarProject`, `AddedProject`; chats grouped by `GrokSession.projectPath` (worktrees fold into their project) | Home › Projects (+ Add Project), drill-in bar (Back, Archive, Pin, +), Archived / search section headers, top-bar path (`projects/acme-web`), New Session Folder + Recent rows, phone "Choose a project" |
| Worktree | `SigilWorktree` (`~/.sigil/worktrees/<encoded>/<8hex>`, branch `sigil/<name>`) | Sheet "Work in: New worktree / Project folder"; Settings "Start in a new worktree" (default on); `project/<8hex>` labels on the tab title, top bar and phone title; the encoded path in the CLI banner. The branch is never shown. |
| Tab | `TerminalTab` | Tab strip chip, tab list (⌃⌘T), Home › Open row, Window › Tab 1–9, phone title drop-down |
| Chat / conversation / session | `GrokSession`, `ProviderSessionReference` | Sidebar rows (Recents buckets, drill-in, Archived, search). Named "chat" (Search chats, "N chats"), "conversation" (Find Conversations, Rename / Delete Conversation), "session" (New Session, Restart Session, "No open session", "Untitled session") and "tab" (Close Tab). |
| Process | none in the UI; shown through `activity` / `.exited(code:)` | Exited capsule ("Session ended with code 1 · Failed · Close Tab · Restart"), red dot, phone "Failed / Restart" |
| Provider | `CLIProvider` (6) | Sheet tiles, Settings "Default CLI", "Provider · folder" titles for non-Grok tabs, phone CLI drop-down |
| Notes | `ConversationNotesStore` | Right panel › Notes only |
| Pins / archive | `pinnedConversations`, `pinnedProjects`, `archivedConversations` | Hover and context actions, "Pinned" sections, the Archived nav item (only when count > 0) |
| Scratch shell | `RightPanel` Terminal mode | Right panel only; not tied to a task |

**Competing ways to reach "a task"** (the same open chat can show in four places at once: strip chip, tab-list row, Home › Open row, sidebar chat row):
1. Tab strip chip.
2. Tab list popover (⌃⌘T; the button exists only with more than one tab).
3. ⌘1–9 and ⇧⌘] / ⇧⌘[ (Window menu).
4. Home › Open (a live list of tabs).
5. Home › Projects › project drill-in › chat row. This reuses the open tab if there is one; otherwise it opens a new tab.
6. Recents (Today / Yesterday / Previous 7 days / 30 days / month).
7. Archived (grouped by project).
8. Sidebar search (⇧⌘F; covers archived too).
9. Phone: title drop-down and the Chats dialog (Open + saved chats). Selection is shared with the Mac.

**Context-dependent controls:**
- The sidebar row "×" means Close Tab when the chat is open, and Delete Conversation otherwise.
- The context menu says "Show Tab" or "Open in New Tab".
- Tab-strip close buttons expose the folder path as their help text, not "Close Tab".

**Status vocabulary differs by surface:**

| Mac glyph | Tab list | Phone |
|---|---|---|
| none | Idle | Ready |
| grey dot | Status unknown (truncated to "…nown") | Status unknown |
| red dot | Exited with code N | Failed |

## Not captured, with reasons

- **Wide 1680×1020:** the display is 1512×982 pt. The wide column is 1512×949, the most macOS allows.
- **Native iOS app:** not built or run. The phone column is the Sidereal web companion from the same revision.
- **Dock badge and attention bounce:** the Dock is shared with the owner's apps and would expose them. Documented from code instead.
- **Hover tooltips:** no pointer events were sent (AX only), so tooltip text comes from the AX help strings.
- **Typing on the Mac:** keystrokes were forbidden. Mac-side typing is counted in the journeys; the text was entered from the phone page instead.
- **Journeys 2–4 in light:** captured in dark only, except the Recents image.
- **Active-window chrome:** the window was not brought to front on purpose.

## Incidents during capture (disclosed)

**1. The owner's real CLIs were run with `--version`.**
- One launch inherited the calling shell's `PATH` through `open`.
- Sigil's provider check therefore ran the owner's real `codex`, `cursor-agent`, `kimi`, `devin` and `claude` with `--version`, under the fake home. When the Codex tile was selected, `codex debug models` may also have run.
- No session was started and no model was called.
- Afterwards:
  - No installed CLI binary was modified (checked by modification time).
  - `cursor-agent` left an empty `.running` folder in its own version folder (`~/.local/share/cursor-agent/versions/2026.09.28-64d2043/`).
  - The fake home was wiped.
- `launch.sh` now starts `open` from an empty environment and kills any copy whose `PATH` reaches the user's folders.

**2. The shell prompt showed the Mac's user and host name.**
- The first right-panel capture showed them in the prompt. That file was replaced before this report was written.
- The harness now sets a neutral `PS1`.

## Harness source (verbatim)

<details><summary><code>fake-cli/fake_grok.py</code> (installed as a copy at <code>$GROK_HOME/bin/grok</code>)</summary>

```python
#!/usr/bin/env python3
"""Fake `grok` CLI for Sigil UX captures. No network, no model calls.

Installed as a COPY at $GROK_HOME/bin/grok (never a symlink to a real CLI).

Behaviour
- `--version`, `models`, `mcp ...`: answer like the real CLI and exit 0.
- Otherwise it is a tiny line-mode TUI. It prints a banner, replays
  `fake-transcript.txt` from the session folder when resuming, then reads
  prompts. Each prompt writes the Grok ACP journal records Sigil watches in
  `<session>/updates.jsonl`: `agent_thought_chunk` (tab goes Working), then
  after a delay `turn_completed` with stop_reason `end_turn` (tab goes Idle).
- Control files in $GROK_HOME/fake/ (per session id, or global):
    <sid>.delay / delay   seconds to "think" (default 4)
    <sid>.fail            print an error at start and exit 1
    <sid>.edit            relative file path to append a line to on each turn
                          (only inside /Users/Shared/sigil-ux/, for review demos)
"""
import datetime
import json
import os
import sys
import time
import urllib.parse
import uuid

SAFE_ROOT = "/Users/Shared/sigil-ux/"
args = sys.argv[1:]
GROK_HOME = os.environ.get("GROK_HOME") or os.path.expanduser("~/.grok")
FAKE = os.path.join(GROK_HOME, "fake")

if args[:1] == ["--version"]:
    print("grok 1.0.40 (sigil-ux fake)")
    sys.exit(0)
if args[:1] == ["models"]:
    print("grok-4.7 (default)\ngrok-4.7-build-fast\ngrok-4.6")
    sys.exit(0)
if args[:1] == ["mcp"]:
    if args[1:2] == ["list"]:
        print("No MCP servers configured.")
    else:
        print("ok")
    sys.exit(0)


def opt(name):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return None


cwd = os.path.realpath(opt("--cwd") or os.getcwd())
resume = opt("--resume")
sid = (resume or opt("--session-id") or str(uuid.uuid4())).lower()
model = opt("--model") or "grok-4.7"
effort = opt("--reasoning-effort") or "default"
sdir = os.path.join(GROK_HOME, "sessions", urllib.parse.quote(cwd, safe=""), sid)
os.makedirs(sdir, exist_ok=True)
summary_path = os.path.join(sdir, "summary.json")
journal_path = os.path.join(sdir, "updates.jsonl")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def control(name, default=None):
    for path in (os.path.join(FAKE, f"{sid}.{name}"), os.path.join(FAKE, name)):
        if os.path.exists(path):
            with open(path) as f:
                return f.read().strip() or "1"
    return default


def load_summary():
    try:
        with open(summary_path) as f:
            return json.load(f)
    except Exception:
        return {"info": {"id": sid, "cwd": cwd}, "session_summary": "", "created_at": now_iso(),
                "updated_at": now_iso(), "num_chat_messages": 0, "current_model_id": model}


def save_summary(data):
    tmp = summary_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, summary_path)


def journal(update, prompt_id=None):
    meta = {"eventId": str(uuid.uuid4()), "agentTimestampMs": int(time.time() * 1000)}
    if prompt_id:
        meta["promptId"] = prompt_id
    record = {"jsonrpc": "2.0", "method": "session/update",
              "params": {"sessionId": sid, "update": update, "_meta": meta},
              "timestamp": now_iso()}
    with open(journal_path, "a") as f:
        f.write(json.dumps(record) + "\n")


DIM, BOLD, ACC, OK, ERR, RST = "\033[2m", "\033[1m", "\033[36m", "\033[32m", "\033[31m", "\033[0m"
w = sys.stdout.write


def banner():
    w(f"{ACC}{BOLD}  ▟█▙  Grok Build{RST} {DIM}1.0.40 · fake CLI for UX capture{RST}\n")
    w(f"{DIM}  model {model} · effort {effort}{RST}\n")
    w(f"{DIM}  {cwd}{RST}\n")
    w(f"{DIM}  session {sid}{RST}\n\n")


summary = load_summary()
if not os.path.exists(summary_path):
    save_summary(summary)
banner()

if control("fail"):
    w(f"{ERR}error:{RST} could not reach the model service (injected failure for UX capture)\n")
    sys.stdout.flush()
    time.sleep(1.5)
    sys.exit(1)

transcript = os.path.join(sdir, "fake-transcript.txt")
if resume and os.path.exists(transcript):
    with open(transcript) as f:
        w(f.read())
    w("\n")

turns = 0
while True:
    w(f"{ACC}›{RST} ")
    sys.stdout.flush()
    try:
        line = sys.stdin.readline()
    except KeyboardInterrupt:
        w("\n")
        continue
    if not line:
        sys.exit(0)
    text = line.strip()
    if not text:
        continue
    if text in ("/exit", "/quit"):
        sys.exit(0)
    turns += 1
    prompt_id = str(uuid.uuid4())
    journal({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Thinking"}}, prompt_id)
    delay = float(control("delay", "4"))
    frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    started = time.time()
    stop_reason = "end_turn"
    try:
        i = 0
        while time.time() - started < delay:
            w(f"\r{ACC}{frames[i % len(frames)]}{RST} Thinking… {DIM}{int(time.time() - started)}s{RST}   ")
            sys.stdout.flush()
            i += 1
            time.sleep(0.25)
    except KeyboardInterrupt:
        stop_reason = "cancelled"
    w("\r\033[K")
    edit = control("edit")
    if stop_reason == "end_turn" and edit and os.path.realpath(cwd).startswith(SAFE_ROOT):
        target = os.path.join(cwd, edit)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "a") as f:
            f.write(f"- {text} (turn {turns}, fake agent)\n")
        w(f"{DIM}  ✎ edited {edit}{RST}\n")
    if stop_reason == "end_turn":
        w(f"{BOLD}●{RST} Done. I looked at the request “{text[:60]}” and made the change.\n")
        w(f"{DIM}  (fake response · no model was called){RST}\n\n")
    else:
        w(f"{DIM}  interrupted{RST}\n\n")
    journal({"sessionUpdate": "turn_completed", "prompt_id": prompt_id, "stop_reason": stop_reason})
    summary = load_summary()
    if not summary.get("session_summary"):
        summary["session_summary"] = text[:80]
    summary["num_chat_messages"] = int(summary.get("num_chat_messages") or 0) + 2
    summary["updated_at"] = now_iso()
    save_summary(summary)
```
</details>

<details><summary><code>fake-cli/fake_agent.py</code> (installed as a copy at <code>$HOME/.local/bin/claude</code>)</summary>

```python
#!/usr/bin/env python3
"""Fake non-Grok provider CLI (installed as a COPY named `claude`).

Answers `--version` so Sigil's install check passes, then runs a tiny
line-mode prompt that echoes a canned reply. No journal: Sigil has no
lifecycle journal for Claude Code tabs, which matches the real app.
"""
import os
import sys
import time

name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
LABEL = {"claude": ("Claude Code", "2.1.283 (Claude Code) [sigil-ux fake]")}.get(
    name, (name, f"{name} 0.0.0 [sigil-ux fake]"))
if args[:1] in (["--version"], ["-v"]):
    print(LABEL[1])
    sys.exit(0)
if args[:1] in (["models"], ["debug"]):
    sys.exit(0)

w = sys.stdout.write
w(f"\033[1m✻ {LABEL[0]}\033[0m \033[2m(fake CLI for UX capture)\033[0m\n")
w(f"\033[2m  cwd: {os.getcwd()}\n  args: {' '.join(args) or '(none)'}\033[0m\n\n")
while True:
    w("> ")
    sys.stdout.flush()
    try:
        line = sys.stdin.readline()
    except KeyboardInterrupt:
        w("\n")
        continue
    if not line:
        sys.exit(0)
    if line.strip():
        time.sleep(1)
        w(f"● (fake) I would work on: {line.strip()[:70]}\n\n")
```
</details>

<details><summary>Seeding (<code>seed-defaults.py</code>, <code>setup-home.py</code>, <code>fixture.json</code>)</summary>

```python
#!/usr/bin/env python3
"""Write the test bundle's preferences before a launch.

Usage: seed-defaults.py <theme> <scenario> [selected-key]
  theme     "Sigil Dark" | "Sigil Light"
  scenario  empty  - no open tabs
            busy   - open tabs A1 A2 W1 W2 I1 (I1 fails at start; see
                     control files written by this script)
  selected  fixture key of the tab selected at launch (default W1)

Ledger: every fixture session with "ledger": true is written to
session.sigilConversations and session.sigilConversationsSeeded is set, so
the sidebar lists them without turning on "show chats from other apps".
Writes to ~/Library/Preferences/$BUNDLE_ID.plist through `defaults` only.
"""
import json
import os
import subprocess
import sys

BASE = os.environ.get("BASE", "/Users/Shared/sigil-ux/baseline")
H = os.environ.get("H", os.path.join(BASE, "home"))
PROJECTS = os.environ.get("PROJECTS", os.path.join(BASE, "projects"))
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.gl11tchy.sigil.base")
RELAY_PORT = os.environ.get("RELAY_PORT", "3099")
if BUNDLE_ID == "com.gl11tchy.sigil":
    sys.exit("refusing to write the real Sigil's preferences")

theme, scenario = sys.argv[1], sys.argv[2]
selected_key = sys.argv[3] if len(sys.argv) > 3 else "W1"
fixture = json.load(open(os.path.join(BASE, "harness", "fixture.json")))
by_key = {s["key"]: s for s in fixture["sessions"]}
cwd = lambda s: os.path.realpath(os.path.join(PROJECTS, s["project"]))


def defaults(*args):
    subprocess.run(["defaults", "write", BUNDLE_ID, *args], check=True)


def data(value):
    return json.dumps(value, separators=(",", ":")).encode().hex()


subprocess.run(["defaults", "delete", BUNDLE_ID], stderr=subprocess.DEVNULL)
defaults("terminal.theme", theme)
defaults("session.sigilConversations", "-data", data([s["id"] for s in fixture["sessions"] if s["ledger"]]))
defaults("session.sigilConversationsSeeded", "-bool", "true")
defaults("session.defaultDirectory", os.path.realpath(os.path.join(PROJECTS, "acme-api")))
defaults("remoteServerURL", f"http://localhost:{RELAY_PORT}")
# SwiftUI would otherwise restore a window frame from an earlier run.
defaults("NSQuitAlwaysKeepsWindows", "-bool", "false")

fake = os.path.join(H, ".grok", "fake")
os.makedirs(fake, exist_ok=True)
for name in os.listdir(fake):
    os.remove(os.path.join(fake, name))

if scenario == "busy":
    keys = ["A1", "A2", "W1", "W2", "I1"]
    tabs = [{"sessionID": by_key[k]["id"], "cwd": cwd(by_key[k]), "model": "", "effort": "",
             "provider": "grokBuild"} for k in keys]
    sel = by_key[selected_key]
    defaults("session.openTabs", "-data", data({"tabs": tabs, "selectedSessionID": sel["id"],
                                                "selectedCWD": cwd(sel), "selectedProvider": "grokBuild"}))
    # Per-session behaviour of the fake CLI.
    open(os.path.join(fake, by_key["I1"]["id"] + ".fail"), "w").write("1")
    open(os.path.join(fake, by_key["A1"]["id"] + ".delay"), "w").write("86400")  # stays Working
    open(os.path.join(fake, by_key["A2"]["id"] + ".delay"), "w").write("25")     # finishes unseen
    open(os.path.join(fake, by_key["W1"]["id"] + ".delay"), "w").write("3")      # finishes while selected
    open(os.path.join(fake, by_key["W1"]["id"] + ".edit"), "w").write("CHANGELOG.md")
elif scenario != "empty":
    sys.exit(f"unknown scenario {scenario}")
print(f"seeded {BUNDLE_ID}: theme={theme} scenario={scenario}")
```

```python
#!/usr/bin/env python3
"""Rebuild the isolated home, fixture Git repositories, fake CLIs and seeded
Grok history for Sigil UX captures. Everything lives under $BASE
(default /Users/Shared/sigil-ux/baseline); nothing outside it is touched.

Usage: setup-home.py            # wipe and rebuild home/ and projects/
Prints the ids it seeded. Reads harness/fixture.json.
"""
import datetime
import json
import os
import shutil
import subprocess
import sys
import urllib.parse

BASE = os.environ.get("BASE", "/Users/Shared/sigil-ux/baseline")
HARNESS = os.path.join(BASE, "harness")
H = os.environ.get("H", os.path.join(BASE, "home"))
PROJECTS = os.environ.get("PROJECTS", os.path.join(BASE, "projects"))
GROK_HOME = os.path.join(H, ".grok")

for path in (H, PROJECTS):
    if not os.path.realpath(path).startswith("/Users/Shared/sigil-ux/"):
        sys.exit(f"refusing to touch {path}")

fixture = json.load(open(os.path.join(HARNESS, "fixture.json")))
shutil.rmtree(H, ignore_errors=True)
shutil.rmtree(PROJECTS, ignore_errors=True)
for d in ("tmp", "cache", "config", ".grok/bin", ".grok/sessions", ".grok/fake", ".local/bin",
          "Library/Application Support"):
    os.makedirs(os.path.join(H, d), exist_ok=True)
# Empty shell startup files: the owner's real ones are never read (HOME is here).
for rc in (".zprofile", ".zshenv"):
    open(os.path.join(H, rc), "w").close()
with open(os.path.join(H, ".zshrc"), "w") as f:
    f.write("# Harness: only system folders and this fake home. Never the owner's CLI folders.\n"
            'export PATH="$HOME/.local/bin:$HOME/.grok/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"\n'
            "# Neutral prompt so screenshots never show the Mac's user or host name.\n"
            "PS1='%1~ %# '\n")

# Fake CLIs are COPIES with a pinned interpreter. Never symlink a real CLI here.
python = shutil.which("python3") or "/usr/bin/python3"


def install(src, dest):
    body = open(os.path.join(HARNESS, "fake-cli", src)).read().split("\n", 1)[1]
    with open(dest, "w") as f:
        f.write(f"#!{python}\n" + body)
    os.chmod(dest, 0o755)


install("fake_grok.py", os.path.join(GROK_HOME, "bin", "grok"))
install("fake_agent.py", os.path.join(H, ".local", "bin", "claude"))
# Codex, Devin, Cursor and Kimi stay uninstalled: the unavailable-provider state.

git_env = dict(os.environ, HOME=H, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
               GIT_AUTHOR_NAME="gl11tchy", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="gl11tchy", GIT_COMMITTER_EMAIL="fixture@example.invalid")


def git(repo, *args):
    subprocess.run(["git", "-C", repo, "-c", "core.hooksPath=/dev/null", *args], check=True,
                   env=git_env, stdout=subprocess.DEVNULL)


def write_files(repo, files):
    for rel, text in files.items():
        p = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)


for name, spec in fixture["projects"].items():
    repo = os.path.join(PROJECTS, name)
    os.makedirs(repo)
    git(repo, "init", "-q", "-b", "main")
    write_files(repo, spec["files"])
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "Initial commit")
    write_files(repo, spec["second_commit"])
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "Add second module")
    write_files(repo, spec["dirty"])  # uncommitted changes stay in the tree

now = datetime.datetime.now(datetime.timezone.utc)
for s in fixture["sessions"]:
    cwd = os.path.realpath(os.path.join(PROJECTS, s["project"]))
    sdir = os.path.join(GROK_HOME, "sessions", urllib.parse.quote(cwd, safe=""), s["id"])
    os.makedirs(sdir)
    updated = now - datetime.timedelta(minutes=s["age_min"])
    created = updated - datetime.timedelta(minutes=25)
    iso = lambda t: t.isoformat().replace("+00:00", "Z")
    json.dump({"info": {"id": s["id"], "cwd": cwd}, "session_summary": s["summary"],
               "created_at": iso(created), "updated_at": iso(updated),
               "num_chat_messages": s["messages"], "num_messages": s["messages"] * 2,
               "current_model_id": "grok-4.7"}, open(os.path.join(sdir, "summary.json"), "w"))
    with open(os.path.join(sdir, "fake-transcript.txt"), "w") as f:
        f.write("\n".join(s["transcript"]) + "\n")
    print(s["key"], s["id"], cwd)
```

```json
{
  "projects": {
    "acme-api": {
      "files": {
        "README.md": "# acme-api\n\nOrders and auth service.\n",
        "src/server.ts": "import { orders } from './routes/orders';\n\nexport function start() {\n  return orders;\n}\n",
        "src/routes/orders.ts": "export const orders = [];\n",
        "test/auth.test.ts": "test('refresh', () => {});\n"
      },
      "second_commit": {"src/middleware/auth.ts": "export const auth = () => true;\n"},
      "dirty": {"src/routes/orders.ts": "export const orders = [];\nexport const limit = 100; // WIP rate limit\n", "notes.txt": "untracked scratch file\n"}
    },
    "acme-web": {
      "files": {
        "README.md": "# acme-web\n\nStorefront.\n",
        "src/App.tsx": "export default function App() { return null; }\n",
        "src/checkout/Button.tsx": "export const Button = () => null;\n"
      },
      "second_commit": {"src/settings/Theme.tsx": "export const Theme = 'light';\n"},
      "dirty": {"src/settings/Theme.tsx": "export const Theme = 'dark';\n"}
    },
    "infra": {
      "files": {
        "README.md": "# infra\n\nTerraform and CI.\n",
        "terraform/staging/main.tf": "module \"vpc\" {}\n",
        "ci/runners.yml": "image: runner-2026-08\n"
      },
      "second_commit": {"terraform/prod/main.tf": "module \"vpc\" {}\n"},
      "dirty": {"ci/runners.yml": "image: runner-2026-09\n"}
    }
  },
  "sessions": [
    {"key": "A1", "id": "a1000000-0000-4000-8000-000000000001", "project": "acme-api", "summary": "Add rate limiting to /v1/orders", "age_min": 120, "messages": 14, "ledger": true,
     "transcript": ["› Add rate limiting to /v1/orders", "● Added a token-bucket limiter in src/middleware/rateLimit.ts and wired it into the orders router.", "  3 files changed · tests pass"]},
    {"key": "A2", "id": "a1000000-0000-4000-8000-000000000002", "project": "acme-api", "summary": "Fix flaky token refresh test", "age_min": 1500, "messages": 22, "ledger": true,
     "transcript": ["› The auth refresh test fails about 1 in 5 runs", "● The test used real timers. Switched to fake timers and pinned the clock.", "  1 file changed"]},
    {"key": "A3", "id": "a1000000-0000-4000-8000-000000000003", "project": "acme-api", "summary": "Upgrade to Node 22", "age_min": 8640, "messages": 8, "ledger": true,
     "transcript": ["› Upgrade the service to Node 22", "● Bumped engines, .nvmrc and the Docker base image."]},
    {"key": "AX", "id": "a1000000-0000-4000-8000-0000000000ff", "project": "acme-api", "summary": "Explore repo (started in a terminal, not in Sigil)", "age_min": 30, "messages": 4, "ledger": false,
     "transcript": ["› what does this repo do?", "● It is the orders and auth API."]},
    {"key": "W1", "id": "b2000000-0000-4000-8000-000000000001", "project": "acme-web", "summary": "Dark mode toggle in Settings", "age_min": 40, "messages": 10, "ledger": true,
     "transcript": ["› Add a dark mode toggle to Settings", "● Added a Theme switch backed by prefers-color-scheme with an override."]},
    {"key": "W2", "id": "b2000000-0000-4000-8000-000000000002", "project": "acme-web", "summary": "Checkout button misaligned on Safari", "age_min": 180, "messages": 6, "ledger": true,
     "transcript": ["› The checkout button is 2px off on Safari", "● Replaced the flex gap fallback with margin on the icon."]},
    {"key": "I1", "id": "c3000000-0000-4000-8000-000000000001", "project": "infra", "summary": "Split staging VPC in Terraform", "age_min": 300, "messages": 18, "ledger": true,
     "transcript": ["› Split the staging VPC into app and data subnets", "● Planned 6 additions. Waiting for your apply."]},
    {"key": "I2", "id": "c3000000-0000-4000-8000-000000000002", "project": "infra", "summary": "Rotate CI runner images", "age_min": 4320, "messages": 12, "ledger": true,
     "transcript": ["› Rotate the CI runner images to the September build", "● Updated ci/runners.yml."]}
  ]
}
```
</details>

<details><summary><code>ux-harness.patch</code> (applied to the isolated build only)</summary>

```diff
diff --git a/Sidereal/server.mjs b/Sidereal/server.mjs
index e431cae..f6dd1c8 100644
--- a/Sidereal/server.mjs
+++ b/Sidereal/server.mjs
@@ -403,7 +403,7 @@ if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
       topic: process.env.APNS_TOPIC,
     }),
   });
-  relay.server.listen(Number(process.env.PORT || 3000), '0.0.0.0');
+  relay.server.listen(Number(process.env.PORT || 3000), process.env.HOST || '0.0.0.0');
   process.on('SIGTERM', () => relay.close());
   process.on('SIGINT', () => relay.close());
 }
diff --git a/Sources/SigilApp/AppModel.swift b/Sources/SigilApp/AppModel.swift
index 8e55bce..2c259a7 100644
--- a/Sources/SigilApp/AppModel.swift
+++ b/Sources/SigilApp/AppModel.swift
@@ -145,7 +145,7 @@ final class AppModel {
             }
         if let pairingStore {
             self.remoteControl = RemoteControl(store: pairingStore)
-        } else if Self.isRunningAutomatedTests {
+        } else if Self.isRunningAutomatedTests || Self.isUXHarness {
             self.remoteControl = RemoteControl(store: InMemoryRemotePairingStore())
         } else {
             self.remoteControl = RemoteControl(
@@ -158,7 +158,8 @@ final class AppModel {
         self.tabMessagingSocketURL = tabMessagingSocketURL ?? BridgePaths.configuredSocket
         self.resolveCanonicalPath = canonicalPath ?? { GrokPaths.canonicalPath($0) }
         self.kimiKeyStore =
-            kimiKeyStore ?? (Self.isRunningAutomatedTests ? InMemoryKimiKeyStore() : KeychainKimiKeyStore())
+            kimiKeyStore
+            ?? (Self.isRunningAutomatedTests || Self.isUXHarness ? InMemoryKimiKeyStore() : KeychainKimiKeyStore())
         hasKimiAPIKey = self.kimiKeyStore.load() != nil
     }
 
@@ -3103,6 +3104,12 @@ final class AppModel {
             || ProcessInfo.processInfo.arguments.contains("--smoke-test")
     }
 
+    /// UX capture harness only: keep pairing and Kimi keys in memory (never the
+    /// Keychain) while everything else runs exactly as in production.
+    private static var isUXHarness: Bool {
+        ProcessInfo.processInfo.environment["SIGIL_UX_HARNESS"] == "1"
+    }
+
     /// Swift Testing does not set XCTestConfigurationFilePath.
     private static var isRunningAutomatedTests: Bool {
         let info = ProcessInfo.processInfo
```
</details>
