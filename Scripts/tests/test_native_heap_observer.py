from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "Scripts/Conformance"


@unittest.skipUnless(sys.platform == "darwin", "libmalloc observation requires macOS")
class NativeHeapObserverTests(unittest.TestCase):
    def compile_observer(self, directory):
        target = directory / "observer.o"
        subprocess.run(["xcrun", "clang", "-std=c11", "-c", str(SUPPORT / "HeapObserver.c"),
                        "-o", str(target)], check=True, capture_output=True, text=True)
        return target

    def test_allocation_capacity_includes_freed_malloc_calloc_realloc_and_aligned_blocks(self):
        with tempfile.TemporaryDirectory(prefix="pi-heap-calibration-") as temporary:
            directory = Path(temporary)
            observer = self.compile_observer(directory)
            source = directory / "calibration.c"
            source.write_text(r'''
#include "HeapObserver.h"
#include <malloc/malloc.h>
#include <stdlib.h>
int main(void) {
  if (pi_heap_begin()) return 1;
  void *(*volatile allocate)(size_t) = malloc;
  void *(*volatile zero_allocate)(size_t, size_t) = calloc;
  void *(*volatile resize)(void *, size_t) = realloc;
  void (*volatile release)(void *) = free;
  uint64_t before = pi_heap_allocated_bytes();
  void *first = allocate(33);
  if (!first || pi_heap_allocated_bytes() - before != malloc_size(first)) return 2;
  before = pi_heap_allocated_bytes();
  release(first);
  if (pi_heap_allocated_bytes() != before) return 3;
  void *second = zero_allocate(7, 13);
  if (!second || pi_heap_allocated_bytes() - before != malloc_size(second)) return 4;
  before = pi_heap_allocated_bytes();
  second = resize(second, 257);
  if (!second || pi_heap_allocated_bytes() - before != malloc_size(second)) return 5;
  before = pi_heap_allocated_bytes();
  void *aligned = NULL;
  if (posix_memalign(&aligned, 256, 513)) return 6;
  if (pi_heap_allocated_bytes() - before != malloc_size(aligned)) return 7;
  before = pi_heap_allocated_bytes();
  release(second);
  release(aligned);
  return pi_heap_allocated_bytes() == before ? 0 : 8;
}
''')
            executable = directory / "calibration"
            subprocess.run(["xcrun", "clang", "-std=c11", "-O1", "-I", str(SUPPORT),
                            str(source), str(observer), "-o", str(executable)],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)

    def test_swift_arrays_freed_each_iteration_still_contribute_to_cumulative_bytes(self):
        with tempfile.TemporaryDirectory(prefix="pi-swift-heap-calibration-") as temporary:
            directory = Path(temporary)
            observer = self.compile_observer(directory)
            source = directory / "main.swift"
            source.write_text('''
import Foundation
precondition(pi_heap_begin() == 0)
let before = pi_heap_allocated_bytes()
var checksum = 0
for _ in 0..<16 {
  let bytes = Array(repeating: UInt8(1), count: 16384)
  checksum += Int(bytes[0])
}
let total = pi_heap_allocated_bytes() - before
precondition(checksum == 16)
precondition(total >= 16 * 16384)
''')
            executable = directory / "calibration"
            subprocess.run(["xcrun", "swiftc", "-Onone", "-import-objc-header",
                            str(SUPPORT / "HeapObserver.h"), str(source), str(observer),
                            "-o", str(executable)], check=True, capture_output=True, text=True)
            subprocess.run([str(executable)], check=True, capture_output=True, text=True)
