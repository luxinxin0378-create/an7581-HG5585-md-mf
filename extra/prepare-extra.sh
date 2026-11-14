#!/usr/bin/env bash
# 额外两机型(hg5585f-cu / xg-040g-mf)云端构建准备：
# 拉取源码 / 配置 feeds / 注入机型定制 / 内置内核 / 按 subtarget 生成 .config
# 由 .github/workflows/build-extra.yml 调用，运行在 GitHub-hosted runner 上。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
SUBTARGET="${3:?缺少 subtarget (an7581/an7583)}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.33}"

REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
SEED="$REPO/extra/seed-extra.config"

case "$SUBTARGET" in
  an7581|an7583) ;;
  *) echo "::error::不支持的 subtarget: ${SUBTARGET}"; exit 1 ;;
esac

group(){ echo "::group::$*"; }
endg(){ echo "::endgroup::"; }

# ---------------------------------------------------------------
# 1) 主源码（pbs05/ponwrt 的 master 分支同时含 an7581 与 an7583 子目标）
# ---------------------------------------------------------------
group "克隆 pbs05/ponwrt (master)"
git clone --depth 1 https://github.com/pbs05/ponwrt.git "$SRC"
cd "$SRC"

# 编译缓存：dl 与 ccache 放到源码树之外，由 Actions cache 跨构建复用
mkdir -p "$REPO/cache/dl" "$REPO/cache/ccache"
[ -e "$SRC/dl" ] || ln -s "$REPO/cache/dl" "$SRC/dl"
[ -e "$SRC/.ccache" ] || ln -s "$REPO/cache/ccache" "$SRC/.ccache"
endg

# ---------------------------------------------------------------
# 2) feeds：与 build.yml 完全一致，保证四机型插件集合相同
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
# 2.5) Aurora 主题 + 配置插件（第三方，不在 immortalwrt/luci 里）
#      eamonxg 的两个仓库（主题 + 配置插件）根目录都是标准 package 结构，
#      clone 后整体拷进 package/。主题要求 OpenWrt 23.05+（ucode LuCI），
#      本源码树满足；包自带 30_luci-theme-aurora 首次启动设默认，
#      99-lang-theme 再兜底。配置插件提供 5 套预设 / 明暗色板 / 布局自定义。
# ---------------------------------------------------------------
group "引入 Aurora 主题与配置插件"
AURORA_DIR="$SRC/package/luci-theme-aurora"
AURORA_CFG_DIR="$SRC/package/luci-app-aurora-config"
if [ ! -f "$AURORA_DIR/Makefile" ] || [ ! -f "$AURORA_CFG_DIR/Makefile" ]; then
  rm -rf /tmp/aurora-src /tmp/aurora-cfg-src
  git clone --depth 1 https://github.com/eamonxg/luci-theme-aurora.git /tmp/aurora-src
  git clone --depth 1 https://github.com/eamonxg/luci-app-aurora-config.git /tmp/aurora-cfg-src
  mkdir -p "$AURORA_DIR" "$AURORA_CFG_DIR"
  cp -a /tmp/aurora-src/. "$AURORA_DIR/"
  cp -a /tmp/aurora-cfg-src/. "$AURORA_CFG_DIR/"
  rm -rf /tmp/aurora-src /tmp/aurora-cfg-src
fi
grep -q 'LUCI_TITLE:=Aurora Theme' "$AURORA_DIR/Makefile" || {
  echo "::error::Aurora 主题源码不完整"
  exit 1
}
grep -q 'LuCI configuration UI for the Aurora theme' "$AURORA_CFG_DIR/Makefile" || {
  echo "::error::Aurora 配置插件源码不完整"
  exit 1
}
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

# 3.5 网络转发调优：RPS 把 RX 软中断分散到 CPU1-3，RFS 按 socket 流建哈希。
#     BBR 由 kmod-tcp-bbr 包自带 sysctl 落地，这里只补 RFS 的内核参数。
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

