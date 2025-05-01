local M = {
	http_listen = "0.0.0.0:8881",				-- WEB前端访问的地址
	xiaozhi_listen = "0.0.0.0:8880",			-- 小智监听的地址
	xiaozhi_websocket = os.getenv("XIAOZHI_WEBSOCKET"),	-- 小智访问的地址
	exit_after_silence_seconds = 30, 			-- 60秒后自动退出
	vad = {
		model_path = "../models/silero_vad.onnx",
	},
	asr = {
		use = "tencent",
		tencent = {
			secret_id = "----------------------------------",	-- 腾讯ASR的ID
			secret_key = "----------------------------------",	-- 腾讯ASR的KEY
		}
	},
	tts = {
		use = "edge",
		azure = {
			region = "eastasia",					-- 语音合成的区域(这里是东亚, 可以切换到其他区域)
			api_key = "---------------------",			-- API密钥
		}
	},
	-- 嵌入模型
	embedding = {
		use = "openai", -- 这里填openai, 默认不开启本地嵌入模型，因为本地嵌入模型需要大量的内存
		openai = {
			api_url = "https://api.siliconflow.cn/v1/embeddings",
			api_key = "Bearer --------------------------------",	-- API密钥
			cn_model = "BAAI/bge-m3",
			en_model = "BAAI/bge-large-en-v1.5",
		},
	},

	-- 大模型
	llm = { -- 只支持兼容openai的API
		intent = {
			api_url = "https://api.siliconflow.cn/v1/chat/completions",
			api_key = "Bearer ---------------------",
			model = "Qwen/Qwen2.5-7B-Instruct", -- 聊天模型，主要用来对话，可以适当降低精度，以提高响应速度
		},
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
	location = {	--定位服务
		use = "tencent",
		tencent = {
			key = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF",
			secret_key = "abcdefghijklmnopqrstuvwxyz",
		},
		custom = {
			lng = "121.54",
			lat = "31.22",
			city = "上海市浦东新区",
		},
	},
}

return M
