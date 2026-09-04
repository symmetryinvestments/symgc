module d.gc.slab;

import d.gc.emap;
import d.gc.extent;
import d.gc.size;
import d.gc.spec;
import d.gc.util;

version (OSX) {
	alias PackedFreeSpace = uint;
	// The finalizer pointer is stored separately on Apple Silicon. Reserve
	// one flag bit for it and use the other two high bits to encode the 1-, 2-,
	// and 3-byte free-space cases without overwriting shared payload bytes.
	enum FinalizerBit = 1u << 29;
	enum SmallFreeSpace2Bit = 1u << 30;
	enum SmallFreeSpace1Bit = 1u << 31;
	enum FreeSpaceMask = FinalizerBit - 1;
} else {
	alias PackedFreeSpace = ushort;
	enum FinalizerBit = 1 << 14;
	enum SingleByteBit = 1 << 15;
	enum FreeSpaceMask = ushort.max & ~(FinalizerBit | SingleByteBit);
}

enum InvalidBinID = 0xff;

struct SlabEntry {
private:
	/**
	 * This is a bitfield containing the following elements:
	 *  - i: The index of the item within the slab.
	 *  - a: The address of the slab.
	 *  - s: The size class of the slab.
	 *
	 * 63    56 55    48 47    40 39    32 31    24 23    16 15     8 7      0
	 * .......i iiiiiiii aaaaaaaa aaaaaaaa aaaaaaaa aaaaaaaa aaaa.... ..ssssss
	 */
	ulong bits;

	// Verify our assumptions.
	static assert(LgAddressSpace <= 48, "Address space too large!");
	static assert(LgPageSize >= 8, "Not enough space in low bits!");

	// Useful constants for bit manipulations.
	enum IndexShift = 48;

public:
	this(PageDescriptor pd, const void* ptr) {
		assert(pd.isSlab(), "Expected a slab!");

		auto ec = pd.extentClass;
		auto sc = ec.sizeClass;

		auto offset = pd.computeOffset(ptr);
		auto index = binInfos[sc].computeIndex(offset);
		auto base = ptr - offset;

		bits = sc;
		bits |= ulong(index) << IndexShift;
		bits |= (cast(ulong) base) & PagePointerMask;
	}

	@property
	uint index() const {
		return bits >> IndexShift;
	}

	@property
	void* base() const {
		return cast(void*) (bits & PagePointerMask);
	}

	@property
	ubyte sizeClass() const {
		return bits & 0xff;
	}

	void* computeAddress() const {
		auto size = binInfos[sizeClass].slotSize;
		return base + index * size;
	}

	const(void*)[] computeRange() const {
		auto size = binInfos[sizeClass].slotSize;
		auto address = cast(void**) (base + index * size);

		return address[0 .. size / PointerSize];
	}
}

@"SlabRange" unittest {
	auto pd = PageDescriptor(0x100000000000000a);

	assert(pd.extent is null);
	assert(pd.index == 1);

	auto ec = pd.extentClass;
	assert(ec.sizeClass == 9);

	auto ptr = cast(void*) 0x56789abcd123;
	import d.gc.util : alignDown;
	auto base = alignDown(ptr, PageSize) - PageSize;
	auto slotSize = binInfos[ec.sizeClass].slotSize;
	auto slot = base + ((ptr - base) / slotSize) * slotSize;

	auto se = SlabEntry(pd, ptr);
	assert(se.index == (ptr - base) / slotSize);
	assert(se.base is base);
	assert(se.sizeClass == 9);

	auto addr = se.computeAddress();
	assert(addr is slot);

	auto r0 = se.computeRange();
	assert(r0.ptr is cast(const(void*)*) slot);
	assert(r0.length == slotSize / PointerSize);
}

