#!/usr/bin/env bash
#===============================================================================
# 阶段二：软件安装                                        预计耗时 15~30 分钟
#-------------------------------------------------------------------------------
# 覆盖范围：
#   解压安装包 / 自动渲染响应文件 / runInstaller 静默安装 /
#   root 脚本自动执行 / 监听器配置（netca + 失败回退）
#   （单机 ASM / RAC 模式额外：Grid 软件安装 + ASM 磁盘组创建）
#
# 用法：
#   sh 2_software_install.sh                # 复用阶段一状态，正常用法
#   sh 2_software_install.sh -lf eth0 ...   # 跳过阶段一直接带全参执行（不推荐）
#===============================================================================
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
set -o pipefail # 管道中任一命令失败都要让整体退出码非 0
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/os_adapt.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/grid.sh"
source "$SCRIPT_DIR/lib/dbsoft.sh"

#==============================================================#
#                         单机模式安装                          #
#==============================================================#
function install_single_mode() {
	execute_and_log "正在解压 Oracle 安装包以及补丁" unzip_dbsoft
	if [[ $only_conf_os == "N" ]]; then
		execute_and_log "正在安装 Oracle 软件以及补丁" install_dbsoft
		execute_and_log "正在创建监听" conf_netca
	fi
}

#==============================================================#
#                       单机 ASM 模式安装                       #
#==============================================================#
function install_standalone_mode() {
	execute_and_log "正在解压 Grid 安装包以及补丁" unzip_gridsoft
	execute_and_log "正在解压 Oracle 安装包以及补丁" unzip_dbsoft
	if [[ $only_conf_os == "N" ]]; then
		execute_and_log "正在安装 Grid 软件以及补丁" install_gridsoft
		if [[ $install_until_grid == "N" ]]; then
			execute_and_log "正在安装 Oracle 软件以及补丁" install_dbsoft
		fi
	fi
}

#==============================================================#
#                          RAC 模式安装                         #
#==============================================================#
function install_rac_mode() {
	# 仅主节点执行软件安装，其他节点由 Grid/DB 安装程序远程分发
	if ((node_num != 1)); then
		color_printf blue "当前为 RAC 非主节点（node $node_num），软件安装由主节点统一执行，本节点跳过阶段二。"
		mark_stage_done 2
		exit 0
	fi
	execute_and_log "正在解压 Grid 安装包以及补丁" unzip_gridsoft
	execute_and_log "正在解压 Oracle 安装包以及补丁" unzip_dbsoft
	if [[ $only_conf_os == "N" ]]; then
		execute_and_log "正在安装 Grid 软件以及补丁" install_gridsoft
		execute_and_log "正在创建 ASM 磁盘组" create_asmgroup
		if [[ $install_until_grid == "N" ]]; then
			execute_and_log "正在安装 Oracle 软件以及补丁" install_dbsoft
		fi
	fi
}

#==============================================================#
#                             主流程                            #
#==============================================================#
function main() {
	if [[ $# -gt 0 ]]; then
		accept_para "$@"
		pre_para_check
		get_os_info
		handle_para
	else
		load_state || color_printf red "未检测到状态文件 $STATE_FILE，请先执行 1_os_config.sh 或传入完整参数！"
		require_stage 1
		get_os_info
	fi

	case "$oracle_install_mode" in
	"single")
		install_single_mode
		;;
	"standalone")
		install_standalone_mode
		;;
	"rac")
		install_rac_mode
		;;
	*)
		color_printf red "未知的 Oracle 安装模式：$oracle_install_mode，请检查参数 [ -install_mode ]！"
		;;
	esac

	mark_stage_done 2
	color_printf green "阶段二（软件安装）执行完成，状态已写入：$STATE_FILE"
	if [[ $install_until_db == "Y" ]]; then
		color_printf green "参数 [ -ud Y ] 已设置，安装到数据库软件结束，不再继续建库。"
	else
		color_printf green "下一步：sh $SCRIPT_DIR/3_db_create.sh"
	fi
}

main "$@" | tee -a "$oracleprintlog"
