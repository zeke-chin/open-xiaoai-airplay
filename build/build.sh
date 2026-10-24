#!/bin/bash
# 用法：
#   SHAIRPORT_SRC=/path/to/shairport-sync ./build.sh   # AirPlay 2（默认）
#   AIRPLAY=1 ./build.sh                               # AirPlay 1（classic）
# shairport-sync 源码默认放在本仓库同级目录（../../shairport-sync）
# 产物：dist/shairport-sync、dist/nqptp（ARMv7 / glibc 2.25，可直接在小爱音箱 Pro 上运行）

set -euo pipefail

cd "$(dirname "$0")"

# 镜像 tag 取 Dockerfile 的哈希，Dockerfile 变化后会自动重新构建
IMAGE=${IMAGE:-open-xiaoai-airplay-builder:$(shasum Dockerfile | cut -c1-8)}
SHAIRPORT_SRC=${SHAIRPORT_SRC:-../../shairport-sync}

if [ ! -f "$SHAIRPORT_SRC/configure.ac" ]; then
  echo "找不到 shairport-sync 源码：$SHAIRPORT_SRC（可通过 SHAIRPORT_SRC 指定）"
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build --platform linux/amd64 -t "$IMAGE" .
fi

docker run --rm --platform linux/amd64 \
  -e AIRPLAY="${AIRPLAY:-2}" \
  -v "$PWD:/work" \
  -v "$(cd "$SHAIRPORT_SRC" && pwd):/src:ro" \
  "$IMAGE" bash /work/scripts/build-in-docker.sh
