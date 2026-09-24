#!/usr/bin/env bash
#===============================================================
# lib/grid.sh —— Grid Infrastructure 安装（仅单机 ASM / RAC 模式使用）
# 包含：解压、渲染响应文件、静默安装、root 脚本、创建 ASM 磁盘组
# 依赖：lib/common.sh、lib/state.sh
#===============================================================

#==============================================================#
#                        解压 Grid 软件包                        #
#==============================================================#
function unzip_gridsoft() {
	log_print "静默解压缩 Grid 软件包"
	chown -R "$grid_user":oinstall "$software_dir"
	color_printf blue "正在静默解压缩 Grid 软件包，请稍等："
	if ((gi_version == 11)); then
		if ! check_file "$software_dir"/grid; then
			cascade_del_file "$software_dir/grid"
		fi
		color_printf green "静默解压 Grid 软件安装包： $grid_soft_name"
		run_as_grid "unzip -oq \"$grid_soft_name\" -d \"$software_dir\""
	else
		echo
		color_printf green "静默解压 Grid 软件安装包： $grid_soft_name"
		run_as_grid "unzip -oq \"$grid_soft_name\" -d \"$env_grid_home\""
	fi
	# Kylin 10 安装 11GR2/12CR2 报错 unzip 问题，Grid 内置 unzip 版本太低
	if [[ "$os_type" == "kylin" ]]; then
		if ((gi_version == 11)); then
			/bin/mv -f "$software_dir"/grid/install/unzip "$software_dir"/grid/install/unzipbak
			/bin/cp -f /usr/bin/unzip "$software_dir"/grid/install/unzip
		elif ((gi_version == 12)); then
			/bin/mv -f "$env_grid_home"/bin/unzip "$env_grid_home"/bin/unzipbak
			/bin/cp -f /usr/bin/unzip "$env_grid_home"/bin/unzip
		fi
	fi
	if [[ $grid_patch ]]; then
		if [[ "$gi_version" != "11" ]]; then
			if check_file "$grid_opatch_name"; then
				echo
				color_printf green "静默解压 OPatch 软件补丁包： $grid_opatch_name"
				run_as_grid "unzip -oq \"$grid_opatch_name\" -d \"$env_grid_home\""
			fi
		fi
		if ! check_file "$software_dir"/"$grid_patch"; then
			echo
			color_printf green "静默解压 Grid 软件补丁包： $grid_patch_name"
			run_as_grid "unzip -oq \"$grid_patch_name\" -d \"$software_dir\""
			if [[ "$gi_version" =~ ^(11|12)$ ]]; then
				for ip in "${rac_public_ips[@]:1}"; do
					scp -q "$grid_patch_name" "$ip":"$software_dir"
					ssh -q "$ip" "chown -R $grid_user:oinstall \"$software_dir\" && su - $grid_user -c \"unzip -oq '$grid_patch_name' -d '$software_dir'\""
				done
			fi
		fi
	fi
	# 安装 cvuqdisk
	if ! type cvuqdisk >/dev/null 2>&1; then
		if check_file "$cvuqdisk"; then
			echo
			color_printf green "静默安装 cvu 软件：$cvu_name"
			echo
			if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
				rpm2cpio "$cvuqdisk" | cpio -idmv >/dev/null 2>&1
				/bin/mv -f "$software_dir"/usr/sbin/cvuqdisk /usr/sbin/
				chown root:oinstall /usr/sbin/cvuqdisk
				chmod 4755 /usr/sbin/cvuqdisk
			else
				rpm -Uvh --quiet "$cvuqdisk" >/dev/null 2>&1
			fi
			for ip in "${rac_public_ips[@]:1}"; do
				scp -q "$cvuqdisk" "$ip":"$software_dir"
				if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
					ssh -q "$ip" "cd $software_dir && rpm2cpio $software_dir/$cvu_name | cpio -idmv" >/dev/null 2>&1
					ssh -q "$ip" "/bin/mv -f $software_dir/usr/sbin/cvuqdisk /usr/sbin/"
					ssh -q "$ip" "chown root:oinstall /usr/sbin/cvuqdisk"
					ssh -q "$ip" "chmod 4755 /usr/sbin/cvuqdisk"
				else
					ssh -q "$ip" "rpm -Uvh --quiet $software_dir/$cvu_name" >/dev/null 2>&1
				fi
				ssh -q "$ip" "/bin/rm -rf $software_dir/$cvu_name"
			done
		fi
	fi
}

