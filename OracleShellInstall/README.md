# OracleShellInstall（拆分版）

原 `OracleShellInstall.sh` 是一个 6191 行的单体脚本，全局变量与函数相互交织，改一处要通读全文。
本目录将其按**安装生命周期**拆成 4 个可独立执行的阶段脚本 + 4 个公共库，逻辑完全保留（单机 / 单机 ASM / RAC 三种模式、11g~26ai 五个版本均支持）。

## 目录结构

```
OracleShellInstall/
├── run_all.sh                 # 一键串行编排入口（推荐入口）
├── 1_os_config.sh             # 阶段一：OS 配置            5~15 分钟
├── 2_software_install.sh      # 阶段二：软件安装           15~30 分钟
├── 3_db_create.sh             # 阶段三：数据库创建         20~40 分钟
├── 4_post_config.sh           # 阶段四：后期配置           5~15 分钟
├── bundle.sh                  # 打包器：把 lib 内联进阶段脚本，产出自包含脚本
├── dist/                      # bundle.sh 产物：单文件自包含脚本，可拷走单独执行
└── lib/
    ├── common.sh              # 打印/日志/文件/校验/SQL/SSH/磁盘/软件包/收尾报告
    ├── state.sh               # 全局变量默认值 + 阶段状态持久化
    ├── os_adapt.sh            # OS 探测、国产化适配、软件源配置
    ├── args.sh                # 参数解析、前置校验、安装包识别、RAC 节点下发
    ├── grid.sh                # Grid 安装（解压/响应文件/runInstaller/ASM 磁盘组）
    └── dbsoft.sh              # Oracle 软件安装（解压/响应文件/runInstaller/补丁/监听）
```

## 四个阶段分别做什么

| 阶段 | 脚本 | 主要工作 |
|------|------|----------|
| 1 | `1_os_config.sh` | 主机名与 `/etc/hosts`、Swap、防火墙、SELinux、GRUB（关闭 THP/NUMA、IO 调度器）、17 类 `sysctl` 内核参数、`limits.conf`、`/dev/shm`、10 个标准组与 oracle/grid 用户、安装目录、离线 YUM 源、40+ 依赖包、`rlwrap`、用户环境变量。**RAC 额外**：时间同步、DNS、multipath + UDEV 绑盘、root/grid/oracle SSH 互信、其他节点脚本下发 |
| 2 | `2_software_install.sh` | 解压安装包与补丁、渲染 `oracle.rsp` / `grid.rsp`、`runInstaller` 静默安装、自动执行 `orainstRoot.sh` + `root.sh`、安装 RU/OJVM 补丁、创建监听（netca，**失败自动回退**为手工生成 `listener.ora`）。**ASM/RAC 额外**：Grid 安装 + ASM 磁盘组创建 |
| 3 | `3_db_create.sh` | DBCA 静默建库、创建 PDB、`sqlnet.ora` 配置。21c/26ai 自动强制 CDB 模式 |
| 4 | `4_post_config.sh` | 核心参数优化（SGA/PGA/游标/进程/优化器隐式参数）、**密码策略放宽**、**归档模式开启**、**PDB 自动打开触发器**、**monitor/backup 专用账户**、控制文件复用、Redo 扩容、开机自启、RMAN 备份任务、`glogin.sql`、内存大页（可选）、**安装验证** |

> 阶段四相对原脚本新增了：归档模式确认与补开、PDB 自动打开触发器、monitor/backup 专用账户、安装验证汇总。

## 状态文件机制

4 个阶段是独立进程，无法共享内存变量。阶段一结束时把「输入参数 + 中间计算结果」序列化到：

```
/soft/.oracle_install_env      # 可用 ORACLE_STATE_FILE 覆盖，权限 600
```

后续阶段 `source` 回来即可。因此支持两种用法：

```bash
# 1) 一键串跑（推荐）
sh run_all.sh -lf eth0 -n orcl -o orcl -dbv 26 -pdb pdb01 -opd Y

# 2) 分阶段执行 / 失败后单独重跑（不重复做已完成的工作）
sh 1_os_config.sh          -lf eth0 -n orcl -o orcl -dbv 26 -pdb pdb01 -opd Y
sh 2_software_install.sh   # 读取状态文件，无需再传参
sh 3_db_create.sh          # 只想重跑建库时，直接执行这一条
sh 4_post_config.sh
```

阶段脚本会校验前置阶段是否完成（`require_stage`），未完成时拒绝执行并提示。
状态文件里记录了 `STAGE1_DONE` ~ `STAGE4_DONE`，安装报告会读取它们。

## 常用示例

