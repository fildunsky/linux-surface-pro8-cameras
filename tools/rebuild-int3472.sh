#!/bin/bash
# Собрать исходники intel_skl_int3472_discrete для Surface Pro 8:
#   mainline + хунки int3472 из патчсета linux-surface + наша правка типа 0x10.
#
# ЗАЧЕМ. Контроллер питания ИК-камеры (INT3472:02, \_SB_.PC00.I2C3.ICL2)
# описывает четыре линии GPIO, и одна из них имеет тип 0x10. Патчсет
# linux-surface этот тип опознаёт и даёт ему имя pwr2, но в switch, который
# заводит регуляторы, у него стоит пустой case — регулятор не создаётся, и
# сенсор остаётся без питания: по I2C он молчит (-121).
#
# ЧТО ЭТО ЗА ЛИНИЯ. Тип 0x10 — питание. Подтверждено двумя независимыми
# источниками:
#   * mainline v7.0 добавил INT3472_GPIO_TYPE_DOVDD = 0x10 и заводит на него
#     регулятор dovdd (digital I/O voltage);
#   * виндовый драйвер контроллера iactrllogic64.sys держит массив имён типов,
#     где индекс 0x10 назван Avdd; пять других индексов этого массива в точности
#     совпадают с константами ядра, так что нумерация подтверждается.
# Названия у них разные (dovdd против Avdd), но суть одна: это регулятор,
# который надо поднимать, а не «линия неизвестного назначения».
#
# Берём имя из mainline — dovdd. Тогда, когда ядро доедет до 7.0, наш драйвер
# сенсора продолжит работать без правок, а этот пакет можно будет просто снять.
#
# Использование:
#   ./rebuild-int3472.sh          # ядро v6.19.8, патчсет master
# Результат: ./int3472/ рядом со скриптом — четыре .c для сборки модуля.
set -euo pipefail

