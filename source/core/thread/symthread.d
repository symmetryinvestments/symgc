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
	// TODO: wish this was package...
	alias core_thread_osthread_suspend =
		externDFunc!("core.thread.osthread.suspend", bool function(Thread) nothrow @nogc);
	alias core_thread_osthread_resume =
		externDFunc!("core.thread.osthread.resume", void function(ThreadBase) nothrow @nogc);
}

private Thread toThread(return scope ThreadBase t) @trusted nothrow @nogc pure
{
	return cast(Thread) cast(void*) t;
}

struct ThreadIterator
{
	this(Thread start)
	{
		self = Thread.getThis;
		tn = start;
		popFront();
	}

	Thread t;
	Thread tn;
	Thread self;
	bool empty() => t is null;
	Thread front() => t;
	void popFront()
	{
		t = tn;
		while (t !is null) {

			if(t is self)
			{
				t = t.next.toThread;
				continue;
			}

			if (!t.isRunning())
			{
				auto nextThread = t.next.toThread;
				Thread.remove(t);
				t = nextThread;
				continue;
			}

			this.tn = t.next.toThread;
			return;
		}

		// here if t is now null.
		this.tn = null;
	}
}

bool suspendDruntimeThreads(bool alwaysSignal, ref uint suspended) {
	import d.gc.tcache;
	import d.gc.tstate;

	suspended = 0;
	bool retry = false;

	foreach(t; ThreadIterator(ThreadBase.sm_tbeg.toThread))
	{
		auto tc = cast(ThreadCache*) t.tlsGCData();

		version (Posix)
		{
			// determine if this thread is suspended or should be suspended.
			if (tc !is null)
			{
				auto ss = tc.suspendState;

				suspended += ss == SuspendState.Suspended;
				retry |= ss != SuspendState.Suspended;

				if (ss != SuspendState.None)
					continue;

				tc.sendSuspendSignal();
				// use druntime suspension calls.
				core_thread_osthread_suspend(t);
			}
			else
			{
				// TODO: remove this code, once we have guarantees the tls gc data
				// is always initialized when attaching a thread.
				retry = true;
				if (alwaysSignal)
				{
					// send the signal directly, this is the first time through the
					// loop. The thread signal handler will register the
					// threadcache data for subsequent collections and loops
					core_thread_osthread_suspend(t);
				}
			}
		}
		else version(Windows)
		{
			if (tc is null) {
				assert(0, "tlsGCData was not set for this thread!");
			}

			// use the same states to make the code consistent.
			tc.sendSuspendSignal();

			if (core_thread_osthread_suspend(t)) {
				if (tc.onSuspendSignal()) {
					tc.markSuspended();
					++suspended;
					continue;
				}

				// Could not suspend, handle a delayed suspend
				import d.gc.thread : delayedThreadInc;
				delayedThreadInc();
				// delayed, resume the thread, and increment the delayed thread count.
				core_thread_osthread_resume(t);
				retry = true;
			}
		}
		else static assert(false);
	}

	version(Windows) if (retry) {
		// in this case, retry means some threads were delayed. need to wait for them,
		// we are not going to return until all threads are suspended.
		retry = false;
		// wait for all delayed threads to be ready for suspension
		import d.gc.thread : waitForDelayedThreads;
		waitForDelayedThreads();
		foreach(t; ThreadIterator(ThreadBase.sm_tbeg.toThread))
		{
			auto tc = cast(ThreadCache*) t.tlsGCData();
			assert (tc !is null); // not possible at this point.
			if (tc.suspendState != SuspendState.Suspended) {
				if (!core_thread_osthread_suspend(t)) {
					assert(0, "could not suspend thread");
				}
				tc.markSuspended();
				++suspended;
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

	suspended = 0;
	bool retry = false;

	foreach(t; ThreadIterator(ThreadBase.sm_tbeg.toThread))
	{
		auto tc = cast(ThreadCache*) t.tlsGCData();

		if (tc is null) {
			// if the threadcache is null, this means we didn't suspend it. skip it.
			continue;
		}

		auto ss = tc.suspendState;

		version(Posix) {
			suspended += ss == SuspendState.Suspended;
			retry |= ss != SuspendState.None;

			if (ss != SuspendState.Suspended)
				continue;

			tc.sendResumeSignal();
		} else version(Windows) {
			// Since there is no signal processing on the target thread, we need to
			// do the step that sets the state properly from here.
			if (ss != SuspendState.Suspended)
				continue;

			tc.sendResumeSignal();
			tc.onResumeSignal();
		}
		else static assert(false);
		core_thread_osthread_resume(t);
	}

	// update the suspended count
	suspendDepth = suspended;
	return retry;
}
