module d.sync.futex.waiter;
version(linux):

import d.sync.atomic;
import d.sync.futex.futex;

import core.stdc.errno;

struct FutexWaiter {
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

			auto err = futex_wait(&wakeupCount, 0);
			switch (err) {
				case 0, -EINTR, -EWOULDBLOCK:
					continue;

				case -ETIMEDOUT:
					return false;

				default:
					assert(0, "futex operation failed!");
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
		auto err = futex_wake_one(&wakeupCount);
		assert(err == 0, "futex operation failed!");
	}
}

@"futex wait" unittest {
	import symgc.test;
	import d.sync.atomic;
	shared Atomic!uint state;
	shared Atomic!uint count;
	shared FutexWaiter waiter;
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
