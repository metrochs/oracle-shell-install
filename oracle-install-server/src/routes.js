import { API_TOKEN } from './config.js'
import { safeEqual, encrypt } from './crypto.js'
import { templates, hosts, tasks, id } from './store.js'
import { audit, readAudit } from './audit.js'
import { subscribe, unsubscribe, start, stop, runningTaskOfHost, ensureTrack } from './runner.js'
import { connectHost, probe } from './ssh.js'
import { deployScripts } from './deploy.js'

function unauthorized(reply) {
  return reply.code(401).send({ error: 'unauthorized' })
}

/** 校验 Authorization: Bearer <token> 或 ?token= */
function checkAuth(req, reply) {
  const header = req.headers.authorization || ''
  const bearer = header.startsWith('Bearer ') ? header.slice(7).trim() : ''
  const token = bearer || (req.query && req.query.token) || ''
  if (!token || !safeEqual(token, API_TOKEN)) {
    unauthorized(reply)
    return false
  }
  req.actor = req.headers['x-actor'] || 'api'
  return true
}

export default async function routes(app) {
  app.addHook('onRequest', async (req, reply) => {
    // 健康检查与 WebSocket 握手（token 走 query）不做 hook 拦截，由各自处理
    if (req.url === '/api/health') return
    if (req.url.startsWith('/ws/')) return
    if (!req.url.startsWith('/api/')) return
    checkAuth(req, reply)
  })

  app.get('/api/health', async () => ({ ok: true, ts: Date.now() }))

  // ---------------- 配置模板 ----------------
  app.get('/api/templates', async () => templates.list())
  app.post('/api/templates', async (req, reply) => {
    const { name, values } = req.body || {}
    if (!name) return reply.code(400).send({ error: '缺少模板名称' })
    templates.upsert({ name, values: values || {} })
    audit(req.actor, 'save_template', { name })
    return templates.list()
  })
  app.delete('/api/templates/:name', async (req) => {
    templates.remove(req.params.name)
    audit(req.actor, 'delete_template', { name: req.params.name })
    return templates.list()
  })

  // ---------------- 目标机 ----------------
  app.get('/api/hosts', async () => hosts.list())
  app.post('/api/hosts', async (req, reply) => {
    const b = req.body || {}
    if (!b.host || (!b.privateKey && !b.password)) {
      return reply.code(400).send({ error: '缺少 host，以及 privateKey 或 password' })
    }
    const rec = {
      id: b.id || id(),
      name: b.name || b.host,
      host: b.host,
      port: Number(b.port) || 22,
      username: b.username || 'root',
      softDir: b.softDir || '/soft'
    }
    if (b.privateKey) rec.privateKey = encrypt(b.privateKey)
    if (b.password) rec.password = encrypt(b.password)
    if (b.passphrase) rec.passphrase = encrypt(b.passphrase)
    hosts.upsert(rec)
    audit(req.actor, 'save_host', { host: b.host })
    return hosts.list()
  })
  app.delete('/api/hosts/:id', async (req) => {
    hosts.remove(req.params.id)
    audit(req.actor, 'delete_host', { id: req.params.id })
    return hosts.list()
  })
  // 把 OracleShellInstall 脚本目录下发到目标机 /soft
  app.post('/api/hosts/:id/deploy', async (req, reply) => {
    const h = hosts.get(req.params.id)
    if (!h) return reply.code(404).send({ error: '目标机不存在' })
    try {
      const result = await deployScripts(h, req.actor)
      return result
    } catch (e) {
      audit(req.actor, 'deploy_fail', { host: h.host, error: String(e.message || e) })
      return reply.code(502).send({ error: String(e.message || e) })
    }
  })
  app.post('/api/hosts/:id/test', async (req, reply) => {
    const h = hosts.get(req.params.id)
    if (!h) return reply.code(404).send({ error: '目标机不存在' })
    try {
      const conn = await connectHost(h)
      const ok = await probe(conn, h.softDir || '/soft')
      conn.end()
      audit(req.actor, 'test_host', { host: h.host, ok })
      return { ok, ready: ok }
    } catch (e) {
      audit(req.actor, 'test_host', { host: h.host, ok: false, error: String(e.message) })
      return reply.code(502).send({ ok: false, error: String(e.message) })
    }
  })

  // ---------------- 任务 ----------------
  app.get('/api/tasks', async () => tasks.list())
  app.get('/api/tasks/:id', async (req, reply) => {
    const t = tasks.get(req.params.id)
    if (!t) return reply.code(404).send({ error: '任务不存在' })
    return t
  })
  app.post('/api/tasks', async (req, reply) => {
    const { hostId, conf, softDir, kind = 'install' } = req.body || {}
    if (!hostId) return reply.code(400).send({ error: '缺少 hostId' })
    if (kind === 'install' && !conf) {
      return reply.code(400).send({ error: '缺少安装配置内容 conf' })
    }
    // 同一台机同时只允许一个安装任务
    const busy = runningTaskOfHost(hostId)
    if (busy) {
      return reply.code(409).send({
        error: `目标机上已有任务在执行（${busy.id}，状态 ${busy.status}），请等待结束或先终止`
      })
    }
    const t = tasks.create({ hostId, status: 'pending', softDir: softDir || '/soft', kind })
    // 先建好日志通道占位，前端立刻订阅才不会漏掉最早的日志
    ensureTrack(t.id)
    audit(req.actor, 'create_task', { taskId: t.id, hostId, kind })
    // 异步启动，不阻塞响应；启动失败会把互斥释放掉
    start(t.id, { hostId, conf, softDir: softDir || '/soft', kind }, req.actor).catch((e) => {
      tasks.update(t.id, { status: 'failed', error: String(e.message || e) })
    })
    return t
  })
  app.post('/api/tasks/:id/stop', async (req) => {
    const ok = await stop(req.params.id, req.actor)
    return { ok }
  })

  // ---------------- 审计 ----------------
  app.get('/api/audit', async () => readAudit(200))

  // ---------------- 日志 WebSocket ----------------
  app.get('/ws/tasks/:id', { websocket: true }, (connection, req) => {
    // @fastify/websocket 传入的是 SocketStream，真正的 WebSocket 在 .socket 上
    const ws = connection.socket || connection
    const q = new URL(req.url, 'http://localhost').searchParams
    const token = q.get('token') || ''
    const send = (obj) => {
      try {
        ws.send(JSON.stringify(obj))
      } catch {
        /* noop */
      }
    }

    if (!token || !safeEqual(token, API_TOKEN)) {
      send({ type: 'error', text: 'unauthorized' })
      ws.close()
      return
    }

    const taskId = req.params.id
    if (!subscribe(taskId, ws)) {
      // 任务已结束或不存在：直接回状态，避免前端一直转圈
      const t = tasks.get(taskId)
      send({ type: 'status', status: t ? t.status : 'unknown' })
      send({ type: 'stage', stages: (t && t.stages) || {} })
      send({ type: 'done', status: t ? t.status : 'unknown' })
      ws.close()
      return
    }
    ws.on('close', () => unsubscribe(taskId, ws))
  })
}
