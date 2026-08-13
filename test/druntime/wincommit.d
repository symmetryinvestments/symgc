/+ dub.json:
   {
	   "name": "wincommit",
	   "dependencies": {
		   "symgc" : {
			   "path" : "../../"
		   }
	   },
	   "targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test to confirm Windows memory commit across multiple reservations works
//T platform:win64
import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

import core.sys.windows.winbase;
import core.sys.windows.winnt;

import core.memory;

void main()
{
    // disable any GC cycles for this test.
    GC.disable();
    scope(exit) GC.enable();

    // constants for sizing
    enum size_t gb = 1024*1024*1024;
    enum size_t blockSize = 1024*1024*2;

    /* The goal here is to set up an environment where a 2GB continuous space
     * will be allocated into the scannable region. This will be allocated 1GB
     * at a time. We can't allocate 2GB directly, because that will be one
     * region and we won't get the overlap error. We can't leave this space
     * open because the GC sometimes allocates small bits (metadata, radix
     * tree leaves, etc) which would break up the space. To prevent this, we
     * do the following:
     *
     * 1. Find the end of the allocated space. This is where new allocations will occur. We increment 1 block (2MB) at a time, as this is the granularity of symgc allocations
     * 2. Put up a blocker allocation directly with the OS. This prevents other allocations (such as other regions, or metadata blocks) from breaking up a 2GB address space.
     * 3. We start with 2GB of blocker. We want to make sure the OS didn't hand out some of this speace elsewhere (in all tests I've performed this is never an issue)
     * 4. We free that 2GB and just block the second GB of space. This gives a 1GB hole to allocate into, but blocks any small allocations after that.
     * 5. Allocate a 1GB block. This won't fit into the existing memory space, so it will ask for another 1GB from the OS. It should go directly into the hole.
     * 6. Remove the blocker, and allocate a second 1GB block. It should go directly after the first 1gb block.
     * 7. Free both blocks, which the GC then combines into one large piece of unused address space.
     * 8. Allocate 1.5G block. This should span the two address spaces, and cause the overlapping commit.
     */
    void *p1 = GC.malloc(gb/2);
    GC.free(p1); // don't actually need to keep it around, we just needed a valid address in the heap.
    void *target = p1 + gb/2;
    void *blocker = null;
    while(!blocker) {
        blocker = VirtualAlloc(target, 2*gb, MEM_RESERVE, PAGE_READWRITE);
        target += blockSize;
    }

    assert(VirtualFree(blocker, 0, MEM_RELEASE));
    blocker = VirtualAlloc(blocker + gb, gb, MEM_RESERVE, PAGE_READWRITE);
    assert(blocker);
    void *p2 = GC.malloc(gb);
    assert(p2 + gb == blocker);
    assert(VirtualFree(blocker, 0, MEM_RELEASE));
    void *p3 = GC.malloc(gb);
    assert(p2 + gb == p3);
    GC.free(p2);
    GC.free(p3);
	GC.malloc(gb * 3 / 2);
}
