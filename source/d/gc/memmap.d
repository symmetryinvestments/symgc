module d.gc.memmap;

import d.gc.spec;
import d.gc.util;

version(linux) {
	import core.sys.linux.sys.mman;

	// not included in druntime for some reason
	enum MADV_FREE = 8;
}
else version(Windows) {
	import core.sys.windows.winbase;
	import core.sys.windows.winnt;
}

// Note, this RESERVES address space, but does not COMMIT memory.
// On OSes where you must commit memory in order to use it, call
// pages_commit on the memory to make sure it's wired.
void* pages_map(void* addr, size_t size, size_t alignment) {
	assert(alignment >= PageSize && isPow2(alignment), "Invalid alignment!");
	assert(isAligned(addr, alignment), "Invalid addr!");
	assert(size > 0 && isAligned(size, PageSize), "Invalid size!");

	/**
	 * Note from jemalloc:
	 *
	 * Ideally, there would be a way to specify alignment to mmap() (like
	 * NetBSD has), but in the absence of such a feature, we have to work
	 * hard to efficiently create aligned mappings.  The reliable, but
	 * slow method is to create a mapping that is over-sized, then trim the
	 * excess.  However, that always results in one or two calls to
	 * os_pages_unmap(), and it can leave holes in the process's virtual
	 * memory map if memory grows downward.
	 *
	 * Optimistically try mapping precisely the right amount before falling
	 * back to the slow method, with the expectation that the optimistic
	 * approach works most of the time.
	 */
	auto ret = os_pages_map(addr, size, alignment);
	if (ret is null || ret is addr) {
		return ret;
	}

	assert(addr is null);
	if (isAligned(ret, alignment)) {
		return ret;
	}

	// We do not have a properly aligned mapping. Let's fix this.
	pages_unmap(ret, size);

	auto asize = size + alignment - PageSize;
	if (asize < size) {
		// size_t wrapped around!
		return null;
	}
	do {

		auto pages = os_pages_map(null, asize, alignment);
		if (pages is null) {
			return null;
		}

		auto leadSize = alignUpOffset(pages, alignment);
		version (linux) {
			if (leadSize > 0) {
				pages_unmap(pages, leadSize);
			}

			assert(asize >= size + leadSize);
			auto trailSize = asize - leadSize - size;
			if (trailSize) {
				pages_unmap(pages + leadSize + size, trailSize);
			}
			ret = pages + leadSize;
		} else version (Windows) {
			pages_unmap(pages, asize);

			ret = os_pages_map(pages + leadSize, size, alignment);

			if (ret && ret !is pages + leadSize) {
				// not aligned how we need
				pages_unmap(ret, size);
				ret = null;
			}
		}
	} while(ret is null);

	return ret;
}

void pages_commit(void* addr, size_t size) {
	version(Windows) {
		if (size == 0) {
			return;
		}
		auto ret = VirtualAlloc(addr, size, MEM_COMMIT, PAGE_READWRITE);
		assert(ret !is null, "Could not commit memory!");
		assert(ret is addr, "MEM_COMMIT moved alloction!");
	}
	// linux does not need explicit commit
}

void pages_unmap(void* addr, size_t size) {
	version(linux) {
		auto ret = munmap(addr, size);
		assert(ret == 0, "munmap failed!");
	}
	else version(Windows) {
		auto ret = VirtualFree(addr, 0, MEM_RELEASE);
		assert(ret, "VirtualFree failed!");
	}
}

void pages_purge(void* addr, size_t size) {
	version(linux) {
		auto ret = madvise(addr, size, MADV_DONTNEED);
		assert(ret == 0, "madvise failed!");
	} else version(Windows) {
		VirtualFree(addr, size, MEM_DECOMMIT);
	}
}

void pages_purge_lazy(void* addr, size_t size) {
	version (linux) {
		auto ret = madvise(addr, size, MADV_FREE);
		assert(ret == 0, "madvise failed!");
	} else version (Windows) {
		VirtualAlloc(addr, size, MEM_RESET, PAGE_READWRITE);
	}
}

void pages_zero(void* addr, size_t size) {
	if (size >= PurgePageThresoldSize) {
		// Purging and recommitting should reset the data to 0.
		pages_purge(addr, size);
		pages_commit(addr, size);
	} else {
		import core.stdc.string;
		memset(addr, 0, size);
	}
}

