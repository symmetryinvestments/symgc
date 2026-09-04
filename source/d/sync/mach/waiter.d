module d.sync.mach.waiter;

version (OSX):

import d.sync.atomic;
import core.stdc.errno : EAGAIN, EFAULT, EINTR, ENOENT;

/*
 * Darwin's ulock interface is the primitive used by libplatform and the
 * system synchronisation classes. It is not public API, but it has been
 * stable since macOS 10.12 and is what libc++'s atomic waits use. The public
 * os_sync_wait_on_address family only exists from macOS 14.4, so switch to
 * it once that is the minimum supported version.
 *
 * Unlike a condition variable it lets the waiter use the same atomic word
 * for both the wake-up count and the kernel wait predicate, so a wake cannot
 * be lost between checking the word and entering the kernel.
 */
extern (C) int __ulock_wait(uint operation, void* address, ulong value,
	uint timeout) nothrow @nogc;
extern (C) int __ulock_wake(uint operation, void* address,
	ulong wakeValue) nothrow @nogc;

enum uint UL_COMPARE_AND_WAIT = 1;
enum uint ULF_NO_ERRNO = 0x0100_0000;

struct MachWaiter {
	Atomic!uint wakeupCount;

	bool block() shared {
		while (true) {
			auto count = wakeupCount.load();
			while (count > 0) {
				if (wakeupCount.casWeak(count, count - 1)) {
					return true;
				}
			}

			assert(count == 0, "Failed to consume wake up!");

			// timeout == 0 means wait indefinitely.  The value is rechecked by
			// the kernel, so a concurrent wake either increments the count before
			// this call or wakes this waiter.
			auto err = __ulock_wait(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO,
				cast(void*) &wakeupCount, 0, 0);
			switch (err) {
				case 0, -EINTR, -EAGAIN, -EFAULT:
					continue;
				default:
					assert(0, "ulock wait failed");
			}
		}
	}

	void wakeup() shared {
		auto oldCount = wakeupCount.fetchAdd(1);
		if (oldCount == 0) {
			poke();
		}
	}

	void poke() shared {
		auto err = __ulock_wake(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO,
			cast(void*) &wakeupCount, 0);
		// ENOENT means there was no waiter at the instant of the wake.  The
		// count remains available for a later waiter, so it is success.
		assert(err == 0 || err == -ENOENT, "ulock wake failed");
	}
}

// Keep the same lost-wake and repeated-wake coverage as the futex backend.
@"mach wait" unittest {
	import symgc.test;
	import d.sync.atomic;

	shared Atomic!uint state;
	shared Atomic!uint count;
	shared MachWaiter waiter;

	void* run() {
		while (true) {
			waiter.block();
			auto st = state.load();
			if (st == 2)
				break;
			assert(st == 1);
			state.casWeak(st, 0);
			count.fetchAdd(1);
		}
		return null;
	}

	auto tid = runThread(&run);
	foreach (_; 0 .. 1000) {
		assert(state.load() == 0);
		state.store(1);
		waiter.wakeup();

		while (state.load() == 1) {
			import core.thread;
			Thread.yield();
		}
		assert(waiter.wakeupCount.load() == 0);
	}

	assert(state.load() == 0);
	state.store(2);
	waiter.wakeup();

	joinThread(tid);
	assert(count.load() == 1000);
	assert(waiter.wakeupCount.load() == 0);
}
