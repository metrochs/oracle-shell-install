<script setup>
import { ref, reactive, onUnmounted, computed, nextTick } from 'vue'
import { api, subscribeTask, getToken, setToken } from '../api.js'

const props = defineProps({
  conf: { type: String, required: true },
  errorCount: { type: Number, default: 0 }
})

const hosts = ref([])
const tasks = ref([])
const auditLog = ref([])
const loading = ref(false)
const msg = ref('')

const selectedHost = ref('')
const currentTask = ref(null)
const status = ref('')
const stages = ref({})
const logs = ref([])
const logBox = ref(null)
let unsub = null

const showAddHost = ref(false)
const newHost = reactive({
  name: '', host: '', port: 22, username: 'root', softDir: '/soft', privateKey: '', passphrase: ''
})

const STAGE_NAMES = {
  1: 'OS 配置',
  2: '软件安装',
  3: '数据库创建',
  4: '后期配置'
}
const progress = computed(() => Object.values(stages.value).filter(Boolean).length)

const online = computed(() => !!getToken())

async function refresh() {
  loading.value = true
  msg.value = ''
  try {
    await api.health()
    hosts.value = await api.hosts()
    tasks.value = await api.tasks()
    auditLog.value = await api.audit()
    if (!selectedHost.value && hosts.value.length) selectedHost.value = hosts.value[0].id
  } catch (e) {
    msg.value = String(e.message || e)
  } finally {
    loading.value = false
  }
}
refresh()

function appendLog(kind, text) {
  const lines = String(text).split('\n')
  for (const l of lines) {
    if (l.trim() === '' && logs.value.length && logs.value[logs.value.length - 1].t === '') continue
    logs.value.push({ kind, t: l })
  }
  if (logs.value.length > 3000) logs.value.splice(0, logs.value.length - 3000)
  nextTick(() => {
    if (logBox.value) logBox.value.scrollTop = logBox.value.scrollHeight
  })
}

async function run() {
  if (!selectedHost.value) return (msg.value = '请先选择目标机')
  if (props.errorCount) return (msg.value = '参数存在错误，请先修正再执行')
  msg.value = ''
  logs.value = []
  stages.value = {}
  const host = hosts.value.find((h) => h.id === selectedHost.value)
  try {
    const t = await api.run(selectedHost.value, props.conf, host.softDir || '/soft')
    currentTask.value = t.id
    status.value = 'pending'
    unsub?.()
    unsub = subscribeTask(t.id, {
      onLog: (m) => appendLog(m.kind, m.text),
      onStage: (s) => (stages.value = s),
      onStatus: (s) => (status.value = s),
      onDone: (s) => {
        status.value = s
        refresh()
      },
      onError: (e) => (msg.value = String(e))
    })
  } catch (e) {
    msg.value = String(e.message || e)
  }
}

async function stop() {
  if (!currentTask.value) return
  await api.stopTask(currentTask.value)
  appendLog('warn', '已发送终止信号')
}

async function addHost() {
  try {
    hosts.value = await api.saveHost({ ...newHost })
    showAddHost.value = false
    newHost.privateKey = ''
    newHost.passphrase = ''
    msg.value = '目标机已保存（私钥已加密存储）'
  } catch (e) {
    msg.value = String(e.message || e)
  }
}

async function testHost(id) {
  msg.value = '正在测试连接...'
  try {
    const r = await api.testHost(id)
    msg.value = r.ready ? '连接正常，目标机脚本已就绪' : '连接正常，但未找到 run_all.sh / lib 目录'
  } catch (e) {
    msg.value = String(e.message || e)
  }
}

async function removeHost(id) {
  hosts.value = await api.deleteHost(id)
  if (selectedHost.value === id) selectedHost.value = ''
}

onUnmounted(() => unsub?.())
</script>

<template>
  <div class="deploy">
    <div class="bar">
      <div class="tok">
        <span>API Token</span>
        <input
          :value="getToken()"
          type="password"
          placeholder="后端 .env 中的 API_TOKEN"
          @change="setToken($event.target.value); refresh()"
        />
      </div>
      <button :disabled="loading" @click="refresh">刷新</button>
      <span v-if="msg" class="msg">{{ msg }}</span>
    </div>

    <div v-if="!online" class="hint">
      请先填写 API Token（后端 .env 里的 API_TOKEN），并确保后端已启动。
    </div>

    <div class="grid">
      <section class="panel">
        <h3>目标机</h3>
        <div v-for="h in hosts" :key="h.id" class="host" :class="{ on: selectedHost === h.id }">
          <label>
            <input v-model="selectedHost" type="radio" :value="h.id" />
            <span>{{ h.name }} <em class="mono">{{ h.username }}@{{ h.host }}:{{ h.port }}</em></span>
          </label>
          <span class="ops">
            <button class="ghost" @click="testHost(h.id)">测试</button>
            <button class="ghost" @click="removeHost(h.id)">删除</button>
          </span>
        </div>
        <p v-if="!hosts.length" class="tip">还没有登记目标机。</p>

        <button v-if="!showAddHost" class="ghost" @click="showAddHost = true">+ 登记目标机</button>
        <div v-else class="form">
          <div class="row2">
            <input v-model="newHost.name" placeholder="名称，如 生产库-01" />
            <input v-model="newHost.host" placeholder="IP 或主机名" />
          </div>
          <div class="row3">
            <input v-model="newHost.username" placeholder="用户名" />
            <input v-model="newHost.port" type="number" placeholder="22" />
            <input v-model="newHost.softDir" placeholder="/soft" />
          </div>
          <textarea
            v-model="newHost.privateKey"
            placeholder="SSH 私钥内容（-----BEGIN ... KEY-----），服务端会加密存储"
            rows="5"
          />
          <input v-model="newHost.passphrase" type="password" placeholder="私钥口令（可留空）" />
          <div class="row2">
            <button class="primary" @click="addHost">保存</button>
            <button @click="showAddHost = false">取消</button>
          </div>
          <p class="tip">
            私钥经 AES-256-GCM 加密后落盘，接口永远只返回 hasKey 标记，不会回传私钥内容。
          </p>
        </div>
      </section>

      <section class="panel wide">
        <div class="head">
          <h3>执行</h3>
          <div class="ops">
            <button class="primary" :disabled="!selectedHost || !!errorCount" @click="run">
              开始安装
            </button>
            <button :disabled="!currentTask || status !== 'running'" @click="stop">终止</button>
          </div>
        </div>

        <div class="steps">
          <div v-for="(n, k) in STAGE_NAMES" :key="k" class="step" :class="{ done: stages[k] }">
            <i>{{ k }}</i><span>{{ n }}</span>
          </div>
        </div>
        <div class="pbar"><div class="fill" :style="{ width: (progress / 4) * 100 + '%' }" /></div>

        <div class="status">
          状态：<strong :class="status">{{ status || '未开始' }}</strong>
          <span v-if="currentTask" class="mono">任务 {{ currentTask }}</span>
        </div>

        <pre ref="logBox" class="log mono"><span
          v-for="(l, i) in logs"
          :key="i"
          :class="l.kind"
        >{{ l.t }}
