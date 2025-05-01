FROM ghcr.io/findstr/silly:slim AS builder

# 安装构建依赖
RUN apt-get update && apt-get install -y build-essential wget libopus-dev libmpg123-dev && rm -rf /var/lib/apt/lists/*

# 复制代码
WORKDIR /app
COPY backend/ ./backend
COPY models/ ./models
COPY audio/ ./audio

# 如果 Makefile 存在构建逻辑，可以启用这行：
WORKDIR /app/backend
RUN ls deps
RUN make MYCFLAGS=-I/opt/include/lua

# 第二阶段：运行环境
FROM ghcr.io/findstr/silly:slim

# 安装依赖
RUN apt-get update && apt-get install -y libopus-dev libmpg123-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# 拷贝运行文件（Lua 脚本和编译库）
COPY --from=builder /app .

WORKDIR /app/backend

# 设置默认启动文件（可修改）
CMD ["main.lua", "--lualib_cpath=../luaclib/?.so"]