struct SlotMetadata {
private:
	version (OSX) {
		// A 16 KiB page makes the largest metadata-capable small slot larger
		// than the 14-bit free-space field used on the other targets. Keep the
		// finalizer pointer and free-space value in separate fields. Put the
		// packed value at the very end of the slot metadata so it never overlaps
		// a payload when only a few bytes remain free.
		size_t finalizerData;
		uint _pad;
		PackedFreeSpace freeSpaceData;
	} else {
		struct FreeSpaceData {
			PackedFreeSpace[size_t.sizeof / PackedFreeSpace.sizeof - 1] _pad;
			PackedFreeSpace freeSpace;
		}

		union Data {
			size_t finalizerData;
			FreeSpaceData freeSpaceData;
		}

		Data data;
	}

public:
	static SlotMetadata* fromBlock(void* ptr, size_t slotSize) {
		return cast(SlotMetadata*) (ptr + slotSize) - 1;
	}

	@property
	size_t freeSpace() {
		version (OSX) {
			return readPackedFreeSpace(&freeSpaceData);
		} else {
			return readPackedFreeSpace(&data.freeSpaceData.freeSpace);
		}
	}

	void setFreshFreeSpace(size_t size) {
		assert(size > 0, "Attempt to set a slot metadata size of 0!");

		version (OSX) {
			writeFreshPackedFreeSpace(&freeSpaceData, size);
		} else {
			writeFreshPackedFreeSpace(&data.freeSpaceData.freeSpace, size);
		}
	}

	void setFreeSpace(size_t size) {
		assert(size > 0, "Attempt to set a slot metadata size of 0!");

		version (OSX) {
			writePackedFreeSpace(&freeSpaceData, size);
		} else {
			writePackedFreeSpace(&data.freeSpaceData.freeSpace, size);
		}
	}

	@property
	Finalizer finalizer() {
		version (OSX) {
			return hasFinalizer
				? cast(Finalizer) (finalizerData & AddressMask)
				: null;
		} else {
			return hasFinalizer
				? cast(Finalizer) (data.finalizerData & AddressMask)
				: null;
		}
	}

	@property
	bool hasFinalizer() {
		version (OSX) {
			return (freeSpaceData & FinalizerBit) != 0;
		} else {
			return (data.freeSpaceData.freeSpace & FinalizerBit) != 0;
		}
	}

}

version (OSX) {
	static assert(SlotMetadata.sizeof == 2 * size_t.sizeof,
			  "Unexpected Apple Silicon slot metadata size!");
} else {
	static assert(SlotMetadata.sizeof == size_t.sizeof,
			  "SlotMetadata must fit in size_t!");
}

struct SlabAllocInfo {
private:
	Extent* e;

	uint index;
	uint slotSize;
	void* _address;

	bool supportsMetadata = false;
	bool _hasMetadata = false;

public:
	this(PageDescriptor pd, const void* ptr) {
		assert(pd.isSlab(), "Expected a slab!");

		e = pd.extent;

		auto se = SlabEntry(pd, ptr);
		index = se.index;
		slotSize = binInfos[se.sizeClass].slotSize;
		_address = se.base + index * slotSize;

		auto ec = pd.extentClass;
		supportsMetadata = ec.supportsMetadata;
		_hasMetadata = ec.supportsMetadata && e.hasMetadata(index);
	}

	@property
	auto hasMetadata() {
		return _hasMetadata;
	}

	@property
	auto address() {
		return _address;
	}

	@property
	size_t slotCapacity() {
		version (OSX) {
			return slotSize - (finalizerEnabled ? SlotMetadata.sizeof : 0);
		} else {
			return slotSize - (finalizerEnabled ? PointerSize : 0);
		}
	}

	@property
	size_t usedCapacity() {
		return slotSize - freeSpace;
	}

	bool setUsedCapacity(size_t size) {
		if (!supportsMetadata || size > slotCapacity) {
			return false;
		}

		setFreeSpace(slotSize - size);
		return true;
	}

	@property
	Finalizer finalizer() {
		return _hasMetadata ? slotMetadata.finalizer : null;
	}

