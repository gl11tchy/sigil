# Task ledger first-writer repair

On 2026-11-04, two synchronized writers reproduced the task ledger failure on
this Mac without Swift, Foundation or application state. A C probe used the same
`openat` flags on a private directory and 1,000 new lock names. Of 2,000 opens,
997 failed with `ENOENT`. No process removed a directory or lock during the run.

Exclusive creation followed by a non-creating open on `EEXIST` completed all
2,000 opens with no error. The store now uses that sequence. It retains the
no-follow flag, private-file checks, cooperative lock, stable inode checks and
bounded lock wait. A missing existing lock or any other error still fails.
The application never retries a write or rebuilds a ledger from old preferences.

An independently published [macOS lock repair](https://github.com/entireio/cli/commit/9c18f31b23a62749b804718125b17c236420a28a)
reports the same kernel create-or-open failure. The local reproduction, not that
report alone, supports this change. Raw C source and results remain in the local
Sigil cleanup evidence folder.

The merge with current main also carries the saved task ID through the newer
Reopen Closed Chat path. A failed registration keeps the closed-chat intent.
The existing reopen regression now checks that the task ID survives the close
and remains in the startup snapshot.

`swift test --no-parallel --filter 'TaskLedger|ClosedTabReopenTests'` passed 45
checks in four suites. These cover first-writer concurrency, interrupted writes,
recovery, identity binding, migration and the merged reopen path. The fixtures
use generated homes and fake provider executables. No model API was called.
Full runner verification remains required before merge.

The original Swift store was then restored in the disposable checkout for the
single existing concurrent-writer test. That test failed at `round-0.json.lock`
with `ENOENT`. Restoring the repaired store made the same unchanged test pass.
This verifies the application-level failure and repair as well as the C probe.
