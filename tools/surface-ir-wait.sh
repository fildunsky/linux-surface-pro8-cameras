#!/bin/sh
# Дождаться, пока петля ИК-камеры начнёт отдавать формат.
#
# /dev/surface-ir-camera существует с момента загрузки модуля v4l2loopback,
# но VIDIOC_G_FMT на ней возвращает EINVAL, пока в неё не начал писать
# поставщик — то есть пока ffmpeg из surface-ir-camera.service не отдал
# первый кадр. visaged, стартовав раньше, падает с "streaming not supported",
# а первый же запрос с экрана входа получает "failed to query current format".
#
# Ждём готовности, а не просто запуска соседнего юнита: After= в systemd
# для Type=simple означает лишь "процесс запущен", а не "формат появился".
DEV=${1:-/dev/surface-ir-camera}
DEADLINE=$(( $(date +%s) + ${2:-30} ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if v4l2-ctl -d "$DEV" --get-fmt-video >/dev/null 2>&1; then
        echo "петля $DEV готова"
        exit 0
    fi
    sleep 1
done
echo "петля $DEV не отдала формат за отведённое время; visaged стартует всё равно" >&2
exit 0
