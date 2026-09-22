#!/usr/bin/env bash

# k8s 클러스터 전체 제거, 노드를 Ubuntu bare metal에 가깝게 되돌림 (모든 노드에서 실행)
# install/01~05 (kubeadm/containerd/kubelet/HA) 의 역순
#
# 실행 순서 주의:
# - GPU Operator/Kubeflow/MLflow가 설치되어 있다면 이 스크립트 전에 먼저 지울 것
# - GPU 노드라면 uninstall/09_nvidia_driver.sh로 호스트 드라이버까지 먼저 제거할 것
#   (순서를 지키지 않으면 nvidia 모듈이 로드된 채로 컨테이너 런타임만 지워져 상태가 꼬일 수 있음)
#
# 완료 후 반드시 reboot 권장

set -uo pipefail  # kubeadm reset 등 일부 명령의 실패를 허용해야 하므로 -e는 사용하지 않음

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "uninstall_00_k8s_reset"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[0/9] GPU 잔존 확인 =="
if lsmod | grep -q '^nvidia'; then
  yellow "WARNING: nvidia 커널 모듈이 아직 로드되어 있습니다."
  yellow "GPU Operator/드라이버를 아직 안 지웠다면 먼저 uninstall/10_gpu_operator.sh, uninstall/09_nvidia_driver.sh를 실행하세요."
  read -r -p "그래도 계속 진행할까요? (yes 입력): " ACK
  [[ "${ACK:-}" == "yes" ]] || die "사용자 취소."
fi

yellow "==[1/9] kubelet/containerd/docker 서비스 중지 =="
for svc in kubelet docker docker.socket containerd keepalived haproxy; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

yellow "==[2/9] kubeadm reset =="
command -v kubeadm >/dev/null 2>&1 && kubeadm reset -f 2>/dev/null || true

yellow "==[3/9] k8s / CNI / kubeconfig 디렉터리 제거 =="
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd \
       /etc/cni /var/lib/cni /opt/cni /run/flannel \
       /var/lib/calico /root/.kube
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  HOME_DIR="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  [[ -n "$HOME_DIR" ]] && rm -rf "${HOME_DIR}/.kube"
fi

yellow "==[4/9] kubeadm/kubelet/kubectl 패키지 제거 =="
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
apt-get purge -y kubeadm kubelet kubectl kubernetes-cni cri-tools 2>/dev/null || true
rm -f /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl
rm -rf /lib/systemd/system/kubelet.service /etc/systemd/system/kubelet.service.d /etc/default/kubelet

yellow "==[5/9] containerd / Docker 제거 =="
apt-mark unhold containerd.io 2>/dev/null || true
apt-get purge -y containerd.io docker-ce docker-ce-cli docker-buildx-plugin \
  docker docker.io containerd runc 2>/dev/null || true
rm -rf /etc/containerd /var/lib/containerd /etc/docker /var/lib/docker \
       /var/run/docker.sock /run/docker.sock

yellow "==[6/9] HA(keepalived/haproxy) 제거 =="
apt-get purge -y keepalived haproxy 2>/dev/null || true
rm -rf /etc/keepalived /etc/haproxy

yellow "==[7/9] apt repo / keyring 제거 =="
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/k8s.list \
      /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/k8s.gpg

yellow "==[8/9] iptables 정리 =="
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true

yellow "==[9/9] apt 정리 =="
apt-get autoremove -y --purge 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo
green "DONE: k8s 관련 구성 요소를 제거했습니다."
red ">>> 재부팅을 권장합니다 (커널 모듈/네트워크 상태 완전 초기화) <<<"
echo "재부팅 후 확인: sudo bash audit/bare_ubuntu_check.sh"
echo "Log: ${LOG_DIR}/uninstall_00_k8s_reset.log"
