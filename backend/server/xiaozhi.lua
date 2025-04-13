local core = require "core"
local time = require "core.time"
local json = require "core.json"
local logger = require "core.logger"
local websocket = require "core.websocket"
local protoc = require "protoc"
local pb = require "pb"
local vad = require "vad"
local asr = require "asr"
local tts = require "tts"
local conf = require "conf"
local memory = require "memory"
local agent = require "agent"
local intent = require "intent"

local pairs = pairs
local ipairs = ipairs

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
		logger.error("xiaozhi", "failed to open audio.bin", err)
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
		logger.error("xiaozhi", "failed to decode audio.bin")
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
---@field state xiaozhi.state
---@field remote_addr string
---@field sock core.http.websocket
---@field session_id string
---@field vad_stream vad.stream
---@field buf string
---@field speak_buf {content: string, type: string}[]
---@field chat? function(session, string):boolean
---@field closed boolean
---@field silence_start_time integer
---@
local xsession = {}
local xsession_mt = {__index = xsession}


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
		vad_stream = nil,
		tts = nil,
		speak_buf = {},
		closed = false,
		chat = nil,
		silence_start_time = math.maxinteger,
	}, xsession_mt)
	core.fork(function()
		local remove = table.remove
		while not s.closed or #s.speak_buf > 0  do
			local dat = remove(s.speak_buf, 1)
			if dat then
				s.sock:write(dat.content, dat.type)
				if dat.type == "binary" then
					core.sleep(30)
				end
			else
				core.sleep(1)
			end
		end
		local vad_stream = s.vad_stream
		if vad_stream then
			vad_stream:close()
			s.vad_stream = nil
		end
	end)
	return s
end

function xsession:start()
	logger.info("xiaozhi", "start")
	self.tts = tts.new()
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
	local opus_data, txt = self.tts:speak(data)
	if not opus_data then
		return true
	end
	self:sendopus(opus_data, txt)
	return true
end

function xsession:stop()
	local opus_datas, txt = self.tts:close()
	if opus_datas then
		self:sendopus(opus_datas, txt)
	end
	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end

function xsession:error(err)
	self:sendjson({type = "tts", state = "stop", session_id = self.session_id})
end


function xsession.sendjson(self, obj)
	local sb = self.speak_buf
	sb[#sb + 1] = {content = json.encode(obj), type = "text"}
end

function xsession.sendopus(self, opus_datas, txt)
	if not opus_datas then
		return
	end
	local sb = self.speak_buf
	self:sendjson({type = "tts", state = "sentence_start", text = txt, session_id = self.session_id})
	for i, dat in ipairs(opus_datas) do
		sb[#sb + 1] = {content = dat, type = "binary"}
	end
end


local router = {}

function router.hello(session, req)
	session:sendjson(req)
	session:sendjson({type = "llm", emotion = "happy", text = "😀"})
end

function router.listen(session, req)
	if req.state == "start" then
		session.state = STATE_LISTENING
		session.vad_stream = vad()
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
		local tts = tts.new()
		if not tts then
			logger.error("xiaozhi", "failed to create tts")
		else
			local prompt = "你好呀，混沌！"
			if not hello_opus then
				local opus, txt = tts:speak(prompt)
				hello_opus = opus
				save_frames("hello.opus", hello_opus)
			end
			session:sendopus(hello_opus, prompt)
			local opus_datas, txt = tts:close()
			if not opus_datas then
				logger.error("xiaozhi", "failed to close tts")
				return nil
			end
			session:sendopus(opus_datas, txt)
		end
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
local function vad_detect(session, dat)
	logger.info("xiaozhi", "binary", #dat)
	local vad_stream = session.vad_stream
	if not vad_stream then
		logger.error("xiaozhi", "vad stream not found")
		session.state = STATE_IDLE
		session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
		return false, "vad stream not found"
	end
	local ok, err = vad_stream:write {
		sampling_rate = 16000,
		min_silence_duration = 0.7,
		threshold = 0.5,
		opus_audio_frame = dat,
	}
	if not ok then
		return false, err
	end
	local res, err = vad_stream:read()
	if not res then
		logger.error("[xiaozhi] vad read error", err)
		return false, err
	end
	if not res.is_finished then
		local now = time.nowsec()
		if session.silence_start_time + conf.exit_after_silence_seconds < now then
			session.state = STATE_CLOSE
		end
		return true, nil
	end
	session.state = STATE_IDLE
	vad_stream:close()
	session.vad_stream = nil
	local txt, err = asr(res.audio)
	if not txt or #txt == 0 then
		logger.error("[xiaozhi] asr error", err)
		return false, err
	end
	logger.infof("[xiaozhi] vad str:%s", txt)
	session:sendjson({type = "stt", text = txt, session_id = session.session_id})
	session.state = STATE_SPEAKING
	local chat = session.chat
	if not chat then
		local agent_name = intent.agent(txt) or "chat"
		chat = agent[agent_name]
		session.chat = chat
	end
	chat(session, txt)
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
			print("text", dat)
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
					logger.error("xiaozhi", "vad detect error", err)
					session.state = STATE_IDLE
					session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
					session:sendjson({type = "tts", state = "stop", session_id = session.session_id})
				end
			end
		end
	end
	session.closed = true
	logger.info("xiaozhi", "stop")
end
}

print("xiaozhi listen on", conf.xiaozhi_listen)
