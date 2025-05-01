# xiaozhi-esp32-server-mini

适配[Xiaozhi](https://github.com/78/xiaozhi-esp32?tab=readme-ov-file)的AI agent服务器程序

## 目标

本服务端致力于能跑到`NAS`, `路由器`, `树莓派`等轻量级设备，因此所有大模型均调用API服务

## 现状

使用[Xiaozhi](https://github.com/78/xiaozhi-esp32)来进行对话。

没有联网能力

## 运行时内存

- 对话时大概76M
- 非对话时大概36M常驻内存

## 部署方式

- Docker部署，镜像大概80M

```
docker run -it --rm \
  -p 0.0.0.0:8880:8880 \
  -p 0.0.0.0:8881:8881 \
  -v "$(pwd)/backend/myconf.lua:/app/backend/myconf.lua" \
  ghcr.io/findstr/xiaozhi-esp32-server-mini:latest
```

## 前端(两个，分别是网页端和语音端)

- 一个Web前端用于调试`AI Agent`相关的功能和OTA接口
- [Xiaozhi](https://github.com/78/xiaozhi-esp32?tab=readme-ov-file)语音终端


## 当前使用的一些组件

- `SileroVad` 用来提前去除一些非人类声音, 降低`ASR`的开销
- `ASR` 使用了腾讯提供的服务，每个月`5000`次的免费额度足够了
- `TTS` 使用了`EdgeTTS`服务，支持流式，目前是通过标点切分来实现流式输入，`EdgeTTS`自带流式输出。
- `Embedding` 使用了`硅基流动`提供的免费API, 虽然有并发限制，在只有一个设备的情况下，并发也够了
- `大模型` 分别使用了`智谱AI`和`硅基流动`提供的免费API, 同时使用可解决并发问题
- `向量数据库` 使用了[Redis-Stack](https://redis.io/about/about-stack)提供的免费数据库，免费的32M内存目前应该也足够做记忆召回了
## 配置文件

[配置文件](./backend/conf.lua), 里面包含了所有的配置信息，包括`ASR`, `TTS`, `Embedding`, `大模型`, `向量数据库`等

## TODO

- 优化TTS延迟问题
- 接入喜马拉雅讲故事
- 基础知识库召回(主要是一些儿童读物，课本，防止大模型的幻觉让小朋友学到错误的知识)