# 3.6 代理转发调优：TCP 缓冲扩容 + conntrack 上限 + dnsmasq 缓存。
#     OpenClash/Passwall 向代理服务器发起的出站连接是本机 TCP，BBR 配合大缓冲
#     才能撑满高延迟大带宽链路（200ms RTT x 300Mbps 约 7.5MB 窗口，默认上限不够）；
#     conntrack 65536 应对 mihomo 大量 UDP/QUIC 短连接，避免表满丢连接。
cat > "$OVL/etc/sysctl.d/91-proxy-tuning.conf" <<'PROXYTUNE'
# TCP/UDP 缓冲上限 16MB：tcp_rmem/wmem 第三列是内核自动调优上限
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# conntrack：代理 UDP/QUIC 海量短连接
net.netfilter.nf_conntrack_max = 65536
PROXYTUNE

# dnsmasq 缓存扩容：分流场景 DNS 查询量大，加大命中缓存降低首包延迟
cat > "$OVL/etc/uci-defaults/98-dns-cache" <<'DNSCACHE'
uci -q set dhcp.@dnsmasq[0].cachesize='2000'
uci -q commit dhcp
DNSCACHE

# 3.1 登录密码 root
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

# 3.3 WiFi：hg5585f 系列 SSID 以机型命名，密码 88888888
#     cu -> HG5585F-CU；mf(xg-040g 系列) 无 WiFi，跳过
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
# 3.4 默认简体中文 + 默认主题（uci-defaults 开机首次执行，99- 前缀保证最后覆盖）
#     dispatcher 读取 luci.main.lang：'zh_cn' 会被转成 'zh-cn' 去加载
#     /usr/lib/lua/luci/i18n/*.zh-cn.lmo（由 luci-i18n-*-zh-cn 包提供）。
#     Aurora 包自带 30_luci-theme-aurora 首次安装会设默认，这里 99- 兜底
#     （显式把 mediaurlbase 指向 aurora，防止任何旧值残留）。
cat > "$OVL/etc/uci-defaults/99-lang-theme" <<LANGTHEME
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q set luci.themes.Aurora='/luci-static/aurora'
uci -q set luci.main.mediaurlbase='/luci-static/aurora'
uci -q commit luci
exit 0
LANGTHEME
chmod +x "$OVL/etc/uci-defaults/"*
endg

# ---------------------------------------------------------------
# 4) OpenClash 内置核心：Mihomo aarch64 静态二进制
# ---------------------------------------------------------------
group "内置 OpenClash 内核 (Mihomo ${MIHOMO_VERSION})"
CORE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-arm64-${MIHOMO_VERSION}.gz"
if ! curl -fL --retry 3 -o /tmp/mihomo.gz "$CORE_URL"; then
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
# 5) 预置源码包：an7583 的 DEFAULT_PACKAGES 同样含 uboot-envtools
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
# 6) .config：平台按 subtarget 动态写入
#    设备符号 CONFIG_TARGET_airoha_<subtarget>_DEVICE_<profile>=y
# ---------------------------------------------------------------
group "生成 .config (${SUBTARGET} / ${PROFILE})"
# ccache 选项默认带可见性条件（bool "Use ccache" if DEVEL），DEVEL 未开时
# kconfig 视为不可见符号，defconfig 会把它重置回默认值 n，种子里写 y 也无效。
# 这里去掉该条件，让 CONFIG_CCACHE=y 真正生效；不影响其他开发选项。
sed -i 's/^\([[:space:]]*\)bool "Use ccache" if DEVEL$/\1bool "Use ccache"/' config/Config-devel.in
grep -q 'bool "Use ccache"$' config/Config-devel.in || {
  echo "::error::改写 ccache 可见性失败，config/Config-devel.in 结构可能已变"
  exit 1
}
{
  echo "CONFIG_TARGET_airoha=y"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}=y"
  echo 'CONFIG_TARGET_BOARD="airoha"'
  echo "CONFIG_TARGET_SUBTARGET=\"${SUBTARGET}\""
  echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
  cat "$SEED"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y"
} > .config

