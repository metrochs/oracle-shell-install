#!/usr/bin/env bash
#===============================================================================
# 阶段四：后期配置                                        预计耗时 5~15 分钟
#-------------------------------------------------------------------------------
# 覆盖范围：
#   1) 核心参数优化（SGA/PGA/游标/进程/优化器隐式参数等）
#   2) 密码策略放宽（密码永不过期、不锁定、失败次数不限制）
#   3) 归档模式开启与确认
#   4) PDB 自动打开触发器（CDB 架构）
#   5) monitor / backup 专用账户创建
#   6) 控制文件复用、Redo 扩容、开机自启、RMAN 备份任务、glogin.sql
#   7) 内存大页（可选 -hf Y）
#   8) 安装验证并输出汇总
#
# 用法：
#   sh 4_post_config.sh                     # 复用阶段一/二/三状态，正常用法
#   sh 4_post_config.sh -lf eth0 -o orcl ...# 跳过前序阶段直接带全参执行（不推荐）
#===============================================================================
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
set -o pipefail # 管道中任一命令失败都要让整体退出码非 0
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/os_adapt.sh"
source "$SCRIPT_DIR/lib/args.sh"

#==============================================================#
#                          配置控制文件                         #
#==============================================================#
function conf_controlfile() {
	log_print "配置 Oracle 数据库控制文件复用"
	local dbname=$1 ctl_count ctl_name ctl_name_new ctl_path
	ctl_count=$(query_sql_scalar "$dbname" "select count(*) from v\$controlfile;")
	if ((ctl_count == 1)); then
		ctl_name=$(query_sql_scalar "$dbname" "select name from v\$controlfile;")
		ctl_path=$(query_sql_scalar "$dbname" "select substr(name, 1, instr(name, '/', 1, 3)) from v\$controlfile;")
		if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
			ctl_name_new=$(query_sql_scalar "$dbname" "select substr(replace(name,substr(name,1,instr(name,'/',1)-1),'+$data_asm_group'),1,instr(name,'/',-1)-1) || '/control02.ctl' from v\$controlfile where name = '$ctl_name';")
			run_as_oracle "srvctl stop database -d $dbname"
			run_as_oracle "srvctl start database -d $dbname -o nomount"
		else
			ctl_name_new="${ctl_path}control02.ctl"
			execute_sqlplus "$dbname" "" "shu immediate;
startup nomount;" >/dev/null 2>&1
		fi
		su - "$oracle_user" <<-SO
			source /home/$oracle_user/.$dbname
			rman target / <<-EOF
			restore controlfile to '$ctl_name_new' from '$ctl_name';
			EOF
		SO
		execute_sqlplus "$dbname" "" "alter system set control_files='$ctl_name','$ctl_name_new' scope=spfile;"
		if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
			run_as_oracle "srvctl stop database -d $dbname"
			run_as_oracle "srvctl start database -d $dbname"
		else
			execute_sqlplus "$dbname" "" "shu immediate;
startup;" >/dev/null 2>&1
		fi
	fi
	echo
	color_printf blue "数据库控制文件："
	execute_sqlplus "$dbname" "col name for a100" "select name from v\$controlfile;"
}

