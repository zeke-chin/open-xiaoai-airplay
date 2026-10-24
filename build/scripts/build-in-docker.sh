#!/bin/bash
# 在 open-xiaoai-runtime 镜像内交叉编译 shairport-sync（以及 AirPlay 2 所需的 nqptp）
#
# 环境变量：
#   AIRPLAY=2（默认）编译 AirPlay 2 版本 + nqptp；AIRPLAY=1 编译 AirPlay 1（classic）版本
#
# 挂载约定：
#   /work  -> packages/airplay（输出到 /work/dist，中间产物在 /work/.build）
#   /src   -> shairport-sync 源码（只读，编译时复制一份并应用 /work/patches 下的补丁）
#
# 链接策略：
#   动态：glibc 2.25、libasound、libdns_sd、libuuid（全部使用设备自带的版本，来自 /opt/sysroot）
#   静态：popt、libconfig、精简版 ffmpeg（仅 ALAC/AAC/PCM 解码 + swresample），
#         AirPlay 1 用 mbedtls；AirPlay 2 的配对加密代码直接调用 OpenSSL，必须用 OpenSSL 3
#         （设备上只有 OpenSSL 1.0.0），并额外静态链接 libsodium、libgcrypt、libgpg-error、libplist

set -euo pipefail

MBEDTLS_VERSION=3.6.2
POPT_VERSION=1.19
LIBCONFIG_VERSION=1.7.3
FFMPEG_VERSION=7.1.1
SODIUM_VERSION=1.0.20
GPG_ERROR_VERSION=1.51
GCRYPT_VERSION=1.11.0
PLIST_VERSION=2.6.0
NQPTP_VERSION=1.2.9
OPENSSL_VERSION=3.5.4

AIRPLAY=${AIRPLAY:-2}

HOST=arm-linux-gnueabihf
SYSROOT=/opt/sysroot
BUILD=/work/.build
PREFIX=$BUILD/prefix
DL=$BUILD/dl
DIST=/work/dist
JOBS=$(nproc)

mkdir -p "$PREFIX/include" "$PREFIX/lib" "$DL" "$DIST"

if ! command -v autoreconf >/dev/null; then
  apt-get update && apt-get install -y --no-install-recommends autoconf automake libtool bzip2
fi

export PATH=/opt/toolchain/bin:$PATH
# 固件 sysroot 只有 .so 没有 libc 头文件，所以编译时使用 Linaro 工具链自带的 glibc 2.25（与设备一致），
# 只在链接阶段从固件 sysroot 引入 libasound / libdns_sd
export CC="$HOST-gcc"
export CXX="$HOST-g++"
export AR=$HOST-ar
export RANLIB=$HOST-ranlib
export STRIP=$HOST-strip
export CFLAGS="-O2 -march=armv7-a -mfpu=neon -mfloat-abi=hard"
export CPPFLAGS="-I$PREFIX/include"
# $PREFIX/lib 必须排在固件库目录前面，确保优先链接我们自己的静态库，
# 而不是固件里同名的 libmbedcrypto.so 等
# --as-needed：ffmpeg 的 .pc 会带上 -latomic，但实际没有用到，设备上也没有 libatomic.so.1
export LDFLAGS="-Wl,--as-needed -L$PREFIX/lib -L$PREFIX/devlib \
  -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/lib"
export PKG_CONFIG="pkg-config --static"
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=
export PKG_CONFIG_SYSROOT_DIR=

# 只暴露需要的固件库，避免固件 sysroot 里的 libc 等覆盖工具链自带的版本
mkdir -p "$PREFIX/devlib" "$PREFIX/lib/pkgconfig"
ln -sf "$SYSROOT/usr/lib/libasound.so.2" "$PREFIX/devlib/libasound.so"
ln -sf "$SYSROOT/usr/lib/libdns_sd.so" "$PREFIX/devlib/libdns_sd.so"
ln -sf "$SYSROOT/usr/lib/libuuid.so.1" "$PREFIX/devlib/libuuid.so"
rm -rf "$PREFIX/include/alsa"
cp -r "$SYSROOT/usr/include/alsa" "$PREFIX/include/alsa"
cat >"$PREFIX/lib/pkgconfig/alsa.pc" <<EOF
Name: alsa
Description: ALSA (OH2P firmware)
Version: 1.2.2
Libs: -lasound
Cflags: -I$PREFIX/include
EOF

