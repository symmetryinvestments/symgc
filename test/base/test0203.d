/+ dub.json:
   {
	   "name": "test0203",
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
//T desc:GC multithreaded collection deadlock test

import d.sync.atomic;
import d.sync.mutex;

// in windows, we must use the SDC GC because we are using druntime's mechanisms.
version(Windows) extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

extern(C) void __sd_gc_collect();
extern(C) void* __sd_gc_alloc_finalizer(size_t size, void* finalizer);

shared Atomic!uint shouldQuit;

shared Mutex mtx;

shared size_t ndestroyed;

struct S {
	~this() {
		mtx.lock();
		scope(exit) mtx.unlock();
		*cast(size_t*)&ndestroyed += 1;
	}
}

void destroyItem(T)(void* item, size_t size) {
	assert(size == T.sizeof);
	(cast(T*) item).__dtor();
}

void allocateItem(T)() {
	version(Windows) {
		// using druntime finalizers, we must add 1 to account for the finalizer subtracting 1.
		auto destructor = cast(void*)typeid(T);
		enum allocSize = T.sizeof + 1;
	} else version(linux) {
		auto destructor = &destroyItem!T;
		enum allocSize = T.sizeof;
	}
	auto ptr = __sd_gc_alloc_finalizer(allocSize, destructor);
}

extern(C) void pthread_create();

void main() {
	// this is needed to engage the pthread hook...
	version(linux) auto pth = &pthread_create;
	import d.gc.thread;
	createProcess();
	static struct ThreadRunner {
		import core.thread;
		Thread t;
		size_t count;
		void runThread() {
			while (!shouldQuit.load()) {
				S s;
				++count;
			}
		}

		void create() {
			t = new Thread(&runThread);
			t.start;
		}

		size_t join() {
			t.join();
			return count;
		}
	}

	ThreadRunner[4] tids;
	foreach (ref tid; tids) {
		tid.create();
	}

	foreach (i; 0 .. 100) {
		allocateItem!S();
		__sd_gc_collect();
	}

	shouldQuit.store(1);
	size_t total = 0;
	foreach (ref tid; tids) {
		total += tid.join();
	}

	// Simple sanity check.
	import core.stdc.stdio;
	printf("ndestroyed = %lld, total = %lld\n", ndestroyed, total);
	assert(ndestroyed > total && ndestroyed <= total + 100);
}
