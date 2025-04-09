import axios from 'axios';


// 存储 session_id 的变量
let sessionId = null;

// 生成 session_id 的函数（也可以在 App.vue 生成后设置）
function generateSessionId() {
  if (typeof window !== 'undefined' && window.crypto?.randomUUID) {
    return window.crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
}

sessionId = generateSessionId();
document.cookie = `session_id=${sessionId}`;
// 这里应该使用相对路径，让请求通过代理
const API_URL = '/api';

const apiService = {
  // 修复流式响应方法
  sendMessageStream(message, onChunk, onComplete, onError) {
    const params = new URLSearchParams({
      message: message,
      uid: "123"
    });
    const eventSource = new EventSource(`${API_URL}/chat?${params.toString()}`);
    eventSource.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.type === 'speaking') {
        onChunk(data.data);
      } else if (data.type === 'stop') {
        onComplete();
        eventSource.close();
      }
    };
    eventSource.onerror = (event) => {
      const errorDetail = {
        timestamp: new Date().toISOString(),
        eventType: event.type,
        readyState: event.target.readyState, // 0=CONNECTING, 1=OPEN, 2=CLOSED
        url: event.target.url,
        error: null
      };

      // 根据不同状态添加额外信息
      switch(event.target.readyState) {
        case EventSource.CLOSED:
          errorDetail.error = '连接被服务器关闭';
          break;
        case EventSource.CONNECTING:
          errorDetail.error = '正在尝试重新连接';
          break;
        default:
          errorDetail.error = '未知错误类型';
      }
      // 如果是HTTP错误
      if (event.status) {
        errorDetail.httpStatus = event.status;
        errorDetail.statusText = event.statusText;
      }
      console.error('SSE连接错误详情:', errorDetail);
      onError(event);
      eventSource.close();
    };
  }
};

export default apiService;