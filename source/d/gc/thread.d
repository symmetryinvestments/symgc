module d.gc.thread;

import d.gc.capi;
import d.gc.tcache;
import d.gc.tstate;
import d.gc.types;

void createProcess() {
	import d.gc.base;
	import d.gc.arena;
	import d.gc.emap;
	Arena.initializeArenaStorage(gBase);
	gExtentMap.initialize(gBase);

	enterBusyState();
	scope(exit) exitBusyState();

	version(linux) {
		import d.gc.fork;
		setupFork();

		import d.gc.signal;
		setupSignals();
	}
	initThread();

	version(Symgc_pthread_hook) {
		import d.gc.hooks;
		__sd_gc_register_global_segments();

		import symgc.rt;
		registerTlsSegments();
	}
}

void createThread(bool AllowStopTheWorld)() {
	enterBusyState();
	scope(exit) {
		if (AllowStopTheWorld) {
			allowStopTheWorld();
		}

		exitBusyState();
	}

	initThread();

	version(Symgc_pthread_hook) {
		import symgc.rt;
		registerTlsSegments();
	}
}

void destroyThread() {
	/**
	 * Note: we are about to remove the thread from the active thread
	 * list, we do not want to suspend, because the thread will never be
	 * woken up. Therefore -- no exitBusyState.
	 */
	enterBusyState();

	threadCache.destroyThread();

	version(Symgc_pthread_hook) {
		gThreadState.remove(&threadCache);
	}
}

void preventStopTheWorld() {
	gThreadState.preventStopTheWorld();
}

void allowStopTheWorld() {
	gThreadState.allowStopTheWorld();
}

uint getRegisteredThreadCount() {
	return gThreadState.getRegisteredThreadCount();
}

uint getSuspendedThreadCount() {
	return gThreadState.getSuspendedThreadCount();
}

uint getRunningThreadCount() {
	return gThreadState.getRunningThreadCount();
}

void enterBusyState() {
	threadCache.state.enterBusyState();
}

void exitBusyState() {
	threadCache.state.exitBusyState();
}

void stopTheWorld() {
	gThreadState.stopTheWorld();
}

void restartTheWorld() {
	gThreadState.restartTheWorld();
}

void clearWorldProbation() {
	gThreadState.clearWorldProbation();
}

void suspendThreadDelayed(d.gc.tstate.ThreadState* tstate) {
	version(linux) {
		import d.gc.signal : suspendThreadDelayedWithSignals;
		suspendThreadDelayedWithSignals(tstate);
	} else version(Windows) {
		gThreadState.suspendThreadDelayedNoSignals(tstate);
	}
}

void delayedThreadInc() {
	gThreadState.delayedThreadInc();
}

void waitForDelayedThreads() {
	gThreadState.waitForDelayedThreads();
}

version(Symgc_testing) {
	void simulateStopTheWorld() {
		gThreadState.stopTheWorldLock.exclusiveLock();
	}

	void simulateResumeTheWorld() {
		gThreadState.stopTheWorldLock.exclusiveUnlock();
	}
}

void threadScan(ScanDg scan) {
	// Scan the registered TLS segments.
	foreach (s; threadCache.tlsSegments) {
		scan(s);
	}

	import d.gc.stack;
	scanStack(scan);
}

void scanSuspendedThreads(ScanDg scan) {
	gThreadState.scanSuspendedThreads(scan);
}

private:

void initThread() {
	assert(threadCache.state.busy, "Thread is not busy!");

	import d.gc.emap, d.gc.base;
	threadCache.initialize(&gExtentMap, &gBase);
	threadCache.activateGC();

	version(Symgc_pthread_hook) {
		import d.gc.global;
		gThreadState.register(&threadCache);
	}
}

struct ThreadState {
private:
	import d.sync.mutex;
	shared Mutex mStats;

	uint registeredThreadCount = 0;
	uint suspendedThreadCount = 0;
	int delayedThreadCount = 0;

	Mutex mThreadList;
	ThreadRing registeredThreads;

	import d.sync.sharedlock;
	shared SharedLock stopTheWorldLock;

	// delayed suspend lock is used to synchronize when the delayed suspend
	// should continue on systems without signals. This is locked when
	// suspending the world exclusively, and then unlocked when the delayed
	// threads should continue.
	// NOTE: we can probably merge STW lock and this lock once we remove
	// support for the pthread hook.
	shared SharedLock delayedSuspendLock;

public:
	/**
	 * Stop the world prevention.
	 */
	void preventStopTheWorld() shared {
		stopTheWorldLock.sharedLock();
	}

