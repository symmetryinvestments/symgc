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
