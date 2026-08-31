#!/bin/bash
# Привести камеры в чувство, когда они «заняты» или переключаются через раз.
#
# ЗАЧЕМ. Плагин libcamera внутри PipeWire держит узлы камеры открытыми всё
# время, пока сессия жива. Если под ним перезагрузить драйвер сенсора
# (modprobe -r / modprobe, в том числе при обновлении через DKMS), старые узлы
# исчезают, а PipeWire продолжает держать их дескрипторы — в /proc/<pid>/fd они
# видны как «(deleted)». Камера при этом enumerate-ится, но захватить её уже
# нельзя: приложение показывает «занята», и так до перезапуска PipeWire.
# Перезапуска одного v4l2-relayd не хватает, он тут ни при чём.
#
# Побочный эффект: звук на секунду пропадёт, PipeWire ведает и им.
#
#   ./camera-reset.sh          — проверить и, если надо, починить
#   ./camera-reset.sh --check  — только проверить
set -u
SUDO="sudo"
BRIDGES="v4l2-relayd@surface-rear v4l2-relayd@surface-front"

stale() {
    for p in $(pgrep -x 'pipewire|wireplumber'); do
        ls -l /proc/$p/fd 2>/dev/null | grep -oE "/dev/[a-z0-9-]+ \(deleted\)"
    done
}

n=$(stale | wc -l)
if [ "$n" -gt 0 ]; then
    echo "PipeWire держит $n висячих узлов:"
    stale | sort | uniq -c | sed 's/^/  /'
else
    echo "висячих узлов нет"
fi

[ "${1:-}" = --check ] && exit 0
[ "$n" -eq 0 ] && { echo "перезапускать нечего"; exit 0; }

echo "останавливаю мосты"
$SUDO systemctl stop $BRIDGES
sleep 1
echo "перезапускаю PipeWire"
systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 4
echo "поднимаю мосты"
$SUDO systemctl start $BRIDGES
sleep 2

n=$(stale | wc -l)
[ "$n" -eq 0 ] && echo "готово, висячих узлов не осталось" || { echo "осталось $n — нужен перезаход в сессию"; exit 1; }
