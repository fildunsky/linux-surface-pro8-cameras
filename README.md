# Surface Pro 8 cameras on Linux

All three cameras of the Microsoft Surface Pro 8 working on mainline Linux:
front (OV5693), rear (OV13858) and the infrared Windows Hello camera
(ST VD55G0). Tested on Ubuntu 26.04 with kernel 6.19.8-surface-3.

| camera | sensor | ACPI id | CSI-2 port | status |
|---|---|---|---|---|
| front | OV5693 | `INT33BE` | csi2-4 | works, 1296x972 binned |
| rear | OV13858 | `OVTID858` | csi2-1 | works, up to 4224x3136 |
| infrared | VD55G0 | `SMO55F0` | csi2-5 | works, 644x604 mono, 50 fps |

The IPU6 is supported in mainline as ISYS only: it delivers raw Bayer and
there is no hardware ISP, so all processing happens in libcamera's CPU
software ISP.

## The short version of what was hard

**The IR camera needs an unpacked pixel format.** This is the single
non-obvious thing that cost the most time. Asking the capture node for
`Y10P` (MIPI packed) gets you exactly one frame-start short packet and
then silence — no data, and no CSI-2 errors either, which makes it look
like the sensor is dead. Asking for `Y10 ` (unpacked) just works, at
50 fps with zero errors.

The mechanism is one line in `ipu6-isys-video.c`:

```c
input_pin->mipi_store_mode = pfmt->bpp == pfmt->bpp_packed ?
        IPU6_FW_ISYS_MIPI_STORE_MODE_DISCARD_LONG_HEADER : /* 1 */
        IPU6_FW_ISYS_MIPI_STORE_MODE_NORMAL;               /* 0 */
```

`Y10P` and `GREY` both have `bpp == bpp_packed`, so both select mode 1,
and mode 1 does not work on this port. `Y10 ` has bpp 16 against
bpp_packed 10, selects mode 0, and works.

Everything else about the sensor turned out to be a red herring. We
verified that by writing the *entire* register table extracted from the
Windows driver into the sensor verbatim, right before stream start:
behaviour did not change. Sensor configuration was never the problem.

Two techniques found the answer and are worth reusing on any similar
bring-up:

* **Read sensor registers while streaming.** A statistics register
  changing ~50 times a second proved the sensor was capturing frames
  continuously and only the transmission was broken. That immediately
  ruled out everything on the sensor side.
* **Run the same measurement against a camera you know works.** Counting
  `FRAME_SOF` on the working colour camera gave 96 in 20 seconds versus 1
  on the IR camera, which confirmed the counting method itself was sound,
  and diffing the `IPU6_FW_ISYS_STREAM_CFG_DATA` block between the two
  pointed straight at `mipi_store_mode`.

## Repository layout

```
driver-ov5693/     front sensor driver (DKMS)
driver-ov13858/    rear sensor driver (DKMS)
driver-ipu6/       ipu-bridge + ipu6 with the Surface Pro 8 entries (DKMS)
patches/libcamera/ patches against libcamera 0.7.0
tuning/            libcamera tuning files for the software ISP
relayd/            v4l2-relayd notes and patch
tools/             bring-up, measurement and tuning tools
docs/              detailed engineering notes (Russian)
```

`docs/NOTES.ru.md` and `docs/NOTES-ir.ru.md` are the full lab notebooks in
Russian. They are much more detailed than this README, including every
hypothesis that turned out to be wrong and how it was excluded. If you are
debugging something similar and can read Russian, start there.

## What you need that is not here

Two things are deliberately absent because they are not ours to
redistribute:

* **Intel factory calibration blobs** (`*.aiqb`). The colour correction
  matrices and the white balance curve in `tuning/` are derived from
  these. Extract your own from the Windows driver package for your device
  — they are per-module calibration, so ours are not strictly correct for
  your unit anyway.
* **VD55G0 firmware patch.** Get it from
  [petm5/vd55g-firmware](https://github.com/petm5/vd55g-firmware) and put
  it in `/lib/firmware`. Without it the sensor comes up in a reduced mode.

## Install

Read `docs/INSTALL.md`. Short form: each `driver-*` directory is a DKMS
package, the libcamera patches need a rebuild of the distribution package,
and the tuning files go into `/usr/share/libcamera/ipa/simple/`.

## Upstream status

Most of this belongs upstream and some of it already is. See
`CREDITS.md` for who did what, which pull requests this builds on, and
what is still carried locally. If you are looking for the "right" way to
support these cameras, follow the linux-surface pull requests listed
there rather than this repository.

## Licence

Kernel drivers and libcamera patches keep the licence of the code they
derive from (GPL-2.0 and LGPL-2.1-or-later respectively). Tools and
documentation are MIT.

## Where the discussion is happening

Findings from this repository have been posted to the relevant
linux-surface threads:

* [kernel#169](https://github.com/linux-surface/kernel/pull/169) — VD55G0
  driver; the unpacked-format finding
* [#2171](https://github.com/linux-surface/linux-surface/pull/2171) —
  MIPI_CTRL00; Pro 8 confirmation
* [#2252](https://github.com/linux-surface/linux-surface/pull/2252) —
  binning and INT3472 GPIO types
* [#2227](https://github.com/linux-surface/linux-surface/pull/2227) —
  rear camera rotation
* [#2166](https://github.com/linux-surface/linux-surface/issues/2166) —
  colour quality and the software ISP statistics bug
* [#2153](https://github.com/linux-surface/linux-surface/issues/2153) —
  IPU6 reverse engineering across Surface models
