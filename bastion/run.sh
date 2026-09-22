#!/usr/bin/env bash

# 클러스터 전체 부트스트랩 오케스트레이터 (bastion에서 실행)
# - CP/Worker IP 목록을 한 번만 입력받아, 각 노드에 필요한 install/*.sh를
#   올바른 인자로 채워서 SSH로 순서대로 실행함
# - CP IP를 Worker 목록에도 넣으면 그 노드는 CP+Worker 겸용으로 자동 처리됨 (taint 제거)
# - 노드 접근은 common/ssh.sh의 부트스트랩 전용 키로 이루어지고, 끝나면 흔적을 지움
#
# 사용법:
#   cp bastion/cluster.env.example bastion/cluster.env   (최초 1회)
#   vi bastion/cluster.env                                (SSH_USER/CP_IPS/WORKER_IPS/VIP 채우기)
#   bash bastion/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/common/lib.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/common/ssh.sh"

in_array() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

echo "===== MLOps 클러스터 부트스트랩 (bastion) ====="

CLUSTER_ENV="${CLUSTER_ENV:-${SCRIPT_DIR}/cluster.env}"
[[ -f "$CLUSTER_ENV" ]] || die "설정 파일이 없습니다: ${CLUSTER_ENV}
다음을 먼저 실행하세요:
  cp ${SCRIPT_DIR}/cluster.env.example ${CLUSTER_ENV}
  vi ${CLUSTER_ENV}"
# shellcheck disable=SC1090
source "$CLUSTER_ENV"

[[ -n "${SSH_USER:-}" ]] || die "${CLUSTER_ENV}에 SSH_USER를 채우세요."
export SSH_PORT="${SSH_PORT:-22}"
[[ -n "${CP_IPS:-}" ]]   || die "${CLUSTER_ENV}에 CP_IPS를 채우세요."
read -r -a CP_IPS <<<"${CP_IPS}"
read -r -a WORKER_IPS <<<"${WORKER_IPS:-}"
read -r -a GPU_IPS <<<"${GPU_IPS:-}"

if [[ "${#CP_IPS[@]}" -gt 1 ]]; then
  [[ -n "${VIP:-}" ]] || die "${CLUSTER_ENV}: CP가 ${#CP_IPS[@]}대라 VIP를 채워야 합니다."
else
  VIP=""
fi

INSTALL_GPU_OPERATOR="${INSTALL_GPU_OPERATOR:-0}"
INSTALL_KUBEFLOW="${INSTALL_KUBEFLOW:-0}"
INSTALL_MLFLOW="${INSTALL_MLFLOW:-0}"
EXPOSE_NODEPORT="${EXPOSE_NODEPORT:-0}"
if [[ "$INSTALL_MLFLOW" == "1" && "$INSTALL_KUBEFLOW" != "1" ]]; then
  die "${CLUSTER_ENV}: INSTALL_MLFLOW=1이면 INSTALL_KUBEFLOW=1도 필요합니다 (MLflow가 Kubeflow의 SeaweedFS/대시보드를 재사용함)."
fi

declare -A SEEN
ALL_NODES=()
for ip in "${CP_IPS[@]}" "${WORKER_IPS[@]}"; do
  if [[ -z "${SEEN[$ip]:-}" ]]; then
    ALL_NODES+=("$ip")
    SEEN[$ip]=1
  fi
done

if [[ "$INSTALL_GPU_OPERATOR" == "1" ]]; then
  [[ "${#GPU_IPS[@]}" -gt 0 ]] || die "${CLUSTER_ENV}: INSTALL_GPU_OPERATOR=1이면 GPU_IPS를 채워야 합니다."
  for ip in "${GPU_IPS[@]}"; do
    in_array "$ip" "${ALL_NODES[@]}" || die "${CLUSTER_ENV}: GPU_IPS의 ${ip}가 CP_IPS/WORKER_IPS에 없습니다."
  done
fi

