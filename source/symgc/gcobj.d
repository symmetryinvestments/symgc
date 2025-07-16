// D runtime hook to include symgc as an option for garbage collection.
module symgc.gcobj;

import core.gc.gcinterface;
static import core.memory;

import core.thread.threadbase : ThreadBase;

import core.stdc.string : memset;

// when running unittests and druntime is involved, set the GC to the symmetry GC
version(Symgc_testing) version(Symgc_druntime_hooks) {
	extern(C) __gshared rt_options = ["gcopt=gc:sdc"];
}

extern(C) nothrow {
	void onOutOfMemoryError(void* pretend_sideffect = null, string file = __FILE__, size_t line = __LINE__) @trusted nothrow @nogc;

	// c api from gc
	void __sd_gc_init();
	void __sd_gc_collect();
	void __sd_gc_free(void *ptr) @nogc;
	void __sd_gc_add_roots(void[] range) @nogc;
	void __sd_gc_remove_roots(void *ptr) @nogc;
	uint __sd_gc_enable();
	uint __sd_gc_disable();

	// hook prototypes needed for druntime api (see below)
	void* __sd_gc_hook_alloc(size_t size, bool containsPointers, bool zeroData);
	void* __sd_gc_hook_alloc_appendable(size_t size, bool containsPointers, bool zeroData, void* finalizer);
	BlkInfo __sd_gc_hook_fetch_alloc_info(void *ptr) @nogc;
	void *__sd_gc_hook_realloc(void *ptr, size_t size, bool hasPointers);
	size_t __sd_gc_hook_get_array_capacity(void[] slice) @nogc;
	void[] __sd_gc_hook_get_allocation_slice(void *ptr) @nogc;
	bool __sd_gc_hook_extend_array_used(void* ptr, size_t newUsed, size_t existingUsed);
	bool __sd_gc_hook_shrink_array_used(void* ptr, size_t newUsed, size_t existingUsed);
	bool __sd_gc_hook_reserve_array_capacity(void* ptr, size_t request, size_t existingUsed);
}

enum TYPEINFO_IN_BLOCK = cast(void*)1;

void initSDCThread(ThreadBase t) nothrow @nogc
{
	// if we are using the pthread hook, this is already done by the pthread hook.
	version(Symgc_pthread_hook) {} else {
		import d.gc.thread;
		// TODO: see if this can be correctly marked
		// createThread!false();
		(cast(void function() nothrow @nogc)&createThread!false)();
	}

	// set up the thread to point at our thread cache;
	import d.gc.tcache;
	t.tlsGCData = &threadCache;
}

private pragma(crt_constructor) void gc_sdc_ctor()
{
	_d_register_sdc_gc();
}

extern(C) void thread_setGCSignals(int suspendSignalNo, int resumeSignalNo) nothrow @nogc;

extern(C) void _d_register_sdc_gc()
{
	version(Symgc_pthread_hook)
	{
		// need to initialize early, as the pthread create hook needs stuff set up.
		import d.gc.thread;
		createProcess();
	}
	else version(Posix)
	{
		// set druntime's signals to match ours, we are going to use their
		// signal mechanisms. Have to do this before dmain2/thread_init.
		import d.gc.signal;
		thread_setGCSignals(SIGSUSPEND, SIGRESUME);
	}

	import core.gc.registry;
	static if(__traits(compiles, registerGCFactory("sdc", &initialize, &initSDCThread)))
	{
		registerGCFactory("sdc", &initialize, &initSDCThread);
		registerGCFactory("sdcq", &initializeQuiet, &initSDCThread);
	}
	else
	{
		version(Posix) {
			registerGCFactory("sdc", &initialize);
			registerGCFactory("sdcq", &initializeQuiet);
		}
		else
			static assert(false, "No support for threadInit in gcinterface!");
	}
}


// since all the real work is done in the SDC library, the class is just a
// shim, and can just be initialized at compile time.
private __gshared SnazzyGC instance = new SnazzyGC;

private GC initializeQuiet()
{
	version(Symgc_pthread_hook) { }
	else {
		// now it is ok to initialize
		import d.gc.thread;
		createProcess();
	}

	// check the config to see if we should set the thread count for scanning.
	import core.gc.config;
	// ignore the thread count if it's the default.
	if (config.parallel != typeof(config).init.parallel)
	{
		import d.gc.collector;
		setScanningThreads(config.parallel + 1);
	}
	return instance;
}

