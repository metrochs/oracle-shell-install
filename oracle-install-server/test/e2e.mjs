/**
 * 端到端联调：模拟 SSH 目标机 + 真实 Fastify 服务 + 真实 runner.js + WebSocket 客户端。
 * 验证：上传配置 → 启动 → 日志推送 → 阶段进度 → 成功判定 → 目标机互斥。
 *
 * 运行：node test/e2e.mjs
 */
import Fastify from 'fastify'
import websocket from '@fastify/websocket'
import crypto from 'node:crypto'

process.env.API_TOKEN = 'test-token'
process.env.MASTER_KEY = crypto.randomBytes(32).toString('base64')
process.env.PORT = '0'
process.env.HOST = '127.0.0.1'
process.env.LOG_LEVEL = 'error'

const { default: routes } = await import('../src/routes.js')
const { hosts, tasks } = await import('../src/store.js')
const { encrypt } = await import('../src/crypto.js')
const { startMockHost } = await import('./mock-host.mjs')
const { start, subscribe, runningTaskOfHost, ensureTrack, peekBuffer } = await import('../src/runner.js')

const results = []
const check = (name, ok, extra = '') => {
  results.push([name, ok, extra])
  console.log(`${ok ? '  PASS' : '  FAIL'}  ${name}${extra ? ' — ' + extra : ''}`)
}

const CONF = `oracle_install_mode=single
db_version=26
local_ifname=eth0
hostname=orcl
db_name=orcl
pdbname=pdb01
iscdb=true
optimize_db=Y
`

// 1. 启动模拟目标机
const mock = await startMockHost(2223, { sftp: false })
check('模拟目标机已启动', true, `127.0.0.1:${mock.port}`)

// 2. 启动 Fastify
const app = Fastify({ logger: false })
await app.register(websocket)
await app.register(routes)
await app.listen({ port: 0, host: '127.0.0.1' })
const base = app.server.address()

// 3. 登记目标机（走真实接口，私钥应加密落盘）
const H = 'FPoe_x_test'
const addRes = await app.inject({
  method: 'POST',
  url: '/api/hosts',
  headers: { authorization: `Bearer test-token` },
  payload: {
    name: 'mock',
    host: '127.0.0.1',
    port: mock.port,
    username: 'root',
    softDir: '/soft',
    privateKey: mock.privateKeyPem
  }
})
check('登记目标机', addRes.statusCode === 200, `HTTP ${addRes.statusCode}`)
const hostId = JSON.parse(addRes.body).slice(-1)[0].id
const raw = JSON.stringify(hosts.get(hostId))
check('私钥已加密存储', !raw.includes('BEGIN'), raw.includes('BEGIN') ? '明文落盘!' : '')
check('接口不回传私钥', !addRes.body.includes('BEGIN'))

// 4. 连接 WebSocket 后再发起任务，确保能收到日志
const t = tasks.create({ hostId, status: 'pending', softDir: '/soft' })
ensureTrack(t.id)
const seen = { logs: [], stages: {}, done: null }
let resolveDone
const finishPromise = new Promise((r) => (resolveDone = r))
const ws = new (await import('ws')).default(
  `ws://127.0.0.1:${base.port}/ws/tasks/${t.id}?token=test-token`
)
const wsReady = new Promise((r) => ws.on('open', r))
ws.on('message', (m) => {
  const msg = JSON.parse(m.toString())
  if (msg.type === 'log') seen.logs.push(msg.text)
  else if (msg.type === 'stage') seen.stages = msg.stages
  else if (msg.type === 'done') {
    seen.done = msg.status
    resolveDone(msg.status)
  }
})
await wsReady
subscribe(t.id, ws)

// 5. 发起执行（复用真实 runner）
const runPromise = start(t.id, { hostId, conf: CONF, softDir: '/soft' }, 'e2e-test')

// 5.1 任务执行期间，同一目标机的第二个任务必须被拒绝
const dup = await app.inject({
  method: 'POST',
  url: '/api/tasks',
  headers: { authorization: 'Bearer test-token' },
  payload: { hostId, conf: CONF, softDir: '/soft' }
})
check('同一目标机并发执行被拒绝', dup.statusCode === 409, `HTTP ${dup.statusCode}`)

await runPromise

// 等待任务收尾（状态判定 + 缓冲写入），最多 25 秒
const status = await Promise.race([
  finishPromise,
  new Promise((r) => setTimeout(() => r('timeout'), 25000))
])
check('任务结束状态为 success', status === 'success', `实际: ${status}`)
check('日志有推送', seen.logs.length > 3, `${seen.logs.length} 条`)
check('配置经 base64 回退上传到目标机', mock.state.execLog.some((c) => c.includes('base64 -d') && c.includes('install.conf')))
check('执行过 run_all.sh', mock.state.execLog.some((c) => c.includes('nohup sh run_all.sh')))
check('四个阶段全部完成', Object.values(seen.stages).filter(Boolean).length === 4)
const task = tasks.get(t.id)
check('任务记录为 success', task && task.status === 'success', task ? task.status : '无记录')
if (task && task.status !== 'success') {
  console.log('--- 诊断：任务错误 ---')
  console.log('  error:', task.error || '(无)')
  console.log('--- 诊断：runner 缓冲日志 ---')
  for (const b of peekBuffer(t.id)) console.log('  [' + b.kind + ']', b.text.trim().slice(0, 200))
}

// 6. 目标机互斥：任务结束后应释放占用
const again = runningTaskOfHost(hostId)
check('任务结束后释放目标机占用', again === null, again ? `仍被 ${again.id} 占用` : '')

// 7. 已结束任务的 WS 订阅应立刻回状态而不是挂着
const ws2 = new (await import('ws')).default(
  `ws://127.0.0.1:${base.port}/ws/tasks/${t.id}?token=test-token`
)
const got = await new Promise((resolve) => {
  const out = []
  ws2.on('message', (m) => out.push(JSON.parse(m.toString())))
  ws2.on('close', () => resolve(out))
  setTimeout(() => resolve(out), 3000)
})
check('已结束任务订阅立刻回状态', got.some((m) => m.type === 'status' && m.status === 'success'))

ws.close()
mock.close()
await app.close()

// 清理本测试产生的数据，避免污染下次运行
const fs = await import('node:fs')
for (const f of ['hosts.json', 'tasks.json', 'templates.json', 'audit.log']) {
  const p = new URL(`../data/${f}`, import.meta.url)
  try {
    fs.rmSync(p)
  } catch {
    /* noop */
  }
}

let fail = 0
for (const [, ok] of results) if (!ok) fail++
console.log(`\n${results.length - fail}/${results.length} 项通过`)
process.exit(fail ? 1 : 0)
