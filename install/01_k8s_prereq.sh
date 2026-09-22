#!/usr/bin/env bash

# Kubernetes 사전 요구사항 적용 (모든 노드: CP/Worker 공통)
# 목적:
# 1) swap 비활성화 (kubelet 필수 조건)
# 2) overlay/br_netfilter 커널 모듈 로드 + 영구 적용
# 3) ip_forward 및 브릿지 netfilter 관련 sysctl 설정 적용

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "01_k8s_prereq"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/4] 커널 모듈 영구 등록 및 즉시 로드 =="
# overlay:      containerd가 사용하는 OverlayFS 파일시스템
# br_netfilter: 브릿지 트래픽을 iptables/ip6tables가 볼 수 있게 함 (CNI 필수)
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
lsmod | grep -E "^overlay|^br_netfilter"
green "커널 모듈 로드 완료"

yellow "==[2/4] sysctl 파라미터 적용 =="
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system | grep -E "bridge-nf-call|ip_forward"
green "sysctl 파라미터 적용 완료"

yellow "==[3/4] Swap 비활성화 =="
# kubelet은 swap이 활성화된 노드에서 기동을 거부함
swapoff -a
cp -a /etc/fstab /etc/fstab.bak 2>/dev/null || true
sed -i -E 's@^([^#].*\s+swap\s+.*)$@#\1@g' /etc/fstab
echo "--- /proc/swaps (비어있어야 정상) ---"
cat /proc/swaps
green "Swap 비활성화 완료"

yellow "==[4/4] Final check =="
echo "---- 커널 모듈 ----"
lsmod | grep -E "^overlay|^br_netfilter" || red "WARNING: 모듈 확인 실패"
echo
echo "---- sysctl 주요 값 ----"
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
echo
echo "---- Swap 상태 ----"
free -h | grep -i swap

echo "Log: ${LOG_DIR}/01_k8s_prereq.log"
green "DONE: k8s prerequisites applied."
