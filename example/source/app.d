import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

__gshared void[] arr;

void main()
{
	foreach(i; 0 .. 1000)
	{
		import core.stdc.stdio;
		if(i % 10000 == 0)
			printf("here %d\n", i);
		arr = new void[10_000_000];
	}
}