fetch() { # fetch <url> <dir-name>
  local url=$1 dir=$2 file=$DL/$(basename "$1")
  [ -f "$file" ] || curl -fL --retry 3 -o "$file" "$url"
  if [ ! -d "$BUILD/$dir" ]; then
    tar -xf "$file" -C "$BUILD"
  fi
}

# ---------- mbedtls ----------
if [ ! -f "$PREFIX/lib/libmbedtls.a" ]; then
  fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2" "mbedtls-$MBEDTLS_VERSION"
  # GEN_FILES 置空：发行包已包含生成好的源码，不需要 python
  make -C "$BUILD/mbedtls-$MBEDTLS_VERSION/library" -j"$JOBS" GEN_FILES= \
    CC="$CC" AR="$AR" CFLAGS="$CFLAGS" libmbedcrypto.a libmbedx509.a libmbedtls.a
  cp "$BUILD/mbedtls-$MBEDTLS_VERSION"/library/libmbed*.a "$PREFIX/lib/"
  cp -r "$BUILD/mbedtls-$MBEDTLS_VERSION"/include/{mbedtls,psa} "$PREFIX/include/"
fi

# ---------- popt ----------
if [ ! -f "$PREFIX/lib/libpopt.a" ]; then
  fetch "http://ftp.rpm.org/popt/releases/popt-1.x/popt-$POPT_VERSION.tar.gz" "popt-$POPT_VERSION"
  (cd "$BUILD/popt-$POPT_VERSION" &&
    ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static --disable-nls &&
    make -j"$JOBS" && make install)
fi

# ---------- libconfig ----------
if [ ! -f "$PREFIX/lib/libconfig.a" ]; then
  fetch "https://github.com/hyperrealm/libconfig/releases/download/v$LIBCONFIG_VERSION/libconfig-$LIBCONFIG_VERSION.tar.gz" "libconfig-$LIBCONFIG_VERSION"
  (cd "$BUILD/libconfig-$LIBCONFIG_VERSION" &&
    ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static \
      --disable-cxx --disable-examples --disable-tests &&
    make -j"$JOBS" && make install)
fi

# ---------- ffmpeg（精简） ----------
if [ ! -f "$PREFIX/lib/libavcodec.a" ]; then
  # ffmpeg.org 国内常连不上，使用 GitHub 官方镜像仓库的 tag 源码包
  fetch "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz" "FFmpeg-n$FFMPEG_VERSION"
  (cd "$BUILD/FFmpeg-n$FFMPEG_VERSION" &&
    ./configure --prefix="$PREFIX" \
      --enable-cross-compile --cross-prefix=$HOST- --arch=arm --target-os=linux \
      --extra-cflags="$CFLAGS" \
      --enable-static --disable-shared --disable-autodetect \
      --disable-programs --disable-doc --disable-network \
      --disable-avdevice --disable-avfilter --disable-swscale \
      --disable-everything \
      --enable-decoder=alac,aac,pcm_s16be \
      --enable-swresample &&
    make -j"$JOBS" && make install)
fi

# ---------- dns_sd.h（设备上的 mdnsd 是 mDNSResponder，固件 sysroot 里只有 .so 没有头文件） ----------
if [ ! -f "$PREFIX/include/dns_sd.h" ]; then
  curl -fL --retry 3 -o "$PREFIX/include/dns_sd.h" \
    "https://raw.githubusercontent.com/apple-oss-distributions/mDNSResponder/main/mDNSShared/dns_sd.h"
fi

