docker run --platform linux/arm64 --rm -v $(pwd):/src -u $(id -u):$(id -g) emscripten/emsdk:2.0.10 emcmake python3 ./platforms/js/build_js.py wasm5 --build_wasm --disable_single_file
