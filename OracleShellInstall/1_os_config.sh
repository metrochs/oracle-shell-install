#!/usr/bin/env bash
#===============================================================================
# 阶段一：OS 配置                                          预计耗时 5~15 分钟
#-------------------------------------------------------------------------------
# 覆盖范围：
#   主机名与网络(/etc/hosts) / LVM 存储目录 / 用户与 10 个标准组 /
#   17 类内核参数(sysctl) / 资源限制(limits) / SELinux·防火墙·GRUB 优化 /
#   离线 YUM 源 / 40+ 依赖包 / 环境变量(profile) / /dev/shm 调整
#   （RAC 模式额外：时间同步、DNS 解析、multipath+UDEV 绑盘、节点间 SSH 互信）
#
# 用法：
#   sh 1_os_config.sh -lf eth0 -n orcl -o orcl -dbv 26 ...     # 带参数执行
#   sh 1_os_config.sh                                          # 复用状态文件重跑
#===============================================================================
SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
set -o pipefail # 管道中任一命令失败都要让整体退出码非 0
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/os_adapt.sh"
source "$SCRIPT_DIR/lib/args.sh"

#==============================================================#
#                           配置 swap                          #
#==============================================================#
function conf_swap() {
	if ! grep -q '/swapfile swap swap defaults 0 0' /etc/fstab; then
		log_print "配置 SWAP 交换空间"
		rm_file /swapfile
		dd if=/dev/zero of=/swapfile bs=1K count=$swap_count >/dev/null 2>&1
		chmod 600 /swapfile
		mkswap /swapfile >/dev/null 2>&1
		swapon /swapfile >/dev/null 2>&1
		write_file "N" "/etc/fstab" "/swapfile swap swap defaults 0 0"
		free -m
	fi
}

#==============================================================#
#                           禁用防火墙                          #
#==============================================================#
function disable_firewall() {
	log_print "禁用防火墙"
	case "$os_type" in
	"ubuntu" | "debian" | "Deepin")
		if type ufw >/dev/null 2>&1; then
			ufw stop && ufw disable >/dev/null 2>&1
			ufw status
		else
			color_printf blue "当前主机未安装防火墙，无需配置！"
		fi
		;;
	"sles")
		if ((os_version == 7)); then
			service SuSEfirewall2 stop && SuSEfirewall2 off >/dev/null 2>&1
			service SuSEfirewall2 status
		else
			systemctl stop firewalld.service && systemctl disable firewalld.service >/dev/null 2>&1
			systemctl status firewalld
		fi
		;;
	*)
		if ((os_version == 6)); then
			chkconfig iptables off && service iptables stop >/dev/null 2>&1
			service iptables status
		else
			systemctl stop firewalld.service && systemctl disable firewalld.service >/dev/null 2>&1
			systemctl status firewalld
		fi
		;;
	esac
}

#==============================================================#
#                          禁用 SELinux                        #
#==============================================================#
function disable_selinux() {
	log_print "禁用 SELinux"
	if [[ $(getenforce) != "Disabled" ]]; then
		setenforce 0
	fi
	sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
	sestatus
}

#==============================================================#
#                       配置 nsysctl.conf                       #
#==============================================================#
function conf_nsysctl() {
	if ! grep -q "^NOZEROCONF=yes$" /etc/sysconfig/network; then
		log_print "配置 nsysctl.conf"
		backup_restore_file /etc/sysconfig/network
		write_file "N" "/etc/sysconfig/network" "# OracleBegin
NOZEROCONF=yes"
		grep -v "^\s*\(#\|$\)" /etc/sysconfig/network
	fi
}

#==============================================================#
#                           配置主机名                          #
#==============================================================#
function conf_hostname() {
	log_print "配置主机名"
	if [[ "$os_type" == "sles" ]]; then
		local hostname_file="/etc/hostname"
	else
		case "$os_version" in
		"6") local hostname_file="/etc/sysconfig/network" ;;
		*) local hostname_file="/etc/hostname" ;;
		esac
	fi
	if ! grep -Fxq "$HOSTNAME" "$hostname_file"; then
		case "$os_version" in
		"6")
			hostname "$HOSTNAME"
			sysctl kernel.hostname="$HOSTNAME"
			write_file "Y" "/proc/sys/kernel/hostname" "$HOSTNAME"
			sed -i "s/^HOSTNAME=.*/HOSTNAME=$HOSTNAME/" "$hostname_file"
			hostname
			;;
		*)
			hostnamectl set-hostname "$HOSTNAME"
			write_file "Y" "$hostname_file" "$HOSTNAME"
			hostnamectl
			;;
		esac
	else
		cat "$hostname_file"
	fi
}

