#!/usr/bin/env python3
"""Читает поток YUYV с stdin и печатает посекундную статистику.

Кадры нигде не сохраняются — считается только яркость, содержимое сразу
отбрасывается. Использование:
    v4l2-ctl -d /dev/video200 --stream-mmap --stream-count=N --stream-to=- \
      | tools/stream-stats.py [ширина] [высота] [секунд]
"""
import sys, time

W = int(sys.argv[1]) if len(sys.argv) > 1 else 1280
H = int(sys.argv[2]) if len(sys.argv) > 2 else 720
LIMIT = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0
FS = W * H * 2

t0 = time.monotonic()
bucket = int(t0)
n = tot = live = 0
sec_n = sec_live = 0
sec_lum = []
first_live = None

while time.monotonic() - t0 < LIMIT:
    buf = sys.stdin.buffer.read(FS)
    if len(buf) < FS:
        break
    y = buf[0::128]
    lo, hi = min(y), max(y)
    is_live = hi > lo
    n += 1; sec_n += 1; tot += 1
    if is_live:
        live += 1; sec_live += 1
        sec_lum.append(sum(y) / len(y))
        if first_live is None:
            first_live = time.monotonic() - t0
    now = int(time.monotonic())
    if now != bucket:
        lum = f"яркость {sum(sec_lum)/len(sec_lum):5.1f}" if sec_lum else "заставка"
        print(f"  +{now-int(t0):2d} с: {sec_n:4d} кадр/с, живых {sec_live:4d}, {lum}", flush=True)
        bucket = now; sec_n = sec_live = 0; sec_lum = []

el = time.monotonic() - t0
print()
print(f"ИТОГО: {tot} кадров за {el:.1f} с = {tot/el:.1f} fps, живых {live}")
print("первый живой кадр: " + (f"{first_live:.2f} с" if first_live is not None else "не появился"))
