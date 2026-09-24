#!/usr/bin/env bash
#===============================================================================
# lib/common.sh —— OracleShellInstall 公共函数库
# 职责：打印/日志/文件操作/参数校验/SQL 执行/SSH 互信/磁盘工具/收尾报告
# 说明：本文件只定义函数，所有依赖的全局变量由 lib/state.sh 提供
#===============================================================================
export PS4='+${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}: '

# 脚本根目录（等价于原脚本约定的 /soft）
# 两种场景都要支持：
#   1) 正常：本文件位于 <root>/lib/common.sh，被阶段脚本 source
#   2) 内联打包：本文件内容被直接嵌入阶段脚本，此时 BASH_SOURCE[0] 指向阶段脚本本身
ORACLE_LIB_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
if [[ $(basename "$ORACLE_LIB_DIR") == "lib" ]]; then
	ORACLE_INSTALL_DIR=$(dirname "$ORACLE_LIB_DIR")
else
	ORACLE_INSTALL_DIR=$ORACLE_LIB_DIR
fi
export ORACLE_LIB_DIR ORACLE_INSTALL_DIR

# bash 版本限制
_bash_major=$(echo "$BASH_VERSION" | cut -d '.' -f1)
if [[ $_bash_major ]] && ((_bash_major < 4)); then
	printf "\n\E[1;31m%-20s\n\E[0m\n" "本脚本不支持 Bash 版本低于 4 执行安装，当前 Bash 版本为：$_bash_major，已退出！"
	exit 1
fi

#==============================================================#
#                           颜色打印                            #
#==============================================================#
function color_printf() {
	declare -u con_flag
	declare -A color_map=(
		["red"]='\E[1;31m'
		["green"]='\E[1;32m'
		["blue"]='\E[1;34m'
		["yellow"]='\E[1;33m'
		["light_blue"]='\E[1;94m'
		["purple"]='\033[35m'
	)
	local res='\E[0m' default_color='\E[1;32m'
	local color=${color_map[$1]:-"$default_color"}
	case "$1" in
	"red")
		printf "\n${color}%-20s %-30s %-50s\n${res}\n" "${2-}" "${3-}" "${4-}"
		exit 1
		;;
	"green" | "light_blue")
		printf "${color}%-20s %-30s %-50s\n${res}" "${2-}" "${3-}" "${4-}"
		;;
	"purple")
		printf "${color}%-s${res}" "${2-}" "${3-}"
		read -r con_flag
		if [[ -z $con_flag ]]; then
			con_flag=Y
		fi
		if [[ $con_flag != "Y" ]]; then
			echo
			exit 1
		fi
		;;
	*)
		printf "${color}%-20s %-30s %-50s\n${res}\n" "${2-}" "${3-}" "${4-}"
		;;
	esac
}

#==============================================================#
#                            日志打印                           #
#==============================================================#
function log_print() {
	echo
	color_printf green "#==============================================================#"
	color_printf green "$1"
	color_printf green "#==============================================================#"
	echo
}

#==============================================================#
#                     执行命令并输出日志文件                     #
#==============================================================#
function execute_and_log() {
	local prompt="$1" cmd="$2" log_file="$oracleinstalllog" pid start_time end_time execution_time status
	echo -e "\e[1;34m${prompt}\e[0m\c"
	printf "......"
	start_time=$(date +%s)
	if [[ $debug_flag == "Y" ]]; then
		set -x
	fi
	eval "$cmd" >>"$log_file" 2>&1 &
	if [[ $debug_flag == "Y" ]]; then
		set +x
	fi
	pid=$!
	while kill -0 "$pid" >/dev/null 2>&1; do
		printf "."
		sleep 0.5
		printf "\b"
		sleep 0.5
	done
	end_time=$(date +%s)
	execution_time=$((end_time - start_time))
	wait $pid
	status=$?
	if ((status == 0 || status == 3)); then
		printf "已完成 (耗时: %s 秒)\n" "$execution_time"
	elif [[ $status != 0 ]]; then
		case "$cmd" in
		pkg_install | disable_firewall | conf_sysctl)
			printf "已完成 (耗时: %s 秒)\n" "$execution_time"
			;;
		*)
			printf "执行出错，请检查日志 %s\n" "$log_file"
			exit 1
			;;
		esac
	fi
}

#==============================================================#
#                          脚本通用函数                         #
#==============================================================#
function upper() { echo "${1^^}"; }
function lower() { echo "${1,,}"; }

