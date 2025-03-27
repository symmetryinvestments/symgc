/+ dub.json:
   {
	   "name": "test0201",
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
//T desc:GC unsuspendable thread test.

import d.sync.mutex;
shared Mutex m1, m2;

extern(C) void __sd_gc_collect();

extern(C) void* runThread(void*) {
	m2.lock();

	import core.sys.posix.signal;
	sigset_t set;
	sigfillset(&set);

	// Block all signals!
	import core.sys.posix.pthread;
	pthread_sigmask(SIG_BLOCK, &set, null);

	// Hand over to the main thread.
	m1.unlock();

	// Wait for the main thread to collect.
	m2.lock();
	m2.unlock();

	return null;
}

void main() {
	import d.gc.thread;
	createProcess();
	m1.lock();

	import core.sys.posix.pthread;
	pthread_t tid;
	pthread_create(&tid, null, &runThread, null);

	// Wait for the thread ot start.
	m1.lock();
	m1.unlock();

	__sd_gc_collect();

	m2.unlock();

	void* ret;
	pthread_join(tid, &ret);
}
