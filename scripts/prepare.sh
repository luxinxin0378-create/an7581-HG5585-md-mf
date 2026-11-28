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
# 2.5a) 主题策略（2026-11-28 调整）：mac / Aurora 主题整体移除，
#       默认主题 Argon（jerrykuku 官方 v3.1.4，immortalwrt/luci feed
#       同步维护，OP 最火主题），唯一主题。
#       Argon 自带的 30- 抢默认脚本由 files 覆盖废掉（见 3.4b），
#       默认主题写死在 files/etc/config/luci（3.0.1 静态配置文件化）。
# ---------------------------------------------------------------
group "主题策略：默认 Argon（mac / Aurora 已移除）"
grep -q "CONFIG_PACKAGE_luci-theme-argon=y" "$SEED" || {
  echo "::error::seed 缺少 luci-theme-argon（默认主题包）"; exit 1; }
echo "默认主题：Argon（feed 版）；唯一主题"
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
mkdir -p "$OVL/etc/uci-defaults" "$OVL/etc/openclash/core" "$OVL/etc/config"

# ---------------------------------------------------------------
# 3.0 静态配置文件化：原 uci-defaults 里的纯配置项（luci 主题语言 / 时区 /
#     NPU 卸载 / dnsmasq 缓存）改为从源树复制包默认 config 后增量修改，
#     以 files 覆盖进 rootfs —— 首启即终态，彻底消除 uci-defaults 并行
#     commit race；运行时逻辑类脚本（wifi/zte-wan/lan25g/qmodem/smsf/
#     ddnsto）仍保留 uci-defaults。每步带校验，失败即中断构建。
# ---------------------------------------------------------------
group "静态配置文件化（luci / system / firewall / dhcp）"

# 3.0.1 LuCI：简体中文 + Argon 默认主题（替代 99-lang-theme / 30_luci-theme-argon）
LCFG="$SRC/feeds/luci/modules/luci-base/root/etc/config/luci"
[ -f "$LCFG" ] || { echo "::error::luci-base 默认 config 未找到"; exit 1; }
cp "$LCFG" "$OVL/etc/config/luci"
sed -i "s|option lang 'auto'|option lang 'zh_cn'|; s|option mediaurlbase .*|option mediaurlbase '/luci-static/argon'|" "$OVL/etc/config/luci"
grep -q "option lang 'zh_cn'" "$OVL/etc/config/luci" && \
grep -q "mediaurlbase '/luci-static/argon'" "$OVL/etc/config/luci" || {
  echo "::error::luci 静态配置生成失败"; exit 1; }

# 3.0.2 system：Asia/Shanghai + 国内 NTP + hostname 固化机型名（替代 99-timezone）
#   源树没有静态 system config——它和 network 一样由 config_generate 在
#   构建 rootfs 时生成，因此这里直接 patch config_generate 的出厂默认值
#   （与 LAN IP 的 patch 方案同构），出厂即终态。
CGF="$SRC/package/base-files/files/bin/config_generate"
[ -f "$CGF" ] || { echo "::error::config_generate 未找到"; exit 1; }
sed -i \
  -e "s|set system.@system\[-1\].hostname='ponwrt'|set system.@system[-1].hostname='$MODEL'|" \
  -e "s|set system.@system\[-1\].timezone='GMT0'|set system.@system[-1].timezone='CST-8'|" \
  -e "s|set system.@system\[-1\].zonename='UTC'|set system.@system[-1].zonename='Asia/Shanghai'|" \
  -e "s|add_list system.ntp.server='time.apple.com'|add_list system.ntp.server='ntp.aliyun.com'|" \
  -e "s|add_list system.ntp.server='time1.google.com'|add_list system.ntp.server='ntp.tencent.com'|" \
  -e "s|add_list system.ntp.server='time.cloudflare.com'|add_list system.ntp.server='cn.pool.ntp.org'|" \
  -e "s|add_list system.ntp.server='pool.ntp.org'|add_list system.ntp.server='time.ustc.edu.cn'|" \
  "$CGF"
