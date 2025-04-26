#include <cassert>
#include <string>
#include <opus.h>
#include <lua.hpp>
#include "silero-vad-onnx.hpp"

#define VAD_TNAME "audio.vad"

#define OPUS_SAMPLE_RATE 	16000
#define OPUS_FRAME_MS 		60	// 60ms
#define OPUS_FRAME_SAMPLES	(OPUS_SAMPLE_RATE * OPUS_FRAME_MS / 1000)
#define VAD_WINDOW_MS		32
#define VAD_WINDOW_SAMPLES	(VAD_WINDOW_MS * OPUS_SAMPLE_RATE / 1000)
#define VAD_PRE_FRAMES		5
#define VAD_POST_FRAMES		1
#define VAD_PRE_SAMPLES		(VAD_PRE_FRAMES * OPUS_SAMPLE_RATE * OPUS_FRAME_MS / 1000)
#define MAX_OPUS_PACKET_SIZE 	(1275 * 3 + 7)

struct voice_conf {
	const char *model_path;
	int sample_rate;
	int windows_frame_ms;	// ms
	float threshold;
	int min_silence_duration_ms;
	int speech_pad_ms;
	int min_speech_duration_ms;
	float max_speech_duration_s;
};

struct lvoice {
public:
	lvoice(const voice_conf &config, OpusDecoder *decoder, OpusEncoder *encoder)
		: iterator(config.model_path, config.sample_rate,
			config.windows_frame_ms, config.threshold, config.min_silence_duration_ms,
			config.speech_pad_ms, config.min_speech_duration_ms, config.max_speech_duration_s)
	{
		this->max_silence_ms = config.min_silence_duration_ms;
		this->decoder = decoder;
		this->encoder = encoder;
		this->reset();
	}
	~lvoice() {
		if (this->decoder) {
			opus_decoder_destroy(this->decoder);
			this->decoder = nullptr;
		}
		if (this->encoder) {
			opus_encoder_destroy(this->encoder);
			this->encoder = nullptr;
		}
	}
	void reset() {
		has_voice = false;
		silence_ms = -1;
		iterator.reset();
		vad_input_pcm.clear();
		vad_speech_pcm.clear();
		vad_context.clear();
	}
public:
	//vad detecter
	bool has_voice;
	int silence_ms;
	int max_silence_ms;
	VadIterator iterator;
	std::vector<float> vad_input_pcm;
	std::vector<float> vad_speech_pcm;
	std::vector<float> vad_context;
	OpusDecoder *decoder;
	//opus encoder
	std::vector<uint8_t> opus_context;
	OpusEncoder *encoder;
};


static inline int opt_int(lua_State *L, int tbl, const char *key, int def)
{
	int n;
	lua_getfield(L, tbl, key);
	n = luaL_optinteger(L, -1, def);
	lua_pop(L, 1);
	return n;
}

static inline float opt_float(lua_State *L, int tbl, const char *key, float def)
{
	lua_Number f;
	lua_getfield(L, tbl, key);
	f = luaL_optnumber(L, -1, def);
	lua_pop(L, 1);
	return f;
}

static inline const char *opt_string(lua_State *L, int tbl, const char *key, const char *def)
{
	const char *s;
	lua_getfield(L, tbl, key);
	s = luaL_optstring(L, -1, def);
	lua_pop(L, 1);
	return s;
}

static int lopus_decode(lua_State *L, const unsigned char *data,
	size_t len, std::vector<float> &output)
{
	OpusDecoder *decoder;
	int error;
	int sampling_rate = OPUS_SAMPLE_RATE;  // Opus 支持的典型采样率
	int channels = 1;                      // 单声道
	// 创建解码器
	decoder = opus_decoder_create(sampling_rate, channels, &error);
	if (error != OPUS_OK) {
		return error;
	}

	// 分配输出缓冲区
	int frame_size = sampling_rate * OPUS_FRAME_MS / 1000;
	int start = output.size();
	output.resize(start + frame_size);
	int samples = opus_decode_float(decoder, data, len, output.data() + start, frame_size, 0);
	if (samples < 0) {
		return samples;
	}
	assert(samples == frame_size);
	opus_decoder_destroy(decoder);
	return samples;
}


