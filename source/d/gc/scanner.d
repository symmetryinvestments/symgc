module d.gc.scanner;
version(none):

import sdc.intrinsics;

import d.gc.emap;
import d.gc.hooks;
import d.gc.range;
import d.gc.spec;
import d.gc.util;

struct Scanner {
private:
	import d.sync.mutex;
	Mutex mutex;

	uint activeThreads;
	uint cursor;
	WorkItem[] worklist;

	ubyte _gcCycle;
	AddressRange _managedAddressSpace;

	enum MaxRefill = 4;

public:
	this(uint threadCount, ubyte gcCycle, AddressRange managedAddressSpace) {
		activeThreads = threadCount;

		this._gcCycle = gcCycle;
		this._managedAddressSpace = managedAddressSpace;
	}

	this(ubyte gcCycle, AddressRange managedAddressSpace) {
		import d.gc.cpu;
		auto nthreads = getCoreCount();
		assert(nthreads >= 1, "Expected at least one thread!");

		this(nthreads, gcCycle, managedAddressSpace);
	}

	@property
	AddressRange managedAddressSpace() shared {
		return (cast(Scanner*) &this)._managedAddressSpace;
	}

	@property
	ubyte gcCycle() shared {
		return (cast(Scanner*) &this)._gcCycle;
	}

	void mark() shared {
		import core.stdc.pthread;
		auto threadCount = activeThreads - 1;
		auto threadsPtr =
			cast(pthread_t*) alloca(pthread_t.sizeof * threadCount);
		auto threads = threadsPtr[0 .. threadCount];

		static void* markThreadEntry(void* ctx) {
			import d.gc.tcache;
			threadCache.activateGC(false);

			(cast(shared(Scanner*)) ctx).runMark();
			return null;
		}

		// First thing, start the worker threads, so they can do work ASAP.
		foreach (ref tid; threads) {
			pthread_create(&tid, null, markThreadEntry, cast(void*) &this);
		}

		// Scan the roots.
		__sd_gc_global_scan(addToWorkList);

		// Now send this thread marking!
		runMark();

		// We now done, we can free the worklist.
		import d.gc.tcache;
		threadCache.free(cast(void*) worklist.ptr);

		foreach (tid; threads) {
			void* ret;
			pthread_join(tid, &ret);
		}
	}

	void addToWorkList(WorkItem[] items) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(Scanner*) &this).addToWorkListImpl(items);
	}

	void addToWorkList(WorkItem item) shared {
		addToWorkList((&item)[0 .. 1]);
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

			addToWorkList(units[0 .. count]);
		}
	}

private:
	void runMark() shared {
		auto worker = Worker(&this);

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
		 */
		import d.gc.thread;
		threadScan(worker.scan);

		WorkItem[MaxRefill] refill;
		while (true) {
			auto count = waitForWork(refill);
			if (count == 0) {
				// We are done, there is no more work items.
				return;
			}

			foreach (i; 0 .. count) {
				worker.scan(refill[i]);
			}
		}
	}

	uint waitForWork(ref WorkItem[MaxRefill] refill) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		activeThreads--;

		/**
		 * We wait for work to be present in the worklist.
		 * If there is, then we pick it up and start marking.
		 *
		 * Alternatively, if there is no work to do, and the number
		 * of active thread is 0, then we know no more work is coming
		 * and we should stop.
		 */
		static hasWork(Scanner* w) {
			return w.cursor != 0 || w.activeThreads == 0;
		}

		auto w = (cast(Scanner*) &this);
		mutex.waitFor(w.hasWork);

		if (w.cursor == 0) {
			return 0;
		}

		activeThreads++;

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

	void ensureWorklistCapacity(size_t count) {
		assert(mutex.isHeld(), "mutex not held!");
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
		assert(mutex.isHeld(), "mutex not held!");
		assert(0 < items.length && items.length < uint.max,
		       "Invalid item count!");

		auto capacity = cursor + items.length;
		ensureWorklistCapacity(capacity);

		foreach (item; items) {
			worklist[cursor++] = item;
		}
	}
}

private:

struct Worker {
	enum WorkListCapacity = 16;

private:
	shared(Scanner)* scanner;

