import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { connectHost, uploadConf, execCapture } from './ssh.js'

const HERE = path.dirname(fileURLToPath(import.meta.url))
/** 拆分后的脚本目录（阶段脚本 + lib） */
export const SCRIPTS_DIR = path.join(HERE, '..', '..', 'OracleShellInstall')

const TOP_FILES = [
  'run_all.sh',
  '1_os_config.sh',
  '2_software_install.sh',
  '3_db_create.sh',
  '4_post_config.sh'
]

/** 收集需要下发的脚本文件（相对路径） */
export function collectScripts() {
  const files = []
  for (const f of TOP_FILES) {
    const p = path.join(SCRIPTS_DIR, f)
    if (!fs.existsSync(p)) throw new Error(`缺少脚本文件：${f}`)
    files.push({ rel: f, abs: p })
  }
  const libDir = path.join(SCRIPTS_DIR, 'lib')
  if (!fs.existsSync(libDir)) throw new Error('缺少 lib 目录')
  for (const f of fs.readdirSync(libDir)) {
    if (f.endsWith('.sh')) files.push({ rel: `lib/${f}`, abs: path.join(libDir, f) })
  }
  // 关键：目标机是 Linux，相对路径必须统一用正斜杠（Windows 上 path.join 会产生反斜杠，
  // 会在目标机上创建名为 "lib\xxx.sh" 的字面文件而不是 lib/ 子目录）
  for (const f of files) {
    f.rel = String(f.rel).split('\\').join('/')
  }
  return files
}

/**
 * 生成自解压安装脚本：每个文件一段 base64，目标机上 base64 -d 还原。
 * 用 heredoc 走 stdin，不受单参数 128KB 限制。
 */
export function buildDeployScript(softDir) {
  const files = collectScripts()
  const dirs = new Set(files.map((f) => path.posix.join(softDir, path.posix.dirname(f.rel))))
  let sh = '#!/bin/bash\nset -e\n'
  for (const d of dirs) sh += `mkdir -p '${d}'\n`
  for (const f of files) {
    const b64 = fs.readFileSync(f.abs).toString('base64')
    sh += `base64 -d > '${path.posix.join(softDir, f.rel)}' <<'ORACLE_EOF_${f.rel.replace(/[^a-z]/gi, '')}'\n`
    sh += b64 + '\n'
    sh += `ORACLE_EOF_${f.rel.replace(/[^a-z]/gi, '')}\n`
  }
  for (const f of files) sh += `chmod +x '${path.posix.join(softDir, f.rel)}'\n`
  sh += `echo DEPLOY_OK\n`
  return { script: sh, files, bytes: Buffer.byteLength(sh) }
}

/** 把脚本目录下发到目标机 softDir 并校验 */
export async function deployScripts(host, actor) {
  const softDir = host.softDir || '/soft'
  const { script, files, bytes } = buildDeployScript(softDir)
  const conn = await connectHost(host)
  try {
    const tmp = `${softDir}/.oracle_deploy_$$.sh`
    await execCapture(conn, `mkdir -p '${softDir}'`)
    await uploadConf(conn, script, tmp)
    const { code, out } = await execCapture(conn, `bash '${tmp}' && rm -f '${tmp}'`)
    if (code !== 0 || !String(out).includes('DEPLOY_OK')) {
      throw new Error(`目标机执行部署脚本失败（退出码 ${code}）：${String(out).slice(-300)}`)
    }
    // 校验关键文件就位
    const check = await execCapture(
      conn,
      `test -x ${softDir}/run_all.sh && test -d ${softDir}/lib && echo READY || echo MISSING`
    )
    const ready = String(check.out).includes('READY')
    return { ok: true, ready, files: files.length, bytes, host: host.host, softDir }
  } finally {
    conn.end()
  }
}
