#!/bin/bash

python -m grpc_tools.protoc \
    --python_out=./edgemind \
    --grpc_python_out=./edgemind \
    --proto_path=proto \
    proto/embedding.proto

python -m grpc_tools.protoc \
    --python_out=./edgemind \
    --grpc_python_out=./edgemind \
    --proto_path=proto \
    proto/vad.proto

python -m grpc_tools.protoc \
    --python_out=./edgemind \
    --grpc_python_out=./edgemind \
    --proto_path=proto \
    proto/opus.proto
