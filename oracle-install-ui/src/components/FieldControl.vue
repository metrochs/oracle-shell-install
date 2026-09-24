<script setup>
import { ref, computed } from 'vue'
import schema from '../data/schema.json'

const props = defineProps({
  param: { type: Object, required: true },
  modelValue: { type: [String, Number], default: '' },
  required: { type: Boolean, default: false },
  issues: { type: Object, default: () => ({ errors: [], warnings: [] }) }
})
const emit = defineEmits(['update:modelValue'])

const showPwd = ref(false)
const listId = computed(() => `dl-${props.param.key}`)

function onInput(e) {
  emit('update:modelValue', e.target.value)
}
function set(v) {
  emit('update:modelValue', v)
}
</script>

<template>
  <div class="field" :class="{ 'has-error': issues.errors.length }">
    <label :for="param.key">
      <span class="lb">{{ param.label }}</span>
      <span v-if="required" class="req">必填</span>
      <code v-if="param.flag" class="flag mono">{{ param.flag }}</code>
    </label>

    <div class="ctrl">
      <select
        v-if="param.type === 'enum'"
        :id="param.key"
        :value="modelValue"
        @change="onInput"
      >
        <option value="">-- 请选择 --</option>
        <option v-for="o in param.enum" :key="o.v" :value="o.v">{{ o.l }}</option>
      </select>

      <template v-else-if="param.type === 'enum-search'">
        <input
          :id="param.key"
          :list="listId"
          :value="modelValue"
          :placeholder="param.placeholder || '可输入检索，例如 AL32UTF8'"
          autocomplete="off"
          @input="onInput"
        />
        <datalist :id="listId">
          <option v-for="o in param.options" :key="o" :value="o" />
        </datalist>
      </template>

      <select
        v-else-if="param.type === 'yn'"
        :id="param.key"
        :value="modelValue"
        @change="onInput"
      >
        <option value="Y">Y（是）</option>
        <option value="N">N（否）</option>
      </select>

      <select
        v-else-if="param.type === 'tf'"
        :id="param.key"
        :value="modelValue"
        @change="onInput"
      >
        <option value="true">true</option>
        <option value="false">false</option>
      </select>

      <div v-else-if="param.type === 'password'" class="pwd">
        <input
          :id="param.key"
          :type="showPwd ? 'text' : 'password'"
          :value="modelValue"
          :placeholder="param.placeholder || ''"
          autocomplete="new-password"
          @input="onInput"
        />
        <button class="ghost tiny" type="button" @click="showPwd = !showPwd">
          {{ showPwd ? '隐藏' : '显示' }}
        </button>
      </div>

      <input
        v-else
        :id="param.key"
        type="text"
        class="mono"
        :value="modelValue"
        :placeholder="param.placeholder || ''"
        @input="onInput"
      />
    </div>

    <p v-if="param.help" class="help">{{ param.help }}</p>
    <p v-for="e in issues.errors" :key="e" class="msg err">{{ e }}</p>
    <p v-for="w in issues.warnings" :key="w" class="msg warn">{{ w }}</p>
  </div>
</template>

<style scoped>
.field {
  padding: 12px 0;
  border-bottom: 1px dashed var(--border);
}
.field:last-child { border-bottom: none; }
label {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 6px;
}
.lb { font-weight: 500; }
.req {
  font-size: 11px;
  color: var(--err);
  background: var(--err-soft);
  border-radius: 4px;
  padding: 1px 6px;
}
.flag {
  color: var(--text-3);
  background: var(--surface-alt);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 1px 6px;
}
.ctrl { display: flex; gap: 8px; }
.pwd { display: flex; gap: 8px; width: 100%; }
.pwd input { flex: 1; }
.tiny { white-space: nowrap; padding: 6px 8px; }
.help {
  margin: 6px 0 0;
  font-size: 12px;
  color: var(--text-3);
  line-height: 1.5;
}
.msg { margin: 4px 0 0; font-size: 12px; }
.msg.err { color: var(--err); }
.msg.warn { color: var(--warn); }
.has-error input,
.has-error select { border-color: var(--err); }
</style>
