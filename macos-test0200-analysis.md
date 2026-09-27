# test0200: slab double-free under multithreaded load on macOS ARM64

Status: **open** — mechanism confirmed by instrumentation, final root cause of the
marking gap still under investigation.
All findings below are backed by instrumented runs of `test/base/test0200.d`
(`cd test/base && dub --single --force test0200.d`), which reproduces within
seconds to a couple of minutes.

## 1. Symptom

`test0200` spawns 4 threads that allocate garbage at a high rate through
`__sd_gc_alloc` with automatic collection disabled, and each thread explicitly
runs `__sd_gc_collect()` every 4 M allocations. Under this load the process hits,
in various combinations and orders:

1. `extent.d(428)` — `assert(slabData.valueAt(index), "Slot is already free!")`
   inside `Extent.free`, reached from:
   `ThreadBin.flush → ThreadBin.flushImpl → Arena.batchFree → Bin.batchFreeImpl → Extent.free`.
2. `arena.d(83)` — `"Arena was not initialized!"`, from
   `ThreadBin.flushImpl → pds[0].arena → Arena.getInitialized`.
3. `extent.d(48)` — `"Non slab do not have a size class!"` from
   `binInfos[ec.sizeClass]` in `Bin.batchFreeImpl` when the descriptor is not a
   slab.

The failing slot indices include values both below and above every geometry
boundary; several consecutive indices of one extent often fail together
(e.g. idx 32–38+ of one sc=26 extent).

## 2. Data flow that produces every observed failure

Thread bins cache *free* slots as full pointers (`tbin.d`: `refill` fills
`[_head - nfill, _head)`, `allocate` pops upward). A cached slot is
"allocated" from the collector's point of view: its occupancy bit was set by
`Extent.batchAllocate` at handout time and is only cleared when the entry is
flushed back through `Bin.batchFreeImpl`.

Therefore the invariant the collector depends on is:

> every pointer sitting in any thread bin must be **marked** during each mark
> phase; otherwise the sweep reclaims the slot (and can free the whole slab)
> while a thread bin still points into it.

When that invariant breaks:

* cycle N sweep clears occupancy bits (or frees the whole slab via the
  "completely empty" shortcuts) while thread bins still reference the slots;
* a later refill hands those slots out again → double allocation;
* a later bin flush calls `Extent.free` on an already-cleared bit → failure 1;
* if the slab was freed entirely, its rtree mapping is cleared
  (`freeExtentLocked → emap.clear`). The stale bin pointer then resolves to a
  null leaf, and `emap.batchLookup` produces `PageDescriptor(0)`
  (`arenaIndex == 0`) → failures 2 and 3.

## 3. Probe evidence (all measured, not inferred)

Instrumentation used: per-slab death probes at the three dead-extent
shortcuts, a scan of all registered thread caches' bin buffers at eviction /
shortcut time, post-refill duplicate detection, a `BINSCAN` counter inside
`scanDruntimeThreadCaches`, and a `BINMARK` sampler run at the end of the root
scan.

### 3.1 Slabs die while bins still point into them — CONFIRMED

Probe at `collectSparseAllocations`' shortcut
(`markBits == 0 && metadataFlags == 0`):

```
DEAD-SLAB-BINNED sparse-shortcut: e=0x1493dc800 base=0x3872d4000 sc=19 nslots=32
DEAD-SLAB-BINNED sparse-shortcut: e=0x1493d3400 base=0x386730000 sc=25 nslots=32
DEAD-SLAB-BINNED sparse-shortcut: e=0x1493d4200 base=0x386780000 sc=26 nslots=56
...
```

The dense pass (`occupancyMask == 0`) and the second sparse shortcut
(`newOccupancy == 0`) were probed as well. All affected size classes
(15, 19, 21, 24, 25, 26, 28, 30) are sieve-sparse.

### 3.2 Binned pointers are fed to the marker but come out unmarked

`scanDruntimeThreadCaches` (added fix, see §5) runs during the root scan:

```
BINSCAN: run=1 caches=3 words=29835
```

i.e. all 3 worker caches (~30 k words each) are enqueued every cycle.
Immediately after enqueueing, sampled binned pointers show inconsistent mark
state:

```
BINMARK: ptr=0x386065100 sc=15 idx=17 gcWord=fffffffffe1fff01   <- marked
BINMARK: ptr=0x3859f7400 sc=15 idx=52 gcWord=10000001           <- NOT marked
BINMARK: ptr=0x385d07300 sc=15 idx=51 gcWord=0                  <- extent untouched
```

and at sweep time the same slots read `marked=0` while the cycle byte matches
(`gcWord=3 cycle=3`):

```
DEAD-SLAB-BINNED: e=... base=0x382d34000 sc=24 gcWord=3 cycle=3
  SLOT ptr=0x382d3bd00 idx=12 marked=0
```

Interpretation: the mark phase processes binned-pointer ranges
inconsistently. Some get marked, others never do — even though they arrive in
the same root ranges in the same cycle. Note the marker runs multi-threaded
(main thread + scanner threads pulling from a shared work list), so the loss
happens somewhere between `work.addToWorkList` and `markSparseSlot`.

### 3.3 Managed-address-space filtering is not the cause

`Scanner.mark` computes `managedAddressSpace =
dataRange.merge(ptrRange)`. Measured once per run:

```
MS: data=[0x3c0000000+40000000) ptr=[0x106600000+2b9a00000) merged=[0x106600000+2f9a00000)
```

Failing pointers (e.g. `0x3838fd600`) fall inside; `ms.contains` passes.

### 3.4 Refills never hand out duplicates