	void allowStopTheWorld() shared {
		stopTheWorldLock.sharedUnlock();
	}

	/**
	 * Thread management.
	 */
	void register(ThreadCache* tcache) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).registerImpl(tcache);
	}

	void remove(ThreadCache* tcache) shared {
		mThreadList.lock();
		scope(exit) mThreadList.unlock();

		(cast(ThreadState*) &this).removeImpl(tcache);
	}

	auto getRegisteredThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		return (cast(ThreadState*) &this).registeredThreadCount;
	}

	auto getSuspendedThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		return (cast(ThreadState*) &this).suspendedThreadCount;
	}

	auto getRunningThreadCount() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		auto state = cast(ThreadState*) &this;
		return state.registeredThreadCount - state.suspendedThreadCount;
	}

	void stopTheWorld() shared {
		import d.gc.hooks;
		__sd_gc_pre_stop_the_world_hook();

		// Prevent any new threads from being created
		stopTheWorldLock.exclusiveLock();

		// get ready for delayed threads that use the lock for synchronization.
		delayedSuspendLock.exclusiveLock();

		uint count;

		while (suspendRunningThreads(count++)) {
			import symgc.thread;
			sched_yield();
		}
	}

	void delayedThreadDec() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		*(cast(uint*)&this.delayedThreadCount) -= 1;
	}

	void delayedThreadInc() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		*(cast(uint*)&this.delayedThreadCount) += 1;
	}

	void waitForDelayedThreads() shared {
		mStats.lock();
		scope(exit) mStats.unlock();

		mStats.waitFor(
			&(cast(ThreadState*)&this).noDelayedThreads
		);
	}

	bool noDelayedThreads() => delayedThreadCount == 0;

	void suspendThreadDelayedNoSignals(d.gc.tstate.ThreadState* tstate) shared {
		// We are no longer delayed, can be suspended
		delayedThreadDec();

		// finally, lock the delayed shared lock, which will be held by the GC
		// runner until we are allowed to restart.
		delayedSuspendLock.sharedLock();
		assert(tstate.suspendState() == SuspendState.None);
		delayedSuspendLock.sharedUnlock();
	}

	void restartTheWorld() shared {
		while (resumeSuspendedThreads()) {
			import symgc.thread;
			sched_yield();
		}
	}

	void clearWorldProbation() shared {
		// Allow thread creation again.
		stopTheWorldLock.exclusiveUnlock();

		version(Symgc_pthread_hook) {
			mThreadList.lock();
			scope(exit) mThreadList.unlock();
		}

		(cast(ThreadState*) &this).clearWorldProbationImpl();

		// allow any threads that have called suspendThreadDelayedNoSignals to
		// continue.
		delayedSuspendLock.exclusiveUnlock();

		import d.gc.hooks;
		__sd_gc_post_restart_the_world_hook();
	}

	void scanSuspendedThreads(ScanDg scan) shared {
		assert(stopTheWorldLock.count == SharedLock.Exclusive);

		version(Symgc_pthread_hook) {
			mThreadList.lock();
			scope(exit) mThreadList.unlock();
		}

		(cast(ThreadState*) &this).scanSuspendedThreadsImpl(scan);
	}

