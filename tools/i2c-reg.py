#!/usr/bin/env python3
"""Чтение и запись регистров сенсора по I2C напрямую, без i2c-tools.

Регистры OV адресуются 16 битами, значения 8-битные.
Нужен доступ к /dev/i2c-N (обычно root) и загруженный модуль i2c-dev.
Сенсор отвечает только когда запитан, то есть во время съёмки.

    ./i2c-reg.py 3 0x10 0x3820          # прочитать
    ./i2c-reg.py 3 0x10 0x3820 0xb0     # записать
"""
import ctypes, fcntl, sys

I2C_RDWR = 0x0707

class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]

class i2c_rdwr_ioctl_data(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]

def xfer(fd, msgs):
    arr = (i2c_msg * len(msgs))(*msgs)
    data = i2c_rdwr_ioctl_data(msgs=arr, nmsgs=len(msgs))
    fcntl.ioctl(fd, I2C_RDWR, data)

def read_reg(bus, addr, reg):
    with open(f"/dev/i2c-{bus}", "r+b", buffering=0) as f:
        wbuf = (ctypes.c_uint8 * 2)(reg >> 8, reg & 0xFF)
        rbuf = (ctypes.c_uint8 * 1)()
        xfer(f.fileno(), [
            i2c_msg(addr=addr, flags=0, len=2, buf=wbuf),
            i2c_msg(addr=addr, flags=1, len=1, buf=rbuf),   # flags=1 -> чтение
        ])
        return rbuf[0]

def write_reg(bus, addr, reg, val):
    with open(f"/dev/i2c-{bus}", "r+b", buffering=0) as f:
        wbuf = (ctypes.c_uint8 * 3)(reg >> 8, reg & 0xFF, val)
        xfer(f.fileno(), [i2c_msg(addr=addr, flags=0, len=3, buf=wbuf)])

if __name__ == "__main__":
    bus = int(sys.argv[1]); addr = int(sys.argv[2], 0); reg = int(sys.argv[3], 0)
    if len(sys.argv) > 4:
        write_reg(bus, addr, reg, int(sys.argv[4], 0))
        print(f"0x{reg:04x} <- 0x{int(sys.argv[4],0):02x}, перечитано: 0x{read_reg(bus,addr,reg):02x}")
    else:
        print(f"0x{reg:04x} = 0x{read_reg(bus, addr, reg):02x}")
