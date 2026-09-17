import ctypes, time
from ctypes import wintypes
from pathlib import Path

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

hwnd = 9307942
user32.ShowWindow(hwnd, 9)
user32.SetForegroundWindow(hwnd)
time.sleep(0.8)

class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long), ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

rect = RECT()
user32.GetWindowRect(hwnd, ctypes.byref(rect))
w, h = rect.right - rect.left, rect.bottom - rect.top
print(f"rect {rect.left},{rect.top} {w}x{h}")

hwndDC = user32.GetWindowDC(hwnd)
mfcDC = gdi32.CreateCompatibleDC(hwndDC)
saveBitMap = gdi32.CreateCompatibleBitmap(hwndDC, w, h)
gdi32.SelectObject(mfcDC, saveBitMap)
ok = user32.PrintWindow(hwnd, mfcDC, 2)
print("PrintWindow", ok)

out = Path(r"C:\Users\weird\.GitHub\Weird-Parts-3rd-run\_smoke\02-app-window.png")
out.parent.mkdir(exist_ok=True)

class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD),
        ("biWidth", ctypes.c_long),
        ("biHeight", ctypes.c_long),
        ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD),
        ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD),
        ("biXPelsPerMeter", ctypes.c_long),
        ("biYPelsPerMeter", ctypes.c_long),
        ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]

bi = BITMAPINFOHEADER()
bi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
bi.biWidth = w
bi.biHeight = -h
bi.biPlanes = 1
bi.biBitCount = 32
buf = ctypes.create_string_buffer(w * h * 4)
bits = gdi32.GetDIBits(mfcDC, saveBitMap, 0, h, buf, ctypes.byref(bi), 0)
print("GetDIBits", bits)

from PIL import Image
img = Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", 0, 1)
img.save(out)
print("saved", out, out.stat().st_size)

gdi32.DeleteObject(saveBitMap)
gdi32.DeleteDC(mfcDC)
user32.ReleaseDC(hwnd, hwndDC)