# ---------- AirPlay 2 依赖 ----------
if [ "$AIRPLAY" = 2 ]; then
  if [ ! -f "$PREFIX/lib/libcrypto.a" ]; then
    fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"
    (cd "$BUILD/openssl-$OPENSSL_VERSION" &&
      ./Configure linux-armv4 $CFLAGS --prefix="$PREFIX" --libdir=lib \
        no-shared no-tests no-docs no-module no-engine &&
      make -j"$JOBS" build_libs && make install_dev)
  fi

  if [ ! -f "$PREFIX/lib/libsodium.a" ]; then
    fetch "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VERSION-RELEASE/libsodium-$SODIUM_VERSION.tar.gz" "libsodium-$SODIUM_VERSION"
    (cd "$BUILD/libsodium-$SODIUM_VERSION" &&
      ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static &&
      make -j"$JOBS" && make install)
  fi

  if [ ! -f "$PREFIX/lib/libgpg-error.a" ]; then
    fetch "https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-$GPG_ERROR_VERSION.tar.bz2" "libgpg-error-$GPG_ERROR_VERSION"
    (cd "$BUILD/libgpg-error-$GPG_ERROR_VERSION" &&
      ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-nls --disable-doc --disable-tests --disable-languages &&
      make -j"$JOBS" && make install)
  fi

  if [ ! -f "$PREFIX/lib/libgcrypt.a" ]; then
    fetch "https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-$GCRYPT_VERSION.tar.bz2" "libgcrypt-$GCRYPT_VERSION"
    (cd "$BUILD/libgcrypt-$GCRYPT_VERSION" &&
      ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static \
        --disable-doc --with-libgpg-error-prefix="$PREFIX" &&
      make -j"$JOBS" && make install)
  fi

  if [ ! -f "$PREFIX/lib/libplist-2.0.a" ]; then
    fetch "https://github.com/libimobiledevice/libplist/releases/download/$PLIST_VERSION/libplist-$PLIST_VERSION.tar.bz2" "libplist-$PLIST_VERSION"
    (cd "$BUILD/libplist-$PLIST_VERSION" &&
      ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static \
        --without-cython --without-tools &&
      make -j"$JOBS" && make install)
  fi

  # 设备自带 libuuid.so.1，只需要头文件
  if [ ! -f "$PREFIX/include/uuid/uuid.h" ]; then
    mkdir -p "$PREFIX/include/uuid"
    curl -fL --retry 3 -o "$PREFIX/include/uuid/uuid.h" \
      "https://raw.githubusercontent.com/util-linux/util-linux/v2.40.2/libuuid/src/uuid.h"
  fi

  # ---------- nqptp（AirPlay 2 时钟同步，独占 UDP 319/320） ----------
  fetch "https://github.com/mikebrady/nqptp/archive/refs/tags/$NQPTP_VERSION.tar.gz" "nqptp-$NQPTP_VERSION"
  (cd "$BUILD/nqptp-$NQPTP_VERSION" &&
    autoreconf -fi &&
    ./configure --host=$HOST &&
    make -j"$JOBS")
  cp "$BUILD/nqptp-$NQPTP_VERSION/nqptp" "$DIST/nqptp"
  $STRIP "$DIST/nqptp"
fi

# ---------- shairport-sync ----------
if [ "$AIRPLAY" = 2 ]; then
  AIRPLAY_FLAGS="--with-airplay-2 --with-ssl=openssl"
  SSL_LIBS=
  # 设备自带的 libuuid 太旧，没有 uuid_generate_sha1()，用 patches/0002 中基于 OpenSSL 的实现
  SPS_CPPFLAGS="-DCONFIG_UUID_SHA1_COMPAT"
else
  AIRPLAY_FLAGS="--with-ffmpeg --with-ssl=mbedtls"
  # 静态 mbedtls 不会自动带上依赖库，configure 的 AC_CHECK_LIB(mbedtls) 需要预先补上
  SSL_LIBS="-lmbedx509 -lmbedcrypto"
  SPS_CPPFLAGS=
fi

SPS=$BUILD/shairport-sync
rm -rf "$SPS"
cp -a /src "$SPS"
for p in /work/patches/*.patch; do
  patch -d "$SPS" -p1 <"$p"
done
(cd "$SPS" &&
  autoreconf -fi &&
  LIBS="$SSL_LIBS" CPPFLAGS="$CPPFLAGS $SPS_CPPFLAGS" ./configure --host=$HOST --sysconfdir=/data/airplay \
    --with-alsa --with-dns_sd --with-tinysvcmdns $AIRPLAY_FLAGS \
    --with-stdout --with-pipe &&
  make -j"$JOBS")

cp "$SPS/shairport-sync" "$DIST/shairport-sync"
$STRIP "$DIST/shairport-sync"

BINS=("$DIST/shairport-sync")
[ "$AIRPLAY" = 2 ] && BINS+=("$DIST/nqptp")
for bin in "${BINS[@]}"; do
  echo
  echo "==> $(basename "$bin") 动态依赖："
  $HOST-readelf -d "$bin" | grep NEEDED
  echo "==> 需要的最高 glibc 版本："
  $HOST-objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1
  ls -lh "$bin"
done
