#!/usr/bin/env bash

# NVIDIA GPU Operator 설치 (CP1에서 1회 실행)
# 순서: 05_kubeadm_bootstrap.sh -> GPU 노드에 09_nvidia_driver.sh -> 이 스크립트 -> 20_kubeflow.sh
#
# 설계 메모:
# - 드라이버는 09_nvidia_driver.sh가 GPU 노드에 미리 설치해두고, 여기서는 driver.enabled=false로
#   GPU Operator가 드라이버를 건드리지 않게 함 (호스트에서 nvidia-smi가 바로 되게 하기 위함).
#   컨테이너 툴킷/디바이스 플러그인/NFD/GFD/DCGM은 그대로 GPU Operator가 관리
# - GPU Operator 26.7.0의 기본 조합으로 고정함
# - MIG Manager는 설치는 해두되(Operator 기본값), 어떤 GPU에도 MIG 설정 라벨을 안 붙이므로
#   GPU는 계속 통째로 쓰임. 나중에 작은 워크로드가 늘면 라벨 하나로 바로 전환 가능

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/versions.env"

require_root
setup_logging "10_gpu_operator"

NS="gpu-operator"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo " GPU Operator ${GPU_OPERATOR_VERSION}"
echo "========================================"

yellow "==[1/4] Helm 설치 확인 =="
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version
green "Helm 준비 완료"

yellow "==[2/4] NVIDIA Helm repo 등록 =="
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia
green "repo 등록 완료"

yellow "==[3/4] GPU Operator ${GPU_OPERATOR_VERSION} 설치 =="
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --version "${GPU_OPERATOR_VERSION}" \
  --namespace "${NS}" \
  --create-namespace \
  --set driver.enabled=false \
  --wait --timeout 15m
green "GPU Operator 설치 완료"

yellow "==[4/4] ClusterPolicy 준비 상태 대기 =="
# GPU Operator는 driver/toolkit/device-plugin 등 여러 DaemonSet을 순차적으로 올리므로
# 전체가 ready 될 때까지 ClusterPolicy 상태로 확인 (최대 15분)
for i in $(seq 1 90); do
  STATE="$(kubectl get clusterpolicy -o jsonpath='{.items[0].status.state}' 2>/dev/null || echo "")"
  [[ "$STATE" == "ready" ]] && break
  echo "ClusterPolicy 상태: ${STATE:-미생성} (${i}/90, 10초 간격)"
  sleep 10
done
[[ "$STATE" == "ready" ]] || die "ClusterPolicy가 15분 안에 ready 상태가 되지 않았습니다. 'kubectl get pods -n ${NS}'로 확인하세요."
green "ClusterPolicy: ready"

echo
echo "---- GPU Operator Pod 상태 ----"
kubectl get pods -n "${NS}"
echo
echo "---- 노드별 GPU 노출 확인 ----"
kubectl get nodes -o json | \
  python3 -c "
import json, sys
nodes = json.load(sys.stdin)['items']
for n in nodes:
    gpu = n['status'].get('capacity', {}).get('nvidia.com/gpu')
    if gpu:
        print(f\"{n['metadata']['name']}: nvidia.com/gpu={gpu}\")
" || true

green "DONE: GPU Operator 설치 완료."
echo "Log: ${LOG_DIR}/10_gpu_operator.log"
