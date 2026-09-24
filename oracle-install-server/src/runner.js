import { connectHost, uploadConf, execStream, execCapture, readStages } from './ssh.js'
import { tasks, hosts } from './store.js'
import { audit } from './audit.js'

/** 运行中的任务：id -> { ctrl, tail, stream, clients, buffer, timer, pid, hostId } */
const running = new Map()
/** 目标机互斥：hostId -> taskId，同一台机同时只允许一个安装任务 */
const runningByHost = new Map()
const MAX_BUFFER = 2000

export function runningTaskOfHost(hostId) {
  const id = runningByHost.get(hostId)
  return id ? tasks.get(id) : null
}

function broadcast(id, payload) {
  const r = running.get(id)
  if (!r) return
  const msg = JSON.stringify(payload)
  for (const ws of r.clients) {
    try {
      ws.send(msg)
    } catch {
      /* 忽略已断开的连接 */
    }
  }
}

function push(id, kind, text) {
  const r = running.get(id)
  if (!r) return
  r.buffer.push({ kind, text, ts: Date.now() })
  if (r.buffer.length > MAX_BUFFER) r.buffer.splice(0, r.buffer.length - MAX_BUFFER)
  broadcast(id, { type: 'log', kind, text })
}

export function subscribe(id, ws) {
  const r = running.get(id)
  if (!r) return false
  r.clients.add(ws)
  // 补发历史，支持断线重连
  for (const b of r.buffer) {
    try {
      ws.send(JSON.stringify({ type: 'log', kind: b.kind, text: b.text }))
    } catch {
      /* noop */
    }
  }
  ws.send(JSON.stringify({ type: 'stage', stages: r.stages }))
  ws.send(JSON.stringify({ type: 'status', status: r.status }))
  return true
}

export function unsubscribe(id, ws) {
  const r = running.get(id)
  if (r) r.clients.delete(ws)
}

export function isRunning(id) {
  return running.has(id)
}

/** 调试用：取任务缓冲日志 */
export function peekBuffer(id) {
  const r = running.get(id)
  return r ? r.buffer : []
}

/**
 * 建立任务的日志通道占位。必须在任务发起时就调用，
 * 否则前端先订阅、后发起任务时会因为 running 里没有记录而订阅失败。
 */
export function ensureTrack(taskId) {
  if (!running.has(taskId)) {
    running.set(taskId, {
      clients: new Set(),
      buffer: [],
      stages: {},
      status: 'pending',
      ctrl: null,
      tail: null,
      stream: null,
      timer: null,
      pid: null,
      hostId: null
    })
  }
  return running.get(taskId)
}

