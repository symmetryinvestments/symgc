# SDC Garbage collector, ported to normal D

This is a port of the [SDC](https://github.com/snazzy-d/sdc) garbage collector to D code that builds with DMD/LDC/gdc.

The idea is to extract the GC portions of the SDC runtime (and everything needed) in order to be able to build using standard compilers.

## Requirements

Linux x64 (so far)

DMD master (2.111 base)

## Progress so far

- d.sync is ported, uses core.atomic for building locks. Unittests passing.
- d.gc modules are in progress (36/37):
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
- [ ] hooks.d - Ported for tests, but needs full integration with druntime to finish
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

## Todo

- [ ] Add object for including new GC into druntime.
- [ ] Test with real projects
- [ ] Remove pthread override, use normal druntime hooks.

## Acknowledgements

[Symmetry Investments](https://symmetryinvestments.com/) is sponsoring this work.
