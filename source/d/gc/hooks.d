module d.gc.hooks;

version(linux):

import d.gc.types;

// ensure that at least one of pthread_hook or druntime_hook must be true (both
// can be true, but both cannot be false)
version(Symgc_pthread_hook) {
}
else version(Symgc_druntime_hooks) {
}
else {
	static assert(0, "At least one of Symgc_pthread_hook or Symgc_druntime_hooks must be true");
}

extern(C):

// druntime API.
bool thread_preSuspend(void* stackTop);
bool thread_postSuspend();

void thread_preStopTheWorld();
void thread_postRestartTheWorld();

void __sd_gc_global_scan(ScanDg scan) {
	import d.gc.global;
	gState.scanRoots(scan);

	import d.gc.thread;
	scanSuspendedThreads(scan);
}

/**
 * Free a pointer directly to an arena. Needed to avoid messing up threadCache
 * bins in signal handler.
 */
import d.gc.emap;
private void arenaFree(ref CachedExtentMap emap, void* ptr) {
	import d.gc.util, d.gc.spec;
	auto aptr = alignDown(ptr, PageSize);
	auto pd = emap.lookup(aptr);
	if (!pd.isSlab()) {
		pd.arena.freeLarge(emap, pd.extent);
		return;
	}

	const(void)*[1] worklist = [ptr];
	pd.arena.batchFree(emap, worklist[0 .. 1], &pd);
}

void __sd_gc_pre_suspend_hook(void* stackTop) {
	version(Symgc_druntime_hooks) {
		if(!thread_preSuspend(stackTop)) {
			return;
		}
		version(Symgc_pthread_hook) {
			/**
			 * If the thread is managed by druntime, then we'll get the
			 * TLS segments when calling thread_scanAll, so we can remove
			 * them from the thread cache in order to not scan them twice.
			 *
			 * Note that we cannot do so with the stack, because we need to
			 * scan it eagerly, as registers containing possible pointers gets
			 * pushed on it.
			 */
			import d.gc.tcache;
			auto tls = threadCache.tlsSegments;
			if (tls.ptr is null) {
				return;
			}

			threadCache.tlsSegments = [];

			// Arena needs a CachedExtentMap for freeing pages.
			auto emap = CachedExtentMap(threadCache.emap.emap, threadCache.emap.base);
			arenaFree(emap, tls.ptr);
		}
	}
}

void __sd_gc_post_suspend_hook() {
	version(Symgc_druntime_hooks) {
		thread_postSuspend();
	}
}

void __sd_gc_pre_stop_the_world_hook() {
	version(Symgc_druntime_hooks) {
		thread_preStopTheWorld();
	}
}
void __sd_gc_post_restart_the_world_hook() {
	version(Symgc_druntime_hooks) {
		thread_postRestartTheWorld();
	}
}

// hook to druntime class finalization.
extern(C) void rt_finalize2(void* p, bool det, bool resetMemory) nothrow;

void __sd_gc_finalize(void* ptr, size_t usedSpace, void* finalizer) {
	version(Symgc_druntime_hooks) {
		import symgc.gcobj : TYPEINFO_IN_BLOCK;
		// if typeinfo is cast(void*)1, then the TypeInfo is inside the block (i.e.
		// this is an object).
		if(finalizer == TYPEINFO_IN_BLOCK)
		{
			rt_finalize2(ptr, false, false);
		}
		else
		{
			// NOTE: we always add 1 byte for buffer space regardless of the
			// used size when we have an appendable block. This means, we
			// always have to subtract 1 when finalizing.
			--usedSpace;

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
	else
	{
		alias FinalizerFunctionType = void function(void* ptr, size_t size);
		(cast(FinalizerFunctionType) finalizer)(ptr, usedSpace);
	}
}

void __sd_gc_register_global_segments() {
	version(Symgc_druntime_hooks) {
		// druntime handles this on its own
	}
	else {
		import symgc.rt;
		registerGlobalSegments();
	}
}
