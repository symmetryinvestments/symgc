module d.gc.collector;

import d.gc.arena;
import d.gc.emap;
import d.gc.spec;
import d.gc.tcache;
import d.gc.time;
import d.gc.util;

struct Collector {
	ThreadCache* treadCache;

	this(ThreadCache* tc) {
		this.treadCache = tc;
	}

	@property
	ref CachedExtentMap emap() {
		return threadCache.emap;
	}

	bool maybeRunGCCycle() {
		return gCollectorState.maybeRunGCCycle(this);
	}

	void runGCCycle() {
		gCollectorState.mutex.lock();
		scope(exit) gCollectorState.mutex.unlock();

		runGCCycleLocked();
	}

private:
	void runGCCycleLocked() {
		assert(gCollectorState.mutex.isHeld(), "Mutex not held!");
		assert(!threadCache.state.busy, "Cannot run GC cycle while busy!");

		// Make sure we do not try to collect during a collection.
		auto oldGCActivationState = threadCache.activateGC(false);
		scope(exit) threadCache.activateGC(oldGCActivationState);

		import d.gc.global;
		auto gcCycle = gState.nextGCCycle();

		// set up the scanner
		import d.gc.scanner;

		// start the threads
		auto threadCount = gCollectorState.scanningThreads;
		if (threadCount == 0) {
			import d.gc.cpu;
			threadCount = getCoreCount();
			assert(threadCount >= 1, "Expected at least one thread!");
		}

		import symgc.thread;
		auto nScanningThreads = threadCount - 1;
		startGCThreads(nScanningThreads);

		import d.gc.thread;
		stopTheWorld();

		import d.gc.region;
		auto dataRange = gDataRegionAllocator.computeAddressRange();
		auto ptrRange = gPointerRegionAllocator.computeAddressRange();

		import d.gc.range;
		auto managedAddressSpace = dataRange.merge(ptrRange);

		prepareGCCycle();

		// Go on and on until all worklists are empty.
		markGC(gcCycle, managedAddressSpace);

		restartTheWorld();

		/**
		 * We might have allocated, and therefore refilled the bin
		 * during the collection process. As a result, slots in the
		 * bins may not be marked at this point.
		 *
		 * The straightforward way to handle this is simply to flush
		 * the bins.
		 *
		 * Alternatively, we could make sure the slots are marked.
		 */
		threadCache.flush();

		collect(gcCycle);

		/**
		 * Removing roots cannot realloc while inside a finalizer,
		 * because that could cause a deadlock. So we must periodically
		 * minimize the roots array, never when inside the collect
		 * phase.
		 */
		gState.minimizeRoots();

		// Probation period is over, threads can enter busy state now.
		clearWorldProbation();
	}

	void prepareGCCycle() {
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.prepareGCCycle(emap);
			}
		}
	}

	void collect(ubyte gcCycle) {
		threadCache.startCollection();
		scope(exit) threadCache.endCollection();
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.collect(emap, gcCycle);
			}
		}
	}
}

uint disableAutomaticCollections() {
	return gCollectorState.disableAutomaticCollections();
}

uint enableAutomaticCollections() {
	return gCollectorState.enableAutomaticCollections();
}

void collectorPrepareForFork() {
	gCollectorState.mutex.lock();
}

void collectorPostForkParent() {
	gCollectorState.mutex.unlock();
}

void collectorPostForkChild() {
	gCollectorState.mutex.__clear();
}

void setScanningThreads(uint nThreads) {
	gCollectorState.setScanningThreads(nThreads);
}

private:
struct CollectorState {
private:
	import d.sync.mutex;
	Mutex mutex;
	uint disableCount;

	// This makes for a 32MB default target.
	enum DefaultHeapSize = 32 * 1024 * 1024 / PageSize;

	/**
	 * Data about the last collection cycle.
	 */
	ulong lastCollectionStart;
	ulong lastCollectionStop;

	size_t lastHeapSize;

	/**
	 * Filtered data over several collection.
	 */
	ulong amortizedDuration;