private GC initialize()
{
	import core.stdc.stdio;
	printf("using SYM GC!\n");
	return initializeQuiet();
}

final class SnazzyGC : GC
{
	void enable()
	{
		__sd_gc_enable();
	}

	/**
	 *
	 */
	void disable()
	{
		__sd_gc_disable();
	}

	/**
	 *
	 */
	void collect() nothrow
	{
		__sd_gc_collect();
	}

	/**
	 * minimize free space usage
	 */
	void minimize() nothrow
	{
		// TODO: add once there is a hook
	}

	/**
	 *
	 */
	uint getAttr(void* p) nothrow
	{
		auto blkinfo = query(p);
		return blkinfo.attr;
	}

	/**
	 *
	 */
	uint setAttr(void* p, uint mask) nothrow
	{
		// SDC GC does not support setting attributes after allocation
		return getAttr(p);
	}

	/**
	 *
	 */
	uint clrAttr(void* p, uint mask) nothrow
	{
		// SDC GC does not support setting attributes after allocation
		return getAttr(p);
	}

	/**
	 *
	 */
	void *malloc(size_t size, uint bits, const TypeInfo ti) nothrow
	{
		return sdcAllocate(size, bits, false, ti);
	}

	/*
	 *
	 */
	BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
	{
		auto ptr = sdcAllocate(size, bits, false, ti);

		if(!ptr)
			return BlkInfo.init;

		return __sd_gc_hook_fetch_alloc_info(ptr);
	}

	/*
	 *
	 */
	void *calloc(size_t size, uint bits, const TypeInfo ti) nothrow
	{
		return sdcAllocate(size, bits, true, ti);
	}

	/*
	 *
	 */
	void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
	{
		return __sd_gc_hook_realloc(p, size, (bits & BlkAttr.NO_SCAN) == 0);
	}

	/**
	 * Attempt to in-place enlarge the memory block pointed to by p by at least
	 * minsize bytes, up to a maximum of maxsize additional bytes.
	 * This does not attempt to move the memory block (like realloc() does).
	 *
	 * Returns:
	 *  0 if could not extend p,
	 *  total size of entire memory block if successful.
	 */
	size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
	{
		// TODO: add once there is a hook
		return 0;
	}

	/**
	 *
	 */
	size_t reserve(size_t size) nothrow
	{
		// TODO: add once there is a hook
		return 0;
	}

	/**
	 *
	 */
	void free(void* p) nothrow @nogc
	{
		// Note: p is not supposed to be freed if it is an interior pointer,
		// but it is freed in SDC in this case.
		__sd_gc_free(p);
	}

	/**
	 * Determine the base address of the block containing p.  If p is not a gc
	 * allocated pointer, return null.
	 */
	void* addrOf(void* p) nothrow @nogc
	{
		auto blkinfo = query(p);
		return blkinfo.base;
	}

	/**
	 * Determine the allocated size of pointer p.  If p is an interior pointer
	 * or not a gc allocated pointer, return 0.
	 */
	size_t sizeOf(void* p) nothrow @nogc
	{
		auto blkinfo = query(p);
		return blkinfo.size;
	}

	/**
	 * Determine the base address of the block containing p.  If p is not a gc
	 * allocated pointer, return null.
	 */
	BlkInfo query(void* p) nothrow @nogc
	{
		return __sd_gc_hook_fetch_alloc_info(p);
	}

	/**
	 * Retrieve statistics about garbage collection.
	 * Useful for debugging and tuning.
	 */
	core.memory.GC.Stats stats() @safe nothrow @nogc
	{
		// TODO: add once there is a hook
		return core.memory.GC.Stats();
	}

	/**
	 * Retrieve profile statistics about garbage collection.
	 * Useful for debugging and tuning.
	 */
	core.memory.GC.ProfileStats profileStats() @safe nothrow @nogc
	{
		// TODO: add once there is a hook
		return core.memory.GC.ProfileStats();
	}

