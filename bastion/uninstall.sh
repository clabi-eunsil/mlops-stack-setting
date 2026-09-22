#!/usr/bin/env bash

# 선택적 제거 오케스트레이터 (bastion에서 실행)
# bastion/cluster.env를 그대로 재사용해 대상 노드를 찾고, 필요한 범위만 SSH로 제거함
#
# 사용법:
#   bash bastion/uninstall.sh mlflow         # MLflow만 (CP1)
#   bash bastion/uninstall.sh kubeflow       # Kubeflow (MLflow가 없어야 함, CP1)
#   bash bastion/uninstall.sh gpu-operator   # GPU Operator만 (CP1)
#   bash bastion/uninstall.sh nvidia-driver  # 호스트 NVIDIA 드라이버 (GPU_IPS 노드, GPU Operator가 먼저 없어야 함)
#   bash bastion/uninstall.sh k8s            # 클러스터 전체 초기화 (모든 노드) - 되돌릴 수 없음
#   bash bastion/uninstall.sh all            # mlflow -> kubeflow -> gpu-operator -> nvidia-driver -> k8s 순서로 전부
#
# run.sh가 끝나면서 부트스트랩 키/NOPASSWD를 지우기 때문에, 이 스크립트는 실행할 때마다
# common/ssh.sh의 bootstrap_node로 다시 임시 접근을 열고 끝나면 다시 정리함

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/common/lib.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/common/ssh.sh"

TARGET="${1:-}"
case "$TARGET" in
  mlflow|kubeflow|gpu-operator|nvidia-driver|k8s|all) ;;
  *) die "사용법: $0 mlflow|kubeflow|gpu-operator|nvidia-driver|k8s|all" ;;
esac

CLUSTER_ENV="${CLUSTER_ENV:-${SCRIPT_DIR}/cluster.env}"
[[ -f "$CLUSTER_ENV" ]] || die "설정 파일이 없습니다: ${CLUSTER_ENV} (bastion/run.sh를 먼저 실행했던 그 파일)"
# shellcheck disable=SC1090
source "$CLUSTER_ENV"

read -r -a CP_IPS <<<"${CP_IPS}"
read -r -a WORKER_IPS <<<"${WORKER_IPS:-}"
read -r -a GPU_IPS <<<"${GPU_IPS:-}"
CP1="${CP_IPS[0]}"

declare -A SEEN
ALL_NODES=()
for ip in "${CP_IPS[@]}" "${WORKER_IPS[@]}"; do
  if [[ -z "${SEEN[$ip]:-}" ]]; then
    ALL_NODES+=("$ip")
    SEEN[$ip]=1
  fi
done

if [[ "$TARGET" == "k8s" || "$TARGET" == "all" ]]; then
  red "경고: 'k8s' 범위는 클러스터를 완전히 초기화하며 되돌릴 수 없습니다."
  echo "대상 노드: ${ALL_NODES[*]}"
  read -r -p "정말 진행할까요? (yes 입력): " ACK
  [[ "${ACK:-}" == "yes" ]] || die "사용자 취소."
fi

ensure_local_key

run_on_cp1() {
  local script="$1"
  yellow "-- CP1(${CP1})에서 ${script} 실행 --"
  bootstrap_node "$SSH_USER" "$CP1"
  remote_copy "$SSH_USER" "$CP1" "$REPO_ROOT"
  remote_run "$SSH_USER" "$CP1" "$script"
  cleanup_node "$SSH_USER" "$CP1"
}

run_on_all_nodes() {
  local script="$1"
  for ip in "${ALL_NODES[@]}"; do
    yellow "-- [$ip]에서 ${script} 실행 --"
    bootstrap_node "$SSH_USER" "$ip"
    remote_copy "$SSH_USER" "$ip" "$REPO_ROOT"
    remote_run "$SSH_USER" "$ip" "$script"
    cleanup_node "$SSH_USER" "$ip"
  done
}

run_on_gpu_nodes() {
  local script="$1"
  if [[ "${#GPU_IPS[@]}" -eq 0 ]]; then
    yellow "GPU_IPS가 비어있어 ${script}는 건너뜁니다."
    return
  fi
  for ip in "${GPU_IPS[@]}"; do
    yellow "-- [$ip]에서 ${script} 실행 --"
    bootstrap_node "$SSH_USER" "$ip"
    remote_copy "$SSH_USER" "$ip" "$REPO_ROOT"
    remote_run "$SSH_USER" "$ip" "$script"
    cleanup_node "$SSH_USER" "$ip"
  done
}

case "$TARGET" in
  mlflow)
    run_on_cp1 uninstall/30_mlflow.sh
    ;;
  kubeflow)
    run_on_cp1 uninstall/20_kubeflow.sh
    ;;
  gpu-operator)
    run_on_cp1 uninstall/10_gpu_operator.sh
    ;;
  nvidia-driver)
    run_on_gpu_nodes uninstall/09_nvidia_driver.sh
    ;;
  k8s)
    run_on_all_nodes uninstall/00_k8s_reset.sh
    ;;
  all)
    run_on_cp1 uninstall/30_mlflow.sh
    run_on_cp1 uninstall/20_kubeflow.sh
    run_on_cp1 uninstall/10_gpu_operator.sh
    run_on_gpu_nodes uninstall/09_nvidia_driver.sh
    run_on_all_nodes uninstall/00_k8s_reset.sh
    ;;
esac

rm -f "$SSH_KEY" "${SSH_KEY}.pub" 2>/dev/null || true
green "DONE: ${TARGET} 제거 완료."
