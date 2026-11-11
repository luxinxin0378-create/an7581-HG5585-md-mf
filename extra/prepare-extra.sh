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
# 3) 机型定制（OpenWrt files/ overlay，直接编进 rootfs）
# ---------------------------------------------------------------
group "注入机型定制 ($MODEL)"
OVL="$SRC/files"
mkdir -p "$OVL/etc/uci-defaults" "$OVL/etc/openclash/core"

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

# 严格校验：用户要求的包必须全部入选
for p in luci-app-onu luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug \
         luci-app-airoha-npu luci-app-qmodem-next qmodem luci-app-openclash \
         luci-app-passwall luci-app-cpufreq xray-core; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::配置缺少 ${p}"
    exit 1
  fi
done
echo "关键包校验通过"
endg
