module d.gc.scanner;

import symgc.intrinsics;

import d.gc.emap;
import d.gc.hooks;
import d.gc.range;
import d.gc.slab;
import d.gc.spec;
import d.gc.util;

private struct ScanningList {
	@disable this(this);
	WorkItem[] worklist;
	uint activeThreads;
	uint cursor;
	enum MaxRefill = 4;

	version(Windows) {
		// The windows implementation uses a similar mechanism to the druntime GC,
		// since most locking schemes do not work on Windows with threads paused.
		// Synchronizing the work list is done via a spinlock and an event system.
		import core.internal.spinlock;
		import core.sync.event;

		shared SpinLock _spinlock;
		Event workReadyEvent;

		void initialize() {
			_spinlock = SpinLock(SpinLock.Contention.brief);
			workReadyEvent.initialize(true, false);
			this.activeThreads = 1;
		}

		void addToWorkList(WorkItem[] items) shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			(cast(ScanningList*) &this).addToWorkListImpl(items);

			(cast(Event*)&workReadyEvent).setIfInitialized();
		}

		// Note: SpinLock does not provide this information, even though it could.
		bool mutexIsHeld() => true;

		void scanThreadStarted() shared {
			auto w = (cast(ScanningList*) &this);

			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			++w.activeThreads;
		}

		uint waitForWork(ref WorkItem[MaxRefill] refill) shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			auto w = (cast(ScanningList*) &this);
			w.activeThreads--;

			/**
			* We wait for work to be present in the worklist.
			* If there is, then we pick it up and start marking.
			*
			* Alternatively, if there is no work to do, and the number
			* of active thread is 0, then we know no more work is coming
			* and we should stop.
			*/
			while(!w.hasWork()) {
				w.workReadyEvent.reset();
				_spinlock.unlock();
				w.workReadyEvent.wait();
				_spinlock.lock();
			}

			if (w.cursor == 0) {
				w.workReadyEvent.setIfInitialized(); // no more work, let everyone know.
				return 0;
			}

			w.activeThreads++;

			uint count = 1;
			uint top = w.cursor;

			refill[0] = w.worklist[top - count];
			auto length = refill[0].length;

			foreach (i; 1 .. min(top, MaxRefill)) {
				auto next = w.worklist[top - count - 1];

				auto nl = length + next.length;
				if (nl > WorkItem.WorkUnit / 2) {
					break;
				}

				count++;
				length = nl;
				refill[i] = next;
			}

			w.cursor = top - count;
			if (w.cursor == 0) {
				// reset the event, no work is ready any more
				w.workReadyEvent.reset();
			}
			return count;
		}
	}
	else
	{
		import d.sync.mutex;
		Mutex _mutex;
		void initialize() {
			this.activeThreads = 1;
		}

		bool mutexIsHeld() => _mutex.isHeld();

		void addToWorkList(WorkItem[] items) shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			(cast(ScanningList*) &this).addToWorkListImpl(items);
		}

		void scanThreadStarted() shared {
			auto w = (cast(ScanningList*) &this);

			_mutex.lock();
			scope(exit) _mutex.unlock();

			// ready to receive scan work.
			++w.activeThreads;
		}

		uint waitForWork(ref WorkItem[MaxRefill] refill) shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			auto w = (cast(ScanningList*) &this);
			w.activeThreads--;

			/**
			* We wait for work to be present in the worklist.
			* If there is, then we pick it up and start marking.
			*
			* Alternatively, if there is no work to do, and the number
			* of active thread is 0, then we know no more work is coming
			* and we should stop.
			*/
			_mutex.waitFor(&w.hasWork);

			if (w.cursor == 0) {
				return 0;
			}

			w.activeThreads++;

			uint count = 1;
			uint top = w.cursor;

			refill[0] = w.worklist[top - count];
			auto length = refill[0].length;

			foreach (i; 1 .. min(top, MaxRefill)) {
				auto next = w.worklist[top - count - 1];

				auto nl = length + next.length;
				if (nl > WorkItem.WorkUnit / 2) {
					break;
				}

				count++;
				length = nl;
				refill[i] = next;
			}

			w.cursor = top - count;
			return count;
		}
	}

	auto hasWork() {
		return cursor != 0 || activeThreads == 0;
	}

	void ensureWorklistCapacity(size_t count) {
		assert(mutexIsHeld(), "mutex not held!");
		assert(count < uint.max, "Cannot reserve this much capacity!");

		if (likely(count <= worklist.length)) {
			return;
		}

		enum MinWorklistSize = 4 * PageSize;

		auto size = count * WorkItem.sizeof;
		if (size < MinWorklistSize) {
			size = MinWorklistSize;
		} else {
			import d.gc.sizeclass;
			size = getAllocSize(count * WorkItem.sizeof);
		}

		import d.gc.tcache;
		auto ptr = threadCache.realloc(worklist.ptr, size, false);
		worklist = (cast(WorkItem*) ptr)[0 .. size / WorkItem.sizeof];
	}

	void addToWorkListImpl(WorkItem[] items) {
		assert(mutexIsHeld(), "mutex not held!");
		assert(0 < items.length && items.length < uint.max,
		       "Invalid item count!");

		auto capacity = cursor + items.length;
		ensureWorklistCapacity(capacity);

		foreach (item; items) {
			worklist[cursor++] = item;
		}
	}

	void cleanup() shared {
		assert(activeThreads == 0, "Still running threads!");

		// We now done, we can free the worklist.
		import d.gc.tcache;
		threadCache.free(cast(void*) worklist.ptr);

		worklist = null;
	}
}

