<script setup>
import { reactive, ref, computed, watch } from 'vue'
import schema from './data/schema.json'
import matrixData from './data/matrix.json'
import FieldControl from './components/FieldControl.vue'
import NodeTable from './components/NodeTable.vue'
import DeployPanel from './components/DeployPanel.vue'
import { validateField, matrixIssues, crossChecks } from './utils/validate.js'
import { buildConf, buildCommand, downloadFile, parseConf, loadTemplates, saveTemplate, deleteTemplate } from './utils/conf.js'

const { groups, params } = schema

// synthetic 参数（如 RAC 节点表格）只是 UI 编辑器，不进表单数据模型
const form = reactive(
  Object.fromEntries(
    params.filter((p) => !p.synthetic).map((p) => [p.key, p.default != null ? String(p.default) : ''])
  )
)

const env = reactive({ os: 'rhel', osVersion: '8', arch: 'x86_64' })
const activeGroup = ref('scene')
const showAdvanced = ref(false)
const view = ref('config')

const OS_VERSIONS = ['6', '7', '8', '9', '10']

// pdbname 填写即启用 CDB；21c / 26ai 强制 CDB
watch(() => form.pdbname, (v) => { if (String(v).trim()) form.iscdb = 'true' })
watch(() => form.db_version, (v) => { if (v === '21' || v === '26') form.iscdb = 'true' })

function matchWhen(cond) {
  if (!cond) return false
  return Object.entries(cond).every(([k, allow]) => allow.includes(form[k]))
}
function isVisible(p) {
  return !p.visibleWhen || matchWhen(p.visibleWhen)
}
function isRequired(p) {
  return !!p.required || matchWhen(p.requiredWhen)
}

// hidden 字段（如 RAC 节点三个键，由节点表格代为编辑）不单独渲染
const visibleParams = computed(() =>
  params.filter((p) => !p.hidden && !p.synthetic ? isVisible(p) : false)
)
const visibleKeys = computed(() => new Set(visibleParams.value.map((p) => p.key)))

const fieldIssues = computed(() => {
  const map = {}
  for (const p of visibleParams.value) {
    map[p.key] = validateField(p, form[p.key], isRequired(p))
  }
  return map
})

const matrix = computed(() => matrixIssues(env, form.db_version))
const cross = computed(() => crossChecks(form))

const fieldErrors = computed(() =>
  Object.entries(fieldIssues.value).flatMap(([k, v]) =>
    v.errors.map((msg) => ({ key: k, msg, label: params.find((p) => p.key === k)?.label || k }))
  )
)
const fieldWarnings = computed(() =>
  Object.entries(fieldIssues.value).flatMap(([k, v]) =>
    v.warnings.map((msg) => ({ key: k, msg, label: params.find((p) => p.key === k)?.label || k }))
  )
)

const errorCount = computed(
  () => fieldErrors.value.length + matrix.value.filter((i) => i.level === 'error').length +
        cross.value.filter((i) => i.level === 'error').length
)
const warnCount = computed(
  () => fieldWarnings.value.length + matrix.value.filter((i) => i.level === 'warn').length +
        cross.value.filter((i) => i.level === 'warn').length
)

const confText = computed(() => buildConf(form, exportKeys.value))
const cmdText = computed(() => buildCommand(form, exportKeys.value))

// 导出键 = 可见字段 + hidden 字段（RAC 节点三个键由表格代编辑，仍需写入 conf）
const exportKeys = computed(() => {
  const s = new Set(visibleKeys.value)
  for (const p of params) if (p.hidden) s.add(p.key)
  return s
})

const currentGroup = computed(() => groups.find((g) => g.id === activeGroup.value))
const currentParams = computed(() =>
  visibleParams.value.filter(
    (p) => p.group === activeGroup.value && (showAdvanced.value || !p.advanced)
  )
)
function groupCount(id) {
  return visibleParams.value.filter((p) => p.group === id && (showAdvanced.value || !p.advanced)).length
}
function groupErrors(id) {
  return fieldErrors.value.filter((e) => params.find((p) => p.key === e.key)?.group === id).length
}
function groupVisible(id) {
  // RAC / ASM 相关分组在单机模式下整组隐藏
  if (id === 'asm') return ['standalone', 'rac'].includes(form.oracle_install_mode)
  if (id === 'rac') return form.oracle_install_mode === 'rac'
  return true
}
const navGroups = computed(() => groups.filter((g) => groupVisible(g.id)))

