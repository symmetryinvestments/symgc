module d.sync.futex.futex;

version(linux):
import d.sync.atomic;

import core.sys.linux.futex;
import core.stdc.errno;
import symgc.intrinsics: likely, unlikely;
import core.stdc.config;

extern(C) long syscall(long number, ...);

enum SYS_futex = 202;

int futex_wait(shared(Atomic!uint)* futex,
               uint expected, /* TODO: timeout */ ) {
	import core.sys.posix.unistd;
	auto err = syscall(SYS_futex, cast(uint*) futex, Futex.WaitPrivate,
	                   expected, null);
	if (likely(err < 0)) {
		return -errno;
	}

	return 0;
}

int futex_wake(shared Atomic!uint* futex, uint count) {
	import core.sys.posix.unistd;
	auto err = syscall(SYS_futex, cast(uint*) futex, Futex.WakePrivate, count);
	if (unlikely(err < 0)) {
		return -errno;
	}

	return 0;
}

int futex_wake_one(shared Atomic!uint* futex) {
	return futex_wake(futex, 1);
}

int futex_wake_all(shared Atomic!uint* futex) {
	return futex_wake(futex, uint.max);
}
