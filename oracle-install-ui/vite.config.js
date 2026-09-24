import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

const API_TARGET = process.env.API_TARGET || 'http://127.0.0.1:3000'

export default defineConfig({
  plugins: [vue()],
  // 使用相对路径，构建产物可直接用任意静态服务器或子目录托管
  base: './',
  server: {
    port: 5173,
    host: true,
    proxy: {
      '/api': { target: API_TARGET, changeOrigin: true },
      '/ws': { target: API_TARGET, ws: true, changeOrigin: true }
    }
  }
})
