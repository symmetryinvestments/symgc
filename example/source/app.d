import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

void main()
{
	foreach(i; 0 .. 200000)
	{
		import core.stdc.stdio;
		if(i % 1000 == 0)
			printf("here %d\n", i);
		auto arr = new int[i];
	}
}
