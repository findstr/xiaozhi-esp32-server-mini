local core = require "core"
local time = require "core.time"
local http = require "core.http"
local logger = require "core.logger"
local conf = require "conf"

local region = conf.tts.azure.region
local token_url = "https://" .. region .. ".api.cognitive.microsoft.com/sts/v1.0/issueToken"
local api_url = "https://" .. region .. ".tts.speech.microsoft.com/cognitiveservices/v1"
local api_key = conf.tts.azure.api_key
local token = ""
local token_time = 0
local function get_token()
	local now = time.nowsec()
	if now - token_time < 500 then
		return token
	end
	local headers = {
		["ocp-apim-subscription-key"] = api_key,
		["content-type"] = "application/x-www-form-urlencoded",
		["content-length"] = 0,
	}
	local res, err = http.POST(token_url, headers, "")
	if not res then
		logger.error("[tts.azure] get token failed, err:", err)
		return nil, err
	end
	token = "Bearer " .. res.body
	token_time = now
	return token
end

---@param text string
---@param pcm_cb fun(pcm: string)
local function tts(text, pcm_cb)
	local token = get_token()
	if not token then
		logger.error("[tts.azure] get token failed")
		return false
	end
	local ssml =
	    "<speak version='1.0' xml:lang='zh-CN'>\z
		<voice xml:lang='zh-CN' xml:gender='Female' name='zh-CN-XiaoyouNeural'><prosody rate='+20%'>\z"
		.. text ..
		"</prosody></voice>\z
	</speak>"
	local headers = {
		["x-microsoft-outputformat"] = "raw-16khz-16bit-mono-pcm",
		["content-type"] = "application/ssml+xml",
		["content-length"] = #ssml,
		["authorization"] = token,
		["user-agent"] = "xiaozhi",
	}
	logger.debugf("[tts.azure] tts text:`%s` start", text)
	local res, err = http.POST(api_url, headers, ssml)
	if not res then
		logger.error("[tts.azure] tts failed, err:", err)
		return false
	end
	logger.debugf("[tts.azure] tts stop status:%s res.status, body:%s", res.status, #res.body)
	pcm_cb(res.body)
	return true
end

return tts
