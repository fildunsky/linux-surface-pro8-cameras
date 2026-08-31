#!/bin/bash
# Собрать media-граф ИК-камеры VD55G0 и выставить формат.
#
# ГЛАВНОЕ, что стоило недели: формат на ноде захвата обязан быть
# НЕУПАКОВАННЫМ ('Y10 '), а не упакованным ('Y10P').
#
# ISYS выбирает mipi_store_mode по правилу (ipu6-isys-video.c:496):
#     bpp == bpp_packed ? DISCARD_LONG_HEADER (1) : NORMAL (0)
# У Y10P bpp = bpp_packed = 10, у GREY 8 = 8 — оба дают режим 1, и на этом
# железе он не работает: сенсор снимает, но наружу уходит ровно один
# короткий пакет начала кадра. У 'Y10 ' bpp = 16, bpp_packed = 10, режим 0
# — и всё едет: 50 кадр/с, ноль ошибок csi2.
set -u
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }
W=${W:-644}; H=${H:-604}
M=${M:-/dev/media0}
SENSOR='"vd55g 3-0060"'
CSI='"Intel IPU6 CSI2 5"'
CAP='"Intel IPU6 ISYS Capture 40"'

media-ctl -d "$M" -l "$SENSOR:0 -> $CSI:0[1]" 2>/dev/null
media-ctl -d "$M" -l "$CSI:1 -> $CAP:0[1]" 2>/dev/null || {
  echo "не удалось включить связь $CSI:1 -> $CAP" >&2; exit 1; }
for pad in "$SENSOR:0" "$CSI:0" "$CSI:1"; do
  media-ctl -d "$M" -V "$pad [fmt:Y10_1X10/${W}x${H}]" || {
    echo "не удалось выставить формат на $pad" >&2; exit 1; }
done
v4l2-ctl -d "${VIDEO:-/dev/video42}" \
  --set-fmt-video=width=$W,height=$H,pixelformat='Y10 ' >/dev/null || exit 1
v4l2-ctl -d "${VIDEO:-/dev/video42}" --get-fmt-video | grep -E "Width|Pixel|Bytes"
