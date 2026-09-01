# Installing

Tested on Ubuntu 26.04, kernel 6.19.8-surface-3, with the linux-surface
kernel already in place. Secure Boot is fine: DKMS signs modules with your
enrolled MOK.

Nothing here is a one-click installer on purpose. Each piece is
independent, and you probably do not want all of them.

## 1. Kernel drivers

Each `driver-*` directory is a DKMS package. Install the ones you need:

```sh
sudo cp -r driver-ov5693  /usr/src/ov5693-1.1-surface-ipu6
sudo dkms install ov5693/1.1-surface-ipu6
```

and likewise for `driver-ov13858` and `driver-ipu6`.

`driver-ipu6` builds `ipu-bridge` alone. It used to rebuild `intel-ipu6`
and `intel-ipu6-isys` alongside it, on the belief that a single-module
out-of-tree build changes the exported checksums under
`CONFIG_MODVERSIONS`. It does not. Measured on 7.2.2, building the bridge
by itself exports exactly the stock CRCs — `ipu_bridge_init 0xbb0996a9`,
`ipu_bridge_instantiate_vcm 0xe53dbf61`, `ipu_bridge_parse_ssdb
0x8730390b` — because only the `.c` file changes and the signatures live
in `include/media/ipu-bridge.h`.

The neighbours need rebuilding only when that header itself changes, as in
the v4 series on linux-media which grows `struct ipu_sensor`. Then
`intel-ipu6` goes with the bridge. `intel-ipu6-isys` does not even then:
it imports only `ipu_bridge_instantiate_vcm`, whose CRC does not move.

`intel_ipu6` cannot be unloaded on a live system, so changes to
`driver-ipu6` only take effect after a reboot. Swapping the bridge module
on a running system does not work either, and it fails in a way that looks
like your own patch broke something: `ipu_bridge_init()` returns early
when the fwnode graph is already present, and the `set_secondary_fwnode()`
it did on the IPU6 PCI device survives module removal. On reload the
bridge creates nothing — no `Found supported sensor` lines at all — while
the sensor drivers probe against the leftovers and read nonsense link
frequencies. Reboot between builds.

For the IR sensor use [linux-surface/kernel#169](https://github.com/linux-surface/kernel/pull/169)
directly rather than anything here, and put the firmware from
[petm5/vd55g-firmware](https://github.com/petm5/vd55g-firmware) into
`/lib/firmware`.

## 2. libcamera

The patches in `patches/libcamera/` apply to libcamera 0.7.0. Order in
`debian/patches/series` matters — later patches build on earlier ones:

```
softisp-agc-proportional.patch
softisp-fix-black-level-order.patch
softisp-split-awb-from-ccm.patch
softisp-awb-use-libipa-bayes.patch
softisp-stats-sums-to-8bit.patch
softisp-agc-gain-floor.patch
```

On Ubuntu, `deb-src` is disabled by default, so enable it first:

```sh
sudo tee /etc/apt/sources.list.d/libcamera-src.sources <<'EOF'
Types: deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: resolute resolute-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
sudo apt-get update
apt-get source libcamera
sudo apt-get build-dep -y libcamera

cd libcamera-0.7.0
cp ../../patches/libcamera/softisp-*.patch debian/patches/
# append the six names above to debian/patches/series, in that order
dpkg-buildpackage -b -uc -us -j"$(nproc)"

cd ..
sudo dpkg -i libcamera0.7_*_amd64.deb libcamera-ipa_*_amd64.deb \
             gstreamer1.0-libcamera_*_amd64.deb
sudo apt-mark hold libcamera0.7 libcamera-ipa gstreamer1.0-libcamera
```

Three things that will bite you:

* `libcamera0.7` and `libcamera-ipa` must be installed **together**. IPA
  modules are signed with a key generated at build time and libcamera
  verifies the signature, so a mismatched pair silently refuses to load.
* `apt-mark hold` is not optional. The next distribution update will
  otherwise replace your build and bring all the defects back.
* Install the dma-buf rule below, or the camera will be missing from
  applications after most boots.

```sh
sudo install -m644 tools/70-dma-heap-video.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger -s dma_heap
```

The software ISP needs a dma-buf provider. The only one a normal user can
reach out of the box is `/dev/udmabuf`, and only through the logind
`uaccess` ACL, which is applied when the session becomes active and races
with the user's own PipeWire starting. Lose that race — which on this
machine happens on most boots — and libcamera prints

```
SoftwareIsp: Failed to create DmaBufAllocator object
SimplePipeline: Failed to create software ISP, disabling software debayering
```

once, then serves Bayer-only formats for the entire life of the process.
PipeWire's libcamera plugin cannot use raw Bayer, so both colour cameras
advertise zero formats and applications report that no camera is present.
The IR camera is unaffected because GRAY8 needs no debayering, which is
why face unlock keeps working while the Camera app finds nothing. The
`dma_heap` provider does not depend on a session, so the rule removes the
race entirely.

## 3. Tuning files

```sh
sudo cp tuning/*.yaml /usr/share/libcamera/ipa/simple/
```

These are derived from *our* camera modules' factory calibration. Colour
calibration is per-module, so for best results regenerate them from your
own device's `.aiqb` files with `tools/factory-tuning.py`.

## 4. V4L2 bridging for applications

Chrome, Zoom and most other applications speak V4L2 and cannot see
libcamera devices, so each camera is exposed through a `v4l2loopback`
node. See `relayd/README` for the colour cameras.

The IR camera does not go through v4l2-relayd, because GStreamer's
`v4l2src` cannot negotiate the `Y10 ` format and fails with
`not-negotiated (-4)`. It uses its own bridge instead — see
`tools/README-ir.md`.

## Checking that it worked

```sh
# all three cameras enumerated by libcamera
gst-launch-1.0 libcamerasrc ! fakesink 2>&1 | grep 'Adding camera'

# a frame from the IR camera
sudo tools/ir-grab.sh 5 /tmp/ir && xdg-open /tmp/ir/ir_001.png
```