</span><span v-if="!logs.length" class="tip">日志将在这里实时输出…</span></pre>
      </section>
    </div>

    <section class="panel">
      <h3>审计日志</h3>
      <ul class="audit">
        <li v-for="(a, i) in auditLog.slice(0, 20)" :key="i">
          <span class="mono">{{ a.ts }}</span>
          <span>{{ a.actor }}</span>
          <span class="act">{{ a.action }}</span>
          <span class="mono">{{ a.host || '' }}</span>
        </li>
      </ul>
      <p v-if="!auditLog.length" class="tip">暂无记录。</p>
    </section>
  </div>
</template>

<style scoped>
.deploy { display: flex; flex-direction: column; gap: 16px; }
.bar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.tok { display: flex; align-items: center; gap: 6px; }
.tok span { font-size: 12px; color: var(--text-2); }
.tok input { width: 260px; }
.msg { font-size: 12px; color: var(--err); }
.hint {
  background: var(--warn-soft);
  color: var(--warn);
  border-radius: 6px;
  padding: 8px 12px;
  font-size: 13px;
}
.grid { display: grid; grid-template-columns: 340px minmax(0, 1fr); gap: 16px; align-items: start; }
.panel {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 14px 16px;
}
.panel.wide { min-width: 0; }
h3 { font-size: 13px; font-weight: 500; margin: 0 0 10px; }
.head { display: flex; justify-content: space-between; align-items: center; }
.ops { display: flex; gap: 4px; }
.host {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  padding: 6px 0;
  border-bottom: 1px dashed var(--border);
}
.host.on { background: var(--brand-soft); border-radius: 6px; padding: 6px 8px; }
.host label { display: flex; align-items: center; gap: 8px; cursor: pointer; }
.host label input { width: auto; }
em { font-style: normal; color: var(--text-3); font-size: 11px; }
.form { display: flex; flex-direction: column; gap: 8px; margin-top: 10px; }
.row2 { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.row3 { display: grid; grid-template-columns: 1fr 80px 1fr; gap: 8px; }
textarea {
  font-family: var(--mono);
  font-size: 11px;
  border: 1px solid var(--border-strong);
  border-radius: 6px;
  padding: 8px;
  width: 100%;
  resize: vertical;
}
.steps { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin: 10px 0 6px; }
.step {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--text-3);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 6px 8px;
}
.step i {
  font-style: normal;
  width: 18px;
  height: 18px;
  line-height: 18px;
  text-align: center;
  border-radius: 50%;
  background: var(--surface-alt);
  border: 1px solid var(--border-strong);
  font-size: 11px;
}
.step.done { color: var(--ok); border-color: var(--ok); background: var(--ok-soft); }
.step.done i { background: var(--ok); color: #fff; border-color: var(--ok); }
.pbar { height: 4px; background: var(--surface-alt); border-radius: 4px; overflow: hidden; }
.fill { height: 100%; background: var(--brand); transition: width 0.4s; }
.status { font-size: 12px; margin: 8px 0; color: var(--text-2); }
.status .running { color: var(--brand); }
.status .success { color: var(--ok); }
.status .failed { color: var(--err); }
.log {
  height: 320px;
  overflow: auto;
  background: #1d2129;
  color: #d7dbe0;
  border-radius: 6px;
  padding: 10px;
  margin: 0;
  white-space: pre-wrap;
  word-break: break-all;
}
.log .err { color: #ff8a8a; }
.log .warn { color: #ffd479; }
.log .info { color: #7fb2ff; }
.log .tip { color: #7a828e; }
.audit { list-style: none; margin: 0; padding: 0; font-size: 12px; }
.audit li {
  display: grid;
  grid-template-columns: 170px 90px 130px 1fr;
  gap: 10px;
  padding: 4px 0;
  border-bottom: 1px dashed var(--border);
  color: var(--text-2);
}
.act { color: var(--brand); }
.tip { font-size: 12px; color: var(--text-3); }
@media (max-width: 1080px) {
  .grid { grid-template-columns: 1fr; }
}
</style>
