import std.stdio;
import std.file;
import std.algorithm;
import std.string;
import std.conv;
import std.array;

struct TestHarness
{
	string filename;
	string description;
	string output;
	int expectedRetval;
	int retval;
}

TestHarness parseTest(string filename)
{
	auto filecontents = readText(filename);
	TestHarness harness;
	harness.filename = filename;
	foreach(line; filecontents.splitter("\n").map!strip)
	{
		if(line.startsWith("//T"))
		{
			// format is: //T field:value
			auto colon = line.indexOf(':');
			switch(line[3 .. colon].strip)
			{
				case "retval":
					harness.expectedRetval = line[colon + 1 .. $].strip.to!int;
					break;
				case "desc":
					harness.description = line[colon + 1 .. $].strip;
					break;
				default:
					break;
			}
		}
	}
	return harness;
}

void runTest(ref TestHarness th, bool verbose)
{
	import std.process;
	auto result = execute(["dub", "--single", th.filename]);
	th.retval = result.status;
	if(th.retval != th.expectedRetval) {
		writeln(i"TEST $(th.filename) FAILED with return code $(th.retval), expected $(th.expectedRetval)");
		writeln("test output:");
		writeln(result.output);
	}
	else
	{
		writeln(i"TEST $(th.filename) PASSED");
		if(verbose)
		{
			writeln("test output:");
			writeln(result.output);
		}
	}
}

void main()
{
	TestHarness[] tests = dirEntries("valid", SpanMode.shallow)
		.filter!(de => de.isFile && de.name.endsWith(".d"))
		.map!(de => parseTest(de.name))
		.array;
	tests.sort!((ref TestHarness a, ref TestHarness b) => a.filename < b.filename);

	foreach(ref th; tests)
	{
		th.runTest(verbose: true);
	}
}
