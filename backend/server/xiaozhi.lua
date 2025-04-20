local core = require "core"
local time = require "core.time"
local json = require "core.json"
local logger = require "core.logger"
local websocket = require "core.websocket"
local protoc = require "protoc"
local pb = require "pb"
local voice = require "voice"
local asr = require "asr"
local tts = require "tts"
local conf = require "conf"
local memory = require "memory"
local intent = require "intent"

local pairs = pairs
local ipairs = ipairs
local remove = table.remove

local p = protoc:new()

---@alias xiaozhi.state "idle" | "listening" | "speaking" | "close"
local STATE_IDLE = "idle"
local STATE_LISTENING = "listening"
local STATE_SPEAKING = "speaking"
local STATE_CLOSE = "close"

p:load[[
syntax = "proto3";
package xiaozhi;

message frames {
	repeated bytes list = 1;
}
]]

local function save_frames(file, frames)
	local f<close>, err = io.open(file, "wb")
	if not f then
		logger.error("[xiaozhi] failed to open audio.bin", err)
		return
	end
	local dat = pb.encode("xiaozhi.frames", {list = frames})
	f:write(dat)
end

local function read_frames(file)
	local f<close>, err = io.open(file, "rb")
	if not f then
		return
	end
	local dat = f:read("a")
	local frames = pb.decode("xiaozhi.frames", dat)
	if not frames then
		logger.error("[xiaozhi] failed to decode audio.bin")
		return
	end
	return frames.list
end

local hello_opus = nil

do
	hello_opus = read_frames("hello.opus")
end


---@class xiaozhi.session : session
---@field memory memory
---@field voice_ctx userdata
---@field state xiaozhi.state
---@field remote_addr string
---@field sock core.http.websocket
---@field session_id string
---@field speak_buf {content: string, type: string}[]
---@field chat? function(session, string):boolean
---@field closed boolean
---@field silence_start_time integer
local xsession = {}
local xsession_mt = {__index = xsession}

local voice_ctx_pool = {}

local function voice_ctx_new()
	local ctx = remove(voice_ctx_pool, 1)
	if ctx then
		voice.reset(ctx)
	else
		ctx = voice.new {
			model_path = "models/silero_vad.onnx",
			min_silence_duration_ms = 700,
		}
	end
	return ctx
end

