#!/usr/bin/env bash
# 云端构建准备：拉取源码 / 配置 feeds / 注入机型定制 / 内置内核 / 生成 .config
# 由 .github/workflows/build.yml 调用，运行在 GitHub-hosted runner 上。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
SUBTARGET="${3:-an7581}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.33}"

REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
# 默认用正式版种子；测试构建可用 SEED_FILE 指向另一份 .config 种子
SEED="${SEED_FILE:-$REPO/config/seed.config}"

case "$SUBTARGET" in
  an7581|an7583) ;;
  *) echo "::error::不支持的 Airoha 子目标: ${SUBTARGET}"; exit 1 ;;
esac
case "$MODEL:$SUBTARGET" in
  hg5585f-ct:an7581|hg5585f-cu:an7581|xg-040g-md:an7581|xg-040g-mf:an7583|h3c_hm2004-du:an7581) ;;
  *) echo "::error::机型与 Airoha 子目标不匹配: ${MODEL} / ${SUBTARGET}"; exit 1 ;;
esac

group(){ echo "::group::$*"; }
endg(){ echo "::endgroup::"; }

# ---------------------------------------------------------------
# 1) 主源码
# ---------------------------------------------------------------
group "克隆 pbs05/ponwrt"
git clone --depth 1 https://github.com/pbs05/ponwrt.git "$SRC"
cd "$SRC"

# 出厂默认 LAN IP 写进配置生成器（不使用 uci-defaults）：
#   config_generate 生成固件自带的 /etc/config/network 默认值，新装/重置后
#   LAN 直接就是 192.168.2.1；保留配置升级时 sysupgrade 回写用户的
#   /etc/config/network，config_generate 不参与生成——用户已改的 LAN IP
#   不会被覆盖回默认（修复「升级后网关被重置」）。
CG="$SRC/package/base-files/files/bin/config_generate"
[ -f "$CG" ] || { echo "::error::config_generate 不存在"; exit 1; }
sed -i 's|ipaddr:-"192.168.1.1"|ipaddr:-"192.168.2.1"|' "$CG"
grep -q 'ipaddr:-"192.168.2.1"' "$CG" || {
  echo "::error::config_generate 默认 LAN IP patch 失败"; exit 1; }
echo "config_generate 出厂 LAN IP → 192.168.2.1"

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
#    - luci-app-openclash / luci-app-cpufreq 由 immortalwrt/luci feed 提供
#    - luci-app-passwall 由 Openwrt-Passwall/passwall feed 提供，
#      依赖包（xray-core/tcping/geoview/chinadns-ng 等）来自 passwall_packages feed，
#      它与 immortalwrt/packages 存在同名包（tcping 等），必须后注册以覆盖
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
src-git qmodem https://github.com/FUjr/QModem.git;main
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git
src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git
FEEDS
cat feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
endg

# ---------------------------------------------------------------
# 2.5) Aurora 主题 + 配置插件（第三方，不在 immortalwrt/luci 里）
#      eamonxg 的两个仓库（主题 + 配置插件）根目录都是标准 package 结构，
#      clone 后整体拷进 package/。主题要求 OpenWrt 23.05+（ucode LuCI），
#      本源码树满足；其 30- uci-defaults 的抢默认行为已在 3.4a 用 files 覆盖废掉（保留注册）。
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
# 2.5a) 主题策略（2026-11-26 调整）：mac 主题整体移除，默认主题改为
#       Argon（jerrykuku 官方 v3.1.4，immortalwrt/luci feed 同步维护，
#       OP 最火主题）；Aurora 保留可切换。
#       Argon 与 Aurora 自带的 30- 抢默认脚本均由 files 覆盖废掉
#       （见 3.4a / 3.4b），默认统一由 99-lang-theme 指定。
# ---------------------------------------------------------------
group "主题策略：默认 Argon（mac 已移除，Aurora 保留）"
grep -q "CONFIG_PACKAGE_luci-theme-argon=y" "$SEED" || {
  echo "::error::seed 缺少 luci-theme-argon（默认主题包）"; exit 1; }