/**
 * Note about why we don't assert the result of madvise in the following 2 functions.
*
 * From madvise(2):
 *
 *    The MADV_HUGEPAGE, MADV_NOHUGEPAGE, and MADV_COLLAPSE operations are
 *    available only if the kernel was configured with
 *    CONFIG_TRANSPARENT_HUGEPAGE
 *
 * This means that if a kernel is not configured with the right option, madvise
 * will fail with EINVAL. The cases where EINVAL happens are listed as follows:
 *
 *     EINVAL addr is not page-aligned or size is negative.
 *
 *     EINVAL advice is not a valid.
 *
 *     EINVAL advice is MADV_COLD or MADV_PAGEOUT and the specified
 *            address range includes locked, Huge TLB pages, or VM_PFNMAP
 *            pages.
 *
 *     EINVAL advice is MADV_DONTNEED or MADV_REMOVE and the specified
 *            address range includes locked, Huge TLB pages, or VM_PFNMAP
 *            pages.
 *
 *     EINVAL advice is MADV_MERGEABLE or MADV_UNMERGEABLE, but the
 *            kernel was not configured with CONFIG_KSM.
 *
 *     EINVAL advice is MADV_FREE or MADV_WIPEONFORK but the specified
 *            address range includes file, Huge TLB, MAP_SHARED, or
 *            VM_PFNMAP ranges.
 *
 *     EINVAL advice is MADV_POPULATE_READ or MADV_POPULATE_WRITE, but
 *            the specified address range includes ranges with
 *            insufficient permissions or special mappings, for example,
 *            mappings marked with kernel-internal flags such a VM_IO or
 *            VM_PFNMAP, or secret memory regions created using
 *            memfd_secret(2).
 *
 *     EINVAL advice is MADV_GUARD_INSTALL or MADV_GUARD_REMOVE, but the
 *            specified address range contains an unsupported mapping.
 *
 * We do not have to worry about anything other than the first two. For a
 * kernel without the right configuration, EINVAL will happen for MADV_HUGEPAGE
 * and MADV_NOHUGEPAGE, because the advice is not valid. But we should also
 * check for the first case, that the page is not aligned or the size is
 * negative (which is odd, since size_t is unsigned, even in C).
 */

bool pages_hugify(void* addr, size_t size) {
	version(linux) {
		auto ret = madvise(addr, size, MADV_HUGEPAGE);
		return ret == 0;
	}
	else {
		return false;
	}
}

bool pages_dehugify(void* addr, size_t size) {
	version(linux) {
		auto ret = madvise(addr, size, MADV_NOHUGEPAGE);
		return ret == 0;
	}
	else {
		return false;
	}
}

private:

void* os_pages_map(void* addr, size_t size, size_t alignment) {
	assert(alignment >= PageSize && isPow2(alignment), "Invalid alignment!");
	assert(isAligned(addr, alignment), "Invalid addr!");
	assert(size > 0 && isAligned(size, PageSize), "Invalid size!");

	version(linux) {
		enum PagesFDTag = -1;
		enum MMapFlags = MAP_PRIVATE | MAP_ANONYMOUS;

		auto ret =
			mmap(addr, size, PROT_READ | PROT_WRITE, MMapFlags, PagesFDTag, 0);
		assert(ret !is null);

		enum MAP_FAILED = cast(void*) -1L;
		if (ret is MAP_FAILED) {
			return null;
		}
	}
	else version(Windows) {
		auto ret =
			VirtualAlloc(addr, size, MEM_RESERVE, PAGE_READWRITE);
		if (ret is null) {
			return null;
		}
	}

	if (addr is null || ret is addr) {
		return ret;
	}

	// We mapped, but not where expected.
	pages_unmap(ret, size);
	return null;
}

@"pages_map" unittest {
	auto ptr = pages_map(null, PageSize, PageSize);
	assert(ptr !is null);
	pages_unmap(ptr, PageSize);
}

@"pages_map_align" unittest {
	struct Alloc {
		void* ptr;
		size_t length;
	}

	size_t i = 0;
	Alloc[32] allocs;
	for (size_t s = PageSize; s <= 1024 * 1024 * 1024; s <<= 1) {
		for (size_t a = PageSize; a <= s && a <= BlockSize; a <<= 1) {
			i = (i + 1) % allocs.length;
			if (allocs[i].ptr !is null) {
				pages_unmap(allocs[i].ptr, allocs[i].length);
			}

			auto ptr = pages_map(null, s, a);
			assert(isAligned(ptr, a));

			allocs[i].ptr = ptr;
			allocs[i].length = s;
		}
	}

	foreach (j; 0 .. allocs.length) {
		pages_unmap(allocs[j].ptr, allocs[j].length);
	}
}
