# Surface Pro 8 cameras on Linux

All three cameras of the Microsoft Surface Pro 8 working on mainline Linux:
front (OV5693), rear (OV13858) and the infrared Windows Hello camera
(ST VD55G0). Tested on Ubuntu 26.04 with kernels 6.19.8-surface-3 and
7.2.2-surface-1.

| camera | sensor | ACPI id | CSI-2 port | status |
|---|---|---|---|---|
| front | OV5693 | `INT33BE` | csi2-4 | works, 1296x972 binned |
| rear | OV13858 | `OVTID858` | csi2-1 | works, up to 4224x3136 |
| infrared | VD55G0 | `SMO55F0` | csi2-5 | works, 644x604 mono, ~31 fps with illumination |

The IPU6 is supported in mainline as ISYS only: it delivers raw Bayer and
there is no hardware ISP, so all processing happens in libcamera's CPU
software ISP.

## The short version of what was hard

**The IR camera needs an unpacked pixel format.** This is the single
non-obvious thing that cost the most time. Asking the capture node for
`Y10P` (MIPI packed) gets you exactly one frame-start short packet and
then silence — no data, and no CSI-2 errors either, which makes it look
like the sensor is dead. Asking for `Y10 ` (unpacked) just works, at
50 fps with zero errors. (We then deliberately run it slower — see the
illuminator section of `docs/FACE-AUTH.md`.)

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
docs/              detailed engineering notes
```

If you are on kernel 7.x, read `docs/KERNEL-7x.md` first. Everything works
there, but four things change on the way from 6.19 — a signing key that
cannot sign a kernel, `/dev/videoN` numbers that move, a changed LED
structure in int3472, and one package that looks redundant and is not.

`docs/NOTES.ru.md` and `docs/NOTES-ir.ru.md` are the full lab notebooks in
Russian. They are much more detailed than this README, including every
hypothesis that turned out to be wrong and how it was excluded. If you are
debugging something similar and can read Russian, start there.

## What you need that is not here

Two things are deliberately absent because they are not ours to
redistribute:

* **Intel factory calibration blobs** (`*.aiqb`). The colour correction
  matrices and the white balance curve in `tuning/` are derived from
  these. They are per-module calibration measured on one specific camera,
  so ours are not right for your unit anyway. `docs/CALIBRATION.md` has
  exact commands to pull your own out of Microsoft's driver package —
  it takes a download and about five minutes, and needs no Windows
  installation.
* **VD55G0 firmware patch.** Get it from
  [petm5/vd55g-firmware](https://github.com/petm5/vd55g-firmware) and put
  it in `/lib/firmware`. Without it the sensor comes up in a reduced mode.

## Install

Read `docs/INSTALL.md`. Short form: each `driver-*` directory is a DKMS
package, the libcamera patches need a rebuild of the distribution package,
and the tuning files go into `/usr/share/libcamera/ipa/simple/`.

## Face authentication

Once the IR camera works, Windows-Hello-style login takes about ten
minutes. Use [**visage**](https://github.com/sovren-software/visage) — a
Rust daemon plus PAM module, actively developed, whose capture path
speaks plain V4L2 in GREY/YUYV/Y16, which is exactly what the bridge
here produces.

Not Howdy. Howdy is the better known project, but its newest release is
v2.6.1 from September 2020, its `master` branch rewrite has never been
released, and its installer both violates PEP 668 and cannot find a
`v4l2loopback` device in the first place. `docs/FACE-AUTH.md` has the
detail if you want it.

Note that visage describes itself as *not yet suitable for production
use*. Its PAM integration is fail-safe, though — see below.

### Install

```sh
curl -LO https://github.com/sovren-software/visage/releases/download/v0.4.0-rc.1/visage_0.4.0.rc.1-1_amd64.deb
sudo apt install ./visage_0.4.0.rc.1-1_amd64.deb

