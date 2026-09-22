#!/usr/bin/env bash

# NVIDIA 드라이버 제거 (install/09_nvidia_driver.sh의 역순, GPU 노드에서 실행)
# GPU Operator가 아직 설치되어 있다면 먼저 uninstall/10_gpu_operator.sh를 실행할 것
# (toolkit/device-plugin이 이 드라이버에 의존하므로 순서가 반대면 GPU Operator가 깨진 상태로 남음)

set -uo pipefail  # apt purge/modprobe 실패를 허용해야 하므로 -e는 사용하지 않음

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "uninstall_09_nvidia_driver"

DRIVER_MAJOR="${GPU_DRIVER_VERSION%%.*}"
DRIVER_PKG="nvidia-driver-${DRIVER_MAJOR}"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/3] 커널 모듈 언로드 =="
modprobe -r nvidia_drm 2>/dev/null || true
modprobe -r nvidia_modeset 2>/dev/null || true
modprobe -r nvidia_uvm 2>/dev/null || true
modprobe -r nvidia 2>/dev/null || true

yellow "==[2/3] 패키지 제거 =="
apt-mark unhold "$DRIVER_PKG" 2>/dev/null || true
apt-get purge -y 'nvidia-driver-*' 'libnvidia-*' 'nvidia-kernel-*' 'xserver-xorg-video-nvidia-*' 2>/dev/null || true
apt-get autoremove -y --purge 2>/dev/null || true

yellow "==[3/3] repo/keyring 제거 =="
rm -f /etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list
rm -f /usr/share/keyrings/cuda-archive-keyring.gpg

echo
green "DONE: NVIDIA 드라이버 제거 완료."
red ">>> 재부팅을 권장합니다 (커널 모듈 완전 초기화) <<<"
echo "Log: ${LOG_DIR}/uninstall_09_nvidia_driver.log"