	void initializeMetadata(Finalizer initialFinalizer,
	                        size_t initialUsedCapacity) {
		assert(isLittleEndian(), "Currently does not work on big-endian!");
		assert(supportsMetadata, "size class not supports slab metadata!");

		bool hasFinalizer = initialFinalizer !is null;
		if (!hasFinalizer && initialUsedCapacity == slotSize) {
			// A full non-finalized slot has no free bytes in which metadata is
			// needed. In particular, do not overwrite its final bytes with a
			// zero free-space marker.
			e.disableMetadata(index);
			_hasMetadata = false;
			return;
		}
		version (OSX) {
			enum FinalizerStorageSize = SlotMetadata.sizeof;
		} else {
			enum FinalizerStorageSize = PointerSize;
		}
		assert(
			initialUsedCapacity <= slotSize - (hasFinalizer ? FinalizerStorageSize : 0),
			"Insufficient alloc capacity!"
		);

		auto finalizerValue = cast(size_t) cast(void*) initialFinalizer;
		assert((finalizerValue & AddressMask) == finalizerValue,
		       "New finalizer pointer is invalid!");

		auto freeSpaceValue = slotSize - initialUsedCapacity;
		version (OSX) {
			if (hasFinalizer)
				slotMetadata.finalizerData = finalizerValue;
			writeFreshPackedFreeSpace(&slotMetadata.freeSpaceData,
			                         freeSpaceValue);
			if (hasFinalizer)
				slotMetadata.freeSpaceData |= FinalizerBit;
		} else {
			PackedFreeSpace native;
			if (freeSpaceValue == 1) {
				assert(!hasFinalizer);
				native = SingleByteBit;
			} else {
				auto finalizerSet = hasFinalizer ? FinalizerBit : 0;
				native = cast(PackedFreeSpace)
					(freeSpaceValue | finalizerSet);
			}

			auto newMetadata = size_t(native) << 48;
			// TODO: Currently only works on little-endian!!!
			// On a big-endian machine, the unused high bits of a pointer will be
			// found at the start, rather than end, of the memory that it occupies,
			// and the freespace (newMetadata) will collide with the finalizer.
			slotMetadata.data.finalizerData = newMetadata | finalizerValue;
		}
		e.enableMetadata(index);
		_hasMetadata = true;
	}

private:
	@property
	SlotMetadata* slotMetadata() {
		return SlotMetadata.fromBlock(cast(void*) address, slotSize);
	}

	@property
	size_t freeSpace() {
		return _hasMetadata ? slotMetadata.freeSpace : 0;
	}

	void setFreeSpace(size_t size) {
		assert(supportsMetadata, "size class not supports slab metadata!");
		assert(size <= slotSize, "size exceeds slot size!");

		if (size == 0) {
			if (_hasMetadata) {
				e.disableMetadata(index);
				_hasMetadata = false;
			}

			return;
		}

		if (!_hasMetadata) {
			slotMetadata.setFreshFreeSpace(size);
			e.enableMetadata(index);
			_hasMetadata = true;
		} else {
			slotMetadata.setFreeSpace(size);
		}
	}

	@property
	bool finalizerEnabled() {
		/**
		 * Right now we fetch hasMetadata eagerly, but the FinalizerBit check
		 * is cheaper. But it may be worthwhile to return early if FinalizerBit
		 * is clear, i.e. to snoop the extent's metadata lazily. The reasons:
		 * 1. If the slot is not full, the bit at the FinalizerBit position
		 *    is most likely 0.
		 * 2. If it has metadata, usually it won't have a finalizer: still 0.
		 * 3. If the metadata space contains an aligned pointer, the last byte
		 *    will be the MSB of that pointer, which will always be 0.
		 * 4. If the space contains a number, its MSB will likely be zero,
		 *    as most numbers are small.
		 * 5. If there is something else in there, that is not heavily biased
		 *    (float, random/compressed data) then we're still at 50/50.
		 * We should expect to find a zero in there the VAST majority of the time.
		 */
		return _hasMetadata && slotMetadata.hasFinalizer;
	}
}

