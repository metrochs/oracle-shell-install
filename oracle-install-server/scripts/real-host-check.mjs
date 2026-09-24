/**
 * 真机检查/安装工具：对一台真实主机执行「登记 → 连通测试 → 下发脚本 → 执行任务」。
 *
 * 两种任务类型：
 *   KIND=check   只读检查，执行 run_all.sh -h，不改动目标机系统（默认）
 *   KIND=install 真实安装，需要 CONF_FILE 指向 install.conf
 *
 * 用法：
 *   node scripts/real-host-check.mjs <host> <user> <password> [port] [softDir]
 * 或用私钥：
 *   PRIVATE_KEY_FILE=/path/to/key node scripts/real-host-check.mjs <host> <user>
 * 安装模式：
 *   KIND=install CONF_FILE=/path/install.conf node scripts/real-host-check.mjs ...
 */
import fs from 'node:fs'

const BASE = process.env.API_BASE || 'http://127.0.0.1:3000'
const TOKEN = process.env.API_TOKEN
const KIND = process.env.KIND || 'check'
const CONF_FILE = process.env.CONF_FILE || ''
if (!TOKEN) {
  console.error('请设置 API_TOKEN（后端 .env 里的值）')
  process.exit(1)
}
if (KIND === 'install' && !CONF_FILE) {
  console.error('KIND=install 需要设置 CONF_FILE 指向 install.conf')
  process.exit(1)
}

const [host, user = 'root', password, port = '22', softDir = '/soft'] = process.argv.slice(2)
if (!host) {
  console.error('用法: node scripts/real-host-check.mjs <host> <user> <password> [port] [softDir]')
  process.exit(1)
}

const headers = { 'Content-Type': 'application/json', authorization: `Bearer ${TOKEN}` }
const log = (s) => console.log(s)

async function req(path, options = {}) {
  const res = await fetch(`${BASE}${path}`, {
    ...options,
    headers: { ...headers, ...(options.headers || {}) }
  })
  const text = await res.text()
  let data
  try {
    data = text ? JSON.parse(text) : null
  } catch {
    data = text
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${JSON.stringify(data)}`)
  return data
}

// 1. 登记目标机
const payload = { name: `${KIND}-${host}`, host, port: Number(port), username: user, softDir }
if (process.env.PRIVATE_KEY_FILE) {
  payload.privateKey = fs.readFileSync(process.env.PRIVATE_KEY_FILE, 'utf8')
} else if (password) {
  payload.password = password
} else {
  console.error('需要 password 或 PRIVATE_KEY_FILE')
  process.exit(1)
}
log('== 1. 登记目标机')
const hosts = await req('/api/hosts', { method: 'POST', body: JSON.stringify(payload) })
const me = hosts.slice(-1)[0]
log(`   已保存 id=${me.id} hasKey=${me.hasKey} hasPassword=${me.hasPassword}`)

// 2. 连通测试
log('== 2. SSH 连通测试')
const test = await req(`/api/hosts/${me.id}/test`, { method: 'POST', body: '{}' })
log(`   ready=${test.ready}`)
if (!test.ready) log('   （脚本目录尚未下发，属正常，下一步会下发）')

// 3. 下发脚本
log('== 3. 下发脚本到目标机')
const dep = await req(`/api/hosts/${me.id}/deploy`, { method: 'POST', body: '{}' })
log(`   ok=${dep.ok} ready=${dep.ready} 文件数=${dep.files} 体积=${(dep.bytes / 1024).toFixed(1)}KB`)
if (!dep.ready) {
  log('   下发后仍未就绪，中止')
  process.exit(1)
}

// 4. 执行任务
log(`== 4. 执行任务（${KIND}）`)
const body = { hostId: me.id, kind: KIND, softDir }
if (KIND === 'install') body.conf = fs.readFileSync(CONF_FILE, 'utf8')
const task = await req('/api/tasks', { method: 'POST', body: JSON.stringify(body) })
log(`   任务 ${task.id} 已创建，等待输出...`)

const wsBase = BASE.replace(/^http/, 'ws')
const { default: WebSocket } = await import('ws')
const ws = new WebSocket(`${wsBase}/ws/tasks/${task.id}?token=${encodeURIComponent(TOKEN)}`)
ws.on('message', (m) => {
  const msg = JSON.parse(m.toString())
  if (msg.type === 'log') process.stdout.write(msg.text)
  else if (msg.type === 'stage' && Object.keys(msg.stages || {}).length) {
    log(`   [进度] ${JSON.stringify(msg.stages)}`)
  } else if (msg.type === 'status' && msg.status !== 'pending') {
    log(`\n   [状态] ${msg.status}`)
  } else if (msg.type === 'done') {
    log(`\n== 5. 结果：${msg.status}`)
    process.exit(msg.status === 'success' ? 0 : 2)
  }
})
ws.on('error', (e) => log(`WS 错误: ${e.message}`))
ws.on('close', () => {
  log('\n连接关闭但未收到完成标记')
  process.exit(2)
})
setTimeout(() => {
  log('\n超时未完成，请检查目标机 /soft 下的日志')
  process.exit(2)
}, KIND === 'check' ? 90000 : 5400000)
