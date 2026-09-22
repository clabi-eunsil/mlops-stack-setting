#!/usr/bin/env bash

# kubeadm init/join + Calico CNI(첫 CP에서만) + CP/Worker 겸용 노드의 taint 제거
#
# 사용법:
#   sudo bash 05_kubeadm_bootstrap.sh init [--vip=<VIP>] [--pod-cidr=<CIDR>] [--schedulable]
#     - --vip를 생략하면 단일 CP(HA 없음) 구성
#     - --pod-cidr를 생략하면 192.168.0.0/16 (Calico 기본값) 사용
#     - 성공하면 /root/kubeadm-join-worker.sh, /root/kubeadm-join-cp.sh 에 join 명령 저장
#       (bastion에서 이 파일 내용을 그대로 join-cp/join-worker의 인자로 넘기면 됨)
#
#   sudo bash 05_kubeadm_bootstrap.sh join-cp "<kubeadm-join-cp.sh 내용>" [--schedulable]
#   sudo bash 05_kubeadm_bootstrap.sh join-worker "<kubeadm-join-worker.sh 내용>"
#
#   --schedulable: 이 노드를 CP이면서 Worker로도 쓰고 싶을 때 (control-plane taint 제거)
#                  join-worker에는 의미 없음 (원래 taint가 없음)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "05_kubeadm_bootstrap"

MODE="${1:-}"
[[ -n "$MODE" ]] || die "사용법: $0 init [--vip=IP] [--pod-cidr=CIDR] [--schedulable] | join-cp \"<join cmd>\" [--schedulable] | join-worker \"<join cmd>\""
shift

SCHEDULABLE=0
VIP=""
POD_CIDR=""
ARGS=()
for a in "$@"; do
  case "$a" in
    --schedulable) SCHEDULABLE=1 ;;
    --vip=*)       VIP="${a#--vip=}" ;;
    --pod-cidr=*)  POD_CIDR="${a#--pod-cidr=}" ;;
    *)             ARGS+=("$a") ;;
  esac
done
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"

setup_kubeconfig() {
  mkdir -p "$HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local home
    home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    mkdir -p "${home}/.kube"
    cp -f /etc/kubernetes/admin.conf "${home}/.kube/config"
    # 그룹은 지정하지 않음: 배포판에 따라 유저명과 같은 이름의 그룹이 없을 수 있음
    # (예: 일부 클라우드 이미지는 계정을 sysadm류 공용 그룹에 넣음) - 소유자만 바꾸면 충분함
    chown "${SUDO_USER}" "${home}/.kube/config"
  fi
}

case "$MODE" in
  init)
    yellow "==[1/4] kubeadm init =="
    if [[ -f /etc/kubernetes/admin.conf ]]; then
      yellow "이미 kubeadm init이 완료되어 있습니다 (건너뜀). 다시 초기화하려면 kubeadm reset 후 재실행하세요."
    else
      INIT_ARGS=(--pod-network-cidr="${POD_CIDR}" --cri-socket=unix:///run/containerd/containerd.sock --upload-certs)
      [[ -n "$VIP" ]] && INIT_ARGS+=(--control-plane-endpoint="${VIP}:6443")
      kubeadm init "${INIT_ARGS[@]}" | tee /root/kubeadm-init.log
    fi

    yellow "==[2/4] kubeconfig 설정 =="
    setup_kubeconfig

    yellow "==[3/4] Calico CNI 설치 =="
    # versions.env엔 minor(3.32.x)까지만 두고, 정확한 patch는 GitHub 릴리스에서 자동 조회
    CALICO_MINOR="${CNI_CALICO_VERSION%.x}"
    CALICO_VERSION="${CALICO_VERSION:-}"
    if [[ -z "$CALICO_VERSION" ]]; then
      CALICO_VERSION="$(curl -fsSL https://api.github.com/repos/projectcalico/calico/releases \
        | grep -oE '"tag_name": *"v'"${CALICO_MINOR}"'\.[0-9]+"' \
        | grep -oE 'v[0-9.]+' \
        | sort -V | tail -1)"
    fi
    [[ -n "$CALICO_VERSION" ]] || die "Calico ${CALICO_MINOR}.x 릴리스를 찾지 못했습니다. CALICO_VERSION을 직접 지정하세요."
    echo "설치할 Calico 버전: ${CALICO_VERSION}"

    # server-side apply: idempotent(재실행 안전)하면서 tigera-operator.yaml에 포함된 대용량 CRD도
    # client-side apply의 annotation 크기 제한에 안 걸림
    kubectl apply --server-side --force-conflicts \
      -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

    # CRD가 API에 등록되기까지 잠깐 시간이 걸려 첫 apply는 실패할 수 있음 (공식 문서에도 나오는 정상 케이스) -> 재시도
    tries=0
    until kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"; do
      tries=$((tries + 1))
      [[ $tries -ge 10 ]] && die "Calico custom-resources.yaml 적용 실패 (10회 재시도)"
      yellow "CRD 등록 대기 중, 재시도 (${tries}/10)"
      sleep 5
    done

    yellow "==[4/4] join 명령 저장 =="
    kubeadm token create --print-join-command > /root/kubeadm-join-worker.sh
    CERT_KEY="$(grep -oP '(?<=--certificate-key )[a-f0-9]+' /root/kubeadm-init.log | head -1)"
    [[ -n "$CERT_KEY" ]] || die "kubeadm init 출력에서 certificate-key를 찾지 못했습니다. /root/kubeadm-init.log 확인 필요."
    echo "$(cat /root/kubeadm-join-worker.sh) --control-plane --certificate-key ${CERT_KEY}" > /root/kubeadm-join-cp.sh
    chmod 600 /root/kubeadm-join-worker.sh /root/kubeadm-join-cp.sh
    green "저장됨: /root/kubeadm-join-worker.sh, /root/kubeadm-join-cp.sh"
    ;;

  join-cp|join-worker)
    JOIN_CMD="${ARGS[*]:-}"
    [[ -n "$JOIN_CMD" ]] || die "join 명령 문자열이 필요합니다 (CP1의 /root/kubeadm-join-*.sh 내용을 그대로 전달)"

    yellow "==[1/2] ${MODE} =="
    eval "$JOIN_CMD"

    if [[ "$MODE" == "join-cp" ]]; then
      yellow "==[2/2] kubeconfig 설정 =="
      setup_kubeconfig
    fi
    ;;

  *)
    die "알 수 없는 MODE: ${MODE} (init|join-cp|join-worker 중 하나)"
    ;;
esac

if [[ "$SCHEDULABLE" -eq 1 && "$MODE" != "join-worker" ]]; then
  yellow "==[추가] Control-plane taint 제거 (이 노드를 Worker로도 사용) =="
  kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null \
    && green "taint 제거 완료" \
    || yellow "taint 제거 실패 또는 이미 없음 (node 이름이 hostname과 다르면 수동 확인 필요)"
fi

kubectl get nodes -o wide 2>/dev/null || true
green "DONE: kubeadm bootstrap (${MODE})"