	size_t amortizedHeapSize = DefaultHeapSize;
	size_t peakHeapSize = DefaultHeapSize;

	/**
	 * Track the targets to meet before collecting.
	 */
	ulong lastTargetAdjustement;

	size_t nextTarget = DefaultHeapSize;

	/**
	 * Configuration.
	 */
	// Do not try to collect bellow this heap size.
	size_t minHeapSize = DefaultHeapSize;

	// Decay by 12.5% per time interval.
	ubyte lgTargetDecay = 3;

	// Keep a minimum overhead of 12.5% over the current heap size.
	ubyte lgMinOverhead = 3;

	// How many threads to run for scanning. 0 to use the cpu count.
	uint scanningThreads = 0;

public:
	bool maybeRunGCCycle(ref Collector collector) shared {
		// Do not unnecessarily create contention on this mutex.
		if (!mutex.tryLock()) {
			return false;
		}

		scope(exit) mutex.unlock();
		return (cast(CollectorState*) &this).maybeRunGCCycleImpl(collector);
	}

	void setScanningThreads(uint nThreads) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(CollectorState*) &this).scanningThreads = nThreads;
	}

	uint disableAutomaticCollections() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this).disableAutomaticCollectionsImpl();
	}

	uint enableAutomaticCollections() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this).enableAutomaticCollectionsImpl();
	}

private:
	bool maybeRunGCCycleImpl(ref Collector collector) {
		assert(mutex.isHeld(), "mutex not held!");

		if (!needCollection()) {
			return false;
		}

		runGCCycle(collector);
		return true;
	}

	bool needCollection() {
		auto now = getMonotonicTime();
		auto interval =
			max(lastCollectionStop - lastCollectionStart, 100 * Millisecond);

		while (now - lastTargetAdjustement >= interval) {
			auto delta = nextTarget - lastHeapSize;
			delta -= delta >> lgTargetDecay;
			delta += lastHeapSize >> (lgTargetDecay + lgMinOverhead);
			nextTarget = lastHeapSize + delta;

			lastTargetAdjustement += interval;
		}

		if (disableCount > 0) {
			return false;
		}

		auto currentHeapSize = Arena.computeUsedPageCount();
		return currentHeapSize >= nextTarget;
	}

	void runGCCycle(ref Collector collector) {
		assert(mutex.isHeld(), "mutex not held!");

		lastCollectionStart = getMonotonicTime();
		scope(exit) updateTargetPageCount();

		collector.runGCCycleLocked();
	}

	void updateTargetPageCount() {
		// This creates a low pass filter.
		static next(size_t base, size_t n) {
			return base - (base >> 3) + (n >> 3);
		}

		lastCollectionStop = getMonotonicTime();
		amortizedDuration =
			next(amortizedDuration, lastCollectionStop - lastCollectionStart);

		lastHeapSize = Arena.computeUsedPageCount();
		amortizedHeapSize = next(amortizedHeapSize, lastHeapSize);
		peakHeapSize = max(next(peakHeapSize, lastHeapSize), lastHeapSize);

		// Peak target at 1.625x the peak to prevent heap explosion.
		auto tpeak = peakHeapSize + (peakHeapSize >> 1) + (peakHeapSize >> 3);

		// Baseline target at 2x so we don't shrink the heap too fast.
		auto tbaseline = 2 * amortizedHeapSize;

		// We set the target at 2x the current heap size.
		auto target = 2 * lastHeapSize;

		// Clamp the target using tpeak and tbaseline.
		target = max(target, tbaseline);
		target = min(target, tpeak);

		lastTargetAdjustement = lastCollectionStop;
		nextTarget = max(target, minHeapSize);
	}

	uint disableAutomaticCollectionsImpl() {
		assert(mutex.isHeld(), "mutex not held!");

		return disableCount++;
	}

	uint enableAutomaticCollectionsImpl() {
		assert(mutex.isHeld(), "mutex not held!");
		assert(disableCount > 0);

		return disableCount--;
	}
}

shared CollectorState gCollectorState;
