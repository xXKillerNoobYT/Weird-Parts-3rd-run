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

def shot_screen(rect, path):
    w, h = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetDC(0)
    mfc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mfc, bmp)
    gdi32.BitBlt(mfc, 0, 0, w, h, hdc, rect.left, rect.top, 0x00CC0020)
    bi = BITMAPINFOHEADER()
    bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.biWidth = w
    bi.biHeight = -h
    bi.biPlanes = 1
    bi.biBitCount = 32
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mfc, bmp, 0, h, buf, ctypes.byref(bi), 0)
    Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1).save(path)
    gdi32.DeleteObject(bmp); gdi32.DeleteDC(mfc); user32.ReleaseDC(0, hdc)
    print("saved", path, Path(path).stat().st_size)

def click(x, y):
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.08)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.05)
    user32.mouse_event(0x0004, 0, 0, 0, 0)

hwnd = find_hwnd()
print("hwnd", hwnd)
user32.ShowWindow(hwnd, 9)
user32.SetForegroundWindow(hwnd)
time.sleep(0.5)
rect = RECT(); user32.GetWindowRect(hwnd, ctypes.byref(rect))
print(rect.left, rect.top, rect.right-rect.left, rect.bottom-rect.top)
out = Path(r"C:\Users\weird\.GitHub\Weird-Parts-3rd-run\_smoke")
L, T = rect.left, rect.top
W, H = rect.right - rect.left, rect.bottom - rect.top

# Catalog - center bottom nav (exclude title bar ~32px)
click(L + W*0.5, T + H - 28)
time.sleep(1.5)
user32.GetWindowRect(hwnd, ctypes.byref(rect))
shot_screen(rect, out / "10-catalog.png")

# FAB
click(L + W - 48, T + H - 90)
time.sleep(1.5)
user32.GetWindowRect(hwnd, ctypes.byref(rect))
shot_screen(rect, out / "11-after-fab.png")

# More
click(L + W*0.83, T + H - 28)
time.sleep(1.2)
user32.GetWindowRect(hwnd, ctypes.byref(rect))
shot_screen(rect, out / "12-more.png")

# Maintenance row ~ y 120 from content
click(L + W*0.4, T + 140)
time.sleep(1.2)
user32.GetWindowRect(hwnd, ctypes.byref(rect))
shot_screen(rect, out / "13-maintenance.png")

# back via More then Change PIN - go More first if not
click(L + W*0.83, T + H - 28)
time.sleep(0.8)
click(L + W*0.4, T + 210)
time.sleep(1.2)
user32.GetWindowRect(hwnd, ctypes.byref(rect))
shot_screen(rect, out / "14-change-pin.png")
print("done")
