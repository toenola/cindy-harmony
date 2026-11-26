#!/bin/sh
set -eu

# Build from the shared Rust sources while keeping native outputs in the Harmony build cache.
: "${DEVECO_SDK_HOME:?Set DEVECO_SDK_HOME to the DevEco Command Line Tools SDK directory}"
harmony_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
repo_dir=$(CDPATH= cd -- "$harmony_dir/../.." && pwd)
native_sdk="$DEVECO_SDK_HOME/default/openharmony/native"
llvm="$native_sdk/llvm/bin"
target=aarch64-unknown-linux-ohos
export CARGO_TARGET_DIR="$harmony_dir/.cache/agent-net-native"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$llvm/$target-clang"
export CC_aarch64_unknown_linux_ohos="$llvm/$target-clang"
export AR_aarch64_unknown_linux_ohos="$llvm/llvm-ar"

"${CARGO:-cargo}" build --locked --release --lib --target "$target" \
  --manifest-path "$repo_dir/packages/agent-net-native/Cargo.toml"

"$llvm/$target-clang++" -std=c++17 -static-libstdc++ -fPIC -shared -Wl,--no-undefined -Wl,-soname,libcindy_agent_net.so \
  -I "$repo_dir/packages/agent-net-native/include" \
  "$harmony_dir/native/agent-net/bridge.cpp" \
  "$CARGO_TARGET_DIR/$target/release/libcindy_agent_net_native.a" \
  -lace_napi.z -o "$CARGO_TARGET_DIR/libcindy_agent_net.so"

if [ "${1:-}" = "--stage" ]; then
  arm64_libs="$harmony_dir/entry/libs/arm64-v8a"
  mkdir -p "$arm64_libs"
  install -m 0644 "$CARGO_TARGET_DIR/libcindy_agent_net.so" "$arm64_libs/"
fi
