# Running these cameras on kernel 7.x

Everything here also works on mainline 7.x. This page records the four things
that broke on the way from 6.19 to 7.2, because none of them announce
themselves clearly and three of them look like camera bugs when they are not.

Tested on Ubuntu 26.04 with a self-built `7.2.2-surface-1`: vanilla 7.2.2 plus
the linux-surface patch series, all three cameras, touch, pen and face
authentication working.

## Getting a 7.x kernel at all

linux-surface has no `patches/7.2` directory. It has 6.18 and 6.19 in `master`
and a 7.1 series in the open pull request
[#2178](https://github.com/linux-surface/linux-surface/pull/2178).

That 7.1 series applies to 7.2.2 almost unchanged. Applied in order with
`git am --3way`, fourteen of the fifteen patches land with no conflict at all.
The fifteenth, `0011-surface-shutdown.patch`, needs three lines of fuzz: in
`include/linux/pci.h` the comment on the neighbouring `non_mappable_bars` field
was reworded from "BARs can't be mapped to user-space" to "by CPU or peers".
The code it patches did not change.

For the config, Ubuntu's own shipped `/boot/config-7.0.0-30-generic` works as
the base, merged with `pkg/debian/kernel/ubuntu.config` and
`configs/surface-7.1.config` from the linux-surface tree.

`CONFIG_RUST` will come out unset, and that is correct — `ubuntu.config` sets
`DEBUG_INFO_NONE`, without debug info there is no `GENDWARFKSYMS`, and with
`MODVERSIONS` on Kconfig then does not offer `RUST` at all. linux-surface's own
kernels are built the same way.

## 1. The DKMS signing key cannot sign a kernel

Symptom: `error: bad shim lock signature` at boot, and then
`error: you need to load the kernel first`.

The key Ubuntu generates for DKMS at `/var/lib/shim-signed/mok/` carries an
extra OID in its Extended Key Usage:

```
X509v3 Extended Key Usage:
    Code Signing, 1.3.6.1.4.1.2312.16.1.2
```

That OID means *module signing only*. Modules signed with it load fine; shim
refuses to use it to verify a bootable image.

The trap is that `sbverify` does not warn you:

```
$ sbverify --cert /var/lib/shim-signed/mok/MOK.der vmlinuz-7.2.2-surface-1
Signature verification OK        # and it still will not boot
```

`sbverify` answers "does this signature match this certificate", not "will shim
accept this image". Generate a separate key with `extendedKeyUsage = codeSigning`
and nothing else, sign with that, and enrol it with `mokutil --import`. Leave the
DKMS key alone — it still signs modules. An image can carry both signatures.

## 2. `/dev/videoN` numbering moves between kernels

Symptom: the IR camera returns black frames. Power, illuminator, media graph and
sensor controls all check out.

The capture node number depends on how many `v4l2loopback` devices registered
before the `ipu6` driver, and that ordering is not stable across kernels. The
same entity moved by one:

```
6.19:  Intel IPU6 ISYS Capture 40  ->  /dev/video42
7.2:   Intel IPU6 ISYS Capture 40  ->  /dev/video43
```

Entity names are stable, device numbers are not. Ask for the number instead of
assuming it:

```sh
VIDEO=$(media-ctl -d /dev/media0 -e "Intel IPU6 ISYS Capture 40")
```

The tools here do this now. `IR_CAPTURE` and `VIDEO` still override it.

## 3. int3472's LED structure changed in 7.1

Symptom: the white privacy LED stops lighting for every camera, while the IR
illuminator still works.

Mainline 7.1 turned the single `pled` field of `struct int3472_discrete_device`
into an array with a counter, and changed the functions:

```c
skl_int3472_register_pled(int3472, gpio)
        -> skl_int3472_register_led(int3472, gpio, con_id)
skl_int3472_unregister_pled -> skl_int3472_unregister_leds
```

If you carry int3472 out of tree, note that this also moves where the LED's name
comes from. The old `led.c` hardcoded `"privacy"` in the lookup and ignored
`con_id`; the new one passes `con_id` straight through into both the LED name and
the lookup. Upstream 6.19's `discrete.c` sets `*con_id = "privacy-led"`, and
upstream changed it to `"privacy"` in the same commit that changed the struct.

Take one without the other and the LED registers under a name the kernel never
looks for:

```
SMO55F0_00::privacy-led_led      registered
                  v4l2-subdev.c: led_get(sd->dev, "privacy")
```

`tools/rebuild-int3472.sh` now emits a `led.c` carrying both implementations
under `#ifdef INT3472_MAX_LEDS` — that macro exists only in 7.1 and later
headers — so one source builds for both.

## 4. int3472 is still needed on 7.x

Mainline 7.0 added `INT3472_GPIO_TYPE_DOVDD = 0x10` and registers a `dovdd`
regulator for it, which makes it look as though the local int3472 package has
become redundant. It has not.

The value of the package is the per-HID supply naming for the IR sensor, which
mainline does not have:

```
SMO55F0: 0x12 HANDSHAKE     -> vcore   (absent on the Pro 8)
SMO55F0: 0x10 DOVDD         -> vddio
SMO55F0: 0x0b POWER_ENABLE  -> vana
```

Both mainline's `vd55g1` and the VD55G0 driver used here request exactly
`vcore`, `vddio` and `vana` (`drivers/media/i2c/vd55g1.c`). Mainline's int3472
offers `avdd`, `dovdd` and `dvdd`. None of those match, so without the mapping
the sensor gets dummy regulators, the rail is never driven, and the first I2C
access fails with -121.

The binding really is by name, and you can watch it:

```
before capture:  INT3472:02-vddio  state=disabled  num_users=0
during capture:  INT3472:02-vddio  state=enabled   num_users=1
```

Note also that different sensors want different names for the same job — on the
Pro 8, `ov5693` asks for `dovdd` while the ST sensor asks for `vddio` — so a
single global con_id for a GPIO type cannot serve both.