grep -q "hostname='$MODEL'" "$CGF" && grep -q "timezone='CST-8'" "$CGF" && \
grep -q "zonename='Asia/Shanghai'" "$CGF" && grep -q "ntp.aliyun.com" "$CGF" || {
  echo "::error::config_generate system 默认值 patch 失败"; exit 1; }

# 3.0.3 firewall：NPU 硬件流卸载默认开启（替代 95-npu-offload）
#   上游 firewall.config 已自带 flow_offloading=1（软件卸载默认开），只补
#   硬件卸载开关；真实源文件是 files/firewall.config（由包 Makefile 拷成
#   /etc/config/firewall），files 覆盖同名文件即生效。
FWF="$SRC/package/network/config/firewall/files/firewall.config"
[ -f "$FWF" ] || { echo "::error::firewall 默认 config 未找到"; exit 1; }
python3 - "$FWF" "$OVL/etc/config/firewall" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
if "flow_offloading_hw" in t:
    open(sys.argv[2], "w").write(t)
    sys.exit(0)
t2, n = re.subn(r"(\toption flow_offloading\t1\n)",
                "\\1\toption flow_offloading_hw\t1\n", t, count=1)
if n != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(t2)
PY
[ $? -eq 0 ] || { echo "::error::firewall 静态配置生成失败"; exit 1; }
grep -q "flow_offloading_hw" "$OVL/etc/config/firewall" || {
  echo "::error::firewall flow_offloading_hw 校验失败"; exit 1; }

# 3.0.4 dhcp：无需注入——上游 dnsmasq 默认 dhcp.conf 已自带 cachesize 8000
#   （比原 98-dns-cache 配方 2000 更大），保持上游值，不再 files 覆盖。

# ---------------------------------------------------------------
# 3.0.2' 时区/NTP：已由 3.0.2 patch config_generate 实现（出厂默认值），
#       原配方见 99-timezone 删除记录；开机 uci-defaults 不再涉及时区。
# ---------------------------------------------------------------


# 3.4 概览页数据脚本 + 自定义系统块（覆盖 luci-mod-status 10_system.js）
#     数据脚本：cpuinfo（架构+频率，rpcd getCPUInfo）/ cpufreq_real（PLL 直读）/
#     ppeinfo（PPE FOE 表占用）。tempinfo 已随温度行移除（2026-11-28）——
#     上游原版 JS 的温度行与架构行末尾温度重复显示，现自定义 JS 不再显示温度。
#     新增：PPE 行（硬件转发引擎表占用）、CPU 频率行、固件编译时间行（注入）；
#     缺失数据的行动态隐藏，不显示 ?。与个人版 3.1b 同款。
mkdir -p "$OVL/sbin" "$OVL/www/luci-static/resources/view/status/include"
install -m 0755 "$REPO/config/overlay/sbin/cpuinfo"      "$OVL/sbin/cpuinfo"
install -m 0755 "$REPO/config/overlay/sbin/cpufreq_real" "$OVL/sbin/cpufreq_real"
install -m 0755 "$REPO/config/overlay/sbin/ppeinfo"      "$OVL/sbin/ppeinfo"

BUILD_TIME="$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')"
cat > "$OVL/www/luci-static/resources/view/status/include/10_system.js" <<'JSEOF'
'use strict';
'require baseclass';
'require fs';
'require rpc';
'require uci';

var callGetUnixtime = rpc.declare({
	object: 'luci',
	method: 'getUnixtime',
	expect: { result: 0 }
});

var callLuciVersion = rpc.declare({
	object: 'luci',
	method: 'getVersion'
});

var callSystemBoard = rpc.declare({
	object: 'system',
	method: 'board'
});

var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info'
});

var callCPUBench = rpc.declare({
	object: 'luci',
	method: 'getCPUBench'
});

