#!/usr/bin/env bash
#===============================================================
# lib/args.sh —— 参数解析、前置校验、安装包信息识别
# 依赖：lib/common.sh、lib/state.sh、lib/os_adapt.sh
#===============================================================

#==============================================================#
#                           Usage                              #
#==============================================================#
function help() {
	print_options() {
		local options=("$@")
		for option in "${options[@]}"; do
			color_printf green "${option%% *}" "${option#* }"
		done
	}
	color_printf blue "用法: run_all.sh [选项]  （或单独执行 1_os_config.sh / 2_software_install.sh / 3_db_create.sh / 4_post_config.sh）"
	color_printf blue "公共参数："
	options=(
		"-c 从配置文件读取参数（Web 配置中心产出的 install.conf），命令行参数优先级更高"
		"-lrp 配置本地软件源，需要挂载本地 ISO 镜像源，默认值：[Y]"
		"-nrp 配置网络软件源，默认值：[N]"
		"-lf [必填] 公网 IP 的网卡名称"
		"-n 主机名，默认值：[orcl]"
		"-ou 系统 oracle 用户名称，默认值：[oracle]"
		"-op 系统 oracle 用户密码，若包含特殊字符必须以单引号包裹，例如：'Passw0rd#'，默认值：[oracle]"
		"-d Oracle 软件安装根目录，默认值：[/u01]"
		"-ord Oracle 数据文件目录，默认值：[/oradata]"
		"-ard Oracle 归档文件目录，默认值：[/oradata/archivelog]"
		"-o Oracle 数据库名称，默认值：[orcl]"
		"-dp Oracle 数据库 sys/system 密码，默认值：[oracle]"
		"-ds 数据库字符集，默认值：[AL32UTF8]"
		"-ns 数据库国家字符集，默认值：[AL16UTF16]"
		"-dbs 数据库块大小，默认值：[8192]，可选：[2048|4096|8192|16384|32768]"
		"-er 是否启用归档日志，默认值：[true]"
		"-pdb 用于 CDB 架构，PDB 名称，支持传入多个PDB：-pdb pdb01,pdb02，默认值：[pdb01]"
		"-redo 数据库 redo 日志文件大小，单位为 MB，默认值[1024]"
		"-opa Oracle PSU/RU 补丁编号"
		"-jpa Oracle OJVM PSU/RU 补丁编号"
		"-m 仅配置操作系统，默认值：[N]"
		"-ud 安装到 Oracle 软件结束，默认值：[N]"
		"-gui 是否安装系统图形界面，默认值：[N]"
		"-opd 安装完成是否优化 Oracle 数据库，默认值：[N]"
		"-hf 安装完成是否配置内存大页，默认值：[N]"
		"-debug 打开调试模式（set -x）"
	)
	print_options "${options[@]}"
	echo
	color_printf blue "单机 ASM 模式附加参数："
	options=(
		"-gu 系统 grid 用户名称，默认值：[grid]"
		"-gp 系统 grid 用户密码，默认值：[oracle]"
		"-adc 是否需要脚本配置 ASM 磁盘，默认值：[Y]"
		"-mp 是否需要脚本配置 multipath 多路径，默认值：[Y]"
		"-dd [必填] ASM DATA 磁盘组的磁盘列表，例如：-dd /dev/sdb"
		"-dn ASM DATA 磁盘组名称，默认值：[DATA]"
		"-dr ASM DATA 磁盘组冗余度，默认值：[EXTERNAL]"
		"-gpa Grid PSU/RU 补丁编号"
		"-vbox 在虚拟机 virtualbox 上安装时需要设置 -vbox Y，默认值：[N]"
		"-fd 过滤多路径磁盘，获取唯一盘符：-fd /dev/sda,/dev/sdb"
	)
	print_options "${options[@]}"
	echo
	color_printf blue "RAC 集群模式附加参数："
	options=(
		"-pf [必填] RAC 所有节点心跳 IP 的网卡名称，例如：-pf eth3,eth4"
		"-hn [必填] RAC 所有节点主机名，按节点顺序排序，例如：-hn orcl01,orcl02"
		"-ri [必填] RAC 所有节点公网 IP 地址，例如：-ri 10.211.55.100,10.211.55.101"
		"-vi [必填] RAC 所有节点虚拟 IP 地址"
		"-si [必填] RAC scan IP 地址"
		"-rp [必填] 系统 root 用户密码，所有节点必须保持一致，用于建立互信"
		"-cn RAC 集群名称，长度不能超过15位，默认值：[主机名前缀-cluster]"
		"-sn RAC scan名称，默认值：[主机名前缀-scan]"
		"-od [必填] ASM OCR 磁盘组的磁盘列表"
		"-ad ASM 归档日志磁盘组的磁盘列表"
		"-on ASM OCR 磁盘组名称，默认值：[OCR]"
		"-an ASM ARCH 磁盘组名称，默认值：[ARCH]"
		"-or ASM OCR 磁盘组冗余度，默认值：[EXTERNAL]"
		"-ar ASM ARCH 磁盘组冗余度，默认值：[EXTERNAL]"
		"-tsi RAC CTSS 的时间服务器 IP 地址"
		"-dns 是否配置 DNS，多个 scan ip 时需要，默认值：[N]"
		"-dnsn DNS 服务器名称"
		"-dnsi DNS 服务器 IP 地址"
		"-ug 安装到 Grid 软件结束，默认值：[N]"
		"-node 节点号，脚本内部参数，RAC 其他节点由主节点自动下发"
	)
	print_options "${options[@]}"
}

