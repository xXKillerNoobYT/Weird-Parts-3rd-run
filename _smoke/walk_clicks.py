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
    for p in __import__("subprocess").check_output("tasklist /FI \"IMAGENAME eq wired_parts.exe\" /FO CSV /NH", shell=True).decode().splitlines():
        pass
    # Enum windows
    targets = []
    @ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def enum_proc(hwnd, lParam):
        if user32.IsWindowVisible(hwnd):
            length = user32.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buf, length + 1)
            if "wired_parts" in buf.value.lower():
                targets.append(hwnd)
        return True
    user32.EnumWindows(enum_proc, 0)
    return targets[0] if targets else None

def shot(hwnd, path):
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)
    rect = RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetWindowDC(hwnd)
    mfc = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
    gdi32.SelectObject(mfc, bmp)
    user32.PrintWindow(hwnd, mfc, 2)
    bi = BITMAPINFOHEADER()
    bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bi.biWidth = w
    bi.biHeight = -h
    bi.biPlanes = 1
    bi.biBitCount = 32
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mfc, bmp, 0, h, buf, ctypes.byref(bi), 0)
    Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1).save(path)
    gdi32.DeleteObject(bmp); gdi32.DeleteDC(mfc); user32.ReleaseDC(hwnd, hdc)
    print("saved", path, Path(path).stat().st_size)
    return rect

def click_abs(x, y):
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)
    user32.mouse_event(0x0004, 0, 0, 0, 0)

def click_rel(rect, rx, ry):
    click_abs(rect.left + rx, rect.top + ry)

hwnd = find_hwnd()
print("hwnd", hwnd)
assert hwnd
user32.ShowWindow(hwnd, 9)
out = Path(r"C:\Users\weird\.GitHub\Weird-Parts-3rd-run\_smoke")
rect = shot(hwnd, out / "03-jobs.png")
# bottom nav approx: Jobs ~25%, Catalog ~50%, More ~75% of width; near bottom
w = rect.right - rect.left
h = rect.bottom - rect.top
# Catalog tab center
click_rel(rect, w * 0.50, h - 40)
time.sleep(1.2)
rect = shot(hwnd, out / "04-catalog.png")
# FAB bottom-right
click_rel(rect, w - 56, h - 100)
time.sleep(1.2)
rect = shot(hwnd, out / "05-catalog-after-fab.png")
# More tab
click_rel(rect, w * 0.78, h - 40)
time.sleep(1.0)
rect = shot(hwnd, out / "06-more.png")
# back to Jobs
click_rel(rect, w * 0.22, h - 40)
time.sleep(0.8)
rect = shot(hwnd, out / "07-jobs-again.png")
# Jobs FAB
click_rel(rect, w - 56, h - 100)
time.sleep(1.2)
rect = shot(hwnd, out / "08-job-create.png")
print("done clicks")