#==============================================================#
#                      配置 /etc/hosts 文件                     #
#==============================================================#
function conf_hosts() {
	log_print "配置 /etc/hosts 文件"
	backup_restore_file /etc/hosts
	if [[ "$oracle_install_mode" == "rac" ]]; then
		[[ $(stat -c "%a" /etc/hosts) != 644 ]] && chmod 644 /etc/hosts
		write_file "N" "/etc/hosts" "
# OracleBegin"
		local node
		for i in "${!rac_hostnames[@]}"; do
			((node = i + 1))
			local priv_count=0
			hosts_array+=("${rac_public_ips[i]}" "${rac_hostnames[i]}")
			write_file "N" "/etc/hosts" "
# RAC$node IP's: ${rac_hostnames[i]}

# RAC$node Public IP
${rac_public_ips[i]} ${rac_hostnames[i]}
# RAC$node Virtual IP
${rac_virtual_ips[i]} ${rac_hostnames[i]}-vip
# RAC$node Private IP"
			for node_name in "${rac_priv_ifnames_sorted[@]}"; do
				for ifname in "${!rac_priv_ips[@]}"; do
					if [[ $ifname == *"$node_name"* ]]; then
						if [[ $ifname == *"${rac_public_ips[i]}"* ]]; then
							((priv_count++))
							if ((priv_count > 1)); then
								hosts_array+=("${rac_priv_ips[$ifname]}" "${rac_hostnames[i]}-priv1")
								write_file "N" "/etc/hosts" "${rac_priv_ips[$ifname]} ${rac_hostnames[i]}-priv1"
							else
								hosts_array+=("${rac_priv_ips[$ifname]}" "${rac_hostnames[i]}-priv")
								write_file "N" "/etc/hosts" "${rac_priv_ips[$ifname]} ${rac_hostnames[i]}-priv"
							fi
						fi
					fi
				done
			done
		done
		if ((scan_count == 1)); then
			write_file "N" "/etc/hosts" "
# SCAN IP
${rac_scan_ips[0]} $scan_name"
		fi
	else
		write_file "N" "/etc/hosts" "
# OracleBegin
# Public IP
$local_ip	$hostname"
	fi
	grep -v "^\s*\(#\|$\)" /etc/hosts >>"$oracleinstalllog" 2>&1 &
}

#==============================================================#
#                        创建用户和组                            #
#==============================================================#
function create_users_groups() {
	log_print "创建用户和组"
	local flag
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		flag="true"
	fi
	# 10 个标准组：oinstall/dba/oper/backupdba/dgdba/kmdba/racdba/asmdba/asmoper/asmadmin
	local group_groups=("oinstall:54321" "dba:54322" "oper:54323" "backupdba:54324" "dgdba:54325" "kmdba:54326" "racdba:54330" ${flag:+"asmdba:54327"} ${flag:+"asmoper:54328"} ${flag:+"asmadmin:54329"})
	local user_groups=("$oracle_user" ${flag:+$grid_user})
	declare -A passwd_groups=(
		[$oracle_user]=$oracle_passwd
		[$grid_user]=$grid_passwd
	)
	for group in "${group_groups[@]}"; do
		local groupname=${group%%:*}
		local gid=${group##*:}
		if ! grep -E -q "^$groupname:" /etc/group; then
			groupadd -g "$gid" "$groupname" >/dev/null 2>&1
		fi
	done
	for user in "${user_groups[@]}"; do
		local uid
		uid=$([[ $user == "$oracle_user" ]] && echo "54321" || echo "11012")
		local primary_group=oinstall
		local other_groups=dba,oper,backupdba,dgdba,kmdba,racdba${flag:+",asmdba"}${flag:+",asmoper"}${flag:+",asmadmin"}
		if ! id -u "$user" >/dev/null 2>&1; then
			rm_file /etc/group.lock
			rm_file /etc/gshadow.lock
			rm_file /etc/passwd.lock
			rm_file /etc/subuid.lock
			rm_file /etc/subgid.lock
			rm_file /etc/shadow.lock
			useradd -u "$uid" -g $primary_group -G "$other_groups" -m "$user" >/dev/null 2>&1
		else
			usermod -g $primary_group -G "$other_groups" "$user" >/dev/null 2>&1
		fi
		echo "$user:${passwd_groups[$user]}" | chpasswd >/dev/null 2>&1
		color_printf blue "$user 用户："
		id "$user"
		echo
	done
}

#==============================================================#
#                         创建安装目录                          #
#==============================================================#
function create_dir() {
	/bin/mkdir -p "$env_oracle_home" "$env_oracle_inven" "$backup_dir" "$oradata_dir"
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		cascade_del_file "$env_grid_home"
		/bin/mkdir -p "$env_grid_base" "$env_grid_home"
		chown -R "$grid_user":oinstall {$env_base_dir,"$env_grid_home","$env_oracle_inven"}
		chown -R "$oracle_user":oinstall {"$backup_dir","$env_oracle_base"}
	else
		/bin/mkdir -p "$archive_dir"
		chown -R "$oracle_user":oinstall {"$oradata_dir","$backup_dir","$env_base_dir","$archive_dir"}
	fi
	chmod -R 775 "$env_base_dir"
}

#==============================================================#
#                        配置 avahi daemon                      #
#==============================================================#
function conf_avahi() {
	log_print "配置 Avahi-daemon 服务"
	case "$os_version" in
	"6")
		if (($(chkconfig --list | grep avahi-daemon | grep -c '3:on') > 0)); then
			service avahi-daemon stop
			chkconfig avahi-daemon off
		fi
		service avahi-daemon status
		;;
	*)
		if (($(systemctl status avahi-daemon | grep -c running) > 0)); then
			systemctl stop avahi-daemon.socket >/dev/null 2>&1
			systemctl stop avahi-daemon.service >/dev/null 2>&1
			kill_process "avahi-daemon"
			systemctl disable avahi-daemon.service >/dev/null 2>&1
			systemctl disable avahi-daemon.socket >/dev/null 2>&1
		fi
		systemctl status avahi-daemon
		;;
	esac
}

