"""Host-side only feasibility probe. No device handle is opened, no USB traffic is sent.

Answers: can a ctypes WinUSB raw client reach the phone's fastboot interface?
Output is ASCII on purpose (Windows console here is not UTF-8).
"""
import ctypes as C
from ctypes import wintypes as W
import sys

setupapi = C.WinDLL("setupapi", use_last_error=True)
kernel32 = C.WinDLL("kernel32", use_last_error=True)

GUID_DEVINTERFACE_USB_DEVICE = (0xA5DCBF10, 0x6530, 0x11D2,
                                (0x90, 0x1F, 0x00, 0xC0, 0x4F, 0xB9, 0x51, 0xED))


class GUID(C.Structure):
    _fields_ = [("Data1", W.DWORD), ("Data2", W.WORD), ("Data3", W.WORD),
                ("Data4", W.BYTE * 8)]


class SP_DEVICE_INTERFACE_DATA(C.Structure):
    _fields_ = [("cbSize", W.DWORD), ("InterfaceClassGuid", GUID),
                ("Flags", W.DWORD), ("Reserved", C.POINTER(W.ULONG))]


DIGCF_PRESENT = 0x02
DIGCF_DEVICEINTERFACE = 0x10
INVALID_HANDLE_VALUE = C.c_void_p(-1).value

setupapi.SetupDiGetClassDevsW.argtypes = [C.POINTER(GUID), W.LPCWSTR, W.HWND, W.DWORD]
setupapi.SetupDiGetClassDevsW.restype = W.HANDLE
setupapi.SetupDiEnumDeviceInterfaces.argtypes = [
    W.HANDLE, C.c_void_p, C.POINTER(GUID), W.DWORD, C.POINTER(SP_DEVICE_INTERFACE_DATA)]
setupapi.SetupDiEnumDeviceInterfaces.restype = W.BOOL
setupapi.SetupDiGetDeviceInterfaceDetailW.argtypes = [
    W.HANDLE, C.POINTER(SP_DEVICE_INTERFACE_DATA), C.c_void_p, W.DWORD,
    C.POINTER(W.DWORD), C.c_void_p]
setupapi.SetupDiGetDeviceInterfaceDetailW.restype = W.BOOL
setupapi.SetupDiDestroyDeviceInfoList.argtypes = [W.HANDLE]


def enum_usb_paths():
    g = GUID(*GUID_DEVINTERFACE_USB_DEVICE)
    h = setupapi.SetupDiGetClassDevsW(C.byref(g), None, None,
                                      DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)
    if h == INVALID_HANDLE_VALUE:
        raise OSError("SetupDiGetClassDevs failed", C.get_last_error())
    out = []
    try:
        i = 0
        while True:
            d = SP_DEVICE_INTERFACE_DATA()
            d.cbSize = C.sizeof(SP_DEVICE_INTERFACE_DATA)
            if not setupapi.SetupDiEnumDeviceInterfaces(h, None, C.byref(g), i, C.byref(d)):
                break
            need = W.DWORD(0)
            setupapi.SetupDiGetDeviceInterfaceDetailW(h, C.byref(d), None, 0,
                                                      C.byref(need), None)
            buf = C.create_string_buffer(need.value)
            C.memmove(buf, C.byref(W.DWORD(8 if C.sizeof(C.c_void_p) == 8 else 6)), 4)
            if not setupapi.SetupDiGetDeviceInterfaceDetailW(
                    h, C.byref(d), buf, need.value, C.byref(need), None):
                i += 1
                continue
            path = C.wstring_at(C.addressof(buf) + 4)
            out.append(path)
            i += 1
    finally:
        setupapi.SetupDiDestroyDeviceInfoList(h)
    return out


def main():
    try:
        wu = C.WinDLL("winusb")
        names = ["WinUsb_Initialize", "WinUsb_QueryInterfaceSettings",
                 "WinUsb_QueryPipe", "WinUsb_WritePipe", "WinUsb_ReadPipe",
                 "WinUsb_ControlTransfer", "WinUsb_Free", "WinUsb_GetOverlappedResult"]
        print("winusb.dll: LOADED")
        for n in names:
            try:
                getattr(wu, n)
                print("  export OK   " + n)
            except AttributeError:
                print("  export MISS " + n)
    except OSError as e:
        print("winusb.dll: NOT LOADABLE -> %s" % e)
        return 2

    paths = enum_usb_paths()
    print("present USB device interfaces: %d" % len(paths))
    hits = []
    for p in paths:
        u = p.upper()
        if "VID_18D1" in u or "VID_12D1" in u:
            tag = "PHONE-fastboot" if ("VID_18D1" in u and "PID_D00D" in u) else \
                  "PHONE-COM1.0" if ("VID_12D1" in u and "PID_3609" in u) else "other-huawei"
            print("  [%s] %s" % (tag, p))
            if tag.startswith("PHONE"):
                hits.append(p)
    if not hits:
        print("RESULT: no phone interface present right now.")
        return 3
    print("RESULT: %d phone interface path(s) reachable via WinUSB. Raw client is feasible." % len(hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())