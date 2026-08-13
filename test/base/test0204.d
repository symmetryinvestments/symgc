/+ dub.json:
   {
	   "name": "test0204",
	   "dependencies": {
		   "dmd:root": "2.112.0",
		   "symgc" : {
			   "path" : "../../",
		   }
	   },
	   "subConfigurations" : {
		   "symgc": "integration"
	   },
	   "targetPath": "./bin"
   }
+/
//T retval:0
//T desc:DMD can xfree an OutBuffer while using SymGC

import dmd.common.outbuffer : OutBuffer;
import dmd.root.rmem : mem;
import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

void main()
{
	// Quickbite has already initialized the collector through DMD allocations
	// before lambda comparison reaches the OutBuffer xfree below.
	mem.xmalloc(1);

	// OutBuffer allocates with C realloc, but mem.xfree delegates to GC.free
	// when DMD is embedded with its GC enabled, as it is in Quickbite. GC.free
	// must ignore memory not allocated by the active collector:
	// https://dlang.org/phobos/core_memory.html#.GC.free
	OutBuffer buffer;
	buffer.writestring("Quickbite");
	auto serialization = buffer.extractSlice();
	mem.xfree(serialization.ptr);
}
