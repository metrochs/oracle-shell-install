#!/usr/bin/env bash
#===============================================================
# lib/dbsoft.sh —— Oracle 数据库软件安装（解压 / 响应文件 / runInstaller / 补丁 / 监听）
# 依赖：lib/common.sh、lib/state.sh
#===============================================================

#==============================================================#
#                        解压 Oracle 软件                       #
#==============================================================#
function unzip_dbsoft() {
	log_print "静默解压 Oracle 软件包"
	chown -R "$oracle_user":oinstall "$software_dir"
	color_printf blue "正在静默解压缩 Oracle 软件包，请稍等："
	case "$db_version" in
	"11" | "12")
		if check_file "$software_dir"/database; then
			cascade_del_file "$software_dir/database"
		fi
		if [[ "$db_soft_name1" ]]; then
			color_printf green "静默解压 Oracle 软件安装包： $db_soft_name,$db_soft_name1"
			run_as_oracle "unzip -oq $db_soft_name -d $software_dir && unzip -oq $db_soft_name1 -d $software_dir"
		else
			color_printf green "静默解压 Oracle 软件安装包： $db_soft_name"
			run_as_oracle "unzip -oq $db_soft_name -d $software_dir"
		fi
		# Kylin 10 安装 11GR2/12CR2 报错 unzip 问题，Oracle 内置 unzip 版本太低
		if [[ "$os_type" == "kylin" ]]; then
			/bin/mv -f "$software_dir"/database/install/unzip "$software_dir"/database/install/unzipbak
			/bin/cp -f /usr/bin/unzip "$software_dir"/database/install/unzip
		fi
		;;
	*)
		echo
		color_printf green "静默解压 Oracle 软件安装包： $db_soft_name"
		run_as_oracle "unzip -oq $db_soft_name -d $env_oracle_home"
		;;
	esac
	# 判断补丁
	if [[ $oracle_patch ]]; then
		patch_number=$oracle_patch
		local patch_name=$db_patch_name
	else
		if [[ $grid_patch ]]; then
			patch_number=$grid_patch
			patch_name=$grid_patch_name
		fi
	fi
	if [[ $patch_number ]]; then
		if ! [[ "$db_version" =~ ^(11|12)$ ]]; then
			if check_file "$db_opatch_name"; then
				echo
				color_printf green "静默解压 OPatch 软件补丁包： $db_opatch_name"
				run_as_oracle "unzip -oq $db_opatch_name -d $env_oracle_home"
			fi
		fi
		if ! check_file "$software_dir"/"$patch_number"; then
			echo
			color_printf green "静默解压 Oracle 软件补丁包：$patch_name"
			run_as_oracle "unzip -oq $patch_name -d $software_dir"
		fi
		if [[ "$oracle_install_mode" == "rac" ]]; then
			if [[ "$db_version" =~ ^(11|12)$ ]]; then
				for ip in "${rac_public_ips[@]:1}"; do
					scp -q "$patch_name" "$ip":"$software_dir"
					ssh -q "$ip" "chown -R $oracle_user:oinstall $software_dir"
					run_as_oracle "ssh -q $ip unzip -oq $patch_name -d $software_dir"
				done
			fi
		fi
	fi
	if [[ $ojvm_patch ]]; then
		if ! check_file "$software_dir"/"$ojvm_patch"; then
			echo
			color_printf green "静默解压 OJVM 软件补丁包： $ojvm_patch_name"
			if ! [[ "$db_version" =~ ^(11|12)$ ]]; then
				run_as_oracle "unzip -oq $db_opatch_name -d $env_oracle_home"
			fi
			run_as_oracle "unzip -oq $ojvm_patch_name -d $software_dir"
		fi
		if [[ "$oracle_install_mode" == "rac" ]]; then
			for ip in "${rac_public_ips[@]:1}"; do
				scp -q "$ojvm_patch_name" "$ip":"$software_dir"
				ssh -q "$ip" "chown -R $oracle_user:oinstall $software_dir"
				run_as_oracle "ssh -q $ip unzip -oq $ojvm_patch_name -d $software_dir"
			done
		fi
	fi
}