#==============================================================#
#                       配置 grid 静默文件                       #
#==============================================================#
function conf_gridrsp() {
	log_print "Grid 安装静默文件"
	if ((gi_version == 26)); then
		local gridrsp_array=(
			"oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v23.0.0"
			"INVENTORY_LOCATION=$env_oracle_inven"
			"ORACLE_BASE=$env_grid_base"
			"OSDBA=asmdba"
			"OSOPER=asmoper"
			"OSASM=asmadmin"
			"storageOption=FLEX_ASM_STORAGE"
			"sysasmPassword=$database_passwd"
			"auSize=$ausize"
			"diskString=$asmdisk_string"
			"asmsnmpPassword=$database_passwd"
			"configureGNS=false"
			"configureAsExtendedCluster=false"
			"useIPMI=false"
			"ignoreDownNodes=false"
			"managementOption=NONE"
			"executeRootScript=false"
		)
		case "$oracle_install_mode" in
		rac)
			gridrsp_array+=(
				"installOption=CRS_CONFIG"
				"scanType=LOCAL_SCAN"
				"scanName=$scan_name"
				"scanPort=1521"
				"clusterName=$cluster_name"
				"clusterNodes=$clusternodes"
				"networkInterfaceList=$networkinterfacelist"
				"diskGroupName=$ocr_asm_group"
				"redundancy=$ocr_redun"
				"diskList=$ocrdisk"
			)
			;;
		standalone)
			gridrsp_array+=(
				"installOption=HA_CONFIG"
				"diskGroupName=$data_asm_group"
				"redundancy=$data_redun"
				"diskList=$datadisk"
			)
			;;
		esac
	else
		case "$oracle_install_mode" in
		rac)
			local gridrsp_array=(
				"INVENTORY_LOCATION=$env_oracle_inven"
				"oracle.install.option=CRS_CONFIG"
				"ORACLE_BASE=$env_grid_base"
				"oracle.install.asm.OSDBA=asmdba"
				"oracle.install.asm.OSOPER=asmoper"
				"oracle.install.asm.OSASM=asmadmin"
				"oracle.install.crs.config.gpnp.scanName=$scan_name"
				"oracle.install.crs.config.gpnp.scanPort=1521"
				"oracle.install.crs.config.clusterName=$cluster_name"
				"oracle.install.crs.config.gpnp.configureGNS=false"
				"oracle.install.crs.config.clusterNodes=$clusternodes"
				"oracle.install.crs.config.networkInterfaceList=$networkinterfacelist"
				"oracle.install.crs.config.useIPMI=false"
				"oracle.install.asm.SYSASMPassword=$database_passwd"
				"oracle.install.asm.diskGroup.name=$ocr_asm_group"
				"oracle.install.asm.diskGroup.redundancy=$ocr_redun"
				"oracle.install.asm.diskGroup.disks=$ocrdisk"
				"oracle.install.asm.diskGroup.diskDiscoveryString=$asmdisk_string"
				"oracle.install.asm.monitorPassword=$database_passwd"
			)
			;;
		standalone)
			gridrsp_array=(
				"INVENTORY_LOCATION=$env_oracle_inven"
				"oracle.install.option=HA_CONFIG"
				"ORACLE_BASE=$env_grid_base"
				"oracle.install.asm.OSDBA=asmdba"
				"oracle.install.asm.OSOPER=asmoper"
				"oracle.install.asm.OSASM=asmadmin"
				"oracle.install.crs.config.gpnp.configureGNS=false"
				"oracle.install.crs.config.useIPMI=false"
				"oracle.install.asm.SYSASMPassword=$database_passwd"
				"oracle.install.asm.diskGroup.name=$data_asm_group"
				"oracle.install.asm.diskGroup.redundancy=$data_redun"
				"oracle.install.asm.diskGroup.disks=$datadisk"
				"oracle.install.asm.diskGroup.diskDiscoveryString=$asmdisk_string"
				"oracle.install.asm.monitorPassword=$database_passwd"
			)
			;;
		esac
		case "$gi_version" in
		"11")
			gridrsp_array+=(
				"oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v11_2_0"
				"SELECTED_LANGUAGES=en"
				"ORACLE_HOME=$env_grid_home"
				"oracle.install.crs.config.storageOption=ASM_STORAGE"
				"oracle.install.asm.diskGroup.AUSize=$ausize"
				"oracle.installer.autoupdates.option=SKIP_UPDATES"
			)
			;;
		"12" | "19" | "21")
			gridrsp_array+=(
				"oracle.install.crs.config.ClusterConfiguration=STANDALONE"
				"oracle.install.crs.config.configureAsExtendedCluster=false"
				"oracle.install.asm.storageOption=ASM"
				"oracle.install.asm.diskGroup.AUSize=$ausize"
				"oracle.install.asm.configureAFD=$afd"
				"oracle.install.crs.config.ignoreDownNodes=false"
				"oracle.install.config.managementOption=NONE"
				"oracle.install.crs.rootconfig.executeRootScript=false"
			)
			case "$gi_version" in
			"12")
				gridrsp_array+=("oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v12.2.0")
				if [[ $oracle_install_mode == "rac" ]]; then
					if [[ $gimr == "false" ]]; then
						gridrsp_array+=("oracle.install.crs.configureGIMR=false")
					fi
				fi
				;;
			"19")
				gridrsp_array+=(
					"oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v19.0.0"
					"oracle.install.crs.config.scanType=LOCAL_SCAN"
					"oracle.install.crs.configureGIMR=false"
				)
				;;
			"21")
				gridrsp_array+=(
					"oracle.install.responseFileVersion=/oracle/install/rspfmt_crsinstall_response_schema_v21.0.0"
					"oracle.install.crs.config.scanType=LOCAL_SCAN"
					"oracle.install.crs.configureGIMR=false"
				)
				;;
			esac
			;;
		esac
	fi
	rm_file "$software_dir/grid.rsp"
	printf '%s\n' "${gridrsp_array[@]}" >>"$software_dir"/grid.rsp
	cat "$software_dir"/grid.rsp
}

