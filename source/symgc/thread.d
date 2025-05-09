module symgc.thread;

version(Windows) {
	import core.sys.windows.winnt : HANDLE;
	import core.sys.windows.windef : DWORD;
	public import core.sys.windows.winbase : currentThreadHandle = GetCurrentThread;
	alias ThreadHandle = HANDLE;
	private enum THREAD_RETURN_VALUE = DWORD(0);
} else version(linux) {
	import core.sys.posix.pthread : pthread_t, pthread_self;
	alias ThreadHandle = pthread_t;
	alias currentThreadHandle = pthread_self;
	private enum THREAD_RETURN_VALUE = null;
}

version(linux):

import d.gc.thread;

/**
 * Create a GC thread that does not prevent stop the world (or block waiting for world stopping to finish)
 */
bool createGCThread(TSR)(ThreadHandle* thread, TSR start_routine, void* arg) {
	auto runner = allocThreadRunner(start_routine, arg);

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
			thread, null, cast(OSThreadRoutine) runner.getFunction!false(), runner);
		return ret == 0;
	} else version(Windows) {
		import core.sys.windows.winbase : LPTHREAD_START_ROUTINE, CreateThread, INVALID_HANDLE_VALUE;
		*thread = CreateThread(null, 0, cast(LPTHREAD_START_ROUTINE) runner.getFunction!false(), runner, 0, null);
		return *thread != INVALID_HANDLE_VALUE;
	}
}

package:

struct ThreadRunner(TSR) {
	void* arg;
	TSR fun;

	static getFunction(bool AllowStopTheWorld)()
	{
		return &runThread!(AllowStopTheWorld, typeof(this));
	}
}

ThreadRunner!TSR* allocThreadRunner(TSR)(TSR fun, void* arg) {
	alias TRType = ThreadRunner!TSR;
	import d.gc.capi : __sd_gc_alloc;
	auto runner = cast(TRType*)__sd_gc_alloc(TRType.sizeof);
	runner.fun = fun;
	runner.arg = arg;
	return runner;
}

extern(C) auto runThread(bool AllowStopTheWorld, TRunner)(TRunner* runner) {
	import d.gc.capi : __sd_gc_free;
	import d.gc.thread : createThread, destroyThread;

	auto fun = runner.fun;
	auto arg = runner.arg;

	createThread!AllowStopTheWorld();
	__sd_gc_free(runner);

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
}
