/+ dub.json:
   {
	   "name": "simple",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Simple test for integration with druntime.

import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

void main() {
	foreach(i; 0 .. 10_000)
	{
		auto arr = new int*[i];
	}
}