#==============================================================#
#                    创建 Oracle 静默安装文件                     #
#==============================================================#
function conf_oraclersp() {
	log_print "Oracle 安装静默文件"
	if ((db_version == 26)); then
		local oracle_rsp_arr=(
			"oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v23.0.0"
			"installOption=INSTALL_DB_SWONLY"
			"UNIX_GROUP_NAME=oinstall"
			"INVENTORY_LOCATION=$env_oracle_inven"
			"ORACLE_BASE=$env_oracle_base"
			"ORACLE_HOME=$env_oracle_home"
			"installEdition=EE"
			"OSDBA=dba"
			"OSOPER=oper"
			"OSBACKUPDBA=backupdba"
			"OSDGDBA=dgdba"
			"OSKMDBA=kmdba"
			"OSRACDBA=racdba"
			"executeRootScript=false"
		)
		if [[ "$oracle_install_mode" == "rac" ]]; then
			oracle_rsp_arr+=("clusterNodes=$rac_hostname")
		fi
	else
		declare -a oracle_rsp_arr=(
			"oracle.install.option=INSTALL_DB_SWONLY"
			"UNIX_GROUP_NAME=oinstall"
			"INVENTORY_LOCATION=$env_oracle_inven"
			"ORACLE_BASE=$env_oracle_base"
			"oracle.install.db.InstallEdition=EE"
		)
		if [[ "$oracle_install_mode" == "rac" ]]; then
			oracle_rsp_arr+=("oracle.install.db.CLUSTER_NODES=$rac_hostname")
		fi
		case "$db_version" in
		"11")
			oracle_rsp_arr+=(
				"oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v11_2_0"
				"SELECTED_LANGUAGES=en,zh_CN"
				"ORACLE_HOME=$env_oracle_home"
				"oracle.install.db.DBA_GROUP=dba"
				"oracle.install.db.OPER_GROUP=oper"
				"DECLINE_SECURITY_UPDATES=true"
				"oracle.installer.autoupdates.option=SKIP_UPDATES"
			)
			;;
		"12")
			oracle_rsp_arr+=(
				"oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v12.2.0"
				"SELECTED_LANGUAGES=en,zh_CN"
				"ORACLE_HOME=$env_oracle_home"
				"oracle.install.db.OSDBA_GROUP=dba"
				"oracle.install.db.OSOPER_GROUP=oper"
				"oracle.install.db.OSBACKUPDBA_GROUP=backupdba"
				"oracle.install.db.OSDGDBA_GROUP=dgdba"
				"oracle.install.db.OSKMDBA_GROUP=kmdba"
				"oracle.install.db.OSRACDBA_GROUP=racdba"
			)
			;;
		"19" | "21")
			oracle_rsp_arr+=(
				"oracle.install.db.OSDBA_GROUP=dba"
				"oracle.install.db.OSOPER_GROUP=oper"
				"oracle.install.db.OSBACKUPDBA_GROUP=backupdba"
				"oracle.install.db.OSDGDBA_GROUP=dgdba"
				"oracle.install.db.OSKMDBA_GROUP=kmdba"
				"oracle.install.db.OSRACDBA_GROUP=racdba"
				"oracle.install.db.rootconfig.executeRootScript=false"
			)
			case "$db_version" in
			"19") oracle_rsp_arr+=("oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v19.0.0") ;;
			"21") oracle_rsp_arr+=("oracle.install.responseFileVersion=/oracle/install/rspfmt_dbinstall_response_schema_v21.0.0") ;;
			esac
			;;
		esac
	fi
	rm_file "$software_dir/oracle.rsp"
	printf '%s\n' "${oracle_rsp_arr[@]}" >"$software_dir/oracle.rsp"
	cat "$software_dir/oracle.rsp"
}

