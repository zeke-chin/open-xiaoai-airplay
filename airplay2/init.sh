#!/bin/sh
# 开机自启（放到 /data/init.sh）：只启动 AirPlay，只依赖局域网

[ -x /data/airplay/airplay.sh ] && /data/airplay/airplay.sh > /dev/null 2>&1 &
