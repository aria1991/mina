#!/bin/sh

set -eu

if [ -z "$KIMCHI_BINDINGS_GEN" ]; then
    rm -rf target Cargo.lock
    pushd binding_generation
    cargo build --release --bin binding_generation
    popd
    KIMCHI_BINDINGS_GEN="target/release"
fi

"$KIMCHI_BINDINGS_GEN/binding_generation" "$@"
