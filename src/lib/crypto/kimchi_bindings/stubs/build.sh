#!/bin/sh

set -eu

if [ -z "$KIMCHI_BINDINGS_STUBS" ]; then
    RUSTFLAGS="-C target-feature=+bmi2,+adx" cargo build --release
    KIMCHI_BINDINGS_STUBS="target/release"
fi

cp "$KIMCHI_BINDINGS_STUBS/libwires_15_stubs.a" .
