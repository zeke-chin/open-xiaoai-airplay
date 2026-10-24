# 第三方组件与许可证

`airplay1/` 和 `airplay2/` 中的预编译二进制由以下上游项目编译而成，各组件遵循其原有许可证。
编译所用的完整脚本、补丁和版本号都在 [`build/`](build/) 中，可按 [README](README.md#从源码编译) 自行重新编译（包括替换其中任一静态链接的库后重新链接）。

## 可执行程序

| 程序 | 上游 | 版本 | 许可证 |
| --- | --- | --- | --- |
| `shairport-sync` | [mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync) | 5.6.1（commit `b991d913`），应用 [`build/patches/`](build/patches/) 中的补丁 | MIT 风格，各文件见源码头部及 [LICENSES](https://github.com/mikebrady/shairport-sync/blob/master/LICENSES)；内置的 tinysvcmdns 为 BSD 3-Clause |
| `nqptp`（仅 AirPlay 2） | [mikebrady/nqptp](https://github.com/mikebrady/nqptp) | 1.2.9，未修改 | GPL-2.0，源码：<https://github.com/mikebrady/nqptp/tree/1.2.9> |

## 静态链接进 `shairport-sync` 的库

| 库 | 版本 | 许可证 | 用于 |
| --- | --- | --- | --- |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg)（libavcodec / libavformat / libavutil / libswresample，仅启用 alac、aac、pcm_s16be 解码器，未启用 GPL 组件） | 7.1.1 | LGPL-2.1-or-later | AirPlay 1 / 2 |
| [popt](https://github.com/rpm-software-management/popt) | 1.19 | MIT | AirPlay 1 / 2 |
| [libconfig](https://github.com/hyperrealm/libconfig) | 1.7.3 | LGPL-2.1-or-later | AirPlay 1 / 2 |
| [mbed TLS](https://github.com/Mbed-TLS/mbedtls) | 3.6.2 | Apache-2.0 OR GPL-2.0-or-later | AirPlay 1 |
| [OpenSSL](https://github.com/openssl/openssl) | 3.5.4 | Apache-2.0 | AirPlay 2 |
| [libsodium](https://github.com/jedisct1/libsodium) | 1.0.20 | ISC | AirPlay 2 |
| [libgcrypt](https://gnupg.org/software/libgcrypt/) | 1.11.0 | LGPL-2.1-or-later | AirPlay 2 |
| [libgpg-error](https://gnupg.org/software/libgpg-error/) | 1.51 | LGPL-2.1-or-later | AirPlay 2 |
| [libplist](https://github.com/libimobiledevice/libplist) | 2.6.0 | LGPL-2.1-or-later | AirPlay 2 |

## 未随本仓库分发的库

以下库在运行时动态链接音箱固件自带的版本，本仓库不包含它们：glibc、alsa-lib（`libasound`）、mDNSResponder 客户端（`libdns_sd`）、util-linux libuuid（`libuuid`）。

编译时使用的头文件 `dns_sd.h`（Apple mDNSResponder，Apache-2.0）和 `uuid/uuid.h`（util-linux，BSD 3-Clause）仅用于编译，不包含在二进制中。
