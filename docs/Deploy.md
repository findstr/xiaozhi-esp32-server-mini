# Docker部署方式

docker镜像已支持x86架构, 如果有需要支持arm64架构的需求, 请联系我

## 1. 安装docker

如果您的电脑还没安装docker，可以按照这里的教程安装：[docker安装](https://www.runoob.com/docker/ubuntu-docker-install.html)

## 2. 镜像(这里有阿里云和github的镜像可选)

```bash
# 阿里云
docker pull registry.cn-hangzhou.aliyuncs.com/findstr/xiaozhi-esp32-server-mini:latest

```bash
# github
docker pull ghcr.io/findstr/xiaozhi-esp32-server-mini:latest
```

## 3. 配置文件

配置文件一共用到了3个服务商：

- [腾讯云ASR(必须)](https://cloud.tencent.com/document/product/1093/35646)
- [硅基流动(必须, 用于聊天和记忆召回, 当然也可以接别的大模型, 但是硅基流动免费)](https://cloud.siliconflow.cn/i/3aTGUGKn)
- [Redis-Stack(可选, 用于记忆召回)](https://redis.io/try-free/)
- [腾讯云定位(可选, 可以根据IP来定位经纬度坐标，目前给天气预报用)](https://lbs.qq.com/service/webService/webServiceGuide/position/webServiceIp)
- [和风天气(可选, 用于天气预报)](https://www.qweather.com/)

新建一个文件`myconf.lua`, 放在任意路径下, 比如`D:/myconf.lua`，并将下面的内容复制到文件中, 填入相应的key

```lua
local M = {
	asr = {
		use = "tencent",
		tencent = {	-- 腾讯云ASR
			secret_id = "----------------------------------",	-- 腾讯ASR的ID
			secret_key = "----------------------------------",	-- 腾讯ASR的KEY
		}
	},
	embedding = { -- 嵌入模型
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
			model = "Qwen/Qwen2-7B-Instruct", --意图识别
		},
		chat = {
			api_url = "https://api.siliconflow.cn/v1/chat/completions",
			api_key = "Bearer ---------------------",	-- API密钥
			model = "deepseek-ai/DeepSeek-V3", -- 聊天模型，主要用来对话
		},
		think = {
			api_url = "https://api.siliconflow.cn/v1/chat/completions",
			api_key = "Bearer ---------------------",	-- API密钥
			model = "THUDM/GLM-Z1-9B-0414", -- 思考模型，用来做记忆总结
		},
	},
	vector_db = { -- 向量数据库
		redis = {	-- 目前使用Redis-Stack的线上版，后续考虑在Docker中集成
			addr = "127.0.0.1",
			port = "16305",
			auth = "123456",
		},
	},
	location = {	--定位服务
		use = "custom",	-- 更推荐使用custom, 因为手动定位非常准， 这对于24小时格点天气效果更好
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
```

## 4. 启动docker

```bash
docker run -it --rm -p 0.0.0.0:8880:8880 -p 0.0.0.0:8881:8881 -e XIAOZHI_WEBSOCKET=your_ip:8880  -v "D:/myconf.lua:/app/backend/myconf.lua" registry.cn-hangzhou.aliyuncs.com/findstr/xiaozhi-esp32-server-mini:latest
```

- `http://your_ip:8881/ota` 是OTA接口, 他会返回`XIAOZHI_WEBSOCKET`定义的websocket地址
- `ws://your_ip:8880` 是websocket地址, 用于小智通过websocket连接

ps. 启动之后可以使用手机访问`http://your_ip:8881/ota`来判断链接是否正常开启，如果无法连通(多出现于Windows)，可考虑防火墙原因，可以临时使用`Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False`来关掉防火墙来确认，如果确认是防火墙问题，可以增加`8881`和`8880`通行规则。

ps. `your_ip`需要自己手动查看本机ip, Windows下可使用`ipconfig`来查看。
