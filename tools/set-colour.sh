#!/bin/bash
# Пересобрать и поставить цветовые профили камер из заводской калибровки Intel.
#
# Профили берутся из factory-tuning/*.aiqb: для каждого источника света там
# лежат сырые R/G и B/G серой карты и матрица цветокоррекции именно этого
# модуля камеры. В тюнинг идут ВСЕ источники сразу, а какой из них применить,
# libcamera решает сама по оценке цветовой температуры от серого мира.
#
#   ./set-colour.sh              — показать источники света обеих камер
#   ./set-colour.sh apply        — собрать тюнинги заново и поставить
#
# Раньше здесь можно было выбрать один источник руками. Так больше не делаем:
# при этом баланс белого зашивается в столбцы матрицы, суммы строк перестают
# быть равными единице, и пересвеченное белое уходит в розовый. Подробности —
# NOTES.md, раздел «Цветопередача». Старый режим остался в самом
# factory-tuning.py (третьим аргументом — температура) и годится только для
# сравнения.
set -euo pipefail
cd "$(dirname "$0")/.."
declare -A AIQB=( [rear]=factory-tuning/OV13858_MSHW0261_TGL.aiqb
                  [front]=factory-tuning/OV5693_MSHW0260_TGL.aiqb )
declare -A YAML=( [rear]=ov13858.yaml [front]=ov5693.yaml )

if [ "${1:-}" != apply ]; then
    for c in front rear; do echo "== $c =="; ./tools/factory-tuning.py "${AIQB[$c]}"; done
    echo
    echo "поставить заново: ./tools/set-colour.sh apply"
    exit 0
fi

for c in front rear; do
    ./tools/factory-tuning.py "${AIQB[$c]}" - "tuning/${YAML[$c]}"
    echo "собран tuning/${YAML[$c]}"
done
# У обеих камер пьедестал чёрного нулевой: у задней его обнуляет драйвер,
# у передней его почти нет. Генератор ставит blackLevel: 0 только для задней,
# передней он нужен ровно так же.
python3 - <<'PY'
p = 'tuning/ov5693.yaml'
s = open(p).read()
if 'blackLevel' not in s:
    s = s.replace("  - BlackLevel:\n", "  - BlackLevel:\n      blackLevel: 0\n")
    open(p, 'w').write(s)
PY
./tools/apply-tuning.sh tuning/ov13858.yaml
./tools/apply-tuning.sh tuning/ov5693.yaml
