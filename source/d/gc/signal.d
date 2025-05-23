module d.gc.signal;
version(linux):

import d.gc.tcache;
import d.gc.tstate;

import core.sys.posix.signal;

// Power failure imminent.
enum SIGPWR = 30;
// CPU time limit exceeded.
enum SIGXCPU = 24;

enum SIGSUSPEND = SIGPWR;
enum SIGRESUME = SIGXCPU;

void setupSignals() {
	sigaction_t action;
	initSuspendSigSet(&action.sa_mask);

	action.sa_flags = SA_RESTART | SA_SIGINFO;
	action.sa_sigaction = &__sd_gc_signal_suspend;

	if (sigaction(SIGSUSPEND, &action, null) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("Failed to set suspend handler!");
		exit(1);
	}

	action.sa_flags = SA_RESTART;
	action.sa_handler = &__sd_gc_signal_resume;

	if (sigaction(SIGRESUME, &action, null) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("Failed to set suspend handler!");
		exit(1);
	}
}

auto signalThreadSuspend(ThreadCache* tc) {
	tc.state.sendSuspendSignal();

	// TODO: Retry on EAGAIN and handle signal loss.
	return pthread_kill(tc.self, SIGSUSPEND);
}

auto signalThreadResume(ThreadCache* tc) {
	tc.state.sendResumeSignal();

	// TODO: Retry on EAGAIN and handle signal loss.
	return pthread_kill(tc.self, SIGRESUME);
}

void suspendThreadFromSignal(ThreadState* ts) {
	/**
	 * When we suspend from the signal handler, we do not need to call
	 * __sd_gc_push_registers. The context for the signal handler has
	 * been pushed on the stack, and it contains the values for all the
	 * registers.
	 * It is capital that the signal handler uses SA_SIGINFO for this.
	 *
	 * In addition, we do not need to mask the resume signal, because
	 * the signal handler should do that for us already.
	 */

	// TODO: we are currently using the stack shell just to get the stack top,
	// even though we already have the registers saved. This may be able to be
	// trimmed in the future, but scanning the registers twice isn't a huge
	// deal.
	import symgc.rt;
	void call(void* stackTop) {
		suspendThreadImpl(ts, stackTop);
	}
	__sd_gc_push_registers(&call);
}

void suspendThreadDelayedWithSignals(ThreadState* ts) {
	/**
	 * First, we make sure that a resume handler cannot be called
	 * before we suspend.
	 */
	sigset_t set, oldSet;
	initSuspendSigSet(&set);
	if (pthread_sigmask(SIG_BLOCK, &set, &oldSet) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("pthread_sigmask failed!");
		exit(1);
	}

	scope(exit) if (pthread_sigmask(SIG_SETMASK, &oldSet, null) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("pthread_sigmask failed!");
		exit(1);
	}

	/**
	 * Make sure to call __sd_gc_push_registers to make sure data
	 * in trash register will be scanned apropriately by the GC.
	 */
	import symgc.rt;
	void call(void* stackTop) {
		suspendThreadImpl(ts, stackTop);
	}
	__sd_gc_push_registers(&call);
}

private:

void initSuspendSigSet(sigset_t* set) {
	if (sigfillset(set) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("sigfillset failed!");
		exit(1);
	}

	/**
	 * The signals we want to allow while in the GC's signal handler.
	 */
	if (sigdelset(set, SIGINT) != 0 || sigdelset(set, SIGQUIT) != 0
		    || sigdelset(set, SIGABRT) != 0 || sigdelset(set, SIGTERM) != 0
		    || sigdelset(set, SIGSEGV) != 0 || sigdelset(set, SIGBUS) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("sigdelset failed!");
		exit(1);
	}
}

void suspendThreadImpl(ThreadState* ts, void* stackTop) {
	threadCache.stackTop = stackTop;
	scope(exit) threadCache.stackTop = null;

	import d.gc.hooks;
	__sd_gc_pre_suspend_hook(stackTop);
	scope(exit) __sd_gc_post_suspend_hook();

	ts.markSuspended();

	sigset_t set;
	initSuspendSigSet(&set);

	/**
	 * Suspend this thread's execution untill the resume signal is sent.
	 *
	 * We could stop all the thread by having them wait on a mutex,
	 * but we also want to ensure that we do not run code via signals
	 * while the thread is suspended, and the mutex solution is unable
	 * to provide that guarantee, so we use sigsuspend instead.
	 */
	if (sigdelset(&set, SIGRESUME) != 0) {
		import core.stdc.stdlib, core.stdc.stdio;
		printf("sigdelset failed!");
		exit(1);
	}

	// When the resume signal is recieved, the suspend state is updated.
	while (ts.suspendState == SuspendState.Suspended) {
		sigsuspend(&set);
	}
}

extern(C) void __sd_gc_signal_suspend(int sig, siginfo_t* info, void* context) {
	// Make sure errno is preserved.
	import core.stdc.errno;
	auto oldErrno = errno;
	scope(exit) errno = oldErrno;

	version(Symgc_pthread_hook) { }
	else {
		// Note: this fixup is only necessary in version 2.111 of the
		// compiler, where we do not have a thread startup hook for the GC.
		import core.thread;
		auto myThread = Thread.getThis();
		assert(myThread !is null);
		if (myThread.tlsGCData is null) {
			// need to store the tlsGCData, but also need to jump to the
			// signalled state, as this is what the main thread would have
			// done if it had access to our threadcache. This only happens
			// on the first suspend in the thread.
			import d.gc.tcache;
			threadCache.state.sendSuspendSignal();

			// now, store the pointer to the threadcache inside mythread.
			// After this point, GC cycles can directly access the
			// threadcache.
			myThread.tlsGCData = &threadCache;
		}
	}

	import d.gc.tcache;
	if (threadCache.state.onSuspendSignal()) {
		suspendThreadFromSignal(&threadCache.state);
	}
}

extern(C) void __sd_gc_signal_resume(int sig) {
	// Make sure errno is preserved.
	import core.stdc.errno;
	auto oldErrno = errno;
	scope(exit) errno = oldErrno;

	import d.gc.tcache;
	threadCache.state.onResumeSignal();
}
