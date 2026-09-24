#!/usr/bin/env bash
#===============================================================================
# 阶段三：数据库创建                                      预计耗时 20~40 分钟
#-------------------------------------------------------------------------------
# 覆盖范围：
#   DBCA 静默创建 CDB + PDB（Oracle 21c/26ai 强制 CDB 模式，26ai 只允许 CDB）
#   建库后配置 sqlnet.ora（低版本客户端兼容性）
#
# 用法：
#   sh 3_db_create.sh                       # 复用阶段一/二状态，正常用法
#   sh 3_db_create.sh -lf eth0 -o orcl ...  # 跳过前序阶段直接带全参执行（不推荐）
#===============================================================================
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
set -o pipefail # 管道中任一命令失败都要让整体退出码非 0
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/os_adapt.sh"
source "$SCRIPT_DIR/lib/args.sh"

#==============================================================#
#                        配置建库响应文件                         #
#==============================================================#
function get_dbca_rsp() {
	local dbname=$1 nums=$2 redo_size templatename db_block_size_11g
	# 计算数据库内存总和(MB) = 物理内存的 80%
	((db_memory_total = os_memory_total * 4 / 5 / 1024 / nums))
	if ((db_block_size == 8192)); then
		templatename=General_Purpose.dbc
	else
		templatename=New_Database.dbt
	fi
	log_print "DBCA 静默建库文件：$dbname"
	if ((db_version == 11)); then
		db_block_size_11g=$((db_block_size / 1024))
		declare -a db_rsp_arr=(
			"[GENERAL]"
			"RESPONSEFILE_VERSION=11.2.0"
			"OPERATION_TYPE=createDatabase"
			"[CREATEDATABASE]"
			"GDBNAME=$dbname"
			"SID=$dbname"
			"TEMPLATENAME=$templatename"
			"SYSPASSWORD=$database_passwd"
			"SYSTEMPASSWORD=$database_passwd"
			"CHARACTERSET=$db_characterset"
			"NATIONALCHARACTERSET=$nation_characterset"
			"INITPARAMS=db_block_size=$db_block_size_11g"
			"TOTALMEMORY=$db_memory_total"
			"AUTOMATICMEMORYMANAGEMENT=FALSE"
		)
		case "$oracle_install_mode" in
		"rac")
			db_rsp_arr+=(
				"NODELIST=$rac_hostname"
				"STORAGETYPE=ASM"
				"DISKGROUPNAME=$data_asm_group"
				"RECOVERYGROUPNAME=$data_asm_group"
			)
			;;
		"standalone")
			db_rsp_arr+=(
				"STORAGETYPE=ASM"
				"DISKGROUPNAME=$data_asm_group"
				"RECOVERYGROUPNAME=$data_asm_group"
			)
			;;
		*)
			db_rsp_arr+=(
				"DATAFILEDESTINATION=$oradata_dir"
				"RECOVERYAREADESTINATION=$oradata_dir"
				"storageType=FS"
			)
			;;
		esac
		redoline="<fileSize unit=\"KB\">51200</fileSize>"
	else
		declare -a db_rsp_arr=(
			"gdbName=$dbname"
			"sid=$dbname"
			"templateName=$templatename"
			"sysPassword=$database_passwd"
			"systemPassword=$database_passwd"
			"characterSet=$db_characterset"
			"nationalCharacterSet=$nation_characterset"
			"automaticMemoryManagement=false"
			"totalMemory=$db_memory_total"
			"initParams=db_block_size=${db_block_size}BYTES"
			"createAsContainerDatabase=$iscdb"
		)
		case "$oracle_install_mode" in
		"rac")
			db_rsp_arr+=(
				"databaseConfigType=RAC"
				"nodelist=$rac_hostname"
				"storageType=ASM"
				"diskGroupName=$data_asm_group"
				"recoveryGroupName=$data_asm_group"
			)
			;;
		"standalone")
			db_rsp_arr+=(
				"databaseConfigType=SI"
				"storageType=ASM"
				"diskGroupName=$data_asm_group"
				"recoveryGroupName=$data_asm_group"
			)
			;;
		*)
			db_rsp_arr+=(
				"databaseConfigType=SI"
				"storageType=FS"
				"datafileDestination=$oradata_dir"
				"recoveryAreaDestination=$oradata_dir"
			)
			;;
		esac
		case "$db_version" in
		"12") db_rsp_arr+=("responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v12.2.0") ;;
		"19") db_rsp_arr+=("responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v19.0.0") ;;
		"21") db_rsp_arr+=("responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v21.0.0") ;;
		"26") db_rsp_arr+=("responseFileVersion=/oracle/assistants/rspfmt_dbca_response_schema_v23.0.0") ;;
		esac
		redoline="<fileSize unit=\"KB\">204800</fileSize>"
	fi
	# 使用归档日志模式
	if [[ $enable_arch == "true" ]]; then
		sed -i "s|<archiveLogMode>false</archiveLogMode>|<archiveLogMode>true</archiveLogMode>|g" "$env_oracle_home/assistants/dbca/templates/$templatename"
	fi
	# 修改 redo 文件大小
	redo_size=$((redosize * 1024))
	sed -i "s|$redoline|<fileSize unit=\"KB\">${redo_size}</fileSize>|g" "$env_oracle_home/assistants/dbca/templates/$templatename"
	# 处理 12.2 Oracle Restart 问题
	if ((db_version == 12)); then
		check_file "$env_oracle_home/log/$dbname" || /bin/mkdir -p "$env_oracle_home/log/$dbname"
		chown -R "$oracle_user":oinstall "$env_oracle_home/log/$dbname"
	fi
	rm_file "$software_dir/db.rsp"
	printf '%s\n' "${db_rsp_arr[@]}" >"$software_dir/db.rsp"
	cat "$software_dir/db.rsp"
}

