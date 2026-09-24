# OracleShellInstall 后端服务

配套 `oracle-install-ui` 的后端：配置模板管理 + **通过 SSH 远程执行安装脚本** + 实时日志回传。

**目标机上不需要装任何东西，也不会留下常驻进程。** 后端通过 SSH 上传配置、启动脚本、
`tail -f` 日志文件，断开后目标机上什么都不会残留。

## 快速开始

```bash
npm install
npm run keygen            # 生成 MASTER_KEY 与 API_TOKEN
# 把输出的两行写进 .env（可从 .env.example 复制）
npm start                 # 默认 http://127.0.0.1:3000
npm test                  # 端到端联调（用内置的模拟 SSH 目标机，无需真实主机）
```

前端开发时用 Vite 代理（已配置 `/api`、`/ws` 转发到 3000）：

```bash
cd ../oracle-install-ui && npm run dev
```

生产部署可直接让后端托管前端构建产物：先 `cd ../oracle-install-ui && npm run build`，
后端启动时会自动托管 `oracle-install-ui/dist`，单端口即可访问。

## 架构

```
浏览器 ──HTTP──> Fastify 后端 ──SSH──> 目标机
   ↑                │  │
   └──WebSocket─────┘  └──轮询 .oracle_install_env 读 STAGE1~4_DONE
```

一次执行的完整链路：

1. SSH 连接目标机，校验 `/soft/run_all.sh` 与 `lib/` 存在
2. SFTP 上传 `install.conf`（权限 600）
3. `setsid nohup sh run_all.sh -c install.conf > .oracle_run_<id>.log 2>&1 &` 后台启动
4. 另开一条 SSH 连接 `tail -f` 日志文件，经 WebSocket 逐块推给前端
5. 每 3 秒读一次目标机状态文件里的 `STAGE1_DONE`~`STAGE4_DONE`，作为进度条数据源
6. 进程退出后判定成功/失败（4 个阶段全完成才算成功）

> 用「后台启动 + tail 日志文件」而不是直接流式读 stdout，是为了支持**断线重连**：
> 浏览器刷新或网络闪断后重新订阅，会把缓冲的历史日志补发一遍。

## 接口

所有 `/api/*` 需要 `Authorization: Bearer <API_TOKEN>`，WebSocket 用 `?token=`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 健康检查，无需鉴权 |
| GET/POST | `/api/templates` | 配置模板列表 / 保存 |
| DELETE | `/api/templates/:name` | 删除模板 |
| GET/POST | `/api/hosts` | 目标机列表 / 登记（支持私钥或密码，均加密存储） |
| DELETE | `/api/hosts/:id` | 删除目标机 |
| POST | `/api/hosts/:id/test` | 测试 SSH 连通性与脚本目录 |
| POST | `/api/hosts/:id/deploy` | 下发脚本目录到目标机（自解压，SFTP 失败自动回退） |
| GET/POST | `/api/tasks` | 任务列表 / 发起执行（kind: install 或 check） |
| GET | `/api/tasks/:id` | 任务详情 |
| POST | `/api/tasks/:id/stop` | 终止任务 |
| GET | `/api/audit` | 审计日志 |
| WS | `/ws/tasks/:id?token=` | 实时日志、阶段进度、状态 |

## 安全设计

这是能远程以 root 执行安装脚本的服务，下列措施都是**硬性要求**，不要绕过：

- **鉴权**：`API_TOKEN` 必填，缺失时拒绝启动；用 `timingSafeEqual` 做恒定时间比较
- **默认只监听 127.0.0.1**：确需内网访问改 `HOST`，但**绝不能暴露公网**
- **私钥加密落盘**：AES-256-GCM，密钥来自 `MASTER_KEY`；接口只返回 `hasKey` 标记，私钥永不回传
- **审计日志**：`data/audit.log` 记录谁、何时、对哪台机、做了什么；不含密码与私钥
- **不记录敏感信息**：日志与审计只写元信息

运维要求：

- 后端部署在运维跳板机或内网独立机，配合防火墙限制来源 IP
- `MASTER_KEY` 泄露等价于私钥泄露，更换后已存私钥将无法解密，需重新录入
- 定期轮转 `API_TOKEN`

## 数据

`data/` 下为 JSON 文件（模板、目标机、任务）与审计日志，已加入 `.gitignore`。
写入走临时文件 + rename，保证原子性。数据量小，不引入数据库以免原生编译依赖。

## 测试

```bash
npm test
```

`test/mock-host.mjs` 用 ssh2 的 Server 能力起了一个**模拟 SSH 目标机**：接受公钥认证、
按时间线推进 `STAGE1~4_DONE`、模拟 `tail -f` 吐日志、接收配置上传。`test/e2e.mjs`
则在同一进程里起真实 Fastify + 真实 runner，跑完整链路，共 13 项断言：

- 目标机登记：HTTP 200、私钥加密落盘、接口不回传私钥
- 执行链路：上传配置 → 启动 run_all.sh → 日志推送 → 四阶段全部完成 → 状态 success
- 安全：同一目标机并发执行返回 409、结束后释放占用
- WebSocket：断线后重新订阅能立刻拿到状态

## 上传配置的方式

优先 SFTP；**如果目标机禁用了 SFTP 子系统（不少加固过的 Oracle 主机会这么做），
自动回退为 exec + base64 写入**（`umask 077 && printf %s '<base64>' | base64 -d > install.conf`），
base64 不含引号与特殊字符，不会破坏命令行。

## 已知限制

- 未做多用户与细粒度授权，只有一个 `API_TOKEN`
- 终止任务会 kill 主进程及其子进程，但如果已经进入 DBCA 建库阶段，中断可能留下半成品库，需要人工清理
- 日志缓冲上限 2000 行（超出丢弃最早的），刷新页面后能看到最近部分
