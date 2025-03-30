<template>
  <div class="chat-input">
    <textarea
      v-model="message"
      placeholder="输入消息..."
      @keydown.enter.ctrl="sendMessage"
      rows="3"
    ></textarea>
    <div class="actions">
      <span class="hint">按 Ctrl+Enter 发送</span>
      <button :disabled="isLoading || !message.trim()" @click="sendMessage">
        {{ isLoading ? '发送中...' : '发送' }}
      </button>
    </div>
  </div>
</template>

<script>
import { ref } from 'vue';

export default {
  name: 'ChatInput',
  props: {
    isLoading: {
      type: Boolean,
      default: false
    }
  },
  emits: ['send'],
  setup(props, { emit }) {
    const message = ref('');

    const sendMessage = () => {
      if (props.isLoading || !message.value.trim()) return;
      
      emit('send', message.value);
      message.value = '';
    };

    return {
      message,
      sendMessage
    };
  }
};
</script>

<style scoped>
.chat-input {
  border: 1px solid #e0e0e0;
  border-radius: 8px;
  padding: 12px;
  background-color: #ffffff;
}

textarea {
  width: 100%;
  border: none;
  resize: none;
  outline: none;
  font-family: inherit;
  font-size: 16px;
  padding: 8px 0;
}

.actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 8px;
}

.hint {
  color: #888;
  font-size: 14px;
}

button {
  background-color: #1a73e8;
  color: white;
  border: none;
  border-radius: 4px;
  padding: 8px 16px;
  cursor: pointer;
  font-weight: 500;
  transition: background-color 0.2s;
}

button:hover:not(:disabled) {
  background-color: #1765cc;
}

button:disabled {
  background-color: #ccc;
  cursor: not-allowed;
}
</style>