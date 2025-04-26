local core = require "core"
local time = require "core.time"
local json = require "core.json"
local logger = require "core.logger"
local websocket = require "core.websocket"
local voice = require "voice"
local asr = require "asr"
local tts = require "tts"
local conf = require "conf"
local memory = require "memory"
local intent = require "intent"

local ipairs = ipairs
local remove = table.remove

local vad_model_path = conf.vad.model_path

---@alias xiaozhi.state "idle" | "listening" | "speaking" | "close"
local STATE_IDLE = "idle"
local STATE_LISTENING = "listening"
local STATE_SPEAKING = "speaking"
local STATE_CLOSE = "close"

local function save_pcm(file, dat)
	local f<close>, err = io.open(file, "wb")
	if not f then
		logger.error("[xiaozhi] failed to open audio.bin", err)
		return
	end
	f:write(dat)
end

local function read_pcm(file)
	local f<close>, err = io.open(file, "rb")
	if not f then
		return nil
	end
	local dat = f:read("a")
	return dat
end

local pcm_cache = setmetatable({}, {__index = function(t, k)
	local path = "../audio/"..k..".pcm"
	local pcm = read_pcm(path)
	if not pcm then
		local err
		local ttsx = tts.new()
		pcm, err = ttsx:txt_to_pcm(k)
		if pcm then
			save_pcm(path, pcm)
		else
			logger.error("[xiaozhi] failed to convert text to pcm", err)
		end
	end
	if pcm then
		t[k] = pcm
	end
	return pcm
end})

---@class xiaozhi.session : session
---@field memory memory
---@field voice_ctx userdata
---@field state xiaozhi.state
---@field remote_addr string
---@field sock core.http.websocket
---@field tts tts
---@field session_id string
---@field chat? function(session, string):boolean
---@field closed boolean
---@field silence_start_time integer
---@field last_send_time integer
---@field device_frame_count integer
local xsession = {}
local xsession_mt = {__index = xsession}

local voice_ctx_pool = {}

local function voice_ctx_new()
	local ctx = remove(voice_ctx_pool, 1)
	if ctx then
		voice.reset(ctx)
	else
		ctx = voice.new {
			model_path = vad_model_path,
			min_silence_duration_ms = 1500,
		}
	end
	return ctx
end

---@param uid number
---@param sock core.http.websocket
---@return xiaozhi.session
function xsession.new(uid, sock)
	local s = setmetatable({
		memory = memory.new(uid),
		state = STATE_IDLE,
		sock = sock,
		remote_addr = sock.stream.remote_addr,
		session_id = false,
		voice_ctx = voice_ctx_new(),
		tts = tts.new(),
		closed = false,
		chat = nil,
		silence_start_time = math.maxinteger,
		last_send_time = time.now(),
		device_frame_count = 0,
	}, xsession_mt)
	return s
end

function xsession:start()
	logger.info("xiaozhi", "start")
	self.pcm_data = {}
	self:sendjson({
		type = "tts",
		state = "start",
		sample_rate = 16000,
		session_id = self.session_id,
		text = "",
	})
end

