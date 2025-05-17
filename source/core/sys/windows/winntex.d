/* Extra defs for windows */
module core.sys.windows.winntex;
import core.sys.windows.windef;

struct PROCESSOR_NUMBER {
  WORD Group;
  BYTE Number;
  BYTE Reserved;
}

extern(Windows) void GetCurrentProcessorNumberEx(PROCESSOR_NUMBER* ProcNumber);
