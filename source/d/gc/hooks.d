module d.gc.hooks;

import d.gc.types;

extern(C):

void __sd_gc_global_scan(ScanDg scan) {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_pre_suspend_hook(void* stackTop) {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}
void __sd_gc_post_suspend_hook() {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_pre_stop_the_world_hook() {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}
void __sd_gc_post_restart_the_world_hook() {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_finalize(void* ptr, size_t usedSpace, void* finalizer) {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}

void __sd_gc_register_global_segments() {
	// TODO: implement this when the class is added.
	pragma(msg, "implement ", __FUNCTION__);
}
