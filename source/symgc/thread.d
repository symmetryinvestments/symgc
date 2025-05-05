module symgc.thread;

version(Windows) {
    import core.sys.windows.winnt : HANDLE;
    import core.sys.windows.windef : DWORD;
    alias ThreadHandle = HANDLE;
    private enum THREAD_RETURN_VALUE = DWORD(0);
} else version(linux) {
    import core.sys.posix.pthread : pthread_t;
    alias ThreadHandle = pthread_t;
    private enum THREAD_RETURN_VALUE = null;
}

version(linux):

import d.gc.thread;

// thread start function application code will use.
// The return value is always void, because we don't use it in this library.
alias ThreadStartRoutine = void function(void*);

/**
 * Create a GC thread that does not prevent stop the world (or block waiting for world stopping to finish)
 */
bool createGCThread(ThreadHandle* thread, ThreadStartRoutine start_routine, void* arg) {
	auto runner = ThreadRunner.alloc(start_routine, arg);

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
            thread, null, cast(OSThreadRoutine) &runThread!false, runner);
        return ret == 0;
    } else version(Windows) {
        import core.sys.windows.winbase : LPTHREAD_START_ROUTINE, CreateThread, INVALID_HANDLE_VALUE;
        *thread = CreateThread(null, 0, cast(LPTHREAD_START_ROUTINE)&runThread!false, runner, 0, null);
        return *thread != INVALID_HANDLE_VALUE;
    }
}

package:

struct ThreadRunner {
	void* arg;
	ThreadStartRoutine fun;

	static alloc(ThreadStartRoutine fun, void* arg) {
        import d.gc.capi : __sd_gc_alloc;
		// TODO: is this the right way to do this now?
		auto runner = cast(ThreadRunner*)__sd_gc_alloc(ThreadRunner.sizeof);
		runner.fun = fun;
		runner.arg = arg;
		return runner;
	}
}

extern(C) typeof(THREAD_RETURN_VALUE) runThread(bool AllowStopTheWorld)(ThreadRunner* runner) {
    import d.gc.capi : __sd_gc_free;
    import d.gc.thread : createThread, destroyThread;

	auto fun = runner.fun;
	auto arg = runner.arg;

	createThread!AllowStopTheWorld();
	__sd_gc_free(runner);

	// Make sure we clean up after ourselves.
	scope(exit) destroyThread();

	fun(arg);

    return THREAD_RETURN_VALUE;
}
