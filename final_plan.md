# Final plan: tcache arraySpill unittest on macOS

## 1. Issue

`dub test`: 27/28 modules green. Last failure:

- `d.gc.tcache`, `@"arraySpill"` unittest, tcache.d(1807):
  `assert(tc.allocated == tc.deallocated)` in `scope(exit)`.
- Byte-accounting balance check after `destroyThread()`.
- Fails somewhere inside 4 sequential calls:
  `testSpill(64, ...)`, `testSpill(80, ...)`,
  `testSpill(16384, ...)`, `testSpill(20480, ...)`.

## 2. Test mechanics (tcache.d 1800-1929)

- `makeTwoAdjacentAllocs(size)` (OSX pool hack): 64 allocs from fresh
  contiguous space, scan for adjacent pair (`pool[j]+size is pool[i]`),
  free other 62, return pair. Each ptr freed exactly once.
- `testSpill`: a0/a1 adjacent; sets used-capacity metadata via
  `setAllocationUsedCapacity` (SlabAllocInfo if slab, extent
  otherwise); queries `tc.getCapacity(a0[s..s])` zero-length slices;
  frees a1, then a0.
- No counter updates in set/get capacity themselves.

## 3. Established facts

- Counters: tcache.d:639-659 `triggerAllocation/DeallocationEvent`.
- Large path balanced by construction: alloc `+= pages*PageSize`
  (:615), freeLarge `+= npages*PageSize` (:633).
- Size ladder byte-based & platform-independent (spec.d): 64/80 = slab,
  16384/20480 = large on BOTH platforms.
- Page deltas on macOS (16k pages): getPageCount(16384)=1 (linux: 4),
  getPageCount(20480)=2 (linux: 5). nslots per class-0 slab: 2048 vs 512.
- Other unittests' own balance asserts pass → basic alloc/free
  accounting sound; failure is arraySpill-specific.

## 4. Candidate root causes (ranked)

- C1. Slab free() derives freed bytes from slot metadata that
  setAllocationUsedCapacity overwrote → asymmetry vs alloc-time count.
  Must check what slab free reads; linux passes, so any such path must
  diverge only under 16k geometry.
- C2. getCapacity spill-read crosses into neighbor and a query path
  mutates extents/counters (extend template at :855+ does growLarge +
  triggerAllocationEvent). Query should be side-effect free.
- C3. destroyThread() flush counts partially-used slabs differently
  than their allocation did (16k-only bin arithmetic).
- C4. Test literals tuned to 4k (capacities arrays fine — absolute
  bytes; less likely than C1-C3).

## 5. Diagnostics (cheapest first)

1. Balance assert after EACH testSpill call → localizes which
   arraySize breaks it (one build).
2. Log bytes in triggerAllocation/DeallocationEvent around the
   breaking call; diff sides.
3. Trace slab alloc/free byte computation symmetry.

## 6. Solution directions

- A. If test is 4k-tuned → rescale literals for OSX (pattern used for
  block.d/extent.d fixes).
- B. If production accounting bug in macOS path → fix tcache/page
  accounting to be symmetric under 16k pages.
- C. If query-side effect (C2) → make getCapacity read-only on OSX
  paths or fix the spill boundary logic it exposes.
