local websocket = require "core.websocket"
local logger = require "core.logger"
local hash = require "core.crypto.hash"
local utils = require "core.crypto.utils"

local mpg123 = require "voice.mpg123"

local os = os
local find = string.find
local byte = string.byte
local format = string.format
local concat = table.concat
local remove = table.remove

local S_TO_NS<const> = 1e9
local WIN_EPOCH<const> = 11644473600

local CHROMIUM_FULL_VERSION<const> = "130.0.2849.68"
local CHROMIUM_MAJOR_VERSION<const>, _ = string.match("^([^.]+)", CHROMIUM_FULL_VERSION)
local SEC_MS_GEC_VERSION<const> = "1-" .. CHROMIUM_FULL_VERSION
local BASE_URL <const> = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
--local BASE_URL <const> = "ws://127.0.0.1:8888/ws"
local TRUSTED_CLIENT_TOKEN<const> = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
local WSS_URL<const> = BASE_URL .. "?TrustedClientToken=" .. TRUSTED_CLIENT_TOKEN

local mpg_ctx_buffer = {}

local function mpg_ctx_new()
	local ctx = remove(mpg_ctx_buffer)
	if not ctx then
		ctx = mpg123.new()
	else
		mpg123.reset(ctx)
	end
	return ctx
end

local function mpg_ctx_free(ctx)
	mpg_ctx_buffer[#mpg_ctx_buffer + 1] = ctx
end

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

local opt_voice <const> = "zh-CN-XiaoxiaoNeural"
local opt_rate<const> = "+0%"
local opt_pitch<const> = "+0%"
local opt_volume<const> = "100%"
local opt_outputFormat<const> = "audio-24khz-48kbitrate-mono-mp3"

-- 生成 SSML 文本
local function generate_ssml(text)
	local ssml_template = "\z
<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>\z
<voice name='%s'>\z
<prosody pitch='%s' rate='%s' volume='%s'>\z
%s\z
</prosody>\z
</voice>\z
</speak>"
	return format(ssml_template,
		opt_voice,
		opt_rate,
		opt_pitch,
		opt_volume,
		text)
end

local date = os.date
local function date_to_string()
	return date("!%a %b %d %Y %H:%M:%S GMT+0000 (Coordinated Universal Time)")
end

-- 创建配置消息
local function create_config_message()
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
local function create_ssml_message(connection_id, text)
	local ssml = generate_ssml(text)
	local message = "X-RequestId:" .. connection_id .. "\r\n"
	message = message .. "Content-Type:application/ssml+xml\r\n"
	message = message .. "X-Timestamp:" .. date_to_string() .. "Z\r\n"
	message = message .. "Path:ssml\r\n\r\n"
	message = message .. ssml
	return message
end

---@param text string
---@param pcm_cb fun(pcm: string)
---@return boolean
local function tts(text, pcm_cb)
	if not text or text == "" then
		logger.errorf("[tts.edge] text is empty")
		return false
	end

	local connection_id = uuid4()
	local receiving_audio = false
	local headers = {
		["Pragma"] = "no-cache",
		["Cache-Control"] = "no-cache",
		["Origin"] = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
		["Accept-Encoding"] = "gzip, deflate, br",
		["Accept-Language"] = "en-US,en;q=0.9",
		["User-Agent"] =
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0",
	}
	local url = WSS_URL .. "&Sec-MS-GEC=" .. sec_gec(os.time(), TRUSTED_CLIENT_TOKEN) .. "&Sec-MS-GEC-Version=" .. SEC_MS_GEC_VERSION .. "&ConnectionId=" .. connection_id
	local sock, err = websocket.connect(url, headers)
	if not sock then
		logger.errorf("[tts.edge] connect failed: %s", err)
		return false
	end
	-- 发送配置消息
	local config_message = create_config_message()
	sock:write(config_message, "text")

	-- 发送 SSML 消息
	local ssml_message = create_ssml_message(connection_id, text)
	sock:write(ssml_message, "text")
	local ctx = mpg_ctx_new()
	while true do
		local data, typ = sock:read()
		if typ == "binary" then
			local len = string.unpack(">I2", data)
			local header = string.sub(data, 3, len+2)
			local body = string.sub(data, len+3)
			--logger.debugf("[tts.edge] binary header: %s", header)
			if receiving_audio then
				local pcm_data = mpg123.mp3topcm(ctx, body)
				if pcm_data then
					pcm_cb(pcm_data)
				end
			end
		else
			if find(data, "Path:turn.start") then
				logger.debugf("[tts.edge] turn.start")
			elseif find(data, "Path:audio.metadata") then
				logger.debugf("[tts.edge] audio.metadata")
				receiving_audio = true
			elseif find(data, "Path:turn.end") then
				logger.debugf("[tts.edge] turn.end")
				break
			end
		end
	end
	mpg_ctx_free(ctx)
	sock:close()
	return true
end

return tts

