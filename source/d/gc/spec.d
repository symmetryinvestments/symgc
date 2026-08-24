module d.gc.spec;

import d.gc.util;

// Pointer sized one.
enum size_t One = 1;

// Pointer size.
enum LgPointerSize = log2floor(size_t.sizeof);
enum PointerSize = One << LgPointerSize;

static assert(PointerSize == size_t.sizeof, "Invalid pointer size!");

// We want 64-bits aligned allocations.
enum LgQuantum = 3;
enum Quantum = One << LgQuantum;
enum QuantumMask = Quantum - 1;

static assert(Quantum >= PointerSize,
			  "Quantum must be at least pointer sized!");

// Cache line.
enum LgCacheLine = 6;
enum CacheLine = One << LgCacheLine;
enum CacheLineMask = CacheLine - 1;

// Page size.
version(OSX) {
	version(AArch64) {
		// Apple Silicon macs use 16k pages in userspace.
		enum LgPageSize = 14;
	} else {
		enum LgPageSize = 12;
	}
} else {
	enum LgPageSize = 12;
}
enum PageSize = One << LgPageSize;
enum PageMask = PageSize - 1;

enum uint PointerInPage = PageSize / PointerSize;

/**
 * Size boundary for slab (small) allocations.
 *
 * Slab slots carry their free space in a packed 14-bit field (see
 * d.gc.slab), which caps the size of small allocations below 16k
 * regardless of the OS page size. This keeps the size class ladder
 * identical on every platform.
 */
enum LgSlabSize = 12;
enum SlabSize = One << LgSlabSize;

// Block size.
enum LgBlockSize = 21;
enum BlockSize = One << LgBlockSize;
enum BlockMask = BlockSize - 1;

enum uint PagesInBlock = BlockSize / PageSize;

// Virtual address space.
enum LgAddressSpace = 48;
enum AddressSpace = One << LgAddressSpace;
enum AddressMask = AddressSpace - 1;

enum PagePointerMask = AddressSpace - PageSize;
enum BlockPointerMask = AddressSpace - BlockSize;

// Allocator specific config.
/**
 * 16k page systems fit more slots per slab, and therefore need wider
 * inline bitmaps in the extents. Grow the extent descriptor size to
 * match: the worst case metadata overhead stays identical (one extent
 * per page: 128 x 512B == 512 x 128B per 2MB block).
 */
version(OSX) {
	version(AArch64) {
		enum LgExtentSize = 9;
	} else {
		enum LgExtentSize = 7;
	}
} else {
	enum LgExtentSize = 7;
}
enum ExtentSize = One << LgExtentSize;
enum ExtentAlign = ExtentSize;
enum ExtentMask = AddressSpace - ExtentAlign;

/**
 * Maximum number of slots a slab can have.
 *
 * This is the width of the inline occupancy bitmap stored in the
 * extent. 16k page systems fit more small slots per slab, so they
 * need a wider bitmap.
 */
version(OSX) {
	version(AArch64) {
		enum LgMaxSlabSlots = 11;
		enum LgMaxFlagSlots = 10;
	} else {
		enum LgMaxSlabSlots = 9;
		enum LgMaxFlagSlots = 8;
	}
} else {
	enum LgMaxSlabSlots = 9;
	enum LgMaxFlagSlots = 8;
}
enum MaxSlabSlots = One << LgMaxSlabSlots;
enum MaxFlagSlots = One << LgMaxFlagSlots;

/**
 * Maximum number of slots for slabs which can be marked inline.
 *
 * The slab metadata layout packs three regions in sequence: an
 * occupancy shadow of MaxSlabSlots/4 bits, then the mark bits, then
 * the metadata flags. A slab can use the inline marks only if its
 * occupancy does not reach the marks region, and the metadata flags
 * only if its occupancy does not reach the flags region.
 */
enum MaxMarkSlots = MaxSlabSlots / 4;

/**
 * Maximum number of slots a sparse slab can have.
 *
 * Sparse slabs track their marks in the extent's gcWord, which packs
 * an 8-bit cycle counter and 56 mark bits (see Extent.markSparseSlot).
 * Slabs with more slots than that could never mark their trailing
 * slots, and the collector would reclaim them while they are alive.
 */
enum MaxSparseSlots = (8 * size_t.sizeof) - 8;
static assert(MaxFlagSlots == MaxSlabSlots / 2,
              "The flags region must follow the marks region!");

enum LgArenaCount = 12;
enum ArenaCount = 1 << LgArenaCount;
enum ArenaMask = ArenaCount - 1;

// Various thresolds.
enum PurgePageThresold = 16;
enum PurgePageThresoldSize = PurgePageThresold * PageSize;

// GC-specific items
alias Finalizer = void*;
// alias Finalizer = void function(void* ptr, size_t size);
