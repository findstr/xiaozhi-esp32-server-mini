# -*- coding: utf-8 -*-
import grpc
import torch
import opuslib_next
import numpy as np
import opus_pb2 as opus_pb2
import opus_pb2_grpc as opus_pb2_grpc

from concurrent import futures
from enum import Enum

class OpusService(opus_pb2_grpc.OpusServicer):
    def __init__(self):
        frame_duration = 60  # 60ms per frame
        self.frame_size = int(16000 * frame_duration / 1000)  # 960 samples/frame
        self.encoder = opuslib_next.Encoder(16000, 1, opuslib_next.APPLICATION_AUDIO)
        # self.test()

    def test(self):
        with open("all.pcm", "rb") as f:
            pcm_data = f.read()

        # 调用fromPCM处理完整的PCM数据（模拟最后一帧）
        opus_datas, left_data = self.fromPCM(pcm_data, is_last=True)
        print("First 5 opus frames:")
        for i, data in enumerate(opus_datas[:5]):
            hex_bytes = ' '.join(f"{b:02x}" for b in data)
            print(f"Frame {i}: len:{len(opus_datas[i])} hex: {hex_bytes}")

        print("\nLast 5 opus frames:")
        start_idx = max(0, len(opus_datas)-5)
        for i in range(start_idx, len(opus_datas)):
            hex_bytes = ' '.join(f"{b:02x}" for b in opus_datas[i])
            print(f"Frame {i}: len:{len(opus_datas[i])} hex: {hex_bytes}")


    def fromPCM(self, pcm_data, is_last):
        opus_datas = []
        left_pcm_data = pcm_data
        # 按帧处理所有音频数据（包括最后一帧可能补零）
        for i in range(0, len(pcm_data), self.frame_size * 2):  # 16bit=2bytes/sample
            # 获取当前帧的二进制数据
            chunk = pcm_data[i:i + self.frame_size * 2]
            # 如果最后一帧不足，补零
            if len(chunk) < self.frame_size * 2:
                if not is_last:
                    break
                chunk += b'\x00' * (self.frame_size * 2 - len(chunk))
            left_pcm_data = pcm_data[i + self.frame_size * 2:]
            # 转换为numpy数组处理
            np_frame = np.frombuffer(chunk, dtype=np.int16)
            # 编码Opus数据
            opus_data = self.encoder.encode(np_frame.tobytes(), self.frame_size)
            opus_datas.append(opus_data)
        return opus_datas, left_pcm_data
    def WrapPCM(self, request_iterator, context):
        """音频文件转换为Opus编码"""
        pcm_data = bytes()
        print("WrapPCM started")
        for i, request in enumerate(request_iterator):
            try:
                pcm_data += request.pcm_data
                (opus_datas, pcm_data) = self.fromPCM(pcm_data, request.is_last)
                yield opus_pb2.OpusWrapPCMRes(opus_datas=[bytes(d) for d in opus_datas])
            except Exception as e:
                print(f"error: {e.with_traceback()}")
                yield opus_pb2.OpusWrapPCMRes(error=str(e))
        print("WrapPCM finished")