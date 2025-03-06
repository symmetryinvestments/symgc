# SDC Garbage collector, ported to normal D

This is a port of the [SDC](https://github.com/snazzy-d/sdc) garbage collector to D code that builds with DMD/LDC/gdc.

The idea is to extract the GC portions of the SDC runtime (and everything needed) in order to be able to build using standard compilers.

## Requirements

Linux x64 (so far)

DMD master (2.111 base)

## Progress so far

- d.sync is ported, uses core.atomic for building locks. Unittests passing.
- d.gc modules are in progress (21/37):
- [X] allocclass.d
- [ ] arena.d
- [X] base.d
- [ ] bin.d
- [X] bitmap.d
- [X] block.d
- [ ] capi.d
- [ ] collector.d
- [X] cpu.d
- [X] emap.d
- [X] extent.d
- [ ] fork.d
- [ ] global.d
- [X] heap.d
- [ ] hooks.d
- [X] memmap.d
- [ ] page.d
- [ ] proc.d
- [X] range.d
- [X] rbtree.d
- [X] region.d
- [X] ring.d
- [X] rtree.d
- [ ] scanner.d
- [ ] signal.d
- [X] size.d
- [X] sizeclass.d
- [X] slab.d
- [X] spec.d
- [X] stack.d
- [ ] tbin.d
- [ ] tcache.d
- [ ] thread.d
- [ ] time.d
- [ ] tstate.d
- [X] types.d
- [X] util.d

## Todo

- Finish porting all GC modules
- Integration tests

## Acknowledgements

[Symmetry Investments](https://symmetryinvestments.com/) is sponsoring this work.