function checkpara_NULL() {
	if [[ -z $2 || $2 == -* ]]; then
		color_printf red "参数 [ $1 ] 的值为空，请检查！"
	fi
}
function checkpara_YN() {
	if ! [[ $2 =~ ^[YyNn]$ ]]; then
		color_printf red "参数 [ $1 ] 的值 $2 必须为 Y 或者 N，请检查！"
	fi
}
function checkpara_tf() {
	if ! [[ $2 =~ ^(true|false)$ ]]; then
		color_printf red "参数 [ $1 ] 的值 $2 必须为 true 或者 false，请检查！"
	fi
}
function checkpara_REDUN() {
	local REDUN="EXTERNAL|NORMAL|HIGH"
	if ! [[ $2 =~ ^($REDUN)$ ]]; then
		color_printf red "RAC 参数 [ $1 ] 的值 $2 必须为 EXTERNAL，NORMAL 或者 HIGH，请检查！"
	fi
}
function checkpara_NUMERIC() {
	if ! [[ $2 =~ ^[0-9]+$ ]]; then
		color_printf red "参数 [ $1 ] 的值 $2 不是数字，请检查！"
	fi
}
function checkpara_DBS() {
	local DBS="2048|4096|8192|16384|32768"
	if ! [[ $2 =~ ^($DBS)$ ]]; then
		color_printf red "参数 [ $1 ] 的值 $2 必须为 2048，4096，8192，16384 或者 32768，请检查！"
	fi
}
function checkpara_DBCHARSET() {
	local CHARSETS="AL16UTF16|AL24UTFFSS|AL32UTF8|AR8ADOS710|AR8ADOS710T|AR8ADOS720|AR8ADOS720T|AR8APTEC715|AR8APTEC715T|AR8ARABICMAC|AR8ARABICMACS|AR8ARABICMACT|AR8ASMO708PLUS|AR8ASMO8X|AR8EBCDIC420S|AR8EBCDICX|AR8HPARABIC8T|AR8ISO8859P6|AR8MSWIN1256|AR8MUSSAD768|AR8MUSSAD768T|AR8NAFITHA711|AR8NAFITHA711T|AR8NAFITHA721|AR8NAFITHA721T|AR8SAKHR706|AR8SAKHR707|AR8SAKHR707T|AR8XBASIC|AZ8ISO8859P9E|BG8MSWIN|BG8PC437S|BLT8CP921|BLT8EBCDIC1112|BLT8EBCDIC1112S|BLT8ISO8859P13|BLT8MSWIN1257|BLT8PC775|BN8BSCII|CDN8PC863|CE8BS2000|CEL8ISO8859P14|CH7DEC|CL8BS2000|CL8EBCDIC1025|CL8EBCDIC1025C|CL8EBCDIC1025R|CL8EBCDIC1025S|CL8EBCDIC1025X|CL8EBCDIC1158|CL8EBCDIC1158R|CL8ISO8859P5|CL8ISOIR111|CL8KOI8R|CL8KOI8U|CL8MACCYRILLIC|CL8MACCYRILLICS|CL8MSWIN1251|D7DEC|D7SIEMENS9780X|D8BS2000|D8EBCDIC1141|D8EBCDIC273|DK7SIEMENS9780X|DK8BS2000|DK8EBCDIC1142|DK8EBCDIC277|E7DEC|E7SIEMENS9780X|E8BS2000|EE8BS2000|EE8EBCDIC870|EE8EBCDIC870C|EE8EBCDIC870S|EE8ISO8859P2|EE8MACCE|EE8MACCES|EE8MACCROATIAN|EE8MACCROATIANS|EE8MSWIN1250|EE8PC852|EEC8EUROASCI|EEC8EUROPA3|EL8DEC|EL8EBCDIC423R|EL8EBCDIC875|EL8EBCDIC875R|EL8EBCDIC875S|EL8GCOS7|EL8ISO8859P7|EL8MACGREEK|EL8MACGREEKS|EL8MSWIN1253|EL8PC437S|EL8PC737|EL8PC851|EL8PC869|ET8MSWIN923|F7DEC|F7SIEMENS9780X|F8BS2000|F8EBCDIC1147|F8EBCDIC297|HU8ABMOD|HU8CWI2|I7DEC|I7SIEMENS9780X|I8EBCDIC1144|I8EBCDIC280|IN8ISCII|IS8MACICELANDIC|IS8MACICELANDICS|IS8PC861|IW7IS960|IW8EBCDIC1086|IW8EBCDIC424|IW8EBCDIC424S|IW8ISO8859P8|IW8MACHEBREW|IW8MACHEBREWS|IW8MSWIN1255|IW8PC1507|JA16DBCS|JA16DBCSFIXED|JA16EBCDIC930|JA16EUC|JA16EUCFIXED|JA16EUCTILDE|JA16EUCYEN|JA16MACSJIS|JA16SJIS|JA16SJISFIXED|JA16SJISTILDE|JA16SJISYEN|JA16VMS|KO16DBCS|KO16DBCSFIXED|KO16KSC5601|KO16KSC5601FIXED|KO16KSCCS|KO16MSWIN949|LA8ISO6937|LA8PASSPORT|LT8MSWIN921|LT8PC772|LT8PC774|LV8PC1117|LV8PC8LR|LV8RST104090|N7SIEMENS9780X|N8PC865|NDK7DEC|NE8ISO8859P10|NEE8ISO8859P4|NL7DEC|RU8BESTA|RU8PC855|RU8PC866|S7DEC|S7SIEMENS9780X|S8BS2000|S8EBCDIC1143|S8EBCDIC278|SE8ISO8859P3|SF7ASCII|SF7DEC|TH8MACTHAI|TH8MACTHAIS|TH8TISASCII|TH8TISEBCDIC|TH8TISEBCDICS|TR7DEC|TR8DEC|TR8EBCDIC1026|TR8EBCDIC1026S|TR8MACTURKISH|TR8MACTURKISHS|TR8MSWIN1254|TR8PC857|US7ASCII|US8BS2000|US8ICL|US8PC437|UTF8|UTFE|VN8MSWIN1258|VN8VN3|WE8BS2000|WE8BS2000E|WE8BS2000L5|
WE8DEC|WE8DG|WE8EBCDIC1047|WE8EBCDIC1047E|WE8EBCDIC1140|WE8EBCDIC1140C|WE8EBCDIC1145|WE8EBCDIC1146|WE8EBCDIC1148|WE8EBCDIC1148C|WE8EBCDIC284|WE8EBCDIC285|WE8EBCDIC37|WE8EBCDIC37C|WE8EBCDIC500|WE8EBCDIC500C|WE8EBCDIC871|WE8EBCDIC924|WE8GCOS7|WE8HP|WE8ICL|WE8ISO8859P1|WE8ISO8859P15|WE8ISO8859P9|WE8ISOICLUK|WE8MACROMAN8|WE8MACROMAN8S|WE8MSWIN1252|WE8NCR4970|WE8NEXTSTEP|WE8PC850|WE8PC858|WE8PC860|WE8ROMAN8|YUG7ASCII|ZHS16CGB231280|ZHS16CGB231280FIXED|ZHS16DBCS|ZHS16DBCSFIXED|ZHS16GBK|ZHS16GBKFIXED|ZHS16MACCGB231280|ZHS32GB18030|ZHT16BIG5|ZHT16BIG5FIXED|ZHT16CCDC|ZHT16DBCS|ZHT16DBCSFIXED|ZHT16DBT|ZHT16HKSCS|ZHT16HKSCS31|ZHT16MSWIN950|ZHT32EUC|ZHT32EUCFIXED|ZHT32SOPS|ZHT32TRIS|ZHT32TRISFIXED"
	if ! [[ $2 =~ ^($CHARSETS)$ ]]; then
		color_printf red "数据库字符集参数 [ $1 ] 的值 $2 无效，请检查！"
	fi
}
function checkpara_NCHARSET() {
	local NCHARSETS="UTF8|AL16UTF16"
	if ! [[ $2 =~ ^($NCHARSETS)$ ]]; then
		color_printf red "国家字符集参数 [ $1 ] 的值 $2 无效，请检查！"
	fi
}
function check_DBNAME() {
	local dbname="$1"
	local regex="^[a-zA-Z0-9]+$"
	if ! [[ $dbname =~ $regex ]]; then
		color_printf red "参数 [ -o ] 的值 $dbname 不符合要求，请使用数字和字母，不要使用特殊字符，请检查！"
	fi
}
function check_RACNAME() {
	if [[ $2 =~ ^[0-9] ]]; then
		color_printf red "参数 [ $1 ] 的值 $2 不能使用数字开头，请检查！"
	fi
}
function check_password() {
	local password="$2"
	if [[ $password =~ [[:cntrl:]] ]]; then
		color_printf red "参数 [ $1 ] 的密码 $2 不符合要求，包含不可见字符，请检查！"
	fi
	if [[ $1 == "-dp" ]]; then
		if ! [[ $password =~ ^[a-zA-Z][a-zA-Z0-9#$_]*$ ]]; then
			color_printf red "参数 [ $1 ] 的密码 $2 不符合要求，必须以字母开头，并且字符只能包含 (_)，(#)，($) ，请检查！"
		fi
	fi
}
function check_disknum() {
	local disk_identifier=$1 redun=$2 normal=$3 high=$4 disk_count=$5
	if [[ $redun == "NORMAL" ]]; then
		if ((disk_count < normal)); then
			color_printf red "$disk_identifier 磁盘组冗余度为 $redun 时，至少需要 $normal 块磁盘，请检查磁盘数量！"
		fi
	elif [[ $redun == "HIGH" ]]; then
		if ((disk_count < high)); then
			color_printf red "$disk_identifier 磁盘组冗余度为 $redun 时，至少需要 $high 块磁盘，请检查磁盘数量！"
		fi
	fi
}

#==============================================================#
#                            文件操作                           #
#==============================================================#
function check_file() {
	if [[ -e "$1" ]]; then
		return 0
	else
		return 1
	fi
}
function mv_file() {
	local file_path=$1
	if ! check_file "$file_path".original; then
		if check_file "$file_path"; then
			/bin/mv -f "$file_path"{,.original} >/dev/null 2>&1
		fi
	fi
}
function rm_file() {
	local file=$1
	if check_file "$file"; then
		/bin/rm -rf "$file" >/dev/null 2>&1
	fi
}
function backup_restore_file() {
	local file_path=$1
	if check_file "$file_path"; then
		if (($(grep -E -c "# OracleBegin" "$file_path") == 0)); then
			/bin/cp -f "$file_path"{,.original}
		else
			/bin/cp -f "$file_path"{,."$current"}
			/bin/cp -f "$file_path"{.original,}
		fi
	else
		touch "$file_path".original
	fi
}
function write_file() {
	local flag=$1 file_name=$2 content=$3
	if [[ $flag == "Y" ]]; then
		printf '%s\n' "$content" >"$file_name"
	elif [[ $flag == "N" ]]; then
		printf '%s\n' "$content" >>"$file_name"
	fi
}

#==============================================================#
#                       用户切换与 SQL 执行                      #
#==============================================================#
function run_as_oracle() {
	local command="$1"
	su - "$oracle_user" -c "bash -l -c \"$command\""
}
function run_as_grid() {
	local command="$1"
	su - "$grid_user" -c "bash -l -c \"$command\""
}
function execute_sqlplus() {
	local dbname="$1" format="$2" sql="$3"
	# 外层 heredoc 不加引号：先在此处展开 $format / $sql（调用方写 v\$xxx 已是字面 $）
	# 内层 heredoc 必须加引号：否则登录 shell 会把 v$controlfile 之类当成变量二次展开（真机踩坑）
	su - "$oracle_user" <<SOF
source /home/$oracle_user/.$dbname
sqlplus -S / as sysdba <<'EOF'
set lin 2222 pages 1000 tab off feedback off
$format
$sql
exit;
EOF
SOF
}
# 执行 SQL 并返回单个标量值（自动去除空白），用于脚本内部判断
function query_sql_scalar() {
	local dbname="$1" sql="$2"
	execute_sqlplus "$dbname" "set pagesize 0" "$sql" | tr -d '[:space:]'
}

#==============================================================#
#                           IP 相关校验                         #
#==============================================================#
function check_ip() {
	local ip=$1
	if echo "$ip" | grep -Eq "^([0-9]{1,3}\.){3}[0-9]{1,3}$"; then
		return 0
	else
		return 1
	fi
}
function check_ip_connectivity() {
	local ip=$1
	if ! ping -c 1 "$ip" >/dev/null 2>&1; then
		color_printf red "IP地址 $ip 无法 ping 通，请检查！"
	fi
}
function check_ip_unreachability() {
	local ip=$2
	if ping -c 1 "$ip" >/dev/null 2>&1; then
		color_printf red "RAC $1 的 $ip 可以被 ping 通，可能被占用，请检查！"
	fi
}
function isunique_ip() {
	declare -A ip_count
	for ip in "${allips[@]}"; do
		((ip_count[$ip]++))
	done
	for ip in "${!ip_count[@]}"; do
		if ((ip_count[$ip] > 1)); then
			color_printf red "IP地址 $ip 存在重复，请检查！"
		fi
	done
}
function check_internet_connectivity() {
	if ! ping -c 1 www.baidu.com >/dev/null 2>&1; then
		color_printf red "脚本参数 [ -nrp ] 值为 $net_repo，当前操作系统 [ $pretty_name ] 需要配置网络软件源，必须联网，否则安装失败！"
	fi
}

#==============================================================#
#                           磁盘工具                            #
#==============================================================#
function is_in_list() {
	local item=$1
	shift
	local list=("$@")
	for element in "${list[@]}"; do
		if [[ "$item" == "$element" ]]; then
			return 0
		fi
	done
	return 1
}
function get_wwid() {
	local wwid scsi_id
	if ((os_version == 6)); then
		scsi_id="/sbin/scsi_id"
	else
		scsi_id="/usr/lib/udev/scsi_id"
	fi
	wwid=$("$scsi_id" -g -u "$1")
	echo "$wwid"
}
function clean_disk_and_get_wwid() {
	local wwid_list wwid wwid_string identifier=$2 disk_count
	IFS=',' read -ra disks <<<"$1"
	disk_count=${#disks[@]}
	for disk in "${disks[@]}"; do
		if [[ -n "$disk" ]]; then
			if hexdump -C -n 102400 "$disk" | grep -q "$identifier"; then
				color_printf purple "检查 ASM 磁盘 [ $disk ] 中已存在磁盘组名称 [ $identifier ] 信息，请确认是否格式化磁盘 (Y/N): [Y] "
				echo
				dd if=/dev/zero of="$disk" bs=4096 count=1 >/dev/null 2>&1
			fi
			wwid=$(get_wwid "$disk")
			if [[ -z "$wwid" ]]; then
				color_printf red "磁盘 $disk 的 WWID 未获取到，请检查磁盘！"
			fi
			wwid_list+=("$wwid")
		fi
	done
	wwid_string=$(
		IFS=,
		echo "${wwid_list[*]}"
	)
	case "$identifier" in
	"OCR")
		ocr_disk_wwid="$wwid_string"
		check_disknum "$identifier" "$ocr_redun" 3 5 "$disk_count"
		;;
	"DATA")
		data_disk_wwid="$wwid_string"
		check_disknum "$identifier" "$data_redun" 2 3 "$disk_count"
		;;
	"ARCH")
		arch_disk_wwid="$wwid_string"
		check_disknum "$identifier" "$arch_redun" 2 3 "$disk_count"
		;;
	esac
}
function conf_disk_wwid() {
	if [[ $asm_disk_conf == "N" ]]; then
		datadisk=$data_base_disk
		ocrdisk=${ocr_base_disk:+"$ocr_base_disk"}
		archdisk=${arch_base_disk:+"$arch_base_disk"}
		asmdisk_string="$(dirname "${data_base_disk##*,}")/$(echo "${data_base_disk##*/}" | cut -c1-3)""*"
	else
		local disk_types=("OCR" "DATA" "ARCH")
		for disk_type in "${disk_types[@]}"; do
			local base_disk="${disk_type,,}_base_disk"
			if [[ "${!base_disk}" ]]; then
				clean_disk_and_get_wwid "${!base_disk}" "$disk_type"
			fi
		done
	fi
}
function filter_disk() {
	local fil_disk=$1 all_disks disk disk_list=() wwid
	declare -A wwids sizes
	disk_storage() {
		lsblk -b -o SIZE,TYPE "${1}" | awk '$2 == "disk" {print $1/1024/1024/1024 "G"}'
	}
	all_disks=$(lsblk -n -o NAME | awk '/^sd|vd/ { print $1 }')
	IFS=',' read -ra fil_disk_arr <<<"$fil_disk"
	for disk in $all_disks; do
		if ! [[ "${fil_disk_arr[*]}" =~ $disk ]]; then
			disk_list+=("/dev/$disk")
		fi
	done
	for disk in "${disk_list[@]}"; do
		sizes[$disk]=$(disk_storage "$disk")
		wwid=$(get_wwid "$disk")
		if [[ -n $wwid && ! "${wwids[*]}" =~ $wwid ]]; then
			wwids[$disk]=$wwid
		fi
	done
	color_printf light_blue "Disk WWID" "Disk Name" "Size"
	for disk in "${!wwids[@]}"; do
		color_printf green "${wwids[$disk]}" "$disk" "${sizes[$disk]}"
	done | sort -k3,3n -k2,2
}

#==============================================================#
#                            SSH 互信                           #
#==============================================================#
function ssh_check() {
	local user=$1 all_connections_ok="true"
	declare -a ips=("${@:2}")
	for ip in "${ips[@]}"; do
		if su -s /bin/bash -c "ssh -q -o ConnectTimeout=1 -o ConnectionAttempts=1 -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no $ip date" "$user" >/dev/null 2>&1; then
			all_connections_ok="true"
		else
			all_connections_ok="false"
			break
		fi
	done
	echo $all_connections_ok
}
function ssh_trust() {
	local dest_user=$1 passwd ssh_dir
	passwd=$(printf "%q" "$2")
	declare -a host_ips=("${@:3}")
	[[ $dest_user == "root" ]] && ssh_dir="/root/.ssh" || ssh_dir="/home/$dest_user/.ssh"
	if [[ -e "$ssh_dir" ]]; then
		/bin/rm -rf "$ssh_dir"
	fi
	/bin/mkdir -p "$ssh_dir" && chmod 755 "$ssh_dir"
	ssh-keygen -t rsa -P '' -f "$ssh_dir/id_rsa"
	cat "$ssh_dir/id_rsa.pub" >>"$ssh_dir/authorized_keys" && chmod 644 "$ssh_dir/authorized_keys"
	for ip in "${host_ips[@]}"; do
		expect <<EOF >/dev/null 2>&1
set timeout 300
spawn ssh -q -o StrictHostKeyChecking=no $dest_user@$ip "echo 'Connected!'"
expect "password:" { send "$passwd\r"; exp_continue } eof { exit } timeout { puts "等待超时，检查 ssh 执行速度"; exit 1 }
EOF
	done
	for ip in "${host_ips[@]}"; do
		expect <<EOF >/dev/null 2>&1
set timeout 300
spawn scp -q -o StrictHostKeyChecking=no -r $ssh_dir $dest_user@$ip:~
expect "password:" { send "$passwd\r"; exp_continue } eof { exit } timeout { puts "等待超时，检查 scp 执行速度"; exit 1 }
EOF
		if ((os_version == 6)); then
			expect <<EOF >/dev/null 2>&1
set timeout 300
spawn ssh -q -o StrictHostKeyChecking=no $dest_user@$ip restorecon -RF $ssh_dir
expect "password:" {  send "$passwd\r"; exp_continue } eof { exit } timeout { puts "等待超时，检查 ssh 执行速度"; exit 1 }
EOF
		fi
	done
	wait
}
function root_ssh_trust() {
	if [[ $(ssh_check root "${ssh_ips[@]}") == "false" ]]; then
		log_print "配置 root 用户互信"
		install_package "expect"
		if ! type expect >/dev/null 2>&1; then
			color_printf red "本脚本安装 RAC 需要使用 expect 命令互信，当前 expect 未安装成功，请检查 YUM 源配置是否正确！"
		fi
		ssh_trust root "$root_passwd" "${ssh_ips[@]}"
		if [[ $(ssh_check root "${ssh_ips[@]}") == "false" ]]; then
			color_printf red "root 用户互信失败，请检查参数 [ -rp ] 传入的 root 密码： $root_passwd 是否正确！"
		fi
	fi
}
function rac_ssh() {
	local users=("$grid_user" "$oracle_user")
	export -f ssh_trust
	for user in "${users[@]}"; do
		if [[ $(ssh_check "$user" "${hosts_array[@]}") == "false" ]]; then
			log_print "配置 ${user^^} 用户 SSH 互信"
			case $user in
			"$grid_user")
				su "$grid_user" -c "ssh_trust $grid_user $grid_passwd ${hosts_array[*]}"
				;;
			"$oracle_user")
				su "$oracle_user" -c "ssh_trust $oracle_user $oracle_passwd ${hosts_array[*]}"
				;;
			esac
			if [[ $(ssh_check "$user" "${hosts_array[@]}") == "false" ]]; then
				color_printf red "$user 用户互信失败，请检查原因！"
			fi
		fi
	done
}