grep -q "CONFIG_PACKAGE_luci-theme-aurora=y" "$SEED" || {
  echo "::error::seed 缺少 luci-theme-aurora（可切换主题包）"; exit 1; }
echo "默认主题：Argon（feed 版）；可切换：Aurora"
endg

# ---------------------------------------------------------------
# 2.5b) ddnsto 内网穿透（koolcenter 官方闭源 ipk，中文界面）
#       闭源预编译包无法走 buildroot feeds，构建时下载进 files/，
#       首次开机由 uci-defaults 执行 opkg 离线安装并注册自启
# ---------------------------------------------------------------
group "下载 ddnsto 离线包"
DDNSTO_BASE="http://fw.koolcenter.com/binary/ddnsto/openwrt"
mkdir -p "$SRC/files/root"
for f in standard/4.2.8/ddnsto_aarch64.ipk luci-app-ddnsto.ipk luci-i18n-ddnsto-zh-cn.ipk; do
  fn="$(basename "$f")"
  curl -fsSLk "$DDNSTO_BASE/$f" -o "$SRC/files/root/$fn" || { echo "::error::ddnsto 下载失败: $fn"; exit 1; }
  [ -s "$SRC/files/root/$fn" ] || { echo "::error::ddnsto 包为空: $fn"; exit 1; }
done
for f in ddnsto_aarch64.ipk luci-app-ddnsto.ipk luci-i18n-ddnsto-zh-cn.ipk; do
  test -s "$SRC/files/root/$f" || { echo "::error::ddnsto 包缺失: $f"; exit 1; }
done
ls -lh "$SRC/files/root/" | grep ipk
echo "ddnsto 三个离线包就绪（客户端 4.2.8 + LuCI 界面 + 中文包）"
endg

# ---------------------------------------------------------------
# 2.5c) luci-app-accesscontrol（上网时段管控，afala2020 版）
#       单包仓库且 immortalwrt/luci 未收录，clone 拷入 package/（与 NPU 包同模式）。
#       原版 Makefile 用相对路径 include ../../luci.mk（仅 feed 子目录层级有效），
#       拷入 package/ 顶层后解析失败导致包被构建系统静默跳过，须改为 $(TOPDIR) 绝对路径。
#       wechatpush（微信推送）已由 immortalwrt/luci feed 直接收录，无需拷入。
# ---------------------------------------------------------------
group "引入 luci-app-accesscontrol (afala2020)"
AC_DIR="$SRC/package/luci-app-accesscontrol"
if [ ! -f "$AC_DIR/Makefile" ]; then
  rm -rf /tmp/accesscontrol-src
  git clone --depth 1 https://github.com/afala2020/luci-app-accesscontrol.git /tmp/accesscontrol-src
  mkdir -p "$AC_DIR"
  cp -a /tmp/accesscontrol-src/. "$AC_DIR/"
  rm -rf /tmp/accesscontrol-src
fi
sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' "$AC_DIR/Makefile"
# po 目录名对齐官方规范：旧式 zh-cn → zh_Hans（官方语言代码，i18n 包名仍为 -zh-cn，
# 且受已有的 CONFIG_LUCI_LANG_zh_Hans=y 语言开关控制；否则开关名非法导致包不被选中）
mv "$AC_DIR/po/zh-cn" "$AC_DIR/po/zh_Hans" 2>/dev/null || true
test -d "$AC_DIR/po/zh_Hans" || { echo "::error::accesscontrol po 目录改名失败"; exit 1; }
grep -q 'feeds/luci/luci.mk' "$AC_DIR/Makefile" || { echo "::error::accesscontrol Makefile include 修复失败"; exit 1; }
grep -q 'LUCI_TITLE' "$AC_DIR/Makefile" || { echo "::error::luci-app-accesscontrol 源码不完整"; exit 1; }
echo "luci-app-accesscontrol 就绪"
endg

