module d.sync.kqueue.waiter;
version(OSX):

import d.sync.atomic;

import core.sys.darwin.sys.event;

import core.stdc.errno;
import core.stdc.stdint : uintptr_t;
import core.sys.posix.unistd : close;

struct KqueueWaiter {
	private int kq = -1;

	Atomic!uint wakeupCount;
	enum WaitingBit = 1u << 30;
	enum CountMask = WaitingBit - 1;

	/**
	 * Creates the kqueue used to park this thread if it doesn't exist
	 * yet, and registers the user event we use to wake up this waiter.
	 *
	 * Returns the kqueue descriptor, or -1 on failure.
	 */
	private int setupKqueue() nothrow @nogc {
		auto queue = this.kq;
		if (queue >= 0) {
			return queue;
		}

		queue = kqueue();
		if (queue < 0) {
			return -1;
		}

		kevent_t event;
		EV_SET(&event, cast(uintptr_t) &this, EVFILT_USER,
			EV_ADD | EV_CLEAR, 0, 0, null);

		if (kevent(queue, &event, 1, null, 0, null) != 0) {
			close(queue);
			return -1;
		}

		this.kq = queue;
		return queue;
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

			/**
			 * The kqueue must be registered before we publish that we
			 * are waiting, so any wake up which does not see the
			 * waiting bit is guaranteed to observe our counter.
			 */
			auto queue = (cast(KqueueWaiter*) &this).setupKqueue();
			assert(queue >= 0, "Failed to setup kqueue!");

			// Let everyone know we are about to wait.
			wakeupCount.fetchAdd(WaitingBit);

			if ((wakeupCount.load() & CountMask) != 0) {
				// A wake up arrived before we went to sleep.
				wakeupCount.fetchSub(WaitingBit);
				continue;
			}

			kevent_t event;
			auto n = kevent(queue, null, 0, &event, 1, null);
			if (n <= 0 && errno != EINTR) {
				assert(0, "kevent operation failed!");
			}

			wakeupCount.fetchSub(WaitingBit);
		}
	}

	void wakeup() shared {
		auto wuc = wakeupCount.fetchAdd(1);
		if ((wuc & CountMask) == 0) {
			poke();
		}
	}

	void poke() shared {
		auto queue = (cast(KqueueWaiter*) &this).kq;
		if (queue < 0) {
			/**
			 * The waiter did not publish its waiting bit yet, so it
			 * will consume our wake up at its pre-sleep check. If the
			 * bit was observed set by our caller, the kqueue was
			 * necessarily registered beforehand.
			 */
			return;
		}

		kevent_t event;
		EV_SET(&event, cast(uintptr_t) &this, EVFILT_USER,
			0, NOTE_TRIGGER, 0, null);

		auto err = kevent(queue, &event, 1, null, 0, null);
		assert(err == 0, "kevent operation failed!");
	}
}

@"kqueue wait" unittest {
	import symgc.test;
	import d.sync.atomic;
	shared Atomic!uint state;
	shared Atomic!uint count;
	shared KqueueWaiter waiter;
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
		assert((waiter.wakeupCount.load() & KqueueWaiter.CountMask) == 0);
	}
	assert(state.load() == 0);
	state.store(2);
	waiter.wakeup();

	joinThread(tid);
	assert(count.load() == 1000);
	assert(waiter.wakeupCount.load() == 0);
}
