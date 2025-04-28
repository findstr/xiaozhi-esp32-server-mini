local websocket = require "core.websocket"
local hash = require "core.crypto.hash"
local utils = require "core.crypto.utils"

local os = os
local byte = string.byte
local format = string.format
local concat = table.concat


local S_TO_NS<const> = 1e9
local WIN_EPOCH<const> = 11644473600

local CHROMIUM_FULL_VERSION<const> = "130.0.2849.68"
local CHROMIUM_MAJOR_VERSION<const>, _ = string.match("^([^.]+)", CHROMIUM_FULL_VERSION)
local SEC_MS_GEC_VERSION<const> = "1-" .. CHROMIUM_FULL_VERSION
local BASE_URL <const> = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
--local BASE_URL <const> = "ws://127.0.0.1:8888/ws"
local TRUSTED_CLIENT_TOKEN<const> = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
local WSS_URL<const> = BASE_URL .. "?TrustedClientToken=" .. TRUSTED_CLIENT_TOKEN

local function hex2str(hex)
	local buf = {}
	for i = 1, #hex do
		buf[i] = format("%02X", byte(hex, i))
	end
	return concat(buf)
end

local function sec_gec(timestamp, token)
	local ticks = timestamp + WIN_EPOCH
	ticks = ticks - ticks % 300
	ticks = ticks * S_TO_NS / 100
	local str = format("%d%s", ticks, token)
	local result = hash.hash("sha256", str)
	return hex2str(result)
end

local function uuid4()
	local bytes = utils.randomkey(16)
	local byte7 = bytes:byte(7)
	local byte9 = bytes:byte(9)
	byte7 = byte7 & 0x0f | 0x40
	byte9 = byte9 & 0x3f | 0x80

	local uuid = string.format(
		"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
		bytes:byte(1), bytes:byte(2), bytes:byte(3), bytes:byte(4),
		bytes:byte(5), bytes:byte(6),
		byte7, bytes:byte(8),
		byte9, bytes:byte(10),
		bytes:byte(11), bytes:byte(12), bytes:byte(13), bytes:byte(14), bytes:byte(15), bytes:byte(16)
	)
	return uuid
end

-- EdgeTTS 类
local EdgeTTS = {}
EdgeTTS.__index = EdgeTTS

-- 创建新的 EdgeTTS 实例
function EdgeTTS.new(options)
	local self = setmetatable({}, EdgeTTS)

	-- 默认配置
	self.options = options or {}
	self.options.voice = self.options.voice or "zh-CN-XiaoxiaoNeural"
	self.options.rate = self.options.rate or "0%"
	self.options.pitch = self.options.pitch or "0%"
	self.options.volume = self.options.volume or "100%"
	self.options.outputFormat = self.options.outputFormat or "audio-24khz-48kbitrate-mono-mp3"

	-- 固定的 UUID (在实际应用中应该生成随机UUID)
	self.connectionId = uuid4()

	-- 存储接收到的音频数据
	self.audioData = {}

	-- 状态标记
	self.receivingAudio = false
	self.completed = false

	return self
end

-- 生成 SSML 文本
function EdgeTTS:generate_ssml(text)
	local ssml_template = "\z
<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\z
<voice name='%s'>\z
<prosody pitch='%s' rate='%s' volume='%s'>\z
%s\z
</prosody>\z
</voice>\z
</speak>"
	return format(ssml_template,
		self.options.voice,
		self.options.rate,
		self.options.pitch,
		self.options.volume,
		text)
end

local function date_to_string()
	return os.date("!%a %b %d %Y %H:%M:%S GMT+0000 (Coordinated Universal Time)")
end

-- 创建配置消息
function EdgeTTS:create_config_message()
	local fmt =
