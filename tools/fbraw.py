"""Raw WinUSB fastboot client for the Huawei/Hisi LK extensions that AOSP fastboot.exe cannot speak.

ZERO-WRITE BY CONSTRUCTION:
  * a hard send-whitelist (ALLOW) gates every command string;
  * if the device answers DATA (i.e. asks us to send a payload) we ABORT and never send one;
  * flash:/erase:/download:/reboot/boot/continue/ultraflash: are not in ALLOW and cannot be sent.

Only the command string is ever written to the bulk OUT pipe. Everything else is read.
Output is ASCII on purpose (this Windows console is not UTF-8).
"""
import ctypes as C
from ctypes import wintypes as W
import argparse
import os
import re
import sys
import time

PHONE_VIDPID = "vid_18d1&pid_d00d"
USB_IFACE_GUID = (0xA5DCBF10, 0x6530, 0x11D2,
                  (0x90, 0x1F, 0x00, 0xC0, 0x4F, 0xB9, 0x51, 0xED))

setupapi = C.WinDLL("setupapi", use_last_error=True)
kernel32 = C.WinDLL("kernel32", use_last_error=True)
winusb = C.WinDLL("winusb", use_last_error=True)


class GUID(C.Structure):
    _fields_ = [("Data1", W.DWORD), ("Data2", W.WORD), ("Data3", W.WORD),
                ("Data4", W.BYTE * 8)]


class SP_DEVICE_INTERFACE_DATA(C.Structure):
    _fields_ = [("cbSize", W.DWORD), ("InterfaceClassGuid", GUID),
                ("Flags", W.DWORD), ("Reserved", C.POINTER(W.ULONG))]


class USB_INTERFACE_DESCRIPTOR(C.Structure):
    _fields_ = [(n, W.BYTE) for n in (
        "bLength", "bDescriptorType", "bInterfaceNumber", "bAlternateSetting",
        "bNumEndpoints", "bInterfaceClass", "bInterfaceSubClass",
        "bInterfaceProtocol", "iInterface")]


class WINUSB_PIPE_INFORMATION(C.Structure):
    _pack_ = 1
    _fields_ = [("PipeType", C.c_uint), ("PipeId", W.BYTE),
                ("MaximumPacketSize", W.USHORT), ("Interval", W.BYTE)]


class WINUSB_PIPE_INFORMATION_UNPACKED(C.Structure):
    _fields_ = [("PipeType", C.c_uint), ("PipeId", W.BYTE),
                ("MaximumPacketSize", W.USHORT), ("Interval", W.BYTE)]


class WINUSB_SETUP_PACKET(C.Structure):
    _pack_ = 1
    _fields_ = [("RequestType", W.BYTE), ("Request", W.BYTE), ("Value", W.USHORT),
                ("Index", W.USHORT), ("Length", W.USHORT)]


DIGCF_PRESENT, DIGCF_DEVICEINTERFACE = 0x02, 0x10
INVALID_HANDLE_VALUE = C.c_void_p(-1).value
GENERIC_READ, GENERIC_WRITE = 0x80000000, 0x40000000
FILE_SHARE_READ, FILE_SHARE_WRITE = 1, 2
OPEN_EXISTING, FILE_FLAG_OVERLAPPED = 3, 0x40000000
USBD_PIPE_TYPE_BULK = 2
PIPE_TRANSFER_TIMEOUT = 0x03
ALLOW_PARTIAL_READS = 0x05
AUTO_CLEAR_STALL = 0x02

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

kernel32.CreateFileW.argtypes = [W.LPCWSTR, W.DWORD, W.DWORD, C.c_void_p,
                                 W.DWORD, W.DWORD, W.HANDLE]
kernel32.CreateFileW.restype = W.HANDLE
kernel32.CloseHandle.argtypes = [W.HANDLE]

winusb.WinUsb_Initialize.argtypes = [W.HANDLE, C.POINTER(C.c_void_p)]
winusb.WinUsb_Initialize.restype = W.BOOL
winusb.WinUsb_Free.argtypes = [C.c_void_p]
winusb.WinUsb_QueryInterfaceSettings.argtypes = [C.c_void_p, W.BYTE,
                                                 C.POINTER(USB_INTERFACE_DESCRIPTOR)]