KVER="${KVER:-v6.19.8}"
BRANCH="$(echo "${KVER#v}" | cut -d. -f1,2)"
PATCHURL="${PATCHURL:-https://raw.githubusercontent.com/linux-surface/linux-surface/master/patches/$BRANCH/0013-cameras.patch}"
OUT="${OUT:-$PWD/int3472}"
BASE="https://raw.githubusercontent.com/gregkh/linux/$KVER/drivers/platform/x86/intel/int3472"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "ядро: $KVER"
for f in discrete.c discrete_quirks.c clk_and_regulator.c led.c; do
    curl -sfL --max-time 120 -o "$TMP/$f" "$BASE/$f"
    [ -s "$TMP/$f" ] || { echo "$f скачался пустым"; exit 1; }
done
echo "mainline: $(wc -l < "$TMP/discrete.c") строк в discrete.c"

curl -sfL --max-time 150 -o "$TMP/cam.patch" "$PATCHURL"
python3 - "$TMP/cam.patch" "$TMP/discrete.patch" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
keep, on = [], False
for line in open(src):
    if line.startswith('--- a/'):
        on = 'int3472/discrete.c' in line
    elif line.startswith('diff --git ') and on:
        on = False
    if on:
        keep.append(line)
if not keep:
    sys.exit("в патчсете нет хунков для discrete.c")
open(dst, 'w').writelines(keep)
print(f"хунков discrete.c: {sum(1 for l in keep if l.startswith('@@'))}")
PYEOF
( cd "$TMP" && patch -p0 --no-backup-if-mismatch -i discrete.patch discrete.c )

# --- наша правка: тип 0x10 заводит регулятор -------------------------------
python3 - "$TMP/discrete.c" <<'PYEOF2'
import sys
p = sys.argv[1]
src = open(p).read()

# 1. константа: в 6.19 её в заголовке ядра ещё нет, в 7.0 есть
ANCHOR = '#include <linux/platform_data/x86/int3472.h>\n'
add = """
/* Появилась в mainline v7.0; в 6.19 заголовок ядра её ещё не знает. */
#ifndef INT3472_GPIO_TYPE_DOVDD
#define INT3472_GPIO_TYPE_DOVDD		0x10
#endif
"""
if 'INT3472_GPIO_TYPE_DOVDD' in src:
    sys.exit("ОШИБКА: правка уже применена")
if src.count(ANCHOR) != 1:
    sys.exit("ОШИБКА: не нашёл include int3472.h")
src = src.replace(ANCHOR, ANCHOR + add)

# 2. имя регулятора: патчсет linux-surface зовёт его pwr2, mainline — dovdd
OLD = """	case 0x10:  /* Surface Pro 9 - secondary power rail */
		*con_id = "pwr2";
		*gpio_flags = GPIO_ACTIVE_HIGH;
		break;"""
NEW = """	case INT3472_GPIO_TYPE_DOVDD:
		/*
		 * Питание цифровой периферии сенсора. В mainline v7.0 эта
		 * линия называется dovdd, в патчсете linux-surface — pwr2.
		 * Берём имя mainline, чтобы драйвер сенсора не пришлось
		 * править при переходе на новое ядро.
		 */
		*con_id = "dovdd";
		*gpio_flags = GPIO_ACTIVE_HIGH;
		break;"""
if src.count(OLD) != 1:
    sys.exit(f"ОШИБКА: не нашёл имя pwr2 ({src.count(OLD)} совпадений)")
src = src.replace(OLD, NEW)

# 3. добыть сам gpiod: в списке типов, которые запрашивают линию, 0x10 уже есть
#    (патчсет добавил "case 0x08: case 0x10:"), проверяем это и не трогаем
if 'case 0x08:  /* Surface Pro 9 power rails */\n	case 0x10:' not in src:
    sys.exit("ОШИБКА: патчсет больше не добавляет 0x10 в список запроса gpiod")

# 4. главное: завести регулятор вместо пустого case
OLD_REG = """		case 0x10:
		    break;"""
NEW_REG = """		case INT3472_GPIO_TYPE_DOVDD:
			/*
			 * Здесь у патчсета linux-surface стоял пустой case:
			 * линия опознавалась, но регулятор не создавался, и
			 * ИК-сенсор оставался без питания — по I2C он молчал
			 * с -121. mainline v7.0 в этом месте заводит регулятор
			 * ровно так же, как для avdd и dvdd.
			 */
			ret = skl_int3472_register_regulator(int3472, gpio,
							     GPIO_REGULATOR_ENABLE_TIME,
							     con_id, NULL);
			if (ret) {
				dev_err(int3472->dev,
					"Failed to register DOVDD regulator: %d\\n",
					ret);
				return ret;
			}
			break;"""
if src.count(OLD_REG) != 1:
    sys.exit(f"ОШИБКА: не нашёл пустой case 0x10 ({src.count(OLD_REG)} совпадений)")
src = src.replace(OLD_REG, NEW_REG)

# 5. имена питаний для SMO55F0 из linux-surface/kernel#169
#
# Драйвер vd55g просит три регулятора: vcore, vddio, vana. У INT3472 они
# приходят линиями типов HANDSHAKE (0x12), DOVDD (0x10) и POWER_ENABLE (0x0b),
# и без этой таблицы имена получаются другие — сенсор остаётся без питания.
# Ровно эти три записи есть в PR petm5, берём как есть.
OLD_MAP = """	{
		.hid = "INT3537",
		.type_from = INT3472_GPIO_TYPE_HANDSHAKE,"""
NEW_MAP = """	{
		.hid = "SMO55F0",
		.type_from = INT3472_GPIO_TYPE_HANDSHAKE,
		.type_to = INT3472_GPIO_TYPE_HANDSHAKE,
		.con_id = "vcore",
	},
	{
		.hid = "SMO55F0",
		.type_from = INT3472_GPIO_TYPE_DOVDD,
		.type_to = INT3472_GPIO_TYPE_DOVDD,
		.con_id = "vddio",
	},
	{
		.hid = "SMO55F0",
		.type_from = INT3472_GPIO_TYPE_POWER_ENABLE,
		.type_to = INT3472_GPIO_TYPE_POWER_ENABLE,
		.con_id = "vana",
	},
	{
		.hid = "INT3537",
		.type_from = INT3472_GPIO_TYPE_HANDSHAKE,"""
if src.count(OLD_MAP) != 1:
    # запасной якорь: вставляем перед закрывающей скобкой таблицы
    OLD_MAP = """		.con_id = "dvdd",
		.enable_time_us = 45 * USEC_PER_MSEC,
	},
};"""
    NEW_MAP = """		.con_id = "dvdd",
		.enable_time_us = 45 * USEC_PER_MSEC,
	},
	{
		.hid = "SMO55F0",
		.type_from = INT3472_GPIO_TYPE_HANDSHAKE,
		.type_to = INT3472_GPIO_TYPE_HANDSHAKE,
		.con_id = "vcore",
	},
	{
		.hid = "SMO55F0",
		.type_from = INT3472_GPIO_TYPE_DOVDD,
		.type_to = INT3472_GPIO_TYPE_DOVDD,
		.con_id = "vddio",
	},
	{
		.hid = "SMO55F0",
		.type_from = INT3472_GPIO_TYPE_POWER_ENABLE,
		.type_to = INT3472_GPIO_TYPE_POWER_ENABLE,
		.con_id = "vana",
	},
};"""
    if src.count(OLD_MAP) != 1:
        sys.exit("ОШИБКА: не нашёл таблицу int3472_gpio_map (%d)" % src.count(OLD_MAP))
src = src.replace(OLD_MAP, NEW_MAP)

open(p, 'w').write(src)
print("тип 0x10 заводит регулятор; SMO55F0 получил vcore/vddio/vana")
PYEOF2

# --- имя регулятора длиннее четырёх букв ------------------------------------
# GPIO_SUPPLY_NAME_LENGTH в ядрах до 7.0 равен 5 — ровно под "avdd\0" и
# "dvdd\0". Имя dovdd, которое mainline даёт линии типа 0x10, туда не влезает,
# и регистрация валится с -E2BIG. Поднять константу нельзя: она задаёт размер
# поля supply_name_upper в структуре int3472_discrete_device, а эта структура
# общая с модулем intel_skl_int3472_common, который мы не пересобираем.
# Поэтому строку в верхнем регистре выносим в отдельную выделенную память, а
# проверяем то, что действительно ограничено, — итоговое имя регулятора
# ("INT3472:02-dovdd" — 16 символов при лимите 17 вместе с нулём).
python3 - "$TMP/clk_and_regulator.c" <<'PYEOF3'
import sys
p = sys.argv[1]
src = open(p).read()

if 'supply_name_upper = devm_kstrdup' in src:
    sys.exit("ОШИБКА: правка длины имени уже применена")

OLD_DECL = """	struct regulator_config cfg = { };
	int i, j;"""
NEW_DECL = """	struct regulator_config cfg = { };
	char *supply_name_upper;
	int i, j;"""
if src.count(OLD_DECL) != 1:
    sys.exit("ОШИБКА: не нашёл объявления в skl_int3472_register_regulator")
src = src.replace(OLD_DECL, NEW_DECL)

OLD_CHK = """	if (strlen(supply_name) >= GPIO_SUPPLY_NAME_LENGTH) {
		dev_err(int3472->dev, "supply-name '%s' length too long\\n", supply_name);
		return -E2BIG;
	}

	regulator = &int3472->regulators[int3472->n_regulator_gpios];
	string_upper(regulator->supply_name_upper, supply_name);"""
NEW_CHK = """	/*
	 * Ограничено на самом деле итоговое имя регулятора, а не имя линии:
	 * GPIO_SUPPLY_NAME_LENGTH задаёт размер поля в структуре, общей с
	 * модулем intel_skl_int3472_common, и трогать его нельзя.
	 */
	if (strlen(acpi_dev_name(int3472->adev)) + 1 + strlen(supply_name) >=
	    GPIO_REGULATOR_NAME_LENGTH) {
		dev_err(int3472->dev, "supply-name '%s' length too long\\n", supply_name);
		return -E2BIG;
	}

	regulator = &int3472->regulators[int3472->n_regulator_gpios];

	supply_name_upper = devm_kstrdup(int3472->dev, supply_name, GFP_KERNEL);
	if (!supply_name_upper)
		return -ENOMEM;
	string_upper(supply_name_upper, supply_name);"""
if src.count(OLD_CHK) != 1:
    sys.exit("ОШИБКА: не нашёл проверку длины supply_name")
src = src.replace(OLD_CHK, NEW_CHK)

OLD_USE = "		const char *supply = i ? regulator->supply_name_upper : supply_name;"
NEW_USE = "		const char *supply = i ? supply_name_upper : supply_name;"
if src.count(OLD_USE) != 1:
    sys.exit("ОШИБКА: не нашёл использование supply_name_upper")
src = src.replace(OLD_USE, NEW_USE)

open(p, 'w').write(src)
print("верхний регистр имени вынесен из структуры")
PYEOF3

# --- имя светодиода приватности --------------------------------------------
# Ядро ищет его строго по con_id "privacy":
#     drivers/media/v4l2-core/v4l2-subdev.c   led_get(sd->dev, "privacy")
# До 7.1 имя было зашито в led.c, а con_id из discrete.c для светодиода не
# использовался вовсе — там стояло "privacy-led", и это никому не мешало.
# С новым API (см. ниже) con_id идёт насквозь и в имя, и в lookup, поэтому
# "privacy-led" ломает поиск: диод регистрируется, но ядро его не находит.
python3 - "$TMP/discrete.c" <<'PYEOF4'
import sys
p = sys.argv[1]
src = open(p).read()
old = '\t\t*con_id = "privacy-led";'
if old not in src:
    print("con_id светодиода уже 'privacy' — правка не нужна")
else:
    src = src.replace(old, '\t\t*con_id = "privacy";')
    open(p, 'w').write(src)
    print("светодиод приватности: con_id приведён к 'privacy'")
PYEOF4

# --- led.c, собирающийся под оба поколения ядра -----------------------------
# В mainline 7.1 поле pled в struct int3472_discrete_device стало массивом
# leds[] со счётчиком n_leds, а функции получили аргумент con_id:
#     skl_int3472_register_pled(int3472, gpio)
#         -> skl_int3472_register_led(int3472, gpio, con_id)
#     skl_int3472_unregister_pled -> skl_int3472_unregister_leds
# Один DKMS-пакет должен собираться и на 6.19, и на 7.x, поэтому кладём обе
# реализации под условной компиляцией. Признак нового ядра — INT3472_MAX_LEDS:
# в заголовках 6.19 и 7.0 этого макроса ещё нет.
cat > "$TMP/led.c" <<'LEDEOF'
// SPDX-License-Identifier: GPL-2.0
/* Author: Hans de Goede <hdegoede@redhat.com> */

#include <linux/acpi.h>
#include <linux/gpio/consumer.h>
#include <linux/leds.h>
#include <linux/platform_data/x86/int3472.h>

/*
 * В mainline 7.1 структура int3472_discrete_device поменялась: одиночное
 * поле pled стало массивом leds[] со счётчиком n_leds, а функции получили
 * аргумент con_id. Признак новой структуры — INT3472_MAX_LEDS: в 6.19 и
 * 7.0 такого макроса в заголовке ядра ещё нет.
 */
#ifdef INT3472_MAX_LEDS

static int int3472_led_set(struct led_classdev *led_cdev, enum led_brightness brightness)
{
	struct int3472_led *led = container_of(led_cdev, struct int3472_led, classdev);

	gpiod_set_value_cansleep(led->gpio, brightness);
	return 0;
}

int skl_int3472_register_led(struct int3472_discrete_device *int3472, struct gpio_desc *gpio,
			     const char *con_id)
{
	struct int3472_led *led;
	char *p;
	int ret;

	if (int3472->n_leds >= INT3472_MAX_LEDS)
		return -ENOSPC;

	led = &int3472->leds[int3472->n_leds];
	led->gpio = gpio;

	/* Generate the name, replacing the ':' in the ACPI devname with '_' */
	snprintf(led->name, sizeof(led->name),
		 "%s::%s_led", acpi_dev_name(int3472->sensor), con_id);
	p = strchr(led->name, ':');
	if (p)
		*p = '_';

	led->classdev.name = led->name;
	led->classdev.max_brightness = 1;
	led->classdev.brightness_set_blocking = int3472_led_set;

	ret = led_classdev_register(int3472->dev, &led->classdev);
	if (ret)
		return ret;

	led->lookup.provider = led->name;
	led->lookup.dev_id = int3472->sensor_name;
	led->lookup.con_id = con_id;
	led_add_lookup(&led->lookup);

	int3472->n_leds++;
	return 0;
}

void skl_int3472_unregister_leds(struct int3472_discrete_device *int3472)
{
	for (unsigned int i = 0; i < int3472->n_leds; i++) {
		struct int3472_led *led = &int3472->leds[i];

		led_remove_lookup(&led->lookup);
		led_classdev_unregister(&led->classdev);
		gpiod_put(led->gpio);
	}
}

#else  /* старая структура: одиночный pled */

static int int3472_pled_set(struct led_classdev *led_cdev,
				     enum led_brightness brightness)
{
	struct int3472_discrete_device *int3472 =
		container_of(led_cdev, struct int3472_discrete_device, pled.classdev);

	gpiod_set_value_cansleep(int3472->pled.gpio, brightness);
	return 0;
}

int skl_int3472_register_pled(struct int3472_discrete_device *int3472, struct gpio_desc *gpio)
{
	char *p;
	int ret;

	if (int3472->pled.classdev.dev)
		return -EBUSY;

	int3472->pled.gpio = gpio;

	/* Generate the name, replacing the ':' in the ACPI devname with '_' */
	snprintf(int3472->pled.name, sizeof(int3472->pled.name),
		 "%s::privacy_led", acpi_dev_name(int3472->sensor));
	p = strchr(int3472->pled.name, ':');
	if (p)
		*p = '_';

	int3472->pled.classdev.name = int3472->pled.name;
	int3472->pled.classdev.max_brightness = 1;
	int3472->pled.classdev.brightness_set_blocking = int3472_pled_set;

	ret = led_classdev_register(int3472->dev, &int3472->pled.classdev);
	if (ret)
		return ret;

	int3472->pled.lookup.provider = int3472->pled.name;
	int3472->pled.lookup.dev_id = int3472->sensor_name;
	int3472->pled.lookup.con_id = "privacy";
	led_add_lookup(&int3472->pled.lookup);

	return 0;
}

void skl_int3472_unregister_pled(struct int3472_discrete_device *int3472)
{
	if (IS_ERR_OR_NULL(int3472->pled.classdev.dev))
		return;

	led_remove_lookup(&int3472->pled.lookup);
	led_classdev_unregister(&int3472->pled.classdev);
	gpiod_put(int3472->pled.gpio);
}

#endif
LEDEOF
echo "led.c: обе реализации под #ifdef INT3472_MAX_LEDS"

mkdir -p "$OUT"
cp "$TMP"/discrete.c "$TMP"/discrete_quirks.c "$TMP"/clk_and_regulator.c "$TMP"/led.c "$OUT/"
echo "готово: $OUT"
