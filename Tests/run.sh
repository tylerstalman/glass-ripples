#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
cc -std=c11 -O2 -Wall -Wextra -Werror -I Sources Tests/GridDecoderTests.c Sources/GridDecoder.c -lm -o "$build/test"
"$build/test"
