import std.stdio;
import std.file;
import std.algorithm;
import std.string;
import std.conv;
import std.array;
import std.range;
import std.system;
import core.time;

struct TestHarness
{
	string filename;
	string description;
	string output;
	int expectedRetval;
	int retval;
	bool timedout;
	OS[] platforms;
	Duration timeout = 2.minutes;
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
				case "platform":
					harness.platforms = line[colon + 1 .. $].splitter(",").map!(s => s.strip.to!OS).array;
					break;
				case "timeout":
					harness.timeout = line[colon + 1 .. $].strip.to!uint.msecs;
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
	import core.thread;

	write(i"TEST $(th.filename) ...");
	stdout.flush();
	auto args = ["dub", "--single"];
	if(verbose)
		args ~= "-v";
	if(force)
		args ~= "--force";
	args ~= th.filename;
	auto pid = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout);
	void processKiller() {
		auto waitFor(Duration d) {
			version(Posix) {
				// no timed wait, have to use trywait
				auto start = MonoTime.currTime;
				while(true) {
					auto r = tryWait(pid.pid);
					if(r.terminated)
						return r;
					auto elapsed = MonoTime.currTime - start;
					auto sleepTime = d - elapsed;
					if(sleepTime < Duration.zero)
						return r;
					if(sleepTime > 100.msecs)
						sleepTime = 100.msecs;
					Thread.sleep(sleepTime);
				}
			} else {
				return waitTimeout(pid.pid, d);
			}
		}

		auto r = waitFor(th.timeout);
		if(!r.terminated)
		{
			th.timedout = true;
			pid.pid.kill;
			r = waitFor(1.seconds);
			if (!r.terminated) {
				// really kill it
				version(Posix) {
					import core.sys.posix.signal : SIGKILL;
				} else {
					enum SIGKILL = 9;
				}
				pid.pid.kill(SIGKILL);
				r = waitFor(1.seconds);
				if(!r.terminated)
				{
					stderr.writeln(i"Could not kill test process $(th.filename)!");
					import core.stdc.stdlib;
					exit(1);
				}
			}
		}
		th.retval = r.status;
	}

	auto killerThread = new Thread(&processKiller);
	killerThread.start();

	// accumulate the output from the process
	auto a = appender!string;
	foreach(ubyte[] chunk; pid.stdout.byChunk(4096))
		put(a, chunk);

	// killerThread is responsible for joining the process and filling in th.retval.
	killerThread.join();

	if(th.timedout || th.retval != th.expectedRetval) {
		if(th.timedout)
			writeln(i"FAILED timed out after $(th.timeout)!");
		else
			writeln(i"FAILED with return code $(th.retval), expected $(th.expectedRetval)");
		writeln("test output:");
		writeln(a.data);
		return false;
	}
	else
	{
		writeln("PASSED");
		if(verbose)
		{
			writeln("test output:");
			writeln(a.data);
		}
		return true;
	}
}

int main(string[] args)
{
	version(Windows)
		enum myPlatform = "windows";
	else version(linux)
		enum myPlatform = "linux";
	else static assert("Platform not supported yet!");
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
		{
			write(i"$(th.filename) - $(th.description)");
			if (th.platforms.length) {
				writef(" [platform(s): %-(%s, %)]", th.platforms);
			}
			writeln();
		}
		return 0;
	}

	auto targets = args[1 .. $];
	int npassed = 0;
	int nrun = 0;
	foreach(ref th; tests)
	{
		bool doRun = true;
		if(targets.length > 0 && !targets.canFind!((t, needle) => needle.filename.startsWith(t))(th)) {
			if(verbose) writeln("skipping unselected test ", th.filename);
			doRun = false;
		}

		if(doRun && th.platforms.length > 0 && !th.platforms.canFind(os)) {
			if(verbose) writeln("skipping unmatching platform test ", th.filename);
			doRun = false;
		}
		if(!doRun) {
			writeln(i"TEST $(th.filename) ...SKIPPED");
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
