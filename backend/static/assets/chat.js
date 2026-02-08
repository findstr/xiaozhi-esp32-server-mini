const chatLog = document.getElementById('chatLog');
const chatInput = document.getElementById('chatInput');
const chatSend = document.getElementById('chatSend');
const chatStatus = document.getElementById('chatStatus');

let currentAssistant = null;

function addMessage(role, text) {
  const wrap = document.createElement('div');
  wrap.className = 'chat-message';
  const bubble = document.createElement('div');
  bubble.className = `chat-bubble ${role}`;
  bubble.textContent = text;
  wrap.appendChild(bubble);
  chatLog.appendChild(wrap);
  chatLog.scrollTop = chatLog.scrollHeight;
  return bubble;
}

function sendMessage() {
  const msg = chatInput.value.trim();
  if (!msg) return;
  addMessage('user', msg);
  chatInput.value = '';
  chatInput.focus();

  currentAssistant = addMessage('assistant', '');
  chatStatus.textContent = '正在请求...';
  const url = `/chat?message=${encodeURIComponent(msg)}`;
  const es = new EventSource(url);

  es.addEventListener('speak', (event) => {
    if (event.data === 'reasoner') return;
    try {
      const payload = JSON.parse(event.data);
      if (payload.type === 'speaking') {
        currentAssistant.textContent += payload.data;
        chatLog.scrollTop = chatLog.scrollHeight;
      } else if (payload.type === 'stop') {
        es.close();
        chatStatus.textContent = '';
      }
    } catch (e) {
      currentAssistant.textContent += event.data;
    }
  });

  es.onerror = () => {
    chatStatus.textContent = '连接中断';
    es.close();
  };
}

chatSend.addEventListener('click', sendMessage);
chatInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    sendMessage();
  }
});
