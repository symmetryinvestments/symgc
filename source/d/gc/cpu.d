module d.gc.cpu;

auto getCoreCount() {
	auto coreCountPtr = cast(uint*) &gCoreCount;
	if (*coreCountPtr == 0) {
		*coreCountPtr = computeCoreCount();
	}

	return *coreCountPtr;
}

private:
shared uint gCoreCount;

auto computeCoreCount() {
	version(linux) {
		import core.sys.linux.sched;
		cpu_set_t set;
		sched_getaffinity(0, cpu_set_t.sizeof, &set);
		return CPU_COUNT(&set);
	}
	else version(Windows) {
		import core.cpuid;
		return threadsPerCPU();
	}
	else version(OSX) {
		import core.sys.darwin.sys.sysctl : CTL_HW, HW_AVAILCPU, HW_NCPU,
			sysctl;

		int[2] mib = [CTL_HW, HW_AVAILCPU];
		int count;
		size_t length = count.sizeof;
		if (sysctl(mib.ptr, mib.length, &count, &length, null, 0) != 0
				|| count <= 0) {
			mib[1] = HW_NCPU;
			length = count.sizeof;
			assert(sysctl(mib.ptr, mib.length, &count, &length, null, 0) == 0,
			       "Unable to query the Darwin CPU count");
		}

		assert(count > 0, "Darwin reported no CPUs");
		return cast(uint) count;
	}
}

@"getCoreCount" unittest {
	version(linux) {
		import core.sys.linux.sys.sysinfo;
		assert(getCoreCount() == get_nprocs());
	}
	else version(OSX) {
		import core.sys.darwin.sys.sysctl : CTL_HW, HW_AVAILCPU, HW_NCPU,
			sysctl;
		int[2] mib = [CTL_HW, HW_AVAILCPU];
		int count;
		size_t length = count.sizeof;
		assert(sysctl(mib.ptr, mib.length, &count, &length, null, 0) == 0);
		if (count <= 0) {
			mib[1] = HW_NCPU;
			length = count.sizeof;
			assert(sysctl(mib.ptr, mib.length, &count, &length, null, 0) == 0);
		}
		assert(getCoreCount() == count);
	}
}
