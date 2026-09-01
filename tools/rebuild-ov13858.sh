#!/bin/bash
# Собрать исходник патченого ov13858.c для Surface Pro 8:
#   mainline + все правки ov13858 из патчсета linux-surface
#   + переворот заднего модуля на 180 градусов (по мотивам PR linux-surface#2227)
#
# ЗАЧЕМ ПОВОРОТ. Задний модуль ov13858 на Pro 8 установлен вверх ногами, но
# SSDB в ACPI сообщает 0, и приложения показывают картинку перевёрнутой.
#
# ПОЧЕМУ НЕ В ipu-bridge, ГДЕ ДЛЯ ЭТОГО ЕСТЬ ТАБЛИЦА. Здесь раньше стояло
# объяснение про контрольные суммы: якобы сборка ipu-bridge вне дерева ломает
# их и ядро отвергает модуль. Это неверно, измерено — одиночная сборка даёт
# ровно стоковые суммы, см. docs/NOTES.ru.md. Правка всё равно сделана в самом
# драйвере сенсора: он листовой, наружу ничего не экспортирует, и ровно так же
# поступает вторая половина PR #2227.
#
# Использование:
#   ./rebuild-ov13858.sh                     # ядро v6.19.8, патчсет master
#   KVER=v6.20 ./rebuild-ov13858.sh
# Результат: ./ov13858.c рядом со скриптом.
set -euo pipefail

