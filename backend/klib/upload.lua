local json = require "core.json"
local redis = require "core.db.redis"
local blogsDir = "./backend/klib/blogs/"
local db, err= redis.new {
	addr = "127.0.0.1:6379",
	db = 0,
}

local ok, res = db:call("ping")
print("ping", ok, res)

-- 检查Redis连接
if not ok then
	print("Redis连接失败:", res)
	return
end

db:flushdb()

-- 清洗文本函数
local function cleanContent(content)
	-- 尝试解码Unicode编码的中文字符
	content = content:gsub("\\xe%x%x?\\x%x%x?\\x%x%x?", function(match)
		local bytes = {}
		for byte in match:gmatch("\\x(%x%x)") do
			table.insert(bytes, tonumber(byte, 16))
		end
		return string.char(table.unpack(bytes))
	end)

	-- 提取第一行作为标题
	local title = content:match("^(.-)\n") or "无标题"
	-- 移除第一行
	content = content:gsub("^.-\n", "", 1)

	-- 保存代码块，替换为占位符
	local codeBlocks = {}
	local codeCount = 0

	-- 处理cnblogs_code类型的代码块
	content = content:gsub('<div class="cnblogs_code">%s*```(.-)```%s*</div>', function(code)
		codeCount = codeCount + 1
		local placeholder = "___CODE_BLOCK_" .. codeCount .. "___"
		codeBlocks[placeholder] = "```\n" .. code .. "\n```"
		return placeholder
	end)

	-- 先保存pre标签中的代码块
	content = content:gsub("<pre[^>]*>(.-)</pre>", function(code)
		codeCount = codeCount + 1
		local placeholder = "___CODE_BLOCK_" .. codeCount .. "___"
		codeBlocks[placeholder] = "```\n" .. code .. "\n```"
		return placeholder
	end)

	-- 保存code标签中的内联代码
	content = content:gsub("<code[^>]*>(.-)</code>", function(code)
		codeCount = codeCount + 1
		local placeholder = "___CODE_INLINE_" .. codeCount .. "___"
		codeBlocks[placeholder] = "`" .. code .. "`"
		return placeholder
	end)

	-- 移除PHP代码块，但保留注释
	content = content:gsub("<%?php.-?%>", "<!-- PHP代码已移除 -->")

	-- 移除脚本和样式标签及其内容
	content = content:gsub("<script.-</script>", "")
	content = content:gsub("<style.-</style>", "")

	-- 移除span标签及其样式属性
	content = content:gsub('<span style="[^"]*">(.-)</span>', "%1")
	content = content:gsub('<span[^>]*>(.-)</span>', "%1")

	-- 处理HTML实体
	content = content:gsub("&nbsp;", " ")
	content = content:gsub("&lt;", "<")
	content = content:gsub("&gt;", ">")
	content = content:gsub("&amp;", "&")
	content = content:gsub("&quot;", "\"")

	-- 移除所有HTML标签，但保留内容
	content = content:gsub("<%/?[^>]+>", " ")

	-- 清理多余空白
	content = content:gsub("%s+", " ")

	-- 恢复代码块
	for placeholder, code in pairs(codeBlocks) do
		-- 转义替换字符串中的%字符
		local escapedCode = code:gsub("%%", "%%%%")
		content = content:gsub(placeholder, escapedCode)
	end

	-- 为代码块添加注释
	content = content:gsub("(```[^\n]*\n.-\n```)", function(codeBlock)
		return codeBlock .. "\n<!-- 以上是代码示例 -->"
	end)

	-- 清理连续空行
	content = content:gsub("\n\n+", "\n\n")

	-- 清理首尾空白
	content = content:gsub("^%s+", "")
	content = content:gsub("%s+$", "")

	return title, content
end

local ok, idstr = db:get("doc:id")
if not ok then
	assert(false, "获取id失败")
end
local id = 1
if idstr then
	id = tonumber(idstr) + 1
end

-- 处理单个文件
local function processFile(filePath)
	local file, err = io.open(blogsDir .. filePath, "r")
	if not file then
		print("无法打开文件:", filePath, err)
		return
	end

	local content = file:read("*all")
	file:close()
	-- 清洗内容
	local title, cleanedContent = cleanContent(content)
	-- 生成唯一ID (使用文件路径的哈希值)
	local docId = "doc:" .. id
	id = id + 1
	-- 构建JSON对象
	local jsonData = {
		title = title,
		content = cleanedContent,
		source = filePath,
		timestamp = os.time()
	}
	-- 使用Redis JSON存储
	local ok, err = db:call("JSON.SET", docId, ".", json.encode(jsonData))
	if not ok then
		print("存储文档失败:", docId, err)
	else
		print("成功存储文档:", docId, title)
	end
	print("------------")
end

-- 开始处理
local function processFileList(listFilePath)
	local file, err = io.open(listFilePath, "r")
	if not file then
		print("无法打开文件列表:", listFilePath, err)
		return
	end
	local count = 0
	for line in file:lines() do
		-- 去除可能的空白字符
		line = line:gsub("^%s*(.-)%s*$", "%1")
		print("line:", line)
		if line ~= "" then
			processFile(line)
		end
	end
	file:close()
	return count
end

db:set("doc:id", id)

processFileList(blogsDir .. "dir.txt")
print("process finish")