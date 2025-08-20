# SDC Garbage collector, ported to normal D

This is a port of the [SDC](https://github.com/snazzy-d/sdc) garbage collector to D code that builds with DMD/LDC/gdc.

The idea is to extract the GC portions of the SDC runtime (and everything needed) in order to be able to build using standard compilers.

## Requirements

### OS/Arch

* Intel/AMD 64-bit CPU.
* AArch64 Linux 4k pages tested only!
* Linux or Windows (so far)

### Compiler
* ~~DMD 2.111 -> Linux only, does not include features needed for Windows support.~~ EDIT: this is not actually correct, and further tests have shown that Fiber-based cases do not work properly. For that reason, I recommend waiting for 2.112.
* DMD 2.112 (or unreleased master) or later. This is required for Windows support. It will also increase Linux performance.

## Using

In order to use symgc, you should import the `symgc.gcobj` module. This will incorporate the symgc garbage collector as an option for your code to use. In order to use this GC, you must give druntime the name `sdc` as the gc requested. There are 2 ways to do this:

1. Use an `rt_options` static configuration. e.g.:

```d
extern(C) __gshared rt_options = ["gcopt=gc:sdc"];
```

2. Pass the runtime parameter `--DRT-gcopt=gc:sdc` when starting your program.

Without either of these, your program will NOT use the symgc, but the default D conservative GC.

Using the GC in this way will print the message "using SYM GC!" to the console on stdout. If you wish to avoid this message, you can use the gc option `sdcq` instead of `sdc`.

Note that if you use symgc as a dub dependency, it will be copmpiled in the same mode as your code. This means, if you build in debug mode (the default), then the GC will not be optimized.

We are working on getting this set up as a dub dependency so you can include the GC optimized, regardless of your project's build settings.

## Performance expectations

In our testing, the GC performs very well in terms of maximum physical RAM required. In some cases saving over 50% of the RAM needed for certain programs. This is likely to be the case for very high memory usage programs, but not nesessarily for small memory programs.

The performance of collection cycles is still a work in progress, and we are hoping to make this more efficient, but at the moment, some tests run much slower than the default GC, and some run faster.

Multithreaded performance should be much better than the default GC, as symgc does not have a global lock.

## Todo

- [ ] Provide mechanism to always include optimized GC.
- [X] ARM 64-bit support.
- [ ] ARM 64-bit support with 16k pages.
- [ ] Mac/FreeBSD support.
- [ ] Explore tuning parameters for memory consumption/performance
- [ ] SIMD improvements for scanner.

## Acknowledgements

[Symmetry Investments](https://symmetryinvestments.com/) is sponsoring this work.
