#!/usr/bin/env python3
"""Сколько строк в кадре ИК-камеры реально заполнено.

Незаписанная память буфера читается как 0xff, поэтому «живая» строка — та,
у которой среднее по байтам заметно меньше 255. Полный кадр — 604 живых
строки; пока сенсор настроен неверно, их 15.
"""
import sys
import numpy as np

f, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = np.fromfile(f, dtype=np.uint8)
if d.size == 0:
    print("    файл пуст")
    sys.exit()

bpl = (W * 10 // 8 + 63) // 64 * 64      # Y10P, выравнивание строки до 64 байт
fsz = bpl * H
n = d.size // fsz
live = []
for k in range(n):
    fr = d[k * fsz:(k + 1) * fsz].reshape(H, bpl)
    live.append(int((fr.mean(axis=1) < 250).sum()))
print(f"    кадров {n}, строка {bpl} байт, живых строк: {live}")
