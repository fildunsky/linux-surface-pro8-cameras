#!/usr/bin/env python3
"""Бегунки для настройки картинки камер Surface Pro 8 вживую.

    ./camera-tune.py [front|rear]

Слева живое превью, справа ползунки. Всё применяется сразу, ничего никуда
не сохраняется, пока вы сами не нажмёте кнопку.

Здесь ровно три ручки, и это не лень — больше libcamera 0.7 не даёт.
Проверено замером на реальных кадрах: `brightness` и `sharpness` у
libcamerasrc есть как свойства, но софтовый ISP их игнорирует (значения
-0.6 и +0.6 дают одинаковую яркость, 2.0 не меняет резкость). Ручной
баланс белого тоже не работает: `awb-enable=false` с `colour-gains`
ничего не меняет, гейны <1.0,1.0> и <3.0,3.0> дают одинаковый кадр —
алгоритм Awb в `simple` не читает эти контролы вовсе, он только
сообщает свои гейны в метаданные. Мёртвые ползунки я убрал, чтобы вы не
тратили на них время.

Что действительно работает (adjust.cpp читает их в queueRequest):

  гамма         controls::Gamma,      0.1 .. 10
  контраст      controls::Contrast,   0 .. 2
  насыщенность  controls::Saturation, 0 .. 2

Это НЕ параметры файла тюнинга: `Adjust` из `tuningData` не берёт ничего.
Поэтому запекать их надо в строку запуска — свойствами `libcamerasrc` в
`VIDEOSRC` в /etc/v4l2-relayd.d/*.conf.

Кнопка «показать значения» печатает готовую строку в терминал.
"""
import sys
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst, Gtk  # noqa: E402

CAMERAS = {
    "front": ("\\_SB_.PC00.I2C2.CAMF", "фронтальная", 1280, 720),
    "rear": ("\\_SB_.PC00.I2C3.CAMR", "задняя", 1280, 720),
}

# имя свойства -> (подпись, минимум, максимум, по умолчанию, шаг)
KNOBS = [
    ("gamma",      "гамма",        0.1, 4.0, 2.2, 0.05),
    ("contrast",   "контраст",     0.0, 2.0, 1.0, 0.02),
    ("saturation", "насыщенность", 0.0, 2.0, 1.0, 0.02),
]


class Tuner(Gtk.Window):
    def __init__(self, which):
        name, human, w, h = CAMERAS[which]
        super().__init__(title=f"Настройка картинки — {human} камера")
        self.set_default_size(1180, 760)
        self.which = which
        self.values = {k: d for k, _, _, _, d in
                       ((k, lab, lo, hi, d) for k, lab, lo, hi, d, _ in KNOBS)}

        self.sink = Gst.ElementFactory.make("gtksink", "sink")
        self.src = Gst.ElementFactory.make("libcamerasrc", "src")
        self.src.set_property("camera-name", name)
        self.pipeline = Gst.Pipeline.new("tune")
        conv = Gst.ElementFactory.make("videoconvert", "conv")
        caps = Gst.ElementFactory.make("capsfilter", "caps")
        caps.set_property("caps", Gst.Caps.from_string(
            f"video/x-raw,width={w},height={h}"))
        for e in (self.src, caps, conv, self.sink):
            self.pipeline.add(e)
        self.src.link(caps)
        caps.link(conv)
        conv.link(self.sink)

        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        box.set_border_width(12)
        self.add(box)
        video = self.sink.props.widget
        video.set_size_request(760, 0)
        box.pack_start(video, True, True, 0)

        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        panel.set_size_request(360, 0)
        box.pack_start(panel, False, False, 0)

        self.scales = {}
        for key, label, lo, hi, default, step in KNOBS:
            panel.pack_start(self._row(key, label, lo, hi, default, step),
                             False, False, 0)

        panel.pack_start(Gtk.Separator(), False, False, 6)

        reset = Gtk.Button(label="вернуть значения по умолчанию")
        reset.connect("clicked", self.on_reset)
        panel.pack_start(reset, False, False, 0)

        show = Gtk.Button(label="показать значения")
        show.connect("clicked", self.on_show)
        panel.pack_start(show, False, False, 0)

        self.hint = Gtk.Label(xalign=0)
        self.hint.set_line_wrap(True)
        self.hint.set_markup(
            "<small>Крутите, пока не понравится, потом нажмите «показать "
            "значения» — строка появится в терминале. Пришлите её, и я "
            "запеку настройку, чтобы она применялась ко всем приложениям."
            "\n\nБаланса белого здесь нет намеренно: libcamera 0.7 не даёт "
            "задать его вручную. Зеленца лечится отдельно, заводскими "
            "гейнами из .aiqb.</small>")
        panel.pack_end(self.hint, False, False, 0)

        self.connect("destroy", self.on_quit)

    def _row(self, key, label, lo, hi, default, step):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        box.pack_start(Gtk.Label(label=label, xalign=0), False, False, 0)
        adj = Gtk.Adjustment(value=default, lower=lo, upper=hi,
                             step_increment=step, page_increment=step * 5)
        scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL,
                          adjustment=adj)
        scale.set_digits(2)
        scale.set_value_pos(Gtk.PositionType.RIGHT)
        scale.connect("value-changed", self.on_knob, key)
        self.scales[key] = scale
        box.pack_start(scale, False, False, 0)
        return box

    def on_knob(self, scale, key):
        self.values[key] = scale.get_value()
        try:
            self.src.set_property(key, self.values[key])
        except Exception as exc:            # свойства может не быть
            print(f"  {key}: не применилось ({exc})", flush=True)

    def on_reset(self, _button):
        for key, _, _, _, default, _ in KNOBS:
            self.scales[key].set_value(default)

    def on_show(self, _button):
        line = " ".join(f"{k}={self.values[k]:.2f}" for k, *_ in KNOBS)
        print("\n=== настройка (" + self.which + ") ===")
        print(line)
        print("=== пришлите эту строку ===\n", flush=True)
        self.hint.set_markup(
            "<small>Значения напечатаны в терминале:\n<tt>" +
            GLib.markup_escape_text(line) + "</tt></small>")

    def run(self):
        self.show_all()
        self.pipeline.set_state(Gst.State.PLAYING)
        Gtk.main()

    def on_quit(self, *_):
        self.pipeline.set_state(Gst.State.NULL)
        Gtk.main_quit()


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "front"
    if which not in CAMERAS:
        sys.exit(f"известны только: {', '.join(CAMERAS)}")
    Gst.init(None)
    Tuner(which).run()


if __name__ == "__main__":
    main()
