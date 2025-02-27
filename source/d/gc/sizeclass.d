module d.gc.sizeclass;
version(none):

import d.gc.spec;
import d.gc.util;

/**
 * Designing a good allocator require to balance external
 * and internal fragmentation. Allocating exactly the amount
 * of memory requested by the user would ensure internal
 * fragmentation remains at zero - not space would be wasted
 * over allocating - but there would be too many allocations
 * with a unique size, which cases external fragmentation.
 * On the other hand, over allocating too much, for instance
 * by allocating the next power of 2 bytes, causes internal
 * fragmentation.
 * 
 * We want to keep fragmentation at a minimum so that we can
 * minimize the amount of memory that is wasted, which in turn
 * translates into better performances as teh pressure caches
 * and TLB is reduced.
 * 
 * As a compromise, the GC rounds up the requested allocation
 * to the closest size of the form `(4 + delta) << shift`
 * where delta is in the [0 .. 4) range. Each allocation is
 * then associated with a bin based oe the required allocation
 * size. This binning is a good compromise between internal
 * and external fragmentation in typical workloads.
 * 
 * The smallest possible delta is bounded by the Quantum.
 * This ensures that any allocation is Quantum aligned.
 * 
 * Size classes bellow 4 * Quantum are know as Tiny. Tiny
 * classes are special cased so finer granularity can be
 * provided at that level.
 */
enum ClassCount {
	Tiny = getTinyClassCount(),
	Small = getSmallClassCount(),
	Large = getLargeClassCount(),
	Total = getTotalClassCount(),
	Lookup = getLookupClassCount(),
}

enum MaxTinySize = ClassCount.Tiny * Quantum;
enum BinCount = ClassCount.Small;

// Determine whether given size class is considered 'small' (slab-allocatable).
bool isSmallSizeClass(uint sizeClass) {
	return sizeClass < ClassCount.Small;
}

bool isLargeSizeClass(uint sizeClass) {
	return sizeClass >= ClassCount.Small && sizeClass < ClassCount.Large;
}

bool isHugeSizeClass(uint sizeClass) {
	return sizeClass >= ClassCount.Large;
}

@"sizeClassPredicates" unittest {
	assert(ClassCount.Small == 39, "Unexpected small class count!");
	assert(ClassCount.Large == 67, "Unexpected large class count!");
	assert(ClassCount.Total == 239, "Unexpected total class count!");

	foreach (s; 0 .. ClassCount.Small) {
		assert(isSmallSizeClass(s));
		assert(!isLargeSizeClass(s));
		assert(!isHugeSizeClass(s));
	}

	foreach (s; ClassCount.Small .. ClassCount.Large) {
		assert(!isSmallSizeClass(s));
		assert(isLargeSizeClass(s));
		assert(!isHugeSizeClass(s));
	}

	foreach (s; ClassCount.Large .. ClassCount.Total) {
		assert(!isSmallSizeClass(s));
		assert(!isLargeSizeClass(s));
		assert(isHugeSizeClass(s));
	}
}

// Determine whether given size class supports metadata.
bool sizeClassSupportsMetadata(uint sizeClass) {
	return sizeClass > 0;
}

@"sizeClassSupportsMetadata" unittest {
	auto bins = getBinInfos();
	foreach (sc; 0 .. ClassCount.Small) {
		assert(sizeClassSupportsMetadata(sc) == bins[sc].supportsMetadata);
	}

	// All large size classes support metadata.
	foreach (sc; ClassCount.Small .. ClassCount.Total) {
		assert(sizeClassSupportsMetadata(sc));
	}
}

// Determine whether given size class supports inline marking.
bool sizeClassSupportsInlineMarking(uint sizeClass) {
	return sizeClass > 2;
}

@"sizeClassSupportsInlineMarking" unittest {
	auto bins = getBinInfos();
	foreach (sc; 0 .. ClassCount.Small) {
		assert(
			sizeClassSupportsInlineMarking(sc) == bins[sc].supportsInlineMarking
		);
	}

	// All large size classes support inline marking.
	foreach (sc; ClassCount.Small .. ClassCount.Total) {
		assert(sizeClassSupportsInlineMarking(sc));
	}
}

bool isDenseSizeClass(uint sizeClass) {
	enum Sieve = 1 << 15 | 1 << 19 | 1 << 21;
	auto match = Sieve & (1 << sizeClass);
	return !match && sizeClass < 23;
}

bool isSparseSizeClass(uint sizeClass) {
	return !isDenseSizeClass(sizeClass);
}

@"isDenseSizeClass" unittest {
	auto bins = getBinInfos();
	foreach (sc; 0 .. ClassCount.Small) {
		assert(isDenseSizeClass(sc) == bins[sc].dense);
		assert(isSparseSizeClass(sc) == bins[sc].sparse);
	}

	// All large size classes are sparse.
	foreach (sc; ClassCount.Small .. ClassCount.Total) {
		assert(!isDenseSizeClass(sc));
		assert(isSparseSizeClass(sc));
	}
}

size_t getAllocSize(size_t size) {
	if (size <= MaxTinySize) {
		return alignUp(size, Quantum);
	}

	import d.gc.util;
	auto shift = log2floor(size - 1) - 2;
	return (((size - 1) >> shift) + 1) << shift;
}

