#!/usr/bin/env bash
# 云端构建准备：拉取源码 / 配置 feeds / 注入机型定制 / 内置内核 / 生成 .config
# 由 .github/workflows/build.yml 调用，运行在 GitHub-hosted runner 上。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.33}"

REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
# 默认用正式版种子；测试构建可用 SEED_FILE 指向另一份 .config 种子
SEED="${SEED_FILE:-$REPO/config/seed.config}"

group(){ echo "::group::$*"; }
endg(){ echo "::endgroup::"; }

# ---------------------------------------------------------------
# 1) 主源码
# ---------------------------------------------------------------
group "克隆 pbs05/ponwrt"
git clone --depth 1 https://github.com/pbs05/ponwrt.git "$SRC"
cd "$SRC"

# 编译缓存：dl（源码包）与 ccache（目标文件）放在源码树之外，
# 由 GitHub Actions cache 在构建之间复用。软链给 make 用。
# git clone 出来的目录里没有 dl/.ccache，软链不会覆盖已有内容。
mkdir -p "$REPO/cache/dl" "$REPO/cache/ccache"
[ -e "$SRC/dl" ] || ln -s "$REPO/cache/dl" "$SRC/dl"
[ -e "$SRC/.ccache" ] || ln -s "$REPO/cache/ccache" "$SRC/.ccache"

# 注意：不要改内核 config-6.18 的 CONFIG_WLAN。
# OpenWrt 的无线栈走 package/kernel/mac80211（backports-7.2 独立源码树），
# cfg80211 / mac80211 / mt76 / rtw88 / ath9k 全部 out-of-tree 编译，
# 与 target 内核的 CONFIG_WLAN 无关；官方 ramips 等 target 同样是
# "# CONFIG_WLAN is not set" 却完整支持 USB 无线网卡。
# 强行打开 CONFIG_WLAN 会引入整棵 WLAN_VENDOR_* 新符号，syncconfig
# 在非交互环境下提问失败（ATH5K_PCI (NEW) → Error 1），构建直接中断。
if [ "${KERNEL_WLAN:-0}" = "1" ]; then
  echo "KERNEL_WLAN=1 已废弃：无线驱动由 backports 提供，无需改内核配置，跳过"
fi
endg

# ---------------------------------------------------------------
# 2) feeds
#    - 标准 feeds 全部沿用官方地址，云端直连即可
#    - ONU 插件用 naoki66/OpenWrt_ONU_CONFIG 取代 pbs05/openwrt-pon-userspace：
#      两者都提供 airoha-ponctl / airoha-pon-daemons / airoha-pon-debug，
#      同时启用会产生同名包冲突
#    - luci-app-openclash / luci-app-passwall / luci-app-cpufreq 均由
#      immortalwrt/luci feed 提供，无需额外 feed
# ---------------------------------------------------------------
group "写入 feeds.conf"
cat > feeds.conf <<'FEEDS'
src-git packages https://github.com/immortalwrt/packages.git
src-git luci https://github.com/immortalwrt/luci.git
src-git routing https://github.com/openwrt/routing.git
src-git telephony https://github.com/openwrt/telephony.git
src-git video https://github.com/openwrt/video.git
src-git pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git
src-git onu https://github.com/naoki66/OpenWrt_ONU_CONFIG.git;main
src-git airoha https://github.com/naoki66/luci-app-airoha.git;main
src-git qmodem https://github.com/FUjr/QModem.git;main
FEEDS
cat feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
endg

# ---------------------------------------------------------------
# 3) 机型定制（OpenWrt files/ overlay，直接编进 rootfs）
# ---------------------------------------------------------------
group "注入机型定制 ($MODEL)"
OVL="$SRC/files"
mkdir -p "$OVL/etc/uci-defaults" "$OVL/etc/openclash/core"

# 3.4 概览页频率/温度显示：LuCI 状态页通过 /sbin/cpuinfo、/sbin/tempinfo 读数。
#     autocore 只在 ipq*/mediatek*/qualcommax* 安装这两个脚本，airoha 不在其列，
#     因此直接从本仓库 overlay 注入，不引入 autocore 包、不改 .config。
mkdir -p "$OVL/sbin"
install -m 0755 "$REPO/config/overlay/sbin/cpuinfo"  "$OVL/sbin/cpuinfo"
install -m 0755 "$REPO/config/overlay/sbin/tempinfo" "$OVL/sbin/tempinfo"