watch(
  () => form.oracle_install_mode,
  (m) => {
    if (m === 'single' && ['asm', 'rac'].includes(activeGroup.value)) activeGroup.value = 'db'
  }
)

// 模板
const templates = ref(loadTemplates())
const tplName = ref('')
const unknownItems = ref([])
const importCount = ref(0)
const confInput = ref(null)
function onSave() {
  const name = tplName.value.trim()
  if (!name) return alert('请先填写模板名称')
  templates.value = saveTemplate(name, { ...form })
  tplName.value = ''
}
function onLoad(t) {
  Object.assign(form, t.values)
}
function onDelete(t) {
  templates.value = deleteTemplate(t.name)
}
function onReset() {
  if (!confirm('确定要恢复全部参数为默认值吗？')) return
  for (const p of params) {
    if (p.synthetic) continue
    form[p.key] = p.default != null ? String(p.default) : ''
  }
}
function onDownload() {
  downloadFile('install.conf', confText.value)
}

function onImport(e) {
  const file = e.target.files && e.target.files[0]
  e.target.value = ''
  if (!file) return
  const reader = new FileReader()
  reader.onload = () => {
    const { values, unknown } = parseConf(reader.result)
    for (const [k, v] of Object.entries(values)) form[k] = v
    unknownItems.value = unknown
    importCount.value = Object.keys(values).length
    activeGroup.value = 'scene'
  }
  reader.readAsText(file, 'utf-8')
}
async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    alert('浏览器拒绝了剪贴板访问，请手动选中复制')
  }
}
</script>

