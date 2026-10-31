#include "HeapObserver.h"
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <stdatomic.h>
#include <stddef.h>

// libmalloc's allocation logger ABI: apple-oss-distributions/libmalloc/src/malloc.c.
typedef void (*allocation_logger)(uint32_t, uintptr_t, uintptr_t, uintptr_t,
                                  uintptr_t, uint32_t);
static _Atomic uint64_t allocated_bytes;

static void observe_allocation(uint32_t type, uintptr_t zone, uintptr_t arg2,
                               uintptr_t arg3, uintptr_t result, uint32_t depth) {
  // Both malloc and realloc mark successful allocation events with bit 2.
  // Count capacity at allocation time; frees never subtract from this total.
  if ((type & 2) && result) {
    atomic_fetch_add_explicit(&allocated_bytes, malloc_size((void *)result),
                              memory_order_relaxed);
  }
}

int pi_heap_begin(void) {
  _Atomic(allocation_logger) *slot = dlsym(RTLD_DEFAULT, "malloc_logger");
  if (!slot || atomic_load_explicit(slot, memory_order_relaxed)) return 1;
  atomic_store_explicit(&allocated_bytes, 0, memory_order_relaxed);
  atomic_store_explicit(slot, observe_allocation, memory_order_relaxed);
  return 0;
}

uint64_t pi_heap_allocated_bytes(void) {
  return atomic_load_explicit(&allocated_bytes, memory_order_relaxed);
}
