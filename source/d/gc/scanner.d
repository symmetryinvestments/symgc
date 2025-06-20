module d.gc.scanner;

import symgc.intrinsics;

import d.gc.emap;
import d.gc.hooks;
import d.gc.range;
import d.gc.slab;
import d.gc.spec;
import d.gc.util;
import d.gc.tcache;

void startGCThreads(uint nThreads) {
	(cast(Scanner*)&gScanner).startThreads(nThreads);
}

void cleanupGCThreads() {
	(cast(Scanner*)&gScanner).joinThreads();
}

void markGC(ubyte gcCycle, AddressRange managedSpace) {
	gScanner.mark(gcCycle, managedSpace);
}

private:
struct ScanningList {
	@disable this(this);
	WorkItem[] worklist;
	int activeThreads;
	uint cursor;
	enum MaxRefill = 4;
	// we want to use the main thread's tcache when reallocating to avoid populating
	// the threadcache of all the scanning threads with stuff.
	ThreadCache* threadCache;

	version(Windows) {
		// The windows implementation uses a similar mechanism to the druntime GC,
		// since most locking schemes do not work on Windows with threads paused.
		// Synchronizing the work list is done via a spinlock and an event system.
		import core.internal.spinlock;
		import core.sync.event;

		shared SpinLock _spinlock;
		Event workReadyEvent;
		Event gcStartedEvent;

		void initialize() {
			this.threadCache = &.threadCache;
			_spinlock = SpinLock(SpinLock.Contention.brief);
			workReadyEvent.initialize(true, false);
			gcStartedEvent.initialize(true, false);
		}

		void addToWorkList(WorkItem[] items) shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			(cast(ScanningList*) &this).addToWorkListImpl(items);

			(cast(Event*)&workReadyEvent).setIfInitialized();
			(cast(Event*)&gcStartedEvent).setIfInitialized();
		}

		// Note: SpinLock does not provide this information, even though it could.
		bool mutexIsHeld() => true;

		void mainThreadStarted() shared {
			auto w = (cast(ScanningList*) &this);

			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			++w.activeThreads;
		}

		void stopScanningThreads() shared {
			auto w = (cast(ScanningList*) &this);

			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			// need to make the active threads go to -1
			--w.activeThreads;
			(cast(Event*)&gcStartedEvent).setIfInitialized();
		}

		bool waitForGCStart() shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			auto w = (cast(ScanningList*) &this);

			/**
			* We wait for work to be present in the worklist or the
			* active threads to be negative (meaning the scanning thread should exit)
			*/
			while(!w.hasStarted()) {
				w.gcStartedEvent.reset();
				_spinlock.unlock();
				w.gcStartedEvent.wait();
				_spinlock.lock();
			}

			if (w.activeThreads == -1) {
				// trying to stop GC threads. Wake up anyone else who is waiting.
				w.gcStartedEvent.setIfInitialized();
				return false;
			}

			// this thread now active
			++w.activeThreads;
			return true;
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
			this.threadCache = &.threadCache;
		}

		bool mutexIsHeld() => _mutex.isHeld();

		void addToWorkList(WorkItem[] items) shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			(cast(ScanningList*) &this).addToWorkListImpl(items);
		}

		void mainThreadStarted() shared {
			auto w = (cast(ScanningList*) &this);

			_mutex.lock();
			scope(exit) _mutex.unlock();

			// ready to receive scan work.
			++w.activeThreads;
		}

		void stopScanningThreads() shared {
			auto w = (cast(ScanningList*) &this);

			_mutex.lock();
			scope(exit) _mutex.unlock();

			// need to make the active threads go to -1
			--w.activeThreads;
		}

		bool waitForGCStart() shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			auto w = (cast(ScanningList*) &this);
			_mutex.waitFor(&w.hasStarted);

			if(w.activeThreads == -1) {
				// exiting GC threads
				return false;
			}

			// this thread is now active
			++w.activeThreads;
			return true;
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

	void startGCScan() shared {
		// note, we don't take the lock here, because there should be no work before a scan starts, and there should be no work when a scan ends.
		assert(cursor == 0, "starting a GC scan, but still data to scan!");
		this.threadCache = cast(shared)&.threadCache;

		mainThreadStarted(); // indicate the main thread is participating.
	}

	auto hasStarted() {
		return cursor != 0 || activeThreads < 0;
	}

	auto hasWork() {
		return cursor != 0 || activeThreads <= 0;
	}

	void ensureWorklistCapacity(size_t count) {
		assert(mutexIsHeld(), "mutex not held!");
		assert(count < uint.max, "Cannot reserve this much capacity!");
		assert(threadCache !is null, "threadCache is null!");

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
		(cast(ThreadCache*)threadCache).free(cast(void*) worklist.ptr);

		worklist = null;
		threadCache = null;
	}
}

