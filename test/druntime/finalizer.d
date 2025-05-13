/+ dub.json:
   {
	   "name": "simple",
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
	int x;
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

shared static ~this() {
	// make sure we clobber the stack
	prepareStack();
	import core.memory;
	GC.collect();
	import std.stdio;
	writeln(Finalized.dtors);
	assert(Finalized.dtors == objCount);
}

void main() {
	foreach(i; 0 .. objCount)
	{
		new Finalized();
	}
}

