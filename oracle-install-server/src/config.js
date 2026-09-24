import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const ROOT = path.join(HERE, '..')
export const DATA_DIR = path.join(ROOT, 'data')

/** 极简 .env 解析，避免引入额外依赖 */
function loadDotEnv(file = path.join(ROOT, '.env')) {
  if (!fs.existsSync(file)) return
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const t = line.trim()
    if (!t || t.startsWith('#')) continue
    const i = t.indexOf('=')
    if (i < 0) continue
    const k = t.slice(0, i).trim()
    const v = t.slice(i + 1).trim().replace(/^['"]|['"]$/g, '')
    if (!(k in process.env)) process.env[k] = v
  }
}
loadDotEnv()

export const PORT = Number(process.env.PORT || 3000)
/** 默认只监听回环地址，绝不直接暴露公网 */
export const HOST = process.env.HOST || '127.0.0.1'

/** API Token。未设置时拒绝启动，避免裸奔 */
export const API_TOKEN = process.env.API_TOKEN || ''

/** 私钥加密主密钥（32 字节，base64 或 64 位 hex） */
export const MASTER_KEY_RAW = process.env.MASTER_KEY || ''

fs.mkdirSync(DATA_DIR, { recursive: true })

if (!API_TOKEN) {
  console.error('[fatal] 未设置 API_TOKEN，拒绝启动。请先配置 .env（见 .env.example）')
  process.exit(1)
}
if (!MASTER_KEY_RAW) {
  console.error('[fatal] 未设置 MASTER_KEY，拒绝启动。可用 npm run keygen 生成')
  process.exit(1)
}
