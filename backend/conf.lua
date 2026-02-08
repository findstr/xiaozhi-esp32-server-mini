local M = {
	http_listen = ":80",
	xiaozhi_websocket = "ws://192.168.31.228/xiaozhi/v1/", -- 小智访问的地址
	exit_after_silence_seconds = 60, -- 60秒后自动退出
	history = {
		log_file = "backend/data/chat.jsonl",
		summary_file = "backend/data/summary.txt",
		archive_file = "backend/data/chat_archive.jsonl",
		silence_seconds = 60,
		recent_rounds = 500,
		session_context_max_messages = 100,
		context_max_tokens = 2000,
		flush_interval_seconds = 10,
		summary_rewrite_every = 20,
		cleanup_max_entries = 5000,
		cleanup_max_days = 30,
	},
	vad = {
		model_path = "../models/silero_vad.onnx",
	},
	asr = {
		use_name = "默认",
		profiles = {
			{
				name = "默认",
				use = "tencent",
				tencent = {
					secret_id = "----------------------------------",
					secret_key = "----------------------------------",
				}
			}
		}
	},
	tts = {
		use_name = "默认",
		profiles = {
			{
				name = "默认",
				use = "edge",
				azure = {
					region = "eastasia",
					api_key = "---------------------",
				}
			}
		}
	},
	llm = {
		use_name = "默认",
		profiles = {
			{
				name = "默认",
				chat = {
					api_url = "https://api.siliconflow.cn/v1/chat/completions",
					api_key = "Bearer ---------------------",
					model = "THUDM/glm-4-9b-chat",
				},
				think = {
					api_url = "https://api.siliconflow.cn/v1/chat/completions",
					api_key = "Bearer ---------------------",
					model = "THUDM/glm-4-9b-chat",
				},
			}
		}
	},
	location = {
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
