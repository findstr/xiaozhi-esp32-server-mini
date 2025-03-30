local http = require "core.http"
local json = require "core.json"
local time = require "core.time"
local hash = require "core.crypto.hash"
local hmac = require "core.crypto.hmac"
local base64 = require "core.base64"

local conf = require "conf"

local secretId = conf.asr.tencent.secret_id
local secretKey = conf.asr.tencent.secret_key

local host = "asr.tencentcloudapi.com"
local url = string.format("%s%s", "https://", host)
local algorithm = "TC3-HMAC-SHA256"
local service = "asr"
local version = "2019-06-14"
local action = "SentenceRecognition"
local region = ""

local function tohex(s)
	local buf = {}
	for i = 1, #s do
		buf[i] = string.format("%02x", s:byte(i))
	end
	return table.concat(buf)
end

---@return string?, string? error
local function asr(dat)
	local data_len = #dat
	local data = base64.encode(dat)

	 -- ************* 步骤 1：拼接规范请求串 *************
	local timestamp = time.nowsec()
	local httpRequestMethod = "POST"
	local canonicalURI = "/"
	local canonicalQueryString = ""
	local canonicalHeaders = string.format("content-type:%s\nhost:%s\nx-tc-action:%s\n",
		"application/json; charset=utf-8", host, string.lower(action))
	local signedHeaders = "content-type;host;x-tc-action"
	local payload = json.encode({
	    EngSerViceType = "16k_zh",
	    SourceType = 1,
	    VoiceFormat = "pcm",
	    Data = data,
	    DataLen = data_len,
	})
	local hashedRequestPayload = tohex(hash.hash("sha256", payload))
	local canonicalRequest = string.format("%s\n%s\n%s\n%s\n%s\n%s",
		httpRequestMethod,
		canonicalURI,
		canonicalQueryString,
		canonicalHeaders,
		signedHeaders,
		hashedRequestPayload)
	--print(string.format("canonicalRequest:\n%s\n---", canonicalRequest))
	 -- ************* 步骤 2：拼接待签名字符串 *************
	local date = os.date("!%Y-%m-%d", timestamp)
	local credentialScope = string.format("%s/%s/tc3_request", date, service)
	local hashedCanonicalRequest = tohex(hash.hash("sha256", canonicalRequest))
	--print(string.format("hashedCanonicalRequest:\n%s\n---", hashedCanonicalRequest))
	local string2sign = string.format("%s\n%d\n%s\n%s",
		algorithm,
		timestamp,
		credentialScope,
		hashedCanonicalRequest)
	--print(algorithm)
	--print(timestamp)
	--print(credentialScope)
	--print(hashedCanonicalRequest)
	-- ************* 步骤 3：计算签名 *************
	local secretDate = hmac.digest("TC3" .. secretKey, date, "sha256")
	local secretService = hmac.digest(secretDate, service, "sha256")
	local secretSigning = hmac.digest(secretService, "tc3_request", "sha256")
	local signature = hmac.digest(secretSigning, string2sign, "sha256")
	signature = tohex(signature)
	-- ************* 步骤 4：拼接 Authorization *************
	local authorization = string.format("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		algorithm,
		secretId,
		credentialScope,
		signedHeaders,
		signature)
	--print(string.format("authorization:\n%s\n---", authorization))

	-- ************* 步骤 5：构造并发起请求 *************
	local headers = {
	    ["Authorization"] = authorization,
	    ["Content-Type"] = "application/json; charset=utf-8",
	    ["Host"] = host,
	    ["X-TC-Action"] = action,
	    ["X-TC-Timestamp"] = timestamp,
	    ["X-TC-Version"] = version,
	    ["X-TC-Region"] = region
	}

	local resp, err = http.POST(url, headers, payload)
	if not resp then
		return nil, err
	end
	print("asr", resp.body)
	local obj = json.decode(resp.body)
	if not obj then
		return nil, "decode error"
	end
	return obj.Response.Result, nil
end

return asr
