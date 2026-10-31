#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int pi_heap_begin(void);
int pi_heap_begin_threaded(void);
uint64_t pi_heap_allocated_bytes(void);
uint64_t pi_heap_live_bytes(void);
void pi_heap_thread_begin(void);
uint64_t pi_heap_thread_end(void);
void pi_heap_pause(void);
void pi_heap_resume(void);

#ifdef __cplusplus
}
#endif
