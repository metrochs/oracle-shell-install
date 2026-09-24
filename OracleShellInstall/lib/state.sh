#!/usr/bin/env bash
#===============================================================================
# lib/state.sh —— 全局变量默认值 + 阶段状态持久化
#
# 设计要点：
#   拆分后 4 个阶段是独立进程，无法共享内存变量。这里把「输入参数」和
#   「前序阶段计算出的中间结果」序列化到 $STATE_FILE（默认 /soft/.oracle_install_env），
#   后续阶段 source 回来即可，从而支持：
#     - run_all.sh 串行执行
#     - 单独重跑某一阶段（例如只重跑 3_db_create.sh）
#===============================================================================

STATE_FILE=${ORACLE_STATE_FILE:-$ORACLE_INSTALL_DIR/.oracle_install_env}

#==============================================================#
#                         全局变量定义                           #
#==============================================================#
# 定义 rhel 系操作系统列表
rhel_os_list=(Red CentOS rhel centos ol rocky anolis uos kylin neokylin openEuler almalinux opencloudos ningos asianux NFS fedora euleros hce tencentos kos ctyunos)
# 定义 deb 系操作系统列表
deb_os_list=(debian ubuntu Deepin)
# 配置网络镜像源列表
net_os_list=(fedora euleros debian ubuntu Deepin arch hce)
# 配置本地镜像源列表
local_os_list=(Red CentOS rhel centos ol rocky anolis uos UOS kylin neokylin sles opensuse-leap opensuse-tumbleweed openEuler almalinux opencloudos ningos asianux NFS tencentos kos ctyunos)
# 定义未认证的国产化操作系统列表
unscertified_os_list=(rocky anolis kylin openEuler uos UOS fedora almalinux euleros ubuntu debian arch Deepin opencloudos ningos asianux NFS opensuse-leap opensuse-tumbleweed hce tencentos kos ctyunos)
# 定义 Oracle 官方认证的操作系统列表
oracle_certified_os_list=(centos CentOS Red rhel ol sles)

# 获取安装软件以及脚本目录
# 若脚本放在子目录（如 /soft/OracleShellInstall）而安装包在别处，用 ORACLE_SOFT_DIR 指定
software_dir=${ORACLE_SOFT_DIR:-$ORACLE_INSTALL_DIR}
# 当前执行脚本系统时间
current=${ORACLE_CURRENT:-$(date +%Y%m%d%H%M%S)}
# 脚本安装日志文件
oracleinstalllog=$software_dir/print_shell_install_$current.log
# 脚本输出日志文件
oracleprintlog=$software_dir/shell_install_output_$current.log
# os 认证标识
oracle_os_flag=NONE
# 物理内存（KB）
os_memory_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
# Swap 大小（KB）
swap_total=$(awk '/^SwapTotal:/ { print $2; }' /proc/meminfo)
# 计算额外需要的交换空间大小
((swap_count = (os_memory_total > 16777216 ? 16777216 : os_memory_total > 2097152 ? os_memory_total : os_memory_total * 3 / 2) - swap_total))

# 主机名称
hostname=orcl
# 数据库名称
db_name=orcl
# 是否 CDB 架构
declare -l iscdb=false
# PDB 名称
pdbname=pdb01
# 系统用户 oracle 名称/密码
oracle_user=oracle
oracle_passwd=oracle
# 数据库用户 sys/system 密码
database_passwd=oracle
# 数据库软件安装根目录
env_base_dir=/u01
# 数据文件目录
oradata_dir=/oradata
# 备份目录
backup_dir=/backup
# 归档目录（为空时自动取 $oradata_dir/archivelog）
archive_dir=
# 数据库字符集
declare -u db_characterset=AL32UTF8
declare -u nation_characterset=AL16UTF16
# 数据库块大小
db_block_size=8192
# 在线重做日志大小（MB）
redosize=1024
# 是否开启归档
declare -l enable_arch=true
# 流程开关
declare -u only_conf_os=N
declare -u install_until_grid=N
declare -u install_until_db=N
declare -u optimize_db=N
declare -u isgui=N
declare -u local_repo=Y
declare -u net_repo=N
declare -u huge_flag=N
declare -u debug_flag=N

#==============================================================#
#                      RAC / ASM 模式全局变量                     #
#==============================================================#
node_num=1
grid_user=grid
grid_passwd=oracle
declare -u dns=N
declare -u multipath=Y
asmdisk_string="/dev/asm*"
declare -u asm_disk_conf=Y
declare -u ocr_asm_group=OCR
declare -u data_asm_group=DATA
declare -u arch_asm_group=ARCH
declare -u ocr_redun=EXTERNAL
declare -u data_redun=EXTERNAL
declare -u arch_redun=EXTERNAL
declare -l afd=false
declare -l gimr=false
declare -u virtualbox=N