echo
yellow "==== 설정 확인 ===="
echo "SSH_USER  : ${SSH_USER}"
echo "SSH_PORT  : ${SSH_PORT}"
echo "CP_IPS    : ${CP_IPS[*]}"
echo "WORKER_IPS: ${WORKER_IPS[*]:-(없음)}"
echo "VIP       : ${VIP:-(단일 CP, HA 없음)}"
echo "전체 노드 : ${ALL_NODES[*]}"
echo "GPU Operator 설치: ${INSTALL_GPU_OPERATOR}  /  Kubeflow 설치: ${INSTALL_KUBEFLOW}  /  MLflow 설치: ${INSTALL_MLFLOW}"
[[ "$INSTALL_GPU_OPERATOR" == "1" ]] && echo "GPU_IPS   : ${GPU_IPS[*]}"
echo "NodePort 노출: ${EXPOSE_NODEPORT}"
echo
read -r -p "위 설정으로 진행할까요? (yes 입력): " ACK
[[ "${ACK:-}" == "yes" ]] || die "사용자 취소."

ensure_local_key

yellow "==== Phase 1: 노드 접근 부트스트랩 + 공통 설치 (00~03) ===="
for ip in "${ALL_NODES[@]}"; do
  yellow "-- [$ip] --"
  bootstrap_node "$SSH_USER" "$ip"
  remote_copy "$SSH_USER" "$ip" "$REPO_ROOT"
  remote_run "$SSH_USER" "$ip" install/00_os_base.sh
  remote_run "$SSH_USER" "$ip" install/01_k8s_prereq.sh
  remote_run "$SSH_USER" "$ip" install/02_containerd.sh
  remote_run "$SSH_USER" "$ip" install/03_kubeadm_packages.sh
done

if [[ -n "$VIP" ]]; then
  yellow "==== Phase 2: HA 설정 (CP 노드) ===="
  for ip in "${CP_IPS[@]}"; do
    remote_run "$SSH_USER" "$ip" install/04_ha_setup.sh "$ip" "$VIP" "${CP_IPS[@]}"
  done
fi

CP1="${CP_IPS[0]}"
yellow "==== Phase 3: kubeadm init (CP1: ${CP1}) ===="
CP1_ARGS=()
[[ -n "$VIP" ]] && CP1_ARGS+=("--vip=${VIP}")
[[ -n "${POD_CIDR:-}" ]] && CP1_ARGS+=("--pod-cidr=${POD_CIDR}")
if in_array "$CP1" "${WORKER_IPS[@]}"; then
  CP1_ARGS+=(--schedulable)
fi
remote_run "$SSH_USER" "$CP1" install/05_kubeadm_bootstrap.sh init "${CP1_ARGS[@]}"

yellow "==== Phase 4: join 명령 회수 ===="
JOIN_CP_CMD="$(fetch_remote_file "$SSH_USER" "$CP1" /root/kubeadm-join-cp.sh)"
JOIN_WORKER_CMD="$(fetch_remote_file "$SSH_USER" "$CP1" /root/kubeadm-join-worker.sh)"
[[ -n "$JOIN_CP_CMD" && -n "$JOIN_WORKER_CMD" ]] || die "CP1에서 join 명령을 읽어오지 못했습니다."

if [[ "${#CP_IPS[@]}" -gt 1 ]]; then
  yellow "==== Phase 5: 나머지 CP join ===="
  for ip in "${CP_IPS[@]:1}"; do
    JOIN_ARGS=("$JOIN_CP_CMD")
    in_array "$ip" "${WORKER_IPS[@]}" && JOIN_ARGS+=(--schedulable)
    remote_run "$SSH_USER" "$ip" install/05_kubeadm_bootstrap.sh join-cp "${JOIN_ARGS[@]}"
  done
fi

PURE_WORKERS=()
for ip in "${WORKER_IPS[@]}"; do
  in_array "$ip" "${CP_IPS[@]}" || PURE_WORKERS+=("$ip")
