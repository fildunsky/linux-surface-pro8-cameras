#!/bin/bash
# Одна проба ИК-камеры VD55G0 с чистого состояния.
#
#   sudo ./ir-probe.sh [параметры модуля vd55g]
#   sudo ./ir-probe.sh                    # как в апстриме
#   sudo ./ir-probe.sh ctx_mode=2
#   sudo ./ir-probe.sh win_table=1        # дословно как Windows
#
# Две ловушки, без обхода которых замер врёт:
#
#  1. PipeWire держит /dev/video42 и /dev/media0 открытыми. Пока он
#     работает, intel_ipu6_isys не выгружается, modprobe -r vd55g молча не
#     срабатывает, и параметры модуля не применяются — проба показывает
#     поведение апстрима. Останавливать надо из пользовательской сессии:
#       systemctl --user stop wireplumber pipewire pipewire-pulse \
#                             pipewire.socket pipewire-pulse.socket
#  2. После перезагрузки модулей ссылки в media-графе выключены. Без
#     media-ctl -l получаем "Link has been severed" и ноль SOF — что легко
#     принять за поведение сенсора.
#
# Порядок выгрузки: сначала intel_ipu6_isys, потом vd55g. Обратный не
# работает — vd55g держит граф.
#
# Контроль метода: на рабочей цветной камере тот же счёт даёт ~96 SOF за
# 20 секунд. У ИК стабильно SOF=1, DATA=0.
set -u
ARGS="$*"
systemctl stop v4l2-relayd@surface-front v4l2-relayd@surface-rear 2>/dev/null
modprobe -r intel_ipu6_isys || { echo "isys держат"; exit 1; }
sleep 1
modprobe -r vd55g || { echo "vd55g держат"; exit 1; }
modprobe vd55g $ARGS || exit 1
modprobe intel_ipu6_isys ignore_str2mmio=1 || exit 1
sleep 3
echo "module intel_ipu6_isys +p" > /sys/kernel/debug/dynamic_debug/control
M=/dev/media0
media-ctl -d $M -l '"vd55g 3-0060":0 -> "Intel IPU6 CSI2 5":0[1]' 2>/dev/null
media-ctl -d $M -l '"Intel IPU6 CSI2 5":1 -> "Intel IPU6 ISYS Capture 40":0[1]' 2>/dev/null
for pad in '"vd55g 3-0060":0' '"Intel IPU6 CSI2 5":0' '"Intel IPU6 CSI2 5":1'; do
  media-ctl -d $M -V "$pad [fmt:Y10_1X10/644x604]" 2>/dev/null
done
dmesg -C; rm -f /tmp/ir.raw
timeout 12 v4l2-ctl -d /dev/video42 --set-fmt-video=width=644,height=604,pixelformat=Y10P \
  --stream-mmap --stream-count=5 --stream-to=/tmp/ir.raw >/dev/null 2>&1
echo "[$ARGS] -> $(stat -c%s /tmp/ir.raw 2>/dev/null || echo 0) байт  SOF=$(dmesg|grep -c FRAME_SOF) DATA=$(dmesg|grep -c PIN_DATA_READY)"
dmesg | grep -iE "Windows register table|OIF_CTRL left" | sed 's/.*: /    /'
dmesg | grep -oE "csi2-[0-9] error: [a-zA-Z ]*" | sort | uniq -c | sed 's/^/    /'
rm -f /tmp/ir.raw