<template>
  <div class="app">
    <header>
      <div class="title">
        <h1>OracleShellInstall 参数配置中心</h1>
        <p>可视化填写安装参数，实时校验，导出 install.conf</p>
      </div>
      <div class="env">
        <div class="env-item">
          <span>操作系统</span>
          <select v-model="env.os">
            <option v-for="o in matrixData.osList" :key="o.id" :value="o.id">
              {{ o.name }}{{ o.certified ? '' : '（非官方认证）' }}
            </option>
          </select>
        </div>
        <div class="env-item">
          <span>大版本</span>
          <select v-model="env.osVersion">
            <option v-for="v in OS_VERSIONS" :key="v" :value="v">Linux {{ v }}</option>
          </select>
        </div>
        <div class="env-item">
          <span>CPU 架构</span>
          <select v-model="env.arch">
            <option value="x86_64">x86_64</option>
            <option value="aarch64">aarch64（ARM）</option>
          </select>
        </div>
      </div>
    </header>

    <nav class="tabs">
      <button :class="{ on: view === 'config' }" @click="view = 'config'">参数配置</button>
      <button :class="{ on: view === 'deploy' }" @click="view = 'deploy'">
        部署执行
        <em v-if="errorCount" class="dot">{{ errorCount }}</em>
      </button>
      <span class="tabs-right">
        <button class="ghost" @click="confInput && confInput.click()">导入 conf</button>
        <input
          ref="confInput"
          type="file"
          accept=".conf,.ini,.txt"
          class="hide"
          @change="onImport"
        />
        <span v-if="importCount" class="imported">
          已导入 {{ importCount }} 项
          <em v-if="unknownItems.length" class="warn">，{{ unknownItems.length }} 个未知键已忽略</em>
          <button class="ghost" @click="importCount = 0; unknownItems = []">关闭</button>
        </span>
      </span>
    </nav>

    <DeployPanel v-if="view === 'deploy'" :conf="confText" :error-count="errorCount" />

    <div v-else class="body">
      <aside>
        <button
          v-for="g in navGroups"
          :key="g.id"
          class="nav"
          :class="{ on: activeGroup === g.id }"
          @click="activeGroup = g.id"
        >
          <span>{{ g.name }}</span>
          <em v-if="groupErrors(g.id)" class="badge err">{{ groupErrors(g.id) }}</em>
          <em v-else class="badge">{{ groupCount(g.id) }}</em>
        </button>
        <label class="adv">
          <input v-model="showAdvanced" type="checkbox" />
          显示高级参数
        </label>
        <div class="aside-foot">
          <button class="ghost" @click="onReset">恢复默认</button>
        </div>
      </aside>

      <main>
        <div class="grp-head">
          <h2>{{ currentGroup.name }}</h2>
          <p>{{ currentGroup.desc }}</p>
        </div>

        <p v-if="!currentParams.length" class="empty">当前模式下该分组没有需要填写的参数。</p>

        <NodeTable
          v-if="activeGroup === 'rac' && form.oracle_install_mode === 'rac'"
          :form="form"
        />

        <FieldControl
          v-for="p in currentParams"
          :key="p.key"
          :param="p"
          :required="isRequired(p)"
          :issues="fieldIssues[p.key]"
          :model-value="form[p.key]"
          @update:model-value="form[p.key] = $event"
        />

        <div class="steps">
          <button v-if="activeGroup !== 'scene'" @click="activeGroup = 'scene'">回到场景选择</button>
        </div>
      </main>

      <section class="side">
        <div class="panel">
          <div class="sum" :class="errorCount ? 'bad' : 'ok'">
            <strong>{{ errorCount ? `${errorCount} 个错误` : '校验通过' }}</strong>
            <span v-if="warnCount">{{ warnCount }} 个提示</span>
          </div>

          <div v-for="i in matrix" :key="'m' + i.msg" class="msg" :class="i.level">{{ i.msg }}</div>
          <div v-for="i in cross" :key="'c' + i.msg" class="msg" :class="i.level">{{ i.msg }}</div>
          <div v-for="e in fieldErrors" :key="e.key" class="msg error">
            {{ e.label }}：{{ e.msg }}
          </div>
          <div v-for="w in fieldWarnings" :key="w.key + w.msg" class="msg warn">
            {{ w.label }}：{{ w.msg }}
          </div>
        </div>

        <div class="panel">
          <h3>install.conf</h3>
          <pre class="mono">{{ confText }}</pre>
          <div class="row">
            <button class="primary" :disabled="!!errorCount" @click="onDownload">
              下载 install.conf
            </button>
            <button @click="copyText(confText)">复制</button>
          </div>
          <p class="tip">
            放到 /soft 后执行：<code class="mono">sh run_all.sh -c install.conf</code>
          </p>
        </div>

        <div class="panel">
          <h3>命令行（密码以占位符显示）</h3>
          <pre class="mono small">{{ cmdText }}</pre>
          <button @click="copyText(cmdText)">复制命令</button>
        </div>

        <div class="panel">
          <h3>配置模板</h3>
          <div class="row">
            <input v-model="tplName" placeholder="模板名称，如 生产-19c-单机" />
            <button @click="onSave">保存</button>
          </div>
          <ul v-if="templates.length" class="tpl">
            <li v-for="t in templates" :key="t.name">
              <span>{{ t.name }}</span>
              <span class="ops">
                <button class="ghost" @click="onLoad(t)">载入</button>
                <button class="ghost" @click="onDelete(t)">删除</button>
              </span>
            </li>
          </ul>
          <p v-else class="tip">还没有保存过模板。模板保存在本机浏览器 localStorage 中。</p>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.app { max-width: 1320px; margin: 0 auto; padding: 24px 20px 60px; }
header {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  gap: 24px;
  flex-wrap: wrap;
  padding-bottom: 16px;
  border-bottom: 1px solid var(--border);
}
h1 { font-size: 18px; font-weight: 500; margin: 0; }
.title p { margin: 4px 0 0; color: var(--text-3); font-size: 13px; }
.env { display: flex; gap: 12px; flex-wrap: wrap; }
.env-item { display: flex; flex-direction: column; gap: 4px; }
.env-item span { font-size: 12px; color: var(--text-2); }
.env-item select { width: 190px; }