#==============================================================#
#               配置 THP && NUMA && 磁盘 IO 调度器               #
#==============================================================#
function conf_grub() {
	log_print "配置透明大页 && NUMA && 磁盘 IO 调度器"
	set_kernel_option() {
		local option="$1"
		if grubby --info=ALL | grep -q "$option"; then
			return 0
		fi
		grubby --update-kernel=ALL --args="$option"
	}
	case "$os_type" in
	"ubuntu" | "debian" | "sles" | "arch" | "Deepin")
		sed -i 's/quiet/quiet transparent_hugepage=never numa=off tsx=off elevator=deadline/' /etc/default/grub
		sed -i 's|GRUB_DISABLE_OS_PROBER="true"|GRUB_DISABLE_OS_PROBER="false"|' /etc/default/grub
		if [[ "$os_type" =~ ^(ubuntu|debian|arch|Deepin)$ ]]; then
			grub-mkconfig -o /boot/grub/grub.cfg
		elif [[ "$os_type" == "sles" ]]; then
			grub2-mkconfig -o /boot/grub2/grub.cfg
		fi
		;;
	*)
		local options=("numa=off" "transparent_hugepage=never" "elevator=deadline")
		for option in "${options[@]}"; do
			set_kernel_option "$option"
		done
		grubby --info=ALL | awk '/numa/{print $0 "\n-" $(NR-1) "\n-" $(NR-2)}'
		;;
	esac
}

#==============================================================#
#                        配置 sysctl.conf                       #
#==============================================================#
function conf_sysctl() {
	log_print "配置 sysctl.conf"
	local pagesize min_free_kbytes shmall shmmax
	pagesize=$(getconf PAGE_SIZE)
	((min_free_kbytes = os_memory_total / 250))
	((shmall = (os_memory_total - 1) * 1024 / pagesize))
	((shmmax = os_memory_total * 1024 - 10))
	((shmall < 2097152)) && shmall=2097152
	((shmmax < 4294967295)) && shmmax=4294967295
	backup_restore_file /etc/sysctl.conf
	write_file "Y" "/etc/sysctl.conf" "# OracleBegin
fs.aio-max-nr = 1048576
fs.file-max = 6815744
kernel.shmall = $shmall
kernel.shmmax = $shmmax
kernel.shmmni = 4096
kernel.sem = 250 32000 100 256
net.ipv4.ip_local_port_range = 9000 65500
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
vm.min_free_kbytes=$min_free_kbytes
net.ipv4.conf.$local_ifname.rp_filter = 1
vm.swappiness = 10
kernel.panic_on_oops = 1
kernel.randomize_va_space = 2
vm.hugetlb_shm_group=54321"
	# centos6 部分版本没有这个参数
	if [[ $os_version != "6" ]]; then
		write_file "N" "/etc/sysctl.conf" "kernel.numa_balancing = 0"
	fi
	# RAC 模式追加心跳网卡参数
	for priv_ifname in "${rac_priv_ifnames[@]}"; do
		if [[ $priv_ifname ]]; then
			write_file "N" "/etc/sysctl.conf" "net.ipv4.conf.$priv_ifname.rp_filter = 2"
		fi
	done
	color_printf blue "查看 sysctl.conf 配置情况 ：sysctl -p"
	sysctl -p
}

