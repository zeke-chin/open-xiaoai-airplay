# open-xiaoai-airplay

让刷机后的小爱音箱 Pro 支持 **AirPlay 2**，iPhone / iPad / Mac 可以直接在“隔空播放”里选择音箱投送音频。

- 只走局域网，不经过小米云
- 不修改固件、不重启任何小米系统服务
- 与小爱自身的声音混音输出：播放中喊“小爱同学”可以正常唤醒对话
- AirPlay 音量只在软件内调节，不改动小爱自身的音量
- 开机自动启动，就绪后播放一声提示音

基于 [Shairport Sync](https://github.com/mikebrady/shairport-sync) + [NQPTP](https://github.com/mikebrady/nqptp) 交叉编译，运行在 [open-xiaoai](https://github.com/idootop/open-xiaoai) 刷机后的音箱上。

## 已测试环境

> [!IMPORTANT]
> 目前只在下面这台设备上测试过，其他型号 / 固件请先确认系统环境（见[技术细节](docs/airplay.md#设备环境)）。

| 项 | 版本 |
| --- | --- |
| 音箱 | Xiaomi 智能音箱 Pro（**OH2P**） |
| 固件 | **1.58.6**（open-xiaoai 补丁固件），LEDE，用户态 armhf / glibc 2.25 |
| SSH | Dropbear 2017.75 |
| 发送端 | iPhone、iPad、Mac |

| 场景 | AirPlay 2 | AirPlay 1 |
| --- | --- | --- |
| 网易云等音乐 App | ✅ | ✅ |
| B 站等视频 App、系统音频、游戏 | ✅ | ❌ 发送端只发静音 |
| 播放中唤醒“小爱同学” | ✅ | ✅ |
| 重启后自动启动 | ✅ | ✅ |

## 目录结构

```
airplay2/          # AirPlay 2（推荐）：预编译二进制 + 配置 + 启动脚本
├── shairport-sync
├── nqptp
├── shairport-sync.conf
├── airplay.sh     # 守护脚本：等待网络就绪、启动并守护 nqptp / shairport-sync、就绪提示音
├── ready.wav      # 默认的就绪提示音（可替换）
└── init.sh        # 开机入口 /data/init.sh 中需要的一行
airplay1/          # AirPlay 1（classic）：只支持音乐类 App，备用
build/             # 交叉编译脚本、Dockerfile、补丁
docs/
├── airplay.md     # 技术细节、调试方法、已知问题
└── ssh-pubkey.md  # 小爱音箱启用 SSH 公钥认证
```

## 安装

前提：音箱已按 open-xiaoai 的[刷机教程](https://github.com/idootop/open-xiaoai/blob/main/docs/flash.md)刷入补丁固件，可以 SSH 登录。推荐先配置 [SSH 公钥认证](docs/ssh-pubkey.md)。

```bash
# 音箱上的 Dropbear 只支持 ssh-rsa；scp 需要 -O 使用旧协议
SPEAKER=root@192.168.31.240
O="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

ssh $O $SPEAKER 'mkdir -p /data/airplay'
scp -O $O airplay2/shairport-sync airplay2/nqptp airplay2/shairport-sync.conf airplay2/airplay.sh airplay2/ready.wav $SPEAKER:/data/airplay/
ssh $O $SPEAKER 'chmod +x /data/airplay/shairport-sync /data/airplay/nqptp /data/airplay/airplay.sh'

# 立即启动
ssh $O $SPEAKER '/data/airplay/airplay.sh > /dev/null 2>&1 &'
```

开机自启：固件开机时会执行 `/data/init.sh`，在其中**追加**一行（不要覆盖已有内容）：

```sh
[ -x /data/airplay/airplay.sh ] && /data/airplay/airplay.sh > /dev/null 2>&1 &
```

> [!NOTE]
> 如果 `/data/init.sh` 里原来是 open-xiaoai client 的启动脚本，它会先等待外网可用，再在前台运行 client，追加在末尾的命令永远执行不到。
> 请把这一行放到 client 启动命令之前；如果已经不再使用 open-xiaoai server，可以直接停用 client（详见[技术细节](docs/airplay.md#open-xiaoai-client)）。

启动后约十几秒听到提示音，即可在 iPhone / iPad / Mac 的“隔空播放”中选择“小爱音箱”。

### 常用配置

`/data/airplay/shairport-sync.conf`：

- `name`：隔空播放列表中显示的名字
- `default_airplay_volume`：启动后首次连接的音量（-30 ~ 0，默认 -24 即 20%；运行期间会记住上次的音量）

`/data/airplay/airplay.sh`：

- `READY_SOUND`：就绪提示音，默认是 `/data/airplay/ready.wav`，**可替换**：直接用自己的 wav / mp3 / opus 覆盖 `ready.wav`，
  或把 `READY_SOUND` 指向其他文件（包括系统自带的音效，见[技术细节](docs/airplay.md#就绪提示音)）；置空则不播放。
  `ready.wav` 不存在时使用系统自带的 `bluetooth_connect.opus`

修改后执行 `killall shairport-sync`，守护脚本会在 5 秒内重新拉起。

## 从源码编译

需要 Docker（macOS 上用 OrbStack / Docker Desktop，amd64 镜像经 Rosetta 运行）：

```bash
git clone https://github.com/mikebrady/shairport-sync.git   # 与本仓库放在同级目录
cd open-xiaoai-airplay/build
./build.sh              # AirPlay 2，产物在 build/dist/
AIRPLAY=1 ./build.sh    # AirPlay 1
```

编译基于 open-xiaoai 提供的交叉编译环境 [`idootop/open-xiaoai-runtime:oh2p`](https://github.com/idootop/open-xiaoai/tree/main/packages/runtime)，详见[技术细节](docs/airplay.md#编译)。预编译二进制使用的上游版本：Shairport Sync 5.6.1（`b991d913`）、NQPTP 1.2.9。

## 致谢

- [open-xiaoai](https://github.com/idootop/open-xiaoai)：小爱音箱刷机补丁、SSH 访问和交叉编译环境，本项目的一切都建立在它之上
- [Shairport Sync](https://github.com/mikebrady/shairport-sync)：AirPlay / AirPlay 2 音频接收端
- [NQPTP](https://github.com/mikebrady/nqptp)：AirPlay 2 所需的 PTP 时钟同步
- 以及 FFmpeg、OpenSSL、mbed TLS、libsodium、libgcrypt、libplist、popt、libconfig 等开源项目

## 许可证

本仓库自己编写的脚本、补丁和文档使用 [MIT](LICENSE) 许可证。

预编译二进制包含多个第三方组件，各自遵循其原有许可证（其中 NQPTP 为 GPL-2.0，FFmpeg、libgcrypt 等为 LGPL），
完整列表、上游源码版本及获取方式见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

本项目与 Apple、小米无关。AirPlay 是 Apple Inc. 的商标。
