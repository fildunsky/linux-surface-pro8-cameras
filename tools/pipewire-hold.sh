#!/bin/bash
# Отпустить и вернуть PipeWire, ничего не сломав.
#
#   ./pipewire-hold.sh stop     — освободить камеру
#   ./pipewire-hold.sh start    — вернуть звук и камеры
#   ./pipewire-hold.sh status
#
# ЗАЧЕМ. PipeWire держит /dev/video* открытыми, и пока он работает,
# intel_ipu6_isys не выгружается, а modprobe -r vd55g молча не срабатывает.
# Для любой работы с драйверами камеры его надо остановить.
#
# ГРАБЛЯ, СТОЯЩАЯ ДНЯ ОТЛАДКИ. Остановить одни только службы мало: сокеты
# поднимут их обратно при первом же обращении. Поэтому глушить приходится
# вместе с сокетами — а вот поднимать их обратно легко забыть, потому что
# камеры и так заработают, службы стартуют вручную. Забыл сокеты — и
# звук исчезает: пропадает бегунок громкости, приложения не находят
# микрофон и динамики. Причём не сразу, а когда службы в следующий раз
# остановятся и поднять их станет некому. Лечится только перезагрузкой,
# если не знать, в чём дело.
#
# Отсюда правило: гасить и поднимать ОДНИМ И ТЕМ ЖЕ списком.
set -u
UNITS="wireplumber pipewire pipewire-pulse pipewire.socket pipewire-pulse.socket"

case "${1:-status}" in
stop)
    systemctl --user stop $UNITS 2>/dev/null
    sleep 1
    if pgrep -x pipewire >/dev/null || pgrep -x wireplumber >/dev/null; then
        echo "PipeWire всё ещё жив, камеру освободить не удалось" >&2
        exit 1
    fi
    echo "PipeWire остановлен; не забудьте '$0 start'"
    ;;
start)
    # сокеты первыми: службы должны увидеть их уже на месте
    systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null
    systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null
    sleep 3
    ;&
status)
    for u in $UNITS; do
        printf "  %-24s %s\n" "$u" "$(systemctl --user is-active "$u" 2>/dev/null)"
    done
    # wpctl, а не pactl: pactl входит в pulseaudio-utils, которого может
    # не быть вовсе, и тогда пустой вывод легко принять за пропавший звук
    if command -v wpctl >/dev/null; then
        echo "  звук: $(wpctl status 2>/dev/null | grep -A2 'Sinks:' | grep -c '\.' ) выход(ов)"
    fi
    ;;
*)
    echo "Использование: $0 {stop|start|status}" >&2; exit 2;;
esac
