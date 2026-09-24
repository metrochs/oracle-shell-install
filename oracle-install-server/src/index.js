import Fastify from 'fastify'
import websocket from '@fastify/websocket'
import { HOST, PORT, ROOT } from './config.js'
import routes from './routes.js'
import { audit } from './audit.js'

const app = Fastify({ logger: { level: process.env.LOG_LEVEL || 'info' } })
await app.register(websocket)
await app.register(routes)

// 静态托管前端构建产物（若存在），实现单端口部署
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const here = path.dirname(fileURLToPath(import.meta.url))
const webDist = path.join(here, '..', '..', 'oracle-install-ui', 'dist')
if (fs.existsSync(path.join(webDist, 'index.html'))) {
  const { default: fastifyStatic } = await import('@fastify/static').catch(() => ({ default: null }))
  if (fastifyStatic) {
    await app.register(fastifyStatic, { root: webDist })
    app.log.info(`静态托管前端：${webDist}`)
  }
}

try {
  await app.listen({ host: HOST, port: PORT })
  audit('system', 'server_start', { host: HOST, port: PORT })
  app.log.info(`监听 http://${HOST}:${PORT}（仅内网，切勿暴露公网）`)
} catch (err) {
  app.log.error(err)
  process.exit(1)
}

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, async () => {
    audit('system', 'server_stop', {})
    await app.close()
    process.exit(0)
  })
}
