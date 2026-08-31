#!/bin/bash
# Установить файл тюнинга libcamera и перезапустить всех, кто его кэширует.
#
# ЗАЧЕМ ЭТОТ СКРИПТ. Файл тюнинга читается один раз, при создании конвейера
# libcamera внутри процесса-потребителя. WirePlumber живёт с момента входа в
# систему, v4l2-relayd — с момента загрузки, поэтому оба продолжают рисовать
# старой матрицей сколько угодно долго после правки файла.
#
# На эти грабли я потратил несколько заходов: прямой замер через gst-launch
# показывал новый цвет, а приложение «Камера» — старый, и выглядело это как
# «правки вообще не влияют». Проверка, которая всё вскрыла:
#   systemctl --user show wireplumber.service -p ActiveEnterTimestamp --value
#   stat -c%y /usr/share/libcamera/ipa/simple/ov13858.yaml
# Если файл новее службы — приложение видит старое.
#
# Использование: ./apply-tuning.sh tuning/ov13858.yaml
set -euo pipefail
[ $# -eq 1 ] || { echo "использование: $0 <файл.yaml>"; exit 2; }
SRC="$1"; NAME=$(basename "$SRC")
[ -f "$SRC" ] || { echo "нет файла $SRC"; exit 1; }

sudo install -m 644 -o root -g root "$SRC" "/usr/share/libcamera/ipa/simple/$NAME"
echo "установлен /usr/share/libcamera/ipa/simple/$NAME"

sudo systemctl restart v4l2-relayd.service 2>/dev/null || true
echo "перезапущен v4l2-relayd (путь Chrome и Zoom)"

systemctl --user restart wireplumber.service
echo "перезапущен wireplumber (путь приложения «Камера» и Firefox)"

echo
echo "Приложения, которые уже держали камеру, надо закрыть и открыть заново."
