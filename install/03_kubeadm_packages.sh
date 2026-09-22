#!/usr/bin/env bash

# kubeadm/kubelet/kubectl 설치 (모든 노드: CP/Worker 공통)
# - 목표 버전: versions.env의 K8S_VERSION(1.36.x) 계열 중 repo에 있는 최신 패치를 자동 선택
# - kubelet은 enable만 해두고 start는 하지 않음 (kubeadm init/join 시 자동 기동, 그 전까진 CrashLoop가 정상)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "03_kubeadm_packages"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

K8S_MINOR="${K8S_VERSION%.x}"  # "1.36.x" -> "1.36"

yellow "==[1/4] k8s ${K8S_MINOR} 공식 repo 등록 =="
# pkgs.k8s.io는 minor 버전별로 repo가 분리되어 있음 (v1.36 repo는 1.36.x만 제공)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/k8s.gpg
chmod a+r /etc/apt/keyrings/k8s.gpg

echo "deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/k8s.list
apt-get update
green "k8s ${K8S_MINOR} repo 등록 완료"

yellow "==[2/4] kubeadm/kubelet/kubectl ${K8S_MINOR}.x 버전 확인 =="
# 하드코딩된 patch 버전은 시간이 지나면 repo에서 사라질 수 있으므로,
# K8S_APT_VERSION을 지정하지 않으면 repo에 있는 최신 패치를 자동 선택
K8S_APT_VERSION="${K8S_APT_VERSION:-}"
if [[ -z "$K8S_APT_VERSION" ]]; then
  K8S_APT_VERSION="$(apt-cache madison kubelet | awk '{print $3}' | grep -E "^${K8S_MINOR//./\\.}\." | sort -V | tail -1)"
fi
[[ -n "$K8S_APT_VERSION" ]] || die "kubelet ${K8S_MINOR}.x 버전을 repo에서 찾지 못했습니다. 'apt-cache madison kubelet'으로 직접 확인하세요."
echo "설치할 버전: ${K8S_APT_VERSION}"

yellow "==[3/4] 설치 및 버전 고정 =="
apt-get install -y \
  kubelet="${K8S_APT_VERSION}" \
  kubeadm="${K8S_APT_VERSION}" \
  kubectl="${K8S_APT_VERSION}"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
green "kubeadm/kubelet/kubectl ${K8S_APT_VERSION} 설치 완료 (apt-mark hold)"

yellow "==[4/4] Final check =="
kubeadm version
kubelet --version
kubectl version --client
apt-mark showhold | grep -E 'kubelet|kubeadm|kubectl'
systemctl is-enabled kubelet && echo "kubelet enabled: OK" || red "kubelet enabled: FAIL"

echo "Log: ${LOG_DIR}/03_kubeadm_packages.log"
green "DONE: kubeadm packages installed."
