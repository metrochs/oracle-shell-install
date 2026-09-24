import crypto from 'node:crypto'

/** 生成 MASTER_KEY 与 API_TOKEN，输出可直接粘进 .env */
const master = crypto.randomBytes(32).toString('base64')
const token = crypto.randomBytes(24).toString('base64url')

console.log('请把下面两行写入 .env（不要提交到版本库）：\n')
console.log(`MASTER_KEY=${master}`)
console.log(`API_TOKEN=${token}\n`)
console.log('说明：')
console.log('- MASTER_KEY 用于加密保存目标机 SSH 私钥，泄露等于私钥泄露，务必保管好')
console.log('- 更换 MASTER_KEY 后，已保存的目标机私钥将无法解密，需要重新录入')
console.log('- API_TOKEN 是后端接口的访问凭据')