function xsession:write(data)
	if self.state ~= STATE_SPEAKING then
		return false
	end
	local pcm_data, txt = self.tts:speak(data)
	if not pcm_data then
		return true
	end
	self.pcm_data[#self.pcm_data + 1] = pcm_data
	self:sendpcm(pcm_data, txt)
	return true
end

function xsession:stop()
	local pcm_data, txt = self.tts:flush()
	if pcm_data then
		self.pcm_data[#self.pcm_data + 1] = pcm_data
		self:sendpcm(pcm_data, txt)
	end
	local pcm = pcm_cache["over"]
	if pcm then
		self:sendpcm(pcm, "over")
	end
	--[[
	local dat = table.concat(self.pcm_data)
	local f<close> = io.open("xiaozhi.pcm", "wb")
	if not f then
		logger.error("[xiaozhi] failed to open xiaozhi.pcm")
		return
	end
	f:write(dat)
	f:close()
	]]

	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end

function xsession:error(err)
	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end


function xsession.sendjson(self, obj)
	local txt = json.encode(obj)
	self.sock:write(txt, "text")
end

local function sendopus(self, opus_datas, txt)
	if not opus_datas then
		return
	end
	self:sendjson({
		type = "tts",
		state = "sentence_start",
		text = txt,
		session_id = self.session_id
	})
	local need_sleep = 0
	for _, dat in ipairs(opus_datas) do
		self.silence_start_time = time.nowsec()
		self.sock:write(dat, "binary")
		need_sleep = need_sleep + 60
		if need_sleep > 1200 then
			local now = time.now()
			core.sleep(600)
			local elapsed = time.now() - now
			need_sleep = need_sleep -  elapsed
		end
	end
	if need_sleep > 0 then
		core.sleep(need_sleep)
	end
end

function xsession.sendpcm(self, pcm_data, txt)
	if not pcm_data or #pcm_data == 0 then
		return
	end
	local voice_ctx = self.voice_ctx
	if not voice_ctx then
		logger.error("[xiaozhi] voice context not found")
		return
	end
	local list = voice.wrap_opus(voice_ctx, pcm_data, true)
	if not list then
		logger.info("[xiaozhi] don't has pcm data")
		return
	end
	sendopus(self, list, txt)
end

local router = {}

function router.hello(session, req)
	session:sendjson(req)
	session:sendjson({type = "llm", emotion = "happy", text = "😀"})
end

function router.listen(session, req)
	if req.state == "start" then
		session.state = STATE_LISTENING
		voice.reset(session.voice_ctx)
		session.silence_start_time = time.nowsec()
		logger.info("xiaozhi", "start listening")
	elseif req.state == "stop" then
		session.state = STATE_IDLE
		logger.info("xiaozhi", "stop listening")
	elseif req.state == "detect" then
		logger.info("xiaozhi", "detect")
		session:sendjson({type = "stt", text = "小智", session_id = session.session_id})
		session:sendjson({type = "llm", text = "😊", emotion = "happy", session_id = session.session_id})
		session:sendjson({type = "tts", state = "start", sample_rate = 24000, session_id = session.session_id, text = "开始检测"})
		core.sleep(50)
		local pcm = pcm_cache["你好呀！"]
		session:sendpcm(pcm, "你好呀！")
		session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
	end
end

function router.abort(session, req)
	session.state = STATE_LISTENING
	session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
end

function router.iot(ctx, req)

end

function router.close(ctx, req)

end

---@param session xiaozhi.session
---@return boolean, string? error
local function vad_detect(session, dat)
	local voice_ctx = session.voice_ctx
	if not voice_ctx then
		logger.error("[xiaozhi] voice context not found")
		session.state = STATE_IDLE
		session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
		return false, "vad stream not found"
	end
	local txt
	local pcm = voice.detect_opus(voice_ctx, dat)
	if pcm then
		local err
		txt, err = asr(pcm)
		if not txt then
			logger.error("[xiaozhi] asr txt:`%s` error:`%s`",
				txt, err)
		end
		voice.reset(voice_ctx)
	end
	if not txt or #txt == 0 then
		local now = time.nowsec()
		if session.silence_start_time + conf.exit_after_silence_seconds < now then
			logger.infof("xiaozhi already silence %s seconds", now - session.silence_start_time)
			session.state = STATE_CLOSE
		end
		return true, nil
	end
	logger.infof("[xiaozhi] vad str:%s", txt)
	session:sendjson({type = "stt", text = txt, session_id = session.session_id})
	session.state = STATE_SPEAKING
	local chat = session.chat
	if not chat then
		session.chat = intent.agent(txt)
	end
	session.chat(session, txt)
	if intent.over(txt) then
		session.state = STATE_CLOSE
	else
		session.state = STATE_LISTENING
	end
	return true, nil
end

local server, err = websocket.listen {
	addr = conf.xiaozhi_listen,
	handler = function(sock)
		local session = xsession.new(1, sock)
		while session.state ~= STATE_CLOSE do
			local dat, typ = sock:read()
			if not dat then
				break
			end
			if typ == "close" then
				sock:close()
				break
			end
			if typ == "text" then
				local req = json.decode(dat)
				if not req then
					sock:write("error", "invalid request")
					sock:close()
					break
				end
				router[req.type](session, req)
			elseif typ == "binary" then
				if session.state == STATE_LISTENING then
					local ok, err = vad_detect(session, dat)
					if not ok then
						logger.error("[xiaozhi] vad detect error", err)
						session.state = STATE_IDLE
						session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
					end
				end
			end
		end
		session:sendjson({
			type = "tts",
			state = "start",
			sample_rate = 16000,
			session_id = session.session_id,
			text = "",
		})
		local pcm = pcm_cache["再见！"]
		if pcm then
			session:sendpcm(pcm, "再见！")
		end
		core.sleep(1000)
		session.closed = true
		logger.info("[xiaozhi] clear")
	end
}

logger.info("[xiaozhi] listen on", conf.xiaozhi_listen)
