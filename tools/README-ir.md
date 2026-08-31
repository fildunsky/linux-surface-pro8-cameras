# IR camera tools

## One-shot capture

```sh
sudo ./ir-setup.sh              # configure the media graph and format
sudo ./ir-grab.sh 10 /tmp/ir    # grab 10 frames, write PNGs
```

`ir-setup.sh` is where the important detail lives: the capture node format
must be `Y10 ` (unpacked), never `Y10P` (packed). See the repository
README for why.

## Always-available V4L2 device

`surface-ir-bridge` keeps a `v4l2loopback` node present at all times and
powers the sensor only while something has the node open. In idle it feeds
a black splash at 2 frames per second, which costs about 0.2% of one core.

This matters because the IR camera's privacy LED is wired to sensor power:
streaming continuously would leave the LED lit whenever the machine is on.

Install:

```sh
# add a third loopback node
sudo tee -a /etc/modprobe.d/v4l2-relayd.conf <<'EOF'
options v4l2loopback devices=3 exclusive_caps=1,1,1 max_buffers=4 \
        card_label="Surface Camera,Surface Camera Rear,Surface Camera IR"
EOF

sudo install -m755 surface-ir-bridge /usr/local/bin/
sudo install -m755 ir-setup.sh /usr/local/lib/surface-ir-setup.sh
sudo install -m644 surface-ir-camera.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now surface-ir-camera
```

The node is found by card label, not by number, because the number moves
between boots depending on whether v4l2loopback or the IPU6 driver loads
first. For the same reason, install the udev rule so that anything else
pointing at the IR camera has a stable path:

```sh
sudo install -m644 99-surface-ir-camera.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=video4linux
ls -l /dev/surface-ir-camera
```

Verify that the sensor really is powered down when idle:

```sh
cat /sys/class/regulator/regulator.*/name   # find the INT3472 one for I2C3
cat /sys/class/regulator/regulator.N/state  # 'disabled' when nobody looks
```

## Why not v4l2-relayd

v4l2-relayd builds its input as a GStreamer pipeline, and `v4l2src`
refuses to negotiate `Y10 `. Explicit `GRAY16_LE` caps do not help. So the
bridge pulls frames with `v4l2-ctl` and converts them with `ffmpeg`.

The ffmpeg input format must be `gray10le`, not `gray16le`: the data is
10-bit in 16-bit little-endian words, and treating it as 16-bit yields a
nearly black frame (mean 0.4 out of 255). The line stride is 1344 bytes
against 644*2 = 1288 bytes of pixels, so read 672 pixels wide and crop.

## Freeing the camera without breaking your sound

PipeWire holds `/dev/video*` open, so while it runs `intel_ipu6_isys`
will not unload and `modprobe -r vd55g` silently does nothing. Any driver
work needs it stopped.

Stopping the services alone is not enough — their sockets start them
again on the first access — so you have to stop the sockets too. And that
is the trap: it is easy to bring the services back and forget the
sockets, because the cameras start working again immediately and nothing
looks wrong. The sound breaks later, when the services next stop and
nothing is left to start them: the volume slider disappears and
applications stop finding the microphone and speakers. If you do not know
the cause it looks like it needs a reboot.

Use the helper so that the same list goes down and comes back up:

```sh
./pipewire-hold.sh stop      # free the camera
# ... driver work ...
./pipewire-hold.sh start     # sound and cameras back
./pipewire-hold.sh status
```

To recover a machine already in that state, without rebooting:

```sh
systemctl --user start pipewire.socket pipewire-pulse.socket
systemctl --user start pipewire pipewire-pulse wireplumber
```

Check with `wpctl status`, not `pactl` — `pactl` lives in
`pulseaudio-utils`, which may not be installed at all, and its empty
output is very easy to misread as "the sound devices are gone".

## Measurement helpers

* `ir-probe.sh [module params]` — one clean probe of the IR camera from a
  known state, printing SOF/EOF/data counts. Reads its own comment header
  for the three traps that make such measurements lie.
* `win-regtable.py` — decode the sensor register table embedded in the
  Windows driver.
* `i2c-reg.py` — read and write sensor registers over I2C without
  i2c-tools.
