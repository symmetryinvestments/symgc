import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

void main()
{
	while(true)
	{
		auto arr = new int[10];
	}
}
