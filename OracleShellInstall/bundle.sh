#!/usr/bin/env bash
#===============================================================================
# bundle.sh —— 把阶段脚本与其依赖的 lib/*.sh 内联，生成可单独拷贝执行的单文件脚本
#
# 背景：阶段脚本靠 `source $SCRIPT_DIR/lib/xxx.sh` 复用公共库，直接把单个脚本拷到
#       别的机器上会因为没有 lib 目录而失败。本脚本把公共库内容嵌入阶段脚本，
#       产出的 dist/ 下每个文件都是自包含的，拷走即用。
#
# 用法：
#   sh bundle.sh                 # 生成到 ./dist/
#   然后把 dist/ 里的文件拷到目标机的 /soft 下执行即可
#===============================================================================
set -e
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
DIST=$SCRIPT_DIR/dist
STAGES=(1_os_config.sh 2_software_install.sh 3_db_create.sh 4_post_config.sh run_all.sh)

/bin/mkdir -p "$DIST"

LIB_PATTERN='^source[[:space:]]+"\$SCRIPT_DIR/lib/([a-zA-Z_]+\.sh)"'

for stage in "${STAGES[@]}"; do
	out="$DIST/$stage"
	: >"$out"
	inlined=0
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $line =~ $LIB_PATTERN ]]; then
			lib=${BASH_REMATCH[1]}
			if [[ ! -f "$SCRIPT_DIR/lib/$lib" ]]; then
				echo "错误：找不到依赖库 lib/$lib" >&2
				exit 1
			fi
			{
				echo "#==============================================================="
				echo "# 内联依赖：lib/$lib （由 bundle.sh 自动嵌入，勿手工修改）"
				echo "#==============================================================="
				cat "$SCRIPT_DIR/lib/$lib"
				echo "#==============================================================="
				echo "# 内联结束：lib/$lib"
				echo "#==============================================================="
			} >>"$out"
			inlined=$((inlined + 1))
		else
			printf '%s\n' "$line" >>"$out"
		fi
	done <"$SCRIPT_DIR/$stage"
	chmod +x "$out" 2>/dev/null || true
	printf '%-24s %6s 行，内联 %d 个库\n' "$stage" "$(wc -l <"$out")" "$inlined"
done

echo
echo "自包含脚本已生成到：$DIST"
echo "说明：dist/ 下每个脚本都可直接拷贝到目标机 /soft 目录单独执行。"
