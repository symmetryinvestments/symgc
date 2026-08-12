/+ dub.json:
   {
	   "name": "finalizer",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test finalizer support

import symgc.gcobj;

extern(C) void* __sd_gc_tl_flush_cache();

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

struct Finalized
{
	__gshared int dtors;
	~this() {
		++dtors;
	}
}

void prepareStack() {
	static void clobber() {
		size_t[1024] arr;
		import core.stdc.string;
		memset(arr.ptr, 0xff, arr.sizeof);
	}
	__sd_gc_tl_flush_cache();
	clobber();
}

enum objCount = 10_000;

void collectFinalizers() {
	prepareStack();
	import core.memory;
	GC.collect();
	assert(Finalized.dtors == objCount);
}

void main() {
	// Allocate on a worker so conservative stack scanning cannot retain the
	// final allocation through a stale pointer in main's stack frame.
	import core.thread : Thread;
	auto allocator = new Thread({
		foreach(i; 0 .. objCount)
		{
			new Finalized();
		}
		__sd_gc_tl_flush_cache();
	});
	allocator.start();
	allocator.join();
	collectFinalizers();
}
