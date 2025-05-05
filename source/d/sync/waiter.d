module d.sync.waiter;

version(linux) {
    import d.sync.futex.waiter;
    alias Waiter = FutexWaiter;
} else version(Windows) {
    import d.sync.win32.waiter;
    alias Waiter = Win32Waiter;
} else {
    static assert(false, "Unsupported platform");
}