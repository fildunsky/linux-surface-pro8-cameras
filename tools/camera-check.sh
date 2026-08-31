#!/bin/bash
# Проверка фронтальной камеры Surface Pro 8 по разрешениям.
#
# Главное: «камера видна в системе» ничего не значит. Сломанный режим сенсора
# отдаёт кадры исправно, но залитые чёрным. Судить только по яркости кадра
# (YMIN=YAVG=YMAX=16 — заливка) и по счётчику Frame sync error в ядре.
#
# Использование:  ./camera-check.sh [back]
set -u
CAM='\\_SB_.PC00.I2C2.CAMF'; WHO=фронтальная; SENSOR=ov5693
[ "${1:-}" = back ] && { CAM='\\_SB_.PC00.I2C3.CAMR'; WHO=задняя; SENSOR=ov13858; }

command -v gst-launch-1.0 >/dev/null || { echo "нет gst-launch-1.0"; exit 1; }
command -v ffmpeg >/dev/null || { echo "нет ffmpeg"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
MARK=$(date '+%H:%M:%S')

echo "камера: $WHO"
echo "драйвер: $(modinfo -n ov5693 2>/dev/null)"
echo "режимы сенсора, которые видит libcamera:"
(LIBCAMERA_LOG_LEVELS='SimplePipeline:DEBUG' timeout -s INT 7 \
  gst-launch-1.0 libcamerasrc camera-name="$CAM" \
  ! video/x-raw,width=640,height=480 ! fakesink 2>&1 || true) \
  | grep -E "Link '$SENSOR" | grep -oE '[0-9]+x[0-9]+-[A-Z0-9_]+' | sort -u | sed 's/^/  /'
echo

printf '%-12s %-10s %-10s %s\n' РАЗМЕР YAVG YMAX ВЕРДИКТ
for size in 640x480 1280x720 1920x1080 2560x1920; do
  WD=${size%x*}; HT=${size#*x}; rm -f "$W"/f_*.jpg
  timeout -s INT 10 gst-launch-1.0 libcamerasrc camera-name="$CAM" \
    ! video/x-raw,width=$WD,height=$HT ! videoconvert ! jpegenc \
    ! multifilesink location="$W/f_%03d.jpg" max-files=2 >/dev/null 2>&1 || true
  last=$(ls -t "$W"/f_*.jpg 2>/dev/null | head -1)
  if [ -z "$last" ]; then printf '%-12s %-10s %-10s %s\n' "$size" - - "не согласован"; continue; fi
  stat() { ffmpeg -hide_banner -i "$last" -vf "signalstats,metadata=print:key=lavfi.signalstats.$1:file=-" \
           -f null - 2>/dev/null | grep -oE '=[0-9.]+' | tr -d '='; }
  y=$(stat YAVG); m=$(stat YMAX)
  v=картинка; [ "${m%%.*}" -le 16 ] 2>/dev/null && v="ЧЁРНЫЙ КАДР"
  printf '%-12s %-10s %-10s %s\n' "$size" "$y" "$m" "$v"
done

echo
n=$(journalctl -k --since "$MARK" --no-pager 2>/dev/null | grep -ic 'Frame sync error')
echo "Frame sync error за прогон: $n   (норма 0; много — сенсор не даёт кадровой синхронизации)"
echo
echo "таймауты на закрытии потока (норма — бывают и на исправной камере,"
echo "потому что скрипт обрывает поток по SIGINT; сами по себе не диагноз):"
journalctl -k --since "$MARK" --no-pager 2>/dev/null | grep -iE 'time out' | tail -2 | sed 's/^/  /'