done
if [[ "${#PURE_WORKERS[@]}" -gt 0 ]]; then
  yellow "==== Phase 6: Worker join ===="
  for ip in "${PURE_WORKERS[@]}"; do
    remote_run "$SSH_USER" "$ip" install/05_kubeadm_bootstrap.sh join-worker "$JOIN_WORKER_CMD"
  done
fi

yellow "==== Phase 7: 전체 노드 Ready 확인 ===="
wait_for_nodes_ready "$SSH_USER" "$CP1" "${#ALL_NODES[@]}" 300 \
  || die "노드가 5분 안에 전부 Ready 상태가 되지 않았습니다. 'ssh -p ${SSH_PORT} ${SSH_USER}@${CP1} kubectl get nodes'로 확인 후 재실행하세요."
green "전체 ${#ALL_NODES[@]}개 노드 Ready 확인됨"

if [[ "$INSTALL_GPU_OPERATOR" == "1" ]]; then
  yellow "==== Phase 8: NVIDIA 드라이버 (GPU 노드) ===="
  for ip in "${GPU_IPS[@]}"; do
    remote_run "$SSH_USER" "$ip" install/09_nvidia_driver.sh
  done

  yellow "==== Phase 9: GPU Operator (CP1) ===="
  remote_run "$SSH_USER" "$CP1" install/10_gpu_operator.sh
else
  yellow "INSTALL_GPU_OPERATOR=0 -> GPU 드라이버/Operator 건너뜀"
fi

if [[ "$INSTALL_KUBEFLOW" == "1" ]]; then
  yellow "==== Phase 10: Kubeflow (CP1) ===="
  remote_run "$SSH_USER" "$CP1" install/20_kubeflow.sh
else
  yellow "INSTALL_KUBEFLOW=0 -> Kubeflow 건너뜀"
fi

if [[ "$INSTALL_KUBEFLOW" == "1" && "$EXPOSE_NODEPORT" == "1" ]]; then
  yellow "==== Phase 11: Kubeflow/MLflow NodePort 노출 (CP1) ===="
  NODEPORT_ARGS=()
  [[ -n "${KUBEFLOW_NODEPORT:-}" ]] && NODEPORT_ARGS+=("--kubeflow-nodeport=${KUBEFLOW_NODEPORT}")
  [[ -n "${KUBEFLOW_STATUS_NODEPORT:-}" ]] && NODEPORT_ARGS+=("--kubeflow-status-nodeport=${KUBEFLOW_STATUS_NODEPORT}")
  [[ -n "${SEAWEEDFS_S3_NODEPORT:-}" ]] && NODEPORT_ARGS+=("--seaweedfs-s3-nodeport=${SEAWEEDFS_S3_NODEPORT}")
  remote_run "$SSH_USER" "$CP1" install/21_kubeflow_nodeport.sh "${NODEPORT_ARGS[@]}"
fi

if [[ "$INSTALL_MLFLOW" == "1" ]]; then
  yellow "==== Phase 12: MLflow (CP1) ===="
  remote_run "$SSH_USER" "$CP1" install/30_mlflow.sh
else
  yellow "INSTALL_MLFLOW=0 -> MLflow 건너뜀"
fi

yellow "==== Phase 13: 부트스트랩 흔적 정리 ===="
for ip in "${ALL_NODES[@]}"; do
  cleanup_node "$SSH_USER" "$ip"
done
rm -f "$SSH_KEY" "${SSH_KEY}.pub"
green "bastion 로컬의 부트스트랩 키도 삭제했습니다 (모든 노드에서 이미 무효화됨)"

yellow "==== 클러스터 상태 확인 ===="
echo "주의: 위에서 SSH 키를 지웠으므로 아래 확인은 CP1에 남아있는 기존 계정 접근으로 재확인하세요."
echo "예: ssh -p ${SSH_PORT} ${SSH_USER}@${CP1} kubectl get nodes -o wide"

green "DONE: 클러스터 부트스트랩 완료."
