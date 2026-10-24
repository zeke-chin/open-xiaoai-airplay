# 技术细节

本文记录在小爱音箱 Pro（OH2P，固件 1.58.6）上实现 AirPlay 的过程、设计取舍、调试方法和已知问题。

## 设备环境

| 项 | 情况 |
| --- | --- |
| 系统 | LEDE，内核 4.9 aarch64，**用户态 32 位 armhf，glibc 2.25** |
| CPU / 内存 | 4 核；247MB，可用约 160MB，无 swap |
| 存储 | rootfs 是只读 SquashFS 且已满，程序放在 `/data`（约 116MB 可用） |
| 开机入口 | 固件通过 `/etc/rc.local` 执行 `/data/init.sh` |
| mDNS | 系统 `mdnsd`（mDNSResponder），由 `/etc/init.d/central_lite` 拉起，被米家中枢 `central_lite` 使用 |
| ALSA | `default` → plug → vis(fifo) → copy → softvol(`mysoftvol`) → dmixer(`hw:0,2`, 48000Hz) |

其他型号请先确认用户态架构（`file /lib/libc-*.so` 或看 `/lib/ld-linux-armhf.so.3` 是否存在）、glibc 版本和 ALSA 配置（`/etc/asound.conf`）。

## AirPlay 1 与 AirPlay 2

| | AirPlay 1（`airplay1/`） | AirPlay 2（`airplay2/`） |
| --- | --- | --- |
| 音乐类 App（网易云等） | ✅ | ✅ |
| 视频 App（B 站等）、系统音频、游戏 | ❌ iOS 只发送全零静音数据 | ✅ |
| 进程 | shairport-sync | shairport-sync + nqptp |
| 端口 | TCP 5000，UDP 6001–6010，UDP 5353 | TCP 7000，UDP 319/320（nqptp），UDP 5353 |
| 二进制大小 | 约 1.3MB | 约 4.3MB + 22KB |
| 加密库 | mbed TLS | OpenSSL 3（AirPlay 2 配对代码直接调用 OpenSSL） |

视频 / 系统音频需要和画面同步，较新的 iOS 只通过 AirPlay 2 的机制发送；面对只支持 AirPlay 1 的接收端，连接能建立但发送的是静音。
抓取 shairport-sync 实际输出的 PCM 可以证实：B 站投送时每秒峰值都是 ±1（shairport 的 dither），网易云正常。

## 设计取舍

### 不影响小爱现有功能

