module symgc.trampoline;

version(Symgc_pthread_hook):

package:

import core.sys.posix.pthread;

import d.gc.thread;

alias PthreadFunction = extern(C) void* function(void*);

// Hijack the system's pthread_create function so we can register the thread.
extern(C) int pthread_create(pthread_t* thread, scope const pthread_attr_t* attr,
		PthreadFunction start_routine, void* arg) {
	import symgc.thread: ThreadRunner, allocThreadRunner;

	auto runner = allocThreadRunner(start_routine, arg);

	// Stop the world cannot happen during thread startup.
	preventStopTheWorld();

	auto ret =
		pthread_create_trampoline(thread, attr,
				cast(PthreadFunction) runner.getFunction!false(), runner);
	if (ret != 0) {
		// The spawned thread will call this when there are no errors.
		allowStopTheWorld();
	}

	return ret;
}

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
