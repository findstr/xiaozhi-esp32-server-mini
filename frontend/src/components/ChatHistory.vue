<template>
  <div class="chat-history" ref="chatContainer">
    <div v-if="messages.length === 0" class="empty-state">
      <div class="icon">💬</div>
      <h2>开始一段新的对话</h2>
      <p>输入消息并点击发送按钮开始聊天</p>
    </div>
    <template v-else>
      <ChatMessage
        v-for="(message, index) in messages"
        :key="index"
        :message="message"
      />
    </template>
  </div>
</template>

<script>
import { ref, watch, nextTick } from 'vue';
import ChatMessage from './ChatMessage.vue';

export default {
  name: 'ChatHistory',
  components: {
    ChatMessage
  },
  props: {
    messages: {
      type: Array,
      required: true
    }
  },
  setup(props) {
    const chatContainer = ref(null);

    // 监听消息变化，自动滚动到底部
    watch(() => props.messages.length, async () => {
      await nextTick();
      if (chatContainer.value) {
        chatContainer.value.scrollTop = chatContainer.value.scrollHeight;
      }
    });

    return {
      chatContainer
    };
  }
};
</script>

<style scoped>
.chat-history {
  flex: 1;
  overflow-y: auto;
  padding: 20px;
}

.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: #666;
  text-align: center;
}

.empty-state .icon {
  font-size: 48px;
  margin-bottom: 16px;
}

.empty-state h2 {
  margin-bottom: 8px;
  font-weight: 500;
}

.empty-state p {
  color: #888;
}
</style>