# ---------------------------------------------------------------
# 2.7) luci-app-airoha-npu 覆盖为 rchen14b 版（带 CPU PLL 超频）
#      feeds 里的同名包为 naoki66 版，CPU 超频能力不明；rchen14b 版
#      （v1.0.1）明确带 AIROHA_OC_MAX_MHZ 上限配置 + devmem PLL 直写
#      （500-1600MHz，与 ATF BL31 en7523_armpll_set 同法），
#      AN7581/AN7583 双 SoC 检测（compatible 优先，chip-id 回退），
#      与个人版同源。package/ 目录优先级高于 feeds，直接同名覆盖。
# ---------------------------------------------------------------
group "覆盖 luci-app-airoha-npu 为 rchen14b 版 (PLL 超频)"
NPU_DIR="$SRC/package/luci-app-airoha-npu"
rm -rf /tmp/airoha-npu-src "$NPU_DIR"
git clone --depth 1 https://github.com/rchen14b/luci-app-airoha-npu.git /tmp/airoha-npu-src || {
  echo "::error::rchen14b/luci-app-airoha-npu 克隆失败"; exit 1; }
mkdir -p "$NPU_DIR"
cp -a /tmp/airoha-npu-src/. "$NPU_DIR/"
rm -rf /tmp/airoha-npu-src
# 确认后端带超频实现（AIROHA_OC_MAX_MHZ 上限配置 + devmem PLL 写入）
grep -q 'AIROHA_OC_MAX_MHZ' "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" || {
  echo "::error::该版本不含 CPU 超频实现（AIROHA_OC_MAX_MHZ），请检查仓库"
  exit 1
}
grep -q 'devmem' "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" || {
  echo "::error::该版本后端缺 devmem 超频路径，请检查仓库"
  exit 1
}
echo "luci-app-airoha-npu 已覆盖为 rchen14b 版（含 PLL 超频 500-1600MHz）"
# 注入中文翻译（rchen14b 上游只有西语 po）：po/zh_Hans 使构建系统生成
# luci-i18n-airoha-npu-zh-cn 包（seed 显式 =y，与 wol/smartdns 同模式）。
mkdir -p "$NPU_DIR/po/zh_Hans" "$NPU_DIR/luci-app-airoha-npu/po/zh_Hans"
cp "$REPO/extra/files/npu-zh.po" "$NPU_DIR/po/zh_Hans/luci-app-airoha-npu.po"
cp "$REPO/extra/files/npu-zh.po" "$NPU_DIR/luci-app-airoha-npu/po/zh_Hans/luci-app-airoha-npu.po"
grep -q 'msgstr "CPU 频率"' "$NPU_DIR/po/zh_Hans/luci-app-airoha-npu.po" || {
  echo "::error::npu 中文 po 注入失败"; exit 1; }
echo "luci-app-airoha-npu 中文翻译已注入"
endg

# ---------------------------------------------------------------
# 3) 机型定制（OpenWrt files/ overlay，直接编进 rootfs）
# ---------------------------------------------------------------
group "注入机型定制 ($MODEL)"
OVL="$SRC/files"
mkdir -p "$OVL/etc/uci-defaults" "$OVL/etc/openclash/core"

# ---------------------------------------------------------------
# 3.0a NPU 硬件流卸载默认开启（Airoha PPE + NPU 硬件转发）
#   flowtable 内核支持由 kmod-nft-offload 提供（上游 airoha generic config
#   NF_FLOW_TABLE 未编入，必须装包；NET_AIROHA_NPU=y 驱动已内置）。
#   开启后 forward 链直连流量经 PPE/NPU 硬件转发；PassWall 代理流量在
#   mangle/nat prerouting 即被 REDIRECT/TPROXY 到本机终结，不进 forward
#   链，不受卸载影响。uci-defaults 仅刷机后首次开机执行，用户之后手动
#   关闭不会被回写。
# ---------------------------------------------------------------
cat > "$OVL/etc/uci-defaults/95-npu-offload" <<'NPUOFF'
#!/bin/sh
uci -q set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@defaults[0].flow_offloading_hw='1'
uci -q commit firewall
exit 0
NPUOFF

