module d.gc.hooks;

import d.gc.types;

version(unittest) version = testing;
version(integrationTests) version = testing;

extern(C):

// druntime API.
bool thread_preSuspend(void* stackTop);
bool thread_postSuspend();

void thread_preStopTheWorld();
void thread_postRestartTheWorld();


// copied from core.thread.threadbase. Removed nothrow for now
// TODO: should we add nothrow back?
alias ScanAllThreadsFn = extern(D) void delegate(void*, void*); // nothrow;
void thread_scanAll(scope ScanAllThreadsFn scan); // nothrow;

void __sd_gc_global_scan(ScanDg scan) {
	import d.gc.global;
	gState.scanRoots(scan);

	import d.gc.thread;
	scanSuspendedThreads(scan);
	version(testing) { }
	else {
		void doScan(void* start, void* stop) {
			import d.gc.range;
			scan(makeRange(start, stop));
		}
		thread_scanAll(&doScan);
	}
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
	version(testing) { }
	else {
		if(!thread_preSuspend(stackTop)) {
			return;
		}
		/**
		 * If the thread is managed by druntime, then we'll get the
		 * TLS segments when calling thread_scanAll_C, so we can remove
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

void __sd_gc_post_suspend_hook() {
	version(testing) { }
	else
		thread_postSuspend();
}

void __sd_gc_pre_stop_the_world_hook() {
	version(testing) { }
	else
		thread_preStopTheWorld();
}
void __sd_gc_post_restart_the_world_hook() {
	version(testing) {
	}
	else
		thread_postRestartTheWorld();
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
	else {
		// druntime handles this on its own
	}
}