winusb.WinUsb_QueryInterfaceSettings.restype = W.BOOL
winusb.WinUsb_QueryPipe.argtypes = [C.c_void_p, W.BYTE, W.BYTE, C.c_void_p]
winusb.WinUsb_QueryPipe.restype = W.BOOL
winusb.WinUsb_SetPipePolicy.argtypes = [C.c_void_p, W.BYTE, W.DWORD, W.DWORD, C.c_void_p]
winusb.WinUsb_SetPipePolicy.restype = W.BOOL
winusb.WinUsb_WritePipe.argtypes = [C.c_void_p, W.BYTE, C.c_void_p, W.DWORD,
                                    C.POINTER(W.DWORD), C.c_void_p]
winusb.WinUsb_WritePipe.restype = W.BOOL
winusb.WinUsb_ReadPipe.argtypes = [C.c_void_p, W.BYTE, C.c_void_p, W.DWORD,
                                   C.POINTER(W.DWORD), C.c_void_p]
winusb.WinUsb_ReadPipe.restype = W.BOOL

# ---------------------------------------------------------------- whitelist

# str2value (LK 0x13dc48) is a BARE-HEX parser: its char table (0x165db8) ends at
# 'f', so 'x' terminates the scan and "0x200" parses as 0. Use a SINGLE colon; a
# doubled one makes the length string start with ':' (case 250 = return) -> 0.
# Both forms stay allowed so the pair still discriminates on a live device.
# upload_emmc: and upload_storage: share one handler (0x0860bc, table 0x26fef8/0x26ff10).
UPLOAD_RE = re.compile(r"^upload_(memory|storage|emmc):[0-9a-fA-F]{1,8}::?[0-9a-fA-F]{1,8}\Z")
MAX_UPLOAD_LEN = 0x400000
# getvar storage:/emmc: -> 0x898a0/0x89894 -> 0x89690, which is strlen, get_ops,
# memcpy_s of the name into the RAM global 0x294378, partition_ops[0x20] (start)
# and [0x28] (length) -- both pure getters -- then a hex OKAY string. No storage
# write or erase on any path. It is the ONLY way to populate 0x294378, which
# upload_storage needs: storage_read (0xd2488) re-looks-up that name itself.
GETVAR_PTN_RE = re.compile(r"^getvar (storage|emmc):[a-z0-9_]{1,32}\Z")
# get_bootFail_info / get_bootFail_ver are deliberately NOT here. The DUMPSTART
# site (0x09b31c) shares a function with a storage_write path (0x09b0ac) and no
# function boundary separates them, so read-only cannot be proven. Read the
# bootfail_info partition with upload_storage: instead -- same data, proven read.
OEM_READ_ONLY = {
    "oem get_noboot_reason",
    "oem read_bsn", "oem read_die_id", "oem get-psid", "oem get-build-number",
    "oem get-product-model", "oem get-lockstate", "oem device info",
    "oem get_socid", "oem get_key_version", "oem get_hwnff_ver",
    "oem get_current_slot", "oem oeminforead", "oem get_crypt_info",
    "oem get_ab_slot_status", "oem get_kimage_size",
    "oem zzz_no_such_cmd_control",
}
GETVAR_READ_ONLY = {
    "getvar product", "getvar version", "getvar max-download-size",
    "getvar error_print", "getvar secure", "getvar unlocked",
}


def ALLOW(cmd):
    """True only for commands proven read-only against the LK disassembly."""
    if cmd in OEM_READ_ONLY or cmd in GETVAR_READ_ONLY:
        return True
    if cmd.startswith("getvar partition-type:") and len(cmd) < 64:
        return True
    if GETVAR_PTN_RE.match(cmd):
        return True
    if not UPLOAD_RE.match(cmd):
        return False
    return int(cmd.rsplit(":", 1)[1], 16) <= MAX_UPLOAD_LEN


