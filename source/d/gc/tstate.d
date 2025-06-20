module d.gc.tstate;

import symgc.intrinsics;

enum SuspendState {
	// The thread is running as usual.
	None,
	// A signal has been sent to the thread that it'll need to suspend.
	Signaled,
	// The suspend was delayed, because the thread was busy.
	Delayed,
	// The thread is suspended.
	Suspended,
	// The thread is in the process of resuming operations.
	Resumed,
	// The thread cannot use the GC because a collect is happening.
	Probation,
	// The thread is detached. The GC won't stop it.
	Detached,
}

static auto status(size_t v) {
	enum StatusMask = ThreadState.BusyIncrement - 1;
	return cast(SuspendState) (v & StatusMask);
}

struct ThreadState {
private:
	import d.sync.atomic;
	shared Atomic!size_t state;

	import d.sync.mutex;
	shared Mutex busyWaitMutex;

	enum BusyIncrement = 0x08;

	enum RunningState = SuspendState.None;
	enum SignaledState = SuspendState.Signaled;
	enum SuspendedState = SuspendState.Suspended;
	enum DelayedState = SuspendState.Delayed;
	enum ResumedState = SuspendState.Resumed;
	enum ProbationState = SuspendState.Probation;

	enum MustSuspendState = BusyIncrement | SuspendState.Delayed;

public:
	@property
	auto suspendState() {
		return status(state.load());
	}

	@property
	bool busy() {
		return state.load() >= BusyIncrement;
	}

