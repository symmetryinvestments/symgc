// runtime hooks needed to run the GC
// These normally would be in sdc's d.rt or elsewhere, but they are here as a
// shim until the GC code can be modified to use the hooks directly from
// druntime.
module sdcgc.rt;

import core.internal.traits;
alias callWithStackShell = externDFunc!("core.thread.osthread.callWithStackShell", void function(scope void delegate(void*) nothrow) nothrow);
void __sd_gc_push_registers(scope void delegate(void*) dg)
{
	auto nothrowdg = cast(void delegate(void*) nothrow)dg;
	callWithStackShell(nothrowdg);
}

alias druntimeGetStackBottom = externDFunc!("core.thread.osthread.getStackBottom", void* function() nothrow @nogc);
void* getStackBottom() {
	return druntimeGetStackBottom();
}

void registerGlobalSegments() {
	import core.sys.linux.link;

	static extern(C)
	int __global_callback(dl_phdr_info* info, size_t size, void* data) {
		auto offset = info.dlpi_addr;

		auto segmentCount = info.dlpi_phnum;
		foreach (i; 0 .. segmentCount) {
			auto segment = info.dlpi_phdr[i];

			import core.sys.linux.elf;
			if (segment.p_type != PT_LOAD || !(segment.p_flags & PF_W)) {
				continue;
			}

			import d.gc.capi;
			auto start = cast(void*) (segment.p_vaddr + offset);
			__sd_gc_add_roots(start[0 .. segment.p_memsz]);
		}

		return 0;
	}

	// TODO: this cast is ugly
	alias ftype = extern(C) int function(dl_phdr_info*, size_t, void*) nothrow @nogc;
	dl_iterate_phdr(cast(ftype)&__global_callback, null);
}

void registerTlsSegments() {
	import core.sys.linux.link;

	static extern(C)
	int __tls_callback(dl_phdr_info* info, size_t size, void* data) {
		auto tlsStart = info.dlpi_tls_data;
		if (tlsStart is null) {
			// FIXME: make sure this is not lazy initialized or something.
			return 0;
		}

		auto segmentCount = info.dlpi_phnum;
		foreach (i; 0 .. segmentCount) {
			auto segment = info.dlpi_phdr[i];

			import core.sys.linux.elf;
			if (segment.p_type != PT_TLS) {
				continue;
			}

			import d.gc.capi;
			__sd_gc_add_tls_segment(tlsStart[0 .. segment.p_memsz]);
		}

		return 0;
	}
	alias ftype = extern(C) int function(dl_phdr_info*, size_t, void*) nothrow @nogc;

	dl_iterate_phdr(cast(ftype)&__tls_callback, null);
}
