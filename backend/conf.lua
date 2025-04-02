local M = {
	http_listen = "127.0.0.1:8081",			-- WEB前端访问的地址
	xiaozhi_listen = "127.0.0.1:8080",		-- 小智访问的地址

	vad = {
		grpc_addr = "127.0.0.1:50051",		-- VAD模型的访问地址
	},
	opus = {
		grpc_addr = "127.0.0.1:50051",		-- OPUS一个简单的流式FPM->OPUS的转换器
	},
	asr = {
		use = "tencent",
		tencent = {
			secret_id = "----------------------------------",	-- 腾讯ASR的ID
			secret_key = "----------------------------------",	-- 腾讯ASR的KEY
		}
	},

	tts = {
		use = "azure",
		azure = {
			region = "eastasia",					-- 语音合成的区域(这里是东亚, 可以切换到其他区域)
			api_key = "---------------------",			-- API密钥
		}
	},

	-- 嵌入模型
	embedding = {
		use = "openai", -- 这里填openai, 默认不开启本地嵌入模型，因为本地嵌入模型需要大量的内存
		native = {
			grpc_addr = "127.0.0.1:50051",
		},
		openai = {
			api_url = "https://api.siliconflow.cn/v1/embeddings",
			api_key = "Bearer --------------------------------",	-- API密钥
			cn_model = "BAAI/bge-large-zh-v1.5",
			en_model = "BAAI/bge-large-en-v1.5",
		},
	},

	-- 大模型
	llm = { -- 只支持兼容openai的API
		chat = {
			api_url = "https://api.siliconflow.cn/v1/chat/completions",
			api_key = "Bearer ---------------------",	-- API密钥
			model = "THUDM/glm-4-9b-chat", -- 聊天模型，主要用来对话，可以适当降低精度，以提高响应速度
		},
		think = {
			api_url = "https://api.siliconflow.cn/v1/chat/completions",
			api_key = "Bearer ---------------------",	-- API密钥
			model = "THUDM/glm-4-9b-chat", -- 思考模型，主要用来对话，可以适当降低精度，以提高响应速度(用来做记忆总结)
		},
	},
	-- 向量数据库
	vector_db = { -- 向量数据库
		use = "redis", -- 目前只支持redis
		redis = {
			addr = "127.0.0.1",
			port = "16305",
			auth = "123456",
		},
	},
	-- 提供的工具
	tools = {
		"weather",
	},
}

return M
