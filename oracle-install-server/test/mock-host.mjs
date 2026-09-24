import ssh2 from 'ssh2'
import crypto from 'node:crypto'

const { Server } = ssh2

/**
 * 模拟目标机：提供一个不需要真实 Linux 主机的 SSH 端点，
 * 用于端到端验证 runner.js 的 上传 → 启动 → tail → 进度轮询 → 收尾 全链路。
 *
 * 行为模拟：
 *   test -x ...            → yes（脚本目录已就绪）
 *   nohup sh run_all.sh    → 返回 pid
 *   tail -f 日志           → 分段吐安装日志并保持连接
 *   grep STAGE             → 按时间推进返回 STAGE1~4_DONE
 *   ps -p <pid>            → 前期 yes，结束后 no
 *   sftp OPEN/WRITE/CLOSE  → 接收上传内容并记录
 */
export async function startMockHost(port = 2223, opts = {}) {
  const timeline = opts.timeline || [300, 3300, 6300, 9300]
  const exitAfter = opts.exitAfter || 11500

  const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  const hostKey = privateKey.export({ type: 'pkcs1', format: 'pem' })
  const publicKeyPem = privateKey.export({ type: 'pkcs1', format: 'pem' })

  const state = {
    pid: 4242,
    alive: true,
    stages: { 1: false, 2: false, 3: false, 4: false },
    uploaded: [],
    execLog: [],
    tailStreams: []
  }

  timeline.forEach((delay, i) => {
    setTimeout(() => {
      state.stages[i + 1] = true
      for (const s of state.tailStreams) {
        s.write(`\n[stage] STAGE${i + 1}_DONE=Y ${'阶段' + (i + 1)}完成\n`)
      }
    }, delay)
  })
  setTimeout(() => {
    state.alive = false
    for (const s of state.tailStreams) s.write('\n[stage] run_all.sh 执行结束\n')
  }, exitAfter)

  const srv = new Server({ hostKeys: [hostKey] }, (client) => {
    client.on('authentication', (ctx) => {
      if (ctx.method === 'publickey' && ctx.key && ctx.key.data && ctx.key.data.length > 0) {
        return ctx.accept()
      }
      return ctx.reject()
    })
    client.on('ready', () => {
      client.on('session', (accept) => {
        const session = accept()
        session.once('exec', (accept2, reject2, info) => {
          const stream = accept2()
          const cmd = info.command
          state.execLog.push(cmd)
          handle(stream, cmd)
        })
        if (opts.sftp === false) return session.once('sftp', (a2, r2) => r2())
        session.once('sftp', (accept2) => {
          const sftp = accept2()
          sftp.on('REQUEST', (reqID, method, args) => {
            switch (method) {
              case 'OPEN':
                return sftp.handle(reqID, Buffer.from('01'))
              case 'WRITE':
                state.uploaded.push(String(args[2]))
                return sftp.status(reqID, 'OK')
              default:
                // 其余请求（SETSTAT/CLOSE/FSTAT 等）一律放行，保证上传能走通
                return sftp.status(reqID, 'OK')
            }
          })
        })
      })
    })
  })

  function handle(stream, cmd) {
    if (cmd.startsWith('test -x')) return respond(stream, 'yes\n')
    if (cmd.includes('nohup sh run_all.sh')) {
      for (const s of state.tailStreams) {
        s.write('\n[stage] run_all.sh 已启动\n')
      }
      return respond(stream, `${state.pid}\n`, 60)
    }
    if (cmd.startsWith('tail -f')) {
      state.tailStreams.push(stream)
      stream.write('OracleShellInstall 开始安装，详细安装过程可查看日志\n')
      stream.write('正在获取操作系统信息......已完成\n')
      return
    }
    if (cmd.startsWith('grep -E')) {
      const out = Object.entries(state.stages)
        .map(([k, v]) => `STAGE${k}_DONE=${v ? 'Y' : 'N'}`)
        .join('\n')
      return respond(stream, out + '\n')
    }
    if (cmd.startsWith('ps -p')) return respond(stream, state.alive ? 'yes\n' : 'no\n')
    if (cmd.includes('wc -l')) return respond(stream, '2\n')
    return respond(stream, '\n')
  }

  function respond(stream, text, delay = 30) {
    stream.write(text)
    setTimeout(() => {
      stream.exit(0)
      stream.end()
    }, delay)
  }

  await new Promise((resolve, reject) => {
    srv.once('error', reject)
    srv.listen(port, '127.0.0.1', resolve)
  })

  return {
    port,
    privateKeyPem: publicKeyPem,
    state,
    close() {
      for (const s of state.tailStreams) {
        try {
          s.end()
        } catch {
          /* noop */
        }
      }
      srv.close()
    }
  }
}