# ---------------------------------------------------------------
# 3.0 默认时区：中国标准时间（Asia/Shanghai UTC+8）+ 国内 NTP
#     LuCI 时区下拉依赖 zoneinfo 数据包（seed 提供 core+asia）；
#     时间准确是 VMess/TLS 代理握手的前提。
# ---------------------------------------------------------------
cat > "$OVL/etc/uci-defaults/99-timezone" <<'TZ'
#!/bin/sh
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp
uci -q set system.ntp=timeserver
uci -q set system.ntp.enabled='1'
uci -q add_list system.ntp.server='ntp.aliyun.com'
uci -q add_list system.ntp.server='ntp.tencent.com'
uci -q add_list system.ntp.server='cn.pool.ntp.org'
uci -q commit system
exit 0
TZ


# 3.4 概览页频率/温度显示：LuCI 状态页通过 /sbin/cpuinfo、/sbin/tempinfo 读数。
#     autocore 只在 ipq*/mediatek*/qualcommax* 安装这两个脚本，airoha 不在其列，
#     因此直接从本仓库 overlay 注入，不引入 autocore 包、不改 .config。
mkdir -p "$OVL/sbin"
install -m 0755 "$REPO/config/overlay/sbin/cpuinfo"      "$OVL/sbin/cpuinfo"
install -m 0755 "$REPO/config/overlay/sbin/tempinfo"     "$OVL/sbin/tempinfo"
install -m 0755 "$REPO/config/overlay/sbin/cpufreq_real" "$OVL/sbin/cpufreq_real"

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

# 3.65 2.5G 口并入 LAN 桥：XG-040G md/mf 的 2.5G RJ45 是独立 GMAC（gdm4），
#     netdev 名为 lan1（EN8811H 2500base-x）。上游 99-default_network 只把
#     eth0（gsw 交换的 1G 口）桥进 br-lan，lan1 未进任何接口 → 有驱动但不通。
#     仅当系统存在 lan1 netdev（即 md/mf）时追加；hg5585f 无 lan1 自动跳过。
cat > "$OVL/etc/uci-defaults/97-lan25g-bridge" <<'LAN25G'
#!/bin/sh
[ -e /sys/class/net/lan1 ] || exit 0
for d in $(uci -q show network | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
  [ "$(uci -q get network.$d.name)" = "br-lan" ] || continue
  case " $(uci -q get network.$d.ports 2>/dev/null) " in
    *" lan1 "*) ;;
    *) uci add_list network.$d.ports='lan1' ;;
  esac
done
uci commit network
exit 0
LAN25G

# 3.66 QModem v3.2.0 rpcd 加载链修复：rpcd 分发脚本漏加载 cmds/<vendor>.sh，
#     quectel 专属 cmd_*（型号/制造商/固件版本/温度/电压）函数不存在 →
#     概览页 base_info 只剩 AT端口/连接状态。幂等补丁：已含加载行或 main
#     分支新架构（无 modem_util 引用）自动跳过。
cat > "$OVL/etc/uci-defaults/95-qmodem-rpcd-cmds" <<'RPCDFIX'
RPCD=/usr/libexec/rpcd/qmodem
if [ -f "$RPCD" ] && ! grep -qF 'cmds/${vendor}.sh' "$RPCD"; then
	sed -i 's|^\([[:space:]]*\)\. /usr/share/qmodem/modem_util.sh$|\1. /usr/share/qmodem/modem_util.sh\n\1[ -n "$vendor" ] \&\& [ -f "/usr/share/qmodem/cmds/${vendor}.sh" ] \&\& . "/usr/share/qmodem/cmds/${vendor}.sh"|' "$RPCD"
