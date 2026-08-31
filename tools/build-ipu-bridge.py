#!/usr/bin/env python3
"""Собирает исходник ipu-bridge.c для Surface Pro 8 из апстрима.

Итоговый файл = mainline ipu-bridge.c нужной версии
              + хунки патчсета linux-surface (patches/<ветка>/0013-cameras.patch)
              + правка из PR linux-surface#2227 (обход всей таблицы квирков)
              + запись для задней камеры Surface Pro 8 (наш вклад)

Зачем всё это: задняя камера ov13858 установлена вверх ногами, но SSDB в ACPI
сообщает поворот 0. В mainline для таких машин есть таблица
upside_down_sensor_dmi_ids, но ищет по ней dmi_first_match() — то есть ровно
одна запись на модель. Патчсет linux-surface уже занял запись Surface Pro 8
идентификатором INT33BE (фронтальная камера), поэтому вторая запись для задней
камеры без правки обхода просто не сработает.

Использование:  ./build-ipu-bridge.py [версия-ядра] > ipu-bridge.c
"""
import re, subprocess, sys, urllib.request

KVER = sys.argv[1] if len(sys.argv) > 1 else "v6.19.8"
BRANCH = ".".join(KVER.lstrip("v").split(".")[:2])   # 6.19.8 -> 6.19

MAINLINE = f"https://raw.githubusercontent.com/gregkh/linux/{KVER}/drivers/media/pci/intel/ipu-bridge.c"
PATCHSET = f"https://raw.githubusercontent.com/linux-surface/linux-surface/master/patches/{BRANCH}/0013-cameras.patch"


def fetch(url):
    sys.stderr.write(f"тяну {url}\n")
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode()


def edit(src, anchor, addition, what, after=True):
    """Вставляет addition рядом с anchor. Падает, если якорь не найден или
    правка уже применена — молчаливый пропуск здесь опаснее остановки."""
    if addition.strip() in src:
        sys.exit(f"ОШИБКА: правка «{what}» уже присутствует в исходнике")
    if src.count(anchor) != 1:
        sys.exit(f"ОШИБКА: якорь для «{what}» найден {src.count(anchor)} раз, ожидался 1")
    return src.replace(anchor, anchor + addition if after else addition + anchor)


src = fetch(MAINLINE)
patchset = fetch(PATCHSET)

# --- 1. хунк linux-surface: конфигурации сенсоров Surface Pro 9 -------------
# Проверяем, что в патчсете он действительно есть — если апстрим его убрал,
# лучше остановиться, чем собрать не то, что задумано.
if 'IPU_SENSOR_CONFIG("OVTID858"' not in patchset:
    sys.exit("ОШИБКА: в патчсете linux-surface нет записи OVTID858")

src = edit(src,
    '\tIPU_SENSOR_CONFIG("INT33F0", 1, 384000000),\n',
    '\t/* Omnivision OV5693 - Surface Pro 9 */\n'
    '\tIPU_SENSOR_CONFIG("OVTI5693", 1, 419200000),\n'
    '\t/* Omnivision OV13858 - Surface Pro 9 */\n'
    '\tIPU_SENSOR_CONFIG("OVTID858", 4, 540000000),\n',
    "конфигурации сенсоров из linux-surface")

# --- 1a. наша запись: ИК-камера ---------------------------------------------
# SMO55F0 — STMicroelectronics VD55G0, ИК-камера Windows Hello на Surface
# Pro 8 и Pro 10. Одна линия — из SSDB в DSDT. Частота линии 400 МГц (то есть
# 800 Мбит/с на линию) взята из виндового драйвера vd55g0.sys: в массиве
# режимов в .data константа 800000000 стоит сразу за полями 644 / 604 / 60 / 1,
# где последнее совпадает с числом линий из SSDB. Раньше здесь стояло 600 МГц
# из примера биндинга st,vd55g1 — это была догадка по верхней границе,
# допустимой драйвером (VD55G1_MIPI_RATE_MAX = 1200 Мбит/с).
src = edit(src,
    '\tIPU_SENSOR_CONFIG("OVTID858", 4, 540000000),\n',
    '\t/* STMicroelectronics VD55G0 - ИК-камера Surface Pro 8 и Pro 10 */\n'
    '\tIPU_SENSOR_CONFIG("SMO55F0", 1, 380000000),\n',
    "запись ИК-камеры")