#==============================================================#
#                      获取安装 grid 命令                        #
#==============================================================#
function get_gridinstall_cmd() {
	log_print "静默安装 Grid 软件命令"
	case "$gi_version" in
	"11")
		gridinstall_cmd=$(echo -e "$software_dir/grid/runInstaller \\
-silent \\
-showProgress \\
-ignoreSysPrereqs \\
-ignorePrereq \\
-waitForCompletion \\
-responseFile $software_dir/grid.rsp")
		;;
	"12" | "19" | "21" | "26")
		if ((gi_version == 12)); then
			# [INS-42505] (Doc ID 2697235.1)
			if ! check_file "$env_grid_home"/install/files.lst.original; then
				/bin/mv -f "$env_grid_home"/install/files.lst "$env_grid_home"/install/files.lst.original
			fi
		fi
		if [[ -z "$grid_patch" ]]; then
			gridinstall_cmd=$(echo -e "$env_grid_home/gridSetup.sh \\
-silent \\
-skipPrereqs \\
-ignorePrereqFailure \\
-waitForCompletion \\
-responseFile $software_dir/grid.rsp")
		else
			case "$gi_version" in
			"12")
				local patch_str="-applyPSU $software_dir/$grid_patch"
				;;
			"19" | "21" | "26")
				patch_str="-applyRU $software_dir/$grid_patch"
				;;
			esac
			gridinstall_cmd=$(echo -e "$env_grid_home/gridSetup.sh \\
-silent \\
-skipPrereqs \\
-ignorePrereqFailure \\
-waitForCompletion \\
-responseFile $software_dir/grid.rsp \\
$patch_str")
		fi
		;;
	esac
	color_printf blue "$gridinstall_cmd"
}

