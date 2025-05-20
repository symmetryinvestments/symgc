/+ dub.json:
   {
	   "name": "test0200",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"subConfigurations" : {
			"symgc": "integration"
		},
		"targetPath": "./bin"
   }
+/
//T compiles:yes
//T has-passed:yes
//T retval:0
//T desc:GC multithreaded stress test.

// in windows, we must use the SDC GC because we are using druntime's mechanisms.
version(Windows) extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

extern(C) void __sd_gc_collect();
extern(C) void* __sd_gc_alloc(size_t size);
extern(C) void __sd_gc_tl_activate(bool activated);

void randomAlloc() {
	// These thread generate garbage as an incredible rate,
	// so we do not trigger collection automatically.
	__sd_gc_tl_activate(false);

	enum CollectCycle = 4 * 1024 * 1024;
	size_t n = 11400714819323198485;
	import symgc.thread;
	n ^= cast(size_t) currentThreadHandle();

	foreach (_; 0 .. 8) {
		foreach (i; 0 .. CollectCycle) {
			n = n * 6364136223846793005 + 1442695040888963407;

			auto x = (i + 1) << 5;
			auto m = (x & -x) - 1;
			auto s = n & m;

			__sd_gc_alloc(s);
		}

		__sd_gc_collect();
	}
}

void main() {
	import d.gc.thread;
	createProcess();
	enum ThreadCount = 4;
	import core.thread;
	Thread[ThreadCount - 1] tids;

	foreach (ref tid; tids) {
		tid = new Thread({randomAlloc();});
		tid.start();
	}

	randomAlloc();

	foreach (ref tid; tids) {
		tid.join();
	}
}
