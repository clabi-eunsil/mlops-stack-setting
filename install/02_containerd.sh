#!/usr/bin/env bash

# containerd 설치 (모든 노드: CP/Worker 공통)
# - Ubuntu 기본 repo의 containerd는 1.x라 Docker 공식 repo에서 containerd.io 2.x를 설치
# - 목표 버전: versions.env의 CONTAINERD_VERSION(2.2.x) 계열 중 repo에 있는 최신 패치를 자동 선택
# - SystemdCgroup=true 로 설정 (kubelet과 cgroup driver 일치 필수)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "02_containerd"

CONTAINERD_MINOR="${CONTAINERD_VERSION%.x}"  # "2.2.x" -> "2.2"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/6] Docker 공식 repo 등록 =="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
green "Docker repo 등록 완료"

yellow "==[2/6] containerd.io ${CONTAINERD_MINOR}.x 버전 확인 =="
# 정확한 patch 버전은 시간이 지나면 repo에서 사라질 수 있으므로 versions.env엔 minor(2.2.x)까지만 두고,
# CONTAINERD_APT_VERSION을 지정하지 않으면 repo에 있는 최신 patch를 자동 선택
CONTAINERD_APT_VERSION="${CONTAINERD_APT_VERSION:-}"
if [[ -z "$CONTAINERD_APT_VERSION" ]]; then
  CONTAINERD_APT_VERSION="$(apt-cache madison containerd.io | awk '{print $3}' | grep -E "^${CONTAINERD_MINOR//./\\.}\." | sort -V | tail -1)"
fi
[[ -n "$CONTAINERD_APT_VERSION" ]] || die "containerd.io ${CONTAINERD_MINOR}.x 버전을 repo에서 찾지 못했습니다. 'apt-cache madison containerd.io'로 직접 확인하세요."
echo "설치할 버전: containerd.io=${CONTAINERD_APT_VERSION}"

yellow "==[3/6] containerd.io 설치 및 버전 고정 =="
apt-get install -y "containerd.io=${CONTAINERD_APT_VERSION}"
apt-mark hold containerd.io
green "containerd.io ${CONTAINERD_APT_VERSION} 설치 완료 (apt-mark hold)"

yellow "==[4/6] containerd 기본 설정 생성 =="
mkdir -p /etc/containerd
if [[ -f /etc/containerd/config.toml ]]; then
  mv /etc/containerd/config.toml /etc/containerd/config.toml.bak
  yellow "기존 config.toml -> config.toml.bak 으로 백업"
fi
containerd config default > /etc/containerd/config.toml
green "생성: /etc/containerd/config.toml"

yellow "==[5/6] SystemdCgroup=true 설정 =="
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd
green "containerd 재시작 완료"

yellow "==[6/6] Final check =="
systemctl is-active containerd && echo "containerd: OK" || red "containerd: FAIL"
containerd --version
grep -n "SystemdCgroup" /etc/containerd/config.toml
apt-mark showhold | grep containerd || true

echo "Log: ${LOG_DIR}/02_containerd.log"
green "DONE: containerd installed and configured for Kubernetes."