	uint cursor;
	WorkItem[WorkListCapacity] worklist;

	// TODO: Use a different caching layer that
	//       can cache negative results.
	CachedExtentMap emap;

public:
	this(shared(Scanner)* scanner) {
		this.scanner = scanner;

		import d.gc.tcache;
		this.emap = threadCache.emap;
	}

	void scan(const(void*)[] range) {
		while (range.length > 0) {
			scan(WorkItem.extractFromRange(range));
		}
	}

	void scan(WorkItem item) {
		auto ms = scanner.managedAddressSpace;
		auto cycle = scanner.gcCycle;

		AddressRange lastDenseSlab;
		PageDescriptor lastDenseSlabPageDescriptor;

		import d.gc.slab;
		BinInfo lastDenseBin;

		while (true) {
			auto range = item.range;
			auto current = range.ptr;
			auto top = current + range.length;

			for (; current < top; current++) {
				auto ptr = *current;
				if (!ms.contains(ptr)) {
					// This is not a pointer, move along.
					continue;
				}

				if (lastDenseSlab.contains(ptr)) {
				MarkDense:
					auto base = lastDenseSlab.ptr;
					auto offset = ptr - base;
					auto index = lastDenseBin.computeIndex(offset);

					auto pd = lastDenseSlabPageDescriptor;
					auto slotSize = lastDenseBin.slotSize;

					if (!markDense(pd, index)) {
						continue;
					}

					if (!pd.containsPointers) {
						continue;
					}

					auto i = WorkItem(base + index * slotSize, slotSize);
					if (likely(cursor < WorkListCapacity)) {
						worklist[cursor++] = i;
						continue;
					}

					/**
					 * We want to make sure that no matter what, this worker processes
					 * the WorkItem it is provided directly. Everything else in the
					 * worklist can be sent to other threads.
					 */
					scanner.addToWorkList(worklist[0 .. WorkListCapacity]);

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
					lastDenseSlabPageDescriptor = pd;
					lastDenseBin = binInfos[ec.sizeClass];

					lastDenseSlab =
						AddressRange(aptr - pd.index * PageSize,
						             lastDenseBin.npages * PointerInPage);

					goto MarkDense;
				}

				if (ec.isLarge()) {
					if (!markLarge(pd, cycle)) {
						continue;
					}

					auto capacity = e.usedCapacity;
					if (!pd.containsPointers || capacity < PointerSize) {
						continue;
					}

					auto range = makeRange(e.address, e.address + capacity);

					// Make sure we do not starve ourselves. If we do not have
					// work in advance, then just keep some of it for ourselves.
					if (cursor == 0) {
						worklist[cursor++] = WorkItem.extractFromRange(range);
					}

					scanner.addToWorkList(range);
					continue;
				}

				import d.gc.slab;
				auto se = SlabEntry(pd, ptr);
				if (!markSparse(pd, se.index, cycle)) {
					continue;
				}

				if (!pd.containsPointers) {
					continue;
				}

				// Make sure we do not starve ourselves. If we do not have
				// work in advance, then just keep some of it for ourselves.
				auto i = WorkItem(se.computeRange());
				if (cursor == 0) {
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
		if (ec.supportsInlineMarking) {
			if (e.slabMetadataMarks.setBitAtomic(index)) {
				return false;
			}
		} else {
			auto bmp = &e.outlineMarks;
			if (bmp is null || bmp.setBitAtomic(index)) {
				return false;
			}
		}

		return true;
	}

	static bool markSparse(PageDescriptor pd, uint index, ubyte cycle) {
		auto bit = 0x100 << index;

		auto e = pd.extent;
		auto old = e.gcWord.load();
		while ((old & 0xff) != cycle) {
			if (e.gcWord.casWeak(old, cycle | bit)) {
				return true;
			}
		}

		if (old & bit) {
			return false;
		}

		old = e.gcWord.fetchOr(bit);
		return (old & bit) == 0;
	}

	static bool markLarge(PageDescriptor pd, ubyte cycle) {
		auto e = pd.extent;
		auto old = e.gcWord.load();
		while (true) {
			if (old == cycle) {
				return false;
			}

			if (e.gcWord.casWeak(old, cycle)) {
				return true;
			}
		}
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
}
