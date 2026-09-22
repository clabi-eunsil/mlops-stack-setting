#!/usr/bin/env bash

# ubuntu 설치 직후 가장 먼저 실행
# 목적:
# - 운영/디버깅에 필요한 기본 패키지 설치
# - chrony로 시간 동기화 (k8s control plane 권장)
# - SSH keepalive 설정으로 세션 끊김 완화
# - 자동 업데이트 비활성화 (재현성 우선)
#
# 대상: Ubuntu 24.04 bare metal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "00_os_base"

TIMEZONE="${TIMEZONE:-Asia/Seoul}"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[0/5] OS 버전 확인 =="
DETECTED_OS="$(lsb_release -rs 2>/dev/null || echo unknown)"
echo "감지된 Ubuntu 버전: ${DETECTED_OS}"
if [[ "${DETECTED_OS}" != "24.04" ]]; then
  yellow "WARNING: 목표 버전은 24.04입니다. 패키지 저장소/커널 조합이 다를 수 있으니 계속 진행 전 확인하세요."
fi

yellow "==[1/5] 기본 패키지 설치 =="
apt-get update
apt-get install -y \
  build-essential dkms libelf-dev libglvnd-dev \
  pciutils lsb-release software-properties-common bash-completion \
  chrony \
  net-tools iproute2 iputils-ping traceroute dnsutils tcpdump \
  ca-certificates apt-transport-https gnupg \
  curl wget tar unzip rsync \
  git vim jq \
  htop sysstat strace less tmux
green "패키지 설치 완료"

yellow "==[2/5] 시간 동기화 (chrony) =="
# k8s control plane은 chrony 권장. systemd-timesyncd와 역할이 겹치므로 비활성화
systemctl disable --now systemd-timesyncd 2>/dev/null || true
systemctl enable --now chrony
timedatectl set-timezone "${TIMEZONE}"
timedatectl | grep "Time zone"
chronyc tracking | grep -E "Reference|Stratum|System time" || true
green "시간 동기화 완료 (chrony, ${TIMEZONE})"

yellow "==[3/5] SSH keepalive =="
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-keepalive.conf <<'EOF'
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
green "SSH keepalive 설정 완료"

yellow "==[4/5] 자동 업데이트 비활성화 =="
systemctl disable --now unattended-upgrades 2>/dev/null || true
green "자동 업데이트 비활성화 완료"

yellow "==[5/5] 최종 확인 =="
echo "---- 설치된 주요 패키지 버전 ----"
chronyc --version   2>/dev/null || true
git    --version    2>/dev/null || true
curl   --version | head -1 2>/dev/null || true
jq     --version    2>/dev/null || true

echo
echo "---- 시스템 상태 요약 ----"
timedatectl
systemctl is-active chrony && echo "chrony: OK" || echo "chrony: FAIL"
systemctl is-active ssh 2>/dev/null && echo "ssh: OK" || \
  systemctl is-active sshd 2>/dev/null && echo "sshd: OK" || echo "ssh/sshd: FAIL"

echo "Log: ${LOG_DIR}/00_os_base.log"
green "DONE: OS base ready."
