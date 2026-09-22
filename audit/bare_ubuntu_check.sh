#!/usr/bin/env bash

# Ubuntu bare metal 상태 점검
# - k8s / containerd / docker / NVIDIA 흔적이 남아있는지 확인
# - uninstall/00_k8s_reset.sh 실행 후 재부팅 뒤 검증 용도
#
# 사용법:
#   sudo bash audit/bare_ubuntu_check.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"

FOUND_COUNT=0
mark_found() { FOUND_COUNT=$((FOUND_COUNT + 1)); }

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    red "[FOUND] command: $cmd -> $(command -v "$cmd")"
    mark_found
  else
    green "[NONE] command: $cmd"
  fi
}

check_dir() {
  local d="$1"
  if [ -d "$d" ]; then
    red "[FOUND] dir: $d"
    mark_found
  else
    green "[NONE] dir: $d"
  fi
}

check_file() {
  local f="$1"
  if [ -e "$f" ]; then
    red "[FOUND] file: $f"
    mark_found
  else
    green "[NONE] file: $f"
  fi
}

yellow "========== Ubuntu Bare Metal Audit =========="

echo
yellow "[1] Command Check"
for cmd in docker containerd ctr crictl kubeadm kubelet kubectl helm nvidia-smi nvcc; do
  check_cmd "$cmd"
done

echo
yellow "[2] Package Check"
PKG_REGEX='kubeadm|kubelet|kubectl|kubernetes-cni|cri-tools|cri-dockerd|docker|docker-ce|docker-ce-cli|docker-buildx-plugin|containerd|containerd\.io|runc|nvidia|libnvidia|cuda|cudnn|nccl|keepalived|haproxy'
PKG_RESULT="$(dpkg -l | grep -E "$PKG_REGEX" || true)"
if [ -n "$PKG_RESULT" ]; then
  red "[FOUND] related packages:"
  echo "$PKG_RESULT"
  mark_found
else
  green "[NONE] related packages"
fi

echo
yellow "[3] Directory Check"
for d in \
  /etc/kubernetes \
  /var/lib/kubelet \
  /var/lib/etcd \
  /etc/cni \
  /var/lib/cni \
  /opt/cni \
  /var/lib/calico \
  /usr/local/cuda \
  /etc/containerd \
  /var/lib/containerd \
  /etc/docker \
  /var/lib/docker \
  /etc/keepalived \
  /etc/haproxy \
  /root/mlflow-platform \
  /root/kubeflow-community-distribution
do
  check_dir "$d"
done

echo
yellow "[4] File / Socket / Repo Check"
for f in \
  /usr/bin/kubeadm \
  /usr/bin/kubelet \
  /usr/bin/kubectl \
  /var/run/docker.sock \
  /run/docker.sock \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/k8s.list \
  /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list \
  /etc/apt/keyrings/docker.gpg \
  /etc/apt/keyrings/k8s.gpg \
  /usr/share/keyrings/cuda-archive-keyring.gpg \
  /etc/crictl.yaml
do
  check_file "$f"
done

echo
yellow "[5] Service / Unit Check"
for svc in kubelet docker docker.socket containerd keepalived haproxy; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service\|^${svc}\.socket"; then
    red "[FOUND] unit: $svc"
    mark_found
  else
    green "[NONE] unit: $svc"
  fi
done

echo
yellow "[6] Kernel NVIDIA Module"
NVIDIA_MOD="$(lsmod | grep '^nvidia' || true)"
if [ -n "$NVIDIA_MOD" ]; then
  red "[FOUND] NVIDIA module loaded:"
  echo "$NVIDIA_MOD"
  mark_found
else
  green "[NONE] NVIDIA module"
fi

echo
yellow "[7] PCI GPU Device"
PCI_GPU="$(lspci | grep -i nvidia || true)"
if [ -n "$PCI_GPU" ]; then
  yellow "[INFO] GPU hardware exists:"
  echo "$PCI_GPU"
else
  green "[NONE] NVIDIA GPU hardware"
fi

echo
yellow "[8] Final Verdict"
if [ "$FOUND_COUNT" -eq 0 ]; then
  green "[PASS] Runtime/config state is close to Ubuntu bare metal."
  green "[INFO] PCI GPU detection alone is acceptable if GPU hardware is physically installed."
else
  red "[FAIL] Found $FOUND_COUNT leftover item(s)."
  red "[ACTION] Review the [FOUND] items above."
fi

green ""
green "========== Audit Complete =========="