#==============================================================#
#                      获取安装 Oracle 命令                      #
#==============================================================#
function get_oracleinstall_cmd() {
	log_print "静默安装 Oracle 软件命令"
	if [[ $oracle_patch ]]; then
		patch_number=$oracle_patch
	else
		if [[ $grid_patch ]]; then
			patch_number=$grid_patch
		fi
	fi
	case "$db_version" in
	"11" | "12")
		oracleinstall_cmd=$(echo -e "$software_dir/database/runInstaller \\
-silent \\
-responseFile $software_dir/oracle.rsp \\
-showProgress \\
-ignoreSysPrereqs \\
-ignorePrereq \\
-waitForCompletion")
		;;
	"19" | "21" | "26")
		if [[ $patch_number ]]; then
			oracleinstall_cmd=$(echo -e "$env_oracle_home/runInstaller \\
-silent \\
-ignorePrereqFailure \\
-responseFile $software_dir/oracle.rsp \\
-waitForCompletion \\
-applyRU $software_dir/$patch_number")
		else
			oracleinstall_cmd=$(echo -e "$env_oracle_home/runInstaller \\
-silent \\
-ignorePrereqFailure \\
-responseFile $software_dir/oracle.rsp \\
-waitForCompletion")
		fi
		;;
	esac
	color_printf blue "$oracleinstall_cmd"
}

#==============================================================#
#                        安装 OJVM 补丁                         #
#==============================================================#
function install_ojvm_patch() {
	log_print "OJVM 补丁安装"
	color_printf blue "检查 OJVM 软件 OPacth 版本："
	check_opatch_version "$env_oracle_home"
	echo
	case "$db_version" in
	"11" | "12")
		run_as_oracle "unzip -oq $db_opatch_name -d $env_oracle_home"
		for ip in "${rac_public_ips[@]:1}"; do
			ssh -q "$ip" "chown -R $oracle_user:oinstall $software_dir"
			run_as_oracle "ssh -q $ip unzip -oq $db_opatch_name -d $env_oracle_home"
		done
		;;
	esac
	if [[ "$oracle_install_mode" == "rac" ]]; then
		color_printf blue "节点 $local_ip ："
	fi
	su - "$oracle_user" <<-EOF
		cd $software_dir/$ojvm_patch
		$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
		$env_oracle_home/OPatch/opatch apply -silent
	EOF
	if [[ "$oracle_install_mode" == "rac" ]]; then
		for ip in "${rac_public_ips[@]:1}"; do
			echo
			color_printf blue "节点 $ip ："
			ssh -q "$ip" "su - $oracle_user <<-EOF
cd $software_dir/$ojvm_patch
$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
$env_oracle_home/OPatch/opatch apply -silent
EOF"
		done
	fi
}

#==============================================================#
#                     安装 Oracle 软件后操作                     #
#==============================================================#
function after_oracle_install() {
	case "$db_version" in
	"11" | "12")
		if ((db_version == 11 && gi_version > 11)); then
			# [INS-35354] GI/DB 版本不一致时更新 nodeList
			run_as_grid "$env_grid_home/oui/bin/runInstaller -updateNodeList ORACLE_HOME=$env_grid_home CRS=true" >/dev/null 2>&1
			for ip in "${rac_public_ips[@]:1}"; do
				run_as_grid "ssh -q $ip $env_grid_home/oui/bin/runInstaller -updateNodeList ORACLE_HOME=$env_grid_home CRS=true" >/dev/null 2>&1
			done
		fi
		if [[ "$os_type" == "kylin" ]]; then
			/bin/mv -f "$env_oracle_home"/bin/unzip "$env_oracle_home"/bin/unzipbak
			/bin/cp -f /usr/bin/unzip "$env_oracle_home"/bin/unzip
		fi
		exec_root "$env_oracle_home"
		if [[ $patch_number ]]; then
			log_print "Oracle 软件安装补丁"
			run_as_oracle "unzip -oq $db_opatch_name -d $env_oracle_home"
			color_printf blue "检查 Oracle 软件 OPacth 版本："
			check_opatch_version "$env_oracle_home"
			echo
			color_printf blue "正在安装 Oracle 软件补丁："
			if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
				for ip in "${rac_public_ips[@]:1}"; do
					ssh -q "$ip" "chown -R $oracle_user:oinstall $software_dir"
					run_as_oracle "ssh -q $ip unzip -oq $db_opatch_name -d $env_oracle_home"
				done
				if ((db_version == 11)); then
					if [[ "$oracle_install_mode" == "rac" ]]; then
						color_printf blue "节点 $local_ip ："
					fi
					if [[ $oracle_patch ]]; then
						su - "$oracle_user" <<-EOF
							cd $software_dir/$patch_number
							$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
							$env_oracle_home/OPatch/opatch apply -silent
						EOF
					else
						"$env_oracle_home"/OPatch/opatch auto "$software_dir"/"$patch_number" -oh "$env_oracle_home"
					fi
					for ip in "${rac_public_ips[@]:1}"; do
						echo
						color_printf blue "节点 $ip ："
						if [[ $oracle_patch ]]; then
							ssh -q "$ip" "su - $oracle_user <<-EOF
