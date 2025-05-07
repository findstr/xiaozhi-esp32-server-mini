local core = require "core"
local time = require "core.time"
local json = require "core.json"
local channel = require "core.sync.channel"
local waitgroup = require "core.sync.waitgroup"
local logger = require "core.logger"
local websocket = require "core.websocket"
local voice = require "voice.vad"
local asr = require "asr"
local tts = require "tts"
local conf = require "conf"
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
	if pcm then
		t[k] = pcm
	end
	return pcm
end})

---@class xiaozhi.session : session
---@field uid number
---@field need_over boolean
---@field voice_ctx userdata
---@field state xiaozhi.state
---@field remoteaddr string
---@field session_id string
---@field silence_start_time integer
---@field ch_ctrl core.sync.channel
---@field ch_device_write core.sync.channel
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

---@param session xiaozhi.session
---@return string?
local function asr_detect(session, dat)
	local txt
	local voice_ctx = session.voice_ctx
	local pcm = voice.detect_opus(voice_ctx, dat)
	if pcm then
		local err
		txt, err = asr(pcm)
		if not txt then
			logger.errorf("[xiaozhi] asr error:`%s`", err)
		end
		voice.reset(voice_ctx)
	end
	return txt
end

--local debugi = 0
local debug_pcm_buf = {}

