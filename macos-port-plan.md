# macOS port — implementation plan for the slab-slot-limit fix

Companion to `macos-port-notes.md` §3.3 (the current `dub test` blocker).

## Problem

With 16 KB pages (`LgPageSize = 14`), small size classes get more slots
per slab than `Extent` can track inline:

| class | slot size | slots @16 KB | limit hit |
|---|---|---|---|
| 0 | 8  | 2048 | occupancy `Bitmap!512` |
| 1 | 16 | 1024 | occupancy + metadata flags `Bitmap!256` |
| 2 | 24 | 682  | occupancy + flags |
| 3 | 32 | 512  | exactly at old cap |

Consequences: `bin.d:133` assert during first refill (`nfree != nslots`),
and even after fixing occupancy, class 1 losing metadata support would
break appendable/finalizer allocations (minimum appendable size is
`2 * Quantum = 16` → class 1, which must support metadata — on 4 KB
pages it has exactly 256 slots).

## Design decisions

- Parameterize inline bitmap widths via new spec constants instead of
  hardcoding 512/256. Linux/Windows values unchanged → zero behavior
  change there.
- Widen the `nfree` bitfield mask from 10 to 16 bits — the documented
  `Extent.bits` layout already reserves bits 48–63 for it.
- Keep mark bits at `Bitmap!128`: classes above 128 slots already use
  the outlined-bitmap marking path on Linux (class 2 has 170 slots
  there), so that mechanism is proven.
- Grow `ExtentSize` from 128 to 512 bytes on OSX/AArch64 only. Metadata
  overhead stays proportional: worst case is one extent per page —
  128 × 512 B = 64 KB per 2 MB block = 3.125%, identical to Linux
  (512 × 128 B).
- Platform-divergent unittests (hardcoded 512-page-block or 512-slot
  arithmetic) are kept for linux/windows and get Darwin-specialized
  copies with the same idea (user directive: adopt only the
  platform-gated tests, specialized for macOS).

## Tasks

### T1 — spec.d: slab capacity constants
Add next to the other allocator config:
```d
version(OSX) { version(AArch64) {
    enum LgMaxSlabSlots = 11;  // 2048 slots (8-byte class)
    enum LgMaxFlagSlots = 10;  // 1024 (16-byte class keeps metadata)
} else {
    enum LgMaxSlabSlots = 9;   // 512
    enum LgMaxFlagSlots = 8;   // 256
} } else {
    enum LgMaxSlabSlots = 9;
    enum LgMaxFlagSlots = 8;
}
enum MaxSlabSlots = One << LgMaxSlabSlots;
enum MaxFlagSlots = One << LgMaxFlagSlots;
```

### T2 — extent.d: parameterize bitmaps and nfree
- `Bitmap!512 slabData` → `Bitmap!MaxSlabSlots` (union member + any
  local references).
- `GCMetadata.outlineBitmap`: `shared(Bitmap!512)*` → `shared(Bitmap!MaxSlabSlots)*`.
- `SlabMetadata.flags`: `Bitmap!256` → `Bitmap!MaxFlagSlots`
  (`marks` stays `Bitmap!128`).
- `nfree` mask: `(1 << 10) - 1` → `ushort.max`.
- Verify no other 512/256 literals remain in extent.d production code.

### T3 — extent.d/base.d: size and padding
- Empirically measure `Extent.sizeof` per platform (pragma(msg) build).
- Header is 64 B (bits 8, npages 4, class 1, gen 1, pad 2, block ptr 8,
  phnode 24, gcMetadata 8, pad1 8). Metadata union becomes 256 B on
  macOS → pad struct to exactly `ExtentSize`.
- Make `LgExtentSize` platform-dependent (7 elsewhere, 9 on
  OSX/AArch64); add explicit tail padding member so
  `static assert(Extent.sizeof == ExtentSize == ExtentAlign)` holds on
  all platforms.
- Check `base.d` `static assert(BlockPerExtent == 5)` still holds with
  `ExtentSize = 512` (expected yes: 512 / alignUp(Block.sizeof, 8);
  specialize if not).

### T4 — block.d unittests: Darwin-specialized copies
The `reserve_release`, `clear`, `growAt`, `track_dirty` unittests
hardcode 512-page-block arithmetic (e.g. reserving 200 pages —
impossible in a 128-page block). Gate them to non-OSX and add OSX
variants with the same scenario scaled to `PagesInBlock == 128`
(e.g. 200→50, 100→25, 212→53, …), keeping the same assertions about
alloc counts, dirty tracking and longest-free-range evolution.

### T5 — extent.d unittests: hardcoded slot counts
Unittests asserting `e.nfree == 512` etc.: gate to non-OSX, add OSX
copies using the actual `binInfos[sc].nslots` for the exercised class.

### T6 — build loop
`dub build` until the standard config compiles clean.

### T7 — unittest loop
`dub test`, fixing remaining failures one at a time. Expected areas:
tstate suspend (OSX variant already wired), kqueue waiter, mutex
fairness/condition tests, cpu count test, memmap tests. Only adapt
tests that are platform-gated or hardcode platform-specific values.

### T8 — integration tests
`cd test && dub` — expect all pass except `test0201` (linux-tagged)
and `wincommit` (win64-tagged), which the harness skips on macOS.

### T9 — documentation
Update `macos-port-notes.md` §3.3/§5 to reflect the resolution.