cd $software_dir/$patch_number
$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
$env_oracle_home/OPatch/opatch apply -silent
EOF"
						else
							ssh -q "$ip" "$env_oracle_home"/OPatch/opatch auto "$software_dir"/"$patch_number" -oh "$env_oracle_home"
						fi
					done
				elif ((db_version == 12)); then
					if [[ "$oracle_install_mode" == "rac" ]]; then
						color_printf blue "节点 $local_ip ："
					fi
					if [[ $oracle_patch ]]; then
						su - "$oracle_user" <<-EOF
							cd $software_dir/$patch_number
							$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
							$env_oracle_home/OPatch/opatch apply -silent
						EOF
					else
						"$env_oracle_home"/OPatch/opatchauto apply "$software_dir"/"$patch_number" -oh "$env_oracle_home"
					fi
					for ip in "${rac_public_ips[@]:1}"; do
						echo
						color_printf blue "节点 $ip ："
						if [[ $oracle_patch ]]; then
							ssh -q "$ip" "su - $oracle_user <<-EOF
cd $software_dir/$patch_number
$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
$env_oracle_home/OPatch/opatch apply -silent
EOF"
						else
							ssh -q "$ip" "cd $software_dir/$patch_number;$env_oracle_home/OPatch/opatchauto apply $software_dir/$patch_number -oh $env_oracle_home"
						fi
					done
				fi
			else
				su - "$oracle_user" <<-EOF
					cd $software_dir/$patch_number
					$env_oracle_home/OPatch/opatch prereq CheckConflictAgainstOHWithDetail -ph ./
					$env_oracle_home/OPatch/opatch apply -silent
				EOF
			fi
		fi
		# Linux6 安装 12c 需要设置 irman、ioracle
		if ((db_version == 12 && os_version == 6)); then
			run_as_oracle "make -s -f $env_oracle_home/rdbms/lib/ins_rdbms.mk irman" >/dev/null 2>&1
			run_as_oracle "make -s -f $env_oracle_home/rdbms/lib/ins_rdbms.mk ioracle" >/dev/null 2>&1
			if [[ "$oracle_install_mode" == "rac" ]]; then
				for ip in "${rac_public_ips[@]:1}"; do
					run_as_oracle "ssh -q $ip make -s -f $env_oracle_home/rdbms/lib/ins_rdbms.mk irman" >/dev/null 2>&1
					run_as_oracle "ssh -q $ip make -s -f $env_oracle_home/rdbms/lib/ins_rdbms.mk ioracle" >/dev/null 2>&1
				done
			fi
		fi
		# 安装 11GR2 需要修改 -lnnz11
		if ((db_version == 11)); then
			if ((os_version >= 7)); then
				sed -i "s/^\(\s*\$(MK_EMAGENT_NMECTL)\)\s*$/\1 -lnnz11/g" "$env_oracle_home"/sysman/lib/ins_emagent.mk
				if [[ "$oracle_install_mode" == "rac" ]]; then
					for ip in "${rac_public_ips[@]:1}"; do
						ssh -q "$ip" "sed -i 's/^\(\s*\$(MK_EMAGENT_NMECTL)\)\s*$/\1 -lnnz11/g' $env_oracle_home/sysman/lib/ins_emagent.mk"
					done
				fi
				if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
					undo_adapt
				fi
			fi
			if ((os_version >= 8)); then
				run_as_oracle "make -s -f $env_oracle_home/sysman/lib/ins_emagent.mk emdctl" >/dev/null 2>&1
				if [[ "$oracle_install_mode" == "rac" ]]; then
					for ip in "${rac_public_ips[@]:1}"; do
						run_as_oracle "ssh -q $ip make -s -f $env_oracle_home/sysman/lib/ins_emagent.mk emdctl" >/dev/null 2>&1
					done
				fi
				undo_adapt
			fi
		fi
		;;
	"19" | "21" | "26")
		exec_root "$env_oracle_home"
		;;
	esac
	if [[ $ojvm_patch ]]; then
		install_ojvm_patch
	fi
}