#==============================================================#
#                      执行 root.sh 脚本                        #
#==============================================================#
function exec_root() {
	local root_path=$1
	log_print "执行 root 脚本"
	if [[ "$oracle_install_mode" == "rac" ]]; then
		color_printf blue "节点 $local_ip ："
	fi
	if check_file "$env_oracle_inven"/orainstRoot.sh; then
		color_printf blue "执行命令：$env_oracle_inven/orainstRoot.sh"
		"$env_oracle_inven"/orainstRoot.sh
	fi
	if check_file "$root_path"/root.sh; then
		echo
		color_printf blue "执行命令：$root_path/root.sh"
		"$root_path"/root.sh
	fi
	if [[ "$oracle_install_mode" == "rac" ]]; then
		for ip in "${rac_public_ips[@]:1}"; do
			echo
			color_printf blue "节点 $ip ："
			color_printf blue "执行命令：$env_oracle_inven/orainstRoot.sh"
			ssh -q "$ip" "$env_oracle_inven"/orainstRoot.sh
			echo
			color_printf blue "执行命令：$root_path/root.sh"
			ssh -q "$ip" "$root_path"/root.sh
		done
	fi
}

#==============================================================#
#                      安装 Grid 软件后操作                      #
#==============================================================#
function after_grid_install() {
	case "$gi_version" in
	"11")
		# Grid patch 18370031，修复执行 root.sh 脚本报错 ohas 服务问题
		if ((os_version >= 7)); then
			log_print "静默安装 18370031 补丁"
			if [[ "$oracle_install_mode" == "rac" ]]; then
				color_printf blue "节点 $local_ip ："
			fi
			run_as_grid "unzip -oq $software_dir/p18370031_112040_Linux-x86-64.zip -d $software_dir"
			run_as_grid "$env_grid_home/OPatch/opatch napply -oh $env_grid_home -local $software_dir/18370031 -silent"
			for ip in "${rac_public_ips[@]:1}"; do
				echo
				color_printf blue "节点 $ip ："
				scp -q -r "$software_dir"/p18370031_112040_Linux-x86-64.zip "$ip":"$software_dir"
				ssh -q "$ip" "chown -R $grid_user:oinstall $software_dir"
				run_as_grid "ssh -q $ip unzip -oq $software_dir/p18370031_112040_Linux-x86-64.zip -d $software_dir"
				run_as_grid "ssh -q $ip $env_grid_home/OPatch/opatch napply -oh $env_grid_home -local $software_dir/18370031 -silent"
			done
		fi
		exec_root "$env_grid_home"
		# 执行 configToolAllCommands 完成 Grid 基础配置
		if ! check_file "$env_grid_home"/cfgtoollogs/configToolAllCommands; then
			run_as_grid "$env_grid_home/oui/bin/runConfig.sh ORACLE_HOME=$env_grid_home MODE=perform ACTION=configure RERUN=true $*" >/dev/null 2>&1
		fi
		write_file "N" "/home/$grid_user/cfgrsp.properties" "oracle.assistants.asm|S_ASMPASSWORD=$database_passwd
