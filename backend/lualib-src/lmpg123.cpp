#include <cassert>
#include <string>
#include <opus/opus.h>
#include <lua.hpp>
#include <mpg123.h>
#include "silero-vad-onnx.hpp"

#include "const.h"

#define MPG_TNAME "voice.mpg123"

struct lmpg123 {
public:
	lmpg123(mpg123_handle *mpg_handle):
		mpg_handle(mpg_handle)
	{
		// 设置输出格式: 强制转换为16kHz, 单声道, 16位
		mpg123_format_none(this->mpg_handle);
		mpg123_format(this->mpg_handle, OPUS_SAMPLE_RATE, 1, MPG123_ENC_SIGNED_16);
		this->reset();
	}
	~lmpg123()
	{
		if (this->mpg_handle) {
			mpg123_close(this->mpg_handle);
			mpg123_delete(this->mpg_handle);
			this->mpg_handle = nullptr;
		}
	}
	void reset()
	{
		mpg_output.clear();
		mpg123_close(this->mpg_handle);
		mpg123_open_feed(this->mpg_handle);
	}
public:
	mpg123_handle *mpg_handle;
	std::vector<uint8_t> mpg_output;
};

static int lmpg123_gc(lua_State *L)
{
	lmpg123 *vad = (lmpg123 *)lua_touserdata(L, 1);
	vad->~lmpg123();
	return 0;
}

static int lmpg123_new(lua_State *L)
{
	int err;
	auto mpg_handle = mpg123_new(NULL, &err);
	if (mpg_handle == NULL) {
		return luaL_error(L, "无法创建mpg123句柄: %s\n", mpg123_plain_strerror(err));
	}
	void *vad = lua_newuserdata(L, sizeof(lmpg123));
	if (luaL_newmetatable(L, MPG_TNAME)) {
		lua_pushcfunction(L, lmpg123_gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	new (vad)lmpg123(mpg_handle);
	return 1;
}

static int lmpg123_reset(lua_State *L)
{
	lmpg123 *vad = (lmpg123 *)luaL_checkudata(L, 1, MPG_TNAME);
	vad->reset();
	return 0;
}

static int lmpg123_mp3topcm(lua_State *L)
{
	size_t len;
	size_t blocksize;
	lmpg123 *vad = (lmpg123 *)luaL_checkudata(L, 1, MPG_TNAME);
	const char *data = luaL_checklstring(L, 2, &len);
	mpg123_feed(vad->mpg_handle, (const unsigned char *)data, len);
	blocksize = mpg123_outblock(vad->mpg_handle);
	// 循环解码直到没有更多输出或者输出缓冲区已满
	while (1) {
		size_t bytes_decoded;
		size_t start = vad->mpg_output.size();
		vad->mpg_output.resize(start + blocksize);
		int ret = mpg123_read(vad->mpg_handle, vad->mpg_output.data() + start,
			blocksize, &bytes_decoded);
		// 处理解码结果
		if (ret == MPG123_NEED_MORE) {
			vad->mpg_output.resize(start + bytes_decoded);
			break;
		} else if (ret == MPG123_NEW_FORMAT) {
			// 获取新的格式信息
			long rate;
			int channels, encoding;
			mpg123_getformat(vad->mpg_handle, &rate, &channels, &encoding);
			vad->mpg_output.resize(start);
			// 继续解码
			continue;
		} else if (ret == MPG123_OK) {
			vad->mpg_output.resize(start + bytes_decoded);
		} else if (ret == MPG123_DONE) {
			vad->mpg_output.resize(start);
			break;
		} else {
			fprintf(stderr, "解码错误: %s\n", mpg123_strerror(vad->mpg_handle));
			break;
		}
	}
	if (vad->mpg_output.size() > 0) {
		lua_pushlstring(L, (const char *)vad->mpg_output.data(), vad->mpg_output.size());
		vad->mpg_output.clear();
	} else {
		lua_pushnil(L);
	}
	return 1;
}

extern "C" int luaopen_voice_mpg123(lua_State *L) {
	const luaL_Reg tbl[] = {
		{"new", lmpg123_new},
		{"reset", lmpg123_reset},
		{"mp3topcm", lmpg123_mp3topcm},
		{NULL, NULL}
	};
	if (mpg123_init() != MPG123_OK) {
		return luaL_error(L, "mpg123_init failed");
	}
	luaL_newlib(L, tbl);
	return 1;
}