struct Scanner {
private:
	ScanningList work;

	ubyte _gcCycle;
	AddressRange _managedAddressSpace;

	ThreadHandle[] threads;

public:

	@property
	AddressRange managedAddressSpace() shared {
		return (cast(Scanner*) &this)._managedAddressSpace;
	}

	@property
	ubyte gcCycle() shared {
		return (cast(Scanner*) &this)._gcCycle;
	}

	private import symgc.thread;
	void startThreads(uint nThreads) {
		if (threads.length != 0) {
			// threads already running.
			return;
		}

		threads = (cast(ThreadHandle*)threadCache.alloc(ThreadHandle.sizeof * nThreads, false, false))[0 .. nThreads];

		work.initialize();
		static void markThreadEntry(void* ctx) {
			import d.gc.tcache;
			threadCache.activateGC(false);

			// Set a flag saying we should not be using our local thread cache.
			// The only allocations/free we should be doing is to resize the work list.
			// Note that scanning threads DO NOT have their stack or TLS scanned,
			// so we can't put any pointers in there that will become garbage.
			threadCache.setIsScanningThread();

			auto scanner = cast(shared(Scanner)*) ctx;

			while(scanner.work.waitForGCStart()) {
				scanner.runMarkFromScanThread();
			}
		}

		// we use a static ThreadRunner because bad things happen if this memory
		// gets collected before the thread can start.
		static ThreadRunner!(typeof(&markThreadEntry)) staticRunner;

		// allocate an array to hold the threads.
		staticRunner.fun = &markThreadEntry;
		staticRunner.arg = cast(void*) &this;
		foreach (ref tid; threads) {
			createGCThread(&tid, &staticRunner);
		}
	}

	void joinThreads() {

		if (threads.length > 0) {
			(cast(shared ScanningList*)&work).stopScanningThreads();
			foreach (tid; threads) {
				joinGCThread(tid);
			}

			// free the thread array
			threadCache.free(threads.ptr);
			threads = null;
		}

		// destroy the work object, it might have OS resources allocated for it.
		destroy(work);
	}

	void mark(ubyte gcCycle, AddressRange managedSpace) shared {
		// set up the address space and the gc cycle. These change every mark phase.
		this._managedAddressSpace = managedSpace;
		this._gcCycle = gcCycle;

		// start the GC
		work.startGCScan();

		// Scan the roots.
		// TODO: this cast is awful, see if we can fix this.
		__sd_gc_global_scan(cast(void delegate(const(void*)[]))&processGlobal);

		// Now send this thread marking!
		runMarkFromMainThread();

		// all work is done, clean up the work list.
		work.cleanup();
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
		runMarkImpl!true();
	}

	void runMarkFromScanThread() shared {
		runMarkImpl!false();
	}

	void runMarkImpl(bool mainThread)() shared {
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

		auto worker = Worker(&this);

		static if(mainThread) {
			// on the main thread, scan the stack and TLS of the thread.
			worker.setScanParameters();
			import d.gc.thread;
			threadScan(&worker.scan);
		}

		WorkItem[ScanningList.MaxRefill] refill;

		while (true) {
			auto count = work.waitForWork(refill);
			if (count == 0) {
				// We are done, there is no more work items.
				return;
			}
			// wait until we get work to set the scan parameters (gc cycle and address range).
			worker.setScanParameters();

			foreach (i; 0 .. count) {
				worker.scan(refill[i]);
			}
		}
	}
}

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
	}

	void setScanParameters() {
		// set up the scan parameters for this batch of scanning.
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

shared Scanner gScanner;

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