# 安装模式（single / standalone / rac）
declare -l oracle_install_mode=

#==============================================================#
#                         状态持久化实现                          #
#==============================================================#
# 需要持久化的标量变量
ORACLE_STATE_SCALARS=(
	software_dir current oracleinstalllog oracleprintlog
	os_type os_version pretty_name cpu_type libc_version a_path so_path profile_name
	uos_edition oracle_os_flag os_memory_total swap_total swap_count
	hostname db_name iscdb pdbname
	oracle_user oracle_passwd grid_user grid_passwd database_passwd root_passwd
	env_base_dir env_oracle_base env_oracle_inven env_oracle_home env_grid_base env_grid_home
	oradata_dir archive_dir backup_dir
	db_characterset nation_characterset db_block_size redosize enable_arch
	only_conf_os install_until_grid install_until_db optimize_db isgui local_repo net_repo huge_flag debug_flag
	oracle_install_mode node_num local_ifname local_ip HOSTNAME
	rac_hostname rac_priv_ifname rac_public_ip rac_virtual_ip rac_scan_ip scan_count
	scan_name cluster_name dns dns_name dns_ip timeserver_ip
	multipath asmdisk_string asm_disk_conf virtualbox
	ocr_asm_group data_asm_group arch_asm_group ocr_redun data_redun arch_redun afd gimr
	ocr_base_disk data_base_disk arch_base_disk ocr_disk_wwid data_disk_wwid arch_disk_wwid
	ocrdisk datadisk archdisk ausize clusternodes networkinterfacelist
	grid_patch oracle_patch ojvm_patch grid_patch_name db_patch_name ojvm_patch_name patch_number
	grid_soft_name grid_opatch_name cvuqdisk cvu_name gi_compatible
	db_soft_name db_soft_name1 db_opatch_name db_compatible
	db_version gi_version install_start_time
	STAGE1_DONE STAGE2_DONE STAGE3_DONE STAGE4_DONE
)

# 需要持久化的数组变量
ORACLE_STATE_ARRAYS=(
	db_names rac_hostnames rac_public_ips rac_virtual_ips rac_scan_ips
	rac_priv_ifnames rac_priv_ifnames_sorted hosts_array allips ssh_ips
)

# 保存当前所有变量到状态文件
function save_state() {
	local f=$STATE_FILE v joined
	{
		echo "# OracleShellInstall 阶段状态文件（自动生成，请勿手工修改）"
		echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
		for v in "${ORACLE_STATE_SCALARS[@]}"; do
			printf '%s=%q\n' "$v" "${!v-}"
		done
		# 数组以逗号拼接原样写入（元素本身不含逗号，不能用 %q，否则逗号会被转义成 \, 导致还原失败）
		for v in "${ORACLE_STATE_ARRAYS[@]}"; do
			joined=$(eval "printf '%s,' \"\${${v}[@]}\"")
			printf '__ARR_%s=%s\n' "$v" "${joined%,}"
		done
	} >"$f"
	chmod 600 "$f" 2>/dev/null
}

# 从状态文件恢复变量
function load_state() {
	[[ -f $STATE_FILE ]] || return 1
	local line k v name
	while IFS= read -r line || [[ -n $line ]]; do
		[[ -z $line || $line == \#* ]] && continue
		k=${line%%=*}
		v=${line#*=}
		if [[ $k == __ARR_* ]]; then
			name=${k#__ARR_}
			eval "IFS=',' read -ra $name <<< \"\$v\""
		else
			eval "$k=$v"
		fi
	done <"$STATE_FILE"
	return 0
}

# 标记某阶段已完成
function mark_stage_done() {
	local n=$1
	eval "STAGE${n}_DONE=Y"
	save_state
}

# 校验前置阶段是否已完成，未完成则报错退出
function require_stage() {
	local n=$1 done_flag
	eval "done_flag=\${STAGE${n}_DONE}"
	if [[ $done_flag != "Y" ]]; then
		echo
		echo -e "\E[1;31m阶段 $n 尚未执行完成，请先执行对应阶段脚本，或检查状态文件：$STATE_FILE\E[0m"
		exit 1
	fi
}

# 供安装报告调用的阶段状态展示
function stage_status() {
	local n=$1 done_flag
	eval "done_flag=\${STAGE${n}_DONE}"
	[[ $done_flag == "Y" ]] && echo "已完成" || echo "未执行"
}
