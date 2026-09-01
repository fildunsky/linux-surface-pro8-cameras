# Сборка ipu-bridge вне дерева ядра.
#
# Раньше здесь собирались три модуля — ipu-bridge, intel-ipu6 и
# intel-ipu6-isys, — потому что мы считали, что при CONFIG_MODVERSIONS сборка
# одного лишь моста даёт другие контрольные суммы. Это неверно. Проверено
# измерением на 7.2.2: одиночная сборка вне дерева экспортирует ровно
# стоковые суммы (0xbb0996a9 у ipu_bridge_init, 0xe53dbf61 у
# ipu_bridge_instantiate_vcm, 0x8730390b у ipu_bridge_parse_ssdb), потому что
# мы правим только .c, а сигнатуры живут в include/media/ipu-bridge.h.
#
# Пересобирать соседа нужно ровно тогда, когда меняется сам заголовок: он
# входит в тип аргумента ipu_bridge_init() и ipu_bridge_parse_ssdb(), и тогда
# с мостом идёт intel-ipu6. intel-ipu6-isys не нужен и в этом случае — он
# берёт из моста только ipu_bridge_instantiate_vcm, чья сумма от заголовка не
# зависит.
obj-m += ipu-bridge.o
