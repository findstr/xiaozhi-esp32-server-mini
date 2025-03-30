<template>
  <div class="app">
    <header>
      <h1>AI 聊天助手</h1>
    </header>

    <main>
      <ChatHistory :messages="messages" />

      <div class="input-container">
        <ChatInput :isLoading="isLoading" @send="sendMessage" />
      </div>
    </main>
  </div>
</template>

<script>
import { ref } from 'vue';
import ChatHistory from './components/ChatHistory.vue';
import ChatInput from './components/ChatInput.vue';
import apiService from './services/api.js';

export default {
  name: 'App',
  components: {
    ChatHistory,
    ChatInput
  },
  setup() {
    const messages = ref([]);
    const isLoading = ref(false);
    let closeStream = null;
    const sendMessage = async (content) => {
      // 如果已有进行中的流，先关闭
      if (closeStream) {
        closeStream();
        closeStream = null;
      }
      // 添加用户消息到聊天记录
      messages.value.push({
        role: 'user',
        content
      });

      // 添加一个空的 AI 回复，用于流式更新
      const aiMessageIndex = messages.value.length;
      messages.value.push({
        role: 'assistant',
        content: '▌' // 使用光标效果表示正在输入
      });

      // 设置加载状态
      isLoading.value = true;
      // 调用流式接口
      closeStream = apiService.sendMessageStream(
        content,
        // 处理每个数据块
        (chunk) => {
          messages.value[aiMessageIndex].content = messages.value[aiMessageIndex].content.slice(0, -1) + chunk + '▌';
        },
        // 处理完成
        () => {
          messages.value[aiMessageIndex].content = messages.value[aiMessageIndex].content.slice(0, -1);
          isLoading.value = false;
          closeStream = null;
        },
        // 处理错误
        (error) => {
          messages.value[aiMessageIndex].content = '对话生成失败，请重试';
          console.error('流式响应错误:', error);
          isLoading.value = false;
          closeStream = null;
        }
      );
    };

    return {
      messages,
      isLoading,
      sendMessage
    };
  }
};
</script>

<style>
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  line-height: 1.6;
  color: #333;
  background-color: #f9f9f9;
}

.app {
  display: flex;
  flex-direction: column;
  height: 100vh;
  max-width: 1000px;
  margin: 0 auto;
  background-color: #fff;
  box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
}

header {
  padding: 16px 20px;
  border-bottom: 1px solid #e0e0e0;
}

header h1 {
  font-size: 20px;
  font-weight: 500;
}

main {
  display: flex;
  flex-direction: column;
  flex: 1;
  overflow: hidden;
}

.input-container {
  padding: 16px;
  border-top: 1px solid #e0e0e0;
}
</style>