'X-Timestamp:%s\r\n\z
Content-Type:application/json; charset=utf-8\r\n\z
Path:speech.config\r\n\r\n\z
{"context":{"synthesis":{"audio":{"metadataoptions":{\z
"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},\z
"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}'
	return format(fmt, date_to_string())
end

-- 创建 SSML 消息
function EdgeTTS:create_ssml_message(text)
	local ssml = self:generate_ssml(text)

	local message = "X-RequestId:" .. self.connectionId .. "\r\n"
	message = message .. "Content-Type:application/ssml+xml\r\n"
	message = message .. "X-Timestamp:" .. date_to_string() .. "Z\r\n"
	message = message .. "Path:ssml\r\n\r\n"
	message = message .. ssml
	return message
end

-- 处理收到的 WebSocket 消息
function EdgeTTS:handle_message(message, isBinary)
	if self.completed then
		return
	end

	if isBinary then
		-- 如果正在接收音频数据，将二进制数据添加到音频数据表中
		if self.receivingAudio then
			table.insert(self.audioData, message)
		end
		return
	end

	-- 处理文本消息
	local message_str = message
	print(message_str)
	-- 检查消息类型
	if string.find(message_str, "Path:turn.start") then
		print("开始语音合成")
	elseif string.find(message_str, "Path:audio.metadata") then
		print("接收到音频元数据")
		self.receivingAudio = true
	elseif string.find(message_str, "Path:turn.end") then
		print("语音合成完成")
		self.completed = true
		self.receivingAudio = false
	end
end

-- 将接收到的音频数据保存到文件
function EdgeTTS:save_audio_to_file(filename)
	if #self.audioData == 0 then
		print("没有接收到音频数据")
		return false
	end

	local file = io.open(filename, "wb")
	if not file then
		print("无法创建文件: " .. filename)
		return false
	end

	-- 处理接收到的音频数据
	for _, data in ipairs(self.audioData) do
		-- 查找音频数据的开始位置，跳过头部
		local audio_start = string.find(data, "\r\n\r\n")
		if audio_start then
			local audio_data = string.sub(data, audio_start + 4)
			file:write(audio_data)
		else
			file:write(data)
		end
	end

	file:close()
	print("音频已保存到: " .. filename)
	return true
end

-- 生成语音
function EdgeTTS:synthesize(text, output_file)
	-- 检查输入
	if not text or text == "" then
		print("文本不能为空")
		return false
	end

	if not output_file or output_file == "" then
		output_file = "output.mp3"
	end

	-- 重置状态
	self.audioData = {}
	self.receivingAudio = false
	self.completed = false

	-- 设置 WebSocket 头部
	local headers = {
		["Pragma"] = "no-cache",
		["Cache-Control"] = "no-cache",
		["Origin"] = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
		["Accept-Encoding"] = "gzip, deflate, br",
		["Accept-Language"] = "en-US,en;q=0.9",
		["User-Agent"] =
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
	}
	local url = WSS_URL .. "&Sec-MS-GEC=" .. sec_gec(os.time(), TRUSTED_CLIENT_TOKEN) .. "&Sec-MS-GEC-Version=" .. SEC_MS_GEC_VERSION .. "&ConnectionId=" .. self.connectionId
	-- 创建 WebSocket 客户端
	local ws, err = websocket.connect(url, headers)
	if not ws then
		print("WebSocket 连接失败: " .. (err or "未知错误"))
		return false
	end

	-- 发送配置消息
	local config_message = self:create_config_message()
	ws:write(config_message, "text")

	-- 发送 SSML 消息
	local ssml_message = self:create_ssml_message(text)
	ws:write(ssml_message, "text")

	-- 接收消息
	local timeout = 30 -- 超时时间，单位秒
	local start_time = os.time()

	while not self.completed and (os.time() - start_time) < timeout do
		local data, typ = ws:read()
		if not data then
			print("接收消息失败: " .. typ)
			break
		end
		local isBinary = typ == "binary"
		self:handle_message(data, isBinary)
	end

	-- 关闭连接
	ws:close()

	-- 保存音频到文件
	if #self.audioData > 0 then
		return self:save_audio_to_file(output_file)
	else
		print("未接收到音频数据")
		return false
	end
end


-- 使用示例
-- 创建 EdgeTTS 实例
local tts = EdgeTTS.new({
	voice = "zh-CN-XiaoxiaoNeural", -- 使用中文女声
	rate = "+0%",					-- 语速
	pitch = "+0%",				   -- 音调
	volume = "100%"				  -- 音量
})

-- 生成语音并保存到文件
local result = tts:synthesize("窗前明月光，疑是地上霜。举头望明月，低头思故乡。", "output.mp3")

if result then
	print("语音生成成功!")
else
	print("语音生成失败!")
end

return EdgeTTS
