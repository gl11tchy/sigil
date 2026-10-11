# Task history — reviewed 2026-10-11

[REA-1252](https://linear.app/reasonable-glyph/issue/REA-1252/fix-readme-drift-and-move-finished-task-plans-out-of-tasks)
reviewed all 16 task documents against main
[`6127d2d`](https://github.com/gl11tchy-team/sigil/commit/6127d2d64722cbfff21f33b08076f16082f9a963),
merged source, current tests, delivery receipts, and tracked path dependencies.
Eight completed files moved here; eight remain in `tasks/`. A merged PR, an old
date, or a checked box alone did not determine completion. Original bodies and
checkboxes are preserved, with archive notices and reference repairs only.

## Disposition by full bundle

Counts are the original checked / unchecked boxes, not a new completion claim.

| Bundle and files | Boxes | Disposition and evidence |
| --- | --- | --- |
| Persistent pairing: [plan](pairing-persist-plan.md), [spec](pairing-persist-spec.md), [todo](pairing-persist-todo.md) | 4 / 10 | All three archived. [PR #36](https://github.com/gl11tchy-team/sigil/pull/36), merge `bdf83fef`, records Keychain restore, ticket rendezvous, retry, disconnect revocation, non-revoking quit, docs, and the full gate. Current `RemoteControlTests`, `RemoteSessionTests`, relay ticket/room-recreation tests, and `app.test.mjs` ticket persistence cover those contracts. The ten unchecked plan checkpoints remain historical. |
| Application quality: [spec](application-polish-spec.md) | 0 / 0 | Archived. [PR #52](https://github.com/gl11tchy-team/sigil/pull/52), merge `f50c7a16`, and [the retained QA record](../qa/application-quality/README.md) cover every acceptance area: responsive layout, session/output search, files, drafts, Stop/restart, offline errors, focus, raw output, multi-term desktop search, and pairing-link fallback. The [release receipt](https://github.com/gl11tchy-team/sigil/pull/52#issuecomment-5751965253) separately records installation. Physical-phone checks remain outside that verified implementation scope. |
| Tab marks: [plan](tab-marks-plan.md) | 5 / 0 | Archived. [PR #128](https://github.com/gl11tchy-team/sigil/pull/128), merge `0c1810bc`, covers saved/cleared colors, folder isolation, existing conversation names, inline/context-menu rename, and marks in tabs and the tab list. Current `TabColorTests`, `TabRenameTests`, `TabStripView`, and `TabListView` retain that scope. The PR reports 27 focused cases; it explicitly does not claim live menu-click QA. Later provider identity changes do not create new work under this old plan. |
| Remote hardening: [verification](remote-hardening-verify.md) | 0 / 0 | Archived. [PR #53](https://github.com/gl11tchy-team/sigil/pull/53), merge `ce00a298`, implements adversarial coverage, sealed routing, and stamped uploads. Its [separate release receipt](https://github.com/gl11tchy-team/sigil/pull/53#issuecomment-5752716778) closes the recorded release boundary with installed/activated build 151, exact clean live health/hash, matching assets, and native/browser production checks. The old checkpoint's pending-release wording is preserved. |
| Phone uploads, hardening, and product continuity: [spec](spec.md), [verification](verify.md), [plan](../../tasks/plan.md), [todo](../../tasks/todo.md) | 30 / 0 | Full historical scope has implementation and delivery receipts: [#28](https://github.com/gl11tchy-team/sigil/pull/28), [#44](https://github.com/gl11tchy-team/sigil/pull/44), #53 above, [#66](https://github.com/gl11tchy-team/sigil/pull/66), and [#121's final release record](https://github.com/gl11tchy-team/sigil/pull/121). #121 records final source `1b98f8c7`, Mac build 230, internal TestFlight build `202609271954`, matching web health/hash, both gates, and synthetic production QA, with explicit hardware/distribution limits. Spec and verification moved. Plan and todo remain solely because `.grok/workflows/ship-product-site.rhai` explicitly names their paths; changing that workflow is outside this documentation PR. Their notices distinguish completed history from active instructions. |
| Product site: [plan](../../tasks/product-site-plan.md), [spec](../../tasks/product-site-spec.md), [todo](../../tasks/product-site-todo.md), [verification](../../tasks/product-site-verify.md) | 5 / 94 | All four retained. [#40](https://github.com/gl11tchy-team/sigil/pull/40), [#46](https://github.com/gl11tchy-team/sigil/pull/46), and [#47](https://github.com/gl11tchy-team/sigil/pull/47) establish implementation and owner DNS/origin decisions. #53 closes the old relay-revision gap, but does not establish every Site production/browser/download checkpoint. The checked-in site still targets the old GitHub repository for its download. [REA-1245](https://linear.app/reasonable-glyph/issue/REA-1245/update-the-product-site-six-clis-real-shortcuts-phone-chats-share-tags) owns current site copy/link work; [REA-1228](https://linear.app/reasonable-glyph/issue/REA-1228/make-the-universal-arm64-x86-64-build-succeed-and-stop-shipping-a-thin) owns universal builds. The tracked workflow also creates/reads these task paths. No site change or deployment is implied by this review. |
| Phone second wave: [plan](../../tasks/phone-companion-2-plan.md), [todo](../../tasks/phone-companion-2-todo.md) | 4 / 0 | Both retained despite checked todos. [#110](https://github.com/gl11tchy-team/sigil/pull/110), [#111](https://github.com/gl11tchy-team/sigil/pull/111), [#112](https://github.com/gl11tchy-team/sigil/pull/112), and [#113](https://github.com/gl11tchy-team/sigil/pull/113) implement the four slices. #121 supplies later internal TestFlight and web receipts, but physical APNs/Live Activity delivery and the original APNs-configured rollout have no complete verification receipt here. The generic Yes/No requirement is superseded by the [product truth contract](../../PRODUCT.md) and #121's literal, unverified terminal controls; it must not be implemented from the old plan. The enduring [second-wave spec](../phone-companion-2-spec.md) stays in place. |

Archived files contain 9 checked and 10 unchecked boxes. Retained files contain
39 checked and 94 unchecked boxes. No box was changed, and no original file was
deleted. Existing QA, audit, release, product, design, experience, and security
records remain in place.

## Reference and README checks

Every moved path was checked against all tracked files, including hidden workflow
configuration, scripts, tests, app sources, web clients, and iOS. None is read or
written by a runtime/test/config consumer. `tasks/plan.md`, `tasks/todo.md`, and
all four product-site paths were retained because the tracked workflow names them.
References from the retained phone plan/todo now point to the archived evidence;
the archived verification names its spec at the new path. Its existing root-relative
code-path citations retain their meaning. Markdown file targets and original-body
preservation were checked without running an app or build.

The README shortcut table covers all 28 explicit `keyboardShortcut` bindings in
`GrokCommands` (36 shortcuts after expanding the nine-tab range), including
clipboard commands, Find Next/Previous, archive/pin, message delivery, and history
rebuild. All 34 local Markdown targets in changed files resolve. Native iPhone capabilities and limits were
read from [its current README](../../iOS/README.md) and `PRODUCT.md`.

Architecture was verified using [main CI run 38146797379](https://github.com/gl11tchy-team/sigil/actions/runs/38146797379):
the universal attempt failed, the allowed arm64 fallback passed, and release
`build-524.1` points to the reviewed main commit. Downloaded asset `630981112`
matched GitHub SHA-256
`2c05d0928a403f4cbeb6b9fb6243dde0791c406e0770a07f18b6f254252102b0`.
Both packaged executables were arm64 and passed strict deep signature verification.
That proves this published artifact's architecture, not Intel execution or
notarized distribution. No local Swift build, GUI test, or new live-site/phone
verification was run for this documentation change; ordinary PR CI is separate.