# 3.5 网络转发调优（PPE 未生效，转发全靠 CPU，这里榨多核）
#     RPS：把网卡 RX 软中断从 CPU0 分散到 CPU1-3；RFS 按 socket 流建哈希。
#     BBR 由 kmod-tcp-bbr 包自带 sysctl 落地，这里只补 RFS 需要的内核参数。
mkdir -p "$OVL/etc/sysctl.d" "$OVL/etc/hotplug.d/net"
cat > "$OVL/etc/sysctl.d/90-rps.conf" <<'SYSCTL'
# RFS：全局 socket 流哈希表项数（每流 4096 由热插拔脚本分配）
net.core.rps_sock_flow_entries = 32768
SYSCTL

cat > "$OVL/etc/hotplug.d/net/20-rps" <<'RPS'
#!/bin/sh
# 网卡上线时把 RX 软中断分散到 CPU1-3（4 核取掩码 e，CPU0 留给硬中断）
[ "$ACTION" = "add" ] || exit 0
[ -n "$INTERFACE" ] || exit 0
[ -d "/sys/class/net/$INTERFACE/queues" ] || exit 0
case "$INTERFACE" in
  lo|sit*|ip6tnl*|tun*|tap*|wg*|br-*|docker*|veth*) exit 0 ;;
esac
for q in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_cpus; do
  [ -w "$q" ] && echo e > "$q" 2>/dev/null
done
for q in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_flow_cnt; do
  [ -w "$q" ] && echo 4096 > "$q" 2>/dev/null
done
exit 0
RPS
chmod +x "$OVL/etc/hotplug.d/net/20-rps"

# 3.1 登录密码 root（MD5-crypt，失败时用等价的固定 hash 兜底）
ROOT_HASH="$(openssl passwd -1 -salt airoha root 2>/dev/null || true)"
[ -n "$ROOT_HASH" ] || ROOT_HASH='$1$airoha$lzq0xSV6pJiFfzc/JwIoc0'
cat > "$OVL/etc/shadow" <<SHADOW
root:${ROOT_HASH}:0:0:99999:7:::
daemon:*:0:0:99999:7:::
ftp:*:0:0:99999:7:::
network:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
ntp:*:0:0:99999:7:::
SHADOW

# 3.2 登录 IP 192.168.2.1
cat > "$OVL/etc/uci-defaults/99-lan-ip" <<'LANIP'
#!/bin/sh
uci -q batch <<'UCIBATCH'
set network.lan.ipaddr='192.168.2.1'
set network.lan.netmask='255.255.255.0'
commit network
UCIBATCH
exit 0
LANIP

# 3.3 WiFi：hg5585f 系列，SSID 以机型命名(HG5585F-CT / HG5585F-CU ...)，密码八个 8
#     不是 hg5585f 的机型(如 xg-040g 系列无 WiFi)则跳过
case "$MODEL" in
  hg5585f-*)
    SSID="$(printf '%s' "$MODEL" | tr '[:lower:]' '[:upper:]')"
cat > "$OVL/etc/uci-defaults/99-wifi" <<'WIFI'
#!/bin/sh
SSID='__SSID__'
[ -s /etc/config/wireless ] || wifi config >/dev/null 2>&1
# 监管域固定 CN（默认 00/US 会让 5G 高信道不可用、EIRP 受限），并解除 radio 禁用
for d in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device/\1/p'); do
  uci -q set "wireless.$d.country=CN"
  uci -q set "wireless.$d.disabled=0"
