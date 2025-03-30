# xiaozhi-esp32-server-mini

适配[Xiaozhi](https://github.com/78/xiaozhi-esp32?tab=readme-ov-file)的AI agent服务器程序

## 目标

本服务端致力于能跑到`NAS`, `路由器`, `树莓派`等轻量级设备，因此所有大模型均调用API服务

## 现状

使用[Xiaozhi](https://github.com/78/xiaozhi-esp32?tab=readme-ov-file)来进行对话。

没有联网能力，待增加意图识别后再支持

## 前端(两个，分别是网页端和语音端)

- 一个Web前端用于调试`AI Agent`相关的功能(不需要启动[EdgeMind](./edgemind/app.py)服务)
- [Xiaozhi](https://github.com/78/xiaozhi-esp32?tab=readme-ov-file)语音终端, 用于语音对话(需要启动[EdgeMind](./edgemind/app.py)服务来配合处理语音相关)


## 当前使用的一些组件

- `SileroVad` 用来提前去除一些非人类声音, 降低`ASR`的开销（目前只能本地部署，模型本身并不大，现在的问题是推理框架占用内存过大，等优化)
- `ASR` 使用了腾讯提供的服务，每个月`5000`次的免费额度足够了
- `TTS` 使用了`AzureTTS`服务，每月`10W`字符，应该也够用了, `AzureTTS`不支持流式，目前是通过标点切分来实现流式TTS的。
- `Embedding` 使用了`硅基流动`提供的免费API, 虽然有并发限制，在只有一个设备的情况下，并发也够了
- `大模型` 分别使用了`智谱AI`和`硅基流动`提供的免费API, 同时使用可解决并发问题
- `向量数据库` 使用了[Redis-Stack](https://redis.io/about/about-stack)提供的免费数据库，免费的32M内存目前应该也足够做记忆召回了
- `EdgeMind` 使用Python实现的一个本地服务使用`gRPC`调用，用于处理语音相关的功能(主要是`VAD`和`Opus`流式打包功能)
## 配置文件

[配置文件](./backend/conf.lua), 里面包含了所有的配置信息，包括`ASR`, `TTS`, `Embedding`, `大模型`, `向量数据库`等

## TODO

- `SoleroVad` 内存占用问题
- 静音一定时间自动退出
- `VAD` 识别优化（儿童音经常识别不出)
- 自动意图识别
- 接入喜马拉雅讲故事
- 基础知识库召回(主要是一些儿童读物，课本，防止大模型的幻觉让小朋友学到错误的知识)

