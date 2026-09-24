#!/usr/bin/env bash
#===============================================================
# lib/os_adapt.sh —— 操作系统探测、国产化/非认证 OS 适配、软件源配置
# 依赖：lib/common.sh、lib/state.sh
#===============================================================

#==============================================================#
#                         获取操作系统信息                        #
#==============================================================#
function get_os_info() {
	local os_file
	libc_version=$(ldd --version | head -n 1 | awk '{print $NF}' | cut -d '.' -f 2)
	cpu_type=$(uname -m)
	if [[ -e /etc/os-release ]]; then
		os_type=$(grep -oP '^ID="?(\K[^"]+|[^"]+$)' /etc/os-release)
		pretty_name=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
	else
		os_file=$(if [[ -f "/etc/system-release" ]]; then echo /etc/system-release; else echo /etc/redhat-release; fi)
		os_type=$(grep -oP '^[A-Za-z]+' "$os_file")
		pretty_name=$(cat /etc/system-release)
	fi
	if ((libc_version >= 12 && libc_version <= 16)); then
		os_version=6
	elif ((libc_version >= 17 && libc_version <= 27)); then
		os_version=7
	elif ((libc_version >= 28 && libc_version <= 33)); then
		os_version=8
	elif ((libc_version >= 34 && libc_version <= 38)); then
		os_version=9
	elif ((libc_version >= 39)); then
		os_version=10
	else
		color_printf red "当前操作系统版本 [ $pretty_name ] 不在脚本支持列表中，如有需要请联系开发者适配！"
	fi
	# 校验 CPU 类型是否适配 19C ARM，需要特性：atomics
	if [[ "$cpu_type" == "aarch64" ]]; then
		if ! grep -qm 1 -oP 'Features\s+:\s+\K.*\batomics\b' /proc/cpuinfo; then
			color_printf red "当前主机 CPU 芯片不适配 Oracle 19C ARM 安装！"
		fi
	fi
	# 部分系统只能配置网络软件源
	if is_in_list "$os_type" "${net_os_list[@]}"; then
		net_repo=Y
		local_repo=N
	fi
	# 适配 UOS 各版本
	if [[ "$os_type" =~ ^(uos|UOS)$ ]]; then
		uos_edition=$(grep -oP '^EditionName="?(\K[^"]+|[^"]+$)' /etc/os-version)
		if [[ "$uos_edition" =~ ^(a|c)$ ]]; then
			os_type=uos
		elif [[ "$uos_edition" == "e" ]]; then
			os_type=openEuler
		elif [[ "$uos_edition" == "d" ]]; then
			os_type=debian
		fi
	fi
	adapt_so_path
	conf_os
}

# 系统库搜索路径赋值函数
function adapt_so_path() {
	case "$os_type" in
	"debian" | "ubuntu" | "Deepin")
		a_path=/usr/lib/${cpu_type}-linux-gnu
		so_path=/lib/${cpu_type}-linux-gnu
		;;
	*)
		a_path=/usr/lib64
		so_path=/usr/lib64
		;;
	esac
}

#==============================================================#
#                      处理系统默认配置                          #
#==============================================================#
function conf_os() {
	# 避免 Linux 主机提示注册
	[[ -e /etc/yum/pluginconf.d/subscription-manager.conf ]] && sed -i 's/enabled=1/enabled=0/' /etc/yum/pluginconf.d/subscription-manager.conf
	[[ -e /etc/yum/pluginconf.d/debuginfo-install.conf ]] && sed -i 's/enabled=1/enabled=0/' /etc/yum/pluginconf.d/debuginfo-install.conf
	# 切换用户时不显示 Last Login 信息
	sed -i 's/^session\+[[:space:]]\+include[[:space:]]\+postlogin/#&/g' /etc/pam.d/su
	# 去除密码复杂度设置（防止简单密码不符合复杂度配置导致互信失败）
	case "$os_type" in
	"sles" | "opensuse-leap" | "opensuse-tumbleweed")
		sed -i 's/^password\+[[:space:]]\+requisite[[:space:]]\+pam_cracklib.so/#&/g' /etc/pam.d/common-password
		sed -i '/^password.*pam_unix\.so/s/use_authtok //' /etc/pam.d/common-password
		;;
	"uos")
		sed -i 's/^password    requisite     pam_deepin_pw_check.so try_first_pass local_users_only retry=1 enforce_for_root authtok_type=/#&/' /etc/pam.d/system-auth
		sed -i 's/use_authtok$//' /etc/pam.d/system-auth
		;;
	"kylin" | "openEuler" | "neokylin")
		sed -i 's/^password\+[[:space:]]\+requisite[[:space:]]\+pam_pwquality.so/#&/g' /etc/pam.d/system-auth
		sed -i 's/use_authtok$//' /etc/pam.d/system-auth
		;;
	esac
	# 处理 egrep 告警问题
	local target_line="echo \"\$cmd: warning: \$cmd is obsolescent; using grep -E\" >&2"
	if check_file /usr/bin/egrep; then
		if grep -q -F "$target_line" /usr/bin/egrep; then
			sed -i "/$target_line/s/^/#/" /usr/bin/egrep
		fi
	fi
	if check_file /bin/egrep; then
		if grep -q -F "$target_line" /bin/egrep; then
			sed -i "/$target_line/s/^/#/" /bin/egrep
		fi
	fi
	# 获取 profile 名称
	if [[ "$os_type" =~ ^(sles|opensuse-leap|opensuse-tumbleweed|ubuntu|debian|Deepin)$ ]]; then
		profile_name=.profile
	else
		profile_name=.bash_profile
	fi
	# 适配 deb 系统缺少 rpm 问题
	if [[ "$os_type" =~ ^(ubuntu|debian|Deepin|arch)$ ]]; then
		write_file "Y" "/usr/bin/rpm" "#!/bin/bash
