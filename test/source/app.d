import std.stdio;
import std.file;
import std.algorithm;
import std.string;
import std.conv;
import std.array;
import std.range;

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

bool runTest(ref TestHarness th, bool verbose, bool force)
{
	import std.process;
	write(i"TEST $(th.filename) ...");
	stdout.flush();
	auto args = ["dub", "--single"];
	if(verbose)
		args ~= "-v";
	if(force)
		args ~= "--force";
	args ~= th.filename;
	auto result = execute(args);
	th.retval = result.status;
	if(th.retval != th.expectedRetval) {
		writeln(i"FAILED with return code $(th.retval), expected $(th.expectedRetval)");
		writeln("test output:");
		writeln(result.output);
		return false;
	}
	else
	{
		writeln("PASSED");
		if(verbose)
		{
			writeln("test output:");
			writeln(result.output);
		}
		return true;
	}
}

int main(string[] args)
{
	import std.getopt;
	bool verbose = false;
	bool info = false;
	bool force = false;
	auto helpInformation = getopt(args,
			"v|verbose", &verbose,
			"i|info", "List and describe tests", &info,
			"f|force", "pass `--force` to dub to ensure rebuilds", &force);
	if(helpInformation.helpWanted)
	{
		defaultGetoptPrinter("Test harness for Symgc integration tests. Specify prefixes of tests to run if desired.\n\tUsage: tester [options] [prefix1] [prefix2] ...",
				helpInformation.options);
		return 0;
	}

	TestHarness[] tests = dirEntries("base", SpanMode.shallow)
		.chain(dirEntries("druntime", SpanMode.shallow))
		.filter!(de => de.isFile && de.name.endsWith(".d"))
		.map!(de => parseTest(de.name))
		.array;
	tests.sort!((ref TestHarness a, ref TestHarness b) => a.filename < b.filename);
	if(info) {
		// instead of running tests, just list all the tests and the information about them.
		foreach(th; tests)
			writeln(i"$(th.filename) - $(th.description)");
		return 0;
	}

	auto targets = args[1 .. $];
	int npassed = 0;
	int nrun = 0;
	foreach(ref th; tests)
	{
		bool doRun = targets.length == 0;
		foreach(t; targets) {
			if(th.filename.startsWith(t)) {
				doRun = true;
			}
		}
		if(!doRun) {
			if(verbose) writeln("skipping unselected test ", th.filename);
			continue;
		}
		++nrun;
		npassed += th.runTest(verbose: verbose, force: force);
	}
	if(nrun == 0)
	{
		writeln("NO TESTS SELECTED, check prefix filters: ", targets);
		return 1;
	}
	writeln(i"SUMMARY: $(nrun) Tests run, $(npassed) PASSED, $(nrun - npassed) FAILED, $(tests.length - nrun) SKIPPED");
	return npassed == nrun ? 0 : 1;
}
