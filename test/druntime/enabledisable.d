/+ dub.json:
   {
	   "name": "enabledisable",
	   "dependencies": {
		   "symgc" : {
			   "path" : "../../"
		   }
	   },
	   "targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test enabling and disabling the GC
import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

struct S {
	__gshared uint dtors;

	ubyte[1024] data;
	~this() {
		++dtors;
	}
}

void main()
{
	void allocS(size_t count) {
		foreach(i; 0 .. count) {
			new S;
		}
	}

	import core.memory;
	GC.disable();
	allocS(100_000);
	// no dtors should have run (no collections)
	assert(S.dtors == 0);

	// test reentrancy
	GC.disable();
	allocS(10_000);
	assert(S.dtors == 0);
	GC.enable();
	allocS(10_000);
	assert(S.dtors == 0);

	// test enabling and finally running a cycle
	GC.enable();
	allocS(10_000);
	assert(S.dtors > 0);

	// test disabling and running a GC cycle manually
	GC.disable();
	S.dtors = 0;
	allocS(100_000);
	assert(S.dtors == 0);
	GC.collect();
	assert(S.dtors > 0);
	GC.enable();
}
