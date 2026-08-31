#!/bin/bash
# Что именно берёт у камеры работающее приложение: размер кадра, формат
# пикселей и в каком режиме при этом стоит сенсор.
#
# ЗАЧЕМ. Мои замеры через gst-launch выходят с верным цветом во всех
# размерах, а приложение показывает перепутанные каналы. Значит приложение
# просит что-то другое, и надо увидеть что.
#
# Запускать, пока «Камера» показывает картинку с ЗАДНЕЙ камеры.
set -u
cd "$(dirname "$0")"

echo "=== что просит приложение у PipeWire ==="
timeout 15 pw-dump 2>/dev/null > /tmp/pwd.json || echo "pw-dump не отработал"
python3 - <<'PY'
import json, re
try:
    d = json.load(open('/tmp/pwd.json'))
except Exception as e:
    raise SystemExit(f"  разбор не удался: {e}")
for o in d:
    info = o.get('info') or {}
    props = info.get('props') or {}
    cls = str(props.get('media.class', ''))
    name = str(props.get('node.name', ''))
    if 'Stream/Input/Video' not in cls and 'CAMR' not in name:
        continue
    params = info.get('params') or {}
    fmt = params.get('Format') or []
    s = json.dumps(fmt)
    size = re.search(r'"size":\s*\{"width":\s*(\d+),\s*"height":\s*(\d+)\}', s)
    pix = re.search(r'"format":\s*"(\w+)"', s)
    print(f"  {props.get('application.name', props.get('node.description','?'))} "
          f"[{cls or 'узел камеры'}]")
    if size:
        print(f"     кадр {size.group(1)}x{size.group(2)}"
              + (f", формат {pix.group(1)}" if pix else ""))
    elif fmt:
        print(f"     формат есть, но размер не разобрался: {s[:200]}")
PY

echo
echo "=== в каком режиме сенсор ==="
sudo -v || exit 1
R() { sudo python3 i2c-reg.py 3 0x10 "$1" 2>/dev/null | awk '{print $NF}'; }
INC=$(R 0x3814)
if [ -z "$INC" ]; then
    echo "  сенсор молчит — задняя камера сейчас не снимает"
    exit 1
fi
H=$(R 0x3811); V=$(R 0x3813)
echo "  0x3814=$INC (0x01 полное чтение, 0x03 прореженное)"
echo "  0x3811=$H  0x3813=$V  сумма $( [ $(( (H + V) % 2 )) -eq 1 ] && echo нечётная || echo чётная )"
