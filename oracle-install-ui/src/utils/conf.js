import schema from '../data/schema.json'

/** 生成 install.conf 内容：只输出非空的 KEY=VALUE，空值交给脚本默认值 */
export function buildConf(form, visibleKeys) {
  const lines = [
    '# OracleShellInstall 配置文件',
    `# 生成时间：${new Date().toLocaleString('zh-CN')}`,
    '#',
    '# 用法：sh run_all.sh -c install.conf',
    '# 说明：命令行参数的优先级高于本文件',
    ''
  ]
  for (const p of schema.params) {
    if (!visibleKeys.has(p.key)) continue
    const v = (form[p.key] ?? '').toString().trim()
    if (!v) continue
    lines.push(`${p.key}=${v}`)
  }
  return lines.join('\n') + '\n'
}

/** 生成可复制的命令行（密码类字段用占位提示，避免明文外泄） */
export function buildCommand(form, visibleKeys) {
  const parts = ['sh run_all.sh']
  for (const p of schema.params) {
    if (!visibleKeys.has(p.key) || !p.flag) continue
    const v = (form[p.key] ?? '').toString().trim()
    if (!v) continue
    if (p.type === 'password') {
      parts.push(`${p.flag} '<${p.label}>'`)
    } else if (/\s/.test(v)) {
      parts.push(`${p.flag} '${v}'`)
    } else {
      parts.push(`${p.flag} ${v}`)
    }
  }
  return parts.join(' \\\n  ')
}

/** 解析 install.conf 文本，回填表单用 */
export function parseConf(text) {
  const values = {}
  const unknown = []
  const keys = new Set(schema.params.map((p) => p.key))
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const i = line.indexOf('=')
    if (i < 0) continue
    const k = line.slice(0, i).trim()
    const v = line.slice(i + 1).trim()
    if (!k) continue
    if (keys.has(k)) values[k] = v
    else unknown.push(k)
  }
  return { values, unknown }
}

export function downloadFile(filename, content) {
  const blob = new Blob([content], { type: 'text/plain;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

const LS_KEY = 'oracle-install-templates'

export function loadTemplates() {
  try {
    return JSON.parse(localStorage.getItem(LS_KEY) || '[]')
  } catch {
    return []
  }
}

export function saveTemplate(name, values) {
  const list = loadTemplates()
  const item = { name, ts: Date.now(), values: { ...values } }
  const idx = list.findIndex((t) => t.name === name)
  if (idx >= 0) list[idx] = item
  else list.push(item)
  localStorage.setItem(LS_KEY, JSON.stringify(list))
  return list
}

export function deleteTemplate(name) {
  const list = loadTemplates().filter((t) => t.name !== name)
  localStorage.setItem(LS_KEY, JSON.stringify(list))
  return list
}
