#!/usr/bin/env bash
#===============================================================================
# OracleShellInstall —— 一键串行编排入口
#-------------------------------------------------------------------------------
# 依次调用四个阶段脚本，阶段之间通过状态文件（默认 /soft/.oracle_install_env）
# 传递参数与中间结果；任一阶段失败即中断，修复后可单独重跑该阶段脚本。
#
# 用法示例：
#   # 单机 Oracle 26ai（强制 CDB + 1 个 PDB）
#   sh run_all.sh -lf eth0 -n orcl -o orcl -dbv 26 -pdb pdb01 -opd Y
#
#   # 单机 19c，指定字符集与块大小
#   sh run_all.sh -lf eth0 -n orcl -o orcl -dbv 19 -ds AL32UTF8 -dbs 8192 -opd Y
#
#   # 单机 ASM 模式
#   sh run_all.sh -install_mode standalone -lf eth0 -dd /dev/sdb -dbv 19 -opd Y
#
#   # RAC 模式（主节点执行即可，其他节点由脚本自动下发）
#   sh run_all.sh -install_mode rac -lf team0 -pf eth3 -n orcl -hn orcl01,orcl02 \
#                 -ri 10.211.55.100,10.211.55.101 -vi 10.211.55.102,10.211.55.103 \
#                 -si 10.211.55.105 -rp 'Root_Passw0rd' -od /dev/sdb -dd /dev/sdc -dbv 19
#
#   # 仅配置操作系统
#   sh run_all.sh -lf eth0 -m Y
#===============================================================================
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
set -o pipefail # 管道中任一命令失败都要让整体退出码非 0
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/os_adapt.sh"
source "$SCRIPT_DIR/lib/args.sh"

# 统一四个阶段的时间戳，保证日志落到同一批文件
export ORACLE_CURRENT=$(date +%Y%m%d%H%M%S)

# 清理历史日志
find "$ORACLE_INSTALL_DIR" -name "print_shell_install_*.log" -exec /bin/rm -rf {} + 2>/dev/null
find "$ORACLE_INSTALL_DIR" -name "shell_install_output_*.log" -exec /bin/rm -rf {} + 2>/dev/null

# 解析参数（此处仅做校验，真正落盘由阶段一完成）
accept_para "$@"

function run_stage() {
	local script=$1 name=$2
	shift 2
	local begin end rc
	begin=$(date +%s)
	echo
	color_printf green "==> 开始执行：${name}（${script}）"
	echo
	bash "$SCRIPT_DIR/$script" "$@"
	rc=$?
	end=$(date +%s)
	if ((rc != 0)); then
		color_printf red "${name} 执行失败（退出码 $rc），已中断，请检查日志：$ORACLE_INSTALL_DIR/print_shell_install_${ORACLE_CURRENT}.log"
	fi
	color_printf green "==> ${name} 执行完成，耗时 $((end - begin)) 秒"
}

# 阶段一：OS 配置（需要接收用户传入的全部参数）
run_stage "1_os_config.sh" "阶段一 OS 配置" "$@"

# 仅配置操作系统时到此为止
if [[ $only_conf_os == "Y" ]]; then
	color_printf green "参数 [ -m Y ] 已设置，仅配置操作系统，流程结束。"
	exit 0
fi

# 阶段二：软件安装
run_stage "2_software_install.sh" "阶段二 软件安装"

# 安装到 Grid / DB 软件结束时不再建库
if [[ $install_until_grid == "Y" || $install_until_db == "Y" ]]; then
	color_printf green "参数 [ -ug Y ] 或 [ -ud Y ] 已设置，安装到软件结束，流程结束。"
	exit 0
fi

# 阶段三：数据库创建
run_stage "3_db_create.sh" "阶段三 数据库创建"

# 阶段四：后期配置
run_stage "4_post_config.sh" "阶段四 后期配置"