#==============================================================#
#                          进程与目录工具                        #
#==============================================================#
function kill_process() {
	local process_name=$1
	pgrep -f "$process_name" | awk '{system("pkill -9 -f "$1)}' >/dev/null 2>&1
}
function cascade_del_file() {
	local file_path=$1
	if [[ -d "$file_path" ]]; then
		find "$file_path" -mindepth 1 -delete >/dev/null 2>&1
	elif [[ -f "$file_path" ]]; then
		/bin/rm -f "$file_path" >/dev/null 2>&1
	fi
}
function create_symlink() {
	local flag=$1 source_path=$2 destination_path=$3
	if [[ $flag == "Y" ]]; then
		ln -sf "$source_path" "$destination_path" >/dev/null 2>&1
	elif [[ $flag == "N" ]]; then
		ln -s "$source_path" "$destination_path" >/dev/null 2>&1
	fi
}
function base64_to_binary() {
	local base64_string=$1 output_file="${2:-decoded.bin}"
	echo -n "$base64_string" | base64 --decode >"$output_file"
}
function check_md5sum() {
	local file_name=$1
	local expected_md5=$2
	color_printf green "正在检测安装包 $file_name 的 MD5 值是否正确，请稍等......"
	if [[ $(md5sum "$file_name" | awk '{print $1}') != "$expected_md5" ]]; then
		color_printf red "请检查 $file_name 文件的完整性，确保 md5sum 值为 $expected_md5！"
	fi
}