@"SlabAllocInfo" unittest {
	import d.gc.base;
	shared Base base;
	scope(exit) base.clear();

	auto slot = base.allocSlot();
	auto e = Extent.fromSlot(0, slot);
	auto block = base.reserveAndCommitAddressSpace(BlockSize);
	assert(block !is null);

	SlabAllocInfo simulateSmallAlloc(size_t size, uint slotIndex) {
		auto ec = ExtentClass.slab(getSizeClass(size));
		auto slotSize = binInfos[ec.sizeClass].slotSize;
		e.at(block, 1, null, ec);

		void*[PageSize / PointerSize] buffer = void;
		e.batchAllocate(buffer.ptr, cast(uint) buffer.length, slotSize);

		auto pd = PageDescriptor(e, ec);
		auto allocAddress = block + slotIndex * slotSize;
		return SlabAllocInfo(pd, allocAddress);
	}

	// When metadata is not supported by the size class.
	foreach (size; [1, 6, 8]) {
		auto sc = getSizeClass(size);
		assert(!sizeClassSupportsMetadata(sc));
		assert(!binInfos[sc].supportsMetadata);

		foreach (slotIndex; 0 .. binInfos[sc].nslots + 1) {
			auto si = simulateSmallAlloc(size, slotIndex);
			assert(si.slotCapacity == getAllocSize(size));
			assert(!si.supportsMetadata);
			assert(!si.hasMetadata);
			assert(si.freeSpace == 0);
			assert(!si.setUsedCapacity(0));
			assert(!si.setUsedCapacity(1));
		}
	}

	// Finalizers.
	static void destruct_a(void* ptr, size_t size) {}
	static void destruct_b(void* ptr, size_t size) {}

	// When metadata is supported by the size class (not exhaustive).
	foreach (size;
		[15, 16, 300, 320, 1000, 1024, MaxSmallSize - 1, MaxSmallSize]
	) {
		auto sc = getSizeClass(size);
		assert(sizeClassSupportsMetadata(sc));
		assert(binInfos[sc].supportsMetadata);

		foreach (slotIndex; 0 .. binInfos[sc].nslots + 1) {
			auto si = simulateSmallAlloc(size, slotIndex);
			assert(si.supportsMetadata);
			auto slotCapacity = si.slotCapacity;
			assert(slotCapacity == getAllocSize(size));
			si.setUsedCapacity(size);
			assert(si.usedCapacity == size);
			assert(si.hasMetadata == (size != slotCapacity));
			// Ensure SlotMetadata can be dirty when adjusting free space
			auto slotData = (cast(ubyte*) si.address)[0 .. size];
			slotData[size - 1] = 0xff;
			assert(si.freeSpace == slotCapacity - size);
			assert(!si.setUsedCapacity(slotCapacity + 1));

			foreach (size_t i; 0 .. slotCapacity + 1) {
				assert(si.setUsedCapacity(i));
				assert(si.usedCapacity == i);
				assert(si.hasMetadata == (i < slotCapacity));
				assert(si.freeSpace == si.slotCapacity - i);
				si.setFreeSpace(i);
				assert(si.freeSpace == i);
				assert(si.hasMetadata == (i > 0));
				assert(si.usedCapacity == si.slotCapacity - i);
			}

			// Test finalizers:
			auto regularSlotCapacity = si.slotCapacity;
			version (OSX) {
				enum FinalizerStorageSize = SlotMetadata.sizeof;
			} else {
				enum FinalizerStorageSize = PointerSize;
			}
			auto finalizedSlotCapacity = regularSlotCapacity - FinalizerStorageSize;

			foreach (size_t i; 0 .. finalizedSlotCapacity + 1) {
				// Without finalizer:
				si.initializeMetadata(null, i);
				assert(si.usedCapacity == i);
				assert(si.slotCapacity == regularSlotCapacity);
				assert(cast(void*) si.finalizer == null);
				// With finalizer:
				si.initializeMetadata(&destruct_a, i);
				assert(si.usedCapacity == i);
				assert(si.slotCapacity == finalizedSlotCapacity);
				assert(cast(void*) si.finalizer == cast(void*) &destruct_a);
				si.initializeMetadata(&destruct_b, i);
				assert(si.usedCapacity == i);
				assert(si.slotCapacity == finalizedSlotCapacity);
				assert(cast(void*) si.finalizer == cast(void*) &destruct_b);
			}
		}
	}

	version (OSX) {
		// The packed value occupies the last four bytes of the metadata
		// record. Exercise every short free-space encoding and verify that
		// payload bytes shared with that record are preserved.
		auto si = simulateSmallAlloc(64, 0);
		auto slotSize = binInfos[getSizeClass(64)].slotSize;
		auto payload = cast(ubyte*) si.address;
		foreach (freeSpace; 1 .. 4) {
			auto used = slotSize - freeSpace;
			foreach (i; 0 .. used)
				payload[i] = cast(ubyte) (i + freeSpace);
			si.initializeMetadata(null, used);
			assert(si.usedCapacity == used);
			foreach (i; 0 .. used)
				assert(payload[i] == cast(ubyte) (i + freeSpace));
		}
	}
}