#==============================================================#
#                         安装 Oracle 软件                       #
#==============================================================#
function install_dbsoft() {
	conf_oraclersp
	get_oracleinstall_cmd
	chown -R "$oracle_user":oinstall "$software_dir"
	log_print "静默安装数据库软件"
	if ! [[ "$db_version" =~ ^(11|12)$ ]]; then
		color_printf blue "检查 Oracle 软件 OPacth 版本："
		check_opatch_version "$env_oracle_home"
		echo
	fi
	color_printf blue "正在安装 Oracle 软件："
	run_as_oracle "$oracleinstall_cmd"
	after_oracle_install
	log_print "Oracle 软件版本"
	run_as_oracle "sqlplus -V"
	log_print "Oracle 补丁信息"
	run_as_oracle "opatch lspatches"
}

#==============================================================#
#                           配置监听                            #
#==============================================================#
# 监听健康探测：listener.ora 存在且 lsnrctl status 返回 0
function listener_is_ready() {
	[[ -f "$env_oracle_home"/network/admin/listener.ora ]] || return 1
	run_as_oracle "lsnrctl status LISTENER" >/dev/null 2>&1
}

# netca 失败回退：手工生成静态 listener.ora 并启动
function conf_listener_manual() {
	color_printf yellow "netca 创建监听失败或未生效，启用回退方案：手工生成 listener.ora 并启动监听"
	local lsnr_file="$env_oracle_home/network/admin/listener.ora"
	/bin/mkdir -p "$env_oracle_home/network/admin"
	if check_file "$lsnr_file"; then
		backup_restore_file "$lsnr_file"
	fi
	write_file "Y" "$lsnr_file" "# OracleBegin
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = $HOSTNAME)(PORT = 1521))
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))
    )
  )

ADR_BASE_LISTENER = $env_oracle_base"
	chown "$oracle_user":oinstall "$lsnr_file"
	chmod 644 "$lsnr_file"
	run_as_oracle "lsnrctl stop LISTENER" >/dev/null 2>&1
	run_as_oracle "lsnrctl start LISTENER"
}

function conf_netca() {
	# 单实例模式由脚本创建监听；单机 ASM / RAC 模式监听由 Grid 管理
	if [[ "$oracle_install_mode" == "single" ]] && ! check_file "$env_oracle_home"/network/admin/listener.ora; then
		if check_file "$env_oracle_home"/assistants/netca/netca.rsp; then
			log_print "静默安装 Oracle 软件命令"
			local netca_cmd
			netca_cmd=$(echo -e "$env_oracle_home/bin/netca -silent \\
-responsefile $env_oracle_home/assistants/netca/netca.rsp")
			color_printf blue "$netca_cmd"
			log_print "创建监听"
			color_printf blue "正在创建监听："
			run_as_oracle "$netca_cmd"
		fi
	fi
	echo
	log_print "检查监听状态"
	if ! listener_is_ready; then
		conf_listener_manual
	fi
	run_as_oracle "lsnrctl stat"
}
