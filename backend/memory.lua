local core = require "core"
local time = require "core.time"
local json = require "core.json"
local logger = require "core.logger"
local mutex = require "core.sync.mutex"
local conf = require "conf"
local openai = require "openai"
local embedding = require "embedding"
local db = require "db"

local tonumber = tonumber
local setmetatable = setmetatable
local date = os.date
local format = string.format
local concat = table.concat

local model_conf = conf.llm.think

---@class memory
---@field uid number
---@field working {role: string, content: string}[]
---@field compressed string[]
---@field profile {content: string}
local M = {}
local mt = {__index = M}

local dbk_profile<const> = "profile:%s"
local dbk_mem<const>  = "mem:%s"
local memory_index_name<const> = "memory_idx"
local dbk_mem_id = time.now() * 1000

local uid_lock = mutex.new()

local user_profile = setmetatable({}, {
	__mode = "v",
	__index = function(t, k)
		local ok, v = db:hget(dbk_profile, k)
		if not ok then
			logger.errorf("[memory] profile uid:%s failed: %s", k, v)
			return {content = ""}
		end
		local p = {content = v or ""}
		t[k] = p
		return p
	end
})

local function create_index()
	-- check index if exists
	local ok, res = db:call("FT.INFO", memory_index_name)
	if ok then
		logger.infof("[memory] index %s already exists", memory_index_name)
		return true
	end
	-- create vector index
	local ok, err = db:call("FT.CREATE", memory_index_name, "ON", "HASH",
		"PREFIX", "1", "mem:",
		"SCHEMA",
			"uid", "TAG",
			"timestamp", "NUMERIC", "SORTABLE",
			"embedding", "VECTOR", "HNSW", "6",
			"TYPE", "FLOAT32",
			"DIM", "1024",
			"DISTANCE_METRIC", "COSINE")
	if not ok then
		logger.errorf("[memory] create index failed: %s", err)
		return false
	end
	logger.infof("[memory] create index success")
	return true
end

local function retrieval(uid, msg)
	local vector, err = embedding(msg)
	if not vector then
		logger.errorf("[memory] uid:%s embedding failed: %s", uid, err)
		return nil, err
	end
	local ok, res = db:call("FT.SEARCH",
		memory_index_name,
		"@uid:{$uid}=>[KNN $n @embedding $vector as score]",
		"PARAMS", "6",
		"n", 5,
		"vector", vector,
		"uid", uid,
		"SORTBY", "timestamp", "DESC",
		"RETURN", "3",
		"chk_id", "score", "text",
		"DIALECT", "2"
	)
	if not ok then
		logger.errorf("[memory] uid:%s search failed: %s", uid, res)
		return nil, err
	end
	if not res or #res < 2 then
		return nil, "no result"
	end
	local results = {
		"以下是与当前查询相关的过去会话记忆："
	}
	for i=2, #res, 2 do
		local r = {}
		local dbv = res[i+1]
		for j = 1, #dbv, 2 do
			local k = dbv[j]
			local v = dbv[j+1]
			r[k] = v
		end
		local score = 1.0 - tonumber(r.score)
		results[#results+1] = format("[相关性: %.2f | 时间: %s] %s",
			score, date("%Y-%m-%d %H:%M:%S", r.timestamp), r.text)
	end
	return concat(results, "\n\n"), nil
end

local function summarize(uid, working, summary)
	local all_context = {}
	all_context[#all_context+1] = {
		role = "system",
		content = [[
# 对话记忆整合指令

你是一个对话信息整合专家，负责从对话中提取关键信息，用于长期记忆建档。
请仅提取用户和 AI 的重要交互内容，不包含闲聊、寒暄、感叹、重复信息等无效内容。
输出必须遵循以下格式，字段名称、顺序、标点必须完全一致。**禁止添加任何分析、评论、解释或问题**。

## 输出要求：
- 每个字段**必须填写**，如无内容请写 “无”；
- 每个字段中内容应以**要点形式**（编号或项目符号）列出；
- 每个字段最多提取 **3 条关键信息**，内容应**简洁明确**；
- 输出不超过 200 字。

<输出格式>
主题: [1~2句高度概括本轮对话的主题]
需求:
- [用户的目标、问题、请求等]
- [...]
- [...]
结论:
- [本轮达成的共识、明确事项或决定]
- [...]
- [...]
偏好:
- [用户表达的偏好，如工具、方式、风格等]
- [...]
- [...]
待办:
- [尚未完成或后续需要行动的事项]
- [...]
- [...]
其他:
- [其他无法归类但值得记录的关键信息]
- [...]
</输出格式>
]]
	}
	all_context[#all_context+1] = {
		role = "user",
		content = format([[
请你根据以下对话内容提取关键信息：

%s

请按照输出格式整理信息。
]], json.encode(working))
	}
	logger.debugf("[memory] update_summary uid:%s request: %s", uid, json.encode(all_context))
	local ai<close>, err = openai.open(model_conf, {
		messages = all_context,
		temperature = 0.1, -- 更低的温度提高确定性
		top_p = 0.3,       -- 限制采样范围
		frequency_penalty = 0.5, -- 降低重复
	})
	if not ai then
		logger.errorf("[memory] update_summary uid:%s failed: %s", uid, err)
		return ""
	end
	local response, err = ai:read()
	if not response then
		logger.errorf("[memory] update_summary uid:%s failed: %s", uid, err)
		return ""
	end
	return response.choices[1].message.content