/**
 * Packed Free Space is stored as a 14-bit unsigned integer, with 2 bits for
 * flags on the existing platforms. Apple Silicon uses a 30-bit value so
 * 16 KiB-page slabs can carry their larger size classes. On Apple Silicon,
 * the high bits encode finalizers and free-space values 1, 2, and 3
 * specially; this keeps the bytes occupied by the payload intact.
 *
 * Existing platforms use the following layout:
 * 15     14 13        0
 * s f    vvvvvvvvvvvvvv
 *
 * s: small bit set if length == 1
 * f: finalizer bit = 1 if a finalizer is stored in allocation
 * v: free space, only set if length > 1
 *
 * Apple Silicon uses bit 29 for the finalizer marker, bits 31 and 30 as the
 * encodings for free-space values 1, 2, and 3, and stores the finalizer
 * pointer separately.
 *
 * If free space is only 1 byte, then the lower bytes of the value are
 * used by the allocation itself, and is not used while reading. Nor is it set
 * when writing the upper byte
 *
 * Note: little endian only! The lower 8 bits are stored first in memory.
 * For big endian support, we likely have to change the end where the bits go.
 */
version (OSX) {
	static assert(MaxSmallSize <= FreeSpaceMask,
			  "Max small alloc size does not fit in packed free space!");
} else {
	static assert(MaxSmallSize < 0x4000,
			  "Max small alloc size doesn't fit in 14 bits!");
}

size_t readPackedFreeSpace(PackedFreeSpace* ptr) {
	assert(isLittleEndian(),
	       "Packed free space not implemented for big endian!");
	auto data = *ptr;
	version (OSX) {
		auto flags = data & ~FreeSpaceMask;
		if (flags == SmallFreeSpace1Bit)
			return 1;
		if (flags == SmallFreeSpace2Bit)
			return 2;
		if (flags == (SmallFreeSpace1Bit | SmallFreeSpace2Bit))
			return 3;
		return data & FreeSpaceMask;
	} else {
		auto value = data & FreeSpaceMask;
		return (data & SingleByteBit) ? 1 : value;
	}
}

void writeFreshPackedFreeSpace(PackedFreeSpace* ptr, size_t x) {
	return writePackedFreeSpaceImpl!false(ptr, x);
}

void writePackedFreeSpace(PackedFreeSpace* ptr, size_t x) {
	return writePackedFreeSpaceImpl!true(ptr, x);
}

void writePackedFreeSpaceImpl(bool PreserveFinalizer)(PackedFreeSpace* ptr,
		size_t x) {
	version (OSX) {
		assert(x <= FreeSpaceMask, "x does not fit in packed free space!");
	} else {
		assert(x < 0x4000, "x does not fit in 14 bits!");
	}
	assert(isLittleEndian(),
	       "Packed free space not implemented for big endian!");

	auto current = *ptr;
	version (OSX) {
		if (x == 0) {
			*ptr = 0;
			return;
		}
		if (x < 4) {
			// The packed field is the final four bytes of the slot. Preserve
			// the lower payload bytes that overlap it and use the high bits to
			// describe how many trailing bytes are free.
			auto preserveMask = uint.max >> (cast(uint) x * 8);
			auto flags = x == 1 ? SmallFreeSpace1Bit
				: x == 2 ? SmallFreeSpace2Bit
				: SmallFreeSpace1Bit | SmallFreeSpace2Bit;
			*ptr = (current & preserveMask) | flags;
			return;
		}

		auto large = cast(PackedFreeSpace) x;
		if (PreserveFinalizer)
			large |= current & FinalizerBit;
		*ptr = large;
		return;
	} else {
		auto small = current | SingleByteBit;
		auto large = cast(PackedFreeSpace) x;
		if (PreserveFinalizer) {
			large |= current & FinalizerBit;
		} else {
			small &= ~FinalizerBit;
		}

		auto value = (x == 1 ? small : large);
		*ptr = value & PackedFreeSpace.max;
	}
}

