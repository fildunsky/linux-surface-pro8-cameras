#!/bin/bash
# Снять кадры с ИК-камеры и разложить в PNG.
#
#   sudo ./ir-grab.sh [сколько] [куда]
#
# Тонкость с преобразованием: данные десятибитные, уложенные по два байта
# little-endian, и в строке 1344 байта против 644*2 = 1288 полезных — то
# есть 672 пикселя с добивкой. Поэтому читаем как 672 в ширину и обрезаем.
# Формат ffmpeg должен быть gray10le, а не gray16le: gray16le считает данные
# шестнадцатибитными и даёт почти чёрный кадр (среднее 0.4 из 255).
set -u
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }
N=${1:-10}
OUT=${2:-/tmp/ir}
W=644; H=604; STRIDE_PX=672
DIR=$(cd "$(dirname "$0")" && pwd)

"$DIR/ir-setup.sh" >/dev/null || exit 1
mkdir -p "$OUT"
RAW=$(mktemp /tmp/ir-XXXXXX.raw)
trap 'rm -f "$RAW"' EXIT

timeout 30 v4l2-ctl -d /dev/video42 --stream-mmap --stream-count="$N" \
  --stream-to="$RAW" >/dev/null 2>&1
SZ=$(stat -c%s "$RAW" 2>/dev/null || echo 0)
[ "$SZ" -gt 0 ] || { echo "кадров нет" >&2; exit 1; }
echo "снято $((SZ / (STRIDE_PX*2*H))) кадров, $SZ байт"

ffmpeg -hide_banner -loglevel error -f rawvideo -pix_fmt gray10le \
  -s ${STRIDE_PX}x${H} -i "$RAW" -vf "crop=${W}:${H}:0:0,format=gray" \
  -y "$OUT/ir_%03d.png" || exit 1
ls "$OUT"/ir_*.png | wc -l | xargs echo "PNG в $OUT:"
