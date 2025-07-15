module d.gc.global;

import d.gc.tcache;
import d.gc.types;

struct GCState {
private:
	import d.sync.mutex;
	Mutex mutex;

	import d.sync.atomic;
	Atomic!ubyte cycle;

	/**
	 * Global roots.
	 */
	const(void*)[][] roots;

public:
	ubyte nextGCCycle() shared {
		auto old = cycle.load();
		while (true) {
			/**
			 * Because we initialize extents with cycle 0, we want to make sure
			 * the chosen GC cycle is never 0. To do so, we ensure it is odd.
			 * Alternatively, we could try to initialize the cycle to
			 * a specific value. This is almost certainly necessary if we want
			 * to go concurrent.
			 */
			ubyte c = ((old + 1) | 0x01) & 0xff;
			if (cycle.casWeak(old, c)) {
				return c;
			}
		}
	}

	/**
	 * Add a block of scannable data as a root to possible GC memory. This
	 * range will be scanned on proper alignment boundaries if it potentially
	 * could contain pointers.
	 *
	 * If it has a length of 0, then the range is added as-is, to allow pinning
	 * of GC blocks. These blocks will be scanned as part of the normal
	 * process, by virtue of the pointer being stored as a range of 0 bytes in
	 * the global array of roots.
	 */
	void addRoots(const void[] range) shared {
		import d.gc.thread;
		enterBusyState();
		scope(exit) exitBusyState();

		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(GCState*) &this).addRootsImpl(range);
	}

	/**
	 * Remove the root (if present) that begins with the given pointer.
	 */
	void removeRoots(const void* ptr) shared {
		import d.gc.thread;
		enterBusyState();
		scope(exit) exitBusyState();

		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(GCState*) &this).removeRootsImpl(ptr);
	}

	/**
	 * This function is used during the mark phase of the GC cycle.
	 *
	 * It is therefore capital that methods that add/remove roots
	 * mark the thread as busy so it is not paused while holding
	 * the mutex.
	 */
	void scanRoots(ScanDg scan) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(GCState*) &this).scanRootsImpl(scan);
	}

	/**
	 * Tidy up any root structure. This should be called periodically to
	 * ensure the roots structure does not become too large. Should not be
	 * called during collection.
	 */
	void minimizeRoots() shared {
		import d.gc.thread;
		enterBusyState();
		scope(exit) exitBusyState();

		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(GCState*) &this).minimizeRootsImpl();
	}

	int iterateRoots(R)(scope int delegate(ref R) nothrow dg) shared
	{
		try {
			import d.gc.thread;
			enterBusyState();
			scope(exit) exitBusyState();

			mutex.lock();
			scope(exit) mutex.unlock();

			return (cast(GCState*) &this).iterateRootsImpl(dg);
		} catch(Exception) {
			// ignore exceptions.
			// TODO: remove this when everything is correctly marked nothrow.
			return 0;
		}
	}

private:
	void addRootsImpl(const void[] range) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto ptr = cast(void*) roots.ptr;
		auto index = roots.length;
		auto length = index + 1;

		// We realloc every time. It doesn't really matter at this point.
		import d.gc.tcache;
		ptr = threadCache.realloc(ptr, length * void*[].sizeof, true);
		roots = (cast(const(void*)[]*) ptr)[0 .. length];

		import d.gc.range;
		if (range.length == 0) {
			roots[index] = cast(void*[]) range;
		} else {
			roots[index] = makeRange(range);
		}
	}

	void removeRootsImpl(const void* ptr) {
		assert(mutex.isHeld(), "Mutex not held!");

		import d.gc.util;
		import d.gc.spec;
		auto alignedPtr = alignUp(ptr, PointerSize);

		/**
		 * Search in reverse, since it's most likely for things to be removed
		 * in the reverse order they were added.
		 */
		foreach_reverse (i; 0 .. roots.length) {
			if (cast(void*) roots[i].ptr !is ptr
				    && cast(void*) roots[i].ptr !is alignedPtr) {
				continue;
			}

			auto length = roots.length - 1;
			roots[i] = roots[length];
			roots[length] = [];

			roots = roots[0 .. length];

			break;
		}
	}

	void minimizeRootsImpl() {
		assert(mutex.isHeld(), "Mutex not held!");

		auto length = roots.length;

		import d.gc.tcache;
		auto newRoots =
			threadCache.realloc(roots.ptr, length * void*[].sizeof, true);
		roots = (cast(const(void*)[]*) newRoots)[0 .. length];
	}

	void scanRootsImpl(ScanDg scan) {
		assert(mutex.isHeld(), "Mutex not held!");

		foreach (range; roots) {
			/**
			 * Adding a range of length 0 is like pinning the given range
			 * address. This is scanned when the roots array itself is scanned
			 * (because it's referred to from the global segment). Therefore,
			 * we can skip the marking of that pointer.
			 */
			if (range.length > 0) {
				scan(range);
			}
		}
	}

	import core.gc.gcinterface : Root, Range;
	int iterateRootsImpl(scope int delegate(ref Root) nothrow dg) nothrow
	{
		assert(mutex.isHeld(), "Mutex not held!");
		foreach (range; roots) {
			if(range.length == 0) {
				auto r = Root(cast(void*)range.ptr);
				if (auto ret = dg(r)) {
					return ret;
				}
			}
		}
		return 0;
	}

	int iterateRootsImpl(scope int delegate(ref Range) nothrow dg) nothrow
	{
		assert(mutex.isHeld(), "Mutex not held!");
		foreach (range; roots) {
			if(range.length >= 0) {
				auto r = Range(cast(void*)range.ptr, cast(void*)(range.ptr + range.length));
				if (auto ret = dg(r)) {
					return ret;
				}
			}
		}
		return 0;
	}
}

shared GCState gState;

// Note, this unittest is covered completely by integration test 202, and this
// does not fit well as a unittest since it leaves behind a lot of pinned
// garbage.
@"addRootReentrancy" unittest {
	import d.gc.capi;
	void*[10] unpinMe;
	foreach (i; 0 .. unpinMe.length) {
		enum BufferSize = 800_000_000;

		// Get the GC close past a collect threshold.
		auto ptr = __sd_gc_alloc(BufferSize);
		__sd_gc_add_roots(ptr[0 .. BufferSize]);
		unpinMe[i] = ptr;
	}
	foreach(p; unpinMe) {
		__sd_gc_remove_roots(p);
	}
}
