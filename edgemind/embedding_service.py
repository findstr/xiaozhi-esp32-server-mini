# -*- coding: utf-8 -*-
import torch
from sentence_transformers import SentenceTransformer
from FlagEmbedding import FlagReranker
from langchain_community.embeddings import HuggingFaceBgeEmbeddings
from langchain_community.vectorstores import DocArrayInMemorySearch
from langdetect import detect, LangDetectException
import embedding_pb2
import numpy as np

class EmbeddingService:
    def __init__(self):
        # 初始化模型（首次运行会自动下载）
        self.device = 'cuda' if torch.cuda.is_available() else 'cpu'
        print(f"Using device: {self.device}")
        self.cn_model = SentenceTransformer('BAAI/bge-large-zh-v1.5').to(self.device)
        print("init model success")

    def _get_language(self, text):
        if not text.strip():  # 处理空文本
            return 'zh'
        try:
            lang = detect(text)
            return 'zh' if lang in ['zh-cn', 'zh-tw'] else ('en' if lang == 'en' else 'zh')
        except LangDetectException:
            return 'zh'  # 默认中文

    def _preprocess_text(self, text, language='zh'):
        """添加指令前缀的预处理"""
        if language == 'zh':
            return f'为这个句子生成表示以用于检索相关文章：{text}'
        elif language == 'en':
            return f'Represent this sentence for searching relevant passages: {text}'
        return text
    def _generate_vectors(self, documents, batch_size=32):
        """
        批量生成文档向量
        :param documents: 列表格式，每个元素是包含文本和元数据的字典
        :param batch_size: 根据GPU显存调整（16/32/64）
        :return: 生成器，每次yield一个文档及其向量
        """
        # 预处理文本
        preprocessed_texts = [
            self._preprocess_text(doc['text'], self._get_language(doc['text']))
            for doc in documents
        ]

        # 批量生成向量
        vectors = self.cn_model.encode(
            preprocessed_texts,
            batch_size=batch_size,
            normalize_embeddings=True,
            show_progress_bar=True,
            convert_to_tensor=True  # 使用Tensor格式更高效
        )
        # 转换为numpy数组并拼接元数据
        vectors = vectors.cpu().numpy()
        return [vec.astype(np.float32).tobytes() for vec in vectors]

    def Encode(self, request, context):
        response = embedding_pb2.EncodeRes()
        # 转换文档格式
        documents = [
            {
                "id": doc.id,
                "text": doc.text,
            }
            for doc in request.documents
        ]
        print("Encode called:")
        print(documents)
        try:
            # 生成向量
            batch_size = 32
            results = self._generate_vectors(documents, batch_size)
            for vector, doc in zip(results, documents):
                print("vector", type(vector), len(vector))
                vec_result = response.results.add()
                vec_result.id = doc["id"]
                vec_result.vector = vector
        except Exception as e:
            response.error = str(e)
        return response

    def Rerank(self, request, context):
        print("Rerank called")
        response = embedding_pb2.RerankRes()
        return response

# 使用示例
if __name__ == "__main__":
    kb = EmbeddingService()
    # 示例文档（实际应从数据库/文件读取）
    sample_docs = [
        {"id": 1, "text": "青蛙是食草动物", "metadata": {"source": "生物学教材"}},
        #{"id": 2, "text": "Gemini Pro is developed by Google", "metadata": {"source": "tech_news"}}
    ]

    # 生成向量
    documents_with_vectors = kb._generate_vectors(sample_docs)
    print(documents_with_vectors)
    """
    # 搜索示例 (indent this block)
    results = kb.search_similar("动物吃什么", k=2)
    if hasattr(results, 'docs'):
        for doc in results.docs:
            print(f"相似度: {1 - float(doc.score):.2f}")
            print(f"内容: {doc.content}")
            print(f"元数据: {doc.metadata}")
            print("---")
    else:
        print("搜索结果:", results)
        print("结果类型:", type(results))
        print("结果属性:", dir(results))
    """