# SDC Garbage collector, ported to normal D

This is a port of the [SDC](https://github.com/snazzy-d/sdc) garbage collector to D code that builds with DMD/LDC/gdc.

The idea is to extract the GC portions of the SDC runtime (and everything needed) in order to be able to build using standard compilers.

## Requirements

### OS/Arch
Intel/AMD 64-bit CPU.
Linux or Windows (so far)

### Compiler
* DMD 2.111 -> Linux only, does not include features needed for Windows support.
* DMD 2.112 (or unreleased master) or later. This is required for Windows support. It will also increase Linux performance.

## Progress so far

- d.sync is ported, uses core.atomic for building locks. Unittests passing.
- d.gc modules are ported.
- [X] allocclass.d
- [X] arena.d
- [X] base.d
- [X] bin.d
- [X] bitmap.d
- [X] block.d
- [X] capi.d
- [X] collector.d
- [X] cpu.d
- [X] emap.d
- [X] extent.d
- [X] fork.d
- [X] global.d
- [X] heap.d
- [X] hooks.d
- [X] memmap.d
- [X] page.d
- [X] proc.d
- [X] range.d
- [X] rbtree.d
- [X] region.d
- [X] ring.d
- [X] rtree.d
- [X] scanner.d
- [X] signal.d
- [X] size.d
- [X] sizeclass.d
- [X] slab.d
- [X] spec.d
- [X] stack.d
- [X] tbin.d
- [X] tcache.d
- [X] thread.d
- [X] time.d
- [X] tstate.d
- [X] types.d
- [X] util.d

Integration tests are also ported, and are in the test directory. Only SDC tests that are GC-specific were brought in.

To run, use dub in the test directory.

- [X] Add object for including new GC into druntime.
- [X] Test with real projects
- [X] Remove pthread override, use normal druntime hooks.
- [X] Detach scan threads from GC start and stop, allow them to be kept for next cycle and beyond.

Note there are 3 configs:
- `standard` - Uses only druntime hooks for all GC operations. The SDC `pthread_create` trampoline is not used
- `pthread` - Uses only the `pthread_create` trampoline to capture started threads. This is the equivalent of SDC's non-druntime build.
- `legacy` - Uses both druntime hooks and the `pthread_create` trampoline. This is what was developed when merging SDC's build of the GC with druntime.

All three configs pass unittests (only a couple unittests needed modification to pass).

The integration tests are explicitly using the `pthread` config, as those do not expect to use druntime.

- [X] druntime update to handle thread creation and destruction.
- [X] Port integration tests to standard config (druntime only).
- [X] Windows support

## Todo

- [ ] ARM 64-bit support.

## Acknowledgements

[Symmetry Investments](https://symmetryinvestments.com/) is sponsoring this work.