#==============================================================#
#                       获取 DB 创建命令                         #
#==============================================================#
function get_dbca_cmd() {
	log_print "静默创建数据库命令"
	if ((db_version == 11)); then
		dbca_cmd="$env_oracle_home/bin/dbca -silent -responseFile $software_dir/db.rsp"
	else
		dbca_cmd="$env_oracle_home/bin/dbca -silent -createDatabase \\
-responseFile $software_dir/db.rsp \\
-ignorePreReqs \\
-ignorePrereqFailure"
		if [[ "$db_version" =~ ^(19|21|26)$ ]]; then
			dbca_cmd="$dbca_cmd \\
-J-Doracle.assistants.dbca.validate.ConfigurationParams=false"
		fi
	fi
	color_printf blue "$dbca_cmd"
}

#==============================================================#
#                           创建数据库                          #
#==============================================================#
function create_db() {
	for name in "${db_names[@]}"; do
		get_dbca_rsp "$name" ${#db_names[@]}
		get_dbca_cmd
		chown -R "$oracle_user":oinstall "$software_dir"
		log_print "创建数据库实例：$name"
		color_printf blue "正在创建数据库：$name"
		run_as_oracle "$dbca_cmd"
		# 配置 Oracle Managed Files（OMF）
		conf_omf "$name"
		# 创建 PDB
		if [[ $iscdb == "true" ]]; then
			create_pdb "$name"
		fi
	done
	if ((db_version >= 12)); then
		conf_sqlnet
	fi
}

#==============================================================#
#                       创建 PDB 数据库                         #
#==============================================================#
function create_pdb() {
	local dbname=$1
	log_print "创建 PDB 数据库"
	for pdbs in ${pdbname//,/ }; do
		color_printf blue "正在创建 PDB：$pdbs"
		execute_sqlplus "$dbname" "" "create pluggable database $pdbs admin user admin identified by $database_passwd default tablespace users;
alter pluggable database all open;
alter pluggable database all save state;
alter session set container=$pdbs;
exec dbms_scheduler.set_scheduler_attribute('default_timezone', 'PRC');
alter profile default limit password_life_time unlimited;"
	done
	execute_sqlplus "$dbname" "" "show pdbs"
}

#==============================================================#
#                         配置 OMF                             #
#==============================================================#
function conf_omf() {
	local omf dbname=$1 arch
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		omf=+$data_asm_group
		if [[ $arch_base_disk ]]; then
			arch=+$arch_asm_group
		else
			arch=$omf
		fi
		su - "$oracle_user" <<-SO
			source /home/$oracle_user/.$dbname
			rman target / <<-EOF
			CONFIGURE SNAPSHOT CONTROLFILE NAME TO '$omf/snapcf_$dbname.f';
			SHOW SNAPSHOT CONTROLFILE NAME;
			EOF
		SO
	else
		omf=$oradata_dir
		arch=$archive_dir
	fi
	execute_sqlplus "$dbname" "" "alter system set db_create_file_dest='$omf';
alter system set log_archive_dest_1='location=$arch';"
}

#==============================================================#
#                       配置 SQLNET.ORA                        #
#==============================================================#
function conf_sqlnet() {
	if check_file "$env_oracle_home/network/admin/sqlnet.ora"; then
		backup_restore_file "$env_oracle_home/network/admin/sqlnet.ora"
	fi
	run_as_oracle "cat <<-EOF >>$env_oracle_home/network/admin/sqlnet.ora
# OracleBegin
SQLNET.ALLOWED_LOGON_VERSION_CLIENT=8
SQLNET.ALLOWED_LOGON_VERSION_SERVER=8
EOF"
	if [[ "$oracle_install_mode" == "rac" ]]; then
		for ip in "${rac_public_ips[@]:1}"; do
			scp -q "$env_oracle_home/network/admin/sqlnet.ora" "$ip:$env_oracle_home/network/admin/"
		done
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
		require_stage 2
		get_os_info
	fi

	# Oracle 21c / 26ai 强制 CDB 架构（26ai 已取消非 CDB 模式）
	if ((db_version >= 21)); then
		if [[ $iscdb != "true" ]]; then
			color_printf yellow "Oracle ${db_version} 强制使用 CDB 架构，已自动将 createAsContainerDatabase 置为 true。"
			iscdb=true
		fi
	fi
	if [[ -z "$pdbname" ]]; then
		pdbname=pdb01
	fi

	if [[ $only_conf_os == "Y" ]]; then
		color_printf green "参数 [ -m Y ] 已设置，仅配置操作系统，跳过建库。"
		mark_stage_done 3
		exit 0
	fi

	execute_and_log "正在创建数据库" create_db

	mark_stage_done 3
	color_printf green "阶段三（数据库创建）执行完成，状态已写入：$STATE_FILE"
	color_printf green "下一步：sh $SCRIPT_DIR/4_post_config.sh"
}

main "$@" | tee -a "$oracleprintlog"
