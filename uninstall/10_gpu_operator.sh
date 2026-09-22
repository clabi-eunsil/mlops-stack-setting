#!/usr/bin/env bash

# GPU Operator 제거 (install/10_gpu_operator.sh의 역순)
# CP1(kubectl 접근 가능한 노드)에서 실행.
# 주의: driver DaemonSet 제거 과정에서 GPU를 쓰던 Pod가 있으면 먼저 정리해야 함

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../common/lib.sh"

require_root
setup_logging "uninstall_10_gpu_operator"

NS="gpu-operator"

echo "========================================"
echo " Start: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "========================================"

yellow "==[1/2] Helm 릴리스 제거 =="
if helm status gpu-operator -n "$NS" >/dev/null 2>&1; then
  helm uninstall gpu-operator -n "$NS" --wait --timeout 10m
  green "helm uninstall 완료"
else
  yellow "helm 릴리스 gpu-operator 없음"
fi

yellow "==[2/2] Namespace 및 잔여 CRD 정리 =="
kubectl delete namespace "$NS" --ignore-not-found --timeout=120s

REMAINING_CRDS="$(kubectl get crd -o name 2>/dev/null | grep -E 'nvidia\.com|gpu-operator' || true)"
if [[ -n "$REMAINING_CRDS" ]]; then
  echo "$REMAINING_CRDS" | xargs -r kubectl delete --ignore-not-found
  green "잔여 CRD 정리 완료"
fi

echo
green "DONE: GPU Operator 제거 완료."
echo "확인: kubectl get nodes -o json | grep nvidia.com/gpu  (아무 것도 없어야 정상)"
echo "Log: ${LOG_DIR}/uninstall_10_gpu_operator.log"