case \"\$2\" in
\"sles-release\")
  echo \"Not installed\"
  exit 1
  ;;
\"/sbin/init\")
  echo \"systemd-219-78.el7.x86_64\"
  exit 0
  ;;
*)
  echo \"test\"
  exit 0
  ;;
esac"
		chmod +x /usr/bin/rpm
	fi
}

#==============================================================#
#                        适配国产/非认证系统                       #
#==============================================================#
function create_libpthreada() {
	/bin/mkdir -p /usr/lib64
	if ! check_file /usr/lib64/libpthread_nonshared.a; then
		ar cr /usr/lib64/libpthread_nonshared.a >/dev/null 2>&1
		chmod a+rx /usr/lib64/libpthread_nonshared.a
	fi
}
function ar_libc_nonshareda() {
	local base64_string
	if [[ $cpu_type == "aarch64" ]]; then
		base64_string='/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Mf/CMZdADMcyt3f9REpe7Mql4Z72aQIt6Fkqj2Aq3SG
JjDLcH6dOLVuP818vA+C+aczpNGBpgE06wvrW45stoi4Z5iGhOHrm4sTBVpuZwov9TVD6PBSlvGb
pailsXIFMOU3h/eYiYEc7h9NkzplDHOsQFxwmD/RmfdSG/WTUmguftOCt85HXW+5KNxKeBK54I1F
rFiH7Z6eoAivlTM0VchNtfKT8CknW3GbG6YS1RqpywczbnggQW4W8tQGruI/PcnZfttd1e/+MzVM
89w8BeEAHCTdBJ2syEJ55kafLFnN681ogUuDA5AE6F+cz88lHSz9J0STAAcZQNH1MMYKtv1kNZ9Z
rkj7aFr6lcrgpRJvk0ResulNroK46JM52sI1zg3ii/lxS/vjYz8W5G12FvNPmotZj9atz5be8TK4
EGF3VDDi2TYfzqV4zue/2Q4NXAcRtDV4BNkKnJG9muXHhKiVASJiohYCv9CJCIv2j0wtBqXgMJng
heKO3ptYP7gv5E76wg9iTkLgQvwanULVmn18KVqc422MM6VTzl3eUc0YjPV64lEsL3+mpNCa+vUl
8Dz0B90eOZztQmk58xZqSmAc8cKgCBFM3oWJYbVPud+bHltzYxEWUI+7TtV5+wFrcQh2xrb21JZw
VV21g1qtcmnE+3qY9RNXgfbqFdynABQ4vuIie4q/XQKOerD5CspVF0AhztL9vlWgg+fMO/I56yCX
8k1z/3MXNkpOUYATuU99U6ASXcTmHEZ9WblcIJx3YgnoqSXphiwpJDbiZ/dBF0K3n+wXJrCayXWb
z/Wj7BsXYTfGga1vYGyECRTj/jiJ0/tlN9J7MR0m3aS5IJ8duuuMjByWa4qDLtE+UQCpbolnoy4U
l1JchXAoxZGGOks1nJfF//uuhlkhgvwP/hFknPqt7jZAAWQphjDcVneTwLFPZC4k4OxdK1yVNPud
Chcz27uay+NOQ+GKF5hVTL6DLvIt/YSOiYhhL3u4srXTZETgIZOVaxXUbLwd9KDPM1jv2wpgkmXt
S5wkLVQXSiQ4y7qAdEltD0+g59WQZKLcfoWu9kfx16JfCZiyFMbJvSM/U1szMHYCMBt/ZHbiCabN
XkPmNsuSaDpUYeuNKurVm+0f8gMyY6Q9mCEXz1jA0nbBzAXVo04Iih3p80B1rvOhUnnT8Ml3zZYz
gI0rllX2xhigD+bIzJhpeiM0DzKC/sQiJ0nM8crgB1NR46ItjXBz0Ade1PChMM7rFLah/vC16o7t
O6iFJg5sWSpGFRi+KdrZat2klTNqsDjrfz1AXqFKfnGRelma5cfSO99cLDauiL1cYqHJfVBvEeUL
uwAJJlFXrWSyAxK3UPmWyPIK+wsCNqKcmqnh3woz/gTs/sVURc36PXRytXqW+wQqIKCQJu3T+Ixw
Fhti9SuGiEmeVmjQPwVOVpBW16ozX099mXw89f2WBups3MfTk1YJZtgdnCVeolZi8L2nzvDaeABZ
A1VjFgNCRni0IMOd3JD3p3YIevm6L//VqyOHf+P8J5wFNPR7AbtTq4o8dLxAz0YXqhjPETFStpMN
HetI/BhFzxSZuLcHzKCq5jvpX1TfL8mDavDuVjliEL27uCTSmDZGlihAS8GSL7zhycyJ8db5Up8d
Thf1ca4M7OxHKJ3/D7j0kg2AaayHDuflUiJJGRmh+XnuePGJmK809EmI0jsmDZ8UdjMRlflP1MMv
TztwRB7JjicM9iyKGlATtx7e7iOSqrdolBZt1juRLOXsDrdaXVoav5KMqU8At4fSHs91AQgiSDo0
85IVUngLVb26VIsWA+QWItAu17s2k9R7608Nh0fDnCrPQX1nuM9FGJFFOYMWHc2t4vasoBQcSK/j
oZarmJxMy7o2+nS6STqU6WieTfhGSnFxwqKZLRUEfc1t+uUyelp+BRmoB6LP67vS1rIlIGRRZSMK
x3opa+G1U0tiSeTBt4Wk/vA6d4Gq6MszDGj8vt5rdJcaK3FdgwF/sa7Mhsr3nJ5XKrRvJQ04tdpu
DrhaJpn1mDLcWv4lUSxWG4VfBIfJnlupGPRrNZVjmyxZtvuhpPIWkwb0opBLAgnp1ueLmmBC9CpL
JaNc852qF7VBKI6UNKdMVovqyBO/DLMfGMEj6xouEOIWqXF/frO2ytdJfW0BEwUjvluK2xbBCBww
o/5WJIVn0zRw0wVnktxSRspbdYL4WDDlnqse0ibwo7lLnJiC0CaluYvouTvxfuSNwS6EjJpjJjin
u58cY0L2Z04fGHeCVKfkufSXjzby5KRIR/ZO5NCX5wo39SJsamrgA5QzAnEAIM5lJKcq0RkR5wTm
6K/qeNcJpz0qKe5sHxuF+hO59ayMlllUUCOry1fT/Lhz8nceAJauIrIVDaFZfwPRHcpH+ehSkJCG
sS3waiwn/4k90HJXynLxOgkPjbtiXatU/tyrwX/BXceRJIUIQgnv+XcLL0S3sHqrY35UWeo3PENQ
JoxC8Jq0jrYhdDE8MXgUrJpbEXtagTL7IBQ5xvl7CacwJ8/UclUXLU5/Bvzs9wsHVe36oJI0oZxP
Mg1azJly9rSykO70Ga5OC2JLLE9cW+gInssifTIcmHGoiqOtmzqMX7udo1TpwV9GUc3eUAr9D5Ck
4bYJncIJB1HisH6Gyh+An6jFDh8utoH+6z392WP3C1LZ0k8rx6i0jgDKjMNhZh2P2XWY+amZmp7n
CXxpNaUO6JspQKUkhTjWrlLIaofzWQaTB8sKzMIYsCx+2ymBcL2OsCQvaRcqiXRIScl6g96objAA
15JIjMNoyzMbdFd/+hy2bxyPRV7uwkr6QOdYHYCYTC0LndLoaylRxcKjBNbi88mf2cdqnDPusRLv
BIB3/2IioRma9rMOc+O1z4HzuEJWRPwCO9L91s8JHSDW4tBM8mBgqHwhM4McVo8h7sPt8/wTlZav
aVI8cABjfq+slqqd96hKhue2QGqhne+UWsbRvGEexKWRrTifeCqN6okMpp8a4kUtLkjEte8PAAAA
7CA44DTdJK8AAeIRgJADAG6NPv6xxGf7AgAAAAAEWVo='
		stat_array=(
			"$software_dir/fstat64.oS"
			"$software_dir/lstat64.oS"
			"$software_dir/lstat.oS"
			"$software_dir/stat64.oS"
			"$software_dir/fstatat64.oS"
			"$software_dir/mknod.oS"
		)
	else
		base64_string='/Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Cf/Af1dADmdCEcK2iXKM9hlSqnJgOklzkj59aGHLFqo
DWNfS87u1zfN2ZEKKUt1dO9GLhDuvHtQQqc4ljXoBmNoK5BLs+vNuOEwa3Hm/IJ9OFH2vxiu+g/a
e98u5sOg1WX22b+A/pm+zW843A9s8M6wHYfjKqp13DxrDtyB/H0Mju2tV8oZ+8mOM4xSPfnM7keT
O69cMufEh5jKsCOL8n2mwAadM/X7/susSp+ThkmiKFzvwpL6pSBIZAZ9NnhyGt+Mb+3z/oh0v/QE
Q9/Sebsd+kdAIYxrlnyR6QwA46RXUx9CUv1WlN9G/mHcK86Jp9y5OTT8/ObWzDLX9OE1y/NzHsYO
riL7LxJAoJbv5iNuakmBHTHLVcNiqcS4A+y3cJpiw+yfqr+/NjpmB/pw9UPhpmMCDX2dS35TPbTl
5mww27aAvuE7WVT25Q6gOZ7VVh7gw2pnoXlvaBH480FmOhMB+5U9mtcbMAoKyYaDhvtjKpfx8l3I
Lq6xlN76sfL3EencD4k8zC+42nLb/sjofaJADN1suSMWUPAFZWrxKaInDdfWCOy764JKBAtMPcia
2l0ltIc7jJ2RzZob591N5iwY2xjcVvQQNv2VJHM6wM3Mw8s6RIjZlP9WeXzFNhWHTl9UZ25RMKe8
DS7PiRyfdum+4wnQckYYvXeWpHSOVp9zq8ngAAAAAHfXVLs/p0kvAAGZBIBQAAAdrVmNscRn+wIA
AAAABFla'
		stat_array=(
			"$software_dir/stat-stubs.o"
		)
	fi
	for stat in "${stat_array[@]}"; do
		if ! check_file "$stat"; then
			base64_to_binary "$base64_string" "$software_dir/stat.tar.xz"
			tar -xJf "$software_dir"/stat.tar.xz -C "$software_dir" >/dev/null 2>&1
		fi
		ar r "$a_path"/libc_nonshared.a "$stat" >/dev/null 2>&1
	done
}
function do_fix_libaio() {
	local base64_string
	base64_string='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'
	if ! check_file "$software_dir"/libaio.so.1; then
		base64_to_binary "$base64_string" "$software_dir/libaio.tar.xz"
		tar -xJf "$software_dir"/libaio.tar.xz -C "$software_dir" >/dev/null 2>&1
	fi
	if ! check_file "$so_path"/libaio.so.1.original; then
		if check_file "$so_path"/libaio.so.1; then
			/bin/mv -f "$so_path"/libaio.so.1 "$so_path"/libaio.so.1.original >/dev/null 2>&1
		fi
		if check_file "$software_dir"/libaio.so.1; then
			/bin/cp -f "$software_dir"/libaio.so.1 "$so_path"/libaio.so.1 >/dev/null 2>&1
			chmod a+rx "$so_path"/libaio.so.1
		fi
	fi
}
function do_fix_libnsl() {
	if ! check_file "$a_path"/libnsl.so; then
		if check_file "$so_path"/libnsl.so.2; then
			create_symlink "N" "$so_path"/libnsl.so.2 "$a_path"/libnsl.so
		elif check_file "$so_path"/libnsl.so.3; then
			create_symlink "N" "$so_path"/libnsl.so.3 "$a_path"/libnsl.so
		fi
	fi
	if ! check_file "$so_path"/libnsl.so.1; then
		if check_file "$so_path"/libnsl.so.2; then
			create_symlink "N" "$so_path"/libnsl.so.2 "$so_path"/libnsl.so.1
		elif check_file "$so_path"/libnsl.so.3; then
			create_symlink "N" "$so_path"/libnsl.so.3 "$so_path"/libnsl.so.1
		fi
	fi
	if [[ $cpu_type == "aarch64" ]]; then
		if ! check_file "$so_path"/libnsl.so.2; then
			if check_file "$a_path"/libnsl.so; then
				create_symlink "N" "$so_path"/libnsl.so "$a_path"/libnsl.so.2
			fi
		fi
	fi
}
function do_fix_libcap() {
	if ! check_file "$so_path"/libcap.so; then
		create_symlink "N" "$so_path"/libcap.so.2 "$a_path"/libcap.so
	fi
	if check_file "$so_path"/libcap.so.2; then
		if ! check_file "$so_path"/libcap.so.1; then
			create_symlink "N" "$so_path"/libcap.so.2 "$so_path"/libcap.so.1
		fi
	fi
}
function do_fix_so() {
	do_fix_libnsl
	do_fix_libcap
	# 适配 11GR2 安装
	if ((db_version == 11)); then
		if [[ "$os_type" =~ ^(ubuntu|debian|Deepin)$ ]]; then
			adapt_gcc
		fi
		do_fix_libaio
	fi
	if [[ $cpu_type == "aarch64" ]]; then
		if [[ "$os_type" =~ ^(ubuntu|debian|Deepin)$ ]]; then
			adapt_gcc
		fi
	fi
}
# OpenSSH 升级到 8.x 后 GI 安装失败 INS-06006 (Doc ID 2639907.1)
function adapt_scp() {
	local scp_ver
	scp_ver=$(ssh -V 2>&1 | grep -oP 'OpenSSH_\K[0-9]+\.[0-9]+')
	handle_scp() {
		local scp_verion=$1 original_scp="/usr/bin/scp" new_content="/usr/bin/scp.original -T"
		if (($(echo "$scp_verion >= 8.7" | bc -l))); then
			new_content+=" -O"
		fi
		mv_file "$original_scp"
		write_file "Y" "$original_scp" "$new_content \$*"
		chmod 555 "$original_scp"
	}
	if (($(echo "$scp_ver >= 8.0" | bc -l))); then
		handle_scp "$scp_ver"
	fi
}
function adapt_gcc() {
	local gccbin gccver
	gccbin=$(basename "$(readlink -f /usr/bin/gcc)" | sed 's/.*-\(gcc-[0-9]*\)/\1/')
	gccver=$(basename "$(readlink -f /usr/bin/gcc)" | awk -F '-' '{print $NF}')
	if [[ "$os_type" == "arch" ]]; then
		gccbin="x86_64-pc-linux-gnu-gcc"
		gccver=100
	fi
	mv_file /usr/bin/gcc
	if (($(echo "$gccver >= 4.6  &&  $gccver < 7.0" | bc -l))); then
		write_file "Y" "/usr/bin/gcc" "#!/bin/bash
/usr/bin/$gccbin -Wl,--no-as-needed \$*"
	elif (($(echo "$gccver >= 7.0" | bc -l))); then
		write_file "Y" "/usr/bin/gcc" "#!/bin/bash
/usr/bin/$gccbin -Wl,--no-as-needed -no-pie \$*"
	fi
	chmod 755 /usr/bin/gcc
}
function add_debs_link() {
	/bin/mkdir -p /usr/lib64
	create_symlink "Y" /bin/bash /bin/sh
	if check_file /usr/bin/gawk; then
		create_symlink "N" /usr/bin/gawk /bin/awk
	else
		create_symlink "N" /usr/bin/mawk /bin/awk
	fi
	find "$a_path" -name "*.o" -exec ln -s {} /usr/lib64/ \;
	create_symlink "N" "$so_path"/libgcc_s.so.1 /usr/lib64
	create_symlink "N" "$so_path"/libstdc++.so.6 /usr/lib64/
	if ((os_version == 7)); then
		create_symlink "Y" "$a_path"/libc_nonshared.a /usr/lib64/
		create_symlink "Y" "$a_path"/libpthread_nonshared.a /usr/lib64/
	else
		create_symlink "Y" "$a_path"/libc_nonshared.a /usr/lib64/
	fi
	# Ubuntu 24 / Debian 13 缺少 libaio.so.1
	if ((os_version > 9)); then
		if ! check_file "$so_path"/libaio.so.1; then
			if check_file "$so_path"/libaio.so.1t64; then
				create_symlink "Y" "$so_path"/libaio.so.1t64 "$so_path"/libaio.so.1
			fi
		fi
	fi
}
function undo_adapt() {
	case $os_type in
	"ubuntu" | "debian" | "Deepin" | "arch")
		if check_file /usr/bin/gcc.original; then
			/bin/mv -f /usr/bin/gcc.original /usr/bin/gcc
		fi
		;;
	esac
	if check_file "$so_path"/libaio.so.1.original; then
		/bin/mv -f "$so_path"/libaio.so.1.original "$so_path"/libaio.so.1
	fi
}
function adapt_os_version() {
	if ((os_version >= 8)); then
		create_libpthreada
		if ((os_version >= 9)); then
			if check_file "$a_path"/libc_nonshared.a; then
				/bin/cp -f "$a_path"/libc_nonshared.a "$a_path"/libc_nonshared.a.original
				ar_libc_nonshareda
			else
				color_printf red "必需文件 $a_path/libc_nonshared.a 文件未找到，请检查原因！"
			fi
		fi
	fi
	do_fix_so
	case $os_type in
	"anolis")
		if ((os_version == 7)); then
			if ((db_version != 11)); then
				if check_file "$software_dir"/libc-2.17.so; then
					/bin/mv -f "$software_dir"/libc-2.17.so /usr/lib64/libc-2.17.so
					chmod 755 /usr/lib64/libc-2.17.so
				fi
			fi
		fi
		;;
	"ubuntu" | "debian" | "Deepin")
		add_debs_link
		;;
	esac
	# ARM 适配
	if [[ "$cpu_type" == "aarch64" ]]; then
		write_file "Y" /etc/oracle-release "Oracle Linux Server release 8"
		chmod 644 /etc/oracle-release
	fi
	if [[ $oracle_install_mode == "rac" ]]; then
		if ((db_version < 26)); then
			adapt_scp
		fi
	fi
}