	/**
	 * add p to list of roots
	 */
	void addRoot(void* p) nothrow @nogc
	{
		__sd_gc_add_roots(p[0 .. 0]);
	}

	/**
	 * remove p from list of roots
	 */
	void removeRoot(void* p) nothrow @nogc
	{
		__sd_gc_remove_roots(p);
	}

	/**
	 *
	 */
	@property RootIterator rootIter() @nogc
	{
		return &iterateRoots!Root;
	}

	/**
	 * add range to scan for roots
	 */
	void addRange(void* p, size_t sz, const TypeInfo ti) nothrow @nogc
	{
		__sd_gc_add_roots(p[0 .. sz]);
	}

	/**
	 * remove range
	 */
	void removeRange(void* p) nothrow @nogc
	{
		__sd_gc_remove_roots(p);
	}

	/**
	 *
	 */
	@property RangeIterator rangeIter() @nogc
	{
		return &iterateRoots!Range;
	}

	private int iterateRoots(T)(scope int delegate(ref T) nothrow dg) nothrow {
		import d.gc.global;
		return gState.iterateRoots(dg);
	}

	/**
	 * run finalizers
	 */
	void runFinalizers(const scope void[] segment) nothrow
	{
		// TODO: add once there is a hook
	}

	/*
	 *
	 */
	bool inFinalizer() nothrow @nogc @safe
	{
		import d.gc.tcache;
		return threadCache.inFinalizer;
	}

	/**
	 * Returns the number of bytes allocated for the current thread
	 * since program start. It is the same as
	 * GC.stats().allocatedInCurrentThread, but faster.
	 */
	ulong allocatedInCurrentThread() nothrow
	{
		import d.gc.tcache;
		return threadCache.allocatedInThread();
	}

	/**
	 * Get array metadata for a specific pointer. Note that the resulting
	 * metadata will point at the block start, not the pointer.
	 */
	void[] getArrayUsed(void *ptr, bool atomic) @nogc nothrow
	{
		return __sd_gc_hook_get_allocation_slice(ptr);
	}

	bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @trusted
	{
		return __sd_gc_hook_extend_array_used(slice.ptr, newUsed, slice.length);
	}

	size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false) nothrow @trusted
	{
		if(request > slice.length)
			if(!__sd_gc_hook_reserve_array_capacity(slice.ptr, request, slice.length))
				return 0;
		return __sd_gc_hook_get_array_capacity(slice);
	}

	bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow
	{
		return __sd_gc_hook_shrink_array_used(slice.ptr, slice.length, existingUsed);
	}

	void initThread(ThreadBase t) nothrow @nogc
	{
		initSDCThread(t);
	}

	void cleanupThread(ThreadBase t) nothrow @nogc
	{
		// set up the thread to point at our thread cache;
		import d.gc.tcache;
		if (t.tlsGCData is &threadCache)
		{
			import d.gc.thread;
			(cast(void function() nothrow @nogc)&destroyThread)();
			t.tlsGCData = null;
		}
	}

	~this() {
		// clean up any lingering GC threads.
		import d.gc.scanner;
		cleanupGCThreads();
	}
}

// HELPER FUNCTIONS

void* getContextPointer(uint bits, const TypeInfo ti) nothrow @nogc
{
	if (bits & BlkAttr.FINALIZE) {
		return (ti !is null && typeid(ti) is typeid(TypeInfo_Struct)) ?
			cast(void*)ti : TYPEINFO_IN_BLOCK;
	}
	return null;
}

void *sdcAllocate(size_t size, uint bits, bool zeroData, const TypeInfo ti) nothrow
{
	if (size == 0)
		return null;

	auto ctx = getContextPointer(bits, ti);

	bool containsPointers = (bits & BlkAttr.NO_SCAN) == 0;

	if ((bits & BlkAttr.APPENDABLE) || ctx)
		return __sd_gc_hook_alloc_appendable(size + 1, containsPointers, zeroData, ctx);

	return __sd_gc_hook_alloc(size, containsPointers, zeroData);
}

// BEGIN C API HOOKS
// These hooks are prototyped at the top, but may have different attributes
// than required, so we need to cheat to get the attributes right.
//
// For a function __sd_gc_hook_foo_bar, we will name it hook_fooBar, and use pragma
// mangle to get the right symbol name.
//
// Hoooks that already exist as part of the C api are not implemented here, but
// instead in d.gc.capi.

