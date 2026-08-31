#!/usr/bin/env python3
"""Восстановить настоящие имена файлов внутри MSI.

Файлы в cab-архивах установщика Windows лежат под искажёнными именами вида
fil<32 шестнадцатеричных знака>. Соответствие искажённого имени настоящему
хранится в таблице !File самого MSI, строки — в !_StringData/!_StringPool.

    7z x -y -oтаблицы драйвер.msi '!File' '!_StringData' '!_StringPool'
    cd таблицы && for f in '!'*; do mv "$f" "${f#!}"; done
    ./msi-filenames.py таблицы | grep -i aiqb

Формат пула строк: 4 байта заголовка (кодовая страница), дальше по 4 байта
на строку — длина, потом счётчик ссылок. Именно в таком порядке; если
перепутать, разбор поедет и выдаст мусор. Длина 0 при ненулевом счётчике
означает длинную строку: старшее слово длины лежит в счётчике, младшее —
в следующей записи.

Таблица !File хранится по столбцам, а не по строкам: сначала все ссылки на
имя файла, потом все ссылки на компонент, потом все имена, потом размеры.
"""
import struct, sys

def load(base):
    data = open(base + '/_StringData', 'rb').read()
    pool = open(base + '/_StringPool', 'rb').read()
    strings, off, i = [''], 0, 4
    while i + 4 <= len(pool):
        ln, rc = struct.unpack_from('<HH', pool, i); i += 4
        if ln == 0 and rc != 0:
            ln2, _ = struct.unpack_from('<HH', pool, i); i += 4
            ln = (rc << 16) | ln2
        strings.append(data[off:off + ln].decode('cp1252', 'replace')); off += ln
    return strings

def main(base):
    s = load(base)
    f = open(base + '/File', 'rb').read()
    n = len(f) // 20                      # 2+2+2+4+2+2+2+4 байта на запись
    col = lambda o, w: [struct.unpack_from('<H' if w == 2 else '<I', f, o + k * w)[0]
                        for k in range(n)]
    o = 0
    key = col(o, 2); o += 2 * n
    o += 2 * n                             # компонент не нужен
    name = col(o, 2); o += 2 * n
    size = col(o, 4)
    g = lambda x: s[x] if x < len(s) else '?'
    for k in range(n):
        # имя бывает вида «короткое 8.3|настоящее»
        real = g(name[k]).split('|')[-1]
        print(f"{g(key[k])}\t{real}\t{size[k]}")

if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit(__doc__)
    main(sys.argv[1])
