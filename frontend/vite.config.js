import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    host: '0.0.0.0', // 允许所有网络接口
    port: 5173,      // 明确指定端口
    strictPort: true, // 禁止端口占用时自动切换
    proxy: {
      '/api': {
        target: 'http://localhost:8081',  // 确保这是你后端服务的正确地址
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, '')
      }
    }
  }
})