local function pcm_cb(session)
	return function(pcm)
		local voice_ctx = session.voice_ctx
		if not voice_ctx then
			logger.error("[xiaozhi] voice context not found")
			return
		end
		--debug_pcm_buf[#debug_pcm_buf + 1] = pcm
		local list = voice.wrap_opus(voice_ctx, pcm, true)
		if not list then
			logger.info("[xiaozhi] don't has pcm data")
			return
		end
		local channel = session.ch_device_write
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
		session.ch_device_write:push {
			type = "tts",
			state = "sentence_start",
			text = txt,
			session_id = session.session_id,
		}
	end
end

local function new_device_writer(session, sock)
	return function()
		local ch_ctrl = session.ch_ctrl
		local ch_device_write = session.ch_device_write
		local device_recv_time = 0
		local last_send_time = 0
		while true do
			local dat, err = ch_device_write:pop()
			if not dat then
				logger.infof("[xiaozhi] channel_data close err:%s", err)
				break
			end
			if dat.type == "opus" then
				local now = time.now()
				session.silence_start_time = now
				sock:write(dat.data, "binary")
				device_recv_time = device_recv_time + 60
				local elapsed = now - last_send_time
				local playing = device_recv_time-elapsed
				logger.debugf("[xiaozhi] write opus, device left:%s", playing // 60)
				if playing < -120 then
					last_send_time = now
					device_recv_time = 0
				end
				if playing >= 180 then -- 缓冲区快满了
					local need_sleep = playing - 180
					core.sleep(need_sleep)
				end
			elseif dat.type == "sync" then
				logger.debugf("[xiaozhi] sync")
				ch_ctrl:push(dat)
			else
				local txt = json.encode(dat)
				sock:write(txt, "text")
				logger.debugf("[xiaozhi] write text:%s", txt)
			end
			if dat.type == "tts" and dat.state == "sentence_start" then
				core.sleep(10)
			end
		end
		logger.info("[xiaozhi] device_writer close")
		ch_ctrl:close()
	end
end

local function new_llm_reader(session)
	return function()
		local first = true
		local tts = tts.new()
		local text_cb = session.txt_cb
		local pcm_cb = session.pcm_cb
		local ch_llm_output = session.ch_llm_output
		local ch_device_write = session.ch_device_write
		while true do
			local dat = ch_llm_output:pop()
			if not dat then
				break
			end
			if #dat > 0 then
				if first then --start tts
					first = false
					ch_device_write:push {
						type = "tts",
						state = "start",
						sample_rate = 16000,
						session_id = session.session_id,
						text = "",
					}
				end
				dat = dat:gsub("%*", "")
				if #dat > 0 then
					tts:speak(dat, text_cb, pcm_cb)
				end
			else
				first = true
				tts:flush(text_cb, pcm_cb)
				local pcm = pcm_cache["over"]
				if pcm then
					pcm_cb(pcm)
				end

				if debugi then
					debugi = debugi + 1
					local name = string.format("pcm/%s.pcm", debugi)
					local f<close>, err = io.open(name, "wb")
					f:write(concat(debug_pcm_buf))
					f:close()
					debug_pcm_buf = {}
				end

				ch_device_write:push {
					type = "tts",
					state = "stop",
					session_id = session.session_id,
				}
				session:sync()
				if session.need_over then
					session.state = STATE_CLOSE
					logger.info("xiaozhi state: close")
				else
					session.state = STATE_LISTENING
					voice.reset(session.voice_ctx)
					logger.info("xiaozhi state: listening")
				end
			end
		end
		logger.info("[xiaozhi] llm_reader close")
		session:sync()
		session.ch_device_write:close()
	end
end

local function listening(session, dat, wg)
	local now = time.nowsec()
	local txt = asr_detect(session, dat)
	if not txt or #txt == 0 then
		if session.silence_start_time + conf.exit_after_silence_seconds < now then
			logger.infof("xiaozhi already silence %s seconds", now - session.silence_start_time)
			local ch_llm_output = session.ch_llm_output
			ch_llm_output:push("再见！")
			ch_llm_output:push("")
			session.state = STATE_CLOSE
			logger.info("xiaozhi state", "close")
		end
		return
	end
	session:sendjson({type = "stt", text = txt, session_id = session.session_id})
	local ch_llm_input = session.ch_llm_input
	if not ch_llm_input then
		ch_llm_input = channel.new()
		session.ch_llm_input = ch_llm_input
		local agent = intent.agent(txt)
		wg:fork(function()
			agent(session)
			logger.debugf("[xiaozhi] agent close")
			ch_llm_input:close()
			session.ch_llm_input = nil
		end)
	end
	session.state = STATE_SPEAKING
	session.ch_llm_input:push(txt)
	session.silence_start_time = now
	session.need_over = intent.over(txt)
	logger.infof("xiaozhi intent intent.over:`%s` result:%s: ", txt, session.need_over)
end

---@param uid number
---@param sock core.websocket.socket
---@param wg core.sync.waitgroup
---@return xiaozhi.session
function xsession.new(uid, sock, wg)
	local ch_device_write = channel.new()
	local ch_ctrl = channel.new()
	local ch_llm_output = channel.new()
	local s = setmetatable({
		uid = uid,
		needover = false,
		state = STATE_IDLE,
		remoteaddr = sock.stream.remoteaddr,
		voice_ctx = voice_ctx_new(),
		silence_start_time = math.maxinteger,
		ch_device_write = ch_device_write,
		ch_llm_input = nil,
		ch_llm_output = ch_llm_output,
		ch_ctrl = ch_ctrl,
		txt_cb = nil,
		pcm_cb = nil,
	}, xsession_mt)
	s.txt_cb = txt_cb(s)
	s.pcm_cb = pcm_cb(s)
	-- device writer
	wg:fork(new_device_writer(s, sock))
	-- llm reader
	wg:fork(new_llm_reader(s))
	return s
end


function xsession:over_tips()
	local pcm = pcm_cache["over"]
	if pcm then
		self.pcm_cb(pcm)
	end
end

function xsession.sendjson(self, obj)
	self.ch_device_write:push(obj)
end

function xsession.sync(self, state)
	self.ch_device_write:push {
		type = "sync",
	}
	self.ch_ctrl:pop()
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
		logger.info("xiaozhi state: listening")
	elseif req.state == "stop" then
		session.state = STATE_CLOSE
		logger.info("xiaozhi state: close")
	elseif req.state == "detect" then
		local ch_llm_output = session.ch_llm_output
		logger.info("xiaozhi state: detect")
		session.ch_device_write:clear()
		session:sendjson({type = "stt", text = "小智", session_id = session.session_id})
		session:sendjson({type = "llm", text = "😊", emotion = "happy", session_id = session.session_id})
		session:sendjson({type = "tts", state = "start", sample_rate = 16000, session_id = session.session_id, text = "开始检测"})
		core.sleep(60)
		ch_llm_output:clear()
		ch_llm_output:push("你好呀！")
		ch_llm_output:push("")
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


local server, err = websocket.listen {
	addr = conf.xiaozhi_listen,
	handler = function(sock)
		local wg = waitgroup.new()
		local session = xsession.new(1, sock, wg)
		while session.state ~= STATE_CLOSE do
			local dat, typ = sock:read()
			if not dat then
				break
			end
			if typ == "close" or session.state == STATE_CLOSE then
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
					listening(session, dat, wg)
				end
			end
		end
		if session.ch_llm_input then
			session.ch_llm_input:close()
		end
		session.ch_llm_output:close()
		wg:wait()
	end,
}

logger.info("[xiaozhi] listen on", conf.xiaozhi_listen)
