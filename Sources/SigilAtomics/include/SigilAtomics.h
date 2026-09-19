#ifndef SIGIL_ATOMICS_H
#define SIGIL_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

// The crash reporter's snapshot descriptor, packed as slot and byte count.
//
// Swift has no lock-free atomics available on this deployment target, and the
// crash reporter needs them: the app publishes from the main thread while a
// signal handler on any thread may read. An aligned word is not a release
// store, so without these the handler could see a new descriptor before the
// bytes it describes. A lock is not an option — none of them are safe to take
// in a signal handler — so the ordering lives here instead.

/// Publishes the descriptor with release ordering, so a reader that sees this
/// value also sees everything written before it.
void sigil_publish_state(uint64_t value);

/// Loads the descriptor with acquire ordering. Lock-free and allocation-free,
/// so a signal handler may call it.
uint64_t sigil_load_state(void);

/// Marks that a crash path has started, so an update still in flight gives up
/// rather than write into a buffer the handler is reading.
void sigil_set_crashing(void);
bool sigil_is_crashing(void);

/// Back to the starting state. Only tests need this; the app crashes once.
void sigil_reset_state(void);

#endif