#==============================================================#
#                      配置在线重做日志                          #
#==============================================================#
function conf_redolog() {
	log_print "配置在线重做日志"
	local i thread dbname=$1 redolog_path max_group new_group
	max_group=$(query_sql_scalar "$dbname" "select max(group#) from v\$logfile;")
	if [[ "$oracle_install_mode" == "rac" ]]; then
		for ((i = 0; i < ${#rac_public_ips[@]}; i++)); do
			max_group=$((max_group + 5 * i))
			((thread = i + 1))
			for ((a = 1; a < 6; a++)); do
				new_group=$((max_group + a))
				execute_sqlplus "$dbname" "" "alter database add logfile thread $thread group $new_group size ${redosize}M;" >/dev/null 2>&1
			done
		done
	else
		redolog_path=$(query_sql_scalar "$dbname" "select substr(member, 1, instr(member, '/', -1, 1)) from v\$logfile where rownum = 1;")
		for ((a = 1; a < 6; a++)); do
			new_group=$((a + max_group))
			if ((new_group < 10)); then
				printf -v new_group "%02d" "$new_group"
			fi
			if [[ "$oracle_install_mode" == "single" ]]; then
				execute_sqlplus "$dbname" "" "alter database add logfile group $new_group '${redolog_path}redo${new_group}.log' size ${redosize}M;" >/dev/null 2>&1
			else
				execute_sqlplus "$dbname" "" "alter database add logfile group $new_group size ${redosize}M;" >/dev/null 2>&1
			fi
		done
	fi
	execute_sqlplus "$dbname" "col member for a80" "select a.thread#,a.group#,b.member member,a.bytes/1024/1024 \"size(M)\" from v\$log a,v\$logfile b where a.group#=b.group# order by 1,2;"
}

#==============================================================#
#                       配置数据库开机自启                        #
#==============================================================#
function db_autostart() {
	log_print "配置 Oracle 数据库开机自启"
	local dbname=$1
	sed -i 's/db:N/db:Y/' /etc/oratab
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		if ((gi_version == 11)); then
			"$env_grid_home"/bin/crsctl modify resource "ora.$dbname.db" -attr "AUTO_START=always"
		else
			"$env_grid_home"/bin/crsctl modify resource "ora.$dbname.db" -attr "AUTO_START=always" -unsupported
		fi
		color_printf blue "数据库开机自启配置："
		"$env_grid_home"/bin/crsctl stat res "ora.$dbname.db" -p | grep AUTO_START
	else
		color_printf blue "数据库开机自启配置："
		sed -i "s/ORACLE_HOME_LISTNER=\$1/ORACLE_HOME_LISTNER=$ORACLE_HOME/" "$env_oracle_home/bin/dbstart"
		if [[ "$os_type" == "sles" ]]; then
			rc_file="/etc/init.d/boot.local"
		elif [[ "$os_type" =~ ^(ubuntu|debian|Deepin)$ ]]; then
			rc_file="/etc/rc.local"
		else
			rc_file="/etc/rc.d/rc.local"
		fi
		backup_restore_file $rc_file
		if ! grep '#!/bin/bash' $rc_file >/dev/null 2>&1; then
			write_file "N" $rc_file "#!/bin/bash"
		fi
		write_file "N" $rc_file "# OracleBegin
su $oracle_user -lc \"$env_oracle_home/bin/lsnrctl start\"
su $oracle_user -lc \"$env_oracle_home/bin/dbstart\""
		chmod +x $rc_file
		grep -v "^\s*\(#\|$\)" $rc_file
	fi
}

#==============================================================#
#                      配置 RMAN 备份脚本                        #
#==============================================================#
function db_backup() {
	log_print "配置 RMAN 备份任务"
	install_package "cron"
	local dbname=$1 scripts_dir=/home/$oracle_user/scripts rman_log_dir="/backup" rman_config
	mkdir -p $scripts_dir
	rman_config=$(
		cat <<-'RMAN'
			allocate channel c1 device type disk;
			allocate channel c2 device type disk;
			crosscheck backup;
			crosscheck archivelog all;
			sql"alter system archive log current";
			delete noprompt expired backup;
			delete noprompt obsolete device type disk;
		RMAN
	)
	local del_arch_script="$scripts_dir/del_arch_$dbname.sh"
	cat >"$del_arch_script" <<DELARCH
#!/bin/bash
source ~/.$dbname
deltime=\$(date +"20%y%m%d%H%M%S")
rman target / nocatalog msglog $scripts_dir/del_arch_${dbname}_\$deltime.log <<EOF
crosscheck archivelog all;
delete noprompt archivelog until time 'sysdate-7';
delete noprompt force archivelog until time 'SYSDATE-10';
EOF
DELARCH
	chmod +x "$del_arch_script"

	local lv0_backup_script="$scripts_dir/dbbackup_lv0_$dbname.sh"
	cat >"$lv0_backup_script" <<LV0BACKUP
#!/bin/bash
source ~/.$dbname
backtime=\$(date +"20%y%m%d%H%M%S")
rman target / log=$rman_log_dir/level0_backup_${dbname}_\$backtime.log<<EOF
run {
$rman_config
backup incremental level 0 database include current controlfile format '/backup/backlv0_%d_%T_%t_%s_%p';
backup not backed up 1 times as compressed backupset archivelog all format '/backup/arch_%d_%T_%t_%s_%p';
}
EOF
LV0BACKUP
	chmod +x "$lv0_backup_script"

	local lv1_backup_script="$scripts_dir/dbbackup_lv1_$dbname.sh"
	cat >"$lv1_backup_script" <<LV1BACKUP
#!/bin/bash
source ~/.$dbname
backtime=\$(date +"20%y%m%d%H%M%S")
rman target / log=$rman_log_dir/level1_backup_${dbname}_\$backtime.log<<EOF
run {
$rman_config
backup incremental level 1 database include current controlfile format '/backup/backlv1_%d_%T_%t_%s_%p';
backup not backed up 1 times as compressed backupset archivelog all format '/backup/arch_%d_%T_%t_%s_%p';
}
EOF
LV1BACKUP
	chmod +x "$lv1_backup_script"

	local crontab_file="/var/spool/cron/$oracle_user"
	if check_file "$crontab_file"; then
		backup_restore_file "$crontab_file"
	else
		touch /var/spool/cron/$oracle_user.original
	fi
	write_file "N" "$crontab_file" "# OracleBegin
00 02 * * * $del_arch_script
#00 00 * * 0 $lv0_backup_script
#00 00 * * 1,2,3,4,5,6 $lv1_backup_script"
	if check_file /etc/cron.allow; then
		write_file "N" "/etc/cron.allow" "$oracle_user"
	fi
	chown -R "$oracle_user":oinstall "$scripts_dir" "$rman_log_dir"
	cat /var/spool/cron/$oracle_user
}

#==============================================================#
#                   优化数据库参数 + 密码策略放宽                  #
#==============================================================#
function conf_para() {
	log_print "优化数据库参数"
	local dbname=$1 nums=$2 sga_target pga_target
	# memory for db sga_size(MB) = os_memory_total * 0.8 * 0.8 / 1024
	((sga_target = (os_memory_total * 8 * 8 / 100 / 1024 / nums)))
	sga_target="${sga_target}M"
	# memory for db pga_size(MB) = os_memory_total * 0.8 * 0.2 / 1024
	((pga_target = (os_memory_total * 8 * 2 / 100 / 1024 / nums)))
	pga_target="${pga_target}M"
	if [[ "$oracle_install_mode" == "rac" ]]; then
		execute_sqlplus "$dbname" "" "alter system set parallel_force_local=true sid='*' scope=spfile;
alter system set \"_gc_policy_time\"=0 scope=spfile;
alter system set \"_gc_undo_affinity\"=false scope=spfile;
alter system set \"_clusterwide_global_transactions\"=FALSE scope=spfile;"
	fi
	# 26ai 已经取消了这两个 job
	if ((db_version != 26)); then
		execute_sqlplus "$dbname" "" "exec dbms_scheduler.disable('ORACLE_OCM.MGMT_CONFIG_JOB');
exec dbms_scheduler.disable('ORACLE_OCM.MGMT_STATS_CONFIG_JOB');"
	fi
	execute_sqlplus "$dbname" "" "BEGIN
DBMS_AUTO_TASK_ADMIN.DISABLE(
client_name => 'auto space advisor',
operation => NULL,
window_name => NULL);
END;
/
BEGIN
DBMS_AUTO_TASK_ADMIN.DISABLE(
client_name => 'sql tuning advisor',
operation => NULL,
window_name => NULL);
END;
/
alter profile default limit password_grace_time unlimited;
alter profile default limit password_life_time unlimited;
alter profile default limit password_lock_time unlimited;
alter profile default limit failed_login_attempts unlimited;
alter system set audit_trail=none sid='*' scope=spfile;
alter system set sga_max_size=$sga_target sid='*' scope=spfile;
alter system set sga_target=$sga_target sid='*' scope=spfile;
alter system set pga_aggregate_target=$pga_target sid='*' scope=spfile;
alter system set processes=2000 scope=spfile;
alter system set open_cursors=1000 scope=spfile;
alter system set session_cached_cursors=300 scope=spfile;
alter system set db_files=5000 scope=spfile;
alter system set \"_undo_autotune\"=false sid='*' scope=spfile;
alter system set undo_retention=10800 scope=spfile;
alter system set control_file_record_keep_time=31;
alter system set event='28401 trace name context forever,level 1','10949 trace name context forever,level 1' sid='*' scope=spfile;
alter system set \"_b_tree_bitmap_plans\"=false sid='*';
alter system set deferred_segment_creation=false sid='*';
alter system set \"_optimizer_adaptive_cursor_sharing\"=false sid='*' scope=spfile;
alter system set \"_optimizer_extended_cursor_sharing\"=none sid='*' scope=spfile;
alter system set \"_optimizer_extended_cursor_sharing_rel\"=none sid='*' scope=spfile;
alter system set \"_optimizer_use_feedback\"=false sid ='*' scope=spfile;
alter system set \"_cleanup_rollback_entries\"=2000 sid='*' scope=spfile;
alter system set \"_datafile_write_errors_crash_instance\"=false sid='*';
alter system set parallel_max_servers=64 sid='*';
alter system reset db_recovery_file_dest;
alter system reset db_recovery_file_dest_size;"
	if ((db_version == 11)); then
		execute_sqlplus "$dbname" "" "alter system set resource_limit=true sid='*' scope=spfile;
alter system set resource_manager_plan='force:' sid='*' scope=spfile;
alter system set \"_optimizer_null_aware_antijoin\"=false sid ='*' scope=spfile;
alter system set \"_px_use_large_pool\"=true sid ='*' scope=spfile;
alter system set \"_partition_large_extents\"=false sid='*' scope=spfile;
alter system set \"_index_partition_large_extents\"=false sid='*' scope=spfile;
alter system set \"_use_adaptive_log_file_sync\"=false sid='*' scope=spfile;
alter system set \"_memory_imm_mode_without_autosga\"=false sid='*' scope=spfile;
alter system set enable_ddl_logging=true sid='*' scope=spfile;
alter system set sec_case_sensitive_logon=false sid='*' scope=spfile;"
	fi
	color_printf blue "数据库参数："
	execute_sqlplus "$dbname" "col name for a50
col sid for a10
col spvalue for a80
col VALUE for a80" "SELECT DISTINCT s.name,
                s.sid,
                s.value spvalue,
                p.value VALUE
  FROM v\$spparameter s,
       gv\$parameter  p
 WHERE s.name = p.name
   AND (s.value IS NOT NULL OR (p.name IN ('statistics_level',
                                           'processes',
                                           'sessions',
                                           'db_files',
                                           'spfile',
                                           'optimizer_adaptive_features',
                                           'optimizer_adaptive_plans',
                                           'optimizer_adaptive_statistics',
                                           'max_string_size',
                                           'control_file_record_keep_time',
                                           '_use_adaptive_log_file_sync',
                                           'fast_start_parallel_rollback',
                                           '_datafile_write_errors_crash_instance',
                                           'max_dump_file_size',
                                           'parallel_max_servers',
                                           'deferred_segment_creation',
                                           '_optimizer_use_feedback',
                                           'open_cursors',
                                           'session_cached_cursors',
                                           'OPTIMIZER_INDEX_COST_ADJ',
                                           'optimizer_index_caching',
                                           'audit_trail',
                                           'SEC_CASE_SENSITIVE_LOGON',
                                           'parallel_force_local',
                                           'db_file_multiblock_read_count',
                                           'event',
                                           'dispatchers',
                                           'db_writer_processes',
                                           'optimizer_mode')))
   AND p.name NOT IN ('thread',
                      'instance_name',
                      'instance_number',
                      'undo_tablespace',
                      'local_listener',
                      'remote_listener',
                      'lisneter_network',
                      'control_files')
 ORDER BY s.name;"
}

#==============================================================#
#                          开启归档模式                          #
#==============================================================#
function conf_archivelog() {
	local dbname=$1 arch log_mode
	log_print "检查并开启归档模式"
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		if [[ $arch_base_disk ]]; then
			arch=+$arch_asm_group
		else
			arch=+$data_asm_group
		fi
	else
		arch=$archive_dir
	fi
	log_mode=$(query_sql_scalar "$dbname" "select log_mode from v\$database;")
	if [[ $log_mode == "ARCHIVELOG" ]]; then
		color_printf green "数据库 $dbname 已处于归档模式，归档路径：$arch，无需切换。"
		return 0
	fi
	if [[ $enable_arch != "true" ]]; then
		color_printf yellow "参数 [ -er false ] 已设置，跳过归档模式开启。"
		return 0
	fi
	color_printf blue "正在开启归档模式：$dbname"
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		execute_sqlplus "$dbname" "" "alter system set log_archive_dest_1='location=$arch' sid='*' scope=spfile;"
		run_as_oracle "srvctl stop database -d $dbname"
		run_as_oracle "srvctl start database -d $dbname -o mount"
		execute_sqlplus "$dbname" "" "alter database archivelog;"
		run_as_oracle "srvctl stop database -d $dbname"
		run_as_oracle "srvctl start database -d $dbname"
	else
		execute_sqlplus "$dbname" "" "alter system set log_archive_dest_1='location=$arch' scope=spfile;
shu immediate;
startup mount;
alter database archivelog;
alter database open;"
	fi
	execute_sqlplus "$dbname" "" "archive log list;"
}

#==============================================================#
#                      PDB 自动打开触发器                        #
#==============================================================#
function conf_pdb_autostart() {
	local dbname=$1
	[[ $iscdb == "true" ]] || return 0
	log_print "创建 PDB 自动打开触发器"
	execute_sqlplus "$dbname" "" "alter pluggable database all open;
alter pluggable database all save state;
CREATE OR REPLACE TRIGGER SYS.OPEN_ALL_PDBS
AFTER STARTUP ON DATABASE
BEGIN
  EXECUTE IMMEDIATE 'alter pluggable database all open';
EXCEPTION
  WHEN OTHERS THEN
    NULL;
END;
/"
	color_printf blue "查看 PDB 状态与触发器："
	execute_sqlplus "$dbname" "" "show pdbs
select owner, trigger_name, status from dba_triggers where trigger_name = 'OPEN_ALL_PDBS';"
}

#==============================================================#
#                  monitor / backup 专用账户创建                  #
#==============================================================#
function conf_service_user() {
	local dbname=$1 prefix="" container_clause="";
	log_print "创建 monitor / backup 专用账户"
	# CDB 架构下公共用户必须以 C## 开头
	if [[ $iscdb == "true" ]]; then
		prefix="C##"
		container_clause=" container=all"
	fi
	local mon_user="${prefix}MONITOR" bak_user="${prefix}BACKUP" pwd=$database_passwd
	# 幂等：账户已存在时跳过，避免重跑报 ORA-01920
	local exists
	exists=$(query_sql_scalar "$dbname" "select count(*) from dba_users where username in ('$mon_user','$bak_user');")
	if ((exists > 0)); then
		color_printf yellow "账户 $mon_user / $bak_user 已存在，跳过创建（如需重置密码请手工 alter user）。"
		return 0
	fi
	execute_sqlplus "$dbname" "" "create user $mon_user identified by $pwd${container_clause};
grant create session to $mon_user${container_clause};
grant select any dictionary to $mon_user${container_clause};
grant select_catalog_role to $mon_user${container_clause};
create user $bak_user identified by $pwd${container_clause};
grant create session to $bak_user${container_clause};
grant select any dictionary to $bak_user${container_clause};
grant select_catalog_role to $bak_user${container_clause};"
	# 12c 之后使用 SYSBACKUP 权限做 RMAN 备份
	if ((db_version >= 12)); then
		execute_sqlplus "$dbname" "" "grant sysbackup to $bak_user${container_clause};"
	else
		execute_sqlplus "$dbname" "" "grant alter session to $bak_user;
grant select any table to $bak_user;"
	fi
	color_printf blue "查看专用账户："
	execute_sqlplus "$dbname" "col username for a20" "select username, account_status, created from dba_users where username in ('$mon_user','$bak_user');"
	color_printf green "已创建账户：$mon_user（只读监控）、$bak_user（备份），密码与 SYS/SYSTEM 一致。"
}

#==============================================================#
#                         配置 glogin.sql                       #
#==============================================================#
function conf_glogin() {
	write_glogin_sql_config() {
		local target_file="$1"
		write_file "Y" "$target_file" "define _editor=vi
set serveroutput on size 1000000
set trimspool on
set long 5000
set linesize 100
set pagesize 9999
column plan_plus_exp format a80
set sqlprompt '&_user.@&_connect_identifier. SQL> '"
	}
	log_print "配置 glogin.sql"
	backup_restore_file "$env_oracle_home/sqlplus/admin/glogin.sql"
	write_glogin_sql_config "$env_oracle_home/sqlplus/admin/glogin.sql"
	if [[ "$oracle_install_mode" == "rac" ]]; then
		backup_restore_file "$env_grid_home/sqlplus/admin/glogin.sql"
		write_glogin_sql_config "$env_grid_home/sqlplus/admin/glogin.sql"
		for ip in "${rac_public_ips[@]:1}"; do
			run_as_oracle "scp -q $env_oracle_home/sqlplus/admin/glogin.sql $ip:$env_oracle_home/sqlplus/admin/"
			run_as_grid "scp -q $env_grid_home/sqlplus/admin/glogin.sql $ip:$env_grid_home/sqlplus/admin/"
		done
	fi
	grep -v "^\s*\(#\|$\|--\)" "$env_oracle_home/sqlplus/admin/glogin.sql"
}

#==============================================================#
#                         配置大页内存                          #
#==============================================================#
function conf_hugepage() {
	log_print "配置大页内存"
	local KERN HPG_SZ NUM_PG=0 MIN_PG RES_BYTES HUGETLB_POOL
	KERN=$(uname -r | awk -F. '{ printf("%d.%d\n",$1,$2); }')
	HPG_SZ=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
	if [ -z "$HPG_SZ" ]; then
		color_printf yellow "在当前系统中不支持 HugePages！"
		echo
		return 1
	fi
	for SEG_BYTES in $(ipcs -m | cut -c44-300 | awk '{print $1}' | grep "[0-9][0-9]*"); do
		MIN_PG=$(echo "$SEG_BYTES/($HPG_SZ*1024)" | bc -q)
		if ((MIN_PG > 0)); then
			NUM_PG=$(echo "$NUM_PG+$MIN_PG+1" | bc -q)
		fi
	done
	RES_BYTES=$(echo "$NUM_PG * $HPG_SZ * 1024" | bc -q)
	if ((RES_BYTES < 100000000)); then
		color_printf yellow "无法为 HugePages 配置分配足够的共享内存段。HugePages 只能用于大小与 Oracle 数据库 SGA 匹配的共享内存段。请确保：
* Oracle 数据库实例正在运行；
* Oracle 数据库 11g 自动内存管理（AMM）未配置！"
		echo
		return 1
	fi
	case $KERN in
	"2.4")
		HUGETLB_POOL=$(echo "$NUM_PG*$HPG_SZ/1024" | bc -q)
		echo "建议的参数设置：vm.hugetlb_pool = $HUGETLB_POOL"
		sysctl -w vm.hugetlb_pool="$HUGETLB_POOL"
		write_file "N" "/etc/sysctl.conf" "vm.hugetlb_pool=$HUGETLB_POOL"
		if [[ "$oracle_install_mode" == "rac" ]]; then
			for ip in "${rac_public_ips[@]:1}"; do
				ssh -q "$ip" sysctl -w vm.hugetlb_pool="$HUGETLB_POOL"
				ssh -q "$ip" "cat <<-EOF >>/etc/sysctl.conf
vm.hugetlb_pool=$HUGETLB_POOL
EOF"
			done
		fi
		;;
	*)
		echo "建议的参数设置：vm.nr_hugepages = $NUM_PG"
		sysctl -w vm.nr_hugepages="$NUM_PG"
		write_file "N" "/etc/sysctl.conf" "vm.nr_hugepages=$NUM_PG"
		if [[ "$oracle_install_mode" == "rac" ]]; then
			for ip in "${rac_public_ips[@]:1}"; do
				ssh -q "$ip" sysctl -w vm.nr_hugepages="$NUM_PG"
				ssh -q "$ip" "cat <<-EOF >>/etc/sysctl.conf
vm.nr_hugepages=$NUM_PG
EOF"
			done
		fi
		;;
	esac
	grep HugePages_Total /proc/meminfo
}

#==============================================================#
#                           安装验证                            #
#==============================================================#
function verify_install() {
	log_print "安装验证"
	local dbname rc=0
	VERIFY_FAILED=0
	for dbname in "${db_names[@]}"; do
		local inst_status open_mode log_mode db_role
		inst_status=$(query_sql_scalar "$dbname" "select status from v\$instance;")
		open_mode=$(query_sql_scalar "$dbname" "select open_mode from v\$database;")
		log_mode=$(query_sql_scalar "$dbname" "select log_mode from v\$database;")
		[[ $inst_status == "OPEN" ]] || VERIFY_FAILED=1
		color_printf green "实例 $dbname" "状态: ${inst_status:-UNKNOWN}" "open_mode: ${open_mode:-UNKNOWN} log_mode: ${log_mode:-UNKNOWN}"
		if [[ $iscdb == "true" ]]; then
			echo
			execute_sqlplus "$dbname" "" "show pdbs"
		fi
	done
	echo
	color_printf blue "监听状态："
	if [[ "$oracle_install_mode" == "single" ]]; then
		run_as_oracle "lsnrctl status" || VERIFY_FAILED=1
	else
		run_as_grid "crsctl stat res -t" || VERIFY_FAILED=1
	fi
	echo
	color_printf blue "数据库版本："
	for dbname in "${db_names[@]}"; do
		execute_sqlplus "$dbname" "" "select * from v\$version where rownum = 1;"
	done
	if ((VERIFY_FAILED == 0)); then
		color_printf green "安装验证通过：数据库实例、监听均正常。"
	else
		color_printf yellow "安装验证存在异常项，请检查上方输出与日志：$oracleinstalllog"
	fi
	return $rc
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
		require_stage 3
		get_os_info
	fi

	if [[ $optimize_db == "Y" ]]; then
		execute_and_log "正在优化数据库" db_optimize
	else
		color_printf yellow "参数 [ -opd N ]，跳过数据库优化（控制文件复用/redo 扩容/开机自启/RMAN 备份/参数优化）。"
	fi

	if [[ $huge_flag == "Y" ]] && ((node_num == 1)); then
		execute_and_log "正在配置内存大页" conf_hugepage
	fi

	execute_and_log "正在执行安装验证" verify_install

	mark_stage_done 4
	install_time_record "end"
}

function db_optimize() {
	for name in "${db_names[@]}"; do
		conf_controlfile "$name"
		conf_redolog "$name"
		conf_para "$name" ${#db_names[@]}
		db_autostart "$name"
		db_backup "$name"
		conf_archivelog "$name"
		conf_pdb_autostart "$name"
		conf_service_user "$name"
		# 参数走 scope=spfile，这里统一重启一次让其立即生效
		# （若库本来就是归档模式，conf_archivelog 不会触发重启，真机验证时踩过）
		if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
			run_as_oracle "srvctl stop database -d $name"
			run_as_oracle "srvctl start database -d $name"
		else
			execute_sqlplus "$name" "" "shu immediate;
startup;" >/dev/null 2>&1
		fi
	done
	conf_glogin
}

main "$@" | tee -a "$oracleprintlog"
