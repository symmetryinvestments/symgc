import std.stdio;

import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

void main()
{
	auto f = &_d_register_sdc_gc;
	while(true)
	{
		auto arr = new int[10];
	}
}
