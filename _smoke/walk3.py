import ctypes, time
from ctypes import wintypes
from pathlib import Path
from PIL import Image

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long), ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long),
        ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", ctypes.c_long), ("biYPelsPerMeter", ctypes.c_long),
        ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD),
    ]

def find_hwnd():
    targets = []
    @ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def enum_proc(hwnd, lParam):
        if user32.IsWindowVisible(hwnd):
            length = user32.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            if buf.value == "wired_parts":
                targets.append(hwnd)
        return True
    user32.EnumWindows(enum_proc, 0)
    return targets[0] if targets else None

def shot(rect, path):
    w, h = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetDC(0)
    mfc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mfc, bmp)
    gdi32.BitBlt(mfc, 0, 0, w, h, hdc, rect.left, rect.top, 0x00CC0020)
    bi = BITMAPINFOHEADER(); bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.biWidth = w; bi.biHeight = -h; bi.biPlanes = 1; bi.biBitCount = 32
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mfc, bmp, 0, h, buf, ctypes.byref(bi), 0)
    Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1).save(path)
    gdi32.DeleteObject(bmp); gdi32.DeleteDC(mfc); user32.ReleaseDC(0, hdc)
    print("saved", path, Path(path).stat().st_size)

def click(x, y):
    user32.SetCursorPos(int(x), int(y)); time.sleep(0.05)
    user32.mouse_event(0x0002,0,0,0,0); time.sleep(0.04); user32.mouse_event(0x0004,0,0,0,0)

hwnd = find_hwnd(); user32.ShowWindow(hwnd,9); user32.SetForegroundWindow(hwnd); time.sleep(0.4)
rect = RECT(); user32.GetWindowRect(hwnd, ctypes.byref(rect))
L,T,W,H = rect.left, rect.top, rect.right-rect.left, rect.bottom-rect.top
out = Path(r"C:\Users\weird\.GitHub\Weird-Parts-3rd-run\_smoke")

# Catalog tab
click(L+W*0.5, T+H-28); time.sleep(1.0)
# Expand Wire row ~ first list item around y 160-180; click left of row (not menu)
click(L+80, T+175); time.sleep(1.0)
user32.GetWindowRect(hwnd, ctypes.byref(rect)); shot(rect, out/"20-wire-expand.png")
# click deeper / second row
click(L+100, T+230); time.sleep(1.0)
user32.GetWindowRect(hwnd, ctypes.byref(rect)); shot(rect, out/"21-deeper.png")
# Jobs + FAB
click(L+W*0.17, T+H-28); time.sleep(0.8)
click(L+W-48, T+H-90); time.sleep(1.2)
user32.GetWindowRect(hwnd, ctypes.byref(rect)); shot(rect, out/"22-job-fab.png")
# type job name via keyboard if dialog
for ch in "Smoke Job":
    # send unicode
    pass
# SendInput simple VK
def tap(vk):
    user32.keybd_event(vk, 0, 0, 0); user32.keybd_event(vk, 0, 2, 0)
# try Enter after assuming focused field - send keys with VkKeyScanW
def type_text(s):
    for ch in s:
        vk = user32.VkKeyScanW(ord(ch))
        lo = vk & 0xff
        shift = (vk >> 8) & 1
        if shift: user32.keybd_event(0x10,0,0,0)
        user32.keybd_event(lo,0,0,0); user32.keybd_event(lo,0,2,0)
        if shift: user32.keybd_event(0x10,0,2,0)
        time.sleep(0.03)
type_text("Smoke Job")
time.sleep(0.3)
tap(0x0D)  # enter
time.sleep(1.0)
user32.GetWindowRect(hwnd, ctypes.byref(rect)); shot(rect, out/"23-after-job-name.png")
print("done")