#==============================================================#
#                            软件包安装                          #
#==============================================================#
function install_package() {
	local yum_cmd
	case "$os_type" in
	"sles")
		yum_cmd=zypper
		;;
	"arch")
		yum_cmd=pacman
		;;
	"ubuntu" | "debian" | "Deepin")
		yum_cmd=apt-get
		;;
	*)
		if ((os_version <= 7)); then
			yum_cmd=yum
		else
			yum_cmd=dnf
		fi
		;;
	esac
	for package in "$@"; do
		if [[ "$os_type" == "arch" ]]; then
			install_cmd="$yum_cmd -S --noconfirm \"$package\""
		else
			install_cmd="$yum_cmd install -y \"$package\""
		fi
		if ! eval "$install_cmd" >/dev/null 2>&1; then
			if is_in_list "$package" "${must_packages[@]}"; then
				if [[ "$package" =~ ^libnsl[0-9]*$ ]]; then
					if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
						color_printf red "Oracle Gird 安装需要依赖包 $package ，当前未成功安装，请检查。"
					fi
				fi
			fi
		fi
	done
}
function install_gui() {
	color_printf green "正在安装图形化界面："
	if [[ "$os_type" == "rhel" ]]; then
		case "$os_version" in
		"6")
			install_package "nautilus-open-terminal" "tigervnc-server"
			yum groupinstall -y -q "X Window System" "Desktop" >/dev/null 2>&1
			;;
		"7" | "8" | "9")
			install_package "tigervnc-server"
			yum groupinstall -y -q "Server with GUI" >/dev/null 2>&1
			;;
		esac
	fi
}
function pkg_install() {
	log_print "安装依赖软件包"
	local option_packages must_packages
	if [[ $isgui == "Y" ]]; then
		install_gui
	fi
	if is_in_list "$os_type" "${rhel_os_list[@]}"; then
		option_packages=(
			libaio-devel e2fsprogs e2fsprogs-libs smartmontools net-tools nfs-utils
			elfutils-libelf elfutils-libelf-devel libibverbs librdmacm fontconfig
			fontconfig-devel libXrender libXrender-devel libX11 libXau libXi libXtst
			libxcb unixODBC sysstat readline readline-devel policycoreutils
			libvirt-libs policycoreutils-python-utils libnsl2 libasan liblsan
			compat-openssl10 libxcrypt-compat compat-openssl11 libgfortran rlwrap
		)
		must_packages=(
			psmisc tar glibc libaio libgcc libstdc++ bc make binutils glibc-devel
			ksh libstdc++-devel unzip gcc gcc-c++
		)
		case "${os_version}" in
		"6")
			must_packages+=(compat-libstdc++-33 compat-libcap1)
			;;
		"7")
			must_packages+=(compat-libcap1)
			;;
		"8" | "9" | "10")
			must_packages+=(libnsl initscripts)
			;;
		esac
	elif is_in_list "$os_type" "${deb_os_list[@]}"; then
		option_packages=(
			bc libnsl2 sysstat net-tools libelf-dev xauth libxi6 libxtst6 x11-utils
			libxrender-dev libreadline8 libreadline-dev rlwrap lsb-release ksh
			libaio-dev libnsl-dev libgcc-s1 build-essential smartmontools
		)
		must_packages=(psmisc tar unzip gcc make libstdc++6 rpm2cpio cpio)
		if ((libc_version >= 39)); then
			must_packages+=(libaio1t64 libpcap0.8t64)
		else
			must_packages+=(libaio1 libpcap0.8)
		fi
	elif [[ "$os_type" == "sles" ]]; then
		option_packages=(
			xz libcap-ng-utils libcap-ng0 libcap-progs libpcre1 libpng16-16 libstdc++6
			libtiff5 mksh nfs-kernel-server pixz rdma-core libX11-6 libXau6 libXrender1
			libXtst6 xorg-x11 xorg-x11-Xvnc xorg-x11-driver-video xorg-x11-essentials
			xorg-x11-fonts xorg-x11-fonts-core xorg-x11-libs xorg-x11-server
			xorg-x11-server-extra
		)
		must_packages=(
			psmisc make tar unzip bc binutils gcc glibc libaio-devel libaio1 libcap1
			libcap2 libgcc_s1 libpcap1 iputils libnsl1
		)
		case "$os_version" in
		"7")
			must_packages+=(
				gcc-c++ gcc-info gcc-locale gcc48 gcc48-c++ gcc48-info gcc48-locale
				libelf-devel libgfortran3 libjpeg-turbo libjpeg62 libjpeg62-turbo
				libpcre16-0 libstdc++-devel libstdc++48-devel
			)
			;;
		"8")
			must_packages+=(
				insserv-compat libXext-devel libXext6 libXi-devel libXi6
				libXrender-devel libelf1 libgfortran4 libjpeg8 rdma-core-devel
				libreadline7 readline-devel
			)
			;;
		"9")
			must_packages+=(insserv-compat systemd-sysvcompat)
			;;
		esac
	elif [[ "$os_type" == "arch" ]]; then
		option_packages=(xorg-xdpyinfo xorg-xauth net-tools inetutils libxcrypt-compat)
		must_packages=(psmisc tar gcc make bc unzip libnsl libaio)
	fi
	if [[ "$cpu_type" == "aarch64" ]]; then
		must_packages+=(psmisc gcc g++)
	fi
	packages=("${must_packages[@]}" "${option_packages[@]}")
	local packages_display
	packages_display=$(printf '%s \\\n' "${packages[@]}" | sed '$s/\\$//')
	color_printf blue "$packages_display"
	log_print "静默安装软件包"
	install_package "${packages[@]}"
	color_printf blue "检查必需软件包安装情况："
	if [[ "$os_type" =~ ^(ubuntu|debian|Deepin)$ ]]; then
		for package in "${must_packages[@]}"; do
			dpkg-query -f '${binary:Package}\n' -W | grep "$package"
		done
	elif [[ "$os_type" == "arch" ]]; then
		for package in "${must_packages[@]}"; do
			pacman -Qs "$package"
		done
	else
		rpm -q "${must_packages[@]}"
	fi
}