.tabs {
  display: flex;
  gap: 4px;
  margin-top: 16px;
  border-bottom: 1px solid var(--border);
}
.tabs button {
  border: none;
  border-bottom: 2px solid transparent;
  background: transparent;
  border-radius: 0;
  padding: 8px 14px;
  color: var(--text-2);
}
.tabs button.on { color: var(--brand); border-bottom-color: var(--brand); }
.dot {
  font-style: normal;
  margin-left: 6px;
  background: var(--err);
  color: #fff;
  border-radius: 10px;
  padding: 0 6px;
  font-size: 11px;
}
.tabs-right {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 8px;
}
.tabs .ghost { padding: 6px 10px; }
.imported {
  font-size: 12px;
  color: var(--ok);
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.imported .warn { font-style: normal; color: var(--warn); }
.hide { display: none; }

.body {
  display: grid;
  grid-template-columns: 180px minmax(0, 1fr) 380px;
  gap: 20px;
  margin-top: 20px;
  align-items: start;
}
aside { display: flex; flex-direction: column; gap: 4px; }
.nav {
  display: flex;
  justify-content: space-between;
  align-items: center;
  width: 100%;
  border: 1px solid transparent;
  background: transparent;
  text-align: left;
  padding: 8px 10px;
}
.nav.on { background: var(--brand-soft); border-color: var(--brand); color: var(--brand); }
.badge {
  font-style: normal;
  font-size: 11px;
  color: var(--text-3);
  background: var(--surface-alt);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0 6px;
}
.badge.err { color: #fff; background: var(--err); border-color: var(--err); }
.adv { display: flex; align-items: center; gap: 6px; margin-top: 12px; font-size: 12px; color: var(--text-2); }
.adv input { width: auto; }
.aside-foot { margin-top: 12px; }

main {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 20px 24px;
}
.grp-head h2 { font-size: 15px; font-weight: 500; margin: 0; }
.grp-head p { margin: 2px 0 8px; font-size: 12px; color: var(--text-3); }
.empty { color: var(--text-3); font-size: 13px; padding: 16px 0; }
.steps { margin-top: 16px; }

.side { display: flex; flex-direction: column; gap: 16px; }
.panel {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 14px 16px;
}
.panel h3 { font-size: 13px; font-weight: 500; margin: 0 0 8px; }
.sum { display: flex; align-items: baseline; gap: 10px; margin-bottom: 10px; }
.sum strong { font-size: 14px; font-weight: 500; }
.sum.ok strong { color: var(--ok); }
.sum.bad strong { color: var(--err); }
.sum span { font-size: 12px; color: var(--text-3); }
.msg {
  font-size: 12px;
  line-height: 1.5;
  padding: 6px 8px;
  border-radius: 6px;
  margin-bottom: 6px;
}
.msg.error { color: var(--err); background: var(--err-soft); }
.msg.warn { color: var(--warn); background: var(--warn-soft); }
pre {
  margin: 0 0 10px;
  background: var(--surface-alt);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 10px;
  max-height: 260px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-all;
}
pre.small { max-height: 180px; font-size: 11px; }
.row { display: flex; gap: 8px; align-items: center; }
.row input { flex: 1; }
.tip { font-size: 12px; color: var(--text-3); margin: 8px 0 0; }
.tip code { background: var(--surface-alt); padding: 1px 4px; border-radius: 4px; }
.tpl { list-style: none; margin: 10px 0 0; padding: 0; }
.tpl li {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  padding: 6px 0;
  border-bottom: 1px dashed var(--border);
  font-size: 13px;
}
.tpl li:last-child { border-bottom: none; }
.ops { display: flex; gap: 2px; }

@media (max-width: 1080px) {
  .body { grid-template-columns: 1fr; }
  aside { flex-direction: row; flex-wrap: wrap; }
  .nav { width: auto; }
}
</style>