done
for s in $(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface/\1/p'); do
  uci -q set "wireless.$s.ssid=$SSID"
  uci -q set "wireless.$s.encryption=psk2"
  uci -q set "wireless.$s.key=88888888"
  uci -q delete "wireless.$s.disabled"
done
if ! uci -q show wireless | grep -q '=wifi-iface'; then
  cat >> /etc/config/wireless <<'UCIWIFI'
config wifi-device 'radio0'
  option type 'mac80211'
  option disabled '0'
config wifi-iface 'default_radio0'
  option device 'radio0'
  option network 'lan'
  option mode 'ap'
  option ssid '__SSID__'
  option encryption 'psk2'
  option key '88888888'
UCIWIFI
fi
uci -q commit wireless
exit 0
WIFI
    sed -i "s/__SSID__/${SSID}/g" "$OVL/etc/uci-defaults/99-wifi"
    ;;
esac
# 3.4 默认简体中文 + Argon 主题（uci-defaults 开机首次执行，99- 前缀保证最后覆盖）
#     dispatcher 读取 luci.main.lang：'zh_cn' 会被转成 'zh-cn' 去加载
#     /usr/lib/lua/luci/i18n/*.zh-cn.lmo（由 luci-i18n-*-zh-cn 包提供）。
#     Argon 包自带 30_luci-theme-argon 也会设主题，这里兜底确保生效。
cat > "$OVL/etc/uci-defaults/99-lang-theme" <<'LANGTHEME'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q set luci.themes.Argon='/luci-static/argon'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
LANGTHEME
chmod +x "$OVL/etc/uci-defaults/"*
endg

# ---------------------------------------------------------------
# 4) OpenClash 内置核心：Mihomo aarch64 静态二进制
#    luci-app-openclash 包本身不含内核，须放到 /etc/openclash/core/clash_meta
# ---------------------------------------------------------------
group "内置 OpenClash 内核 (Mihomo ${MIHOMO_VERSION})"
CORE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-arm64-${MIHOMO_VERSION}.gz"
if ! curl -fL --retry 3 -o /tmp/mihomo.gz "$CORE_URL"; then
  # 固定版本不可用时，自动从最新 release 里挑选 linux-arm64 的 .gz 资产
  CORE_URL="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    | grep -oE 'https://[^\"]*mihomo-linux-arm64-[^\"]*\.gz' | head -1 || true)"
  if [ -z "$CORE_URL" ]; then
    echo "::error::无法定位 Mihomo arm64 内核"
    exit 1
  fi
  curl -fL --retry 3 -o /tmp/mihomo.gz "$CORE_URL"
fi
gunzip -f /tmp/mihomo.gz
install -m 0755 /tmp/mihomo "$OVL/etc/openclash/core/clash_meta"
file "$OVL/etc/openclash/core/clash_meta"
endg

# ---------------------------------------------------------------
# 5) 预置源码包：tools/mkimage 与 uboot-envtools 需要 u-boot 源码，
#    部分上游老站响应很慢，优先直取官方源，失败时回退到项目 GitHub 镜像并重算校验值
# ---------------------------------------------------------------
group "预置 u-boot / openssl 源码"
mkdir -p dl
UB="dl/u-boot-2026.10.tar.bz2"
if ! curl -fL --connect-timeout 15 --max-time 180 --retry 1 \
      "https://git.u-boot-project.org/u-boot/u-boot/-/releases/v2026.10/downloads/u-boot-2026.10.tar.bz2" \
      -o "$UB"; then
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/src.tar.gz" \
    "https://github.com/u-boot/u-boot/archive/refs/tags/v2026.10.tar.gz"
  TOP="$(tar -tzf "$TMP/src.tar.gz" | head -1 | cut -d/ -f1)"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP"
  tar -cjf "$UB" -C "$TMP" "$TOP"
  rm -rf "$TMP"
fi
UB_HASH="$(sha256sum "$UB" | cut -d' ' -f1)"
sed -i -E "s/^PKG_HASH:=.*/PKG_HASH:=${UB_HASH}/" \
  tools/mkimage/Makefile package/boot/uboot-tools/Makefile
echo "u-boot hash: ${UB_HASH}"

if [ ! -f dl/openssl-3.5.9.tar.gz ]; then
  curl -fL --retry 3 -o dl/openssl-3.5.9.tar.gz \
    https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
fi
echo "openssl hash: $(sha256sum dl/openssl-3.5.9.tar.gz | cut -d' ' -f1)"
endg

# ---------------------------------------------------------------
# 6) .config
# ---------------------------------------------------------------
group "生成 .config ($PROFILE)"
# ccache 选项默认带可见性条件（bool "Use ccache" if DEVEL），DEVEL 未开时
# kconfig 视为不可见符号，defconfig 会把它重置回默认值 n，种子里写 y 也无效。
# 这里去掉该条件，让 CONFIG_CCACHE=y 真正生效；不影响其他开发选项。
sed -i 's/^\([[:space:]]*\)bool "Use ccache" if DEVEL$/\1bool "Use ccache"/' config/Config-devel.in
grep -q 'bool "Use ccache"$' config/Config-devel.in || {
  echo "::error::改写 ccache 可见性失败，config/Config-devel.in 结构可能已变"
  exit 1
}
# 单设备模式：设备是 "Target Profile" choice 的成员，符号格式为
#   CONFIG_TARGET_<board>_<subtarget>_DEVICE_<dev>=y
# 这里 board/subtarget = airoha/an7581，dev 即 profile。
# 选中后 CONFIG_TARGET_PROFILE 会自动 default 成 "DEVICE_<dev>"，
# 设备的 DEVICE_PACKAGES（WiFi 驱动、fitblk 等）也随之进入 rootfs。
{
  cat "$SEED"
  echo "CONFIG_TARGET_airoha_an7581_DEVICE_${PROFILE}=y"
} > .config

# QFirehose was explicitly requested for HG5585F CT; keep it model-scoped
# so the XG-040G-MD image does not gain an unnecessary flashing utility.
if [[ "$MODEL" == "hg5585f-ct" ]]; then
  cat >> .config <<'QFIREHOSE'
CONFIG_PACKAGE_qmodem_INCLUDE_ADD_QFIREHOSE_SUPPORT=y
CONFIG_PACKAGE_qfirehose=y
QFIREHOSE
fi
make defconfig

# ccache 是构建加速项，未生效不阻塞出固件，但要显式告警
if grep -q "^CONFIG_CCACHE=y$" .config; then
  echo "ccache: 已启用"
else
  echo "::warning::CONFIG_CCACHE 未生效，本次构建不会写编译缓存"
fi

# 断言机型设备符号确实被选中，避免编错设备白跑几小时
if ! grep -q "^CONFIG_TARGET_airoha_an7581_DEVICE_${PROFILE}=y$" .config; then
  echo "::error::机型设备未选中: ${PROFILE}"
  echo "--- .config 中实际选中的设备符号 ---"
  grep -E "^CONFIG_TARGET_.*_DEVICE_.*=y$" .config | head -20 || true
  echo "--- 含 ${PROFILE} 的所有行 ---"
  grep -n "$PROFILE" .config | head -20 || true
  exit 1
fi
echo "已选设备: $(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' .config | tr '\n' ' ')"
grep -E "^CONFIG_TARGET_PROFILE=" .config || true

# 关闭设备独立 bootloader / ATF / 外部交叉工具链包。
# 这些包产出的是单独烧录的 bootloader artifact，不属于 sysupgrade 固件；
# 且其源码托管在自托管 GitLab（arm / u-boot 域），CI 环境不稳定。
# 依据 an7581.mk：两机型 IMAGES 均为 sysupgrade.itb，不依赖这些包。
KEYS="$(grep -E '^CONFIG_PACKAGE_(u-boot-|trusted-firmware-a-|arm-gnu-toolchain)[^=]*=y$' .config | sed 's/=y$//' || true)"
for k in $KEYS; do
  sed -i "s|^${k}=y|# ${k} is not set|" .config
done

# 严格校验：用户要求的包必须全部入选
for p in luci-app-onu luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug \
         luci-app-airoha-npu luci-app-qmodem-next qmodem luci-app-openclash \
         luci-app-passwall luci-app-cpufreq xray-core \
         luci-theme-argon luci-i18n-base-zh-cn \
         usb-modeswitch kmod-usb-net-qmi-wwan chat comgt \
         kmod-usb-serial-sierrawireless kmod-mtk-t7xx \
         autocore kmod-crypto-hw-eip93 kmod-cryptodev openssl-util \
         libopenssl-devcrypto kmod-tcp-bbr ${EXTRA_REQUIRED_PKGS:-}; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::配置缺少 ${p}"
    exit 1
  fi
done
# QFirehose is mandatory for HG5585F CT only; fail early if feeds/defconfig drop it.
if [[ "$MODEL" == "hg5585f-ct" ]]; then
  grep -Fq "CONFIG_PACKAGE_qmodem_INCLUDE_ADD_QFIREHOSE_SUPPORT=y" .config || {
    echo "::error::HG5585F CT 缺少 QModem QFirehose 支持开关"
    exit 1
  }
  grep -Fq "CONFIG_PACKAGE_qfirehose=y" .config || {
    echo "::error::HG5585F CT 缺少 qfirehose 包"
    exit 1
  }
fi
# 语言开关是 HIDDEN 中文包能否被选中的前提，必须存在
if ! grep -q "^CONFIG_LUCI_LANG_zh_Hans=y$" .config; then
  echo "::error::缺少 CONFIG_LUCI_LANG_zh_Hans，中文翻译包不会生效"
  exit 1
fi
echo "关键包校验通过（含中文 / Argon 主题）"
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)' .config
endg

