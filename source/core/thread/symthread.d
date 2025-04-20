// we have to put this in the core.thread package to access thread package internals
module core.thread.symthread;
import core.thread.osthread;
import core.thread.threadbase;
import core.thread.types;
import d.gc.types;

private {
    import core.internal.traits : externDFunc;
    alias DruntimeScanDg = void delegate(void* pstart, void* pend) nothrow;
    alias rt_tlsgc_scan =
        externDFunc!("rt.tlsgc.scan", void function(void*, scope DruntimeScanDg) nothrow);
}

private Thread toThread(return scope ThreadBase t) @trusted nothrow @nogc pure
{
    return cast(Thread) cast(void*) t;
}

bool suspendDruntimeThreads(bool alwaysSignal, ref uint suspended) {
	import d.gc.tcache;
	import d.gc.tstate;
	Thread t = ThreadBase.sm_tbeg.toThread;
	auto self = Thread.getThis;

	suspended = 0;
	bool retry = false;

	while (t)
	{
		auto tn = t.next.toThread;
		scope(exit) t = tn;
		if (!t.isRunning)
		{
			Thread.remove(t);
			continue;
		}

		// skip current thread, we don't need to suspend it.
		if (t is self) {
			continue;
		}

		auto tc = cast(ThreadCache*) t.tlsGCData();
		// determine if this thread is suspended or should be suspended.
		if (tc !is null) {
			auto ss = tc.suspendState;

			suspended += ss == SuspendState.Suspended;
			retry |= ss != SuspendState.Suspended;

			if (ss != SuspendState.None)
				continue;

			import d.gc.signal;
			signalThreadSuspend(tc);
		}
		else {
			retry = true;
			if(alwaysSignal) {
				// send the signal directly, this is the first time through the
				// loop. The thread signal handler will register the
				// threadcache data for subsequent collections and loops
				import d.gc.signal;
				import core.sys.posix.pthread;
				pthread_kill(t.m_addr, SIGSUSPEND);
			}
		}
	}

	// suspend all the threads that are not us, but also record that we suspended "ourself"
	suspendDepth = suspended + 1;
	return retry;
}

void scanWorldPausedData(ScanDg scan) {
	// scan all data that is NOT part of our thread's current stack.
	auto myStackBottom = Thread.getThis().m_curr.bstack;
	void scanItem(ScanType type, void* pbot, void* ptop) nothrow {
		import d.gc.range;
		auto r = makeRange(pbot, ptop);
		if (type == ScanType.stack && myStackBottom >= r.ptr &&
				myStackBottom <= r.ptr + r.length)
			// my stack range, no need to scan right now, this will be scanned later
			return;
		// TODO: ignore my thread's TLS data as well.
		// TODO: shouldn't need this cast
		alias NoThrowScanDg = void delegate(const(void*)[] range) nothrow;
		(cast(NoThrowScanDg)scan)(r);
	}

	thread_scanAllType(&scanItem);
}

bool resumeDruntimeThreads(ref uint suspended) {
	import d.gc.tcache;
	import d.gc.tstate;
	Thread t = ThreadBase.sm_tbeg.toThread;

	suspended = 0;
	bool retry = false;

	while (t)
	{
		auto tn = t.next.toThread;
		scope(exit) t = tn;
		if (!t.isRunning)
		{
			Thread.remove(t);
			continue;
		}

		auto tc = cast(ThreadCache*) t.tlsGCData();
		// determine if this thread is suspended or should be suspended.
		if (tc is null) {
			// if the threadcache is null, this means we didn't suspend it. skip it.
			continue;
		}

		auto ss = tc.suspendState;

		suspended += ss == SuspendState.Suspended;
		retry |= ss != SuspendState.None;

		if (ss != SuspendState.Suspended)
			continue;

		import d.gc.signal;
		signalThreadResume(tc);
	}

	// update the suspended count
	suspendDepth = suspended;
	return retry;
}