@"getAllocSize" unittest {
	assert(getAllocSize(0) == 0);

	size_t[] boundaries =
		[8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256,
		 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048];

	size_t s = 1;
	foreach (b; boundaries) {
		while (s <= b) {
			assert(getAllocSize(s) == b);
			assert(getSizeFromClass(getSizeClass(s)) == b);
			s++;
		}
	}
}

ubyte getSizeClass(size_t size) {
	if (size <= MaxTinySize) {
		auto ret = ((size + QuantumMask) >> LgQuantum) - 1;

		assert(size == 0 || ret < ubyte.max);
		return ret & 0xff;
	}

	import d.gc.util;
	auto shift = log2floor(size - 1) - 2;
	auto mod = (size - 1) >> shift;
	auto ret = 4 * (shift - LgQuantum) + mod;

	assert(ret < ubyte.max);
	return ret & 0xff;
}

@"getSizeClass" unittest {
	import d.gc.slab;
	assert(getSizeClass(0) == InvalidBinID);

	size_t[] boundaries =
		[8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256,
		 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048];

	uint bid = 0;
	size_t s = 1;
	foreach (b; boundaries) {
		while (s <= b) {
			assert(getSizeClass(s) == bid);
			assert(getAllocSize(s) == getSizeFromClass(bid));
			s++;
		}

		bid++;
	}
}

size_t getSizeFromClass(uint sizeClass) {
	if (isSmallSizeClass(sizeClass)) {
		import d.gc.slab;
		return binInfos[sizeClass].slotSize;
	}

	auto largeSizeClass = sizeClass - ClassCount.Small;
	auto shift = largeSizeClass / 4 + LgPageSize;
	size_t bits = (largeSizeClass % 4) | 0x04;

	auto ret = bits << shift;

	// XXX: out contract
	assert(sizeClass == getSizeClass(ret));
	assert(ret == getAllocSize(ret));
	return ret;
}

@"getSizeFromClass" unittest {
	size_t[] boundaries =
		[8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256,
		 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 1792, 2048];

	uint bid = 0;
	foreach (b; boundaries) {
		assert(getSizeFromClass(bid++) == b);
	}
}

auto getBinInfos() {
	import d.gc.slab;
	BinInfo[BinCount] bins;

	static ubyte computePageCount(uint size, ubyte shift) {
		// Try to see if one page is acceptable.
		enum MaxAcceptableSlack = 16;
		auto slack = PageSize - size * (PageSize / size);
		if (slack <= MaxAcceptableSlack) {
			return 1;
		}

		// Try to see if two pages is acceptable.
		slack = 2 * PageSize - size * (2 * PageSize / size);
		if (slack <= MaxAcceptableSlack) {
			return 2;
		}

		ubyte[4] npLookup = [(((size - 1) >> LgPageSize) + 1) & 0xff, 5, 3, 7];
		return npLookup[(size >> shift) % 4];
	}

	computeSizeClass((uint id, uint grp, uint delta, uint ndelta) {
		if (!isSmallSizeClass(id)) {
			return;
		}

		auto s = (1 << grp) + (ndelta << delta);
		assert(s < ushort.max);
		ushort slotSize = s & ushort.max;

		ubyte shift = delta & 0xff;
		if (grp == delta) {
			auto tag = (ndelta + 1) / 2;
			shift = (delta + tag - 2) & 0xff;
		}

		auto npages = computePageCount(slotSize, shift);
		ushort slots = ((npages << LgPageSize) / s) & ushort.max;

		bins[id] = BinInfo(slotSize, shift, npages, slots);
	});

	return bins;
}

private:

auto getTotalClassCount() {
	uint count = 0;

	computeSizeClass((uint id, uint grp, uint delta, uint ndelta) {
		count++;
	});

	return count;
}

auto getTinyClassCount() {
	uint count = 1;

	computeSizeClass((uint id, uint grp, uint delta, uint ndelta) {
		if (delta <= LgQuantum) {
			count++;
		}
	});

	return count;
}

auto getSmallClassCount() {
	uint count = 0;

	computeSizeClass((uint id, uint grp, uint delta, uint ndelta) {
		if (delta < LgPageSize) {
			count++;
		}
	});

	return count;
}

auto getLargeClassCount() {
	uint count = 0;

	computeSizeClass((uint id, uint grp, uint delta, uint ndelta) {
		if (grp < LgBlockSize) {
			count++;
		}
	});

	return count;
}

auto getLookupClassCount() {
	uint count = 0;

	computeSizeClass((uint id, uint grp, uint delta, uint ndelta) {
		if (grp < LgPageSize) {
			count++;
		}
	});

	return count + 1;
}

void computeSizeClass(
	void delegate(uint id, uint grp, uint delta, uint ndelta) fun
) {
	uint id = 0;

	// Tiny sizes.
	foreach (i; 0 .. 3) {
		fun(id++, LgQuantum, LgQuantum, i);
	}

	// Most size classes falls here.
	foreach (uint grp; LgQuantum + 2 .. 8 * size_t.sizeof) {
		foreach (i; 0 .. 4) {
			fun(id++, grp, grp - 2, i);
		}
	}

	// We want to be able to store the binID in a byte.
	assert(id <= ubyte.max);
}