#==============================================================#
#                             杂项                              #
#==============================================================#
function check_opatch_version() {
	local opatch_path=$1/OPatch/opatch
	$opatch_path version
}
function print_sysinfo() {
	log_print "打印系统信息"
	print_cpu_info() {
		local keys=("A" "B" "C" "D" "E")
		declare -A keywords=(
			["A"]="$(grep </proc/cpuinfo "model name" | head -n 1 | awk -F ': ' '{print $2}')"
			["A_DESC"]="型号名称                "
			["B"]="$(grep </proc/cpuinfo "physical id" | sort | uniq | wc -l)"
			["B_DESC"]="物理 CPU 个数           "
			["C"]="$(grep </proc/cpuinfo "core id" | sort -u | wc -l)"
			["C_DESC"]="每个物理 CPU 的逻辑核数 "
			["D"]="$(grep -c "processor" /proc/cpuinfo)"
			["D_DESC"]="系统的 CPU 线程数       "
			["E"]="$cpu_type"
			["E_DESC"]="系统的 CPU 类型         "
		)
		for key in "${keys[@]}"; do
			local desc="${keywords[${key}_DESC]}"
			local value="${keywords[$key]}"
			color_printf green "$desc ：$value"
		done
	}
	color_printf blue "服务器时间: "
	date
	echo
	color_printf blue "操作系统版本: "
	if check_file /etc/os-release; then
		cat /etc/os-release
	elif check_file /etc/system-release; then
		cat /etc/system-release
	elif check_file /etc/redhat-release; then
		cat /etc/redhat-release
	fi
	echo
	color_printf blue "内核信息: "
	cat /proc/version
	echo
	color_printf blue "Glibc 版本: "
	ldd --version | head -n 1 | awk '{print $NF}'
	echo
	color_printf blue "CPU 信息: "
	print_cpu_info
	echo
	color_printf blue "内存信息: "
	free -m
	echo
	color_printf blue "挂载信息: "
	grep </etc/fstab -E -v '^#|^$'
	echo
	color_printf blue "目录信息: "
	df -h
}

