<template>
  <div class="message" :class="{ 'user-message': isUser, 'ai-message': !isUser }">
    <div class="avatar">
      {{ isUser ? '👤' : '🤖' }}
    </div>
    <div class="content">
      <div class="sender">{{ isUser ? '你' : 'AI' }}</div>
      <div class="text" v-html="formattedText"></div>
    </div>
  </div>
</template>

<script>
import { computed } from 'vue';
import { marked } from 'marked';

export default {
  name: 'ChatMessage',
  props: {
    message: {
      type: Object,
      required: true
    }
  },
  setup(props) {
    const isUser = computed(() => props.message.role === 'user');
    
    const formattedText = computed(() => {
      // 使用 marked 将 markdown 转换为 HTML
      return marked(props.message.content);
    });

    return {
      isUser,
      formattedText
    };
  }
};
</script>

<style scoped>
.message {
  display: flex;
  margin-bottom: 20px;
  padding: 12px;
  border-radius: 8px;
}

.user-message {
  background-color: #f0f4f9;
}

.ai-message {
  background-color: #ffffff;
  border: 1px solid #e0e0e0;
}

.avatar {
  width: 40px;
  height: 40px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-right: 12px;
  font-size: 20px;
}

.content {
  flex: 1;
}

.sender {
  font-weight: bold;
  margin-bottom: 4px;
}

.text {
  line-height: 1.5;
}

.text :deep(pre) {
  background-color: #f6f8fa;
  padding: 12px;
  border-radius: 6px;
  overflow-x: auto;
}

.text :deep(code) {
  font-family: monospace;
}

.text :deep(p) {
  margin: 8px 0;
}
</style>