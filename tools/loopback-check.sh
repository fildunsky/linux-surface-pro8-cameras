#!/bin/bash
# Проверка V4L2-пути: v4l2-relayd -> v4l2loopback -> приложение.
# Это то, что видят Chrome и Zoom.
#
# ВАЖНО про способ проверки. Не бери кадр через
#     ffmpeg -f v4l2 -input_format yuyv422 -video_size ... -i /dev/videoN
# он заставляет loopback переторговать формат и отдаёт чёрный буфер, даже когда
# всё исправно. Я потратил на эти грабли час. Проверять только через GStreamer.
set -u
DEV="${1:-/dev/video64}"

command -v gst-launch-1.0 >/dev/null || { echo "нет gst-launch-1.0"; exit 1; }
[ -e "$DEV" ] || { echo "нет $DEV — не загружен v4l2loopback?"; exit 1; }

echo "устройство: $DEV  ($(v4l2-ctl -d "$DEV" --all 2>/dev/null | grep -m1 'Card type' | sed 's/.*: //'))"
echo "сервис: $(systemctl is-active 'v4l2-relayd@surface-front.service' 2>/dev/null)"

busy=$(fuser "$DEV" 2>/dev/null | wc -w)
if [ "$busy" -gt 0 ]; then
  echo "ВНИМАНИЕ: устройство уже кем-то занято ($(fuser -v "$DEV" 2>&1 | awk 'NR>1{print $NF}' | tr '\n' ' ')) — закрой браузер и повтори"
fi

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PID=$(pgrep -x v4l2-relayd | head -1)
HZ=$(getconf CLK_TCK)

timeout -k 2 16 gst-launch-1.0 v4l2src device="$DEV" ! videoconvert ! jpegenc \
  ! multifilesink location="$W/f_%03d.jpg" max-files=2 >/dev/null 2>&1 &
GP=$!
# Первые секунды уходят на раскрутку libcamera, их в замер не берём —
# иначе цифра завышается втрое.
sleep 7
read u1 s1 <<< "$(awk '{print $14,$15}' /proc/${PID:-self}/stat 2>/dev/null || echo '0 0')"
sleep 5
read u2 s2 <<< "$(awk '{print $14,$15}' /proc/${PID:-self}/stat 2>/dev/null || echo '0 0')"
wait $GP 2>/dev/null || true
last=$(ls -t "$W"/f_*.jpg 2>/dev/null | head -1)

if [ -z "$last" ]; then echo "РЕЗУЛЬТАТ: кадров нет — пайплайн не играет"; exit 1; fi
stat() { ffmpeg -hide_banner -i "$last" -vf "signalstats,metadata=print:key=lavfi.signalstats.$1:file=-" \
         -f null - 2>/dev/null | grep -oE '=[0-9.]+' | tr -d '='; }
y=$(stat YAVG); m=$(stat YMAX)
echo "кадр: $(ffprobe -hide_banner -loglevel error -show_entries stream=width,height -of csv=p=0 "$last")  YAVG=$y  YMAX=$m"
if [ "${m%%.*}" -le 16 ] 2>/dev/null; then
  echo "РЕЗУЛЬТАТ: ЧЁРНЫЙ КАДР — relayd отдаёт свой splash, входной пайплайн не играет."
  echo "  проверь: journalctl -u v4l2-relayd@surface-front -n 40"
  echo "  частые причины: нет videorate в VIDEOSRC; нет дроп-ина с DeviceAllow для dma-buf"
else
  echo "РЕЗУЛЬТАТ: картинка есть"
fi
[ -n "${PID:-}" ] && echo "нагрузка v4l2-relayd в установившемся режиме: $(( (u2+s2-u1-s1)*100/(5*HZ) ))% ядра"
echo "выбранный режим сенсора: $(journalctl -u v4l2-relayd@surface-front.service --since '1 minute ago' --no-pager 2>/dev/null | grep -oE 'configuring streams: \(0\) [0-9]+x[0-9]+' | tail -1 | sed 's/.*) //')"
