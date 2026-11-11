#!/usr/bin/env bash
# 固件命名规则（以后统一使用）：
#   <前缀>-<机型>-R<NN>-<批次>-<月>-<日>
#   实际示例：arioha-hg5585f-ct-R01-B26-11-11.itb
#
#   - <前缀>  默认 arioha（按用户指定拼写；平台官方名为 airoha）
#             可用环境变量 FW_PREFIX 覆盖
#   - <机型>  如 hg5585f-ct / xg-040g-mf
#   - R<NN>   两位版本号，从 R01 起每轮构建递加；数值来自 config/REVISION
#             （每次发版前把该文件数字 +1），也可用 FW_REV 临时指定
#   - <批次>  默认 B26，可用 FW_BATCH 覆盖
#   - <月>-<日> 构建当天日期，北京时间 Asia/Shanghai，两位补零
#
# 用法：source 本文件后调用 firmware_basename <机型> <REVISION 文件路径>
firmware_basename() {
  local model="${1:?缺少机型名}"
  local revfile="${2:?缺少 REVISION 文件路径}"
  local prefix batch rev mmdd
  prefix="${FW_PREFIX:-arioha}"
  batch="${FW_BATCH:-B26}"
  rev="${FW_REV:-}"
  if [ -z "$rev" ]; then
    rev="$(tr -dc '0-9' < "$revfile" 2>/dev/null || true)"
  fi
  [ -n "$rev" ] || rev=1
  mmdd="$(TZ=Asia/Shanghai date +%m-%d)"
  printf '%s-%s-R%02d-%s-%s' "$prefix" "$model" "$rev" "$batch" "$mmdd"
}
