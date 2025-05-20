/+ dub.json:
   {
	   "name": "test0199",
		"dependencies": {
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
//T compiles:yes
//T has-passed:yes
//T retval:0
//T desc:GC add/remove single root

extern(C) void* __sd_gc_tl_flush_cache();
extern(C) void __sd_gc_collect();

extern(C) void* __sd_gc_alloc_finalizer(size_t size, void* finalizer);
extern(C) void __sd_gc_free(void* ptr);

extern(C) void __sd_gc_add_roots(const void[] range);
extern(C) void __sd_gc_remove_roots(const void* ptr);

// in windows, we must use the SDC GC because we are using druntime's mechanisms.
version(Windows) extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

int finalizerCalled;

void finalize(void* ptr, size_t size) {
	++finalizerCalled;
}

size_t allocate(bool pin) {
	version(Windows) {
		// using druntime finalizers. Need a struct typeinfo
		static struct Finalizer {
			ubyte[15] data;
			~this() {
				finalize(null, 0);
			}
		}
		auto destructor = cast(void*)typeid(Finalizer);
	} else version(linux) {
		auto destructor = &finalize;
	}
	auto ptr = __sd_gc_alloc_finalizer(16, destructor);

	if (pin) {
		__sd_gc_add_roots(ptr[0 .. 0]);
	}

	// swap all the bits in the pointer before returning.
	// This will also overwrite the stack data.
	ptr = cast(void*)~cast(size_t)ptr;
	return cast(size_t) ptr;
}

void unpin(size_t blk) {
	__sd_gc_remove_roots(cast(void*) ~blk);
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

void main() {
	import d.gc.thread;
	createProcess();
	auto blk = allocate(false);
	prepareStack();
	__sd_gc_collect();
	assert(finalizerCalled == 1, "Finalizer not called when unpinned.");
	blk = allocate(true);
	prepareStack();
	__sd_gc_collect();
	assert(finalizerCalled == 1, "Finalizer called when pinned.");
	unpin(blk);
	prepareStack();
	__sd_gc_collect();
	assert(finalizerCalled == 2, "Finalizer not called after unpinning.");
}
