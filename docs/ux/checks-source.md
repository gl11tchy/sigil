# Review checks: source decision

Decision for REA-1185 / M3, checked **2026-10-18** against main
`8ca33db146b8e8d899696c5b3e500fadd1c71135`. This specifies a future integration; it implements
no runner, API client, credentials, workflow or UI change.

## Decision and alternatives

**Choose read-only hosted GitHub checks through an existing, explicitly selected GitHub
connection.** Keep Checks **Not connected** until the user enables it for a project, selects the
account/repository and selects the expected check sources. Reading results does not run tests or
request a new CI run. Unsupported hosts remain unavailable in the first integration.

| Option | Benefit | Trust, cost and decision |
| --- | --- | --- |
| Hosted GitHub checks | Existing remote evidence identifies a commit and check issuer; no repository program runs on the Mac. | Requires existing repository access, network and API quota. Workflow authors still control what a reported result means. Chosen for the first integration. |
| Explicit-opt-in local command | Can test an unpushed working tree and support non-GitHub projects. | Executes arbitrary code with local filesystem, environment, network and compute authority. Consent, isolation, cancellation and changed-command handling require a separate runner design. Deferred; no local runner in this integration. |

**A repository file can never make Sigil execute a command without the user's explicit opt-in.**
A `.sigil` file, package script, workflow, hook or cloned repository is data, not execution
authorization. Even a future local runner must show the executable/arguments, directory and
authority before consent, store approval outside repository-controlled files and invalidate it
when the approved command or trust context changes. This decision supplies no such runner. Users
may still run checks themselves in the real terminal; terminal text is not imported as verified
check evidence.

## Read contract and authorization

