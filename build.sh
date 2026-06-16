git submodule update --init --recursive
mkdir -p build
./vendor/zap-toml/build_lib.sh
zapc src/main.zp -o build/thor --import-map @toml=./vendor/zap-toml/src -Lvendor/zap-toml/lib -lztoml
