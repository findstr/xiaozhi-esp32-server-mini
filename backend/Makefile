.PHONY: all deps

ONNXRUNTIME = ./deps/onnxruntime-linux
INCLUDE = -I$(ONNXRUNTIME)/include $(MYCFLAGS)
LIB_PATH = -L$(ONNXRUNTIME)/lib

CFLAGS = -g3 -std=c++20 -fPIC $(LIB_PATH)
LDFLAGS = -l:libonnxruntime.so.1 -Wl,-rpath,\$$ORIGIN -lopus -lmpg123


all: ../luaclib/voice.so

../luaclib/voice.so: lualib-src/lvoice.cpp lualib-src/lmpg123.cpp deps |../luaclib
	g++ $(CFLAGS) lualib-src/lvoice.cpp lualib-src/lmpg123.cpp $(STATIC_LIB) -o $@ $(INCLUDE) $(LDFLAGS) -shared
	cp $(ONNXRUNTIME)/lib/libonnxruntime.so.1 ../luaclib/

../luaclib:
	mkdir -p ../luaclib

deps:
	cd ./deps && chmod u+x ./init.sh && ./init.sh

clean:
	rm -f luaclib/voice.so
