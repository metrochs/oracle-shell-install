<script setup>
import { ref, watch, computed } from 'vue'
import { isIp } from '../utils/validate.js'

const props = defineProps({
  form: { type: Object, required: true }
})
defineEmits(['change'])

// 表格只负责编辑方式，真实数据仍落在三个逗号分隔的键上：
// rac_hostname / rac_public_ip / rac_virtual_ip（脚本消费的格式不变）
const KEYS = ['rac_hostname', 'rac_public_ip', 'rac_virtual_ip']
const COLS = [
  { key: 'hostname', label: '主机名', ph: 'orcl01' },
  { key: 'publicIp', label: '公网 IP', ph: '10.0.0.1' },
  { key: 'virtualIp', label: '虚拟 IP', ph: '10.0.0.11' }
]

function split(v) {
  return String(v || '').split(',').map((s) => s.trim())
}
function fromForm() {
  const parts = KEYS.map((k) => split(props.form[k]))
  const n = Math.max(...parts.map((a) => a.length))
  return Array.from({ length: n }, (_, i) => ({
    hostname: parts[0][i] || '',
    publicIp: parts[1][i] || '',
    virtualIp: parts[2][i] || ''
  }))
}
function serialize(rs) {
  const live = rs.filter((r) => r.hostname.trim() || r.publicIp.trim() || r.virtualIp.trim())
  return KEYS.map((k, i) =>
    live
      .map((r) => r[COLS[i].key].trim())
      .filter(Boolean)
      .join(',')
  ).join('|')
}

const rows = ref(fromForm())
if (!rows.value.length) rows.value.push({ hostname: '', publicIp: '', virtualIp: '' })

// conf 导入 / 模板载入 / 恢复默认时，从表单字符串反向重建表格
watch(
  () => KEYS.map((k) => props.form[k]),
  () => {
    if (serialize(rows.value) !== serialize(fromForm())) rows.value = fromForm()
  }
)

function commit() {
  const live = rows.value.filter(
    (r) => r.hostname.trim() || r.publicIp.trim() || r.virtualIp.trim()
  )
  props.form.rac_hostname = live.map((r) => r.hostname.trim()).join(',')
  props.form.rac_public_ip = live.map((r) => r.publicIp.trim()).join(',')
  props.form.rac_virtual_ip = live.map((r) => r.virtualIp.trim()).join(',')
}

function addRow() {
  rows.value.push({ hostname: '', publicIp: '', virtualIp: '' })
}
function delRow(i) {
  rows.value.splice(i, 1)
  if (!rows.value.length) rows.value.push({ hostname: '', publicIp: '', virtualIp: '' })
  commit()
}

const rowIssues = computed(() => {
  const issues = rows.value.map(() => [])
  const seen = { hostname: {}, publicIp: {}, virtualIp: {} }
  rows.value.forEach((r) => {
    if (!(r.hostname.trim() || r.publicIp.trim() || r.virtualIp.trim())) return
    for (const c of COLS) {
      const v = r[c.key].trim()
      if (v) seen[c.key][v] = (seen[c.key][v] || 0) + 1
    }
  })
  rows.value.forEach((r, i) => {
    const errs = issues[i]
    const filled = COLS.filter((c) => r[c.key].trim())
    if (filled.length && filled.length < COLS.length) errs.push('该行信息不完整')
    for (const c of COLS) {
      const v = r[c.key].trim()
      if (!v) continue
      if (c.key === 'hostname' && !/^[a-zA-Z0-9][a-zA-Z0-9-]*$/.test(v)) {
        errs.push('主机名仅允许字母、数字、中划线')
      }
      if (c.key !== 'hostname' && !isIp(v)) errs.push(`${c.label}格式不正确`)
      if (seen[c.key][v] > 1) errs.push(`${c.label}重复`)
    }
    if (r.publicIp.trim() && r.publicIp.trim() === r.virtualIp.trim()) {
      errs.push('公网与虚拟 IP 相同')
    }
  })
  return issues
})

const rowErrors = computed(() =>
  rowIssues.value
    .map((errs, i) => ({ i, errs }))
    .filter(({ errs }) => errs.length)
)
</script>

<template>
  <div class="field nt">
    <label>
      <span class="lb">RAC 节点列表</span>
      <span class="req">必填</span>
      <code class="flag mono">-hn -ri -vi</code>
    </label>

    <table>
      <thead>
        <tr>
          <th style="width: 42px">#</th>
          <th v-for="c in COLS" :key="c.key">{{ c.label }}</th>
          <th class="op-col"></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(r, i) in rows" :key="i">
          <td class="idx mono">{{ i + 1 }}<em v-if="i === 0" class="main" title="主节点">主</em></td>
          <td v-for="c in COLS" :key="c.key">
            <input
              v-model="r[c.key]"
              class="mono"
              :class="{ bad: rowIssues[i].length }"
              :placeholder="c.ph"
              spellcheck="false"
              @input="commit"
            />
          </td>
          <td class="op-col">
            <button class="ghost tiny" type="button" :disabled="rows.length === 1" @click="delRow(i)">
              删除
            </button>
          </td>
        </tr>
      </tbody>
    </table>

    <div class="nt-foot">
      <button class="ghost" type="button" @click="addRow">＋ 添加节点</button>
      <span class="tip">每行一个节点，按顺序填写；第 1 个节点为主节点（其公网 IP 必须是本机 IP）</span>
    </div>

    <p v-for="e in rowErrors" :key="e.i" class="msg err">
      第 {{ e.i + 1 }} 行：{{ e.errs.join('；') }}
    </p>
  </div>
</template>

<style scoped>
.nt table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}
.nt th {
  text-align: left;
  font-weight: 400;
  font-size: 12px;
  color: var(--text-3);
  padding: 4px 6px;
  border-bottom: 1px solid var(--border);
}
.nt td {
  padding: 4px 6px;
}
.nt input {
  width: 100%;
}
.nt input.bad {
  border-color: var(--err);
}
.idx {
  color: var(--text-3);
  white-space: nowrap;
}
.main {
  font-style: normal;
  font-size: 10px;
  color: var(--brand);
  border: 1px solid var(--brand);
  border-radius: 4px;
  padding: 0 4px;
  margin-left: 4px;
}
.op-col {
  width: 64px;
  text-align: right;
}
.tiny {
  font-size: 12px;
  padding: 5px 8px;
  white-space: nowrap;
}
.tiny:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.nt-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 8px;
}
.nt-foot .tip {
  font-size: 12px;
  color: var(--text-3);
}
.msg {
  margin: 6px 0 0;
  font-size: 12px;
}
.msg.err {
  color: var(--err);
}
</style>
