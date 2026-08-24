# macOS (Apple Silicon) port — internal findings

This document captures the findings gathered while porting symgc to
macOS ARM64 (M1 family). It describes the GC's internal structure, the
platform-dependent seams, and the consequences of running with 16 KB
OS pages.

## 1. Platform abstraction seams

The GC forks behavior by platform in these places:

| Area | Linux | Windows | macOS (this port) |
|---|---|---|---|
| Reserve/commit/purge | `mmap`/`madvise` (`d/gc/memmap.d`) | `VirtualAlloc`/`VirtualFree` | `mmap`/`madvise` (shared with Linux patterns) |
| Core count | `sched_getaffinity` (`d/gc/cpu.d`) | `threadsPerCPU` | `sysctlbyname("hw.ncpu")` |
| Wait primitive | futex (`d/sync/futex/`) | `WaitOnAddress` (`d/sync/win32/`) | kqueue `EVFILT_USER` (`d/sync/kqueue/waiter.d`) |
| Stop-the-world | POSIX signals on the target thread (`d/gc/signal.d`) | druntime suspend + suspender-driven state machine + `gcBusyEvent` | druntime suspend (mach `thread_suspend`/`thread_get_state`) + suspender-driven state machine + `gcBusyEvent` |
| Delayed suspension | `sigsuspend` on target | `gcBusyEvent` parking | same as Windows |
| Thread registry | own list when `Symgc_pthread_hook` | druntime's thread list | druntime's thread list (`Symgc_druntime_hooks` only) |

Key druntime facts relied upon (LDC 1.42 / druntime 2.112):
- On Darwin, `core.thread.osthread.suspend()` uses `thread_suspend` +
  `thread_get_state` (captures x0–x28, fp, lr, sp into `m_reg`),
  `resume()` uses `thread_resume`. No GC signals on Darwin.
- `thread_preSuspend`/`thread_postSuspend` are exported only for
  non-Darwin Posix; they must not be referenced on macOS
  (`d/gc/hooks.d` gates them behind `version(linux)` now).
- `thread_scanAllType` is platform-independent and scans stacks/registers
  of suspended threads — used via `scanWorldPausedData` in
  `core/thread/symthread.d`.
- `core.sync.event` works on Posix (pthread cond/mutex) — used for
  `gcBusyEvent` on Windows and now macOS.
- `callWithStackShell` / `getStackBottom` exist on Darwin (via
  `pthread_get_stackaddr_np`), so `symgc/rt.d`'s stack helpers work
  unchanged.

## 2. The kqueue waiter

`d.sync.mutex` needs a parking primitive (`block`/`wakeup`/`poke`).
The macOS implementation (`source/d/sync/kqueue/waiter.d`) mirrors
`FutexWaiter`'s counting semantics:

- `Atomic!uint wakeupCount` — block() consumes counts; wakeups that
  arrive while the waiter isn't parked are counted, not lost.
- A lazily created, per-waiter kqueue fd with one `EVFILT_USER` event
  registered with `EV_ADD | EV_CLEAR`.
- `poke()` issues `NOTE_TRIGGER` on the event; the trigger persists in
  the kernel until consumed by `kevent`, so a poke racing with the
  waiter's counter check cannot be lost.
- Order in `block()`: register event first, re-check the counter, only
  then wait in `kevent` — otherwise a wakeup between the check and the
  wait would be missed.
- Spurious wakeups are harmless (block() loops); the counter is the
  source of truth, the kqueue is only a wake-up channel.
- `poke()` is a no-op when the waiter never blocked (no fd yet).

One fd per thread that parks on a contended mutex. The default macOS
soft fd limit on current systems (1048576 here) is far above the
1024-thread tests in `d/sync/mutex.d`.

## 3. 16 KB page size consequences (M1 userspace pages are always 16 KB)

`d/gc/spec.d` now sets `LgPageSize = 14` for `version(OSX) version(AArch64)`.
Everything derived from it adapts (`BlockSize` stays 2 MB,
`PagesInBlock` becomes 128, rtree levels shift, …), except the places
below, which were handled or are still open:

### 3.1 Size-class ladder — fixed via `LgSlabSize` (done)

`sizeclass.d` used `LgPageSize` for the small/large class boundary
(`getSmallClassCount`, `getLookupClassCount`, `getSizeFromClass`).
With 16 KB pages that extended small classes to ~57 KB, breaking the
14-bit packed free-space metadata in `slab.d`
(`static assert(MaxSmallSize < 0x4000)`).

Fix: new constant `LgSlabSize = 12` in `spec.d`, decoupling the slab
boundary from the OS page size. The size-class ladder is now identical
on every platform: `MaxSmallSize = 14336`, `ClassCount.Small = 39`,
`ClassCount.Total = 239` — the existing size unittests stay valid
unchanged on all platforms.

### 3.2 `BlockDescriptor` count per page — fixed (done)

`block.d` asserts `Count == 21` where
`Count = PageSize / alignUp(BlockDescriptor.sizeof, CacheLine)`.
`BlockDescriptor` embeds two `Bitmap!PagesInBlock` instances, so its
size changes with the page size (128 on macOS vs 192 on 4 KB pages),
and 16 KB pages host more of them: `Count == 128` on macOS. The assert
is now platform-specialized.

### 3.3 Slab slot count limits — OPEN ISSUE (current blocker)

`Extent` (`d/gc/extent.d`) hard-limits slab slot counts:

- Occupancy bitmap: `Bitmap!512 slabData` (union with mark/metadata
  bitmaps) — max **512 slots** per slab.
- Free-slot counter: 10-bit field in `Extent.bits`
  (`nfree` mask `(1 << 10) - 1`) — max **1023**.
- Inline mark bits (`SlabMetadata.marks`, `Bitmap!128`) and metadata
  flags (`Bitmap!256`); larger slot counts already fall back to
  outlined bitmaps for marking (`GCMetadata.outlineBuffer`), but
  occupancy is always inline.

With 16 KB pages, small classes exceed the 512-slot cap, e.g.:

| slot size | slots in 16 KB | cap 512 utilization |
|---|---|---|
| 8  | 2048 | 25% |
| 16 | 1024 | 50% |
| 24 | 682  | 75% |
| 32 | 512  | 100% (at cap) |

This currently trips `bin.d:133`:
`assert(freshSlab is null || freshSlab.nfree == nslots)` on the first
slab refill during `gc_init` (`ProtoGC.transferRangesAndRoots` →
`addRootsImpl` → small alloc of 16 bytes).

Options considered:

- **A. Cap `nslots` at 512 in `getBinInfos`.** Trivial, but wastes the
  slab tail (up to 75% for 8-byte slots).
- **B. Cap slots and trim `npages`.** 16 KB-page classes for slots
  < 32 bytes would need sub-page slabs — impossible (mmap granularity),
  so same waste as A.
- **C. Widen inline bitmaps (`Bitmap!2048`) and the `nfree` field.**
  Overflows the 128-byte `ExtentSize` budget; requires moving occupancy
  out-of-line (large redesign of Extent).
- **D. Increase `ExtentSize` (e.g. 512 B) on 16 KB platforms.**
  Metadata-to-heap ratio stays constant (fewer pages → fewer extents),
  keeps 100% slot utilization, medium-sized change: layout of `Extent`,
  `static assert(Extent.sizeof == ExtentSize)`, extent allocation in
  `base.d`, and unittests hardcoding slot counts (extent.d unittests
  assert `e.nfree == 512` etc. would need `PagesInBlock`-derived
  variants). Slab index bits in `SlabEntry` (16 bits from
  `IndexShift = 48`) still suffice (2048 max).

### 3.4 Purge semantics (verified safe)

`pages_purge` = `MADV_DONTNEED` (deterministic zeroing; used by
`pages_zero` and the rtree leaf-purge optimization — enabled for OSX).
`pages_purge_lazy` = `MADV_FREE` (lazy discard; macOS value 5 has
Linux-like semantics). No hugify/dehugify on macOS (return false).