import d.gc.tcache;

extern(C):

pragma(mangle, "__sd_gc_hook_fetch_alloc_info")
BlkInfo hook_fetchAllocInfo(void* ptr) {
	BlkInfo result;
	import d.gc.capi;
	auto pd = __sd_gc_maybe_get_page_descriptor(ptr);
	auto e = pd.extent;
	if (e is null) {
		return result;
	}

	if (!pd.containsPointers) {
		result.attr |= BlkAttr.NO_SCAN;
	}

	if (pd.isSlab()) {
		import d.gc.slab;
		auto si = SlabAllocInfo(pd, ptr);
		result.base = cast(void*) si.address;

		if (si.hasMetadata) {
			result.attr |= BlkAttr.APPENDABLE;
			if (si.finalizer) {
				result.attr |= BlkAttr.FINALIZE;
			}
		}

		result.size = si.slotCapacity;
	} else {
		// Large blocks are always appendable.
		result.attr |= BlkAttr.APPENDABLE;

		if (e.finalizer) {
			result.attr |= BlkAttr.FINALIZE;
		}

		result.base = e.address;

		result.size = e.size;
	}

	return result;
}

pragma(mangle, "__sd_gc_hook_realloc")
void* hook_realloc(void* ptr, size_t size, bool containsPointers) {
	return threadCache.realloc(ptr, size, containsPointers);
}

pragma(mangle, "__sd_gc_hook_alloc")
void* hook_alloc(size_t size, bool containsPointers, bool zeroData) {
	return threadCache.alloc(size, containsPointers, zeroData);
}

pragma(mangle, "__sd_gc_hook_alloc_appendable")
void* hook_allocAppendable(size_t size, bool containsPointers, bool zeroData, void* context) {
	return threadCache.allocAppendable(size, containsPointers, zeroData, context);
}

pragma(mangle, "__sd_gc_hook_get_array_capacity")
size_t hook_getArrayCapacity(void[] slice) {
	auto capacity = threadCache.getCapacity(slice.ptr[0 .. slice.length + 1]);
	if (capacity == 0) {
		return 0;
	}

	return capacity - 1;
}

pragma(mangle, "__sd_gc_hook_get_allocation_slice")
void[] hook_getAllocationSlice(const void* ptr) {
	return threadCache.getAllocationSlice(ptr);
}

pragma(mangle, "__sd_gc_hook_shrink_array_used")
bool hook_shrinkArrayUsed(void* ptr, size_t newUsed, size_t existingUsed) {
	assert(newUsed <= existingUsed);
	import d.gc.capi;
	auto pd = __sd_gc_maybe_get_page_descriptor(ptr);
	auto e = pd.extent;
	if (e is null) {
		return false;
	}

	if (pd.isSlab()) {
		import d.gc.slab;
		auto si = SlabAllocInfo(pd, ptr);
		if (!threadCache.validateCapacity(ptr[0 .. existingUsed + 1],
		                                  si.address, si.usedCapacity)) {
			return false;
		}

		auto offset = ptr - si.address;
		return si.setUsedCapacity(newUsed + offset + 1);
	}

	// Large allocation.
	if (!threadCache.validateCapacity(ptr[0 .. existingUsed + 1], e.address,
	                                  e.usedCapacity)) {
		return false;
	}

	auto offset = ptr - e.address;
	e.setUsedCapacity(newUsed + offset + 1);
	return true;
}


pragma(mangle, "__sd_gc_hook_extend_array_used")
bool hook_extendArrayUsed(void* ptr, size_t newUsed, size_t existingUsed) {
	assert(newUsed >= existingUsed);
	return
		threadCache.extend(ptr[0 .. existingUsed + 1], newUsed - existingUsed);
}

pragma(mangle, "__sd_gc_hook_reserve_array_capacity")
bool hook_reserveArrayCapacity(void* ptr, size_t request,
									size_t existingUsed) {
	assert(request >= existingUsed);
	return
		threadCache.reserve(ptr[0 .. existingUsed + 1], request - existingUsed);
}
