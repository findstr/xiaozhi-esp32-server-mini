#!/bin/bash
# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(realpath "$(dirname "$0")")
if [ "$PWD" != "$SCRIPT_DIR" ]; then
    cd "$SCRIPT_DIR"
fi

# ONNX Runtime 版本
ONNXRUNTIME_VERSION=1.20.1

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ONNX_ARCH="x64"
        ;;
    aarch64|arm64)
        ONNX_ARCH="aarch64"
        ;;
    *)
        echo "不支持的架构: $ARCH"
        exit 1
        ;;
esac

# 设置下载目录名和文件名
ONNX_DIR="onnxruntime-linux"
ONNX_TARBALL="onnxruntime-linux-${ONNX_ARCH}-${ONNXRUNTIME_VERSION}.tgz"
ONNX_DOWNLOAD_URL="https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/${ONNX_TARBALL}"

# 检查是否已经下载
if [ ! -d "${ONNX_DIR}" ]; then
    echo "开始下载: ${ONNX_TARBALL}"

    # 检查 wget 命令是否存在
    if ! command -v wget &> /dev/null; then
        echo "错误: wget 命令未找到，请安装 wget"
        exit 1
    fi

    # 下载 ONNX Runtime
    if ! wget -q --show-progress "${ONNX_DOWNLOAD_URL}"; then
        echo "下载失败: ${ONNX_DOWNLOAD_URL}"
        exit 1
    fi

    # 解压文件
    if ! tar -xzf "${ONNX_TARBALL}"; then
        echo "解压失败: ${ONNX_TARBALL}"
        exit 1
    fi

    # 移除压缩包
    rm "${ONNX_TARBALL}"

    # 重命名解压后的目录
    mv "onnxruntime-linux-${ONNX_ARCH}-${ONNXRUNTIME_VERSION}" "${ONNX_DIR}"

    echo "下载完成: ${ONNX_TARBALL}"
else
    echo "ONNX Runtime 已存在: ${ONNX_DIR}"
fi

echo "使用 ONNX Runtime: ${ONNX_DIR}"