### 3.5 Sparse slot-count limit — fixed (done)

Sparse slabs track their marks in the extent's `gcWord`: an 8-bit
cycle counter plus 56 mark bits (`Extent.markSparseSlot`,
`bit = 0x100 << index`).  The size-class sieve marks classes
{15, 19, 21} and >= 23 as sparse.  With 4 KB pages their natural
slot counts are <= 16, but with 16 KB pages classes 15/21/24/26 get
64 slots — so slots 56..63 could never be marked and the collector
reclaimed them while they were alive.

Fix: `MaxSparseSlots = 56` in `spec.d`; `getBinInfos` caps the slot
count of sieve-sparse classes at that limit (about 12% slack on the
affected classes).  Guarded by an assertion in the
`isDenseSizeClass` unittest.  Also widened the sieve shift to
`ulong`, since `getBinInfos` now evaluates it at CTFE for all 39
small classes.

### 3.6 GC selection for integration tests — fixed (done)

The integration tests select symgc as the process GC via
`rt_options = ["gcopt=gc:sdc"]`, but only under `version(Windows)`.
Without it, druntime never routes thread registration through
`initSDCThread`, leaving `tlsGCData` null for every druntime thread,
which deadlocks or asserts in `suspendDruntimeThreads`.

Fix: new `Symgc_default_gc` version (integration config,
`versions-osx`) which defines `rt_options` in `gcobj.d`.  The
standard/unittest configuration is unchanged.

## 4. Threading / suspension machinery enabled for OSX

- `d/gc/thread.d`: new local version tag `Symgc_GCBusyEvent`
  (Windows or OSX) enabling `gcBusyEvent`, delayed-thread counting,
  `suspendThreadDelayedNoSignals`, and the `simulateStopTheWorld`/
  `simulateResumeTheWorld` test hooks. `createProcess` sets up
  `pthread_atfork` handlers on OSX (no signals).
- `core/thread/symthread.d`: OSX branches in
  `suspendDruntimeThreads`/`resumeDruntimeThreads` mirror the Windows
  flow (suspend via druntime, then drive the suspend-state machine from
  the suspending thread), without the Windows-only
  `checkLockWaiting`/`resolveLockWaiting` workaround — kqueue wakeups
  are kernel-persisted across a mach suspend.
- `d/gc/tstate.d`: signal-based suspend unittest gated to linux; the
  busy-event suspend unittest now also runs on OSX (local tag
  `Symgc_BusyWaitSuspension`).
- `symgc/thread.d`, `symgc/test.d`: pthread-based thread create/join,
  `sched_yield`, `sleep`/`usleep` widened from `linux` to `Posix`.
- `d/gc/fork.d`: widened via local tag `Symgc_AtFork`.
- `dub.json`: `integration` configuration now uses
  `"versions-osx": ["Symgc_druntime_hooks", "Symgc_default_gc"]`.
  Tests in `test/` pick it up unchanged; `test0201` is linux-tagged,
  `wincommit` win64-tagged — both skipped by the harness on macOS.
  `test0198`/`test0199`/`test0203` gained
  `//T platform:win64,linux` tags — they only compile under Windows
  or linux (their finalizer setup is version-gated to those platforms).

## 5. Current state

- `dub build` (standard config): **passes**.
- `dub test`: **28/28 modules pass**.
- Integration tests (`cd test && dub`): `test0195`, `test0196` pass;
  platform-tagged tests skip correctly.  Remaining failure:
  `test0200` (multithreaded stress) hits a double-free of slab slots
  under load — see section 6.

## 6. Open issue: test0200 double-free

`extent.d(428)` "Slot is already free" fires from
`ThreadBin.flush → Bin.batchFreeImpl → Extent.free` after some GC
cycles under test0200's allocation load (4 threads allocating
32-byte..large garbage with explicit `__sd_gc_collect`).  A secondary
`arena.d(83)` "Arena was not initialized" assert appears sometimes,
suggesting extent metadata corruption.