private:
	void registerImpl(ThreadCache* tcache) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		{
			mStats.lock();
			scope(exit) mStats.unlock();
			registeredThreadCount++;
		}

		registeredThreads.insert(tcache);
	}

	void removeImpl(ThreadCache* tcache) {
		assert(mThreadList.isHeld(), "Mutex not held!");

		{
			mStats.lock();
			scope(exit) mStats.unlock();
			registeredThreadCount--;
		}

		registeredThreads.remove(tcache);
	}

	version(Symgc_pthread_hook) {
		bool suspendRunningThreads(uint count) shared {
			mThreadList.lock();
			scope(exit) mThreadList.unlock();

			return (cast(ThreadState*) &this).suspendRunningThreadsImpl(count);
		}

		bool suspendRunningThreadsImpl(uint count) {
			assert(mThreadList.isHeld(), "Mutex not held!");

			bool retry = false;
			uint suspended = 0;

			auto r = registeredThreads.range;
			while (!r.empty) {
				auto tc = r.front;
				scope(success) r.popFront();

				// Make sure we do not self suspend!
				if (tc is &threadCache) {
					continue;
				}

				// If the thread isn't already stopped, we'll need to retry.
				auto ss = tc.state.suspendState;
				if (ss == SuspendState.Detached) {
					continue;
				}

				// If a thread is detached, stop trying.
				if (count > 32 && ss == SuspendState.Signaled) {
					import d.gc.proc;
					if (isDetached(tc.tid)) {
						tc.state.detach();
						continue;
					}
				}

				suspended += ss == SuspendState.Suspended;
				retry |= ss != SuspendState.Suspended;

				// If the thread has already been signaled.
				if (ss != SuspendState.None) {
					continue;
				}

				import d.gc.signal;
				signalThreadSuspend(tc);
			}

			mStats.lock();
			scope(exit) mStats.unlock();

			suspendedThreadCount = suspended;
			return retry;
		}

		bool resumeSuspendedThreads() shared {
			mThreadList.lock();
			scope(exit) mThreadList.unlock();

			return (cast(ThreadState*) &this).resumeSuspendedThreadsImpl();
		}

		bool resumeSuspendedThreadsImpl() {
			assert(mThreadList.isHeld(), "Mutex not held!");

			bool retry = false;
			uint suspended = 0;

			auto r = registeredThreads.range;
			while (!r.empty) {
				auto tc = r.front;
				scope(success) r.popFront();

				// No need to resume our own thread!
				if (tc is &threadCache) {
					continue;
				}

				// If the thread isn't already resumed, we'll need to retry.
				auto ss = tc.state.suspendState;
				if (ss == SuspendState.Detached) {
					continue;
				}

				suspended += ss == SuspendState.Suspended;
				retry |= ss != SuspendState.Probation;

				// If the thread isn't suspended, move on.
				if (ss != SuspendState.Suspended) {
					continue;
				}

				import d.gc.signal;
				signalThreadResume(tc);
			}

			mStats.lock();
			scope(exit) mStats.unlock();

			suspendedThreadCount = suspended;
			return retry;
		}

		void scanSuspendedThreadsImpl(ScanDg scan) {
			assert(mThreadList.isHeld(), "Mutex not held!");

			auto r = registeredThreads.range;
			while (!r.empty) {
				auto tc = r.front;
				scope(success) r.popFront();

				// If the thread isn't suspended, move on.
				auto ss = tc.state.suspendState;
				if (ss != SuspendState.Suspended && ss != SuspendState.Detached) {
					continue;
				}

				// Scan the registered TLS segments.
				foreach (s; tc.tlsSegments) {
					scan(s);
				}

				// Only suspended thread have their stack properly set.
				// For detached threads, we just hope nothing's in there.
				if (ss == SuspendState.Suspended) {
					import d.gc.range;
					scan(makeRange(tc.stackTop, tc.stackBottom));
				}
			}

			version(Symgc_druntime_hooks) {
				// also scan using the druntime mechanisms. This scans some
				// extra things we aren't looking at here.
				import core.thread.symthread;
				scanWorldPausedData(scan);
			}
		}

		void clearWorldProbationImpl() {
			assert(mThreadList.isHeld(), "Mutex not held!");

			auto r = registeredThreads.range;
			while (!r.empty) {
				auto tc = r.front;
				scope(success) r.popFront();

				auto ss = tc.state.suspendState;
				if (ss != SuspendState.Probation) {
					continue;
				}

				tc.state.clearProbationState();
			}
		}

	} else {
		bool suspendRunningThreads(uint count) shared {
			// We are going to use druntime's thread list to iterate over
			// threads that should be suspended. The pre hook should have
			// locked the slock. If count is 0, we will send signals to threads
			// that do not have their tlsgcdata set. This means they have never
			// been stopped before, and so their tstate should be none
			// (possibly busy). The suspend signal handler should update the
			// pointer.

			import core.thread.symthread;
			uint suspended = 0;

			auto retry = suspendDruntimeThreads(count == 0, suspended);

			mStats.lock();
			scope(exit) mStats.unlock();

			suspendedThreadCount = suspended;
			return retry;
		}

		bool resumeSuspendedThreads() shared {
			import core.thread.symthread;

			uint suspended = 0;

			auto retry = resumeDruntimeThreads(suspended);

			mStats.lock();
			scope(exit) mStats.unlock();

			suspendedThreadCount = suspended;
			return retry;
		}

		void scanSuspendedThreadsImpl(ScanDg scan) {
			// use our specialized druntime function
			import core.thread.symthread;
			scanWorldPausedData(scan);
		}

		void clearWorldProbationImpl() {
			import core.thread.symthread;
			clearDruntimeThreadProbation();
		}
	}
}

shared ThreadState gThreadState;
