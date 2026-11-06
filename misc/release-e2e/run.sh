#!/usr/bin/env bash
# End-to-end check that a dedicated-mode nydusd stops when its image's last
# container is removed, and comes back for the next one.
#
# usage: misc/release-e2e/run.sh <containerd-nydus-grpc binary (linux, host arch)>
# Runs real containerd + nerdctl + nydusd in a privileged Docker container.
# Run it once with an upstream binary and once with the fixed one to compare.
set -euo pipefail

BIN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
[ -x "$BIN" ] || { echo "not executable: $BIN" >&2; exit 1; }

docker run --rm --privileged --device /dev/fuse \
  -v "$BIN":/usr/local/bin/containerd-nydus-grpc:ro \
  -v "$HERE/inside.sh":/inside.sh:ro \
  ubuntu:24.04 bash /inside.sh
