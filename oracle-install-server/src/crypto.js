import crypto from 'node:crypto'
import { MASTER_KEY_RAW } from './config.js'

const KEY = deriveKey(MASTER_KEY_RAW)

function deriveKey(raw) {
  // 支持 64 位 hex 或 base64(32字节)
  if (/^[0-9a-fA-F]{64}$/.test(raw)) return Buffer.from(raw, 'hex')
  const b = Buffer.from(raw, 'base64')
  if (b.length === 32) return b
  // 兜底：对任意口令做 scrypt 派生，保证始终得到 32 字节
  return crypto.scryptSync(raw, 'oracle-install-server', 32)
}

/** AES-256-GCM 加密，输出 base64( iv | tag | ciphertext ) */
export function encrypt(plain) {
  const iv = crypto.randomBytes(12)
  const cipher = crypto.createCipheriv('aes-256-gcm', KEY, iv)
  const enc = Buffer.concat([cipher.update(String(plain), 'utf8'), cipher.final()])
  const tag = cipher.getAuthTag()
  return Buffer.concat([iv, tag, enc]).toString('base64')
}

export function decrypt(payload) {
  const buf = Buffer.from(String(payload), 'base64')
  const iv = buf.subarray(0, 12)
  const tag = buf.subarray(12, 28)
  const enc = buf.subarray(28)
  const decipher = crypto.createDecipheriv('aes-256-gcm', KEY, iv)
  decipher.setAuthTag(tag)
  return Buffer.concat([decipher.update(enc), decipher.final()]).toString('utf8')
}

/** 恒定时间比较，防时序侧信道 */
export function safeEqual(a, b) {
  const ba = Buffer.from(String(a))
  const bb = Buffer.from(String(b))
  if (ba.length !== bb.length) return false
  return crypto.timingSafeEqual(ba, bb)
}
