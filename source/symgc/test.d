// abstractions of things needed just for testing (not used in the normal code)
module symgc.test;

version(Symgc_testing):

public import symgc.thread : ThreadHandle, sched_yield;

/**
 * Fast unittest runner: reports failures as file(line): message without
 * symbolicated stack traces. The default trace handler shells out to
 * atos for every printed frame, which is prohibitively slow when a
 * suite has many failures.
 */
shared static this() {
	import core.runtime : Runtime;
	Runtime.extendedModuleUnitTester = &fastUnitTestRunner;
}

private {
	import core.runtime : UnitTestResult;

	UnitTestResult fastUnitTestRunner() {
		UnitTestResult results;

		foreach (m; ModuleInfo) {
			if (!m) {
				continue;
			}

			auto fp = m.unitTest;
			if (!fp) {
				continue;
			}

			++results.executed;
			try {
				fp();
				++results.passed;
			} catch (Throwable e) {
				import core.stdc.stdio;
				fprintf(stderr, "%.*s: %.*s(%llu): [unittest] %.*s\n",
					cast(int) m.name.length, m.name.ptr,
					cast(int) e.file.length, e.file.ptr,
					cast(ulong) e.line,
					cast(int) (e.msg ? e.msg.length : 0),
					e.msg ? e.msg.ptr : "");
			}
		}

		results.summarize = true;
		return results;
	}
}

public:

// functions to create and join low level threads
version(Posix) {
	public import core.sys.posix.unistd : sleep, usleep;
}
else version(Windows) {
	import core.sys.windows.winbase;
	import symgc.thread : _beginthreadex;
	void sleep(int seconds) {
		Sleep(1000 * seconds);
	}

	void usleep(ulong usecs) {
		Sleep(cast(uint)(usecs / 1000));
	}
}

ThreadHandle runThread(void* delegate() dg) {
	ThreadHandle tid;
	version (Posix) {
		import core.sys.posix.pthread;
		extern (C) void* function(void*) fptr;
		fptr = cast(typeof(fptr)) dg.funcptr;

		auto r = pthread_create(&tid, null, fptr, dg.ptr);
		assert(r == 0, "Failed to create thread!");
	}
	else version(Windows) {
		LPTHREAD_START_ROUTINE fptr;
		fptr = cast(typeof(fptr)) dg.funcptr;

		tid = _beginthreadex(null, 0, fptr, dg.ptr, 0, null);

		assert(tid != INVALID_HANDLE_VALUE, "Failed to create thread!");
	}
	return tid;
}

void* joinThread(ThreadHandle tid) {
	version(Posix) {
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

version(Symgc_test_main) {
	void main() {
	}
}
