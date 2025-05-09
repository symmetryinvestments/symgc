// abstractions of things needed just for testing (not used in the normal code)
module symgc.test;

version(Symgc_testing):

public import symgc.thread : ThreadHandle;

// functions to create and join threads
version(linux) {
	public import core.sys.posix.sched: sched_yield;
	public import core.sys.posix.unistd : sleep, usleep;
}
else version(Windows) {
	import core.sys.windows.winbase;
	alias sched_yield = core.sys.windows.winbase.SwitchToThread;
	void sleep(int seconds) {
		Sleep(1000 * seconds);
	}

	void usleep(ulong usecs) {
		Sleep(cast(uint)(usecs / 1000));
	}
}

ThreadHandle runThread(void* delegate() dg) {
	ThreadHandle tid;
	version (linux) {
		import core.sys.posix.pthread;
		extern (C) void* function(void*) fptr;
		fptr = cast(typeof(fptr)) dg.funcptr;

		auto r = pthread_create(&tid, null, fptr, dg.ptr);
		assert(r == 0, "Failed to create thread!");
	}
	else version(Windows) {
		LPTHREAD_START_ROUTINE fptr;
		fptr = cast(typeof(fptr)) dg.funcptr;

		tid = CreateThread(null, 0, fptr, dg.ptr, 0, null);

		assert(tid != INVALID_HANDLE_VALUE, "Failed to create thread!");
	}
	return tid;
}

void* joinThread(ThreadHandle tid) {
	version(linux) {
		import core.sys.posix.pthread;
		void* result;
		pthread_join(tid, &result);
		return result;
	}
	else version(Windows) {
		if (WaitForSingleObject(tid, INFINITE) != WAIT_OBJECT_0) {
			assert(false, "Failed to join thread");
		}
		uint result;
		GetExitCodeThread(tid, &result);
		CloseHandle(tid);
		return cast(void*)result;
	}
}
