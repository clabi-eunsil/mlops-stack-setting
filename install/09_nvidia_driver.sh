#!/usr/bin/env bash

# NVIDIA 드라이버를 호스트에 직접 설치 (GPU 노드에서만 실행)
# 10_gpu_operator.sh가 driver.enabled=false로 설치되므로, 여기서 미리 깔아둔 드라이버를 그대로 사용함
#
# 왜 GPU Operator가 드라이버까지 관리하지 않게 했나:
# - GPU Operator 기본 모드(드라이버도 컨테이너로 관리)에서는 nvidia-smi가 호스트 PATH에 없어서
#   운영 중 상태 확인이 kubectl exec/dmesg로만 가능해 불편함
# - 드라이버만 호스트에 두고 나머지(toolkit/device-plugin/NFD/DCGM)는 GPU Operator가 관리하면
#   nvidia-smi는 평소처럼 호스트에서 바로 되면서 나머지 자동화 이점은 그대로 유지됨
#
# 참고: 첫 설치 후 커널 모듈 로드를 위해 재부팅이 필요할 수 있음 (스크립트 마지막에 확인)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "09_nvidia_driver"

DRIVER_MAJOR="${GPU_DRIVER_VERSION%%.*}"  # "595.91.07" -> "595"
DRIVER_PKG="nvidia-driver-${DRIVER_MAJOR}"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " Target driver: ${GPU_DRIVER_VERSION} (package: ${DRIVER_PKG})"
echo "========================================"

yellow "==[1/4] 기존 드라이버 흔적 확인 =="
if command -v nvidia-smi >/dev/null 2>&1; then
  yellow "이미 nvidia-smi가 있습니다:"
  nvidia-smi --query-gpu=driver_version --format=csv,noheader || true
  yellow "버전이 다르면 계속 진행 시 upgrade됩니다."
fi

yellow "==[2/4] NVIDIA CUDA apt repo 등록 =="
if [[ ! -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list ]]; then
  TMP_DEB="$(mktemp)"
  curl -fsSL -o "$TMP_DEB" \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i "$TMP_DEB"
  rm -f "$TMP_DEB"
fi
apt-get update
green "repo 등록 완료"

yellow "==[3/4] ${DRIVER_PKG} 설치 =="
# 정확한 patch 버전은 시간이 지나면 repo에서 사라질 수 있으므로,
# NVIDIA_DRIVER_APT_VERSION을 지정하지 않으면 목표 버전(예: 595.91.07)과 일치하는 패키지를 자동 탐색
NVIDIA_DRIVER_APT_VERSION="${NVIDIA_DRIVER_APT_VERSION:-}"
if [[ -z "$NVIDIA_DRIVER_APT_VERSION" ]]; then
  NVIDIA_DRIVER_APT_VERSION="$(apt-cache madison "$DRIVER_PKG" | awk '{print $3}' | grep -F "${GPU_DRIVER_VERSION}" | sort -V | tail -1)"
fi
if [[ -z "$NVIDIA_DRIVER_APT_VERSION" ]]; then
  yellow "WARNING: ${GPU_DRIVER_VERSION}과 정확히 일치하는 패키지를 못 찾았습니다. ${DRIVER_MAJOR} 브랜치 최신 patch로 대체합니다."
  NVIDIA_DRIVER_APT_VERSION="$(apt-cache madison "$DRIVER_PKG" | awk '{print $3}' | sort -V | tail -1)"
fi
[[ -n "$NVIDIA_DRIVER_APT_VERSION" ]] || die "${DRIVER_PKG} 버전을 repo에서 찾지 못했습니다. 'apt-cache madison ${DRIVER_PKG}'로 직접 확인하세요."
echo "설치할 버전: ${DRIVER_PKG}=${NVIDIA_DRIVER_APT_VERSION}"

apt-get install -y "${DRIVER_PKG}=${NVIDIA_DRIVER_APT_VERSION}"
apt-mark hold "$DRIVER_PKG"
green "${DRIVER_PKG} ${NVIDIA_DRIVER_APT_VERSION} 설치 완료 (apt-mark hold)"

yellow "==[4/4] 커널 모듈 로드 확인 =="
modprobe nvidia 2>/dev/null || true
if nvidia-smi >/dev/null 2>&1; then
  green "nvidia-smi 정상 동작:"
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
else
  die "nvidia-smi가 아직 동작하지 않습니다. 이 노드를 재부팅한 뒤 이 스크립트를 다시 실행하세요.
(GPU Operator가 driver.enabled=false로 이 드라이버에 의존하므로, 여기서 확실히 확인하고 넘어가야 함)"
fi

echo "Log: ${LOG_DIR}/09_nvidia_driver.log"
green "DONE: NVIDIA 드라이버 설치 완료."
