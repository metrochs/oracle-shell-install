import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { DATA_DIR } from './config.js'

/**
 * 极简 JSON 持久化。数据量小（几十个模板 / 目标机 / 任务），
 * 不引入数据库，避免原生编译依赖；写入走临时文件 + rename 保证原子性。
 */
function file(name) {
  return path.join(DATA_DIR, `${name}.json`)
}

const cache = new Map()

function read(name) {
  if (cache.has(name)) return cache.get(name)
  const f = file(name)
  let data = []
  if (fs.existsSync(f)) {
    try {
      data = JSON.parse(fs.readFileSync(f, 'utf8'))
    } catch {
      data = []
    }
  }
  cache.set(name, data)
  return data
}

function write(name, data) {
  const f = file(name)
  const tmp = `${f}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf8')
  fs.renameSync(tmp, f)
  cache.set(name, data)
}

export const id = () => crypto.randomBytes(8).toString('hex')

export const templates = {
  list: () => read('templates'),
  upsert(item) {
    const all = read('templates')
    const i = all.findIndex((t) => t.name === item.name)
    if (i >= 0) all[i] = { ...all[i], ...item, updatedAt: Date.now() }
    else all.push({ id: id(), ...item, createdAt: Date.now(), updatedAt: Date.now() })
    write('templates', all)
    return all
  },
  remove(name) {
    const all = read('templates').filter((t) => t.name !== name)
    write('templates', all)
    return all
  }
}

export const hosts = {
  list() {
    // 私钥、密码等敏感内容永远不出后端
    return read('hosts').map(({ privateKey, password, passphrase, ...rest }) => ({
      ...rest,
      hasKey: !!privateKey,
      hasPassword: !!password
    }))
  },
  get(id) {
    return read('hosts').find((h) => h.id === id)
  },
  upsert(item) {
    const all = read('hosts')
    const i = all.findIndex((h) => h.id === item.id)
    if (i >= 0) all[i] = { ...all[i], ...item, updatedAt: Date.now() }
    else all.push({ id: id(), ...item, createdAt: Date.now(), updatedAt: Date.now() })
    write('hosts', all)
    return this.list()
  },
  remove(id) {
    write('hosts', read('hosts').filter((h) => h.id !== id))
    return this.list()
  }
}

export const tasks = {
  list: () => read('tasks').slice(-50).reverse(),
  get(id) {
    return read('tasks').find((t) => t.id === id)
  },
  create(item) {
    const all = read('tasks')
    const t = { id: id(), status: 'pending', createdAt: Date.now(), ...item }
    all.push(t)
    write('tasks', all)
    return t
  },
  update(id, patch) {
    const all = read('tasks')
    const i = all.findIndex((t) => t.id === id)
    if (i >= 0) {
      all[i] = { ...all[i], ...patch }
      write('tasks', all)
      return all[i]
    }
    return null
  }
}
