module sdcgc.intrinsics;

public import core.bitop : bsr, bsf, popcnt, bitswap;

// TODO: Change all uses of countLeadingZeros to bsr directly
auto countLeadingZeros(T)(T x) {
    enum S = T.sizeof * 8;
    return S - 1 - bsr(x);
}
alias countTrailingZeros = bsf;
alias popCount = popcnt;
alias bswap = bitswap;
