#!/bin/sh
# 小爱音箱 AirPlay 接收端
#
# 守护运行 nqptp（AirPlay 2 时钟同步）和 shairport-sync，异常退出后自动重启。
# 只依赖局域网，不需要外网。
# 开机自启：将同目录下的 init.sh 放到 /data/init.sh

DIR=/data/airplay
# 调试时可指定其他配置：CONF=/tmp/sps-debug.conf /data/airplay/airplay.sh
CONF="${CONF:-$DIR/shairport-sync.conf}"
# AirPlay 就绪后播放的提示音（本地播放），置空则不播放。
# 默认使用同目录下的 ready.wav，可替换为任意 miplayer 支持的音频（wav / mp3 / opus）；
# ready.wav 不存在时使用系统自带的提示音
READY_SOUND="${READY_SOUND-$DIR/ready.wav}"
if [ -n "$READY_SOUND" ] && [ ! -f "$READY_SOUND" ]; then
    READY_SOUND=/usr/share/sound/bluetooth_connect.opus
fi
PIDFILE=/tmp/airplay.pid

# 避免重复启动多个守护进程
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "AirPlay 已在运行（pid $(cat "$PIDFILE")）"
    exit 0
fi
echo $$ > "$PIDFILE"

run_forever() { # run_forever <log> <cmd...>
    log=$1
    shift
    while true; do
        "$@" > "$log" 2>&1
        sleep 5
    done
}

# 等待 Wi-Fi 拿到 IP：开机时过早启动 nqptp / shairport-sync，
# nqptp 会一直锁定不了主时钟，投送能连上但没有声音
while ! ip -4 addr show wlan0 2>/dev/null | grep -q inet; do
    sleep 2
done
sleep 3

# 等待系统 mDNS 服务就绪
while ! ps | grep -v grep | grep -q /usr/bin/mdnsd; do
    sleep 2
done

# AirPlay 1 版本没有 nqptp
if [ -x "$DIR/nqptp" ]; then
    run_forever /tmp/nqptp.log "$DIR/nqptp" &
fi

run_forever /tmp/airplay.log "$DIR/shairport-sync" -c "$CONF" &

# 就绪检查：nqptp 在运行（AirPlay 2）、shairport-sync 在监听 7000（AirPlay 1 为 5000）、
# 小爱的 mediaplayer 服务已就绪，然后播放一次提示音
is_ready() {
    if [ -x "$DIR/nqptp" ]; then
        pidof nqptp > /dev/null || return 1
    fi
    netstat -lnt 2>/dev/null | grep -qE ':(7000|5000) ' || return 1
    ubus list mediaplayer > /dev/null 2>&1
}
while ! is_ready; do
    sleep 2
done
echo "AirPlay 已就绪"
if [ -n "$READY_SOUND" ] && [ -f "$READY_SOUND" ]; then
    miplayer --file "$READY_SOUND" > /dev/null 2>&1
fi

wait
