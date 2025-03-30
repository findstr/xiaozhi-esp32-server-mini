# -*- coding: utf-8 -*-
import grpc
import embedding_pb2_grpc
import vad_pb2_grpc
import opus_pb2_grpc
from concurrent import futures
from embedding_service import EmbeddingService
from vad_service import SileroVadService
from opus_service import OpusService

def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    """暂时禁用embedding服务
    embedding_pb2_grpc.add_EmbeddingServicer_to_server(
        EmbeddingService(), server
    )
    """
    vad_pb2_grpc.add_SileroVadServicer_to_server(
        SileroVadService(), server
    )
    opus_pb2_grpc.add_OpusServicer_to_server(
        OpusService(), server
    )
    server.add_insecure_port('[::]:50051')
    server.start()
    print("gRPC 服务已启动，监听端口 50051")
    server.wait_for_termination()

if __name__ == '__main__':
    serve()