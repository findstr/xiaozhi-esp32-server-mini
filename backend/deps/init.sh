#!/bin/bash

SCRIPT_DIR=$(realpath "$(dirname "$0")")
if [ "$PWD" != "$SCRIPT_DIR" ]; then
    cd "$SCRIPT_DIR"
fi

ONNXRUNTIME_VERSION=1.21.0
if [ ! -d "onnxruntime-linux-x64" ]; then
	echo "Download start onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz"
	wget https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_VERSION}/onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz
	tar -xzf onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz
	rm onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz
	mv onnxruntime-linux-x64-${ONNXRUNTIME_VERSION} onnxruntime-linux-x64
	echo "Download finish onnxruntime-linux-x64-${ONNXRUNTIME_VERSION}.tgz"
fi

OPUS_VERSION=1.5.2
if [ ! -d "opus" ]; then
	echo "Download start opus-${OPUS_VERSION}.tar.gz"
	wget https://ftp.osuosl.org/pub/xiph/releases/opus/opus-${OPUS_VERSION}.tar.gz
	tar -xzf opus-${OPUS_VERSION}.tar.gz
	rm opus-${OPUS_VERSION}.tar.gz
	mv opus-${OPUS_VERSION} opus
	cd opus
	./configure
	make
	echo "Download finish opus-${OPUS_VERSION}.tar.gz"
fi
