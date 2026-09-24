# oracle-shell-install

Oracle 数据库安装自动化套件：**Shell 脚本 + Web 配置中心 + SSH 执行后端**，已在 CentOS Stream 9 真机完成 Oracle 19c 单机 CDB 全流程安装验证。

## 组成

| 目录 | 说明 |
|---|---|
| [`OracleShellInstall/`](OracleShellInstall/) | 四阶段拆分的安装脚本（OS 配置 → 软件安装 → 建库 → 后配置），支持单机 / RAC / 两种一键模式，支持 `-c install.conf` 配置文件入口 |
| [`oracle-install-ui/`](oracle-install-ui/) | Vue3 + Vite 参数配置中心：schema 驱动动态表单、版本兼容矩阵校验、模板库、conf 生成与反向导入 |
| [`oracle-install-server/`](oracle-install-server/) | Node + Fastify 后端：SSH 远程执行、WebSocket 实时日志、四阶段进度、脚本下发、私钥/密码加密存储 |

原单体脚本见 [`OracleShellInstall.sh`](OracleShellInstall.sh)（拆分前的版本，保留对照）。

## 快速开始

**只用脚本**（无 Web 界面）：

```bash
# 把 OracleShellInstall/ 和安装包放到 /soft，然后
sh /soft/run_all.sh -lf eth0 -n orcl -o orcl -dbv 19 -pdb pdb01
```

完整参数见 `sh run_all.sh -h`；支持的 OS / 版本矩阵见 [OracleShellInstall/README.md](OracleShellInstall/README.md)。

**Web 全流程**（配置 → 下发 → 执行 → 实时日志）：

```bash
cd oracle-install-ui && npm install && npm run build
cd ../oracle-install-server && npm install && npm run keygen   # 生成 .env 密钥
npm start                                                       # http://127.0.0.1:3000
```

后端同时托管前端产物，单端口访问。目标机**无需安装任何东西**，走 SSH 执行，测试可用 `npm test`（内置模拟 SSH 主机）。

## 真机验证记录

CentOS Stream 9 / 4C / 5.7G 内存，Oracle 19c 单机 CDB + PDB：

- 阶段一 OS 配置 233s → 阶段二 软件安装 134s → 阶段三 DBCA 建库 908s → 阶段四 优化收尾
- 归档模式、PDB 自启动、C##MONITOR/C##BACKUP 账户、监听 1521、优化参数全部验证通过

## 安全说明

- 目标机零常驻进程，后端通过 SSH 完成一切；凭据 AES-256-GCM 加密落盘
- 仓库不含任何密钥与运行时数据（`.env`、`data/` 已排除），部署前务必 `npm run keygen` 重新生成
- 后端默认仅监听 `127.0.0.1`，对外暴露请自行加反代与访问控制
