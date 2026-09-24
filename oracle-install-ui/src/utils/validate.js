import matrixData from '../data/matrix.json'

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/

function isIp(v) {
  const m = IPV4.exec(v)
  if (!m) return false
  return m.slice(1).every((n) => Number(n) >= 0 && Number(n) <= 255)
}

/** 单个字段校验，返回 { errors, warnings } */
export function validateField(p, raw, isRequired) {
  const errors = []
  const warnings = []
  const v = (raw ?? '').toString().trim()

  if (isRequired && !v) {
    errors.push('此项必填')
    return { errors, warnings }
  }
  if (!v) return { errors, warnings }

  switch (p.type) {
    case 'number':
      if (!/^\d+$/.test(v)) errors.push('必须为数字')
      else if (p.min != null && Number(v) < p.min) errors.push(`不能小于 ${p.min}`)
      break
    case 'yn':
      if (!/^[YN]$/.test(v)) errors.push('只能为 Y 或 N')
      break
    case 'tf':
      if (!/^(true|false)$/.test(v)) errors.push('只能为 true 或 false')
      break
    case 'enum':
      if (!p.enum.some((e) => e.v === v)) errors.push('取值不在允许范围内')
      break
    case 'enum-search':
      if (!p.options.includes(v)) errors.push('取值不在允许范围内')
      break
    default:
      break
  }

  switch (p.validate) {
    case 'ip':
      if (!isIp(v)) errors.push('IP 地址格式不正确')
      break
    case 'iplist': {
      const items = v.split(',').map((s) => s.trim()).filter(Boolean)
      const bad = items.filter((s) => !isIp(s))
      if (bad.length) errors.push(`以下不是合法 IP：${bad.join('、')}`)
      break
    }
    case 'orapwd':
      if (!/^[a-zA-Z][a-zA-Z0-9#$_]*$/.test(v)) {
        errors.push('必须以字母开头，且只能包含字母、数字、_、#、$')
      }
      break
    case 'dbname': {
      const items = v.split(',').map((s) => s.trim()).filter(Boolean)
      const bad = items.filter((s) => !/^[a-zA-Z0-9]+$/.test(s))
      if (bad.length) errors.push('数据库名只能包含字母和数字，不要使用特殊字符')
      const tooLong = items.filter((s) => s.length > 12)
      if (tooLong.length) errors.push('数据库名长度不能超过 12 位')
      else if (items.some((s) => s.length > 8)) {
        warnings.push('超过 8 位的数据库名在建库时会被自动截断为前 8 位')
      }
      break
    }
    case 'nostartdigit':
      if (/^[0-9]/.test(v)) errors.push('不能以数字开头')
      break
    default:
      break
  }

  if (p.key === 'cluster_name' && v.length > 15) errors.push('集群名称长度不能超过 15 位')

  return { errors, warnings }
}

/** 版本 / 架构 / 操作系统 兼容矩阵校验 */
export function matrixIssues(env, dbVersion) {
  const out = []
  if (!dbVersion) return out
  const arch = env.arch || 'x86_64'
  const byArch = matrixData.versionMatrix[arch] || {}
  const rule = byArch[dbVersion]
  if (!rule) {
    const allow = Object.keys(byArch).join('、')
    out.push({ level: 'error', msg: `架构 ${arch} 仅支持数据库版本：${allow || '无'}` })
    return out
  }
  const list = env.os === 'sles' ? rule.sles : rule.linux
  if (!list.length) {
    out.push({ level: 'error', msg: `${env.os} 上不支持安装该数据库版本` })
  } else if (!list.includes(Number(env.osVersion))) {
    out.push({
      level: 'error',
      msg: `该数据库版本在 ${env.os} 上仅支持 Linux ${list.join(' / ')}，当前选择 ${env.osVersion}`
    })
  }
  if (arch === 'aarch64') {
    out.push({ level: 'warn', msg: 'ARM 平台需要 CPU 支持 atomics 特性，且仅 19c 经过验证' })
  }
  return out
}

/** 跨字段一致性校验 */
export function crossChecks(form) {
  const out = []

  if (form.oracle_install_mode === 'rac') {
    const gi = form.gi_version || form.db_version
    if (gi && form.db_version && Number(gi) < Number(form.db_version)) {
      out.push({ level: 'error', msg: `Grid 版本 ${gi} 必须大于等于数据库版本 ${form.db_version}` })
    }
    const scan = (form.rac_scan_ip || '').split(',').map((s) => s.trim()).filter(Boolean)
    if (scan.length > 1 && form.dns !== 'Y') {
      out.push({ level: 'error', msg: 'SCAN IP 超过 1 个时必须开启 DNS 配置' })
    }
    const pub = (form.rac_public_ip || '').split(',').map((s) => s.trim()).filter(Boolean)
    const hn = (form.rac_hostname || '').split(',').map((s) => s.trim()).filter(Boolean)
    if (pub.length && hn.length && pub.length !== hn.length) {
      out.push({
        level: 'error',
        msg: `节点公网 IP 数量 (${pub.length}) 与主机名数量 (${hn.length}) 不一致`
      })
    }
    const priv = (form.rac_priv_ifname || '').split(',').map((s) => s.trim()).filter(Boolean)
    if (priv.length > 2) out.push({ level: 'warn', msg: '心跳网卡不建议超过 2 组' })
    if (form.db_version === '11' && hn.some((h) => /[A-Z]/.test(h))) {
      out.push({ level: 'error', msg: 'Oracle 11gR2 RAC 主机名不能包含大写字母' })
    }
    if (!form.cluster_name && (form.hostname || '').length > 7) {
      out.push({
        level: 'warn',
        msg: '未填集群名称且主机名超过 7 位，自动生成的集群名将超过 15 位限制'
      })
    }
  }

  if (form.oracle_install_mode === 'standalone' || form.oracle_install_mode === 'rac') {
    const disks = (form.data_base_disk || '').split(',').map((s) => s.trim()).filter(Boolean)
    if (form.data_redun === 'NORMAL' && disks.length && disks.length < 2) {
      out.push({ level: 'error', msg: 'DATA 磁盘组 NORMAL 冗余至少需要 2 块磁盘' })
    }
    if (form.data_redun === 'HIGH' && disks.length && disks.length < 3) {
      out.push({ level: 'error', msg: 'DATA 磁盘组 HIGH 冗余至少需要 3 块磁盘' })
    }
    if (form.oracle_install_mode === 'rac') {
      const ocr = (form.ocr_base_disk || '').split(',').map((s) => s.trim()).filter(Boolean)
      if (form.ocr_redun === 'NORMAL' && ocr.length && ocr.length < 3) {
        out.push({ level: 'error', msg: 'OCR 磁盘组 NORMAL 冗余至少需要 3 块磁盘' })
      }
      if (form.ocr_redun === 'HIGH' && ocr.length && ocr.length < 5) {
        out.push({ level: 'error', msg: 'OCR 磁盘组 HIGH 冗余至少需要 5 块磁盘' })
      }
      if (form.gi_version === '12' && !form.grid_patch) {
        out.push({
          level: 'warn',
          msg: '12cR2 未指定 Grid 补丁时，OCR 磁盘组需至少 50G 以容纳 GIMR 组件'
        })
      }
    }
  }

  if (['21', '26'].includes(form.db_version) && form.iscdb !== 'true') {
    out.push({ level: 'error', msg: '21c / 26ai 强制使用 CDB 架构，iscdb 必须为 true' })
  }
  if (form.pdbname && form.iscdb !== 'true') {
    out.push({ level: 'error', msg: '填写了 PDB 名称时，iscdb 必须为 true' })
  }
  if (form.only_conf_os === 'Y' && form.install_until_db === 'Y') {
    out.push({ level: 'warn', msg: '仅配置操作系统时，安装到数据库软件结束的设置不会生效' })
  }
  if (form.local_repo === 'Y' && form.net_repo === 'Y') {
    out.push({ level: 'warn', msg: '同时开启本地源与网络源时，网络源优先且本地源会被关闭' })
  }
  return out
}