A probe inside `ThreadBin.refill` compared every freshly filled batch pair-wise:
no duplicates ever. Combined with the fact that test0200 never calls
`__sd_gc_free`, the only way a pointer appears twice in flush worklists is the
sweep-reclaims-binned-slot path above.

### 3.5 `PageDescriptor(0)` explains the arena assert

`CachedExtentMap.batchLookup` maps null leaves to `PageDescriptor(0)`, whose
`arenaIndex == 0`. Since arena 0 is always initialized first, the
`BADARENA: index=0` backtrace (`flushImpl → pds[0].arena`) proves the flushed
pointer had **no rtree mapping at all**: its slab had already been freed and
unmapped.

## 4. Ruled out

* Query paths mutating state — `getCapacity` etc. are read-only.
* Large-allocation byte accounting asymmetry — balanced by construction;
  balance checkpoints around every `testSpill` call are exact.
* Duplicate pointers created inside a single refill batch — disproven.
* Eviction-time bins holding the evicted slot — disproven for the per-slot
  eviction loops (dense and sparse); the loss happens through the
  whole-slab shortcuts, which bypass per-slot eviction entirely
  (see §3.1) — this is why early per-slot probes missed it.
* `nfree` field width — 16 bits, sufficient for 2048 slots.
* Managed-space filter rejecting heap pointers — §3.3.
* Stale `LastDenseSlabCache` across cycles misrouting marks — plausible
  contributor (a recycled address range would route marks into
  `markDense`/inline bitmaps instead of the sparse `gcWord`, matching
  `gcWord=<cycle>` with zero bits); fixed defensively (§5.2) but deaths
  persisted after the fix, so either it is not the sole cause or the reset
  does not cover all workers.

## 5. Changes applied so far

### 5.1 Bin buffers as explicit GC roots (keep)

* `tcache.d`: `public const(void*)[] binBufferWords()`.
* `symthread.d`: `void scanDruntimeThreadCaches(ScanDg scan)` — iterates
  druntime threads' `tlsGCData` caches and feeds each bin buffer to the
  marker.
* `thread.d`: called from `scanSuspendedThreadsImpl`
  (Symgc_druntime_hooks branch) right after `scanWorldPausedData`.

Rationale: upstream relies on regular TLS scanning covering the bin buffer
(see the FIXME in `tbin.d finalizeFlush`: *"we currently have no way to
ensure the thread cache is not marked as part of the regular TLS marking"*).
On the macOS druntime-hooks configuration that coverage evidently does not
materialize, which is exactly what §3.2 shows. Scanning the buffer explicitly
removes the platform dependence. Cost: conservative retention of stale
pointers in the buffer — identical to upstream's accepted behaviour
(`finalizeFlush` already nulls flushed entries for this reason).

### 5.2 Per-cycle `ldsCache` reset (keep)

`scanner.d Worker.setScanParameters` now resets
`ldsCache = LastDenseSlabCache.init`. The cache persists across cycles;
slabs freed during collect can have their address range recycled into a
different kind of extent before the next mark phase, and a stale cache entry
would misroute those pointers into `markDense` on the old descriptor —
leaving the real marks untouched (consistent with §3.2's `gcWord=<cycle>,
zero bits` signature).

### 5.3 Earlier related fixes (from previous sessions, prerequisites)

* Sparse classes capped at `MaxSparseSlots = 56` (sparse `gcWord` has only
  56 mark bits; uncapped 64-slot sparse slabs had permanently unmarkable
  trailing slots).
* `Symgc_default_gc` / `rt_options = ["gcopt=gc:sdc"]` for the integration
  config so druntime routes thread registration through `initSDCThread`.

## 6. Open questions / next steps

1. **Where do unmarked work items go?** Instrument `Worker.scanImpl` (or
   `markSparseSlot`) to log, per cycle, whether any binned pointer's slot was
   processed; compare against the set of pointers present in bins. Candidates:
   work-list overflow/drop in `ScanningList`/`Work.addToWorkList`, items left
   unprocessed when scanner threads shut down, or breadth-first workers
   starting from a stale `LastDenseSlabCache` (the breadth-first path passes
   `cache` by parameter — verify every entry point resets it).
2. **Verify druntime TLS coverage independently.** If
   `rt_tlsgc_scan(t.m_tlsrtdata)` does not cover executable static TLS on
   Darwin, then *all* module-level TLS variables holding GC pointers are
   invisible for suspended threads on this configuration — a much wider issue
   than bins. Test: store a live GC pointer in a module-level TLS variable in
   a worker thread, force a collection, check survival. If it fails, port the
   pthread-hook config's `registerTlsSegments` approach (currently ELF-only,
   `symgc/rt.d`) to Mach-O, or keep §5.1 and extend it to
   `tc.tlsSegments`/whole-cache scanning.
3. **Scanner-thread lifetime vs work list**: confirm all enqueued root ranges
   are drained before `restartTheWorld`; a shutdown race would drop exactly
   the tail of the root scan.
4. After the fix lands: full `test && dub` integration run (all druntime/*
   tests have never been executed on this platform yet), plus a regression
   unittest that fills a thread bin, forces two collections, and asserts the
   cached slots' slab survives.

## 7. Current tree state relevant to this issue

* `scanner.d` — `ldsCache` reset in `setScanParameters` (§5.2).
* `thread.d`, `symthread.d`, `tcache.d` — bin-buffer root scanning (§5.1).
* Everything else in this bug's scope restored to upstream semantics (hard
  asserts in `Extent.free` and `Arena.getInitialized`).
* `dub build`: clean. `dub test`: 28/28 modules pass.
