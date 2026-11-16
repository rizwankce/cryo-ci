#!/bin/sh
# Build `cryo-ci` for macOS and install it to ~/.cryo/bin, next to `cryo`:
# `cryo ci …` runs the cryo-ci beside it, and the runner's ssh uses the cryo beside cryo-ci.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product cryo-ci
mkdir -p "$HOME/.cryo/bin"
# Replace, never overwrite in place: the kernel caches a binary's signature per inode, and a
# signed binary rewritten in place is killed (SIGKILL) on its next launch.
cp .build/release/cryo-ci "$HOME/.cryo/bin/cryo-ci.new"
mv -f "$HOME/.cryo/bin/cryo-ci.new" "$HOME/.cryo/bin/cryo-ci"
echo "installed: $HOME/.cryo/bin/cryo-ci"
