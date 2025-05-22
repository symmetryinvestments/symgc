/+ dub.json:
   {
	   "name": "infinalizer",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test GC.inFinalizer support

import symgc.gcobj;

extern(C) void* __sd_gc_tl_flush_cache();

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

struct Finalized
{
	__gshared int dtors;
	__gshared int callsFromFinalizer;
	bool destroyed;
	~this() {
		if(!destroyed)
		{
			import core.memory;
			if(GC.inFinalizer)
				++callsFromFinalizer;
			++dtors;
		}
		destroyed = true;
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

enum objCount = 50;

shared static ~this() {
	// make sure we clobber the stack
	prepareStack();
	import core.memory;
	GC.collect();
	assert(Finalized.dtors == objCount);
	assert(Finalized.callsFromFinalizer == objCount / 2);
}

void main() {
	foreach(i; 0 .. objCount / 2)
	{
		new Finalized();
	}

	foreach(i; 0 .. objCount / 2)
	{
		auto f = new Finalized();
		destroy!false(*f);
	}
}
