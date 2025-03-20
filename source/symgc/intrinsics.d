module symgc.intrinsics;

public import core.bitop : bsr, bsf, popcnt, bswap;
public import core.builtins : likely, unlikely;

// TODO: Change all uses of countLeadingZeros to bsr directly
auto countLeadingZeros(T)(T x) {
	enum S = T.sizeof * 8;
	return S - 1 - bsr(x);
}
alias countTrailingZeros = bsf;
alias popCount = popcnt;

// copy atomicOp, but with returning the get value.
T atomicFetchOp(string op, T, V1)(ref shared T val, V1 mod)
{
	import core.atomic : atomicLoad, casWeak, MemoryOrder;
	T set, get = atomicLoad!(MemoryOrder.raw, T)(val);
	do
	{
		set = get;
		mixin("set = get " ~ op ~ " mod;");
	} while (!casWeak(&val, &get, set));
	return get;
}
