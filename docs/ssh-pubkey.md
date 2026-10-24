# 小爱音箱启用 SSH 公钥认证

本文记录 Xiaomi 智能音箱 Pro（OH2P，固件 1.58.6、Dropbear 2017.75）的配置过程。前提是已经刷入补丁固件，并且可以使用密码 SSH 登录音箱，参见 open-xiaoai 的[刷机教程](https://github.com/idootop/open-xiaoai/blob/main/docs/flash.md)。

本次设备的系统分区是只读 SquashFS，`/data` 是可写分区；固件会通过 `/etc/rc.local` 执行 `/data/init.sh`。其他固件请先确认这些路径和启动方式。

## 1. 确认 SSH 服务

先在电脑上使用密码登录（替换为自己的音箱 IP）：

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.31.240
```

在音箱上检查：

```sh
ps | grep '[d]ropbear'
cat /etc/config/dropbear
cat /etc/rc.local
mount
```

Dropbear 默认支持公钥认证，不使用 OpenSSH 的 `sshd_config`，因此无需设置 `PubkeyAuthentication yes`。确认服务没有使用禁止 root 登录的 `-w` 参数；本次设备原本就允许 root 登录。

本固件的 root 公钥授权文件为 `/etc/dropbear/authorized_keys`。由于该文件位于只读分区，我们将它复制到 `/data/etc/dropbear/authorized_keys`，再通过 bind mount 挂载到原路径。

## 2. 配置电脑的 SSH 别名

以下命令均在**电脑终端**执行。将下面的配置加入 `~/.ssh/config`，保留已有配置。如果已经存在同名 `Host`，修改原配置即可，不要重复添加。

```sshconfig
Host xiaomi-speaker
    HostName 192.168.31.240
    User root
    IdentityFile ~/.ssh/id_rsa
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

```sh
chmod 600 ~/.ssh/config
cat ~/.ssh/id_rsa.pub
```

本次使用电脑已有的 RSA 密钥。若没有密钥，可用 `ssh-keygen -t rsa -b 3072` 创建；不要覆盖已有私钥。只上传 `.pub` 公钥，私钥留在电脑上。

两个算法选项用于兼容音箱的旧版 Dropbear，仅对该别名生效：`HostKeyAlgorithms` 用于验证音箱身份，`PubkeyAcceptedAlgorithms` 用于用户公钥认证。仅使用密码登录时，通常只需要前一个选项。

## 3. 创建可写授权文件并配置开机挂载

在电脑执行以下命令，按提示输入音箱 SSH 密码：

```sh
ssh xiaomi-speaker 'sh -s' <<'REMOTE'
set -e

# 确认当前固件具备所需路径和启动入口。
test -f /etc/dropbear/authorized_keys
test -f /data/init.sh
grep -qF '/data/init.sh' /etc/rc.local
sh -n /data/init.sh

stamp=$(date +%Y%m%d%H%M%S)
cp -p /data/init.sh "/data/init.sh.bak-pubkey-$stamp"

mkdir -p /data/etc/dropbear
chmod 700 /data/etc/dropbear
if [ ! -f /data/etc/dropbear/authorized_keys ]; then
    cp /etc/dropbear/authorized_keys /data/etc/dropbear/authorized_keys
fi
cp -p /data/etc/dropbear/authorized_keys \
    "/data/etc/dropbear/authorized_keys.bak-$stamp"
chown root:root /data/etc/dropbear/authorized_keys
chmod 600 /data/etc/dropbear/authorized_keys

# 首次配置立即挂载；重复执行时避免叠加挂载。
if ! grep -q ' /etc/dropbear/authorized_keys ' /proc/mounts; then
    mount -o bind /data/etc/dropbear/authorized_keys /etc/dropbear/authorized_keys
fi

# 插入到脚本第 2 行，在等待网络或启动其他程序之前执行。
if ! grep -qF '# ssh-pubkey-persistent' /data/init.sh; then
    sed -i '1a mount -o bind /data/etc/dropbear/authorized_keys /etc/dropbear/authorized_keys # ssh-pubkey-persistent' /data/init.sh
fi

sh -n /data/init.sh
sync
echo '开机挂载配置完成'
REMOTE
```

原有公钥会保留。不要直接用 `>` 覆盖授权文件，也不要把整个 `/etc/dropbear` 目录覆盖挂载，以免遮住设备的其他 SSH 文件。

## 4. 上传电脑公钥

在电脑执行：

```sh
cat ~/.ssh/id_rsa.pub | ssh xiaomi-speaker '
set -e
IFS= read -r key
test -n "$key"
grep -qF "$key" /data/etc/dropbear/authorized_keys ||
    printf "\n%s\n" "$key" >> /data/etc/dropbear/authorized_keys
chmod 600 /data/etc/dropbear/authorized_keys
sync
'
```

公钥立即生效，无需重启 Dropbear。通过 SSH 标准输入传输，可避免在音箱交互终端粘贴长公钥时发生截断。

## 5. 验证登录

保留原来的密码登录会话，在电脑另一个终端执行：

```sh
ssh -o BatchMode=yes -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    xiaomi-speaker 'echo PUBKEY_LOGIN_OK; id'
```

输出 `PUBKEY_LOGIN_OK` 和 `uid=0(root)` 表示公钥认证成功。`BatchMode=yes` 禁止交互询问密码，因此成功结果可以确认没有回退到密码登录。如果私钥设有口令，先在电脑通过 `ssh-add ~/.ssh/id_rsa` 加载密钥，再执行验证。

以后直接连接：

```sh
ssh xiaomi-speaker
```

本次已验证公钥登录成功，并通过 `/data/init.sh` 的语法检查；没有重启音箱验证。方便时可重启后再次执行验证命令，确认开机挂载生效。

## 排查与恢复

- `no matching host key type found`：确认别名配置中的 `HostKeyAlgorithms +ssh-rsa` 生效。
- `Permission denied (publickey,password)`：用 `ssh -vv xiaomi-speaker` 检查密钥选择；确认 `PubkeyAcceptedAlgorithms +ssh-rsa`、授权文件内容和 `600` 权限，以及 bind mount 是否生效。
- `Operation timed out`：检查音箱 IP、网络和 22 端口；连接超时发生在认证之前。
- 重启后公钥失效：检查 `/etc/rc.local` 是否仍执行 `/data/init.sh`，以及该脚本第 2 行的挂载命令。刷机或恢复出厂设置可能改变启动入口或清除数据。

需要撤销开机挂载时，在音箱上执行：

```sh
sed -i '/# ssh-pubkey-persistent$/d' /data/init.sh
umount /etc/dropbear/authorized_keys
sync
```

卸载后恢复使用系统分区原有的授权文件。备份保存在 `/data/init.sh.bak-pubkey-*` 和 `/data/etc/dropbear/authorized_keys.bak-*`，可按需恢复。本流程保留了原有密码认证方式。
