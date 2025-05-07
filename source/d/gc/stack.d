module d.gc.stack;

version(linux):

import d.gc.types;
import symgc.rt;

void scanStack(ScanDg scan) {
	auto ts = ThreadScanner(scan);
	__sd_gc_push_registers(&ts.scanStack);
}

private:

struct ThreadScanner {
	ScanDg scan;

	this(ScanDg scan) {
		this.scan = scan;
	}

	void scanStack(void* top) {
		import d.gc.tcache;
		auto bottom = threadCache.stackBottom;
		version(Symgc_druntime_hooks) {
			// TODO: need to look up Thread.getThis() twice, because there is
			// no public way to get the stack bottom from a thread instance,
			// and if we try to call thread_stackBottom() blindly, a null
			// current thread pointer could trigger a segfault.
			import core.thread;
			if (Thread.getThis() !is null) {
				bottom = thread_stackBottom();
			}
			assert(bottom !is null, "Null stack bottom!");
		}

		import d.gc.range;
		scan(makeRange(top, bottom));
	}
}
