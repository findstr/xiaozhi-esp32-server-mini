# -*- coding: utf-8 -*-
import grpc
import torch
import opuslib_next
import numpy as np
import vad_pb2 as pb2
import vad_pb2_grpc as pb2_grpc

from concurrent import futures
from enum import Enum

class VadStatus(Enum):
    IDLE        = "idle"        # 空闲
    SPEAKING    = "speaking"    # 正在说话
    END         = "end"         # 声音结束（返回完整音频数据）
    ERROR       = "error"       # 错误状态

class VadCtx:
    def __init__(self, model, get_speech_timestamps):
        self.model = model
        self.get_speech_timestamps = get_speech_timestamps
        # 初始化状态变量
        self.frame_index = 0
        self.frame_buffer = []
        self.full_samples = np.array([], dtype=np.int16)
        self.speech_samples = np.array([], dtype=np.int16)
        self.is_speaking = False
        self.speaking_frame_count = 0
        self.silence_frame_count = 0

        # VAD参数
        self.frame_seconds = 0.060          # 每帧60ms
        self.sampling_rate = 16000          # 采样率
        self.vad_threshold = 0.5            # 降低阈值提高敏感度（默认0.5）
        self.min_speech_duration_ms = 50    # 较短以捕获短音素
        self.min_silence_duration_ms = 200  # 允许短暂停顿

        # 帧参数计算
        max_silence_duration = 0.5         # 最大切片时长（秒）
        self.pre_roll = 0.3                # 语音前保留静音（秒）
        self.post_roll = 0.3               # 语音后保留静音（秒）
        self.max_buffer_duration = 10.0    # 最大缓冲时长（秒）
        self.max_buffer_size = int(self.max_buffer_duration * self.sampling_rate)
        self.frame_samples = int(self.sampling_rate * self.frame_seconds)
        self.pre_size = int(self.sampling_rate * self.pre_roll)
        self.post_size = int(self.sampling_rate * self.post_roll)
        self.max_silence_frame_count = int(max_silence_duration / self.frame_seconds) # 最大静默时长（帧）, 超出认为语音结束

        self.decoder = opuslib_next.Decoder(self.sampling_rate, 1)

    def Feed(self, frame):
        try:
            self.frame_index += 1
            # 解码OPUS音频帧
            pcm_data = np.frombuffer(self.decoder.decode(frame, frame_size= self.frame_samples), dtype=np.int16)
            self.full_samples = np.append(self.full_samples, pcm_data)
            self.frame_buffer.append(pcm_data)
            if len(self.frame_buffer) < 4: # 如果音频数据小于4帧 240ms，则不进行VAD分析
                return VadStatus.IDLE
            # 限制缓冲区大小
            if len(self.full_samples) > self.max_buffer_size:
                trim_samples = len(self.full_samples) - self.max_buffer_size
                self.full_samples = self.full_samples[trim_samples:]
            # 更新处理缓冲区
            self.frame_buffer = self.frame_buffer[-4:]
            # 有足够数据进行VAD分析
            audio_chunk = np.concatenate(self.frame_buffer)
            # 使用优化后的VAD参数检测语音
            speech_timestamps = self.get_speech_timestamps(
                torch.tensor(audio_chunk),
                self.model,
                sampling_rate=self.sampling_rate,
                threshold=self.vad_threshold,
                min_speech_duration_ms=self.min_speech_duration_ms,
                min_silence_duration_ms=self.min_silence_duration_ms
            )
            if speech_timestamps:
                self.silence_frame_count = 0
                self.speaking_frame_count += 1
            else:
                self.silence_frame_count += 1
            if not self.is_speaking:
                if not speech_timestamps:
                    return VadStatus.IDLE
                self.is_speaking = True
                self.speaking_frame_count = 1  # 初始化为1而不是0，因为已检测到语音
                pre_buffer_size = min(len(self.full_samples), self.pre_size + len(pcm_data))
                self.speech_samples = np.append(self.speech_samples, self.full_samples[-pre_buffer_size:])
                return VadStatus.SPEAKING
            else:
                self.speech_samples = np.append(self.speech_samples, pcm_data)

            if self.is_speaking and self.silence_frame_count >= self.max_silence_frame_count:
                # 确保至少有足够的语音帧才返回END
                if self.speaking_frame_count < 5:
                    self.is_speaking = False
                    self.speaking_frame_count = 0
                    self.silence_frame_count = 0
                    self.speech_samples = np.array([], dtype=np.int16)
                    return VadStatus.IDLE

                # 检查语音样本是否为空或几乎为空
                if len(self.speech_samples) <= self.post_size:
                    self.is_speaking = False
                    self.speaking_frame_count = 0
                    self.silence_frame_count = 0
                    self.speech_samples = np.array([], dtype=np.int16)
                    return VadStatus.IDLE

                # 计算应保留的样本数量
                trim_samples = self.silence_frame_count * self.frame_samples
                if trim_samples > self.post_size:
                    trim_samples = trim_samples - self.post_size
                    # 确保不会过度裁剪
                    if trim_samples < len(self.speech_samples):
                        self.speech_samples = self.speech_samples[:-trim_samples]

                # 检查最终的语音样本
                if np.max(np.abs(self.speech_samples)) < 100:  # 如果语音样本几乎是静音
                    self.is_speaking = False
                    self.speaking_frame_count = 0
                    self.silence_frame_count = 0
                    self.speech_samples = np.array([], dtype=np.int16)
                    return VadStatus.IDLE

                print(f"end frame_index: {self.frame_index}, samples: {len(self.speech_samples)}")
                return VadStatus.END
        except Exception as e:
            print(f"Error: {str(e)}")
            return VadStatus.ERROR

