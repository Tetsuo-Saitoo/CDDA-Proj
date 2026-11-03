# Dumps every thread's call stack of a running x64 process (module+offset, symbols where dbghelp finds them).
# usage: python -I stacks.py <pid>
import ctypes
import sys
from ctypes import wintypes as wt

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
dbg = ctypes.WinDLL("dbghelp", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

PROCESS_ALL_ACCESS = 0x1F0FFF
THREAD_ALL_ACCESS = 0x1FFFFF
TH32CS_SNAPTHREAD = 4
CONTEXT_FULL = 0x10000B


class THREADENTRY32(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ThreadID", wt.DWORD),
                ("th32OwnerProcessID", wt.DWORD), ("tpBasePri", ctypes.c_long), ("tpDeltaPri", ctypes.c_long),
                ("dwFlags", wt.DWORD)]


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [("SizeOfStruct", wt.ULONG), ("TypeIndex", wt.ULONG), ("Reserved", ctypes.c_uint64 * 2),
                ("Index", wt.ULONG), ("Size", wt.ULONG), ("ModBase", ctypes.c_uint64), ("Flags", wt.ULONG),
                ("Value", ctypes.c_uint64), ("Address", ctypes.c_uint64), ("Register", wt.ULONG),
                ("Scope", wt.ULONG), ("Tag", wt.ULONG), ("NameLen", wt.ULONG), ("MaxNameLen", wt.ULONG),
                ("Name", wt.WCHAR * 512)]


k32.OpenProcess.restype = wt.HANDLE
k32.OpenThread.restype = wt.HANDLE
k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
dbg.SymFunctionTableAccess64.restype = ctypes.c_void_p
dbg.SymFunctionTableAccess64.argtypes = [wt.HANDLE, ctypes.c_uint64]
dbg.SymGetModuleBase64.restype = ctypes.c_uint64
dbg.SymGetModuleBase64.argtypes = [wt.HANDLE, ctypes.c_uint64]
FTA = ctypes.WINFUNCTYPE(ctypes.c_void_p, wt.HANDLE, ctypes.c_uint64)
GMB = ctypes.WINFUNCTYPE(ctypes.c_uint64, wt.HANDLE, ctypes.c_uint64)
fta = FTA(lambda h, a: dbg.SymFunctionTableAccess64(h, a))
gmb = GMB(lambda h, a: dbg.SymGetModuleBase64(h, a))
dbg.StackWalk64.argtypes = [wt.DWORD, wt.HANDLE, wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                            FTA, GMB, ctypes.c_void_p]
dbg.SymFromAddrW.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64),
                             ctypes.POINTER(SYMBOL_INFOW)]
psapi.GetModuleFileNameExW.argtypes = [wt.HANDLE, wt.HMODULE, wt.LPWSTR, wt.DWORD]


def main(pid):
    hp = k32.OpenProcess(PROCESS_ALL_ACCESS, False, pid)
    if not hp:
        sys.exit("OpenProcess failed %d" % ctypes.get_last_error())
    dbg.SymSetOptions(0x2 | 0x4)  # UNDNAME | DEFERRED_LOADS
    dbg.SymInitializeW(hp, None, True)
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    te = THREADENTRY32()
    te.dwSize = ctypes.sizeof(te)
    tids = []
    ok = k32.Thread32First(snap, ctypes.byref(te))
    while ok:
        if te.th32OwnerProcessID == pid:
            tids.append(te.th32ThreadID)
        ok = k32.Thread32Next(snap, ctypes.byref(te))
    raw = ctypes.create_string_buffer(1232 + 16)
    ctx_addr = (ctypes.addressof(raw) + 15) & ~15
    sym = SYMBOL_INFOW()
    namebuf = ctypes.create_unicode_buffer(520)
    for tid in tids:
        ht = k32.OpenThread(THREAD_ALL_ACCESS, False, tid)
        k32.SuspendThread(ht)
        ctypes.memset(ctx_addr, 0, 1232)
        ctypes.c_uint32.from_address(ctx_addr + 0x30).value = CONTEXT_FULL
        if not k32.GetThreadContext(ht, ctypes.c_void_p(ctx_addr)):
            print("thread %d: GetThreadContext failed" % tid)
            k32.ResumeThread(ht)
            continue
        frame = ctypes.create_string_buffer(512)
        fa = ctypes.addressof(frame)
        for off, reg in ((0, 0xF8), (32, 0xA0), (48, 0x98)):  # PC=Rip, Frame=Rbp, Stack=Rsp
            ctypes.c_uint64.from_address(fa + off).value = ctypes.c_uint64.from_address(ctx_addr + reg).value
            ctypes.c_int32.from_address(fa + off + 12).value = 3
        lines = []
        for _ in range(40):
            if not dbg.StackWalk64(0x8664, hp, ht, ctypes.c_void_p(fa), ctypes.c_void_p(ctx_addr), None, fta,
                                   gmb, None):
                break
            pc = ctypes.c_uint64.from_address(fa).value
            if pc == 0:
                break
            base = dbg.SymGetModuleBase64(hp, pc)
            mod = "?"
            if base and psapi.GetModuleFileNameExW(hp, wt.HMODULE(base), namebuf, 520):
                mod = namebuf.value.rsplit("\\", 1)[-1]
            sym.SizeOfStruct = 88
            sym.MaxNameLen = 500
            disp = ctypes.c_uint64()
            name = ""
            if dbg.SymFromAddrW(hp, pc, ctypes.byref(disp), ctypes.byref(sym)):
                name = "%s+0x%x" % (sym.Name, disp.value)
            lines.append("    %s!%s (+0x%x)" % (mod, name, pc - base if base else pc))
        k32.ResumeThread(ht)
        k32.CloseHandle(ht)
        print("thread %d:" % tid)
        print("\n".join(lines))


main(int(sys.argv[1]))