Ruled out with instrumentation (since removed):

- Sweep-time probes in BOTH `collectDenseAllocations` and
  `collectSparseAllocations`: no evicted slot was present in any
  registered thread cache bin at eviction time.
- Refill-time duplicate check inside `ThreadBin.refill`: batches
  never contain duplicate pointers.
- `getCapacity`/query paths are read-only; large alloc/free byte
  accounting is symmetric by construction.

The sparse-slot cap (3.5) removed the deterministic unmarkable-slots
bug but test0200 still trips.  Next steps: checksum each slab's
occupancy word across cycles to find who clears the bit of the
eventually-double-freed slot; suspect the OSX delayed-suspension /
probation protocol (mach suspend + gcBusyEvent parking) letting one
thread mutate a slab while another collects.

## 7. Unittest port progress (session: block/base/arena/extent/rtree/emap)

All `dub test` module unittests pass: 28 modules total, 28 green.
The `d.gc.tcache` `arraySpill` failure was resolved: the last
`testSpill` size (20480) is an exact page multiple only on 4 KB
systems; on 16 KB pages the OSX path uses 32768 instead (see
`tcache.d`).

### Fixes applied

- `d/gc/block.d`: `reserve_release`, `clear`, `growAt` unittests
  scaled for `PagesInBlock == 128` (16k pages). The `clear` branch
  releases the *remaining* allocated count after shrinks (50 not 53,
  lfr 54) — `release()` delegates to `clear()`, which asserts every
  page is still allocated.
- `d/gc/arena.d`: `growLarge` unittest uses versioned size constants
  (`l0/l1/l2/g0/lc` = 8/16/32/12/25 on OSX, 35/64/128/44/100 else);
  all page-count expressions derived symbolically
  (`PagesInBlock - l0 - l1` etc.). Cross-block huge-grow section is
  fully symbolic already.
- `d/gc/base.d`: `count_blocks` hardcoded 16382/16383 metadata-slot
  indices (linux: 2MB/128B extents) replaced with
  `BlockSize / ExtentSize - 2 / -1` (OSX extents are 512B → 4096 slots).
- `d/gc/extent.d`: missing local `import d.gc.slab` in the priority
  unittest's `makeExtent` (compile error); `contains` unittest base
  address aligned via `alignUp(..., PageSize)`; `allocfree` and
  `batchAllocate` unittests rewritten against
  `N = binInfos[0].nslots` (2048 slots per size-class-0 slab on OSX vs
  512 on linux). Batch semantics verified: phase 3 leaves exactly two
  occupied slots {N/2-1, N/2}; request `R = N - 48`,
  postFree `= N - R - 2`.
- `d/gc/rtree.d`: removed the OSX `pages_purge` shortcut in
  `clearRange` — Darwin `MADV_DONTNEED` does **not** guarantee
  zero-fill-on-refault without memory pressure, so purged leaf arrays
  read back stale values (caught by `set_clear_range`: entry i=910
  survived). Falls through to explicit per-leaf stores.
  OSX `rtreeAddr4` moved to `0x5680_0000_0000`: the `rtree_cache`
  unittest XORs `ptr0` with `RepeatOffset` (16 level-0 keys), which
  requires key bit 4 clear, i.e. address aligned to `32 * Level0Align`
  (2^36). Old value's key 0xACF0 carried when +16.
- `d/gc/emap.d`: unittest base address aligned with
  `alignUp(..., PageSize)` (lookup hits rtree `isValidAddress` before
  any extent assert fires).

### Debug instruments currently in tree

- `source/symgc/test.d`: fast unittest runner now prefixes failures
  with the **module name** (`d.gc.emap: source/d/gc/rtree.d(80)...`),
  which is how cross-module throws are attributed. Permanent keeper.
  The rtree/tcache debug dumps from earlier sessions have been
  removed.

### Remaining

- `test0200` double-free (section 6).