class SileroVadService(pb2_grpc.SileroVadServicer):
    def __init__(self):
        # 加载模型
        self.model, utils = torch.hub.load(
            repo_or_dir='snakers4/silero-vad',
            model='silero_vad',
            force_reload=False,
            trust_repo=True
        )
        self.get_speech_timestamps = utils[0]
        #self.test()
    def test(self):
        frames = self.read_audio_file("audio.bin")
        print(f"frames: {len(frames)}")
        vadCtx = VadCtx(self.model, self.get_speech_timestamps)
        for frame in frames:
            print(f"frame: {len(frame)}")
            status = vadCtx.Feed(frame)
            if status == VadStatus.END:
                break
        print(f"end {len(vadCtx.speech_samples)}")
        with open(f"speech_filter.pcm", 'wb') as file:
            file.write(bytes(vadCtx.speech_samples))

    def read_audio_file(self, file_path):
        try:
            with open(file_path, 'rb') as f:
                audio_data = f.read()

            # Parse using the Audio proto message
            audio_proto = pb2.Audio()
            audio_proto.ParseFromString(audio_data)

            # Return the frames
            return audio_proto.frames

        except FileNotFoundError:
            print(f"Error: Could not find audio file at {file_path}")
            return None
        except Exception as e:
            print(f"Error parsing audio file: {str(e)}")
            return None
    def Feed(self, request_iterator, context):
        vadCtx = VadCtx(self.model, self.get_speech_timestamps)
        # 循环处理每个请求
        for i, request in enumerate(request_iterator):
            try:
                status = vadCtx.Feed(request.opus_audio_frame)
                if status == VadStatus.END:
                    with open(f"vad_filter.pcm", 'wb') as file:
                        file.write(bytes(vadCtx.speech_samples))
                    yield pb2.SileroVadFeedRes(
                        is_finished=True,
                        audio=bytes(vadCtx.speech_samples)
                    )
                else:
                    yield pb2.SileroVadFeedRes(
                        is_finished=False
                    )
            except Exception as e:
                context.abort(grpc.StatusCode.INTERNAL, f"处理音频帧失败: {str(e)}")
        print("Feed end")