make defconfig

# ccache 是构建加速项，未生效不阻塞出固件，但要显式告警
if grep -q "^CONFIG_CCACHE=y$" .config; then
  echo "ccache: 已启用"
else
  echo "::warning::CONFIG_CCACHE 未生效，本次构建不会写编译缓存"
fi

if ! grep -q "^CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y$" .config; then
  echo "::error::机型设备未选中: ${SUBTARGET} / ${PROFILE}"
  echo "--- .config 中实际选中的设备符号 ---"
  grep -E "^CONFIG_TARGET_.*_DEVICE_.*=y$" .config | head -20 || true
  echo "--- 含 ${PROFILE} 的所有行 ---"
  grep -n "$PROFILE" .config | head -20 || true
  exit 1
fi
echo "已选设备: $(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' .config | tr '\n' ' ')"
grep -E "^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=" .config || true

# 关闭设备独立 bootloader / ATF / 外部交叉工具链包
KEYS="$(grep -E '^CONFIG_PACKAGE_(u-boot-|trusted-firmware-a-|arm-gnu-toolchain)[^=]*=y$' .config | sed 's/=y$//' || true)"
for k in $KEYS; do
  sed -i "s|^${k}=y|# ${k} is not set|" .config
done

# ---------------------------------------------------------------
# an7583 专属修复：XG-040G-MF(UBI) 设备除 sysupgrade.itb 外还定义了
#   ARTIFACTS := bl31-uboot.fip preloader.bin
# 这两个 ARTIFACT 是「首次烧录用」的独立 bootloader，生成时要调用 host
# 工具 fiptool（由 arm-trusted-firmware-tools/host 提供），其输入
# bl2.bin / bl31.lzma / u-boot.lzma 又由上面刚禁用的 ATF / u-boot 包产出。
# 于是云端上一轮报 `fiptool: No such file or directory` → target/linux
# 构建失败（Error 127）。它们不属于 sysupgrade 固件，直接移除 ARTIFACT
# 定义，只保留 IMAGES := sysupgrade.itb，与 an7581 三机型处理一致。
# ---------------------------------------------------------------
if [ "$SUBTARGET" = "an7583" ]; then
  group "移除 an7583 独立 bootloader ARTIFACT 规则（修复 fiptool 缺失）"
  MK="target/linux/airoha/image/an7583.mk"
  sed -i -E '/^[[:space:]]*ARTIFACT/d' "$MK"
  echo "剩余 ARTIFACT 定义行数: $(grep -cE '^[[:space:]]*ARTIFACT' "$MK" || true)"
  echo "--- mf-ubi 设备块（确认只产 sysupgrade.itb）---"
  sed -n '/define Device\/nokia_xg-040g-mf-ubi/,/^endef/p' "$MK"
  endg
fi

# 严格校验：用户要求的包必须全部入选
for p in luci-app-onu luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug \
         luci-app-airoha-npu luci-app-qmodem-next qmodem luci-app-openclash \
         luci-app-passwall luci-app-cpufreq xray-core \
         luci-theme-aurora luci-app-aurora-config luci-i18n-base-zh-cn \
         usb-modeswitch kmod-usb-net-qmi-wwan chat comgt \
         kmod-usb-serial-sierrawireless kmod-mtk-t7xx \
         autocore kmod-crypto-hw-eip93 kmod-cryptodev openssl-util \
         libopenssl-devcrypto kmod-tcp-bbr; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::配置缺少 ${p}"
    exit 1
  fi
done
# 语言开关是 HIDDEN 中文包能否被选中的前提，必须存在
if ! grep -q "^CONFIG_LUCI_LANG_zh_Hans=y$" .config; then
  echo "::error::缺少 CONFIG_LUCI_LANG_zh_Hans，中文翻译包不会生效"
  exit 1
fi
echo "关键包校验通过（含中文 / Aurora 主题）"
endg