struct Scanner {
private:
	ScanningList work;

	ubyte _gcCycle;
	AddressRange _managedAddressSpace;

public:
	this(ubyte gcCycle) {
		this._gcCycle = gcCycle;
	}

	@property
	AddressRange managedAddressSpace() shared {
		return (cast(Scanner*) &this)._managedAddressSpace;
	}

	@property
	ubyte gcCycle() shared {
		return (cast(Scanner*) &this)._gcCycle;
	}

	private import symgc.thread;
	void startThreads(ThreadHandle[] threads) {
		work.initialize();
		static void markThreadEntry(void* ctx) {
			import d.gc.tcache;
			threadCache.activateGC(false);

			auto scanner = cast(shared(Scanner)*) ctx;
			// Deferring becoming active until the thread is fully started
			// allows the scan to complete if this thread couldn't start (which
			// can happen in the case of a race between the thread starting and
			// a paused thread holding a critical lock needed to start
			// threads).
			scanner.work.scanThreadStarted();
			scanner.runMark();
		}

		foreach (ref tid; threads) {
			createGCThread(&tid, &markThreadEntry, cast(void*) &this);
		}
	}

	void joinThreads(ThreadHandle[] threads) shared {
		foreach (tid; threads) {
			joinGCThread(tid);
		}

		work.cleanup();
	}

	void mark(AddressRange managedSpace) shared {
		this._managedAddressSpace = managedSpace;

		// Scan the roots.
		// TODO: this cast is awful, see if we can fix this.
		__sd_gc_global_scan(cast(void delegate(const(void*)[]))&processGlobal);

		// Now send this thread marking!
		runMarkFromMainThread();
	}

	void addToWorkList(WorkItem item) shared {
		work.addToWorkList((&item)[0 .. 1]);
	}

	void processGlobal(const(void*)[] range) shared {
		addToWorkList(range);
	}

	void addToWorkList(const(void*)[] range) shared {
		// In order to expose some parallelism, we split the range
		// into smaller chunks to be distributed.
		while (range.length > 0) {
			uint count;
			WorkItem[16] units;

			foreach (ref u; units) {
				if (range.length == 0) {
					break;
				}

				count++;
				u = WorkItem.extractFromRange(range);
			}

			work.addToWorkList(units[0 .. count]);
		}
	}

private:

	void runMarkFromMainThread() shared {
		auto worker = Worker(&this);
		import d.gc.thread;
		threadScan(&worker.scan);

		runMarkImpl(worker);
	}
	void runMark() shared {
		auto worker = Worker(&this);
		runMarkImpl(worker);
	}

	void runMarkImpl(ref Worker worker) shared {
		/**
		 * Scan the stack and TLS.
		 *
		 * It may seems counter intuitive that we do so for worker threads
		 * as well, but it turns out to be necessary. NPTL caches resources
		 * necessary to start a thread after a thread exits, to be able to
		 * restart new ones quickly and cheaply.
		 *
		 * Because we start and stop threads during the mark phase, we are
		 * at risk of missing pointers allocated for thread management resources
		 * and corrupting the internal of the standard C library.
		 *
		 * This is NOT good! So we scan here to make sure we don't miss anything.
		 *
		 * Note: this is only relevant if the C malloc calls are replaced with the
		 * GC allocation calls which is not a thing we can do universally. Since
		 * this prospect is dicey, there is no reason to do this, and this allows
		 * us to avoid an extra startup sync.
		 */
		// import d.gc.thread;
		// threadScan(&worker.scan);

		WorkItem[ScanningList.MaxRefill] refill;
		auto count = work.waitForWork(refill);
		// had to wait until now to be sure the managed address space is correct
		worker.managedAddressSpace = managedAddressSpace;
		while (true) {
			if (count == 0) {
				// We are done, there is no more work items.
				return;
			}

			foreach (i; 0 .. count) {
				worker.scan(refill[i]);
			}
			count = work.waitForWork(refill);
		}
	}
}

