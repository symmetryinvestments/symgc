module d.sync.win32.waiter;

version(Windows):

pragma(lib, "synchronization");

import d.sync.atomic;

import core.stdc.errno;

import core.sys.windows.windows;

extern(Windows) {
	bool WaitOnAddress(
		VOID* Address,
		PVOID CompareAddress,
		SIZE_T AddressSize,
		DWORD dwMilliseconds
	);

	void WakeByAddressSingle(
		PVOID Address
	);

	void WakeByAddressAll(
		PVOID Address
	);
}

struct Win32Waiter {
	Atomic!uint wakeupCount;
	enum WaitingBit = 1u << 30;
	enum GCBusyBit = 1u << 31;
	enum CountMask = WaitingBit - 1;

	// this should be called ONLY with the thread paused.
	bool setGCBusy() shared {
		auto b = wakeupCount.fetchAdd(GCBusyBit);
		return (b & WaitingBit) ? true : false;
	}

	void clearGCBusy() shared {
		auto oldval = wakeupCount.fetchSub(GCBusyBit);
		assert(oldval & GCBusyBit, "GCBusy bit was not set!");
	}

	bool block( /* TODO: timeout */ ) shared {
		while (true) {
			auto c = wakeupCount.load();
			while ((c & CountMask) > 0) {
				if (wakeupCount.casWeak(c, c - 1)) {
					// We consumed a wake up.
					return true;
				}
			}

			assert((c & CountMask) == 0, "Failed to consume wake up!");

			c += WaitingBit;
			wakeupCount.fetchAdd(WaitingBit); // let everyone know we are waiting
			auto err = WaitOnAddress(cast(void*)&wakeupCount, &c, c.sizeof, INFINITE);
			if (!err) {
				// TODO: if timeout ever gets implemented, check here.
				assert(0, "WaitOnAddress operation failed!");
			}
			c = wakeupCount.fetchSub(WaitingBit);

			if(c & GCBusyBit) {
				// GC asked us to pause, wait on the GC event
				import d.gc.thread;
				waitForGCBusy();
			}
		}
	}

	void wakeup() shared {
		auto wuc = wakeupCount.fetchAdd(1);
		if ((wuc & CountMask) == 0) {
			poke();
		}
	}

	void poke() shared {
		WakeByAddressSingle(cast(void*)&wakeupCount);
	}
}

@"win32 wait" unittest {
	import symgc.test;
	import d.sync.atomic;
	shared Atomic!uint state;
	shared Atomic!uint count;
	shared Win32Waiter waiter;
	void *run() {
		while(true)
		{
			waiter.block();
			auto st = state.load();
			if(st == 2)
				break;
			assert(st == 1);
			state.casWeak(st, 0);
			count.fetchAdd(1);
		}
		return null;
	}

	auto tid = runThread(&run);
	foreach(i; 0 .. 1000)
	{
		assert(state.load() == 0);
		state.store(1);
		waiter.wakeup();

		while(state.load() == 1)
		{
			import core.thread;
			Thread.yield();
		}
		assert((waiter.wakeupCount.load() & Win32Waiter.CountMask) == 0);
	}
	assert(state.load() == 0);
	state.store(2);
	waiter.wakeup();

	joinThread(tid);
	assert(count.load() == 1000);
	assert(waiter.wakeupCount.load() == 0);
}