fi
exit 0
RPCDFIX

# 94.3 短信转发自愈：LuCI 表单对"等于默认值"的选项保存时不写入 UCI
#     （api_type 下拉框 default=webhook，界面显示着但配置里没有），
#     转发器读不到 api_type 就静默跳过实例 → 配了也不转发。
#     开机扫描：启用了但缺 api_type 的实例，按 api_config 特征自动补
#     类型（已有类型的不动，幂等；未启用的示例实例不碰）。
cat > "$OVL/etc/uci-defaults/94-smsf-apitype" <<'SMSF'
#!/bin/sh
[ -f /etc/config/sms_forwarder ] || exit 0
i=0
while uci -q get "sms_forwarder.@sms_forward_instance[$i]" >/dev/null 2>&1; do
  s="sms_forwarder.@sms_forward_instance[$i]"
  if [ "$(uci -q get "$s.enable")" = "1" ] && [ -z "$(uci -q get "$s.api_type")" ]; then
    ac=$(uci -q get "$s.api_config")
    t=""
    case "$ac" in
      *'"bot_token"'*)     t=tgbot ;;
      *'"pushkey"'*)       t=pushdeer ;;
      *'"recipient_uri"'*) t=sip ;;
      *open.feishu.cn*)    t=feishu ;;
      *'"token"'*)         t=serverchan ;;
      *'"webhook_url"'*)   t=webhook ;;
    esac
    [ -n "$t" ] && uci set "$s.api_type=$t"
  fi
  i=$((i+1))
done
uci commit sms_forwarder
exit 0
SMSF

# 96-passwall-dns：PassWall 远程 DNS 预置为 8.8.8.8（规避 1.1.1.1 anycast 路由黑洞）
#   根因（2026-11-26 设备实测）：PassWall 默认 remote_dns=1.1.1.1，生成 chinadns-ng
#   trust-dns tcp://1.1.1.1，所有境外域名解析都依赖该可信 DNS。而部分机房/线路对
#   Cloudflare 1.1.1.0/24 anycast 段路由黑洞（1.1.1.1 / 1.0.0.1 :443 全超时，
#   同机房 8.8.4.4:443 正常 302）→ 可信 DNS 永远无响应 → 境外域名解析挂起，
#   表现为「节点配置正确但没网」（国内直连不受影响）。
#   修复：预置 8.8.8.8（实测可达）。注意 remote_dns 必须存裸 IP —— PassWall
#   生成 chinadns-ng 配置时自动拼 tcp:// 前缀，存 'tcp://8.8.8.8' 会被二次
#   拼接成乱码 tcp://tcp://8.8.8.8（本次踩坑实录）。
#   仅当值为默认 1.1.1.1 / 空 / 带前缀默认值时覆盖，用户自定义 DNS 不动；
#   uci-defaults 仅刷机后首次开机执行，之后用户手动改的值不会被回写。
cat > "$OVL/etc/uci-defaults/96-passwall-dns" <<'PWDNS'
#!/bin/sh
[ -f /etc/config/passwall ] || exit 0
cur=$(uci -q get passwall.@global[0].remote_dns)
case "$cur" in
  ""|"1.1.1.1"|"tcp://1.1.1.1"|"udp://1.1.1.1")
    uci set passwall.@global[0].remote_dns='8.8.8.8'
    uci -q commit passwall
    ;;
esac
exit 0
PWDNS

# 3.6 代理转发调优：TCP 缓冲扩容 + conntrack 上限 + dnsmasq 缓存。
#     OpenClash/SSR-Plus 向代理服务器发起的出站连接是本机 TCP，BBR 配合大缓冲
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