```bash
# 单机 Oracle 26ai（强制 CDB + 1 个 PDB），建库后做优化
sh run_all.sh -lf eth0 -n orcl -o orcl -dbv 26 -pdb pdb01 -opd Y

# 单机 19c，自定义目录与字符集
sh run_all.sh -lf eth0 -n dbserver -o orcl -dbv 19 \
              -d /u01 -ord /oradata -ard /oradata/archivelog \
              -ds AL32UTF8 -dbs 8192 -redo 1024 -opd Y

# 单机 ASM 模式
sh run_all.sh -install_mode standalone -lf eth0 -dd /dev/sdb -dbv 19 -opd Y

# RAC 两节点（仅需在主节点执行，其他节点由脚本远程下发）
sh run_all.sh -install_mode rac -lf team0 -pf eth3 -n orcl -hn orcl01,orcl02 \
              -ri 10.211.55.100,10.211.55.101 -vi 10.211.55.102,10.211.55.103 \
              -si 10.211.55.105 -rp 'Root_Passw0rd' -od /dev/sdb -dd /dev/sdc -dbv 19

# 只看系统有哪些可用 ASM 盘（不安装，打印完即退出）
sh run_all.sh -fd /dev/sda

# 仅配置操作系统
sh run_all.sh -lf eth0 -m Y

# 打开调试模式
sh run_all.sh -lf eth0 -dbv 26 -debug
```

完整参数列表见 `sh run_all.sh -h`。

## 配置文件方式（推荐）

参数多、密码含特殊字符时，命令行容易出错。可以用 `KEY=VALUE` 形式的配置文件：

```ini
# install.conf
oracle_install_mode=single
db_version=26
local_ifname=eth0
hostname=orcl
db_name=orcl
database_passwd=oracle
pdbname=pdb01
iscdb=true
optimize_db=Y
```

```bash
sh run_all.sh -c install.conf            # 全部走配置文件
sh run_all.sh -c install.conf -o oradb   # 命令行优先级更高，可覆盖配置文件
```

约束：

- 键名是脚本内部全局变量名（即 `sh run_all.sh -h` 中各参数对应的变量），不是短选项
- 只允许空行、`#` 注释和 `KEY=VALUE`；含其它 shell 语法的文件会被拒绝加载（防注入）
- 留空即使用脚本默认值，不需要把所有参数写全

配套的 Web 配置中心见同级目录 `oracle-install-ui/`，可可视化填参、实时校验并导出该文件。

## 单独部署：拷到别的机器 / 单文件执行

阶段脚本靠 `source $SCRIPT_DIR/lib/xxx.sh` 复用公共库，**单独拷一个 `.sh` 出去是不能跑的**。三种用法：

**1）整目录拷贝（推荐，最好维护）**

保持目录结构一起拷，脚本和 `lib/` 的相对位置不能变：

```bash
scp -r OracleShellInstall root@目标机:/soft_content
# 目标机上：cd /soft_content && sh run_all.sh -lf eth0 -dbv 26
```

**2）生成自包含单文件（要单独拷某个脚本时用这个）**

```bash
sh bundle.sh          # 把 lib 内联进阶段脚本，输出到 dist/
```

`dist/` 下每个文件都是自包含的（3000~4000 行），拷到目标机 `/soft` 下即可单独执行，不需要 `lib/`：

```bash
scp dist/1_os_config.sh dist/2_software_install.sh \
    dist/3_db_create.sh dist/4_post_config.sh root@目标机:/soft/
```

> `lib/common.sh` 会自动识别自己是被 `source` 还是被内联：位于 `lib/` 下时根目录取其上级目录，
> 被内联进阶段脚本时根目录就是脚本所在目录，两种布局下 `/soft` 的解析结果一致。
> 改完 `lib/` 里的内容后需要重新跑一次 `sh bundle.sh`。

**3）只拷部分文件**

至少要带上这些（缺一个就会失败）：

| 要执行 | 必须同时存在 |
|---|---|
| `1_os_config.sh` | `lib/common.sh` `lib/state.sh` `lib/os_adapt.sh` `lib/args.sh` |
| `2_software_install.sh` | 上面 4 个 + `lib/grid.sh` `lib/dbsoft.sh` |
| `3_db_create.sh` | 上面前 4 个 |
| `4_post_config.sh` | 上面前 4 个 |

### 安装包目录在哪

脚本把「脚本所在目录」当作安装包目录（`software_dir`），会去那里找 `LINUX.X64_*.zip`、
补丁包，并把日志和状态文件写在那里。所以：

- **推荐布局**：把脚本内容**直接放在 `/soft`**（`/soft/1_os_config.sh` + `/soft/lib/`），安装包也放 `/soft`，与原脚本行为完全一致。
- 如果脚本放在子目录（如 `/soft/OracleShellInstall/`）而安装包在 `/soft`，用环境变量指定：
  ```bash
  export ORACLE_SOFT_DIR=/soft
  sh /soft/OracleShellInstall/run_all.sh -lf eth0 -dbv 26
  ```
- 状态文件位置也可覆盖：`export ORACLE_STATE_FILE=/soft/.oracle_install_env`

## 原脚本函数归属对照