#==============================================================#
#                         配置 RemoveIPC                       #
#==============================================================#
function conf_ipc() {
	log_print "配置 RemoveIPC"
	if grep -Fq "#RemoveIPC=yes" "$logind_file"; then
		sed -i 's/#RemoveIPC=yes/RemoveIPC=no/' "$logind_file"
	fi
	if grep -Fq "#RemoveIPC=no" "$logind_file"; then
		sed -i 's/#RemoveIPC=no/RemoveIPC=no/' "$logind_file"
	fi
	systemctl daemon-reload >/dev/null 2>&1
	systemctl restart systemd-logind >/dev/null 2>&1
	color_printf blue "查看 RemoveIPC ：$logind_file"
	grep "RemoveIPC" "$logind_file"
}

#==============================================================#
#                        配置 limits.conf                       #
#==============================================================#
function conf_limits() {
	log_print "配置 /etc/security/limits.conf 和 /etc/pam.d/login"
	backup_restore_file /etc/security/limits.conf
	write_file "N" "/etc/security/limits.conf" "# OracleBegin
$oracle_user soft nofile 1024
$oracle_user hard nofile 65536
$oracle_user soft stack 10240
$oracle_user hard stack 32768
$oracle_user soft nproc 16384
$oracle_user hard nproc 16384
$oracle_user hard memlock unlimited
$oracle_user soft memlock unlimited"
	if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
		write_file "N" "/etc/security/limits.conf" "grid soft nofile 1024
$grid_user hard nofile 65536
$grid_user soft stack 10240
$grid_user hard stack 32768
$grid_user soft nproc 16384
$grid_user hard nproc 16384"
	fi
	color_printf blue "查看 /etc/security/limits.conf："
	grep -v "^\s*\(#\|$\)" /etc/security/limits.conf
	backup_restore_file /etc/pam.d/login
	write_file "N" "/etc/pam.d/login" "# OracleBegin
session required pam_limits.so
# OracleEnd"
	echo
	color_printf blue "查看 /etc/pam.d/login 文件："
	grep -v "^\s*\(#\|$\)" /etc/pam.d/login
}

#==============================================================#
#                         配置 /dev/shm                        #
#==============================================================#
function conf_shm() {
	log_print "配置 /dev/shm"
	local shm_total
	shm_total=$(df -k /dev/shm | awk 'NR==2 {print $2}')
	if ! grep -qE "/dev/shm" /etc/fstab; then
		backup_restore_file /etc/fstab
		write_file "N" "/etc/fstab" "# OracleBegin
tmpfs /dev/shm tmpfs size=${os_memory_total}k 0 0"
	elif ((shm_total < os_memory_total)); then
		backup_restore_file /etc/fstab
		sed -i "/\/dev\/shm/d" /etc/fstab
		write_file "N" "/etc/fstab" "# OracleBegin
tmpfs /dev/shm tmpfs size=${os_memory_total}k 0 0"
	fi
	mount -o remount /dev/shm
	color_printf blue "查看 Linux 挂载情况：/etc/fstab"
	grep -v "^\s*\(#\|$\)" /etc/fstab
}

#==============================================================#
#                       安装 rlwrap 插件                        #
#==============================================================#
function install_rlwrap() {
	log_print "安装 rlwrap 插件"
	/bin/mkdir -p "$software_dir"/rlwrap && cd "$software_dir"/rlwrap || return 1
	tar -xf "$software_dir"/rlwrap-*.gz --strip-components 1 -C "$software_dir"/rlwrap
	(./configure -q && make -s && make install -s prefix=/usr/local libdir=/usr/local/libexec) >/dev/null 2>&1
	cd ..
	rm_file "$software_dir/rlwrap"
	if type rlwrap >/dev/null 2>&1; then
		color_printf green "成功安装 rlwrap：" "$(rlwrap -v)"
	else
		color_printf yellow "未能成功安装 rlwrap，请检查安装日志。"
	fi
}

