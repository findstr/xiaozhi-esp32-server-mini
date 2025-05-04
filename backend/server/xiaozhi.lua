local core = require "core"
local time = require "core.time"
local json = require "core.json"
local channel = require "core.sync.channel"
local logger = require "core.logger"
local websocket = require "core.websocket"
local voice = require "voice.vad"
local asr = require "asr"
local tts = require "tts"
local conf = require "conf"
local memory = require "memory"
local intent = require "intent"

local ipairs = ipairs
local concat = table.concat
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
		local buf = {}
		local ttsx = tts.new()
		local ok = ttsx:txt_to_pcm(k, function(pcm)
			buf[#buf + 1] = pcm
		end)
		if #buf > 0 then
			save_pcm(path, concat(buf))
		end
		if not ok then
			logger.error("[xiaozhi] failed to convert text to pcm", k)
		end
		pcm = table.concat(buf)
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
---@field remoteaddr string
---@field sock core.websocket.socket
---@field tts tts
---@field session_id string
---@field chat? function(session, string):boolean
---@field silence_start_time integer
---@field last_send_time integer
---@field channel_data core.sync.channel
---@field channel_ctrl core.sync.channel
---@field txt_cb fun(txt: string)
---@field pcm_cb fun(pcm: string)
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

local function pcm_cb(session)
	return function(pcm)
		session.pcm_data[#session.pcm_data + 1] = pcm
		local voice_ctx = session.voice_ctx
		if not voice_ctx then
			logger.error("[xiaozhi] voice context not found")
			return
		end
		local list = voice.wrap_opus(voice_ctx, pcm, true)
		if not list then
			logger.info("[xiaozhi] don't has pcm data")
			return
		end
		local channel = session.channel_data
		for _, opus in ipairs(list) do
			channel:push {
				type = "opus",
				data = opus,
			}
		end
	end
end

local function txt_cb(session)
	return function(txt)
		session.channel_data:push {
			type = "tts",
			state = "sentence_start",
			text = txt,
			session_id = session.session_id,
		}
	end
end

---@param uid number
---@param sock core.websocket.socket
---@return xiaozhi.session
function xsession.new(uid, sock)
	local channel_data = channel.new()
	local channel_ctrl = channel.new()
	local s = setmetatable({
		memory = memory.new(uid),
		state = STATE_IDLE,
		sock = sock,
		remoteaddr = sock.stream.remoteaddr,
		session_id = false,
		voice_ctx = voice_ctx_new(),
		tts = tts.new(),
		closed = false,
		chat = nil,
		silence_start_time = math.maxinteger,
		last_send_time = time.now(),
		device_frame_count = 0,
		pcm_data = {},
		channel_data = channel_data,
		channel_ctrl = channel_ctrl,
		txt_cb = nil,
		pcm_cb = nil,
	}, xsession_mt)
	s.txt_cb = txt_cb(s)
	s.pcm_cb = pcm_cb(s)
	core.fork(function()
		local device_recv_time = 0
		local last_send_time = 0
		while true do
			local dat, err = channel_data:pop()
			if not dat then
				logger.infof("[xiaozhi] channel_data close err:%s", err)
				break
			end
			if dat.type == "opus" then
				local now = time.now()
				s.silence_start_time = now
				s.sock:write(dat.data, "binary")
				device_recv_time = device_recv_time + 60
				local elapsed = now - last_send_time
				local playing = device_recv_time-elapsed
				logger.debugf("[xiaozhi] write opus, device left:%s", playing // 60)
				if playing < -120 then
					last_send_time = now
					device_recv_time = 0
				end
				if playing > 180 then -- 缓冲区快满了
					local need_sleep = playing - 180
					core.sleep(need_sleep)
				end
			elseif dat.type == "sync" then
				logger.debugf("[xiaozhi] sync")
				channel_ctrl:push(dat)
			else
				local txt = json.encode(dat)
				s.sock:write(txt, "text")
				logger.debugf("[xiaozhi] write text:%s", txt)
			end
			if dat.type == "tts" and dat.state == "sentence_start" then
				core.sleep(10)
			end
		end
		channel_ctrl:close()
	end)
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
	-- remove '*' from data
	data = data:gsub("%*", "")
	if #data == 0 then
		return true
	end
	local ok = self.tts:speak(data, self.txt_cb, self.pcm_cb)
	if not ok then
		return true
	end
	return true
end

function xsession:over_tips()
	local pcm = pcm_cache["over"]
	if pcm then
		self.txt_cb("结束")
		self.pcm_cb(pcm)
	end
end

function xsession:stop()
	self.tts:flush(self.txt_cb, self.pcm_cb)
	self:over_tips()
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
	logger.debugf("[xiaozhi] tts stop")
end

function xsession:error(err)
	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end


function xsession.sendjson(self, obj)
	self.channel_data:push(obj)
end

function xsession.sync(self, state)
	self.channel_data:push {
		type = "sync",
	}
	self.channel_ctrl:pop()
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

---@param session xiaozhi.session
function router.listen(session, req)
	if req.state == "start" then
		session.state = STATE_LISTENING
		voice.reset(session.voice_ctx)
		session.silence_start_time = time.nowsec()
		logger.info("xiaozhi state:", "listening")
	elseif req.state == "stop" then
		session.state = STATE_IDLE
		logger.info("xiaozhi state", "idle")
	elseif req.state == "detect" then
		logger.info("xiaozhi", "detect")
		session.channel_data:clear()
		session:sendjson({type = "stt", text = "小智", session_id = session.session_id})
		session:sendjson({type = "llm", text = "😊", emotion = "happy", session_id = session.session_id})
		session:sendjson({type = "tts", state = "start", sample_rate = 16000, session_id = session.session_id, text = "开始检测"})
		core.sleep(60)
		local pcm = pcm_cache["你好呀！"]
		if pcm then
			session.txt_cb("你好呀！")
			session.pcm_cb(pcm)
		end
		session:over_tips()
		session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
	end
end

function router.abort(session, req)
	session.state = STATE_IDLE
	session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
	logger.info("xiaozhi state", "idle")
end

function router.iot(ctx, req)

end

function router.close(ctx, req)

end

---@param session xiaozhi.session
local function vad_detect(session, dat)
	local voice_ctx = session.voice_ctx
	if not voice_ctx then
		logger.error("[xiaozhi] voice context not found")
		session.state = STATE_IDLE
		logger.info("xiaozhi state", "idle")
		session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
		return
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
			logger.info("xiaozhi state", "close")
		end
		return
	end
	core.fork(function()
		logger.infof("[xiaozhi] vad str:%s", txt)
		session:sendjson({type = "stt", text = txt, session_id = session.session_id})
		session.state = STATE_SPEAKING
		logger.info("xiaozhi state", "speaking")
		local chat = session.chat
		if not chat then
			session.chat = intent.agent(txt)
		end
		session.chat(session, txt)
		session:sync()
		if intent.over(txt) then
			session.state = STATE_CLOSE
			logger.info("xiaozhi state", "close")
		else
			session.state = STATE_LISTENING
			voice.reset(session.voice_ctx)
			logger.info("xiaozhi state", "listening")
		end
	end)
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
				break
			end
			if typ == "text" then
				local req = json.decode(dat)
				if not req then
					break
				end
				router[req.type](session, req)
			elseif typ == "binary" then
				if session.state == STATE_LISTENING then
					vad_detect(session, dat)
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
			session.txt_cb("再见！")
			session:sendjson({
				type = "tts",
				state = "stop",
				session_id = session.session_id,
			})
		end
		session.channel_data:close()
		session:sync()
		core.sleep(500)
		logger.info("[xiaozhi] clear")
	end
}

logger.info("[xiaozhi] listen on", conf.xiaozhi_listen)