KVER="${KVER:-v6.19.8}"
BRANCH="$(echo "${KVER#v}" | cut -d. -f1,2)"
PATCHURL="${PATCHURL:-https://raw.githubusercontent.com/linux-surface/linux-surface/master/patches/$BRANCH/0013-cameras.patch}"
OUT="${OUT:-$PWD/ov13858.c}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "ядро: $KVER"
curl -sfL --max-time 120 -o "$TMP/ov13858.c" \
  "https://raw.githubusercontent.com/gregkh/linux/$KVER/drivers/media/i2c/ov13858.c"
[ "$(wc -l < "$TMP/ov13858.c")" -gt 1500 ] || { echo "mainline скачался неполным"; exit 1; }
echo "mainline: $(wc -l < "$TMP/ov13858.c") строк"

curl -sfL --max-time 150 -o "$TMP/cam.patch" "$PATCHURL"
echo "патчсет: $(wc -c < "$TMP/cam.patch") байт"

# вырезаем из патчсета только хунки, относящиеся к ov13858.c
python3 - "$TMP/cam.patch" "$TMP/ov13858.patch" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
keep, on = [], False
for line in open(src):
    if line.startswith('--- a/'):
        on = 'drivers/media/i2c/ov13858.c' in line
    elif line.startswith('diff --git ') and on:
        on = False
    if on:
        keep.append(line)
if not keep:
    sys.exit("в патчсете нет хунков для ov13858.c")
open(dst, 'w').writelines(keep)
print(f"хунков ov13858: {sum(1 for l in keep if l.startswith('@@'))}")
PYEOF

( cd "$TMP" && patch -p0 --no-backup-if-mismatch -i ov13858.patch ov13858.c )
echo "после патчсета: $(wc -l < "$TMP/ov13858.c") строк"

# --- наша правка: поворот заднего модуля на Surface Pro 8 -------------------
python3 - "$TMP/ov13858.c" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()

def edit(anchor, addition, what, after=True):
    global src
    if addition.strip() and addition.strip() in src:
        sys.exit(f"ОШИБКА: правка «{what}» уже применена")
    if src.count(anchor) != 1:
        sys.exit(f"ОШИБКА: якорь «{what}» найден {src.count(anchor)} раз, нужен 1")
    src = src.replace(anchor, anchor + addition if after else addition + anchor)

edit("#include <linux/clk.h>\n", "#include <linux/dmi.h>\n", "include dmi.h")

edit("/* Initialize control handlers */\n",
"""static const struct dmi_system_id surface_pro_8_dmi[] = {
	{
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),
			DMI_MATCH(DMI_PRODUCT_NAME, "Surface Pro 8"),
		},
	},
	{ }
};

""", "таблица DMI", after=False)

edit("	ret = v4l2_ctrl_handler_init(ctrl_hdlr, 10);",
     "", "размер обработчика")  # проверка якоря
src = src.replace("	ret = v4l2_ctrl_handler_init(ctrl_hdlr, 10);",
                  "	/* +2 под поворот и ориентацию, добавляемые ниже для Surface Pro 8 */\n"
                  "	ret = v4l2_ctrl_handler_init(ctrl_hdlr, 12);")

ANCHOR = "	ret = v4l2_ctrl_new_fwnode_properties(ctrl_hdlr, &ov13858_ctrl_ops,\n"
edit(ANCHOR,
"""	/*
	 * Задний модуль Surface Pro 8 установлен вверх ногами, но SSDB в ACPI
	 * сообщает поворот 0, и ipu-bridge берёт значение оттуда. Таблица
	 * квирков в ipu-bridge для Pro 8 уже занята фронтальным INT33BE, а
	 * ищет по ней dmi_first_match(), то есть вторая запись на ту же модель
	 * невыразима. Правим здесь, до регистрации свойств fwnode.
	 * Подтверждено визуально на живой машине 30.08.2026.
	 */
	if (dmi_check_system(surface_pro_8_dmi)) {
		props.rotation = 180;
		if (props.orientation == V4L2_FWNODE_ORIENTATION_EXTERNAL)
			props.orientation = V4L2_FWNODE_ORIENTATION_BACK;
		dev_info(ov13858->dev,
			 "Surface Pro 8: rotation=180 для заднего модуля\\n");
	}

""", "переопределение поворота", after=False)

open(p, 'w').write(src)
print("правка поворота применена")
PYEOF

# --- поддержка HFLIP/VFLIP ------------------------------------------------
# Без неё libcamera не может исправить перевёрнутый модуль: она умеет
# компенсировать поворот только флипом в сенсоре, программного разворота у неё
# нет (в libcamera прямо есть строка "Camera sensor does not support
# horizontal/vertical flip"). Штатный ov13858 контролов флипа не имеет.
#
# Биты взяты у ov13b10 из mainline (тот же ряд сенсоров, тот же регистровый
# набор) и проверены на живом сенсоре записью по I2C: горизонтальное зеркало —
# сброс бита 3 в 0x3820, вертикальный переворот — установка битов 4 и 5.
# ВАЖНО: смещение окна кадрирования трогать НЕЛЬЗЯ, хотя ov13b10 в mainline
# так делает. На этом модуле переворот байеровский порядок не сдвигает, и
# поправка 0x3811 +1 / 0x3813 -1 наоборот его ломает: красный меняется местами
# с синим по всему тракту. Внешне это не похоже на сбой, а выглядит как «плохая
# цветопередача»: серое, белое и зелёное в порядке, а красная отвёртка
# фиолетовая, сине-зелёные пассатижи жёлтые, жёлтая карточка голубая. Проверено
# 30.08.2026 записью 0x3811=0x08 и 0x3813=0x03 во время съёмки, на сцене с
# предметами известного цвета.
python3 - "$TMP/ov13858.c" <<'PYEOF2'
import sys
p = sys.argv[1]
src = open(p).read()

def edit(anchor, addition, what, after=True):
    global src
    if addition.strip() and addition.strip() in src:
        sys.exit(f"ОШИБКА: правка «{what}» уже применена")
    if src.count(anchor) != 1:
        sys.exit(f"ОШИБКА: якорь «{what}» найден {src.count(anchor)} раз, нужен 1")
    src = src.replace(anchor, anchor + addition if after else addition + anchor)

# 1. адреса регистров
line = [l for l in src.splitlines() if l.startswith('#define OV13858_REG_CHIP_ID')]
if len(line) != 1:
    sys.exit("ОШИБКА: не нашёл #define OV13858_REG_CHIP_ID")
edit(line[0] + "\n",
     "\n/* Флип и смещение окна кадрирования (см. ov13b10 в mainline) */\n"
     "#define OV13858_REG_FORMAT1\t\t0x3820\n"
     "#define OV13858_FORMAT1_HFLIP\t\tBIT(3)\n"
     "#define OV13858_FORMAT1_VFLIP\t\t(BIT(4) | BIT(5))\n",
     "адреса регистров флипа")

# 2. сами обработчики
edit("static int ov13858_set_ctrl(struct v4l2_ctrl *ctrl)\n",
r"""static int ov13858_set_ctrl_hflip(struct ov13858 *ov13858, u32 ctrl_val)
{
	int ret;
	u32 val;

	ret = ov13858_read_reg(ov13858, OV13858_REG_FORMAT1,
			       OV13858_REG_VALUE_08BIT, &val);
	if (ret)
		return ret;

	/* Сброшенный бит 3 включает зеркало. */
	return ov13858_write_reg(ov13858, OV13858_REG_FORMAT1,
				 OV13858_REG_VALUE_08BIT,
				 ctrl_val ? val & ~OV13858_FORMAT1_HFLIP
					  : val | OV13858_FORMAT1_HFLIP);
}

static int ov13858_set_ctrl_vflip(struct ov13858 *ov13858, u32 ctrl_val)
{
	int ret;
	u32 val;

	ret = ov13858_read_reg(ov13858, OV13858_REG_FORMAT1,
			       OV13858_REG_VALUE_08BIT, &val);
	if (ret)
		return ret;

	/*
	 * Бит 4 включает переворот. Бит 5 уже поднят самими списками режимов
	 * (0xa8, 0xab, 0xac), гасить его нельзя — это настройка режима.
	 */
	return ov13858_write_reg(ov13858, OV13858_REG_FORMAT1,
				 OV13858_REG_VALUE_08BIT,
				 ctrl_val ? val | OV13858_FORMAT1_VFLIP
					  : val & ~BIT(4));
}


""", "обработчики флипа", after=False)

# 3. ветки switch
edit("	case V4L2_CID_TEST_PATTERN:\n",
"""	case V4L2_CID_HFLIP:
		ret = ov13858_set_ctrl_hflip(ov13858, ctrl->val);
		break;
	case V4L2_CID_VFLIP:
		ret = ov13858_set_ctrl_vflip(ov13858, ctrl->val);
		break;
""", "ветки switch", after=False)

# 4. регистрация контролов
edit("	v4l2_ctrl_new_std_menu_items(ctrl_hdlr, &ov13858_ctrl_ops,\n",
"""	/*
	 * Флипы объявляются, чтобы libcamera могла сама развернуть кадр:
	 * модуль установлен вверх ногами, camera_sensor_rotation = 180.
	 */
	v4l2_ctrl_new_std(ctrl_hdlr, &ov13858_ctrl_ops, V4L2_CID_HFLIP,
			  0, 1, 1, 0);
	v4l2_ctrl_new_std(ctrl_hdlr, &ov13858_ctrl_ops, V4L2_CID_VFLIP,
			  0, 1, 1, 0);

""", "регистрация контролов флипа", after=False)

# 5. место под два новых контрола
old = "	/* +2 под поворот и ориентацию, добавляемые ниже для Surface Pro 8 */\n	ret = v4l2_ctrl_handler_init(ctrl_hdlr, 12);"
new = "	/* +2 под поворот и ориентацию, +2 под HFLIP/VFLIP */\n	ret = v4l2_ctrl_handler_init(ctrl_hdlr, 14);"
if src.count(old) != 1:
    sys.exit("ОШИБКА: не нашёл v4l2_ctrl_handler_init(ctrl_hdlr, 12)")
src = src.replace(old, new)

open(p, 'w').write(src)
print("поддержка флипа добавлена")
PYEOF2

# --- нулевой пьедестал (BLC target) ---------------------------------------
# Сенсор по умолчанию поднимает чёрный на 64 из 1024 (регистр 0x4002/0x4003).
# Программный ISP libcamera из-за этого промахивается по балансу белого:
# шейдер вычитает пьедестал как долю от 255, а серый мир Awb вычитает то же
# число из сумм СЫРЫХ 10-битных отсчётов, то есть вчетверо меньше, чем нужно.
# Остаток в 48/1024 подмешивается ко всем трём каналам поровну и тянет их
# отношения к единице — тем сильнее, чем темнее сцена. Ночью баланс белого
# промахивался вдвое, заводская матрица добивала синий в ноль, и картинка
# уезжала в жёлто-оливковую; на пересвете белое становилось розовым.
# Ставим пьедестал в ноль: тогда обе стороны вычитают ноль и сходятся.
# В тюнинге при этом обязателен blackLevel: 0 (см. tools/factory-tuning.py).
# Проверено записью 0x4003=0x00 на живом сенсоре 30.08.2026: среднее по кадру
# стало R/G=0.96 B/G=0.99 вместо R/G=1.37 B/G=0.04.
python3 - "$TMP/ov13858.c" <<'PYEOF3'
import sys
p = sys.argv[1]
src = open(p).read()

line = [l for l in src.splitlines() if l.startswith('#define OV13858_REG_FORMAT1')]
if len(line) != 1:
    sys.exit("ОШИБКА: не нашёл #define OV13858_REG_FORMAT1")
add = ("\n/* Целевой уровень чёрного, 16 бит. Заводское значение 0x0040. */\n"
       "#define OV13858_REG_BLC_TARGET\t\t0x4002\n")
if add.strip() in src:
    sys.exit("ОШИБКА: правка пьедестала уже применена")
src = src.replace(line[0] + "\n", line[0] + "\n" + add)

ANCHOR = """	/* Apply customized values from user */
	ret =  __v4l2_ctrl_handler_setup(ov13858->sd.ctrl_handler);"""
if src.count(ANCHOR) != 1:
    sys.exit("ОШИБКА: якорь start_streaming не найден")
src = src.replace(ANCHOR, """	/*
	 * Убираем заводской пьедестал чёрного (0x0040 из 1024): программный ISP
	 * libcamera вычитает его из сумм для серого мира в другом масштабе,
	 * чем из самой картинки, и промахивается по балансу белого тем сильнее,
	 * чем темнее сцена. С нулём обе стороны сходятся. Тюнинг при этом обязан
	 * объявлять blackLevel: 0.
	 */
	ret = ov13858_write_reg(ov13858, OV13858_REG_BLC_TARGET,
				OV13858_REG_VALUE_16BIT, 0);
	if (ret) {
		dev_err(ov13858->dev, "%s failed to zero black level\\n", __func__);
		return ret;
	}

""" + ANCHOR)

open(p, 'w').write(src)
print("нулевой пьедестал добавлен")
PYEOF3

# --- только полное чтение сенсора ------------------------------------------
# Режим сенсора выбирает libcamera по запрошенному размеру выхода, и берёт
# самый маленький подходящий. На 1920x1080 это 2112x1188: по горизонтали там
# прореживание (0x3814 = 0x03, каждый второй столбец выбрасывается), по
# вертикали биннинг (0x3820 = 0xb3 против 0xb0 у полного кадра). Отсюда
# мягкость и лесенки; Windows всегда читает полный кадр 4224x3136 и уменьшает
# его своим ISP.
#
# Прячем прореженные режимы, оставляя только полный. Скорость от этого не
# страдает: замерено 29 кадр/с и на 1280x720, и на 2560x1440. Плата — около
# ступени по свету, которую давал вертикальный биннинг.
#
# Сделано параметром модуля, а не удалением, чтобы можно было вернуть без
# пересборки:
#   echo "options ov13858 subsampled_modes=1" | sudo tee /etc/modprobe.d/ov13858.conf
python3 - "$TMP/ov13858.c" <<'PYEOF4'
import sys
p = sys.argv[1]
src = open(p).read()

ANCHOR = "struct ov13858 {\n"
add = """static bool subsampled_modes;
module_param(subsampled_modes, bool, 0444);
MODULE_PARM_DESC(subsampled_modes,
	"Also offer the subsampled sensor modes (2112x1568, 2112x1188, 1056x784). "
	"They are softer than full readout: horizontally the sensor skips every "
	"other column. Off by default.");

/*
 * Полный кадр стоит в таблице первым, поэтому «только полное чтение» — это
 * просто длина таблицы, равная единице.
 */
static unsigned int ov13858_num_modes(void)
{
	return subsampled_modes ? ARRAY_SIZE(supported_modes) : 1;
}

"""
if add.strip().splitlines()[0] in src:
    sys.exit("ОШИБКА: правка про режимы уже применена")
if src.count(ANCHOR) != 1:
    sys.exit("ОШИБКА: якорь «struct ov13858 {» найден не один раз")
src = src.replace(ANCHOR, add + ANCHOR)

for old, new, what in (
    ("	if (fse->index >= ARRAY_SIZE(supported_modes))",
     "	if (fse->index >= ov13858_num_modes())", "перечисление размеров"),
    ("	mode = v4l2_find_nearest_size(supported_modes,\n"
     "				      ARRAY_SIZE(supported_modes),",
     "	mode = v4l2_find_nearest_size(supported_modes,\n"
     "				      ov13858_num_modes(),", "подбор ближайшего размера"),
):
    if src.count(old) != 1:
        sys.exit(f"ОШИБКА: якорь «{what}» найден {src.count(old)} раз, нужен 1")
    src = src.replace(old, new)

open(p, 'w').write(src)
print("прореженные режимы спрятаны за параметр модуля")
PYEOF4

cp "$TMP/ov13858.c" "$OUT"
echo "готово: $OUT ($(wc -l < "$OUT") строк)"
