local json = require "core.json"
local db = require "db"
local embedding = require "embedding"
local tostring = tostring

-- 删除所有chk:*的键
local function delete_all_chunks()
    local cursor = "0"
    local count = 0

    repeat
        local ok, res = db:call("SCAN", cursor, "MATCH", "chk:*", "COUNT", "100")
        if not ok then
            return false, res
        end

        cursor = res[1]
        local keys = res[2]

        if #keys > 0 then
            local ok, err = db:call("DEL", table.unpack(keys))
            if not ok then
                print("删除键失败:", err)
            else
                count = count + #keys
            end
        end
    until cursor == "0"

    print("成功删除", count, "个chk:*键")
    return true
end

delete_all_chunks()

local ok, chk_id_str = db:get("chk:id")
assert(ok, chk_id_str)
local chk_id = 1
if chk_id_str then
	chk_id = tonumber(chk_id_str)
end
print("chk_id", chk_id)
-- 创建全文索引
local function create_index()
	-- 检查索引是否已存在
	local ok, res = db:call("FT.INFO", "chunks_idx")
	if ok then
		print("索引已存在，跳过创建")
		return true
	end
	-- 创建向量索引
	local ok, err = db:call("FT.CREATE", "chunks_idx", "ON", "HASH", "PREFIX", "1", "chk:",
		"SCHEMA", "embedding", "VECTOR", "HNSW", "6",
			"TYPE", "FLOAT32",
			"DIM", "1024",
			"DISTANCE_METRIC", "COSINE")
	if not ok then
		print("创建索引失败:", err)
		return false
	end
	print("成功创建全文索引")
	return true
end

-- 将文本分块
local function splitIntoChunks(text, maxChunkSize)
	local chunks = {}
	local chunkSize = maxChunkSize or 500 -- 默认每块500字符
	-- 按段落分割
	local paragraphs = {}
	for para in text:gmatch("([^\n]+)") do
		if para:match("%S") then -- 忽略空行
			paragraphs[#paragraphs + 1] = para
		end
	end
	local currentChunk = ""
	for _, para in ipairs(paragraphs) do
		if #currentChunk + #para > chunkSize and #currentChunk > 0 then
			chunks[#chunks + 1] = currentChunk
			currentChunk = para
		else
			if #currentChunk > 0 then
				currentChunk = currentChunk .. "\n\n" .. para
			else
				currentChunk = para
			end
		end
	end
	if #currentChunk > 0 then
		chunks[#chunks + 1] = currentChunk
	end
	return chunks
end

-- 处理单个文档
local function processDocument(docId)
	-- 获取文档内容
	local ok, docJson = db:call("JSON.GET", docId, ".")
	if not ok then
		print("获取文档失败:", docId)
		return false
	end

	local doc = json.decode(docJson)
	if not doc or not doc.content then
		print("文档格式错误:", docId)
		return false
	end

	-- 分块
	local chunks = splitIntoChunks(doc.content)
	print("文档 " .. doc.title .. " 分割为 " .. #chunks .. " 个块")
	local docs = {}
	for i, chunk in ipairs(chunks) do
		local id = chk_id + 1
		chk_id = id
		docs[i] = {
			id = tostring(id),
			text = chunk,
		}
	end
	local res, err = embedding.Encode({
		documents = docs
	})
	assert(res, err)
	for i, v in ipairs(res.results) do
		local chk_key = "chk:" .. v.id
		local txt = chunks[i]
		local vector = v.vector
		local ok, res = db:hmset(chk_key,
			"text", txt,
			"doc_id", docId,
			"chunk_id", v.id,
			"embedding", vector
		)
		print("存储chunk成功:", chk_key, ok, res)
		assert(ok, res)
	end
	return true
end

-- 处理所有文档
local function processAllDocuments()
	-- 获取所有文档ID
	local ok, keys = db:call("KEYS", "doc:*")
	if not ok or not keys then
		print("获取文档列表失败")
		return
	end
	-- 过滤掉非文档键
	local docKeys = {}
	for _, key in ipairs(keys) do
		if key ~= "doc:id" then
			docKeys[#docKeys + 1] = key
		end
	end
	print("找到 " .. #docKeys .. " 个文档")
	-- 处理每个文档
	local successCount = 0
	for _, docId in ipairs(docKeys) do
		if processDocument(docId) then
			successCount = successCount + 1
		end
	end
	print("处理完成，成功处理 " .. successCount .. " 个文档")
end

-- 创建索引
if not create_index() then
	return
end

-- 执行处理
if true then
	processAllDocuments()
	local ok, res = db:set("chk:id", chk_id)
	assert(ok, res)
end

local test = {
}

for i, txt in ipairs(test) do
	local k = "chk:" .. i
	local res, err = embedding.Encode({
		documents = {
			{
				id = k,
				text = txt,
			}
		}
	})
	assert(res, err)
	local vector = res.results[1].vector
	local ok, res = db:call("FT.SEARCH",
		"chunks_idx",
		"*=>[KNN 1 @embedding $vector as score]",
		"PARAMS", "2",
		"vector", vector,
		"RETURN", "3",
		"chk_id", "score", "text",
		"DIALECT", "4"
	)
	assert(ok, res)
	print("A:", txt)
	for i=2, #res, 2 do
		print(res[i], res[i+1])
		for k, v in pairs(res[i+1]) do
			print(k, v)
		end
		print("--------------------------------")
	end
end
