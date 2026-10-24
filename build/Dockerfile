# 在 open-xiaoai-runtime 基础上补齐编译工具，避免每次编译都重新 apt 安装
#   autotools：shairport-sync / nqptp 需要 autoreconf
#   libplist-utils、xxd：shairport-sync AirPlay 2 编译时在宿主机上生成代码用
FROM --platform=linux/amd64 idootop/open-xiaoai-runtime:oh2p

RUN apt-get update && \
    apt-get install -y --no-install-recommends autoconf automake libtool bzip2 patch libplist-utils xxd && \
    rm -rf /var/lib/apt/lists/*