end

local function save_chats(user)
	local working = user.working
	local content = summarize(user.uid, working, user.compressed)
	if not content or #content == 0 then
		logger.errorf("[memory] save_chats uid:%s failed: %s", user.uid, "no content")
		return
	end
	local vector, err = embedding(content)
	if not vector then
		logger.errorf("[memory] uid:%s save_chats embedding failed: %s", user.uid, err)
		return nil, err
	end
	local id = dbk_mem_id + 1
	dbk_mem_id = id
	local dbk = format(dbk_mem, id)
	local ok, err = db:pipeline {
		{"HMSET", dbk,
			"uid", user.uid,
			"embedding", vector,
			"text", content,
			"timestamp", os.time()
		},
		{"EXPIRE", dbk, 60 * 60 * 24 * 30}
	}
	if not ok then
		logger.errorf("[memory] uid:%s save_chats failed: %s", user.uid, err)
		return
	end
	logger.infof("[memory] uid:%s save_chats `%s` success", user.uid, content)
end
local function update_profile(user)
	local all_context = {}
	all_context[#all_context+1] = {
		role = "system",
		content = [[
# 用户画像生成器
你是一个用户画像提取与维护专家，任务是根据当前对话内容**更新并生成**用户画像。
- 请在分析后，根据需要修改、增加或补充画像中的字段。
- 如果当前对话没有新增信息，请原样保留所有字段内容，不可进行空洞总结或删减。

格式严格如下，不添加额外内容、不改变字段顺序、不增加额外字段：
<用户画像>
兴趣: [列出兴趣点，多个用逗号分隔]
职业: [简明准确地描述职业]
需求: [总结用户当前表达的主要需求或目标]
偏好: [总结用户偏好的工具、语言、交互方式等]
背景: [历史对话中提取的有价值背景信息]
</用户画像>
]]
	}
	local lock<close> = uid_lock:lock(user.uid)
	all_context[#all_context+1] = {
		role = "user",
		content = format([[
用户当前画像：
%s
用户当前对话记录:
%s

请根据当前对话内容更新用户画像。
]], user.profile.content, json.encode(user.working)),
	}
	local ai<close>, err = openai.open(model_conf, {
		messages = all_context,
		temperature = 0.0, -- 降至最低以获得最大确定性
		top_p = 0.1, -- 进一步限制采样范围
		frequency_penalty = 0.2, -- 略微降低，因为过高可能导致避开必要的格式词
		presence_penalty = 0.0, -- 添加轻微的惩罚以避免引入新主题
		max_tokens = 256 -- 限制输出长度，只需要画像部分
	})
	if not ai then
		logger.errorf("[memory] update_profile failed: %s", err)
		return
	end
	local response, err = ai:read()
	if not response then
		logger.errorf("[memory] update_profile failed: %s", err)
		return
	end
	local content = response.choices[1].message.content
	logger.debugf("[memory] update_profile uid:%s content: %s", user.uid, content)
	user.profile.content = content
	local ok, err = db:hset(dbk_profile, user.uid, content)
	logger.infof("[memory] update_profile uid:%s result: %s err: %s", user.uid, ok, err)
end

function M.start()
	create_index()
end

---@param uid number
---@return memory
function M.new(uid)
	return setmetatable({
		uid = uid,
		working = {},
		compressed = {},
		profile = user_profile[uid],
	}, mt)
end

---@param self memory
---@param tbl table{role: string, content: string}
---@param msg string
function M:retrieve(tbl, msg)
	-- 1. 长期记忆
	local txt, err = retrieval(self.uid, msg)
	if txt and #txt > 0 then
		tbl[#tbl + 1] = {
			role = "system",
			content = txt,
		}
	else
		logger.errorf("[memory] retrieval uid:%s failed: %s", self.uid, err)
	end
	-- 2. 用户画像信息
	local profile = self.profile.content
	tbl[#tbl + 1] = {
		role = "system",
		content = "用户画像信息：" .. profile,
	}
	-- 4. 添加近期上下文（如果有）
	local compressed = self.compressed
	if #compressed > 0 then
		tbl[#tbl + 1] = {
			role = "system",
			content = "近期上下文：" .. concat(compressed, "\n\n"),
		}
	end
	-- 5. 添加工作记忆
	local working = self.working
	for i = 1, #working do
		tbl[#tbl + 1] = working[i]
	end
	-- 6. 添加当前问题
	tbl[#tbl + 1] = {
		role = "user",
		content = msg,
	}
end

function M:add(q, a)
	local working = self.working
	working[#working + 1] = {
		role = "user",
		content = q,
	}
	working[#working + 1] = {
		role = "assistant",
		content = a,
	}
end

function M:close()
	core.fork(function()
		save_chats(self)
	end)
	core.fork(function()
		update_profile(self)
	end)

end

return M