The official [check-run
API](https://docs.github.com/en/rest/checks/runs#list-check-runs-for-a-git-reference) and
[commit-status
API](https://docs.github.com/en/rest/commits/statuses#get-the-combined-status-for-a-specific-reference),
accessed 2026-10-18, expose different result families. Read both for the full workspace commit
object ID, not a moving branch name. Check runs identify `head_sha`, app and suite; legacy
statuses identify contexts and a combined commit SHA. Private access requires existing
authorization; fine-grained endpoints document Checks/read and Commit statuses/read
respectively. Workflow metadata also needs the documented Actions/read access. No missing scope
is granted automatically; an existing credential's broader rights do not authorize adapter
writes. An empty response is not proof that expected checks passed. The combined status itself
treats an absence of statuses as pending; Sigil instead distinguishes **No check evidence** from
a known scheduled run.

Use a trusted `gh` executable, fixed argument arrays, a neutral working directory and sanitized
environment, never a repository-selected shell, pager or helper. Use explicit approved
host/repository arguments and allowlisted read endpoints. The [CLI API
manual](https://cli.github.com/manual/gh_api), checked on the same date, notes that adding
fields can change the default method to POST: **every proposed request must explicitly use
GET**. No dispatch, rerun/rerequest, write, login, token creation, scope upgrade or
credential-helper execution from repository configuration is permitted. Missing/expired
authorization or insufficient scopes is **Unavailable**, never passing. Show a connection
explanation; do not create credentials or change access to repair it.

The [API version reference](https://docs.github.com/en/rest/about-the-rest-api/api-versions),
accessed 2026-10-18, documents versioned requests. Pin the reviewed `2026-03-10` REST contract
at implementation and reject unsupported/malformed result shapes as unknown. The rolling CLI
manual is a documentation reference, not a tested installed-version compatibility claim.

## Identity and completeness

Before reading, capture the Sigil workspace identity, full Git HEAD object ID, explicitly
confirmed GitHub repository ID/host, account identity, selected-source policy and request
generation, plus a separate working-tree/index/untracked-change generation. A remote URL can
suggest a repository for confirmation; it cannot choose a credential destination, execute SSH or
authorize another host. Use a metadata reader that cannot execute repository-controlled hooks,
filters, fsmonitor or command/config helpers. The existing [workspace
reader](../../Sources/SigilKit/Workbench/WorkspaceChanges.swift) is not certified as that new
security boundary by this document.

Publish only if that identity still matches the selected workspace and current HEAD. Cancel or
discard late responses after HEAD, workspace, repository, account or policy changes. Cache
remote evidence by workspace, full HEAD, confirmed repository/host, account and selected-source
policy. The request generation fences late responses; the separate working-tree generation
guards rendered coverage below. Never key evidence by branch name, tab title, directory/time
similarity or provider conversation. Detached HEAD is valid if the exact commit exists in the
confirmed repository. Unborn HEAD, unpublished/inaccessible commits and ambiguous fork/remote
mappings remain unavailable/unknown. Checks on a PR's synthetic merge SHA, base branch, old HEAD
or equal-content tree are **Other commit / stale**, not exact-HEAD success. Dirty/untracked
working-tree changes are explicitly **Not checked** even when the committed HEAD has passing
checks.

The rendered coverage snapshot must also match the current working-tree change generation.
Before publishing a fetched or cached result, obtain a fresh bounded dirty/index/untracked-state
read through the hardened metadata reader. Reject a coverage snapshot if the generation changes
during that read. A failed, truncated or unstable read means **Working-tree coverage unknown**,
not clean. While Review is visible, working-tree/index change events immediately invalidate the
coverage snapshot and request a new local metadata read, without waiting for the network refresh
interval. Edits, deletions, staging changes and new untracked files must be observed even if
HEAD does not move. A commit's cached remote result may be reused, but its working-tree coverage
label must be revalidated rather than cached by HEAD alone.

GitHub's commit association is not independent proof of the tested checkout. The official
[workflow event
reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request),
checked 2026-10-18, documents a merge commit for `pull_request`'s `GITHUB_SHA`. A PR run's head
metadata alone cannot certify workspace HEAD. Display unproven PR/merge evidence separately; do
not include it in an exact-HEAD pass without a current-attempt tested-revision assertion from
the explicitly trusted source. Missing proof remains unknown, with no log scraping, workflow
changes or new credential creation to manufacture it. Even a trusted assertion remains that
source's report, not independent verification of what its job executed.

Expected sources are user-selected in Sigil-owned settings: check kind/name plus issuer app ID
and, for Actions, workflow identity; legacy contexts also require a confirmed issuer. Do not
infer that every similarly named check is trusted, or claim GitHub branch
protection/mergeability from this summary. A workflow author can report success without
meaningful tests; the badge reports that source's assertion, not independent correctness or
security certification.

Read all needed pages and validate response SHA, issuer, context, suite and attempt identities.
The check-run endpoint documents a limit to the most recent 1,000 suites: use the suite/run read
APIs when needed to prove completeness, or show **Unknown: incomplete evidence**. A truncation,
timeout, missing expected context, conflicting issuer or unprovable newest attempt cannot
produce an aggregate pass. Do not rely on `filter=latest`, timestamps or an old green combined
result alone.

The [check-run rerequest
contract](https://docs.github.com/en/rest/checks/runs#rerequest-a-check-run), checked
2026-10-18, queues the parent suite without updating that check run. Read [suite
status](https://docs.github.com/en/rest/checks/suites#get-a-check-suite) and, for Actions, the
[workflow run](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run)
identity/attempt metadata before choosing the current generation. A newer queued/running or
unfinished rerun suppresses an older pass. If the relationship cannot be proved, report unknown.
[PR checks](https://cli.github.com/manual/gh_pr_checks) is a PR-scoped CLI view with grouped
buckets and a distinct pending exit code; neither its process exit status nor its PR summary
replaces the commit/issuer/attempt validation above.

## Display and attention mapping

Use a separate review-check state. The [attention contract](EXPERIENCE.md#truth-and-attention)
and current [task model](../../Sources/SigilKit/Workbench/WorkbenchModel.swift) derive task
attention from provider/process evidence. **Check results never establish provider completion,
successful requested work or approval authority.** This first integration does not mutate the
task's lifecycle, Finished/unread dot, Needs input, Stopped, Failed or Blocked state, or its
rail attention count. Review failures stay visible as check failures; provider attention retains
its existing meaning and priority.

| Evidence | Checks display | Attention effect |
| --- | --- | --- |
| Fresh exact-HEAD association and tested-revision assertion; every expected trusted source has current complete `success` | Reported passed for HEAD, with commit and read time | No Finished/unread change; no claim about uncommitted changes. |
| Exact HEAD; current queued/in-progress/waiting/requested run, suite or pending status | Pending, naming the current source | No provider Working/Finished inference. |
| Exact HEAD; current failure/error/timed-out check | Failed (checks), red review mark and source reason | Review uses the Failed vocabulary; provider/task Failed is unchanged. |
| Cancelled or action-required check | Cancelled / action required, with words | Review warning only; not provider Stopped or a permission request. |
| Neutral/skipped/stale conclusion, unknown enum or contradictory/malformed record | Unknown / not verified, with exact reason | No pass; no provider attention mutation. |
| Missing expected source, zero results, partial pagination or unresolved attempt | No check evidence / unknown | No vacuous pass and no assumption that a run is scheduled. |
| Cached old HEAD, expired freshness or responses for another commit | Stale / other commit, showing that commit and read time | Cannot overwrite current evidence or supply a current pass. |
| Connection disabled, missing `gh`, missing/expired authorization, denied access or network failure | Not connected / unavailable, with reason | Not passing; does not make an otherwise runnable provider task Blocked. |

Only a complete, fresh exact-HEAD set with current tested-revision assertions and successful
expected sources receives Reported passed. Preserve known failed/pending details if another
source is missing, but label the overall result incomplete rather than passing. A
skipped/neutral conclusion is not silently accepted as success even if a GitHub merge rule would
accept it. Access-denied/not-found responses must not reveal private repository existence or be
converted into No checks. Display remote text as bounded untrusted text. Fetch no logs or
credentials; persist only the needed identities, conclusions and read times, not raw output, and
open only validated HTTPS check-detail links to approved hosts on explicit user action.

## Refresh, cost and failure behavior

After connection opt-in, read on opening Review, selected-workspace/HEAD change and explicit
Refresh. Coalesce requests for the same identity; serialize API reads. While Review is visible,
refresh no more than once per minute; stop background polling when hidden/offline. Treat cached
data older than that interval as stale until revalidated. These are proposed product limits, not
measured performance. Never push, commit, start local tests or dispatch/rerun CI to obtain a
missing result.

The official [REST best
practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api),
checked 2026-10-18, cover pagination, conditional reads and rate-limit backoff. Use conditional
requests where supported, bounded pagination/payloads/timeouts and shared cache/request budgets.
Honor Retry-After and reset headers, back off and expose the next retry time; no busy retry on
authorization failures. The cost is API quota, network and small local parsing/cache work, plus
the existing user's GitHub plan. Reading results must not incur new CI compute, start provider
inference, or change billing/credentials. Existing CI costs remain the repository owner's.

## Delivery boundary and fallback

This is a **GO for a separately implemented read-only hosted-check adapter**, not a working
connection. Keep the current [Not connected
UI](../../Sources/SigilApp/Workbench/ReviewRegion.swift) and the user's terminal as the fallback
until implementation passes generated fixtures for: HEAD/workspace/account races; cached pass
followed by edit/delete/stage/untracked changes with unchanged HEAD; unstable/failed/truncated
working-tree reads; fork and synthetic-merge mismatch; dirty/unborn commits; missing
authorization/404/rate limits; empty/partial evidence; spoofed contexts; pending reruns over old
passes; skipped/unknown conclusions; and unchanged provider attention on every check outcome. No
local runner, live API integration or provider/runtime behavior was implemented or tested for
this record. Required repository PR CI is development evidence, not a checks integration.
