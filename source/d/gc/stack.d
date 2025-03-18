module d.gc.stack;

import d.gc.types;
import sdcgc.rt;

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

		import d.gc.range;
		scan(makeRange(top, bottom));
	}
}
