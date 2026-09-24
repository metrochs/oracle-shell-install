const BASE = import.meta.env.VITE_API_BASE || '/api'

export function getToken() {
  return localStorage.getItem('oracle-ui-token') || ''
}
export function setToken(t) {
  localStorage.setItem('oracle-ui-token', t)
}

function wsBase() {
  const explicit = import.meta.env.VITE_WS_BASE
  if (explicit) return explicit
  const p = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${p}//${location.host}`
}

async function req(path, options = {}) {
  const res = await fetch(`${BASE}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${getToken()}`,
      ...(options.headers || {})
    }
  })
  if (res.status === 401) throw new Error('未授权：请检查 API Token 配置')
  const text = await res.text()
  let data = null
  try {
    data = text ? JSON.parse(text) : null
  } catch {
    data = text
  }
  if (!res.ok) throw new Error((data && data.error) || `请求失败 ${res.status}`)
  return data
}

export const api = {
  health: () => req('/health'),
  hosts: () => req('/hosts'),
  saveHost: (h) => req('/hosts', { method: 'POST', body: JSON.stringify(h) }),
  deleteHost: (id) => req(`/hosts/${id}`, { method: 'DELETE' }),
  testHost: (id) => req(`/hosts/${id}/test`, { method: 'POST' }),

  run: (hostId, conf, softDir) =>
    req('/tasks', { method: 'POST', body: JSON.stringify({ hostId, conf, softDir }) }),
  tasks: () => req('/tasks'),
  task: (id) => req(`/tasks/${id}`),
  stopTask: (id) => req(`/tasks/${id}/stop`, { method: 'POST' }),

  audit: () => req('/audit')
}

/** 订阅任务日志，返回关闭函数 */
export function subscribeTask(taskId, { onLog, onStage, onStatus, onDone, onError }) {
  const url = `${wsBase()}/ws/tasks/${taskId}?token=${encodeURIComponent(getToken())}`
  const ws = new WebSocket(url)
  ws.onmessage = (e) => {
    let msg
    try {
      msg = JSON.parse(e.data)
    } catch {
      return
    }
    if (msg.type === 'log') onLog?.(msg)
    else if (msg.type === 'stage') onStage?.(msg.stages || {})
    else if (msg.type === 'status') onStatus?.(msg.status)
    else if (msg.type === 'done') onDone?.(msg.status)
    else if (msg.type === 'error') onError?.(msg.text)
  }
  ws.onerror = () => onError?.('WebSocket 连接失败')
  return () => {
    try {
      ws.close()
    } catch {
      /* noop */
    }
  }
}