#==============================================================#
#                        兼容性 / 版本检查                       #
#==============================================================#
function check_oracle_compatibility() {
	check_version_compatibility() {
		local supported_versions="$1"
		if [[ "$os_version" =~ ^($supported_versions)$ ]]; then
			oracle_os_flag=Y
		else
			oracle_os_flag=N
		fi
	}
	check_unscertified_os() {
		if is_in_list "$os_type" "${unscertified_os_list[@]}"; then
			oracle_os_flag="N"
		fi
	}
	check_neokylin_os() {
		if [[ "$os_type" == "neokylin" ]]; then
			if ((db_version == 11 && os_version == 7)); then
				oracle_os_flag="Y"
			else
				oracle_os_flag="N"
			fi
		fi
	}
	check_oracle_certified_os() {
		if is_in_list "$os_type" "${oracle_certified_os_list[@]}"; then
			if [[ $cpu_type == "aarch64" ]]; then
				if [[ "$os_type" == "ol" ]]; then
					check_version_compatibility "8"
				else
					oracle_os_flag="N"
				fi
			else
				if [[ "$os_type" == "sles" ]]; then
					case "$db_version" in
					11) check_version_compatibility "7" ;;
					12 | 19) check_version_compatibility "7|8" ;;
					21) check_version_compatibility "8" ;;
					26) oracle_os_flag="N" ;;
					esac
				else
					case "$db_version" in
					11 | 12) check_version_compatibility "6|7|8" ;;
					19) check_version_compatibility "7|8|9" ;;
					21) check_version_compatibility "7|8" ;;
					26) check_version_compatibility "8|9" ;;
					esac
				fi
			fi
		fi
	}
	check_unscertified_os
	check_neokylin_os
	check_oracle_certified_os
	if [[ "$oracle_os_flag" == "N" ]]; then
		color_printf purple "!!! 免责声明：当前操作系统版本是 [ $pretty_name ] 不在 Oracle 官方支持列表，本脚本只负责安装，请确认是否继续安装 (Y/N): [Y] "
		echo
	elif [[ "$oracle_os_flag" == "NONE" ]]; then
		color_printf red "当前操作系统版本是 [ $pretty_name ] 不在脚本支持列表中，如有需要请联系开发者适配！"
	fi
}
function check_os_version() {
	case "$os_type" in
	"anolis")
		if ((os_version == 7)); then
			if ((db_version != 11)); then
				if [[ $(md5sum /usr/lib64/libc-2.17.so | awk '{print $1}') != "391da37c6f4a98f1103ea72a42490fbb" ]]; then
					if ! check_file "$software_dir"/libc-2.17.so; then
						color_printf red "本脚本在 anolis 7.9 安装 Oracle 12C/19C/21/26 需要上传 libc-2.17.so 到 $software_dir 目录下！
              下载地址：https://www.modb.pro/doc/129426"
					fi
				fi
			fi
		fi
		;;
	"kylin")
		if ((gi_version == 11)); then
			if ! ls "$software_dir"/libnsl-*.rpm >/dev/null 2>&1; then
				color_printf red "本脚本安装 Oracle 11GR2 Grid 必须上传 libnsl 软件包到 $software_dir 目录下！
            银河麒麟 V10 libnsl 包下载地址：https://update.cs2c.com.cn/NS/V10/"
			fi
		fi
		;;
	esac
	if ((os_version == 6)); then
		if [[ "$gi_version" =~ ^(19|21|26)$ || "$db_version" =~ ^(19|21|26)$ ]]; then
			color_printf red "Oracle 19C/21C/26ai 官方不支持 Linux 6 版本！"
		fi
	fi
	if ((os_version == 7)); then
		if ((gi_version == 26 || db_version == 26)); then
			color_printf red "Oracle 26ai 官方不支持 Linux 7 版本！"
		fi
	fi
	if [[ "$cpu_type" == "aarch64" ]]; then
		if ((os_version < 8)); then
			color_printf red "本脚本暂不支持 [ $pretty_name ] 安装 Oracle 19C ARM 数据库！"
		fi
		if ((db_version != 19)); then
			color_printf red "官方目前只支持在 Linux ARM 上安装 Orale 19C 版本！"
		fi
	fi
}

