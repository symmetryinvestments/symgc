module d.gc.hooks;

import d.gc.types;

version(unittest) version = testing;
version(integrationTests) version = testing;

extern(C):

void __sd_gc_global_scan(ScanDg scan) {
	version(testing) {
		import core.stdc.stdio;
		printf("doing global scan\n");
		import d.gc.global;
		gState.scanRoots(scan);

		import d.gc.thread;
		scanSuspendedThreads(scan);
	}
	else
		// TODO: implement this when the class is added.
		pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_pre_suspend_hook(void* stackTop) {
	version(testing) {
	}
	else
		// TODO: implement this when the class is added.
		pragma(msg, "implement ", __FUNCTION__);
}
void __sd_gc_post_suspend_hook() {
	version(testing) {
	}
	else
		// TODO: implement this when the class is added.
		pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_pre_stop_the_world_hook() {
	version(testing) {
	}
	else
		// TODO: implement this when the class is added.
		pragma(msg, "implement ", __FUNCTION__);
}
void __sd_gc_post_restart_the_world_hook() {
	version(testing) {
	}
	else
		// TODO: implement this when the class is added.
		pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_finalize(void* ptr, size_t usedSpace, void* finalizer) {
	version(testing) {
		alias FinalizerFunctionType = void function(void* ptr, size_t size);
		(cast(FinalizerFunctionType) finalizer)(ptr, usedSpace);
	}
	else
		// TODO: implement this when the class hook is added.
		pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_register_global_segments() {
	version(testing) {
		import symgc.rt;
		registerGlobalSegments();
	}
	else
		// TODO: implement this when the class is added.
		pragma(msg, "implement ", __FUNCTION__);
}