# 3.2 登录 IP 192.168.2.1 —— 已移入 config_generate（clone 段 patch）：
#     出厂默认直接生成在固件 /etc/config/network 里，不再用 uci-defaults；
#     保留配置升级时用户改过的 LAN IP 不会被覆盖回默认。

# 3.3 WiFi：hg5585f 系列与 HM2004-DU，SSID 以机型命名(HG5585F-CT / HM2004-DU ...)，密码八个 8
#     不是 hg5585f/hm2004 的机型(如 xg-040g 系列)则跳过
case "$MODEL" in
  hg5585f-*|h3c_hm2004-du)
    SSID="$(printf '%s' "$MODEL" | sed 's/^h3c_hm2004-du$/HM2004-DU/' | tr '[:lower:]' '[:upper:]')"
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
#     默认主题 mac（见 99-lang-theme）；Aurora 包自带的 30- 脚本
#     会抢设 aurora 默认，已在下方 3.4a 用 files 覆盖废掉（只注册）。
# 3.5 远程访问：ddnsto 内网穿透（首次开机离线安装三件套并注册自启）
cat > "$OVL/etc/uci-defaults/99-ddnsto" <<'TS'
#!/bin/sh
# 首次开机安装 ddnsto 离线包（闭源预编译 ipk 无法走 buildroot feeds）
# 安装顺序：主程序 → LuCI 界面 → 中文语言包，然后注册开机自启
opkg install /root/ddnsto_aarch64.ipk 2>/dev/null
opkg install /root/luci-app-ddnsto.ipk 2>/dev/null
opkg install /root/luci-i18n-ddnsto-zh-cn.ipk 2>/dev/null
if command -v ddnsto >/dev/null 2>&1; then
  /etc/init.d/ddnsto enable 2>/dev/null || true
  rm -f /root/ddnsto_aarch64.ipk /root/luci-app-ddnsto.ipk /root/luci-i18n-ddnsto-zh-cn.ipk
else
  logger -t ddnsto "离线安装失败，ipk 保留在 /root/ 供手动排查"
fi
exit 0
TS

# 3.4a 废掉 Aurora 自带 uci-defaults 的「抢默认」行为（保留主题注册）
#     根因同个人版 Argon race：首启 uci-defaults 为并行后台执行，
#     Aurora 的 30- 脚本内含 mediaurlbase=/luci-static/aurora，
#     它 commit 慢、后到时会用旧快照把 mac 默认主题整个抹掉，
#     表现为首启默认主题随机变成 Aurora 且主题切换失效。
#     处理：files 覆盖 30_luci-theme-aurora 为「只注册、不设默认」版，
#     默认主题统一由 99-lang-theme 指定为 mac。
cat > "$OVL/etc/uci-defaults/30_luci-theme-aurora" <<'AURORAFIX'
#!/bin/sh
uci get luci.themes.Aurora >/dev/null 2>&1 || \
uci batch <<-EOF
	set luci.themes.Aurora=/luci-static/aurora
	commit luci
EOF
exit 0
AURORAFIX

cat > "$OVL/etc/uci-defaults/99-lang-theme" <<'LANGTHEME'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q set luci.themes.Argon='/luci-static/argon'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
LANGTHEME

# 3.4b 同款 race 防治：feed 版 Argon（jerrykuku v3.1.4）自带的 30- 脚本
#     会抢默认且慢 commit 时抹掉 Aurora 注册，files 覆盖为「只注册」版。
cat > "$OVL/etc/uci-defaults/30_luci-theme-argon" <<'ARGONFIX'
#!/bin/sh
uci get luci.themes.Argon >/dev/null 2>&1 || \
uci -q set luci.themes.Argon=/luci-static/argon
exit 0
ARGONFIX
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
group "生成 .config ($SUBTARGET / $PROFILE)"
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
  echo "CONFIG_TARGET_airoha=y"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}=y"
  echo 'CONFIG_TARGET_BOARD="airoha"'
  echo "CONFIG_TARGET_SUBTARGET=\"${SUBTARGET}\""
  echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
  cat "$SEED"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y"
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
if ! grep -q "^CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y$" .config; then
  echo "::error::机型设备未选中: ${SUBTARGET} / ${PROFILE}"
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
# 依据各设备 image 定义：本工作流仅需要 sysupgrade 固件，不依赖独立 bootloader artifacts。
KEYS="$(grep -E '^CONFIG_PACKAGE_(u-boot-|trusted-firmware-a-|arm-gnu-toolchain)[^=]*=y$' .config | sed 's/=y$//' || true)"
for k in $KEYS; do
  sed -i "s|^${k}=y|# ${k} is not set|" .config
