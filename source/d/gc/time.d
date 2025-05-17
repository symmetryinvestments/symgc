module d.gc.time;

import core.time;

enum ulong Microsecond = 10;
enum ulong Millisecond = 1000 * Microsecond;
enum ulong Second = 1000 * Millisecond;
enum ulong Minute = 60 * Second;
enum ulong Hour = 60 * Minute;
enum ulong Day = 24 * Hour;
enum ulong Week = 7 * Day;

ulong getMonotonicTime() {
	auto cur = MonoTime.currTime();
	return (cur - MonoTime.zero).total!"hnsecs";
}
