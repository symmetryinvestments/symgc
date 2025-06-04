/+ dub.json:
   {
	   "name": "mutex",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test mutex contention

import d.sync.mutex;

shared Mutex m;
__gshared int widgets;
__gshared long total;
enum stopAfter = 50000;
__gshared bool exiting;

void producer()
{

	bool underflow() {
		return exiting || widgets < 1000;
	}

	while(true)
	{
		m.lock();
		scope(exit) m.unlock();
		m.waitFor(&underflow);
		if(exiting) break;
		assert(widgets < 1000);
		++widgets;
		++total;
		if(total > stopAfter)
			exiting = true;
	}
}

void consumer()
{
	bool available() {
		return exiting || widgets != 0;
	}

	int consumed = 0;
	while(true)
	{
		m.lock();
		scope(exit) m.unlock();

		m.waitFor(&available);
		if(widgets == 0 && exiting) break;
		assert(widgets > 0);
		--widgets;
		if(++consumed % 100000 == 0) {
			import std.stdio;
			//writeln("conusumed ", consumed);
		}
	}
}

void main()
{
	import core.thread;
	Thread[128] threads;
	foreach(i, ref t; threads) {
		t = new Thread((i & 1) ? &producer : &consumer);
		t.start;
	}

	foreach(ref t; threads) {
		t.join();
	}
	import std.stdio;
	assert(total == stopAfter + 1);
}
