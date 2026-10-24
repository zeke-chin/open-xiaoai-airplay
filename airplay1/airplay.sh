#!/bin/sh
# 小爱音箱 AirPlay 1 接收端
#
# 守护运行 shairport-sync，异常退出后自动重启。只依赖局域网，不需要外网。
# 开机自启：将同目录下的 init.sh 放到 /data/init.sh

DIR=/data/airplay
BIN="$DIR/shairport-sync"
CONF="$DIR/shairport-sync.conf"
LOG=/tmp/airplay.log
PIDFILE=/tmp/airplay.pid

# 避免重复启动多个守护进程
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "AirPlay 已在运行（pid $(cat "$PIDFILE")）"
    exit 0
fi
echo $$ > "$PIDFILE"

# 等待系统 mDNS 服务就绪
while ! ps | grep -v grep | grep -q /usr/bin/mdnsd; do
    sleep 2
done

while true; do
    "$BIN" -c "$CONF" > "$LOG" 2>&1
    sleep 5
done