- **声音输出**：输出到 ALSA `default`，经过 dmix 和小爱的声音混音，不独占声卡；`vis` fifo 链路也保持不变，播放中唤醒正常
- **音量**：不设置 `mixer_control_name`，AirPlay 音量只在 shairport-sync 内部衰减，不改动小爱的 `mysoftvol`
- **mDNS**：不重启、不替换系统 `mdnsd`（见[已知问题 1](#1-系统-mdnsd-的-socket-文件丢失)），改用 shairport-sync 内置的 tinysvcmdns，与 `mdnsd`、`micont_rtmapp` 通过 `SO_REUSEADDR` 共用 UDP 5353
- **只走局域网**：不需要外网，启动时不等待外网连通

### open-xiaoai client

如果 `/data/init.sh` 原来是 open-xiaoai client 的启动脚本，它会先 `ping baidu.com` 等待外网，再在**前台**运行 client，后面追加的命令永远执行不到。

client 的所有功能（唤醒词、指令、播放状态监听，录音转发，播放音频流，RPC）都要先连上 server 才会启动；server 下线时它只会每秒重连一次。
同时它提供 `run_shell` RPC，局域网中有人占用 `server.txt` 里的地址和端口就能以 root 身份执行任意命令。

测试设备上已经不再使用 open-xiaoai server，因此把 `/data/init.sh` 换成只启动 AirPlay（原文件备份为 `/data/init.sh.bak`），不需要重新编译 client。

### 启动流程（`airplay2/airplay.sh`）

1. 用 `/tmp/airplay.pid` 防止重复启动
2. 等 wlan0 拿到 IPv4 地址（开机过早启动会导致 nqptp 锁定不了时钟，见[已知问题 4](#4-开机后能连上但没有声音)）
3. 等系统 `mdnsd` 运行
4. 启动 nqptp、shairport-sync，各自异常退出后 5 秒自动重启（日志 `/tmp/nqptp.log`、`/tmp/airplay.log`）
5. nqptp 在运行、shairport-sync 在监听 7000、小爱的 `mediaplayer` 已就绪后，用 `miplayer` 播放一次提示音

## 编译

基于 open-xiaoai 的 `idootop/open-xiaoai-runtime:oh2p` 镜像（Linaro GCC 7.5 + 从固件提取的 sysroot），`build/Dockerfile` 在其上补装 autotools、patch、libplist-utils、xxd。
镜像 tag 取 Dockerfile 的哈希，Dockerfile 变化后自动重新构建。

- 固件 sysroot 只有 `.so`，没有 libc 头文件，编译使用 Linaro 工具链自带的 glibc 2.25（与设备一致），只在链接阶段引入固件的 `libasound`、`libdns_sd`、`libuuid`
- 其余依赖全部静态链接，版本见 [THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md)
- FFmpeg 只启用 alac、aac、pcm_s16be 解码器和 swresample，体积很小，44.1k → 48k 用 swresample 高质量重采样
- `-Wl,--as-needed` 去掉多余的 `libatomic`（设备上没有）和 `libstdc++`
- 依赖源码缓存在 `build/.build/dl`，编译好的静态库缓存在 `build/.build/prefix`，再次编译只重编 nqptp 和 shairport-sync
- 容器内下载失败（ffmpeg.org、gnupg.org 等在国内可能连不上）时，可以先在宿主机下载到 `build/.build/dl/`，文件名与 `build/scripts/build-in-docker.sh` 中 URL 的 basename 一致即可跳过下载

`build/patches/` 中的补丁在编译时应用到 shairport-sync 源码副本上：

| 补丁 | 作用 |
| --- | --- |
| `0001-tinysvcmdns-airplay2.patch` | 让内置的 tinysvcmdns 支持 AirPlay 2：额外注册 `_airplay._tcp`、使用运行时生成的 TXT 记录、实现 `mdns_update`；应答线程访问记录时加锁（递归锁，`populate_answers()` 内部也会加同一把锁）；TXT 字符串上限从 63 改为 255 字节（`pk=...` 超过 63 字节，原实现返回 NULL 导致段错误） |
| `0002-uuid-sha1-compat.patch` | 固件自带的 libuuid 太旧，没有 `uuid_generate_sha1()`，用 OpenSSL 实现（与上游 macOS 兼容实现一致） |

## 使用说明

### 初始音量

- shairport-sync 启动后第一次连接的音量是 `default_airplay_volume`（默认 -24 dB，即 iOS 上的 20%）
- 运行期间会记住最后一次设置的音量，之后的连接沿用；重启音箱后回到默认值
- 在 `shairport-sync.conf` 的 `general` 中设置 `default_airplay_volume`（-30 ~ 0，例如 -15 约为 50%）；音量曲线可用 `volume_control_profile`（`standard` / `flat` / `dasl_tapered`）调整

### 显示名称

`shairport-sync.conf` 的 `general.name`，修改后 `killall shairport-sync` 等待重新拉起。AirPlay 2 设备以 `deviceid`（MAC 地址）识别，iOS 一般会自动刷新名字；仍显示旧名字时在 iPhone / iPad 上关闭再打开 Wi-Fi。

### 就绪提示音

`airplay.sh` 中的 `READY_SOUND` 可替换为系统自带的其他声音（`/usr/share/sound/`，其他音色在 `/usr/share/sound-vendor/{XiaoMi,XiaoMi_male,XiaoMi_M88}/`）：

| 类型 | 文件 |
| --- | --- |
| 短提示音 | `bluetooth_connect.opus`（默认）、`bluetooth_disconnect.opus`、`mic_on.opus`、`mic_off.opus`、`hourly_chime.opus`、`prompt_power_connected.opus` |
| 唤醒应答 | `wakeup_zai_01.wav`、`wakeup_zai_02.wav`、`wakeup_wozai.wav`、`wakeup_ei_01.wav` |
| 语音提示 | `init_wifi_success.opus`、`first_voice.opus`、`tip_zaine.opus`、`tip_shuoba.opus` 等 |

也可以放自己的 mp3 / wav 到 `/data/airplay/`，由 `miplayer --file` 播放。

## 调试

### 查看运行状态

```bash
ps | grep -E 'airplay.sh|shairport|nqptp'
netstat -lntup | grep -E 'shairport|nqptp'   # AirPlay 2: TCP 7000 + UDP 5353；nqptp: UDP 319/320
cat /tmp/airplay.log /tmp/nqptp.log          # 守护脚本记录的输出（默认不带 -v）
amixer -c 0 cget name=mysoftvol              # 小爱自身音量，AirPlay 不应改动它
```

在局域网中的 Mac 上确认广播：

```bash
dns-sd -B _airplay._tcp local.               # 应能看到 小爱音箱
dns-sd -L 小爱音箱 _airplay._tcp local.
```

### 停止 / 重启服务

```bash
# 不要用 grep airplay.sh 去 kill：执行这条命令的 shell 命令行里也有 airplay.sh，会把自己杀掉
for p in $(ps | grep '[{]airplay.sh[}]' | awk '{print $1}'); do kill $p; done
killall shairport-sync nqptp; rm -f /tmp/airplay.pid
/data/airplay/airplay.sh > /dev/null 2>&1 &
```

重启 shairport-sync 时如果 iPad 正在投送，iPad 会卡在旧会话上没声音，需要在 iPad 上断开再重新选择。

### 详细日志 / 统计

```bash
cp /data/airplay/shairport-sync.conf /tmp/sps-debug.conf
echo 'diagnostics = { statistics = "yes"; log_verbosity = 1; };' >> /tmp/sps-debug.conf
# 按上面的方法停止服务后，用调试配置启动
CONF=/tmp/sps-debug.conf /data/airplay/airplay.sh > /dev/null 2>&1 &
```

- 统计行中 `Output FPS` 约等于 48000 说明在持续向声卡输出
- `Av Sync Error` 大、`Net Sync PPM` 高说明在大幅修正同步，可能产生杂音
- 出现 `XRUN` 说明声卡缓冲欠载

### 检查 nqptp 是否锁定时钟

`/dev/shm/nqptp` 中第 9–16 字节（`uint16_t version` 加对齐填充之后的 `master_clock_id`，小端）为 0 说明还没有锁定任何主时钟：

```bash
ssh ... root@<音箱IP> 'cat /dev/shm/nqptp' | python3 -c "import sys; d=sys.stdin.buffer.read(); print(d[8:16][::-1].hex())"
```

### 抓取实际输出的 PCM

用于判断发送端是否在发静音（抓包期间音箱不出声）：

```bash
# 音箱上：录 20 秒（44100Hz × 2ch × 2byte × 20s）
/data/airplay/shairport-sync -c /tmp/sps-debug.conf -o stdout 2>/tmp/cap.log | head -c 3528000 > /tmp/cap.raw &

# 电脑上：拉回来按秒统计峰值（±1 只是 dither，等同于数字静音）
ssh ... root@<音箱IP> 'cat /tmp/cap.raw' > cap.raw
python3 -c "
import array
a = array.array('h', open('cap.raw', 'rb').read()); fr = 44100 * 2
print(' '.join(f'{i//fr+1}s:{max(abs(x) for x in a[i:i+fr])}' for i in range(0, len(a), fr)))"
```

## 已知问题

### 1. 系统 mdnsd 的 socket 文件丢失

`/var/run` 是指向 `/tmp/run` 的软链接，开机后 `/var/run/mdnsd` 这个 socket 文件不存在，但 mdnsd 进程仍在监听原 inode，`central_lite` 也保持着开机时建立的连接。
因此 shairport-sync 的 `dns-sd` 后端注册失败（`-65563 kDNSServiceErr_ServiceNotRunning`）。

重启 mdnsd 可以恢复 socket，但会断开 `central_lite` 的连接，可能影响米家本地联动，所以不采用，改用 tinysvcmdns。

### 2. AirPlay 1 下视频 / 系统音频是静音

属于发送端行为，接收端无法修复，需要使用 AirPlay 2。

### 3. AirPlay 2 起播时的“滋啦”声

nqptp 刚启动（或第一次见到某台设备）时还没锁定对方的 PTP 时钟，起播同步误差可达 -32ms，shairport-sync 以约 1900 PPM 快速插入 / 丢弃采样修正，
`interpolation = "basic"` 下会听到几秒“滋啦”声；nqptp 稳定后起播误差约 1ms，无需修正。

现使用 `vernier`（按包重编码，适合低功耗设备），即使需要修正听感也更平滑。

不要调小 `audio_backend_buffer_desired_length_in_seconds`（默认 0.2）：实测 0.06 时 ALSA 每 ~90ms 欠载一次，杂音更严重。

### 4. 开机后能连上但没有声音

开机时过早启动（Wi-Fi 还没拿到 IP），nqptp 一直锁定不了主时钟（`master_clock_id` 为 0），shairport-sync 的播放线程一直等待时钟。
现在 `airplay.sh` 会等 wlan0 拿到 IPv4 地址后再启动 nqptp 和 shairport-sync。

### 5. 音量调节有延迟

使用软件音量，变化要等已缓冲的音频播完才生效。改用硬件音量（`mixer_control_name`）会改到小爱自身的音量，所以不采用。

### 6. AirPlay 2 模式下未观察到 `_raop._tcp` 广播

AirPlay 2 模式下 shairport-sync 也会注册 AirPlay 1 兼容的 `_raop._tcp`，但在 Mac 上没有观察到。iOS / macOS 使用 `_airplay._tcp`，不受影响，未深入排查。

## 回滚到 AirPlay 1

```bash
for p in $(ps | grep '[{]airplay.sh[}]' | awk '{print $1}'); do kill $p; done
killall shairport-sync nqptp 2>/dev/null; rm -f /tmp/airplay.pid
# 将 airplay1/ 中的 shairport-sync、shairport-sync.conf、airplay.sh 覆盖到 /data/airplay/，并删除 /data/airplay/nqptp
/data/airplay/airplay.sh > /dev/null 2>&1 &
```
