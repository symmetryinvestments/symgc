/+ dub.json:
   {
	"name": "stalemetadata",
	"dependencies": {
		"symgc" : {
			"path" : "../../"
		}
	},
	"targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Ensure metadata bit is cleared for next alloc

import symgc.gcobj;
import core.memory;
import std.stdio;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

struct HasDtor
{
	~this() { writeln("dtor");}
}

struct CorruptDtor
{
	size_t[2] val = 0xdeadbeefdeadbeef;
}

void main()
{
	HasDtor*[100] hd;
	foreach(i, ref p; hd)
		p = new HasDtor;
	foreach(i; 0 .. hd.length / 2)
		GC.free(hd[i * 2]);
	hd[] = null;
	foreach(i; 0 .. 20000) {
		new CorruptDtor;
		if(++i % 1000 == 0)
			writeln(i);
	}
}
