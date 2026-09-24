const fs = require('fs')
const files = [
  'run_all.sh',
  '1_os_config.sh',
  '2_software_install.sh',
  '3_db_create.sh',
  '4_post_config.sh'
]
const bad =
  'SCRIPT_DIR=\nset -o pipefail # 管道中任一命令失败都要让整体退出码非 0$(cd "$(dirname "$(readlink -f "$0")")" && pwd)'
const good =
  'SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)\nset -o pipefail # 管道中任一命令失败都要让整体退出码非 0'
for (const f of files) {
  let s = fs.readFileSync(f, 'utf8')
  if (!s.includes(bad)) {
    console.log('skip(未匹配):', f)
    continue
  }
  fs.writeFileSync(f, s.replace(bad, good))
  console.log('fixed:', f)
}
