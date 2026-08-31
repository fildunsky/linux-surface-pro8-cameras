# Face authentication with the IR camera

Once the IR camera works, Windows-Hello-style login is a matter of pointing
a PAM module at it. This is what worked here, and what did not.

## Use visage, not Howdy

[Howdy](https://github.com/boltgolt/howdy) is the well known project, but
as of August 2026 its newest release is **v2.6.1 from September 2020**.
Its `master` branch is a rewrite (Meson, C++ PAM module) that was merged
in June 2025 and has had no commits since and no release ever. The PPA
only carries 2.6.1 for every Ubuntu series up to 25.10, with nothing for
26.04; the single attempt to build 3.0.0 there failed.

Two concrete blockers if you try the packaged 2.6.1 on a current distro:

* its installer walks `/dev/v4l/by-path` asking "did your IR emitters turn
  on?" for each device. A `v4l2loopback` node does not appear there at
  all, so the picker never finds the camera and aborts;
* its postinst runs `pip install` into the system Python, which PEP 668
  forbids, and then compiles dlib 19.16 from source.

Both are surmountable — you can repackage with a preinst that writes the
device choice directly, and `dlib-bin` on PyPI does have a `cp314`
manylinux wheel so no compilation is needed — but at that point you are
maintaining a fork of a six-year-old package.

[visage](https://github.com/sovren-software/visage) is a Rust
reimplementation with a daemon and a PAM module, actively developed, and
its capture path speaks plain V4L2 in GREY/YUYV/Y16 — which is exactly
what our bridge produces. It ships a `.deb`.

Be aware that visage describes itself as *not yet suitable for production
use*. Judge that for yourself; the PAM integration is at least fail-safe,
see below.

## Installing

```sh
# .deb from the latest release (0.4.0-rc.1 at time of writing)
curl -LO https://github.com/sovren-software/visage/releases/download/v0.4.0-rc.1/visage_0.4.0.rc.1-1_amd64.deb
sudo apt install ./visage_0.4.0.rc.1-1_amd64.deb

# ONNX models, about 180 MB. The download is flaky; just run it again if
# it fails partway, it resumes per file and verifies checksums.
sudo visage setup
```

Point it at the IR camera and stop it trying to drive an IR emitter it
cannot reach:

```sh
sudo mkdir -p /etc/systemd/system/visaged.service.d
sudo cp tools/visage-surface.conf /etc/systemd/system/visaged.service.d/surface.conf
sudo systemctl daemon-reload
sudo systemctl enable --now visaged
```

The two settings in that file are `VISAGE_CAMERA_DEVICE`, pointed at the
udev symlink rather than a `/dev/videoN` number that moves between boots,
and `VISAGE_EMITTER_ENABLED=0`, because visage drives IR emitters through
a UVC extension unit and this camera is not UVC — it sits behind the IPU6.

## Checking before you trust it

```sh
sudo visage discover                                   # camera listed?
sudo visage test -d /dev/surface-ir-camera -n 15       # frames and brightness
sudo visage status                                     # daemon, camera, model count
```

`visage test` writes the captured frames to `/tmp/visage-test` as PGM
files. Look at them, then delete them — they are pictures of your face.

Note that `visage test` defaults to `/dev/video2` and ignores the
environment variable the daemon uses, so pass `-d` explicitly.

## Enrolling

This has to be done by the person being enrolled, sitting in front of the
camera:

```sh
sudo visage enroll -l normal
sudo visage enroll -l glasses     # a second angle or appearance helps
sudo visage list
```

## Is it safe for login?

The PAM profile visage installs is:

```
Auth-Type: Primary
Auth:
        [success=done default=ignore]    pam_visage.so
```

at priority 900, so it runs before `pam_unix`. On success authentication
completes; on **anything** else — no face, no camera, daemon down, timeout
— the result is `ignore` and PAM falls through to the password prompt. It
adds a way in, it does not remove one.

Verify that for yourself after installing, and keep a root shell open the
first time:

```sh
grep -v '^#' /etc/pam.d/common-auth
sudo -k true          # must still accept your password
```

## The IR illuminator

Without it, face authentication does not work in a room lit by LED lamps.
They emit almost no infrared, unlike sunlight or incandescent bulbs, so
the sensor sees essentially nothing: exposure pinned at its maximum
(1796 of 1796), digital gain at 8x, and still a mean brightness of about
16 out of 255. In daylight the same camera produces a perfectly good
picture, which makes this easy to misdiagnose.

The illuminator hangs off sensor GPIO 1 in strobe mode. The driver
already knows this — `ext_leds_mask` defaults to that pin — it just needs
enabling through the `led_mode` control:

```sh
v4l2-ctl -d /dev/v4l-subdevN --set-ctrl=led_mode=1
```

Measured, twice: mean brightness 16 with it off, 86 with it on.

**It must be set before the stream starts.** The sensor latches its GPIO
configuration at stream start, and the same control set on an already
running stream changes nothing — which is a confusing way to lose an
hour. `tools/ir-setup.sh` sets it in the right place, so anything going
through that script gets illumination for free.

