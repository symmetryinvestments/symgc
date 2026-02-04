/+ dub.json:
   {
	   "name": "shrinkfit",
		"dependencies": {
			"symgc" : {
				"path" : "../../"
			}
		},
		"targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Ensure assumeSafeAppend works as expected

import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

void main() {
	auto arr = [1, 2, 3, 4];
	auto origcap = arr.capacity;
	assert(origcap != 0);
	arr = arr[0 .. 1];
	assert(arr.capacity == 0);
	arr.assumeSafeAppend;
	assert(arr.capacity == origcap);
}