done

# AN7583 的 XG-040G-MF UBI 设备还声明了首次烧录用 BL31/U-Boot 独立产物。
# 本工作流只发布 sysupgrade.itb，且上面已关闭对应 bootloader/ATF 包；
# 移除该临时源码树中的独立 ARTIFACT 规则，避免无关的 fiptool 产物步骤失败。
if [ "$SUBTARGET" = "an7583" ]; then
  MK="target/linux/airoha/image/an7583.mk"
  [ -f "$MK" ] || { echo "::error::缺少 AN7583 image 定义: $MK"; exit 1; }
  grep -q '^define Device/nokia_xg-040g-mf-ubi$' "$MK" || {
    echo "::error::上游未找到 XG-040G-MF UBI profile，停止构建"
    exit 1
  }
  sed -i -E '/^[[:space:]]*ARTIFACT/d' "$MK"
  if grep -qE '^[[:space:]]*ARTIFACT' "$MK"; then
    echo "::error::AN7583 独立 ARTIFACT 规则未能全部移除"
    exit 1
  fi
  echo "AN7583: 已保留 sysupgrade.itb，跳过独立 bootloader artifacts"
fi

# ---------------------------------------------------------------
# sysupgrade 元数据兼容修复：补全 image SUPPORTED_DEVICES
# ---------------------------------------------------------------
group "补全 image supported_devices（恢复系统内保留配置升级）"
# fwtool_check_image（an7581/an7583 subtarget 均 REQUIRE_IMAGE_METADATA=1）
# 用板子 DTS compatible（/tmp/sysinfo/board_name）比对镜像 metadata 的
# supported_devices。上游定义与之错位：
#   - fiberhome/nokia 各变体交叉写了对方的名字（不含自身 compatible）
#   - h3c_hm2004-du 与 an7583 的 mf/mf-ubi 完全未定义 SUPPORTED_DEVICES
#     （append-metadata 因条件为假不写 metadata）
# 结果：系统内（LuCI/sysupgrade）升级一律报
#   「Device not supported by this image」/「Image metadata not present」
# 被拒，只能走 U-Boot/recovery 引导刷写。补全后系统内保留配置升级恢复。
MK1="target/linux/airoha/image/an7581.mk"
MK2="target/linux/airoha/image/an7583.mk"
[ -f "$MK1" ] && [ -f "$MK2" ] || { echo "::error::缺少 airoha image 定义文件"; exit 1; }
sed -i \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-ct-usb-sfp$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-ct|' \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-ct$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-ct-usb-sfp|' \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-cu-usb-sfp$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-cu|' \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-cu$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-cu-usb-sfp|' \
  -e 's|^  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi-usb-sfp$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi|' \
  -e 's|^  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi-usb-sfp|' \
  -e 's|^  DEVICE_DTS := an7581-h3c-hm2004-du$|&\n  SUPPORTED_DEVICES += h3c,hm2004-du|' \
  "$MK1"
sed -i \
  -e 's|^  DEVICE_DTS := an7583-nokia_xg-040g-mf-ubi$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-mf-ubi|' \
  -e 's|^  DEVICE_DTS := an7583-nokia_xg-040g-mf$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-mf|' \
  "$MK2"
