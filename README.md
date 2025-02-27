# SDC Garbage collector, ported to normal D

This is a port of the [SDC](https://github.com/snazzy-d/sdc) garbage collector to D code that builds with DMD/LDC/gdc.

The idea is to extract the GC portions of the SDC runtime (and everything needed) in order to be able to build using standard compilers.

## Requirements

Linux x64 (so far)

DMD master (2.111 base)

## Progress so far

- d.sync is ported, uses core.atomic for building locks. Unittests passing.

## Todo

- The rest of the GC
- Integration tests

## Acknowledgements

[Symmetry Investments](https://symmetryinvestments.com/) is sponsoring this work.
