/+ dub.json:
   {
	   "name": "test0202",
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
//T desc:GC addRoot reentrancy test.
//T timeout:300000

extern(C) void* __sd_gc_alloc(size_t size);
extern(C) void __sd_gc_add_roots(const void[] range);

// For Windows, which must commit on every allocation,
// we cannot do 204GB of allocations.
version(Windows) enum BufferSize = 8_000_000;
else enum BufferSize = 800_000_000;

void main() {
	import d.gc.thread;
	createProcess();
	foreach (i; 0 .. 256) {
		// Get the GC close past a collect threshold.
		auto ptr = __sd_gc_alloc(BufferSize);
		__sd_gc_add_roots(ptr[0 .. BufferSize]);
	}
}