static int lvoice_gc(lua_State *L)
{
	lvoice *vad = (lvoice *)lua_touserdata(L, 1);
	vad->~lvoice();
	return 0;
}

static int lvoice_config(lua_State *L, int stk, voice_conf &config)
{
	config.model_path = opt_string(L, stk, "model_path", "model/silero_vad.onnx");
	config.sample_rate = opt_int(L, stk, "sample_rate", 16000);
	config.windows_frame_ms = VAD_WINDOW_MS;
	config.threshold = opt_float(L, stk, "threshold", 0.5);
	config.min_silence_duration_ms = opt_int(L, stk, "min_silence_duration_ms", 100);
	config.speech_pad_ms = opt_int(L, stk, "speech_pad_ms", 30);
	config.min_speech_duration_ms = opt_int(L, stk, "min_speech_duration_ms", 250);
	config.max_speech_duration_s = opt_float(L, stk, "max_speech_duration_s", std::numeric_limits<float>::infinity());
	return 0;
}

static int lvoice_new(lua_State *L)
{
	int error;
	int sampling_rate = OPUS_SAMPLE_RATE;  // Opus 支持的典型采样率
	int channels = 1;                      // 单声道
	OpusDecoder *decoder;
	OpusEncoder *encoder;
	voice_conf config;
	lvoice_config(L, 1, config);
	// 创建解码器
	decoder = opus_decoder_create(sampling_rate, channels, &error);
	if (error != OPUS_OK) {
		return luaL_error(L, "opus_decoder_create failed: %s", opus_strerror(error));
	}
	encoder = opus_encoder_create(sampling_rate, channels, OPUS_APPLICATION_VOIP, &error);
	if (error != OPUS_OK) {
		opus_decoder_destroy(decoder);
		return luaL_error(L, "opus_encoder_create failed: %s", opus_strerror(error));
	}
	void *vad = lua_newuserdata(L, sizeof(lvoice));
	if (luaL_newmetatable(L, VAD_TNAME)) {
		lua_pushcfunction(L, lvoice_gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	new (vad)lvoice(config, decoder, encoder);
	return 1;
}

static int lvoice_reset(lua_State *L)
{
	lvoice *vad = (lvoice *)luaL_checkudata(L, 1, VAD_TNAME);
	vad->reset();
	return 0;
}

static int lvoice_detect_opus(lua_State *L)
{
	size_t len;
	int keep_samples = VAD_PRE_SAMPLES + OPUS_FRAME_SAMPLES;
	lvoice *vad = (lvoice *)luaL_checkudata(L, 1, VAD_TNAME);
	const char *data = luaL_checklstring(L, 2, &len); // 16-bit PCM data
	int error = lopus_decode(L, (const unsigned char *)data, len, vad->vad_input_pcm);
	if (error < 0) {
		luaL_error(L, "opus_decode failed: %d", opus_strerror(error));
	}
	while (vad->vad_input_pcm.size() > VAD_WINDOW_SAMPLES) {
		bool has_voice = false;
		std::vector<float> chunk(vad->vad_input_pcm.begin(), vad->vad_input_pcm.begin() + VAD_WINDOW_SAMPLES);
		vad->vad_input_pcm.erase(vad->vad_input_pcm.begin(), vad->vad_input_pcm.begin() + VAD_WINDOW_SAMPLES);
		if (!vad->has_voice) {
			vad->vad_context.insert(vad->vad_context.end(), chunk.begin(), chunk.end());
			if (vad->vad_context.size() > keep_samples) { // 如果缓冲区大于keep_samples，则删除前面多余的samples
				int erase_samples = vad->vad_context.size() - keep_samples;
				vad->vad_context.erase(vad->vad_context.begin(), vad->vad_context.begin() + erase_samples);
			}
		}
		has_voice = vad->iterator.predict(chunk);
		if (!vad->has_voice && has_voice) { // 语音的开始
			vad->silence_ms = -1;
			vad->has_voice = true;
			vad->vad_speech_pcm.insert(vad->vad_speech_pcm.end(),
				vad->vad_context.begin(), vad->vad_context.end());
			vad->vad_context.clear();
			vad->silence_ms = 0;
		} else if (vad->has_voice) {
			if (!has_voice) { // 语音的结束
				vad->silence_ms += VAD_WINDOW_MS;
			}
			vad->vad_speech_pcm.insert(vad->vad_speech_pcm.end(),
				chunk.begin(), chunk.end());
			if (vad->silence_ms > vad->max_silence_ms) {
				break;
			}
		}
	}
	if (vad->silence_ms >= vad->max_silence_ms) {
		std::vector<uint8_t> output_wav;
		auto silence_samples = (vad->silence_ms / OPUS_FRAME_MS) - VAD_POST_FRAMES;
		if (silence_samples > 0) {
			vad->vad_speech_pcm.erase(vad->vad_speech_pcm.end() - silence_samples * OPUS_FRAME_SAMPLES,
				vad->vad_speech_pcm.end());
		}
		output_wav.reserve(vad->vad_speech_pcm.size() * sizeof(uint16_t));
		for (auto &sample : vad->vad_speech_pcm) {
			uint16_t value = static_cast<uint16_t>(sample * 32767);
			output_wav.push_back(static_cast<uint8_t>(value & 0xff));
			output_wav.push_back(static_cast<uint8_t>(value >> 8));
		}
		vad->has_voice = false;
		vad->vad_context.clear();
		vad->vad_input_pcm.clear();
		vad->vad_speech_pcm.clear();
		lua_pushlstring(L, (const char *)output_wav.data(), output_wav.size());
	} else {
		lua_pushnil(L);
	}
	return 1;
}

static int lvoice_wrap_opus(lua_State *L)
{
	int is_last;
	size_t len;
	const size_t frame_bytes = OPUS_FRAME_SAMPLES * sizeof(int16_t); // 每帧字节数
	lvoice *vad = (lvoice *)luaL_checkudata(L, 1, VAD_TNAME);
	const char *data = luaL_checklstring(L, 2, &len);
	// 检查输入数据有效性
	if (len == 0 || len % 2 != 0) {
		return luaL_error(L, "invalid data length (must be even)");
	}
	is_last = lua_toboolean(L, 3);
	// 追加新数据到缓冲区
	vad->opus_context.insert(vad->opus_context.end(),
		(const unsigned char *)data,
		(const unsigned char *)data + len);
	// 修正补零逻辑：基于字节对齐
	if (is_last) {
		const size_t current_bytes = vad->opus_context.size();
		const size_t padding_bytes = (frame_bytes - (current_bytes % frame_bytes)) % frame_bytes;
		if (padding_bytes > 0) {
			vad->opus_context.insert(vad->opus_context.end(), padding_bytes, 0);
		}
	}
	// 计算可用帧数
	const int frame_count = vad->opus_context.size() / frame_bytes;
	if (frame_count == 0) {
		lua_pushnil(L);
	} else {
		unsigned char output[MAX_OPUS_PACKET_SIZE]; // 确保足够大
		lua_createtable(L, frame_count, 0); // 预分配数组空间
		unsigned char *current_ptr = vad->opus_context.data();
		for (int i = 0; i < frame_count; ++i) {
			// 编码当前帧
			int bytes = opus_encode(
				vad->encoder,
				reinterpret_cast<const int16_t*>(current_ptr),
				OPUS_FRAME_SAMPLES,
				output,
				sizeof(output)
			);
			// 错误处理
			if (bytes < 0) {
				return luaL_error(L, "opus_encode failed: %s", opus_strerror(bytes));
			}
			// 将编码结果存入Lua表
			lua_pushlstring(L, reinterpret_cast<const char*>(output), bytes);
			lua_rawseti(L, -2, i + 1); // 使用-2因为表格在栈顶
			// 移动指针到下一帧
			current_ptr += frame_bytes;
		}
		// 安全擦除已处理数据
		const size_t processed_bytes = frame_count * frame_bytes;
		if (processed_bytes <= vad->opus_context.size()) {
			vad->opus_context.erase(
				vad->opus_context.begin(),
				vad->opus_context.begin() + processed_bytes
			);
		} else {
			vad->opus_context.clear();
		}
	}
	return 1;
}


extern "C" int luaopen_voice(lua_State *L) {
	const luaL_Reg tbl[] = {
		{"new", lvoice_new},
		{"reset", lvoice_reset},
		{"detect_opus", lvoice_detect_opus},
		{"wrap_opus", lvoice_wrap_opus},
		{NULL, NULL}
	};
	luaL_newlib(L, tbl);
	return 1;
}