# ---------------------------------------------------------------- transport

def phone_path():
    g = GUID(*USB_IFACE_GUID)
    h = setupapi.SetupDiGetClassDevsW(C.byref(g), None, None,
                                      DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)
    if h == INVALID_HANDLE_VALUE:
        raise OSError("SetupDiGetClassDevs failed err=%d" % C.get_last_error())
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
            if setupapi.SetupDiGetDeviceInterfaceDetailW(h, C.byref(d), buf,
                                                         need.value, C.byref(need), None):
                p = C.wstring_at(C.addressof(buf) + 4)
                if PHONE_VIDPID in p.lower():
                    return p
            i += 1
    finally:
        setupapi.SetupDiDestroyDeviceInfoList(h)
    return None


def plausible(ptype, pid, mps):
    return ptype == USBD_PIPE_TYPE_BULK and pid != 0 and mps in (8, 16, 32, 64, 512, 1024)


class FastbootRaw:
    def __init__(self, path, timeout_ms=3000):
        self.h = kernel32.CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                                      FILE_SHARE_READ | FILE_SHARE_WRITE, None,
                                      OPEN_EXISTING, FILE_FLAG_OVERLAPPED, None)
        if self.h == INVALID_HANDLE_VALUE:
            raise OSError("CreateFile failed err=%d (is fastboot.exe holding it?)"
                          % C.get_last_error())
        self.wu = C.c_void_p()
        if not winusb.WinUsb_Initialize(self.h, C.byref(self.wu)):
            kernel32.CloseHandle(self.h)
            raise OSError("WinUsb_Initialize failed err=%d" % C.get_last_error())
        self.ep_in = self.ep_out = None
        self.mps = 512
        self.timeout_ms = timeout_ms
        self._pipes()

    def _pipes(self):
        desc = USB_INTERFACE_DESCRIPTOR()
        if not winusb.WinUsb_QueryInterfaceSettings(self.wu, 0, C.byref(desc)):
            raise OSError("QueryInterfaceSettings failed err=%d" % C.get_last_error())
        print("  iface class=%02x sub=%02x prot=%02x endpoints=%d"
              % (desc.bInterfaceClass, desc.bInterfaceSubClass,
                 desc.bInterfaceProtocol, desc.bNumEndpoints))
        for i in range(desc.bNumEndpoints):
            got = None
            for struct in (WINUSB_PIPE_INFORMATION, WINUSB_PIPE_INFORMATION_UNPACKED):
                buf = C.create_string_buffer(max(64, C.sizeof(struct)))
                if not winusb.WinUsb_QueryPipe(self.wu, 0, i, buf):
                    continue
                p = struct.from_buffer_copy(buf.raw[:C.sizeof(struct)])
                if plausible(p.PipeType, p.PipeId, p.MaximumPacketSize):
                    got = p
                    break
            if got is None:
                raise OSError("endpoint %d: no plausible bulk pipe info" % i)
            print("  ep[%d] id=0x%02x type=%d maxpkt=%d"
                  % (i, got.PipeId, got.PipeType, got.MaximumPacketSize))
            if got.PipeId & 0x80:
                self.ep_in, self.mps = got.PipeId, got.MaximumPacketSize
            else:
                self.ep_out = got.PipeId
        if self.ep_in is None or self.ep_out is None:
            raise OSError("need one bulk IN and one bulk OUT")
        tv = W.DWORD(self.timeout_ms)
        winusb.WinUsb_SetPipePolicy(self.wu, self.ep_in, PIPE_TRANSFER_TIMEOUT,
                                    4, C.byref(tv))
        for pol in (ALLOW_PARTIAL_READS, AUTO_CLEAR_STALL):
            bv = W.BYTE(1)
            if not winusb.WinUsb_SetPipePolicy(self.wu, self.ep_in, pol, 1, C.byref(bv)):
                print("  [w] SetPipePolicy(%d) failed err=%d" % (pol, C.get_last_error()))

    def close(self):
        if getattr(self, "wu", None):
            winusb.WinUsb_Free(self.wu)
            self.wu = None
        if getattr(self, "h", None) and self.h != INVALID_HANDLE_VALUE:
            kernel32.CloseHandle(self.h)
            self.h = None

    def _read(self, nbytes=None):
        # One max-packet-sized read at a time: a payload that is an exact multiple
        # of MaxPacketSize is not a short packet, so a large buffer would never
        # complete and the transfer would look like a timeout.
        nbytes = nbytes or self.mps
        buf = C.create_string_buffer(nbytes)
        got = W.DWORD(0)
        ok = winusb.WinUsb_ReadPipe(self.wu, self.ep_in, buf, nbytes,
                                    C.byref(got), None)
        if not ok:
            err = C.get_last_error()
            if err == 121:                      # ERROR_SEM_TIMEOUT
                return None
            raise OSError("ReadPipe failed err=%d" % err)
        return buf.raw[:got.value]

    def drain(self):
        """Discard stale responses left in the IN pipe by an earlier command."""
        dropped = 0
        while True:
            try:
                chunk = self._read()
            except OSError as e:
                print("    (drain stopped: %s)" % e)
                break
            if not chunk:
                break
            dropped += len(chunk)
        if dropped:
            print("    (drained %d stale bytes)" % dropped)
        return dropped

    def run(self, cmd, outdir, max_seconds=20.0, max_bytes=64 * 1024 * 1024):
        if not ALLOW(cmd):
            raise ValueError("WHITELIST REFUSED, nothing sent: %r" % cmd)
        self.drain()
        tag = re.sub(r"[^A-Za-z0-9_.-]", "_", cmd)
        wire = "getvar:" + cmd[7:] if cmd.startswith("getvar ") else cmd
        payload = wire.encode("ascii")
        sent = W.DWORD(0)
        print("--- %s" % cmd)
        if not winusb.WinUsb_WritePipe(self.wu, self.ep_out, payload, len(payload),
                                       C.byref(sent), None):
            raise OSError("WritePipe failed err=%d" % C.get_last_error())
        if sent.value != len(payload):
            raise OSError("short write %d/%d" % (sent.value, len(payload)))
        is_upload = cmd.startswith("upload_")
        blob = bytearray()
        packets = []
        t0 = time.time()
        verdict = "TIMEOUT"
        zlps = 0
        while time.time() - t0 < max_seconds and len(blob) < max_bytes:
            chunk = self._read()
            if chunk is None:
                if not blob:
                    verdict = "READ-TIMEOUT"
                break
            if not chunk:
                zlps += 1
                if is_upload and zlps <= 3:
                    continue
                verdict = "EMPTY"
                break
            packets.append(chunk)
            blob += chunk
            head = bytes(chunk[:4])
            if head == b"DATA":
                verdict = "DATA-ABORT"          # device wants a payload: we refuse
                break
            if chunk.startswith(b"DUMPEND"):
                verdict = "DUMPEND"
                break
            if verdict == "TIMEOUT":
                verdict = head.decode("ascii", errors="backslashreplace") \
                    if head in (b"OKAY", b"FAIL", b"INFO") else "RAW"
            # keep reading to the idle timeout: INFO/DUMP payload can follow OKAY
        raw_path = os.path.join(outdir, tag + ".bin")
        with open(raw_path, "wb") as f:
            f.write(bytes(blob))
        txt_path = os.path.join(outdir, tag + ".txt")
        with open(txt_path, "w", encoding="ascii", errors="backslashreplace") as f:
            f.write("cmd: %s\nwire: %s\nverdict: %s\npackets: %d\nbytes: %d\nelapsed: %.3fs\n"
                    % (cmd, wire, verdict, len(packets), len(blob), time.time() - t0))
            for i, p in enumerate(packets):
                f.write("\n[packet %d] %d bytes\n" % (i, len(p)))
                f.write(p.decode("ascii", errors="backslashreplace") + "\n")
        printable = sum(1 for b in blob if 32 <= b < 127 or b in (9, 10, 13))
        print("    verdict=%s packets=%d bytes=%d printable=%.1f%% elapsed=%.2fs"
              % (verdict, len(packets), len(blob),
                 100.0 * printable / max(1, len(blob)), time.time() - t0))
        preview = bytes(blob[:160])
        print("    head: %s" % preview.decode("ascii", errors="backslashreplace"))
        print("    saved: %s" % raw_path)
        return verdict, bytes(blob)


