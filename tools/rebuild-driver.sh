#!/bin/bash
# Собрать исходник патченого ov5693.c: mainline + все правки ov5693 из
# патчсета linux-surface. Заменяет прежний rebuild-from-mainline.sh, который
# накладывал правки вручную и удалял биннинг-режим — это больше не нужно,
# биннинг чинится по-настоящему патчем из PR #2252.
#
# Использование:
#   ./rebuild-driver.sh                      # ветка PR 2252, ядро v6.19.8
#   KVER=v6.20 ./rebuild-driver.sh           # другое ядро
#   SRC=master ./rebuild-driver.sh           # патчсет из master linux-surface
#
# Результат: ./ov5693.c рядом со скриптом. Дальше:
#   sudo cp ov5693.c /usr/src/ov5693-1.1-surface-ipu6/
#   sudo dkms install -m ov5693 -v 1.1-surface-ipu6
set -euo pipefail

KVER="${KVER:-v6.19.8}"
SRC="${SRC:-pr2252}"
OUT="${OUT:-$PWD/ov5693.c}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

case "$SRC" in
  pr2252) PATCHURL="https://raw.githubusercontent.com/dmanresa-saes/linux-surface/a7513638cda7/patches/6.19/0013-cameras.patch" ;;
  master) PATCHURL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/patches/6.19/0013-cameras.patch" ;;
  *)      PATCHURL="$SRC" ;;
esac

echo "ядро: $KVER, патчсет: $SRC"

# git.kernel.org периодически отдаёт страницу ошибки вместо файла,
# поэтому зеркало на GitHub идёт первым.
got=""
for u in \
  "https://raw.githubusercontent.com/gregkh/linux/$KVER/drivers/media/i2c/ov5693.c" \
  "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/media/i2c/ov5693.c?h=$KVER" ; do
  curl -sfL --max-time 120 -o "$TMP/ov5693.c" "$u" 2>/dev/null || continue
  if [ "$(wc -l < "$TMP/ov5693.c")" -gt 1000 ]; then got="$u"; break; fi
done
[ -n "$got" ] || { echo "не удалось скачать mainline ov5693.c"; exit 1; }
echo "mainline: $(wc -l < "$TMP/ov5693.c") строк"

curl -sfL --max-time 150 -o "$TMP/cam.patch" "$PATCHURL" || { echo "не скачался патчсет"; exit 1; }
echo "патчсет: $(wc -c < "$TMP/cam.patch") байт"

python3 - "$TMP/cam.patch" "$TMP/ov5693.patch" <<'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
txt = open(src).read().split('\n')
starts = [i for i, l in enumerate(txt) if re.match(r'^From [0-9a-f]{40}', l)]
starts.append(len(txt))
out, taken = [], []
for a, b in zip(starts, starts[1:]):
    block = txt[a:b]
    subj = next((l for l in block if l.startswith('Subject:')), '')
    keep, on = [], False
    for l in block:
        if l.startswith('diff --git '):
            on = l.endswith('b/drivers/media/i2c/ov5693.c')
        if on:
            keep.append(l)
    if keep:
        taken.append(subj[9:].strip())
        out += keep
if not out:
    print("в патчсете нет правок по ov5693.c"); sys.exit(1)
open(dst, 'w').write('\n'.join(out) + '\n')
print("беру коммиты:")
for t in taken:
    print("  -", t[:88])
PYEOF

mkdir -p "$TMP/drivers/media/i2c"
mv "$TMP/ov5693.c" "$TMP/drivers/media/i2c/ov5693.c"
( cd "$TMP" && patch -p1 --silent < ov5693.patch )
cp "$TMP/drivers/media/i2c/ov5693.c" "$OUT"
echo "готово: $OUT ($(wc -l < "$OUT") строк)"
grep -q binned_y_offset "$OUT" && echo "  фикс биннинга на месте (есть параметр binned_y_offset)"
