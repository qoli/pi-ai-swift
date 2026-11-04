#include "HeapObserver.h"
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <stdatomic.h>
#include <stddef.h>
#include <pthread.h>

// libmalloc's allocation logger ABI: apple-oss-distributions/libmalloc/src/malloc.c.
typedef void (*allocation_logger)(uint32_t, uintptr_t, uintptr_t, uintptr_t,
                                  uintptr_t, uint32_t);
static _Atomic(allocation_logger) *logger_slot;
static _Atomic uint64_t allocated_bytes;
static _Atomic uintptr_t measuring_thread;
static _Atomic uint64_t thread_bytes;
static _Atomic int thread_only;
static pthread_key_t pause_key;
static pthread_once_t pause_key_once = PTHREAD_ONCE_INIT;

static void create_pause_key(void) { pthread_key_create(&pause_key, NULL); }

static void observe_allocation(uint32_t type, uintptr_t zone, uintptr_t arg2,
                               uintptr_t arg3, uintptr_t result, uint32_t depth) {
  // Both malloc and realloc mark successful allocation events with bit 2.
  // Count capacity at allocation time; frees never subtract from this total.
  if ((type & 2) && result) {
    uintptr_t target = atomic_load_explicit(&measuring_thread, memory_order_relaxed);
    int matches = target == (uintptr_t)pthread_self();
    if (atomic_load_explicit(&thread_only, memory_order_relaxed) && !matches) return;
    if (pthread_getspecific(pause_key)) return;
    uint64_t size = malloc_size((void *)result);
    if (matches) {
      atomic_fetch_add_explicit(&thread_bytes, size, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&allocated_bytes, size,
                              memory_order_relaxed);
  }
}

int pi_heap_begin_threaded(void) {
  atomic_store_explicit(&thread_only, 1, memory_order_relaxed);
  int status = pi_heap_begin();
  if (!status) atomic_store_explicit(logger_slot, NULL, memory_order_relaxed);
  return status;
}

int pi_heap_begin(void) {
  pthread_once(&pause_key_once, create_pause_key);
  _Atomic(allocation_logger) *slot = dlsym(RTLD_DEFAULT, "malloc_logger");
  if (!slot) return 1;
  allocation_logger previous = atomic_load_explicit(slot, memory_order_relaxed);
  if (previous && previous != observe_allocation) return 1;
  logger_slot = slot;
  atomic_store_explicit(&allocated_bytes, 0, memory_order_relaxed);
  atomic_store_explicit(slot, observe_allocation, memory_order_relaxed);
  return 0;
}

uint64_t pi_heap_allocated_bytes(void) {
  return atomic_load_explicit(&allocated_bytes, memory_order_relaxed);
}

uint64_t pi_heap_live_bytes(void) {
  malloc_statistics_t statistics;
  malloc_zone_statistics(NULL, &statistics);
  return statistics.size_in_use;
}

void pi_heap_thread_begin(void) {
  atomic_store_explicit(&thread_bytes, 0, memory_order_relaxed);
  atomic_store_explicit(&measuring_thread, (uintptr_t)pthread_self(), memory_order_relaxed);
  if (atomic_load_explicit(&thread_only, memory_order_relaxed))
    atomic_store_explicit(logger_slot, observe_allocation, memory_order_relaxed);
}

uint64_t pi_heap_thread_end(void) {
  if (atomic_load_explicit(&thread_only, memory_order_relaxed))
    atomic_store_explicit(logger_slot, NULL, memory_order_relaxed);
  atomic_store_explicit(&measuring_thread, 0, memory_order_relaxed);
  return atomic_load_explicit(&thread_bytes, memory_order_relaxed);
}

void pi_heap_pause(void) {
  pthread_once(&pause_key_once, create_pause_key);
  uintptr_t depth = (uintptr_t)pthread_getspecific(pause_key);
  pthread_setspecific(pause_key, (void *)(depth + 1));
}

void pi_heap_resume(void) {
  uintptr_t depth = (uintptr_t)pthread_getspecific(pause_key);
  pthread_setspecific(pause_key, (void *)(depth - 1));
}
