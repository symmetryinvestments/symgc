module symgc.trampoline;

import d.gc.capi;
import d.gc.thread;

import core.sys.posix.pthread;

alias PthreadFunction = extern(C) void* function(void*);

version(Symgc_pthread_hook) {
	// Hijack the system's pthread_create function so we can register the thread.
	extern(C) int pthread_create(pthread_t* thread, scope const pthread_attr_t* attr,
			PthreadFunction start_routine, void* arg) {
		auto runner = ThreadRunner.alloc(start_routine, arg);

		// Stop the world cannot happen during thread startup.
		preventStopTheWorld();

		auto ret =
			pthread_create_trampoline(thread, attr,
					cast(PthreadFunction) &runThread!true, runner);
		if (ret != 0) {
			// The spawned thread will call this when there are no errors.
			allowStopTheWorld();
		}

		return ret;
	}
}

/**
 * This special hook does not involve preventing "Stop the world". otherwise
 * creates a thread in the same way.
 */
int createGCThread(pthread_t* thread, scope const pthread_attr_t* attr,
                   PthreadFunction start_routine, void* arg) {
	auto runner = ThreadRunner.alloc(start_routine, arg);

	auto ret = pthread_create_trampoline(
		thread, attr, cast(PthreadFunction) &runThread!false, runner);
	return ret;
}

private:

struct ThreadRunner {
	void* arg;
	extern(C) void* function(void*) fun;

	static alloc(PthreadFunction fun, void* arg) {
		// TODO: is this the right way to do this now?
		auto runner = cast(ThreadRunner*)__sd_gc_alloc(ThreadRunner.sizeof);
		runner.fun = fun;
		runner.arg = arg;
		return runner;
	}
}

extern(C) void* runThread(bool AllowStopTheWorld)(ThreadRunner* runner) {
	auto fun = runner.fun;
	auto arg = runner.arg;

	createThread!AllowStopTheWorld();
	__sd_gc_free(runner);

	// Make sure we clean up after ourselves.
	scope(exit) destroyThread();

	return fun(arg);
}

version(Symgc_pthread_hook) {
	alias PthreadCreateType = typeof(&core.sys.posix.pthread.pthread_create);

	__gshared
		PthreadCreateType pthread_create_trampoline = cast(PthreadCreateType)&resolve_pthread_create;

	extern(C) int resolve_pthread_create(pthread_t* thread, scope const pthread_attr_t* attr,
			PthreadFunction start_routine, void* arg) {
		PthreadCreateType real_pthread_create;

		// First, check if there is an interceptor and if so, use it.
		// This ensure we remain compatible with sanitizers, as they use
		// a similar trick to intercept various library calls.
		import core.sys.linux.dlfcn;
		real_pthread_create = cast(PthreadCreateType)
			dlsym(RTLD_DEFAULT, "__interceptor_pthread_create");
		if (real_pthread_create !is null) {
			goto Forward;
		}

		// It doesn't look like we have an interceptor, forward to the method
		// in the next object.
		real_pthread_create =
			cast(PthreadCreateType) dlsym(RTLD_NEXT, "pthread_create");
		if (real_pthread_create is null) {
			import core.stdc.stdlib, core.stdc.stdio;
			printf("Failed to locate pthread_create!");
			exit(1);
		}

Forward:
		// Rebind the trampoline so we never resolve again.
		pthread_create_trampoline = real_pthread_create;
		return real_pthread_create(thread, attr, start_routine, arg);
	}
} else {
	// no trampoline used
	alias pthread_create_trampoline = pthread_create;
}
