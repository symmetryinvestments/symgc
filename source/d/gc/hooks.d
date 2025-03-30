module d.gc.hooks;

import d.gc.types;

version(unittest) version = testing;
version(integrationTests) version = testing;

extern(C):

void __sd_gc_global_scan(ScanDg scan) {
	version(testing) {
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

// hook to druntime class finalization.
extern(C) void rt_finalize2(void* p, bool det, bool resetMemory) nothrow;

void __sd_gc_finalize(void* ptr, size_t usedSpace, void* finalizer) {
	import symgc.gcobj : TYPEINFO_IN_BLOCK;
	version(testing) {
		alias FinalizerFunctionType = void function(void* ptr, size_t size);
		(cast(FinalizerFunctionType) finalizer)(ptr, usedSpace);
	}
	else
	{
		// if typeinfo is cast(void*)1, then the TypeInfo is inside the block (i.e.
		// this is an object).
		if(finalizer == TYPEINFO_IN_BLOCK)
		{
			rt_finalize2(ptr, false, false);
		}
		else
		{
			// context is a typeinfo pointer, which can be used to destroy the
			// elements in the block.
			auto ti = cast(TypeInfo)finalizer;
			auto elemSize = ti.tsize;
			if(elemSize == 0)
			{
				// call the destructor on the pointer, and be done
				ti.destroy(ptr);
			}
			else
			{
				// if an array, ensure the size is a multiple of the type size.
				assert(usedSpace % elemSize == 0);
				// just in case, make sure we don't wrap past 0
				while(usedSpace >= elemSize)
				{
					ti.destroy(ptr);
					ptr += elemSize;
					usedSpace -= elemSize;
				}
			}
		}
	}
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