	void sendSuspendSignal() {
		auto s = state.load();
		while (true) {
			auto n = s + SuspendState.Signaled;

			assert(status(s) == SuspendState.None);
			assert(status(n) == SuspendState.Signaled);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	void detach() {
		auto s = state.load();
		while (true) {
			auto n = s - SuspendState.Signaled + SuspendState.Detached;

			assert(status(s) == SuspendState.Signaled);
			assert(status(n) == SuspendState.Detached);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	void preventPausing() {
		auto s = state.load();
		while (true) {
			auto n = s + SuspendState.Detached;

			assert(status(s) == SuspendState.None);
			assert(status(n) == SuspendState.Detached);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	bool onSuspendSignal() {
		auto s = state.load();

		while (true) {
			assert(status(s) == SuspendState.Signaled);

			// If the thread isn't busy, we can suspend
			// immediately.
			if (s == SignaledState) {
				return true;
			}

			// The thread is busy, delay suspension.
			auto n = s + SuspendState.Signaled;
			assert(status(n) == SuspendState.Delayed);

			if (state.casWeak(s, n)) {
				return false;
			}
		}
	}

	void sendResumeSignal() {
		auto s = state.load();
		while (true) {
			auto n = s + SuspendState.Signaled;

			assert(status(s) == SuspendState.Suspended);
			assert(status(n) == SuspendState.Resumed);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

	void onResumeSignal() {
		assert(state.load() == ResumedState);
		state.store(ProbationState);
	}

	void enterBusyState() {
		auto s = state.fetchAdd(BusyIncrement);
		assert(status(s) != SuspendState.Suspended);

		if (status(s) != ProbationState) {
			return;
		}

		// In Probation state, we need to wait until the GC cycle is done
		// before doing anything.
		busyWaitMutex.lock();
		scope(exit) busyWaitMutex.unlock();
		busyWaitMutex.waitFor(&offProbation);
	}

	bool exitBusyState() {
		size_t s = BusyIncrement;
		if (likely(state.casWeak(s, RunningState))) {
			return false;
		}

		return exitBusyStateSlow(s);
	}

	void clearProbationState() {
		size_t s = ProbationState;
		if (state.casWeak(s, RunningState)) {
			return;
		}

		// The thread has now tried to enter a busy state. Must use the
		// lock to to wake it up.
		busyWaitMutex.lock();
		scope(exit) busyWaitMutex.unlock();
		while (true) {
			enum BusyMask = ~(BusyIncrement - 1);
			auto n = s & BusyMask;

			assert(s >= BusyIncrement);
			assert(n >= BusyIncrement);
			assert(status(s) == ProbationState);
			assert(status(n) == RunningState);

			if (state.casWeak(s, n)) {
				break;
			}
		}
	}

package:
	void markSuspended() {
		// The status to delayed because of the fetchAdd in onSuspendSignal.
		auto s = state.load();
		assert(s == SignaledState || s == MustSuspendState);

		state.store(SuspendedState);
	}

private:
	bool offProbation() {
		auto s = state.load();
		assert(s >= BusyIncrement);
		return status(s) != ProbationState;
	}

	bool exitBusyStateSlow(size_t s) {
		while (true) {
			assert(s >= BusyIncrement);
			assert(status(s) != SuspendState.Suspended);

			if (s == MustSuspendState) {
				import d.gc.thread;
				suspendThreadDelayed(&this);

				return true;
			}

			if (state.casWeak(s, s - BusyIncrement)) {
				return false;
			}
		}
	}
}

@"busy" unittest {
	ThreadState s;

	void check(SuspendState ss, bool busy) {
		assert(s.suspendState == ss);
		assert(s.busy == busy);
	}

	// Check init state.
	check(SuspendState.None, false);

	void checkForState(SuspendState ss) {
		// Check simply busy/unbusy state transition.
		s.state.store(ss);
		check(ss, false);

		s.enterBusyState();
		check(ss, true);

		assert(!s.exitBusyState());
		check(ss, false);

		// Check nesting busy states.
		s.enterBusyState();
		s.enterBusyState();
		check(ss, true);

		assert(!s.exitBusyState());
		check(ss, true);

		assert(!s.exitBusyState());
		check(ss, false);
	}

	checkForState(SuspendState.None);
	checkForState(SuspendState.Signaled);
}
version(Posix)
@"suspend" unittest {
	import d.gc.signal;
	import symgc.test;
	setupSignals();

	// Make sure to use the state from the thread cache
	// so signal can find it back when needed.
	import d.gc.tcache;
	ThreadCache* tc = &threadCache;

	// Depending on the environement the thread runs in,
	// this may not have been initialized.
	import core.sys.posix.pthread;
	tc.self = pthread_self();

	version(Symgc_druntime_hooks) {
		import core.thread;
		// set the threadcache pointer in the current thread
		auto myThread = Thread.getThis();
		assert(myThread !is null);
		myThread.tlsGCData = tc;
	}

	ThreadState* s = &tc.state;
	scope(success) {
		assert(s.state.load() == 0, "Invalid leftover state!");
	}

	import d.sync.atomic;
	shared Atomic!uint resumeCount;
	shared Atomic!uint lockedProbationCount;

	import d.sync.mutex;
	shared Mutex mutex;
	uint step = 0;
	bool mustStop = false;

	void moveToNextStep() {
		mutex.lock();
		scope(exit) mutex.unlock();

		step++;
	}

	void setMustStop() {
		mutex.lock();
		scope(exit) mutex.unlock();

		mustStop = true;
	}

	bool waitForState(SuspendState state, bool needBusy) {
		// Wait for the main thread to progress to the given state.
		while (!mustStop && s.suspendState != state || (needBusy && !s.busy)) {
			// Make sure we leave the opportunity to update mustStop!
			mutex.unlock();
			scope(exit) mutex.lock();

			sched_yield();
		}

		return !mustStop;
	}

	void* autoResume() {
		mutex.lock();
		scope(exit) mutex.unlock();
		assert(step == 0, "Unexpected step when starting.");

		uint nextStep = 1;

		while (true) {
			if (!waitForState(SuspendState.Suspended, false)) {
				break;
			}

			// It is suspend, resume it.
			resumeCount.fetchAdd(1);

			import d.gc.signal;
			signalThreadResume(tc);

			// Wait for the next test.
			bool hasReachedNextStep() {
				return mustStop || step >= nextStep;
			}

			mutex.waitFor(&hasReachedNextStep);
			nextStep = step + 1;

			// If the probation state was skipped, we don't need to handle it here.
			if (s.suspendState != SuspendState.Probation) {
				continue;
			}

			// Wait for the probation state
			if (!waitForState(SuspendState.Probation, true)) {
				break;
			}

			// Locked on probation, clear the probation state.
			lockedProbationCount.fetchAdd(1);

			s.clearProbationState();

			mutex.waitFor(&hasReachedNextStep);
			nextStep = step + 1;
		}

		return null;
	}

	auto autoResumeThreadID = runThread(&autoResume);
	scope(exit) {
		setMustStop();

		joinThread(autoResumeThreadID);
	}

	void check(SuspendState ss, bool busy, uint suspendCount,
			uint probationCount) {
		assert(s.suspendState == ss);
		assert(s.busy == busy);
		assert(resumeCount.load() == suspendCount);
		assert(lockedProbationCount.load() == probationCount);
	}

	// Check init state.
	check(SuspendState.None, false, 0, 0);

	// Simple signal.
	s.sendSuspendSignal();
	check(SuspendState.Signaled, false, 0, 0);

	assert(s.onSuspendSignal());
	suspendThreadFromSignal(s);

	check(SuspendState.Probation, false, 1, 0);

	// Clear the probation
	s.clearProbationState();
	check(SuspendState.None, false, 1, 0);
	moveToNextStep();

	// Signal while busy.
	s.sendSuspendSignal();
	check(SuspendState.Signaled, false, 1, 0);

	s.enterBusyState();
	s.enterBusyState();
	check(SuspendState.Signaled, true, 1, 0);

	assert(!s.onSuspendSignal());
	check(SuspendState.Delayed, true, 1, 0);

	assert(!s.exitBusyState());
	check(SuspendState.Delayed, true, 1, 0);

	assert(s.exitBusyState());
	check(SuspendState.Probation, false, 2, 0);
	moveToNextStep();

	// Enter busy state while on probation
	s.enterBusyState();
	check(SuspendState.None, true, 2, 1);

	assert(!s.exitBusyState());
	check(SuspendState.None, false, 2, 1);
	moveToNextStep();
}

version(Windows)
@"suspend" unittest {
	import symgc.test;
	import d.gc.thread;

	import d.gc.tcache;
	ThreadState s;
	scope(success) {
		assert(s.state.load() == 0, "Invalid leftover state!");
	}

	import d.sync.atomic;
	shared Atomic!uint resumeCount;
	shared Atomic!uint lockedProbationCount;

	import d.sync.mutex;
	shared Mutex mutex;
	uint step = 0;
	bool mustStop = false;

	void moveToNextStep() {
		mutex.lock();
		scope(exit) mutex.unlock();

		step++;
	}

	void setMustStop() {
		mutex.lock();
		scope(exit) mutex.unlock();

		mustStop = true;
	}

	bool waitForState(SuspendState state, bool needBusy) {
		// Wait for the main thread to progress to the given state.
		while (!mustStop && s.suspendState != state || (needBusy && !s.busy)) {
			// Make sure we leave the opportunity to update mustStop!
			mutex.unlock();
			scope(exit) mutex.lock();

			sched_yield();
		}

		return !mustStop;
	}

	void* autoResume() {
		mutex.lock();
		scope(exit) mutex.unlock();
		assert(step == 0, "Unexpected step when starting.");

		uint nextStep = 1;

		// Wait for the next test.
		bool hasReachedNextStep() {
			return mustStop || step >= nextStep;
		}

		while (!mustStop) {
			// Wait for the main thread to be in a delayed state.
			waitForState(SuspendState.Delayed, false);

			delayedThreadInc();

			waitForDelayedThreads();

			// simulate suspending and then resuming.
			s.markSuspended();

			resumeCount.fetchAdd(1);

			s.sendResumeSignal();

			s.onResumeSignal();

			simulateResumeTheWorld();

			mutex.waitFor(&hasReachedNextStep);
			nextStep = step + 1;

			// If the probation state was skipped, we don't need to handle it here.
			if (s.suspendState != SuspendState.Probation) {
				continue;
			}

			// Wait for the probation state
			if (!waitForState(SuspendState.Probation, true)) {
				break;
			}

			// Locked on probation, clear the probation state.
			lockedProbationCount.fetchAdd(1);

			s.clearProbationState();

			mutex.waitFor(&hasReachedNextStep);
			nextStep = step + 1;
		}

		return null;
	}

	auto autoResumeThreadID = runThread(&autoResume);
	scope(exit) {
		setMustStop();

		joinThread(autoResumeThreadID);
	}

	void check(SuspendState ss, bool busy, uint suspendCount,
	uint probationCount) {
		assert(s.suspendState == ss);
		assert(s.busy == busy);
		assert(resumeCount.load() == suspendCount);
		assert(lockedProbationCount.load() == probationCount);
	}

	// Check init state.
	check(SuspendState.None, false, 0, 0);

	// Simple signal.
	s.sendSuspendSignal();
	check(SuspendState.Signaled, false, 0, 0);

	assert(s.onSuspendSignal());
	s.markSuspended();
	check(SuspendState.Suspended, false, 0, 0);

	s.sendResumeSignal();
	check(SuspendState.Resumed, false, 0, 0);

	s.onResumeSignal();

	check(SuspendState.Probation, false, 0, 0);
	s.clearProbationState();
	check(SuspendState.None, false, 0, 0);

	// Signal while busy.
	s.enterBusyState();
	s.enterBusyState();
	check(SuspendState.None, true, 0, 0);

	simulateStopTheWorld();

	s.sendSuspendSignal();
	check(SuspendState.Signaled, true, 0, 0);

	assert(!s.onSuspendSignal());
	check(SuspendState.Delayed, true, 0, 0);

	assert(!s.exitBusyState());
	check(SuspendState.Delayed, true, 0, 0);

	assert(s.exitBusyState());
	check(SuspendState.Probation, false, 1, 0);
	moveToNextStep();

	// try entering a busy state while in probation.
	s.enterBusyState();
	check(SuspendState.None, true, 1, 1);
	assert(!s.exitBusyState());

	check(SuspendState.None, false, 1, 1);
}
