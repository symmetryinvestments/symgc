/+ dub.json:
   {
	   "name": "largearrayextend",
	   "dependencies": {
		   "symgc" : {
			   "path" : "../../"
		   }
	   },
	   "targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test extending an array into more blocks actually allows writing.
import symgc.gcobj;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];


void main() {
	// first, allocate an array of 4 MB. This will consume multiple blocks.
	// then double the size. Must keep going until we see it be an actual in-place extend.
	while(true) {
		ubyte[] arr;
		enum BlockSize = 2 * 1024 * 1024; // 2MB
		arr.length = 2 * BlockSize;
		auto ptr = arr.ptr;
		arr.length = arr.length * 2; // extend to 8 blocks
		if(ptr is arr.ptr) { // extended in place
			break;
		}
		import core.memory;
		GC.free(arr.ptr); // clear the array, try again.
	}
}