# --- 2. хунк linux-surface: записи квирка поворота --------------------------
TERM = "\t{} /* Terminating entry */\n};\n\nstatic const struct ipu_property_names prop_names"
src = edit(src, TERM,
    '\t{\n'
    '\t\t.matches = {\n'
    '\t\t\tDMI_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),\n'
    '\t\t\tDMI_MATCH(DMI_PRODUCT_NAME, "Surface Pro 8"),\n'
    '\t\t},\n'
    '\t\t.driver_data = "INT33BE",\n'
    '\t},\n'
    '\t{\n'
    '\t\t.matches = {\n'
    '\t\t\tDMI_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),\n'
    '\t\t\tDMI_MATCH(DMI_PRODUCT_NAME, "Surface Pro 9"),\n'
    '\t\t},\n'
    '\t\t.driver_data = "OVTI5693",\n'
    '\t},\n'
    '\t{\n'
    '\t\t.matches = {\n'
    '\t\t\tDMI_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),\n'
    '\t\t\tDMI_MATCH(DMI_PRODUCT_NAME, "Surface Pro 9"),\n'
    '\t\t},\n'
    '\t\t.driver_data = "OVTID858",\n'
    '\t},\n'
    # --- 3. наш вклад: задняя камера Surface Pro 8 -------------------------
    '\t/*\n'
    '\t * Surface Pro 8: задний модуль ov13858 (OVTID858) стоит вверх ногами,\n'
    '\t * SSDB сообщает 0. Подтверждено визуально на живой машине 30.08.2026.\n'
    '\t * Работает только вместе с обходом всей таблицы ниже: запись\n'
    '\t * Surface Pro 8 выше уже занята фронтальным INT33BE, а\n'
    '\t * dmi_first_match() вернул бы именно её.\n'
    '\t */\n'
    '\t{\n'
    '\t\t.matches = {\n'
    '\t\t\tDMI_MATCH(DMI_SYS_VENDOR, "Microsoft Corporation"),\n'
    '\t\t\tDMI_MATCH(DMI_PRODUCT_NAME, "Surface Pro 8"),\n'
    '\t\t},\n'
    '\t\t.driver_data = "OVTID858",\n'
    '\t},\n',
    "записи квирка поворота", after=False)

# --- 4. правка из PR #2227: перебирать всю таблицу, а не первое совпадение --
OLD = """	const struct dmi_system_id *dmi_id;

	dmi_id = dmi_first_match(upside_down_sensor_dmi_ids);
	if (dmi_id && acpi_dev_hid_match(adev, dmi_id->driver_data))
		return 180;
"""
NEW = """	const struct dmi_system_id *dmi_id;

	/*
	 * У одной модели ноутбука может быть несколько перевёрнутых сенсоров
	 * с разными HID (Surface Pro 8/9: фронтальный и задний). Через
	 * dmi_first_match() это невыразимо — он вернёт только первую запись,
	 * поэтому проверяем каждую запись таблицы отдельно.
	 */
	for (dmi_id = upside_down_sensor_dmi_ids; dmi_id->matches[0].slot;
	     dmi_id++) {
		struct dmi_system_id one[2] = {};

		one[0] = *dmi_id;
		if (!dmi_check_system(one))
			continue;
		if (acpi_dev_hid_match(adev, dmi_id->driver_data))
			return 180;
	}
"""
if src.count(OLD) != 1:
    sys.exit("ОШИБКА: не нашёл тело ipu_bridge_parse_rotation в ожидаемом виде")
src = src.replace(OLD, NEW)

sys.stdout.write(src)
sys.stderr.write("готово: все четыре правки применены\n")