| 原脚本函数 | 拆分后位置 |
|-----------|-----------|
| `color_printf` / `log_print` / `execute_and_log` / 各类 `checkpara_*` / `check_file` / `write_file` / `backup_restore_file` | `lib/common.sh` |
| `run_as_oracle` / `run_as_grid` / `execute_sqlplus` / `ssh_trust` / `get_wwid` / `install_package` / `pkg_install` | `lib/common.sh` |
| `print_sysinfo` / `logo_print` / `install_time_record` / `end_del_file` / `ask_for_reboot` | `lib/common.sh` |
| 全局变量默认值定义（原 17~154 行） | `lib/state.sh` |
| `get_os_info` / `adapt_so_path` / `conf_os` / `adapt_os_version` / `do_fix_*` / `add_debs_link` / `adapt_gcc` / `adapt_scp` | `lib/os_adapt.sh` |
| `check_iso` / `backup_repos` / `conf_local_repository` / `conf_network_repository` / `conf_repo` | `lib/os_adapt.sh` |
| `check_oracle_compatibility` / `check_os_version` | `lib/os_adapt.sh` |
| `help` / `accept_para` / `pre_para_check` / `conf_master_node` / `handle_para` / `select_db_options` / `clean_old_envir` | `lib/args.sh` |
| `get_grid_soft` / `get_db_soft` / `send_to_other_nodes` / `other_node_shell` / `check_and_update_date` / `root_ssh_trust` | `lib/args.sh` |
| `unzip_gridsoft` / `conf_gridrsp` / `get_gridinstall_cmd` / `exec_root` / `after_grid_install` / `install_gridsoft` / `get_asmca_cmd` / `create_asmgroup` | `lib/grid.sh` |
| `unzip_dbsoft` / `conf_oraclersp` / `get_oracleinstall_cmd` / `install_dbsoft` / `after_oracle_install` / `install_ojvm_patch` / `conf_netca` | `lib/dbsoft.sh` |
| `conf_swap` / `disable_firewall` / `disable_selinux` / `conf_nsysctl` / `conf_hostname` / `conf_hosts` / `create_users_groups` / `create_dir` / `conf_avahi` / `conf_grub` / `conf_sysctl` / `conf_ipc` / `conf_limits` / `conf_shm` / `install_rlwrap` / `conf_profile` / `conf_asm` / `conf_timesync` / `conf_dns` | `1_os_config.sh` |
| `get_dbca_rsp` / `get_dbca_cmd` / `create_db` / `create_pdb` / `conf_omf` / `conf_sqlnet` | `3_db_create.sh` |
| `conf_controlfile` / `conf_redolog` / `db_autostart` / `db_backup` / `conf_para` / `conf_glogin` / `conf_hugepage` / `db_optimize` | `4_post_config.sh` |
| 新增：`conf_archivelog` / `conf_pdb_autostart` / `conf_service_user` / `verify_install` / `conf_listener_manual` | `4_post_config.sh`、`lib/dbsoft.sh` |

## 注意事项

1. **安装包目录**：脚本默认把自身所在目录当作安装包目录，建议把脚本内容直接放在 `/soft`、安装包也放 `/soft`；若不在同一目录，用 `ORACLE_SOFT_DIR` 指定（见上一节）。软件目录不能与 `-d`（ORACLE_BASE 根目录）相同。
2. 所有脚本需 **root** 执行，且需要 `ping` 命令。
3. 阶段四中大量参数使用 `scope=spfile` 写入，**需数据库重启后才生效**；控制文件复用、归档模式切换会触发重启，通常已覆盖此场景。若需立即生效，可手动重启一次实例。
4. 阶段四创建的账户：CDB 架构下为公共用户 `C##MONITOR`（只读监控）与 `C##BACKUP`（RMAN 备份，12c+ 授予 `SYSBACKUP`），密码与 `SYS/SYSTEM` 相同；非 CDB 架构下为 `MONITOR` / `BACKUP`。
5. 数据库密码中若包含 `$`，在经 `sqlplus` heredoc 传递时可能被 shell 展开，建议避免使用。
6. 阶段四 `verify_install` 只做只读检查（实例状态、PDB、归档模式、监听、版本），不会中断安装；有异常时会提示查看日志。
7. 日志：`/soft/print_shell_install_<时间戳>.log`（详细过程）、`/soft/shell_install_output_<时间戳>.log`（终端输出）、`/soft/install_report_<时间戳>.md`（安装报告）。

## 与原脚本的行为差异

- 监听创建新增 **netca 失败回退**：netca 未生成 `listener.ora` 或 `lsnrctl status` 不通过时，自动手写静态 `listener.ora` 并启动监听。
- 阶段三对 21c/26ai 显式强制 `createAsContainerDatabase=true`。
- 阶段四新增归档、PDB 触发器、专用账户、安装验证四项（原脚本归档依赖 DBCA 模板开关，无事后确认）。
- `pre_para_check` 不再强制脚本必须命名为 `OracleShellInstall`。
- RAC 下发到其他节点的是 `1_os_config.sh` + `lib/`，而非单个大脚本。