private:

struct LastDenseSlabCache {
	AddressRange slab;
	PageDescriptor pageDescriptor;
	BinInfo bin;

	this(AddressRange slab, PageDescriptor pageDescriptor, BinInfo bin) {
		this.slab = slab;
		this.pageDescriptor = pageDescriptor;
		this.bin = bin;
	}
}

struct Worker {
private:
	shared(Scanner)* scanner;

	// TODO: Use a different caching layer that
	//       can cache negative results.
	CachedExtentMap emap;

	/**
	 * Cold elements that benefit from being kept alive
	 * across scan calls.
	 */
	AddressRange managedAddressSpace;
	ubyte gcCycle;

	LastDenseSlabCache ldsCache;

public:
	this(shared(Scanner)* scanner) {
		this.scanner = scanner;

		import d.gc.tcache;
		this.emap = threadCache.emap;

		this.managedAddressSpace = scanner.managedAddressSpace;
		this.gcCycle = scanner.gcCycle;
	}

	void scan(const(void*)[] range) {
		while (range.length > 0) {
			scan(WorkItem.extractFromRange(range));
		}
	}

	void scan(WorkItem item) {
		scanImpl!true(item, ldsCache);
	}

	void scanBreadthFirst(WorkItem item, LastDenseSlabCache cache) {
		scanImpl!false(item, cache);
	}

	void scanImpl(bool DepthFirst)(WorkItem item, LastDenseSlabCache cache) {
		auto ms = managedAddressSpace;

		scope(success) {
			if (DepthFirst) {
				ldsCache = cache;
			}
		}

		// Depth first doesn't really need a worklist,
		// but this makes sharing code easier.
		enum WorkListCapacity = DepthFirst ? 1 : 16;

		uint cursor;
		WorkItem[WorkListCapacity] worklist;

		while (true) {
			auto r = item.range;
			auto current = r.ptr;
			auto top = current + r.length;

			for (; current < top; current++) {
				auto ptr = *current;
				if (!ms.contains(ptr)) {
					// This is not a pointer, move along.
					continue;
				}

				if (cache.slab.contains(ptr)) {
				MarkDense:
					auto base = cache.slab.ptr;
					auto offset = ptr - base;

					auto ldb = cache.bin;
					auto index = ldb.computeIndex(offset);

					auto pd = cache.pageDescriptor;
					assert(pd.extent !is null);
					assert(pd.extent.contains(ptr));

					if (!markDense(pd, index)) {
						continue;
					}

					if (!pd.containsPointers) {
						continue;
					}

					auto slotSize = ldb.slotSize;
					auto i = WorkItem(base + index * slotSize, slotSize);
					if (DepthFirst) {
						scanBreadthFirst(i, cache);
						continue;
					}

					if (likely(cursor < WorkListCapacity)) {
						worklist[cursor++] = i;
						continue;
					}

					scanner.work.addToWorkList(worklist[0 .. WorkListCapacity]);

					cursor = 1;
					worklist[0] = i;
					continue;
				}

				auto aptr = alignDown(ptr, PageSize);
				auto pd = emap.lookup(aptr);

				auto e = pd.extent;
				if (e is null) {
					// We have no mapping here, move on.
					continue;
				}

				auto ec = pd.extentClass;
				if (ec.dense) {
					assert(e !is cache.pageDescriptor.extent);

					auto ldb = binInfos[ec.sizeClass];
					auto lds = AddressRange(aptr - pd.index * PageSize,
					                        ldb.npages * PageSize);

					cache = LastDenseSlabCache(lds, pd, ldb);
					goto MarkDense;
				}

				if (ec.isLarge()) {
					if (!markLarge(pd, gcCycle)) {
						continue;
					}

					/*
					auto capacity = e.usedCapacity;
					/*/
					auto capacity = e.size;
					// */
					if (!pd.containsPointers || capacity < PointerSize) {
						continue;
					}

					auto range = makeRange(e.address, e.address + capacity);

					// Make sure we do not starve ourselves. If we do not have
					// work in advance, then just keep some of it for ourselves.
					if (DepthFirst && cursor == 0) {
						worklist[cursor++] = WorkItem.extractFromRange(range);
					}

					scanner.addToWorkList(range);
					continue;
				}

				auto se = SlabEntry(pd, ptr);
				if (!markSparse(pd, se.index, gcCycle)) {
					continue;
				}

				if (!pd.containsPointers) {
					continue;
				}

				// Make sure we do not starve ourselves. If we do not have
				// work in advance, then just keep some of it for ourselves.
				auto i = WorkItem(se.computeRange());
				if (DepthFirst && cursor == 0) {
					worklist[cursor++] = i;
				} else {
					scanner.addToWorkList(i);
				}
			}

			// In case we reached our limit, we bail. This ensures that
			// we can scan iteratively.
			if (cursor == 0) {
				return;
			}

			item = worklist[--cursor];
		}
	}

private:
	static bool markDense(PageDescriptor pd, uint index) {
		auto e = pd.extent;

		/**
		 * /!\ This is not thread safe.
		 *
		 * In the context of concurrent scans, slots might be
		 * allocated/deallocated from the slab while we scan.
		 * It is unclear how to handle this at this time.
		 */
		if (!e.slabData.valueAt(index)) {
			return false;
		}

		auto ec = pd.extentClass;
		return e.markDenseSlot(index);
	}

