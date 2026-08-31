#!/usr/bin/env python3
"""Таблица настройки сенсора VD55G0 из виндового драйвера vd55g0.sys.

Секция .rdata, смещение в файле 0x47434, 71 запись по 16 байт вида
{u32 адрес, u32 значение, u32 0, u32 размер}. Все записи побайтовые;
многобайтовые регистры собираются little-endian по карте полей ниже.
Карта взята из reg_map[] апстримного драйвера (vd55g.c, vd55g0_reg_map).

    ./win-regtable.py windows-driver/vd55g0.sys
"""
import struct, sys

OFF = 0x47434

# адрес -> (длина в байтах, имя)
FIELDS = {
    0x0000: (1, "MODEL_ID[0]"),
    0x0220: (4, "EXT_CLOCK, Гц"),
    0x0224: (4, "MIPI_DATA_RATE, бит/с"),
    0x0300: (2, "LINE_LENGTH"),
    0x0416: (1, "0x0416 (не разобран)"),
}
# контексты: база 0x044c, шаг 0x30
CTX = [
    (0x0000, 1, "EXP_MODE"),
    (0x0001, 1, "MANUAL_ANALOG_GAIN"),
    (0x0002, 2, "MANUAL_COARSE_EXPOSURE"),
    (0x0004, 2, "MANUAL_DIGITAL_GAIN"),
    (0x000c, 4, "FRAME_LENGTH"),
    (0x0010, 2, "0x045c (не разобран)"),
    (0x0012, 2, "X_START"),
    (0x0014, 2, "X_WIDTH_OR_END"),
    (0x0016, 2, "Y_START"),
    (0x0018, 2, "Y_HEIGHT_OR_END"),
    (0x001b, 1, "GPIO_0_CTRL"),
    (0x001c, 1, "GPIO_1_CTRL"),
    (0x001d, 1, "GPIO_2_CTRL"),
    (0x001e, 1, "GPIO_3_CTRL"),
    (0x0024, 4, "0x0470 (не разобран)"),
]
for ctx in (0, 1):
    base = 0x044c + 0x30 * ctx
    for off, n, name in CTX:
        FIELDS[base + off] = (n, f"ctx{ctx} {name}")
FIELDS[0x0476] = (2, "REPEAT_COUNT_CTX0")
FIELDS[0x0478] = (2, "NEXT_CTX")
FIELDS[0x04a6] = (2, "REPEAT_COUNT_CTX1")
FIELDS[0x04a8] = (1, "0x04a8 (не разобран)")


def main(path):
    d = open(path, "rb").read()
    raw = {}
    for i in range(256):
        a, v, z, sz = struct.unpack_from("<IIII", d, OFF + i * 16)
        if a > 0xffff or z != 0 or sz not in (1, 2, 4):
            break
        raw[a] = v & 0xff
    print(f"{len(raw)} байтовых записей по смещению {OFF:#x}\n")
    seen = set()
    for a in sorted(raw):
        if a in seen:
            continue
        n, name = FIELDS.get(a, (1, "?"))
        val = 0
        for k in range(n - 1, -1, -1):
            val = (val << 8) | raw.get(a + k, 0)
            seen.add(a + k)
        print(f"  0x{a:04x}  {name:28s} = {val:>11}  (0x{val:0{2*n}x})")
    missing = sorted(set(raw) - seen)
    if missing:
        print("\nне попали в карту полей:",
              " ".join(f"0x{a:04x}" for a in missing))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "windows-driver/vd55g0.sys")
