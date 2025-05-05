module d.sync.win32.waiter;

version(Windows):

pragma(lib, "synchronization.lib");

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

	bool block( /* TODO: timeout */ ) shared {
		while (true) {
			auto c = wakeupCount.load();
			while (c > 0) {
				if (wakeupCount.casWeak(c, c - 1)) {
					// We consumed a wake up.
					return true;
				}
			}

			assert(c == 0, "Failed to consume wake up!");

			auto err = WaitOnAddress(cast(void*)&wakeupCount, &c, c.sizeof, INFINITE);
			if (!err) {
				// TODO: if timeout ever gets implemented, check here.
				assert(0, "WaitOnAddress operation failed!");
			}
		}
	}

	void wakeup() shared {
		auto wuc = wakeupCount.fetchAdd(1);
		if (wuc == 0) {
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
			auto st = state.load();
			while(st == 0)
			{
				waiter.block();
				st = state.load();
			}
			if(st == 2)
				break;
			assert(st == 1);
			state.casWeak(st, 0);
			count.fetchAdd(1);
		}
		return null;
	}

	auto tid = runThread(&run);
	foreach(i; 0 .. 10)
	{
		assert(state.load() == 0);
		state.store(1);
		waiter.wakeup();

		while(state.load() == 1)
		{
			import core.thread;
			Thread.yield();
		}
	}
	assert(state.load() == 0);
	state.store(2);
	waiter.wakeup();

	joinThread(tid);
	assert(count.load() == 10);
	assert(waiter.wakeupCount.load() == 0);
}
