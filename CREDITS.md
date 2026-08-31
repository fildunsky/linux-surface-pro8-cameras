# Where this comes from

Most of the work here is other people's. This file says plainly which part
is whose, so that credit lands correctly and so that anyone can tell what
is already heading upstream from what is only carried locally.

## Taken from linux-surface, unmodified or nearly so

**IR sensor driver — [linux-surface/kernel#169](https://github.com/linux-surface/kernel/pull/169)**
by petm5 ("media: i2c: st-vd55g: Genericize driver and add VD55G0
support"). `vd55g.c` and `vd55g-fw.h` are used verbatim; nothing of ours is
in that driver. The firmware patch blobs come from
[petm5/vd55g-firmware](https://github.com/petm5/vd55g-firmware).

If you want VD55G0 support, use that pull request. This repository does
not improve on it — it only adds the userspace pieces around it.

**MIPI_CTRL00 write for OV5693 on IPU6 —
[linux-surface#2171](https://github.com/linux-surface/linux-surface/pull/2171)**.
Without writing register `0x4800` the IPU6 D-PHY never locks and the
sensor delivers nothing. The value `0x2d` was found by reverse
engineering the Windows driver. Note the discussion in that thread: two
people independently bit-swept the register on real hardware (including a
Surface Pro 8) and found that only bit 5 matters, so the eventual upstream
form may be `cci_update_bits()` on bit 5 rather than a full register write.
We carry `0x2d` as in the pull request.

**OV5693 binning on IPU6, INT3472 GPIO type mapping —
[linux-surface#2252](https://github.com/linux-surface/linux-surface/pull/2252)**.
Analogue 2x2 binning matters a lot for image quality: without it the front
camera reads out full resolution and the result is noisy and dark.

**Rear camera 180° rotation quirk —
[linux-surface#2227](https://github.com/linux-surface/linux-surface/pull/2227)**
and its kernel counterpart
[linux-surface/kernel#170](https://github.com/linux-surface/kernel/pull/170).

**v4l2-relayd bridging recipe** — from
[dmanresa-saes/surface-ipu6-cameras](https://github.com/dmanresa-saes/surface-ipu6-cameras).
The three non-obvious requirements in our relayd configuration
(`videorate skip-to-first`, an explicit caps filter to select the binned
sensor mode, and a live splash source) all come from there. That
repository is also the reference for turning Intel `.aiqb` calibration
into libcamera tuning, and its `ov5693.yaml` is worth reading before
writing your own.

**libcamera software ISP fixes** — backports of upstream libcamera
commits, see `patches/libcamera/`. Each patch header names the original
commit and author.

## What was worked out here

**The IR camera needs an unpacked pixel format.** `Y10P` yields exactly
one frame-start packet and no data; `Y10 ` works. Described in the README
and in `docs/NOTES-ir.ru.md`, including the full list of hypotheses that
were excluded on the way, and the two measurement techniques that found
it. As far as we can tell this is not written down anywhere else.

**A software ISP statistics unit bug in libcamera.** Channel sums are
accumulated in native sensor units while the black level subtracted from
them is 8-bit, so a 10-bit sensor gets a quarter of the intended
subtraction. Fixed in `patches/libcamera/softisp-stats-sums-to-8bit.patch`.
Present in current upstream too; needs reporting.

**Factory white balance instead of grey world.** libcamera's software ISP
AWB is plain grey world with no damping. The Intel calibration blob
contains the reference grey-card ratios per illuminant, which is exactly
the calibrated curve the libipa Bayesian AWB wants. Wiring those together
is `patches/libcamera/softisp-awb-use-libipa-bayes.patch` plus the
generator in `tools/factory-tuning.py`.

**On-demand IR bridge.** The IR camera has a privacy LED wired to sensor
power, so it must not stream when nobody is looking. `tools/` and the
systemd service keep the V4L2 device present at all times with a black
splash, and power the sensor only while a consumer has it open — the same
model v4l2-relayd uses for the colour cameras. Two details cost time and
are documented in the code: the v4l2loopback client-usage event type is
`0x10E00001`, not `V4L2_EVENT_PRIVATE_START + 1`; and `struct v4l2_event`
is 136 bytes with the client count at offset 8, because the union inside
it is 8-byte aligned.

## Still open

* Colour rendering does not match Windows yet. The factory calibration is
  in pedestal-included units, so applying the correct black level (which
  is very much wanted: it takes the darkest percentile from 63 to 0,
  contrast up 40%, saturation up 90%) breaks the colour matrices. Either
  the matrices need re-deriving, or the pedestal has to be applied after
  the matrix rather than before.
* No sharpening and no lens shading correction exist in libcamera's
  software ISP at all, so neither can be recovered from the factory
  calibration for now.
* The local sensor drivers for OV5693 and OV13858 have drifted from the
  linux-surface pull requests and should be brought back in line.
