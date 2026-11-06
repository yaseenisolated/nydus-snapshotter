#!/usr/bin/env bash
# Same check as run.sh, on a node-testing box: real kubelet, the AMI's nydus
# config and a real pipeline-built nydus image.
#
# usage (on the box): sudo -E ./node-testing.sh <label> [image]
# Swap /usr/local/bin/containerd-nydus-grpc and restart nydus-snapshotter
# between runs to compare binaries.
set -euo pipefail

LABEL=${1:?usage: $0 <label> [image]}
IMAGE=${2:-registry.dev-aws.us-east-1.cerebrium.ai/dev-p-9676c59f-node-testing-gpu-warmup:dev-build-5a205893}
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
SINCE=$(date '+%Y-%m-%d %H:%M:%S')

daemons() { pgrep -c -x nydusd || true; }
step() { printf '[%s] %-46s nydusd=%s\n' "$LABEL" "$1" "$(daemons)"; }

pod() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, labels: {release-e2e: "true"}}
spec:
  nodeName: $NODE
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  containers:
  - name: app
    image: $IMAGE
    imagePullPolicy: IfNotPresent
    command: ["sleep", "infinity"]
EOF
  kubectl wait --for=condition=Ready "pod/$1" --timeout=15m >/dev/null
}

delete() {
  kubectl delete pod "$1" --wait >/dev/null
  # kubelet removes the container, then containerd GC removes its snapshot.
  local snaps
  for _ in $(seq 600); do
    snaps=$(ctr -n k8s.io snapshots --snapshotter nydus ls | awk '$3=="Active"' | wc -l)
    [ "$snaps" -le "$BASE_ACTIVE" ] && break
    sleep 0.1
  done
}

# Seconds from "[Prepare] snapshot with key <container snapshot>" to the
# image's "Nydus remote snapshot ... is ready", for the most recent Prepare.
prepare_secs() {
  journalctl -u nydus-snapshotter --since "$SINCE" -o short-iso-precise --no-pager |
    awk '/\[Prepare\] snapshot with key/ && !/extract-/ {start=$1} /Nydus remote snapshot .* is ready/ {end=$1}
         END {print start, end}' |
    while read -r s e; do
      [ -n "${e:-}" ] && python3 -c "from datetime import datetime as d;print(round((d.fromisoformat('$e')-d.fromisoformat('$s')).total_seconds(),3))"
    done
}

kubectl delete pod -l release-e2e=true --wait >/dev/null 2>&1 || true
BASE_ACTIVE=$(ctr -n k8s.io snapshots --snapshotter nydus ls | awk '$3=="Active"' | wc -l)
step "start (snapshotter $(containerd-nydus-grpc --version | awk '/Revision/{print $2}' | cut -c1-8))"

pod a1; step "pod a1 Ready"
pod a2; step "pod a2 Ready (same image)"; echo "  a2 prepare, nydusd running: $(prepare_secs)s"
delete a1; step "deleted a1"
delete a2
for _ in $(seq 100); do [ "$(daemons)" -eq 0 ] && break; sleep 0.1; done
step "deleted a2 (last pod on the image)"
pod a3; step "pod a3 Ready (same image again)"; echo "  a3 prepare, after release: $(prepare_secs)s"
kubectl exec a3 -- sh -c 'ls / | tr "\n" " "; echo; find /usr -type f | head -2000 | xargs cat 2>/dev/null | wc -c' | sed "s/^/  a3 fs: /"
delete a3
for _ in $(seq 100); do [ "$(daemons)" -eq 0 ] && break; sleep 0.1; done
step "deleted a3"
echo "  release log lines: $(journalctl -u nydus-snapshotter --since "$SINCE" --no-pager | grep -c 'no containers left' || true)"