var callCPUInfo = rpc.declare({
	object: 'luci',
	method: 'getCPUInfo'
});

var callCPUUsage = rpc.declare({
	object: 'luci',
	method: 'getCPUUsage'
});

var FW_BUILD_TIME = '__BUILD_TIME__';

return baseclass.extend({
	title: _('System'),

	load: function() {
		return Promise.all([
			L.resolveDefault(callSystemBoard(), {}),
			L.resolveDefault(callSystemInfo(), {}),
			L.resolveDefault(callCPUBench(), {}),
			L.resolveDefault(callCPUInfo(), {}),
			L.resolveDefault(callCPUUsage(), {}),
			L.resolveDefault(callLuciVersion(), { revision: _('unknown version'), branch: 'LuCI' }),
			L.resolveDefault(callGetUnixtime(), 0),
			L.resolveDefault(fs.read('/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq'), ''),
			L.resolveDefault(fs.read('/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq'), ''),
			L.resolveDefault(fs.read('/sys/devices/system/cpu/cpufreq/cpu0/cpuinfo_cur_freq'), ''),
			L.resolveDefault(fs.exec('/bin/sh', ['-c', '/sbin/cpufreq_real 2>/dev/null']), {}),
			L.resolveDefault(fs.exec('/bin/sh', ['-c', '/sbin/ppeinfo 2>/dev/null']), {}),
			uci.load('system')
		]);
	},

	render: function(data) {
		var boardinfo   = data[0],
		    systeminfo  = data[1],
		    cpubench    = data[2],
		    cpuinfo     = data[3],
		    cpuusage    = data[4],
		    luciversion = data[5],
		    unixtime    = data[6],
		    freqk1      = parseInt(data[7], 10),
		    freqk2      = parseInt(data[8], 10),
		    freqk3      = parseInt(data[9], 10),
		    freqk0      = (L.isObject(data[10]) && typeof data[10].stdout == 'string') ? parseInt(data[10].stdout, 10) : 0,
		    ppeRaw      = (L.isObject(data[11]) && typeof data[11].stdout == 'string') ? data[11].stdout.trim() : '';

		luciversion = luciversion.branch + ' ' + luciversion.revision;

		var datestr = null;

		if (unixtime) {
			var date = new Date(unixtime * 1000),
				zn = uci.get('system', '@system[0]', 'zonename')?.replaceAll(' ', '_') || 'UTC',
				ts = uci.get('system', '@system[0]', 'clock_timestyle') || 0,
				hc = uci.get('system', '@system[0]', 'clock_hourcycle') || 0;

			datestr = new Intl.DateTimeFormat(undefined, {
				dateStyle: 'medium',
				timeStyle: (ts == 0) ? 'long' : 'full',
				hourCycle: (hc == 0) ? undefined : hc,
				timeZone: zn
			}).format(date);
		}

		/* CPU 频率：优先 /sbin/cpufreq_real（PLL 寄存器直读真值——含 NPU 页的
		   PLL 直写超频，cpufreq sysfs 感知不到），sysfs 兜底，再兜底 cpuinfo
		   输出解析（格式 "…x 4 (1300MHz)"，rpcd 产物，必有） */
		var freqk = freqk0 || freqk1 || freqk2 || freqk3 || 0,
		    freqstr = null;

		if (freqk > 0) {
			freqstr = (freqk >= 1000000) ? '%.2f GHz'.format(freqk / 1000000) : '%d MHz'.format(Math.round(freqk / 1000));
		} else {
			var mf = (typeof cpuinfo.cpuinfo == 'string' ? cpuinfo.cpuinfo : '').match(/\((\d+)\s*MHz/);

			if (mf && parseInt(mf[1], 10) > 0)
				freqstr = (parseInt(mf[1], 10) >= 1000) ? '%.2f GHz'.format(parseInt(mf[1], 10) / 1000) : '%d MHz'.format(mf[1]);
		}

		/* PPE：/sbin/ppeinfo 输出（形如 "PPE0: 1/37, PPE1: 3/43, DRAM: 0/5"，
		   x/y = 硬件绑定中/表内总条目）；debugfs 缺失或不可读时隐藏该行 */
		var ppestr = (ppeRaw && ppeRaw != 'unavailable') ? ppeRaw : null;

		/* 固件编译时间：编译时注入（占位符用 indexOf 检测，避免 sed 误伤本行） */
		var buildstr = (FW_BUILD_TIME && FW_BUILD_TIME.indexOf('BUILD') < 0) ? FW_BUILD_TIME : null;

		var fields = [
			_('Hostname'),         boardinfo.hostname,
			_('Model'),            boardinfo.model + cpubench.cpubench,
			_('Architecture'),     cpuinfo.cpuinfo || boardinfo.system,
			_('Target Platform'),  (L.isObject(boardinfo.release) ? boardinfo.release.target : ''),
			_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),
			_('Kernel Version'),   boardinfo.kernel,
			_('Local Time'),       datestr,
			_('Uptime'),           systeminfo.uptime ? '%t'.format(systeminfo.uptime) : null,
			_('Load Average'),     Array.isArray(systeminfo.load) ? '%.2f, %.2f, %.2f'.format(
				systeminfo.load[0] / 65535.0,
				systeminfo.load[1] / 65535.0,
				systeminfo.load[2] / 65535.0
			) : null,
			_('CPU usage (%)'),    cpuusage.cpuusage
		];

		/* 缺失数据的行动态隐藏；编译时间紧跟固件版本，频率紧跟内核，PPE 殿后 */
		var ins = 5;

		if (buildstr) {
			fields.splice(ins, 0, _('固件编译时间'), buildstr);
			ins += 2;
		}

		if (freqstr) {
			fields.splice(ins, 0, _('CPU 频率'), freqstr);
			ins += 2;
		}

		if (ppestr)
			fields.push(_('PPE'), ppestr);

		var table = E('table', { 'class': 'table' });

		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
				E('td', { 'class': 'td left' }, [ (fields[i + 1] != null) ? fields[i + 1] : '?' ])
			]));
		}

		return table;
	}
});
JSEOF
# 只替换定义行（^var FW_BUILD_TIME），避免误伤其他引用占位符的逻辑行
sed -i "/^var FW_BUILD_TIME = /s|__BUILD_TIME__|$BUILD_TIME|" "$OVL/www/luci-static/resources/view/status/include/10_system.js"
# 自检：构建日志打印注入结果，未替换或仍含占位符则报错
INJECTED="$(grep -o "FW_BUILD_TIME = '[^']*'" "$OVL/www/luci-static/resources/view/status/include/10_system.js" | head -1)"
echo "BUILD_TIME 注入结果: $INJECTED"
echo "$INJECTED" | grep -q "FW_BUILD_TIME = '20" || { echo "::error::固件编译时间注入失败"; exit 1; }
grep -q "ppeinfo" "$OVL/www/luci-static/resources/view/status/include/10_system.js" || {
  echo "::error::10_system.js 缺少 PPE 数据源"; exit 1; }

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

# dnsmasq 缓存：上游 dhcp.conf 默认 cachesize 8000（优于旧配方 2000），无需覆盖

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
# 3.4 默认简体中文 + 默认主题 Argon —— 已由 3.0.1 静态配置文件化
#     （files/etc/config/luci，首启即终态）；Argon 包自带 30- 迁移脚本
#     的写入值与静态文件一致（mediaurlbase=argon），即使后 commit 也幂等，
#     原 99-lang-theme / 30_luci-theme-argon 两个脚本删除，race 根除。
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
         luci-theme-argon luci-i18n-base-zh-cn \
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
echo "关键包校验通过（含中文 / Argon 主题）"
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)' .config
endg