local function voice_ctx_free(ctx)
	voice_ctx_pool[#voice_ctx_pool + 1] = ctx
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
		speak_buf = {},
		closed = false,
		chat = nil,
		silence_start_time = math.maxinteger,
	}, xsession_mt)
	core.fork(function()
		local remove = table.remove
		local frames_in_device = 0
		local last_send_time = time.now()  -- 初始化为当前时间
		local frame_duration_ms = 60  -- Opus 一帧的持续时间(ms)
		local max_buffer_frames = 10   -- 目标是保持设备缓冲区不超过 4 帧(给 5 帧缓冲区留出安全余量)

		while not s.closed or #s.speak_buf > 0 do
		   	local list = remove(s.speak_buf, 1)
		   	if list then
				local now_ms = time.now()
			        -- 计算自上次发送以来，设备消耗了多少帧
			        if last_send_time > 0 and frames_in_device > 0 then
			        	local elapsed_ms = now_ms - last_send_time
			        	local consumed_frames = elapsed_ms / frame_duration_ms
			        	frames_in_device = math.max(0, frames_in_device - consumed_frames)
			        end
				for _, dat in ipairs(list) do
			            -- 如果缓冲区已满，等待直到有空间
			            while frames_in_device >= max_buffer_frames do
			                -- 等待一小段时间
			                core.sleep(10)  -- 等待更小的时间单位，更精确地控制流量
			                -- 更新当前时间和已消耗的帧数
			                now_ms = time.now()
			                local elapsed_ms = now_ms - last_send_time
			                local consumed_frames = elapsed_ms / frame_duration_ms
			                -- 更新设备中的帧数
			                if consumed_frames > 0 then
			                    frames_in_device = math.max(0, frames_in_device - consumed_frames)
			                    last_send_time = now_ms
			                    logger.debug("[xiaozhi] 缓冲区当前帧数: " .. string.format("%.2f", frames_in_device))
			                end
			            end
			            -- 发送数据
			            local ok = s.sock:write(dat.content, dat.type)
			            if not ok then
			                logger.error("[xiaozhi] write error")
			                break
			            end
			            -- 只有二进制数据（Opus 帧）才计入缓冲区
			            if dat.type == "binary" then
			                frames_in_device = frames_in_device + 1
			                last_send_time = time.now()  -- 更新最后发送时间
			                logger.debug("[xiaozhi] 发送帧，当前缓冲区: " .. string.format("%.2f", frames_in_device))
			            end
			        end
			else
				core.sleep(10)
			end
		end
		local voice_ctx = s.voice_ctx
		if voice_ctx then
			voice_ctx_free(voice_ctx)
			s.voice_ctx = nil
		end
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
	--print("write", data)
	local pcm_data, txt = self.tts:speak(data)
	if not pcm_data then
		return true
	end
	self.pcm_data[#self.pcm_data + 1] = pcm_data
	self:sendpcm(pcm_data, txt)
	return true
end

function xsession:stop()
	local pcm_data, txt = self.tts:close()
	if pcm_data then
		self.pcm_data[#self.pcm_data + 1] = pcm_data
		self:sendpcm(pcm_data, txt)
	end

	local dat = table.concat(self.pcm_data)
	local f<close> = io.open("xiaozhi.pcm", "wb")
	if not f then
		logger.error("[xiaozhi] failed to open xiaozhi.pcm")
		return
	end
	f:write(dat)
	f:close()

	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end

function xsession:error(err)
	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end


function xsession.sendjson(self, obj)
	local sb = self.speak_buf
	sb[#sb + 1] = {{content = json.encode(obj), type = "text"}}
end

function xsession.sendopus(self, opus_datas, txt)
	if not opus_datas then
		return
	end
	local start = {
		type = "tts",
		state = "sentence_start",
		text = txt,
		session_id = self.session_id
	}
	local list = {
		{content = json.encode(start), type = "text"},
	}
	for i, dat in ipairs(opus_datas) do
		list[#list + 1] = {content = dat, type = "binary"}
	end
	local sb = self.speak_buf
	sb[#sb + 1] = list
end

function xsession.sendpcm(self, pcm_data, txt)
	if not pcm_data then
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
	xsession.sendopus(self, list, txt)
end

local router = {}

function router.hello(session, req)
	session:sendjson(req)
	session:sendjson({type = "llm", emotion = "happy", text = "😀"})
end

function router.listen(session, req)
	if req.state == "start" then
		session.state = STATE_LISTENING
		session.speak_buf = {}
		voice.reset(session.voice_ctx)
		session.silence_start_time = time.nowsec()
		logger.info("xiaozhi", "start listening")
	elseif req.state == "stop" then
		session.state = STATE_IDLE
		logger.info("xiaozhi", "stop listening")
	elseif req.state == "detect" then
		logger.info("xiaozhi", "detect")
		session:sendjson({type = "tts", state = "start", sample_rate = 24000, session_id = session.session_id, text = "开始检测"})
		session:sendjson({type = "stt", text = "小智", session_id = session.session_id})
		session:sendjson({type = "llm", text = "😊", emotion = "happy", session_id = session.session_id})
		session:sendjson({type = "tts", state = "sentence_start", text = "你好呀，混沌！今天有什么新鲜事儿吗？", session_id = session.session_id})
		session.speak_buf = {}
		local tts = session.tts
		local prompt = "你好呀，混沌！"
		if not hello_opus then
			local opus, txt = tts:speak(prompt)
			hello_opus = opus
			save_frames("hello.opus", hello_opus)
		end
		session:sendopus(hello_opus, prompt)
		local pcm_data, txt = tts:close()
		if not pcm_data then
			logger.error("[xiaozhi] failed to close tts")
			return nil
		end
		session:sendpcm(pcm_data, txt)
		session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
	end
end

function router.abort(session, req)
	local buf = session.speak_buf
	for k in pairs(buf) do
		buf[k] = nil
	end
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
	logger.info("xiaozhi", "binary", #dat)
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
					session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
				end
			end
		end
	end
	session.closed = true
	logger.info("[xiaozhi] stop")
end
}

logger.info("[xiaozhi] listen on", conf.xiaozhi_listen)
