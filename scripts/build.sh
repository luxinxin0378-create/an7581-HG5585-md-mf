#!/usr/bin/env bash
# 下载全部源码包并编译单机型固件，产物按机型分目录收集。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
cd "$SRC"

group(){ echo "::group::$*"; }
endg(){ echo "::endgroup::"; }

group "下载源码包"
# 首次并行下载，个别源失败时用单任务重试补齐
make -j"$(nproc)" download || make -j1 download
endg

group "编译固件 ($MODEL)"
set +e
make -j"$(nproc)" V=s > "$REPO/build-${MODEL}.log" 2>&1
RC=$?
set -e
tail -n 25 "$REPO/build-${MODEL}.log"
if [ "$RC" -ne 0 ]; then
  echo "::error::编译失败，关键错误："
  grep -nE "Error [0-9]|error:|failed to build|No such file|fatal:|Killed" \
    "$REPO/build-${MODEL}.log" | tail -n 60 || true
  echo "::error::末尾 200 行日志："
  tail -n 200 "$REPO/build-${MODEL}.log"
  exit "$RC"
fi
endg

group "收集产物并按规则重命名"
OUT="$REPO/output/$MODEL"
mkdir -p "$OUT"
find bin/targets/airoha/an7581 -maxdepth 1 -type f \
  \( -name "*${PROFILE}*sysupgrade*" -o -name "*${PROFILE}*squashfs*" \) \
  -exec cp -v {} "$OUT/" \;
# 兜底：若 profile 名未出现在文件名里，收集该机型全部 sysupgrade 固件
if [ -z "$(ls -A "$OUT")" ]; then
  find bin/targets/airoha/an7581 -maxdepth 1 -type f \
    -name "*sysupgrade*" -exec cp -v {} "$OUT/" \;
fi
if [ -z "$(ls -A "$OUT")" ]; then
  echo "::error::未找到 sysupgrade 固件"
  exit 1
fi

# 命名规则：arioha-<机型>-R<NN 递加>-B26-<月>-<日>
# R 号来自 config/REVISION（每轮发版 +1），日期按北京时间
source "$REPO/scripts/name-firmware.sh"
FWNAME="$(firmware_basename "$MODEL" "$REPO/config/REVISION")"
MAIN="$(find "$OUT" -maxdepth 1 -type f -name '*sysupgrade*.itb' -print -quit)"
[ -n "$MAIN" ] || MAIN="$(find "$OUT" -maxdepth 1 -type f -name '*sysupgrade*' -print -quit)"
if [ -z "$MAIN" ]; then
  echo "::error::未定位到 sysupgrade 主固件"
  exit 1
fi
mv -v "$MAIN" "$OUT/${FWNAME}.itb"
echo "固件名: ${FWNAME}.itb"

{
  echo "固件名:   ${FWNAME}.itb"
  echo "机型:     $MODEL"
  echo "Profile:  $PROFILE"
  echo "原始产物: $(basename "$MAIN")"
  echo "源码:     $(git -C "$SRC" log -1 --format='pbs05/ponwrt %h %cd' --date=short 2>/dev/null || echo pbs05/ponwrt)"
  echo "构建:     GitHub Actions run ${GITHUB_RUN_NUMBER:-local}"
} > "$OUT/${FWNAME}-BUILD-INFO.txt"
# 只保留统一命名后的固件与构建信息，避免旧名产物混进 Release
find "$OUT" -maxdepth 1 -type f \
  ! -name "${FWNAME}.itb" ! -name "${FWNAME}-BUILD-INFO.txt" -delete
ls -lh "$OUT"
endg