for dev in fiberhome,hg5585f-ct fiberhome,hg5585f-ct-usb-sfp \
           fiberhome,hg5585f-cu fiberhome,hg5585f-cu-usb-sfp \
           nokia,xg-040g-md-ubi nokia,xg-040g-md-ubi-usb-sfp \
           h3c,hm2004-du; do
  grep -q "^  SUPPORTED_DEVICES += ${dev}\$" "$MK1" || {
    echo "::error::AN7581 supported_devices 补全失败: ${dev}"; exit 1
  }
done
for dev in nokia,xg-040g-mf nokia,xg-040g-mf-ubi; do
  grep -q "^  SUPPORTED_DEVICES += ${dev}\$" "$MK2" || {
    echo "::error::AN7583 supported_devices 补全失败: ${dev}"; exit 1
  }
done
echo "supported_devices 补全完成（AN7581 +7 / AN7583 +2）"
endg

# 严格校验：用户要求的包必须全部入选
for p in luci-app-onu luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug \
         luci-app-airoha-npu luci-app-qmodem-next qmodem sms-forwarder-next luci-app-openclash \
         luci-app-passwall xray-core luci-app-cpufreq \
         zoneinfo-core zoneinfo-asia \
         luci-theme-argon luci-theme-aurora luci-app-aurora-config luci-i18n-base-zh-cn \
         usb-modeswitch kmod-usb-net-qmi-wwan chat comgt \
         kmod-usb-serial-sierrawireless kmod-mtk-t7xx \
         autocore kmod-crypto-hw-eip93 kmod-cryptodev openssl-util \
         libopenssl-devcrypto kmod-tcp-bbr \
         luci-app-wol luci-i18n-wol-zh-cn \
         smartdns luci-app-smartdns luci-i18n-smartdns-zh-cn \
         luci-app-hd-idle luci-i18n-hd-idle-zh-cn \
         luci-app-upnp luci-i18n-upnp-zh-cn \
         luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn \
         sqm-scripts luci-app-sqm luci-i18n-sqm-zh-cn \
         luci-compat luci-app-accesscontrol luci-i18n-accesscontrol-zh-cn \
         luci-app-wechatpush luci-i18n-wechatpush-zh-cn \
         udpxy luci-app-udpxy luci-i18n-udpxy-zh-cn \
         adguardhome luci-app-adguardhome luci-i18n-adguardhome-zh-cn \
         jq bash iputils-arping ${EXTRA_REQUIRED_PKGS:-}; do
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
# 反向校验：PassWall2/sing-box 已由 PassWall+Xray 取代，若 feeds 解析后被
# 连带选中（依赖残留）则立即失败，避免 opkg 安装阶段才暴露文件冲突
if grep -Eq '^CONFIG_PACKAGE_(luci-app-passwall2|sing-box)=y$' .config; then
  echo "::error::luci-app-passwall2/sing-box 不应被选中（代理已由 PassWall+Xray 内核取代）"
  grep -E '^CONFIG_PACKAGE_.*passwall|^CONFIG_PACKAGE_sing-box' .config || true
  exit 1
fi
# 反向校验：Tailscale 已由 ddnsto 取代，若依赖残留被连带选中则立即失败
if grep -Eq '^CONFIG_PACKAGE_(tailscale|luci-app-tailscale)=y$' .config; then
  echo "::error::tailscale 不应被选中（远程访问已由 ddnsto 离线包取代）"
  grep -E '^CONFIG_PACKAGE_.*tailscale' .config || true
  exit 1
fi
# 语言开关是 HIDDEN 中文包能否被选中的前提，必须存在
if ! grep -q "^CONFIG_LUCI_LANG_zh_Hans=y$" .config; then
  echo "::error::缺少 CONFIG_LUCI_LANG_zh_Hans，中文翻译包不会生效"
  exit 1
fi
echo "关键包校验通过（含中文 / mac + Aurora 主题）"
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)' .config
endg