# ONNX models, about 180 MB. The download is flaky — if it stops partway,
# just run it again; it resumes per file and verifies checksums.
sudo visage setup
```

### Configure

visage has no GUI and no config file: everything is environment variables
on the daemon. These three are what this hardware needs.

```sh
sudo mkdir -p /etc/systemd/system/visaged.service.d
sudo tee /etc/systemd/system/visaged.service.d/surface.conf <<'EOF'
[Service]
# The udev symlink, not /dev/videoN — the loopback node number moves
# between boots depending on module load order.
Environment=VISAGE_CAMERA_DEVICE=/dev/surface-ir-camera

# visage drives IR emitters through a UVC extension unit. This camera is
# not UVC, it sits behind the IPU6, and its illuminator is handled by
# ir-setup.sh instead. Stop visage trying.
Environment=VISAGE_EMITTER_ENABLED=0

# Anti-spoofing: visage looks for face displacement between frames, since
# a living person is never perfectly still and a photograph is. Without
# this an infrared photograph of your face would in principle pass — an
# ordinary phone photo would not, there is no IR in it.
Environment=VISAGE_LIVENESS_ENABLED=1

# Liveness looks at how far the face moves between frames. Three frames at
# ~31 fps is about 100 ms, and someone sitting still in front of a login
# screen does not move that much — measured here, a correctly recognised
# face was refused on displacement 0.25 against a threshold of 0.8. More
# frames give natural movement time to happen; the check itself is no less
# strict.
Environment=VISAGE_FRAMES_PER_VERIFY=6
EOF
```

`visaged` also has to wait for the IR loopback to have a producer. The device
node exists from the moment `v4l2loopback` loads, but `VIDIOC_G_FMT` on it
returns EINVAL until the bridge has fed it a frame — and at boot `visaged`
otherwise wins that race, dies with `streaming not supported`, and the first
request from the GDM login screen comes back as

    failed to query current format: Invalid argument (os error 22)

`After=` alone does not fix it: for a `Type=simple` unit that only means the
process was executed, not that the format exists. Wait for the device:

```sh
sudo install -m 755 tools/surface-ir-wait.sh /usr/local/lib/

sudo tee /etc/systemd/system/visaged.service.d/wait-for-camera.conf <<'EOF'
[Unit]
After=surface-ir-camera.service
Wants=surface-ir-camera.service

[Service]
ExecStartPre=/usr/local/lib/surface-ir-wait.sh /dev/surface-ir-camera 30
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now visaged
```

### Enrol your face

Do this sitting in front of the camera, and enrol **two** models — one
plain and one for however else you often look. Recognition gets
noticeably more robust when you are not square-on to the screen.

```sh
sudo visage enroll -l normal
sudo visage enroll -l glasses      # or: beard, hat, headphones, evening
sudo visage list
```

### Check it

```sh
sudo visage status                                  # daemon, camera, model count
sudo visage test -d /dev/surface-ir-camera -n 15    # frames and brightness
sudo -k && sudo true                                # should let you in by face
```

Measured here, three consecutive attempts: similarity 0.68, 0.81 and 0.72
against a threshold of 0.40, about 1.2 seconds each.

`visage test` writes the captured frames to `/tmp/visage-test` as PGM
files. Look at them if something seems wrong, then delete them — they are
pictures of your face.

### It cannot lock you out

The PAM profile visage installs runs before `pam_unix` as:

```
[success=done default=ignore]    pam_visage.so
```

On success authentication completes. On **anything** else — no face, no
camera, daemon stopped, liveness check failed, timeout — the result is
`ignore` and PAM falls through to the password prompt. It adds a way in;
it does not remove one. Verify that yourself after installing:

```sh
grep -v '^#' /etc/pam.d/common-auth
sudo -k true          # must still accept your password
```

### If it starts refusing you

If it refuses you at the login screen but works for `sudo`, check the boot
race above first — `journalctl -b -u visaged` will show `streaming not
supported` if that is what happened.

If it refuses you intermittently everywhere, it is usually liveness rather
than recognition, and the journal says which: a refusal on `displacement`
is liveness, a refusal on `similarity` is the model. Raising
`VISAGE_FRAMES_PER_VERIFY` past the 6 above helps the first; re-enrolling
the model helps the second.

Watch what is actually happening with `sudo journalctl -u visaged -f`
while authenticating in another terminal. It logs similarity, displacement
and the reason for any refusal.

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
