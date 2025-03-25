/+ dub.json:
   {
	   "name": "test0196",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"targetPath": "./bin"
   }
+/
//T compiles:yes
//T has-passed:yes
//T retval:0
//T desc: GC stress test.

extern(C) void __sd_gc_collect();
extern(C) void* __sd_gc_alloc(size_t size);
extern(C) void __sd_gc_tl_activate(bool activated);

struct Link {
	Link* next;

	this(Link* next) {
		this.next = next;
	}
}

void main() {
	import d.gc.thread;
	createProcess();
	// We generate garbage at an alarming rate,
	// so we do not trigger collection automatically.
	__sd_gc_tl_activate(false);

	enum NodeCount = 10000000;

	foreach (loop; 0 .. 20) {
		auto ll = new Link(null);
		foreach (i; 0 .. NodeCount) {
			ll = new Link(ll);
		}

		__sd_gc_collect();
	}
}
