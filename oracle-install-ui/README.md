# OracleShellInstall 参数配置中心

把 OracleShellInstall 的 60+ 个安装参数做成可视化表单：按场景动态显隐、实时校验、
版本兼容矩阵拦截，最后导出 `install.conf` 给脚本用。

纯前端，无后端，不接触目标主机。

## 快速开始

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # 产物在 dist/，可直接静态托管
```

## 用法

1. 右上角选择目标环境：**操作系统 + Linux 大版本 + CPU 架构**
2. 左侧按分组填写（场景 → 主机与网络 → 数据库 → 路径与软件源 → 存储 ASM → 集群 RAC → 补丁与高级）；RAC 模式下节点配置为动态表格（每行一个节点：主机名 + 公网 IP + 虚拟 IP，可增删行，行级与跨行校验实时提示）
3. 右侧实时显示错误与提示，错误清零后才能导出
4. 下载 `install.conf`，放到目标机 `/soft` 目录
5. 目标机执行：`sh run_all.sh -c install.conf`

## 工作原理

```
scripts/gen-schema.py  →  src/data/schema.json   （58 个参数的元数据，单一数据源）
                          src/data/charsets.json （247 种字符集，从原脚本抽取）
                          src/data/matrix.json   （版本兼容矩阵 + OS 清单）
                                 ↓
                          App.vue 按 schema 渲染表单
                                 ↓
                          install.conf
```

**schema 驱动**是关键：不在 Vue 里手写 58 个表单项，而是渲染器读元数据出表单。
参数表变更时改 `scripts/gen-schema.py` 后重新生成即可：

```bash
python scripts/gen-schema.py
```

## schema 字段说明

| 字段 | 作用 |
|---|---|
| `key` / `flag` | 脚本全局变量名 / 命令行短选项 |
| `type` | `enum` `enum-search` `string` `number` `password` `yn` `tf` `ifname` |
| `enum` / `options` | 可选取值；`enum-search` 用于 247 种字符集这类超大枚举（带检索） |
| `default` | 默认值，与 `lib/state.sh` 保持一致 |
| `group` | 所属分组 |
| `visibleWhen` | 条件显隐，如 `{oracle_install_mode: ["rac"]}` |
| `requiredWhen` | 条件必填 |
| `implies` | 联动赋值，如填了 `pdbname` 自动置 `iscdb=true` |
| `validate` | 校验规则：`ip` `iplist` `orapwd` `dbname` `nostartdigit` |
| `advanced` | 高级参数，默认折叠 |

## 校验覆盖

- **字段级**：必填、枚举、数字、Y/N、true/false、IP、IP 列表、密码字符集、库名长度与字符、名称不以数字开头
- **版本矩阵**（`utils/validate.js` 的 `matrixIssues`）：数据库版本 × 操作系统 × Linux 大版本 × CPU 架构
- **跨字段**（`crossChecks`）：GI 版本 ≥ DB 版本、多个 SCAN IP 必须开 DNS、节点 IP 与主机名数量一致、
  11gR2 主机名不能大写、冗余度与磁盘数量匹配、21c/26ai 强制 CDB 等

## 产物

- **install.conf**：`KEY=VALUE` 文件，只输出非空值，空值交给脚本默认值。
  脚本侧由 `lib/args.sh` 的 `load_conf()` 加载，只允许赋值行（防注入），命令行参数优先级更高。
- **命令行预览**：方便直接粘贴执行，密码以 `<标签>` 占位，避免明文泄露。
- **配置模板**：保存在浏览器 localStorage，可命名保存/载入/删除，适合多套环境复用。

## 注意

- 参数键名是脚本内部全局变量名，不是短选项（例如 `oracle_install_mode` 而非 `-install_mode`）
- 模板存在本地浏览器，换机器或清缓存会丢失，重要配置请导出 conf 文件保存
- 前端不保存任何密码到服务端（因为没有服务端）；但模板存在 localStorage 的会包含密码明文，共用电脑时慎用