#==============================================================#
#                         配置 profile                         #
#==============================================================#
function conf_profile() {
	local oracle_sids grid_sid
	log_print "Root 用户环境变量"
	backup_restore_file /root/"$profile_name"
	write_file "N" "/root/$profile_name" "# OracleBegin
alias so='su - $oracle_user'
export PS1="[\`whoami\`@\`hostname\`:"'\$PWD]# '
alias bdf='df -Th'
alias syslog='vi /var/log/messages'"
	if [[ $oracle_install_mode =~ ^(rac|standalone)$ ]]; then
		write_file "N" "/root/$profile_name" "alias sg='su - $grid_user'
alias crsctl='$env_grid_home/bin/crsctl'
alias srvctl='$env_grid_home/bin/srvctl'"
	fi
	color_printf blue "查看 root 用户环境变量：/root/$profile_name"
	grep -v "^\s*\(#\|$\)" /root/"$profile_name"
	if [[ $oracle_install_mode == "rac" ]]; then
		grid_sid=+ASM$node_num
	elif [[ $oracle_install_mode == "standalone" ]]; then
		grid_sid=+ASM
	fi
	for name in "${db_names[@]}"; do
		if [[ "$oracle_install_mode" =~ ^(single|standalone)$ ]]; then
			oracle_sids+=("$name" "$name")
		else
			oracle_sids+=("$name" "${name}$node_num")
		fi
	done
	adapt_oracle_support() {
		local profile_user=$1
		if [[ "$cpu_type" == "aarch64" ]]; then
			write_file "N" "/home/$profile_user/$profile_name" "export CV_ASSUME_DISTID=OL8"
		else
			case "$os_version" in
			7)
				if [[ "$oracle_os_flag" == "N" ]]; then
					write_file "N" "/home/$profile_user/$profile_name" "export CV_ASSUME_DISTID=OL7"
				fi
				;;
			8 | 9 | 10)
				if ((db_version >= 26)); then
					write_file "N" "/home/$profile_user/$profile_name" "export CV_ASSUME_DISTID=OL8"
				else
					write_file "N" "/home/$profile_user/$profile_name" "export CV_ASSUME_DISTID=OL7"
				fi
				;;
			esac
		fi
	}
	for ((i = 0; i < ${#oracle_sids[@]}; i += 2)); do
		log_print "$oracle_user 用户环境变量，实例名：${oracle_sids[i + 1]}"
		backup_restore_file /home/$oracle_user/"$profile_name"
		write_file "N" "/home/$oracle_user/$profile_name" "# OracleBegin
umask 022
export TMP=/tmp
export TMPDIR=\$TMP
export NLS_LANG=AMERICAN_AMERICA.$db_characterset
export ORACLE_BASE=$env_oracle_base
export ORACLE_HOME=$env_oracle_home
export ORACLE_TERM=xterm
export TNS_ADMIN=\$ORACLE_HOME/network/admin
export ORACLE_SID=${oracle_sids[i + 1]}
export PATH=/usr/sbin:\$PATH
export PATH=\$ORACLE_HOME/bin:\$ORACLE_HOME/OPatch:\$ORACLE_HOME/perl/bin:\$PATH
export PERL5LIB=\$ORACLE_HOME/perl/lib
alias sas='sqlplus / as sysdba'
alias awr='sqlplus / as sysdba @?/rdbms/admin/awrrpt'
alias ash='sqlplus / as sysdba @?/rdbms/admin/ashrpt'
alias alert='vi \$ORACLE_BASE/diag/rdbms/*/\$ORACLE_SID/trace/alert_\$ORACLE_SID.log'
export PS1=\"[\`whoami\`@\`hostname\`:\"'\$PWD]\$ '
alias bdf='df -Th'
alias acd='cd \$ORACLE_BASE/diag/rdbms/*/\$ORACLE_SID/trace'
alias dblog='tail -200f \$ORACLE_BASE/diag/rdbms/*/\$ORACLE_SID/trace/alert_\$ORACLE_SID.log'"
		adapt_oracle_support "$oracle_user"
		if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
			export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib:$HOME/lib:/lib/x86_64-linux-gnu
		else
			export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
		fi
		if [[ $oracle_install_mode =~ ^(rac|standalone)$ ]]; then
			if ((db_version = 11)) && ((os_version >= 10)); then
				write_file "N" "/home/$oracle_user/$profile_name" "export LD_LIBRARY_PATH=\$ORACLE_HOME/oui/lib/linux64/:$LD_LIBRARY_PATH"
			fi
		fi
		if type rlwrap >/dev/null 2>&1; then
			write_file "N" "/home/$oracle_user/$profile_name" "alias sqlplus='rlwrap sqlplus'
alias rman='rlwrap rman'
alias adrci='rlwrap adrci'"
		fi
		if [[ "$os_type" == "sles" ]]; then
			chown -R "$oracle_user":oinstall /home/$oracle_user/
		fi
		color_printf blue "查看 $oracle_user 用户环境变量：/home/$oracle_user/$profile_name"
		grep -v "^\s*\(#\|$\)" /home/$oracle_user/"$profile_name"
		/bin/cp -f /home/$oracle_user/"$profile_name" /home/$oracle_user/."${oracle_sids[i]}"
		chown -R "$oracle_user":oinstall "/home/$oracle_user/"
	done
	if [[ $oracle_install_mode =~ ^(rac|standalone)$ ]]; then
		log_print "$grid_user 用户环境变量"
		backup_restore_file /home/$grid_user/"$profile_name"
		write_file "N" "/home/$grid_user/$profile_name" "# OracleBegin
umask 022
export TMP=/tmp
export TMPDIR=\$TMP
export NLS_LANG=AMERICAN_AMERICA.$db_characterset
export ORACLE_BASE=$env_grid_base
export ORACLE_HOME=$env_grid_home
export ORACLE_TERM=xterm
export TNS_ADMIN=\$ORACLE_HOME/network/admin
export ORACLE_SID=$grid_sid
export PATH=/usr/sbin:\$PATH
export PATH=\$ORACLE_HOME/bin:\$ORACLE_HOME/OPatch:\$PATH
alias sas='sqlplus / as sysasm'
alias bdf='df -Th'
export PS1=\"[\`whoami\`@\`hostname\`:\"'\$PWD]\$ '"
		adapt_oracle_support "$grid_user"
		if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
			export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib:$HOME/lib:/lib/x86_64-linux-gnu
		else
			export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
		fi
		if type rlwrap >/dev/null 2>&1; then
			write_file "N" "/home/$grid_user/$profile_name" "alias sqlplus='rlwrap sqlplus'
alias adrci='rlwrap adrci'"
		fi
		local node_count=${#rac_public_ips[@]}
		if ((db_version = 19 && node_count > 2)); then
			write_file "N" "/home/$grid_user/$profile_name" "export SRVM_DISABLE_MTTRANS=true"
		fi
		if [[ "$os_type" == "sles" ]]; then
			chown -R "$grid_user":oinstall /home/$grid_user/
		fi
		if ((os_version >= 8 && gi_version == 11)); then
			if check_file /etc/profile.d/which2.sh; then
				write_file "N" "/home/$grid_user/$profile_name" "unset -f \$(env | grep BASH_FUNC | sed 's/BASH_FUNC_\([^%]*\).*/\1/')"
			fi
		fi
		color_printf blue "查看 $grid_user 用户环境变量：/home/$grid_user/$profile_name"
		grep -v "^\s*\(#\|$\)" /home/$grid_user/"$profile_name"
		chown -R "$grid_user":oinstall "/home/$grid_user/"
	fi
}

#==============================================================#
#                    RAC：时间同步 / DNS / ASM 磁盘              #
#==============================================================#
function conf_ntp() {
	case "$os_version" in
	6 | 7)
		backup_restore_file /etc/ntp.conf
		backup_restore_file /etc/sysconfig/ntpd
		write_file "N" "/etc/ntp.conf" "# OracleBegin
tos maxdist 30
tinker panic 0"
		sed -i '/^server/d' /etc/ntp.conf
		write_file "N" "/etc/ntp.conf" "server $timeserver_ip iburst"
		touch /var/run/ntpd.pid
		write_file "Y" "/etc/sysconfig/ntpd" "# OracleBegin
OPTIONS=\"-g -x -p /var/run/ntpd.pid\"
SYNC_HWCLOCK=yes"
		;;
	*)
		backup_restore_file /etc/chrony.conf
		sed -i '/^server/d;/^pool/d' /etc/chrony.conf
		write_file "N" "/etc/chrony.conf" "# OracleBegin
server $timeserver_ip iburst"
		;;
	esac
}
function conf_timesync() {
	log_print "配置时间同步"
	if [[ "$os_version" =~ ^(6|7)$ ]]; then
		install_package "ntp"
		conf_ntp
		service ntpd restart >/dev/null 2>&1 || systemctl restart ntpd >/dev/null 2>&1
		ntpq -p
	else
		install_package "chrony"
		conf_ntp
		systemctl restart chronyd >/dev/null 2>&1
		chronyc sources
	fi
}
function conf_dns() {
	log_print "配置 DNS 解析"
	if ! rpm -q bind >/dev/null; then
		install_package "bind-libs" "bind" "bind-utils"
	fi
	write_file "Y" "/etc/resolv.conf" "search $dns_name
nameserver $dns_ip
options rotate
options timeout:2
options attempts:5"
	if nslookup "$scan_name"."$dns_name"; then
		color_printf green "DNS 配置成功！域名解析正常！"
	else
		color_printf yellow "DNS 配置成功！但域名无法正常解析，请检查网络连接或者 DNS 设置！"
	fi
}
function conf_asmdisk() {
	local uuid=$1 symlink=$2 udev_rule
	if [[ $multipath == "Y" ]]; then
		udev_rule="KERNEL==\"dm-*\",ENV{DM_UUID}==\"$uuid\",SYMLINK+=\"$symlink\",OWNER=\"grid\",GROUP=\"asmadmin\",MODE=\"0660\""
	else
		if ((os_version == 6)); then
			udev_rule="SUBSYSTEM==\"block\", PROGRAM==\"/sbin/scsi_id -g -u -d /dev/\$name\", RESULT==\"$uuid\", SYMLINK+=\"$symlink\", OWNER=\"grid\", GROUP=\"asmadmin\", MODE=\"0660\""
		else
			udev_rule="SUBSYSTEM==\"block\", PROGRAM==\"/usr/lib/udev/scsi_id -g -u -d /dev/\$name\", RESULT==\"$uuid\", SYMLINK+=\"$symlink\", OWNER=\"grid\", GROUP=\"asmadmin\", MODE=\"0660\""
		fi
	fi
	write_file "N" "/etc/udev/rules.d/99-oracle-asmdevices.rules" "$udev_rule"
}
function conf_asm() {
	rm_file /etc/udev/rules.d/99-oracle-asmdevices.rules
	if [[ $multipath == "Y" ]]; then
		if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
			install_package "multipath-tools" "multipath-tools-boot"
		elif [[ "$os_type" == "openEuler" ]]; then
			install_package "multipath-tools"
		else
			install_package "device-mapper-multipath"
		fi
		log_print "配置 multipath 多路径和 UDEV 绑盘"
		mpathconf --enable --with_multipathd y >/dev/null 2>&1
		case "$os_version" in
		"6") chkconfig multipathd.service on >/dev/null 2>&1 ;;
		*) systemctl enable multipathd.service >/dev/null 2>&1 ;;
		esac
		backup_restore_file /etc/multipath.conf
		write_file "Y" "/etc/multipath.conf" "# OracleBegin
