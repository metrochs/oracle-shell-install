# -*- coding: utf-8 -*-
"""从 OracleShellInstall 脚本导出前端所需的参数元数据。

- 参数表：手工核对（来源 lib/args.sh 的 accept_para 与 lib/state.sh 默认值）
- 247 个字符集清单：从原脚本自动抽取，避免手抄出错
- 版本兼容矩阵：来源 lib/os_adapt.sh 的 check_oracle_compatibility / check_os_version
"""
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
# 原单体脚本，用于抽取 247 个字符集清单
SRC_SCRIPT = os.path.join(HERE, "..", "..", "OracleShellInstall.sh")
OUT_DIR = os.path.join(HERE, "..", "src", "data")

src = io.open(SRC_SCRIPT, encoding="utf-8", errors="surrogateescape").read()
m = re.search(r'local CHARSETS="', src)
CHARSETS = src[m.end(): src.index('"', m.end())].split("|")
assert len(CHARSETS) == 247, len(CHARSETS)

NCHARSETS = ["UTF8", "AL16UTF16"]
DBS = ["2048", "4096", "8192", "16384", "32768"]
REDUN = ["EXTERNAL", "NORMAL", "HIGH"]
VERSIONS = ["11", "12", "19", "21", "26"]

MATRIX = {
    "x86_64": {
        "11": {"linux": [6, 7, 8], "sles": [7]},
        "12": {"linux": [6, 7, 8], "sles": [7, 8]},
        "19": {"linux": [7, 8, 9], "sles": [7, 8]},
        "21": {"linux": [7, 8], "sles": [8]},
        "26": {"linux": [8, 9], "sles": []},
    },
    "aarch64": {
        "19": {"linux": [8, 9, 10], "sles": []},
    },
}

OS_LIST = [
    {"id": "rhel", "name": "Red Hat Enterprise Linux", "certified": True},
    {"id": "centos", "name": "CentOS", "certified": True},
    {"id": "ol", "name": "Oracle Linux", "certified": True},
    {"id": "rocky", "name": "Rocky Linux", "certified": False},
    {"id": "almalinux", "name": "AlmaLinux", "certified": False},
    {"id": "kylin", "name": "银河麒麟 Kylin", "certified": False},
    {"id": "openEuler", "name": "openEuler", "certified": False},
    {"id": "anolis", "name": "Anolis OS", "certified": False},
    {"id": "uos", "name": "统信 UOS", "certified": False},
    {"id": "neokylin", "name": "中标麒麟 NeoKylin", "certified": False},
    {"id": "opencloudos", "name": "OpenCloudOS", "certified": False},
    {"id": "tencentos", "name": "TencentOS", "certified": False},
    {"id": "ctyunos", "name": "天翼云 CTyunOS", "certified": False},
    {"id": "hce", "name": "Huawei Cloud EulerOS", "certified": False},
    {"id": "sles", "name": "SUSE Linux Enterprise", "certified": True},
    {"id": "ubuntu", "name": "Ubuntu", "certified": False},
    {"id": "debian", "name": "Debian", "certified": False},
    {"id": "Deepin", "name": "Deepin", "certified": False},
]

GROUPS = [
    {"id": "scene", "name": "场景", "desc": "安装模式与版本，决定后续需要填哪些内容"},
    {"id": "host", "name": "主机与网络", "desc": "主机名、网卡、系统用户"},
    {"id": "db", "name": "数据库", "desc": "库名、字符集、块大小、PDB 等"},
    {"id": "path", "name": "路径与软件源", "desc": "安装目录、数据目录、软件源方式"},
    {"id": "asm", "name": "存储 ASM", "desc": "单机 ASM / RAC 模式下的磁盘组配置"},
    {"id": "rac", "name": "集群 RAC", "desc": "RAC 模式下的节点、网络与互信配置"},
    {"id": "adv", "name": "补丁与高级", "desc": "补丁编号、流程开关、调优选项"},
]

