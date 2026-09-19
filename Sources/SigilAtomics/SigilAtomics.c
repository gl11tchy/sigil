#include "SigilAtomics.h"

#include <stdatomic.h>

static _Atomic uint64_t sigil_state_publication = 0;
static atomic_bool sigil_crashing = false;

void sigil_publish_state(uint64_t value) {
    atomic_store_explicit(&sigil_state_publication, value, memory_order_release);
}

uint64_t sigil_load_state(void) {
    return atomic_load_explicit(&sigil_state_publication, memory_order_acquire);
}

void sigil_set_crashing(void) {
    atomic_store_explicit(&sigil_crashing, true, memory_order_relaxed);
}

bool sigil_is_crashing(void) {
    return atomic_load_explicit(&sigil_crashing, memory_order_relaxed);
}

void sigil_reset_state(void) {
    atomic_store_explicit(&sigil_state_publication, 0, memory_order_release);
    atomic_store_explicit(&sigil_crashing, false, memory_order_relaxed);
}