export async function start(taskId, { hostId, conf, softDir = '/soft', kind = 'install' }, actor) {
  const host = hosts.get(hostId)
  if (!host) throw new Error('目标机不存在')
  if (!host.privateKey && !host.password) {
    throw new Error('目标机未配置 SSH 私钥或密码')
  }
  // 互斥：同一目标机同时只能有一个安装任务，否则两个 runInstaller 会互相破坏
  if (runningByHost.has(hostId)) {
    throw new Error(`目标机 ${host.host} 上已有正在执行的任务，请等待结束或先终止`)
  }

  const r = ensureTrack(taskId)
  if (r.status === 'running' || r.status === 'starting') {
    throw new Error('该任务已在执行中')
  }
  r.status = 'starting'
  r.hostId = hostId
  r.timer = null
  r.pid = null

  runningByHost.set(hostId, taskId)

  const finish = async (status, extra = {}) => {
    if (r.timer) clearInterval(r.timer)
    r.status = status
    tasks.update(taskId, { status, finishedAt: Date.now(), ...extra })
    broadcast(taskId, { type: 'status', status })
    broadcast(taskId, { type: 'done', status })
    try {
      r.stream?.close?.()
    } catch {
      /* noop */
    }
    r.tail?.end()
    r.ctrl?.end()
    // 释放目标机占用
    if (runningByHost.get(r.hostId) === taskId) runningByHost.delete(r.hostId)
    // 结束后保留一段时间，便于前端拉取缓冲日志
    setTimeout(() => running.delete(taskId), 10 * 60 * 1000)
  }

  try {
    r.ctrl = await connectHost(host)
    push(taskId, 'info', `已连接 ${host.username}@${host.host}:${host.port || 22}`)

    const ready = await execCapture(
      r.ctrl,
      `test -x ${softDir}/run_all.sh && test -d ${softDir}/lib && echo yes || echo no`
    )
    if (!String(ready.out).includes('yes')) {
      push(taskId, 'err', `${softDir} 下未找到 run_all.sh 或 lib/ 目录，请先部署脚本`)
      await finish('failed')
      return
    }

    // 只读环境检查：不带任何副作用，验证脚本能在目标机 bash 上正常加载并执行
    if (kind === 'check') {
      r.status = 'running'
      tasks.update(taskId, { status: 'running', kind, host: host.host, softDir })
      broadcast(taskId, { type: 'status', status: 'running' })
      const cmd = `cd ${softDir} && sh run_all.sh -h`
      push(taskId, 'info', `执行只读检查：${cmd}`)
      const { code } = await execStream(r.ctrl, cmd, (chunk) => push(taskId, 'out', chunk))
      push(taskId, code === 0 ? 'info' : 'err', `检查结束，退出码 ${code}`)
      audit(actor, 'check_env', { host: host.host, taskId, exitCode: code })
      await finish(code === 0 ? 'success' : 'failed', { exitCode: code })
      return
    }

    if (!conf) {
      push(taskId, 'err', '缺少安装配置内容')
      await finish('failed')
      return
    }

    const confPath = `${softDir}/install.conf`
    await uploadConf(r.ctrl, conf, confPath)
    push(taskId, 'info', `已上传配置文件 ${confPath}`)
    audit(actor, 'upload_conf', { host: host.host, path: confPath, taskId })

    // 后台启动，输出重定向到日志文件，便于断线重连后继续 tail
    // 注意：-c 必须用绝对路径 —— bash 的 source 对不含斜杠的名字只搜 $PATH，不搜当前目录
    // 注意：必须用「子 shell 双 fork」方式启动，否则 sshd 的通道会因父进程未退出而挂住，
    //       runner 会一直等不到 execCapture 返回（真机测试踩过）
    const runLog = `${softDir}/.oracle_run_${taskId}.log`
    const startCmd =
      `cd ${softDir} && rm -f ${runLog} && ` +
      `( setsid nohup sh run_all.sh -c ${confPath} > ${runLog} 2>&1 < /dev/null & ) && ` +
      `sleep 1 && pgrep -f 'run_all.sh -c ${confPath}' | head -1`
    const { out } = await execCapture(r.ctrl, startCmd)
    r.pid = String(out).trim().split('\n').filter(Boolean).pop() || ''
    tasks.update(taskId, { pid: r.pid, host: host.host, softDir, runLog })
    push(taskId, 'info', `已启动 run_all.sh（pid ${r.pid}）`)
    audit(actor, 'start_install', { host: host.host, taskId, softDir })

    r.status = 'running'
    tasks.update(taskId, { status: 'running', startedAt: Date.now() })
    broadcast(taskId, { type: 'status', status: 'running' })

    // 日志流：独立连接 tail -f
    r.tail = await connectHost(host)
    execStream(r.tail, `tail -f -n +1 ${runLog}`, (chunk) => push(taskId, 'out', chunk)).catch(
      () => {
        /* 正常结束或连接断开 */
      }
    )

    // 进度：轮询状态文件里的 STAGE 标记
    r.timer = setInterval(async () => {
      try {
        if (!r.ctrl || !r.ctrl._sock || r.ctrl._sock.destroyed) return
        const st = await readStages(r.ctrl, softDir)
        if (JSON.stringify(st) !== JSON.stringify(r.stages)) {
          r.stages = st
          tasks.update(taskId, { stages: st })
          broadcast(taskId, { type: 'stage', stages: st })
        }
        // 进程退出则判定结束
        const { out: alive } = await execCapture(
          r.ctrl,
          `ps -p ${r.pid} > /dev/null 2>&1 && echo yes || echo no`
        )
        if (!String(alive).includes('yes')) {
          const t = tasks.get(taskId)
          const done = Object.values(st).filter(Boolean).length
          await finish(done === 4 ? 'success' : 'failed', { stages: st, exitHint: (t || {}).status })
        }
      } catch {
        /* 轮询失败不打断任务 */
      }
    }, 3000)
  } catch (e) {
    push(taskId, 'err', String(e.message || e))
    if (e.stack) push(taskId, 'err', '\n' + e.stack)
    audit(actor, 'task_error', { taskId, error: String(e.message || e) })
    await finish('failed', { error: String(e.message || e) })
  }
}

export async function stop(taskId, actor) {
  const r = running.get(taskId)
  const t = tasks.get(taskId)
  if (!r || !t) return false
  try {
    if (r.ctrl && t.pid) {
      // 终止整个进程组，避免子进程残留
      await execCapture(r.ctrl, `pkill -TERM -P ${t.pid} 2>/dev/null; kill -TERM ${t.pid} 2>/dev/null; true`)
    }
    push(taskId, 'warn', '已收到终止请求')
    audit(actor, 'stop_install', { taskId, host: t.host })
    return true
  } catch {
    return false
  }
}