PARAMS = [
    dict(key="oracle_install_mode", flag="-install_mode", label="安装模式", type="enum",
         enum=[{"v": "single", "l": "单机"}, {"v": "standalone", "l": "单机 ASM"}, {"v": "rac", "l": "RAC 集群"}],
         default="", group="scene", required=True,
         help="决定需要填写的参数集合：单机最简，单机 ASM 需配置磁盘，RAC 需配置多节点"),
    dict(key="db_version", flag="-dbv", label="数据库版本", type="enum",
         enum=[{"v": "11", "l": "11g (11.2.0.4)"}, {"v": "12", "l": "12c (12.2.0.1)"},
               {"v": "19", "l": "19c (19.3)"}, {"v": "21", "l": "21c (21.3)"},
               {"v": "26", "l": "26ai (23.26)"}],
         default="19", group="scene", required=True,
         help="ARM 架构仅支持 19c"),
    dict(key="gi_version", flag="-giv", label="Grid 版本", type="enum",
         enum=[{"v": v, "l": v} for v in VERSIONS], default="", group="scene",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]},
         help="留空则与数据库版本相同；必须大于等于数据库版本"),
    dict(key="hostname", flag="-n", label="主机名", type="string", default="orcl",
         group="host", required=True,
         help="单机/单机ASM 作为主机名；RAC 模式下作为集群名与 SCAN 名的前缀"),
    dict(key="local_ifname", flag="-lf", label="公网网卡名", type="ifname", default="",
         group="host", required=True, placeholder="eth0",
         help="必填。脚本据此取本机 IP，写入 /etc/hosts 与监听配置"),
    dict(key="oracle_user", flag="-ou", label="Oracle 系统用户", type="string",
         default="oracle", group="host"),
    dict(key="oracle_passwd", flag="-op", label="Oracle 用户密码", type="password",
         default="oracle", group="host",
         help="含特殊字符时建议改用配置文件方式，避免命令行转义问题"),
    dict(key="root_passwd", flag="-rp", label="root 用户密码", type="password",
         default="", group="host",
         visibleWhen={"oracle_install_mode": ["rac"]},
         requiredWhen={"oracle_install_mode": ["rac"]},
         help="仅 RAC 需要，用于建立节点间 root 互信，所有节点必须一致"),
    dict(key="timeserver_ip", flag="-tsi", label="时间服务器 IP", type="string",
         default="", group="host", visibleWhen={"oracle_install_mode": ["rac"]},
         validate="ip", help="RAC 使用 CTSS 同步时填；留空则跳过时间同步配置"),
    dict(key="db_name", flag="-o", label="数据库名", type="string", default="orcl",
         group="db", required=True, validate="dbname",
         help="多个库用逗号分隔，如 orcl,oradb；超过 8 位会被自动截断为前 8 位，最长 12 位"),
    dict(key="database_passwd", flag="-dp", label="SYS/SYSTEM 密码", type="password",
         default="oracle", group="db", required=True, validate="orapwd",
         help="必须以字母开头，且只能包含字母、数字、_、#、$"),
    dict(key="pdbname", flag="-pdb", label="PDB 名称", type="string", default="pdb01",
         group="db", implies={"iscdb": "true"},
         help="填写即启用 CDB 架构；多个 PDB 用逗号分隔。21c/26ai 强制 CDB"),
    dict(key="db_characterset", flag="-ds", label="数据库字符集", type="enum-search",
         default="AL32UTF8", group="db", options=CHARSETS,
         help="支持 247 种字符集，可输入检索"),
    dict(key="nation_characterset", flag="-ns", label="国家字符集", type="enum",
         enum=[{"v": c, "l": c} for c in NCHARSETS], default="AL16UTF16", group="db"),
    dict(key="db_block_size", flag="-dbs", label="数据块大小", type="enum",
         enum=[{"v": v, "l": v} for v in DBS], default="8192", group="db",
         help="非 8192 时 DBCA 使用 New_Database.dbt 模板"),
    dict(key="redosize", flag="-redo", label="Redo 日志大小 (MB)", type="number",
         default="1024", group="db", min=1),
    dict(key="enable_arch", flag="-er", label="开启归档", type="tf", default="true",
         group="db", help="关闭时数据库运行在 NOARCHIVELOG 模式"),
    dict(key="iscdb", flag="", label="CDB 架构", type="tf", default="false",
         group="db", advanced=True,
         help="21c/26ai 强制为 true；填写 PDB 名称时自动置为 true"),
    dict(key="env_base_dir", flag="-d", label="软件安装根目录", type="string",
         default="/u01", group="path",
         help="ORACLE_BASE 根目录，不能与安装包所在目录相同"),
    dict(key="oradata_dir", flag="-ord", label="数据文件目录", type="string",
         default="/oradata", group="path"),
    dict(key="archive_dir", flag="-ard", label="归档目录", type="string", default="",
         group="path", placeholder="留空则为 数据目录/archivelog"),
    dict(key="local_repo", flag="-lrp", label="配置本地软件源", type="yn", default="Y",
         group="path", help="需要挂载 ISO 镜像"),
    dict(key="net_repo", flag="-nrp", label="配置网络软件源", type="yn", default="N",
         group="path", help="需要主机能访问外网"),
    dict(key="asm_disk_conf", flag="-adc", label="脚本配置 ASM 磁盘", type="yn",
         default="Y", group="asm",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]},
         help="Y 时传入的磁盘参数会被解析为 WWID；N 时直接使用盘符"),
    dict(key="multipath", flag="-mp", label="配置多路径", type="yn", default="Y",
         group="asm", visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="data_asm_group", flag="-dn", label="DATA 磁盘组名", type="string",
         default="DATA", group="asm",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="data_base_disk", flag="-dd", label="DATA 磁盘", type="string", default="",
         group="asm", placeholder="/dev/sdb,/dev/sdc",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]},
         requiredWhen={"oracle_install_mode": ["standalone", "rac"]},
         help="必填。多块盘用逗号分隔"),
    dict(key="data_redun", flag="-dr", label="DATA 冗余度", type="enum",
         enum=[{"v": v, "l": v} for v in REDUN], default="EXTERNAL", group="asm",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]},
         help="NORMAL 至少 2 块盘，HIGH 至少 3 块盘"),
    dict(key="ocr_asm_group", flag="-on", label="OCR 磁盘组名", type="string",
         default="OCR", group="asm", visibleWhen={"oracle_install_mode": ["rac"]}),
    dict(key="ocr_base_disk", flag="-od", label="OCR 磁盘", type="string", default="",
         group="asm", placeholder="/dev/sdb", visibleWhen={"oracle_install_mode": ["rac"]},
         requiredWhen={"oracle_install_mode": ["rac"]},
         help="必填。12cR2 未打补丁时 OCR 磁盘组需至少 50G"),
    dict(key="ocr_redun", flag="-or", label="OCR 冗余度", type="enum",
         enum=[{"v": v, "l": v} for v in REDUN], default="EXTERNAL", group="asm",
         visibleWhen={"oracle_install_mode": ["rac"]},
         help="NORMAL 至少 3 块盘，HIGH 至少 5 块盘"),
    dict(key="arch_asm_group", flag="-an", label="ARCH 磁盘组名", type="string",
         default="ARCH", group="asm",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="arch_base_disk", flag="-ad", label="ARCH 磁盘", type="string", default="",
         group="asm", placeholder="留空则不单独建归档磁盘组",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="arch_redun", flag="-ar", label="ARCH 冗余度", type="enum",
         enum=[{"v": v, "l": v} for v in REDUN], default="EXTERNAL", group="asm",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="virtualbox", flag="-vbox", label="VirtualBox 环境", type="yn", default="N",
         group="asm", visibleWhen={"oracle_install_mode": ["standalone", "rac"]},
         help="虚拟机环境需修正多路径 WWID 前缀"),
    dict(key="rac_nodes_table", flag="", label="RAC 节点列表", type="node-table",
         default="", group="rac", synthetic=True,
         visibleWhen={"oracle_install_mode": ["rac"]},
         help="每行一个节点：主机名 + 公网 IP + 虚拟 IP；第一个节点为主节点"),
    # 以下三个键由 rac_nodes_table 表格统一编辑（合成参数），不在表单中单独出现，
    # 但仍是 conf 导出的真实字段
    dict(key="rac_hostname", flag="-hn", label="节点主机名", type="string", default="",
         group="rac", placeholder="orcl01,orcl02", hidden=True,
         help="按节点顺序，逗号分隔。11gR2 不能含大写字母"),
    dict(key="rac_public_ip", flag="-ri", label="节点公网 IP", type="string", default="",
         group="rac", placeholder="10.0.0.1,10.0.0.2", hidden=True,
         validate="iplist",
         help="第一个 IP 必须是主节点 IP"),
    dict(key="rac_virtual_ip", flag="-vi", label="节点虚拟 IP", type="string", default="",
         group="rac", placeholder="10.0.0.11,10.0.0.12", hidden=True,
         validate="iplist",
         help="必须未被占用（不可 ping 通）"),
    dict(key="rac_scan_ip", flag="-si", label="SCAN IP", type="string", default="",
         group="rac", placeholder="10.0.0.20",
         visibleWhen={"oracle_install_mode": ["rac"]},
         requiredWhen={"oracle_install_mode": ["rac"]}, validate="iplist",
         help="超过 1 个 SCAN IP 时必须配置 DNS"),
    dict(key="rac_priv_ifname", flag="-pf", label="心跳网卡名", type="string", default="",
         group="rac", placeholder="eth3", visibleWhen={"oracle_install_mode": ["rac"]},
         requiredWhen={"oracle_install_mode": ["rac"]},
         help="不建议超过 2 组心跳网卡"),
    dict(key="scan_name", flag="-sn", label="SCAN 名称", type="string", default="",
         group="rac", placeholder="留空则为 主机名-scan",
         visibleWhen={"oracle_install_mode": ["rac"]}, validate="nostartdigit"),
    dict(key="cluster_name", flag="-cn", label="集群名称", type="string", default="",
         group="rac", placeholder="留空则为 主机名-cluster",
         visibleWhen={"oracle_install_mode": ["rac"]}, validate="nostartdigit",
         help="长度不能超过 15 位"),
    dict(key="dns", flag="-dns", label="配置 DNS", type="yn", default="N", group="rac",
         visibleWhen={"oracle_install_mode": ["rac"]}),
    dict(key="dns_name", flag="-dnsn", label="DNS 域名", type="string", default="",
         group="rac", placeholder="example.com",
         visibleWhen={"dns": ["Y"]}, requiredWhen={"dns": ["Y"]}),
    dict(key="dns_ip", flag="-dnsi", label="DNS 服务器 IP", type="string", default="",
         group="rac", visibleWhen={"dns": ["Y"]}, requiredWhen={"dns": ["Y"]},
         validate="ip"),
    dict(key="grid_user", flag="-gu", label="Grid 系统用户", type="string",
         default="grid", group="rac",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="grid_passwd", flag="-gp", label="Grid 用户密码", type="password",
         default="oracle", group="rac",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="grid_patch", flag="-gpa", label="Grid RU 补丁号", type="string", default="",
         group="adv", placeholder="例如 34130714",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]},
         help="需将对应 zip 上传至安装包目录"),
    dict(key="oracle_patch", flag="-opa", label="Oracle RU 补丁号", type="string",
         default="", group="adv", placeholder="例如 34133642"),
    dict(key="ojvm_patch", flag="-jpa", label="OJVM 补丁号", type="string", default="",
         group="adv"),
    dict(key="optimize_db", flag="-opd", label="建库后优化数据库", type="yn", default="Y",
         group="adv", help="参数优化、开机自启、RMAN 备份任务、归档、监控账户等"),
    dict(key="huge_flag", flag="-hf", label="配置内存大页", type="yn", default="N",
         group="adv"),
    dict(key="isgui", flag="-gui", label="安装图形界面", type="yn", default="N",
         group="adv"),
    dict(key="only_conf_os", flag="-m", label="仅配置操作系统", type="yn", default="N",
         group="adv", help="Y 时只执行阶段一，不装软件"),
    dict(key="install_until_grid", flag="-ug", label="安装到 Grid 结束", type="yn",
         default="N", group="adv",
         visibleWhen={"oracle_install_mode": ["standalone", "rac"]}),
    dict(key="install_until_db", flag="-ud", label="安装到数据库软件结束", type="yn",
         default="N", group="adv", help="Y 时只装软件不建库"),
    dict(key="node_num", flag="-node", label="节点号", type="number", default="1",
         group="adv", advanced=True,
         help="脚本内部参数，RAC 其他节点由主节点自动下发"),
    dict(key="debug_flag", flag="-debug", label="调试模式", type="yn", default="N",
         group="adv", advanced=True),
]

os.makedirs(OUT_DIR, exist_ok=True)


def dump(name, obj):
    p = os.path.join(OUT_DIR, name)
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    print("wrote", p)


dump("schema.json", {"groups": GROUPS, "params": PARAMS})
dump("charsets.json", CHARSETS)
dump("matrix.json", {"versionMatrix": MATRIX, "osList": OS_LIST,
                     "versions": VERSIONS, "redun": REDUN})

print("params:", len(PARAMS), "charsets:", len(CHARSETS))