defaults {
  user_friendly_names yes
}

blacklist {
  devnode \"^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*\"
  devnode \"^asm/*\"
  devnode \"ofsctl\"
}

multipaths {"
	fi
	declare -A DISK_INFOS=(
		["ocr"]="$ocr_disk_wwid"
		["data"]="$data_disk_wwid"
		["arch"]="$arch_disk_wwid"
	)
	for NAME in "${!DISK_INFOS[@]}"; do
		local WWID_LIST=${DISK_INFOS[$NAME]}
		local asm_disks="${NAME}disk"
		if [[ -n $WWID_LIST ]]; then
			IFS=',' read -ra WWIDS <<<"$WWID_LIST"
			for ((i = 0; i < ${#WWIDS[@]}; i++)); do
				local WID="${WWIDS[i]}"
				local NUM
				((NUM = i + 1))
				local ALIAS=asm_${NAME}_$NUM
				local WWID=$WID
				if [[ $multipath == "Y" ]]; then
					WWID=mpath-$WID
					write_file "N" "/etc/multipath.conf" "multipath {
wwid $WID
alias $ALIAS
}"
				fi
				local ALIAS_STR=/dev/$ALIAS
				conf_asmdisk "$WWID" "$ALIAS"
				eval "${asm_disks}=\"\${${asm_disks}}${ALIAS_STR},\""
			done
		fi
		eval "${asm_disks}=\${${asm_disks}%?}"
	done
	if [[ $multipath == "Y" ]]; then
		write_file "N" "/etc/multipath.conf" "}"
		if [[ $virtualbox =~ ^[yY] ]]; then
			sed -i 's/1ATA_//' /etc/multipath.conf
			sed -i 's/1ATA_//' /etc/udev/rules.d/99-oracle-asmdevices.rules
		fi
		case "$os_version" in
		"6") service multipathd restart >/dev/null 2>&1 ;;
		*) systemctl restart multipathd >/dev/null 2>&1 ;;
		esac
		color_printf blue "检查 Mulltipath 多路径情况："
		while true; do
			if multipath -ll >>"$oracleinstalllog" 2>&1; then
				break
			fi
			sleep 5s
		done
	fi
	{
		echo
		color_printf blue "UDEV 配置信息："
		cat /etc/udev/rules.d/99-oracle-asmdevices.rules
		echo
	} >>"$oracleinstalllog"
	while true; do
		if ((os_version == 6)); then
			start_udev >/dev/null 2>&1
		else
			udevadm control --reload-rules >/dev/null 2>&1
			udevadm trigger --type=devices --action=change >/dev/null 2>&1
		fi
		sleep 5s
		if [[ $(find /dev -name "asm*" 2>/dev/null) ]]; then
			{
				color_printf blue "检查 UDEV 绑定磁盘情况："
				ls -lcm /dev/asm_*
				echo
				color_printf blue "UDEV 配置完成！"
			} >>"$oracleinstalllog"
			break
		fi
	done
}

