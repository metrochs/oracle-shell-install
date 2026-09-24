import fs from 'node:fs'
import path from 'node:path'
import { DATA_DIR } from './config.js'

const LOG = path.join(DATA_DIR, 'audit.log')

/**
 * 审计日志：记录谁在什么时候对哪台机做了什么。
 * 只记录元信息，绝不写入密码、私钥等敏感内容。
 */
export function audit(actor, action, detail = {}) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    actor: actor || 'anonymous',
    action,
    ...detail
  })
  try {
    fs.appendFileSync(LOG, line + '\n', 'utf8')
  } catch (e) {
    console.error('[audit] 写入失败', e.message)
  }
}

export function readAudit(limit = 200) {
  if (!fs.existsSync(LOG)) return []
  const lines = fs.readFileSync(LOG, 'utf8').trim().split('\n').filter(Boolean)
  return lines.slice(-limit).reverse().map((l) => {
    try {
      return JSON.parse(l)
    } catch {
      return { raw: l }
    }
  })
}