oracle.assistants.asm|S_ASMMONITORPASSWORD=$database_passwd"
		run_as_grid "$env_grid_home/cfgtoollogs/configToolAllCommands RESPONSE_FILE=/home/$grid_user/cfgrsp.properties" >/dev/null 2>&1
		rm_file /home/$grid_user/cfgrsp.properties
		if [[ $grid_patch ]]; then
			log_print "Grid 软件安装补丁"
			if [[ "$oracle_install_mode" == "rac" ]]; then
				color_printf blue "节点 $local_ip ："
			fi
			run_as_grid "unzip -oq $grid_opatch_name -d $env_grid_home"
			color_printf blue "检查 Grid 软件 OPacth 版本："
			check_opatch_version "$env_grid_home"
			echo
			color_printf blue "正在安装 Grid 软件补丁："
			"$env_grid_home"/OPatch/opatch auto "$software_dir"/"$grid_patch" -oh "$env_grid_home"
			for ip in "${rac_public_ips[@]:1}"; do
				echo
				color_printf blue "节点 $ip ："
				run_as_grid "ssh -q $ip unzip -oq $grid_opatch_name -d $env_grid_home"
				ssh -q "$ip" "$env_grid_home"/OPatch/opatch auto "$software_dir"/"$grid_patch" -oh "$env_grid_home"
			done
		fi
		;;
	"12" | "19" | "21" | "26")
		if ((gi_version == 12)); then
			if check_file "$env_grid_home"/install/files.lst.original; then
				/bin/mv -f "$env_grid_home"/install/files.lst.original "$env_grid_home"/install/files.lst
			fi
			if [[ "$oracle_install_mode" == "rac" ]]; then
				for ip in "${rac_public_ips[@]:1}"; do
					ssh -q "$ip" /bin/mv -f "$env_grid_home"/install/files.lst.original "$env_grid_home"/install/files.lst
				done
			fi
			make -s -f "$env_grid_home"/rdbms/lib/ins_rdbms.mk client_sharedlib libasmclntsh12.ohso libasmperl12.ohso ORACLE_HOME="$env_grid_home" >/dev/null 2>&1
			for ip in "${rac_public_ips[@]:1}"; do
				ssh -q "$ip" "make -s -f $env_grid_home/rdbms/lib/ins_rdbms.mk client_sharedlib libasmclntsh12.ohso libasmperl12.ohso ORACLE_HOME=$env_grid_home" >/dev/null 2>&1
			done
		fi
		exec_root "$env_grid_home"
		run_as_grid "$env_grid_home/gridSetup.sh -executeConfigTools -responseFile $software_dir/grid.rsp -silent" >/dev/null 2>&1
		;;
	esac
	if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
		if check_file "$env_grid_home"/crs/init/ohasd.sles; then
			/bin/cp -f "$env_grid_home"/crs/init/ohasd.sles /etc/init.d/ohasd
			systemctl enable ohasd.service
			ssh -q "$ip" "/bin/cp -f $env_grid_home/crs/init/ohasd.sles /etc/init.d/ohasd"
			ssh -q "$ip" "systemctl enable ohasd.service"
		fi
	fi
}

#==============================================================#
#                         安装 Grid 软件                        #
#==============================================================#
function install_gridsoft() {
	conf_gridrsp
	get_gridinstall_cmd
	chown -R "$grid_user":oinstall "$software_dir"
	log_print "静默安装 Grid 软件"
	if [[ "$db_version" != "11" ]]; then
		color_printf blue "检查 Grid 软件 OPacth 版本："
		check_opatch_version "$env_grid_home"
		echo
	fi
	color_printf blue "正在安装 Grid 软件："
	run_as_grid "$gridinstall_cmd"
	after_grid_install "$@"
	log_print "Grid 软件版本"
	color_printf blue "查看 Grid 软件版本：sqlplus -V"
	run_as_grid "sqlplus -V"
	log_print "Grid 补丁信息"
	color_printf blue "查看 Grid 补丁信息：opatch lspatches"
	run_as_grid "opatch lspatches"
	log_print "Grid 资源检查"
	color_printf blue "查看 Grid 集群情况：crsctl stat res -t"
	run_as_grid "crsctl stat res -t"
}

#==============================================================#
#                       创建 ASM 磁盘组                         #
#==============================================================#
function get_asmca_cmd() {
	log_print "静默创建 ASM 磁盘组命令"
	data_asmca_cmd=$(echo -e "$env_grid_home/bin/asmca -silent \\
-createDiskGroup \\
-diskGroupName $data_asm_group \\
-diskList $datadisk \\
-redundancy $data_redun \\
-au_size $ausize \\
-compatible.asm $gi_compatible \\
-compatible.rdbms $db_compatible")
	color_printf blue "$data_asmca_cmd"
	if [[ -n "$arch_base_disk" ]]; then
		arch_asmca_cmd=$(echo -e "$env_grid_home/bin/asmca -silent \\
-createDiskGroup \\
-diskGroupName $arch_asm_group \\
-diskList $archdisk \\
-au_size $ausize \\
-redundancy $arch_redun \\
-compatible.asm $gi_compatible \\
-compatible.rdbms $db_compatible")
		color_printf blue "$arch_asmca_cmd"
	fi
}
function create_asmgroup() {
	get_asmca_cmd
	log_print "ASM 磁盘组创建"
	color_printf blue "正在创建 ASM 磁盘组："
	run_as_grid "$data_asmca_cmd"
	if [[ -n "$arch_asmca_cmd" ]]; then
		run_as_grid "$arch_asmca_cmd"
	fi
	color_printf blue "查看 ASM 磁盘组：asmcmd lsdg"
	run_as_grid "asmcmd lsdg"
}