#==============================================================#
#                            软件源配置                          #
#==============================================================#
function check_iso() {
	mountPath=$(mount | awk '/iso9660/ && !/(deleted)/ && !/run\/media/ && !/\/media/ {print $3}')
	if [[ $(echo "$mountPath" | wc -l) -gt 1 ]]; then
		echo "$mountPath"
		color_printf red "当前主机存在多个 ISO 镜像源，脚本无法判断，请务必只保留一个！"
	fi
	if [[ -z $mountPath ]]; then
		if mount /dev/sr0 /mnt >/dev/null 2>&1; then
			mountPath=/mnt
		else
			color_printf red "本地软件源配置需要挂载 ISO 镜像源，建议挂载 Everything ISO 源！"
		fi
	fi
}
function backup_repos() {
	local bak_type="$1" source_repo="$2" backup_repo="$3"
	/bin/mkdir -p "$backup_repo" >/dev/null 2>&1
	if [[ "$bak_type" == "d" ]]; then
		find "$source_repo" -mindepth 1 -maxdepth 1 -type f -exec /bin/mv -f {} "$backup_repo" \; >/dev/null 2>&1
	elif [[ "$bak_type" == "f" ]]; then
		/bin/mv -f "$source_repo" "$backup_repo" >/dev/null 2>&1
	fi
}
function conf_local_repository() {
	log_print "配置本地软件源"
	conf_rhel7_repository() {
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/local.repo" "[server]
name=server
baseurl=file://$mountPath
enabled=1
gpgcheck=0"
		cat /etc/yum.repos.d/local.repo
	}
	conf_rhel8_repository() {
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/local.repo" "[BaseOS]
name=BaseOS
baseurl=file://$mountPath/BaseOS
enabled=1
gpgcheck=0
[AppStream]
name=AppStream
baseurl=file://$mountPath/AppStream
enabled=1
gpgcheck=0"
		cat /etc/yum.repos.d/local.repo
	}
	conf_anolis23_repository() {
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/local.repo" "[server]
name=os
baseurl=file://$mountPath/os
enabled=1
gpgcheck=0"
		cat /etc/yum.repos.d/local.repo
	}
	conf_uos_e_repository() {
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/local.repo" "[BaseOS]
name=BaseOS
baseurl=file://$mountPath
enabled=1
gpgcheck=0
[AppStream]
name=AppStream
baseurl=file://$mountPath/AppStream
enabled=1
gpgcheck=0"
		cat /etc/yum.repos.d/local.repo
	}
	conf_uos_d_repository() {
		local uos_codename
		uos_codename=$(grep -oP '^VERSION_CODENAME="?(\K[^"]+|[^"]+$)' /etc/os-release)
		backup_repos "f" /etc/apt/sources.list /etc/apt/bak
		write_file "Y" "/etc/apt/sources.list" "deb [trusted=yes] file://$mountPath $uos_codename main"
		apt-get update >/dev/null 2>&1
		cat /etc/apt/sources.list
	}
	conf_rhel_repository() {
		if ((os_version >= 8)); then
			conf_rhel8_repository
		else
			conf_rhel7_repository
		fi
	}
	conf_openeuler_repository() {
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/local.repo" "[openEuler]
name=openeuler
baseurl=file://$mountPath
enabled=1
gpgcheck=1
gpgkey=file://$mountPath/RPM-GPG-KEY-openEuler"
		cat /etc/yum.repos.d/local.repo
	}
	conf_sles_repository() {
		backup_repos "d" "/etc/zypp/repos.d/" "/etc/zypp/repos.d/bak"
		if [[ "$os_type" =~ ^(opensuse-leap|opensuse-tumbleweed)$ ]]; then
			zypper ar -f "$mountPath" opensuse
		else
			case "$os_version" in
			"7") zypper ar -f "$mountPath"/suse sles ;;
			"8" | "9")
				zypper ar -f "$mountPath"/Module-Basesystem sles
				zypper ar -f "$mountPath"/Module-Legacy sles-Legacy
				zypper ar -f "$mountPath"/Module-Development-Tools sles-Tools
				;;
			esac
		fi
	}
	if is_in_list "$os_type" "${local_os_list[@]}"; then
		case $os_type in
		"kylin" | "ningos" | "asianux" | "NFS")
			conf_rhel7_repository
			;;
		"sles" | "opensuse-leap" | "opensuse-tumbleweed")
			conf_sles_repository
			;;
		"openEuler" | "ctyunos")
			if [[ "$uos_edition" == "e" ]]; then
				conf_uos_e_repository
			else
				conf_openeuler_repository
			fi
			;;
		*)
			if [[ $os_type == "anolis" ]] && ((os_version >= 9)); then
				conf_anolis23_repository
			else
				conf_rhel_repository
			fi
			;;
		esac
	else
		if [[ $os_type == "debian" ]]; then
			conf_uos_d_repository
		fi
	fi
}
function conf_network_repository() {
	log_print "配置网络软件源"
	conf_fedora_repository() {
		local releasever
		releasever=$(grep -oP '^VERSION_ID="?(\K[^"]+|[^"]+$)' /etc/os-release)
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/fedora.repo" "[fedora]
name=Fedora
failovermethod=priority
baseurl=http://mirrors.tuna.tsinghua.edu.cn/fedora/releases/$releasever/Everything/$cpu_type/os/
metadata_expire=28d
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$cpu_type
skip_if_unavailable=False"
		cat /etc/yum.repos.d/fedora.repo
	}
	conf_euleros_repository() {
		local euler_codename
		euler_codename=$(grep -oP '(?<=release )\d+\.' /etc/euleros-release)$(grep -oP '(?<=SP)\d+' /etc/euleros-release)
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/EulerOS-base.repo" "[base]
name=EulerOS
baseurl=http://mirrors.huaweicloud.com/euler/$euler_codename/os/x86_64/
enabled=1
gpgcheck=1
gpgkey=http://mirrors.huaweicloud.com/euler/$euler_codename/os/RPM-GPG-KEY-EulerOS"
		cat /etc/yum.repos.d/EulerOS-base.repo
	}
	conf_hce_repository() {
		backup_repos "d" "/etc/yum.repos.d/" "/etc/yum.repos.d/bak"
		write_file "Y" "/etc/yum.repos.d/HCE2-base.repo" "[base]
name=HCE-2.0 base
#ARM-Repo
baseurl=https://repo.huaweicloud.com/hce/2.0/os/aarch64/
enabled=1
gpgcheck=1
gpgkey=https://repo.huaweicloud.com/hce/2.0//os/RPM-GPG-KEY-HCE-2"
		cat /etc/yum.repos.d/HCE2-base.repo
	}
	conf_arch_repository() {
		backup_repos "f" /etc/pacman.d/mirrorlist /etc/pacman.d/bak
		write_file "Y" "/etc/pacman.d/mirrorlist" "Server = http://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch"
		cat /etc/pacman.d/mirrorlist
	}
	set_sources() {
		local codename=$1 extra=$2
		new_sources="deb http://mirrors.tuna.tsinghua.edu.cn/debian/ $codename main contrib non-free $extra
deb http://mirrors.tuna.tsinghua.edu.cn/debian/ ${codename}-updates main contrib non-free $extra
deb http://mirrors.tuna.tsinghua.edu.cn/debian/ ${codename}-backports main contrib non-free $extra
deb http://mirrors.tuna.tsinghua.edu.cn/debian-security/ ${codename}-security main contrib non-free $extra"
	}
	conf_deb_repository() {
		local debs_codename
		if check_file "/etc/lsb-release"; then
			debs_codename=$(grep DISTRIB_CODENAME /etc/lsb-release | cut -d '=' -f2)
		elif check_file "/etc/os-release"; then
			debs_codename=$(grep VERSION_CODENAME /etc/os-release | cut -d '=' -f2)
		fi
		backup_repos "f" /etc/apt/sources.list /etc/apt/bak
		if [[ "$os_type" == "debian" ]]; then
			if ((os_version == 7)); then
				wget http://deb.freexian.com/extended-lts/archive-key.gpg -O /tmp/elts-archive-key.gpg >/dev/null 2>&1
				/bin/mv -f /tmp/elts-archive-key.gpg /etc/apt/trusted.gpg.d/freexian-archive-extended-lts.gpg
				new_sources="deb http://mirrors4.tuna.tsinghua.edu.cn/debian-elts $debs_codename main contrib non-free"
			elif ((os_version == 8)); then
				if [[ $debs_codename == "buster" ]]; then
					new_sources="deb http://mirrors4.tuna.tsinghua.edu.cn/debian-elts $debs_codename main contrib non-free"
				else
					set_sources "$debs_codename"
				fi
			elif ((os_version > 8)); then
				set_sources "$debs_codename" "non-free-firmware"
			fi
		elif [[ "$os_type" == "ubuntu" ]]; then
			if [[ "$cpu_type" == "aarch64" ]]; then
				new_sources="deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ $debs_codename main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ ${debs_codename}-updates main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ ${debs_codename}-backports main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ ${debs_codename}-security main restricted universe multiverse"
			else
				new_sources="deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ $debs_codename main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${debs_codename}-updates main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${debs_codename}-backports main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${debs_codename}-security main restricted universe multiverse"
			fi
		elif [[ "$os_type" == "Deepin" ]]; then
			new_sources="deb https://community-packages.deepin.com/deepin/ $debs_codename main contrib non-free"
		fi
		write_file "Y" "/etc/apt/sources.list" "$new_sources"
		apt-get update >/dev/null 2>&1
		cat /etc/apt/sources.list
	}
	if is_in_list "$os_type" "${net_os_list[@]}"; then
		case $os_type in
		"fedora") conf_fedora_repository ;;
		"euleros") conf_euleros_repository ;;
		"arch") conf_arch_repository ;;
		"hce") conf_hce_repository ;;
		*) conf_deb_repository ;;
		esac
	fi
}
function conf_repo() {
	if [[ $net_repo == "Y" ]]; then
		local_repo=N
		if is_in_list "$os_type" "${local_os_list[@]}"; then
			color_printf red "本脚本暂不支持 [ $pretty_name ] 配置网络镜像源，正在适配中，请配置本地软件源或者自行配置软件源！"
		fi
		if [[ $os_type != "hce" ]]; then
			check_internet_connectivity
		fi
		execute_and_log "正在配置网络软件源" conf_network_repository
	fi
	if [[ $local_repo == "Y" ]]; then
		check_iso
		execute_and_log "正在配置本地软件源" conf_local_repository
	else
		if [[ $net_repo == "N" ]]; then
			if [[ "$os_type" =~ ^(opensuse-leap|opensuse-tumbleweed)$ ]]; then
				if ! zypper ref >/dev/null 2>&1; then
					color_printf red "当前软件源配置错误，请自行检查软件源配置！"
				fi
			else
				yum clean all >/dev/null 2>&1
				if ! yum makecache >/dev/null 2>&1; then
					color_printf red "当前软件源配置错误，请自行检查软件源配置！"
				fi
			fi
		fi
	fi
	# 适配 openSUSE
	if [[ "$os_type" =~ ^(opensuse-leap|opensuse-tumbleweed)$ ]]; then
		os_type=sles
	fi
}
