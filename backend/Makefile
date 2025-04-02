.PHONY: all

ONNXRUNTIME = ./deps/onnxruntime-linux-x64
OPUS = ./deps/opus
INCLUDE = -I$(ONNXRUNTIME)/include -I$(OPUS)/include -I/home/zhoupy/silly/deps/lua/
LIB_PATH = -L$(ONNXRUNTIME)/lib -L$(OPUS)/.libs

CFLAGS = -g3 -std=c++20 -fPIC $(LIB_PATH)
LDFLAGS = -l:libonnxruntime.so.1 -l:libopus.so.0 -Wl,-rpath,\$$ORIGIN

all: luaclib/voice.so

luaclib/voice.so: lualib-src/lvoice.cpp deps
	g++ $(CFLAGS) lualib-src/lvoice.cpp $(STATIC_LIB) -o $@ $(INCLUDE) $(LDFLAGS) -shared
	cp $(ONNXRUNTIME)/lib/libonnxruntime.so.1 luaclib/
	cp $(OPUS)/.libs/libopus.so.0 luaclib/

deps:
	cd ./deps && ./init.sh

clean:
	rm -f luaclib/voice.so