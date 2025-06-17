module symgc.thread;

version(Windows) {
	import core.sys.windows.winnt : HANDLE;
	import core.sys.windows.windef : DWORD;
	import core.sys.windows.winbase;
	alias currentThreadHandle = GetCurrentThread;
	alias sched_yield = SwitchToThread;
	alias ThreadHandle = HANDLE;
	private enum THREAD_RETURN_VALUE = DWORD(0);
	extern (C) ThreadHandle _beginthreadex(void*, uint, LPTHREAD_START_ROUTINE, void*, uint, uint*) nothrow @nogc;
} else version(linux) {
	import core.sys.posix.pthread : pthread_t, pthread_self;
	alias ThreadHandle = pthread_t;
	alias currentThreadHandle = pthread_self;
	public import core.sys.posix.sched: sched_yield;
	private enum THREAD_RETURN_VALUE = null;
}

import d.gc.thread;

bool createGCThread(TSR)(ThreadHandle* thread, TSR start_routine, void* arg) {
	auto runner = allocThreadRunner(start_routine, arg);
	return createGCThread(thread, runner);
}

/**
 * Create a GC thread that does not prevent stop the world (or block waiting for world stopping to finish)
 */
bool createGCThread(TSR)(ThreadHandle* thread, ThreadRunner!TSR*  runner) {
	version(linux) {
		alias OSThreadRoutine = extern(C) void* function(void*);
		version(Symgc_pthread_hook) {
			// use the trampoline as the thread create function
			import symgc.trampoline : start_thread = pthread_create_trampoline;
		}
		else {
			// no trampoline, just use the normal pthread_create
			import core.sys.posix.pthread : start_thread = pthread_create;
		}
		auto ret = start_thread(
			thread, null, cast(OSThreadRoutine) runner.getFunction!true(), runner);
		return ret == 0;
	} else version(Windows) {
		import core.sys.windows.winbase : LPTHREAD_START_ROUTINE, CreateThread, INVALID_HANDLE_VALUE;
		*thread = _beginthreadex(null, 0, cast(LPTHREAD_START_ROUTINE) runner.getFunction!true(), runner, 0, null);
		return *thread != INVALID_HANDLE_VALUE;
	}
}

void joinGCThread(ThreadHandle tid) {
	version(linux) {
		import core.sys.posix.pthread;
		void* result;
		pthread_join(tid, &result);
	}
	else version(Windows) {
		if (WaitForSingleObject(tid, INFINITE) != WAIT_OBJECT_0) {
			assert(false, "Failed to join thread");
		}
		uint result;
		GetExitCodeThread(tid, &result);
		CloseHandle(tid);
	}
}

struct ThreadRunner(TSR) {
	void* arg;
	TSR fun;

	static getFunction(bool BackgroundThread)()
	{
		return &runThread!(BackgroundThread, typeof(this));
	}
}

package:

ThreadRunner!TSR* allocThreadRunner(TSR)(TSR fun, void* arg) {
	alias TRType = ThreadRunner!TSR;
	import d.gc.capi : __sd_gc_alloc;
	auto runner = cast(TRType*)__sd_gc_alloc(TRType.sizeof);
	runner.fun = fun;
	runner.arg = arg;
	return runner;
}

extern(C) void _d_print_throwable(Throwable t);

extern(C) auto runThread(bool BackgroundThread, TRunner)(TRunner* runner) {
	import d.gc.capi : __sd_gc_free;
	import d.gc.thread : createThread, destroyThread;

	auto fun = runner.fun;
	auto arg = runner.arg;

	try {
		createThread!BackgroundThread();
		static if(!BackgroundThread) __sd_gc_free(runner);

		// Make sure we clean up after ourselves.
		scope(exit) destroyThread();

		// If the passed in function returns void, give a valid return to the OS
		// function.
		static if(is(typeof(fun(arg)) == void))
		{
			fun(arg);
			return THREAD_RETURN_VALUE;
		}
		else
		{
			return fun(arg);
		}
	} catch(Throwable t) {
		// print the throwable
		_d_print_throwable(t);
	}

	return THREAD_RETURN_VALUE;
}
