# Сборка тройки модулей IPU6 вне дерева ядра.
#
# Зачем все три, если правка нужна только в ipu-bridge: intel_ipu6 линкуется с
# его экспортируемыми символами (ipu_bridge_init, ipu_bridge_parse_ssdb), и при
# включённом CONFIG_MODVERSIONS сборка одного лишь ipu-bridge даёт другие
# контрольные суммы — ядро отвергает модуль с "disagrees about version of
# symbol ipu_bridge_init". Собранные вместе, три модуля согласованы между
# собой, а наружу смотрят только в ядро, чьи суммы не менялись.
obj-m += ipu-bridge.o
obj-m += intel-ipu6.o
obj-m += intel-ipu6-isys.o

intel-ipu6-y := ipu6.o ipu6-bus.o ipu6-dma.o ipu6-mmu.o \
                ipu6-buttress.o ipu6-cpd.o ipu6-fw-com.o

intel-ipu6-isys-y := ipu6-isys.o ipu6-isys-csi2.o ipu6-fw-isys.o \
                     ipu6-isys-video.o ipu6-isys-queue.o ipu6-isys-subdev.o \
                     ipu6-isys-mcd-phy.o ipu6-isys-jsl-phy.o ipu6-isys-dwc-phy.o