#==============================================================#
#                       收尾：报告/清理/重启                      #
#==============================================================#
function logo_print() {
	cat <<'EOF'

       ███████                             ██          ████████ ██               ██  ██ ██                    ██              ██  ██
      ██░░░░░██                           ░██         ██░░░░░░ ░██              ░██ ░██░██                   ░██             ░██ ░██
     ██     ░░██ ██████  ██████    █████  ░██  █████ ░██       ░██       █████  ░██ ░██░██ ███████   ██████ ██████  ██████   ░██ ░██
    ░██      ░██░░██░░█ ░░░░░░██  ██░░░██ ░██ ██░░░██░█████████░██████  ██░░░██ ░██ ░██░██░░██░░░██ ██░░░░ ░░░██░  ░░░░░░██  ░██ ░██
    ░██      ░██ ░██ ░   ███████ ░██  ░░  ░██░███████░░░░░░░░██░██░░░██░███████ ░██ ░██░██ ░██  ░██░░█████   ░██    ███████  ░██ ░██
    ░░██     ██  ░██    ██░░░░██ ░██   ██ ░██░██░░░░        ░██░██  ░██░██░░░░  ░██ ░██░██ ░██  ░██ ░░░░░██  ░██   ██░░░░██  ░██ ░██
     ░░███████  ░███   ░░████████░░█████  ███░░██████ ████████ ░██  ░██░░██████ ███ ███░██ ███  ░██ ██████   ░░██ ░░████████ ███ ███
      ░░░░░░░   ░░░     ░░░░░░░░  ░░░░░  ░░░  ░░░░░░ ░░░░░░░░  ░░   ░░  ░░░░░░ ░░░ ░░░ ░░ ░░░   ░░ ░░░░░░     ░░   ░░░░░░░░ ░░░ ░░░

EOF
	echo
	color_printf yellow "注意：本脚本仅用于新服务器上实施部署数据库使用，严禁在已运行数据库的主机上执行，以免发生数据丢失或者损坏，造成不可挽回的损失！！！"
}
function generate_install_report() {
	local execution_time=$1
	local report_file="$software_dir/install_report_${current}.md"
	local install_date
	install_date=$(date '+%Y-%m-%d %H:%M:%S')
	cat >"$report_file" <<REPORT_EOF
# Oracle 数据库安装报告

## 环境信息

| 项目 | 值 |
|------|----|
| 操作系统 | $pretty_name |
| OS 类型 | $os_type $os_version |
| CPU 架构 | $cpu_type |
| 主机名 | $hostname |
| Oracle 版本 | $db_version |
| 数据库名称 | $db_name |
| 安装模式 | $oracle_install_mode |
| 字符集 | $db_characterset |
| 安装目录 | $env_base_dir |
| 安装耗时 | ${execution_time} 秒 |
| 安装时间 | $install_date |

## 各阶段执行情况

| 阶段 | 脚本 | 状态 |
|------|------|------|
| 1. OS 配置 | 1_os_config.sh | $(stage_status 1) |
| 2. 软件安装 | 2_software_install.sh | $(stage_status 2) |
| 3. 数据库创建 | 3_db_create.sh | $(stage_status 3) |
| 4. 后期配置 | 4_post_config.sh | $(stage_status 4) |

## 验证信息

\`\`\`bash
su - $oracle_user -c "sqlplus / as sysdba <<< 'select instance_name, status from v\\\$instance;'"
su - $oracle_user -c "lsnrctl status"
\`\`\`

---

*本报告由 OracleShellInstall 自动生成*
*官网：https://www.oracleshellinstall.com*
REPORT_EOF
	color_printf green "安装报告已生成：$report_file"
}
function print_share_guide() {
	local line="════════════════════════════════════════════════════════════"
	local res='\E[0m'
	local cyan='\E[1;36m'
	local yellow='\E[1;33m'
	local green='\E[1;32m'
	local white='\E[1;37m'
	echo
	printf "${cyan}  ╔${line}╗${res}\n"
	printf "${cyan}  ║${white}  感谢使用 OracleShellInstall！                              ${cyan}║${res}\n"
	printf "${cyan}  ╠${line}╣${res}\n"
	printf "${cyan}  ║${green}  如果本工具帮您节省了时间，欢迎分享您的安装体验：           ${cyan}║${res}\n"
	printf "${cyan}  ║${res}                                                              ${cyan}║${res}\n"
	printf "${cyan}  ║${white}  投稿通道：https://www.oracleshellinstall.com/contribute.html ${cyan}║${res}\n"
	printf "${cyan}  ║${white}  官方邮箱：pc1107750981@163.com                              ${cyan}║${res}\n"
	printf "${cyan}  ╚${line}╝${res}\n"
	echo
}
function install_time_record() {
	local signal=$1
	if [[ "$signal" == "start" ]]; then
		install_start_time=$(date +%s)
		date >>"$oracleinstalllog"
		color_printf green "OracleShellInstall 开始安装，详细安装过程可查看日志： tail -2000f $oracleinstalllog"
		echo
	elif [[ "$signal" == "end" ]]; then
		local install_end_time install_execution_time
		install_end_time=$(date +%s)
		# 单独执行阶段四时可能没有起始时间，置为结束时间避免算出无意义的大数
		[[ -z $install_start_time ]] && install_start_time=$install_end_time
		install_execution_time=$((install_end_time - install_start_time))
		echo
		generate_install_report "$install_execution_time"
		print_share_guide
		ask_for_reboot "恭喜！Oracle 一键安装执行完成 (耗时: $install_execution_time 秒)，现在是否重启主机：[Y/N]"
	fi
}
function end_del_file() {
	rm_file "$software_dir/libaio.so.1"
	rm_file "$software_dir/libaio.tar.xz"
	rm_file "$software_dir/db.rsp"
	rm_file "$software_dir/oracle.rsp"
	rm_file "$software_dir/grid.rsp"
	rm_file "$software_dir/database"
	rm_file "$software_dir/grid"
	rm_file "$software_dir/stat.tar.xz"
	rm_file "$software_dir/stat-stubs.o"
	rm_file "$software_dir/README.txt"
	rm_file "$software_dir/README.html"
	rm_file "$software_dir/bundle.xml"
	rm_file "$software_dir/18370031"
	if [[ $cpu_type == "aarch64" ]]; then
		rm_file "$software_dir/fstat64.oS"
		rm_file "$software_dir/lstat64.oS"
		rm_file "$software_dir/lstat.oS"
		rm_file "$software_dir/stat64.oS"
		rm_file "$software_dir/fstatat64.oS"
		rm_file "$software_dir/mknod.oS"
	fi
	if [[ $grid_patch ]]; then
		rm_file "$software_dir/$grid_patch"
	fi
	if [[ $oracle_patch ]]; then
		rm_file "$software_dir/$oracle_patch"
	fi
}
function ask_for_reboot() {
	declare -u isreboot
	read -rep "$(echo -e "\033[1;34m$1 \E[0m")" isreboot
	echo
	end_del_file
	if [[ $isreboot == "Y" ]]; then
		if [[ "$oracle_install_mode" == "rac" ]]; then
			for ip in "${rac_public_ips[@]:1}"; do
				color_printf blue "正在重启节点 $ip 主机......"
				ssh -q "$ip" "$(typeset -f check_file); $(typeset -f rm_file); $(typeset -f end_del_file); end_del_file"
				ssh -q "$ip" shutdown -r now
			done
		fi
		color_printf blue "正在重启当前节点主机......"
		shutdown -r now
	else
		exit 0
	fi
}