	static bool markSparse(PageDescriptor pd, uint index, ubyte cycle) {
		auto e = pd.extent;
		return e.markSparseSlot(cycle, index);
	}

	static bool markLarge(PageDescriptor pd, ubyte cycle) {
		auto e = pd.extent;
		return e.markLarge(cycle);
	}
}

struct WorkItem {
private:
	size_t payload;

	// Verify our assumptions.
	static assert(LgAddressSpace <= 48, "Address space too large!");

	// Useful constants for bit manipulations.
	enum LengthShift = 48;
	enum FreeBits = 8 * PointerSize - LengthShift;

	// Scan parameter.
	enum WorkUnit = 16 * PointerInPage;

public:
	@property
	void* ptr() {
		return cast(void*) (payload & AddressMask);
	}

	@property
	size_t length() {
		auto ptrlen = 1 + (payload >> LengthShift);
		return ptrlen * PointerSize;
	}

	@property
	const(void*)[] range() {
		auto base = cast(void**) ptr;
		return base[0 .. length / PointerSize];
	}

	this(const void* ptr, size_t length) {
		assert(isAligned(ptr, PointerSize), "Invalid ptr!");
		assert(length >= PointerSize, "WorkItem cannot be empty!");

		auto storedLength = length / PointerSize - 1;
		assert(storedLength < (1 << FreeBits), "Invalid length!");

		payload = cast(size_t) ptr;
		payload |= storedLength << LengthShift;
	}

	this(const(void*)[] range) {
		assert(range.length > 0, "WorkItem cannot be empty!");
		assert(range.length <= (1 << FreeBits), "Invalid length!");

		payload = cast(size_t) range.ptr;
		payload |= (range.length - 1) << LengthShift;
	}

	static extractFromRange(ref const(void*)[] range) {
		assert(range.length > 0, "range cannot be empty!");

		enum SplitThresold = 3 * WorkUnit / 2;

		// We use this split strategy as it guarantee that any straggler
		// work item will be between 1/2 and 3/2 work unit.
		if (range.length <= SplitThresold) {
			scope(success) range = [];
			return WorkItem(range);
		}

		scope(success) range = range[WorkUnit .. range.length];
		return WorkItem(range[0 .. WorkUnit]);
	}
}

@"WorkItem" unittest {
	void* stackPtr;
	void* ptr = &stackPtr;

	foreach (i; 0 .. 1 << WorkItem.FreeBits) {
		auto n = i + 1;

		foreach (k; 0 .. PointerSize) {
			auto item = WorkItem(ptr, n * PointerSize + k);
			assert(item.ptr is ptr);
			assert(item.length == n * PointerSize);

			auto range = item.range;
			assert(range.ptr is cast(const(void*)*) ptr);
			assert(range.length == n);

			auto ir = WorkItem(range);
			assert(item.payload == ir.payload);
		}
	}

	enum WorkUnit = WorkItem.WorkUnit;
	enum MaxUnit = 3 * WorkUnit / 2;

	foreach (size; 1 .. MaxUnit + 1) {
		auto range = (cast(const(void*)*) ptr)[0 .. size];
		auto w = WorkItem.extractFromRange(range);
		assert(w.ptr is ptr);
		assert(w.length is size * PointerSize);

		assert(range.length == 0);
	}

	foreach (size; MaxUnit + 1 .. MaxUnit + WorkUnit + 1) {
		auto range = (cast(const(void*)*) ptr)[0 .. size];
		auto w = WorkItem.extractFromRange(range);

		assert(w.ptr is ptr);
		assert(w.length is WorkUnit * PointerSize);

		assert(range.length == size - WorkUnit);

		w = WorkItem.extractFromRange(range);
		assert(w.ptr is ptr + WorkUnit * PointerSize);
		assert(w.length is (size - WorkUnit) * PointerSize);

		assert(range.length == 0);
	}
}