def selftest():
    ok = ["upload_memory:10000000:1000", "upload_memory:10000000:200",
          "upload_storage:0:200", "upload_storage:200000:400000",
          "upload_emmc:80000:40000",
          "getvar storage:vrl", "getvar storage:ptable", "getvar emmc:fastboot",
          "oem get_noboot_reason", "oem get-build-number", "getvar product",
          "getvar partition-type:xloader", "oem zzz_no_such_cmd_control"]
    bad = ["oem read", "oem write", "flash:xloader:a.img", "flash xloader a.img",
           "erase:misc", "download:00010000", "reboot", "reboot-bootloader", "boot",
           "continue", "ultraflash:system", "oem erase_storage_all", "oem wrefuse",
           "oem emmc-dump", "oem sec_unlock", "oem oeminfowrite", "oem efuse_ 1",
           "oem ddrtest", "oem ramdump", "oem set_current_slot B",
           "upload_memory:10000000:1000; flash:xloader:a.img", "getvar all",
           "oem reboot_boot_dump", "oem onchiprom_download",
           "oem get_bootFail_info", "oem get_bootFail_ver",
           "upload_memory:10000000:8000000", "upload_storage:0:ffffffff",
           "upload_memory:0x10000000:0x200", "upload_storage:0:200 ",
           "upload_memory:10000000:::200", "upload_memory:10000000:200\nreboot",
           "getvar storageid", "getvar set_config_lock", "getvar resize",
           "getvar storage:vrl; reboot", "getvar storage:", "getvar nve:x",
           "getvar call:x", "getvar cmd", "dump:-addr 0 200"]
    fails = 0
    for c in ok:
        if not ALLOW(c):
            print("  SELFTEST FAIL (should allow): %r" % c); fails += 1
    for c in bad:
        if ALLOW(c):
            print("  SELFTEST FAIL (should refuse): %r" % c); fails += 1
    print("selftest: %d allow-cases + %d refuse-cases, failures=%d"
          % (len(ok), len(bad), fails))
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--list", action="store_true", help="host-side only: show device path")
    ap.add_argument("--cmd", action="append", default=[], help="repeatable")
    ap.add_argument("--outdir", default=None)
    ap.add_argument("--seconds", type=float, default=20.0)
    a = ap.parse_args()

    if a.selftest:
        return 1 if selftest() else 0

    path = phone_path()
    if not path:
        print("[x] no phone fastboot interface on the bus right now.")
        return 5
    print("device path: %s" % path)
    if a.list:
        return 0
    if not a.cmd:
        print("[x] nothing to do (pass --cmd). No device handle was opened.")
        return 0

    for c in a.cmd:
        if not ALLOW(c):
            print("[x] WHITELIST REFUSED before opening the device: %r" % c)
            return 9

    outdir = a.outdir or os.path.join("out_check", "raw_%s" % time.strftime("%H%M%S"))
    os.makedirs(outdir, exist_ok=True)
    fb = FastbootRaw(path)
    rc = 0
    try:
        for c in a.cmd:
            try:
                verdict, blob = fb.run(c, outdir, max_seconds=a.seconds)
                # The device sometimes executes a command but its response never
                # reaches the IN pipe. Re-ask once; every allowed command is
                # read-only, so a repeat cannot change device state.
                if not blob:
                    print("    (no response, re-asking once)")
                    fb.run(c, outdir, max_seconds=a.seconds)
            except Exception as e:
                print("    ERROR: %s" % e)
                rc = 1
    finally:
        fb.close()
    print("outdir=%s  (zero-write: only command strings were sent)" % outdir)
    return rc


if __name__ == "__main__":
    sys.exit(main())