#==============================================================#
#                          传参前校验                            #
#==============================================================#
function pre_para_check() {
	if [[ "$ORACLE_INSTALL_DIR" != "/soft" ]]; then
		color_printf yellow "注意：建议将 Oracle 软件安装包以及脚本放到 /soft 目录下并在 /soft 目录下执行脚本，否则可能会失败！"
	fi
	if [ "$(id -u)" != 0 ]; then
		color_printf red "本脚本需要使用 root 用户执行，已退出！"
	fi
	if ! type ping >/dev/null 2>&1; then
		color_printf red "本脚本需要使用 ping 命令，请提前安装！"
	fi
}

#==============================================================#
#                         配置文件加载                           #
#==============================================================#
# 读取 KEY=VALUE 形式的配置文件，供 Web 配置中心产出的 install.conf 使用。
# 出于安全考虑，只接受变量赋值行，拒绝任何其它 shell 语法，避免 source 到任意代码。
function load_conf() {
	local conf_file=$1
	[[ -z $conf_file ]] && return 0
	# 不含斜杠时 bash 的 source 只搜 $PATH 不搜当前目录，这里统一补成绝对路径
	if [[ $conf_file != */* ]] && [[ ${software_dir:-} ]] && check_file "${software_dir}/${conf_file}"; then
		conf_file="${software_dir}/${conf_file}"
	fi
	if ! check_file "$conf_file"; then
		color_printf red "参数 [ -c ] 指定的配置文件 $conf_file 不存在，请检查！"
	fi
	if grep -qvE '^[[:space:]]*(#|$|[A-Za-z_][A-Za-z0-9_]*=)' "$conf_file"; then
		color_printf red "配置文件 $conf_file 存在非法行，只允许空行、# 注释和 KEY=VALUE 形式！"
	fi
	source "$conf_file"
	color_printf green "已加载配置文件" "$conf_file"
}

#==============================================================#
#                            校验传参                           #
#==============================================================#
function accept_para() {
	# 先加载配置文件，再解析命令行，因此命令行参数优先级更高
	local argv=("$@") conf_file="" i
	for ((i = 0; i < $#; i++)); do
		if [[ ${argv[i]} == "-c" || ${argv[i]} == "--conf" ]]; then
			conf_file=${argv[i + 1]}
		fi
	done
	load_conf "$conf_file"
	while [[ $1 ]]; do
		case $1 in
		-c | --conf)
			shift 2
			;;
		-node | --node_num)
			node_num=$2
			shift 2
			;;
		-lrp | --local_repo)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			local_repo=$2
			shift 2
			;;
		-nrp | --net_repo)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			net_repo=$2
			shift 2
			;;
		-o | --db_name)
			checkpara_NULL "$1" "$2"
			db_name=$2
			shift 2
			;;
		-n | --hostname)
			checkpara_NULL "$1" "$2"
			hostname=$2
			shift 2
			;;
		-hn | --rac_hostname)
			checkpara_NULL "$1" "$2"
			rac_hostname=$2
			shift 2
			;;
		-sn | --scan_name)
			checkpara_NULL "$1" "$2"
			check_RACNAME "$1" "$2"
			scan_name=$2
			shift 2
			;;
		-cn | --cluster_name)
			checkpara_NULL "$1" "$2"
			check_RACNAME "$1" "$2"
			cluster_name=$2
			shift 2
			;;
		-d | --env_base_dir)
			checkpara_NULL "$1" "$2"
			env_base_dir=${2%/}
			shift 2
			;;
		-ord | --oradata_dir)
			checkpara_NULL "$1" "$2"
			oradata_dir=${2%/}
			shift 2
			;;
		-ard | --archive_dir)
			checkpara_NULL "$1" "$2"
			archive_dir=${2%/}
			shift 2
			;;
		-rp | --root_passwd)
			checkpara_NULL "$1" "$2"
			check_password "$1" "$2"
			root_passwd=$2
			shift 2
			;;
		-gu | --grid_user)
			checkpara_NULL "$1" "$2"
			grid_user=$2
			shift 2
			;;
		-gp | --grid_passwd)
			checkpara_NULL "$1" "$2"
			check_password "$1" "$2"
			grid_passwd=$2
			shift 2
			;;
		-ou | --oracle_user)
			checkpara_NULL "$1" "$2"
			oracle_user=$2
			shift 2
			;;
		-op | --oracle_passwd)
			checkpara_NULL "$1" "$2"
			check_password "$1" "$2"
			oracle_passwd=$2
			shift 2
			;;
		-dp | --database_passwd)
			checkpara_NULL "$1" "$2"
			check_password "$1" "$2"
			database_passwd=$2
			shift 2
			;;
		-lf | --local_ifname)
			checkpara_NULL "$1" "$2"
			local_ifname=$2
			shift 2
			;;
		-pf | --rac_priv_ifname)
			checkpara_NULL "$1" "$2"
			rac_priv_ifname=$2
			shift 2
			;;
		-ri | --rac_public_ip)
			checkpara_NULL "$1" "$2"
			rac_public_ip=$2
			shift 2
			;;
		-vi | --rac_virtual_ip)
			checkpara_NULL "$1" "$2"
			rac_virtual_ip=$2
			shift 2
			;;
		-si | --rac_scan_ip)
			checkpara_NULL "$1" "$2"
			rac_scan_ip=$2
			shift 2
			;;
		-ds | --db_characterset)
			checkpara_NULL "$1" "$2"
			checkpara_DBCHARSET "$1" "$2"
			db_characterset=$2
			shift 2
			;;
		-ns | --nation_characterset)
			checkpara_NULL "$1" "$2"
			checkpara_NCHARSET "$1" "$2"
			nation_characterset=$2
			shift 2
			;;
		-dbs | --db_block_size)
			checkpara_NUMERIC "$1" "$2"
			checkpara_DBS "$1" "$2"
			db_block_size=$2
			shift 2
			;;
		-redo | --redosize)
			checkpara_NULL "$1" "$2"
			redosize=$2
			shift 2
			;;
		-er | --enable_arch)
			checkpara_NULL "$1" "$2"
			checkpara_tf "$1" "$2"
			enable_arch=$2
			shift 2
			;;
		-pdb | --pdbname)
			checkpara_NULL "$1" "$2"
			pdbname=$2
			iscdb=true
			shift 2
			;;
		-dnsn | --dns_name)
			checkpara_NULL "$1" "$2"
			dns_name=$2
			shift 2
			;;
		-dnsi | --dns_ip)
			checkpara_NULL "$1" "$2"
			dns_ip=$2
			shift 2
			;;
		-dns | --dns)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			dns=$2
			shift 2
			;;
		-on | --ocr_asm_group)
			checkpara_NULL "$1" "$2"
			ocr_asm_group=$2
			shift 2
			;;
		-dn | --data_asm_group)
			checkpara_NULL "$1" "$2"
			data_asm_group=$2
			shift 2
			;;
		-an | --arch_asm_group)
			checkpara_NULL "$1" "$2"
			arch_asm_group=$2
			shift 2
			;;
		-mp | --multipath)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			multipath=$2
			shift 2
			;;
		-adc | --asm_disk_conf)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			asm_disk_conf=$2
			shift 2
			;;
		-od | --ocr_base_disk)
			checkpara_NULL "$1" "$2"
			ocr_base_disk=$2
			shift 2
			;;
		-dd | --data_base_disk)
			checkpara_NULL "$1" "$2"
			data_base_disk=$2
			shift 2
			;;
		-ad | --arch_base_disk)
			checkpara_NULL "$1" "$2"
			arch_base_disk=$2
			shift 2
			;;
		-or | --ocr_redun)
			checkpara_NULL "$1" "$2"
			checkpara_REDUN "$1" "$2"
			ocr_redun=$2
			shift 2
			;;
		-dr | --data_redun)
			checkpara_NULL "$1" "$2"
			checkpara_REDUN "$1" "$2"
			data_redun=$2
			shift 2
			;;
		-ar | --arch_redun)
			checkpara_NULL "$1" "$2"
			checkpara_REDUN "$1" "$2"
			arch_redun=$2
			shift 2
			;;
		-tsi | --timeserver_ip)
			checkpara_NULL "$1" "$2"
			timeserver_ip=$2
			shift 2
			;;
		-gui | --isgui)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			isgui=$2
			shift 2
			;;
		-vbox | --virtualbox)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			virtualbox=$2
			shift 2
			;;
		-gpa | --grid_patch)
			checkpara_NULL "$1" "$2"
			grid_patch=$2
			shift 2
			;;
		-opa | --oracle_patch)
			checkpara_NULL "$1" "$2"
			oracle_patch=$2
			shift 2
			;;
		-jpa | --ojvm_patch)
			checkpara_NULL "$1" "$2"
			ojvm_patch=$2
			shift 2
			;;
		-m | --only_conf_os)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			only_conf_os=$2
			shift 2
			;;
		-ug | --install_until_grid)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			install_until_grid=$2
			shift 2
			;;
		-ud | --install_until_db)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			install_until_db=$2
			shift 2
			;;
		-opd | --optimize_db)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			optimize_db=$2
			shift 2
			;;
		-install_mode | --oracle_install_mode)
			checkpara_NULL "$1" "$2"
			oracle_install_mode=$2
			shift 2
			;;
		-giv | --gi_version)
			checkpara_NULL "$1" "$2"
			gi_version=$2
			shift 2
			;;
		-dbv | --db_version)
			checkpara_NULL "$1" "$2"
			db_version=$2
			shift 2
			;;
		-hf | --huge_flag)
			checkpara_NULL "$1" "$2"
			checkpara_YN "$1" "$2"
			huge_flag=$2
			shift 2
			;;
		-debug | --debug)
			debug_flag="Y"
			shift 1
			;;
		-fd | --filter_disk)
			checkpara_NULL "$1" "$2"
			get_os_info
			filter_disk "$2"
			exit 0
			;;
		-h | --help)
			help
			exit 0
			;;
		*)
			color_printf red "脚本执行命令中的参数 [ $1 ] 传参不正确，请使用 '-h' 以获取更多帮助信息！"
			;;
		esac
	done
}

#==============================================================#
#                     主节点必传参数与业务校验                    #
#==============================================================#
function conf_master_node() {
	local paras paran parav
	paras=("-lf local_ifname")
	if [[ $oracle_install_mode == "standalone" ]]; then
		paras+=("-dd data_base_disk")
	elif [[ $oracle_install_mode == "rac" ]]; then
		paras+=(
			"-pf rac_priv_ifname"
			"-n hostname"
			"-hn rac_hostname"
			"-rp root_passwd"
			"-ri rac_public_ip"
			"-vi rac_virtual_ip"
			"-si rac_scan_ip"
			"-od ocr_base_disk"
			"-dd data_base_disk"
		)
	fi
	for para in "${paras[@]}"; do
		paran=${para%% *}
		parav=${para##* }
		if [[ -z ${!parav} ]]; then
			color_printf red "Oracle $oracle_install_mode 模式安装必须设置参数：[ $paran ]，请运行命令 'sh run_all.sh -h' 以获取更多帮助信息！"
		fi
	done
	for name in "${db_names[@]}"; do
		local length=${#name}
		check_DBNAME "$name"
		if ((length > 8 && length <= 12)); then
			color_printf purple "数据库名称 $name 长度超过 8 位，受 Oracle 限制，建库时会自动截取前 8 位作为数据库名称：${name:0:8}，请确认是否继续 (Y/N): [Y] "
			echo
		elif ((length > 12)); then
			color_printf red "数据库实例名称 $name 长度不能超过 12 位，受 Oracle 限制，建库会报错失败，请检查参数 [ -o ] 的值！"
			echo
		fi
	done
	if [[ $local_ip ]]; then
		if check_ip "$local_ip"; then
			check_ip_connectivity "$local_ip"
		else
			color_printf red "参数 [ -lf ] 网卡名称：$local_ifname 对应的 IP：$local_ip 不合规，请检查！"
		fi
	else
		color_printf red "参数 [ -lf ] 网卡名称：$local_ifname 不存在或者未配置 IP 信息，请检查！"
	fi
	if [[ $oracle_patch ]]; then
		db_patch_name=$(find "$software_dir" -type f -name "*$oracle_patch*zip")
		if ! check_file "$db_patch_name"; then
			color_printf red "参数 [ -opa ] 对应的补丁包：$db_patch_name 是否已上传至目录：$software_dir，请检查并上传！"
		fi
	fi
	if [[ $ojvm_patch ]]; then
		ojvm_patch_name=$(find "$software_dir" -type f -name "*$ojvm_patch*zip")
		if ! check_file "$ojvm_patch_name"; then
			color_printf red "参数 [ -jpa ] 对应的补丁包：$ojvm_patch_name 是否已上传至目录：$software_dir，请检查并上传！"
		fi
	fi
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		if [[ $grid_patch ]]; then
			grid_patch_name=$(find "$software_dir" -type f -name "*$grid_patch*zip")
			if ! check_file "$grid_patch_name"; then
				color_printf red "参数 [ -gpa ] 对应的补丁包：$grid_patch_name 是否已上传至目录：$software_dir，请检查并上传！"
			fi
		fi
		if [[ "$os_version" =~ ^(7|8|9|10)$ ]]; then
			if ((gi_version == 11)); then
				if check_file "$software_dir"/p18370031_112040_Linux-x86-64.zip; then
					check_md5sum "$software_dir/p18370031_112040_Linux-x86-64.zip" "2a081e6145d4e4d2bf5350709dd3affa"
				else
					color_printf red "在 Linux 7 安装 11GR2 RAC 时，必须应用补丁 18370031，请上传补丁包 p18370031_112040_Linux-x86-64.zip 到 $software_dir 目录下！"
				fi
			fi
		fi
	fi
	if [[ "$oracle_install_mode" == "rac" ]]; then
		if ((${#rac_priv_ifnames[@]} > 2)); then
			color_printf red "参数 [ -pf ] 心跳网卡不建议超过 2 组！"
		fi
		for public_ip in "${rac_public_ips[@]}"; do
			if check_ip "$public_ip"; then
				allips+=("$public_ip")
				ssh_ips+=("$public_ip")
				check_ip_connectivity "$public_ip"
			else
				color_printf red "参数 [ -ri ] 中的 IP：$public_ip 不合规，请检查！"
			fi
		done
		for virtual_ip in "${rac_virtual_ips[@]}"; do
			if check_ip "$virtual_ip"; then
				allips+=("$virtual_ip")
				check_ip_unreachability "Virtual IP" "$virtual_ip"
			else
				color_printf red "参数 [ -vi ] 中的 IP：$virtual_ip 不合规，请检查！"
			fi
		done
		for ((i = 0; i < ${#rac_scan_ips[@]}; i++)); do
			if check_ip "${rac_scan_ips[i]}"; then
				allips+=("${rac_scan_ips[i]}")
				check_ip_unreachability "SCAN IP" "${rac_scan_ips[i]}"
			else
				color_printf red "参数 [ -si ] 中的 IP 地址：${rac_scan_ips[i]} 不合规，请检查！"
			fi
		done
		if [[ "$dns_ip" ]]; then
			if check_ip "$dns_ip"; then
				allips+=("$dns_ip")
				check_ip_connectivity "$dns_ip"
			else
				color_printf red "参数 [ -dnsi ] IP 地址：$dns_ip 不合规，请检查！"
			fi
		fi
		if [[ "$timeserver_ip" ]]; then
			if check_ip "$timeserver_ip"; then
				allips+=("$timeserver_ip")
				check_ip_connectivity "$timeserver_ip"
			else
				color_printf red "参数 [ -tsi ] IP 地址：$timeserver_ip 不合规，请检查！"
			fi
		fi
		isunique_ip
		if [[ "$local_ip" != "${rac_public_ips[0]}" ]]; then
			color_printf red "参数 [ -ri ] 的值：${rac_public_ips[0]} 第一个 IP 不是主节点的 IP，请检查参数！"
		fi
		if [[ -z $cluster_name ]]; then
			if ((${#hostname} > 7)); then
				color_printf red "参数 [ -cn ] 未配置，但是参数 [ -n ] 的值：$hostname 已超过 7 位，组成的集群名称将超过 15 位，不符合官方要求，请检查！"
			fi
		else
			if ((${#cluster_name} > 15)); then
				color_printf red "参数 [ -cn ] 集群名称：$cluster_name 已超过 15 位，不符合官方要求，请检查！"
			fi
		fi
		if [[ -z $scan_name ]]; then
			if [[ "$hostname" =~ ^[0-9] ]]; then
				color_printf red "参数 [ -sn ] 未配置，默认 SCAN 名称取自参数 [ -n ] 值拼接而成，SCAN 名称不能以数字开头，请检查参数 [ -n ] 值: $hostname！"
			fi
		fi
		if [[ $dns == "Y" ]]; then
			if [[ -z $dns_name || -z $dns_ip ]]; then
				color_printf red "参数 [ -dns ] 已传参，但是级联参数 [ -dnsn ] 和 [ -dnsi ] 没有传参，请检查！"
			fi
		else
			if ((scan_count > 1)); then
				color_printf red "参数 [ -si ] SCAN IP 数量超过 1 个，需要配置 DNS，但是配置 DNS 参数 [ -dns ] 没有传参，请检查！"
			fi
		fi
		for host in "${rac_hostnames[@]}"; do
			if ((db_version == 11)); then
				if [[ "$host" == *[[:upper:]]* ]]; then
					color_printf red "Oracle 11GR2 RAC 安装主机名不能包含大写字母，请检查主机名: $host！"
				fi
			fi
		done
		# root 用户互信（后续下发脚本与补丁依赖）
		execute_and_log "配置 root 用户互信" root_ssh_trust
		# 检查主机时间是否一致，相差超过 10s 则更新其他节点为本节点时间
		execute_and_log "正在检查并更新 RAC 主机时间" check_and_update_date
		# 生成其他节点参数并分发脚本
		send_to_other_nodes
		# 安装 12CR2 RAC 存在 bug，必须上传 GRID RU 补丁包
		if ((gi_version == 12)); then
			if [[ $grid_patch ]]; then
				if ((grid_patch < 28828733)); then
					color_printf red "本脚本安装 12CR2 RAC 时，必须安装 Grid PSU 补丁号为 12.2.0.1.190115(28828733) 或者之后的 PSU 版本，请使用参数 [ -gpa ] 安装补丁！"
				fi
			else
				local ocr_avg_storage reduns ocr_total_storage=0 ocr_disks
				IFS=',' read -ra ocr_disks <<<"$ocr_base_disk"
				for disk in "${ocr_disks[@]}"; do
					if [[ -n "$disk" ]]; then
						ocr_storage=$(lsblk -b -o SIZE,TYPE "$disk" | awk '$2 == "disk" {print $1/1024/1024/1024}')
						ocr_total_storage=$((ocr_total_storage + ocr_storage))
					fi
				done
				if [[ $ocr_redun == "EXTERNAL" ]]; then
					reduns=1
				elif [[ $ocr_redun == "NORMAL" ]]; then
					reduns=3
				elif [[ $ocr_redun == "HIGH" ]]; then
					reduns=5
				fi
				ocr_avg_storage=$((ocr_total_storage / reduns))
				if ((ocr_avg_storage < 50)); then
					color_printf red "Oracle 12CR2 基础版官方默认必须安装 GIMR 组件（OCR 磁盘组至少需要 50 G 空间），当前 OCR 冗余计算后为 [ $ocr_avg_storage G ] ，建议增加 OCR 磁盘空间或者安装 Grid PSU 补丁号为 12.2.0.1.190115(28828733) 之后的版本！"
				else
					gimr=true
				fi
			fi
		fi
	fi
}

#==============================================================#
#                      RAC 主节点特有流程                        #
#==============================================================#
function check_and_update_date() {
	log_print "检查并更新 RAC 主机时间"
	color_printf green "当前主机时间: $(date)"
	echo
	for ip in "${rac_public_ips[@]:1}"; do
		local time_diff_threshold=10 local_time remote_time
		hwclock --systohc >/dev/null 2>&1
		local_time=$(date +%s)
		remote_time=$(ssh -q -o ConnectTimeout=1 -o ConnectionAttempts=1 -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no "${ip}" "date +%s")
		local time_diff=$((remote_time - local_time))
		time_diff=${time_diff#-}
		if ((time_diff > time_diff_threshold)); then
			color_printf blue "目标主机 (${ip}) 时间误差: ${time_diff} 秒超过 10 秒，正在自动调整目标主机时间："
			ssh -q -o ConnectTimeout=1 -o ConnectionAttempts=1 -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no "${ip}" "date -s '@${local_time}' && hwclock --systohc" >/dev/null 2>&1
			echo
			color_printf blue "主机 (${ip}) 时间已经更新。"
		else
			color_printf blue "目标主机 (${ip}) 时间误差: ${time_diff} 秒小于 10 秒，无需调整！"
		fi
	done
}
function send_to_other_nodes() {
	local node_cmd="./1_os_config.sh -lf $local_ifname -pf $rac_priv_ifname -ri $rac_public_ip \
              -vi $rac_virtual_ip -n $hostname -hn $rac_hostname -o $db_name -d $env_base_dir -rp $root_passwd \
              -gu $grid_user -gp $grid_passwd -ou $oracle_user -op $oracle_passwd -mp $multipath -dns $dns -si $rac_scan_ip \
              -adc $asm_disk_conf -or $ocr_redun -dr $data_redun -install_mode $oracle_install_mode \
              -dbv $db_version -giv $gi_version -gui $isgui -lrp $local_repo -nrp $net_repo -hf $huge_flag -vbox $virtualbox -sn $scan_name"
	if [[ $asm_disk_conf == "N" ]]; then
		node_cmd+=" -od $ocr_base_disk -dd $data_base_disk"
	else
		node_cmd+=" -od $ocr_disk_wwid -dd $data_disk_wwid"
	fi
	if [[ $arch_base_disk ]]; then
		if [[ $asm_disk_conf == "N" ]]; then
			node_cmd+=" -an $arch_asm_group -ad $arch_base_disk -ar $arch_redun"
		else
			node_cmd+=" -an $arch_asm_group -ad $arch_disk_wwid -ar $arch_redun"
		fi
	fi
	if [[ $timeserver_ip ]]; then
		node_cmd+=" -tsi $timeserver_ip"
	fi
	if [[ $dns_ip && $dns_name ]]; then
		node_cmd+=" -dnsn $dns_name -dnsi $dns_ip"
	fi
	echo -n "$node_cmd" >"$software_dir"/racnode.sh
	for ((i = 1; i < ${#rac_public_ips[@]}; i++)); do
		ssh -q "${rac_public_ips[i]}" "[[ -f $software_dir || -d $software_dir ]] && /bin/rm -rf $software_dir ; /bin/mkdir -p $software_dir"
		scp -q "$software_dir"/racnode.sh "${rac_public_ips[i]}":"$software_dir"
		ssh -q "${rac_public_ips[i]}" "echo -n ' -node $((i + 1))' >> $software_dir/racnode.sh"
		scp -q "$ORACLE_INSTALL_DIR"/1_os_config.sh "${rac_public_ips[i]}":"$software_dir"
		scp -q -r "$ORACLE_INSTALL_DIR"/lib "${rac_public_ips[i]}":"$software_dir"
		if check_file "$grid_opatch_name"; then
			scp -q "$grid_opatch_name" "${rac_public_ips[i]}":"$software_dir"
		fi
		if [[ "$gi_version" != "$db_version" ]]; then
			if check_file "$db_opatch_name"; then
				scp -q "$db_opatch_name" "${rac_public_ips[i]}":"$software_dir"
			fi
		fi
		case "$os_type-$os_version" in
		"anolis-7")
			if check_file "$software_dir"/libc-2.17.so; then
				scp -q "$software_dir"/libc-2.17.so "${rac_public_ips[i]}":"$software_dir"
			fi
			;;
		esac
		if ls "$software_dir"/libnsl-*.rpm >/dev/null 2>&1; then
			find "$software_dir" -name "libnsl-*.rpm" -exec scp -q {} "${rac_public_ips[i]}":"$software_dir" \;
		fi
		if ls "$software_dir"/rlwrap-*.gz >/dev/null 2>&1; then
			find "$software_dir" -name "rlwrap-*.gz" -exec scp -q {} "${rac_public_ips[i]}":"$software_dir" \;
		fi
	done
	rm_file "$software_dir/racnode.sh"
}
function other_node_shell() {
	for ip in "${rac_public_ips[@]:1}"; do
		log_print "配置 RAC 节点：$ip"
		color_printf blue "正在节点：$ip 上执行脚本："
		ssh -t -q "$ip" "cd $software_dir && sh racnode.sh"
		color_printf blue "配置 RAC 节点：$ip 结束！"
	done
}

#==============================================================#
#                        获取安装包信息                          #
#==============================================================#
function get_grid_soft() {
	case "$gi_version" in
	"11")
		cvu_name="cvuqdisk-1.0.9-1.rpm"
		;;
	*)
		cvu_name="cvuqdisk-1.0.10-1.rpm"
		;;
	esac
	declare -A gi_version_dirs=(
		["11"]="$software_dir/p6880880_112000_Linux-x86-64.zip;$env_base_dir/app/11.2.0/grid;$software_dir/p13390677_112040_Linux-x86-64_3of7.zip;$software_dir/grid/rpm/$cvu_name;11.2.0.4.0"
		["12"]="$software_dir/p6880880_122010_Linux-x86-64.zip;$env_base_dir/app/12.2.0/grid;$software_dir/LINUX.X64_122010_grid_home.zip;$env_grid_home/cv/rpm/$cvu_name;12.2.0.1.0"
		["19"]="$software_dir/p6880880_190000_Linux-x86-64.zip;$env_base_dir/app/19.3.0/grid;$software_dir/LINUX.X64_193000_grid_home.zip;$env_grid_home/cv/rpm/$cvu_name;19.0.0.0.0"
		["21"]="$software_dir/p6880880_210000_Linux-x86-64.zip;$env_base_dir/app/21.3.0/grid;$software_dir/LINUX.X64_213000_grid_home.zip;$env_grid_home/cv/rpm/$cvu_name;21.0.0.0.0"
		["26"]="$software_dir/p6880880_230000_Linux-x86-64.zip;$env_base_dir/app/26.1.0/grid;$software_dir/LINUX.X64_2326100_grid_home.zip;$env_grid_home/cv/rpm/$cvu_name;23.0.0.0.0"
	)
	IFS=";" read -r grid_opatch_name env_grid_home grid_soft_name cvuqdisk gi_compatible <<<"${gi_version_dirs[$gi_version]}"
	if [[ $cpu_type == "aarch64" ]]; then
		grid_soft_name=$software_dir/LINUX.ARM64_1919000_grid_home.zip
		grid_opatch_name=$software_dir/p6880880_190000_Linux-ARM-64.zip
	fi
	if ((node_num == 1)); then
		if check_file "$grid_soft_name"; then
			case "${gi_version}" in
			"11") check_md5sum "$grid_soft_name" "04cef37991db18f8190f7d4a19b26912" ;;
			"12") check_md5sum "$grid_soft_name" "ac1b156334cc5e8f8e5bd7fcdbebff82" ;;
			"19")
				if [[ $cpu_type == "aarch64" ]]; then
					check_md5sum "$grid_soft_name" "e8666c88c56d77c4bdf0188673b3fe37"
				else
					check_md5sum "$grid_soft_name" "b7c4c66f801f92d14faa0d791ccda721"
				fi
				;;
			"21") check_md5sum "$grid_soft_name" "b3fbdb7621ad82cbd4f40943effdd1be" ;;
			"26") check_md5sum "$grid_soft_name" "d1161f1297593e5a681400f0dc124b9e" ;;
			esac
		else
			color_printf red "请检查 Grid 软件安装包 $grid_soft_name 是否已上传至 $software_dir 目录下！"
		fi
		if [[ $grid_patch ]]; then
			if ! check_file "$grid_opatch_name"; then
				color_printf red "OPatch 补丁包：$grid_opatch_name 不存在，请检查并上传！"
			fi
		fi
	fi
}
function get_db_soft() {
	declare -A db_version_dirs=(
		["11"]="$software_dir/p6880880_112000_Linux-x86-64.zip;$env_oracle_base/product/11.2.0/db;$software_dir/p13390677_112040_Linux-x86-64_1of7.zip;$software_dir/p13390677_112040_Linux-x86-64_2of7.zip;;11.2.0.4.0"
		["12"]="$software_dir/p6880880_122010_Linux-x86-64.zip;$env_oracle_base/product/12.2.0/db;$software_dir/LINUX.X64_122010_db_home.zip;;$iscdb;12.2.0.1.0"
		["19"]="$software_dir/p6880880_190000_Linux-x86-64.zip;$env_oracle_base/product/19.3.0/db;$software_dir/LINUX.X64_193000_db_home.zip;;$iscdb;19.0.0.0.0"
		["21"]="$software_dir/p6880880_210000_Linux-x86-64.zip;$env_oracle_base/product/21.3.0/db;$software_dir/LINUX.X64_213000_db_home.zip;;true;21.0.0.0.0"
		["26"]="$software_dir/p6880880_230000_Linux-x86-64.zip;$env_oracle_base/product/26.1.0/db;$software_dir/LINUX.X64_2326100_db_home.zip;;true;23.0.0.0.0"
	)
	IFS=";" read -r db_opatch_name env_oracle_home db_soft_name db_soft_name1 iscdb db_compatible <<<"${db_version_dirs[$db_version]}"
	if [[ $cpu_type == "aarch64" ]]; then
		db_soft_name=$software_dir/LINUX.ARM64_1919000_db_home.zip
		db_opatch_name=$software_dir/p6880880_190000_Linux-ARM-64.zip
	fi
	if ((node_num == 1)); then
		if ((db_version == 11)); then
			if check_file "$db_soft_name" && check_file "$db_soft_name1"; then
				check_md5sum "$db_soft_name" "1616f61789891a56eafd40de79f58f28"
				check_md5sum "$db_soft_name1" "67ba1e68a4f581b305885114768443d3"
			else
				color_printf red "请检查 Oracle 软件安装包 $db_soft_name,$db_soft_name1 是否已上传至 $software_dir 目录下。"
			fi
		else
			if check_file "$db_soft_name"; then
				case "${db_version}" in
				"12") check_md5sum "$db_soft_name" "1841f2ce7709cf909db4c064d80aae79" ;;
				"19")
					if [[ $cpu_type == "aarch64" ]]; then
						check_md5sum "$db_soft_name" "6c39043ad12e11bcdc505184631e11a2"
					else
						check_md5sum "$db_soft_name" "1858bd0d281c60f4ddabd87b1c214a4f"
					fi
					;;
				"21") check_md5sum "$db_soft_name" "8ac915a800800ddf16a382506d3953db" ;;
				"26") check_md5sum "$db_soft_name" "91f4b49dfd586df2bc904ab61aedeff7" ;;
				esac
			else
				color_printf red "请检查 Oracle 软件安装包 $db_soft_name 是否已上传至 $software_dir 目录下。"
			fi
		fi
		if [[ $oracle_patch || $ojvm_patch ]]; then
			if ! check_file "$db_opatch_name"; then
				color_printf red "OPatch 补丁包：$db_opatch_name 不存在，请检查并上传！"
			fi
		fi
	fi
}

#==============================================================#
#                      选择安装模式与版本                        #
#==============================================================#
function select_db_options() {
	local dbversion
	while :; do
		read -rep "$(echo -e "\033[1;34m请选择安装模式 [单机(si)/单机ASM(sa)/集群(rac)] : \E[0m")" oracle_install_mode
		echo
		case "$oracle_install_mode" in
		si) oracle_install_mode=single ;;
		sa) oracle_install_mode=standalone ;;
		esac
		if [[ "$oracle_install_mode" =~ ^(single|standalone|rac)$ ]]; then
			color_printf green "数据库安装模式:" "$oracle_install_mode"
			break
		else
			color_printf yellow "数据库安装模式输入错误，请重新选择！"
		fi
	done
	if [[ $cpu_type == "aarch64" ]]; then
		dbversion=19
	else
		dbversion='11|12|19|21|26'
	fi
	while :; do
		echo
		read -rep "$(echo -e "\033[1;34m请选择数据库版本 [$dbversion] : \E[0m")" db_version
		echo
		if [[ "$db_version" =~ ^($dbversion)$ ]]; then
			color_printf green "数据库版本:" "$db_version"
			break
		else
			color_printf yellow "数据库版本输入错误，请重新选择！"
		fi
	done
	echo
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		if [[ -z "$gi_version" ]]; then
			gi_version=$db_version
		else
			if ((gi_version < db_version)); then
				color_printf red "参数 [ -giv ] 的值：GI 版本 $gi_version 必须大于等于 DB 版本 $db_version，请检查！"
			fi
		fi
	fi
}

#==============================================================#
#                     参数加工（handle_para）                    #
#==============================================================#
function handle_para() {
	if [[ $software_dir == "$env_base_dir" ]]; then
		color_printf red "Oracle 软件安装包以及脚本不能放在 $env_base_dir，建议创建 /soft 目录存放！"
	fi
	env_oracle_base=$env_base_dir/app/oracle
	env_oracle_inven=$env_base_dir/app/oraInventory
	env_grid_base=$env_base_dir/app/grid
	if [[ -z "$archive_dir" ]]; then
		archive_dir=$oradata_dir/archivelog
	fi
	IFS=',' read -ra db_names <<<"$db_name"
	local_ip=$(ip addr show dev "$local_ifname" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
	if [[ "$oracle_install_mode" == "rac" ]]; then
		IFS=',' read -ra rac_hostnames <<<"$rac_hostname"
		IFS=',' read -ra rac_priv_ifnames <<<"$rac_priv_ifname"
		IFS=',' read -ra rac_public_ips <<<"$rac_public_ip"
		IFS=',' read -ra rac_virtual_ips <<<"$rac_virtual_ip"
		IFS=',' read -ra rac_scan_ips <<<"$rac_scan_ip"
		scan_count=${#rac_scan_ips[@]}
		if [[ -z $scan_name ]]; then
			scan_name=$hostname-scan
		fi
	fi
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		get_grid_soft
	fi
	get_db_soft
	conf_repo
	if ((node_num == 1)); then
		conf_master_node
	else
		if [[ $asm_disk_conf == "Y" ]]; then
			ocr_disk_wwid=$ocr_base_disk
			data_disk_wwid=$data_base_disk
			[[ $arch_base_disk ]] && arch_disk_wwid=$arch_base_disk
		fi
	fi
	case "$oracle_install_mode" in
	"single" | "standalone")
		HOSTNAME=$hostname
		;;
	"rac")
		local_ip=${rac_public_ips[0]}
		HOSTNAME=${rac_hostnames[$((node_num - 1))]}
		if [[ -z $cluster_name ]]; then
			cluster_name=$hostname-cluster
		fi
		declare -a clusternodes_array
		for host in "${rac_hostnames[@]}"; do
			if ((db_version == 12)); then
				clusternodes_array+=("$host:${host}-vip:HUB")
			else
				clusternodes_array+=("$host:${host}-vip")
			fi
		done
		clusternodes=$(printf "%s," "${clusternodes_array[@]}")
		clusternodes=${clusternodes%?}
		local local_ipmask priv_ip rac_priv_ipmask
		local_ipmask=$(ip route show dev "$local_ifname" 2>/dev/null | awk '/kernel/ && /proto/ {print $1}' | cut -d'/' -f1 | head -n 1)
		networkinterfacelist_array=("$local_ifname:$local_ipmask:1")
		for public_ip in "${rac_public_ips[@]}"; do
			for priv_ifname in "${rac_priv_ifnames[@]}"; do
				priv_ip=$(ssh -q "$public_ip" ip addr show dev "$priv_ifname" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
				if check_ip "$priv_ip"; then
					check_ip_connectivity "$priv_ip"
				else
					color_printf red "RAC 节点 $public_ip 参数 [ -pf ] 的网卡名称：$priv_ifname 对应的 IP：$priv_ip 不合规，请检查！"
				fi
				if [[ $public_ip == "$local_ip" ]]; then
					rac_priv_ipmask=$(ip route show dev "$priv_ifname" 2>/dev/null | awk '/kernel/ && /proto/ {print $1}' | cut -d'/' -f1 | head -n 1)
					if ((gi_version == 11)); then
						ausize=1
						networkinterfacelist_array+=("$priv_ifname:$rac_priv_ipmask:2")
					else
						ausize=4
						networkinterfacelist_array+=("$priv_ifname:$rac_priv_ipmask:5")
					fi
				fi
				node_name="${public_ip}_${priv_ifname}"
				rac_priv_ips["$node_name"]=$priv_ip
				rac_priv_ifnames_sorted+=("$node_name")
			done
		done
		networkinterfacelist=$(printf "%s," "${networkinterfacelist_array[@]}")
		networkinterfacelist=${networkinterfacelist%?}
		;;
	esac
}

#==============================================================#
#                         清理旧环境                            #
#==============================================================#
function clean_old_envir() {
	color_printf purple "当前主机已存在数据库用户 $oracle_user 且 $env_base_dir 目录已存在，请检查是否连错主机，若没有则需要清理旧环境后再执行脚本，是否打印清理命令 (Y/N): [Y] "
	echo
	color_printf blue "请使用 root 用户手工执行清理旧环境命令（RAC 模式所有节点均需执行，建议清理完成后重启主机）："
	echo "RAC 模式下清理过程中可能主机会自动重启，重启后再次执行以下命令即可"
	echo
	local users=("$oracle_user") groups=("oinstall" "dba" "oper" "dgdba" "backupdba" "kmdba" "racdba") oracle_processes=("oracle" "$oracle_user" "ora_" "tnslsnr")
	local dirs_to_clean=("/etc/oracle" "$env_base_dir" "$oradata_dir" "$archive_dir") files_to_clean=("/etc" "/opt" "/tmp")
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		dirs_to_clean+=("/etc/init.d/init.tfa" "/etc/init.d/init.ohasd")
		oracle_processes+=("grid" "$grid_user" "crsd.bin" "ohasd.bin" "ohasd" "evmd.bin" "evmlogger.bin" "ocssd.bin" "agent.bin" "asm_" "ASM" "tfa" "tfa.TFAMain" "OSWatcher")
		users+=("$grid_user")
		groups+=("asmdba" "asmoper" "asmadmin")
	fi
	for user in "${users[@]}"; do
		if getent passwd "$user" >/dev/null 2>&1; then
			echo "pkill -KILL -u $user"
			echo "pkill -u $user -9 -f"
			echo "userdel -rf $user"
			if [[ "$os_type" == "kylin" ]]; then
				if grep -q "^$user:" /etc/uid_list; then
					echo "sed -i \"/^$user:/d\" /etc/uid_list"
				fi
			fi
		fi
	done
	for group in "${groups[@]}"; do
		if getent group "$group" >/dev/null 2>&1; then
			echo "groupdel $group"
		fi
	done
	for dir in "${dirs_to_clean[@]}"; do
		if [[ "$dir" ]]; then
			echo "/bin/rm -rf $dir"
		fi
	done
	for path in "${files_to_clean[@]}"; do
		echo "find $path -maxdepth 1 \( -name \"Ora*\" -o -name \"ora*\" -o -name \"CVU*\" -o -name \"osw*\" -o -name \"hsperfdata*\" \) ! -name \"oracle-release\" -exec /bin/rm -rf {} +"
	done
	for process in "${oracle_processes[@]}"; do
		if pgrep -f "$process" >/dev/null 2>&1; then
			echo "pkill -9 -f $process"
		fi
	done
	echo "shutdown -r now"
}