#==============================================================#
#                             主流程                            #
#==============================================================#
function main() {
	logo_print
	# 1. 参数解析（无参数时直接复用状态文件，便于单独重跑本阶段）
	if [[ $# -gt 0 ]]; then
		accept_para "$@"
		get_os_info
	else
		load_state || color_printf red "未检测到状态文件 $STATE_FILE，且未传入任何参数，请先带参数执行本脚本或使用 run_all.sh！"
		get_os_info
	fi

	if ((node_num == 1)); then
		pre_para_check
		if [[ -z "$oracle_install_mode" ]]; then
			select_db_options
		fi
		# 旧环境检测（本脚本此前已跑过阶段一时跳过，便于修复问题后重复执行）
		if [[ $STAGE1_DONE != "Y" ]]; then
			if getent passwd "$oracle_user" >/dev/null 2>&1 && check_file "$env_base_dir"; then
				clean_old_envir
				echo
				exit 1
			fi
		fi
		check_oracle_compatibility
		# 获取共享磁盘 WWID（单机 ASM / RAC）
		if [[ "$oracle_install_mode" =~ ^(rac|standalone)$ ]]; then
			conf_disk_wwid
		fi
		check_os_version
		install_time_record "start"
		color_printf blue "正在进行安装前检查，请稍等......"
	fi

	# 2. 参数加工（含软件源配置、安装包校验、主节点必传参数校验）
	handle_para

	# 3. OS 配置主流程
	execute_and_log "正在获取操作系统信息" print_sysinfo
	execute_and_log "正在安装依赖包" pkg_install
	adapt_os_version
	if ((swap_count > 40)); then
		execute_and_log "正在配置 Swap" conf_swap
	fi
	if { type firewalld || type ufw || type iptables; } >/dev/null 2>&1; then
		execute_and_log "正在禁用防火墙" disable_firewall
	fi
	if type getenforce >/dev/null 2>&1 && check_file /etc/selinux/config; then
		execute_and_log "正在禁用 selinux" disable_selinux
	fi
	if [[ $os_type != "sles" ]]; then
		if check_file /etc/sysconfig/network; then
			execute_and_log "正在配置 nsyctl" conf_nsysctl
		fi
	fi
	execute_and_log "正在配置主机名和 hosts 文件" conf_hostname
	conf_hosts
	execute_and_log "正在创建用户和组" create_users_groups
	execute_and_log "正在创建安装目录" create_dir
	if type avahi-daemon >/dev/null 2>&1; then
		execute_and_log "正在配置 Avahi-daemon 服务" conf_avahi
	fi
	execute_and_log "正在配置透明大页 && NUMA && 磁盘 IO 调度器" conf_grub
	execute_and_log "正在配置操作系统参数 sysctl" conf_sysctl
	if ((os_version >= 7)); then
		if [[ $os_type == "sles" ]] && ((os_version >= 9)); then
			logind_file="/usr/lib/systemd/logind.conf"
		else
			if ((os_version >= 10)); then
				logind_file="/usr/lib/systemd/logind.conf"
			else
				logind_file="/etc/systemd/logind.conf"
			fi
		fi
		if grep -q "RemoveIPC=" $logind_file; then
			execute_and_log "正在配置 RemoveIPC" conf_ipc
		fi
	fi
	execute_and_log "正在配置用户限制 limit" conf_limits
	execute_and_log "正在配置 shm 目录" conf_shm
	if ls "$software_dir"/rlwrap-*.gz >/dev/null 2>&1; then
		if ! type rlwrap >/dev/null 2>&1; then
			execute_and_log "正在安装 rlwrap 插件" install_rlwrap
		fi
	fi
	execute_and_log "正在配置用户环境变量" conf_profile

	# 4. RAC 模式额外准备工作（仅主节点调度）
	if ((node_num == 1)) && [[ "$oracle_install_mode" == "rac" ]]; then
		if [[ $timeserver_ip ]]; then
			execute_and_log "正在配置时间同步" conf_timesync
		fi
		if [[ $dns == "Y" ]]; then
			execute_and_log "正在配置 DNS 解析" conf_dns
		fi
		if [[ $asm_disk_conf == "Y" ]]; then
			conf_asm
		fi
		execute_and_log "正在配置 RAC 其他节点信息" other_node_shell
		execute_and_log "正在配置 RAC 所有节点互信" rac_ssh
	elif [[ "$oracle_install_mode" == "standalone" ]]; then
		if [[ $asm_disk_conf == "Y" ]]; then
			conf_asm
		fi
	fi

	# 5. 保存状态
	mark_stage_done 1
	color_printf green "阶段一（OS 配置）执行完成，状态已写入：$STATE_FILE"
	color_printf green "下一步：sh $SCRIPT_DIR/2_software_install.sh"
}

main "$@" | tee -a "$oracleprintlog"
