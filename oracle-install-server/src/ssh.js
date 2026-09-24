import ssh2 from 'ssh2'
import { decrypt } from './crypto.js'

const { Client } = ssh2

export function connectHost(h) {
  return new Promise((resolve, reject) => {
    const opts = {
      host: h.host,
      port: Number(h.port) || 22,
      username: h.username || 'root',
      readyTimeout: 20000,
      keepaliveInterval: 15000,
      keepaliveCountMax: 3
    }
    // 支持私钥或密码两种认证方式，均以密文存储
    if (h.privateKey) {
      opts.privateKey = decrypt(h.privateKey)
      if (h.passphrase) opts.passphrase = decrypt(h.passphrase)
    } else if (h.password) {
      opts.password = decrypt(h.password)
    } else {
      return reject(new Error('目标机未配置私钥或密码'))
    }

    const conn = new Client()
    const timer = setTimeout(() => {
      conn.end()
      reject(new Error(`连接 ${h.host} 超时`))
    }, 25000)
    conn.on('ready', () => {
      clearTimeout(timer)
      resolve(conn)
    })
    conn.on('error', (err) => {
      clearTimeout(timer)
      reject(err)
    })
    conn.connect(opts)
  })
}

export function upload(conn, content, remotePath) {
  return new Promise((resolve, reject) => {
    conn.sftp((err, sftp) => {
      if (err) return reject(err)
      const ws = sftp.createWriteStream(remotePath, { mode: 0o600 })
      ws.on('error', reject)
      ws.on('close', resolve)
      ws.end(content, 'utf8')
    })
  })
}

/**
 * 上传配置文件。
 * 优先走 SFTP；部分加固过的主机禁用了 SFTP 子系统，此时回退到
 * exec + base64 写入（base64 不含引号与特殊字符，不会破坏命令行）。
 */
export async function uploadConf(conn, content, remotePath) {
  try {
    await upload(conn, content, remotePath)
  } catch (e) {
    const b64 = Buffer.from(content, 'utf8').toString('base64')
    await execCapture(
      conn,
      `umask 077 && printf %s '${b64}' | base64 -d > ${remotePath} && wc -c < ${remotePath}`
    )
  }
}

/** 流式执行，onData 收到增量输出；返回退出码 */
export function execStream(conn, cmd, onData) {
  return new Promise((resolve, reject) => {
    conn.exec(cmd, (err, stream) => {
      if (err) return reject(err)
      let settled = false
      stream.on('close', (code, signal) => {
        if (settled) return
        settled = true
        resolve({ code, signal })
      })
      stream.on('data', (d) => onData(d.toString('utf8')))
      stream.stderr.on('data', (d) => onData(d.toString('utf8')))
    })
  })
}

/** 短命令执行，一次性取回输出 */
export async function execCapture(conn, cmd) {
  let out = ''
  const { code } = await execStream(conn, cmd, (d) => {
    out += d
  })
  return { code, out }
}

/** 读取目标机状态文件中的阶段完成标记 */
export async function readStages(conn, softDir) {
  const { out } = await execCapture(
    conn,
    `grep -E '^STAGE[0-9]_DONE=' ${softDir}/.oracle_install_env 2>/dev/null || true`
  )
  const stages = {}
  for (const line of out.split('\n')) {
    const m = /^STAGE(\d)_DONE=(.*)$/.exec(line.trim())
    if (m) stages[m[1]] = m[2] === 'Y'
  }
  return stages
}

/** 探测目标机脚本目录是否就绪 */
export async function probe(conn, softDir) {
  const { out } = await execCapture(
    conn,
    `ls -1 ${softDir}/run_all.sh ${softDir}/lib 2>/dev/null | wc -l`
  )
  return Number(String(out).trim()) >= 1
}