@"packedFreeSpace" unittest {
	ubyte[4] a;
	auto p = cast(uint*) a.ptr;

	version (OSX) {
		static void check(uint* ptr, size_t i) {
			*ptr = 0;
			writePackedFreeSpace(ptr, i);
			assert(readPackedFreeSpace(ptr) == i);

			// A fresh write must not retain any old packed flags.
			*ptr = SmallFreeSpace1Bit | SmallFreeSpace2Bit;
			writeFreshPackedFreeSpace(ptr, i);
			assert(readPackedFreeSpace(ptr) == i);
		}

		foreach (uint i; 0 .. 0x4000)
			check(p, i);
		foreach (i; [0x4000u, 0x10000u, MaxSmallSize, FreeSpaceMask])
			check(p, i);
	} else foreach (ushort i; 0 .. 0x4000) {
		// With finalizer bit set:
		*p |= FinalizerBit;
		writePackedFreeSpace(p, i);
		assert(readPackedFreeSpace(p) == i);
		assert(*p & FinalizerBit);

		// With finalizer bit cleared:
		*p &= ~FinalizerBit;
		// Should remain same as before:
		assert(readPackedFreeSpace(p) == i);
		writePackedFreeSpace(p, i);
		assert(!(*p & FinalizerBit));

		// Ensure a fresh write always clears the finalizer bit.
		*p |= FinalizerBit;
		writeFreshPackedFreeSpace(p, i);
		assert(readPackedFreeSpace(p) == i);
		assert(~(*p & FinalizerBit));
	}

	// Make sure we do not disturb the penultimate byte
	// when the length is 1.
	foreach (x; 0 .. 256) {
		a[0] = 0xff & x;
		writePackedFreeSpace(p, 1);
		assert(readPackedFreeSpace(p) == 1);
		assert(a[0] == x);
	}
}

struct BinInfo {
	ushort slotSize;
	ushort nslots;
	ubyte npages;
	ubyte shift;
	ushort mul;

	this(ushort slotSize, ubyte shift, ubyte npages, ushort nslots) {
		this.slotSize = slotSize;
		this.nslots = nslots;
		this.npages = npages;
		this.shift = (shift + 17) & 0xff;

		// XXX: out contract
		enum MaxShiftMask = (8 * size_t.sizeof) - 1;
		assert(this.shift == (this.shift & MaxShiftMask));

		/**
		 * This is a bunch of magic values used to avoid requiring
		 * division to find the index of an item within a run.
		 *
		 * Computed using finddivisor.d
		 */
		ushort[4] mulIndices = [32768, 26215, 21846, 18725];
		auto tag = (slotSize >> shift) & 0x03;
		this.mul = mulIndices[tag];
	}

	uint computeIndex(size_t offset) const {
		// FIXME: in contract.
		assert(offset < npages * PageSize, "Offset out of bounds!");

		return cast(uint) ((offset * mul) >> shift);
	}

	@property
	bool dense() const {
		// We use the number of items as a proxy to estimate the density
		// of the span. Dense spans are assumed to be long lived.
		return nslots > 16;
	}

	@property
	bool sparse() const {
		return !dense;
	}

	/**
	 * The metadata flags and the mark bits share the extent's slab bitmap
	 * with the occupancy bits, see Extent.SlabMetadata. Slabs with more
	 * slots than fit alongside them use the next size class for metadata
	 * and outlined buffers for marking.
	 */
	@property
	bool supportsMetadata() const {
		return nslots <= MaxSlotsPerSlab / 2;
	}

	@property
	bool supportsInlineMarking() const {
		return nslots <= MaxSlotsPerSlab / 4;
	}
}

import d.gc.sizeclass;
immutable BinInfo[BinCount] binInfos = getBinInfos();

@"binInfos" unittest {
	foreach (uint sc, bin; binInfos) {
		assert(bin.supportsMetadata == sizeClassSupportsMetadata(sc));
		assert(bin.supportsInlineMarking == sizeClassSupportsInlineMarking(sc));
		assert(bin.dense == isDenseSizeClass(sc));
		assert(bin.sparse == isSparseSizeClass(sc));
	}
}
