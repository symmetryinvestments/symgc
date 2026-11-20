// runtime hooks needed to run the GC
// These normally would be in sdc's d.rt or elsewhere, but they are here as a
// shim until the GC code can be modified to use the hooks directly from
// druntime.
module symgc.rt;

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

version(Symgc_pthread_hook):

void registerGlobalSegments() {
	version(OSX) {
		import core.sys.darwin.mach.dyld : _dyld_get_image_header,
			_dyld_get_image_vmaddr_slide, _dyld_image_count;
		import core.sys.darwin.mach.getsect : getsectbynamefromheader_64;
		import core.sys.darwin.mach.loader : mach_header_64, SECT_BSS,
			SECT_COMMON, SECT_DATA, SEG_DATA;

		foreach (i; 0 .. _dyld_image_count()) {
			auto header = cast(const(mach_header_64)*) _dyld_get_image_header(i);
			if (header is null)
				continue;

			auto slide = _dyld_get_image_vmaddr_slide(i);
			foreach (sectionName; [SECT_DATA.ptr, SECT_BSS.ptr, SECT_COMMON.ptr]) {
				auto section = getsectbynamefromheader_64(
					header, SEG_DATA.ptr, sectionName);
				if (section is null || section.size == 0)
					continue;

				import d.gc.capi;
				auto start = cast(void*) section.addr + slide;
				__sd_gc_add_roots(start[0 .. cast(size_t) section.size]);
			}
		}
	} else version(linux) {
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
}

void registerTlsSegments() {
	version(OSX) {
		import core.sys.darwin.mach.dyld : _dyld_get_image_header,
			_dyld_get_image_vmaddr_slide, _dyld_image_count;
		import core.sys.darwin.mach.loader : LC_SEGMENT_64, SECTION_TYPE,
			S_THREAD_LOCAL_REGULAR, S_THREAD_LOCAL_VARIABLES,
			S_THREAD_LOCAL_ZEROFILL, mach_header_64, load_command,
			segment_command_64, section_64, tlv_descriptor;
		import core.sys.posix.pthread : pthread_getspecific, pthread_key_t;

		foreach (i; 0 .. _dyld_image_count()) {
			auto header = cast(const(mach_header_64)*) _dyld_get_image_header(i);
			if (header is null)
				continue;

			auto slide = _dyld_get_image_vmaddr_slide(i);

			/**
			 * dyld gives each image one thread local block per thread.
			 * All the thread local sections of the image live in that block
			 * in image order, so the block spans from the start of the first
			 * such section to the end of the last one.
			 */
			const(tlv_descriptor)* descriptor = null;
			size_t blockStart = size_t.max;
			size_t blockEnd = 0;

			auto command = cast(const(load_command)*)
				(cast(const(ubyte)*) header + mach_header_64.sizeof);
			foreach (_; 0 .. header.ncmds) {
				if (command.cmdsize == 0)
					break;

				if (command.cmd == LC_SEGMENT_64) {
					auto segment = cast(const(segment_command_64)*) command;
					auto sections = (cast(const(section_64)*)
						(cast(const(ubyte)*) segment + segment_command_64.sizeof))
						[0 .. segment.nsects];
					foreach (ref section; sections) {
						auto type = section.flags & SECTION_TYPE;
						if (type == S_THREAD_LOCAL_VARIABLES) {
							if (descriptor is null && section.size > 0) {
								descriptor = cast(const(tlv_descriptor)*)
									(cast(size_t) section.addr + slide);
							}
						} else if (type == S_THREAD_LOCAL_REGULAR
							|| type == S_THREAD_LOCAL_ZEROFILL) {
							if (section.addr < blockStart)
								blockStart = section.addr;
							if (section.addr + section.size > blockEnd)
								blockEnd = section.addr + section.size;
						}
					}
				}

				command = cast(const(load_command)*)
					(cast(const(ubyte)*) command + command.cmdsize);
			}

			if (descriptor is null || blockStart >= blockEnd)
				continue;

			/**
			 * dyld allocates the block lazily, on first access from each
			 * thread. Go through the descriptor's thunk so that the block
			 * exists before looking it up, otherwise the thread locals this
			 * thread has not touched yet would never be scanned.
			 */
			alias Thunk = extern(C) void* function(const(tlv_descriptor)*);
			(cast(Thunk) descriptor.thunk)(descriptor);

			// macOS 15.4 may populate the upper half of this field. Only the
			// low 32 bits are the pthread key.
			auto key = cast(pthread_key_t) (descriptor.key & 0xffff_ffff);
			auto block = cast(void*) pthread_getspecific(key);
			assert(block !is null, "dyld did not allocate the TLS block!");

			import d.gc.capi;
			__sd_gc_add_tls_segment(block[0 .. blockEnd - blockStart]);
		}
	} else version(linux) {
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
}
