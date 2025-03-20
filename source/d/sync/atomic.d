module d.sync.atomic;

import drta = core.atomic;
import symgc.intrinsics;

enum MemoryOrder : drta.MemoryOrder {
	Relaxed = drta.MemoryOrder.raw,
	Consume = drta.MemoryOrder.acq, // currently a synonym for acquire.
	Acquire = drta.MemoryOrder.acq,
	Release = drta.MemoryOrder.rel,
	AcqRel = drta.MemoryOrder.acq_rel,
	SeqCst = drta.MemoryOrder.seq,
}

/**
 * For now, this simply uses the strongest possible memory order,
 * rather than the one specified by the user.
 *
 * FIXME: Actually use the provided ordering.
 */
struct Atomic(T) {
private:
	T value;

public:
	T load(MemoryOrder order = MemoryOrder.SeqCst)() shared {
		return drta.atomicLoad!order(value);
	}

	void store(MemoryOrder order = MemoryOrder.SeqCst)(T value) shared {
		drta.atomicStore!order(this.value, value);
	}

	T fetchAdd(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return drta.atomicFetchAdd(value, n);
	}

	T fetchSub(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return drta.atomicFetchSub(value, n);
	}

	T fetchAnd(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return atomicFetchOp!"&"(value, n);
	}

	T fetchOr(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return atomicFetchOp!"|"(value, n);
	}

	T fetchXor(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return atomicFetchOp!"^"(value, n);
	}

	bool cas(MemoryOrder order = MemoryOrder.SeqCst)(ref T expected, T desired) shared {
		return drta.cas(&value, &expected, desired);
	}

	bool casWeak(MemoryOrder order = MemoryOrder.SeqCst)(ref T expected, T desired) shared {
		return drta.casWeak(&value, &expected, desired);
	}
}
