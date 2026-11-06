#!/usr/bin/env bash
# Runs inside the privileged container started by run.sh.
set -euo pipefail

NYDUS_VERSION=v2.4.5
NERDCTL_VERSION=2.1.3
IMAGE=ghcr.io/dragonflyoss/image-service/alpine:nydus-latest
ARCH=$(dpkg --print-architecture)

apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq containerd curl ca-certificates fuse3 procps >/dev/null

curl -fsSL "https://github.com/dragonflyoss/nydus/releases/download/${NYDUS_VERSION}/nydus-static-${NYDUS_VERSION}-linux-${ARCH}.tgz" |
  tar -xz -C /usr/local/bin --strip-components=1
curl -fsSL "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${ARCH}.tar.gz" |
  tar -xz -C /usr/local/bin nerdctl

mkdir -p /etc/nydus /etc/containerd
cat >/etc/nydus/nydusd-config.json <<'EOF'
{
  "device": {
    "backend": {"type": "registry", "config": {"scheme": "https", "timeout": 30, "connect_timeout": 10, "retry_limit": 2}},
    "cache": {"type": "blobcache"}
  },
  "mode": "direct",
  "digest_validate": false,
  "enable_xattr": true,
  "fs_prefetch": {"enable": true, "threads_count": 4}
}
EOF
cat >/etc/nydus/config.toml <<'EOF'
version = 1
root = "/var/lib/containerd-nydus"
address = "/run/containerd-nydus/containerd-nydus-grpc.sock"
daemon_mode = "dedicated"
[daemon]
nydusd_config = "/etc/nydus/nydusd-config.json"
nydusd_path = "/usr/local/bin/nydusd"
nydusimage_path = "/usr/local/bin/nydus-image"
fs_driver = "fusedev"
recover_policy = "restart"
[snapshot]
sync_remove = true
EOF
cat >/etc/containerd/config.toml <<'EOF'
version = 2
[proxy_plugins.nydus]
  type = "snapshot"
  address = "/run/containerd-nydus/containerd-nydus-grpc.sock"
EOF

containerd-nydus-grpc --config /etc/nydus/config.toml --log-to-stdout >/var/log/snapshotter.log 2>&1 &
containerd >/var/log/containerd.log 2>&1 &
for _ in $(seq 50); do
  [ -S /run/containerd-nydus/containerd-nydus-grpc.sock ] && [ -S /run/containerd/containerd.sock ] && break
  sleep 0.2
done

n() { nerdctl --snapshotter nydus "$@"; }
daemons() { pgrep -c -x nydusd || true; }
step() { printf '%-44s nydusd=%s\n' "$1" "$(daemons)"; }
removes() { grep -c '\[Remove\] snapshot with key' /var/log/snapshotter.log || true; }
# containerd removes a deleted container's snapshot asynchronously in its GC;
# wait for the snapshotter to log it before counting daemons.
rm_and_wait() {
  local before; before=$(removes)
  n rm "$1" >/dev/null
  for _ in $(seq 100); do
    [ "$(removes)" -gt "$before" ] && return 0
    sleep 0.1
  done
  echo "timed out waiting for the snapshot of $1 to be removed" >&2
  return 1
}

n pull -q --platform linux/amd64 "$IMAGE" >/dev/null
step "pulled image"
n create -q --platform linux/amd64 --net none --name c1 "$IMAGE" true >/dev/null
step "created container c1"
n create -q --platform linux/amd64 --net none --name c2 "$IMAGE" true >/dev/null
step "created container c2 (same image)"
rm_and_wait c1
step "removed c1"
rm_and_wait c2
# The fix stops nydusd at the end of Remove; give it up to 10s to exit.
for _ in $(seq 100); do [ "$(daemons)" -eq 0 ] && break; sleep 0.1; done
step "removed c2 (last container)"
n create -q --platform linux/amd64 --net none --name c3 "$IMAGE" true >/dev/null
step "created c3 (same image again)"

mnt=$(grep -oE '/var/lib/containerd-nydus/snapshots/[0-9]+/mnt' /proc/mounts | head -1)
echo "c3 image mount ${mnt:-<none>}: $(ls "${mnt:-/nonexistent}" 2>/dev/null | tr '\n' ' ')"
echo "cached blob files: $(find /var/lib/containerd-nydus/cache -type f | wc -l)"
rm_and_wait c3
for _ in $(seq 100); do [ "$(daemons)" -eq 0 ] && break; sleep 0.1; done
step "removed c3"
echo "--- snapshotter log (release lines)"
grep -E 'no containers left|failed to release' /var/log/snapshotter.log || echo "(none)"
